# API gateway rate-limit observability — PR #95 (2026-08-06)

Walkthrough of [deklareddotcom/api-gateway#95](https://github.com/deklareddotcom/api-gateway/pull/95),
written for an engineer new to the codebase, plus the cardinality reasoning behind it and
a merge-readiness review.

## Start here

- **[SUMMARY.md](SUMMARY.md)** — problem, the four changes with line numbers, the cardinality
  finding, design reasoning, merge readiness and open questions.

## Files

| File | Contents |
|---|---|
| [`2026-08-06_pr95-walkthrough-for-new-engineers.txt`](2026-08-06_pr95-walkthrough-for-new-engineers.txt) | Change-by-change: why it was needed, exact file/line references, before-vs-after runtime flow for one real request, design alternatives, and a debugging guide (breakpoints, log searches, Redis keys). Assumes you know Java but not this codebase. |
| [`2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt`](2026-08-06_metric-cardinality-why-raw-paths-cost-money.txt) | Why "we can just strip the UUIDs in Grafana" doesn't work — the cost is paid in JVM heap, scrape payload and TSDB before any query runs — and where the resource IDs went instead. |

## Headline

The rejection counter was tagged with the **raw URL**, so every distinct throttled path created
a permanent Prometheus time series. Because the counter only fires on rejection, and rejections
spike during an ID-enumeration flood, **the metric exploded precisely when you needed to read it**.

The PR tags it with the bounded matched route pattern instead, and moves the high-cardinality
detail (raw path) plus the newly-added `organizationID` into the **log**, where cardinality is free.
No throttling behaviour changes.

## Related

- [Rate-limit reference and prod config audit](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md) — how the two limiters work and what prod is actually configured to do
- [Filter order and request lifecycle](../2026-08-06-aditya-understanding-api-gateway-filter-order-and-request-lifecycle/SUMMARY.md)
