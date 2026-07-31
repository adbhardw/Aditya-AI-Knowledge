# DL/TL Meeting Discussion — DV-13856 Observability Architecture
**Date:** 2026-06-01
**Context:** Pre-DL meeting discussion — TL concern on choke point, industry standard, final schema
**Author:** Aditya Bhardwaj
**Attendees expected:** TL + DL + Ravindra + Jon Chua

---

## TL's Core Concern — The Choke Point Problem

**TL's exact concern (paraphrased):**
"If there are 15 different teams like MI registering callbacks, we have to manage 15 different
endpoints. If something breaks, we have to communicate with all 15 teams. Habu becomes the
choke point for every one of their integrations."

This is a VALID architectural concern. It deserves a precise answer, not a dismissal.

---

## What the Concern Is Actually About

The TL is worried about **operational coupling**, not about being the event source.
There are two distinct risks:

| Risk | What It Means | Is It Real? |
|------|--------------|-------------|
| Habu as canonical source | All event knowledge flows through us | YES — and this is CORRECT. We are the source of truth. |
| Operational choke point | Every team's delivery failure requires Habu intervention | This is the real risk — and it is SOLVABLE by design |

Being the canonical source is not a choke point. It is the product.
The choke point only happens if Habu's on-call is responsible for every consumer's delivery failure.

**The design decision that resolves this:** Consumer isolation + consumer-owned observability.

---

## Industry Standard Answer — How Enterprise Platforms Solve This

We are building a multi-tenant, multi-cloud, vendor-neutral enterprise platform.
These are well-solved problems. The industry standard is a **hybrid pull + push model**.

### Who does this at scale

| Company | Pull API | Push Webhooks | Notes |
|---------|----------|--------------|-------|
| Stripe | Events API (cursor) | Webhooks | Exact same pattern we're proposing |
| GitHub | REST API polling | Webhooks | Same pattern |
| Shopify | REST API | Webhooks | Same pattern, self-service registration portal |
| Salesforce | SOQL polling | Platform Events + Webhooks | Enterprise, multi-tenant |
| Twilio | API | Webhooks | Telecom-grade, same model |

**Every major enterprise API platform provides BOTH pull and push.** Not one or the other.
Different customers need different things:
- Small teams, no server: use the pull API (cursor-based polling)
- Teams with backend infra: use webhooks (true push, sub-second latency)

### The CNCF CloudEvents Standard

For vendor neutrality, the industry uses [CloudEvents](https://cloudevents.io/) — a CNCF specification for event envelopes.

Adopted by:
- Google Cloud (PubSub natively supports CloudEvents)
- Microsoft Azure (EventGrid uses CloudEvents format)
- AWS EventBridge (supports CloudEvents)
- Salesforce, Knative, Serverless.com

**Using CloudEvents means:**
- Our event payloads are cloud-agnostic by specification
- Consumers on GCP, Azure, or AWS all receive the same envelope format
- If we ever want to add a cloud-native delivery channel later (Approach 3), the payload format does not change

---

## How to Resolve the Choke Point Concern — Design Principles

### Principle 1: Self-service registration

Teams register their own endpoint via API or UI. **Zero human involvement from Habu.**

```
POST /cleanrooms/{crId}/callbacks
{
  "callbackUrl": "https://mi-team.liveramp.com/habu-events",
  "objectType": "QUESTION",
  "monitoredFields": ["dimensions", "status"]
}
```

Adding 15 teams = 15 API calls. No Habu engineer is in the loop.

### Principle 2: Per-consumer isolation (the critical one)

Each team gets their **own SQS queue**. Failure of one queue does NOT affect any other.

```
SNS topic: habu-object-events
  → SQS-XMI        (XMI's queue, XMI's DLQ, XMI's CloudWatch alarm)
  → SQS-MI         (MI team's queue, MI's DLQ, MI's alarm)
  → SQS-SafeHaven  (SafeHaven's queue, independent)

If XMI's endpoint goes down for 2 hours:
  → XMI-DLQ fills up → XMI's on-call gets paged
  → MI team is completely unaffected
  → Habu's on-call is NOT paged
```

Adding a new consumer = one `aws sns subscribe` command. Zero code change in unhygienix.
This directly addresses: "we become the choke point."

### Principle 3: Consumer-owned failure responsibility

When XMI's endpoint returns 500:
- Habu retries 3x automatically (1s → 5s → 30s)
- After 3 failures: message goes to SQS-XMI-DLQ
- CloudWatch alarm fires → **XMI's on-call** is paged (not Habu's)
- XMI's team inspects their DLQ, fixes their endpoint, replays messages
- Habu on-call is involved ONLY if the SNS topic itself or the interceptor fails

