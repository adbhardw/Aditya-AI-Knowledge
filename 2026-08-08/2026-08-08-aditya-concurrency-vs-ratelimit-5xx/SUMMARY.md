# SUMMARY — Concurrency vs rate limiting: why a rate-limited API still 5xx'd, and how to fix it

**Date:** 2026-08-08
**Session type:** Load-test post-mortem + observability change + first-principles walkthrough
**Repos touched:** `external-api-server` (PR #353), `api-gateway` (PR #95, prior)

---

## 1. Problem statement

While load-testing rate limiting on stage (org `c0699ec6-7cd9-4277-ac02-f4411cbc7f5b`), the API returned **5xx (30×502 + 10×500)** instead of clean `429`s — even though the org's quota burst was **5,082**. The question: why did a rate-limited API fall over at only ~150–200 requests, well under the quota, and where should it be fixed?

**Root cause in one line:** a per-second **rate** limit does not cap **concurrency**. Traffic stayed under the rate limit (~10/sec) but put ~150 slow requests *in flight at once*, which exhausted the backend's thread pool.

---

## 2. First principles

### Rate ≠ concurrency ≠ quota — three independent limits

| Limit | Unit | Analogy | Binding here? |
|---|---|---|---|
| **Quota** (`ALL ORGANIZATION 1/86400/17`) | requests **counted over time** (5,082 burst, ~5,082/day) | total customers served all day | No — never sent 5,082 |
| **Rate** (per-second token bucket) | arrivals **per second** | customers arriving per minute | No — ~10/sec, under any limit |
| **Concurrency** | requests **in flight at the same instant** | how many can *sit at once* | **YES — this is what broke** |

The quota was never the binding constraint. ~150 requests arrived **simultaneously**, each held for 5–17s by a slow backend, filling every table.

### Concurrent vs parallel

- **Concurrent** = multiple things in progress and overlapping in time (one cook juggling 5 dishes). What stresses a server: how many it must hold open *at once*.
- **Parallel** = literally executing at the same instant on separate resources (5 cooks).

The backend damage is driven by the **concurrent in-flight count**, not raw parallelism or total volume.

### Why slow requests are the multiplier

Every in-flight request holds a **thread + a connection + a downstream connection** for its **whole duration**. At 5–17s each, 150 simultaneous = 150 threads tied up for 15s. Tomcat is thread-per-request (~200 max), so it can't hold that many slow ones at once.

---

## 3. High-level architecture / where each 5xx originates

```
client → ALB (Application Load Balancer) → api-gateway → external-api-server → gRPC downstream (moonraker, ...)
           │                                   │                │
   (1) connection capacity         (2) forwards + WAITS   (3) Tomcat thread pool
       → refuses excess (000)          on slow backend        (~200 threads, 1/req)
                                        → 502 on timeout       → exhausted → 500 / no response
```

- `000` (connection refused) = the **ALB** shedding load before it reaches the gateway.
- `502` = the gateway/ALB couldn't get a good response from a slow/overwhelmed backend.
- `500` = external-api-server errored internally (caught + logged).

---

## 4. The 5 load-test runs (the evidence)

`-Pn` = `xargs -P n` (n parallel processes, **new connection each**). `-c n` = `ab -c n` (n concurrent, **reused** connections via keep-alive).

| Run | Command | Simultaneous | Result | Lesson |
|---|---|---|---|---|
| 1 | 200 req, `-P40` | 40 | 200 OK | 40 concurrent slow: **backend copes** |
| 2 | 1000 req, `-P150` | 150 | **40× 5xx**, 216× `000` | 150 concurrent: **backend overwhelmed** |
| 3 | 500 req, `ab -c60 -k` | 60 reused | 0 fail | 60 reused: copes (slow, no errors) |
| 4 | 400 req, `-P200` | 200 | 198× `000`, 0 5xx | 200 new conns: **ALB refuses half at the door** |
| 5 | 25 req (after `2/2` rule) | 6 | 15× `429` | rate rule works — but only once set |

Key: the **parallelism** number decides, not the total. Run 1 (200 total) was fine at 40-wide; Run 4 (400 total) refused half at 200-wide. `ab` reuses ~60 connections (one program, connection pool); `xargs+curl` spawns N one-shot processes, each a fresh TLS handshake — which is why the same concurrency behaves worse under `xargs`.

**Why queuing doesn't save it:** Tomcat *does* queue (`acceptCount ~100` behind `maxThreads ~200`), but queuing only adds *more waiting*, and the requests are already slow — queued requests time out (gateway/ALB timeout) before a thread frees, → 502. An unbounded queue would OOM the server, so servers deliberately cap it and refuse (`000`) — refusing fast is the *healthy* failure. Queuing helps for short bursts of **fast** requests, not sustained **slow** ones.

---

## 5. How to fix it, and at which service

The missing control is a **concurrency cap**, not a better rate limit. Fixes, innermost-out:

| Fix | Service | Stops |
|---|---|---|
| **Downstream call timeouts** (gRPC to moonraker etc.) + connection-pool caps | **external-api-server** | Slow requests hanging 17s and holding a thread — fail fast, thread frees |
| **Per-org concurrency / in-flight limit** ⭐ primary | **api-gateway** | The actual trigger: too many requests in flight at once |
| **Gateway→backend response timeout + bulkhead** (isolate a slow route) | **api-gateway** | Gateway waiting forever on a dead backend → 502 |
| **ALB target-group / connection tuning** | **ALB (infra/Terraform)** | Connection shedding tuned deliberately, not accidentally |

**Primary fix = concurrency limit at api-gateway.** Rate limits count arrivals/sec; add a cap on *simultaneous in-flight per org*. Spring Cloud Gateway supports request-limiting beyond the token bucket.
**Equally important = timeouts at external-api-server** so a slow downstream fails fast instead of pinning a thread for 17s. A rate limit + a concurrency limit + tight timeouts together close the gap; any one alone doesn't.

> **Refinement (see [the-fix-concurrency-limits-and-timeouts.txt](the-fix-concurrency-limits-and-timeouts.txt)):** a *per-org* cap alone does **not** protect the shared backend — 26 orgs × 30 = 780 still drowns it (26 × a 20-cap = 520 > ~200 threads). You need a **global** in-flight cap sized to backend capacity (survival) **plus** a per-org cap (fairness). And the rejection is **not** automatically 429 — choose it; prefer **`503 + Retry-After`** and keep it distinct from the rate-limit 429 on dashboards.

> **Where the guarantee lives (see [2026-08-10_external-api-server-bulkhead-design.txt](2026-08-10_external-api-server-bulkhead-design.txt)):** the authoritative cap belongs **at external-api-server**, not the gateway — each pod's thread pool is a *per-pod* resource, so a per-pod **Semaphore bulkhead** protects it exactly and sees *all* callers (`/v1` + `/internal`). A per-gateway cap can't guarantee the number (N replicas × cap, plus non-gateway traffic). The design spec adds a bulkhead filter that fast-rejects with `503 + Retry-After`, sized **below** `threads.max` so a thread is always free to reject — **without touching the moonraker gRPC calls** (their latency is out of scope).

---

## 6. The observability change shipped this session — external-api-server PR #353

No existing log carried **organization + status + latency** together, so "which tenant's flood caused the 5xx" was unanswerable. Added `AccessLogFilter`:

```
access route=/v1/cleanrooms/{id}, method=GET, status=502, latencyMs=8123, organizationID=org-42, path=..., requestId=...
```

**Key design points (files/lines):**
- `http/filters/AccessLogFilter.java` — `@Order(HIGHEST_PRECEDENCE)`, logs in a `finally` block so it sees the **final** status after `@ControllerAdvice`; WARN for 5xx else INFO.
- org read from a **request attribute**, not MDC — both auth filters `MDC.remove` the org in their own `finally`, so MDC is empty when the outer filter logs; a request attribute persists regardless of filter order.
- One added line each in `InternalJwtTokenFilter.java:50` (external paths) and `InternalAuthFilter.java:122` (`/internal` paths) to set that attribute.
- Filter-order ladder is now declared explicitly across the package (see `InternalAuthFilter` javadoc): `AccessLogFilter` (HIGHEST) → `RequestIdFilter` (+10) → `FilterChainExceptionHandler` (+20) → `InternalAuthFilter` (+30, TERMINAL — never calls `doFilter`, either `sendError`s or forwards) → Spring Security → `InternalJwtTokenFilter` (LOWEST).
- Regression check: `try/finally` with no `catch` (exceptions re-propagate, nothing swallowed); no attribute-name collision; `getRequestURI()` excludes query string (no secret leakage). Cost = one log line per non-health request (sampling is a later option).

### Filter-chain mechanics learned (for future readers)
- Filters nest: `chain.doFilter()` pauses a filter and runs everything inside; code after it (the `finally`) runs on the way back out. Outermost filter = first in, last out — required to measure the whole request and see the final status.
- The response is **not returned**; it's written into a shared `HttpServletResponse` object passed by reference. When the outermost filter's `void` method ends, Tomcat sends whatever is in that object. AccessLogFilter's `finally` only *reads* status; it returns nothing.
- `FilterChainExceptionHandler` catches exceptions thrown by **filters** (not just controllers, which `@ControllerAdvice` handles), calls `resolver.resolveException` to set a proper status, and does **not** re-throw — so the outer AccessLogFilter still reads a real final status.

---

## 7. What logs/metrics exist today (pre-PR-merge) for 5xx

- **external-api-server error log** `GlobalRestResponseEntityExceptionHandler.java:80` — `log.error("Error in request: {}", ...)`. Fires inside auth-filter scope, so `organizationID` rides in via MDC as a top-level JSON field. **But**: no status in the message, and it fires for 4xx too — cannot cleanly isolate 5xx. This is exactly why PR #353 was needed.
- **502s from the ALB are not in app logs at all** — the gateway/backend never finished those requests. Authoritative source = **ALB (Application Load Balancer) CloudWatch metrics / access logs**: `HTTPCode_Target_5XX_Count` (gateway-origin), `HTTPCode_ELB_5XX_Count` (ALB-origin), `TargetResponseTime`, `RejectedConnectionCount` (= the `000`s). ALB access logs' `elb_status_code` vs `target_status_code` distinguish who produced the 502; the ALB never knows `organizationID`.
- **Prometheus metric** `http_server_requests_seconds_count` exists but only `janus` reports it (collection gap: `prometheusOperatorObjects: false` + no `prometheus.io` annotation) — so use **LogQL**, not PromQL.

---

## 8. Open questions / next steps

1. Implement the **per-org concurrency limit** at api-gateway (primary fix). Decide the ceiling per org.
2. Add/verify **downstream gRPC timeouts + pool caps** in external-api-server so slow calls fail fast.
3. Set a **gateway→backend response timeout** and consider a per-route bulkhead for expensive routes.
4. Merge PR #353, then build the per-org 5xx and P95-latency LogQL panels.
5. Confirm whether ALB access logs ship to Loki — if so, that single source answers "how many 502s, ALB vs gateway origin."
6. Rotate the stage client_secret used in the load test (it appeared in chat), and delete the temporary `^/v1/cleanrooms.* 2/2` rate rule.
