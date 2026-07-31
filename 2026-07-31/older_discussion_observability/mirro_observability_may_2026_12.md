# Miro Prompts — DV-13856 Clean Room Observability
**Date:** 2026-05-12
**Usage:** Paste each prompt separately into Miro's AI box to generate diagrams

---

## Prompt 1 — MVP V1 Activity Feed (simple, foundation slide)

Create a clean vertical flowchart titled:
"DV-13856 V1 — Activity Feed UI (Sprints 1–2)"

Subtitle: "Every user benefits immediately — no setup required"

TOP SECTION — label "Habu Platform (unhygienix)" — blue border box:
  Three trigger boxes side by side (horizontal row):
    Box 1: "Question mutation (columns removed / deleted / renamed)"
    Box 2: "Data Connection mutation (field type changed / deleted)"
    Box 3: "Export Job mutation (status changed)"
  All three converge with arrows pointing DOWN to:

  One box: "CRUD Interceptor — unhygienix"
    Inside show three sub-steps:
      Step 1: "Snapshot state BEFORE mutation"
      Step 2: "Execute mutation"
      Step 3: "Diff before vs after — build event"

  Arrow DOWN labeled "[IN SAME DB TRANSACTION — atomic]" to:

  Box: "object_events table (PostgreSQL)"
    Show schema inline:
      event_id | cleanroom_id | object_type | object_id
      object_name | event_type | changed_fields (JSONB)
      performed_by | event_time
    Label: "Append-only audit log — never updated, only inserted"
    Note on right side: "If mutation rolls back, event row rolls back too"

  Arrow RIGHT from object_events to:

  Box: "GET /cleanrooms/{id}/events API"
    Label: "external-api-server"
    Show query params: ?since=T  &objectType=QUESTION  &performedBy=email

  Arrow RIGHT to:

  Box — wireframe UI panel:
    Title: "Activity Feed Tab — Clean Room UI"
    Show:
      Filter bar: [All Types] [All Users] [Last 30 days]
      Event rows:
        2026-05-12  sarah@acme.com
          QUESTION "Revenue Analysis" — columns removed
          Removed: customer_segment, channel

        2026-05-11  john@acme.com
          DATA CONNECTION "CRM_Import" — field type changed
          purchase_count: Integer to String

        2026-05-10  admin@liveramp.com
          QUESTION "Lookalike Segments" — DELETED

BOTTOM STRIP — green box:
  "V1 delivers value to ALL users with zero setup.
  The same interceptor becomes the foundation for V2 webhooks."

COLOR SCHEME:
  Blue = platform internals
  Green = UI and user value
Show directional arrows with labels. Clean enterprise style. Rounded box corners.

---

## Prompt 2 — Callback Registration Lifecycle (swimlane, integration slide)

Create a swimlane sequence diagram titled:
"DV-13856 V2 — Callback Registration Lifecycle"
Subtitle: "How XMI registers once and receives all future changes automatically"

Three vertical swimlanes:
  Lane 1 (orange): "XMI UI — Consumer"
  Lane 2 (blue): "Habu Platform"
  Lane 3 (purple): "Delivery Infrastructure"

PHASE 1 — label "One-time Setup" at top:

  Lane 1 to Lane 2:
    Arrow: POST /cleanrooms/{crId}/callbacks
    Show request body box:
      objectType: QUESTION
      objectId: null (means all questions in this cleanroom)
      callbackUrl: https://xmi.liveramp.com/habu-events
      monitoredFields: [dimensions, status, name]
      authConfig: { authType: BEARER, authValue: eyJ... }

  Lane 2 internal:
    Box: "external-api-server validates request"
    Arrow down: "store registration"
    Box: "callback_registrations table"
      Row: id=cb-456 | cleanroom_id=cr-abc | object_type=QUESTION
           object_id=NULL | callback_url=xmi... | signing_secret=whsec_...

  Lane 2 to Lane 1:
    Arrow: Registration response
    Box:
      id: cb-456
      signingSecret: whsec_a3f9...
    Note: "XMI stores signingSecret for HMAC verification on receipt"

