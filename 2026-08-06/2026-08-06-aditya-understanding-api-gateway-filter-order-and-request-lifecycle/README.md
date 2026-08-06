# api-gateway — startup, request lifecycle, and rate-limit filter ordering

**Date:** 2026-08-06
**Repository analysed:** `deklareddotcom/api-gateway` @ `OC-76440/relanding-spring-boot-3-upgrade` (commit `39ae277`)
**Framework internals verified against:** `spring-cloud-gateway-server-4.3.5` (decompiled + sources jar)

> **Start with [`SUMMARY.md`](SUMMARY.md).** It is self-contained — an AI assistant or a new
> engineer should read it first and only open the numbered documents below for line-level
> evidence.

---

## Contents

| File | What it covers |
|---|---|
| [`SUMMARY.md`](SUMMARY.md) | **Entry point.** Problem, two-flow model, startup vs. request time, the ordering finding, all 9 findings ranked, open questions, next steps. |
| [`01-startup-what-main-does.md`](01-startup-what-main-does.md) | Spring Boot from first principles for a newcomer: what `SpringApplication.run` actually does in six steps, component scan, auto-configuration, the bean graph, `@Lazy` and the circular dependency, and the Phase A / Phase B split that makes the rest make sense. |
| [`02-request-lifecycle-v1-cleanroom.md`](02-request-lifecycle-v1-cleanroom.md) | `GET /v1/cleanroom` traced end to end with a Mermaid sequence diagram — Netty → WebFilter → DispatcherHandler → route match → filter chain → downstream. Exact Redis keys at each step. |
| [`03-filter-ordering-defect.md`](03-filter-ordering-defect.md) | **The main finding.** Why `getOrder()` is never called, the decompiled bytecode proving it, why quota still runs first, and two fix options with their trade-off. |
| [`04-redisratelimiter-internals.md`](04-redisratelimiter-internals.md) | Inside Spring's `RedisRateLimiter.isAllowed()` — why `setApplicationContext` is load-bearing, what `routeId` really does, the token-bucket Lua script line by line, a worked refill example, and the double fail-open. |
| [`05-routes-and-lr-token-exchange.md`](05-routes-and-lr-token-exchange.md) | How the ~15 `RouteLocator` beans merge, the full route table, why `/internal/**` is exempt from rate limiting, and what `lr` means (LiveRamp token exchange via identity-bridge). |
| [`06-findings-and-open-questions.md`](06-findings-and-open-questions.md) | All 9 findings with evidence, severity, and fixes — including the **confirmed P0** `spring.redis.*` vs `spring.data.redis.*` Boot 3 regression. |
| [`07-external-api-server-filters-and-network-topology.md`](07-external-api-server-filters-and-network-topology.md) | How `external-api-server` does filters differently (servlet stack, Boot 2.7, `@Order` — the **third** ordering mechanism), and what actually forces traffic through the gateway: nothing in code, only ALB security groups the charts leave as a placeholder. |

---

## Headline findings

1. 🔴 **P0, CONFIRMED — rate limiting is silently dead on this branch.** `application.yml:36-39`
   uses `spring.redis.*`, the Boot 2 prefix **removed in Boot 3.0**, on a Boot 3.5.15 app with no
   properties-migrator. Verified from the jar that Boot 3.5 binds `spring.data.redis`, and from
   `dyogram/charts/api-gateway/templates/deployment.yaml:43-46` that the chart sets only
   `REDIS_HOST`/`REDIS_PORT` — **`SPRING_DATA_REDIS_HOST` is set nowhere.** Lettuce dials
   `localhost:6379`, every call fails, and the double fail-open means no limits are enforced
   while health checks stay green.
2. **`getOrder()` on the rate-limit filters is dead code.** Neither implements
   `org.springframework.core.Ordered`, so Spring Cloud Gateway assigns both order `0`. Quota
   runs before path only because it is added one line earlier and TimSort is stable. *This
   corrects a claim in the [2026-08-04 rate-limit document](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md).*
3. **The gateway does not validate JWTs.** No `SecurityWebFilterChain`;
   `JwtDecoder.decodeWithoutValidation` reads the org claim without checking the signature.
   The platform `CLAUDE.md` says otherwise and should be corrected.
4. **There is no blacklisting endpoint,** and the design is fail-open throughout — it cannot
   express "deny".
5. **The `/internal` trust boundary is network-only.** `external-api-server`'s
   `InternalAuthFilter` grants **every scope in the system** on the strength of three
   `X-Internal-*` headers, on a `permitAll()` path — and the Helm charts default *both* the
   gateway and the backing services to `internet-facing` ALBs with a placeholder security group.
   Whether that boundary holds cannot be answered from these repos.

## Related sessions

- [2026-08-04 — rate limiting: how it works and what prod actually does](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md) *(one claim corrected here)*
- [2026-08-03 — Grafana dashboard prompts and telemetry inventory](../../2026-08-03/2026-08-03-aditya-grafana-dashboard-prompts-and-telemetry-inventory/SUMMARY.md)
- [2026-08-02 — Loki / Grafana / Datadog abuse-monitoring discussion](../../2026-08-02/2026-08-02-aditya-loki-grafana-datadog-discussion/SUMMARY.md)
