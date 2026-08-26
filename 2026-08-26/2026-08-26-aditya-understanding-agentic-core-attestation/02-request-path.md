# End-to-end request path

Every line reference below is to a branch checked out locally:

| Repo | Path | Branch |
|---|---|---|
| agentic-core | `/Users/adbhar/Documents/Habu_Cloned_Repo/agentic-core` | `hackathon_attestation` |
| unhygienix | `/Users/adbhar/Documents/Habu_Cloned_Repo/unhygienix-attestation` | `hackathon_attestation` |

---

## The 16 new unhygienix endpoints

All registered on one mux in `api/server/attestation.go:38-58`:

```
/unhygienix/organization/{orgId}/attestation-rule
/unhygienix/organization/{orgId}/attestation-rule/{ruleId}
/unhygienix/organization/{orgId}/data-import-job/{jobId}/attestation-rule
/unhygienix/organization/{orgId}/clean-room/{crId}/dataset/{dsId}/attestation-rule
/unhygienix/organization/{orgId}/clean-room/{crId}/dataset/{dsId}/attestation-enforcement
/unhygienix/organization/{orgId}/clean-room/{crId}/clean-room-question/{crqId}/attestation-rule/apply
/unhygienix/organization/{orgId}/clean-room/{crId}/clean-room-question/{crqId}/attestation-rule/save
/unhygienix/organization/{orgId}/clean-room/{crId}/clean-room-question/{crqId}/attestation-rule/run/status
/unhygienix/organization/{orgId}/clean-room/{crId}/clean-room-question/{crqId}/attestation-rule/verdict
/unhygienix/organization/{orgId}/clean-room/{crId}/clean-room-question/{crqId}/attestation-rule/finding-verdict
/unhygienix/organization/{orgId}/clean-room/{crId}/clean-room-question/{crqId}/attestation-rule/golden
/unhygienix/organization/{orgId}/clean-room/{crId}/clean-room-question/{crqId}/attestation-rule/report
/unhygienix/organization/{orgId}/clean-room/{crId}/attestation/ds-counts
/unhygienix/organization/{orgId}/clean-room/{crId}/attestation/review-queue
/unhygienix/organization/{orgId}/clean-room/{crId}/attestation/golden-set-questions
/unhygienix/organization/{orgId}/clean-room/{crId}/attestation/golden-set-examples
/unhygienix/organization/{orgId}/clean-room/{crId}/attestation/audit-log
```

Path dispatch is a `switch` on the split path at `attestation.go:62-118`.

**The agent side adds no new endpoint.** It reuses the two Agent Protocol calls
every agent on the server already exposes.

---

## Step trace — Apply

| # | Step | File:line |
|---|---|---|
| 1 | Apply / Save handler (`sync` bool distinguishes them) | `attestation.go:543` |
| 2 | Status → `RUNNING` | `attestation.go:1150` |
| 3 | Base URL from `ATTESTATION_AGENT_BASE_URL`, default `http://localhost:8080` | `attestation.go:1132-1137` |
| 4 | HTTP client, 180s timeout | `attestation.go:1379` |
| 5 | `POST /threads`, body literally `{}` | `attestation.go:1381-1382` |
| 6 | Headers: `Content-Type`, `lr-org-id`, optional `Authorization` | `attestation.go:1386-1390` |
| 7 | Extract `thread_id` (falls back to `threadId`) | `attestation.go:1403-1416` |
| 8 | `POST /threads/{id}/runs/wait` with `assistant_id: "attestation-agent"` | `attestation.go:1418-1424` |
| 9 | Parse report from the reply | `attestation.go:1454` |
| 10 | Report missing → re-read `GET /threads/{id}/state` | `attestation.go:1455-1470` |
| 11 | Auto-approve → `APPROVED` | `attestation.go:1158` |
| 12 | Otherwise → `INREVIEW` | `attestation.go:1164` |
| 13 | Human verdict writes final status | `attestation.go:843` |
| 14 | Column definition | `db/attestation.go:353`, `models/cleanroom.go:405-406` |

---

## Failure handling at the call site

The thread-state fallback is **not** for slowness. It sits below every failure path:

| Line | Condition | Behaviour |
|---|---|---|
| 1441-1444 | network error or 180s timeout | returns the error — no fallback |
| 1450-1452 | HTTP >= 300 | returns the error — no fallback |
| 1455 | report absent from an otherwise-fine 200 | **falls back**, line 1456 |

`fetchAttestationThreadState` itself is `attestation.go:1474-1496`. It swallows
all its own errors and returns `nil` — a best-effort second look, never a retry.

Cause: LangGraph can package the AI message in a wrapped ("constructor") form
whose content sits one level deeper. `GET /threads/{id}/state` returns a
different representation of the same conversation.

---

## Identity Bridge — on the return leg only

| Leg | Goes through Identity Bridge? |
|---|---|
| unhygienix → agent | **No.** Direct HTTP; `lr-org-id` header forwarded. |
| agent → unhygienix (golden set) | **Yes.** |

Agent side: `agentic-core/core/agents/attestation-agent/unhygienix_client.py`.

The payload carries the **Habu** org id, but Identity Bridge keys off the
**LiveRamp** org id. `unhygienix_client.py:33-77` (`resolve_ib_auth`) converts
between them, calling `GET /user/organizations` when needed.

Golden set fetch is best-effort: any transport or auth failure returns `[]`
(`unhygienix_client.py`, every `except` branch), and the engine verdict stands.

---

## When this runs

At question **definition and approval** time. The question has not executed;
there is no result set anywhere.

```
INITIATED -> RUNNING -> INREVIEW -> APPROVED -> REJECTED
```

`RUNNING` means the attestation check is running — not the question.

**Not verified:** whether an unapproved question is hard-blocked from executing.

---

## Which agent is actually called

On PR #1160 / unhygienix #3753, `attestation.go:1419` hard-codes:

```go
"assistant_id": "attestation-agent",
```

`cleanroom-assistant` is **not** in this path. Only the later pair
(unhygienix #3768 / agentic-core #1176) swaps that string.
