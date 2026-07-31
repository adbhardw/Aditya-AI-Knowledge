# DV-13856 — Cleanroom Observability: Event Notification Design


## Problem

Cleanroom consumers — starting with XMI, expanding to future partners — have no way to know when objects inside a cleanroom change. When a data connection moves from `MAPPING_REQUIRED` to `CONFIGURATION_COMPLETE`, when a question's SQL is modified, or when an export job destination changes, XMI currently finds out through manual communication or by polling individual resource endpoints with no standardized mechanism. This causes delayed reactions, broken downstream workflows, and support overhead on the Habu side.

We need a first-class event notification layer that captures every cleanroom object mutation and exposes it to consumers in a structured, reliable, cloud-agnostic way.

---

## What We Are Building

A cleanroom observability layer with three components:

**1. Event capture** — Every mutation to a `QUESTION`, `DATA_CONNECTION`, or `EXPORT_JOB` within a cleanroom is captured as an immutable event row in a single append-only table (`object_events`). The event records a structured diff: `{ "field": { "from": <old>, "to": <new> } }`. Where this table lives and who writes to it is the open architectural decision described in the Internal Architecture section below.

**2. Internal event bus** — unhygienix, forebitt, and picanmix each publish post-commit to a shared AWS SNS topic (`habu-object-events`). An SQS consumer reads the topic and writes to `object_events`. No service calls another service directly — SNS is the only integration boundary, eliminating circular dependencies.

**3. Delivery layer** — A single gRPC endpoint (`GetCleanroomEvents`) is exposed externally via external-api-server as a REST API. This is the read interface for all consumers regardless of delivery model (pull, push, or cloud-native queue). The schema does not change between delivery models.

---

## Why CNCF CloudEvents as the Schema

Every event — regardless of how it is delivered — is wrapped in the CNCF CloudEvents v1.0 envelope:

```json
{
  "specversion": "1.0",
  "id":          "<event-uuid>",
  "source":      "urn:habu:cleanroom:<cleanroom-id>",
  "type":        "com.habu.cleanroom.<object-type>.<action>",
  "time":        "<RFC3339 UTC timestamp>",
  "data": {
    "objectType":    "<QUESTION | DATA_CONNECTION | EXPORT_JOB>",
    "objectId":      "<uuid>",
    "objectName":    "<name at time of event>",
    "changeType":    "<CREATED | UPDATED | DELETED>",
    "changedFields": {
      "<field>": { "from": "<old-value>", "to": "<new-value>" }
    },
    "performedBy":   "<user-email or system:service-name>",
    "schemaVersion": 1
  }
}
```

**Three reasons this is the right choice:**

**1. Vendor neutrality — the schema works on every cloud without changes.**
GCP Eventarc, Azure Event Grid, and AWS EventBridge have all adopted CloudEvents v1.0 natively. The outer envelope fields (`specversion`, `type`, `source`) are what these platforms use for routing and filtering. The `data` block — which is Habu's schema — is never touched by the cloud platform. XMI on GCP, MSFT on Azure, and any future partner on any cloud receive identical JSON. Habu writes no cloud-specific transformation code.

**2. The schema is decoupled from the delivery model.**
The three delivery approaches discussed below (pull, push, cloud-native queue) all produce this same payload. Choosing or changing a delivery approach does not require changing the schema, the `object_events` table, or the gRPC endpoint. This means we can ship Approach 1 today and layer Approach 2 on top later without rework.

**3. Industry standard — consumers already know how to parse it.**
CloudEvents is the same pattern GitHub Webhooks, Stripe Events, Salesforce Platform Events, and AWS EventBridge natively use. Engineering teams on the consumer side do not need to learn a Habu-specific envelope. The `type` field (`com.habu.cleanroom.data_connection.updated`) follows the same reverse-DNS convention as GitHub (`com.github.push`) and is immediately parseable.

**The uniform `changedFields` shape — one parser for all object types:**

