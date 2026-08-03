# Loki / Grafana / Datadog — token-request abuse visibility (2026-08-02)

Investigation into making API abuse by organization visible in Grafana and Datadog for
`external-api-server`, and into a ~12× apparent disagreement between the two platforms.

## Start here

- **[SUMMARY.md](SUMMARY.md)** — self-contained executive summary: problem, architecture,
  runtime flow, the verified dashboard queries, the root cause of the Grafana/Datadog
  discrepancy, repository evidence with line numbers, design options, trade-offs,
  recommendation, open questions, next steps.

## Raw transcripts (preserved verbatim)

| File | Contents |
|---|---|
| [`datadog-discussion.txt`](datadog-discussion.txt) | Datadog Bits AI session — widget IDs and queries for the "Cleanroom Auth Token Abuse Monitor" dashboard, the Grafana-vs-Datadog volume investigation, cluster-tag comparison, how Promtail and the Datadog Agent attach cluster labels |
| [`grafana-discussion.txt`](grafana-discussion.txt) | Grafana Assistant session — the LogQL behind "Token Request Rate Over Time", total vs token-subset log volumes, cluster label discovery |

## Headline findings

- The Grafana panel's `rate(...[$__auto]) * 3600` with unit `reqpm` **inflates and
  mislabels** the number — the real rate is ~73/hr, not "780 req/m". There is **no** log
  ingestion gap between Loki and Datadog.
- The widget named "Orgs above threshold" **has no threshold** configured.
- The token endpoint `/v1/oauth/token` is **exempt** from gateway rate limiting.
- The gateway's 429 log line is unstructured, so **"top orgs by 429" cannot be built today**.
- `Auth0Service` logs only *successful* token requests — **failed-auth floods are invisible**.
