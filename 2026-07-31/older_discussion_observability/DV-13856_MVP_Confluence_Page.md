# Clean Room Observability & Callback Registration — MVP Design
**Ticket:** DV-13856 | **Parent Initiative:** CFI-1388 — "Clean Rooms Feel Like Enterprise Software" (FY27Q1)
**Author:** Aditya Bhardwaj | **Date:** 2026-05-10
**Status:** Proposal — For TLM + Product Review

---

## 1. Problem Statement

Clean room objects — **Questions**, **Data Connections**, **Export Jobs**, **Flows** — live inside the Habu platform. External systems (XMI UI, customer integrations) hold references to those objects. When state changes (a question's output columns are removed, a data connection's field type flips, an object is deleted), those external references go silently stale.

Today, external systems use **polling** to detect changes: they call `GET /cleanrooms/{id}/questions` every N seconds and compare the response. There is no notification mechanism. This affects three object types:

- **Questions** — when output columns are removed, a dataset is swapped, or a question is deleted, XMI UI has no way to know until its next poll. Downstream dashboards break silently.
- **Data Connections** — when a field type changes or a field is added/removed, SQL queries and pipelines fail at runtime with no prior warning to the teams that depend on the schema.
- **Exports** — export configuration changes and run completions are invisible to integrations. External systems must poll repeatedly to detect status.

**Two audiences have different needs:**

| Audience | Need | MVP Shape |
|----------|------|-----------|
| **Human users** on the Habu platform | "What changed in my clean room, when, and who did it?" | **Activity Feed UI** |
| **Programmatic systems** (XMI UI, customer integrations) | Automatically react when an object changes | **Webhook / Callback delivery** |

---

## 2. Scope of Changes We Are Tracking

Based on analysis of real change scenarios, the following object mutations are in scope for V1 and V2:

### Questions
| Change Type | Example | Why It Matters to External Systems |
|------------|---------|-------------------------------------|
| Output columns removed | `[revenue, region, date, segment, channel]` → `[revenue, region, date]` | Dashboards built expecting 5 columns silently break |
| Dataset assignment swapped | Question switched from `Q1_Sales_2026` to `Q2_Sales_2026` | External system schedules imports for the wrong dataset |
| Status changed | `DRAFT` → `PUBLISHED` or `PAUSED` | External system may need to trigger downstream workflows |
| Question renamed | `"Revenue Analysis"` → `"Revenue Analysis v2"` | UI labels and cached references go stale |
| Question deleted | Object removed entirely | External links return 404; downstream workflows fail |

### Data Connections
| Change Type | Example | Why It Matters |
|------------|---------|----------------|
| Field type changed | `purchase_count: Integer` → `purchase_count: String` | SQL like `SUM(purchase_count)` fails at runtime; UI filters break |
| Field added/removed | New output column added or an existing one removed | Downstream schema expectations are violated |
| Data connection deleted | Object removed entirely | Any question or workflow referencing this DC fails |

---

## 3. MVP Architecture — Two-Phase Delivery

### The Shared Foundation: Interceptor + Event Log

Both the UI and the webhook delivery are powered by one correctly-built component: an **interceptor** that writes to an `object_events` table on every create/update/delete.

```
Every CRUD mutation in unhygienix:
  ┌──────────────────────────────────────────────────────┐
  │  func DeleteQuestion(id) {                           │
  │      before = loadQuestion(id)    // snapshot state  │
  │      doDelete(id)                 // actual delete   │
  │      event = buildEvent("DELETED", before, nil)      │
  │      objectEventsRepo.insert(event)  ← V1: UI feed  │
  │      if callbacksExist(id):                         │
  │          sns.publish(event)          ← V2: webhooks  │
  │  }                                                   │
  └──────────────────────────────────────────────────────┘
```

Build the interceptor once. V1 uses only the DB write. V2 adds the SNS publish on top of V1.

### Event Store Schema (unhygienix database)

