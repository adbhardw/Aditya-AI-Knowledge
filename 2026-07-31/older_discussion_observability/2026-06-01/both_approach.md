# DV-13856 — Both Recommended Approaches: Pull API + Webhook Push
**Date:** 2026-06-01
**Author:** Aditya Bhardwaj
**Context:** DL/TL meeting — two approaches that complement each other, not compete

---

## Architecture Foundation — Shared Across Both Approaches

Before the two approaches diverge, both share an identical foundation.

### Service Ownership (where does the table live?)

```
Dependency graph (from go.mod):
  unhygienix  → imports: forebitt, picanmix, postaldistrix, hank, ignoramus
  forebitt    → imports: postaldistrix, hank, ignoramus  (does NOT import unhygienix)
  picanmix    → imports: forebitt, unhygienix, postaldistrix, hank, ignoramus
  postaldistrix → imports NONE of the three (neutral service)
```

**The single gRPC endpoint approach (recommended):**
Each service calls one neutral gRPC endpoint asynchronously to write events.
Table lives in the neutral service (postaldistrix or a new dedicated service).

```
forebitt DC change   → go neutralSvc.RecordObjectEvent(dcEvent)   ─┐
unhygienix Q change  → go neutralSvc.RecordObjectEvent(qEvent)    ─┼→ object_events
picanmix export chg  → go neutralSvc.RecordObjectEvent(exportEvt) ─┘

external-api-server  → neutralSvc.GetCleanroomEvents(crId, since)
                     → GET /cleanrooms/{id}/events  ← XMI calls this
```

Each call is a non-blocking goroutine — mutation handler returns immediately.
No circular dependency. forebitt never calls unhygienix.

### The Polymorphic object_events Table

One table handles all three object types. `object_type` is the discriminator.

```sql
CREATE TABLE object_events (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    spec_version     VARCHAR(10)  NOT NULL DEFAULT '1.0',
    source           VARCHAR      NOT NULL,    -- urn:habu:cleanroom:{cleanroom_id}
    type             VARCHAR      NOT NULL,    -- com.habu.cleanroom.question.updated
    org_id           UUID         NOT NULL,
    cleanroom_id     UUID         NOT NULL,
    object_type      VARCHAR      NOT NULL,    -- QUESTION | DATA_CONNECTION | EXPORT_JOB
    object_id        UUID         NOT NULL,
    object_name      VARCHAR,                  -- snapshot at event time
    change_type      VARCHAR      NOT NULL,    -- CREATED | UPDATED | DELETED | STATUS_CHANGED
    changed_fields   JSONB,                    -- shape varies per object_type (see below)
    performed_by     VARCHAR,
    performed_by_type VARCHAR     NOT NULL DEFAULT 'USER',
    schema_version   INT          NOT NULL DEFAULT 1,
    idempotency_key  VARCHAR      UNIQUE,
    cursor_position  BIGINT,                   -- monotonic sequence, indexed
    event_time       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_cleanroom_cursor ON object_events (cleanroom_id, cursor_position);
CREATE INDEX idx_events_org_type         ON object_events (org_id, object_type);
```

**changed_fields JSONB shapes per object_type:**

QUESTION (from unhygienix QuestionDimensions, QuestionMetrics protos):
```json
{
  "dimensions": {
    "removed": [{ "name": "Customer_Email_Id", "type": "STRING", "filterable": true }],
    "added":   [],
    "current": [{ "name": "Ramp_ID", "type": "STRING" }, ...]
  },
  "metrics": { "removed": [], "added": ["conversion_rate"], "current": [...] },
  "status":  { "old": "DRAFT", "new": "ACTIVE" },
  "name":    { "old": "Q1", "new": "Revenue Analysis" },
  "datasetAssignments": { "old": "DS_Q1_2025", "new": "DS_Q2_2025" }
}
```

