# 06 — Meeting Preparation

## 1. Open with this, in under a minute

> A Data Connection lives in two tables, so creating one is five row writes, not
> one. Anything that watches rows sees five things happen and has to guess they were
> one action. The function that handled the request already knows it was one action,
> already has the before and after, and already knows who did it — because it needed
> all of that to build its response. So we add one line there and send one message.
>
> The alternative is watching the rows. That gives us five messages via one API and
> ten via another, for the same button click, with no field values in any of them.

Then go straight to the delete slide, because it needs no setup:

```go
forebitt/db/job.go:185
tx.Scopes(IDScope(id)).Delete(&models.DataImportJob{})
```

The ID is in the WHERE clause; the object passed in is empty. So the automatic
record reads:

```json
{ "ObjectType": "DataImportJob", "ObjectID": "", "Action": "DELETE" }
```

*"Somebody deleted a data connection. We are not saying which one."*

---

## 2. Likely questions, with answers

### Q. "Why not just use the Hank hooks? They are already everywhere."

Because they fire per **row**, and a Data Connection is not a row — it is a job row
plus one row per setting. One create is 5 hook firings via the V2 route and 10 via
the V1 route, because the V1 route saves the whole thing twice
(`job_service.go:1418` then `:1425`). And the record has no field values in it at
all — `hank/db/audit.go`'s `AuditLog` carries object type, ID, name, action and
actor, and nothing else.

### Q. "Then add the values to the hook."

We can, and it would genuinely improve the audit log. It does not fix this problem,
because the remaining issues are not about the payload:

- We still cannot tell **when all five records have arrived**. No count, no
  end-of-transaction marker. Only a timer, which turns a slow message into a *wrong*
  event.
- We still cannot tell **which of the five rows is the main object**. That is
  forebitt's knowledge, so we would copy it into orinix and it would drift.
- Reading the old value means **one extra SELECT before every UPDATE in five
  services**.
- `primage/models/models.go:219-226` — the `Credential` table has a `Value` column
  and uses the same audit embed. Logging values would write credentials into our
  logs. That needs a field-by-field allow-list across ~91 tables first.

### Q. "What about change data capture?"

*Take this one seriously — it is the strongest alternative.* It solves two things
the hooks do not: it has the old and new values for free, and it knows which changes
shared a transaction, so it can tell us when the set is complete.

It fails on **who did it**. The database's change log has no user, no email, no
request — it sees "row changed," not "Aditya changed it," and both this product and
the audit log must name the actor. The standard workaround is to write the user into
a column on every table first, which is application work everywhere — so the "no
code changes" advantage disappears.

Three more: it still cannot say which row is the main object; **our column names
would become XMI's contract**, so renaming a column breaks a partner; and it holds a
replication slot open on production Postgres, which can fill the disk and stop the
database if the consumer stalls.

*One-liner:* it fixes the mechanical problems and not the meaning problems.

### Q. "Why not just tell XMI something changed and let them call us back?"

That is the option I would take seriously if we are short on time, and it is worth
being precise about it. Three levels:

- **Level 0** — "X was updated." This re-creates polling with an extra step, and
  DV-15621 says polling is the problem we are solving. Also XMI cannot distinguish
  a rename from a stage change, so they react to everything.
- **Level 1** — "X is now at stage CONFIGURATION_COMPLETE." **This genuinely
  satisfies all four of XMI's M1 use cases**, because all four act on the new state
  and none asks what it was before.
- **Level 2** — full before and after.

My proposal is Level 1 for the state-transition events and Level 2 for object
create/update/delete. Same code locations either way; the difference is one database
read.

Note this also rules out the hooks even for Level 1: the record carries `Action`
(CREATE/UPDATE/DELETE), not `Status`. It can say "the run was updated." It cannot
say "the run completed."

### Q. "Seven code sites for one object type. What is that across five types?"

Fair, and I do not want to hand-wave it. It is bounded and mechanical — the same
block, different fields — but it is real. Two things reduce it: if Doors B and C turn
out to be legacy we instrument 3 sites rather than 7, and Option 5 (collect events
during the request, publish once at the end) centralises the publish so per-site
code shrinks to one append call. I would like your view on whether to go straight to
Option 5.

### Q. "What if someone adds a new write path and forgets the line?"

Then that path emits nothing, and the automatic approaches would have caught it.
**This is the one genuine advantage they have.** Three mitigations: all the write
paths live in two files; we can add a test that fails when a handler writes without
emitting; and the failure mode is *silence*, which monitoring can detect — much
better than the wrong-event a timer-based assembler produces.

### Q. "How do you know you have not lost events?"