```sql
CREATE TABLE object_events (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cleanroom_id   UUID NOT NULL,
    object_type    VARCHAR NOT NULL,   -- QUESTION, DATA_CONNECTION, EXPORT_JOB, FLOW
    object_id      UUID NOT NULL,
    object_name    VARCHAR,            -- name at time of event (denormalized for display)
    event_type     VARCHAR NOT NULL,   -- CREATED, UPDATED, DELETED, STATUS_CHANGED
    changed_fields JSONB,              -- { "dimensions": {"old": [...], "new": [...]} }
    performed_by   VARCHAR,            -- user email or "system"
    org_id         UUID NOT NULL,
    event_time     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_object_events_cleanroom_time
    ON object_events (cleanroom_id, event_time DESC);
```

Every mutation writes here **before returning**. This is the single source of truth for both the UI and the webhook worker.

---

## 4. V1 — Activity Feed UI (2 Sprints)

### What the Customer Sees

An **"Activity" tab** inside the Clean Room UI. A chronological, filterable feed of every change that happened to any object within that clean room.

```
┌─────────────────────────────────────────────────────────────────┐
│  Clean Room: Acme Corp x LiveRamp Q1 2026                       │
│  [Overview]  [Questions]  [Data Connections]  [Activity ▼]      │
├─────────────────────────────────────────────────────────────────┤
│  Filter by: [All Types ▼]  [All Users ▼]  [Last 30 days ▼]     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ● 2026-05-09 14:32  sarah@acme.com                            │
│    QUESTION "Revenue Analysis" — columns removed                │
│    Removed: customer_segment, channel                           │
│    Remaining: revenue, region, date                             │
│                                                                 │
│  ● 2026-05-09 11:15  john@acme.com                             │
│    DATA CONNECTION "CRM_Import" — field type changed            │
│    purchase_count: Integer → String                             │
│                                                                 │
│  ● 2026-05-08 09:00  sarah@acme.com                            │
│    QUESTION "Attribution Model" — dataset swapped               │
│    Was: Q1_Sales_2026  →  Now: Q2_Sales_2026                   │
│                                                                 │
│  ● 2026-05-07 16:45  admin@liveramp.com                        │
│    QUESTION "Lookalike Segments" — DELETED                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### What Gets Built in V1

| Component | What It Is | Service |
|-----------|-----------|---------|
| `object_events` table | Append-only event store (schema above) | unhygienix DB |
| Interceptors | Before/after hooks on every CRUD method for Questions + Data Connections | unhygienix |
| Field differ | Snapshots before state, computes diff, writes JSONB to `changed_fields` | unhygienix |
| Read API | `GET /cleanrooms/{id}/events?since=T&objectType=QUESTION` | external-api-server |
| Activity Feed UI | Tab in clean room UI rendering the event feed, with filters | Frontend |

### V1 Read API Response (also usable by XMI as a polling-upgrade)

```json
GET /cleanrooms/{id}/events?since=2026-05-08T00:00:00Z&objectType=QUESTION

[
  {
    "event": "UPDATED",
    "objectId": "q-123",
    "objectType": "QUESTION",
    "objectName": "Revenue Analysis",
    "changedFields": {
      "dimensions": {
        "removed": ["customer_segment", "channel"],
        "current": ["revenue", "region", "date"]
      }
    },
    "performedBy": "sarah@acme.com",
    "timestamp": "2026-05-09T14:32:00Z"
  },
  {
    "event": "DELETED",
    "objectId": "q-456",
    "objectType": "QUESTION",
    "objectName": "Lookalike Segments",
    "performedBy": "admin@liveramp.com",
    "timestamp": "2026-05-07T16:45:00Z"
  }
]
```

> **Note:** This cursor-based polling API (Pattern B) is a viable near-term integration path for XMI UI — it is far better than object-level polling and does not require XMI to maintain a webhook server.

### V1 Value Delivered

- Every user on the platform immediately benefits — no setup required
- Answers "what happened to my question?" without filing a support ticket
- Directly serves the CFI-1388 OKR: audit history is table-stakes enterprise software behavior
- Interceptors built correctly in V1 become the foundation for V2 webhooks

---

## 5. V2 — Webhook / Callback Delivery to Customer Endpoint (2–3 Sprints on top of V1)

### What the Customer Gets

For programmatic consumers (XMI UI and future enterprise customers), the ability to register an HTTP endpoint that Habu calls whenever a monitored object changes — **no polling required**.

### Registration Flow

```
POST /cleanrooms/{crId}/callbacks
{
  "objectType": "QUESTION",
  "objectId": "q-123-abc",
  "callbackUrl": "https://xmi-ui.internal.liveramp.com/webhooks/habu",
  "monitoredFields": ["dimensions", "metrics", "datasetAssignments", "status"],
  "authConfig": {
    "authType": "BEARER",
    "authValue": "eyJhbGciOiJSUzI1..."
  }
}