### Principle 4: Org isolation via JWT (multi-tenancy)

For the pull API (Approach 1), JWT token carries `org_id` claim.
MSFT only sees MSFT events. XMI only sees XMI events.
No per-consumer filtering logic needed in unhygienix — handled at the API layer.

For webhooks (Approach 2), `callback_registrations` is scoped to `cleanroom_id + org_id`.
Events for a different org never match a registration for another org.

---

## Recommended Approach — Hybrid (Industry Standard)

**Ship in phases, but design the foundation right on day one.**

### Phase 1 (V1 — 2 sprints): Pull-based Events API — API-only, no UI (PM decision)

**Two-layer architecture — this is the existing pattern across unhygienix and external-api-server:**

```
Layer 1 — unhygienix (Go, internal gRPC + grpc-gateway REST)
  What gets built:
  ├── object_events table + Liquibase migration (unhygienix DB)
  ├── db/ package: InsertObjectEvent, QueryObjectEvents (by cleanroom + cursor + type)
  ├── New proto message: GetCleanroomObjectEvents.Request / Response
  │   in cleanroom.proto with google.api.http annotation:
  │   get: "/unhygienix/organization/{organizationID}/clean-room/{cleanRoomID}/events"
  ├── api/server/ implementation: func (s *Server) GetCleanroomObjectEvents(...)
  └── Interceptors hooked into existing handlers:
      UpdateCleanRoomQuestion, DeleteCleanRoomQuestion (questions)
      UpdateDataConnection, DeleteDataConnection (data connections)
      — these write to object_events AFTER the mutation, SEPARATE from
        the existing hevent.EventStruct SNS publishes which must NOT be touched

  Internal path (grpc-gateway): /unhygienix/organization/{orgID}/clean-room/{crID}/events
  Also callable as gRPC by external-api-server

Layer 2 — external-api-server (public-facing)
  What gets built:
  └── GET /cleanrooms/{id}/events?since=T&objectType=QUESTION&limit=50
      → calls unhygienix gRPC GetCleanroomObjectEvents internally
      → maps response to CloudEvents JSON format
      → JWT-authenticated (Bearer token carries org_id — auto org-filter)
      → XMI calls this endpoint with cursor

XMI usage:
  GET /cleanrooms/{id}/events?since=2026-06-01T10:00:00Z&objectType=QUESTION
  → returns CloudEvents array
  → XMI stores cursor (last event_time), calls every 60s
  → no server required on XMI side
```

**Key: the existing hevent.EventStruct publishes in unhygienix are for operational
events (triggering picanmix, cronos, etc.) and must NOT be changed.
The observability interceptor is additive — a second, independent write.**

**Who benefits immediately:**
- XMI can adopt the cursor API immediately — no server required on their side
- Same endpoint will power future webhook delivery worker (V2) for event replay
- Foundation is correct for Phase 2

### Phase 2 (V2 — 3-5 sprints on top of V1): Self-service Webhook Delivery

What gets built on top of Phase 1:
- `callback_registrations` table
- Registration CRUD API (POST/GET/PUT/DELETE `/cleanrooms/{id}/callbacks`)
- SNS publish step in V1 interceptors (after writing to object_events)
- Per-consumer SQS queue + delivery worker (Java, horizontally scalable)
- Retry (1s → 5s → 30s) + DLQ per consumer
- Consumer-owned CloudWatch alarm

