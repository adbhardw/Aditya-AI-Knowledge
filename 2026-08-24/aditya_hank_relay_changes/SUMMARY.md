# Hank Change Events — Transactional Outbox, Relay, and Flow Event Coverage

**Session date:** 2026-08-24 (analysis spans 2026-08-21 → 2026-08-24)
**Repos:** `hank`, `forebitt`, `unhygienix`, `pegleg`, `picanmix`
**Read this first.** Detail documents are listed at the end.

---

## Problem statement

Hank emits CloudEvents to SNS from its GORM audit hooks whenever an audited row
changes, so XMI can stop polling. Two separate problems were found.

1. **Delivery is not at-least-once.** The hook hands the event to an in-memory Go
   channel *before* the transaction commits. An event can be published for a
   transaction that later rolls back; a failed SNS publish destroys the event with
   no retry; a full buffer drops silently; a `SIGKILL` loses the buffer.
2. **Four of the five events XMI asked for never fire at all** — and not for the
   reason previously assumed.

---

## First principles: why the current design cannot be at-least-once

There are **two independent commit decisions** with nothing coordinating them:
the channel handoff, and the Postgres `COMMIT`.

```
hank/db/change_events.go:279   p.buf <- queuedEvent{...}   ← a MEMORY write.
                                                             Postgres never knows.
                                                             Not in the transaction.
                                                             Cannot be rolled back.
```

The publish attempt then **consumes** the only copy: `run()`
(`hank/db/change_events.go:177-182`) pops the event, `publishOne` fails at `:219`,
`:224-227` logs it, the local variable goes out of scope and is garbage collected.
No retry is possible because nothing remembers the obligation.

---

## The fix: transactional outbox

**One line changes.** `hank/db/change_events.go:279` becomes
`scope.DB().Create(&ChangeEventOutbox{...})`.

`scope.DB()` **is** the caller's transaction handle. Verified:

| Fact | Source |
|---|---|
| `BeginTxDB` wraps a `*sql.Tx` and stashes ctx | `hank/db/audit.go:230-234` |
| `gorm:after_create` runs immediately before `gorm:commit_or_rollback_transaction` | `gorm/callback_create.go:9-19` |
| `scope.Begin()` starts no nested tx when already inside one | `gorm/scope.go:403-411` |
| `CommitOrRollback` no-ops without `gorm:started_transaction` | `gorm/callback_save.go:12-14` |

**The hook firing before COMMIT is the bug today and the requirement under the
outbox.** Same fact, opposite sign.

### Timeline — creating a data connection (1 job + 10 parameters)

| Time | Code | `data_import_jobs` | `change_event_outbox` | SNS |
|---|---|---|---|---|
| T1 | `forebitt/db/job_v2.go:19` BEGIN | – | – | – |
| T2 | `:20` `tx.Create(&job)` | 1 row *(uncommitted)* | – | – |
| T3 | hook → outbox INSERT | 1 *(uncommitted)* | 1 row, `published_at=NULL` *(uncommitted)* | – |
| T4 | `:25` parameter inserts | +10 *(uncommitted)* | +10 NULL *(uncommitted)* | – |
| **T5** | **`:31` `tx.Commit()`** | **11 durable** | **11 durable, all still NULL** | – |
| T6 | relay `SELECT` | 11 | 11 NULL — relay sees them *first time* | – |
| T7 | relay `Publish` | 11 | 11 NULL | 11 msgs |
| T8 | relay `UPDATE` | 11 | 11 timestamped | 11 msgs |

At T5 the outbox row is **not** updated — it was inserted at T3; COMMIT only makes
it durable. Transaction isolation means the relay *cannot* see uncommitted rows, so
phantom events become structurally impossible rather than merely tolerated.

---

## The relay

It is `run()` with the channel swapped for a table — **a goroutine in a process that
already exists**, replacing `go p.run()` at `hank/db/service.go:78`. Not a sidecar,
cron, or new service.

