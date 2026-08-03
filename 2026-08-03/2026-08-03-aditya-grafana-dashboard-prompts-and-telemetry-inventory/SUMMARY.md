# SUMMARY — Grafana dashboard build prompts + full telemetry inventory

**Date:** 2026-08-03
**Session type:** Dashboard authoring + multi-repo telemetry audit
**Follows on from:** [`2026-08-02-aditya-loki-grafana-datadog-discussion`](../../2026-08-02/2026-08-02-aditya-loki-grafana-datadog-discussion/SUMMARY.md)

**Files in this folder:**
- [`2026-08-03_grafana-ai-dashboard-build-prompts.txt`](2026-08-03_grafana-ai-dashboard-build-prompts.txt) — paste-ready prompts for the Grafana AI chat window that construct 11 panels
- [`2026-08-03_telemetry-inventory-what-else-is-emitted.txt`](2026-08-03_telemetry-inventory-what-else-is-emitted.txt) — what every service actually emits, searched across 5 repos + the deployment charts

---

## 1. Problem statement

Two questions, answered in order:

1. **"Give me one file I can paste into the Grafana AI chat so it builds all the panels."** The Grafana assistant demonstrably works when given an explicit query plus explicit panel options — it had just built a clean 1-bar-per-hour panel from exactly that shape. So the deliverable is a sequence of self-contained build instructions, not prose.
2. **"Are we emitting anything else besides `Token request successful`?"** The 2026-08-02 investigation assumed that log line was the only aggregatable signal. That assumption needed testing across the whole estate before committing to a dashboard design.

The answer to (2) materially revised (1).

---

## 2. Headline finding: the estate already exports Prometheus metrics

The prior session treated **logs as the only telemetry source**. That was wrong, and it under-scoped the dashboard by roughly half.

**Verified from source and Helm charts:**

| Evidence | Location |
|---|---|
| `spring-boot-starter-actuator` + `micrometer-registry-prometheus` | `external-api-server/pom.xml:125,133` |
| `management.metrics.export.prometheus.enabled: true`, exposure includes `prometheus`, management port 9444 | `external-api-server/src/main/resources/application.yml:19-38` |
| `metrics.enabled: true`, `serviceMonitor.enabled: true`, 30s interval | `dyogram/charts/api-gateway/values.yaml:147-156` |
| ServiceMonitor scraping `/actuator/prometheus` on the `management` port | `dyogram/charts/api-gateway/templates/servicemonitor.yaml`, and the identical file under `charts/external-api-server/` |
| 15 charts ship a ServiceMonitor with metrics enabled | api-gateway, armorica, bucolix, cronos, external-api-server, forebitt, identity-bridge, janus, moonraker, pegleg, picanmix, postaldistrix, primage, unhygienix (kedge has one, disabled) |
| Hand-rolled Go metrics: `http_requests_total{path}`, `http_response_time_seconds{method,path,code}`, `requests_in_flight{method,path}` | `hank/metrics/prometheus.go:12-34` |

**What this unblocks with no code change** — previously filed as blocked: requests/sec, errors/sec, 5xx rate, total 429 rate, P95 latency, endpoint breakdown by `uri`, and CPU/memory for the correlation overlay. All from standard Micrometer `http_server_requests_seconds_*{uri, method, status, outcome}`.

**Unverified, and stated as such:** whether those series are actually reachable in their Grafana, and under which datasource name. What is verified is that the exporter dependency, the exposure config and the scrape config are all in place. Confirm with `http_server_requests_seconds_count{service="external-api-server"}` in Explore (the label may be `job`/`app`/`kubernetes_name`).

---

## 3. The architectural point

```
METRICS  answer:  how much, how fast, how broken     (status, uri, latency — no tenant)
LOGS     answer:  which tenant                       (organizationID — no status)
NEITHER  answers: which tenant is being throttled
```

Every remaining blocked panel reduces to **one missing join**: no single record contains both an organization identifier and an HTTP status. Micrometer deliberately omits tenant tags from HTTP metrics — that is correct, and `organizationID` must **not** be added as a Micrometer tag (org count × uri × method × status is unbounded cardinality).

So the fix belongs in the gateway's rejection log, not in the metrics.

---

## 4. Logs: ~25 org-carrying lines, four incompatible formats

`external-api-server` has **390 log statements**; about 25 carry an org/client/user identifier. But:

| Format | Occurrences | Datadog auto-facet? |
|---|---|---|
| `organizationID={}` | **1** (`Auth0Service.java:75`) | ✅ yes |
| `organizationID {}` (space) | 13 | ❌ no |
| `organizationID: {}` (colon) | 9 | ❌ no |
| `orgId={}` | 2 | ✅ but different key |
| `caller={}, owner={}, cr={}` | 2 | ✅ different keys again |

The single line every existing dashboard is built on is also the **only** one in the facet-parseable form. The other 22 org-carrying lines — clean room creation, question runs, data connections, credential fetches, user lookups, run schedules — are invisible to per-tenant aggregation without a custom Grok parser (Datadog) or an alternation regexp (Loki):

```logql
| regexp `organizationID[=: ]\s*(?P<organizationID>[0-9a-f-]{8,})`
```

which still misses `orgId=` and the `caller=`/`owner=` pair.

### Two high-value lines nobody is dashboarding

```java
IntelligenceService.java:50   log.warn("Org mismatch on getCleanRoomIntelligence: caller={}, owner={}, cr={}")
IntelligenceService.java:121  log.warn("Org mismatch in authz check: caller={}, owner={}, cr={}")
```

