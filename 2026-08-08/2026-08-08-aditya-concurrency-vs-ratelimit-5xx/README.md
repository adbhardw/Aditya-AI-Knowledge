# Concurrency vs rate limiting — why a rate-limited API still 5xx'd (2026-08-08)

A load test of the api-gateway rate limiter produced **5xx**, not `429`, at a fraction of the
org's quota. The reason: a per-second **rate** limit doesn't cap **concurrency**, so ~150 slow
requests in flight at once exhausted the backend's thread pool.

## Start here

- **[SUMMARY.md](SUMMARY.md)** — problem, the three-limits distinction (quota vs rate vs
  concurrency), the 5 load-test runs as evidence, where each error code originates, the fix
  (concurrency cap at the gateway + timeouts at external-api-server), and the observability
  change shipped this session (external-api-server PR #353 access log).
- **[concurrency-vs-ratelimit-explained.txt](concurrency-vs-ratelimit-explained.txt)** —
  the plain-language walkthrough: concurrent vs parallel, why `ab` reuses connections but
  `xargs -P` opens new ones, why queuing doesn't help slow requests, and the fix table.
- **[the-fix-concurrency-limits-and-timeouts.txt](the-fix-concurrency-limits-and-timeouts.txt)** —
  the fix in depth: why a per-org cap alone fails against many orgs summing up (26 × 30 = 780),
  the **global vs per-org** cap distinction, why the backend thread pool is a *bad* global cap,
  what status to return (**not** automatically 429 — prefer `503 + Retry-After`, kept distinct
  from the rate 429), and the full fix by service with implementation order.
- **[2026-08-10_external-api-server-bulkhead-design.txt](2026-08-10_external-api-server-bulkhead-design.txt)** —
  **design spec (no Java edits)** for the authoritative fix: a **Semaphore bulkhead filter** at
  external-api-server that fast-rejects the overflow with `503 + Retry-After` once N are in flight.
  Covers the sizing rule (bulkhead **below** `threads.max` so a thread is always free to reject),
  exact files/config/order to add, why it belongs at the backend (per-pod thread pool = per-pod
  limiter, sees `/v1` **and** `/internal`), the 503-not-429 choice, metrics, and dark rollout.
  Constraint respected: **the moonraker gRPC calls are not touched.**

## Headline

| | |
|---|---|
| Quota burst | 5,082 — never the binding limit |
| Rate observed | ~10/sec — under any limit, so no 429 |
| **Concurrency** | **~150 in flight at once — this is what broke it** |

Every in-flight request holds a thread for its whole 5–17s. 150 simultaneous = 150 threads
pinned → Tomcat (~200 threads) exhausted → `502`/`500`. The number that matters is
**parallelism, not total**: 200 requests at 40-wide passed; 400 at 200-wide had half refused.

## The fix, and at which service

**The guarantee belongs at external-api-server** — each pod's thread pool is a per-pod resource,
so a **per-pod bulkhead** (Semaphore filter, `503 + Retry-After`, sized below `threads.max`)
protects it exactly, and it sees *all* traffic (`/v1` via the gateway **and** `/internal`). The
gateway concurrency limit is complementary — cheaper early shedding + **per-org fairness** — but a
per-gateway cap can't *guarantee* the backend number (N replicas × cap, plus non-gateway traffic).
Design spec: [2026-08-10_external-api-server-bulkhead-design.txt](2026-08-10_external-api-server-bulkhead-design.txt).
Full layering in [the-fix-concurrency-limits-and-timeouts.txt](the-fix-concurrency-limits-and-timeouts.txt).

## Related

- [api-gateway rate-limit observability PR #95](../../2026-08-06/2026-08-06-aditya-api-gateway-ratelimit-observability-pr95/SUMMARY.md)
- [Rate-limit reference and prod config audit](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md)
- external-api-server PR #353 (access log with organizationID + status + latency) — described in SUMMARY.md §6
