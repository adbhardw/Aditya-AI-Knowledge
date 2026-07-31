# DV-13856: Callback Registration / Observability — Design Discussion
**Aditya Bhardwaj, Staff L5, LiveRamp**
**Date: April 30, 2026**
**Context: CFI-1388 — Clean Rooms Feel Like Enterprise Software**

---

## The Core Problem

Clean room objects (Questions, Data Connections, Export Jobs, Flows) live in Habu. External
systems and internal users hold references to those objects. When state changes — a question
is deleted, a data connection's status flips, a flow is paused — those references go stale.

Two different audiences need to know about changes:

| Audience | Need | Solution shape |
|----------|------|----------------|
| **Human users** on the Habu platform | "What changed in my clean room and when?" | Activity Feed UI |
| **Programmatic systems** (XMI UI, customer integrations) | React automatically when an object changes | Webhook / callback delivery |

DV-13856 was written for the programmatic consumer (XMI UI). But the Activity Feed UI serves
a broader audience and is higher ROI for the CFI-1388 OKR.

---

## Industry Patterns — Full Landscape

### Pattern A — Polling (Naive Pull)
External system calls `GET /questions/{id}` on a timer and diffs the response.

- Who uses it: legacy enterprise integrations, quick prototypes
- Problem: 99% of calls return "nothing changed". Cannot detect deletes — the object
  is gone, GET returns 404, you don't know WHEN it was deleted or WHO deleted it.
- This is probably what XMI UI does today.

---

### Pattern B — Audit Log API with Cursor (Smart Pull)

Platform maintains an ordered, append-only event log. External system polls the log
using a timestamp or cursor, not the object itself.

```
GET /cleanrooms/{id}/events?since=2026-04-29T10:00:00Z&objectType=QUESTION

Response:
[
  { "event": "DELETED",        "objectId": "q-123", "objectType": "QUESTION",
    "deletedBy": "user@lr.com", "timestamp": "2026-04-30T10:05Z" },
  { "event": "FIELD_CHANGED",  "objectId": "q-456", "objectType": "QUESTION",
    "changedFields": { "name": { "old": "Q1", "new": "Q2" } },
    "changedBy": "user@lr.com", "timestamp": "2026-04-30T10:10Z" }
]
```

**Where are events stored?**
In a dedicated append-only database table. NOT in the object's own row.
The object row stores current state. The events table stores history.

```sql
CREATE TABLE object_events (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cleanroom_id   UUID NOT NULL,
    object_type    VARCHAR NOT NULL,  -- QUESTION, DATA_CONNECTION, EXPORT_JOB, FLOW
    object_id      UUID NOT NULL,
    object_name    VARCHAR,           -- denormalized for display (name at time of event)
    event_type     VARCHAR NOT NULL,  -- CREATED, UPDATED, DELETED, STATUS_CHANGED
    changed_fields JSONB,             -- { "name": {"old": "Q1", "new": "Q2"} }
    performed_by   VARCHAR,           -- user email or "system"
    org_id         UUID NOT NULL,
    event_time     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for the polling query
CREATE INDEX idx_object_events_cleanroom_time
    ON object_events (cleanroom_id, event_time DESC);
```

Every mutation in unhygienix (create/update/delete) writes a row here BEFORE returning.
This is an interceptor — one place, all objects.

**Real-world examples:** Stripe Events API, GitHub Audit Logs, AWS CloudTrail

- Pro: No registration needed. Consumer controls its own polling rate.
  Simple to implement on the server side — just inserts.
- Con: Still polling. Latency = polling interval (30s? 60s?).
  XMI must manage cursor state (remember "I last read up to timestamp T").
  Wasted API calls when nothing has changed.

---

### Pattern C — Webhooks, Synchronous Delivery (Push, Naive)

External system registers a callback URL upfront. Platform calls that URL INSIDE the
same HTTP request cycle as the mutation — before returning 200 OK to the caller.

```
Caller → DELETE /questions/q-123
           ↓ (unhygienix deletes the row)
           ↓ (before returning...) POST https://xmi-ui/webhooks/habu { event: "DELETED" }
           ↓ (waits for XMI to respond... 200ms... 2s... timeout?)
         ← 200 OK returned to caller
```

**The critical problem:**
The delete operation is BLOCKED waiting for XMI's server to respond.
- If XMI is slow: your delete takes 2 seconds instead of 50ms
- If XMI is down: your delete fails or times out
- If XMI returns 500: do you roll back the delete? Or ignore it?