These fire when one organization attempts to reach another organization's clean room — a **cross-tenant authorization failure**. That is a security signal, not a capacity signal, and it is arguably more important than anything in the original ten-dashboard wishlist. It is already in `key=value` form, so it is aggregatable today with zero code change.

Also present in `http/filters/`: `"Missing required internal headers for path: {}"`, `"Missing or invalid Authorization header for internal path: {}"`, `"Invalid base64 in {} claim"`. Countable in total, but not attributable to a tenant — by definition, the request failed before the org was resolved.

`forebitt` emits **no** tenant-attributable log lines (searched for organization/orgid/tenant/clientid across its Go sources). It does ship a ServiceMonitor, so its HTTP metrics are available.

---

## 5. Still-open question: is production logging JSON?

```xml
<!-- external-api-server/src/main/resources/logback-spring.xml -->
<appender name="json"    class="...ConsoleAppender"><encoder class="net.logstash.logback.encoder.LogstashEncoder"/></appender>
<appender name="console" class="...ConsoleAppender"><encoder><pattern>%cyan(...)%yellow(...)%highlight(...)- %msg%n</pattern></encoder></appender>
<root level="info"><appender-ref ref="${LOGBACK_APPENDER:-console}"/></root>
```

Output is JSON **only** if `LOGBACK_APPENDER=json`. A repo-wide grep finds that variable **only inside the logback XML files themselves** — it is set in no chart, no values file, no deployment template in `dyogram`. So either it is injected from outside this repository, or production emits the plain **coloured** console pattern, in which case Loki queries need `| decolorize` before parsing.

```
kubectl -n external-api-server get pods -l app=external-api-server \
  -o jsonpath='{.items[0].spec.containers[0].env}' | tr ',' '\n' | grep -i logback
```

This is STEP 0 of the prompt file and it remains unresolved.

---

## 6. The dashboard prompt file

Structured for how the Grafana assistant actually behaves — one panel per turn, so blocks are pasted individually.

**Part A — 11 panels buildable today** from the token log: total requests stat, active-organizations stat, org × client table, requests/hour bars, requests/hour by org (stacked), traffic-concentration pie, top-10 org and top-10 client bar gauges, growth-factor spike detection, org activity status-history, total log volume (ingestion sanity check), and a per-org logs drill-down driven by a textbox variable.

Two worth building first:
- **Traffic concentration pie** — one tenant above ~40% of all traffic is the single most actionable abuse signal available.
- **Growth factor** — current 15m req/min ÷ 6h baseline req/min per org. An org steady at 300/min is not an incident; one that went 250 → 3,000 is. Absolute-volume panels cannot tell those apart.

**Part B — blocked panels with queries pre-written** for the day the gateway emits a structured access log.

**A closing rules section**, paste-able when the assistant proposes a different shape, encoding the lessons from 2026-08-02:

1. `count_over_time([window])`, never `rate(...[$__auto]) * 3600` — the latter extrapolates a micro-burst across a full hour (10 events in a 2-min burst reads as 300/hr instead of 10).
2. **Min interval must equal the range vector.** `[1h]` only sets the lookback; without `Min interval: 1h` Grafana picks its own ~15–20 min step and plots overlapping hourly windows landing on `:15`/`:45`.
3. Unit must match the expression's real dimension — a per-hour count under a `reqpm` unit is wrong by 60× and nothing warns you.
4. Time series + **Draw style: Bars**, not the Bar chart panel (that one is for categorical data).
5. Line filter before parser.
6. Keep `organizationID`/`clientID` as parsed fields, never stream labels.
7. Don't put a threshold in a panel title unless one is configured.

---

## 7. Recommendations, in priority order

1. **Resolve `LOGBACK_APPENDER`** — one kubectl command, and it determines every parser in the prompt file.
2. **Confirm the Prometheus datasource**, then build Dashboard 1, 8 and 9 from metrics. This is the largest amount of dashboard for the least work and requires no code change.
3. **Add the structured 429 log at the gateway** — the single change that unblocks everything still blocked:
   ```
   Rate limit exceeded organizationID=<id>, clientID=<id>, route=<path>,
   method=<verb>, status=429, limitPerSec=<n>, retryAfterSec=<n>
   ```
4. **Build a cross-tenant authorization-failure panel** from the `Org mismatch` warnings. Free, already parseable, and a security signal rather than a capacity one.
5. **Normalise the 22 non-`key=value` org log lines** in `external-api-server` to `organizationID=<value>`. Mechanical change; makes two dozen existing business-operation logs aggregatable per tenant for free.
6. **Log token-request failures** in `Auth0Service` (the `ForbiddenException` path at line 63 and Auth0 rejections) — a client flooding with a bad secret is still invisible.

---

## 8. Open questions

- Is `LOGBACK_APPENDER` set in production? (blocks parser choice)
- Which Grafana datasource fronts Prometheus/Mimir, and what is the service-identifying label?
- Is the production `api-gateway` (image `deklared/api-gateway`) a Spring Cloud Gateway? If so, `spring_cloud_gateway_requests_seconds_count{routeId, outcome, status}` is also available.
- The production gateway repository is **not** checked out locally — `aditya-external-api-api-gateway` is a study project with no git remote. Its rate-limit values are illustrative, not authoritative.
- Are Datadog log pipelines running any Grok parser that already normalises the four org formats? Not checkable from the repo.
