# 05 — Runtime Interaction Flows (C4 Dynamic)

**Question this answers:** *What actually happens, in order, when something changes —
including when things go wrong?*

Six flows. The first is the happy path; the rest are the ones that decide whether this
architecture is sound.

---

## Flow 1 — Data Connection created, end to end (the M1 happy path)

```mermaid
sequenceDiagram
    autonumber
    actor U as 👤 Customer
    participant UI as Clean Room UI
    participant H as forebitt<br/>CreateDataConnectionV2
    participant DBL as db.InsertJobV2
    participant PG as forebitt Postgres
    participant OBS as services/observability<br/>🟧 NEW
    participant SNS as SNS Standard topic
    participant SQS as SQS ingest queue
    participant OX as Orinix ingest
    participant OE as object_events
    participant D as Delivery workers
    participant X as XMI

    U->>UI: create "Adidas EMEA CRM Data"<br/>+ 3 settings
    UI->>H: POST /v2/organization/{orgId}/data-connection
    H->>H: :313 getAuthUser → actor
    H->>PG: :323 :328 resolve dataType, dataSource
    H->>DBL: :356 InsertJobV2
    DBL->>PG: BEGIN
    DBL->>PG: INSERT data_import_jobs
    DBL->>PG: DELETE org_job_parameters (0 rows)
    DBL->>PG: INSERT org_job_parameters ×3
    DBL->>PG: COMMIT
    DBL-->>H: job.ID populated
    H->>H: :362-371 Snowflake — may still fail
    H->>H: :372-378 assemble response
    rect rgb(255, 230, 204)
    H->>OBS: :378 emitDataConnectionEvent<br/>{CREATED, actor, after, params, source, type}
    OBS->>SNS: publish 1 event (fire-and-forget)
    end
    H-->>UI: :379 201 Created
    UI-->>U: connection created

    SNS->>SQS: subscription
    SQS->>OX: long-poll receive
    OX->>OE: INSERT … ON CONFLICT DO NOTHING
    OE->>D: new event
    D->>X: signed webhook POST
    D->>X: GCP Pub/Sub publish
    X-->>D: 2xx / ack
```

**Key ordering guarantees visible here:**

- The **emit is after `COMMIT`** → we can never announce something that did not
  happen.
- The **emit is after the Snowflake block** (`:362-371`) → we never announce a create
  the caller was told failed.
- The **user's response does not wait on delivery** → publish is fire-and-forget.
- **Exactly one event** regardless of the five underlying row writes.

---

## Flow 2 — Flow Run completes (XMI's most important use case, and the biggest risk)

This is use case 2 *and* the trigger for use cases 3 and 4 (flow chaining,
onboarding). It is also the flow with an **open, high-probability risk**.

```mermaid
sequenceDiagram
    autonumber
    participant BG as Background worker<br/>(no user request)
    participant UNH as unhygienix<br/>⬜ future producer
    participant PG as Postgres
    participant OBS as observability emit
    participant SNS as SNS
    participant OX as Orinix
    participant X as XMI

    BG->>UNH: flow run finishes
    UNH->>PG: UPDATE flow_run SET state = 'COMPLETED'

    alt 🟥 V2 UNVERIFIED — are auth claims present?
        Note over UNH,OBS: If the context carries NO parsed auth claims:<br/>• hank hooks emit NOTHING (claims gate returns nil)<br/>• Option 1 has no authUser → needs a SYSTEM ACTOR
    end

    UNH->>OBS: emit {FLOW_RUN, state: COMPLETED, actor: system?}
    OBS->>SNS: publish
    SNS->>OX: via SQS
    OX->>X: deliver "FlowRun 123 is now COMPLETED"
    X->>X: chain Flow 2 / trigger onboarding run
```

**Why this flow decides the payload level.** XMI must be able to act on *"is now
COMPLETED"*. A payload that only says *"FlowRun 123 was updated"* (Level 0) sends them
straight back to polling — the very problem DV-15621 is solving. **This is also the
single sharpest argument against Hank's hooks**: the hook record carries `Action`, not
`Status`, so it cannot express this event *at all*.

> **🟥 Verification item V2 — the highest-value open question in the package.**
> A flow run completing is almost certainly a background worker, not a user request.
> If no parsed auth claims reach the context: Hank's hooks emit **nothing**, and
> Option 1 must supply a **system actor**. Close this before committing to any option.

---

## Flow 3 — Delivery fails, retries, then dead-letters

```mermaid
sequenceDiagram
    autonumber
    participant OE as object_events
    participant D as Delivery dispatcher
    participant R as Retry / DLQ handler
    participant X as XMI endpoint

    OE->>D: event ready
    D->>X: webhook POST (attempt 1)
    X--xD: 5xx / timeout
    D->>R: record failure
    R->>D: backoff, re-attempt
    D->>X: webhook POST (attempt 2)
    X--xD: 5xx / timeout
    R->>R: exhaust retries → park in DLQ
    Note over OE,R: 🟩 the event is NOT lost —<br/>it is still in object_events
    X->>OE: later: cursor catch-up via GetCleanroomEvents
    Note over X: XMI self-heals from the stored history
```

