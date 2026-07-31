# Miro Prompts — Final TLM Presentation, DV-13856 Cleanroom Observability
**Date:** 2026-06-01
**Author:** Aditya Bhardwaj
**Audience:** TLM (Jon Chua, Shruthi, Ravindra)
**Purpose:** Two focused diagrams — one per approach — using real service names, real IDs, real schema

---

## Prompt 1 — Pull API: SNS Fan-In → object_events → gRPC → external-api-server → XMI

```
Create an enterprise architecture flowchart titled:
"Approach 1 — Event Processing Layer Powers the Pull API"
Subtitle: "SNS fan-in · unhygienix gRPC (GetCleanroomEvents) · external-api-server REST · XMI cursor-based polling"

LAYOUT: Strictly TOP-TO-BOTTOM vertical flowchart. Center spine flows downward.
Boxes stack vertically on the center spine. Side annotations hang LEFT or RIGHT.
Service labels, schema blocks, and payload examples are side panels — NOT in the main flow.
This is a vertical diagram. No left-to-right axis.

======================================================================
SECTION A — HORIZONTAL BAND (dark blue header bar, full width):
"MUTATION LAYER — Three services, one SNS topic"
======================================================================

Three boxes arranged horizontally across the top, each a distinct color, rounded corners, drop shadow:

  Box A1 (blue):
    Title: "unhygienix"
    Body:
      QUESTION mutation
      ── sqlQuery changed
      ── status: DRAFT → PUBLISHED
      ── dataset assignment changed
      Real example: question "Revenue Analysis"
      id: d94ccaeb-d0f9-4665-8a42-378f9f030f57

  Box A2 (teal):
    Title: "forebitt"
    Body:
      DATA_CONNECTION mutation
      ── stage: MAPPING_REQUIRED → CONFIGURATION_COMPLETE
      ── field type changed: FLOAT64 → STRING
      Real example: "cvs_lcr-modified_txns_hq"
      id: 97b6cf60-f8be-48aa-b7a0-ec112c1fb801

  Box A3 (orange):
    Title: "picanmix / cronos"
    Body:
      EXPORT_JOB mutation
      ── destination: s3://a/a.bcs → s3://b/b.abc
      ── runStatus: RUNNING → COMPLETED
      Real example: "TestGCSnetwork / Q1"
      id: c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4

  Side annotation RIGHT of A1+A2+A3 (gray sticky):
    "Each service publishes to SNS post-commit (~1ms after DB COMMIT).
     No service calls another service directly.
     forebitt never calls unhygienix. Zero circular dependency."

All three boxes merge into a single DOWN arrow labeled:
  "[POST COMMIT — non-blocking, ~1ms]
   sns.publish(topic='habu-object-events', attributes={cleanroom_id, org_id, object_type})"

======================================================================
SECTION B — CENTER SPINE BOX (orange, large):
"AWS SNS Topic — habu-object-events"
======================================================================

Box B1 (orange, center spine):
  Title: "AWS SNS — habu-object-events"
  Body:
    Internal event bus — stays inside Habu AWS account.
    SNS Message Attributes:
      cleanroom_id: cr-abc
      org_id:       02617c50-a923-4877-a968-6465d5d2baaa
      object_type:  DATA_CONNECTION

  Side annotation LEFT (gray sticky):
    "SNS filter policy routes per-org events to dedicated SQS queues.
     XMI org events never appear in MI queue. Isolation enforced at AWS level."

Arrow DOWN labeled: "SNS → SQS subscription (Habu internal)"

======================================================================
SECTION C — CENTER SPINE BOX (purple, large):
"SQS Consumer in unhygienix — Writes to object_events"
======================================================================

Box C1 (purple, large, center spine):
  Title: "SQS Consumer — unhygienix service"
  Sub-label: "Reads from sqs-habu-object-events-internal. Owned by unhygienix."
  Body — three numbered steps:
    [1] receiveMessage from SQS
    [2] Compute changedFields diff: { field: { from: X, to: Y } }
        Same uniform shape for ALL object types — no branching.
    [3] INSERT INTO object_events (atomic, append-only)

  Schema block inside box (monospace, gray background):
    object_events table (unhygienix PostgreSQL):
    ┌─────────────────────────────────────────────────────┐
    │ event_id        UUID    PK  (idempotency key)       │
    │ cursor_position BIGINT  monotonic SEQUENCE          │
    │ org_id          UUID    FK — org isolation          │
    │ cleanroom_id    UUID    FK                          │
    │ object_type     VARCHAR QUESTION/DATA_CONNECTION/   │
    │                         EXPORT_JOB                  │
    │ object_id       UUID    entity being tracked        │
    │ object_name     VARCHAR snapshot at time of event   │
    │ event_type      VARCHAR com.habu.cleanroom.*.*      │
    │ change_type     VARCHAR CREATED/UPDATED/DELETED     │
    │ changed_fields  JSONB   { field: {from, to} }       │
    │ performed_by    VARCHAR email or system:<svc>       │
    │ schema_version  INT     1 (bumped on breaking Δ)   │
    │ event_time      TIMESTAMPTZ wall-clock UTC          │
    └─────────────────────────────────────────────────────┘
    Append-only. REVOKE UPDATE, DELETE FROM unhygienix_app.

  Side annotation RIGHT — three real changed_fields examples (yellow sticky, monospace):

    DATA_CONNECTION stage change:
    "changedFields": {
      "stage": { "from": "MAPPING_REQUIRED",
                 "to":   "CONFIGURATION_COMPLETE" }
    }

    QUESTION sql change:
    "changedFields": {
      "sqlQuery": {
        "from": "SELECT ramp_id, purchase_date
                  FROM adidas_data WHERE amount > 100",
        "to":   "SELECT ramp_id, purchase_date, shoe_category
                  FROM adidas_data WHERE amount > 50"
      }
    }

    EXPORT_JOB destination change:
    "changedFields": {
      "destination": { "from": "s3://a/a.bcs",
                       "to":   "s3://b/b.abc" }
    }

    Note below (teal callout):
      "Uniform { from, to } shape for ALL 3 object types.
       Consumer parses with one loop — no switch(objectType) branching.
       Same pattern as Stripe Events and GitHub Webhooks."

Arrow DOWN labeled: "[SAME DB TRANSACTION — atomic rollback guaranteed]"

======================================================================
SECTION D — CENTER SPINE BOX (purple, medium):
"gRPC Endpoint — CleanroomEventService (unhygienix)"
======================================================================

Box D1 (purple, center spine):
  Title: "gRPC — CleanroomEventService.GetCleanroomEvents"
  Sub-label: "Defined in proto/unhygienix/events.proto. Served by unhygienix."
  Body (monospace):
    rpc GetCleanroomEvents(GetCleanroomEventsRequest)
        returns (GetCleanroomEventsResponse)

    Request fields:
      cleanroom_id : string  (required)
      since_cursor : int64   (0 = from beginning)
      object_type  : string  ("" = all types)
      limit        : int32   (max 100, default 25)
      org_id       : string  (injected from JWT — never trusted from caller)

    Response fields:
      events[]     : ObjectEvent  (repeated — the batch)
      next_cursor  : int64        (pass as since_cursor next call)
      has_more     : bool         (false = consumer is caught up)

  Side annotation LEFT (green sticky):
    "Two callers of this endpoint:
     1. topgallant (React UI) — internal gRPC, no auth header, VPC-only
     2. external-api-server — translates to REST for XMI

     One endpoint. Two consumers. Zero duplication."

TWO arrows split from D1 — one LEFT, one RIGHT — each pointing DOWN:

LEFT arrow (green) labeled: "Internal gRPC — topgallant (React UI)"
  Box D2 (green, left of spine):
    Title: "Activity Feed Tab — topgallant"
    Body (wireframe UI style):
      [All Types ▼]  [All Users ▼]  [Last 30 days ▼]

      ● 2026-05-12  sarah@acme.com
        DATA CONNECTION "cvs_lcr-modified_txns_hq"
        stage: MAPPING_REQUIRED → CONFIGURATION_COMPLETE

      ● 2026-05-11  sreekar.s@liveramp.com
        EXPORT JOB "TestGCSnetwork / Q1"
        destination: s3://a/a.bcs → s3://b/b.abc

      ● 2026-05-10  sarah@acme.com
        QUESTION "Revenue Analysis" — SQL CHANGED
        WHERE amount > 100 → WHERE amount > 50

    Sub-label: "Every Habu user sees this. Zero setup. Ships with V1."

RIGHT arrow (orange) labeled: "REST Translation — external-api-server"

======================================================================
SECTION E — CENTER SPINE BOX (orange, large):
"external-api-server — REST Endpoint"
======================================================================

Box E1 (orange, center spine):
  Title: "external-api-server"
  Sub-label: "Translates gRPC ObjectEvent → CloudEvents v1.0 JSON. Adds JWT org filter."
  Body (monospace):
    GET /v1/cleanrooms/{cleanroomId}/events
        ?since=eyJsYXN0X2N1cnNvciI6NDgyMX0=
        &objectType=DATA_CONNECTION
        &limit=50
    Authorization: Bearer <XMI JWT>
    Accept: application/cloudevents-batch+json

  Auth flow annotation RIGHT (gray sticky):
    "JWT contains org_id claim.
     external-api-server injects org_id into gRPC request.
     unhygienix filters WHERE org_id = claim.
     XMI sees only XMI org events. MSFT sees only MSFT events.
     No per-customer config needed."

  Rate-limit annotation LEFT (gray sticky):
    "Rate limit: 120 req/min per org (token-bucket)
     Response headers:
       X-RateLimit-Limit:     120
       X-RateLimit-Remaining: 87
       X-RateLimit-Reset:     1715521260
     ETag + 304 Not Modified on no new events → zero body transfer."

Arrow DOWN labeled: "HTTPS response — CloudEvents v1.0 batch"

======================================================================
SECTION F — CENTER SPINE BOX (yellow, large):
"CloudEvents v1.0 Response Payload — what XMI receives"
======================================================================

Box F1 (yellow, center spine, monospace interior):
  Title: "CloudEvents v1.0 Response — CNCF standard envelope"

  HTTP/1.1 200 OK
  Content-Type: application/cloudevents-batch+json
  ETag: "W/\"4823\""
  X-Next-Cursor: eyJsYXN0X2N1cnNvciI6NDgyM30=

  [
    {
      "specversion":     "1.0",
      "id":              "evt-b2c3d4e5-f6a7-8901-bcde-f12345678901",
      "source":          "urn:habu:cleanroom:cr-abc",
      "type":            "com.habu.cleanroom.data_connection.updated",
      "time":            "2026-02-05T04:18:35.095472Z",
      "datacontenttype": "application/json",
      "schemaurl":       "https://schema.habu.com/events/v1/cleanroom_object_event.json",
      "traceparent":     "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      "data": {
        "orgId":       "02617c50-a923-4877-a968-6465d5d2baaa",
        "cleanroomId": "cr-abc",
        "objectType":  "DATA_CONNECTION",
        "objectId":    "97b6cf60-f8be-48aa-b7a0-ec112c1fb801",
        "objectName":  "cvs_lcr-modified_txns_hq",
        "changeType":  "UPDATED",
        "changedFields": {
          "stage": { "from": "MAPPING_REQUIRED",
                     "to":   "CONFIGURATION_COMPLETE" }
        },
        "performedBy":   "sreekar.s@liveramp.com",
        "schemaVersion": 1,
        "cursor":        "eyJsYXN0X2N1cnNvciI6NDgyM30="
      }
    }
  ]

  Side annotation RIGHT (teal callout box — make it PROMINENT):
    "VENDOR NEUTRALITY — CNCF CloudEvents v1.0:
     ● GCP Eventarc:      consumes this JSON natively
     ● Azure Event Grid:  consumes this JSON natively
     ● AWS EventBridge:   consumes this JSON natively (GA 2023)

     Our payload works on any cloud XMI or any future partner runs on.
     Zero field transformation. Zero per-cloud SDK.
     This is why we chose CloudEvents over a custom envelope."

======================================================================
SECTION G — CENTER SPINE BOX (green, large):
"XMI Polling Client — Google Cloud"
======================================================================

Box G1 (green, center spine):
  Title: "XMI UI — Cursor-Based Poller (Google Cloud)"
  Body — numbered steps:
    [1] Poll GET /v1/cleanrooms/{id}/events?since=<cursor> every 60s
    [2] On 304 Not Modified (ETag matched) → no new events, advance timer
    [3] On 200 → deserialize CloudEvents batch
    [4] For each event: read changedFields { field: { from, to } }
        No switch(objectType) needed — uniform shape for all types
    [5] Persist next_cursor to Redis (TTL 30d) for crash recovery
    [6] Trigger downstream: invalidate cache, update UI, pause workflows

  Side annotation LEFT (blue sticky):
    "Zero XMI infrastructure required:
     ✓ No inbound HTTPS endpoint
     ✓ No firewall rule / no inbound port
     ✓ No server to deploy
     XMI engineers only need a scheduled job (Cloud Scheduler + Cloud Run)
     that calls our REST API every 60s."

======================================================================
SECTION H — BOTTOM SCORECARD (full width, two boxes side by side)
======================================================================

Box H1 (green, left half):
  Title: "Why This Approach — V1 Ship List"
  ✓ One gRPC endpoint (unhygienix) powers Activity Feed UI + External REST API
  ✓ SNS fan-in: unhygienix, forebitt, picanmix publish to SNS — no cross-service gRPC
  ✓ forebitt never calls unhygienix — zero circular dependency
  ✓ CNCF CloudEvents: same JSON on GCP, Azure, AWS — zero cloud-specific code
  ✓ Org isolation via JWT org_id claim — automatic, zero per-customer config
  ✓ Uniform changedFields { from, to } — one consumer parser for all 3 object types
  ✓ cursor_position SEQUENCE — no missed events on reconnect
  ✓ ETag + 304 Not Modified — zero bandwidth on idle poll cycles
  ✓ Activity Feed UI ships simultaneously — platform utility from day 1

Box H2 (yellow, right half):
  Title: "Known Trade-offs"
  △ Change latency = polling interval (30–60s)
    → Acceptable for V1. Approach 2 (webhook) adds sub-second push in V2.
  △ XMI must persist cursor across restarts
    → Mitigated: cursor in every response + Redis TTL 30d
  △ Wasted HTTP calls when nothing changed
    → Mitigated: ETag + 304 Not Modified (zero body on idle)

COLOR SPEC:
  Blue = unhygienix service, Teal = forebitt, Orange = SNS + picanmix + external-api-server,
  Purple = SQS consumer + gRPC layer, Yellow = CloudEvents payload,
  Green = XMI client + Activity Feed + scorecard, Teal callout = CNCF vendor-neutrality.
Monospace font for all schema, SQL, proto, HTTP, JSON blocks.
Drop shadows on all primary spine boxes. Directional arrow labels on every edge.
TOP-TO-BOTTOM vertical diagram. All main arrows point DOWNWARD.
Side annotations connect to spine boxes with horizontal dashed lines.
```

