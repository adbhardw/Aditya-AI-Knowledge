# 2026-05-12 — Webhook Mechanics, Queue vs Table, SNS+SQS vs Kafka

**Context:** DV-13856 — Clean Room Observability MVP (CFI-1388)
**Topics covered:** How webhooks work, Option A vs B for event delivery, SNS+SQS compared to Kafka, corrected architecture separating audit log from webhook delivery.

---

## 1. How Webhooks Work (in this system)

Normal API (what XMI does today — polling):
```
XMI calls Habu every 30s: GET /questions/q-123
Habu: "No change." (99 times out of 100)
Finally: "Yes, 2 columns removed."  ← XMI finds out 30s late
```

Webhook (what we are building):
```
XMI registers once: POST /cleanrooms/{id}/callbacks
  { callbackUrl: "https://xmi.liveramp.com/habu-events" }

User deletes columns in Habu UI
  → unhygienix interceptor fires
  → event written to object_events table (audit log)
  → Java callback worker picks it up
  → HTTP POST to https://xmi.liveramp.com/habu-events  ← Habu calls XMI immediately
  → XMI updates its UI in real time
```

The webhook server mentioned in notes = XMI's inbound HTTPS endpoint that accepts Habu's outbound POST.
The cursor API (GET /events?since=T) is a near-term option for XMI that avoids maintaining a webhook server.

---

## 2. Option A vs Option B for Event Delivery

### Option A — DB Polling Worker
```
Worker runs every 5s:
  SELECT * FROM object_events WHERE processed = false
  → for each row: find callbacks → POST to URL → mark row processed
```

### Option B — Event Queue (SNS → SQS → Worker)
```
unhygienix interceptor → publishes to SNS after transaction commits
Worker is a queue consumer: message arrives → find callbacks → POST → ACK
```

### Why B is better (multiple perspectives)

**Database pressure:**
Option A adds constant SELECT load to the unhygienix DB every 5 seconds per worker — a production transactional DB should not double as a message broker.

**Failure recovery / correctness:**
Option A has a correctness trap: if worker POSTs to XMI successfully but crashes before marking the row `processed = true`, it re-delivers on restart. If it marks processed before POSTing, events can be silently dropped on crash. There is no way to wrap an HTTP call and a DB UPDATE in one atomic operation.

Option B uses SQS visibility timeout: when a worker picks up a message, SQS hides it from other workers for N seconds. If the worker dies, the message reappears automatically — no custom locking needed.

**Concurrency without coordination:**
Option A with multiple workers requires `SELECT FOR UPDATE SKIP LOCKED` (Postgres row locking) to avoid double-delivery — non-trivial, adds lock contention.
Option B: SQS handles message assignment to multiple consumers natively.

**Producer isolation:**
Option A couples the worker to the unhygienix DB schema.
Option B: unhygienix publishes a JSON event to SNS — schema contract the producer owns. Worker only knows about message format, not DB internals.

**Adding new consumers:**
Option A: new consumer = new worker polling the same table, same locking problems.
Option B: subscribe a new SQS queue to the SNS topic — zero changes to unhygienix or existing workers.

---

## 3. SNS + Multiple SQS Queues vs Kafka

### Where they are equivalent

Both support fan-out to multiple independent consumers:
```
Kafka: consumer group A, B, C each get their own copy of every message
SNS+SQS: Queue A, B, C each subscribed to SNS topic, each get their own copy
```
Each consumer is independent — one being slow or behind does not affect others.

### Where Kafka is fundamentally different

Kafka is a **durable append-only log**. The offset concept is the key distinction:
- Each consumer group has an offset pointer: "I have read up to message #4721"
- A new consumer group can **replay from message #1** (beginning of retention window)
- A consumer that crashed for 2 hours **resumes exactly where it left off**
- Retention configurable to weeks or months

