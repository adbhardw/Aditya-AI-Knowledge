# DV-13856 — Q&A: Event Delivery Approaches, Cloud Portability, API vs SNS
**Date:** 2026-05-18
**Context:** Pre-call prep for John + XMI alignment on Clean Room Observability event delivery model

---

## Q0: Should I go to XMI with the SNS/SQS concept or the API?

**Answer: Bring only the API to XMI. SNS/SQS is Habu's internal plumbing — XMI never sees it.**

From XMI's perspective there are only two options:
- **Pull:** XMI calls `GET /events?since=T` on a timer (cursor API)
- **Push:** Habu calls XMI's URL when something changes (webhook/callback)

SNS/SQS is only relevant if we choose push — it is how Habu delivers the HTTP POST to XMI internally. XMI does not care what Habu uses behind the scenes. Go to XMI with: *"here are your two integration options, which fits your team?"*

---

## Q1: What does "share V1 API response shape with XMI" mean?

Go with a concrete proposal — show XMI the exact JSON they would receive and ask: *does this structure work for your system?*

Specifically validate:
- Is `changedFields: { "dimensions": { "removed": [...], "current": [...] } }` the right format, or does XMI need something different?
- Which event types do they actually care about — column removals? Deletes? Status changes? All?

This is a **contract review**, not a discovery call. You go with a draft, they react to it.

---

## Q2: Is SNS cloud-dependent? API vs SNS for multi-cloud partners

| Scenario | Cloud dependency |
|----------|-----------------|
| XMI calls `GET /events?since=T` (cursor API) | Zero — plain HTTPS, works from any cloud |
| Habu POSTs to XMI's webhook URL (push) | Zero for XMI — they expose an HTTPS endpoint, works on GCP |
| Habu uses SNS→SQS internally | AWS-only on Habu's side — invisible to consumers |

**The cloud problem only bites if you give consumers direct SQS access** (i.e., "poll our SQS queue"). Don't do that. The consumer always gets either an HTTPS API or an inbound HTTP POST — both cloud-agnostic.

For Josh's framework: SNS is fine as Habu's internal backbone since Habu is on AWS. The consumer gets HTTP regardless of whether they are on Azure, GCP, or AWS.

---

## Q3: Org_id enforcement — is it done at SQS level?

Yes. Since Habu owns the SQS queues, we add an SNS filter policy at subscription time:

```
MSFT's SQS subscription filter:
  { "org_id": ["msft-org-uuid"] }
```

SNS evaluates this before routing — MSFT's queue only receives events from their org. They cannot see other orgs' events. This is a Habu infra configuration, not application code, set at the time we provision the consumer's queue.

For the cursor API: same enforcement in the SQL query — `WHERE org_id = :requesting_org_id AND cleanroom_id = :crId`.

This is a **V2 concern, not V3** — org filtering must be in the design before any external consumer goes live.

---

## Q4: How does the cursor API work?

```
XMI stores locally:  last_read_timestamp = "2026-05-18T10:00:00Z"

Every 30 seconds:
  GET /cleanrooms/{id}/events?since=2026-05-18T10:00:00Z

  Response: [evt-901, evt-902, evt-903]

  XMI processes events → updates UI / refreshes cache
  XMI saves cursor:    last_read_timestamp = "2026-05-18T10:31:45Z"

Next call uses the new cursor. No duplicates. No missed events.
```

Key properties:
- XMI controls their own polling rate
- If XMI goes down for an hour, they catch up on next call — no events lost (events live in DB)
- No webhook server required on XMI's side
- Latency = polling interval (~30–60s), acceptable for "question/DC changed" notifications
- Powers both the Activity Feed UI and the external integration from the same table

---

## Q5 (NEW — 2026-05-18): Doesn't it make sense to emit events to all cloud providers? What challenges arise?

### What "emitting to all clouds" would mean
Instead of SNS→SQS (AWS-only internal delivery), we would maintain separate publisher integrations per cloud:
- AWS consumers → SNS/SQS
- GCP consumers (XMI) → Google Cloud Pub/Sub
- Azure consumers (MSFT) → Azure Event Grid or Service Bus