PHASE 2 — label "Runtime — when object changes" in middle:

  Lane 2 internal:
    Box: "User removes columns from Question q-123 in Habu UI"
    Arrow down: "unhygienix interceptor fires"
    Two parallel arrows labeled:
      Left: "[IN TRANSACTION] INSERT object_events — evt-789"
      Right: "[POST COMMIT async] SNS publish to habu-object-events"

  Lane 2 to Lane 3:
    Arrow: "SNS fans out to SQS-XMI-Delivery"

  Lane 3 internal:
    Box: "SQS-XMI-Delivery queue"
    Arrow down: "Callback Delivery Worker reads message"
    Box: "Worker steps:"
      1. receiveMessage from SQS — visibility timeout starts (30s)
      2. Query callback_registrations — cleanroom=cr-abc, type=QUESTION — finds cb-456
      3. Build JSON payload from evt-789
      4. Compute HMAC-SHA256(signingSecret, payload)
      5. Circuit breaker check — CLOSED, proceed
      6. HTTP POST to https://xmi.liveramp.com/habu-events
      7. Write to delivery_log (attempt=1, status=200, latency=45ms)
      8. deleteMessage — ACK SQS

  Lane 3 to Lane 1:
    Arrow: HTTP POST
    Show headers box:
      Authorization: Bearer eyJ...
      X-Habu-Signature: sha256=a3f9c2...
      X-Habu-Event-Id: evt-789
      X-Habu-Timestamp: 1715521200
    Show body box:
      eventType: UPDATED
      objectType: QUESTION
      objectName: Revenue Analysis
      changedFields: { dimensions: { removed: [customer_segment] } }
      changedBy: sarah@acme.com
      eventTime: 2026-05-12T10:32:00Z

  Lane 1 internal:
    Box: "XMI verifies HMAC signature using stored signingSecret"
    Arrow: "Updates UI — refreshes cache — triggers downstream workflow"
    Arrow back to Lane 3: "Returns 200 OK"

COLOR: Lane 1 = orange. Lane 2 = blue. Lane 3 = purple.
Show timing annotations on arrows. Clean swimlane borders.
Monospace font for code values and table names.

---

## Prompt 3 — Full Platform-Grade Diagram (DLQ, fan-out, circuit breaker — TLM slide)

Create a large enterprise architecture diagram titled:
"DV-13856 — Platform-Grade Event Delivery System"
Subtitle: "Clean Room Observability and Webhook Backbone — V1 + V2 + V3"

LAYOUT: Vertical main flow top to bottom. Horizontal fan-out in the middle section.

=== TOP — Event Sources (horizontal row, blue boxes) ===

Three boxes side by side:
  Box 1: "unhygienix
          Question mutations
          create / update / delete"

  Box 2: "moonraker / conn
          Data Connection mutations
          field type / schema changes"

  Box 3: "cronos / picanmix
          Export Job mutations
          status changes"

All three arrows converge pointing DOWN to:

=== INTERCEPTOR LAYER (purple wide box) ===

Box label: "CRUD Interceptor Layer — unhygienix"
  Inside show three sequential steps:
    [1] Snapshot state BEFORE mutation
    [2] Execute mutation
    [3] Diff before vs after — build ObjectEvent

  TWO arrows out of this box:

  LEFT arrow — label "[IN DB TRANSACTION — atomic]" pointing LEFT-DOWN to:
    Box: "object_events table
          PostgreSQL
          Append-only audit log"
    From this box, arrow RIGHT labeled "UI reads here" to:
    Box (green): "Activity Feed UI
                  GET /cleanrooms/{id}/events
                  V1 — Sprint 1 to 2"

  RIGHT arrow — label "[POST COMMIT async 1ms — non-blocking]" pointing DOWN to:

=== FAN-OUT LAYER (orange box) ===

Box: "SNS Topic
      habu-object-events
      picanmix"
Note beside: "Adding new consumer = new SQS subscription only. Zero code change to unhygienix."

Three arrows fanning OUT downward:
  Arrow 1 to Box: "SQS-XMI
                   Delivery Queue"
  Arrow 2 to Box: "SQS-SafeHaven
                   Delivery Queue"
  Arrow 3 to Box: "SQS-Future
                   Delivery Queue"

=== DELIVERY WORKER LAYER ===

Below each SQS queue, arrow down to a Worker box.
Show XMI worker in FULL DETAIL. Show SafeHaven and Future workers as simplified boxes.

