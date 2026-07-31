# Miro Prompts V2 — Three Approaches, DV-13856 Clean Room Observability
**Date:** 2026-06-01
**Context:** DL meeting prep — three distinct architecture options for event notification
**Author:** Aditya Bhardwaj
**Key attendees:** TL + DL (Jon Chua, Shruthi, Ravindra)
**Version:** V2 — vertical flowcharts, full industry-standard detail, CNCF CloudEvents envelope

---

## Prompt 1 — Approach 1: Cursor-Based Events API (Pull) — Vertical Flowchart

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
  "gRPC interceptor fires synchronously within DB transaction scope"

======================================================================
SECTION B — INTERCEPTOR + EVENT STORE (center spine, purple)
======================================================================

Box B1 (purple, large, center):
  Title: "CRUD Interceptor — unhygienix"
  Sub-label: "Built once. Powers Activity Feed, External API, and any future consumer."
  Inside, three sequential steps with numbered badges:
    [1] Snapshot entity state BEFORE mutation
        → serialize to changed_fields JSONB
    [2] Execute DB mutation (questions / data_connections / export_jobs)
    [3] Diff before vs after
        → compute changedFields: { field: { from: X, to: Y } }
        → assign schemaVersion: 1 (semver-aligned, bumped on breaking change)
        → generate idempotency key: SHA-256(cleanroom_id + object_id + event_type + event_time)

  Side annotation RIGHT (yellow sticky):
    "Idempotency key prevents duplicate events if interceptor fires twice
     on retry. Consumers can safely re-process; key stored in object_events."

Arrow DOWN labeled: "[SAME DB TRANSACTION — atomic rollback]
                    If mutation fails → INSERT is rolled back. Event never orphaned."

Box B2 (purple, monospace interior):
  Title: "object_events — append-only table (unhygienix PostgreSQL)"
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
    "cursor_position: PostgreSQL sequence — monotonically increasing.
     Clients pass ?since=<cursor> to page forward. No time-based gaps."

  Index annotations (monospace, below schema):
    "CREATE INDEX idx_events_cleanroom_cursor ON object_events(cleanroom_id, cursor_position);
     CREATE INDEX idx_events_org_type         ON object_events(org_id, object_type);
     Partial index on event_time WHERE event_time > NOW() - INTERVAL '90 days';"

======================================================================
SECTION C — FAN-OUT: TWO DELIVERY CHANNELS (vertical branches)
======================================================================

Arrow DOWN splits into TWO vertical branches. Label the split: "Two read paths — same source of truth."

LEFT BRANCH (green): "Internal gRPC Channel"
  Box C1 (green):
    Title: "gRPC Internal Endpoint — external-api-server"
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
    Side annotation: "Called by topgallant (React UI). No auth header — stays on internal VPC mesh."

  Arrow DOWN (green):
  Box C2 (green, wireframe UI panel):
    Title: "Activity Feed Tab — Clean Room UI (topgallant — React)"
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
    Sub-label: "Every Habu user benefits immediately. Zero setup. Zero config."
    Side annotation RIGHT (blue sticky):
      "Cursor returned in each response.
       UI auto-polls every 30s with last seen cursor.
       Empty response = no new events (no wasted render)."

