# Q&A — Callback Registration, ACK, delivery_log
**Date:** 2026-05-12
**Context:** DV-13856 Clean Room Observability — follow-up Q&A from deep dive session

---

## Q1: How and where is a callback registered? Is it question-level or org-level?

**Short answer:** Cleanroom-level registration is the right MVP granularity — one registration
covers all questions (or all data connections) in a cleanroom. Not per-question, not per-org.

### Registration API

XMI calls this once per cleanroom they want to monitor:

```
POST /cleanrooms/{crId}/callbacks
{
  "objectType": "QUESTION",          -- QUESTION, DATA_CONNECTION, ALL
  "objectId": null,                  -- null = all questions in this CR
                                     -- or a specific UUID for one question
  "callbackUrl": "https://xmi.liveramp.com/habu-events",
  "monitoredFields": ["dimensions", "status", "name", "datasetAssignments"],
  "authConfig": {
    "authType": "BEARER",
    "authValue": "eyJhbGciOiJSUzI1..."
  }
}

Response:
{
  "id": "cb-456",
  "cleanroomId": "cr-abc",
  "objectType": "QUESTION",
  "callbackUrl": "https://xmi.liveramp.com/habu-events",
  "signingSecret": "whsec_a3f9c2...",   ← XMI stores this for HMAC verification
  "createdAt": "2026-05-12T10:00:00Z"
}
```

### Where the registration is stored

`callback_registrations` table in unhygienix DB:

```
id:               cb-456
cleanroom_id:     cr-abc
org_id:           org-xyz
object_type:      QUESTION
object_id:        NULL          ← means "all questions in this cleanroom"
callback_url:     https://xmi.liveramp.com/habu-events
auth_config:      { type: BEARER, value: encrypted }
signing_secret:   whsec_a3f9c2... (encrypted at rest)
monitored_fields: ["dimensions", "status", "name"]
created_at:       2026-05-12T10:00:00Z
```

This is a NEW table (V2). Needs a DB migration in unhygienix.

### Granularity options compared

| Level | Registration | Events received | Practical? |
|-------|-------------|-----------------|------------|
| Per question | One per question ID | Only that question | XMI would register hundreds of callbacks — impractical |
| Per cleanroom | One per cleanroom, per object type | All questions in that CR | Practical — XMI has ~10 cleanrooms, 2 object types = ~20 registrations |
| Per org | One for entire org | All cleanrooms, all object types | Too noisy — hard to route on receiver side |

**MVP recommendation:** cleanroom-level, per object type.
XMI registers once for QUESTION changes in cleanroom cr-abc.
All future question changes in that cleanroom trigger that one callback.

### How the worker matches event → callback

When event evt-789 fires (question q-123 changed in cleanroom cr-abc):

```sql
SELECT * FROM callback_registrations
WHERE cleanroom_id = 'cr-abc'
  AND object_type IN ('QUESTION', 'ALL')
  AND (object_id = 'q-123' OR object_id IS NULL)
  AND active = true;
```

