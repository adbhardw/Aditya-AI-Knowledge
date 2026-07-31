# Delivery Mechanism — Open Questions for Architect Meeting
**Date:** 2026-06-22
**Author:** Aditya Bhardwaj
**Context:** DV-15090 — M1 internal users. XMI confirmed they want GCP Pub/Sub delivery.
**Parent:** 2026-06-22_orinix_design_ask.md

---

## The Core Tension

XMI (the first confirmed M1 consumer) has two specific needs that pull in different directions:

1. **Flow chaining** — sub-second latency. When Flow 1 completes, trigger Flow 2. A 60-second
   cursor poll interval is not acceptable.

2. **Google Pub/Sub delivery** — XMI wants to receive events on their native GCP infrastructure,
   not by polling an HTTP endpoint or exposing an inbound HTTPS receiver.

The existing design (June 2 Confluence) recommended:
- V1: cursor-based pull API (Approach 1)
- V2: webhook push (Approach 2)
- Approach 3 (cloud-native queues): reserved for special contractual cases

XMI's ask changes the calculus for M1 (internal). The question is which path forward is correct.

---

## Option A — Webhooks to Cloud Run, XMI Fans Out to Pub/Sub Internally

```
orinix Delivery Worker
  → POST CloudEvents to https://events.xmi.liveramp.com/habu-webhook  (HTTPS, Habu pushes)
       │
       ▼
XMI Cloud Run endpoint (receives webhook)
  → validates HMAC
  → publishes to XMI's internal GCP Pub/Sub topic  ← XMI handles this internally
  → downstream XMI services subscribe from Pub/Sub
```

**What Habu builds:** Webhook delivery worker (cloud-agnostic, reused for all future consumers)
**What XMI builds:** One Cloud Run endpoint + internal Pub/Sub fan-out

**Pros:**
- Same delivery worker handles XMI (GCP), MSFT (Azure), all future consumers — no per-cloud code
- XMI owns their own Pub/Sub routing — they decide what to fan out where
- Habu does not store or manage GCP credentials
- Self-service: XMI registers their Cloud Run URL via API

**Cons:**
- XMI must expose an inbound HTTPS Cloud Run endpoint (non-trivial but standard on GCP)
- XMI said "we want Pub/Sub" — need to confirm if this option is acceptable to them

**Key question for XMI:** "Would you be willing to expose a Cloud Run HTTPS endpoint that receives
our webhook and fans out to your Pub/Sub internally? You'd own the Pub/Sub routing on your side."

---

## Option B — Bridge Lambda: SNS → GCP Pub/Sub (Approach 3 for M1 internal only)

```
orinix → SNS: habu-observability-events
                   │
                   ▼
       SQS: sqs-habu-bridge-xmi     (Habu-internal)
                   │
                   ▼
       Lambda: habu-to-gcp-pubsub   (Habu-owned)
           - google-cloud-pubsub SDK
           - GCP Service Account credentials in AWS Secrets Manager
                   │  HTTPS cross-cloud
                   ▼
       GCP Pub/Sub: habu-cleanroom-events  (XMI-owned, XMI grants Habu publisher SA)
                   │
                   ▼
       XMI subscribers read natively
```

**What Habu builds:** Lambda + GCP service account management (per M1 consumer who wants Pub/Sub)
**What XMI builds:** Pub/Sub topic + subscription + subscriber service

**Pros:**
- XMI gets native Pub/Sub exactly as they asked
- No inbound HTTPS endpoint required on XMI's side
- Low latency: SNS → SQS → Lambda → Pub/Sub in < 2 seconds typically

