# Miro Prompts — DV-13856 Observability (Corrected Repo Names)
**Date:** 2026-05-13
**Repo names used:**
  - unhygienix  → Questions and question runs
  - forebitt    → Data Connections
  - picanmix    → Exports (also owns SNS infra)
  - pegleg      → Event listener worker (callback delivery — has many existing event listeners)
  - external-api-server → public REST APIs
  - ignoramus   → Proto definitions
  - moonraker   → Auth, feature flipper (NOT involved in this feature)

Paste each prompt separately into Miro → Diagram → (select type noted per prompt)

---

## PROMPT 1 — V1 Activity Feed UI
**Miro type: Diagram → Flowchart**

---

Create a vertical flowchart titled:
"DV-13856  V1 — Activity Feed UI  (Sprints 1–2)"

Subtitle below title:
"Every Habu user benefits immediately — no setup, no registration required"

=== TOP SECTION — label this group "Event Sources" (blue rounded border) ===

Three boxes in a horizontal row:

  Box 1 (blue):
    Title: "unhygienix"
    Body: "Question mutations
    • columns removed / added
    • dataset assignment swapped
    • question renamed or deleted
    • status changed (DRAFT → PUBLISHED)"

  Box 2 (orange):
    Title: "forebitt"
    Body: "Data Connection mutations
    • field type changed (Integer → String)
    • field added or removed
    • data connection deleted"

  Box 3 (green):
    Title: "picanmix"
    Body: "Export mutations
    • export job status changed
    • export config updated
    • export deleted"

All three boxes have arrows pointing DOWN converging into one box below:

=== INTERCEPTOR BOX (purple, wide) ===

Box label: "CRUD Interceptor  —  unhygienix"
Inside the box show 3 numbered steps:
  [1]  Snapshot state BEFORE mutation
  [2]  Execute mutation (delete / update / create)
  [3]  Diff before vs after  →  build ObjectEvent

Arrow pointing DOWN from this box.
Arrow label: "[IN SAME DB TRANSACTION — atomic]"
Note beside arrow: "If mutation rolls back, the event row rolls back too"

=== TABLE BOX (blue) ===

Box label: "object_events table  —  PostgreSQL  —  unhygienix DB"
Inside show schema as a small table:

  event_id         UUID
  cleanroom_id     UUID
  org_id           UUID
  object_type      QUESTION | DATA_CONNECTION | EXPORT_JOB
  object_id        UUID
  object_name      VARCHAR  (name at time of event)
  event_type       CREATED | UPDATED | DELETED | STATUS_CHANGED
  changed_fields   JSONB    e.g. { "dimensions": { "removed": ["customer_segment"] } }
  performed_by     sarah@acme.com
  event_time       TIMESTAMPTZ

Label below schema: "Append-only — never updated, only inserted"

=== TWO ARROWS FROM TABLE ===

Arrow 1 (pointing RIGHT):
  Label: "UI reads directly from this table"
  Goes to: API box

Arrow 2 (pointing RIGHT and then DOWN — dashed, labeled "V2 builds on top of this"):
  Goes to: small note box labeled
  "After COMMIT → pegleg picks up and delivers webhooks  (V2)"
  Style this as a faded/dashed future path

=== API BOX ===

Box (blue):
  "GET /cleanrooms/{id}/events
  external-api-server
  Query params: ?since=T  &objectType=QUESTION  &performedBy=email"

Arrow pointing RIGHT:

=== UI WIREFRAME BOX ===

Draw a browser/panel wireframe box with:

  Header: "Clean Room: Acme Corp × LiveRamp  Q1 2026"
  Tab bar: [Overview]  [Questions]  [Data Connections]  [Activity ◀ selected]

  Filter row: [All Types ▾]  [All Users ▾]  [Last 30 days ▾]  [Search events...]

  Event row 1 (blue left border):
    QUESTION UPDATED  —  2026-05-12  14:32  —  sarah@acme.com
    "Revenue Analysis"  —  output columns removed
    Removed: customer_segment, channel

  Event row 2 (orange left border):
    DATA CONNECTION UPDATED  —  2026-05-12  11:15  —  john@acme.com
    "CRM_Import"  —  field type changed
    purchase_count: Integer → String

  Event row 3 (red left border):
    QUESTION DELETED  —  2026-05-11  16:45  —  admin@liveramp.com
    "Lookalike Segments"  —  permanently deleted

  Event row 4 (green left border):
    QUESTION UPDATED  —  2026-05-11  09:00  —  sarah@acme.com
    "Attribution Model"  —  dataset swapped
    Q1_Sales_2026  →  Q2_Sales_2026

