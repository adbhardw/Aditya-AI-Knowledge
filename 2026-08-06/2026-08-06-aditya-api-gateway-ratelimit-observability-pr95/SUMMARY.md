# SUMMARY — API gateway rate-limit observability (PR #95): design, cardinality, dashboards

**Date:** 2026-08-06
**Session type:** PR authoring → teaching walkthrough → design iteration → dashboard queries
**PR:** [deklareddotcom/api-gateway#95](https://github.com/deklareddotcom/api-gateway/pull/95) — branch `DV-observability/path-ratelimit-org-attribution`

**Files in this folder:**
- [`2026-08-06_rate-limit-dashboard-queries-grafana-datadog.txt`](2026-08-06_rate-limit-dashboard-queries-grafana-datadog.txt) — **paste-ready**: 19 panels, every query in both Prometheus and Loki, plus Datadog log queries
- [`2026-08-06_pr95-walkthrough-for-new-engineers.txt`](2026-08-06_pr95-walkthrough-for-new-engineers.txt) — change-by-change teaching walkthrough (carries a header noting which section is historical)
- [`2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt`](2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt) — why "just strip the UUIDs in Grafana" doesn't work

**Related:** [rate-limit reference + prod audit (2026-08-04)](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md) · [filter order and request lifecycle](../2026-08-06-aditya-understanding-api-gateway-filter-order-and-request-lifecycle/SUMMARY.md)

---

## 1. Problem statement

Rate-limit rejections could not answer the question the whole abuse-detection effort exists for: **which customer is being throttled?** The organization was resolved inside the filter (it builds the Redis bucket key) and then discarded. Separately, the rejection counter was tagged with the raw request URL.

## 2. First principles

```
METRICS  →  "how much?"   bounded labels, aggregate counts, cheap, alertable
LOGS     →  "who / which one?"   unbounded detail, one line per event, free per value
```

A metric name **plus one specific set of tag values** is a separate time series, retained for the whole window and — in Micrometer — a `Counter` object retained in JVM heap until the process restarts. So the question before adding any tag is *"how many distinct values, worst case?"*

## 3. What shipped

| Change | File / lines | Why |
|---|---|---|
| `final String orgId` | `PathRateLimitFilter.java:89` | Java requires lambda-captured locals be *effectively final*; `organizationId` is assigned twice. Compile-only. |
| Log gains `organizationID`, `method`, `outcome`, `path` | `PathRateLimitFilter.java:99-100` | Makes rejections attributable to a tenant |
| Counter tagged `{source, path, organization_id, method}` | `PathRateLimitFilter.java:97, 154-157` | Per-tenant **and** per-cleanroom breakdown, alertable in Prometheus |
| Quota tag renamed `key` → `organization_id` | `QuotaRateLimitFilter.java` | One query spans both limiters |
| Failure branches gain context; `setStatusCode` return checked | `AbstractRateLimitFilter.java:34-47` | A failed rejection was previously anonymous and silent |
| New test | `PathRateLimitFilterTelemetryTest.java` | There was no test for this filter at all |

**No throttling behaviour changes** — no limits, buckets, thresholds or request outcomes are touched.

### Final metric shape

```
rate_limit_exceeded_total{source="Path",  path, organization_id, method}
rate_limit_exceeded_total{source="QUOTA", organization_id}
```

## 4. The design went through three positions — worth recording why

| Commit | Tag design | Why it moved |
|---|---|---|
| `ec3c730` / `6220bf8` | raw path → **matched route pattern** via `matchedRoute()` | Fixed the cardinality bomb, but duplicated a dimension `http_server_requests{route=…}` already provides, and rested on an unverified assumption about when `GATEWAY_PREDICATE_MATCHED_PATH_ATTR` is populated |
| `5f186e9` | **organization** instead of route; `matchedRoute()` removed | The org dimension existed *nowhere*; the route dimension existed already. Trading a duplicate for a unique signal, and removing the unverified assumption entirely |
| `bf7eb74` | **path added back** alongside org and method | Per-cleanroom breakdown wanted in Prometheus/Datadog too, not only in Loki |

## 5. The cardinality question, resolved

The original concern: the counter increments **only on rejection**, rejections spike during a flood, and a client enumerating resource IDs would create thousands of series in minutes — *the metric exploding precisely when you need to read it*.

**That concern was overstated, and the arithmetic shows why.** Two facts settle it:

1. **A novel URL starts with a full bucket.** The counter lives inside `if (!response.isAllowed())`. A brand-new random UUID means a brand-new Redis bucket at full burst capacity, so the first request is *allowed* → no series created.
2. **Quota short-circuits the path filter.** `QuotaRateLimitFilter` is order −2, `PathRateLimitFilter` is −1. When quota rejects, `handleRateLimitExceeded` calls `setComplete()`, terminating the chain — the path filter never runs.

So to create **one** new `path` series an attacker must exhaust that URL's bucket:

| Rule in play | Burst | Requests to trip it |
|---|---|---|
| create-run `ALL` (1/3600/180) | 20 | 21 |
| `^/v1.*` `ALL` (100/100/1) | 100 | 101 |
| per-org allowlist (1000/1000/1) | 1000 | 1001 |

```
org on the ALL quota      5,082 req/day ÷ 21 ≈ 242 new series/day
org with its own quota   28,800 req/day ÷ 21 ≈ 1,371 new series/day
```

**The quota is the backstop; no extra cap was added.** No hard limit exists anywhere in the stack (Micrometer has no default cap, the ServiceMonitor sets no `sampleLimit`); the real ceiling is the Grafana Cloud plan's active-series limit. JVM-side accumulation is cleared by pod restart, so normal deploys bound it naturally.

If it ever does bite, the one-line fix is `MeterFilter.maximumAllowableTags("rate_limit_exceeded", "path", 5000, MeterFilter.deny())` — full detail up to a ceiling, then no new series. Panel **D4** in the dashboard file watches for it.

## 6. `outcome=REJECTED`, not `status=429` — and an honest correction

The first version logged `status=429`. That line is emitted before `handleRateLimitExceeded` runs, and that method has a branch returning `Mono.error` → a 500. The log asserted something undecided.

Writing a test for that branch revealed it is **unreachable**: `RedisRateLimiter.Response`'s constructor asserts non-null headers. So no wrong data was ever emitted — `status=429` was accurate *by accident of a constructor three classes away*. The test was deleted rather than kept as one that cannot fail; the rename stands because it removes the coupling.

## 7. `setStatusCode` — no behavioural risk

```java
if (!exchange.getResponse().setStatusCode(HttpStatus.TOO_MANY_REQUESTS)) {
    log.warn("… reason=RESPONSE_ALREADY_COMMITTED", …);
}
addRateLimitHeaders(exchange, response);   // runs either way
return exchange.getResponse().setComplete();
```

The `if` body contains only a log — no return, no throw, no state change. `ServerHttpResponse.setStatusCode` returns `boolean` (`false` when the response is already committed); the old code discarded it, so "silently failed to throttle" had no signal. Purely a detection change.

## 8. What you can build now — 19 panels

Full queries in [`2026-08-06_rate-limit-dashboard-queries-grafana-datadog.txt`](2026-08-06_rate-limit-dashboard-queries-grafana-datadog.txt). The ones that matter most:

- **A4 — top 10 orgs by rejections.** The panel the whole exercise exists for.
- **B2 — org × limiter type.** An org appearing under *both* `path` and `quota` is hitting a per-URL rule *and* burning its daily budget — the strongest abuse signal available.
- **B4 — rejections with `organization_id="ALL"`.** The quota filter **skips entirely** when the org can't be resolved, so this traffic has no org-wide ceiling — only per-URL limits, which ID rotation defeats.
- **C2 — org × path.** Which cleanroom of which customer. Available in Prometheus because the `path` tag was kept.
- **D1 / D2 — alert on these.** `outcome=ERROR` means the limiter decided to reject but the client didn't get a 429. `"Error during rate limiting check"` means Redis threw, `onErrorResume` returned `Mono.empty()`, and **the request was allowed through** — fail-open, with nothing else signalling it.
- **E2 — cross-tenant access attempts.** Already in production, parseable today, dashboarded nowhere.

## 9. Two things must be verified before the dashboards work

1. **Are gateway logs in Loki?** `{cluster="eks-admin-prod"} |= "Rate limit exceeded"`
2. **Are gateway metrics in Grafana?** `rate_limit_exceeded_total` — if empty, this is the collection-path gap: `monitoring-k8s` sets `prometheusOperatorObjects.enabled: false` (ServiceMonitors not consumed) and the app charts carry no `prometheus.io/scrape` annotation. **A config fix, not a code fix.** Every panel has a Loki variant meanwhile.

Datadog sections are all log-based, since the same annotation gap likely means Datadog has the logs but not these metrics.

## 10. Merge readiness

| Check | State |
|---|---|
| `check-labels` | ❌ → ✅ — was the only red check; `change/standard` added |
| `build`, Snyk × 6 | ✅ |
| Local `mvn test` | ✅ 13 tests |
| Merge with `main` | clean |
| Reviews | 0 — `REVIEW_REQUIRED` |

**The real pre-merge risk:** two log message strings changed shape (`"Path rate limit exceeded for path: {}"` and `"Quota exceeded. organizationId={}"`). Any Datadog monitor matching those literals **stops firing**, and a silent monitor is indistinguishable from "no problems." A grep of `dyogram` and all locally checked-out repos found nothing referencing them or `rate_limit_exceeded`, but monitors usually live in the Datadog UI. **Someone with Datadog access must confirm.** Same class of check for the `key` → `organization_id` tag rename on the quota counter.

## 11. Open questions

- Does any Datadog monitor match the two old log strings? (blocking)
- Are gateway logs and metrics actually reaching Grafana? (§9)
- Four commits, with the tag design moving twice — squash on merge, or keep the history that records why?

## 12. Next steps

1. Datadog monitor check (blocking).
2. Request reviewers — none assigned.
3. Run the two verification queries; if metrics are absent, fix the scrape config.
4. Build the dashboard from the queries file, starting with A4, B2, D1, D2.
5. Consider the same treatment for `HeaderRateLimitFilter`, untouched by this PR.

## 13. Key takeaways

1. Metrics answer *how much*, logs answer *who*. Choose deliberately which tier carries each dimension.
2. Every metric tag value is a permanent object — in the JVM *and* in Prometheus.
3. Before rejecting a tag on cardinality grounds, **do the arithmetic**. Here the enforcement design (full initial bucket + quota short-circuit) bounded it far better than intuition suggested.
4. Log what you **know**, not what you **assume**.
5. Check return values — `setStatusCode` returning `boolean` isn't decoration.
6. Changing a log message shape silently breaks monitors matching the old literal. Grep is necessary but not sufficient.
