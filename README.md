# Aditya AI Knowledge

A searchable, long-term engineering knowledge base. Each entry is a self-contained
documentation folder produced during a deep-dive analysis, architecture, or learning
session, preserved exactly as generated.

## How this repository is organised

```
Aditya-AI-Knowledge/
    YYYY-MM-DD/                     <- date the knowledge was published
        <generated-folder>/         <- the session's documentation, preserved as-is
            SUMMARY.md              <- START HERE: 1-2 page executive summary
            README.md               <- folder index
            NN-*.md                 <- the detailed documents
```

## How to use this (for humans and for AI assistants)

Every documentation folder contains a **`SUMMARY.md`**. It is written to be
self-contained: an assistant (Claude, ChatGPT, Gemini, …) should read `SUMMARY.md`
first to understand the whole session, and only open the numbered detail documents
when it needs line-level evidence for a specific claim.

Summaries follow a consistent shape: problem statement → first-principles
explanation → high-level architecture → end-to-end runtime flow → design options →
trade-offs → final recommendation → bugs/root cause → open questions → next steps,
with repository files, classes, methods and line numbers cited where applicable.

Diagrams are Mermaid, inline in the Markdown, so they render directly on GitHub.

---

## Index

Reverse chronological — newest first.

### 2026-08-03

| Folder | Summary |
|---|---|
| [2026-08-03-aditya-grafana-dashboard-prompts-and-telemetry-inventory](2026-08-03/2026-08-03-aditya-grafana-dashboard-prompts-and-telemetry-inventory/) — [SUMMARY](2026-08-03/2026-08-03-aditya-grafana-dashboard-prompts-and-telemetry-inventory/SUMMARY.md) | Paste-ready prompts that make the **Grafana AI chat** build an API tenant-health / abuse dashboard (13 panels), plus a multi-repo telemetry audit that **revises the 2026-08-02 conclusion**: the estate already exports **Prometheus metrics** — 15 dyogram charts ship a ServiceMonitor with metrics enabled, `api-gateway` and `external-api-server` both scraping `/actuator/prometheus` — so requests/sec, 5xx, P95 latency, endpoint breakdown and CPU/memory are buildable **today with no code change**. The architectural crux: **metrics carry status but no tenant, logs carry tenant but no status**, and every still-blocked panel reduces to that one missing join. Of ~25 org-carrying log lines in `external-api-server` (out of 390 total), **only one** uses the `organizationID=` form Datadog auto-facets — the other 22 use space/colon separators or `orgId=`. Surfaces two unused **cross-tenant authorization failure** warnings (`IntelligenceService.java:50,121`). Confirms from live output that production logs are **JSON**, with `requestId`, `logger_name` and `level` as top-level fields — `requestId` being the same correlation key the hank event-design work landed on independently — while `organizationID`/`clientID` stay embedded in `message`, so extraction is two-stage. Also finds that **`organizationID` is already written to the logging MDC** by the auth filters and that LogstashEncoder promotes MDC entries to top-level JSON fields — so tenant attribution may already be solved for authenticated requests; the token endpoint, the only one anyone had examined, is the one place MDC is necessarily empty. Ships a third file: an **implementation plan** for the remaining 429 / 5xx / latency / route telemetry, with the filter-ordering and route-templating traps, cardinality guardrails, rollout order and a verification query per step. Includes a panel-rules appendix encoding the `rate()*3600`, Min-interval and unit-mismatch lessons. **Contains a corrections file**: after reading the real `deklareddotcom/api-gateway` (the earlier analysis had used a local study project), three claims were corrected — per-org 429 attribution was **already available** for quota rejections, the Prometheus collection path is **unproven** (the chart reaching Grafana Cloud does not consume ServiceMonitors and the apps are unannotated), and the path filter's `rate_limit_exceeded` counter was tagged with the **raw URI path**, an unbounded-cardinality bug live in production. Shipped as [api-gateway PR #95](https://github.com/deklareddotcom/api-gateway/pull/95). Also documents that path rate-limit **buckets key on the raw path**, so ID-enumerating clients get a fresh bucket per resource — org quota is the real control. |
| [2026-08-03-aditya-hank-platform-event-design](2026-08-03/2026-08-03-aditya-hank-platform-event-design/) — [SUMMARY](2026-08-03/2026-08-03-aditya-hank-platform-event-design/SUMMARY.md) | **Supersedes the service-layer recommendation.** Anil and Josh decided orinix change events are produced from **Hank's model-layer GORM hooks** (platform-level), not per-handler emit blocks — because the unit of forgetting moves from "every new write path" to "every new resource type". CDC and DB triggers stashed; **from/to dropped** (XMI reads back by resource id). Answers the correlation-key question from source: **`RequestID` already exists and is the only `AuditLog` field stable across the insert/delete/insert of one create** — and beats a transaction id, since the V1 route runs two transactions per request; but `RootObjectType`/`RootObjectID` must be **added**, as identity cannot be derived from per-row fields. Verified blockers: the `if !parsed { return nil }` claims gate silently drops **background-worker events** (i.e. flow-run completion, XMI's main use case), and `gorm:after_create` runs **inside** the transaction with a hook error triggering ROLLBACK — so emit to a transactional **outbox**, never SNS. Explains Fowler's Event Sourcing article, why this is **Event Notification** not event sourcing, and the **replay-re-triggers-flows** hazard. Includes a full source trace of the correlation key: where `requestId` is actually set (`WithTracing` → `WithContextLogger`, in **both** the gRPC and HTTP chains), why `job_service.go:1418` and `:1425` share one despite being two transactions (**they are passed the same `ctx`**), how the audit hook is invoked when *nothing calls it* (**struct embedding + `scope.CallMethod` reflection by name**), and the trap that `GetReqIdCtx` **mints a fresh UUID when it finds none** — which would silently fan one action out into N events on background paths. Now also carries the **architect walkthrough** (28 Q&A, then one create traced click → outbox → relay → SNS → orinix → XMI, the exact `AuditLog` diff, and a 12-row failure table showing why a pod dying after `COMMIT` loses nothing) and the **Phase 1 PR plan** (files, outbox schema, tests, metrics, rollout). Corrects the earlier hook-firing count: the parameter DELETE passes the model **by value** so its pointer-receiver hook never fires — **4** firings per V2 create and **8** per V1 create, not 5 and 10; the phantom-DELETE record described earlier does not exist, and the empty-identity defect is on the **job** delete. |
| [2026-07-31-aditya-c4-architecture-orinix](2026-08-03/2026-07-31-aditya-c4-architecture-orinix/) — [SUMMARY](2026-08-03/2026-07-31-aditya-c4-architecture-orinix/SUMMARY.md) | Review-ready **C4 architecture package** for the orinix change-event platform: 21 validated Mermaid diagrams across L1 context, L2 containers, L3 components (Orinix internals *and* the producer), six runtime flows, and deployment/trust boundaries — plus a **Structurizr DSL** `workspace.dsl` (validated with the Structurizr CLI) for the L2 view. Every element is status-tagged 🟩 built / 🟦 agreed / 🟧 proposed / 🟥 open, so the one undecided arrow is visible at a glance. Note: its **producer-side recommendation predates the 2026-07-30 decision** above; the traced runtime flows, constraints C1–C6 and risk register remain valid. |