**The architectural point:** because `object_events` is the durable record and the
pull API reads from it, **delivery failure degrades to catch-up rather than data
loss**. This is why storage sits between ingest and delivery instead of Orinix
forwarding straight through.

---

## Flow 4 — Replay and catch-up (cursor)

```mermaid
sequenceDiagram
    autonumber
    participant X as XMI
    participant API as Pull API<br/>GetCleanroomEvents
    participant OE as object_events

    Note over X: XMI was down for 3 hours
    X->>API: GetCleanroomEvents(cursor = last_seen_id)
    API->>OE: SELECT … WHERE id > cursor ORDER BY id LIMIT n
    OE-->>API: page of events
    API-->>X: events + next_cursor
    loop until caught up
        X->>API: GetCleanroomEvents(next_cursor)
        API-->>X: next page
    end
    Note over X,OE: 🟥 bounded by the hard 90-day delete —<br/>Q10: what happens on day 91?
```

**Idempotent by construction:** XMI may reprocess overlapping pages safely because
every event carries a stable ID. That same ID makes Orinix's ingest idempotent against
SQS redelivery.

---

## Flow 5 — What the rejected alternative would produce (contrast)

Same user action as Flow 1. This is the diagram to show if anyone asks *"why not just
use the hooks we already have?"*

```mermaid
sequenceDiagram
    autonumber
    actor U as 👤 Customer
    participant H as forebitt handler
    participant PG as Postgres
    participant HK as hank GORM hooks
    participant ASM as ⁉️ Assembler in Orinix
    participant X as XMI

    U->>H: ONE click — "create connection"
    H->>PG: INSERT job
    PG-->>HK: AfterCreate → event 1 {DataImportJob, CREATE}
    H->>PG: DELETE settings (0 rows)
    PG-->>HK: AfterDelete → event 2 {ObjectID: "" ⚠️}
    H->>PG: INSERT setting ×3
    PG-->>HK: AfterCreate ×3 → events 3,4,5

    HK->>ASM: 5 separate records, no field values
    Note over ASM: Must now: correlate them ·<br/>identify which is the ROOT object ·<br/>know when ALL have arrived (no count,<br/>no txn marker → timer-and-hope) ·<br/>discard the phantom DELETE ·<br/>find values that DO NOT EXIST
    ASM--xX: 🟥 a slow message yields a WRONG event,<br/>not a late one
```

**And via Door B the same click produces 10 records, not 5.**

The failure shape is what condemns it: a timer-based assembler turns a slow message
into a **wrong** event — *the worst possible failure, because it looks like success*.
Compare Option 1's worst case: one event missing, detectable by volume monitoring.

---

## Flow 6 — The reliability gap, stated honestly

```mermaid
sequenceDiagram
    autonumber
    participant H as forebitt handler
    participant PG as Postgres
    participant SNS as SNS
    participant OX as Orinix

    H->>PG: COMMIT ✅ row exists
    H->>SNS: publish
    SNS--xH: ❌ network / throttle / ARN error
    H->>H: error LOGGED AND SWALLOWED<br/>job_service.go:1602-1605
    H-->>H: request returns 200 to the user
    Note over H,OX: 🟥 the change happened.<br/>No event exists. Nobody knows.
```

| | |
|---|---|
| **Can happen** | Row exists, no event sent → recoverable by backfilling from the source table |
| **Cannot happen** | An event for a row that does not exist → publish is strictly after `COMMIT` |
| **Today** | We would **not know** how many we lost |
| **Minimum fix** | A publish-failure counter and an alert (D4) |
| **Proper fix** | **Transactional outbox** — write the event row in the same transaction, a worker sends it and marks it done. Goes at **exactly the line the publish is on today**, so choosing best-effort now does not make it harder later |

The source calls this *"the weakest part of the proposal"* and *"the gap I would push
hardest on if I were reviewing."* A review package that hid it would be doing the
reader a disservice.

---

## Flow summary — which flows are proven and which are not

| Flow | Status | Blocking item |
|---|---|---|
| 1 — Data Connection create | 🟧 emit proposed; downstream 🟦 agreed | D1, D3, V1 |
| 2 — Flow Run completion | 🟥 **producer not built, actor unverified** | **V2**, unhygienix instrumentation (M2+) |
| 3 — Delivery retry / DLQ | 🟦 agreed | — |
| 4 — Replay by cursor | 🟩 pull API already reads `object_events` | 90-day boundary (Q10) |
| 5 — Hook-based alternative | 🟥 rejected | — |
| 6 — Publish loss | 🟥 **accepted gap for M1** | D4 |

---

**Next:** [06-deployment.md](06-deployment.md) — where all this actually runs.