DATA_CONNECTION (from forebitt FieldConfiguration proto, ForebittDataType enum):
```json
{
  "fieldConfigurations": {
    "typeChanges": [{ "fieldName": "Amount", "oldType": "DOUBLE", "newType": "STRING" }],
    "added":   [{ "fieldName": "Region", "dataType": "STRING" }],
    "removed": [{ "fieldName": "Customer_Email_Id", "dataType": "STRING" }],
    "current": [{ "fieldName": "Ramp_ID", "dataType": "STRING", "isPii": false }, ...]
  },
  "status": { "old": "ACTIVE", "new": "PAUSED" }
}
```

EXPORT_JOB (from forebitt FlowNodeExportJob, ForebittStatus/ForebittRunStatus enums):
```json
{
  "status":        { "old": "ACTIVE",  "new": "PAUSED"     },
  "channelStatus": { "old": "RUNNING", "new": "PAUSED"      }
}
```

---

## Approach 1 — Cursor-Based Events API (Pull)

### Miro Diagram Prompt

```
Create an enterprise architecture flowchart titled:
"Approach 1 — Events API (Cursor-Based Pull)"
Subtitle: "CNCF CloudEvents v1.0 envelope · One event table · Two consumers: Activity Feed UI + External REST API"

LAYOUT: Strictly top-to-bottom vertical flowchart. Use swim-lane columns only where annotating parallel paths.
All primary flow boxes stack vertically down the center spine. Side annotations hang LEFT or RIGHT of the spine.
Do NOT lay out left-to-right. This is a vertical architecture diagram.

======================================================================
SECTION A — TOP: MUTATION TRIGGERS
Label this section with a horizontal band: "MUTATION LAYER — unhygienix (PostgreSQL service)"
======================================================================

Three boxes stacked vertically, LEFT COLUMN (blue, rounded corners, drop shadow):
  Box A1: "QUESTION mutation
           ── columns removed / added / renamed
           ── dataset assignment changed
           ── question status: DRAFT → ACTIVE → DELETED
           Entity: questions (id, cleanroom_id, org_id, ...)"

  Box A2: "DATA CONNECTION mutation
           ── field type changed (Integer → String)
           ── field added / removed
           ── connection status: ENABLED / DISABLED
           Entity: data_connections (id, cleanroom_id, schema_snapshot JSONB)"

  Box A3: "EXPORT JOB mutation
           ── status changed: PENDING → RUNNING → COMPLETED / FAILED
           ── output path changed, schedule modified
           Entity: export_jobs (id, cleanroom_id, status, cronos_job_id)"

All three boxes merge into a single DOWN arrow labeled:
  "Async goroutine gRPC call to neutral event service (non-blocking)"

======================================================================
SECTION B — INTERCEPTOR + EVENT STORE (center spine, purple)
======================================================================

Box B1 (purple, large, center):
  Title: "CRUD Interceptor — per service (unhygienix / forebitt / picanmix)"
  Sub-label: "Built once per service. Single neutral service owns the event store."
  Inside, three sequential steps with numbered badges:
    [1] Snapshot entity state BEFORE mutation
        → serialize to changed_fields JSONB
    [2] Execute DB mutation (questions / data_connections / export_jobs)
    [3] Diff before vs after
        → compute changedFields: { field: { from: X, to: Y } }
        → assign schemaVersion: 1
        → generate idempotency key: SHA-256(cleanroom_id + object_id + event_type + event_time)
    [4] go neutralSvc.RecordObjectEvent(ctx, event)  ← non-blocking goroutine

  Side annotation RIGHT (yellow sticky):
    "Idempotency key prevents duplicate events if interceptor fires twice on retry.
     Non-blocking goroutine: mutation returns 200 OK immediately.
     If event write fails, mutation still succeeds (observability is best-effort for MVP)."

Arrow DOWN labeled: "[NEUTRAL SERVICE WRITES EVENT — eventual, ~milliseconds]"

Box B2 (purple, monospace interior):
  Title: "object_events — append-only table (neutral event service DB)"
  Sub-label: "Never updated. Never deleted (soft TTL: 90 days, configurable)."
  Schema table inside:
    ┌─────────────────────────────────────────────────────────┐
    │  event_id         UUID         PK  (idempotency key)   │
    │  cleanroom_id     UUID         FK → cleanrooms          │
    │  org_id           UUID         FK → organizations       │
    │  object_type      ENUM         QUESTION / DC / EXPORT   │
    │  object_id        UUID         FK → source entity       │
    │  event_type       VARCHAR      com.habu.cleanroom.*     │
    │  changed_fields   JSONB        diff snapshot            │
    │  performed_by     VARCHAR      actor email / svc acct   │
    │  schema_version   INTEGER      1 (bumped on breaking Δ) │
    │  event_time       TIMESTAMPTZ  wall-clock, UTC          │
    │  cursor_position  BIGINT       monotonic, indexed       │
    └─────────────────────────────────────────────────────────┘
  Side annotation LEFT (gray):
    "cursor_position: monotonically increasing sequence.
     Clients pass ?since=<cursor> to page forward. No time-based gaps."

  Index annotations (monospace, below schema):
    "CREATE INDEX idx_events_cleanroom_cursor ON object_events(cleanroom_id, cursor_position);
     CREATE INDEX idx_events_org_type         ON object_events(org_id, object_type);"

======================================================================
SECTION C — FAN-OUT: TWO DELIVERY CHANNELS (vertical branches)
======================================================================

Arrow DOWN splits into TWO vertical branches. Label the split: "Two read paths — same source of truth."

LEFT BRANCH (green): "Internal gRPC Channel"
  Box C1 (green):
    Title: "gRPC Internal Endpoint — neutral event service"
    Method: "GetCleanroomEvents(crId, since, objectType, limit)"
    Proto definition (monospace):
      rpc GetCleanroomEvents (GetCleanroomEventsRequest)
          returns (GetCleanroomEventsResponse);

      message GetCleanroomEventsRequest {
        string cleanroom_id  = 1;
        int64  since_cursor  = 2;   // 0 = from beginning
        string object_type   = 3;   // "" = all types
        int32  limit         = 4;   // max 100, default 25
      }
    Side annotation: "Called by topgallant (React UI) via external-api-server.
                      Stays on internal VPC mesh. No public auth needed."

  Arrow DOWN (green):
  Box C2 (green, wireframe UI panel):
    Title: "Activity Feed Tab — Clean Room UI (topgallant — React)"
    Sub-label: "[PM NOTE: deprioritized for V1 — API-first. Include as V3 scope.]"
    Filter bar: "[All Types ▼]  [All Users ▼]  [Last 30 days ▼]  [Export CSV]"
    Feed items (monospace-style):
      ● 2026-05-12  sarah@acme.com              cursor: 4821
        QUESTION "Revenue Analysis" — COLUMNS REMOVED
        Removed: customer_segment, channel
        Current dimensions: revenue, region, date

      ● 2026-05-11  john@acme.com               cursor: 4820
        DATA CONNECTION "CRM_Import" — FIELD TYPE CHANGED
        purchase_count: Integer → String

      ● 2026-05-10  admin@liveramp.com           cursor: 4819
        QUESTION "Lookalike Segments" — DELETED
    Side annotation RIGHT (blue sticky):
      "Cursor returned in each response.
       UI auto-polls every 30s with last seen cursor.
       Empty response = no new events."

RIGHT BRANCH (orange): "External REST API Channel"
  Box C3 (orange):
    Title: "External REST API — external-api-server"
    Two-layer path (monospace):
      Layer 1 (internal):
        neutral event service gRPC endpoint
        /unhygienix-equivalent/org/{orgId}/cleanroom/{crId}/events

      Layer 2 (external — what XMI calls):
        GET /v1/cleanrooms/{cleanroomId}/events
             ?since=eyJsYXN0X2N1cnNvciI6NDgyMX0=   ← base64 opaque cursor
             &objectType=QUESTION
             &limit=50
        Authorization: Bearer <JWT>
        Accept: application/cloudevents+json

    JWT auth annotation (LEFT side):
      "JWT Bearer token carries org_id claim.
       external-api-server enforces: org_id in token MUST match cleanroom owner/partner.
       MSFT only sees MSFT org events. XMI only sees XMI org events.
       Zero per-customer filter config — handled at auth layer."

    Rate-limiting annotation (RIGHT side, monospace):
      "Rate limit: 120 req/min per org (token-bucket)
       Headers returned:
         X-RateLimit-Remaining: 87
         X-RateLimit-Reset:     1715521260
       429 response → Retry-After: 15s"

  Arrow DOWN:
  Box C4 (orange, monospace JSON):
    Title: "Response Payload — CNCF CloudEvents v1.0 Envelope"
    Sub-label (teal callout box, RIGHT):
      "VENDOR NEUTRALITY (CloudEvents CNCF spec):
       Adopted natively by GCP Eventarc, Azure Event Grid, AWS EventBridge.
       Our payloads work on any cloud without changing a single field.
       XMI on GCP, MSFT on Azure — same JSON verbatim."

    JSON body (monospace):
      HTTP/1.1 200 OK
      Content-Type: application/cloudevents-batch+json
      ETag: "W/\"4821\""
      X-Next-Cursor: eyJsYXN0X2N1cnNvciI6NDgyMX0=

      [
        {
          "specversion":  "1.0",
          "id":           "evt-789-a3f9c2d1-uuid",
          "source":       "urn:habu:cleanroom:cr-abc",
          "type":         "com.habu.cleanroom.question.updated",
          "time":         "2026-05-12T10:32:00Z",
          "datacontenttype": "application/json",
          "schemaurl":    "https://schema.habu.com/events/v1/question.updated.json",
          "data": {
            "orgId":         "org-xyz",
            "cleanroomId":   "cr-abc",
            "objectType":    "QUESTION",
            "objectId":      "q-123",
            "objectName":    "Revenue Analysis",
            "changeType":    "UPDATED",
            "changedFields": {
              "dimensions": {
                "removed": ["customer_segment", "channel"],
                "current": ["revenue", "region", "date"]
              }
            },
            "performedBy":   "sarah@acme.com",
            "schemaVersion": 1,
            "cursor":        4821
          }
        }
      ]

  Arrow DOWN:
  Box C5 (orange):
    Title: "XMI UI Polling Client — Google Cloud"
    Steps:
      1. Poll GET /events?since=<cursor> every 60s
      2. On 304 Not Modified (ETag matched) → skip processing, advance timer
      3. On 200 → deserialize CloudEvents batch → update UI state
      4. Persist new cursor to Redis (TTL 30d)
      5. No inbound port. No firewall rule. No XMI server required.
    Side annotation (red sticky):
      "Change latency = poll interval (default 60s).
       For sub-second latency → see Approach 2 (Webhook Push)."

======================================================================
SECTION D — BOTTOM: DECISION SCORECARD
======================================================================

Two boxes side by side at the bottom:

Box D1 (green, left half):
  Title: "Why Approach 1"
  ✓ One gRPC endpoint powers both internal UI and external API — zero duplication
  ✓ Cloud-agnostic: XMI (GCP), MSFT (Azure) both call identical REST/CloudEvents API
  ✓ CNCF CloudEvents: works natively on GCP Eventarc, Azure Event Grid, AWS EventBridge
  ✓ Org-filtering via JWT org_id claim — automatic, zero per-customer config
  ✓ Cursor pagination: append-only table, no data loss on reconnect
  ✓ No inbound HTTPS endpoint needed on XMI side — purely outbound polling
  ✓ Activity Feed UI uses same table (V3 scope)
  ✓ Schema versioning field enables non-breaking evolution

Box D2 (yellow, right half):
  Title: "Trade-offs + Mitigations"
  △ Change latency = poll interval (30–60s) — not sub-second
    → Mitigation: combine with Approach 2 for SLA-sensitive consumers
  △ XMI must persist cursor across restarts
    → Mitigation: Redis KV, cursor in response payload
  △ Wasted HTTP calls when nothing changed
    → Mitigation: ETag + 304 Not Modified (zero body transfer)
  △ At scale, high-frequency pollers need rate-limit awareness
    → Mitigation: X-RateLimit headers + 429 with Retry-After

COLOR SPEC: Blue = mutation layer, Purple = interceptor + event store,
Green = internal gRPC + UI channel, Orange = external REST + XMI client,
Teal callout = CloudEvents vendor-neutrality note, Yellow = trade-offs, Red = warnings.
Monospace font for all SQL, proto, JSON, HTTP payloads.
Rounded box corners. Drop shadows. Directional arrow labels on every edge.
All arrows point DOWNWARD or fan left/right from center.
```