RIGHT BRANCH (orange): "External REST API Channel"
  Box C3 (orange):
    Title: "External REST API — external-api-server"
    Endpoint (monospace):
      GET /v1/cleanrooms/{cleanroomId}/events
           ?since=eyJsYXN0X2N1cnNvciI6NDgyMX0=   ← base64 opaque cursor
           &objectType=QUESTION
           &limit=50
      Authorization: Bearer <JWT>
      Accept: application/cloudevents+json

    Rate-limiting annotation (monospace, RIGHT side):
      "Rate limit: 120 req/min per org (token-bucket algorithm)
       Headers returned:
         X-RateLimit-Limit:     120
         X-RateLimit-Remaining: 87
         X-RateLimit-Reset:     1715521260
       429 response on breach → Retry-After: 15s"

  Arrow DOWN:
  Box C4 (orange, monospace JSON):
    Title: "Response Payload — CNCF CloudEvents v1.0 Envelope"
    Sub-label (teal callout box, RIGHT):
      "VENDOR NEUTRALITY NOTE:
       We use the CNCF CloudEvents spec as the event envelope.
       Adopted natively by GCP Eventarc, Azure Event Grid, and AWS EventBridge.
       Our payloads work on any cloud without changing a single field.
       Future consumers on Azure / GCP consume the same JSON verbatim."

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
            "cursor":        "eyJsYXN0X2N1cnNvciI6NDgyMX0="
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
      4. Persist new cursor to Redis (TTL 30d) for crash recovery
      5. No inbound port. No firewall rule. No XMI server required.
    Side annotation (red sticky):
      "Change latency = poll interval (default 60s).
       Mitigated with ETag / conditional GET → 304 avoids body transfer.
       For sub-second latency → see Approach 2 (Webhook Push)."

======================================================================
SECTION D — BOTTOM: DECISION SCORECARD
======================================================================

Two boxes side by side at the bottom:

Box D1 (green, left half):
  Title: "Why Approach 1"
  ✓ One gRPC endpoint powers both internal UI and external API — zero duplication
  ✓ Cloud-agnostic: XMI (GCP), MSFT (Azure) both call identical REST/CloudEvents API
  ✓ CNCF CloudEvents: payload runs on GCP Eventarc, Azure Event Grid, AWS EventBridge natively
  ✓ Org-filtering via JWT org_id claim — automatic, zero per-customer config
  ✓ Cursor pagination: append-only table, no data loss on reconnect
  ✓ ETag conditional GET reduces bandwidth on idle periods
  ✓ Activity Feed UI — immediate platform utility, zero consumer setup
  ✓ Schema versioning field (schemaVersion) enables non-breaking evolution

Box D2 (yellow, right half):
  Title: "Trade-offs + Mitigations"
  △ Change latency = poll interval (30–60s) — not sub-second
    → Mitigation: combine with Approach 2 for SLA-sensitive consumers
  △ XMI must persist cursor across restarts
    → Mitigation: Redis KV store, TTL 30d, cursor in response payload
  △ Wasted HTTP calls when nothing changed
    → Mitigation: ETag + 304 Not Modified (zero body transfer)
  △ At scale, high-frequency pollers need rate-limit awareness
    → Mitigation: X-RateLimit headers + 429 with Retry-After

COLOR SPEC: Blue = mutation layer, Purple = interceptor + event store,
Green = internal gRPC + UI channel, Orange = external REST + XMI client,
Teal callout = vendor-neutrality / CloudEvents note, Yellow = trade-offs,
Red sticky = latency warning.
Monospace font for all SQL, proto, JSON, HTTP payloads.
Rounded box corners. Drop shadows on all major boxes. Directional arrow labels on every edge.
All arrows point DOWNWARD or fan left/right from center. This is a TOP-TO-BOTTOM vertical diagram.
```

---

## Prompt 2 — Approach 2: Cloud-Agnostic Webhook / Callback Registration (Push) — Vertical Flowchart

```
Create an enterprise architecture flowchart titled:
"Approach 2 — Webhook Callback Registration (Push)"
Subtitle: "CNCF CloudEvents v1.0 · HMAC-SHA256 signed · Consumer registers once · Habu pushes sub-second"

LAYOUT: Strictly top-to-bottom vertical flowchart. Three vertical swim-lane columns run the full height.
Phases are clearly labeled horizontal band headers separating the diagram into distinct tiers.
All arrows run top-to-bottom or horizontally between lanes. No left-to-right main axis.

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
      "retentionDays": 7,
      "maxDeliveryAttempts": 5
    }