Response:
{
  "id": "cb-456-def",
  "objectType": "QUESTION",
  "objectId": "q-123-abc",
  "callbackUrl": "https://xmi-ui.internal.liveramp.com/webhooks/habu",
  "createdAt": "2026-05-10T10:00:00Z"
}
```

### Event Delivery — What XMI Receives

**Scenario A: Columns removed from question**

```
POST https://xmi-ui.internal.liveramp.com/webhooks/habu
Authorization: Bearer eyJhbGciOiJSUzI1...
Content-Type: application/json

{
  "eventType": "FIELD_CHANGED",
  "registrationId": "cb-456-def",
  "objectType": "QUESTION",
  "objectId": "q-123-abc",
  "objectName": "Revenue Analysis",
  "cleanroomId": "cr-abc",
  "changedFields": {
    "dimensions": {
      "removed": ["customer_segment", "channel"],
      "current": ["revenue", "region", "date"]
    }
  },
  "changedBy": "sarah@acme.com",
  "eventTime": "2026-05-09T14:32:00Z"
}
```

**Scenario B: Data connection field type changed**

```
POST https://xmi-ui.internal.liveramp.com/webhooks/habu
Authorization: Bearer eyJhbGciOiJSUzI1...

{
  "eventType": "FIELD_CHANGED",
  "objectType": "DATA_CONNECTION",
  "objectId": "dc-456",
  "objectName": "CRM_Import",
  "changedFields": {
    "outputFields": {
      "purchase_count": {
        "oldType": "Integer",
        "newType": "String"
      }
    }
  },
  "changedBy": "john@acme.com",
  "eventTime": "2026-05-09T11:15:00Z"
}
```

**Scenario C: Question deleted**

```
POST https://xmi-ui.internal.liveramp.com/webhooks/habu
Authorization: Bearer eyJhbGciOiJSUzI1...

{
  "eventType": "DELETED",
  "objectType": "QUESTION",
  "objectId": "q-789",
  "objectName": "Lookalike Segments",
  "cleanroomId": "cr-abc",
  "deletedBy": "admin@liveramp.com",
  "eventTime": "2026-05-07T16:45:00Z"
}
```

### V2 Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         HABU PLATFORM                               │
│                                                                     │
│  User Action (delete/update)                                        │
│       │                                                             │
│       ▼                                                             │
│  ┌──────────────────────────────────────┐                           │
│  │  unhygienix — CRUD Interceptor       │                           │
│  │  1. Snapshot before state            │                           │
│  │  2. Execute mutation                 │                           │
│  │  3. Diff before/after                │                           │
│  │  4. Write to object_events (V1)      │                           │
│  │  5. Check callback_registrations     │                           │
│  │  6. If match: publish to SNS (~1ms)  │ ← non-blocking            │
│  └──────────────────┬───────────────────┘                           │
│                     │ ← 200 OK returned to user immediately         │
│                     │                                               │
│                     ▼                                               │
│  ┌──────────────────────────────────────┐                           │
│  │  SNS Topic → SQS Queue               │                           │
│  │  (buffer + at-least-once delivery)   │                           │
│  └──────────────────┬───────────────────┘                           │
│                     │                                               │
│                     ▼                                               │
│  ┌──────────────────────────────────────┐                           │
│  │  Callback Delivery Worker            │                           │
│  │  • Reads from SQS                    │                           │
│  │  • Looks up registration (URL, auth) │                           │
│  │  • HTTP POST to callback URL         │                           │
│  │  • Retry: 1s → 5s → 30s backoff     │                           │
│  │  • After 3 failures: → DLQ           │                           │
│  └──────────────────────────────────────┘                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
         │
         ▼
 ┌─────────────────────────┐
 │  XMI UI / Customer      │
 │  Webhook Endpoint       │
 │  POST /webhooks/habu    │
 │                         │
 │  Receives event →       │
 │  • Refresh UI           │
 │  • Update cache         │
 │  • Trigger workflow     │
 └─────────────────────────┘
```