```json
// DATA_CONNECTION — stage moved
"changedFields": { "stage": { "from": "MAPPING_REQUIRED", "to": "CONFIGURATION_COMPLETE" } }

// QUESTION — SQL changed
"changedFields": { "sqlQuery": { "from": "SELECT ... WHERE amount > 100",
                                  "to":   "SELECT ... WHERE amount > 50" } }

// EXPORT_JOB — destination changed
"changedFields": { "destination": { "from": "s3://a/a.bcs", "to": "s3://b/b.abc" } }
```

Every field across every object type follows `{ "from": X, "to": Y }`. Consumer code iterates one loop with zero branching on object type.

---

## Internal Architecture — How Events Are Captured

The publishing side is identical in both options. The open decision is **who consumes the SNS topic and who owns the `object_events` table**.

```
unhygienix (QUESTION / DATA_CONNECTION)
forebitt   (DATA_CONNECTION)              ──► AWS SNS: habu-object-events
picanmix / cronos (EXPORT_JOB)
```

All three services publish post-commit to the same SNS topic. Neither forebitt nor picanmix calls unhygienix directly. This is fixed regardless of which option below is chosen.

---

### Option A — Pegleg as SQS Consumer → unhygienix owns the table

```
AWS SNS: habu-object-events
         │
         ▼
SQS: sqs-habu-object-events-internal
         │
         ▼
Pegleg (SQS consumer)
  [1] read event from SQS
  [2] gRPC: unhygienix.RecordEvent(event)
         │
         ▼
unhygienix.RecordEvent() — new gRPC method
  [3] INSERT INTO object_events (unhygienix DB)
         │
         ▼
unhygienix.GetCleanroomEvents() — new gRPC method
         │
         ▼
external-api-server → REST API
```

**Two new gRPC methods added to unhygienix:**
```protobuf
service UnhygienixService {
    // existing methods unchanged...

    rpc RecordEvent(RecordEventRequest) returns (RecordEventResponse);
    rpc GetCleanroomEvents(GetCleanroomEventsRequest) returns (GetCleanroomEventsResponse);
}

message RecordEventRequest {
    string object_id    = 1;
    string object_type  = 2;  // QUESTION | DATA_CONNECTION | EXPORT_JOB
    string event_type   = 3;  // com.habu.cleanroom.<type>.<action>
    string changed_by   = 4;
    string org_id       = 5;
    string cleanroom_id = 6;
    bytes  before_state = 7;  // JSON snapshot
    bytes  after_state  = 8;  // JSON snapshot
}

message GetCleanroomEventsRequest {
    string cleanroom_id = 1;
    string org_id       = 2;  // injected from JWT by external-api-server
    int64  since_cursor = 3;
    string object_type  = 4;
    int32  limit        = 5;
}
```

**Why this works:**
Pegleg already has `@GrpcClient("unhygienix")` — the coupling already exists. unhygienix is a reasonable owner of `object_events` because the activity feed is a cleanroom-level concept: a customer views their cleanroom and sees everything that changed inside it, including data connections from forebitt and exports from picanmix. external-api-server calls the same `GetCleanroomEvents` endpoint it already calls unhygienix for everything else.

**Trade-offs:**
- `object_events` lives inside unhygienix's already large schema — every future schema change to the event store is a migration inside the biggest service in the platform.
- Pegleg's domain is query validation and execution. Making it an SQS event consumer is scope creep outside that domain. When the observability schema evolves, the change touches Pegleg.
- unhygienix grows two new gRPC methods that have nothing to do with cleanroom CRUD — observability is a distinct concern being absorbed into the control plane.
- Lower setup cost. No new service to deploy, no new infrastructure, no new port.

---

### Option B — orinix: New Lightweight Observability Service

```
AWS SNS: habu-object-events
         │
         ▼
SQS: sqs-habu-object-events-internal
         │
         ▼
orinix (SQS consumer + gRPC server)
  [1] read event from SQS
  [2] INSERT INTO object_events (orinix DB — separate PostgreSQL schema)
  [3] serve GetCleanroomEvents via gRPC
         │
         ▼
external-api-server
  @GrpcClient("orinix") — one new client entry
         │
         ▼
REST API
```

