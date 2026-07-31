# DV-13856 — Version Evolution: Tables, APIs, Services, Infra
**Date:** 2026-05-12
**Purpose:** Complete inventory of what gets built in each version — tables, APIs, services, infra, UI

---

## Overview

| Version | Theme | Sprints | Who benefits |
|---------|-------|---------|--------------|
| V1 | Activity Feed UI — human audit trail | 1–2 | Every user on Habu platform |
| V2 | Webhook Callback Delivery — programmatic push | 3–5 | XMI UI, SafeHaven, external integrations |
| V3 | Production Hardening — enterprise-grade | 6–7 | Ops team, large-scale enterprise customers |

---

## V1 — Activity Feed UI (Sprints 1–2)

### What V1 solves
Users cannot answer "what changed in my cleanroom, when, and who did it?" without filing
a support ticket. V1 adds an audit trail that every user benefits from immediately — no setup.

### New Tables (V1)

#### object_events — the only new table in V1

```sql
CREATE TABLE object_events (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cleanroom_id   UUID NOT NULL,
    org_id         UUID NOT NULL,
    object_type    VARCHAR NOT NULL,   -- QUESTION, DATA_CONNECTION, EXPORT_JOB, FLOW
    object_id      UUID NOT NULL,
    object_name    VARCHAR,            -- name at time of event (denormalized for display)
    event_type     VARCHAR NOT NULL,   -- CREATED, UPDATED, DELETED, STATUS_CHANGED
    changed_fields JSONB,              -- { "dimensions": { "removed": [...], "current": [...] } }
    performed_by   VARCHAR,            -- user email or "system"
    event_time     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_object_events_cleanroom_time
    ON object_events (cleanroom_id, event_time DESC);
```

Written to synchronously inside the DB transaction that executes the mutation.
If the mutation rolls back, the event row rolls back too — fully atomic.

### New APIs (V1)

| Method | Path | Service | Purpose |
|--------|------|---------|---------|
| GET | /cleanrooms/{crId}/events | external-api-server | Read activity feed — filterable by objectType, since timestamp, performedBy |

**Response shape:**
```json
[
  {
    "eventId": "evt-789",
    "objectType": "QUESTION",
    "objectId": "q-123",
    "objectName": "Revenue Analysis",
    "eventType": "UPDATED",
    "changedFields": {
      "dimensions": { "removed": ["customer_segment"], "current": ["revenue", "region"] }
    },
    "performedBy": "sarah@acme.com",
    "eventTime": "2026-05-12T10:32:00Z"
  }
]
```

This API is also usable by XMI as a cursor-based polling upgrade (GET /events?since=T)
without needing a webhook server on XMI's side.

### New Code (V1)

| Component | Service | What it does |
|-----------|---------|-------------|
| CRUD interceptors | unhygienix | Before/after hooks on Question + Data Connection mutations |
| Field differ | unhygienix | Snapshots state before mutation, computes JSONB diff, writes changed_fields |
| Activity Feed UI tab | Frontend | New tab in clean room UI — chronological event list with filters |

### No new infra in V1 — only DB migration + code changes.

---

## V2 — Webhook Callback Delivery (Sprints 3–5, builds on V1)

### What V2 solves
XMI UI cannot react to changes instantly — it polls. V2 lets any programmatic consumer
register an HTTP endpoint. Habu calls that endpoint automatically when a monitored object changes.

### New Tables (V2) — two new tables

#### callback_registrations — stores who wants to be notified and where

```sql
CREATE TABLE callback_registrations (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cleanroom_id     UUID NOT NULL,
    org_id           UUID NOT NULL,
    object_type      VARCHAR NOT NULL,   -- QUESTION, DATA_CONNECTION, ALL
    object_id        UUID,               -- NULL = all objects of this type in cleanroom
    callback_url     VARCHAR NOT NULL,   -- https://xmi.liveramp.com/habu-events
    auth_config      JSONB,              -- { authType: BEARER, authValue: encrypted }
    signing_secret   VARCHAR,            -- HMAC secret, encrypted at rest
    monitored_fields JSONB,              -- ["dimensions", "status", "name"]
    active           BOOLEAN DEFAULT true,
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    updated_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_callback_reg_cleanroom_type
    ON callback_registrations (cleanroom_id, object_type, active);
```