Arrow RIGHT → Lane 2, labeled: "HTTPS POST (TLS 1.3, mutual auth)"

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
    "callback_registrations — unhygienix DB"
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
    │  last_delivery_at TIMESTAMPTZ                               │
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
     XMI stores it in GCP Secret Manager (rotation every 90 days).
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
      └── [5] INSERT INTO object_events VALUES(evt-789-uuid, ...) ← ATOMIC
    COMMIT TRANSACTION
    → 200 OK returned to sarah@acme.com

Arrow DOWN in Lane 2:
Box 2.2 (blue):
  "Post-Commit Hook (~1ms after COMMIT, non-blocking)"
  Sub-label: "User's mutation is COMPLETE. User UI is unblocked. Delivery is async."
  Steps:
    pg_notify channel: 'object_event_inserted' payload: evt-789-uuid
    → picanmix event bridge picks up notification
    → publishes to SNS Topic

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
              XMI queue receives only XMI org events. Cross-org isolation enforced at SNS."

Arrow DOWN:
Box 3.2 (purple):
  "SQS Queue — sqs-habu-delivery-xmi  (dedicated per consumer)"
  Queue config:
    Visibility Timeout:    30s
    Message Retention:     4 days
    Max Receive Count:     5 (before DLQ)
    Encryption:            SSE-SQS (AWS KMS)
    Redrive Policy → DLQ: sqs-habu-dlq-xmi

  Side annotation LEFT (red box):
    "CONSUMER ISOLATION GUARANTEE:
     sqs-habu-delivery-xmi failure, backpressure, or XMI endpoint outage
     has ZERO effect on sqs-habu-delivery-mi or sqs-habu-delivery-safehaven.
     Each consumer has its own queue, its own DLQ, its own CloudWatch alarm."

Arrow DOWN:
Box 3.3 (purple, large, detailed):
  "Callback Delivery Worker — ECS Fargate (picanmix)"
  Execution steps (numbered, monospace):
    [1] receiveMessage(sqs-habu-delivery-xmi)
        → message hidden (visibilityTimeout=30s), not yet deleted
    [2] query callback_registrations WHERE cleanroom=cr-abc AND type=QUESTION
        → cb-456 matched; decrypt callback_url + auth_config via KMS
    [3] filter: changedFields ∩ monitoredFields → non-empty? proceed : skip + ACK
    [4] build CloudEvents v1.0 JSON payload from evt-789 (see PAYLOAD section below)
    [5] sign payload:
        timestamp = Unix epoch now (1715521200)
        signed_payload = timestamp + "." + SHA-256(payload)
        signature = HMAC-SHA256(signingSecret, signed_payload)
        → X-Habu-Signature: t=1715521200,v1=a3f9c2d1...
    [6] HTTP POST to https://events.xmi.liveramp.com/habu-webhook
        Headers:
          Authorization:    Bearer eyJhbGci...  ← authConfig.authValue
          X-Habu-Signature: t=1715521200,v1=a3f9c2d1...
          X-Habu-Event-Id:  evt-789-uuid
          X-Habu-Timestamp: 1715521200
          Content-Type:     application/cloudevents+json
        Timeout: 10s connect, 30s read
    [7] on HTTP 2xx → deleteMessage from SQS (explicit ACK)
        → write delivery_log: { attempt: 1, status: 200, latency: 45ms }
    [8] on HTTP 4xx (non-409) → deleteMessage (consumer rejected, do not retry)
    [9] on HTTP 5xx or timeout → do NOT deleteMessage → message reappears after visibilityTimeout

  Side annotation RIGHT (teal callout):
    "VENDOR NEUTRALITY NOTE:
     CloudEvents v1.0 is the CNCF-standard envelope.
     GCP Eventarc, Azure Event Grid, and AWS EventBridge
     natively consume CloudEvents — no field transformation required.
     The identical payload works verbatim on any cloud the consumer runs on."

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
    "traceparent":       "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
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
  Side annotation (gray): "traceparent: W3C Trace Context header.
                           XMI can correlate its span to Habu's originating trace in Jaeger/Zipkin."

