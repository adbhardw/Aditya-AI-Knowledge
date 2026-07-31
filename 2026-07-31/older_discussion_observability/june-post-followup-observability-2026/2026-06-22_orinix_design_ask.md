# orinix — Cleanroom Observability Platform: Design Ask
**Tickets:** DV-13856 (Callback Registration) + DV-15090 (Clean Room Pub/Sub — Internal M1)
**Author:** Aditya Bhardwaj
**Date:** 2026-06-22
**Status:** Draft — for Architect review
**Confluece design (v6):** https://liveramp.atlassian.net/wiki/spaces/~7120200751337419d4448994eb0175e31894fe/pages/5602181406/Observability+Design

---

## Problem

Cleanroom consumers — starting with XMI and expanding to future internal and external partners — have no standardized way to know when objects inside a cleanroom change.

**What changes matter:**
- A Data Connection moves from `MAPPING_REQUIRED` to `CONFIGURATION_COMPLETE`
- A Question's SQL or dimensions are modified
- An Export Job status changes (`RUNNING` → `COMPLETED` / `FAILED`)
- A Flow Run completes (trigger for downstream chaining)

**How consumers find out today:**
- Manual communication (Slack, email, support tickets)
- Polling individual resource REST endpoints with no standardized mechanism

**Result:** Delayed downstream reactions, broken workflows, increased support overhead on the Habu side, and unnecessary API load from polling.

We recently integrated Clean Room with Connect's notification system for **human users** (UI-visible alerts). This ticket is the equivalent for **programmatic consumers**: API users, agents, and internal services that need to react to events automatically.

---

## XMI's Concrete Use Cases (from DV-15090)

These are the confirmed M1 internal use cases from XMI:

### 1. Changes to selected CR Datasets
XMI wants to know when a dataset assigned to a question changes — new dataset, removed dataset, schema change.

### 2. Changes to selected DataConnections
XMI needs to react when a DataConnection status changes (e.g. goes inactive, field schema changes).
This is the highest-frequency real-world trigger today: `stage` changes drive downstream XMI workflows.

### 3. Flow Run state changes
XMI wants to subscribe to `FLOW_RUN` state transitions (`STARTED`, `COMPLETED`, `FAILED`).
This powers the flow chaining use case below.

### 4. Flow Chaining
When Flow 1 run completes → XMI triggers Flow 2. When Flow 2 completes → trigger Flow 3.
Reference: https://miro.com/app/board/uXjVHQBS17Q=/?moveToWidget=3458764674010912645

This requires **low-latency push delivery**. Cursor-based polling at 60s interval is not
acceptable here — XMI needs to react within seconds of a Flow completion.

### 5. Clean Room Onboarding (Quick Start for Partners/Buyers)
Once **all datasets have been assigned** to a given Question, trigger a run automatically.
Reference: https://miro.com/app/board/uXjVHQBS17Q=/?moveToWidget=3458764673465113730

This is a complex event condition: "watch Question q-123, fire when all required dataset
assignments reach `ASSIGNED` state." Requires field-level filtering on QUESTION events.

---

## What We Are Building — orinix

A new dedicated observability service named **orinix**.

**Decision confirmed (post-TLM meeting):** Option B — new dedicated service, not Pegleg routing through unhygienix.
**Precedent:** gangway (RTBF / consumer rights service) — same shape of problem.
gangway is its own service with its own DB and its own gRPC port. Nobody questions it.
Observability is the same: a cross-cutting concern that touches multiple services but belongs to none of them.

### orinix owns end-to-end:

```
orinix/
├── proto/
│   └── events.proto             GetCleanroomEvents, RecordObjectEvent, StreamCleanroomEvents
├── db/
│   └── object_events            append-only event store — orinix DB only
│   └── callback_registrations   webhook registrations (V2)
│   └── delivery_log             per-attempt delivery audit (V2)
├── consumer/
│   └── SqsEventConsumer         reads habu-observability-events SNS → SQS
├── server/
│   └── EventServiceImpl         gRPC server: RecordObjectEvent + GetCleanroomEvents
└── worker/
    └── CallbackDeliveryWorker   HTTP POST to registered consumer URLs (V2)
```

