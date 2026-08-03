# SUMMARY — Platform-Level Change Events in Hank (post Anil/Josh decision)

**Session date:** 2026-07-31 → 2026-08-03
**Author:** Aditya Bhardwaj
**Decision meeting:** 2026-07-30 with Anil and Josh Wo (Principal Architects)
**Tickets:** DV-13856 (platform), DV-15090 / DV-15091 (M1), DV-15496 (epic), DV-15621 (XMI polling)
**Detail document:** [`2026-07-31_hank_platform_event_design_after_anil_josh.txt`](2026-07-31_hank_platform_event_design_after_anil_josh.txt)

> **This supersedes the recommendation in
> [`../2026-07-31-aditya-c4-architecture-orinix/`](../2026-07-31-aditya-c4-architecture-orinix/)
> and in `2026-07-31/2026-07-30-aditya-architect-followup/`.** Those argued for
> **service-layer** emission (decision D1, Option 1). The architects decided
> **against** it. Read this file for the current direction; read those for the
> evidence base and the traced runtime flows, which remain valid.

---

## 1. Problem statement

XMI polls our API to learn when Clean Room resources change (DV-15621 records the
rate-limiting pain). Orinix will push instead. The receiving side is agreed. The open
question was **where the event is produced**. My earlier analysis recommended emitting
from the service layer (per-handler). The 2026-07-30 meeting decided otherwise.

## 2. The decision

1. **Use Hank** — the shared library whose GORM hooks every service already gets by
   embedding `hdb.Audit`. A function-by-function approach does not scale: new methods
   get added and engineers forget to emit. **Think at the platform level.**
2. **DB triggers and CDC are stashed.** Triggers are costly; CDC yields roughly
   Hank-equivalent output at the extra cost of running and maintaining a pipeline.
3. **Drop from/to** (before-and-after values) from the XMI payload. That was the
   hardest part for Hank, and XMI can query by the resource id in the event.
4. **Extend `AuditLog`** rather than build something new.
5. Josh raised a **"root node"** approach and shared Fowler's Event Sourcing article.
6. Josh is fine with **orinix** once the Hank piece is resolved.

## 3. Why they are right, and why two of my objections die

**The forgetting argument is decisive.** The real difference is the *unit of
forgetting*: service-layer forgets once per **new write path** (many, growing);
model-layer forgets once per **new resource type** (few, reviewable). Every model
already embeds `hdb.Audit`, so adding a field to `DataImportJob` needs zero new code
to reach events.

**Dropping from/to kills my two strongest objections.** My case against hooks rested
on "the record has no field values" and "an assembler cannot know when all 5 row
records arrived, so a timer turns a slow message into a *wrong* event."
- "No values" is moot once we are not sending values.
- The "wrong event" failure was conditional on **fat** events. With a **thin** event a
  straggler produces a *duplicate notification*, not a wrong one — and XMI reads back
  current state either way. **I was right about the mechanism and wrong about the
  consequence**, because I assumed a payload they have now removed.

## 4. First principles — why one action is five events

A Data Connection is **one business resource stored as two tables**:
`data_import_jobs` (1 row) + `organization_job_parameters` (**1 row per setting**).
One create = **5 row writes** (INSERT job, DELETE settings matching zero rows, INSERT
setting ×3), all in one transaction — and **10** via the V1 route, which saves the
whole connection twice (`job_service.go:1418` then `:1425`).

Josh's **"root node" is the DDD Aggregate Root**. If Hank knows that
`OrganizationJobParameter`'s root is the `DataImportJob`, five row events roll up to
one resource event **automatically, at the platform layer, for every resource type**.
That is the piece that makes the platform approach work, and the piece my design was
solving by hand in each handler.

## 5. The correlation key — answered from source

**Question:** is there an existing `AuditLog` field that is the same across the
insert/delete/insert of one `createJob`, or must one be added?

**Answer: `RequestID` — it already exists and it is the only field that works.**