**orinix owns everything observability-related:**
```
orinix/
├── proto/
│   └── events.proto          GetCleanroomEvents, RecordEvent
├── db/
│   └── object_events         owns the table, owns the migrations
├── consumer/
│   └── SqsEventConsumer      reads SNS → SQS, writes to object_events
└── server/
    └── EventServiceImpl      serves GetCleanroomEvents gRPC
```

**Why this is the right shape:**
Gangway is the existing precedent in the Habu codebase. It was built for exactly one concern (consumer rights / RTBF), has its own PostgreSQL database, its own gRPC service (`ConsumerRightsService`), and its own port (6069). Nobody questions whether gangway should have been part of moonraker. Observability is the same shape of problem — a cross-cutting concern that touches multiple services but belongs to none of them.

Three publishers (unhygienix, forebitt, picanmix) each add three lines:
```java
// The only change required in each publishing service:
snsClient.publish(PublishRequest.builder()
    .topicArn(HABU_OBJECT_EVENTS_TOPIC)
    .message(objectEvent.toJson())
    .build());
```

That is the full cost to the existing services. orinix handles everything else.

**Trade-offs:**
- Higher setup cost: new service, new deployment, new DB schema, new port, new `@GrpcClient` entry in external-api-server.
- Clean domain boundary: observability logic never enters unhygienix, forebitt, or picanmix beyond the three-line SNS publish.
- `object_events` schema evolves independently. Adding a new event field, a new object type, or a new index requires a migration in orinix — no other service is touched.
- As the feature expands (delivery_log, callback_registrations, webhook worker), all of that lives in orinix. unhygienix stays focused on cleanroom CRUD.
- external-api-server adds one `@GrpcClient("orinix")` — the same pattern it already uses for unhygienix, pegleg, and others.

---

### Side-by-Side Comparison

| Dimension | Option A — Pegleg → unhygienix | Option B — orinix (new service) |
|---|---|---|
| Who consumes SNS | Pegleg | orinix |
| Who owns `object_events` | unhygienix | orinix (own DB) |
| Who serves `GetCleanroomEvents` | unhygienix | orinix |
| New services | 0 | 1 |
| New gRPC methods in unhygienix | 2 (`RecordEvent`, `GetCleanroomEvents`) | 0 |
| Domain purity | Pegleg does event routing (off-domain) | orinix owns observability end-to-end |
| Schema evolution | Migration inside unhygienix | Migration inside orinix only |
| Future growth (webhooks, delivery_log) | Grows unhygienix further | Grows orinix only |
| Existing precedent | Pegleg already calls unhygienix | Gangway pattern |
| Setup cost | Lower | Higher |

**Recommendation:** Option B (orinix) is the right long-term choice. The observability surface will expand — callback registrations, delivery logs, webhook workers, and retry infrastructure all belong to this domain. Building that inside unhygienix trades short-term convenience for long-term coupling. Option A is viable for a time-boxed MVP if the team decides to defer the service extraction, but the extraction cost grows with every sprint spent inside Option A.

---

**Shared design decisions (apply to both options):**

- **forebitt never calls unhygienix or orinix directly.** SNS is the only integration boundary.
- **`object_events` is append-only.** `REVOKE UPDATE, DELETE FROM <app_role>` enforced at DB permission level.
- **Org isolation is automatic.** external-api-server injects the JWT `org_id` claim into every gRPC request. The event store filters `WHERE org_id = claim`. XMI sees only XMI events.
- **Activity Feed UI calls the same `GetCleanroomEvents` endpoint** as external-api-server. One endpoint, two consumers, zero duplication.

---

## Three Delivery Approaches

The approaches below are not mutually exclusive. The event capture layer and schema are identical in all three. The difference is only in how LR gets the event to the consumer.

---

### Approach 1 — Pull: Cursor-Based Polling API

**How it works:**
XMI calls `GET /v1/cleanrooms/{id}/events?since=<cursor>` on a schedule. Each response returns a batch of CloudEvents and a `nextCursor` to use on the following call. The cursor is a monotonically increasing opaque token backed by the `cursor_position` PostgreSQL sequence — no events are ever missed on reconnect.