### What Gets Built in V2

| Component | What It Is | Service |
|-----------|-----------|---------|
| `callback_registrations` table | Stores (objectId, objectType, callbackUrl, monitoredFields, authConfig) | unhygienix DB |
| Registration CRUD endpoints | POST/GET/PUT/DELETE `/cleanrooms/{id}/callbacks` | external-api-server |
| SNS publish in interceptors | After writing to `object_events`, also publish to SNS if callbacks registered | unhygienix |
| Callback delivery worker | Reads from SQS, builds HTTP payload, POSTs with auth, handles retry + DLQ | New service (or extend postaldistrix) |
| Delivery status in UI | Green/red status per registered callback visible in Activity tab | Frontend |

---

## 6. V3 — Production Hardening (1–2 Sprints, post-V2)

For enterprise and large-scale external customers:

| Feature | Purpose |
|---------|---------|
| HMAC signature on every payload | Receiver can cryptographically verify the request is genuinely from Habu |
| Dead Letter Queue visibility | Admins can see and replay failed deliveries in the UI |
| Event replay API | "Re-deliver all events for object X from date Y" |
| Per-field subscription enforcement | Only fire callback if *specifically monitored* fields changed (not just any field) |
| Webhook testing endpoint | `POST /callbacks/{id}/test` sends a synthetic event to validate the endpoint is reachable |

---

## 7. Delivery Roadmap

```
Sprint 1–2 (V1):  Activity Feed UI
═══════════════════════════════════════════════════════════
├── Design: object_events schema + interceptor pattern
├── Build: CRUD interceptors for Questions + Data Connections in unhygienix
├── Build: field differ (before/after snapshot, JSONB diff)
├── Build: GET /cleanrooms/{id}/events read API (external-api-server)
└── Build: Activity tab UI with filters (Frontend)

Sprint 3–5 (V2):  Webhook / Callback Delivery
═══════════════════════════════════════════════════════════
├── Build: callback_registrations table + proto definitions (ignoramus)
├── Build: Registration CRUD endpoints (external-api-server)
├── Build: SNS publish step in V1 interceptors (unhygienix)
├── Build: SQS consumer / callback delivery worker
├── Build: Retry logic + DLQ
└── Build: Delivery status view in UI

Sprint 6–7 (V3):  Production Hardening
═══════════════════════════════════════════════════════════
├── HMAC signature verification
├── DLQ admin visibility + replay
├── Event replay API
└── Webhook test endpoint
```

---

## 8. Object Types In Scope

| Object Type | V1 (Activity Feed) | V2 (Webhooks) | Fields to Diff |
|-------------|--------------------|--------------|-----------------|
| **QUESTION** | ✅ Sprint 1–2 | ✅ Sprint 3–5 | dimensions, metrics, queryTemplates, datasetAssignments, status, name |
| **DATA_CONNECTION** | ✅ Sprint 1–2 | ✅ Sprint 3–5 | outputFields (name, type), status, name |
| **EXPORT_JOB** | ✅ Sprint 1–2 | Sprint 6+ | status, exportScope |
| **FLOW** | Sprint 2+ | Sprint 6+ | status, steps |

---

## 9. Decision Points for TLM + Product

| # | Question | Recommendation | Options |
|---|---------|----------------|---------|
| 1 | **Which object types in V1 scope?** | Questions + Data Connections first (highest customer pain) | All object types from day one (more work) |
| 2 | **Is XMI UI the only webhook consumer today?** | Assume yes — but design API generically | Confirm with Solutions team |
| 3 | **Activity Feed scope** | Per-clean-room | Per-org across all clean rooms (larger scope) |
| 4 | **Event retention** | 90 days (configurable) | 1 year (storage + index cost) |
| 5 | **Delivery infrastructure** | SNS + SQS (already in platform) | EventBridge (cleaner but net-new AWS service) |
| 6 | **Who owns callback delivery service?** | Extend postaldistrix | New dedicated service |