Today, we would not. The publish error is logged and swallowed
(`job_service.go:1602-1605`), and it happens after the commit — so we can fail to
announce something that happened, though we can never announce something that did
not. **This is the weakest part of the proposal.** Minimum fix is a failure counter
and an alert. The proper fix is a transactional outbox, which sits at the same line
and is real scope if you want the guarantee.

### Q. "Why a new SNS topic instead of the existing one?"

Because the existing one would deliver our messages to pegleg. `pegleg.tf:17` — its
subscription filter already matches `"dataImportJob"`, so publishing with the
natural attribute value lands in pegleg's queue. Avoiding that would mean editing
pegleg's filter policy, which is the thing we promised not to touch.

Also worth knowing: the existing topic is FIFO, and its ordering guarantee is weaker
than people assume — `hank/aws/sns/service.go:48` sets the message group to the
request ID, and FIFO only orders within a group. So two updates to the same object
from different requests are already unordered.

### Q. "Do we need a new service at all?"

Yes, and this is independent of today's decision. Whatever produces the events,
something has to store them, serve the cursor-based pull API, and deliver to XMI by
webhook and Pub/Sub. That is orinix. Publishing straight from each producer to XMI's
Pub/Sub would mean Google Cloud credentials in 10+ repos, a code change in every
producer to add a second consumer, and no replay or history.

---

## 3. Counter-arguments I should be ready for

| Their argument | My response |
|---|---|
| "You are hand-writing what the framework does automatically." | The framework works at the row level. The contract is at the resource level. The translation between them only exists in the service layer. |
| "This will drift as the code changes." | True, and I would rather have silence I can monitor than a timer that produces wrong events. |
| "Start thin and iterate." | Agreed for the state events. Adding `changedFields` later is additive and safe; going the other way is not. |
| "The audit log should be one system, not two." | The audit log answers "who touched which row." XMI asks "what changed on this resource." Same code site, different questions. Hooks are right for the first. |
| "Seven sites is too many." | Verify the doors first; possibly three. And Option 5 shrinks each site to one line. |
| "Just have XMI poll." | DV-15621 records polling as the problem being solved. |

---

## 4. Where I should be careful

1. **Do not overstate the cost of the alternatives.** Change data capture is
   genuinely strong. If I dismiss it glibly and Anil knows it well, I lose
   credibility for the rest of the meeting.
2. **Do not claim performance is negligible.** I have not measured the p99 of the
   affected handlers. Say "one indexed read on a path that already does three or
   four" — that is what I can defend.
3. **Do not present the `Stage` empty-value bug as if I am fixing it.** I am
   flagging it. Fixing it is a separate ticket.
4. **Do not assert the requestId correlation is impossible.** It is *insufficient*,
   which is a different and stronger claim. Overstating it invites a correction.
5. **Do not assume Doors B and C are dead.** I checked the routes exist; I have not
   checked traffic. Say so.
6. **Do not promise at-least-once.** Today it is at-most-once on the producer side.
   Be straight about it and offer the outbox as the fix.

---

## 5. Terminology to use, and to avoid

| Say this | Not this | Why |
|---|---|---|
| "one business action = five row writes" | "aggregate/entity boundary mismatch" | Concrete and checkable |
| "the record has no field values" | "the payload is insufficiently rich" | States the fact |
| "we cannot tell when all five have arrived" | "completeness is undecidable" | Plainer, same point |
| "our column names would become XMI's contract" | "schema coupling / information leakage" | Says the consequence |
| "the delete record does not say which object" | "identity is not propagated" | Anyone can verify it in one line |
| "at-most-once today; loss, never a phantom" | "eventual consistency concerns" | Precise about which failure |
| "current state" / "before and after" | "thin/fat events" | Says what is in the message |

Avoid framework names and design-pattern vocabulary unless asked. Every claim
should be checkable in the repository in under a minute.

---

## 6. Common mistakes to avoid in the room

- Conflating **Hank's audit hooks** with **Hank's event publisher**. They are
  separate systems that never call each other, and the publisher is *already* the
  service-layer approach with a thin payload. Getting this wrong makes the whole
  argument sound confused.
- Saying "Hank already emits events on every change." It emits **log lines** on
  every change, and SNS messages only where someone wrote a publish call.
- Presenting the 5-versus-10 number without saying *why* it is 10 — the draft-then-final
  double save at `job_service.go:1418` and `:1425`. The number without the mechanism
  sounds like an exaggeration.
- Leading with CloudEvents, schema versions or replay. Lead with the two tables.
- Answering "how long will this take" before the door question is resolved.

---

## 7. If the meeting goes badly, the fallback position

If Anil is not convinced, the smallest thing worth agreeing to:

**Instrument only `CreateDataConnectionV2`, `UpdateDataConnectionV2` and
`DeleteImportJob`, at Level 1, behind an empty-topic-ARN guard.** That is three
blocks of code, no security review, no new infrastructure until the topic exists,
and it proves the end-to-end path with XMI. Everything else — the V1 doors, Level 2
payloads, the audit tier — becomes a second conversation with real data behind it.

Being able to name a small first step is usually what unblocks an approval.

---

## 8. Talking points, in a structure I can read off

### Talking point 1 — Where the event is produced

- **Problem:** a Data Connection is stored in two tables, so one user action is five
  row writes. Any row-level mechanism sees five separate things and has to guess
  they were one action.
- **Why this design:** the handler already holds the complete object, the before and
  after states, and the identity of the user — because it needs all three to build
  its response. One added line reuses what is already there.
- **Trade-offs:** 7 code sites instead of 0; a future write path could be forgotten.
  In exchange: exactly one event per action, on every route, with values and actor.
- **Alternatives considered:** Hank's GORM hooks; change data capture; database
  triggers; a request-scoped event buffer.
- **Why rejected:** hooks have the actor but no values, and cannot tell when all five
  records have arrived. Change capture has the values but not the actor, and would
  make our column names a partner's contract. Triggers run inside the transaction, so
  a bug in PL/pgSQL breaks production writes. The buffer is a reasonable variant, not
  a different answer — worth adopting if the site count grows.
- **Remaining risks:** drift between the emit block and the handler on refactor; the
  suppression flag is correctness-critical and easy to forget.
- **Future improvements:** move to the request-scoped buffer once there are more than
  a handful of sites; add a test that fails when a write path does not emit.

### Talking point 2 — How much goes in the message

- **Problem:** too little and XMI has to call us back, which is polling with extra
  steps. Too much and we are exporting field values to a partner and need a security
  review.
- **Why this design:** current state for the state-transition events, full before and
  after for object create/update/delete. All four of XMI's M1 use cases act on the
  new state and none asks what it was before — so the richer payload is only spent
  where "what changed" is genuinely the question.
- **Trade-offs:** the security review applies only to the create/update/delete
  events; the state events stay trivial and ship sooner.
- **Alternatives considered:** action-only everywhere; full diffs everywhere.
- **Why rejected:** action-only cannot say *"the run completed"*, only *"the run was
  updated"* — which is precisely the use case being asked for. Full diffs everywhere
  spends the review cost where nobody consumes the result.
- **Remaining risks:** if a customer-facing history view is on the roadmap, the state
  events will need upgrading; adding fields later is safe, so this is recoverable.
- **Future improvements:** upgrade to full diffs when Josh's audit tier lands, since
  it needs them anyway.

### Talking point 3 — Reliability

- **Problem:** the publish happens after the commit and the error is swallowed, so an
  event can be lost. We are building an observability product on a best-effort
  transport.
- **Why this design (for M1):** it matches the existing platform pattern, and the
  failure mode is loss only — never an event for something that did not happen.
- **Trade-offs:** we cannot promise at-least-once end to end, and today we would not
  even know how many we lost.
- **Alternatives considered:** in-process retry; transactional outbox.
- **Why rejected for now:** retry narrows the window without closing it; the outbox
  closes it properly but is real M1 scope and we would rather surface that as a
  decision than absorb it silently.
- **Remaining risks:** silent loss, unmeasured.
- **Future improvements:** the minimum is a failure counter and an alert. The proper
  fix is the outbox, and it goes at exactly the line the publish is on today — so
  choosing best-effort now does not make it harder later.

### Talking point 4 — Why a separate topic and a separate service

- **Problem:** reusing the existing topic would deliver our messages to consumers who
  did not ask for them.
- **Why this design:** `pegleg.tf:17`'s filter already matches `"dataImportJob"`, so
  our messages would land in pegleg's queue. A new Standard topic gives isolation by
  construction. And the middle service is what makes replay, history and the pull API
  possible.
- **Trade-offs:** new Terraform, new IAM, new config in three places.
- **Alternatives considered:** reuse the FIFO topic; publish directly to XMI's Google
  Cloud Pub/Sub from each producer.
- **Why rejected:** the first requires editing pegleg's filter policy — the thing we
  promised not to touch — and inherits a 300 msg/s ceiling whose ordering guarantee
  turns out to be per-request anyway. The second would put Google Cloud credentials in
  10+ repos and make adding a second consumer a code change everywhere instead of a
  config row.
- **Remaining risks:** infrastructure lead time; mitigated by the empty-ARN guard so
  code can merge first.
- **Future improvements:** per-consumer delivery queues are already designed; adding
  Microsoft or SafeHaven should stay a configuration change.

---

**Next:** [07-questions-to-ask.md](07-questions-to-ask.md)
