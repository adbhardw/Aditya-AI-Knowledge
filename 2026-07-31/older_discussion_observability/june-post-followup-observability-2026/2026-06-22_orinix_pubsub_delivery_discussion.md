# orinix: Pub/Sub Delivery — Terminal Discussion
**Date:** 2026-06-22
**Author:** Aditya Bhardwaj
**Context:** How orinix delivers events to XMI (GCP Pub/Sub). Lambda bridge vs orinix-as-publisher.

---

## Key Insight: orinix IS the Bridge — No Separate Lambda Needed

The "Lambda bridge" in the original Confluence design was a **documentation placeholder**, not a real
separate service. The question was: which component crosses the cloud boundary (AWS → GCP)?

The answer: orinix itself. There is no architectural difference between:

```
SQS → Lambda (bridge) → GCP Pub/Sub
```

and

```
SQS → orinix → GCP Pub/Sub
```

orinix already consumes from SQS (to write `object_events`). Adding a second output — publishing
to XMI's GCP Pub/Sub topic — is a natural extension of the same consumer loop.

---

## Architecture: orinix with Two Outputs

```
unhygienix / forebitt / picanmix / cronos
  → SNS: habu-observability-events  (new topic, hevent pattern)
         ↓
  SQS: sqs-habu-observability-consumer
         ↓
     orinix (single service, two outputs after consuming from SQS)
       [1] INSERT INTO object_events  ← always, durable store for all consumers
       [2] query internal_consumer_registrations for matching event type + org
           → XMI registered (GCP_PUBSUB)?  publish to their topic
           → future MSFT internal (AZURE_SERVICE_BUS)?  publish to their topic
           → future internal AWS team (AWS_SQS)?  direct SQS send — trivial, same cloud
         ↓
  projects/xmi-project/topics/habu-cleanroom-events  ← XMI-owned topic
  XMI subscribes natively from their GCP side
```

orinix uses the `google-cloud-pubsub` Java/Go SDK to publish to XMI's topic.
Lambda was just what the original docs called "some compute that runs this SDK" — that compute IS orinix.

---

## Consumer Registration Table (orinix DB)

```sql
CREATE TABLE internal_consumer_registrations (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    consumer_name  VARCHAR   NOT NULL,   -- "XMI", "MI", "SafeHaven"
    delivery_type  VARCHAR   NOT NULL,   -- GCP_PUBSUB | AZURE_SERVICE_BUS | AWS_SQS
    destination    VARCHAR   NOT NULL,   -- "projects/xmi-proj/topics/habu-events"
    object_types   TEXT[],              -- ["DATA_CONNECTION", "FLOW_RUN"] — null = all
    org_filter     TEXT[],              -- null = all orgs
    active         BOOLEAN   NOT NULL DEFAULT true
);
```

After every `object_events` write, orinix queries matching registrations and delivers
to each registered cloud-native endpoint.

---

## Credential Question: How Does orinix Authenticate to GCP?

For orinix (running in AWS) to publish to XMI's GCP Pub/Sub topic it needs GCP identity.
**This is deferred for full discussion** but two options were identified:

### Option 1 — Static Service Account Key (not recommended)
- XMI creates a GCP service account, grants `roles/pubsub.publisher` on their topic
- Exports JSON key → gives to Habu → stored in AWS Secrets Manager
- orinix loads key at startup and uses it to publish
- Problem: XMI rotates key → Habu SRE must update secret → orinix redeploys → Habu incident

### Option 2 — GCP Workload Identity Federation (recommended)
- No static JSON key exists anywhere
- orinix runs on an AWS IAM role (e.g. `arn:aws:iam::123:role/orinix-delivery`)
- XMI creates a Workload Identity Pool on their GCP side that trusts AWS OIDC tokens from that role
- orinix exchanges its AWS STS token for a short-lived GCP access token (15-min TTL, auto-refreshed)
- XMI rotates nothing — there is no key to rotate
- orinix publishes using short-lived tokens

Cross-cloud credential pattern: AWS IAM role → GCP Workload Identity Federation.
Compare to current Habu pattern: cacofonix uses `ZABRA_PRIVATE_KEY` (PEM volume mount)
for intra-Habu JWT signing. For cross-cloud (AWS → GCP), Workload Identity is the equivalent
— no static key, identity-based auth.

**Open:** discuss how this fits the existing cacofonix / pegleg secrets pattern in the next session.

---

## M1 vs M2 Delivery Summary

| Consumer tier | Delivery mechanism | orinix action after object_events write |
|---------------|-------------------|------------------------------------------|
| M1 internal (XMI on GCP) | GCP Pub/Sub | publish to `projects/xmi/topics/habu-events` |
| M1 internal (AWS team) | Direct SQS send | `sqsClient.sendMessage(destinationQueueArn)` |
| M2 external | HTTPS webhook | POST CloudEvents to registered callback URL |
| Any consumer | Cursor pull API | reads from `object_events` via gRPC (self-serve) |

Same service (orinix), different delivery plugins per consumer type.