=== BOTTOM STRIP (green) ===

"V1 ships value to every user on the platform.
No infra changes. No customer setup.
The interceptor built here is the exact foundation V2 webhooks attach to."

=== SPRINT TIMELINE BAR at very bottom ===
Blue block: "Sprint 1–2  V1  Activity Feed"
(leave room for orange and green blocks to be added in later diagrams)

STYLE:
Blue = unhygienix / platform internals.
Orange = forebitt / data connections.
Green = picanmix / exports and UI value.
Purple = shared interceptor.
Red = deleted events.
Rounded corners. Drop shadows. Directional arrows with text labels.
Monospace font for table field names and API paths.

---

## PROMPT 2 — V2 Webhook Callback Delivery
**Miro type: Diagram → Sequence Diagram (UML swimlane)**

---

Create a UML sequence diagram titled:
"DV-13856  V2 — Webhook Callback Delivery  (Sprints 3–5)"

Subtitle: "XMI registers once. Habu calls XMI on every change. No polling."

Four vertical swimlanes:

  Lane 1 (orange):  "XMI UI  /  SafeHaven  (Consumer)"
  Lane 2 (blue):    "external-api-server  (Habu API)"
  Lane 3 (purple):  "unhygienix  /  forebitt  /  picanmix  (Mutation Source)"
  Lane 4 (teal):    "pegleg  (Callback Delivery Worker)"

=== PHASE 1 — label "One-time Registration" ===

  Lane 1 → Lane 2:
    Solid arrow labeled:
    POST /cleanrooms/{crId}/callbacks

    Show request payload box beside the arrow:
      objectType:      "QUESTION"
      objectId:        null  (all questions in this cleanroom)
      callbackUrl:     "https://xmi.liveramp.com/habu-events"
      monitoredFields: ["dimensions", "status", "name"]
      authConfig:      { authType: "BEARER" }

  Lane 2 internal:
    Box: "Validate request"
    Box: "INSERT INTO callback_registrations"
    Show row:
      id=cb-456 | cleanroom_id=cr-abc
      object_type=QUESTION | object_id=NULL
      callback_url=https://xmi...
      signing_secret=whsec_a3f9...  (generated by Habu)

  Lane 2 → Lane 1:
    Dashed return arrow labeled: "201 Created"
    Payload box:
      id: "cb-456"
      signingSecret: "whsec_a3f9..."
    Note: "XMI stores signingSecret — used to verify all future payloads"

=== PHASE 2 — label "Runtime — Object Changes in Habu" ===

  Lane 3 internal:
    Box: "User removes columns from Question q-123"
    Box: "unhygienix CRUD interceptor fires"

    Two parallel arrows DOWN labeled:
      Left:  "[IN TRANSACTION] INSERT object_events → evt-789"
      Right: "[POST COMMIT async ~1ms] SNS publish → habu-object-events"

  Lane 3 → Lane 4:
    Arrow: "SNS fans out → SQS-XMI-Delivery (independent queue per consumer)"

=== PHASE 3 — label "Delivery" ===

  Lane 4 internal:
    Box: "pegleg reads SQS message"
    Show numbered step list:
      1. receiveMessage(SQS-XMI-Delivery)  — visibility timeout 30s starts
      2. Check delivery_log  — already delivered? skip (idempotency)
      3. Query callback_registrations  — cleanroom=cr-abc, type=QUESTION → cb-456
      4. Build JSON payload from evt-789
      5. Compute HMAC-SHA256(signingSecret, payload)  →  X-Habu-Signature header
      6. Circuit breaker check  → CLOSED: proceed
      7. HTTP POST to https://xmi.liveramp.com/habu-events
      8. Write delivery_log  (attempt=1, http_status=200, latency=45ms)  ← BEFORE ACK
      9. deleteMessage(SQS)  ← ACK

  Lane 4 → Lane 1:
    Solid arrow labeled: "HTTP POST"

    Show headers box:
      Authorization:      Bearer eyJ...
      X-Habu-Signature:   sha256=a3f9c2...
      X-Habu-Event-Id:    evt-789
      X-Habu-Timestamp:   1715521200

    Show body box:
      eventType:     "UPDATED"
      objectType:    "QUESTION"
      objectName:    "Revenue Analysis"
      changedFields: { dimensions: { removed: ["customer_segment"] } }
      changedBy:     "sarah@acme.com"
      eventTime:     "2026-05-12T10:32:00Z"

  Lane 1 internal:
    Box: "Verify HMAC signature using stored signingSecret"
    Box: "Process event — update UI / refresh cache / trigger workflow"

  Lane 1 → Lane 4:
    Dashed return arrow: "200 OK"

