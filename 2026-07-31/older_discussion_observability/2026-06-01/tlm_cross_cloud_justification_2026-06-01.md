# TLM Pitch — Why Cross-Cloud Native Queues Add Maintenance, HTTPS Webhooks Remove It
**Date:** 2026-06-01
**Context:** TLM asked: "find a way where consumers consume what we publish, no maintenance on Habu's end"
**Author:** Aditya Bhardwaj

---

## What "Consume What We Publish" Actually Requires Per Cloud

AWS SNS cannot natively deliver to GCP Pub/Sub or Azure Service Bus.
There is no cross-cloud pub/sub protocol.

```
XMI (GCP):
  SNS → SQS → Lambda (Habu-owned) → GCP Pub/Sub REST API → XMI reads
                         ↑
              Habu owns this Lambda.
              Habu stores GCP service account key in Lambda env vars.
              XMI rotates their key → Habu updates Lambda config (Habu incident).
              Lambda fails silently → Habu debugs it (Habu incident).

MSFT (Azure):
  SNS → SQS → Lambda (different Lambda, Azure SDK) → Azure Service Bus REST → MSFT reads
                         ↑
              Different SDK (@azure/service-bus, not the GCP one).
              Different auth model (Azure AD app registration + client secret).
              Different Habu engineer who knows Azure.
              MSFT rotates Azure client secret → Habu incident.

Future team MI (new cloud):
  Another bridge. Another Lambda. Another SDK. Another credential set.
  Every new consumer on a new cloud = new Habu engineering project.
```

---

## 6 Reasons Cross-Cloud Native Queues = More Habu Maintenance

### 1. No native bridge — Habu builds and owns it

AWS PrivateLink, EventBridge partner integrations, and cross-account SQS subscriptions
all stay within AWS. Crossing to GCP or Azure requires a Lambda relay that Habu writes,
deploys, monitors, and maintains.

### 2. Credential ownership flips to Habu

```
HTTPS webhook model:
  XMI rotates their bearer token
  → XMI calls PUT /callbacks/cb-456 (self-service API, updates their own config)
  → Zero Habu involvement. Zero incident.

Cloud-native model:
  XMI rotates GCP service account key
  → Habu SRE updates Lambda environment variable
  → Lambda redeploys
  → Habu incident ticket raised
  → Cross-team coordination required
```

With HTTPS: consumer owns credentials. With cloud-native: Habu owns credentials for every consumer.

### 3. Org isolation becomes a per-cloud engineering problem

With SNS message attributes + SQS filter policies, org isolation is 2 lines of JSON config:
```json
{ "org_id": ["org-xyz"] }
```

With cloud-native queues: implement org filtering inside each Lambda relay,
OR create one Pub/Sub topic per org per consumer.
For N orgs × M consumers = N×M topics to manage, monitor, and bill for.

### 4. One generic delivery worker vs N per-cloud Lambdas

```
HTTPS webhook (Approach 2):
  One delivery worker handles ALL consumers regardless of cloud.
  XMI on GCP      → same worker, same code, HTTPS POST
  MSFT on Azure   → same worker, same code, HTTPS POST
  MI team on AWS  → same worker, same code, HTTPS POST
  New consumer    → zero code change, self-service registration

Cloud-native queues:
  XMI on GCP      → Lambda A (GCP Pub/Sub SDK)
  MSFT on Azure   → Lambda B (Azure Service Bus SDK)
  MI team on AWS  → Lambda C or cross-account SQS (this one is clean)
  New cloud       → new Lambda, new SDK, new credential set, new Habu project
```

### 5. The existing SNS pattern already proves the model

`PublishEventAsyncWithRetry` in `unhygienix/services/events/service.go` is the exact
pattern we reuse — goroutine, exponential backoff (1s → 2s → 4s...), 30-second timeout,
survives context cancellation. Publishing observability events adds a new SNS topic
to infrastructure that already runs in picanmix. No new AWS services needed.

### 6. CloudEvents makes HTTPS the actual zero-maintenance cross-cloud standard

