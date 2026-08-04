# SUMMARY — FINAL: Hank Audit Event → SNS → XMI

**Decision date:** 2026-08-04 · **Attendees:** two Principal Architects + Director of Engineering
**Author:** Aditya Bhardwaj
**Tickets:** DV-13856 (platform), DV-15090 / DV-15091 (M1), DV-15496 (epic), DV-15621 (XMI polling)
**Detail document:** [`2026-08-04_final_discussion_version_hank_audit_event_to_xmi.txt`](2026-08-04_final_discussion_version_hank_audit_event_to_xmi.txt)

> **⚠️ THIS SUPERSEDES EVERY EARLIER DESIGN IN THIS KNOWLEDGE BASE**, including
> `2026-08-03/2026-08-03-aditya-hank-platform-event-design/` and
> `2026-08-03/2026-07-31-aditya-c4-architecture-orinix/`. Those remain valid as the
> *decision trail* — the source-level findings in them are still correct and still
> cited here — but their **designs are obsolete**. §2 of the detail document lists
> exactly what is dropped.

---

## 1. Problem statement

XMI polls our API to learn when Clean Room resources change; DV-15621 records the
resulting rate-limiting pain. XMI also keeps asking for **more object types** — not just
Data Connection and Dataset. Instrumenting every write function per object type does not
scale for new engineers, which is what killed the service-layer approach.

## 2. The decision, in six points

| # | Decision |
|---|---|
| **D1** | **Use Hank's existing audit event** as the change event. No new event type. |
| **D2** | **Do not modify the `AuditLog` struct** — no root attribute, no root source type, no state, no changedFields. |
| **D3** | **XMI subscribes to our SNS.** We do *not* publish to their Pub/Sub. Subscribing is just an endpoint + credential on their side. |
| **D4** | **The code change lives in Hank**, the library already embedded in every service. Per-service work is configuration only. |
| **D5** | **First deliverable is a verification, not code** — confirm in Datadog that flow-run state transitions actually produce audit lines today. |
| **D6** | **orinix is not in the M1 path.** `object_events`, pull API, webhooks and replay defer to M2+. |

## 3. First principles — why this works

Hank already writes an audit record on **every row write, in every service**, for any
model embedding `hdb.Audit`. That subscription is one line of struct embedding, resolved
by GORM reflection — so a new write path or a new field is covered automatically. The
**unit of forgetting** is a new *resource type*, not a new *write path*.

We publish that same record to SNS, filtered to an allow-list of object types. XMI
receives *"this object changed"* and calls our existing API to read the new state.

**This is the pattern Fowler calls Event Notification** — thin event plus read-back — and
read-back is an intended part of it, not a workaround.

## 4. High-level architecture

```
UI → forebitt / unhygienix / picanmix / primage / pegleg
        │  (any row write on a model embedding hdb.Audit)
        ▼
   hank — hdb.Audit AfterCreate/Update/Delete
        1. build AuditLog            (exists today)
        2. log "Audit Log: {...}"    (exists today)
        3. if enabled AND ObjectType allow-listed → publish to SNS   ← NEW
        ▼
   SNS  habu-change-events  [Standard]
        ▼
   SQS  xmi-change-events  (+DLQ)  ── XMI polls ──► XMI ──► reads back via our API
        ▼
   (M2+) further subscriptions = audit tier, Microsoft, SafeHaven, orinix
```

**Why a queue in front of XMI rather than a raw SNS subscription:** SNS alone has no
retention — if XMI is down, an HTTPS subscription retries for a bounded window and the
message is gone. An SQS queue gives durability, a DLQ, and consumption at their own pace.
That is what makes "continuously consumable" (D3) actually true.

## 5. End-to-end runtime flow — one data connection create

1. Request arrives; `WithTracing` establishes `requestId` (both gRPC and HTTP chains).
2. `CreateDataConnectionV2` → `BeginTxDB(ctx)` attaches ctx to the transaction.
3. **5 SQL writes, 4 hook firings**: INSERT job (hook) · DELETE params — *0 rows, fires no
   hook* · INSERT param ×3 (3 hooks).
4. Each hook builds the `AuditLog` and logs it — unchanged behaviour.
5. **The allow-list filters**: `OrganizationJobParameter` is not listed → dropped.
   `DataImportJob` is → **1 event** published asynchronously to SNS.
6. SNS → SQS → XMI polls → XMI `GET`s the connection by `ObjectID` → reads `stage`.

**4 hook firings → 1 event, with a config list.** That is the roll-up we previously
designed an aggregate root for, achieved for free.

## 6. What XMI receives

The `AuditLog` exactly as it exists today (`hank/db/audit.go:43-56`):

```json
{ "ObjectID": "d56ada74-…", "ObjectName": "Adidas EMEA CRM Data",
  "ObjectType": "DataImportJob", "Action": "UPDATE",
  "ActionByEmail": "aditya@…", "ActionAt": "2026-08-04T09:14:02Z",
  "OrgID": "org-adidas-emea", "RequestID": "abc-123" }
```

**No field values, no before/after, no `Status`, no `Stage`.** The event says *"object X
was updated"*; XMI reads back for state. All four M1 use cases are satisfied that way.

**Is this just polling again? No.** DV-15621's problem is *periodic blind* polling —
calling every few minutes for every object, mostly returning "no change". Here XMI calls
**only when we say something changed, and only for that object**. The read is *triggered*,
not scheduled; call volume drops by the change-rate-to-poll-rate ratio.

## 7. Trade-offs accepted, and the one real hazard

**The hook runs *inside* the transaction** (verified: gorm `callback_create.go:10-18`
registers `gorm:after_create` immediately before `gorm:commit_or_rollback_transaction`,
and `scope.go:414-426` rolls back on a hook error). Two consequences:

1. **Publishing must be asynchronous and must never return an error into the hook.**
   A synchronous SNS call would hold row locks for a network round-trip, and a propagated
   error would let an SNS outage **fail customer writes**. Non-negotiable.
2. **Phantom events are possible** — the hook fires *before* commit, so a later rollback
   means we announced a change that never happened. **This is reachable in real code:**
   `job_v2.go:20` fires the hook, then `SetOrganizationJobParametersInTransaction` has
   several `tx.Rollback()` paths.

   **Why it is survivable:** because the payload is thin and XMI reads back, a phantom is
   **self-correcting** — XMI calls, gets 404 or unchanged state, moves on. Cost is one
   wasted API call. *The thin-payload decision is precisely what makes skipping the outbox
   acceptable; with a fat payload a phantom would be actively wrong.*

**Accepted:** phantom events (self-correcting) · event loss on pod death or SNS failure
(**not** self-correcting — needs a failure counter and alert) · duplicates (harmless) ·
out-of-order (read-back wins).

**Documented upgrade:** the transactional outbox is additive and goes at exactly the line
the publish sits on. Do not build it for M1.

## 8. The allow-list is now load-bearing

Without roll-up (D2), *every* row write on *every* model embedding `hdb.Audit` would
publish — unhygienix alone has ~91 such models. Unfiltered this floods the topic and
exposes internal table names to a partner. So Hank publishes only for configured object
types, e.g. `["DataImportJob","FlowRun","Flow","CleanRoomQuestion","Dataset"]`.

**Where it does not roll up:** the V1 create route saves twice → `CREATE` then `UPDATE`
for one action (harmless with read-back); and a change touching **only child rows**
publishes nothing (Q3).

## 9. Key repository references

| Concern | File:line |
|---|---|
| `AuditLog` struct (**unchanged**) | `hank/db/audit.go:43-56` |
| The three hooks | `hank/db/audit.go:150` / `:183` / `:199` |
| Background-worker gate (**the D5 risk**) | `hank/db/audit.go:33-41`, `:215-225` |
| Reads only ID + Name | `hank/db/audit.go:241-267` |
| SNS accepts `message any` — **no change needed** | `hank/aws/sns/service.go:34` |
| FIFO `MessageGroupId` caveat | `hank/aws/sns/service.go:48` |
| New SNS client per publish — fix in H5 | `hank/events/service.go:18` |
| `after_create` runs **before** commit | gorm `callback_create.go:10-18` |
| Hook error → ROLLBACK | gorm `scope.go:414-426` |
| `.Addr()` only when addressable | gorm `scope.go:434-436` |
| Delete with empty struct | `forebitt/db/job.go:185` |
| V1 double save | `forebitt/api/server/job_service.go:1418`, `:1425` |
| Why a new topic | `orinjade/aws/modules/habu-events/pegleg.tf:17` |

## 10. Known defects that limit what XMI receives

1. **Delete events carry no object id.** `forebitt/db/job.go:185` passes an *empty*
   struct — the id is only in the WHERE clause — so XMI would get *"something was deleted,
   we are not saying what"*. Also a live defect in the compliance audit log we ship today.
2. **Some writes fire no hook at all.** `hdb.Audit`'s hooks have pointer receivers and
   GORM only takes `.Addr()` on addressable values, so a struct passed **by value** never
   matches. Confirmed at `job_parameters.go:81`, `:62`, `job.go:207`. Mostly benign here,
   since those are child-table writes the allow-list filters anyway.
3. **V1 create produces two events** (`job_service.go:1418`, `:1425`).

## 11. Open questions

- **Q1** Do we send `ActionByEmail` / `ImpersonatedByEmail` / `Method` to an external
  partner? Recommend publishing a **projection** — which does not modify the struct, so D2
  holds. Needs security sign-off.
- **Q2** Does XMI subscribe with a queue **we** own (meeting language implies yes) or one
  in **their** account (gives them retention/DLQ control)? Decide before I2/I5.
- **Q3** Is there a settings-only update path that does not touch `data_import_jobs`? If
  so it publishes nothing after filtering.
- **Q4** Exact `ObjectType` strings for flows/flow runs (they come from the Go **model
  name**, not the table name).
- **Q5/Q6** XMI latency expectations, unknown-object behaviour, queue retention and DLQ.

## 12. Next steps

**Phase 0 — verify (~0.5 day, THE GATE).** Datadog: do flow-run state transitions produce
`Audit Log:` lines, **including for background workers**? Every hook opens
`if !parsed { return nil }` and needs a ctx attached by `BeginDB`/`BeginTxDB`, so a
background worker may produce **no record at all, silently**. If so, use cases 2–4 are
blocked. Also harvest the real `ObjectType` strings and daily volume.

**Phase 1 — Hank (~3 days).** Config + allow-list filter + **asynchronous** buffered
publisher (drop-not-block) + one-line wiring into the three hooks + single SNS client +
lifecycle + metrics + tests. `AuditLog` untouched.

**Phase 2 — infrastructure (~2 days, other teams).** SNS Standard topic, SQS queue + DLQ,
queue policy, IAM to publish and for XMI to consume, ARN into dyogram/fiddley, empty-ARN
guard.

**Phase 3 — enablement (~0.5 day/service).** forebitt first; **unhygienix next — that is
where flow runs live and what XMI actually needs**, gated on Phase 0.

**Phase 4 — XMI onboarding.** Queue URL, credentials, written schema doc stating the
payload is a *notification* and they must read back.

**Phase 5 — rollout.** Merge disabled → services bump → enable in stage → QE → prod.
Rollback is a config flag; no migration to revert.

**Total ≈ 6–7 engineering days** plus infrastructure lead time and XMI's integration.