### Challenges

| Challenge | Detail |
|-----------|--------|
| **Operational complexity** | Each cloud has different retry semantics, DLQ patterns, and IAM models. Three clouds = three separate infra stacks to provision, monitor, and on-call for. |
| **Credential management** | We would hold and rotate secrets for each external cloud account. Security surface expands significantly. |
| **Schema/format differences** | SNS, Pub/Sub, and Event Grid have slightly different message envelope formats. We'd need adapters or consumers would see inconsistent event shapes. |
| **Ordering and delivery guarantees differ** | SQS standard = at-least-once unordered; Pub/Sub = at-least-once ordered per key; Event Grid = at-least-once with no ordering guarantee. Hard to reason about across all three. |
| **Cross-cloud egress cost** | Data leaving AWS to GCP or Azure incurs egress charges. At scale this adds up. |
| **Blast radius** | A config mistake on the GCP Pub/Sub side can affect MSFT and XMI consumers simultaneously if they share any infra layer. |

### Why the HTTPS approach avoids all of this
Whether we use cursor API (pull) or webhook/callback (push), the consumer just talks HTTPS. The event is delivered as a standard JSON payload over HTTP — no cloud SDK, no IAM cross-account trust, no Pub/Sub or Event Grid subscription to manage. Habu's internal SNS/SQS stays entirely within our AWS account. The consumer is cloud-agnostic.

**Recommendation:** Do not emit directly to cloud-native queues for external partners. Keep Habu's event backbone AWS-internal (SNS→SQS). External consumers always receive via HTTPS — either they pull (cursor API) or we push (webhook HTTP POST). This is how Stripe, GitHub, and every major platform handles this.

---

## Q6 (NEW — 2026-05-18): Why should consumers NOT consume directly from SQS?

| Reason | Detail |
|--------|--------|
| **Security risk** | Giving XMI or MSFT direct SQS access means issuing them AWS IAM credentials or setting up cross-account IAM roles. This is a compliance and security exposure. |
| **Cloud lock-in for consumers** | XMI is on GCP. They would need the AWS SDK and AWS credentials just to read a queue. We are forcing our infrastructure choice onto them. |
| **No org isolation** | Without careful queue-per-consumer setup, a consumer could potentially see events from other orgs. Queue-level isolation requires us to fully manage which queue each consumer reads from — which we already do internally via SNS filter policies. |
| **Tight coupling to our infra** | If we rename a queue, change ARNs, or move to a different queue system (Kafka, EventBridge), every consumer breaks. HTTPS endpoints are stable contracts; SQS ARNs are implementation details. |
| **Dual auth systems** | Our external API uses Bearer tokens / API keys. SQS uses AWS IAM. Running two auth models for the same feature creates confusion and operational overhead. |
| **Not how production platforms work** | Stripe, Shopify, Twilio, GitHub — none of them give consumers direct queue access. They all use HTTPS webhooks or polling APIs. There is a reason for this. |

**Rule:** SQS/SNS is Habu's internal delivery mechanism. The external contract is always HTTPS — either a REST API the consumer calls, or an HTTP POST Habu delivers to the consumer's URL.

---

## Three approaches summary (for John / XMI call)

| Approach | How | Cloud dependency | Setup burden on consumer |
|----------|-----|-----------------|--------------------------|
| **1. Cursor API (pull)** | Consumer calls `GET /events?since=T` | None — plain HTTPS | Low — just call an API |
| **2. Cloud-agnostic webhook (push)** | Consumer registers an HTTPS URL; Habu POSTs to it | None — consumer just needs an HTTPS endpoint | Medium — must run a server that accepts inbound POSTs |
| **3. Cloud-native streaming (direct queue)** | Consumer subscribes to SNS/SQS, Pub/Sub, or Event Grid directly | High — consumer must use the same cloud or hold cross-cloud credentials | High — AWS SDK, IAM, per-cloud setup |

**Approach 3 is ruled out** for external partners. Decision is between Approach 1 (cursor API) and Approach 2 (webhook). XMI conversation determines which.