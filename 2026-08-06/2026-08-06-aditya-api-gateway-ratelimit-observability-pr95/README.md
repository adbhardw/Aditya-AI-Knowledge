# API gateway rate-limit observability — PR #95 (2026-08-06)

[deklareddotcom/api-gateway#95](https://github.com/deklareddotcom/api-gateway/pull/95): making
rate-limit rejections attributable to a tenant, the cardinality reasoning behind the tag design,
and the dashboards it unlocks.

## Start here

- **[SUMMARY.md](SUMMARY.md)** — problem, what shipped, why the tag design moved three times,
  the cardinality arithmetic, merge readiness and open questions.

## Files

| File | Contents |
|---|---|
| [`2026-08-06_rate-limit-dashboard-queries-grafana-datadog.txt`](2026-08-06_rate-limit-dashboard-queries-grafana-datadog.txt) | **Paste-ready.** 19 panels across executive / per-org / per-cleanroom / limiter-health / upstream sections. Every query given for **both** Prometheus and Loki, plus Datadog log queries. Opens with two verification queries that decide which half applies, and closes with the panel rules (`rate()*3600`, Min-interval, unit mismatch). |
| [`2026-08-06_pr95-walkthrough-for-new-engineers.txt`](2026-08-06_pr95-walkthrough-for-new-engineers.txt) | Change-by-change teaching walkthrough: why each change was needed, exact line references, before-vs-after runtime flow for one request, design alternatives, debugging guide. Carries a header marking which section is historical — the metric tag design changed after it was written. |
| [`2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt`](2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt) | Why "we can just strip the UUIDs in Grafana" doesn't work — the cost is paid in JVM heap, scrape payload and TSDB active series before any query runs. |

## Final metric shape

```
rate_limit_exceeded_total{source="Path",  path, organization_id, method}
rate_limit_exceeded_total{source="QUOTA", organization_id}
```

## Headline

The organization was resolved inside the filter (it builds the Redis bucket key) and then
**thrown away** — so "which customer is being throttled" was unanswerable. It's now in both the
log and the metric.

The tag design moved three times: raw path → matched route → organization → organization **and**
path. The cardinality objection to keeping the path turned out to be **overstated**, and the
arithmetic is in §5 of the summary: a novel URL starts with a full bucket so the first request
costs nothing, and the quota filter runs first and short-circuits the path filter once an org's
daily budget is gone — bounding series creation to roughly 242/day for an org on the `ALL` quota.
The quota is the backstop; no extra cap was needed.

## Related

- [Rate-limit reference and prod config audit](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md) — how the two limiters work and what prod is configured to do
- [Filter order and request lifecycle](../2026-08-06-aditya-understanding-api-gateway-filter-order-and-request-lifecycle/SUMMARY.md)
