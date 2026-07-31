# DV-13856 — Enterprise Architecture Miro Prompt
**Date:** 2026-05-13
**Feature:** Clean Room Observability & Webhook Backbone
**Diagram type:** Flowchart (spatial architecture — top-to-bottom flow, horizontal fan-out)
**Miro selection:** Diagram or mindmap → Flowchart

---

This is a spatial architecture diagram with top-to-bottom flow and horizontal fan-out.

---

## Why the first attempt went messy
Miro AI treated the V3 strip, legend, and fan-out branches as separate flowchart columns — diagram exploded horizontally. Fix: single strict vertical spine, fan-out stays compact, no side strips, no legend block.

---

## Miro Prompt v2 — Clean version (paste into Miro AI after selecting Flowchart)

```
Create a clean, compact enterprise architecture flowchart titled:
"DV-13856 — Clean Room Observability & Webhook Backbone"
Subtitle: "Platform-grade audit trail + webhook delivery for Habu Clean Rooms"

CRITICAL LAYOUT RULE: Strict top-to-bottom vertical flow. Keep the diagram narrow and tall, not wide. Do not spread branches into side columns.

All components sit inside one large outer container box labeled:
"Habu Platform"

─── ROW 1 — Mutation Sources (3 small blue boxes, horizontal, centered) ───

  [unhygienix · Questions]   [forebitt · Data Connections]   [picanmix · Exports]

All three merge into a single arrow pointing DOWN labeled "mutation event"

─── ROW 2 — Interceptor (purple box, full width) ───

  "CRUD Interceptor — unhygienix"
  1. Snapshot state BEFORE mutation
  2. Execute mutation
  3. Diff before vs after → build ObjectEvent

TWO arrows out of this box — keep both on the vertical spine:

  LEFT branch arrow labeled "[IN TRANSACTION — atomic]" → small left indent:
    Box (blue): "object_events table
                 Append-only audit log
                 event_id | object_type | changed_fields (JSONB)
                 performed_by | event_time"
    Small green badge on right: "← V1 · Activity Feed UI reads here"

  CENTER/RIGHT arrow labeled "[POST COMMIT async ~1ms]" continues DOWN:

─── ROW 3 — Fan-out (orange box) ───

  "SNS Topic: habu-object-events
   One publish → N independent consumers
   New consumer = new SQS subscription, zero code change"

  Three arrows DOWN (compact, close together):
    [SQS-XMI-Delivery]   [SQS-SafeHaven-Delivery]   [SQS-Future-Delivery]

─── ROW 4 — Delivery Workers (blue box, full width) ───

  "pegleg — Callback Delivery Workers  (horizontally scalable — N instances)"

  Single vertical step list inside:
    1  receiveMessage → visibility timeout 30s starts
    2  lookup callback_registrations → find callback URL + auth
    3  build JSON payload
    4  sign: HMAC-SHA256 → X-Habu-Signature header  [V3]
    5  circuit breaker check: CLOSED / OPEN / HALF-OPEN  [V3]
    6  HTTP POST to callback URL
    7  write to delivery_log table (before ACK)
    8  deleteMessage → ACK SQS

  Two small side boxes attached to the worker (right side, do NOT make new columns):
    Box A (attached to step 2): "callback_registrations table · cb-456 | cr-abc | QUESTION"
    Box B (attached to step 7): "delivery_log table · evt-789 | attempt=1 | http_status=200"

─── ROW 5 — Failure Path (compact, red, below worker) ───

  Arrow labeled "on failure: retry 1s → 5s → 30s, then maxReceiveCount=3 exceeded" → 

  Box (red): "Dead Letter Queue · SQS-XMI-Delivery-DLQ
              AWS moves message automatically"

  Two arrows from DLQ (keep inline, not side columns):
    → Box: "CloudWatch Alarm · DLQ depth > 0 → PagerDuty / Slack"
    → Box (green): "DLQ Admin UI · inspect + one-click Replay  [V3]"

─── BOTTOM — External Consumers (3 orange boxes, outside platform container) ───

  [XMI UI · /habu-events · verifies HMAC · updates UI/cache/workflow]
  [SafeHaven · independent queue · XMI issues do not affect this]
  [Future Customer · any HTTPS endpoint · self-serve registration]

STYLE RULES:
- Rounded rectangle boxes, subtle drop shadow
- Blue: platform internals · Purple: interceptor · Orange: fan-out + consumers
- Green: UI and delivered value · Red: failure path
- [V3] badges on HMAC, circuit breaker, DLQ Admin UI steps
- Monospace font for table names and API paths
- Keep width compact — do not spread into wide columns
```