**Granularity:** cleanroom-level per object type.
XMI registers once per cleanroom — covers all questions/DCs in that cleanroom.
`object_id = NULL` means "all objects of this type."

#### delivery_log — records every HTTP delivery attempt

```sql
CREATE TABLE delivery_log (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id   UUID NOT NULL REFERENCES callback_registrations(id),
    event_id          UUID NOT NULL,        -- references object_events.id
    attempt_number    INT NOT NULL,         -- 1, 2, 3
    http_status       INT,                  -- 200, 500, null on timeout
    response_time_ms  INT,
    delivered_at      TIMESTAMPTZ,          -- null = not yet delivered
    failure_reason    VARCHAR,              -- "timeout", "500 Internal Server Error"
    payload_hash      VARCHAR,              -- SHA256 of sent JSON body
    created_at        TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (registration_id, event_id, attempt_number)
);

CREATE INDEX idx_delivery_log_reg_event
    ON delivery_log (registration_id, event_id);
```

**Purpose:** powers idempotency check (already delivered?), powers V3 Webhooks UI,
enables ops to answer "was evt-789 delivered to XMI?"

### New APIs (V2)

| Method | Path | Service | Purpose |
|--------|------|---------|---------|
| POST | /cleanrooms/{crId}/callbacks | external-api-server | Register new callback URL |
| GET | /cleanrooms/{crId}/callbacks | external-api-server | List all registrations for a cleanroom |
| PUT | /cleanrooms/{crId}/callbacks/{cbId} | external-api-server | Update callback URL or auth |
| DELETE | /cleanrooms/{crId}/callbacks/{cbId} | external-api-server | Deregister a callback |

### New Services (V2)

#### Callback Delivery Worker (Java)
New service — or extended postaldistrix (existing notification service).

Responsibilities:
1. Poll SQS queue for new event messages
2. Query callback_registrations to find matching registered URLs
3. Build JSON event payload
4. Compute HMAC-SHA256 signature (X-Habu-Signature header)
5. Check circuit breaker state for target endpoint
6. HTTP POST to registered callback URL
7. Write result to delivery_log (before ACKing SQS)
8. ACK SQS (deleteMessage) on success
9. On failure: SQS visibility timeout handles retry (3 attempts → DLQ)

### New Infra (V2)

| Component | Type | Purpose |
|-----------|------|---------|
| SNS Topic: habu-object-events | AWS SNS | Fan-out backbone — receives events from unhygienix interceptors |
| SQS-XMI-Delivery | AWS SQS | XMI's delivery queue — independent of other consumers |
| SQS-XMI-Delivery-DLQ | AWS SQS | Dead letter queue for XMI — receives messages after 3 failed attempts |
| SQS-SafeHaven-Delivery | AWS SQS | SafeHaven's delivery queue (future) |
| SQS-SafeHaven-Delivery-DLQ | AWS SQS | DLQ for SafeHaven |
| CloudWatch Alarm | AWS CloudWatch | Alert when DLQ depth > 0 → PagerDuty/Slack |

**DLQ is automatic — no app code.** Configure `maxReceiveCount=3` + `deadLetterTargetArn`
on each delivery queue. AWS moves messages to DLQ after 3 failed receive cycles.

### Changes to Existing Code (V2)

| Service | Change |
|---------|--------|
| unhygienix interceptors (built in V1) | Add SNS publish after transaction commits |
| ignoramus (proto definitions) | Add CallbackRegistration, CallbackEvent, CallbackAuthConfig protos |

---

## V3 — Production Hardening (Sprints 6–7)

### What V3 solves
Enterprise customers need: verified signatures, replay capability, webhook testing,
and ops visibility into delivery health — all table-stakes for a production integration.