**Answering TL's choke point:** Adding team MI = one SQS subscription. Habu's on-call
is never paged for MI's delivery failures. Each team owns their own queue health.

---

## The Schema — CloudEvents Aligned, Endpoint-Neutral

This schema handles ALL object types (Question, Data Connection, Export Job, Flow)
in a single table. The `object_type` field discriminates the payload shape of `changed_fields`.

### Database Schema (object_events table — unhygienix DB)

```sql
CREATE TABLE object_events (

    -- CloudEvents envelope fields (vendor-neutral standard)
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    spec_version     VARCHAR(10)  NOT NULL DEFAULT '1.0',
    source           VARCHAR      NOT NULL,
    -- urn:habu:cleanroom:{cleanroom_id}
    type             VARCHAR      NOT NULL,
    -- com.habu.cleanroom.{object_type_lower}.{change_type_lower}
    -- examples:
    --   com.habu.cleanroom.question.updated
    --   com.habu.cleanroom.data_connection.deleted
    --   com.habu.cleanroom.export_job.status_changed

    -- Multi-tenancy (required on every row)
    org_id           UUID         NOT NULL,
    cleanroom_id     UUID         NOT NULL,

    -- Object identification — endpoint-neutral
    object_type      VARCHAR      NOT NULL,
    -- QUESTION | DATA_CONNECTION | EXPORT_JOB | FLOW
    object_id        UUID         NOT NULL,
    object_name      VARCHAR,
    -- name AT TIME OF EVENT — denormalized for display after deletion

    -- Change details
    change_type      VARCHAR      NOT NULL,
    -- CREATED | UPDATED | DELETED | STATUS_CHANGED
    changed_fields   JSONB,
    -- Typed per object_type — see shapes below
    -- NULL for DELETED and CREATED events

    -- Actor
    performed_by      VARCHAR,
    -- user email | "system" | API key name
    performed_by_type VARCHAR      NOT NULL DEFAULT 'USER',
    -- USER | SYSTEM | API_KEY

    -- Versioning + dedup
    schema_version   INT          NOT NULL DEFAULT 1,
    -- Increment when changed_fields JSON shape changes.
    -- Consumers check this to handle backward compat.
    idempotency_key  VARCHAR      UNIQUE,
    -- Prevents duplicate rows if interceptor is called twice on retry.
    -- Format: {object_id}:{change_type}:{event_time_ms}

    -- Timing
    event_time       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Index for cursor-based polling (primary read pattern)
CREATE INDEX idx_object_events_org_cleanroom_time
    ON object_events (org_id, cleanroom_id, event_time DESC);

-- Index for per-object history queries
CREATE INDEX idx_object_events_object_id_time
    ON object_events (object_id, event_time DESC);

-- Index for type-filtered queries
CREATE INDEX idx_object_events_cleanroom_type_time
    ON object_events (cleanroom_id, object_type, event_time DESC);
```

---

### changed_fields JSONB — Typed Shapes Per Object Type

The `changed_fields` field is intentionally polymorphic. Consumers use `object_type`
as a discriminator to determine which shape to parse.

#### QUESTION events

```json
{
  "dimensions": {
    "removed": ["customer_segment", "channel"],
    "added":   [],
    "current": ["revenue", "region", "date"]
  },
  "metrics": {
    "removed": [],
    "added":   ["conversion_rate"],
    "current": ["revenue_sum", "conversion_rate"]
  },
  "datasetAssignments": {
    "old": "Adidas_Purchase_Data_Q1_2025",
    "new": "Adidas_Purchase_Data_Q2_2025"
  },
  "status": {
    "old": "DRAFT",
    "new": "PUBLISHED"
  },
  "name": {
    "old": "Revenue Q1",
    "new": "Revenue Analysis"
  },
  "queryTemplates": {
    "removed": [],
    "added":   ["tmpl-456"],
    "current": ["tmpl-123", "tmpl-456"]
  }
}
```

