# 05 — The Review I Would Give If I Were the Architect

Written deliberately against my own proposal. If I can answer these, the meeting is
easy. If I cannot, I would rather find out here.

---

## 1. Assumptions I would challenge

### A1. "The information is free at line 378"

**Challenge:** free *today*. What guarantees it stays free? If someone refactors
`CreateDataConnectionV2` so the response is built lazily, or moves the parameter
loop, the emit block silently loses data.

**Honest answer:** nothing guarantees it. The mitigation is that the emit reads the
same variables the response does, so a refactor that breaks the event also breaks
the response, which tests already cover. That is a real coupling, and it is a
weaker guarantee than "the database told us."

### A2. "One message per user action"

**Challenge:** you have three doors, two of which nest, and you are proposing a
context flag to prevent double-emitting. That flag is now load-bearing correctness
logic. What happens when someone adds a fourth door, or calls Door C from a new
place without setting the flag?

**Honest answer:** they get two events, and `UNIQUE(idempotency_key)` will **not**
save us, because they would be two distinct events with distinct IDs, not
duplicates of one. The real mitigation is Option 5 from `03` (collect during the
request, flush once at the end), which makes double-emission structurally
impossible. If this concern is weighted heavily, we should go straight to Option 5
rather than the flag.

### A3. "All four of XMI's M1 use cases only need the new state"

**Challenge:** that is today's requirement list, gathered in a meeting. What happens
when XMI asks "show my users who changed this connection and what they changed"?
Level 1 cannot answer it, and by then they have built against Level 1.

**Honest answer:** correct, and this is why my recommendation is Level 2 for
object create/update/delete rather than Level 1 everywhere. Level 1 only for the
state-transition events where the current state genuinely is the whole question.

### A4. "The extra cost is one database read"

**Challenge:** one read on the *update* path *for data connections*. What is the
number across five object types and all their write paths? Has anyone measured the
p99 of `UpdateDataConnectionV2` today?

**Honest answer:** no, we have not measured it. **[UNVERIFIED]** and I should not
claim the cost is negligible without a number. What I can say is it is one indexed
lookup by two columns on a path that already performs three or four reads.

### A5. "Fire-and-forget is fine for M1"

**Challenge:** you are building an *observability* product whose value proposition is
"you will know what happened," and shipping it on a transport that silently drops
messages. How will you even know how many you dropped?

**Honest answer:** this is the weakest part of the proposal. We would not know,
today, because the error is logged and swallowed. The minimum acceptable position is
a metric and an alert on publish failures. If that is not enough, the outbox is the
answer and it is real M1 scope.

---

## 2. Questions I would ask

### On correctness

1. What happens when a request is **retried by the client**? Do we emit two events
   for one logical change? (Answer: yes, with different IDs — the idempotency key
   does not help across separate requests. Worth thinking about.)
2. What is the event for a **no-op update** where the payload is identical to the
   current state? Empty diff, no event, or a "touched" event? (Open: `08` item.)
3. You are diffing settings by `(ImportDataSourceParameterID, Name)`. What happens
   if two settings share a name under different source-parameter IDs? Is that pair
   actually unique?
4. Soft delete: you send `DELETED`, but the row still exists and something could
   in principle undelete it. Do you emit a `CREATED` then? What does XMI do with a
   resurrection?
5. `dataConnections_v2.go:337-341` — you have found that `Stage` can land empty.
   You are proposing to emit `Stage` in the event. Are you shipping a known-wrong
   value to a partner?

### On the design

6. Why is this in forebitt's code rather than a shared library, given unhygineix and
   picanmix will need the same thing? What stops three divergent implementations?
7. You are asking me to approve instrumenting 7 sites for **one** object type. What
   is the number for all five object types in `object_events`? Is that 35 sites?
8. If the answer to "who calls Door B and Door C" is "nobody, they are legacy," why
   are we instrumenting them at all rather than deleting them?

### On operations

9. What is the expected message volume per day, and what does that cost on SNS,
   SQS and Postgres storage in `object_events`?
10. `object_events` has a hard 90-day delete in its DDL. What happens to XMI's
    replay window on day 91?
11. How do we know the pipeline is healthy? What is the alert when forebitt writes
    a row and no event appears?

### On the partner contract

12. Is the event schema versioned, and how do we add a field without breaking XMI?
13. Who owns the schema document, and where does it live so XMI can read it?
14. What is XMI's behaviour when they receive an event for an object they have never
    seen — do they backfill, or drop it?

---

## 3. Edge cases that would concern me