```
XMI polls every 60s:
GET /v1/cleanrooms/cr-abc/events
    ?since=eyJsYXN0X2N1cnNvciI6NDgyMX0=
    &objectType=DATA_CONNECTION
Authorization: Bearer <JWT>

Response (CloudEvents v1.0 batch):
{
  "events": [ { ...CloudEvent... } ],
  "nextCursor": "eyJsYXN0X2N1cnNvciI6NDgyMn0=",
  "hasMore": false
}
```

**What XMI must do:** Write a scheduled job (Cloud Scheduler + Cloud Run) that calls the REST endpoint, processes the batch, and persists the cursor. No inbound HTTPS endpoint. No firewall rule. No server to expose.

**What Habu must build:** The `object_events` table, the gRPC endpoint, and the REST endpoint in external-api-server. The Activity Feed UI in topgallant ships as a direct benefit of the same work.

**Operational details:**
- ETag + `304 Not Modified` — if nothing changed since the last cursor, no event body is transferred. Zero bandwidth on idle poll cycles.
- Rate limit: X (we can decide) requests per minute per org (token-bucket). Response headers: `X-RateLimit-Remaining`, `X-RateLimit-Reset`.
- Org isolation via JWT `org_id` claim — automatic, no per-customer config.

**Trade-off:** Change latency equals the poll interval (30–60 seconds). Acceptable for audit and activity-feed use cases. Not suitable for workflows that need sub-second reaction.

**Industry precedent:** GitHub Events API, Stripe Events, AWS CloudTrail, Salesforce Change Data Capture (pull mode).

---

### Approach 2 — Push: Webhook Callback Registration

**How it works:**
XMI registers a callback endpoint once via API. Habu calls that endpoint over HTTPS within seconds of every matching mutation. Each delivery is signed with HMAC-SHA256 so XMI can verify the request is genuinely from Habu.

**Registration (one-time):**
```
POST /v1/cleanrooms/{crId}/callbacks

{
  "objectType":      "DATA_CONNECTION",
  "objectId":        null,
  "callbackUrl":     "https://events.xmi.liveramp.com/habu-webhook",
  "monitoredFields": ["stage", "destination", "sqlQuery"],
  "authConfig":      { "authType": "BEARER", "authValue": "eyJhbGci..." }
}

201 Created → { "id": "cb-456", "signingSecret": "whsec_a3f9c2d1..." }
```

`signingSecret` is shown once in the 201 response. XMI stores it in GCP Secret Manager. Habu stores it encrypted at rest via AWS KMS. It is used to sign every subsequent delivery.

**Delivery (every mutation):**
```
POST https://events.xmi.liveramp.com/habu-webhook
Authorization:    Bearer eyJhbGci...
X-Habu-Signature: t=1715521200,v1=a3f9c2d1...
X-Habu-Event-Id:  evt-a1b2c3d4-uuid
Content-Type:     application/cloudevents+json

{ ...CloudEvents v1.0 payload... }
```

**What XMI must do:** Expose one HTTPS endpoint (Cloud Run on GCP — no VPN, no firewall configuration beyond standard HTTPS). Verify the HMAC-SHA256 signature on every inbound request. Deduplicate using `X-Habu-Event-Id` against a Redis TTL key (SQS delivers at-least-once).

**What Habu must build:** `callback_registrations` table, a Callback Delivery Worker (ECS Fargate), and a `delivery_log` table for audit. The delivery worker is cloud-agnostic — the same service handles XMI (GCP), MSFT (Azure), and any future consumer. Adding a new consumer means adding one SQS subscription. Zero code change in unhygienix or forebitt.

**Operational details:**
- Consumer isolation: dedicated SQS queue per consumer (`sqs-habu-delivery-xmi`). XMI queue failure or backpressure has zero effect on MI or SafeHaven queues.
- `monitoredFields` filter: Habu only delivers if `changedFields ∩ monitoredFields` is non-empty. XMI is not notified for fields they did not register interest in.
- Retry: 5 attempts with exponential backoff and jitter. On exhaustion: Dead Letter Queue → CloudWatch alarm → Slack `#platform-alerts`.
- `delivery_log` records every attempt: HTTP status, latency, outcome. Queryable SLA evidence.
- W3C `traceparent` header in every payload: XMI can correlate their processing span to Habu's originating trace in their observability tooling.