**Scope expansion path:** As observability grows (webhook delivery, delivery logs, circuit breakers,
consumer health dashboards), all of that is absorbed into orinix. unhygienix, forebitt, and
picanmix never grow observability responsibilities.

---

## Event Publishing — hevent Pattern, New Topic

**Confirmed:** A new observability-specific SNS topic, published using the existing hevent mechanism.
The existing `hevent.EventStruct` operational topic (which drives picanmix and cronos) is
**not touched**. Observability is a second, additive publish — same code pattern, separate topic.

```
Topic: habu-observability-events   (new, separate from operational hevent topic)

Publishers:
  unhygienix  → QUESTION events          (create, update, delete)
  forebitt    → DATA_CONNECTION events   (create, update, delete, status change)
  picanmix    → EXPORT_JOB events        (status changes: RUNNING → COMPLETED / FAILED)
  forebitt /
  cronos      → FLOW + FLOW_RUN events   (run started, run completed, run failed) ← NEW per XMI

Each publisher adds ~3 lines post-commit using the existing PublishEventAsyncWithRetry goroutine.
No new AWS services. No synchronous coupling. Mutation returns 200 OK before publish completes.
```

**Why not the same hevent topic:**
The operational topic carries event types that drive picanmix job triggers, cronos scheduling,
and other control-plane flows. orinix subscribing to that topic would receive all operational
events — most of which are not object mutation events. A dedicated observability topic ensures
orinix receives exactly what it needs, and adding new observability event types does not risk
side effects on existing operational consumers.

---

## Event Schema — CNCF CloudEvents v1.0

Every event — regardless of delivery mechanism — is wrapped in the CNCF CloudEvents v1.0 envelope.
This is fixed. It does not change between V1 and V2 or between internal and external delivery.

```json
{
  "specversion":     "1.0",
  "id":              "evt-a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "source":          "urn:habu:cleanroom:cr-abc",
  "type":            "com.habu.cleanroom.data_connection.updated",
  "time":            "2026-06-01T10:32:00Z",
  "datacontenttype": "application/json",
  "data": {
    "objectType":    "DATA_CONNECTION",
    "objectId":      "97b6cf60-f8be-48aa-b7a0-ec112c1fb801",
    "objectName":    "cvs_lcr-modified_txns_hq",
    "changeType":    "UPDATED",
    "changedFields": {
      "stage": { "from": "MAPPING_REQUIRED", "to": "CONFIGURATION_COMPLETE" }
    },
    "performedBy":   "sreekar.s@liveramp.com",
    "schemaVersion": 1
  }
}
```

**One shape for all object types** — `{ "field": { "from": X, "to": Y } }` across QUESTION,
DATA_CONNECTION, EXPORT_JOB, and FLOW. Consumer parses with one loop, zero branching on object type.

**Why CloudEvents:**
- Vendor neutral: GCP Eventarc, Azure Event Grid, AWS EventBridge all consume it natively
- Industry standard: Stripe, GitHub, Salesforce, AWS all use the same envelope
- Delivery-model independent: same payload via pull API, webhook, or cloud-native queue

**Event types in scope:**

| Object Type      | Event Types                                                              | Publisher     |
|------------------|--------------------------------------------------------------------------|---------------|
| QUESTION         | created, updated, deleted                                                | unhygienix    |
| DATA_CONNECTION  | created, updated, deleted, status_changed                                | forebitt      |
| EXPORT_JOB       | created, updated, deleted, run_started, run_completed, run_failed        | picanmix      |
| FLOW             | created, updated, deleted                                                | forebitt      |
| FLOW_RUN         | started, completed, failed                                               | cronos        |

---

## Internal Architecture — orinix

```
unhygienix (QUESTION)
forebitt   (DATA_CONNECTION, FLOW)       → SNS: habu-observability-events (new topic)
picanmix   (EXPORT_JOB)
cronos     (FLOW_RUN)
                    │
                    ▼
         SQS: sqs-habu-observability-internal
                    │
                    ▼
                 orinix
           [1] SQS consumer reads event
           [2] INSERT INTO object_events (orinix DB)
           [3] Serve via gRPC: GetCleanroomEvents / StreamCleanroomEvents
                    │
                    ▼
         external-api-server
           @GrpcClient("orinix") — one new entry, same pattern as unhygienix
                    │
                    ▼
         GET /v1/cleanrooms/{id}/events   (cursor API, external REST)
         AND / OR
         Pub/Sub delivery to XMI         (delivery mechanism — see open question below)
```

