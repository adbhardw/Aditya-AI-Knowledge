# 05 — Findings and suspected bugs

All findings were read from source in this session. None were reproduced at runtime, and
none were confirmed with the owning teams — treat every one as **needs confirmation before
action**. Severity is this analysis's judgement, not a triage decision.

| # | Severity | Where | Finding |
|---|---|---|---|
| F1 | High | `A/picanmix/db/job.go:895-903` | `SoftDeleteJobsByQULID` is over-broad — deletes other partners' jobs on the same question |
| F2 | High | `A/picanmix/db/activation.go:249-257` + `:220` | `SetQuestionUserListDetailsPartnerCodes` has no live producer; first-run audiences can be stranded |
| F3 | Medium | `A/unhygienix/db/cleanroom_partner.go:400,437` | `HardDeleteCleanRoomPartner` leaves `clean_room_users` and `datasets` soft-deleted |
| F4 | Medium | `A/unhygienix/api/server/cleanroom_partner.go:454-492` | `DeleteCleanRoomPartner` performs no authorization check |
| F5 | Medium | `A/picanmix/api/server/job_run.go:171` | `CreateJobRunV2` shadows `jobRun`, returns an empty response on the create path |
| F6 | Low/Medium | `A/picanmix/api/server/partner_account.go:710-730` | `DeletePartnerAccount` spans four separate transactions with no sweeper |
| F7 | Low | `A/picanmix/db/job.go:788-800`, `api/server/job.go:2523-2534` | `price` is never written on the QUL path — always `0.0` |
| F8 | Low | `A/unhygienix/db/cleanroom_partner.go:422-431, 445-455` | The flows-node-access delete loop is written twice |

---

## F1 — `SoftDeleteJobsByQULID` matches by question, not by QUL

`A/picanmix/db/job.go:895-903`:

```go
err := db.Table("question_user_list_details").Where("clean_room_question_id = (?)",
    db.Select("clean_room_question_id").Model(&models.QuestionUserList{}).
        Scopes(IDScope(qulID)).QueryExpr()).
    Scan(&questionListDetails).Error
```

It resolves `QUL-3` → its `clean_room_question_id` (CRQ-5), then selects **every** detail
row for CRQ-5 — ignoring `question_user_list_details.question_user_list_id`, which exists at
`A/picanmix/models/job.go:114`.

**Failure scenario.** Adidas has `QUL-3 → PA-77` (Meta) and `QUL-4 → PA-88` (LinkedIn), both
on CRQ-5. Deleting partner account PA-77 calls `DeletePartnerAccount`
(`api/server/partner_account.go:710`) → `SoftDeleteJobsByQULID(QUL-3)` → returns detail rows
for **both** QULs → soft-deletes PA-88's activation jobs too. LinkedIn activation silently
stops with no error surfaced.

**Suggested fix.** Add `question_user_list_id = ?` to the predicate.

**Ordering note (currently correct, fragile).** The sub-select uses
`.Model(&models.QuestionUserList{})`, so it inherits `deleted_at IS NULL`.
`DeletePartnerAccount` calls `SoftDeleteJobsByQULID` at `:710` **before**
`SoftDeleteQuestionUserListByID` at `:717`. Swapping those two lines makes the sub-select
return nothing and no jobs get deleted at all.

---

## F2 — the run-level segment-code back-fill is unreachable

`SetQuestionUserListDetailsPartnerCodes` (`A/picanmix/db/activation.go:108-126`) writes
`question_user_list_details.partner_segment_code`. tenansix reaches it only when
`job.getCleanRoomQuestionRunId()` is non-empty (`B/tenansix/.../PicanmixClient.java:439-446`),
which requires the proto to carry `CleanRoomQuestionRunID`
(`PicanmixClient.java:511-513`).

`A/picanmix/db/activation.go:249-257` builds `models.PartnerQuestionUserListJob` **without**
`CleanRoomQuestionRunID`, and the SELECT at `:202-215` never requests it. So the 20-minute
syncher always takes the config-table branch.

**Failure scenario.** A QUL is created and its question runs *before* the syncher has ever
created the audience at the partner. `question_user_lists.partner_segment_code` is empty, so
`db/job.go:735-737` writes an empty code into that run's detail row. The hourly sender gates
on `q.partner_segment_code IS NOT NULL AND LENGTH(q.partner_segment_code) > 0`
(`A/picanmix/db/activation.go:605`), so **that run's detail row is excluded forever**. The
syncher then fills the config row, and the *next* question run gets a good detail row — so
the first run's audience is silently never sent, with no error anywhere.

