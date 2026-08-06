# SUMMARY — api-gateway: startup, request lifecycle, and why the rate-limit filter order is accidental

**Date:** 2026-08-06
**Repository:** `deklareddotcom/api-gateway` @ `OC-76440/relanding-spring-boot-3-upgrade` (commit `39ae277`)
**Session type:** Source trace + framework-internals verification (decompiled Spring Cloud Gateway 4.3.5)
**Related:** [2026-08-04 rate-limit habu-all](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md) — **this session corrects one claim there** · [2026-08-03 telemetry inventory](../../2026-08-03/2026-08-03-aditya-grafana-dashboard-prompts-and-telemetry-inventory/SUMMARY.md)

---

## 1. Problem statement

A walkthrough of `api-gateway`'s rate limiting that started as "who calls what" and turned into
a framework-internals audit. Six questions drove it:

1. Is `RateLimiterConfig` the entry point, and why does a `@Configuration` class call a service?
2. Who calls `new RedisRateLimitConfigRepository(StringRedisTemplate)` — and where does
   `StringRedisTemplate` come from?
3. Trace `GET /v1/cleanroom` end to end. How does `QuotaRateLimitFilter` come first?
4. What happens from `main()`? (Spring Boot from first principles.)
5. `isAllowed()` is a Spring class — how does it actually work?
6. Is there a blacklisting endpoint?

Answering (3) properly required decompiling the gateway jar, and that is where the main finding
came from.

---

## 2. First principles: two flows, not one

The single biggest source of confusion is that **two independent flows both end at Redis**.

```
WRITE (admin CRUD, rare)
  RateLimiterController  ->  RateLimitConfigManager  ->  RateLimiterService
      ->  RedisRateLimitConfigRepository  ->  Redis

READ (enforcement, every request)
  PathRateLimitFilter / QuotaRateLimitFilter        <- THE real entry point
      ->  RateLimiterConfig  (a factory, despite the name and package)
          ->  RateLimiterService  ->  repository  ->  Redis
      ->  RedisRateLimiter.isAllowed(...)           <- the token-bucket check
```

`RateLimiterConfig` is **not** an entry point. It is a per-request factory that reads the
current limits out of Redis and constructs a `RedisRateLimiter` sized to them. It calls the
service because the limits are operator-editable at runtime — you cannot build a limiter without
first knowing the numbers.

**Naming collision worth internalising:** `config/RateLimiterConfig` = Spring *wiring* config
(a `@Configuration` with `@Bean` methods). `models/RateLimitConfig` = rate-limit *settings data*
(a `@Data` POJO, JSON-bound, validated, stored in Redis). Both packages are correct; the names
differ by three characters and mean unrelated things.

---

## 3. Startup vs. request time — the mental model

The numbered request steps are **not** invoked by `main()`.

| | Phase A (startup, once) | Phase B (per request) |
|---|---|---|
| Triggered by | `SpringApplication.run` (`ApiGatewayApplication.java:17`) | a TCP connection |
| Thread | main | Netty event loop |
| Produces | beans, routes, a bound port `:8443` | an HTTP response |
| `@Configuration` code | **runs here** | never runs again |
| `@Component` filter code | constructed here | **`filter()` runs here** |

Phase A in six steps: decide app type (webflux → reactive context) → component-scan
`com.habu.apigateway` → evaluate auto-configuration from every jar → build the bean graph →
invoke every `@Bean` method (this is what "calls" `ApiGatewayConfig` — nobody else does) →
start Netty.

**Where `StringRedisTemplate` comes from:** nothing in the repo declares it.
`RedisAutoConfiguration` creates it because `spring-boot-starter-data-redis` is on the classpath
(`pom.xml:128`). `RedisRateLimitConfigRepository` has one constructor, so Spring uses implicit
constructor injection. There is no `new RedisRateLimitConfigRepository(...)` anywhere in the
codebase, tests included.

Detail: [`01-startup-what-main-does.md`](01-startup-what-main-does.md)

---

## 4. End-to-end runtime flow — `GET /v1/cleanroom`