You have coupled your system's availability to the external system's availability.
This is why synchronous webhook delivery is considered an anti-pattern in production.

Acceptable only for: internal systems on the same network with guaranteed low latency.

---

### Pattern D — Async Webhooks with Queue (Push, Production-grade)

Mutation happens → event published to internal queue (SNS/SQS/Kafka) — non-blocking,
~1ms → separate worker reads from queue → POSTs to registered callback URL →
retries with exponential backoff on failure → Dead Letter Queue after max retries.

```
Caller → DELETE /questions/q-123
           ↓ unhygienix deletes the row
           ↓ publishes to SNS: { event: "DELETED", objectId: "q-123", callbackUrl: "..." }
         ← 200 OK returned immediately (main operation NOT blocked)

[2 seconds later, async worker]
           → POST https://xmi-ui/webhooks/habu { event: "DELETED", ... }
           ← 500 (XMI is having issues)
           → retry after 5s
           ← 200 OK
           → mark delivery as SUCCEEDED
```

- Pro: Main operation never blocked. Reliable delivery. Production-grade.
- Con: Not instantaneous (seconds delay). More infrastructure to build.
  Every new customer/integration must maintain a webhook endpoint (see pain point section below).

**Habu already has SNS in picanmix** (for job run events). The plumbing exists.
What's missing: callback_registrations table + HTTP delivery worker.

**Real-world examples:** Stripe Webhooks, GitHub Webhooks, Shopify, Twilio

---

### Pattern E — SSE vs WebSocket (Real-time Streaming)

Both keep a long-lived connection open so the server can push events the instant they happen.

#### SSE (Server-Sent Events)
- **One-directional**: server → client only
- Built on plain HTTP. Browser opens one connection, server streams events as text.
- Client cannot send messages back over the same connection.
- Analogy: **FM radio broadcast**. The station (server) transmits. You (client) receive.
  You cannot talk back to the radio station.
- Reconnects automatically if connection drops.
- Good for: live dashboards, notification feeds, progress bars

```
Client: GET /cleanrooms/{id}/events/stream   (keeps connection open)
Server: data: {"event":"DELETED","objectId":"q-123"}\n\n   ← pushed instantly
Server: data: {"event":"UPDATED","objectId":"q-456"}\n\n   ← pushed instantly
```

#### WebSocket
- **Bi-directional**: client ↔ server, both can send at any time
- Upgrades HTTP connection to a persistent socket
- Analogy: **phone call**. Both parties can speak at any time.
- Good for: chat, collaborative document editing, multiplayer games, live trading

#### Why Both Are Overkill for DV-13856

Clean room objects do not change every second. A question might be updated once a day.
Keeping a persistent connection open per user just to detect that infrequent change is
wasteful:
- Server must maintain connection state for every active user/integration
- Reconnection logic, heartbeats, connection pooling — significant infrastructure
- If the tab closes or the integration restarts, you miss events and need a catch-up mechanism

The latency benefit (sub-second vs seconds) is not worth this complexity for object-level
change notifications. Use async webhooks (Pattern D) or the Activity Feed UI instead.

---

## The Pain Point: Webhook URL Per Customer

This is a real and important objection.

If DV-13856 is implemented purely as "register a callback URL," then:

1. Every customer who wants notifications must **run and maintain a server** that accepts
   inbound HTTPS POST requests
