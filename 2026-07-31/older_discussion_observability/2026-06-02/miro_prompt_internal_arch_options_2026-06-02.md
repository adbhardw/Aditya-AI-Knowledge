# Miro Prompt — Internal Architecture: Option A vs Option B
**Date:** 2026-06-02
**Author:** Aditya Bhardwaj
**Audience:** TLM (Jon Chua, Shruthi, Ravindra)
**Purpose:** One diagram showing both consumer paths after SNS — Pegleg→unhygienix (Option A) vs orinix new service (Option B)

---

## Prompt — Option A vs Option B: Where Does the SQS Consumer Live?

```
Create an enterprise architecture flowchart titled:
"DV-13856 — Internal Architecture: Two Options for Event Consumer Ownership"
Subtitle: "Publishers are identical. The decision is who consumes SNS and who owns object_events."

LAYOUT: Strictly TOP-TO-BOTTOM vertical flowchart.
The top half (mutation layer + SNS) is a shared center spine — identical for both options.
Below SNS, the diagram SPLITS into TWO parallel vertical columns:
  LEFT COLUMN  = Option A (Pegleg → unhygienix)
  RIGHT COLUMN = Option B (orinix new service)
Both columns rejoin at the bottom at external-api-server → REST API.
A bold vertical DIVIDER LINE separates the two columns from the split point to the rejoin.
Label the left column header: "Option A — Pegleg + unhygienix"
Label the right column header: "Option B — orinix (new service)"
All arrows within each column point DOWNWARD.
Side annotations hang outside the outer edges of each column.
This is a TOP-TO-BOTTOM vertical diagram. No left-to-right main axis.

======================================================================
SECTION A — SHARED TOP: MUTATION LAYER (full width, no split yet)
Horizontal band label: "MUTATION LAYER — Publishing side is identical in both options"
======================================================================

Three boxes arranged horizontally across the full width, rounded corners, drop shadow:

  Box A1 (blue):
    Title: "unhygienix"
    QUESTION mutation
    ── sqlQuery changed
    ── status: DRAFT → PUBLISHED
    ── dataset assignment changed
    Example: "Revenue Analysis"
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
    "Each service publishes post-commit (~1ms after DB COMMIT).
     3 lines of code per service:
       snsClient.publish(HABU_OBJECT_EVENTS_TOPIC, event.toJson())
     No service calls another service directly.
     forebitt never calls unhygienix. Zero circular dependency."

All three boxes converge into ONE down arrow labeled:
  "[POST COMMIT — non-blocking, ~1ms]
   sns.publish(topic='habu-object-events',
     attributes={cleanroom_id, org_id, object_type})"

======================================================================
SECTION B — SHARED CENTER: SNS TOPIC (full width, no split yet)
======================================================================

Box B1 (orange, full width, center spine):
  Title: "AWS SNS — habu-object-events"
  Internal event bus. Stays inside Habu AWS account.
  SNS Message Attributes (monospace):
    cleanroom_id: cr-abc
    org_id:       02617c50-a923-4877-a968-6465d5d2baaa
    object_type:  DATA_CONNECTION

  Side annotation LEFT (gray sticky):
    "SNS filter policy isolates events per consumer.
     XMI org events never appear in MI or SafeHaven queues.
     Isolation enforced at the AWS layer — not in application code."

Arrow DOWN labeled: "SNS → SQS subscription"

Immediately below this arrow, the diagram SPLITS into two parallel columns.
Draw a bold dashed VERTICAL DIVIDER between the two columns.
Place a label at the split point: "⬅ Option A    |    Option B ➡"

======================================================================
SECTION C — LEFT COLUMN: OPTION A — Pegleg + unhygienix
Header band (dark blue, left column only): "Option A — Pegleg as Consumer · unhygienix owns the table"
======================================================================

Box C-A1 (blue, left column):
  Title: "SQS — sqs-habu-object-events-internal"
  Pegleg subscribes to this queue.
  Visibility Timeout: 30s
  Max Receive Count: 5 → DLQ

Arrow DOWN (left column):

Box C-A2 (blue, large, left column):
  Title: "Pegleg — SQS Consumer"
  Sub-label: "Pegleg already has @GrpcClient('unhygienix') — coupling already exists."
  Steps (monospace, numbered):
    [1] receiveMessage from SQS
    [2] parse ObjectEvent from SNS message body
    [3] compute changedFields diff:
        { "stage": { "from": "MAPPING_REQUIRED",
                     "to":   "CONFIGURATION_COMPLETE" } }
    [4] gRPC call → unhygienix.RecordEvent(event)
    [5] on gRPC success → deleteMessage (explicit ACK)
    [6] on gRPC failure → do NOT delete → SQS retry

  Side annotation LEFT (yellow sticky):
    "Why Pegleg?
     ✓ Already Java — same stack
     ✓ Already has @GrpcClient('unhygienix')
     ✓ No new service to deploy
     ✗ Pegleg domain = query validation
       Event routing is off-domain
     ✗ Schema evolution touches Pegleg"

Arrow DOWN labeled: "gRPC: unhygienix.RecordEvent()"

Box C-A3 (blue, large, left column):
  Title: "unhygienix — RecordEvent() [NEW gRPC method]"
  Proto definition (monospace):
    rpc RecordEvent(RecordEventRequest)
        returns (RecordEventResponse);

    message RecordEventRequest {
      string object_id    = 1;
      string object_type  = 2;  // QUESTION | DATA_CONNECTION | EXPORT_JOB
      string event_type   = 3;  // com.habu.cleanroom.<type>.<action>
      string changed_by   = 4;
      string org_id       = 5;
      string cleanroom_id = 6;
      bytes  before_state = 7;  // JSON snapshot
      bytes  after_state  = 8;  // JSON snapshot
    }

Arrow DOWN:

Box C-A4 (blue, left column, monospace interior):
  Title: "object_events table — unhygienix PostgreSQL"
  Sub-label: "Lives inside unhygienix DB. unhygienix owns migrations."
  Schema (compact):
    event_id        UUID   PK
    cursor_position BIGINT SEQUENCE
    org_id          UUID   org-scoped
    cleanroom_id    UUID
    object_type     VARCHAR
    object_id       UUID
    event_type      VARCHAR  com.habu.cleanroom.*.*
    change_type     VARCHAR  CREATED|UPDATED|DELETED
    changed_fields  JSONB    { field: {from, to} }
    performed_by    VARCHAR
    schema_version  INT      1
    event_time      TIMESTAMPTZ

  Side annotation LEFT (red sticky):
    "⚠ Trade-offs:
     — object_events grows unhygienix's already large schema
     — Future webhook infra (delivery_log, callback_registrations)
       also lands inside unhygienix
     — Observability concern absorbed into control plane
     — Schema migration = unhygienix deployment"

Arrow DOWN labeled: "gRPC: unhygienix.GetCleanroomEvents() [NEW method]"

Box C-A5 (blue, left column):
  Title: "unhygienix — GetCleanroomEvents() [NEW gRPC method]"
  Proto (monospace):
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
SECTION C — RIGHT COLUMN: OPTION B — orinix (new service)
Header band (purple, right column only): "Option B — orinix: Dedicated Observability Service"
======================================================================

Box C-B1 (purple, right column):
  Title: "SQS — sqs-habu-object-events-internal"
  orinix subscribes to this queue.
  Same queue config as Option A.
  (Or a separate queue — orinix decides its own SQS topology)

Arrow DOWN (right column):

Box C-B2 (purple, large, right column):
  Title: "orinix — SQS Consumer + gRPC Server"
  Sub-label: "Single-responsibility service. Owns all observability logic."
  Directory structure (monospace):
    orinix/
    ├── proto/
    │   └── events.proto       GetCleanroomEvents, RecordEvent
    ├── consumer/
    │   └── SqsEventConsumer   reads SNS→SQS, writes object_events
    ├── db/
    │   └── object_events      owns table + migrations (own DB)
    └── server/
        └── EventServiceImpl   serves GetCleanroomEvents gRPC

  Steps (numbered):
    [1] receiveMessage from SQS
    [2] parse ObjectEvent
    [3] compute changedFields diff:
        { "stage": { "from": "MAPPING_REQUIRED",
                     "to":   "CONFIGURATION_COMPLETE" } }
    [4] INSERT INTO object_events (orinix's own DB)
    [5] deleteMessage (explicit ACK)

  Side annotation RIGHT (teal sticky):
    "Gangway precedent:
     Gangway = standalone Go service for RTBF/consent.
     Own PostgreSQL DB. Own gRPC (port 6069). Own domain.
     Nobody put RTBF inside moonraker.
     orinix follows the same pattern for observability."

Arrow DOWN:

Box C-B3 (purple, large, right column, monospace interior):
  Title: "object_events table — orinix PostgreSQL (own DB)"
  Sub-label: "orinix owns migrations. No unhygienix deployment needed for schema changes."
  Schema (compact):
    event_id        UUID   PK
    cursor_position BIGINT SEQUENCE
    org_id          UUID   org-scoped
    cleanroom_id    UUID
    object_type     VARCHAR
    object_id       UUID
    event_type      VARCHAR  com.habu.cleanroom.*.*
    change_type     VARCHAR  CREATED|UPDATED|DELETED
    changed_fields  JSONB    { field: {from, to} }
    performed_by    VARCHAR
    schema_version  INT      1
    event_time      TIMESTAMPTZ

  Side annotation RIGHT (green sticky):
    "✓ Future growth stays in orinix:
     callback_registrations table → orinix DB
     delivery_log table          → orinix DB
     Callback Delivery Worker    → orinix service
     Retry + DLQ logic           → orinix service

     unhygienix never sees any of this."

Arrow DOWN labeled: "gRPC: orinix.GetCleanroomEvents()"

Box C-B4 (purple, right column):
  Title: "orinix — GetCleanroomEvents() gRPC"
  Proto (monospace):
    service CleanroomEventService {
      rpc GetCleanroomEvents(GetCleanroomEventsRequest)
          returns (GetCleanroomEventsResponse);
    }
    // Same request/response shape as Option A.
    // external-api-server calls orinix instead of unhygienix.
    // No change to the REST contract for XMI.

======================================================================
SECTION D — SHARED BOTTOM: Both columns rejoin here
Horizontal band label: "DELIVERY LAYER — identical in both options"
======================================================================

TWO arrows from C-A5 (left) and C-B4 (right) converge DOWN into:

Box D1 (green, full width, center):
  Title: "external-api-server"
  Option A: @GrpcClient("unhygienix") — existing client, new method
  Option B: @GrpcClient("orinix")    — one new client entry

  REST endpoint (monospace):
    GET /v1/cleanrooms/{cleanroomId}/events
        ?since=eyJsYXN0X2N1cnNvciI6NDgyMX0=
        &objectType=DATA_CONNECTION
        &limit=50
    Authorization: Bearer <JWT>
    → JWT org_id claim injected into gRPC request
    → consumers see only their org's events (automatic)

  Side annotation LEFT (gray sticky):
    "The REST API contract for XMI does not change
     between Option A and Option B.
     XMI calls the same endpoint either way.
     The option only affects what external-api-server
     calls internally."

Arrow DOWN:

Box D2 (yellow, full width, center, monospace JSON):
  Title: "CloudEvents v1.0 Response — CNCF standard"
  [
    {
      "specversion":     "1.0",
      "id":              "evt-a1b2c3d4-uuid",
      "source":          "urn:habu:cleanroom:cr-abc",
      "type":            "com.habu.cleanroom.data_connection.updated",
      "time":            "2026-02-05T04:18:35.095472Z",
      "datacontenttype": "application/json",
      "data": {
        "objectType":  "DATA_CONNECTION",
        "objectId":    "97b6cf60-f8be-48aa-b7a0-ec112c1fb801",
        "objectName":  "cvs_lcr-modified_txns_hq",
        "changeType":  "UPDATED",
        "changedFields": {
          "stage": { "from": "MAPPING_REQUIRED",
                     "to":   "CONFIGURATION_COMPLETE" }
        },
        "performedBy":   "sreekar.s@liveramp.com",
        "schemaVersion": 1
      }
    }
  ]

  Side annotation RIGHT (teal callout — PROMINENT):
    "CNCF CloudEvents v1.0 — vendor neutral.
     GCP Eventarc, Azure Event Grid, AWS EventBridge:
     all consume this payload natively.
     Schema does not change between Option A and Option B."

Arrow DOWN:

Box D3 (green, full width):
  Title: "XMI / Consumer"
  Pull: polls GET /events?since=<cursor> every 60s
  Push: receives HTTP POST to registered webhook endpoint
  Same CloudEvents payload regardless of delivery model.

======================================================================
SECTION E — BOTTOM DECISION PANEL (full width, two boxes side by side)
======================================================================

Box E1 (blue, left half):
  Title: "Option A — Choose when"
  ✓ Team wants to move fast with minimal new infra
  ✓ Acceptable to grow unhygienix short-term
  ✓ Pegleg's scope can absorb the SQS consumer temporarily
  ✗ Plan to extract later — extraction cost grows per sprint
  ✗ Not recommended if webhook delivery (V2) is in scope soon:
    delivery_log + callback_registrations would also land in unhygienix

Box E2 (purple, right half):
  Title: "Option B — Choose when"
  ✓ Observability will expand beyond V1 (webhooks, delivery_log, DLQ worker)
  ✓ Team values clean domain boundaries (gangway precedent)
  ✓ unhygienix is already large — avoid growing it further
  ✓ Schema changes should not require unhygienix deployments
  ✗ Higher setup cost: new service, new DB, new deployment pipeline
  → Recommendation: Option B is the correct long-term choice.
    Setup cost is a one-time cost. Coupling cost compounds every sprint.

COLOR SPEC:
  Blue = unhygienix / Option A path, Purple = orinix / Option B path,
  Teal = forebitt / gangway precedent / vendor-neutrality callout,
  Orange = picanmix / SNS, Green = delivery layer + shared bottom,
  Yellow = CloudEvents payload, Red sticky = Option A trade-offs,
  Green sticky = Option B advantages.
Bold dashed vertical divider between Option A and Option B columns.
Monospace font for all proto, SQL, JSON, code blocks.
Drop shadows on all primary boxes. Directional labels on every arrow.
TOP-TO-BOTTOM vertical diagram. Arrows within columns go DOWN.
The split and rejoin are the only horizontal transitions.
```