**Key design invariants:**
- forebitt never calls unhygienix or orinix directly. SNS is the only integration boundary.
- `object_events` is append-only. DB-level permission: `REVOKE UPDATE, DELETE FROM <app_role>`.
- Org isolation is automatic: external-api-server injects JWT `org_id` claim. No per-consumer config.
- Activity Feed UI (future, V3): calls the same `GetCleanroomEvents` endpoint — one endpoint, two consumers.

---

## object_events Table — orinix DB

```sql
CREATE TABLE object_events (
    id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    spec_version      VARCHAR(10)  NOT NULL DEFAULT '1.0',
    source            VARCHAR      NOT NULL,    -- urn:habu:cleanroom:{cleanroom_id}
    type              VARCHAR      NOT NULL,    -- com.habu.cleanroom.question.updated
    org_id            UUID         NOT NULL,
    cleanroom_id      UUID         NOT NULL,
    object_type       VARCHAR      NOT NULL,    -- QUESTION | DATA_CONNECTION | EXPORT_JOB | FLOW | FLOW_RUN
    object_id         UUID         NOT NULL,
    object_name       VARCHAR,                  -- snapshot at event time (survives deletion)
    change_type       VARCHAR      NOT NULL,    -- CREATED | UPDATED | DELETED | STATUS_CHANGED
    changed_fields    JSONB,                    -- { "field": { "from": X, "to": Y } }
    performed_by      VARCHAR,                  -- user email | "system:<service-name>"
    performed_by_type VARCHAR      NOT NULL DEFAULT 'USER',  -- USER | SYSTEM | API_KEY
    schema_version    INT          NOT NULL DEFAULT 1,
    idempotency_key   VARCHAR      UNIQUE,      -- prevents duplicate rows on interceptor retry
    cursor_position   BIGINT,                   -- monotonic PostgreSQL sequence
    event_time        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_cleanroom_cursor ON object_events (cleanroom_id, cursor_position);
CREATE INDEX idx_events_org_type         ON object_events (org_id, object_type);
CREATE INDEX idx_events_object_id        ON object_events (object_id, event_time DESC);
```

---

## Delivery Mechanism — Open Decision for Architect

This is the key open question. XMI's ask (Flow chaining, quick start) requires **low-latency push delivery**.
They have confirmed they want to consume via **Google Pub/Sub**, not a cursor-based pull API.

Three approaches were analyzed in depth. Summary for Architect:

### Approach 1 — Cursor-Based Pull API
XMI polls `GET /v1/cleanrooms/{id}/events?since=<cursor>` on a schedule.

- XMI confirmed: **does not meet their needs** for Flow chaining (60s polling latency is too slow)
- Still valuable as a complementary interface — keep it in the design for consumers who want it
- Powers the Activity Feed UI (V3)

### Approach 2 — Webhook Push (HTTPS)
orinix delivery worker POSTs CloudEvents payload to XMI's HTTPS endpoint on each mutation.

- Sub-second latency ✓
- XMI must expose an HTTPS Cloud Run endpoint (inbound from Habu)
- XMI said they prefer Pub/Sub — need to confirm if webhook to Cloud Run + internal Pub/Sub fan-out is acceptable
- HMAC-SHA256 signed. SQS-backed per-consumer isolation. Self-service registration.

### Approach 3 — Cloud-Native Queue: SNS → Bridge → GCP Pub/Sub
orinix publishes to SNS → Lambda bridge → GCP Pub/Sub topic that XMI owns.
XMI reads natively from their Pub/Sub subscription. No inbound HTTPS endpoint needed.

**For M1 (internal consumers only):**
- IAM coordination is internal (within LiveRamp) — key rotation can be handled operationally
- XMI is a LiveRamp team — no "external customer manages their server" problem
- Trade-off: Habu must own and maintain the Lambda bridge + GCP credentials

**For M2 (external consumers):**
- Per-cloud bridge = per-cloud engineering project
- MSFT (Azure) → different Lambda, Azure Service Bus SDK, Azure AD auth
- Every new cloud = new bridge