| Field | Same across the 5 writes? | Unique to this operation? |
|---|---|---|
| `ObjectID` / `ObjectName` / `ObjectType` / `Action` | ❌ differ per row | — |
| `ActionByID` / `ActionByEmail` | ✅ | ❌ same for every action that user ever takes |
| `ActionAt` | ~ truncated to the second | ❌ collides; can straddle a second boundary |
| `Method` | ✅ | ❌ identifies the operation *type*, not the *instance* |
| `OrgID` / `ImpersonatedBy*` | ✅ | ❌ |
| **`RequestID`** | **✅** | **✅ fresh UUID per request** |

**It is also better than a transaction id**, because the V1 route performs **two
transactions in one request** — `RequestID` spans both, so one user action still
yields one event.

**But `RequestID` alone is not sufficient.** It says *which rows belong together*; it
does not say *which business resource changed* (one request can touch several).
So the roll-up key is:

```
(RootObjectType, RootObjectID, RequestID)
```

→ **Correlation: reuse existing `RequestID`. Identity: must add `RootObjectType` +
`RootObjectID`** — these cannot be derived, because `ObjectID`/`ObjectType` are
per-row.

### Verified mechanics of `RequestID`

- Set in exactly one place: `hank/http/middleware/tracing.go` `WithTracing` reads the
  `X-Request-Id` header and **generates a UUID if absent**, storing it via
  `contexts.SetReqIdCtx`. `hank/http/middleware/logging.go:104` `WithContextLogger`
  then copies it into the logrus fields as `requestId`.
- `AuditLog.RequestID` (`hank/db/audit.go:70`) reads the **log-field copy**
  (`hlog.LogEntryCtx(ctx).Data["requestId"]`), which exists only if
  `WithContextLogger` ran.
- **Read the canonical context value instead** — `contexts.GetReqIdCtx(ctx)`. That is
  exactly what `hank/aws/sns/service.go:37` already does.
- **Nice precedent for the review:** `hank/aws/sns/service.go:48` already sets
  `MessageGroupId: reqId`. RequestID is *already* the platform's de-facto correlation
  identity for messaging.
- **Gap:** background workers have no HTTP request → no middleware → `RequestID` is
  empty. Fix: `contexts.SetReqIdCtx(ctx, uuid.New().String())` at the start of the
  worker's unit of work. This also fixes the audit log for background operations.
- `RequestID` is `interface{}` — guard for `nil`.

## 6. Design — five changes

**Change 1 (BLOCKER) — fix the claims gate.** Every hook opens
`tokenClaims, ctx, parsed := claims(scope); if !parsed { return nil }`
(`hank/db/audit.go:151-154, 184-187, 200-203`), and `claims()` needs a context set by
`BeginDB`/`BeginTxDB` (`audit.go:215-225`). Any write not on that path — **or any
background worker** — produces **no audit record at all**, silently. A flow run
completing is almost certainly a background worker, and that is XMI's most important
event. Fix: fall back to a system actor. The precedent is 40 lines away —
`GetAuditDetails` (`audit.go:91-123`) already degrades gracefully via
`HABU_PLATFORM_SUPERUSER` / `IsAuthorizedServiceUser`.

**Change 2 (BLOCKER) — fix the empty `ObjectID` on delete.**
`getObjectDetails` (`audit.go:241-267`) marshals `scope.Value` and reads `"ID"`, but
`forebitt/db/job.go:185` deletes with an **empty struct**
(`tx.Scopes(IDScope(id)).Delete(&models.DataImportJob{})`) — the id is in the WHERE
clause. So delete records read `{"ObjectType":"DataImportJob","ObjectID":"","Action":"DELETE"}`.
Already a live defect; fatal under the platform approach.

**Change 3 — declare the aggregate root.** Optional, opt-in interface in `hank/db` so
the other services see zero change:
```go
type EventScoped interface { EventRoot() (objectType string, objectID string) }

func (j DataImportJob) EventRoot() (string, string)            { return "DATA_CONNECTION", j.ID }
func (p OrganizationJobParameter) EventRoot() (string, string) { return "DATA_CONNECTION", p.ImportJobID }
```
This also yields the **business name** (`DATA_CONNECTION`) instead of the model name,
so our schema stays private.