Notes:
- Any field can be absent if it did not change in this event
- For DELETED events: `changed_fields` is null. `object_name` is preserved.
- For CREATED events: `changed_fields` is null. Use `object_name` + `object_id`.

#### DATA_CONNECTION events

```json
{
  "outputFields": {
    "typeChanges": [
      {
        "fieldName": "purchase_count",
        "oldType":   "INTEGER",
        "newType":   "STRING"
      }
    ],
    "added": [
      { "name": "Shoe_Category", "type": "STRING" }
    ],
    "removed": [
      { "name": "Customer_Email_Id", "type": "STRING" }
    ],
    "current": [
      { "name": "Ramp_ID",       "type": "STRING"  },
      { "name": "Purchase_Date", "type": "DATE"    },
      { "name": "Amount",        "type": "FLOAT"   },
      { "name": "Shoe_Name",     "type": "STRING"  },
      { "name": "Shoe_Category", "type": "STRING"  }
    ]
  },
  "status": {
    "old": "ACTIVE",
    "new": "INACTIVE"
  },
  "name": {
    "old": "Adidas_Purchase_Data_2024",
    "new": "Adidas_Purchase_Data_2025"
  }
}
```

Notes:
- `typeChanges` is a list — multiple fields can change type in one mutation
- `current` is the full current schema snapshot (after mutation)
  — consumers can rebuild their schema cache from a single event

#### EXPORT_JOB events

```json
{
  "status": {
    "old": "RUNNING",
    "new": "COMPLETED"
  },
  "exportScope": {
    "old": "ALL_ROWS",
    "new": "FILTERED"
  },
  "name": {
    "old": "Export v1",
    "new": "Export v2"
  }
}
```

#### FLOW events

```json
{
  "status": {
    "old": "ACTIVE",
    "new": "PAUSED"
  },
  "steps": {
    "removed": ["step-uuid-1"],
    "added":   ["step-uuid-4"],
    "current": ["step-uuid-2", "step-uuid-3", "step-uuid-4"]
  }
}
```

---

### External Event Payload — CloudEvents Envelope (API + Webhook)

The same envelope is used whether the event is served via the pull API
(GET /cleanrooms/{id}/events) or pushed via webhook HTTP POST.
This is the CloudEvents specification — consumers parse it identically regardless of delivery method.

```json
{
  "specversion":      "1.0",
  "id":               "evt-789-uuid",
  "source":           "urn:habu:cleanroom:cr-abc-uuid",
  "type":             "com.habu.cleanroom.question.updated",
  "time":             "2026-05-12T10:32:00Z",
  "datacontenttype":  "application/json",
  "schemaurl":        "https://habu.com/events/schema/cleanroom/v1",
  "data": {
    "orgId":          "org-xyz-uuid",
    "cleanroomId":    "cr-abc-uuid",
    "objectType":     "QUESTION",
    "objectId":       "q-123-uuid",
    "objectName":     "Revenue Analysis",
    "changeType":     "UPDATED",
    "changedFields":  { ... },
    "performedBy":    "sarah@acme.com",
    "performedByType": "USER",
    "schemaVersion":  1
  }
}
```

For DELETED events:
```json
{
  "specversion": "1.0",
  "id":          "evt-790-uuid",
  "source":      "urn:habu:cleanroom:cr-abc-uuid",
  "type":        "com.habu.cleanroom.question.deleted",
  "time":        "2026-05-12T11:00:00Z",
  "data": {
    "orgId":        "org-xyz-uuid",
    "cleanroomId":  "cr-abc-uuid",
    "objectType":   "QUESTION",
    "objectId":     "q-456-uuid",
    "objectName":   "Lookalike Segments",
    "changeType":   "DELETED",
    "changedFields": null,
    "performedBy":  "admin@liveramp.com",
    "schemaVersion": 1
  }
}
```

---

### callback_registrations table (V2)