**Current recommendation framing (for discussion):**
- M1 (internal): Approach 3 viable because IAM coordination is internal
- M2 (external): Approach 2 (webhooks) — cloud-agnostic, consumer-owned infra
- In both cases: Approach 1 (pull API) ships first as the foundation

**What XMI actually needs Habu to build for Approach 3 (internal):**
```
SNS: habu-observability-events
           │
           ▼
SQS: sqs-habu-bridge-xmi     (Habu-owned, per consumer)
           │
           ▼
Lambda: habu-to-gcp-pubsub-xmi  (Habu-owned — publishes using google-cloud-pubsub SDK)
           │   HTTPS cross-cloud
           ▼
GCP Pub/Sub: habu-cleanroom-events  (XMI-owned topic, XMI grants Habu publisher IAM)
           │
           ▼
XMI reads natively from their Pub/Sub subscription
```

**Open questions to resolve in Architect meeting:**
See `2026-06-22_delivery_open_questions.md`

---

## Phasing

### M1 — Internal Users (DV-15090 scope, current sprint target)

**What gets built:**
1. orinix service scaffolding (new repo, own DB, own proto, own gRPC port)
2. `object_events` table + Liquibase migration
3. SQS consumer: reads `habu-observability-events` → inserts to `object_events`
4. New SNS topic: `habu-observability-events` (infra/terraform)
5. Publishers in unhygienix, forebitt, picanmix, cronos (hevent pattern, ~3 lines each)
6. `GetCleanroomEvents` gRPC method + external REST `GET /v1/cleanrooms/{id}/events`
7. Delivery to XMI: **TBD based on Architect discussion** (Approach 2 webhook or Approach 3 Pub/Sub bridge)

**Consumers:** XMI (Flow chaining, quick start, DataConnection monitoring)

**Success metrics:**
- XMI can receive DataConnection stage change events within N seconds of mutation
- Flow chaining latency: Flow 1 complete → Flow 2 trigger < 5 seconds
- Decreased polling load on unhygienix REST endpoints

### M2 — External Customers (future)

**What gets added on top of M1:**
1. `callback_registrations` table + self-service registration API (`POST /v1/cleanrooms/{id}/callbacks`)
2. Webhook Delivery Worker (Approach 2) — cloud-agnostic, handles all external consumers
3. HMAC-SHA256 signing on every payload
4. Per-consumer SQS isolation + DLQ + CloudWatch alarm
5. `delivery_log` table — per-attempt audit

**Why webhooks for external (not cloud-native queues):**
External customers are on different clouds. Building a per-cloud bridge (Lambda + SDK per cloud)
multiplies Habu's maintenance burden. HTTPS webhooks are cloud-agnostic: one delivery worker,
every consumer on every cloud, self-service registration, consumer-owned credential rotation.

### V3 — Hardening + UI (future)

- Activity Feed UI tab in topgallant (reads same GetCleanroomEvents endpoint)
- Event replay API
- Circuit breaker + DLQ admin UI
- Per-field subscription precision

---

## Comparison to Connect Notification System

We recently integrated Clean Room with Connect's notification system for human users.
DV-15090 is the programmatic equivalent:

| Dimension          | Connect Notification (human users) | orinix (programmatic consumers)     |
|--------------------|-------------------------------------|-------------------------------------|
| Consumer           | Human via Clean Room UI             | API users, agents, internal services|
| Delivery           | UI notification / email             | Cloud-native queue or webhook push  |
| Latency            | Near real-time                      | Sub-second (push) or 30-60s (pull)  |
| M1 scope           | Already shipped                     | Internal consumers (XMI)            |
| M2 scope           | All users                           | External API customers               |

---

## Measures of Success (DV-15090)

- **Decreased API load from polling:** XMI stops polling individual question/DC endpoints
- **Decreased reaction time:** Flow chaining latency drops from minutes to seconds
- **Incremental decrease in TTGL:** Quick start triggers dataset-assignment completion events
  instead of polling for question readiness

---

## What Is NOT in Scope for M1

- Activity Feed UI (V3 — PM decision, API-first)
- External customer webhook API (M2)
- Event replay (V3)
- HMAC signing (V2/M2 — internal consumers use IAM/service account auth instead)
- Azure Service Bus delivery (M2)