```
① Netty :8443 (TLS terminated)
② WebFilter chain — RequestIdPreFilter adds X-Request-Id.  NO SecurityWebFilterChain exists.
③ DispatcherHandler -> RoutePredicateHandlerMapping
④ Route match: external_api_lr_routes needs LR-Org-ID (absent) -> external_api_service_routes
⑤ FilteringWebHandler: globalFilters + route filters, AnnotationAwareOrderComparator.sort
⑥ QuotaRateLimitFilter -> HGET rate-limit:QUOTA:ORGANIZATION:ORG_<org>, then ORG_ALL, else pass
⑦ PathRateLimitFilter  -> exact API key, then org REGEX, then ALL REGEX, else 50/50 default
⑧ rewritePath (a no-op for this route)
⑨ NettyRoutingFilter -> external-api-server
```

Detail with the sequence diagram, exact Redis keys and line numbers:
[`02-request-lifecycle-v1-cleanroom.md`](02-request-lifecycle-v1-cleanroom.md)

**`isAllowed` internals** — `RedisRateLimiter` gets its `ReactiveStringRedisTemplate` and Lua
`RedisScript` in `setApplicationContext`, which is why `RateLimiterConfig.buildLimiter` exists
(these limiters are `new`'d at request time, so Spring's post-processor never runs on them). The
`routeId` argument is *not* a config lookup here — `defaultConfig` was baked in by the
constructor — it only namespaces the Redis key:
`request_rate_limiter.{<routeId>.<id>}.tokens`. The algorithm is a lazily-refilled token bucket
in an atomic Lua script; **on any Redis error it returns allowed=true**.
Detail: [`04-redisratelimiter-internals.md`](04-redisratelimiter-internals.md)

---

## 5. The main finding: `getOrder()` is dead code

**Claim under test:** `QuotaRateLimitFilter.getOrder() == -2` and
`PathRateLimitFilter.getOrder() == -1`, therefore quota runs first.

**Verified reality:** the framework never calls those methods.

`RateLimitFilter extends GatewayFilter` (`RateLimitFilter.java:8`) and declares its own
`int getOrder()`. But `GatewayFilter` does **not** extend `org.springframework.core.Ordered`,
and neither does `RateLimitFilter`. Java is nominally typed — having a method named
`getOrder()` does not make you an `Ordered`. Decompiled `GatewayFilterSpec.filter(GatewayFilter)`:

```
1: instanceof org/springframework/core/Ordered
4: ifeq 18                 <-- not Ordered -> jump
20: iconst_0               <-- literal 0
21: invokevirtual filter:(GatewayFilter;I)   -> OrderedGatewayFilter(filter, 0)
```

**Both filters get order `0`.** `FilteringWebHandler` then calls
`AnnotationAwareOrderComparator.sort`, which is TimSort — **stable** — so equal orders keep
insertion order. Quota runs first *because `ApiGatewayConfig:91` precedes `:92`*. Nothing else.

Compare `RequestIdPreFilter.java:20`, which does `implements WebFilter, Ordered` and is
genuinely ordered.

**Why it matters:** swapping two adjacent lines silently inverts the security semantics; the
pattern is duplicated in three places (`:91-92`, `:179-180`, `:254-255`); and a comment at
`:88-90` asserts a guarantee the code does not provide.

**This corrects the 2026-08-04 document**, which records the orders as −2/−1 taking effect.
Behaviour right, mechanism wrong.

Detail incl. both fix options and their trade-off:
[`03-filter-ordering-defect.md`](03-filter-ordering-defect.md)

---

## 6. Design options considered (for the ordering fix)

| Option | Mechanism | Trade-off |
|---|---|---|
| **A** `RateLimitFilter extends GatewayFilter, Ordered` | `instanceof` becomes true; −2/−1 honoured | ⚠️ also moves the filters **relative to SCG global filters** — `NettyWriteResponseFilter` sits at `-1`, `ForwardPathFilter` at `0`. Unrequested behavioural change. |
| **B (recommended)** `f.filter(quota, 0); f.filter(path, 1);` | non-`Ordered` filters get `OrderedGatewayFilter(filter, order)` | Quota keeps its current absolute position (`0`), path becomes strictly later, ordering is framework-enforced. No interleaving surprises. |

The two do not compose: `filter(GatewayFilter, int)` **ignores** the explicit order for an
`Ordered` filter and logs a warning.