Returns: cb-456 (XMI's registration)
Worker uses cb-456's callbackUrl and authConfig to POST the event.
delivery_log records: event_id=evt-789, registration_id=cb-456.

---

## Q2: Event evt-789 → registered callback cb-456 (XMI) — what is this mapping?

The mapping is: one event can trigger multiple callbacks, tracked via delivery_log.

```
object_events table:
  id: evt-789
  object_type: QUESTION
  object_id: q-123
  cleanroom_id: cr-abc
  event_type: UPDATED
  changed_fields: { dimensions: { removed: ["customer_segment"] } }
  performed_by: sarah@acme.com

callback_registrations table:
  id: cb-456    ← XMI registered this
  cleanroom_id: cr-abc
  object_type: QUESTION
  callback_url: https://xmi.liveramp.com/habu-events

  id: cb-789    ← SafeHaven registered this (future)
  cleanroom_id: cr-abc
  object_type: QUESTION
  callback_url: https://safehaven.com/events

delivery_log rows created for evt-789:
  event_id: evt-789, registration_id: cb-456  ← delivery to XMI
  event_id: evt-789, registration_id: cb-789  ← delivery to SafeHaven (independent)
```

One event → worker finds N matching registrations → N separate HTTP POSTs →
N separate delivery_log rows. Each delivery is tracked independently.

---

## Q3: What does ACK mean? Do you have to ACK separately after reading?

**Yes — ACK in SQS is a separate explicit step. Reading a message does NOT delete it.**

### What happens when worker reads from SQS

```
Step 1: sqsClient.receiveMessage(queueUrl)
  → SQS returns the message to the worker
  → SQS makes the message INVISIBLE to all other workers (visibility timeout = 30s)
  → Message is NOT deleted — it is just hidden
  → SQS gives back a receiptHandle token with the message

Step 2: Worker processes the message (POST to XMI)

Step 3: sqsClient.deleteMessage(queueUrl, receiptHandle)
  → This is the ACK
  → SQS permanently deletes the message
  → Done
```

If step 3 never happens (worker crashes):
```
After 30s: SQS makes the message visible again automatically
Other worker (or restarted worker) picks it up → retry
```

### ACK = deleteMessage in SQS terminology

```java
// Read
ReceiveMessageResult result = sqsClient.receiveMessage(queueUrl);
Message msg = result.getMessages().get(0);
String receiptHandle = msg.getReceiptHandle();  // token for this specific read

// Process
httpClient.post(callbackUrl, buildPayload(msg));

// ACK — explicit delete
sqsClient.deleteMessage(queueUrl, receiptHandle);
```

The receiptHandle is unique to each read of a message — it is not the message ID.
If the same message is delivered twice (after visibility timeout), it has a different receiptHandle each time.

### "Just POST and ACK" flow (no delivery_log)

If you skip delivery_log entirely:
```
1. Read message from SQS
2. POST to callback URL
3. deleteMessage (ACK)
Done.
```
Simple. No idempotency protection, no UI observability, no ops debugging.
Acceptable for early MVP. Add delivery_log when you need the Webhooks UI tab.

---

## Q4: Is delivery_log a new table that needs to be created?

**Yes. It is a brand new table. It does not exist anywhere in the current system.**

### What needs to be created for the full design (all new)

| Table | Purpose | Sprint | Where |
|-------|---------|--------|-------|
| `object_events` | Audit log of all mutations, powers activity feed UI | V1 | unhygienix DB |
| `callback_registrations` | Stores registered callback URLs per cleanroom | V2 | unhygienix DB |
| `delivery_log` | Records every HTTP delivery attempt | V2 | Worker DB (or unhygienix DB) |

### Minimum for MVP V2 (without full observability)

If you want to ship webhooks without the delivery UI tab:
- `callback_registrations` — must have (needed to know where to POST)
- `delivery_log` — optional for MVP, add in V3 when building Webhooks UI tab

### DB migration needed

```sql
-- V2 migration 1: callback_registrations
CREATE TABLE callback_registrations (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cleanroom_id     UUID NOT NULL,
    org_id           UUID NOT NULL,
    object_type      VARCHAR NOT NULL,   -- QUESTION, DATA_CONNECTION, ALL
    object_id        UUID,               -- NULL = all objects of this type
    callback_url     VARCHAR NOT NULL,
    auth_config      JSONB,
    signing_secret   VARCHAR,
    monitored_fields JSONB,
    active           BOOLEAN DEFAULT true,
    created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- V2 migration 2: delivery_log
CREATE TABLE delivery_log (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id  UUID NOT NULL,
    event_id         UUID NOT NULL,
    attempt_number   INT NOT NULL,
    http_status      INT,
    response_time_ms INT,
    delivered_at     TIMESTAMPTZ,
    failure_reason   VARCHAR,
    UNIQUE (registration_id, event_id, attempt_number)
);
```

### V1 already has one new table

```sql
-- V1 migration: object_events (already discussed)
CREATE TABLE object_events (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cleanroom_id   UUID NOT NULL,
    object_type    VARCHAR NOT NULL,
    object_id      UUID NOT NULL,
    object_name    VARCHAR,
    event_type     VARCHAR NOT NULL,
    changed_fields JSONB,
    performed_by   VARCHAR,
    org_id         UUID NOT NULL,
    event_time     TIMESTAMPTZ DEFAULT NOW()
);
```

So across V1 + V2: three new tables total, all in unhygienix DB, all via standard Flyway/Liquibase migrations.

---

## Summary

| Question | Answer |
|----------|--------|
| Where is callback registered? | Via POST /cleanrooms/{crId}/callbacks — stored in callback_registrations table |
| Question-level or org-level? | Cleanroom-level per object type — one registration covers all questions in a CR |
| How does evt-789 → cb-456 mapping work? | Worker queries callback_registrations by cleanroom_id + object_type → finds cb-456 → POSTs evt-789 to its URL |
| What is ACK? Automatic after read? | No — explicit sqsClient.deleteMessage(receiptHandle). SQS only hides message on read; you must delete it manually |
| Is delivery_log new? | Yes — new table, DB migration needed in unhygienix. Optional for MVP, required for Webhooks UI tab |
