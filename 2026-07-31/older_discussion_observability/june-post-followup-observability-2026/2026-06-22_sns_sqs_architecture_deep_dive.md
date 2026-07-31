# SNS vs SQS — Data Structure and Terraform Subscription Wiring
**Date:** 2026-06-22
**Author:** Aditya Bhardwaj
**Context:** Understanding SNS internals and how TF subscriptions wire SNS → SQS for orinix.

---

## The Fundamental Difference

**SQS** — queue, producer pushes in, consumer polls and pulls out, message stored until read.
You understand this model already.

**SNS** — NOT a queue. A routing table (called a topic) with a subscriber list.
No storage. When a message arrives, SNS immediately pushes to every subscriber and the message is gone.
If a subscriber is down at that instant, that subscriber misses the message.

This is why SNS alone is never used for durability. The pattern is always:
**SNS (fan-out) → SQS (durability)** per consumer.

---

## SNS Internal Data Structure

A topic is a named ARN with a subscriber list:

```
SNS Topic: habu-observability-events
  ARN: arn:aws:sns:us-east-1:123456:habu-observability-events

  Subscriber list:
  ┌─────────────────────────────────────────────────────────────────┐
  │ subscription-id-1 │ protocol: sqs  │ endpoint: sqs-orinix ARN  │
  │ subscription-id-2 │ protocol: sqs  │ endpoint: sqs-team-mi ARN │
  │ subscription-id-3 │ protocol: http │ endpoint: https://...     │
  └─────────────────────────────────────────────────────────────────┘
```

When forebitt calls `sns.publish(topicArn, message)`:
1. SNS accepts the message (~1ms)
2. SNS looks up the subscriber list
3. SNS calls `sqs.sendMessage` on each SQS subscriber in parallel
4. forebitt's `publish()` call returns — it does NOT wait for SQS writes to complete

---

## SNS Envelope — What Lands in SQS

SNS wraps your original payload before writing to SQS. orinix must unwrap it:

```json
{
  "Type":      "Notification",
  "MessageId": "abc-uuid",
  "TopicArn":  "arn:aws:sns:us-east-1:123456:habu-observability-events",
  "Message":   "{ \"objectType\": \"DATA_CONNECTION\", \"objectId\": \"97b6cf...\" }",
  "Timestamp": "2026-06-22T10:30:00Z",
  "MessageAttributes": {
    "object_type": { "Type": "String", "Value": "DATA_CONNECTION" },
    "org_id":      { "Type": "String", "Value": "org-xyz" }
  }
}
```

The original payload is in `"Message"` as a JSON string inside the envelope.
orinix parses the outer SNS envelope first, then parses the inner `Message` field.
This double-parse is a common implementation gotcha.

---

## Terraform — Three Resources Required to Wire SNS → SQS

```hcl
# 1. SNS topic — the broadcast channel
resource "aws_sns_topic" "habu_observability_events" {
  name = "habu-observability-events"
}

# 2. SQS queue — orinix's durable inbox
resource "aws_sqs_queue" "orinix_consumer" {
  name                       = "sqs-habu-observability-consumer"
  message_retention_seconds  = 345600   # 4 days
  visibility_timeout_seconds = 30
}

# 3. Subscription — THE wire between SNS and SQS
#    Creates the entry in SNS's subscriber list.
#    Without this resource, SNS has no idea the SQS queue exists.
resource "aws_sns_topic_subscription" "orinix_sub" {
  topic_arn = aws_sns_topic.habu_observability_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.orinix_consumer.arn
}

# 4. SQS queue policy — grants SNS IAM permission to write to this queue
#    Without this, SNS's push attempt is rejected by SQS (AccessDenied)
resource "aws_sqs_queue_policy" "orinix_allow_sns" {
  queue_url = aws_sqs_queue.orinix_consumer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.orinix_consumer.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.habu_observability_events.arn
        }
      }
    }]
  })
}
```

**The subscription resource is the critical one.** It creates the entry in SNS's internal
subscriber list. Adding a new consumer = one new SQS queue + one new subscription + one queue policy.
Zero code change in forebitt, picanmix, or unhygienix.