SNS + SQS is a **delivery network, not a log**:
- Messages delivered to queues subscribed at time of publishing — old messages are gone
- A new SQS queue subscribed tomorrow gets nothing from today
- No offset concept — SQS uses visibility timeout (lock while processing, reappear on timeout)
- Max SQS retention: 14 days

**Key difference in one sentence:**
Kafka = log you read from at your own pace. SNS+SQS = push delivery that fires and forgets.

### Why it doesn't matter for this design

The `object_events` table is the durable log. Replay is done by querying the table, not the queue. The queue is only the real-time delivery transport for webhooks.

This separation is actually cleaner than Kafka for two jobs:
```
object_events table  →  durable log, queryable, replayable, powers UI
SNS + SQS           →  real-time delivery transport, powers webhooks
```

---

## 4. Corrected Architecture — The Critical Distinction

**Earlier diagram was wrong on the left branch.** It showed an "Event Indexer via SQS" writing to the object_events table. This is unnecessary and removes transactional atomicity.

### Correct design

```
unhygienix interceptor:

  BEGIN TRANSACTION
    doDelete(questionId)              ← mutation
    INSERT INTO object_events (...)   ← audit log, SAME TRANSACTION
  COMMIT

  ← 200 OK returned to user immediately

  (async, non-blocking, after commit)
  if callbacksRegistered:
    sns.publish(event)
         │
         ▼
    SQS Queue (callback delivery)
         │
         ▼
    Callback Delivery Worker (Java)
         │
         ├── POST → XMI endpoint
         └── POST → Customer B endpoint
```

### Why the table write must be in the transaction

If the question deletion commits but the event write fails, the audit log has a silent gap. One DB transaction wrapping both makes them atomic — either both succeed or both roll back. A queue cannot provide this guarantee.

### Two paths are fundamentally different in nature

| | Activity Feed (object_events) | Webhook Delivery (SNS → SQS → Worker) |
|---|---|---|
| Timing | Synchronous, inside DB transaction | Async, after transaction commits |
| Why | Audit log must be atomic with mutation | HTTP POST cannot be inside a DB transaction |
| Failure handling | DB rollback | Retry queue, visibility timeout, DLQ |
| Consumer | UI reads from table | External HTTP endpoints (XMI etc.) |

---

## 5. Java Worker Design (Callback Delivery Worker)

The worker does five things:

1. **Listen** — poll SQS queue (or GCP Pub/Sub equivalent) for new messages
2. **Resolve** — look up registered callback URLs for the changed objectId + objectType
3. **Build payload** — serialize event to JSON (objectName, changeType, changedFields, changedBy, timestamp)
4. **POST** — HTTP call to registered URL with auth header (Bearer / API key / Basic)
5. **Handle outcome** — ACK on success; on failure: retry with backoff; after max retries: send to DLQ

Next topics to cover: retry/backoff logic, DLQ design, HMAC signature verification.

---

## 6. Open Architecture Decision

**For activity feed events (the table write path):** Direct synchronous write in transaction. No queue needed. Correct.

**For webhook delivery:** SNS + SQS or GCP Pub/Sub. Queue is required because HTTP cannot be inside a DB transaction and delivery must be non-blocking.

**If we want to make the design look like a platform-level eventing system (for TLM weight):**
The SNS topic can fan out to multiple SQS queues — one per downstream consumer (XMI, future customer B, audit service, billing). This is the "platform event bus" framing: unhygienix publishes once, N systems receive independently. Adding a new consumer = adding a new SQS subscription. No code change to unhygienix.

This framing positions the work not as "a callback for XMI" but as "an eventing backbone that any Habu service or external integration can subscribe to."

---

## References
- DV-13856_MVP_Confluence_Page.md — full design document
- DV-13856_MVP_Presentation.html — slide deck
- aditya_callback_registration/2026-03-26_concrete_examples_and_delivery_options.md
- aditya_observability_discussion/DV-13856_Observability_Design_Discussion.md
