# DV-13856 — Miro Prompt (Simple Version)
**Date:** 2026-05-13
**Why this exists:** The "enterprise_style_arch_product.md" v2 prompt generated floating unconnected boxes.
Root cause: Miro AI ignores ROW/layout instructions and ASCII art. It only reliably draws
what you describe as explicit directed connections ("arrow from A to B").
This prompt fixes that by listing nodes then connections separately.

---

## Paste this into Miro AI → Diagram or mindmap → Flowchart

```
Create a top-to-bottom flowchart titled:
"DV-13856 — Clean Room Observability & Webhook Backbone"
Subtitle: "Platform-grade audit trail + push-based webhook delivery"

─────────────────────────────────────────
NODES — create one labelled box for each:
─────────────────────────────────────────

Node A (blue, 3 boxes side by side):
  A1: unhygienix · Questions
  A2: forebitt · Data Connections
  A3: picanmix · Exports

Node B (purple):
  CRUD Interceptor
  1. Snapshot state BEFORE mutation
  2. Execute mutation
  3. Diff before → after · build ObjectEvent

Node C (blue):
  object_events table
  Append-only audit log
  event_id | object_type | changed_fields JSONB
  performed_by | event_time
  [badge] V1 · Activity Feed UI reads here

Node D (orange):
  SNS Topic: habu-object-events
  One publish → N independent consumers
  Add consumer = new SQS queue, zero code change

Node E1 (blue): SQS-XMI-Delivery
Node E2 (blue): SQS-SafeHaven-Delivery
Node E3 (blue, dashed border): SQS-Future-Delivery

Node F (blue):
  Delivery Workers — pegleg service
  (horizontally scalable — N instances)
  1. receiveMessage → visibility timeout 30s
  2. lookup callback_registrations table
  3. build JSON payload
  4. sign: HMAC-SHA256 → X-Habu-Signature [V3]
  5. circuit breaker check [V3]
  6. HTTP POST to registered callback URL
  7. write to delivery_log table
  8. deleteMessage (ACK)

Node G (red):
  Dead Letter Queue
  SQS-XMI-Delivery-DLQ
  maxReceiveCount = 3 exceeded

Node H (orange): CloudWatch Alarm → PagerDuty / Slack

Node I (green):
  DLQ Admin UI
  Inspect + one-click Replay [V3]

Node J (green):
  XMI UI · /habu-events endpoint
  verifies HMAC signature
  updates UI / cache / workflow

Node K (green): SafeHaven endpoint

Node L (green, dashed border): Future Customer endpoint

─────────────────────────────────────────
CONNECTIONS — draw an arrow for each:
─────────────────────────────────────────

Arrow from A1 to B  label: "mutation event"
Arrow from A2 to B  label: "mutation event"
Arrow from A3 to B  label: "mutation event"

Arrow from B to C   label: "IN TRANSACTION — atomic write"
Arrow from B to D   label: "POST COMMIT · async ~1ms"

Arrow from D to E1
Arrow from D to E2
Arrow from D to E3

Arrow from E1 to F
Arrow from E2 to F
Arrow from E3 to F

Arrow from F to G   label: "failure · retry 1s → 5s → 30s → exceeded"
Arrow from G to H   label: "DLQ depth > 0"
Arrow from G to I

Arrow from F to J   label: "HTTP POST · success"
Arrow from F to K   label: "HTTP POST · success"
Arrow from F to L   label: "HTTP POST · success"

─────────────────────────────────────────
CONTAINER:
─────────────────────────────────────────

Put nodes A1 A2 A3 B C D E1 E2 E3 F G H I
inside one large container box labelled "Habu Platform"

Nodes J K L are OUTSIDE the container (external consumers)

─────────────────────────────────────────
STYLE:
─────────────────────────────────────────

Blue = platform internals (sources, tables, queues, worker)
Purple = interceptor (Node B)
Orange = fan-out SNS + external alarm (D, H)
Red = failure path (G)
Green = delivered value + external consumers (C badge, I, J, K, L)
Rounded rectangle shapes, subtle drop shadow
Monospace font for table names and API paths
```

---

## Why this prompt should work

| Problem with v2 | Fix in this prompt |
|---|---|
| Layout instructions (ROW 1, ROW 2) that Miro AI ignores | No layout instructions — Miro decides layout |
| ASCII art in the prompt body | Removed completely |
| Connections implied by indentation | Every connection is an explicit "Arrow from X to Y" |
| Fan-out branches described spatially | Fan-out described as 3 separate arrow statements |
| Container described inline with content | Container listed as a separate section at the end |

---

## What the diagram should show once generated

```
        Habu Platform
┌─────────────────────────────────────────────────┐
│                                                 │
│  [unhygienix]  [forebitt]  [picanmix]           │
│       │            │           │                │
│       └────────────┴───────────┘                │
│                    │ mutation event              │
│                    ▼                            │
│         [CRUD Interceptor — purple]             │
│          snapshot → mutate → diff               │
│              │                │                 │
│   IN TRANSACTION         POST COMMIT ~1ms       │
│              │                │                 │
│   [object_events table]  [SNS habu-object-events│
│    V1 UI reads here]      │        │        │   │
│                         [E1]     [E2]     [E3]  │
│                           │        │        │   │
│                           └────────┴────────┘   │
│                                    │            │
│              [Delivery Workers — pegleg]         │
│               lookup · build · sign · POST       │
│                    │             │              │
│                 [DLQ]       success HTTP POST    │
│                  │ │                            │
│          [Alarm] [Admin UI]                     │
└─────────────────────────────────────────────────┘
           │              │              │
      [XMI UI]      [SafeHaven]     [Future]
   verifies HMAC    endpoint        endpoint
```