---

## Prompt 2 — Push API: XMI Registers Webhook → Habu Pushes CloudEvents on Every Mutation

```
Create an enterprise architecture flowchart titled:
"Approach 2 — Webhook Callback Registration (Push)"
Subtitle: "XMI registers once · Habu signs and pushes CloudEvents on every mutation · Sub-second latency"

LAYOUT: Strictly TOP-TO-BOTTOM vertical flowchart.
THREE swim-lane columns run the full height of the diagram.
Horizontal phase-band labels (bold, full-width) divide the diagram into tiers.
All arrows within a lane point DOWNWARD. Cross-lane arrows are HORIZONTAL.
This is a vertical swimlane diagram. No left-to-right main axis.

THREE vertical swimlanes, labeled at top:
  Lane 1 (orange):  "XMI — Google Cloud (Consumer)"
  Lane 2 (blue):    "Habu Platform — unhygienix + external-api-server (AWS us-east-1)"
  Lane 3 (purple):  "Async Delivery — SNS → SQS → Callback Worker (Habu AWS)"

======================================================================
PHASE 1 BAND (bold, full-width): "ONE-TIME SETUP — XMI registers callback endpoint"
======================================================================

[Lane 1 — orange]
Box 1.1:
  "XMI Engineer registers once via API"
  HTTP request (monospace):
    POST /v1/cleanrooms/{crId}/callbacks
    Authorization: Bearer <platform-jwt>

    {
      "objectType":      "DATA_CONNECTION",
      "objectId":        null,
      "callbackUrl":     "https://events.xmi.liveramp.com/habu-webhook",
      "monitoredFields": ["stage", "destination", "sqlQuery"],
      "authConfig": {
        "authType":  "BEARER",
        "authValue": "eyJhbGci..."
      }
    }

  Annotation below:
    "objectId: null = subscribe to ALL data connections in this cleanroom.
     monitoredFields: only fire delivery when these specific fields change.
     XMI won't be notified for fields they don't care about."

Horizontal arrow RIGHT → Lane 2

[Lane 2 — blue]
Box 1.2:
  "external-api-server — Registration Handler"
  Validation steps:
    [1] Verify platform JWT (org_id claim, scope: callbacks:write)
    [2] HEAD callbackUrl → expect 200 (endpoint reachability check)
    [3] Generate signingSecret: CSPRNG 32-byte → whsec_a3f9c2d1...
    [4] KMS envelope-encrypt: callbackUrl, authConfig, signingSecret at rest

Arrow DOWN in Lane 2:

Box 1.3 (monospace schema block):
  "callback_registrations table (unhygienix DB)"
  ┌──────────────────────────────────────────────────┐
  │ id               UUID   PK  cb-456-uuid          │
  │ org_id           UUID   02617c50-a923-...         │
  │ cleanroom_id     UUID   cr-abc                    │
  │ object_type      VARCHAR DATA_CONNECTION          │
  │ object_id        UUID   NULL (= all DCs)          │
  │ monitored_fields TEXT[] {stage, destination, ...} │
  │ callback_url     TEXT   KMS-encrypted             │
  │ signing_secret   VARCHAR whsec_a3f9c2... KMS-enc  │
  │ status           VARCHAR ACTIVE                   │
  │ failure_count    INT    0                         │
  └──────────────────────────────────────────────────┘

Horizontal arrow RIGHT → Lane 1:

[Lane 1 — orange]
Box 1.4:
  HTTP 201 Created response (monospace):
    {
      "id":            "cb-456-uuid",
      "signingSecret": "whsec_a3f9c2d1e4b7...",
      "status":        "ACTIVE"
    }
  Red sticky note:
    "signingSecret shown ONCE in 201 response.
     XMI stores it in GCP Secret Manager.
     Used to verify every future inbound event is genuinely from Habu.
     Habu never shows it again — not even to Habu engineers."

======================================================================
PHASE 2 BAND (bold, full-width): "RUNTIME — mutation fires, Habu delivers within 2 seconds"
======================================================================

[Lane 2 — blue]
Box 2.1:
  "sreekar.s@liveramp.com changes DATA_CONNECTION stage"
  DB write sequence (monospace):
    BEGIN TRANSACTION
      [1] forebitt interceptor: snapshot BEFORE state
      [2] UPDATE data_connections SET stage='CONFIGURATION_COMPLETE'
      [3] Build changedFields: {
            "stage": { "from": "MAPPING_REQUIRED",
                       "to":   "CONFIGURATION_COMPLETE" }
          }
      [4] INSERT INTO object_events (evt-a1b2...) ← ATOMIC
    COMMIT TRANSACTION
    → 200 OK to sreekar immediately. User NOT blocked.

Arrow DOWN in Lane 2:

Box 2.2:
  "Post-Commit Hook (~1ms after COMMIT)"
  pg_notify → picanmix event bridge → SNS publish

Horizontal arrow RIGHT → Lane 3, labeled:
  "SNS publish: habu-object-events
   Attributes: cleanroom_id=cr-abc, org_id=02617c50, object_type=DATA_CONNECTION"

======================================================================
PHASE 3 BAND (bold, full-width): "ASYNC DELIVERY — SNS → SQS → Worker → XMI"
======================================================================

[Lane 3 — purple]
Box 3.1:
  "AWS SNS — habu-object-events"
  SNS filter policy routes to:
    sqs-habu-delivery-xmi  ← XMI org events only

Arrow DOWN:

Box 3.2:
  "SQS — sqs-habu-delivery-xmi (dedicated per consumer)"
  Config:
    Visibility Timeout:   30s
    Message Retention:    4 days
    Max Receive Count:    5 → then DLQ
    Encryption:           SSE-SQS (AWS KMS)

  Red side panel (LEFT of Box 3.2):
    "CONSUMER ISOLATION:
     sqs-habu-delivery-xmi failure or XMI outage
     has ZERO effect on sqs-habu-delivery-mi
     or sqs-habu-delivery-safehaven.
     Separate queue. Separate DLQ. Separate alarm."

Arrow DOWN:

Box 3.3 (large, detailed):
  "Callback Delivery Worker — ECS Fargate"
  Execution steps (monospace, numbered):
    [1] receiveMessage → visibility timeout 30s (hidden, not deleted)
    [2] Query callback_registrations WHERE cleanroom=cr-abc
        AND object_type=DATA_CONNECTION → cb-456 matched
    [3] changedFields ∩ monitoredFields = {"stage"} → non-empty → proceed
        (if empty → skip, deleteMessage, done — no delivery)
    [4] Build CloudEvents v1.0 payload from evt-a1b2...
    [5] Sign payload:
          timestamp    = 1715521200 (Unix epoch)
          signed_body  = SHA-256(raw_payload)
          signature    = HMAC-SHA256(signingSecret, timestamp + "." + signed_body)
          header       = "t=1715521200,v1=a3f9c2d1..."
    [6] HTTP POST → https://events.xmi.liveramp.com/habu-webhook
          Headers:
            Authorization:    Bearer eyJhbGci...
            X-Habu-Signature: t=1715521200,v1=a3f9c2d1...
            X-Habu-Event-Id:  evt-a1b2c3d4-uuid
            Content-Type:     application/cloudevents+json
          Timeout: 30s
    [7] HTTP 2xx → deleteMessage from SQS (explicit ACK)
        write delivery_log: {attempt:1, status:200, latency:45ms, outcome:SUCCESS}
    [8] HTTP 5xx or timeout → do NOT delete → reappears after 30s → retry

Arrow DOWN:

Box 3.4 (monospace JSON, yellow background):
  Title: "CloudEvents v1.0 — Delivered to XMI"
  {
    "specversion":     "1.0",
    "id":              "evt-a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "source":          "urn:habu:cleanroom:cr-abc",
    "type":            "com.habu.cleanroom.data_connection.updated",
    "time":            "2026-02-05T04:18:35.095472Z",
    "datacontenttype": "application/json",
    "schemaurl":       "https://schema.habu.com/events/v1/cleanroom_object_event.json",
    "traceparent":     "00-4bf92f3577b34da6a3ce929d0e0e4736-b7ad6b7169203331-01",
    "data": {
      "orgId":       "02617c50-a923-4877-a968-6465d5d2baaa",
      "objectType":  "DATA_CONNECTION",
      "objectId":    "97b6cf60-f8be-48aa-b7a0-ec112c1fb801",
      "objectName":  "cvs_lcr-modified_txns_hq",
      "changeType":  "UPDATED",
      "changedFields": {
        "stage": { "from": "MAPPING_REQUIRED",
                   "to":   "CONFIGURATION_COMPLETE" }
      },
      "performedBy":   "sreekar.s@liveramp.com",
      "schemaVersion": 1,
      "idempotencyKey":"sha256-7f83b1657ff1fc53b92dc18148a1d65d"
    }
  }

  Side annotation RIGHT (teal callout — PROMINENT):
    "VENDOR NEUTRALITY — CNCF CloudEvents v1.0:
     GCP Eventarc, Azure Event Grid, AWS EventBridge
     all consume this payload natively.
     XMI is on GCP. MSFT will be on Azure.
     Both receive identical JSON — zero transformation."

Arrow DOWN (crosses Lane 3 → Lane 1 horizontally):

======================================================================
PHASE 4 BAND (bold, full-width): "XMI RECEIVES — verify, deduplicate, process"
======================================================================

[Lane 1 — orange]
Box 4.1:
  "XMI Webhook Receiver — Cloud Run (GCP)"
  Verification steps (numbered):
    [1] Parse X-Habu-Signature: extract t= and v1=
    [2] Reject if abs(now - t) > 300s → replay attack window
    [3] Recompute HMAC-SHA256(signingSecret, t + "." + SHA-256(body))
    [4] Constant-time compare with v1 value
    [5] Mismatch → 401 Unauthorized
        (Worker will NOT retry 4xx — message ACK'd and dropped)

Arrow DOWN:

Box 4.2:
  "Deduplication Guard — Redis (GCP Memorystore)"
  key: "habu:evt:evt-a1b2c3d4-uuid"    TTL: 7 days
  SET NX → already exists → return 200 (idempotent ACK, skip processing)
  Sub-label: "Handles SQS at-least-once delivery safely."

Arrow DOWN:

Box 4.3:
  "Business Logic — XMI downstream"
  Read changedFields:
    stage.from = "MAPPING_REQUIRED"
    stage.to   = "CONFIGURATION_COMPLETE"
  → Invalidate cleanroom schema cache for cr-abc
  → Mark data connection as ready for question assignment
  → Emit internal XMI GCP Pub/Sub event for downstream pipeline
  → Return HTTP 200 within 30s (Habu worker timeout window)

======================================================================
PHASE 5 BAND (bold, full-width, RED): "FAILURE PATH — retries + DLQ"
======================================================================

[Lane 3 — purple]
Box 5.1 (red background):
  Title: "Retry + Dead Letter Queue"
  Exponential backoff (monospace):
    Attempt 1: immediate         → SQS visibilityTimeout = 30s
    Attempt 2: +30s jitter       → visibilityTimeout = 60s
    Attempt 3: +90s jitter       → visibilityTimeout = 180s
    Attempt 4: +270s jitter      → visibilityTimeout = 600s
    Attempt 5: maxReceiveCount=5 exceeded
    → Message moved to sqs-habu-dlq-xmi (Dead Letter Queue)

[Lane 2 — blue]
Box 5.2 (red border):
  "Habu SRE Alert"
  CloudWatch alarm: DLQ depth > 0
  → SNS alert → Slack #platform-alerts
  delivery_log record:
    { attempt: 5, status: 0, outcome: FAILURE_TERMINAL,
      error: "Connection refused: events.xmi.liveramp.com" }

[Lane 1 — orange]
Box 5.3 (red border):
  "XMI On-Call Alert"
  PagerDuty: team-xmi-oncall
  Source: sqs-habu-dlq-xmi CloudWatch alarm
  Sub-label: "Consumer owns their DLQ alarm. Habu does not page XMI — XMI pages themselves."

======================================================================
SECTION D — BOTTOM SCORECARD (full width, two boxes side by side)
======================================================================

Box D1 (green, left half):
  Title: "Why Approach 2 — What V2 adds on top of V1"
  ✓ Sub-second push latency — no 60s polling gap
  ✓ HMAC-SHA256 signed + replay-window: same security model as Stripe, GitHub, Twilio
  ✓ monitoredFields filter: XMI only gets notified for fields they care about
  ✓ Consumer isolation: XMI queue failure never affects MI or SafeHaven queues
  ✓ Self-service registration: API only, no Habu human involvement per new consumer
  ✓ delivery_log: queryable audit of every delivery attempt — SLA-provable
  ✓ traceparent (W3C): XMI can correlate their span to Habu's originating trace
  ✓ Adding MI team = new SQS subscription only — zero code change in unhygienix or forebitt
  ✓ CNCF CloudEvents: XMI (GCP) + MSFT (Azure) both consume identical JSON verbatim

Box D2 (yellow, right half):
  Title: "Trade-offs + Mitigations"
  △ XMI must expose HTTPS endpoint (inbound from Habu AWS)
    → Cloud Run (GCP) supports inbound HTTPS trivially — no VPN, no firewall rule
  △ At-least-once delivery (SQS) — duplicates possible
    → Mitigated: Redis dedup guard with 7-day TTL on event_id
  △ More sprints than Approach 1 alone
    → Mitigation: ship Approach 1 (Activity Feed + Pull API) as V1.
      Approach 2 (webhook push) as V2. Incremental — no rework.
  △ signingSecret rotation requires API call
    → Mitigated: PATCH /callbacks/{id} to rotate. XMI updates GCP Secret Manager.

COLOR SPEC:
  Orange = Lane 1 / XMI consumer, Blue = Lane 2 / Habu platform,
  Purple = Lane 3 / async infra, Red = failure/DLQ path,
  Green = scorecard / success, Yellow = CloudEvents payload,
  Teal callout = CNCF vendor-neutrality (make PROMINENT in both Phase 3 and scorecard).
Monospace font for all SQL, JSON, HTTP, proto, code blocks.
Bold horizontal phase-band labels span all three lanes.
Drop shadows on all primary boxes. Directional labels on every arrow.
TOP-TO-BOTTOM vertical swimlane diagram. Arrows within lanes go DOWN. Cross-lane arrows are HORIZONTAL.
```
