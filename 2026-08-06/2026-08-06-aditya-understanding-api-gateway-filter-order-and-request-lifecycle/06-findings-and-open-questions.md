# 06 — Findings, ranked

All findings below were verified against source in
`deklareddotcom/api-gateway` @ branch `OC-76440/relanding-spring-boot-3-upgrade`
(commit `39ae277`), and against decompiled/source jars of
`spring-cloud-gateway-server-4.3.5`.

---

## F1 — `spring.redis.*` is the Spring Boot 2 prefix, on a Boot 3.5 app ⚠️ **highest severity**

```yaml
# application.yml:36-39
spring:
  redis:                        # <-- Boot 2 prefix
    host: ${REDIS_HOST:localhost}
    port: ${REDIS_PORT:6379}
```

- `pom.xml:15` → `<springboot.version>3.5.15</springboot.version>`
- `spring.redis.*` was deprecated in Boot 2.6 and **removed in Boot 3.0**; `RedisProperties`
  now binds `spring.data.redis.*`.
- No `spring-boot-properties-migrator` dependency is present, so there is **no warning** at
  startup.
- No other Redis configuration exists anywhere in `src/main/resources` (verified by grep), and
  no `RedisConnectionFactory` bean is declared in code.

**As written, these two lines bind to nothing.** `REDIS_HOST` / `REDIS_PORT` are resolved into a
key nothing reads, and Lettuce falls back to its own defaults of `localhost:6379`.

### ✅ CONFIRMED — the deployment chart does not save it

Two independent checks close this out:

**1. The Boot 3.5 property prefix, from the jar itself.**

```
$ javap -v RedisProperties.class   # spring-boot-autoconfigure-3.5.14
org.springframework.boot.context.properties.ConfigurationProperties(
    value="spring.data.redis"
)
```

**2. The Helm chart sets only the old-style env vars.**

```yaml
# dyogram/charts/api-gateway/templates/deployment.yaml:43-46
- name: REDIS_HOST
  value: "{{ .Values.redis.host }}"      # -> "api-gateway-redis-ha-haproxy"
- name: REDIS_PORT
  value: "{{ .Values.redis.port }}"      # -> "6379"
```

**`SPRING_DATA_REDIS_HOST` is set nowhere.** `REDIS_HOST` feeds only the dead `spring.redis.host`
key. There is no other Redis configuration in `src/main/resources` and no
`RedisConnectionFactory` bean in code (both verified by grep).

**Therefore, on this branch, in production: Lettuce connects to `localhost:6379`, which does not
exist in the pod.** Every Redis call fails, and because of the double fail-open documented in
[`04`](04-redisratelimiter-internals.md) — `RedisRateLimiter` returns `allowed=true` on any
error — **rate limiting silently stops working entirely** while health checks stay green.

The chart also sets `APIGATEWAY_REDIS_READERS` / `_WRITERS` (`deployment.yaml:47-48`), which the
application does not read at all — no `@ConfigurationProperties` or `@Value` references them.
Leftovers from an earlier configuration scheme.

**Severity: P0 for the Spring Boot 3 relanding.** This is a silent, complete loss of rate
limiting with no error surfaced to operators.

**Fix:**

```yaml
spring:
  data:
    redis:
      host: ${REDIS_HOST:localhost}
      port: ${REDIS_PORT:6379}
```

Given the current branch is the Spring Boot 3 relanding, this is exactly the class of
regression that upgrade should catch.

---

## F2 — Filter ordering is accidental, not enforced

`getOrder()` on `QuotaRateLimitFilter` (`-2`) and `PathRateLimitFilter` (`-1`) is **never called
by the framework**. Neither class implements `org.springframework.core.Ordered`, so
`GatewayFilterSpec.filter()` wraps both as `OrderedGatewayFilter(filter, 0)`. Quota runs first
only because it is added one line earlier and TimSort is stable.

Full analysis and the recommended fix: [`03-filter-ordering-defect.md`](03-filter-ordering-defect.md).

**This corrects the "Order −2 (first) / −1 (second)" claim in the
[2026-08-04 rate-limit document](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md).**
Behaviour is right; the stated mechanism is not.

---

## F3 — The `/v1` LR route relies on the same accidental ordering

`externalApiLRRoutes` (`:169`) carries a comment claiming higher priority than
`externalApiServiceRoutes` (`:238`), but neither sets `.order()`. Only the V2 pair does
(`:249`). If the sort ever placed the non-LR route first, every LiveRamp request would bypass
identity-bridge carrying a token external-api-server cannot validate.

**Fix:** `.order(-1)` on `externalApiLRRoutes`, matching V2.

---

## F4 — Blocking Redis I/O on the Netty event loop

`RedisRateLimitConfigRepository` uses the **blocking** `StringRedisTemplate`, and it is called
from inside `PathRateLimitFilter.filter()` / `QuotaRateLimitFilter.filter()` — i.e. on a Netty
event-loop thread, on every request. Additionally:

- `createPathRateLimiter` Step 2 (`RateLimiterConfig:190`) issues a Redis **`SCAN`** over
  `rate-limit:PATH:REGEX*` whenever the exact-match lookup misses.
- A fresh `RedisRateLimiter` object is allocated per request.

**Fix direction:** cache resolved configs in memory with invalidation on the
`RateLimiterController` write path (the class is already `@RefreshScope`), or move to
`ReactiveStringRedisTemplate` throughout.

