# Slack Message — To John (cc Shruthi)
**Date:** 2026-05-18
**Context:** Following up on the events/observability discussion post TLM/PM feedback

---

Hey John — following up on the events/observability discussion. I've been thinking through the approaches and wanted to share where my head is before we sync, and then set up a call with XMI.

There are really three approaches on the table:

**1. Cursor-based polling API (pull)**
We expose `GET /cleanrooms/{id}/events?since=T`. XMI (or any consumer) calls this on a timer with a cursor. They get back structured field-level diffs — which columns were removed, what type changed, what was deleted. This is cloud-agnostic, requires no setup on XMI's side beyond calling an API, and the same table powers the Activity Feed UI we'd build. The main thing we'd need to align on with XMI is the event schema/structure they want to consume.

**2. Cloud-agnostic webhook / callback registration (push)**
Consumer registers an HTTPS URL with us via `POST /callbacks`. We call that URL whenever a monitored object changes — async, non-blocking, with retry. This needs a new `callback_registrations` table and a delivery worker on our side. Consumer just needs an HTTPS endpoint — doesn't matter if they're on GCP, Azure, or AWS.

**3. Cloud-native event streaming (SNS/SQS or GCP Pub/Sub)**
We could emit events directly to each consumer's cloud queue. But this gets complex fast — different SDKs, different IAM/auth models per cloud, egress costs, and we'd be giving external partners access to our internal infra. I'm leaning against this for external partners. The right model is SNS/SQS stays internal to Habu; external consumers always receive via HTTPS.

Given TLM's feedback to focus on API first, I think we start the XMI conversation with Option 1 — show them the event schema and cursor API, understand if that covers their needs. If they genuinely need sub-second push we layer in Option 2.

Two things I'd love to set up:
- A quick 20-min sync between us first to align on direction and what we want to learn from XMI
- Then a joint call with XMI — walk them through both options, get their feedback on the event structure, and understand whether polling works for them or if they need push

Happy to set those up — does this week or early next work for the first sync?

---

*Draft — review before sending*