```
for {
    rows := poll(`WHERE published_at IS NULL`)   // 1. get pending
    publish(rows)                                 // 2. publish
    markPublished(rows)                           // 3. record success  ← NEW
}
```

**Step 3 is the entire fix.** A channel *acknowledges on read*, before the publish.
A table *acknowledges on success*, after it. Ordering must never invert:
publish→mark gives duplicates (at-least-once, wanted); mark→publish gives loss.
XMI already dedupes on the CloudEvents `id` (`hank/db/change_events.go:307`), so the
consumer contract needs no change.

`FOR UPDATE SKIP LOCKED` lets N pods run relays with no leader election.

### SNS outage, wall clock

```
10:00:00  COMMIT                → 11 rows, published_at NULL
10:00:03  poll → 11; #1-4 OK, #5 → 503 → break; UPDATE the 4 → 7 still NULL
10:00:08  poll → the same 7 (they still match the predicate) → no UPDATE
   ...    3 hours; writes keep committing normally; backlog grows
13:00:00  SNS back → poll drains backlog oldest-first → 0 NULL
```

**Human action required at recovery: none.** There is no retry code — the retry is a
consequence of the row still matching `published_at IS NULL`.

---

## The correction that mattered most

An earlier framing — "empty struct passed to Update/Delete → no event" — is **too
coarse and mispredicts forebitt**. The real rule:

For **updates**, GORM mutates `scope.Value` *before* the hook:
`gorm:assign_updating_attributes` (`gorm/callback_update.go:12`, runs first) →
`updatedAttrsWithValues` → `field.Set(value)` at `gorm/scope.go:919`. Fields are
included only `if !field.IsBlank` (`gorm/scope.go:897`). For **deletes** no such
step exists (`gorm/callback_delete.go:9-15`).

| Call shape | ObjectID | Event |
|---|---|---|
| `Updates(<struct with non-blank ID>)` | merged in | **fires** |
| `Updates(map{...})` without `"ID"` | blank | skipped |
| `Update("col", val)` | blank | skipped |
| `Delete(&models.X{})` | blank | skipped |
| `Delete(x)` with `x.ID` set | present | **fires** |

So `forebitt`'s `tx.Model(&models.DataImportJob{}).Updates(*job)` **works** — `*job`
carries the ID, which GORM merges into the empty literal. `unhygienix`'s
`Model(&models.CleanRoomFlowRun{}).Scopes(IDScope(id)).Update("job_status", status)`
**does not** — the update map has no ID.

---

## Root cause: why 4 of 5 XMI events never fire

Two **independent** gates, both must pass:

- **Gate 1 — `claims()`** (`hank/db/audit.go:33-41`): `"context"` is set only by
  `BeginTxDB`. A bare `db *gorm.DB` handle fails, and the hook returns at
  `hank/db/audit.go:171` before `publishChangeEvent`.
- **Gate 2 — ObjectID** (`hank/db/change_events.go:270-276`): empty → skipped.

| Event | Status | Cause |
|---|---|---|
| Flow node fails | **No** | No audited model exists |
| Flow completes | **No** | `unhygienix/db/flows.go:1816`, `:1821` — both gates |
| Flow deleted | **No** | `unhygienix/db/flows.go:427`, `:404` — gate 2 |
| Dataset assigned | **Yes** | but emits `CLEAN_ROOM_QUESTION_DATA_SET` |
| Dataset removed | **No** | bulk deletes, gate 2 |

**Flow node failure has no row to hook.** `FlowNode`
(`unhygienix/models/flows.go:255-261`) embeds only `TimeAudit`, and — fatally — has
**no `ID` field** (composite PK of FlowID/NodeID/FlowVersion), so
`getObjectDetails` (`hank/db/audit.go:250-262`) would return empty even with
`hdb.Audit` added. It is also a *structural* record; a runtime failure writes no
`FlowNode` row at all. Recommendation: emit at `CleanRoomQuestionRun` level.