---

## F5 — Quota fails open, path fails to a hard-coded default

| | no matching config |
|---|---|
| Quota | `null` → request passes through **unlimited** (`RateLimiterConfig:130`) |
| Path | `null` → substituted with `buildLimiter(50, 50)` (`RateLimiterConfig:145`) |

Two different philosophies in adjacent code paths. Neither is documented as a decision. The
`50/50` in particular is a magic number with no configuration surface.

---

## F6 — The gateway is not an auth boundary

There is **no `SecurityWebFilterChain`** in this service. `JwtDecoder.decodeWithoutValidation`
(`security/JwtDecoder.java:25`) is exactly what it says — the signature is never verified. The
gateway reads the org claim purely to key the rate-limit buckets.

This is architecturally fine (downstream services validate), but it contradicts the platform
`CLAUDE.md`, which states the gateway "handles rate-limiting … and JWT validation". **The
documentation is wrong, not the code** — worth correcting so nobody builds on the false
assumption.

Practical consequence: a caller can forge an `Authorization` header with an arbitrary org claim
and choose which rate-limit bucket to consume — including someone else's. Rate limiting is
attributable but not trustworthy.

---

## F7 — Path buckets key on the raw URI path

`isAllowed("api_path_method_organization", path + ":" + method + ":" + orgId)`
(`PathRateLimitFilter:89`) uses the **raw** path. `/v1/cleanroom/{id}` with N distinct ids
yields N independent full buckets. Per-path limits therefore do not constrain
ID-enumerating clients; **org quota is the only real control**.

Consistent with the 2026-08-03 finding that the `rate_limit_exceeded` counter was tagged with
the raw path (unbounded metric cardinality) — same root cause, different symptom.

---

## F8 — No blacklisting endpoint exists

Grepped for `blacklist`, `blocklist`, `denylist`, `banned`, `blocked` across all Java and YAML:
**nothing**. There is exactly one controller in the service, `RateLimiterController`
@ `/internal/apigateway/rate-limit`:

| Method | Path |
|---|---|
| POST | `/configs` — upsert |
| GET | `/configs` — list all |
| POST | `/config/get` |
| POST | `/config/delete` |
| POST | `/config/delete-bulk` |

The nearest available action is **throttling to near-zero**: a QUOTA config with
`replenishRate: 1, burstCapacity: 1`. That yields 429 on almost everything but still lets one
request per second through.

Note the semantics cut against a hard block: when no config matches, the filters **pass the
request through**. The system is fail-open — deleting a config removes a limit, it never
creates one. A real blacklist needs a new filter that fails **closed**, because nothing in the
current design can express "deny".

---

## F9 — Dead code

- `ApiGatewayConfig` constructor takes `RateLimiterService`, `RateLimiterConfig` and
  `MetricsService` (`:75`). All three are assigned to fields (`:76-78`) and **never read** —
  verified by grep. Removing them also shrinks the dependency graph that motivated the `@Lazy`
  workaround at `:67-73`.
- `RedisRateLimitConfigRepository.findByStrategyAndType` is `@Deprecated` (`:48`) and contains a
  clear bug at `:55`: `redisTemplate.opsForHash().get("key", "key")` reads from a literal
  Redis key `"key"` instead of `redisKey`. Still reachable via
  `RateLimiterService.getRateLimitConfig`, which `RateLimiterConfig.createRedisRateLimiter(strategy, type)`
  calls from `globalRateLimiter()` (`:76`).

---

## Open questions

1. ~~Does the deployment chart set `SPRING_DATA_REDIS_HOST`?~~ **ANSWERED: no.** F1 is a live
   production outage of rate limiting on this branch. See F1.
2. Is `globalRateLimiter()` (`RateLimiterConfig:74`) used at all? It is `@Primary` +
   `@Scope("prototype")` but no injection point for a bare `RedisRateLimiter` was found. If
   unused, it and the deprecated repository method can both go.
3. Was quota-before-path an intentional decision or an accident that happened to be right?
   The comment at `ApiGatewayConfig:88-90` reads as intentional; the mechanism says otherwise.
4. Is the non-LR `rewritePath` genuinely safe for percent-encoded query params, or does
   spring-cloud-gateway#2065 bite on an identity rewrite too?
5. Should `/internal/**` really be entirely exempt from rate limiting? A compromised internal
   service has no ceiling.
6. **Is `external-api-server`'s `/internal/*` ALB actually restricted to the gateway's security
   group in production?** The chart default is `internet-facing` with a placeholder security
   group, and `InternalAuthFilter` grants **every scope** on the strength of spoofable
   `X-Internal-*` headers. See [`07`](07-external-api-server-filters-and-network-topology.md).

## Next steps

1. **P0 — fix F1.** Re-indent to `spring.data.redis.*` (or add `SPRING_DATA_REDIS_HOST` to the
   chart). Confirmed broken; nothing else is more urgent on this branch.
2. F2 + F3 as one small PR: explicit `.filter(f, 0)` / `.filter(f, 1)` and `.order(-1)`, plus a
   test asserting chain order.
3. Correct the `CLAUDE.md` claim about gateway JWT validation (F6).
4. F9 dead-code removal as a follow-up cleanup.
5. F4 (caching) sized separately — it is a design change, not a fix.