Arrow DOWN:
Box 3.5 (red, failure path):
  Title: "Retry + Dead Letter Path (failure scenario)"
  Exponential backoff with jitter (monospace):
    Attempt 1: immediate      → SQS visibilityTimeout=30s
    Attempt 2: 30s + jitter   → visibilityTimeout=60s
    Attempt 3: 90s + jitter   → visibilityTimeout=180s
    Attempt 4: 270s + jitter  → visibilityTimeout=600s
    Attempt 5: 600s + jitter  → maxReceiveCount=5 exceeded
    → message moved to sqs-habu-dlq-xmi
    → SNS alert → PagerDuty: team-xmi-oncall (consumer's responsibility)
    → Habu SRE CloudWatch alarm: DLQ depth > 0 → Slack #platform-alerts

Arrow RIGHT from 3.5 → Lane 2:
Box 2.3 (blue):
  "delivery_log table — unhygienix DB"
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
  Sub-label: "Habu-side delivery audit. Consumer can query delivery status via API."

======================================================================
PHASE 4 — horizontal band label: "CONSUMER RECEIVE + VERIFY"
======================================================================

[Lane 1]
Box 4.1 (orange):
  "XMI Webhook Receiver — Cloud Run (GCP)"
  Verification steps (numbered):
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
    SET NX → if already set → skip processing → return 200 (idempotent ACK)
  Sub-label: "Handles SQS at-least-once delivery. Same event may arrive twice."

Arrow DOWN:
Box 4.3 (orange):
  "Business Logic — downstream processing"
  → Invalidate UI cache for cleanroom cr-abc
  → Emit internal XMI event to GCP Pub/Sub for downstream pipeline
  → Update question schema registry snapshot
  → Return HTTP 200 OK within 30s (Habu worker timeout)

======================================================================
SECTION D — BOTTOM: DECISION SCORECARD
======================================================================

Two boxes side by side:

Box D1 (green):
  Title: "Why Approach 2"
  ✓ Sub-second push latency — no polling interval gap
  ✓ CNCF CloudEvents: payload consumed natively by GCP, Azure, AWS EventBridge — no translation
  ✓ HMAC-SHA256 + replay window: enterprise-grade webhook security (same as Stripe, GitHub, Twilio)
  ✓ Consumer isolation: SQS queue per consumer, DLQ per consumer, alarm per consumer
  ✓ Self-service: API registration → no Habu engineer involvement per new consumer
  ✓ Field-level filtering: monitoredFields prevents noise
  ✓ Delivery audit log: queryable, SLA-reportable
  ✓ W3C traceparent: distributed trace continuity across Habu → XMI boundary
  ✓ Adding MI team = new SQS subscription only — zero code change in unhygienix

Box D2 (yellow):
  Title: "Trade-offs + Mitigations"
  △ XMI must expose HTTPS endpoint (inbound from AWS)
    → Mitigation: Cloud Run (GCP) or Azure Container Apps both support inbound HTTPS trivially
  △ New infra: delivery worker, callback_registrations, delivery_log, DLQ, CloudWatch
    → Mitigation: delivery worker is generic — reused for MI, SafeHaven, any future consumer
  △ At-least-once delivery (SQS) — duplicates possible
    → Mitigation: Redis dedup guard with 7-day TTL on event_id
  △ More sprints than Approach 1 alone (~3 sprints incremental on top of Activity Feed)
    → Mitigation: V1 = Activity Feed (Approach 1). V2 = Webhook (Approach 2). Ship in phases.

COLOR SPEC: Orange = Lane 1 / XMI consumer, Blue = Lane 2 / Habu platform,
Purple = Lane 3 / async infra, Red = failure/DLQ path, Green = why/success,
Yellow = trade-offs, Teal = CloudEvents vendor-neutrality callout.
Monospace font for all SQL, JSON, HTTP, code blocks.
Horizontal phase band labels in bold across all three lanes.
Arrows within lanes point DOWNWARD. Cross-lane arrows are horizontal.
This is a TOP-TO-BOTTOM vertical swimlane diagram. No left-to-right axis.
```

---

## Prompt 3 — Approach 3: Cloud-Native Queue Delivery vs. HTTPS Verdict — Vertical Flowchart

```
Create an enterprise architecture decision flowchart titled:
"Approach 3 — Cloud-Native Event Streaming: GCP Pub/Sub + Azure Service Bus"
Subtitle: "Full complexity analysis · Why HTTPS (Approach 2) wins · When Approach 3 is the right call"

LAYOUT: Strictly top-to-bottom vertical flowchart.
Primary decision flow runs down the center.
Complexity costs hang LEFT and RIGHT as annotated side panels.
Bottom tier shows the Decision Matrix and Recommended Hybrid pattern.
No left-to-right main axis.

======================================================================
SECTION A — TOP: MUTATION + INTERNAL BUS (same as Approaches 1 & 2)
======================================================================

Horizontal band label: "INTERNAL EVENT BUS — identical across all three approaches"

Three boxes stacked vertically, staggered with down-merge arrows (blue):
  Box A1: "unhygienix — Question mutations (CRUD Interceptor)"
  Box A2: "unhygienix — Data Connection mutations (CRUD Interceptor)"
  Box A3: "cronos / picanmix — Export Job mutations (status hook)"

Three arrows converge DOWN to:

Box A4 (purple):
  Title: "CRUD Interceptor + object_events table"
  Sub-label: "[SAME DB TRANSACTION] Diff → INSERT object_events → COMMIT"
  Side annotation RIGHT: "Identical to Approaches 1 & 2. One interceptor, built once."

Arrow DOWN (labeled "[POST COMMIT ~1ms]"):

Box A5 (orange):
  Title: "AWS SNS Topic — habu-object-events (picanmix)"
  SNS Message Attributes:
    cleanroom_id, org_id, object_type
  Sub-label: "SNS = Habu's internal event bus. Always lives inside Habu AWS account."
  Side annotation LEFT (teal):
    "IMPORTANT: SNS and SQS are INTERNAL to Habu.
     They are the delivery backbone — not the consumer-facing interface.
     Approach 3 proposes crossing this boundary.
     Approach 2 keeps this boundary and uses HTTPS externally."

======================================================================
SECTION B — APPROACH 3 FAN-OUT: THREE CLOUD TARGETS
Label: "Approach 3 proposes: SNS cross-account subscriptions direct to consumer cloud queues"
======================================================================

SNS Topic fans into THREE branches descending vertically:

LEFT BRANCH (orange, GCP):
  Box B1: "GCP Pub/Sub Topic
            habu-cleanroom-events-xmi
            (cross-cloud SNS → Pub/Sub bridge)"
  Arrow DOWN:
  Box B2 (orange):
    "XMI Event Receiver — GCP project
     Reads natively from Pub/Sub
     GCP IAM service account: habu-publisher@habu-prod.iam.gserviceaccount.com
     No inbound HTTPS required"

  COMPLEXITY PANEL — hang LEFT of B1+B2 (large RED box):
    "WHAT HABU MUST PROVISION FOR GCP (per new consumer):
     ─────────────────────────────────────────────────
     1. Create GCP Pub/Sub topic in Habu GCP project
     2. Grant XMI service account roles/pubsub.subscriber
     3. Build SNS→Pub/Sub bridge (custom Lambda or 3rd-party relay)
        — AWS SNS cannot natively publish to GCP Pub/Sub
        — Requires: SNS → SQS → Lambda → GCP Pub/Sub HTTP push
        — Lambda must hold GCP service account key (secret mgmt sprawl)
     4. Handle GCP IAM key rotation: XMI rotates → Habu loses publish silently
     5. Monitor cross-cloud delivery latency (adds 50–200ms vs intra-AWS)
     6. Egress cost: AWS → GCP data transfer = $0.08/GB (100K events/day ≈ $15/mo per consumer)
     7. Org isolation: filter by Pub/Sub message attribute OR separate topic per consumer
        — Separate topic = N topics for N consumers
        — Message attribute filter = complex SNS filter policy per consumer"

CENTER BRANCH (blue, AWS):
  Box B3: "SQS Queue — sqs-habu-internal (Habu services)
            Same AWS account — no cross-cloud complexity
            Used by: Habu ML pipeline, audit service, etc."
  Side annotation (green): "This is the ONLY part of Approach 3 that is genuinely simple.
                             Internal consumers in the same AWS account = zero overhead."

RIGHT BRANCH (yellow, Azure):
  Box B4: "Azure Service Bus Topic
            habu-cleanroom-events-msft
            (future — MSFT on Azure)"
  Arrow DOWN:
  Box B5 (yellow):
    "MSFT Event Receiver — Azure subscription
     Reads natively from Service Bus
     Azure RBAC: Habu sends via Service Bus Data Sender role"

  COMPLEXITY PANEL — hang RIGHT of B4+B5 (large RED box):
    "WHAT HABU MUST PROVISION FOR AZURE (per new consumer):
     ─────────────────────────────────────────────────
     1. Create Azure Service Bus namespace + topic (Habu pays namespace cost)
     2. Configure RBAC: Azure AD app registration, Habu SP → Data Sender
     3. SNS → Azure Service Bus bridge:
        — No native AWS↔Azure bridge exists
        — Requires: SNS → SQS → Lambda → Azure Service Bus REST API
        — Different SDK: @azure/service-bus (npm) or azure-servicebus (Python)
     4. Handle Azure AD token rotation (client secret or managed identity)
     5. Org isolation: separate namespace per consumer OR topic-level filters
     6. Cross-cloud latency: AWS us-east-1 → Azure East US ≈ 5–15ms overhead
     7. Compliance: data leaving AWS — confirm with legal for SOC2 cross-cloud flow"

======================================================================
SECTION C — COMPLEXITY SUMMARY PANEL (center spine, large RED band)
======================================================================

Wide horizontal RED box spanning full width:
  Title: "APPROACH 3 COMPLEXITY COST — WHAT YOU ARE ACTUALLY BUYING"
  Table (monospace, full-width):
    ┌─────────────────────────┬────────────────────────────────────┬──────────────────────────────────┐
    │  Dimension              │  Approach 3 (cloud-native queues)  │  Approach 2 (HTTPS webhook)      │
    ├─────────────────────────┼────────────────────────────────────┼──────────────────────────────────┤
    │  XMI setup              │  GCP Pub/Sub + IAM + bridge Lambda │  HTTPS endpoint + HMAC verify    │
    │  MSFT setup             │  Azure SDK + Service Bus + RBAC    │  Same HTTPS pattern as XMI       │
    │  New consumer (MI team) │  New cloud-specific SDK + infra    │  New SQS subscription only       │
    │  Habu code change       │  New SDK branch per cloud          │  Zero — generic HTTP worker      │
    │  Org isolation          │  SNS filter policy (per topic)     │  JWT org_id claim (automatic)    │
    │  Vendor neutral?        │  NO — different SDK per cloud      │  YES — plain HTTPS + CloudEvents │
    │  CloudEvents adoption   │  Bypass: queues use native format  │  CNCF spec, GCP/Azure/AWS native │
    │  Egress cost            │  $0.08/GB cross-cloud transfer     │  Zero — stays in AWS             │
    │  Service acct rotation  │  Silent failure risk               │  Signing secret rotation via API │
    │  Future cloud (Oracle?) │  New SDK to build                  │  Zero change                     │
    │  Delivery audit         │  CloudWatch per queue (fragmented) │  delivery_log table (unified)    │
    └─────────────────────────┴────────────────────────────────────┴──────────────────────────────────┘

  Bottom note (bold red):
    "VENDOR NEUTRALITY VERDICT:
     The CNCF CloudEvents spec was adopted specifically so that event producers
     do not need separate SDKs per cloud. GCP Eventarc, Azure Event Grid, and
     AWS EventBridge all consume CloudEvents v1.0 natively.
     Approach 3 bypasses CloudEvents and reintroduces the per-cloud SDK problem
     that CloudEvents was designed to eliminate.
     Approach 2 + CloudEvents envelope = portable on any cloud, zero rework."

======================================================================
SECTION D — DECISION TREE (center spine)
======================================================================

Diamond decision node (large, bold border):
  "Does the consumer contractually prohibit exposing an inbound HTTPS endpoint?"

  Branch YES (right, red arrow):
  Box D1 (red):
    "Negotiate Approach 3 as a PREMIUM TIER
     ─────────────────────────────────────
     Charge for: cross-cloud infra, per-SDK maintenance, SLA overhead.
     Document it as a bespoke integration, not the standard product.
     Require: legal sign-off on cross-cloud data residency.
     Assign: dedicated Habu SRE per cloud target."

  Branch NO (left, green arrow, WIDE):
  Box D2 (green):
    "Use Approach 2 — HTTPS Webhook + CloudEvents
     ─────────────────────────────────────────────
     XMI on GCP:  Cloud Run endpoint — trivial, no firewall rule needed
     MSFT on Azure: Azure Container Apps endpoint — same pattern
     Any future consumer: Same HTTPS worker, zero code change in Habu
     Result: one delivery worker, all consumers, all clouds."

======================================================================
SECTION E — RECOMMENDED HYBRID ARCHITECTURE (bottom, teal)
======================================================================

Wide teal box spanning full width:
  Title: "RECOMMENDED HYBRID — Best of Approach 2 + Approach 3"
  Sub-label: "SNS is the internal bus. HTTPS is the external interface. These are complementary, not competing."

  Vertical mini-diagram inside the teal box:
    [unhygienix CRUD Interceptor]
           ↓  [POST COMMIT, non-blocking]
    [AWS SNS — habu-object-events]    ← INTERNAL BUS (Approach 3 spine, stays in AWS)
           ↓
    [SQS per consumer]                ← INTERNAL QUEUE (fan-out, consumer isolation)
           ↓
    [Callback Delivery Worker]        ← SINGLE WORKER, cloud-agnostic
           ↓  [HTTPS + CloudEvents v1.0]
    [Any consumer, any cloud]         ← XMI (GCP) · MSFT (Azure) · future (any)

  Three callout bullets:
    "SNS/SQS absorbs burst traffic and provides delivery guarantee inside AWS — its strength."
    "HTTPS delivery worker is stateless, cloud-agnostic, O(1) code per new consumer — its strength."
    "CloudEvents envelope means GCP, Azure, and AWS EventBridge all consume the same payload natively."

======================================================================
SECTION F — WHEN APPROACH 3 IS THE RIGHT CALL (right strip, teal small)
======================================================================

Vertical panel on the right:
  Title: "When Approach 3 wins"
  Scenario 1 (green): "Internal consumers in Habu AWS account
                        → direct SQS subscription, zero overhead
                        → ML pipeline, audit service, activity feed backend"
  Scenario 2 (yellow): "Enterprise customer contractually prohibits inbound HTTPS
                         → premium tier, bespoke contract, dedicated SRE"
  Scenario 3 (blue): "Consumer is already on AWS and owns an SQS queue
                       → cross-account SQS subscription: simplest case of Approach 3"
  Scenario 4 (red): "Any other case → default to Approach 2 + CloudEvents"

COLOR SPEC: Blue = mutation layer + AWS internal, Purple = interceptor + event store,
Orange = GCP / XMI path, Yellow = Azure / MSFT path, Red = complexity warnings + failure,
Green = recommended path + internal-only consumers, Teal = hybrid recommendation + CloudEvents note.
All red complexity panels are LARGE and PROMINENT — they are the key decision input.
Monospace for all schema, code, HTTP, tables.
This is a TOP-TO-BOTTOM vertical diagram. Arrows point DOWN the center spine.
Side panels hang LEFT and RIGHT, connected with horizontal annotation lines, not main flow arrows.
```