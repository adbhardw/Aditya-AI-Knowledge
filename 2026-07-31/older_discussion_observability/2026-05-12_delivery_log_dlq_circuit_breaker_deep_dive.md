# 2026-05-12 — delivery_log, DLQ Setup, Circuit Breaker, At-least-once Deep Dive
**Context:** DV-13856 — follow-up on final_good_design_dlq_hmac_fanout_atleast_once.md
**Topics:** How delivery_log works, idempotency scenario, write-before-ACK ordering,
DLQ creation and access, circuit breaker states

---

## 1. delivery_log Table — What It Is

Every HTTP POST attempt the worker makes to a callback URL produces one row in delivery_log.
It is a postal receipt book — every attempt, success or failure, gets a record.

```
Event: evt-789 (Question "Revenue Analysis" columns removed)
Callback registration: cb-456 (XMI)

Attempt 1 — fails:
  event_id: evt-789 | registration_id: cb-456 | attempt_number: 1
  http_status: 500  | response_time_ms: 234
  failure_reason: "Internal Server Error" | delivered_at: NULL

Attempt 2 — succeeds:
  event_id: evt-789 | registration_id: cb-456 | attempt_number: 2
  http_status: 200  | response_time_ms: 45
  delivered_at: 2026-05-12T10:32:15Z
```

### What powers it:

- **V3 Webhooks UI** — green/red status per delivery, last delivered timestamp, failure reason
- **Idempotency check** — before POSTing, worker queries for existing success row
- **Ops debugging** — "why didn't XMI receive the event?" → inspect delivery_log

### Schema

```sql
CREATE TABLE delivery_log (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id   UUID NOT NULL,
    event_id          UUID NOT NULL,
    attempt_number    INT NOT NULL,
    http_status       INT,                    -- 200, 500, null on timeout
    response_time_ms  INT,
    delivered_at      TIMESTAMPTZ,            -- null if not delivered
    failure_reason    VARCHAR,
    payload_hash      VARCHAR,               -- SHA256 of sent body
    UNIQUE (registration_id, event_id, attempt_number)
);
```

### Is delivery_log always needed?

No. Only if you need at least one of:
- Idempotency (prevent duplicate POSTs on SQS re-delivery)
- UI showing delivery status per registration
- Ops visibility into failures

If you want pure fire-and-forget with no tracking: skip it.
For an enterprise callback system: yes, include it.

---

## 2. At-least-once + Idempotency — The Exact Crash Scenario

SQS guarantees at-least-once delivery. In rare cases it delivers the same message twice.

### When it happens

```
Normal flow:
  Step 1: Worker pulls message from SQS
          └─ SQS hides message (visibility timeout = 30s)
  Step 2: POST to XMI → 200 OK       ← XMI received and processed it
  Step 3: ACK SQS (deleteMessage)    ← message gone, never seen again

Crash scenario:
  Step 1: Worker pulls message (hidden for 30s)
  Step 2: POST to XMI → 200 OK       ← XMI received it
  [WORKER CRASHES BEFORE STEP 3]

  30 seconds later:
  SQS: "no ACK received" → makes message visible again
  Worker restarts → pulls same message → Step 2 again
  POST to XMI → 200 OK               ← XMI receives DUPLICATE
```

### How delivery_log prevents the duplicate

```
Worker flow with delivery_log:

  Step 1: Pull message from SQS
  
  Step 1.5: CHECK delivery_log
    SELECT 1 FROM delivery_log
    WHERE event_id = 'evt-789'
      AND registration_id = 'cb-456'
      AND http_status = 200
    LIMIT 1;

    → row found?  → already delivered → ACK SQS → done (no POST)
    → not found?  → proceed to POST

  Step 2: POST to XMI → 200 OK
  Step 2.5: WRITE to delivery_log (success row)  ← BEFORE ACK
  Step 3: ACK SQS (deleteMessage)
```

---

## 3. Why "Write Before ACK" — Order Matters

Two sequences, very different outcomes:

```
WRONG order:
  POST to XMI → 200 OK
  ACK SQS (deleteMessage)         ← message gone from SQS
  CRASH here
  → delivery_log has no record
  → SQS message already deleted, will never reappear
  → event SILENTLY LOST FOREVER — no retry, no DLQ, no trace

RIGHT order:
  POST to XMI → 200 OK
  WRITE to delivery_log           ← persist result first
  CRASH here
  → delivery_log has the success record
  → SQS visibility timeout expires → message reappears
  → Worker restarts → checks delivery_log → "already delivered" → ACK, skip
  → No duplicate sent to XMI

  If no crash:
  WRITE to delivery_log
  ACK SQS                         ← safe to remove now
```

### Is write-before-ACK needed for all SQS cases?

Only if you have delivery_log and need idempotency.
If doing pure fire-and-forget (POST and ACK, no table): write-before-ACK is irrelevant.

---

## 4. DLQ — Creation, Automatic Movement, How to Access

### DLQ is a separate SQS queue you create. AWS moves messages automatically — zero app code.

Setup (three steps, done once in infra/Terraform):

```
Step 1: Create main delivery queue
  aws sqs create-queue --queue-name SQS-XMI-Delivery

Step 2: Create DLQ
  aws sqs create-queue --queue-name SQS-XMI-Delivery-DLQ

Step 3: Configure redrive policy on main queue
  {
    "deadLetterTargetArn": "arn:aws:sqs:us-east-1:...:SQS-XMI-Delivery-DLQ",
    "maxReceiveCount": "3"
  }
```

After step 3: when SQS-XMI-Delivery's receive count for a message hits 3,
AWS moves it to DLQ automatically. Your Java worker code never handles this.

### What lives in DLQ

No separate table. The DLQ queue holds the original message payload — the same JSON
event object that was published to SNS. Nothing new to create.

