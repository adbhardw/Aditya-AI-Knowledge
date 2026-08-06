# 05 — `RouteLocator` beans, and what `lr` means

## How one `RouteLocator` per service works

`ApiGatewayConfig` declares ~15 `@Bean RouteLocator` methods (`:103`–`:266`). They do not
conflict, because Spring Cloud Gateway collects **every** `RouteLocator` bean in the context
into a `CompositeRouteLocator` (then wraps it in a `CachingRouteLocator`). Each bean contributes
its routes to one merged table.

Every route is three things:

| Part | Example | Role |
|---|---|---|
| **Predicate** | `.path("/internal/forebitt/**")` | does this request match? |
| **Filters** | quota + path rate limit, then `rewritePath` | transform the request |
| **URI** | `forebittUrl` | where to forward |

The shared helper:

```java
// ApiGatewayConfig.java:82-100
private RouteLocator createRouteForService(RouteLocatorBuilder builder, String routeId,
        String path, String redirectFrom, String redirectTo, String targetUrl) {
    return builder.routes()
        .route(routeId, p -> p
            .path(path)
            .filters(f -> {
                if (!path.startsWith(WHITE_LISTED_ROUTE)) {   // "/internal"
                    f.filter(quotaRateLimitFilter);
                    f.filter(pathRateLimitFilter);
                }
                f.rewritePath(redirectFrom, redirectTo);
                return f;
            })
            .uri(targetUrl))
        .build();
}
```

### Consequence: `/internal/**` is never rate limited

`WHITE_LISTED_ROUTE = "/internal"` (`:26`). Every downstream-service route is
`/internal/<service>/**`, so the guard at `:87` skips both filters for all of them. In practice
**only `/v1/**` and `/v2/**` are rate limited** — internal service-to-service traffic is
unmetered by design.

### Route table

| Bean | Path | Target |
|---|---|---|
| `moonRakerRoutes` :103 | `/internal/moonraker/**` | moonraker |
| `picanmixRoutes` :109 | `/internal/picanmix/**` | picanmix |
| `primageRoutes` :115 | `/internal/primage/**` | primage |
| `unhygienixRoutes` :121 | `/internal/unhygienix/**` | unhygienix |
| `janusRoutes` :127 | `/internal/janus/**` | janus |
| `identityBridgeRoutes` :133 | `/internal/identity-bridge/**` | identity-bridge |
| `bucolixRoutes` :139 | `/internal/bucolix/**` | bucolix |
| `forebittRoutes` :145 | `/internal/forebitt/**` | forebitt |
| `gangwayRoutes` :151 | `/internal/gangway/**` | gangway |
| `armoricaRoutes` :157 | `/internal/armorica/**` | armorica |
| `quarterdeckRoutes` :163 | `/internal/quarterdeck/**` | quarterdeck |
| **`externalApiLRRoutes` :169** | `/v1/**` + `LR-Org-ID` | **identity-bridge** |
| `externalApiServiceRoutes` :238 | `/v1/**` | external-api-server |
| **`externalApiLRRoutesV2` :244** | `/v2/**` + `LR-Org-ID`, `.order(-1)` | **identity-bridge** |
| `externalApiServiceRoutesV2` :266 | `/v2/**` | external-api-server |

---

## What `lr` means: LiveRamp

Habu was acquired by LiveRamp, so the same `/v1` surface serves two different classes of caller.

| | `external_api_lr_routes` | `external_api_service_routes` |
|---|---|---|
| Caller | LiveRamp-side, holding an **LR** token | Direct Habu customer, Habu/Auth0 token |
| Discriminator | `LR-Org-ID` header **present** | header absent (fallback) |
| Target | **identity-bridge** — exchanges LR token for a Habu one | **external-api-server** directly |
| Rewrite | `/v1/x` → `/api/v1/lr-habu/external-api-server/v1/x` | `/v1/x` → `/v1/x` (no-op) |

So the naming reads as:

- **`lr`** = *LiveRamp-authenticated traffic that needs token exchange first*
- **`service`** = *the plain path straight to the backing service*

`lr-habu` in the rewrite target is identity-bridge's own namespace for "the Habu tenant".

This also explains the fallback in the quota filter:

```java
// QuotaRateLimitFilter.java:99-102
// Fall back to LR-Org-ID header if JWT doesn't contain org claim (e.g., LR tokens)
if (organizationId == null || organizationId.isEmpty()) {
    organizationId = exchange.getRequest().getHeaders().getFirst("LR-Org-ID");
}
```

An LR token has no Habu org claim, so the filter reads the org from the **same header the route
predicate keys on**.

---

## Two ordering fragilities

### 1. The V1 pair has no explicit order

```java
// externalApiLRRoutesV2 — :249
.order(-1)          // explicit, wins over externalApiServiceRoutesV2

// externalApiLRRoutes — :173
// (no .order() call)   both /v1 routes are order 0
```

The comment at `:170-171` claims *"This route has higher priority (lower order) than
externalApiServiceRoutes"*, but nothing enforces it. Both are order `0`, so which one wins
depends on the order the `RouteLocator` beans are collected and stable-sorted — the same
fragility as the filter ordering in [`03`](03-filter-ordering-defect.md).

If `externalApiServiceRoutes` ever sorted first, **every LiveRamp request would bypass
identity-bridge** and hit external-api-server with an LR token it cannot validate.

**Fix:** add `.order(-1)` to `externalApiLRRoutes` for parity with the V2 pair.

### 2. The percent-encoding workaround is only on the LR routes

`rewritePathPreservingEncoding` (`:202-235`) exists because Spring Cloud Gateway's built-in
`rewritePath` double-encodes percent-encoded query parameters
([spring-cloud-gateway#2065](https://github.com/spring-cloud/spring-cloud-gateway/issues/2065)) —
e.g. `%5B` for `[`, `%5D` for `]`.

It is applied to `externalApiLRRoutes` (`:184`) and `externalApiLRRoutesV2` (`:256`) but **not**
to the non-LR routes, which still use `f.rewritePath(...)` via the shared helper. Since the
non-LR rewrite is a no-op (`/v1/(?<path>.*)` → `/v1/${path}`), this may be harmless in
practice — but it is worth confirming that the built-in filter does not re-encode even on an
identity rewrite. If it does, direct Habu customers passing bracketed query params are
affected and LiveRamp callers are not.

---

## Dead code spotted

```java
// ApiGatewayConfig.java:28, 75, 77
private final RateLimiterConfig rateLimiterConfig;
public ApiGatewayConfig(RateLimiterService rateLimiterService,
                        RateLimiterConfig rateLimiterConfig, MetricsService metricsService) {
    this.rateLimiterConfig = rateLimiterConfig;
```

`rateLimiterConfig` is assigned and **never read**. Same for `rateLimiterService` and
`metricsService` — grep shows no other use in the class. All three constructor dependencies can
be dropped, which would also shrink the dependency graph that forced the `@Lazy` workaround.
