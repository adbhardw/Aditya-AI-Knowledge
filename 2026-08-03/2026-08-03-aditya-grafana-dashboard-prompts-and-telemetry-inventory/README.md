# Grafana dashboard build prompts + telemetry inventory (2026-08-03)

Paste-ready prompts that make the Grafana AI chat construct an API tenant-health /
abuse-detection dashboard, plus a multi-repo audit of what telemetry actually exists
to feed it.

## Start here

- **[SUMMARY.md](SUMMARY.md)** — the headline finding (the estate already exports
  Prometheus metrics, which the prior session missed), the four incompatible
  organizationID log formats, the confirmed JSON log envelope and its parser, and
  the prioritised recommendations.

## Files

| File | Contents |
|---|---|
| [`2026-08-03_grafana-ai-dashboard-build-prompts.txt`](2026-08-03_grafana-ai-dashboard-build-prompts.txt) | Paste into the Grafana AI chat window. Resolved STEP 0 parser, 13 buildable panels (Part A), pre-written queries for blocked panels (Part B), and a panel-rules appendix that prevents the `rate()*3600` and unit-mismatch defects recurring. |
| [`2026-08-03_telemetry-inventory-what-else-is-emitted.txt`](2026-08-03_telemetry-inventory-what-else-is-emitted.txt) | What every service emits, searched across external-api-server, forebitt, hank, moonraker and the dyogram deployment charts. Logs and metrics, with file and line references. |
| [`2026-08-03_CORRECTIONS-and-gateway-change-spec.txt`](2026-08-03_CORRECTIONS-and-gateway-change-spec.txt) | **Read this alongside the other three.** Corrects three claims after reading the real `deklareddotcom/api-gateway` (earlier analysis used a local study project), explains how `PathRateLimitFilter` actually resolves config and buckets requests, and specifies the change shipped as [PR #95](https://github.com/deklareddotcom/api-gateway/pull/95). |
| [`2026-08-03_implementation-plan-429-5xx-latency-telemetry.txt`](2026-08-03_implementation-plan-429-5xx-latency-telemetry.txt) | **§4 superseded by the corrections file.** | What to actually build to unblock 429 / 5xx / latency / route panels: the access-log filter (with the filter-ordering and route-templating traps), the structured gateway 429, token-failure logging, cardinality guardrails, rollout order with effort estimates, and a verification query per step. |

## Headline findings

- **15 Helm charts ship a Prometheus ServiceMonitor with metrics enabled** — but the chart
  that reaches Grafana Cloud does **not** consume ServiceMonitors and the apps are not
  annotated, so app HTTP metrics may not be collected. Verify before planning around them.
  Cluster metrics (CPU/memory/restarts/HPA) are shipping regardless.
- **Per-org 429 was already available for quota rejections** all along; only the path
  filter lacked it. Fixed in api-gateway PR #95, which also fixed an unbounded-cardinality
  metric tag (raw URI path) that was live in production.
- **Path rate-limit buckets key on the raw path**, so a client enumerating resource IDs
  gets a fresh bucket per ID. Org quota is the real control for flooding.
- **Metrics have status but no tenant; logs have tenant but no status.** Every remaining
  blocked panel reduces to that one missing join.
- Of ~25 org-carrying log lines in `external-api-server`, **only one** uses the
  `organizationID=` form that Datadog auto-facets — and it happens to be the one every
  existing dashboard is built on. The other 22 use space or colon separators, or a
  different key name.
- Two **cross-tenant authorization failure** warnings (`IntelligenceService.java:50,121`)
  are already parseable and dashboarded nowhere.
- **`organizationID` is already put into the logging MDC** by the auth filters, and
  LogstashEncoder promotes MDC entries to top-level JSON fields — so tenant attribution
  may already be solved for authenticated requests. The token endpoint is the one place
  MDC is empty, and it is the only endpoint anyone had looked at.
- Production logs **are JSON** (confirmed from live Grafana output). `requestId`, `logger_name`
  and `level` are top-level fields; `organizationID`/`clientID` are not — they stay inside
  `message`, so extraction is two-stage.

## Related

- [2026-08-02 — Loki/Grafana/Datadog abuse visibility](../../2026-08-02/2026-08-02-aditya-loki-grafana-datadog-discussion/SUMMARY.md) — the investigation this builds on, including the 12× Grafana/Datadog discrepancy root cause.