### No new tables in V3 — extends existing ones.

delivery_log already captures what V3 UI needs.
object_events already stores what event replay needs.

### New APIs (V3)

| Method | Path | Service | Purpose |
|--------|------|---------|---------|
| POST | /cleanrooms/{crId}/callbacks/{cbId}/test | external-api-server | Send synthetic test event to registered URL |
| POST | /admin/callbacks/{cbId}/replay-dlq | external-api-server | Replay all DLQ messages for a registration |
| GET | /cleanrooms/{crId}/events/{eventId}/replay | external-api-server | Re-deliver a specific event to all registered callbacks |

### New UI (V3)

#### Webhooks tab in clean room UI
New tab added to existing clean room page (alongside Overview, Questions, Data Connections, Activity).

Panels:
- Registered callbacks list — URL, object type, status (healthy/degraded)
- Per-registration delivery health — success rate, last delivered, avg latency
- DLQ panel — list of failed messages with Replay button per message
- Delivery timeline — last 50 delivery attempts per registration

### New Code (V3)

| Component | Service | What it does |
|-----------|---------|-------------|
| HMAC signature verification | Delivery worker | Compute X-Habu-Signature header on every POST |
| Circuit breaker | Delivery worker (Resilience4j) | Stop calling endpoint after N failures; CLOSED → OPEN → HALF-OPEN |
| Per-field subscription filter | Delivery worker | Only fire callback if monitored_fields changed (not just any field) |
| DLQ replay backend | external-api-server | Move messages from DLQ back to main SQS queue via AWS start-message-move-task |

---

## Complete Table Inventory

| Table | Version | Service / DB | New or Existing |
|-------|---------|--------------|-----------------|
| object_events | V1 | unhygienix DB | NEW |
| callback_registrations | V2 | unhygienix DB | NEW |
| delivery_log | V2 | unhygienix DB (or worker DB) | NEW |

**Total: 3 new tables across V1 + V2. V3 adds no new tables.**

---

## Complete API Inventory

| Version | Method | Path | Service |
|---------|--------|------|---------|
| V1 | GET | /cleanrooms/{crId}/events | external-api-server |
| V2 | POST | /cleanrooms/{crId}/callbacks | external-api-server |
| V2 | GET | /cleanrooms/{crId}/callbacks | external-api-server |
| V2 | PUT | /cleanrooms/{crId}/callbacks/{cbId} | external-api-server |
| V2 | DELETE | /cleanrooms/{crId}/callbacks/{cbId} | external-api-server |
| V3 | POST | /cleanrooms/{crId}/callbacks/{cbId}/test | external-api-server |
| V3 | POST | /admin/callbacks/{cbId}/replay-dlq | external-api-server |
| V3 | GET | /cleanrooms/{crId}/events/{eventId}/replay | external-api-server |

---

## Sprint Delivery Summary

```
Sprint 1–2 (V1)
  ├── DB migration: CREATE TABLE object_events
  ├── Code: CRUD interceptors + field differ (unhygienix)
  ├── Code: GET /events read API (external-api-server)
  └── UI: Activity Feed tab (Frontend)

Sprint 3–5 (V2)
  ├── DB migrations: CREATE TABLE callback_registrations, delivery_log
  ├── Infra: SNS topic, SQS queues + DLQs per consumer, CloudWatch alarm
  ├── Code: SNS publish in V1 interceptors (unhygienix)
  ├── Code: Callback registration CRUD APIs (external-api-server)
  ├── Code: Proto definitions (ignoramus)
  └── Code: Callback Delivery Worker — SQS consumer, POST, retry, delivery_log (new service)

Sprint 6–7 (V3)
  ├── Code: HMAC signature (delivery worker)
  ├── Code: Circuit breaker / Resilience4j (delivery worker)
  ├── Code: Per-field subscription filter (delivery worker)
  ├── Code: DLQ replay + webhook test APIs (external-api-server)
  └── UI: Webhooks tab — delivery status, DLQ inspect + replay (Frontend)
```