XMI Worker box (blue, detailed):
  Label: "Callback Delivery Worker — Java
          Horizontally scalable — N instances"
  Inside vertical step list:
    Step 1: receiveMessage from SQS — visibility timeout 30s starts
    Step 2: Query callback_registrations — find cb-456 — XMI URL + auth
    Step 3: Build JSON payload from event
    Step 4: HMAC-SHA256(signingSecret, payload) — X-Habu-Signature header
    Step 5: Circuit Breaker check
              CLOSED — proceed with HTTP call
              OPEN — fail fast, no HTTP attempt, protect thread pool
              HALF-OPEN — probe with 1 call to test recovery
    Step 6: HTTP POST to callback URL
    Step 7: Write to delivery_log before ACK
    Step 8: deleteMessage — ACK SQS

Box to the RIGHT connected to Step 2:
  "callback_registrations table
   cb-456 | cr-abc | QUESTION
   https://xmi.../habu-events
   signing_secret=whsec_..."

Box to the RIGHT connected to Step 7:
  "delivery_log table
   evt-789 | cb-456 | attempt=1
   http_status=200 | latency=45ms"

=== FAILURE PATH (right side, red) ===

Arrow RIGHT from Worker labeled "on failure: retry 1s then 5s then 30s":
  Box: "SQS visibility timeout
        message reappears automatically
        no app code needed"
  Arrow DOWN: "maxReceiveCount=3 exceeded"
  Box (red): "Dead Letter Queue
              SQS-XMI-Delivery-DLQ
              AWS moves message automatically"

  Two arrows from DLQ:
    Arrow RIGHT to Box: "CloudWatch Alarm
                         DLQ depth greater than 0
                         PagerDuty slash Slack alert to on-call"

    Arrow DOWN to Box (green): "DLQ Admin UI — V3
                                 Webhooks tab in clean room UI
                                 Inspect failed messages
                                 One-click Replay button"

=== SUCCESS PATH (left side, green) ===

Arrow LEFT-DOWN from Worker labeled "200 OK — ACK SQS":
  Box: "XMI endpoint
        habu-events
        verifies X-Habu-Signature
        updates UI, refreshes cache, triggers workflow"

=== BOTTOM — External Consumers (horizontal row, orange) ===

Three boxes:
  Box 1: "XMI UI
          xmi.liveramp.com/habu-events
          verifies HMAC signature
          independent queue — own DLQ"

  Box 2: "SafeHaven
          safehaven.com/events
          independent queue
          XMI slowness does not affect this"

  Box 3: "Future Customer
          any HTTPS endpoint
          self-serve via registration API
          zero platform code change"

=== RIGHT SIDE STRIP — V3 Production Hardening (teal vertical strip) ===

Label: "V3 Production Hardening — Sprint 6 to 7"
Five cards stacked vertically:
  Card 1: "HMAC Signature Verification
           X-Habu-Signature on every POST
           Timestamp prevents replay attacks"

  Card 2: "Circuit Breaker — Resilience4j
           CLOSED to OPEN to HALF-OPEN
           Protects worker threads during outages"

  Card 3: "Delivery Observability
           delivery_log: every attempt recorded
           CloudWatch metrics dashboard"

  Card 4: "Webhook Test Endpoint
           POST /callbacks/{id}/test
           Validate endpoint before going live"

  Card 5: "Event Replay API
           Re-deliver from object_events table
           For missed or failed deliveries"

=== LEGEND (bottom left corner) ===
  Blue = Habu platform internals
  Purple = shared interceptor layer
  Orange = fan-out and external consumers
  Green = user-facing UI and delivered value
  Red = failure path and DLQ
  Teal = V3 hardening

=== SPRINT TIMELINE (very bottom, horizontal bar) ===
Sprint 1 to 2 (blue): object_events table + interceptors + Activity Feed UI
Sprint 3 to 5 (orange): callback_registrations + delivery_log + SNS/SQS infra + Delivery Worker + DLQ + CloudWatch
Sprint 6 to 7 (teal): HMAC + Circuit Breaker + Webhooks tab UI + Replay API + Test endpoint

STYLE INSTRUCTIONS:
Use enterprise architecture style. Rounded corner boxes with drop shadows.
Color per legend above. All arrows must have direction labels.
Show both vertical flow (top to bottom) and horizontal fan-out (middle section).
Monospace font for table names, API paths, and code values.
Group related components inside bordered containers.
Make the diagram large enough to show all detail — this is a TLM presentation diagram.