**Recommendation: Option B**, plus delete the misleading `getOrder()` from `RateLimitFilter`
(or make it real), plus a test asserting chain order.

---

## 7. Findings, ranked

| # | Finding | Severity |
|---|---|---|
| **F1** | ✅ **CONFIRMED.** `application.yml:36-39` uses **`spring.redis.*`** — the Boot 2 prefix, removed in Boot 3.0 — on a **Boot 3.5.15** app, no properties-migrator. Verified from the jar that Boot 3.5 binds `spring.data.redis`; verified from `dyogram/charts/api-gateway/templates/deployment.yaml:43-46` that the chart sets only `REDIS_HOST`/`REDIS_PORT` and **never** `SPRING_DATA_REDIS_HOST`. In production Lettuce therefore dials `localhost:6379`, every call fails, and the double fail-open means **rate limiting silently stops working** with health checks green. | 🔴 **P0** |
| **F2** | Filter ordering accidental (§5). | high |
| **F3** | `/v1` LR route relies on the same accidental ordering — no `.order()`, unlike the V2 pair (`:249`). If it lost, every LiveRamp request would bypass identity-bridge. | high |
| **F4** | **Blocking** `StringRedisTemplate` reads on the Netty event loop, every request, plus a Redis `SCAN` on exact-match miss and a fresh limiter object per request. | medium |
| **F5** | Quota fails **open** (unlimited); path falls back to a hard-coded **50/50**. Two philosophies, neither documented. | medium |
| **F6** | **No `SecurityWebFilterChain`.** `JwtDecoder.decodeWithoutValidation` never checks the signature. Contradicts platform `CLAUDE.md`. A caller can forge an org claim and choose whose bucket to drain. | medium |
| **F7** | Path buckets key on the **raw URI path** — N distinct ids ⇒ N full buckets. Org quota is the only real control against enumeration. | medium |
| **F8** | **No blacklisting endpoint exists.** One controller, five CRUD methods. Nearest action is throttling to 1/1. The design is fail-open and cannot express "deny". | informational |
| **F9** | Dead code: `ApiGatewayConfig`'s three constructor deps are assigned and never read (`:75-78`). `findByStrategyAndType` is `@Deprecated` and reads a literal Redis key `"key"` at `:55`. | low |

Detail: [`06-findings-and-open-questions.md`](06-findings-and-open-questions.md)

---

## 8. Route naming: what `lr` means

Habu was acquired by LiveRamp, so `/v1` serves two caller classes.

- **`external_api_lr_routes`** — `/v1/**` **AND** header `LR-Org-ID` → **identity-bridge**, which
  exchanges the LiveRamp token for a Habu one. Rewrites to
  `/api/v1/lr-habu/external-api-server/v1/…`.
- **`external_api_service_routes`** — `/v1/**` → **external-api-server** directly (no-op rewrite).

`lr` = *LiveRamp-authenticated traffic needing token exchange*; `service` = *the plain path to
the backing service*. This also explains `QuotaRateLimitFilter:99-102`: an LR token carries no
Habu org claim, so the filter falls back to the same `LR-Org-ID` header the route predicate
keys on.

Also: `/internal/**` is **entirely exempt** from rate limiting (`ApiGatewayConfig:87`), so only
`/v1` and `/v2` are metered.

Detail: [`05-routes-and-lr-token-exchange.md`](05-routes-and-lr-token-exchange.md)

---

## 8b. Cross-service: how `external-api-server` differs, and the `/internal` trust boundary

**Different stack entirely.** `external-api-server` is Spring Boot **2.7.18**, servlet (Jetty,
Tomcat excluded), `javax.servlet`, `OncePerRequestFilter`, with a full Spring Security
`SecurityFilterChain`. The gateway is Boot 3.5.15, reactive, Netty, and has no security chain at
all.

**Its ordering works — via the third mechanism.** `InternalAuthFilter.java:40` uses
`@Order(Ordered.HIGHEST_PRECEDENCE)` — the **annotation**, not the interface (it imports
`Ordered` only for the constant). This is why the comparator is called
*Annotation*AwareOrderComparator: it reads the `Ordered` interface **and** the `@Order`
annotation. The gateway's rate-limit filters have neither.