---

## 10. Why This Approach — Key Design Principles

**Single interceptor, two consumers.** The `object_events` table write (for V1 UI) and the SNS publish (for V2 webhooks) both attach to the same interceptor. We do not build two separate change-detection systems.

**Async delivery is non-negotiable.** The callback POST to an external URL happens asynchronously (via SNS → SQS → worker), never inline with the user's operation. This means: user's delete completes in ~50ms regardless of whether XMI's webhook server is slow, down, or returning 500.

**V1 read API is a viable XMI migration path.** The `GET /cleanrooms/{id}/events?since=T` cursor API from V1 is already a significant improvement over object-level polling. XMI UI can adopt it immediately and get field-level change detail without needing a webhook server.

**Ship V1 first.** Two sprints to deliver value to every user on the platform. No delivery infrastructure risk. Interceptors built correctly in V1 are the correct foundation for V2.

---

## 11. Key Repositories

| Repository | V1 Role | V2 Role |
|-----------|---------|---------|
| **unhygienix** | `object_events` table, interceptors, field differ | `callback_registrations` table, SNS publish |
| **external-api-server** | `GET /cleanrooms/{id}/events` read endpoint | Callback CRUD endpoints |
| **ignoramus** | — | Proto definitions: `CallbackRegistration`, `CallbackEvent`, `CallbackAuthConfig` |
| **postaldistrix** | — | Extend for webhook HTTP delivery worker (or new service) |
| **Frontend** | Activity Feed UI tab | Webhook registration UI, delivery status |
| **picanmix** | — | Extend SNS infrastructure if reused |

---

## 12. Open Questions

1. Is XMI UI the only programmatic consumer today, or are there external enterprise customers who also need webhooks?
2. Does unhygienix have a consistent update/delete path per object type, or is it scattered across services? (This affects interceptor placement difficulty.)
3. Retention policy: how long do we keep rows in `object_events`? 90 days? 1 year?
4. Do callback registrations expire, or do they live forever until explicitly deleted?
5. Rate limiting: if a question is updated 100 times in a minute (bulk migration scenario), do we batch events or send 100 callbacks?

---

## V2 Summary — Webhook Callback Delivery

V2 adds **push-based notification** for programmatic consumers (XMI UI, customer integrations). Once a callback URL is registered via `POST /cleanrooms/{id}/callbacks`, Habu automatically calls that URL whenever a monitored object changes — sending the object name, the type of change, who made it, and when.

**Key properties of V2 delivery:**
- **Non-blocking** — the callback POST happens async (SNS → SQS → worker); user's operation returns in ~50ms regardless of whether the external endpoint is slow or down
- **Retry with backoff** — failed deliveries retry at 1s → 5s → 30s before going to Dead Letter Queue
- **Auth support** — Bearer token, API key, or basic auth attached to every outbound request
- **Built on V1** — the same interceptor that writes to `object_events` (V1) also publishes to SNS (V2); no duplicate change-detection logic

**Flow:** Register URL → object changes in Habu → SNS topic → SQS queue → delivery worker → HTTP POST to XMI endpoint → XMI reacts (refresh UI / update cache / trigger workflow)

**Note on XMI near-term path:** V1's cursor API (`GET /cleanrooms/{id}/events?since=T`) is a viable first step for XMI — no webhook server required on XMI's side. V2 webhooks are the long-term push model.

---

## References

- **DV-13856**: Callback Registration Tool — Jon Chua, 2026-03-11
- **CFI-1388**: Clean Rooms Feel Like Enterprise Software (FY27Q1)
- **DV-13789**: Better Ingestion Observability (related — same interceptor pattern)
- **DV-13837**: Export Non-Report Clean Compute Files (related — picanmix SNS infrastructure)
- Design notes: `aditya_callback_registration/2026-03-26_concrete_examples_and_delivery_options.md`
- Design notes: `aditya_observability_discussion/DV-13856_Observability_Design_Discussion.md`