**Change 4 — declare event-visible state via struct tags (the one push-back).**
"No from/to" should mean **Level 1, not Level 0**. from/to was the expensive part
(before-image SELECT on every update + a security review). **Current state costs
nothing** — the value is already in the struct being written.
```go
Status string `gorm:"type:varchar(20);not null"       event:"state"`
Stage  string `gorm:"...;default:'STAGE_UNKNOWN'"     event:"state"`
```
Without it Hank carries `Action`, **not `Status`** — so the event can say *"the flow
run was updated"* but never *"the flow run COMPLETED"*, which is the event this is
being built for. The tag list also **is** the security allow-list (`Credential.Value`
simply never gets tagged), answering the leak objection to platform-level emission.

*Verified bonus:* gorm v1.9.11 stores the update map at
`scope.InstanceGet("gorm:update_attrs")` (`callback_update.go:27`), so
`changedFields: ["stage"]` (**names only**) is free — no before-image, no extra query.
*Caveat:* `UpdateJobV2` uses `Updates(*job)` and gorm v1 drops zero values, so only
emit a tagged field if it appears in `update_attrs` — otherwise you ship `"stage": ""`
to a partner.

**Change 5 — never publish from the hook; write an outbox row.**
**Verified** in gorm v1.9.11 `callback_create.go:10-18`: `gorm:after_create` is
registered **immediately before** `gorm:commit_or_rollback_transaction`, and
`afterCreateCallback` (`:166`) propagates a returned error into scope, which
`CommitOrRollback` (`scope.go:414-426`) turns into a **ROLLBACK**. So publishing to
SNS from the hook would put network latency inside a transaction and let an SNS
failure **roll back a user's write**, plus risk phantom events.

Instead the hook does `tx.Create(&outboxRow)` on the **same tx**; a relay publishes
after commit. This buys:
- **Atomicity** — no phantom events, no loss. A real at-least-once guarantee (D4).
- **Deterministic completeness** — all rows of one action commit together, so **the
  transaction boundary is the completeness signal**. No timer. *This dissolves my
  original objection to hooks entirely.*
- SNS stays out of the transaction.

This is where the architects' platform direction and my rejected "Option 5"
(request-scoped buffer) converge — and the outbox is strictly better, being atomic.

## 7. The event

```json
{
  "eventId": "b4f1…", "eventTime": "2026-07-31T09:14:02Z", "schemaVersion": "1.0",
  "objectType": "DATA_CONNECTION", "objectId": "d56ada74-…", "action": "UPDATED",
  "state": { "stage": "CONFIGURATION_COMPLETE", "status": "ACTIVE" },
  "changedFields": ["stage"],
  "actor": { "id": "…", "email": "…", "type": "USER" },
  "organizationId": "…", "requestId": "…"
}
```
No from/to anywhere. `AuditLog` gains `RootObjectType`, `RootObjectID`, `State`,
`ChangedFields`, `EventID`, `SchemaVersion` — **all optional/additive**, so the other
four services are unchanged unless they opt in (constraint C5).

## 8. What Fowler's article says, and the hazard it surfaces

[Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html): *"Capture all
changes to an application state as a sequence of events."* The log is the book of
record; current state is a derived fold you can rebuild by replay. Key concepts:
rebuilding by replay, **snapshots**, reversal/compensating events, and **external
systems / Gateways**.

Two honest observations:

1. **What was agreed is *not* event sourcing.** In Fowler's taxonomy it is **Event
   Notification** (thin event, receiver calls back) — a good choice, but worth naming,
   because event sourcing *requires* events sufficient to rebuild state. *"X was
   updated"* cannot rebuild anything. The audit workstream must not assume it can
   reconstruct history from these events.