```
implements Ordered    -> framework reads it   OK   (RequestIdPreFilter, api-gateway)
@Order(n) annotation  -> framework reads it   OK   (InternalAuthFilter, external-api-server)
public int getOrder() -> framework ignores it FAIL (Quota/PathRateLimitFilter)
```

Same smell recurs though: `RequestIdFilter` and `InternalAuthFilter` are at an exact
`HIGHEST_PRECEDENCE` tie.

**What forces traffic through the gateway? Nothing in application code.** The gateway rewrites
`/internal/forebitt/x` → `/forebitt/x`, and forebitt's own chart serves `/forebitt/*` on its own
ALB — the two converge on the same backend. Both charts default to
`alb.ingress.kubernetes.io/scheme: internet-facing` with `ADD YOUR SECURITY GROUP HERE!` as a
placeholder. The real control is that per-environment security group, which is **not in these
repositories**.

This matters because `InternalAuthFilter` grants **every scope in the system**
(`ALL_SCOPES` + `ALL_USER_PERMISSIONS`, `:75-77`) on the strength of three `X-Internal-*`
headers, on a path `SecurityConfiguration:81-82` marks `permitAll()`. The `/internal` trust
boundary is therefore enforced **only** at the ALB security-group layer. Whether it holds is an
open question, flagged not asserted.

Detail: [`07-external-api-server-filters-and-network-topology.md`](07-external-api-server-filters-and-network-topology.md)

---

## 9. Key files and line numbers

| Concern | Location |
|---|---|
| Entry point | `config/ApiGatewayApplication.java:16-18` |
| Routes + filter wiring | `config/ApiGatewayConfig.java:82-100`, `:91-92`, `:169`, `:238`, `:249` |
| Limiter factory | `config/RateLimiterConfig.java:55` `buildLimiter`, `:98` quota resolution, `:177` path resolution |
| Filters | `http/filters/ratelimiter/QuotaRateLimitFilter.java:32`, `PathRateLimitFilter.java:37` |
| The dead `getOrder()` | `http/filters/ratelimiter/RateLimitFilter.java:12` |
| Redis key shapes | `repository/RedisRateLimitConfigRepository.java:361` `buildRedisKey` |
| Admin API | `controller/RateLimiterController.java:28` |
| Redis property bug | `src/main/resources/application.yml:36-39` |
| Boot version | `pom.xml:15` (gateway 3.5.15) · external-api-server `pom.xml:7` (2.7.18) |
| Chart env vars | `dyogram/charts/api-gateway/templates/deployment.yaml:43-48` |
| Internal auth | `external-api-server` `http/filters/InternalAuthFilter.java:40,75-77,108-109` |

---

## 10. Open questions

1. ~~Does the deployment chart set `SPRING_DATA_REDIS_HOST`?~~ **ANSWERED: no.** Confirmed a live
   outage of rate limiting on this branch — see F1.
2. **Is the `/internal/*` ALB actually restricted to the gateway's security group in
   production?** The charts default to `internet-facing` with a placeholder security group. If
   it is not restricted, `InternalAuthFilter`'s header trust is an authentication bypass.
   *Not answerable from these repos — needs the environment overrides.*
3. Is `globalRateLimiter()` (`RateLimiterConfig:74`) used anywhere? No injection point for a
   bare `RedisRateLimiter` was found.
4. Was quota-before-path intentional, or accidentally correct?
5. Does spring-cloud-gateway#2065 (double-encoding) bite on the non-LR *identity* rewrite too?
6. Should `/internal/**` really be wholly exempt from rate limiting?

## 11. Next steps

1. **P0 — fix F1 now.** Re-indent `application.yml` to `spring.data.redis.*` (or add
   `SPRING_DATA_REDIS_HOST` to the chart). Confirmed broken; nothing on this branch is more
   urgent.
2. One small PR for F2 + F3: explicit filter orders, `.order(-1)` on `externalApiLRRoutes`, and
   a chain-order test.
3. Correct the `CLAUDE.md` claim that the gateway validates JWTs (F6).
4. Dead-code cleanup (F9).
5. Size F4 (config caching) separately — design change, not a fix.
