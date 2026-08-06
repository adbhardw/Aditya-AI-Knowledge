# 07 — external-api-server filters, and what actually forces traffic through the gateway

## Part 1 — Does external-api-server use filters the same way?

Yes, conceptually — but on a **completely different stack**, and its ordering is real where the
gateway's is not.

| | `api-gateway` | `external-api-server` |
|---|---|---|
| Spring Boot | **3.5.15** (`pom.xml:15`) | **2.7.18** (`pom.xml:7`) |
| Stack | WebFlux, **reactive** | Web MVC, **servlet** |
| Server | Netty | **Jetty** (Tomcat excluded, `pom.xml:71-77`) |
| Filter base | `GatewayFilter` / `WebFilter` | **`OncePerRequestFilter`** |
| Servlet API | n/a | **`javax.servlet`** (pre-Jakarta) |
| Signature | `Mono<Void> filter(ServerWebExchange, GatewayFilterChain)` | `void doFilterInternal(HttpServletRequest, HttpServletResponse, FilterChain)` |
| Ordering | ⚠️ **broken** — see [`03`](03-filter-ordering-defect.md) | ✅ **works** — via `@Order` |
| Auth | none — `decodeWithoutValidation` | **full Spring Security** `SecurityFilterChain` |

### The filters

| Filter | Order | Purpose |
|---|---|---|
| `RequestIdFilter` | `@Order(Ordered.HIGHEST_PRECEDENCE)` | correlation id (mirrors the gateway's `RequestIdPreFilter`) |
| `InternalAuthFilter` | `@Order(Ordered.HIGHEST_PRECEDENCE)` | auth for `/internal/**` traffic from identity-bridge |
| `FilterChainExceptionHandler` | `@Order(Ordered.HIGHEST_PRECEDENCE + 1)` | turns filter-chain exceptions into REST errors |
| `InternalJwtTokenFilter` | *(no `@Order`)* | propagates the Moonraker JWT for downstream gRPC |

### The key contrast: three ways to be ordered, not two

Earlier we established that a method merely *named* `getOrder()` is invisible to Spring — you
need the `Ordered` **interface**. `InternalAuthFilter` shows the **third** mechanism:

```java
// InternalAuthFilter.java:40
@Order(Ordered.HIGHEST_PRECEDENCE)
public class InternalAuthFilter extends OncePerRequestFilter {
```

Note that `org.springframework.core.Ordered` is imported here only to supply the **constant**
`Ordered.HIGHEST_PRECEDENCE` (= `Integer.MIN_VALUE`). The class does *not* implement the
interface. The ordering works because of the **`@Order` annotation**.

This is precisely why the comparator is called `AnnotationAwareOrderComparator` — it reads
**both**:

1. the `Ordered` **interface** (`((Ordered) o).getOrder()`), and
2. the `@Order` / `@Priority` **annotation** (`AnnotationUtils.findAnnotation(...)`).

Extending the plug/socket analogy: `implements Ordered` is wiring the plug; `@Order` is a
labelled adapter the socket also knows how to read. The gateway's rate-limit filters have
**neither** — just a method with a suggestive name.

```
implements Ordered   -> framework reads it   ✅  (RequestIdPreFilter, api-gateway)
@Order(n) annotation -> framework reads it   ✅  (InternalAuthFilter, external-api-server)
public int getOrder()-> framework ignores it ❌  (QuotaRateLimitFilter, PathRateLimitFilter)
```

### A familiar smell, though

`RequestIdFilter` and `InternalAuthFilter` **both** sit at `Ordered.HIGHEST_PRECEDENCE` — an
exact tie. As in the gateway, the tiebreak falls to stable-sort insertion order (here, bean
registration order). It matters less because their concerns barely overlap, but if
`InternalAuthFilter` ever wins, its `forward()` on `:109` re-enters the chain and
`RequestIdFilter` — a `OncePerRequestFilter` — will **not** run again on the forwarded request.
Worth an explicit `+1`.

### What `InternalAuthFilter` actually does

It is the **receiving end** of the `/internal` path the gateway forwards to. Steps, from the
class doc at `:30-37`:

1. Requires `X-Internal-User-Email` / `-User-Id` / `-Org-Id` headers + a Bearer token; **401**
   if absent (`:58-68`).
2. Mints a **mock `Jwt`** with Auth0-shaped base64 claims (`createMockJwt`, `:123`) and installs
   it in the `SecurityContext` — `alg: none`, `iss: identity-bridge` (`:130-134`).
3. Stashes the Moonraker token in `InternalJwtContext` for downstream gRPC (`:91`).
4. Sets MDC `organizationID` / `userEmail` — the same MDC-to-JSON promotion noted in the
   2026-08-03 telemetry work.
5. `forward()`s `/internal/v1/**` → `/v1/**` so the normal controllers handle it (`:108-109`),
   deliberately instead of a path rewrite, to stop Spring Security re-evaluating the path.

**Security note.** `SecurityConfiguration:81-82` marks `/internal/**` `permitAll()`, and this
filter then **grants every scope in existence** (`Constants.ALL_SCOPES` +
`ALL_USER_PERMISSIONS`, `:75-77`). The entire trust model rests on the three
`X-Internal-*` headers being un-spoofable — which is a **network** assumption, not an
application one. See Part 2.

---

## Part 2 — Why does `/internal/forebitt` go to api-gateway and not straight to forebitt?

**Short answer: nothing in the application code forces it. It is network topology — and the
Helm chart defaults do not enforce it either.**

### The two paths are different URLs

| | Through the gateway | Direct to forebitt |
|---|---|---|
| URL | `https://<gateway-host>/internal/forebitt/jobs/1` | `https://<forebitt-host>/forebitt/jobs/1` |
| Ingress | `charts/api-gateway/templates/ingress.yaml` → `/internal/*` | `charts/forebitt/templates/ingress.yaml` → `/forebitt/*` |
| Rate limited | ❌ no — `/internal` is exempt (`ApiGatewayConfig:87`) | ❌ no |
| Rewrite | `/internal/forebitt/(?<path>.*)` → `/forebitt/${path}` | n/a |

The gateway's rewrite (`ApiGatewayConfig:104-105`) turns `/internal/forebitt/x` into
`/forebitt/x` — **exactly the path forebitt's own ingress serves.** The two routes converge on
the same backend.

### What the charts actually say

```yaml
# charts/api-gateway/values.yaml:115-119        # charts/forebitt/values.yaml:240-244
ingress:                                        ingress:
  enabled: true                                   enabled: true
  annotations:                                    annotations:
    kubernetes.io/ingress.class: alb                kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme:               alb.ingress.kubernetes.io/scheme:
      internet-facing                                 internet-facing        # <-- same
    alb.../security-groups:                         alb.../security-groups:
      ADD YOUR SECURITY GROUP HERE!                   ADD YOUR SECURITY GROUP HERE!
```

**Both are `internet-facing` ALBs by default.** forebitt is not a `ClusterIP`-only service
hidden inside the cluster — it gets its own AWS Application Load Balancer.

So what stops a direct call?

1. **The ALB security group** — the `ADD YOUR SECURITY GROUP HERE!` placeholder is supplied per
   environment in an `overrides.yaml` that is **not in this repository**. This is the real
   control, and it is invisible from the code.
2. **DNS / hostname knowledge** — `.Values.ingress.host` is `required` and set per environment.
   Clients only know the gateway's hostname. Security by obscurity, not a control.
3. **Per-service JWT validation** — every Go control-plane service validates the asymmetric JWT
   itself. Bypassing the gateway does **not** bypass authentication.

### What bypassing *would* cost you

Since `/internal/**` is already exempt from rate limiting, going direct does not evade the
limiter — there is nothing to evade on that path. What it does evade:

- the gateway's `X-Request-Id` stamping, so the call is uncorrelated in logs;
- any future gateway-level policy;
- for **external-api-server** specifically, it would let a caller supply their own
  `X-Internal-User-Email` / `-Org-Id` headers and, via `InternalAuthFilter`, be granted
  **every scope in the system** against **any organisation**. That path is `permitAll()` at
  `SecurityConfiguration:81-82`.

That last one is the reason this question matters. The `/internal` trust boundary is enforced
**only** at the ALB security group layer.

### Open question

**Is `external-api-server`'s ingress (and forebitt's) actually restricted to the VPC/gateway
security group in production?** The chart defaults say `internet-facing` with a placeholder
security group. This cannot be answered from this repo — it needs the environment's
`overrides.yaml`. If any `/internal/*` ALB is reachable from the internet, the header-trust
model in `InternalAuthFilter` is an authentication bypass.

*Flagged as a question, not an assertion — the overrides were not available for inspection.*