The CNCF CloudEvents spec was created precisely because cloud-native queues are not
interoperable. GCP Eventarc, Azure Event Grid, and AWS EventBridge all natively
consume CloudEvents v1.0 over HTTPS. Our webhook payload arrives at XMI's Cloud Run
endpoint as standard CloudEvents JSON. XMI internally fans it to GCP Pub/Sub,
BigQuery, or whatever they need. That routing is XMI's concern, not Habu's.

---

## What "Zero Maintenance on Habu's End" Actually Looks Like

The TLM's goal is achievable — but the mechanism is HTTPS webhooks, not cloud-native queues.

```
Habu publishes to SNS (internal, already in picanmix)
    ↓
SQS per consumer (Habu-internal, isolation layer)
    ↓
Delivery Worker (one, generic, cloud-agnostic — reuses hank/aws/sns pattern)
    ↓  HTTPS POST + CloudEvents v1.0
Consumer endpoint (their cloud, their infra, their on-call)

Maintenance responsibility per action:
──────────────────────────────────────────────────────────────────
Action                          | Cloud-native queues | HTTPS webhook
Adding new consumer             | New Lambda + SDK    | Self-service POST /callbacks
Consumer URL changes            | N/A (queue-based)   | Consumer calls PUT /callbacks
Consumer token rotates          | Habu updates Lambda | Consumer calls PUT /callbacks
Consumer endpoint down          | Habu debugs bridge  | Consumer's DLQ, consumer on-call
Adding new object type          | No change needed    | No change needed
New consumer on new cloud       | New Lambda, new SDK | Zero change — same HTTPS worker
Consumer credential rotation    | Habu incident       | Consumer-side, zero Habu
──────────────────────────────────────────────────────────────────
```

---

## 5-Line TLM Pitch

1. **SNS/SQS already runs in picanmix** — observability events reuse `PublishEventAsyncWithRetry`
   from `hank/events` which is already tested and deployed. No new AWS services, no new risk.

2. **Cross-cloud native queues require Habu to build a Lambda relay per consumer cloud** —
   AWS SNS cannot natively deliver to GCP Pub/Sub or Azure Service Bus. Every bridge is
   Habu-owned code, Habu-owned credentials, and a Habu incident when the consumer rotates
   their cloud IAM key.

3. **One generic HTTPS delivery worker handles all consumers on all clouds** — XMI on GCP
   and MSFT on Azure both receive identical CloudEvents v1.0 over HTTPS. Adding team MI
   costs one `aws sns subscribe` command. Zero code change in unhygienix, forebitt, or picanmix.

4. **"They consume what we publish, zero Habu maintenance" IS the webhook model** —
   HTTPS is the only universal cross-cloud protocol. GCP Eventarc, Azure Event Grid,
   and AWS EventBridge all natively consume CloudEvents over HTTPS. Consumers self-register
   via API; Habu is never in the loop for their credential or URL changes.

5. **Consumer isolation resolves the TL's choke-point concern by design** —
   per-consumer SQS queue means XMI's endpoint failure pages XMI's on-call, not Habu's.
   Habu is the canonical event source, not the operational owner of each consumer's delivery.

---

## Addressing the TLM Directly

TLM said: "Find a way where they consume what we publish, no maintenance on our end."

The cross-cloud native queue approach (GCP Pub/Sub, Azure Service Bus) sounds like
"they consume our queue" but it actually inverts the maintenance model:
- Habu builds and maintains N bridges (one per consumer cloud)
- Habu holds credentials for every consumer's cloud
- Every consumer credential rotation = Habu incident

The HTTPS webhook approach actually delivers TLM's goal:
- Consumers register their own endpoint via self-service API (no Habu engineer)
- Consumers rotate their own credentials (no Habu engineer)
- Consumer endpoints go down — consumer's problem (no Habu engineer)
- New consumer on any cloud — same HTTPS worker, self-service registration (no Habu engineer)

The only Habu-owned component is the generic delivery worker.
That worker does not change when a new consumer joins, when a consumer changes clouds,
or when a consumer's credentials rotate.
That is the zero-maintenance model the TLM is asking for.