### How to access DLQ (four ways)

```
Option 1 — AWS Console:
  SQS service → select SQS-XMI-Delivery-DLQ
  → "Send and receive messages" → "Poll for messages"
  View raw JSON payload of each failed message

Option 2 — AWS CLI:
  aws sqs receive-message \
    --queue-url https://sqs.us-east-1.amazonaws.com/123.../SQS-XMI-Delivery-DLQ \
    --max-number-of-messages 10

Option 3 — Java code (same SQS client, just different queue URL):
  String dlqUrl = "https://sqs.../SQS-XMI-Delivery-DLQ";
  sqsClient.receiveMessage(dlqUrl);
  // read, inspect, decide whether to replay

Option 4 — Replay back to main queue (AWS built-in, no code):
  aws sqs start-message-move-task \
    --source-arn arn:aws:sqs:...:SQS-XMI-Delivery-DLQ \
    --destination-arn arn:aws:sqs:...:SQS-XMI-Delivery

  AWS moves all DLQ messages back to main queue.
  Worker picks them up and retries delivery.
```

### CloudWatch alarm on DLQ

```
Metric: ApproximateNumberOfMessagesVisible on SQS-XMI-Delivery-DLQ
Threshold: > 0
Action: SNS → PagerDuty / Slack alert to on-call engineer
```

This means any delivery failure that exhausts all retries pages someone within minutes.
No need to manually watch the DLQ.

---

## 5. Circuit Breaker — Three States Explained

Yes — circuit breaker means: stop calling the webhook endpoint after X consecutive failures,
wait a cooldown period, then probe whether it recovered.

### Three states

```
CLOSED  (normal — endpoint is healthy)
  Worker calls endpoint on every event delivery
  Tracks: failure rate over last 10 calls
  If failure rate > 50% → trips to OPEN

  Example: 6 of last 10 calls returned 5xx → OPEN


OPEN  (endpoint is broken — do not call)
  Worker receives event → circuit says "do not attempt HTTP"
  Fails immediately without making a network call
  Cooldown timer: 60 seconds
  After 60s → trips to HALF-OPEN

  Example: XMI is down for 10 minutes
  Messages for XMI fail instantly → go to DLQ
  Worker threads free to serve SafeHaven (unaffected)


HALF-OPEN  (testing whether endpoint recovered)
  Allows exactly 1 HTTP call through
  → 200 OK  : endpoint recovered → trips to CLOSED, resume normal delivery
  → 5xx     : still broken → trips back to OPEN, wait another 60s
```

### Why circuit breaker on top of DLQ/retry — different problems

```
SQS retry (3 attempts, ~90s total):
  Handles: one bad request — brief timeout, one bad deploy, transient 500

Circuit breaker:
  Handles: sustained outage — endpoint down for 10+ minutes

Without circuit breaker during 10-min XMI outage:
  Message 1:  attempt 1 → timeout (30s wait) → attempt 2 → timeout → attempt 3 → DLQ
  Message 2:  same — 90s of worker threads blocked on broken endpoint
  Message 50: same
  → Worker thread pool saturated retrying a broken endpoint
  → SafeHaven deliveries (healthy) backed up, delayed

With circuit breaker:
  Message 1:  attempt 1 → timeout → attempt 2 → timeout → OPEN circuit
  Messages 2–50: circuit OPEN → fail instantly (no HTTP) → DLQ
  Worker threads free → SafeHaven unaffected
  After 60s: HALF-OPEN → probe XMI → if recovered → CLOSED, resume
```

### Java implementation — Resilience4j (one annotation)

```java
// Configuration
CircuitBreakerConfig config = CircuitBreakerConfig.custom()
    .failureRateThreshold(50)           // 50% failure rate triggers OPEN
    .waitDurationInOpenState(Duration.ofSeconds(60))
    .slidingWindowSize(10)              // evaluate last 10 calls
    .build();

CircuitBreaker cb = CircuitBreaker.of("xmi-endpoint", config);

// Usage — wrap the HTTP call
@CircuitBreaker(name = "xmi-endpoint", fallbackMethod = "handleOpenCircuit")
public void postToCallback(String url, String payload) {
    httpClient.post(url, payload);
}

public void handleOpenCircuit(String url, String payload, CallNotPermittedException ex) {
    // circuit is OPEN — log it, message will go to DLQ via SQS retry
    log.warn("Circuit OPEN for endpoint: {}", url);
    throw ex;  // rethrow so SQS does not ACK — message retried or DLQ'd
}
```

Circuit state stored in memory per worker instance.
For shared state across multiple worker instances: use Redis key per endpoint URL.

---

## 6. Summary Table

| Concept | What ensures it | App code needed? |
|---------|----------------|-----------------|
| Fan-out | SNS subscription per SQS queue | No (infra config) |
| Circuit breaker | Resilience4j in Java worker | Yes (one annotation) |
| HMAC signature | Worker computes HMAC-SHA256, attaches header | Yes |
| DLQ movement | SQS redrive policy config (maxReceiveCount=3) | No (AWS automatic) |
| DLQ access | AWS Console / CLI / Java SQS client | No code for access |
| DLQ replay | aws sqs start-message-move-task | No (AWS built-in) |
| Delivery observability | delivery_log table, worker writes each attempt | Yes |
| At-least-once | SQS default behavior | No |
| Idempotency | Worker checks delivery_log before POST | Yes |
| Write-before-ACK | Ordering in worker code | Yes |

---

## References
- final_good_design_dlq_hmac_fanout_atleast_once.md — full component design
- 2026-05-12_webhook_and_queue_design_discussion.md — Option A vs B, corrected architecture
- DV-13856_MVP_Confluence_Page.md — full MVP document
