# Tradeoff: Lambda Bridge (SNS → Lambda) vs orinix (SNS → SQS → orinix)
**Date:** 2026-06-22
**Author:** Aditya Bhardwaj
**Context:** DV-15090 — delivery of observability events to XMI's GCP Pub/Sub.
**Question answered:** Can Lambda subscribe to SNS directly? And should we use it instead of orinix?

---

## SNS Subscriber Protocols

SNS supports multiple subscriber types — SQS is not the only option:

```
SNS subscriber protocols:
  - sqs       → pushes message to an SQS queue
  - lambda    → directly invokes a Lambda function
  - http/https → POSTs to an HTTP endpoint
  - email     → sends an email
  - sms       → sends a text
  - firehose  → streams to Kinesis Firehose
```

Yes — Lambda can subscribe to SNS directly. No SQS required in between.

---

## Option A — Lambda Bridge (SNS → Lambda directly)

```
SNS: habu-observability-events
  ├── subscription: sqs    → sqs-orinix-consumer   (orinix reads, writes object_events)
  └── subscription: lambda → bridge-lambda         (invoked directly, publishes to GCP Pub/Sub)
```

**Terraform:**

```hcl
resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.habu_observability_events.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.pubsub_bridge.arn
}

resource "aws_lambda_permission" "allow_sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pubsub_bridge.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.habu_observability_events.arn
}
```

**What Lambda does:**
```
SNS invokes Lambda with event payload
  → Lambda parses SNS envelope
  → Lambda calls google-cloud-pubsub SDK
  → Lambda publishes to XMI's GCP Pub/Sub topic
  → Lambda exits
```

**Failure behavior:**
- If Lambda errors or times out: SNS retries **2 more times** with backoff, then gives up
- After 3 total attempts: message is **lost** unless a DLQ is configured on the Lambda
- A Lambda cold start spike or throttle during a burst = dropped events
- No queue buffering the message between SNS and Lambda

---

## Option B — orinix (SNS → SQS → orinix)

```
SNS: habu-observability-events
         ↓
SQS: sqs-habu-observability-consumer   (durable, 4-day retention)
         ↓
orinix (persistent service)
  [1] INSERT INTO object_events         ← always
  [2] publish to XMI GCP Pub/Sub        ← for registered consumers
  [3] deleteMessage from SQS            ← explicit ACK only after both succeed
```

**Failure behavior:**
- If orinix crashes mid-processing: message reappears in SQS after visibility timeout (30s)
- If GCP Pub/Sub publish fails: orinix does not delete the SQS message → automatic retry
- After max retries: message moves to SQS DLQ → alarm fires → inspectable, replayable
- Message is **never lost** as long as it reaches SQS

---

## Side-by-Side Tradeoff

| Dimension | Lambda Bridge (SNS → Lambda) | orinix (SNS → SQS → orinix) |
|---|---|---|
| **Durability** | No queue buffer. 3 SNS retry attempts, then lost. | SQS stores up to 14 days. Message survives orinix crash/deploy. |
| **Retry on failure** | SNS retries 2x then gives up. DLQ must be manually configured on Lambda. | SQS visibility timeout auto-retries. DLQ catches after max retries. |
| **Lost events on deploy** | Lambda cold start during deploy = possible drops | SQS queues messages during orinix deploy. Processed when it comes back. |
| **Burst handling** | Lambda throttle during burst = drops unless reserved concurrency set | SQS absorbs bursts. orinix processes at its own pace. |
| **Complexity** | Simpler infra: no SQS queue to manage | One extra SQS resource, but already needed for orinix object_events writes |
| **Cost** | Cheaper for very low volume (Lambda billed per invocation) | SQS + compute cost, but orinix is a persistent service anyway |
| **Observability** | DLQ requires separate Lambda DLQ config | SQS DLQ is standard, message content inspectable in AWS console |
| **object_events write** | Lambda would need to call orinix gRPC OR write to DB directly | orinix writes both object_events and Pub/Sub in one processing loop |
| **Adding a new consumer** | New Lambda per consumer type (GCP, Azure, etc.) | orinix queries consumer_registrations, one service handles all |
| **Credential management** | Lambda environment variable (SA key or WIF) | orinix environment/config (same credential options) |

---

## Why orinix Wins for This Use Case

The Lambda bridge was a conceptual placeholder in the original Confluence design — it illustrated
"some compute that crosses the cloud boundary." That compute IS orinix.

Three reasons orinix is the right choice over a separate Lambda:

**1. orinix already consumes from SQS for object_events writes.**
Adding a second output (GCP Pub/Sub publish) to orinix's existing SQS processing loop
is ~10 lines of code. A separate Lambda is a whole new deployment, new IAM role,
new monitoring, new DLQ config — for work that orinix is already positioned to do.

**2. SQS durability is non-negotiable for event delivery.**
The explicit ACK pattern (delete SQS message only after BOTH object_events write AND
Pub/Sub publish succeed) guarantees no event is lost. Direct SNS → Lambda gives up
after 3 attempts with no durable buffer. For XMI's Flow chaining use case, a dropped
FLOW_RUN completed event means Flow 2 never triggers — silent failure.

**3. orinix scales to N consumers without N Lambdas.**
When team MI or SafeHaven wants Pub/Sub or Azure Service Bus delivery:
orinix queries `internal_consumer_registrations`, finds their delivery config, and delivers.
The Lambda approach would require a new Lambda per consumer cloud with a new SDK dependency
and new credential set per Lambda.

---

## When Lambda Bridge IS the Right Call

Lambda directly subscribing to SNS makes sense when:
- The task is stateless and idempotent (losing an occasional event is acceptable)
- Very low volume (cost of SQS not justified)
- Simple fan-out to a known, fixed set of destinations with no routing logic
- Prototype or internal tooling, not production event delivery

For production event delivery where XMI's workflow automation depends on receiving every event: **orinix with SQS durability is the right architecture.**
