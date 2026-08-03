# Grafana dashboard build prompts + telemetry inventory (2026-08-03)

Paste-ready prompts that make the Grafana AI chat construct an API tenant-health /
abuse-detection dashboard, plus a multi-repo audit of what telemetry actually exists
to feed it.

## Start here

- **[SUMMARY.md](SUMMARY.md)** — the headline finding (the estate already exports
  Prometheus metrics, which the prior session missed), the four incompatible
  organizationID log formats, the unresolved log-format question, and the
  prioritised recommendations.

## Files

| File | Contents |
|---|---|
| [`2026-08-03_grafana-ai-dashboard-build-prompts.txt`](2026-08-03_grafana-ai-dashboard-build-prompts.txt) | Paste into the Grafana AI chat window. STEP 0 discovery query, 11 buildable panels (Part A), pre-written queries for blocked panels (Part B), and a panel-rules appendix that prevents the `rate()*3600` and unit-mismatch defects recurring. |
| [`2026-08-03_telemetry-inventory-what-else-is-emitted.txt`](2026-08-03_telemetry-inventory-what-else-is-emitted.txt) | What every service emits, searched across external-api-server, forebitt, hank, moonraker and the dyogram deployment charts. Logs and metrics, with file and line references. |

## Headline findings

- **15 Helm charts ship a Prometheus ServiceMonitor with metrics enabled**, including
  `api-gateway` and `external-api-server`, both scraping `/actuator/prometheus`. Roughly
  half the previously "blocked" panels are buildable today from metrics, no code change.
- **Metrics have status but no tenant; logs have tenant but no status.** Every remaining
  blocked panel reduces to that one missing join.
- Of ~25 org-carrying log lines in `external-api-server`, **only one** uses the
  `organizationID=` form that Datadog auto-facets — and it happens to be the one every
  existing dashboard is built on. The other 22 use space or colon separators, or a
  different key name.
- Two **cross-tenant authorization failure** warnings (`IntelligenceService.java:50,121`)
  are already parseable and dashboarded nowhere.
- Whether production logs as JSON is **still unresolved** — `LOGBACK_APPENDER` is set in
  no chart in the repo.

## Related

- [2026-08-02 — Loki/Grafana/Datadog abuse visibility](../../2026-08-02/2026-08-02-aditya-loki-grafana-datadog-discussion/SUMMARY.md) — the investigation this builds on, including the 12× Grafana/Datadog discrepancy root cause.