```sql
CREATE TABLE callback_registrations (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Scope
    cleanroom_id     UUID        NOT NULL,
    org_id           UUID        NOT NULL,
    object_type      VARCHAR     NOT NULL,
    -- QUESTION | DATA_CONNECTION | EXPORT_JOB | ALL
    object_id        UUID,
    -- NULL = all objects of this type in the cleanroom
    -- Specific UUID = only this object

    -- Consumer endpoint
    callback_url     VARCHAR     NOT NULL,
    -- HTTPS required. Habu will POST CloudEvents payload here.
    auth_config      JSONB,
    -- { "authType": "BEARER", "authValue": "encrypted-token" }
    -- { "authType": "API_KEY", "headerName": "X-API-Key", "authValue": "encrypted-key" }
    -- { "authType": "NONE" }  ← rely on HMAC signature only
    signing_secret   VARCHAR,
    -- HMAC-SHA256 secret. Habu generates. Consumer stores. Encrypted at rest.

    -- Field-level filter
    monitored_fields JSONB,
    -- ["dimensions", "status"]  ← only fire if these fields changed
    -- null = fire on any field change

    -- Lifecycle
    active           BOOLEAN     NOT NULL DEFAULT true,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by       VARCHAR,
    updated_at       TIMESTAMPTZ
);

CREATE INDEX idx_callback_reg_cleanroom_type
    ON callback_registrations (cleanroom_id, object_type, active);
```

### delivery_log table (V2)

```sql
CREATE TABLE delivery_log (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id  UUID        NOT NULL REFERENCES callback_registrations(id),
    event_id         UUID        NOT NULL REFERENCES object_events(id),
    attempt_number   INT         NOT NULL,
    http_status      INT,
    -- 200 = success, 500 = server error, null = timeout / connection refused
    response_time_ms INT,
    delivered_at     TIMESTAMPTZ,
    failure_reason   VARCHAR,
    -- "timeout after 10s", "5xx: Internal Server Error", "connection refused"
    UNIQUE (registration_id, event_id, attempt_number)
    -- Prevents duplicate delivery_log rows on worker retry
);

CREATE INDEX idx_delivery_log_registration
    ON delivery_log (registration_id, delivered_at DESC);
```

---

---

## Clarification 1 — Is One object_events Table Industry Standard?

**Yes. This is the established pattern for event/audit log stores.**

The single-table polymorphic approach — one table, `object_type` as discriminator,
typed JSONB in `changed_fields` — is used by:

| Platform | Their Implementation |
|----------|---------------------|
| **Stripe** | Single `events` table. `type` field discriminates (`charge.updated`, `customer.deleted`). `data.object` is polymorphic JSON. Exact same pattern. |
| **AWS CloudTrail** | Single event stream. `eventSource` + `eventName` discriminate. `requestParameters` and `responseElements` are polymorphic per service. |
| **GitHub Audit Log** | Single event stream. `action` field discriminates (`repo.create`, `org.remove_member`). |
| **Datadog Events API** | Single stream, `source_type_name` discriminates. |

**Alternative: separate table per object type** (`question_events`, `data_connection_events`...)
- Pro: DB-level type safety per field
- Con: Separate indexes, separate queries, interceptor logic duplicated per type,
  harder to query "all events for a cleanroom" across types, adding a new object type
  means a new table migration

**Verdict:** Single table is the right call. The JSONB shape is validated at the application
layer (interceptor builds it), not the DB layer. `schema_version` field handles evolution.

---

## Clarification 2 — object_events Does NOT Directly Power Webhook Delivery

**Previous statement was imprecise and needs correction.**

The interceptor does TWO things independently after a mutation:

```
Mutation fires → unhygienix interceptor:
  [1] INSERT INTO object_events  ← in the same DB transaction (V1)
                                    Powers: pull API, future UI, event replay
  [2] sns.publish(eventPayload)  ← post-commit, ~1ms, non-blocking (V2)
                                    Powers: SQS → delivery worker → HTTP POST to callback URL
```

These are **two separate outputs from the same interceptor**, not one powering the other.

```
object_events table  →  GET /events API  →  XMI pulls with cursor
                     →  (V3) event replay endpoint

SNS → SQS → Worker  →  HTTP POST to registered callback URL
                     →  delivery_log table (records each attempt)
```