### 2026-08-02

| Folder | Summary |
|---|---|
| [2026-08-02-aditya-loki-grafana-datadog-discussion](2026-08-02/2026-08-02-aditya-loki-grafana-datadog-discussion/) — [SUMMARY](2026-08-02/2026-08-02-aditya-loki-grafana-datadog-discussion/SUMMARY.md) | Making **API abuse by organization** visible in Grafana and Datadog for `external-api-server`, so a flooding tenant can be identified and quarantined. Documents the verified queries behind the "Cleanroom Auth Token Abuse Monitor" (Datadog) and "Token Requests by Organization" (Grafana/Loki) dashboards, and resolves an apparent **12× disagreement** between the platforms: root cause is the Grafana panel's `rate(...[$__auto]) * 3600` extrapolating micro-bursts plus a `reqpm` unit on an hourly expression — there is **no** ingestion gap (~73/hr Loki vs ~62/hr Datadog). Also surfaces three structural gaps: `/v1/oauth/token` is **exempt** from gateway rate limiting, the gateway's 429 log is unstructured so "top orgs by 429" cannot be built, and `Auth0Service.java:75` logs only *successful* token requests — failed-auth floods are invisible. Covers Loki-label-vs-Datadog-facet cardinality, when blacklisting is actually justified, and why enforcement must stay outside both tools. |

### 2026-07-31

| Folder | Summary |
|---|---|
| [2026-07-30-aditya-architect-followup](2026-07-31/2026-07-30-aditya-architect-followup/) — [SUMMARY](2026-07-31/2026-07-30-aditya-architect-followup/SUMMARY.md) | orinix event production for the XMI partner notification pipeline (DV-13856 / DV-15090 / DV-15091): should change events be emitted from the **service layer** or from **Hank's automatic row hooks**, **change data capture**, or **database triggers**? Traces one Data Connection create end to end (5 row writes across 2 tables, 5 hook firings via the V2 route and 10 via V1), scores five options against seven requirements, and recommends service-layer emission with Level 1 detail for state transitions and Level 2 for create/update/delete. Also surfaces a pre-existing audit-log bug: delete records carry an empty `ObjectID`. |
| [older_discussion_observability](2026-07-31/older_discussion_observability/) — [SUMMARY](2026-07-31/older_discussion_observability/SUMMARY.md) | The full working archive behind the orinix observability design — 106 files spanning **May–July 2026**: meeting notes, Q&A transcripts, design iterations, Confluence drafts, Miro prompts, presentations and schema examples. Covers webhook/queue and DLQ design, `object_events` schema and ownership, SNS/SQS and Pub/Sub delivery, the Java-vs-Go language decision, orinix↔XMI auth (CAC, nexus, JWKS), the audit-log expansion for Josh and Jon, and PR 1. The `SUMMARY.md` is a navigational index organised by question, not a re-analysis. |