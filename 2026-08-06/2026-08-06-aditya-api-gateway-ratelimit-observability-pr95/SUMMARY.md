# SUMMARY — API gateway rate-limit observability (PR #95): walkthrough, cardinality, merge readiness

**Date:** 2026-08-06
**Session type:** PR authoring → teaching walkthrough → merge-readiness review
**PR:** [deklareddotcom/api-gateway#95](https://github.com/deklareddotcom/api-gateway/pull/95) — branch `DV-observability/path-ratelimit-org-attribution`

**Files in this folder:**
- [`2026-08-06_pr95-walkthrough-for-new-engineers.txt`](2026-08-06_pr95-walkthrough-for-new-engineers.txt) — change-by-change walkthrough with line numbers, runtime flow, debugging guide
- [`2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt`](2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt) — why "just strip the UUIDs in Grafana" doesn't work

**Related:** [rate-limit reference + prod audit (2026-08-04)](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md) · [filter order and request lifecycle](../2026-08-06-aditya-understanding-api-gateway-filter-order-and-request-lifecycle/SUMMARY.md)

---

## 1. Problem statement

Rate-limit rejections in the API gateway could not answer the one question the whole abuse-detection effort exists for: **which customer is being throttled?** Separately, the rejection counter carried an unbounded-cardinality tag that was live in production.

## 2. First principles

```
METRICS  →  "how much?"   bounded labels, aggregate counts, cheap, alertable
LOGS     →  "who?"        unbounded detail, one line per event, free per value
```

Every metric name **plus one specific set of tag values** is a separate time series, stored for the whole retention window. So the question to ask before adding any tag is *"how many distinct values can this take, worst case?"*

## 3. What the PR changes

| Change | File / lines | Why |
|---|---|---|
| `final String orgId` | `PathRateLimitFilter.java:93` | Java requires lambda-captured locals be *effectively final*; `organizationId` is assigned twice. Compile-only. |
| Metric tag: raw path → matched route (+ `method`) | `PathRateLimitFilter.java:101-102, 178-186` | Fixes unbounded cardinality |
| Log gains `organizationID`, `route`, `method`, `outcome` | `PathRateLimitFilter.java:112-113` | Makes rejections attributable to a tenant |
| Failure branches gain context; `setStatusCode` return checked | `AbstractRateLimitFilter.java:48-61` | A failed rejection was previously anonymous and silent |
| Message shape aligned, `organizationId` → `organizationID` | `QuotaRateLimitFilter.java` | One Datadog facet / Grafana variable covers both services (matches `Auth0Service.java:75`) |
| New test | `PathRateLimitFilterTelemetryTest.java` | There was no test for this filter at all |

**No throttling behaviour changes** — no limits, buckets, thresholds or request outcomes are touched.

## 4. The core finding: a cardinality bomb triggered by the attack

The counter increments only **on rejection** (`PathRateLimitFilter.java:114`). Before the PR it was tagged with `exchange.getRequest().getURI().getPath()` — the raw URL:

```
BEFORE   rate_limit_exceeded{source="Path", key="/v1/cleanrooms/3f2a91c4-…/questions/8c1b7e90-…"}
         → one permanent series per RESOURCE

AFTER    rate_limit_exceeded{source="Path", route="/v1/cleanrooms/**", method="POST"}
         → one series per configured ROUTE + method
```

Rejections spike during a flood. A client enumerating resource IDs — precisely the abuse being hunted — creates thousands of series in minutes. **The metric explodes exactly when you need to read it**, degrading the same Prometheus serving the dashboard.

### Why "strip the UUIDs in Grafana" doesn't help

The cost is paid three steps before any query:

1. **JVM heap** — `Metrics.counter(name, tags)` creates and *permanently retains* a `Counter` object per unique tag set for the process lifetime.
2. **Scrape payload** — one line per series, re-serialised every 30s.
3. **Prometheus / Grafana Cloud** — memory and billing are on active series; `label_replace()` must load them all first.

**But the IDs aren't lost.** `PathRateLimitFilter.java:112-113` still logs `path={}` with the full raw URL on every rejection. The detail moved from the metric to the log, where cardinality is free — logs charge per line written, not per distinct value.

## 5. Where the bounded route comes from

`matchedRoute()` reads `ServerWebExchangeUtils.GATEWAY_PREDICATE_MATCHED_PATH_ATTR` — the *pattern* Spring Cloud Gateway matched, from route config:

```
request:   /v1/cleanrooms/3f2a91c4-…/questions/8c1b7e90-…
attribute: "/v1/cleanrooms/**"
```

**Default return value: the literal string `"NOT_FOUND"`** (constant at line 27) when the attribute is absent. Not `null`, for two reasons: `Tags.of()` with a null value throws — turning a rejection into a 500 — and it collapses unmatched requests into one bounded series.

This mirrors the existing `http/metrics/RouteIdWebFluxTagContributor.java:19-22`, which reads the same attribute with the same `"NOT_FOUND"` fallback, so the `route` tag agrees with the one already on `http_server_requests`.

## 6. Design reasoning: why org is logged, not tagged

As a metric tag, `organizationID` multiplies: 500 orgs × 30 routes × 7 methods ≈ 105,000 potential series. As a log field it costs nothing — the line is written regardless. The reasoning is left as a comment at `PathRateLimitFilter.java:104-106` so a future contributor doesn't "helpfully" add the tag.

## 7. `outcome=REJECTED`, not `status=429` — and an honest correction

The first version logged `status=429`. That line is emitted at 112, but `handleRateLimitExceeded` (which decides the status) runs at 115 and has a branch returning `Mono.error` → a 500. The log asserted something undecided.

Writing a test for that branch revealed it is **unreachable**: `RedisRateLimiter.Response`'s constructor asserts non-null headers. So no wrong data was ever emitted — `status=429` was accurate *by accident of a constructor three classes away*. The test was deleted rather than kept as one that cannot fail; the rename stands because it removes the coupling (if quota later returns 503, the log won't silently lie).