2. That server must be **publicly reachable** (or reachable from Habu's network)
3. That server must handle **authentication** (verify the request is genuinely from Habu)
4. That server must handle **idempotency** (what if the same event is delivered twice?)
5. That server must handle **backpressure** (what if 1000 events fire simultaneously?)

For a large enterprise customer with a dedicated engineering team: manageable.
For a mid-market customer or a team using the XMI UI without backend engineering: a blocker.

**This is exactly why the Activity Feed UI approach has higher ROI for CFI-1388.**

Comparison:

| | Webhook (callback URL) | Activity Feed UI |
|--|------------------------|-----------------|
| Who benefits | Customers with engineering teams | Every user on the platform |
| Setup required | Maintain a server endpoint | None — just open the tab |
| Misses events if... | Server is down | Never — events are in DB |
| Latency | Seconds (async) | Real-time (page load) |
| Debugging | Hard — need server logs | Easy — visible in UI |
| Implementation effort | High (DB + interceptor + worker + retry + DLQ) | Medium (DB + interceptor + read endpoint + UI) |

---

## Revised Approach: Three Versions

### V1 — Activity Feed UI (2 sprints)

**What it is:**
An "Activity" tab inside the Clean Room UI. Shows a chronological feed of all changes
to all object types (Questions, Data Connections, Export Jobs, Flows) within that clean room.
Filterable by object type, date range, user.

**How it works:**
1. Add `object_events` table to unhygienix (schema above)
2. Add interceptors in unhygienix for create/update/delete of each object type
   — each interceptor writes a row to `object_events` with before/after diff
3. New read endpoint: `GET /cleanrooms/{id}/events`
4. UI tab: renders the event feed

**No webhook infrastructure. No registration. No delivery concerns.**

Users see this directly in the platform. Answers "what happened to my question?"
without filing a support ticket.

---

### V2 — V1 + Webhook Registration for Programmatic Consumers (2-3 sprints on top of V1)

**What it is:**
For customers with engineering teams (like XMI UI), allow registering a callback URL
that gets called when events occur. Builds on V1's `object_events` table and interceptors —
the interceptor now also publishes to SNS for delivery.

**New components on top of V1:**
1. `callback_registrations` table: (objectId, objectType, callbackUrl, monitoredFields, authConfig)
2. External API CRUD: `POST /cleanrooms/{id}/callbacks`, GET, PUT, DELETE
3. SNS publish step in interceptors (after writing to object_events, also publish to SNS)
4. Callback delivery worker: reads from SNS, HTTP POSTs to registered URL, retries 3x

**V1 interceptors are reused.** The delivery mechanism is separate.

---

### V3 — V2 + Production Hardening (1-2 sprints on top of V2)

Additional hardening for external/enterprise customers:
- HMAC signature on every webhook payload (receiver can verify authenticity)
- Dead Letter Queue with admin visibility (see and replay failed deliveries)
- Event replay: "re-deliver all events for object X from date Y"
- Webhook delivery status visible in UI (green/red per registration)
- Per-field subscriptions enforced precisely (not just "any field changed")

---

## Shared Foundation: The Interceptor Pattern

All three versions depend on one correctly-built component: the **update/delete interceptor**
in unhygienix.

```
Before/After interceptor (pseudo-code in Go/Java):

func DeleteQuestion(id) {
    before = loadQuestion(id)           // snapshot current state
    doDelete(id)                        // actual DB delete
    event = buildEvent("DELETED", before, nil, currentUser)
    objectEventsRepo.insert(event)      // V1: write to DB for UI
    if callbacksExist(id):
        sns.publish(event)              // V2: async delivery to registered URLs
}

func UpdateQuestion(id, patch) {
    before = loadQuestion(id)
    doUpdate(id, patch)
    after = loadQuestion(id)
    diff = computeDiff(before, after)   // { "name": { "old": "Q1", "new": "Q2" } }
    if diff is not empty:
        event = buildEvent("UPDATED", before, diff, currentUser)
        objectEventsRepo.insert(event)  // V1
        if callbacksExist(id) AND diff.intersects(registration.monitoredFields):
            sns.publish(event)          // V2
}
```

Build the interceptor once. V1 uses the DB write. V2 adds the SNS publish on top.

---

## Recommendation

**Ship V1 first.**

- Gets value into users' hands in 2 sprints
- No delivery infrastructure risk
- Interceptors built correctly become the foundation for V2
- Directly serves the CFI-1388 OKR ("Clean Rooms Feel Like Enterprise Software")
  — audit trail and activity history is a table-stakes enterprise feature

**Add V2 in the same quarter** only if XMI UI team explicitly cannot use the polling API
(Pattern B) as their integration mechanism. The polling API from V1's read endpoint is
a viable XMI integration path without the webhook URL pain point.

---

## Open Questions

1. Is XMI UI the only programmatic consumer, or are there external customers who need webhooks?
2. Does unhygienix currently have a consistent update/delete path per object type, or is
   it scattered across services? (Interceptor placement depends on this.)
3. Which object types are in scope for V1: Questions only, or also Data Connections,
   Export Jobs, and Flows?
4. Retention policy: how long do we keep rows in object_events? 90 days? 1 year?
5. Does the Activity Feed UI need to be scoped per-org (all clean rooms) or per-clean-room?

---

**References:**
- DV-13856: Callback Registration Tool (Jon Chua, 2026-03-11)
- CFI-1388: Clean Rooms Feel Like Enterprise Software (FY27Q1)
- Related: DV-13789 (Better Ingestion Observability), DV-13837 (Export Non-Report Files)
- Habu existing SNS events: picanmix/services/events/config.go