=== FAILURE PATH (show as an alt box below the success path) ===

Alt box label: "FAILURE — endpoint returns 5xx or times out"

  Lane 4 internal:
    Box: "SQS visibility timeout expires — message reappears"
    Box: "pegleg retries: 1s → 5s → 30s backoff"
    Box: "After 3 attempts: SQS auto-moves to DLQ (no app code)"
    Box: "CloudWatch alarm fires → PagerDuty / Slack alert"
    Note: "V3 adds DLQ Admin UI with one-click Replay"

STYLE:
Lane 1 = orange. Lane 2 = blue. Lane 3 = purple. Lane 4 = teal.
Solid arrows = requests. Dashed arrows = responses.
Show phase labels as dividers across all lanes.
Monospace for table names, API paths, payload fields.

---

## PROMPT 3 — V3 Full Platform-Grade Architecture
**Miro type: Diagram → Flowchart (large, enterprise architecture style)**

---

Create a large enterprise architecture diagram titled:
"DV-13856 — Platform-Grade Event Delivery System"

Subtitle: "Clean Room Observability + Webhook Backbone  —  V1 + V2 + V3"

LAYOUT: Vertical main flow top-to-bottom. Horizontal fan-out in the middle.
Right-side strip for V3 hardening. Bottom sprint timeline bar.

=== TOP ROW — Event Sources (horizontal, 3 boxes, labeled "Mutation Sources") ===

Box 1 (blue, solid border):
  "unhygienix
  Questions & Question Runs
  create / update / delete"

Box 2 (orange, solid border):
  "forebitt
  Data Connections
  field type / schema changes"

Box 3 (green, solid border):
  "picanmix
  Export Jobs
  status / config changes"

All three have arrows pointing DOWN, converging into one arrow to the next layer.

=== INTERCEPTOR LAYER (wide purple box, labeled "Shared Foundation") ===

Box title: "CRUD Interceptor Layer — added to unhygienix / forebitt / picanmix"

Inside show two parallel outputs:

  Left output — solid arrow — label "[IN DB TRANSACTION — atomic]":
    Goes DOWN-LEFT to:
    Box (blue): "object_events table
                 PostgreSQL — unhygienix DB
                 NEW TABLE — V1
                 Append-only audit log"

    From object_events, arrow RIGHT labeled "UI reads here":
    Box (green): "Activity Feed UI
                  GET /cleanrooms/{id}/events
                  external-api-server
                  V1 — Sprint 1–2"

  Right output — dashed arrow — label "[POST COMMIT — async ~1ms — non-blocking]":
    Goes DOWN-RIGHT to:

=== SNS FAN-OUT LAYER (orange box) ===

Box:
  "SNS Topic: habu-object-events
  picanmix infrastructure (reused)
  V2 — Sprint 3–5"

Note card beside box:
  "Adding new consumer = 1 new SQS subscription
  Zero code change to unhygienix / forebitt / picanmix"

Three arrows fan OUT downward from SNS:

  Arrow 1 → Box (blue): "SQS-XMI-Delivery
                          XMI's independent queue
                          maxReceiveCount = 3"

  Arrow 2 → Box (orange): "SQS-SafeHaven-Delivery
                            SafeHaven's independent queue
                            Unaffected by XMI failures"

  Arrow 3 → Box (gray, dashed): "SQS-Future-Delivery
                                  Any future consumer
                                  Self-serve subscription"

=== PEGLEG WORKER LAYER (teal box, detailed) ===

Below SQS-XMI box, arrow DOWN to:

Box title: "pegleg — Callback Delivery Worker (Java)
            Horizontally scalable — N worker instances
            V2 — Sprint 3–5"

Inside the box show a numbered vertical list:
  Step 1:  receiveMessage(SQS)  ← visibility timeout 30s
  Step 2:  Check delivery_log  ← idempotency guard (already delivered? skip)
  Step 3:  Query callback_registrations  ← find URL + auth for this object
  Step 4:  Build JSON event payload
  Step 5:  HMAC-SHA256(signingSecret, body)  →  X-Habu-Signature  [V3]
  Step 6:  Circuit Breaker check  →  CLOSED / OPEN / HALF-OPEN  [V3]
  Step 7:  HTTP POST to callback URL
  Step 8:  Write delivery_log  (BEFORE ACK — crash-safe ordering)
  Step 9:  deleteMessage(SQS)  ← ACK