## 8. Does the `setStatusCode` change carry risk?

**No.** The `if` body contains only a log — no return, no throw, no state change:

```java
if (!exchange.getResponse().setStatusCode(HttpStatus.TOO_MANY_REQUESTS)) {
    log.warn("… reason=RESPONSE_ALREADY_COMMITTED", …);
}
addRateLimitHeaders(exchange, response);   // runs either way
return exchange.getResponse().setComplete();
```

`ServerHttpResponse.setStatusCode` returns `boolean` — `false` when the response is already committed. The old code discarded it, so "silently failed to throttle" had no signal. Now it does. Purely a detection change.

## 9. Merge readiness (as of 2026-08-06)

| Check | State |
|---|---|
| `check-labels` | ❌ → ✅ — was the **only** red check; missing SOC2 label, `change/standard` added |
| `build`, Snyk × 6 | ✅ |
| Local `mvn test` | ✅ 13 tests, 0 failures |
| Merge with `main` | clean; 3 commits behind, **zero overlap** with rate-limiter files |
| Reviews | 0 — `REVIEW_REQUIRED` |

### The real pre-merge risk

Two **log message strings changed shape**:

```
"Path rate limit exceeded for path: {}"   →  "Rate limit exceeded limitType=path, …"
"Quota exceeded. organizationId={}"       →  "Rate limit exceeded limitType=quota, …"
```

Any Datadog monitor matching those literals **stops firing** — and a silent monitor is indistinguishable from "no problems." A grep of `dyogram` and all locally checked-out repos found nothing referencing them or `rate_limit_exceeded`, but monitors usually live in the Datadog UI, not git. **Someone with Datadog access must confirm before merge.** Same class of check for the `key` → `route` tag rename.

## 10. Open questions

- Is `GATEWAY_PREDICATE_MATCHED_PATH_ATTR` actually populated at filter order −1 in a routed request? Tests set it by hand. If not, every series tags `route="NOT_FOUND"` — safe but useless. **Post-deploy check:** `sum by (route) (rate(rate_limit_exceeded_total{source="Path"}[5m]))`.
- Does any Datadog monitor match the two old log strings?
- Two commits, the second partly reversing the first (`status=429` → `outcome=REJECTED`) — squash on merge, or keep the history?

## 11. Next steps

1. Datadog monitor check on the two old strings (blocking).
2. Request reviewers — none assigned yet.
3. Merge, then verify the `route` tag isn't universally `NOT_FOUND`.
4. Build the top-offenders-by-org panel, now that the org is in the log.
5. Consider the same treatment for `HeaderRateLimitFilter`, untouched by this PR.

## 12. Key takeaways

1. Metrics answer *how much*, logs answer *who*. Never put a customer ID in a metric tag.
2. Every metric tag value is a permanent object — in the JVM *and* in Prometheus.
3. If you plan to strip part of a tag value at query time, it shouldn't be in the tag.
4. Log what you **know**, not what you **assume**.
5. Check return values — `setStatusCode` returning `boolean` isn't decoration.
6. Match existing conventions; consistency is what makes cross-service queries possible.