**Trade-off:** XMI must expose an HTTPS endpoint. On GCP, Cloud Run handles this trivially — no inbound port, no VPN, standard HTTPS termination. This is the standard model used by Stripe Webhooks, GitHub Webhooks, Twilio, and every major SaaS API.

**Industry precedent:** Stripe Webhooks, GitHub Webhooks, Twilio, Salesforce Platform Events (push mode), Shopify Webhooks.

---

### Approach 3 — Cloud-Native Queue: Direct Pub/Sub / Service Bus Delivery

**How it works:**
Instead of LR calling XMI's HTTPS endpoint, LR publishes the CloudEvents payload directly to a cloud-native queue that XMI owns: GCP Pub/Sub for XMI, Azure Service Bus for MSFT, cross-account SQS for AWS-based partners.

**What this requires for XMI on GCP specifically:**

Since AWS SNS cannot natively publish to GCP Pub/Sub, LR must build a bridge:

```
AWS SNS (habu-object-events)
         ↓
AWS SQS (sqs-habu-bridge-xmi)
         ↓
AWS Lambda / ECS (google-cloud-pubsub SDK)   ← Habu builds and maintains this
         ↓ HTTPS cross-cloud
GCP Pub/Sub topic (habu-cleanroom-events-xmi)
         ↓
XMI reads natively from Pub/Sub
```

Habu must provision per customer:
- A dedicated SQS queue and bridge service per consumer cloud
- A GCP project with a Pub/Sub topic and IAM grant for XMI's subscriber service account
- GCP service account credentials in AWS Secrets Manager (or Vault
- Key rotation handling: if XMI's GCP service account is rotated without notifying LR, the bridge Lambda silently starts returning 403 — LR detects this only when the DLQ fills

For MSFT (Azure), an entirely different bridge is required: Azure Service Bus SDK, Azure AD application registration, Azure RBAC configuration. Every new cloud provider is a new SDK, a new auth model, and a new bridge service.

**Org isolation:** Either a separate Pub/Sub topic per consumer (N topics for N consumers, each requiring dedicated IAM) or per-message attribute filtering (XMI must configure a subscription filter — misconfiguration means XMI sees other orgs' events, which Habu cannot detect or prevent).

**Where Approach 3 is the right call:**
- Internal Habu services within the same AWS account (direct SQS subscription — simple, no bridge needed)
- An enterprise consumer that contractually prohibits exposing any inbound HTTPS endpoint (treat as a bespoke premium tier with dedicated engineering cost)
- A consumer already on AWS who owns an SQS queue (cross-account SQS subscription — straightforward)

This approach has highest operational cost.
**Trade-off:** The schema stays the same. The operational cost multiplies per consumer cloud. Each new cloud is a new engineering surface that LR owns end-to-end. CNCF CloudEvents was adopted by GCP, Azure, and AWS EventBridge specifically so that producers do not need per-cloud SDKs — Approach 3 re-introduces the problem CloudEvents was designed to eliminate.

---

## Recommendation and Path Forward

**Approach 1 (Pull API) is the V1 baseline.** It requires the least infrastructure, ships the Activity Feed UI as a by-product, and gives XMI a working integration with zero infrastructure on their side. This establishes the `object_events` table, the gRPC endpoint, and the external REST API — the foundation that all three approaches share.

**Approach 2 (Webhook Push) is the V2 layer.** It builds on the same foundation and adds sub-second latency for consumers that need it. The delivery worker is cloud-agnostic and serves every future consumer without code changes.

**Approach 3 (Cloud-native queue) is reserved for specific contractual cases.** It is not the default delivery model. SNS and SQS remain internal to Habu. External partners always receive via HTTPS.

The schema — CNCF CloudEvents v1.0 with the uniform `{ from, to }` changedFields — is fixed from day one and does not change between V1 and V2. Any consumer who integrates with V1 Pull requires no schema changes to adopt V2 Push.

---