The delivery worker reads from **SQS**, not from `object_events`.
The only place `object_events` touches the delivery path is:
- **Idempotency check (V2):** worker checks `delivery_log` (linked to `object_events.id`) before POSTing
- **Event replay (V3):** worker re-reads `object_events` rows to re-deliver historical events

The corrected three-table description:

| Table | Powers | When |
|-------|--------|------|
| `object_events` | Pull API (`GET /events`) + future Activity Feed UI + event replay | V1 |
| `callback_registrations` | Delivery worker: which URL to POST, what auth, which fields to filter | V2 |
| `delivery_log` | Per-attempt observability, idempotency dedup, consumer health dashboard | V2 |

SNS/SQS is the delivery backbone — it is NOT stored in any of these tables.
SNS/SQS is infrastructure (AWS), not application state.

---

## Product Direction — No UI in V1 (PM Decision)

**PM's position:** No Activity Feed UI in V1.
Reasons:
- UI will invite feature requests from other teams ("why can't I filter by user?", "add export button")
- Feature flipper management overhead
- Raises questions on why not all event types are captured yet

**Jon Chua in Slack:** "Let's focus on the API first... putting the events in the UI will
require feature flipper management and may raise questions on why all events are not being captured."

**This is the right call for MVP.** Revised delivery:

```
V1 (1-2 sprints): API-only
  - object_events table + CRUD interceptors (Questions + Data Connections)
  - GET /cleanrooms/{id}/events  (cursor API, JWT auth, CloudEvents format)
  - XMI adopts immediately — no server needed on their side
  - No UI. No frontend. Faster to ship. Fewer scope questions.

V2 (3-5 sprints): Webhook delivery
  - callback_registrations table
  - POST /cleanrooms/{id}/callbacks  (self-service registration)
  - SNS publish in interceptors
  - Per-consumer SQS queue + delivery worker + retry + DLQ

V3 (future): UI + hardening
  - Activity Feed tab (if business case justifies it later)
  - DLQ admin UI + one-click replay
  - HMAC + circuit breaker
  - Event replay API
```

---

## Summary Table for TL/DL Presentation

| Concern | Answer |
|---------|--------|
| "15 teams = choke point?" | Self-service API — teams register themselves. No Habu human in the loop. |
| "Something breaks, 15 teams?" | Per-consumer SQS isolation. XMI's DLQ failure pages XMI, not Habu. |
| "Adding team MI?" | One SNS subscription. Zero code change in unhygienix. |
| "MSFT on Azure, XMI on GCP?" | Pull API (REST) + HTTPS webhooks are cloud-agnostic. No per-cloud SDK. |
| "Org isolation?" | JWT org_id claim on pull API. org_id scoped in callback_registrations for push. |
| "Vendor neutral?" | CloudEvents spec. Plain HTTPS. No GCP Pub/Sub SDK, no Azure Service Bus. |
| "Extensible?" | New object type = new interceptor only. Same table, same delivery infra. |
| "Industry standard?" | Stripe (exact same pattern), AWS CloudTrail, GitHub Audit Log. |
| "UI in V1?" | No — PM decision. API-only V1. UI is V3 if justified. |
| "object_events powers webhooks?" | No — interceptor writes to BOTH object_events AND SNS independently. |

## Recommended Pitch to DL (Revised — No UI in V1)

> "The industry standard for multi-tenant enterprise event platforms is a hybrid of pull and push —
> Stripe, GitHub, and Salesforce all ship both.
> V1 is API-only: the cursor events API ships in 1-2 sprints, XMI can adopt immediately
> with no server on their side, no UI scope creep.
> V2 adds self-service webhook delivery where each team owns their own isolated queue and on-call —
> adding team MI costs one SNS subscription and zero code changes in unhygienix.
> The schema follows the CNCF CloudEvents standard — vendor-neutral, cloud-agnostic,
> already adopted by GCP, Azure, and AWS EventBridge.
> This is not a choke point — it is a platform event bus with consumer isolation by design."