---

## Filter Policies — Org Isolation at SNS Level

Each subscription can carry a filter policy. SNS evaluates message attributes against the
filter before deciding whether to push to that SQS queue.

```hcl
resource "aws_sns_topic_subscription" "xmi_sub" {
  topic_arn = aws_sns_topic.habu_observability_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.xmi_consumer.arn

  filter_policy = jsonencode({
    object_type = ["DATA_CONNECTION", "FLOW_RUN"]   # XMI only wants these two
    org_id      = ["xmi-org-uuid"]                  # only XMI's org events
  })
}

resource "aws_sns_topic_subscription" "team_mi_sub" {
  topic_arn = aws_sns_topic.habu_observability_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.team_mi_consumer.arn

  filter_policy = jsonencode({
    object_type = ["QUESTION"]
    org_id      = ["mi-org-uuid"]
  })
}
```

XMI's SQS queue only receives DataConnection and FlowRun events for XMI's org.
Team MI's queue only receives Question events for MI's org.
Isolation is enforced at SNS — no consumer ever sees another org's events.

**For this to work:** publishers (forebitt, unhygienix, etc.) must set message attributes
when calling `sns.publish()`:

```go
// Go example — forebitt publishing a DATA_CONNECTION event
snsClient.Publish(ctx, &sns.PublishInput{
    TopicArn: aws.String(observabilityTopicARN),
    Message:  aws.String(eventPayloadJSON),
    MessageAttributes: map[string]types.MessageAttributeValue{
        "object_type": { DataType: aws.String("String"), StringValue: aws.String("DATA_CONNECTION") },
        "org_id":      { DataType: aws.String("String"), StringValue: aws.String(orgID) },
    },
})
```

---

## Full Flow — forebitt to orinix

```
forebitt:  DC stage change mutation
             ↓
           sns.Publish(habu-observability-events, payload, attrs: {object_type, org_id})
             ↓  (returns immediately ~1ms)
           200 OK returned to caller — DC mutation complete

[async, ~10ms later]
SNS:       receives message
           checks subscriber list for habu-observability-events
           for each subscriber, checks filter policy against {object_type, org_id}
           matched subscribers:
             → sqs.SendMessage(sqs-habu-observability-consumer)  ← orinix's queue
             → sqs.SendMessage(sqs-xmi-consumer) if filter matches
           SNS done, message gone from SNS

SQS queues: store messages durably until consumed

[orinix polling loop — every ~1s]
           receiveMessage(sqs-habu-observability-consumer)
           message appears (visibility timer starts — other instances won't see it)
             → unwrap SNS envelope
             → parse inner Message JSON → ObjectEvent
             → INSERT INTO object_events (orinix DB)
             → query internal_consumer_registrations
             → publish to GCP Pub/Sub for matching consumers
           deleteMessage(sqs-habu-observability-consumer)  ← explicit ACK
           if processing fails before deleteMessage: message reappears after visibility timeout → retry
```

---

## The Newspaper Analogy

```
SNS topic     = newspaper editorial office (receives stories, routes copies)
forebitt      = journalist files a story (publish to topic)
subscription  = your subscription contract with the newspaper
filter policy = "deliver only sports and tech sections to my mailbox"
SQS queue     = your physical mailbox (stores what was delivered)
orinix        = you reading your mailbox each morning (polling SQS)
```

The `aws_sns_topic_subscription` TF resource IS the contract.
Without creating it, SNS doesn't know your mailbox exists.

---

## Why SNS + SQS Instead of Publishing Directly to SQS

If forebitt published directly to one SQS queue:
- Only one consumer (orinix) could read
- Adding team MI means forebitt must know about and publish to MI's queue too
- forebitt grows a dependency per consumer

With SNS in the middle:
- forebitt publishes to ONE topic, knows nothing about consumers
- Adding team MI = new SQS + new SNS subscription in Terraform
- Zero code change in forebitt
- N consumers, one publish call