2. **A live hazard, probably not yet raised.** Fowler's **External Update** problem:
   replay must not re-fire real-world side effects. XMI's use case 3 is *"when Flow 1
   completes, **trigger Flow 2**."* If orinix replays — catch-up, DLQ redrive,
   backfill — **XMI could re-trigger flows.** Needs an explicit answer (replay marker,
   consumer-side dedupe on `eventId`, or agreed idempotency) before M1 ships.

Also: Fowler's **snapshot** concept is the clean answer to the 90-day `object_events`
delete — current state in the source table *is* the snapshot; you re-read, you do not
replay from the beginning.

## 9. Key repository references

| Concern | File:line |
|---|---|
| The claims gate (blocker) | `hank/db/audit.go:33-41`, `:151-154`, `:184-187`, `:200-203` |
| Context injection | `hank/db/audit.go:215-225` (`BeginDB` / `BeginTxDB`) |
| System-actor precedent | `hank/db/audit.go:91-123` (`GetAuditDetails`), `:107-110` |
| `AuditLog` struct | `hank/db/audit.go:43-56`; `RequestID` at `:70` |
| ID/Name extraction | `hank/db/audit.go:241-267` (`getObjectDetails`) |
| Hook registration | `hank/db/service.go` (`applyEmbeddedHooks`) |
| requestId origin | `hank/http/middleware/tracing.go` (`WithTracing`), `logging.go:104` |
| requestId canonical read | `contexts.GetReqIdCtx`; used by `hank/aws/sns/service.go:37`, MessageGroupId `:48` |
| AfterCreate inside txn | gorm v1.9.11 `callback_create.go:10-18`, `:166`; `scope.go:414-426` |
| changedFields source | gorm v1.9.11 `callback_update.go:27` (`gorm:update_attrs`) |
| Empty ObjectID on delete | `forebitt/db/job.go:185` |
| Two tables / 5 writes | `forebitt/db/job_v2.go:13-36`; `job_parameters.go:109-167` (`:121`, `:150`) |
| V1 double save | `forebitt/api/server/job_service.go:1418`, `:1425` |
| Model embedding pattern | `forebitt/models/data_import_job.go:15-39` |

## 10. Open questions and next steps

**Verify first (Aditya's note: V1/V2 are testable in stage and are not the concern —
platform capability is):**
- **V2** do flow-run state changes reach the hooks with parsed claims? Decides whether
  a system-actor fallback is mandatory.
- **V6** does anything parse the `Audit Log:` stdout lines today (Datadog monitors,
  the audit feed to pegleg)? Bounds the blast radius of changing that JSON shape.
- **V3** is `requestId` populated on the paths we care about — and is it absent for
  background workers, as the code suggests?
- **V1** are the V1 doors live? Decides whether the double-event on that route matters.

**Still unresolved:**
- Cross-service resources (Dataset → DataImportJob in forebitt → Credential in
  primage) — the aggregate root works *within* a service, not across three databases.
- **Read-access auditing** (Jon's ask) has no emit point: reads do not write rows, so
  **no model-layer or database-level mechanism can ever capture them.** Only
  service-layer code can. Worth saying now rather than discovering it in M3.
- Replay vs XMI's flow-triggering (§8 hazard).

**Order of work:** Phase 0 verify (V2, V6, V3, V1) → Phase 1 Hank, additive and
opt-in (claims fallback, `EventScoped`, `event:"state"` reflection, `AuditLog` fields,
outbox writer, empty-ObjectID guard) → Phase 2 forebitt (`EventRoot()` on the two
models, tags on `Status`/`Stage`/`Name`, fix the delete call site, outbox table +
relay) → Phase 3 orinix unchanged (SQS listener, `INSERT … ON CONFLICT DO NOTHING`).

**To put back to the architects:** agreed on platform-level via Hank and on dropping
from/to; **one ask** — let "no from/to" mean Level 1, not Level 0; **one correction**
to my own earlier position — with thin events plus an outbox the "wrong event" failure
I argued against does not exist; **two blockers** to fund first (claims gate, empty
delete id); **one question to Josh** on the replay/external-update hazard.