**Cons:**
- Habu must own GCP credentials (XMI's service account key) in AWS Secrets Manager
- When XMI rotates their GCP service account → Habu SRE must update Lambda env vars → Habu incident
- Does not generalize: MSFT (Azure) requires a completely different Lambda with Azure SDK
- Per-cloud bridge multiplies: N consumers × M clouds = N×M bridge variants
- Lambda failures are Habu incidents even though the event originated from XMI's mutation

**Viable for M1 (internal):** IAM coordination is internal to LiveRamp — key rotation can be
a coordinated operational task, not a production incident. Acceptable as an internal shortcut.

**Not viable for M2 (external):** External customers cannot give Habu their cloud credentials.
External delivery must use webhooks (Option A).

---

## Option C — Hybrid: Webhook for M2, Pub/Sub Bridge for M1 (Different per tier)

M1 (internal): Option B — Pub/Sub bridge (Habu-managed, per internal consumer)
M2 (external): Option A — Webhooks (consumer-owned HTTPS endpoint)

**Architecture impact:** orinix delivery worker handles both paths:
- Internal consumers: SQS → Lambda → cloud-native queue (per-cloud per-consumer)
- External consumers: SQS → delivery worker → HTTPS POST (universal)

**Pros:** Each tier gets what they actually want
**Cons:** Two delivery code paths in orinix to maintain

---

## Option D — gRPC Streaming (Internal Only)

orinix exposes `StreamCleanroomEvents` as a server-streaming gRPC method.
XMI calls it as an internal service (VPC mesh, no public HTTPS needed).

```
XMI service (AWS/GCP VPC)
  → gRPC stream: orinix.StreamCleanroomEvents(cleanroomId, objectType)
  ← server-side stream: ObjectEvent messages pushed in real-time as they arrive
```

**What XMI builds:** gRPC client that opens a streaming connection and fans events to their Pub/Sub
**What Habu builds:** StreamCleanroomEvents implementation in orinix (proto already defined)

**Pros:**
- Real-time (no polling). Sub-second latency.
- No cross-cloud bridge. No credential management.
- XMI internally fans events to Pub/Sub — they own their cloud routing
- Standard gRPC — works over VPC peering (GCP ↔ AWS PrivateLink)

**Cons:**
- Requires VPC connectivity: XMI's GCP VPC must have network path to orinix in Habu's AWS VPC
  (AWS PrivateLink or VPN tunnel — not trivial)
- Reconnection logic on XMI's side (gRPC streams disconnect on network blip)
- Not externally viable (M2) — external customers cannot open gRPC streams to internal services

**Viable only if:** VPC connectivity between XMI and Habu already exists (worth confirming)

---

## Questions to Bring to the Architect Meeting

### Q1 — Delivery decision for M1 internal
Which option do we recommend?
- A (webhook to Cloud Run, XMI fans to Pub/Sub)
- B (Habu builds SNS → Pub/Sub bridge)
- C (hybrid: B for M1, A for M2)
- D (gRPC streaming if VPC connectivity exists)

**Suggested framing:** Present A and B. Ask Architect to weigh "does XMI prefer zero inbound HTTPS vs
Habu managing their service account key?" Both are reasonable for an internal team.

### Q2 — If Option B: who owns GCP credentials lifecycle?
If Habu builds the Lambda bridge, we store XMI's GCP publisher service account key in
AWS Secrets Manager. Key rotation process needs to be defined:
- Does XMI notify Habu infra team when rotating?
- Is this automated via GCP Workload Identity Federation (no static key)?
- Who gets paged when the Lambda 403s?

**Note:** GCP Workload Identity Federation eliminates static key storage.
The Lambda can authenticate using short-lived tokens without storing a service account JSON key.
This is the right approach if Option B is chosen — worth raising with Architect.

### Q3 — Does M1 require both Approach 1 AND push delivery?
The Confluence recommendation was: V1 = pull API only, V2 = add push.
XMI's Flow chaining use case cannot wait for V2. Do we ship both Approach 1 (pull) and
Pub/Sub delivery in M1, or does pull API get deprioritized since XMI won't use it?

**Suggested position:** Ship Approach 1 (pull API) regardless — it powers the Activity Feed UI
and gives every other future consumer an option. Approach 3 / Pub/Sub bridge is additive on top.

### Q4 — orinix service ownership
orinix is a new service. Which squad owns it? The events cross team boundaries:
- QUESTION → unhygienix (squad A)
- DATA_CONNECTION / FLOW → forebitt (squad B)
- EXPORT_JOB / FLOW_RUN → picanmix/cronos (squad C)

**Suggested position:** orinix is owned by the team doing the DV-15090 work (Aditya + squad).
Publishing additions in each service are one-line PRs into unhygienix, forebitt, picanmix.
orinix is the absorber of all complexity — other squads contribute nothing beyond the 3-line publish.

### Q5 — Scope: which object types in M1?
XMI specifically asked for:
- DATA_CONNECTION stage changes ✓
- FLOW_RUN state changes ✓
- CR Dataset changes (maps to DATA_CONNECTION object events) ✓

Are QUESTION events and EXPORT_JOB events in M1 scope, or deferred?
**Suggested position:** Instrument all four publishers in M1 even if XMI only subscribes to two.
The instrumentation cost is the same (3-line publish per mutation path), and it prevents
future M2 consumers from needing a separate rollout for unpublished object types.

### Q6 — Cursor-based pull API: internal path vs external-api-server
The pull API (`GET /v1/cleanrooms/{id}/events`) is served by external-api-server which calls
orinix gRPC. For internal M1 consumers: should they call orinix gRPC directly (internal VPC),
or always go through external-api-server (which is the authenticated external path)?

**Suggested position:** Internal services call orinix gRPC directly. External consumers (M2)
use external-api-server with JWT auth. The two paths share the same gRPC implementation.

---

## Summary Table for Architect

| Option | Latency | XMI needs inbound HTTPS? | Habu needs GCP creds? | Generalizes to M2? | Complexity |
|--------|---------|--------------------------|------------------------|---------------------|------------|
| A — Webhook → Cloud Run | Sub-second | Yes (Cloud Run) | No | Yes (all clouds) | Low (one worker) |
| B — Lambda → Pub/Sub bridge | ~1-2s | No | Yes (SA key) | No (per-cloud bridges) | Medium per consumer |
| C — Hybrid A+B | Sub-second | Yes for external | Yes for internal | Partial | Medium |
| D — gRPC streaming | Real-time | No (VPC only) | No | No | High (VPC setup) |

**Recommendation to bring to Architect:**
Start with Approach 1 (pull API) as the foundation — this ships regardless.
For push delivery: propose Option A (webhook) as the standard.
Ask Architect + XMI team: "Can XMI host a Cloud Run endpoint? If yes, we avoid per-cloud bridge complexity forever."
If XMI hard blocks on no-inbound-HTTPS, then Option B (Pub/Sub bridge with GCP Workload Identity)
for M1 internal only, with a clear line that M2 external uses webhooks.