**Architecture confirmed:** pegleg's Temporal workflow only orchestrates and
**polls** unhygienix (`HabuFlowActivitiesImpl.java:33` triggers, `:96` polls
`getActivityStatus`). Unhygienix owns the status row — **emit from unhygienix, never
pegleg.**

---

## Design options considered

| Option | Verdict |
|---|---|
| 2PC / XA | Rejected — coordinator SPOF, locks held through prepare |
| Saga with compensation | Rejected — unnecessary; a natural abort exists |
| **Transactional outbox + relay** | **Chosen** |
| CDC (Debezium) | Stashed 2026-07-30 — Hank-equivalent output, extra ops cost |
| `LISTEN`/`NOTIFY` instead of polling | Deferred — buys latency, not correctness |

**Trade-offs accepted:** two inserts per audited write (the real cost, on the request
path); table growth needing a reaper; up to one poll interval of added latency; and
one pooled connection held across a batch's SNS round trips — connection-pool
pressure, not CPU, mitigated by a smaller batch or `PublishBatch`.

---

## Final recommendation — three branches, all off `release_1x`

1. **`DV-observability/change-events-publisher`** — merge as-is. *(Rebased this
   session: 4 commits, 0 behind. A stale bot commit bumping to 1.23.2 was dropped —
   it would have regressed `release_1x`'s 1.23.6.)*
2. **Relay / outbox** — spec in this folder. Per-service `change_event_outbox` table,
   which **must** live in the same database as the business row.
3. **Flow + dataset coverage** — mostly unhygienix, one hank line.

Branch 2 makes delivery reliable; branch 3 makes the events exist. Independent —
do not merge into one PR.

**Do not "fix" the empty-ObjectID guard as part of branch 2.** An outbox row with no
objectId is worse than none: durable, retried forever, useless to a consumer whose
contract is GET-by-objectId.

---

## Open questions

- **D1–D6** in the relay spec §2 — blocking ones are D1 (which services get the
  table) and D2 (AutoMigrate vs versioned migration per service).
- Should `change_event_outbox` be excluded from Snowflake replication? It would land
  as `FOREBITT_CHANGE_EVENT_OUTBOX`; it is transient, churns hard, and every row
  carries a full payload.
- Object-type string for the question-dataset link — a **wire contract** value.
- Node-level vs flow-run-level failure granularity; per-dataset removal events vs one
  "datasets changed" event.

---

## Next steps

1. Merge branch 1; verify in stage with the 15-event harness.
2. Answer D1/D2; implement the relay.
3. Ship the one-word `Delete` fixes (`unhygienix/db/flows.go:427`, `:404`) as a
   standalone proof the pipeline works end to end.
4. Fix `UpdateCleanRoomFlowRunStatusAndTimestamps` + its 6 call sites — the
   highest-value event.
5. Run the **two-gate sweep** to inventory every silently-skipped write site:
   ```
   grep -rn "Delete(&models\.\|Model(&models\." unhygienix/db/ | grep -v _test.go
   grep -rn "^func .*(db \*gorm.DB" unhygienix/db/ | grep -v _test.go
   ```

---

## Detail documents

**This folder**
- `2026-08-24_relay_implementation_spec.txt` — full branch-2 spec: model, indexes,
  relay code, per-service changes, failure modes, cost, test plan, D1–D6.

**`../../2026-08-20/2026-08-20-aditya-understanding-forebitt-events-sns-config-wiring/`**
- `2026-08-21_change_events_outbox_step_trace.txt` — before/after step trace.
- `2026-08-21_outbox_relay_and_go_transactions_qa.txt` — Q&A: Go transactions, the
  relay, SNS-down trace, relay cost.

**`../../2026-08-17/2026-08-17-aditya-understanding-hank-change-events/`**
- `2026-08-24_flows_dataset_events_deep_dive_and_plan.txt` — the five events, the
  Temporal architecture, three-branch sequencing.
- `2026-08-24_flow_file_changes_evenet.txt` — exact per-file change list.
- `2026-08-17_method_find_silently_skipped_change_events.txt` — the original
  `claims()` gate method.