| # | Edge case | Status |
|---|---|---|
| E1 | Door B's draft-then-final double save produces `CREATED` then `UPDATED` for one user create | **Real.** With Option 1 we emit once from the outer handler, so it is handled — but only because of the suppression flag |
| E2 | A background worker changes a flow run's state with no auth claims in context | **[UNVERIFIED], high risk.** Breaks Option 2 entirely; for Option 1 we must confirm `authUser` is available on those paths or use a system actor |
| E3 | Settings containing customer-identifying data (`DataLocation`, `SampleFilePath`, `TableName`) travelling to a partner | **Real.** Needs an explicit field allow-list, which Option 1 gives us by construction |
| E4 | A connection used by several cleanrooms, when the event format is keyed by cleanroom | **Real and unresolved** — see `08` item D2 |
| E5 | `object_events` reaching the 90-day boundary mid-integration | Known; the two-tier archive proposal addresses it, not yet built |
| E6 | Two concurrent updates to the same connection producing out-of-order events | Mitigated by producer-stamped `event_time`; XMI's consumers are last-state-wins |
| E7 | SNS message size limit (256 KB) with a large settings set | Unlikely; the fallback is publishing a reference instead of the body |
| E8 | An event emitted for a transaction that later gets rolled back | **Cannot happen** — the publish is strictly after `COMMIT` |

---

## 4. Future requirements I would want considered now

1. **A second and third consumer.** Microsoft and SafeHaven are named in the design
   doc. Does adding one require a code change anywhere? (With orinix in the middle:
   no, it is a config row. This is the strongest argument against publishing
   directly to a consumer's Pub/Sub from each producer.)
2. **Read-access auditing** (Jon's separate ask). Nothing emits on reads today. Does
   the chosen mechanism extend to read paths? Option 1 does — a read handler can
   emit too. Options 2, 3 and 4 **cannot**, because reads do not write rows.
   *This is a strong and under-used argument for Option 1.*
3. **Cross-service objects.** A Dataset depends on a DataImportJob (forebitt) which
   depends on a Credential (primage). Three services, three databases. Any
   database-level mechanism cannot span them; the service layer can.
4. **Long retention for audit.** Multi-year compliance tiers versus a 90-day live
   table. Already designed as hot + cold tiers; not yet built.
5. **Customer-facing history UI.** If this is on the roadmap, Level 1 payloads
   cannot support it and the decision should be made with that in mind.

---

## 5. Technical debt this creates or reveals

**Creates:**

| Debt | Severity | Note |
|---|---|---|
| Emit blocks duplicated across 7 sites | Low | Mechanical, reviewable, in two files |
| The suppression flag is correctness-critical but easy to forget | **Medium** | Option 5 removes it entirely |
| Fire-and-forget publish with no metric | **Medium** | Fix with a counter and alert at minimum |
| Event schema defined in forebitt, will need sharing | Low-Medium | Decide the contract home now (`08` item D5) |

**Reveals (pre-existing, worth raising separately):**

| Finding | Where |
|---|---|
| Delete audit records carry an empty `ObjectID` | `forebitt/db/job.go:185` + `hank/db/audit.go` — **our existing audit log cannot say which connection was deleted** |
| Settings are re-keyed with a new UUID on every save | `job_parameters.go:150` — makes any ID-based history impossible |
| A phantom DELETE fires on every create | `job_parameters.go:121` runs unconditionally |
| `Stage` fallback is dead code | `dataConnections_v2.go:337-341` |
| `UpdateImportJobStage` writes `Status`, not `Stage` | `job_service.go:1814` — may be intentional, may be a bug |
| Door B saves the whole connection twice | `job_service.go:1418` + `:1425` |

The first one is worth a ticket on its own merits, regardless of orinix.

---

## 6. What feels over-engineered

- **Instrumenting all three doors before confirming they are all in use.** If Doors
  B and C are legacy, this is 4 wasted sites and a suppression flag we may not need.
  Verify first.
- **A full `{from, to}` diff for the state-transition events.** XMI does not use the
  `from` side for flow runs. Level 1 there is not laziness, it is correct sizing.
- **CloudEvents' full envelope** for internal traffic. Justified by the external
  contract, but it is more ceremony than an internal message needs.

## 7. What feels under-engineered

- **Reliability.** Fire-and-forget on an observability product, with no metric on
  publish failure. This is the gap I would push hardest on if I were reviewing.
- **The cleanroom-versus-organisation scoping question.** It is unresolved and it
  determines the primary query key. Building before deciding it is the riskiest
  thing on the list.
- **No end-to-end health check.** Nothing today would tell us that forebitt wrote a
  row and no event arrived.
- **Schema ownership and versioning** for an external partner contract is not
  written down anywhere yet.
- **No measurement.** We are asserting the cost is low without a p99 number for the
  affected handlers.

---

**Next:** [06-meeting-preparation.md](06-meeting-preparation.md)