---

## Approach 2 — Webhook Callback Registration (Push)

### Miro Diagram Prompt

```
Create an enterprise architecture flowchart titled:
"Approach 2 — Webhook Callback Registration (Push)"
Subtitle: "CNCF CloudEvents v1.0 · HMAC-SHA256 signed · Consumer registers once · Habu pushes sub-second"

LAYOUT: Strictly top-to-bottom vertical flowchart. Three vertical swim-lane columns run the full height.
Phases are clearly labeled horizontal band headers separating the diagram into distinct tiers.
All arrows run top-to-bottom or horizontally between lanes.

THREE vertical swimlanes, full height of diagram:
  Lane 1 (orange):  "CONSUMER — XMI UI (Google Cloud)"
  Lane 2 (blue):    "HABU PLATFORM  (unhygienix + external-api-server, AWS us-east-1)"
  Lane 3 (purple):  "ASYNC DELIVERY INFRASTRUCTURE  (AWS SNS → SQS → Delivery Worker)"

======================================================================
PHASE 1 — horizontal band label: "ONE-TIME SETUP  (Registration)"
======================================================================

[Lane 1]
Box 1.1 (orange):
  "XMI Engineer calls Registration API once"
  Monospace HTTP request:
    POST /v1/cleanrooms/{crId}/callbacks
    Authorization: Bearer <platform-jwt>
    Content-Type: application/json

    {
      "objectType":      "QUESTION",
      "objectId":        null,           ← null = subscribe to ALL questions
      "callbackUrl":     "https://events.xmi.liveramp.com/habu-webhook",
      "monitoredFields": ["dimensions", "status", "name", "datasetAssignments"],
      "authConfig": {
        "authType":  "BEARER",
        "authValue": "eyJhbGci..."        ← XMI-issued bearer token
      },
      "maxDeliveryAttempts": 5
    }

Arrow RIGHT → Lane 2, labeled: "HTTPS POST"

[Lane 2]
Box 1.2 (blue):
  "external-api-server — Registration Handler"
  Validation steps (numbered):
    [1] Verify platform JWT (org_id claim, scope: callbacks:write)
    [2] Validate callbackUrl reachability → HEAD request, expect 200
    [3] Rate-limit: max 10 registrations per cleanroom per org
    [4] Generate signingSecret: CSPRNG 32-byte → base64url (whsec_...)
    [5] Encrypt signingSecret at rest: AWS KMS envelope encryption

  Arrow DOWN in Lane 2:
  Box 1.3 (blue, monospace schema):
    "callback_registrations — neutral event service DB"
    ┌──────────────────────────────────────────────────────────────┐
    │  id               UUID        PK                            │
    │  cleanroom_id     UUID        FK → cleanrooms               │
    │  org_id           UUID        FK → organizations (auto-set) │
    │  object_type      ENUM        QUESTION / DC / EXPORT / *    │
    │  object_id        UUID        NULL = all objects of type    │
    │  callback_url     VARCHAR     encrypted at rest (KMS)       │
    │  monitored_fields TEXT[]      field-level filter            │
    │  auth_config      JSONB       encrypted at rest (KMS)       │
    │  signing_secret   VARCHAR     KMS envelope-encrypted        │
    │  status           ENUM        ACTIVE / PAUSED / SUSPENDED   │
    │  created_at       TIMESTAMPTZ                               │
    │  failure_count    INTEGER     resets on success             │
    └──────────────────────────────────────────────────────────────┘
    Side annotation RIGHT: "signing_secret never leaves Habu unencrypted.
                            Decrypted in-memory only at delivery time."

Arrow RIGHT → Lane 1:
Box 1.4 (orange):
  HTTP 201 Created response:
    {
      "id":            "cb-456-uuid",
      "signingSecret": "whsec_a3f9c2d1e4b7...",  ← one-time exposure
      "status":        "ACTIVE",
      "createdAt":     "2026-05-01T09:00:00Z"
    }
  Sub-label (red sticky):
    "signingSecret shown ONCE in 201 response.
     XMI stores in GCP Secret Manager.
     Used to verify every inbound event is genuinely from Habu."

======================================================================
PHASE 2 — horizontal band label: "RUNTIME — OBJECT MUTATION EVENT"
======================================================================

[Lane 2]
Box 2.1 (blue):
  "sarah@acme.com removes columns from Question q-123"
  DB write path (monospace, sequential):
    BEGIN TRANSACTION
      ├── [1] interceptor: SELECT question WHERE id=q-123 (BEFORE snapshot)
      ├── [2] UPDATE questions SET dimensions=... WHERE id=q-123
      ├── [3] diff(before, after) → changedFields JSONB
      ├── [4] generate idempotency_key = SHA-256(cr-abc|q-123|UPDATED|2026-05-12T10:32:00Z)
      └── [5] go neutralSvc.RecordObjectEvent(ctx, event) ← non-blocking goroutine
    → 200 OK returned to sarah@acme.com immediately

Arrow DOWN in Lane 2:
Box 2.2 (blue):
  "Post-Commit: SNS Publish (~1ms after COMMIT, non-blocking)"
  Sub-label: "User's mutation is COMPLETE. Delivery is fully async."
  Steps:
    neutralSvc.RecordObjectEvent writes to object_events
    → SNS publish to habu-object-events topic
    → SNS message attributes: cleanroom_id, object_type, org_id

Arrow RIGHT → Lane 3, labeled: "AWS SNS Publish — habu-object-events topic"

======================================================================
PHASE 3 — horizontal band label: "ASYNC DELIVERY (SNS → SQS → Worker)"
======================================================================

[Lane 3]
Box 3.1 (purple):
  "AWS SNS Topic — habu-object-events"
  SNS Message Attributes (monospace):
    cleanroom_id:  cr-abc         (String)
    object_type:   QUESTION       (String)
    org_id:        org-xyz        (String)
  Sub-label: "SNS filter policies route per-org to per-consumer SQS queues.
              XMI queue receives only XMI org events. Cross-org isolation at SNS."

  Side annotation LEFT (teal):
    "ADDING TEAM MI:
     Step 1: Create sqs-habu-delivery-mi
     Step 2: aws sns subscribe --topic-arn ... --protocol sqs --endpoint sqs-mi-arn
     Step 3: MI registers their callback URL via POST /callbacks
     Done. Zero code change in unhygienix, forebitt, or picanmix."

Arrow DOWN:
Box 3.2 (purple):
  "SQS Queue — sqs-habu-delivery-xmi  (dedicated per consumer)"
  Queue config:
    Visibility Timeout:    30s
    Message Retention:     4 days
    Max Receive Count:     5 (before DLQ)
    Redrive Policy → DLQ: sqs-habu-dlq-xmi

  Side annotation LEFT (red box):
    "CONSUMER ISOLATION GUARANTEE:
     sqs-habu-delivery-xmi failure has ZERO effect on
     sqs-habu-delivery-mi or sqs-habu-delivery-safehaven.
     Each consumer: own queue, own DLQ, own CloudWatch alarm.
     XMI outage pages XMI on-call — NOT Habu on-call."

Arrow DOWN:
Box 3.3 (purple, large, detailed):
  "Callback Delivery Worker — neutral event service (ECS Fargate)"
  Execution steps (numbered, monospace):
    [1] receiveMessage(sqs-habu-delivery-xmi)
        → message hidden (visibilityTimeout=30s), NOT deleted yet
    [2] query callback_registrations WHERE cleanroom=cr-abc AND type=QUESTION
        → cb-456 matched; decrypt callback_url + auth_config via KMS
    [3] filter: changedFields ∩ monitoredFields → non-empty? proceed : skip + ACK
    [4] build CloudEvents v1.0 JSON payload from evt-789
    [5] sign payload:
        timestamp = Unix epoch now (1715521200)
        signed_payload = timestamp + "." + SHA-256(payload)
        signature = HMAC-SHA256(signingSecret, signed_payload)
        → X-Habu-Signature: t=1715521200,v1=a3f9c2d1...
    [6] HTTP POST to https://events.xmi.liveramp.com/habu-webhook
        Headers:
          Authorization:    Bearer eyJhbGci...
          X-Habu-Signature: t=1715521200,v1=a3f9c2d1...
          X-Habu-Event-Id:  evt-789-uuid
          Content-Type:     application/cloudevents+json
        Timeout: 10s connect, 30s read
    [7] on HTTP 2xx → deleteMessage from SQS (explicit ACK)
        → write delivery_log: { attempt: 1, status: 200, latency: 45ms }
    [8] on HTTP 4xx (non-409) → deleteMessage (consumer rejected, do not retry)
    [9] on HTTP 5xx / timeout → do NOT deleteMessage → reappears after visibilityTimeout

  Side annotation RIGHT (teal callout):
    "VENDOR NEUTRALITY (CloudEvents):
     GCP Eventarc, Azure Event Grid, AWS EventBridge all consume this payload natively.
     XMI on GCP and MSFT on Azure receive identical JSON — no field transformation."

Arrow DOWN:
Box 3.4 (purple, monospace JSON):
  Title: "CloudEvents v1.0 Payload — delivered to XMI"
  {
    "specversion":       "1.0",
    "id":                "evt-789-a3f9c2d1-uuid",
    "source":            "urn:habu:cleanroom:cr-abc",
    "type":              "com.habu.cleanroom.question.updated",
    "time":              "2026-05-12T10:32:00Z",
    "datacontenttype":   "application/json",
    "schemaurl":         "https://schema.habu.com/events/v1/question.updated.json",
    "data": {
      "orgId":           "org-xyz",
      "cleanroomId":     "cr-abc",
      "objectType":      "QUESTION",
      "objectId":        "q-123",
      "objectName":      "Revenue Analysis",
      "changeType":      "UPDATED",
      "changedFields": {
        "dimensions": {
          "removed": ["customer_segment", "channel"],
          "current": ["revenue", "region", "date"]
        }
      },
      "performedBy":     "sarah@acme.com",
      "schemaVersion":   1,
      "idempotencyKey":  "sha256-7f83b1657..."
    }
  }

Arrow DOWN:
Box 3.5 (red, failure path):
  Title: "Retry + Dead Letter Path"
  Exponential backoff:
    Attempt 1: immediate      → visibilityTimeout=30s
    Attempt 2: 30s + jitter
    Attempt 3: 90s + jitter
    Attempt 4: 270s + jitter
    Attempt 5: maxReceiveCount=5 exceeded
    → message moved to sqs-habu-dlq-xmi
    → CloudWatch alarm → XMI on-call paged (consumer's responsibility)
    → Habu SRE alarm: DLQ depth > 0 → Slack #platform-alerts

Arrow RIGHT from 3.5 → Lane 2:
Box 2.3 (blue):
  "delivery_log table — neutral event service DB"
  ┌──────────────────────────────────────────────────────┐
  │  id              UUID        PK                      │
  │  event_id        UUID        FK → object_events      │
  │  registration_id UUID        FK → callback_regs      │
  │  attempt_number  INTEGER     1..5                    │
  │  http_status     INTEGER     200 / 500 / 0 (timeout) │
  │  latency_ms      INTEGER                             │
  │  error_message   TEXT        null on success         │
  │  delivered_at    TIMESTAMPTZ                         │
  └──────────────────────────────────────────────────────┘

======================================================================
PHASE 4 — horizontal band label: "CONSUMER RECEIVE + VERIFY"
======================================================================

[Lane 1]
Box 4.1 (orange):
  "XMI Webhook Receiver — Cloud Run (GCP)"
  Verification steps:
    [1] Extract t= and v1= from X-Habu-Signature header
    [2] Reject if abs(now - t) > 300s (replay attack window)
    [3] Recompute HMAC-SHA256(signingSecret, t + "." + raw_body)
    [4] constant-time compare with v1 value
    [5] If mismatch → 401 Unauthorized (Habu worker will NOT retry 4xx)

Arrow DOWN:
Box 4.2 (orange):
  "Deduplication + Idempotency Guard"
  Redis (GCP Memorystore):
    key: "habu:evt:evt-789-a3f9c2d1-uuid"  TTL: 7 days
    SET NX → if already set → return 200 (idempotent ACK, skip processing)
  Sub-label: "Handles SQS at-least-once. Same event may arrive twice in rare cases."

Arrow DOWN:
Box 4.3 (orange):
  "Business Logic — downstream processing"
  → Invalidate UI cache for cleanroom cr-abc
  → Update question schema registry snapshot
  → Return HTTP 200 OK within 30s (Habu worker timeout)

======================================================================
SECTION D — BOTTOM: DECISION SCORECARD
======================================================================

Box D1 (green):
  Title: "Why Approach 2"
  ✓ Sub-second push latency — no polling interval gap
  ✓ CNCF CloudEvents: consumed natively by GCP, Azure, AWS EventBridge — no translation
  ✓ HMAC-SHA256 + replay window: enterprise-grade webhook security (Stripe, GitHub, Twilio)
  ✓ Consumer isolation: SQS queue per consumer, DLQ per consumer, alarm per consumer
  ✓ Self-service: API registration → no Habu engineer per new consumer
  ✓ Field-level filtering: monitoredFields prevents noise
  ✓ Adding MI team = new SQS subscription + callback registration → zero code change in unhygienix
  ✓ TL concern resolved: each team owns their own queue, their own on-call

Box D2 (yellow):
  Title: "Trade-offs + Mitigations"
  △ XMI must expose HTTPS endpoint (inbound from AWS)
    → Mitigation: Cloud Run (GCP) supports inbound HTTPS trivially — not a server, just a route
  △ New infra: delivery worker, callback_registrations, delivery_log, DLQ, CloudWatch
    → Mitigation: delivery worker is generic — reused for MI, SafeHaven, all future consumers
  △ At-least-once delivery (SQS) — duplicates possible
    → Mitigation: Redis dedup guard with 7-day TTL on event_id
  △ More sprints than Approach 1 alone (~3 sprints incremental)
    → Mitigation: V1 = Pull API (Approach 1). V2 = Webhook (Approach 2). Ship in phases.

COLOR SPEC: Orange = Lane 1 / XMI consumer, Blue = Lane 2 / Habu platform,
Purple = Lane 3 / async infra, Red = failure/DLQ path, Green = success/why,
Yellow = trade-offs, Teal = CloudEvents + vendor-neutrality callout.
Monospace for all SQL, JSON, HTTP, code blocks.
Horizontal phase band labels in bold across all three lanes.
Arrows within lanes point DOWNWARD. Cross-lane arrows are horizontal.
```

---

## How the Two Approaches Fit Together

```
V1 (1–2 sprints): Approach 1 only
  ├── object_events table + CRUD interceptors (unhygienix, forebitt, picanmix)
  ├── Neutral event service: RecordObjectEvent gRPC (write) + GetCleanroomEvents gRPC (read)
  └── external-api-server: GET /cleanrooms/{id}/events (JWT, CloudEvents, cursor)
      → XMI adopts cursor API immediately — no server needed on their side

V2 (3–5 sprints, on top of V1): Add Approach 2
  ├── callback_registrations table (neutral event service DB)
  ├── POST /cleanrooms/{id}/callbacks registration API
  ├── SNS publish in neutral event service (post RecordObjectEvent)
  ├── SQS per-consumer + Callback Delivery Worker + DLQ
  └── XMI migrates from polling (Approach 1) to webhook (Approach 2) at their own pace

V3 (future): Activity Feed UI + hardening
  ├── Activity Feed tab in clean room UI (reads Approach 1 cursor API)
  ├── HMAC + circuit breaker + delivery_log UI
  └── Event replay API
```

Both approaches share the same event table, same interceptors, same CloudEvents payload.
The only difference is the delivery mechanism: XMI pulls in Approach 1, Habu pushes in Approach 2.