**Two candidate fixes** (needs the owning team's call): populate `CleanRoomQuestionRunID` in
`db/activation.go:249-257` so the back-fill becomes reachable, or have the sender's query
fall back to `question_user_lists.partner_segment_code` when the detail row's is empty.

---

## F3 — "HardDelete" leaves permission-bearing rows soft-deleted

`A/unhygienix/db/cleanroom_partner.go:352-463` sprinkles `Unscoped()` per statement
(`:358`, `:363`, `:373`, `:422`, `:445`) but omits it at `:400` (`clean_room_users`) and
`:437` (`datasets`). `clean_room_users` is precisely the row class the hard delete exists to
eliminate — see `01-soft-vs-hard-delete.md`, "First principles". The leak surface the hard
delete was meant to close stays half-open, protected only by every reader remembering
`deleted_at IS NULL`.

---

## F4 — no authorization on `DeleteCleanRoomPartner`

`A/unhygienix/api/server/cleanroom_partner.go:454-492` goes from `GetCleanRoom` (`:459`)
straight to `HardDeleteCleanRoomPartner` (`:471`) with no
`isUserAuthorizedWriteV2` / `cleanRoomUserAuthorizationCheck` equivalent — compare picanmix
`api/server/partner_account.go:659`. Additionally `:485` dereferences `crp.ID` after the row
was hard-deleted at `:471`.

---

## F5 — `CreateJobRunV2` variable shadowing

`A/picanmix/api/server/job_run.go:160-178`:

```go
jobRun, notFound := db.FetchJobRunByJobIDSourceID(s.DB, in.JobID, sourceJobRunID)
if notFound {
    jobRun := models.NewJobRunForJobID(...)   // :171 shadows the outer jobRun
    err = db.CreateJobRun(ctx, s.DB, jobRun)
    ...
}
return &proto.CreateJobRun_Response{JobRun: jobRun.ToProto()}, nil   // outer = zero value
```

On the create path the response carries an empty `JobRun`. tenansix
`B/tenansix/.../PicanmixClient.java:100-104` requires
`response.getJobRun().getStatus() == QUEUED` before returning an ID, so V2 would return
`null` — plausibly why tenansix still calls V1 `createJobRun` at `:99`.

Consequence of using V1: a `job_runs` row stuck in `QUEUED` (process died between
`createJobRun` and `startJobRun`) is re-fetched by every hourly sweep, because the latch
predicate is `job_status != QUEUED` (`A/picanmix/db/activation.go:598`), and each sweep adds
another orphan row. Fixing the shadowing would let tenansix move to V2 and reuse the orphan.

---

## F6 — `DeletePartnerAccount` is four transactions

`A/picanmix/api/server/partner_account.go:710` (`SoftDeleteJobsByQULID`), `:717`
(`SoftDeleteQuestionUserListByID`), `:724` (`UpdateProvisionedPartner`), `:730`
(`SoftDeletePartnerAccount`) each call `hdb.BeginTxDB` … `Commit` independently. A crash
between any two leaves a documented intermediate state (see the T7–T10 table in
`01-soft-vs-hard-delete.md`) and nothing reconciles it. Same class as the
collaborator-removal / export-job gap.

---

## F7 — `price` never leaves zero on the QUL path

- `A/picanmix/db/job.go:788-800` `CreateQuestionUserList` copies eight fields; `Price` is
  **not** among them.
- `A/picanmix/api/server/job.go:2523-2534` `FetchQuestionUserList` builds the proto without
  `Price`, though `A/picanmix/proto/domain.proto:422` defines `float price = 12`.
- Grepping every `Price` write in `api/server/`, `db/`, `models/` finds exactly one:
  `A/picanmix/db/job.go:738`, `listDetail.Price = price`, fed from `in.Price` ← pegleg's
  `ul.getPrice()` ← the un-populated proto field.
- `A/picanmix/models/job.go:210` `QuestionUserList.Price` has no assignment anywhere.

So `question_user_list_details.price` is always `0`, yet it *is* read back
(`A/picanmix/db/activation.go:197,256`) and shipped to tenansix. The plumbing is complete
end to end; only the source is missing. Two lines would fix it, **but** something downstream
may already compensate for the zero — confirm with whoever owns activation billing first.

---

## F8 — duplicated flows-node-access loop

`A/unhygienix/db/cleanroom_partner.go:422-431` and `:445-455` iterate `clean_room_flows` for
the same clean room and `Unscoped().Delete(&models.FlowsNodeAccess{})` with the same scopes.
Harmless (idempotent), but the second pass is dead work and both loops `return nil` on error
(swallowing it) rather than `return err`.
