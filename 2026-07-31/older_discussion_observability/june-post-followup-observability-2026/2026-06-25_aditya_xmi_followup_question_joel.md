# XMI Delivery — Follow-up Questions for Joel (PM)
**Date:** 2026-06-25
**Author:** Aditya Bhardwaj
**Context:** DV-15090 — M1 internal delivery to XMI. Resolving callback URL vs. subscription-based delivery before Architect meeting.
**Parent:** 2026-06-22_orinix_design_ask.md, 2026-06-22_delivery_open_questions.md

---

## Q1 — The Core Question: Callback URL vs. Subscription (Most Important)

XMI said they want GCP Pub/Sub delivery. Does that mean they hard-block on exposing an inbound
HTTPS endpoint, or is that just their preference?

If we built webhook-based delivery where Habu POSTs to a Cloud Run URL that XMI owns, and XMI
fans out to their Pub/Sub internally — would XMI accept that? Or do they specifically want Habu
to publish directly to their Pub/Sub topic?

**Why this matters:** It is the difference between Habu managing GCP credentials forever (Option B)
vs. XMI owning one Cloud Run endpoint (Option A). Option A generalizes to all future consumers
(M2 external, other clouds). Option B is a per-consumer, per-cloud maintenance commitment for Habu.

---

## Q2 — What Does XMI Need to Build Either Way?

Both options require XMI to build something:
- **Option A (callback URL):** XMI builds a Cloud Run HTTPS endpoint that receives Habu's webhook
  and fans out to their internal Pub/Sub.
- **Option B (Habu publishes to Pub/Sub):** XMI creates a Pub/Sub topic + subscription and grants
  Habu publisher IAM access.

Has XMI been told they have build work regardless of which option we pick? Which of the two is a
lighter lift for their team? If XMI's preference for Pub/Sub is about avoiding build work, Option A
is not significantly more work for them — and it keeps Habu's architecture simpler long-term.

---

## Q3 — Flow Chaining Latency Requirement

XMI said 60-second polling is too slow for flow chaining. Do they have a specific SLA in mind —
is 2-3 seconds acceptable, or do they need sub-second?

This affects whether a pull API with a short poll interval could serve as a stopgap for M1 while
we build and finalize the push delivery mechanism.

---

## Q4 — M1 Scope: Which Events First?

XMI asked for:
1. DataConnection stage changes
2. FlowRun state changes (flow chaining)
3. Dataset assignment changes
4. Quick-start trigger (all datasets assigned → auto-trigger run)

For M1, is there a priority order? If we shipped DataConnection + FlowRun events first, does that
unblock XMI's most critical workflows while we resolve the delivery mechanism decision?

---

## Suggested Ask to Joel

If the answers to Q1 and Q2 are not immediately clear: request a 30-minute call with XMI, Aditya,
and the Architect to resolve the callback-URL vs. Pub/Sub question before the design is finalized.
This single decision gates the entire M1 architecture.
