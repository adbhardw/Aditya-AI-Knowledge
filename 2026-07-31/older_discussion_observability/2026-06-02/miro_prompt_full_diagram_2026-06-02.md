# Miro Prompt — Full End-to-End Diagram (Complete Flow)
**Date:** 2026-06-02
**Author:** Aditya Bhardwaj
**Audience:** TLM (Jon Chua, Shruthi, Ravindra)
**Purpose:** Single comprehensive diagram — mutation → SNS → Option A/B internal architecture → external-api-server → Pull and Push consumption paths

---

## Prompt — Complete End-to-End: Event Capture + Internal Architecture Options + XMI Consumption

```
Create an enterprise architecture flowchart titled:
"DV-13856 — Cleanroom Observability: Full End-to-End Flow"
Subtitle: "Event capture · Two internal architecture options · Pull and Push delivery to XMI · CNCF CloudEvents v1.0"

LAYOUT: Strictly TOP-TO-BOTTOM vertical flowchart.
The diagram has TWO split points and TWO rejoin points — forming a shape like two hourglasses stacked:

  SPLIT 1 (after SNS):   Left = Option A (Pegleg→unhygienix) | Right = Option B (orinix)
  REJOIN 1:              external-api-server + CloudEvents payload (full width)
  SPLIT 2 (after payload): Left = Pull path (XMI polling) | Right = Push path (XMI webhook)
  REJOIN 2:              Decision scorecard (full width)

Bold dashed vertical dividers separate columns at each split.
All arrows within a column point DOWNWARD. Cross-column arrows are HORIZONTAL.
Side annotations hang outside the outer edges of each section.
Monospace font for all schema, proto, SQL, JSON, HTTP blocks.
Drop shadows on all primary boxes. Directional labels on every arrow.

======================================================================
SECTION A — TOP SHARED: MUTATION LAYER (full width)
Horizontal band label (dark blue, full width): "MUTATION LAYER — All three services publish to SNS. Fixed in both options."
======================================================================

Three boxes arranged horizontally, rounded corners, drop shadows:

  Box A1 (blue):
    Title: "unhygienix"
    QUESTION mutation
    ── sqlQuery changed
    ── status: DRAFT → PUBLISHED
    ── dataset assignment changed
    Example: question "Revenue Analysis"
    id: d94ccaeb-d0f9-4665-8a42-378f9f030f57

  Box A2 (teal):
    Title: "forebitt"
    DATA_CONNECTION mutation
    ── stage: MAPPING_REQUIRED → CONFIGURATION_COMPLETE
    ── field type: FLOAT64 → STRING
    Example: "cvs_lcr-modified_txns_hq"
    id: 97b6cf60-f8be-48aa-b7a0-ec112c1fb801

  Box A3 (orange):
    Title: "picanmix / cronos"
    EXPORT_JOB mutation
    ── destination: s3://a/a.bcs → s3://b/b.abc
    ── runStatus: RUNNING → COMPLETED
    Example: "TestGCSnetwork / Q1"
    id: c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4

  Side annotation RIGHT (gray sticky):
    "3 lines added per service — the full publishing cost:
       snsClient.publish(HABU_OBJECT_EVENTS_TOPIC, event.toJson())
     No service calls another service directly.
     forebitt never calls unhygienix. Zero circular dependency."

All three boxes merge into ONE down arrow labeled:
  "[POST COMMIT — non-blocking, ~1ms]
   sns.publish(topic='habu-object-events',
     attributes={cleanroom_id, org_id, object_type})"

======================================================================
SECTION B — SHARED: SNS TOPIC (full width)
======================================================================

Box B1 (orange, full width):
  Title: "AWS SNS — habu-object-events"
  Internal event bus. Stays inside Habu AWS account.
  SNS Message Attributes:
    cleanroom_id: cr-abc
    org_id:       02617c50-a923-4877-a968-6465d5d2baaa
    object_type:  DATA_CONNECTION

  Side annotation LEFT (gray sticky):
    "SNS filter policy isolates per consumer.
     XMI org events never appear in MI or SafeHaven queues.
     Isolation enforced at the AWS layer — not in application code."

Arrow DOWN labeled: "SNS → SQS subscription"

────────────────────────────────────────────────────────────────────
SPLIT POINT 1 — Draw bold dashed vertical divider.
Label at split: "⬅ Option A: Pegleg + unhygienix    |    Option B: orinix ➡"
────────────────────────────────────────────────────────────────────

======================================================================
SECTION C-LEFT — OPTION A: Pegleg + unhygienix (left column)
Column header band (dark blue): "Option A — Pegleg as Consumer · unhygienix owns object_events"
======================================================================

Box C-A1 (blue, left column):
  Title: "SQS — sqs-habu-object-events-internal"
  Pegleg subscribes. Visibility Timeout: 30s. Max Receive Count: 5 → DLQ.

Arrow DOWN:

Box C-A2 (blue, large, left column):
  Title: "Pegleg — SQS Consumer"
  Sub-label: "Pegleg already has @GrpcClient('unhygienix') — coupling pre-exists."
  Steps:
    [1] receiveMessage from SQS
    [2] build changedFields diff:
        { "stage": { "from": "MAPPING_REQUIRED",
                     "to":   "CONFIGURATION_COMPLETE" } }
    [3] gRPC → unhygienix.RecordEvent(event)
    [4] on gRPC success → deleteMessage (ACK)
    [5] on gRPC failure → do NOT delete → SQS retry

  Side annotation LEFT (red sticky):
    "⚠ Domain concern:
     Pegleg = query validation engine.
     Event routing is off-domain for Pegleg.
     Schema evolution touches Pegleg unnecessarily."

Arrow DOWN labeled: "gRPC: unhygienix.RecordEvent()"

Box C-A3 (blue, left column):
  Title: "unhygienix.RecordEvent() — NEW gRPC method"
  Proto:
    rpc RecordEvent(RecordEventRequest)
        returns (RecordEventResponse);

    message RecordEventRequest {
      string object_id    = 1;
      string object_type  = 2;
      string event_type   = 3;
      string changed_by   = 4;
      string org_id       = 5;
      string cleanroom_id = 6;
      bytes  before_state = 7;
      bytes  after_state  = 8;
    }

Arrow DOWN:

Box C-A4 (blue, left column):
  Title: "object_events — unhygienix PostgreSQL"
  Sub-label: "Lives inside unhygienix DB. unhygienix owns migrations."
  Schema (compact monospace):
    event_id        UUID   PK
    cursor_position BIGINT SEQUENCE (monotonic)
    org_id          UUID   org-scoped
    cleanroom_id    UUID
    object_type     VARCHAR QUESTION|DATA_CONNECTION|EXPORT_JOB
    object_id       UUID
    event_type      VARCHAR com.habu.cleanroom.*.*
    change_type     VARCHAR CREATED|UPDATED|DELETED
    changed_fields  JSONB   { field: {from, to} }
    performed_by    VARCHAR email or system:<svc>
    schema_version  INT     1
    event_time      TIMESTAMPTZ

  Side annotation LEFT (red sticky):
    "Future webhook infra also lands in unhygienix:
     callback_registrations → unhygienix DB
     delivery_log           → unhygienix DB
     Schema changes require unhygienix deployment."

Arrow DOWN labeled: "gRPC: unhygienix.GetCleanroomEvents()"

Box C-A5 (blue, left column):
  Title: "unhygienix.GetCleanroomEvents() — NEW gRPC method"
  Proto:
    rpc GetCleanroomEvents(GetCleanroomEventsRequest)
        returns (GetCleanroomEventsResponse);
    message GetCleanroomEventsRequest {
      string cleanroom_id = 1;
      string org_id       = 2;  // injected from JWT
      int64  since_cursor = 3;
      string object_type  = 4;
      int32  limit        = 5;
    }

======================================================================
SECTION C-RIGHT — OPTION B: orinix new service (right column)
Column header band (purple): "Option B — orinix: Dedicated Observability Service"
======================================================================

Box C-B1 (purple, right column):
  Title: "SQS — sqs-habu-object-events-internal"
  orinix subscribes. Same queue config.

Arrow DOWN:

Box C-B2 (purple, large, right column):
  Title: "orinix — SQS Consumer + gRPC Server"
  Sub-label: "Single-responsibility service. Owns all observability logic."
  Directory:
    orinix/
    ├── proto/     events.proto (GetCleanroomEvents, RecordEvent)
    ├── consumer/  SqsEventConsumer (reads SQS, writes object_events)
    ├── db/        object_events (own PostgreSQL DB, own migrations)
    └── server/    EventServiceImpl (serves GetCleanroomEvents gRPC)

  Steps:
    [1] receiveMessage from SQS
    [2] build changedFields diff:
        { "stage": { "from": "MAPPING_REQUIRED",
                     "to":   "CONFIGURATION_COMPLETE" } }
    [3] INSERT INTO object_events (orinix's own DB)
    [4] deleteMessage (ACK)

  Side annotation RIGHT (teal sticky):
    "Gangway precedent — already in Habu codebase:
     Gangway = standalone service for RTBF/consent.
     Own DB. Own gRPC (port 6069). Own domain.
     Nobody put RTBF inside moonraker.
     orinix = same pattern for observability."

Arrow DOWN:

Box C-B3 (purple, left column):
  Title: "object_events — orinix PostgreSQL (own DB)"
  Sub-label: "Schema evolution never touches unhygienix."
  Schema (same shape as Option A — identical columns):
    event_id, cursor_position, org_id, cleanroom_id,
    object_type, object_id, event_type, change_type,
    changed_fields JSONB, performed_by, schema_version, event_time

  Side annotation RIGHT (green sticky):
    "✓ Future growth stays entirely in orinix:
     callback_registrations → orinix DB
     delivery_log           → orinix DB
     Callback Delivery Worker (ECS Fargate) → orinix service
     Retry + DLQ logic      → orinix service
     unhygienix never sees any of this."

Arrow DOWN labeled: "gRPC: orinix.GetCleanroomEvents()"

Box C-B4 (purple, right column):
  Title: "orinix.GetCleanroomEvents() — gRPC"
  Proto:
    service CleanroomEventService {
      rpc GetCleanroomEvents(GetCleanroomEventsRequest)
          returns (GetCleanroomEventsResponse);
    }
    // Same request/response shape as Option A.
    // external-api-server calls orinix instead of unhygienix.
    // REST contract for XMI is identical.

────────────────────────────────────────────────────────────────────
REJOIN POINT 1 — Both columns merge back into center spine.
Label at rejoin: "REST contract for XMI is identical regardless of Option A or B"
────────────────────────────────────────────────────────────────────

======================================================================
SECTION D — SHARED: EXTERNAL-API-SERVER + CLOUDevents PAYLOAD (full width)
Horizontal band label (green): "DELIVERY LAYER — identical in both options"
======================================================================

Box D1 (green, full width):
  Title: "external-api-server"
  Option A: @GrpcClient("unhygienix") — existing client, two new methods
  Option B: @GrpcClient("orinix")    — one new client entry

  REST endpoint (monospace):
    GET /v1/cleanrooms/{cleanroomId}/events
        ?since=eyJsYXN0X2N1cnNvciI6NDgyMX0=
        &objectType=DATA_CONNECTION
        &limit=50
    Authorization: Bearer <JWT>

  Side annotation LEFT (gray sticky):
    "JWT org_id claim injected into every gRPC request.
     Consumers see only their org's events — automatic.
     XMI sees XMI. MSFT sees MSFT. No per-customer config."

  Side annotation RIGHT (gray sticky):
    "Rate limit: 120 req/min per org (token-bucket)
     X-RateLimit-Limit:     120
     X-RateLimit-Remaining: 87
     X-RateLimit-Reset:     1715521260
     ETag + 304 Not Modified — zero body on idle poll cycles."

  Split: TWO internal consumers of GetCleanroomEvents:
    LEFT internal arrow (green) → topgallant Activity Feed UI:
      Box (green, wireframe):
        Title: "Activity Feed — topgallant (React UI)"
        Internal gRPC only. VPC-only. No auth header.
        ● 2026-05-12  sarah@acme.com
          DATA CONNECTION "cvs_lcr-modified_txns_hq"
          stage: MAPPING_REQUIRED → CONFIGURATION_COMPLETE
        ● 2026-05-11  sreekar.s@liveramp.com
          EXPORT JOB "TestGCSnetwork / Q1"
          destination: s3://a/a.bcs → s3://b/b.abc
        ● 2026-05-10  sarah@acme.com
          QUESTION "Revenue Analysis" — SQL CHANGED
        Sub-label: "Ships with V1. Zero setup. Every Habu user benefits."

    RIGHT continues DOWN as main external spine.

Arrow DOWN labeled: "HTTPS — CloudEvents v1.0 batch"

Box D2 (yellow, full width, monospace):
  Title: "CloudEvents v1.0 Response — CNCF standard envelope"
  HTTP/1.1 200 OK
  Content-Type: application/cloudevents-batch+json
  ETag: "W/\"4823\""
  X-Next-Cursor: eyJsYXN0X2N1cnNvciI6NDgyM30=

  [
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
        "idempotencyKey":"sha256-7f83b1657ff1fc53b92dc18148a1d65d",
        "cursor":        "eyJsYXN0X2N1cnNvciI6NDgyM30="
      }
    }
  ]

  Side annotation RIGHT (teal callout — PROMINENT):
    "CNCF CloudEvents v1.0 — vendor neutral:
     ● GCP Eventarc      → consumes natively
     ● Azure Event Grid  → consumes natively
     ● AWS EventBridge   → consumes natively (GA 2023)
     Schema is identical for Pull AND Push.
     Schema does not change between Option A and Option B."

Arrow DOWN labeled: "Same payload — delivered via Pull OR Push"

────────────────────────────────────────────────────────────────────
SPLIT POINT 2 — Draw bold dashed vertical divider.
Label at split: "⬅ Approach 1: Pull (XMI polls)    |    Approach 2: Push (Habu delivers) ➡"
────────────────────────────────────────────────────────────────────

======================================================================
SECTION E-LEFT — APPROACH 1: PULL — XMI Cursor-Based Polling (left column)
Column header band (green): "Approach 1 — Pull · XMI polls on schedule · No inbound endpoint needed"
======================================================================

Box E-L1 (green, left column):
  Title: "XMI Polling Client — Cloud Scheduler + Cloud Run (GCP)"
  Steps (numbered):
    [1] Poll every 60s:
        GET /v1/cleanrooms/cr-abc/events
            ?since=eyJsYXN0X2N1cnNvciI6NDgyMX0=
            &objectType=DATA_CONNECTION
        Authorization: Bearer <JWT>
    [2] On 304 Not Modified (ETag matched)
        → no new events → advance timer, no processing
    [3] On 200 → deserialize CloudEvents batch
    [4] For each event: read changedFields { field: { from, to } }
        No switch(objectType) — uniform shape for all types
    [5] Persist next_cursor to Redis (TTL 30d) for crash recovery
    [6] Trigger downstream: invalidate cache, update UI, pause workflows

  Side annotation LEFT (blue sticky):
    "Zero XMI infrastructure:
     ✓ No inbound HTTPS endpoint
     ✓ No firewall rule / no inbound port
     ✓ No server to expose
     XMI only needs Cloud Scheduler + Cloud Run job."

Box E-L2 (green, left column):
  Title: "Latency + Reliability"
  Change latency: 30–60s (poll interval)
  ETag/304: zero bandwidth when nothing changed
  Cursor recovery: Redis TTL 30d
  Industry precedent: GitHub Events API, Stripe Events, AWS CloudTrail

======================================================================
SECTION E-RIGHT — APPROACH 2: PUSH — Webhook Registration + Delivery (right column)
Column header band (orange): "Approach 2 — Push · XMI registers once · Habu delivers in <2s"
======================================================================

Box E-R1 (orange, right column):
  Title: "One-Time Registration — XMI calls POST /callbacks"
  Request (monospace):
    POST /v1/cleanrooms/{crId}/callbacks
    {
      "objectType":      "DATA_CONNECTION",
      "objectId":        null,
      "callbackUrl":     "https://events.xmi.liveramp.com/habu-webhook",
      "monitoredFields": ["stage", "destination", "sqlQuery"],
      "authConfig":      { "authType": "BEARER", "authValue": "eyJhbGci..." }
    }

  Response 201 Created:
    { "id": "cb-456-uuid", "signingSecret": "whsec_a3f9c2d1..." }

  Red sticky:
    "signingSecret shown ONCE. XMI stores in GCP Secret Manager.
     Used to verify all future Habu→XMI deliveries via HMAC-SHA256."

Arrow DOWN:

Box E-R2 (orange, right column):
  Title: "callback_registrations table (orinix DB in Option B / unhygienix DB in Option A)"
  Schema (compact):
    id               UUID   cb-456-uuid
    org_id           UUID   02617c50-a923-...
    cleanroom_id     UUID   cr-abc
    object_type      VARCHAR DATA_CONNECTION
    object_id        UUID   NULL (= all DCs)
    monitored_fields TEXT[] {stage, destination, sqlQuery}
    callback_url     TEXT   KMS-encrypted
    signing_secret   VARCHAR whsec_a3f9c2... KMS-encrypted
    status           VARCHAR ACTIVE
    failure_count    INT    0

Arrow DOWN:

Box E-R3 (purple, large, right column):
  Title: "Callback Delivery Worker — ECS Fargate"
  Sub-label: "Lives in orinix (Option B) or unhygienix (Option A)."
  Steps (numbered):
    [1] receiveMessage from sqs-habu-delivery-xmi
        → visibility timeout 30s (hidden, not deleted)
    [2] match event against callback_registrations WHERE cleanroom=cr-abc
        AND object_type=DATA_CONNECTION → cb-456
    [3] changedFields ∩ monitoredFields = {"stage"} → non-empty → proceed
        if empty → skip, deleteMessage — no HTTP call made
    [4] build CloudEvents v1.0 payload
    [5] sign:
        timestamp = 1715521200
        signature = HMAC-SHA256(signingSecret, t + "." + SHA-256(body))
        header    = "t=1715521200,v1=a3f9c2d1..."
    [6] HTTP POST → https://events.xmi.liveramp.com/habu-webhook
          X-Habu-Signature: t=1715521200,v1=a3f9c2d1...
          X-Habu-Event-Id:  evt-a1b2c3d4-uuid
          Content-Type:     application/cloudevents+json
          Timeout: 30s
    [7] 2xx → deleteMessage. Write delivery_log: {attempt:1, status:200, latency:45ms}
    [8] 5xx/timeout → do NOT delete → reappears after 30s → retry

  Side annotation RIGHT (gray sticky):
    "Consumer isolation:
     sqs-habu-delivery-xmi failure has ZERO effect
     on sqs-habu-delivery-mi or sqs-habu-delivery-safehaven.
     Separate queue. Separate DLQ. Separate alarm per consumer."

Arrow DOWN:

Box E-R4 (orange, right column):
  Title: "XMI Webhook Receiver — Cloud Run (GCP)"
  Steps:
    [1] Parse X-Habu-Signature: extract t= and v1=
    [2] Reject if abs(now - t) > 300s → replay attack window
    [3] Recompute HMAC-SHA256(signingSecret, t + "." + SHA-256(body))
    [4] Constant-time compare → mismatch → 401 (worker drops, no retry)
    [5] Redis dedup: SET NX key=evt-a1b2c3d4-uuid TTL=7d
        already exists → 200 OK, skip (handles SQS at-least-once)
    [6] Read changedFields → invalidate cache → update UI → return 200

Box E-R5 (red, right column):
  Title: "Retry + DLQ (on delivery failure)"
  Attempt 1: immediate          → visibilityTimeout = 30s
  Attempt 2: +30s jitter        → visibilityTimeout = 60s
  Attempt 3: +90s jitter        → visibilityTimeout = 180s
  Attempt 4: +270s jitter       → visibilityTimeout = 600s
  Attempt 5: maxReceiveCount=5 exceeded
  → sqs-habu-dlq-xmi → CloudWatch alarm → Slack #platform-alerts
  → PagerDuty: team-xmi-oncall (consumer's own alarm)

────────────────────────────────────────────────────────────────────
REJOIN POINT 2 — Both columns merge into the bottom scorecard.
────────────────────────────────────────────────────────────────────

======================================================================
SECTION F — BOTTOM: DECISION SCORECARD (full width, four boxes in 2x2 grid)
======================================================================

Row 1 — Internal Architecture Decision:

Box F1 (blue, top-left):
  Title: "Option A — Choose when"
  ✓ Move fast, minimal new infra
  ✓ Pegleg scope can temporarily absorb SQS consumer
  ✗ unhygienix grows for a non-CRUD concern
  ✗ webhook infra (delivery_log, callback_registrations) also lands in unhygienix
  ✗ extraction cost grows per sprint

Box F2 (purple, top-right):
  Title: "Option B — Choose when (Recommended)"
  ✓ Observability will expand beyond V1 (webhooks, delivery_log, retry worker)
  ✓ Clean domain: gangway precedent already accepted in codebase
  ✓ unhygienix already large — do not grow it further
  ✓ Schema evolution in orinix never triggers unhygienix deployment
  ✗ Higher setup cost — but one-time. Coupling cost compounds every sprint.

Row 2 — Delivery Model Decision:

Box F3 (green, bottom-left):
  Title: "Approach 1 (Pull) — V1 baseline"
  ✓ Zero XMI infrastructure — no inbound endpoint, no firewall rule
  ✓ Activity Feed UI ships as a by-product of the same gRPC endpoint
  ✓ ETag + 304 — zero bandwidth on idle
  ✓ Cursor — no missed events on reconnect or restart
  △ 30–60s latency — acceptable for audit/activity feed use cases

Box F4 (orange, bottom-right):
  Title: "Approach 2 (Push) — V2 layer on top"
  ✓ Sub-second delivery — Habu pushes within 2s of mutation
  ✓ HMAC-SHA256 signed — same security model as Stripe, GitHub, Twilio
  ✓ monitoredFields filter — XMI only gets notified for fields they care about
  ✓ delivery_log — queryable SLA evidence per consumer
  ✓ Adding MI team = new SQS subscription only, zero code change in publishers
  △ XMI must expose one HTTPS endpoint (Cloud Run on GCP — trivial)

COLOR SPEC:
  Blue = unhygienix / Option A, Purple = orinix / Option B / Callback Worker,
  Teal = forebitt / gangway precedent / CloudEvents vendor-neutrality callout,
  Orange = picanmix / SNS / external-api-server / Push path / XMI webhook,
  Green = Activity Feed UI / Pull path / shared delivery band / Option B recommendation,
  Yellow = CloudEvents payload, Red = retry/DLQ/failure path / Option A trade-offs,
  Gray sticky = operational annotations, Teal callout = CNCF CloudEvents note (PROMINENT).
Bold dashed vertical dividers at both split points.
Horizontal band labels (bold, full-width) at every section transition.
Monospace font for ALL schema, proto, SQL, JSON, HTTP blocks.
Drop shadows and rounded corners on all primary boxes.
TOP-TO-BOTTOM vertical diagram throughout.
Arrows within columns point DOWN. Cross-column arrows are HORIZONTAL only at split/rejoin transitions.
```