Two reference boxes connected to pegleg with dashed lines:

  RIGHT side — Box (blue):
    "callback_registrations table
     cb-456 | cr-abc | QUESTION | NULL
     callback_url: https://xmi.../habu-events
     signing_secret: whsec_a3f9...  (encrypted)"

  RIGHT side below — Box (blue):
    "delivery_log table
     evt-789 | cb-456 | attempt=1
     http_status=200 | latency=45ms
     delivered_at: 2026-05-12T10:32Z"

=== SUCCESS PATH (bottom-left, green) ===

Arrow from pegleg DOWN-LEFT labeled "200 OK → ACK SQS":

Three boxes in a horizontal row:
  Box 1 (orange): "XMI UI
                   https://xmi.liveramp.com/habu-events
                   verifies X-Habu-Signature
                   updates UI / refreshes cache / triggers workflow"

  Box 2 (orange): "SafeHaven
                   https://safehaven.com/events
                   independent queue and DLQ
                   XMI outage does not affect this"

  Box 3 (gray, dashed): "Future Customer
                          any HTTPS endpoint
                          registered via POST /callbacks
                          zero platform code change"

=== FAILURE PATH (bottom-right, red) ===

Arrow from pegleg RIGHT labeled "failure → retry 1s → 5s → 30s":

Box (yellow): "SQS Visibility Timeout
               Message reappears automatically
               No application code needed"

Arrow DOWN labeled "maxReceiveCount = 3 exceeded":

Box (red): "Dead Letter Queue
            SQS-XMI-Delivery-DLQ
            AWS moves automatically — no app code"

Two arrows from DLQ:

  Arrow RIGHT → Box: "CloudWatch Alarm
                       DLQ depth > 0
                       → PagerDuty / Slack alert to on-call"

  Arrow DOWN → Box (green): "DLQ Admin UI  (V3)
                              Webhooks tab in clean room UI
                              Inspect failed messages
                              One-click Replay button
                              → moves message back to main queue"

=== RIGHT SIDE STRIP — V3 Production Hardening ===

Vertical strip title: "V3 — Production Hardening  (Sprint 6–7)"
Color: teal border

Five stacked cards:

  Card 1:
    "HMAC Signature Verification
    X-Habu-Signature on every outbound POST
    Per-registration secret (XMI ≠ SafeHaven)
    X-Habu-Timestamp prevents replay attacks"

  Card 2:
    "Circuit Breaker — Resilience4j (pegleg)
    CLOSED → normal delivery
    OPEN → 5+ failures, stop calling 60s, free threads
    HALF-OPEN → 1 probe call, recover if 200 OK"

  Card 3:
    "Delivery Observability
    delivery_log: every attempt, status, latency, reason
    CloudWatch: success rate, latency histogram, DLQ depth
    Per-registration health visible in Webhooks UI tab"

  Card 4:
    "Webhook Test Endpoint
    POST /callbacks/{id}/test — external-api-server
    Sends synthetic event to registered URL
    Returns http_status, latency, success flag"

  Card 5:
    "Event Replay API
    Re-deliver from object_events table (durable log)
    POST /admin/callbacks/{cbId}/replay-dlq
    For missed deliveries and ops recovery"

=== LEGEND (bottom-left corner) ===

  Blue   = unhygienix — Questions
  Orange = forebitt — Data Connections / picanmix — Exports / SNS fan-out
  Green  = UI value and success paths
  Purple = shared interceptor layer
  Teal   = V3 hardening additions
  Red    = failure path and DLQ
  Gray   = future / optional components

=== SPRINT TIMELINE BAR (very bottom, full width) ===

Three adjacent blocks:
  Blue block   (left, 2 units):   "Sprint 1–2  ·  V1  ·  object_events + interceptors + Activity Feed UI"
  Orange block (middle, 3 units): "Sprint 3–5  ·  V2  ·  callback_registrations + delivery_log + SNS/SQS + pegleg worker + DLQ"
  Teal block   (right, 2 units):  "Sprint 6–7  ·  V3  ·  HMAC + Circuit Breaker + Webhooks UI tab + Replay API"

STYLE INSTRUCTIONS:
Enterprise architecture style. Rounded corner boxes with drop shadows.
Color per legend. All arrows must have directional labels.
Both vertical flow (top to bottom) and horizontal fan-out visible.
Monospace font for all table names, field names, API paths, and code values.
Group related components inside labeled bordered containers.
Large enough to show all detail — this is the TLM presentation diagram.
Make pegleg box the most visually prominent in V2 section.
