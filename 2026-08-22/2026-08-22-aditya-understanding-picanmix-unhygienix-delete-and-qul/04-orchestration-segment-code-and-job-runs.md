# 04 — Orchestration: who calls what, where `partner_segment_code` is set, and the `job_runs` lifecycle

## The three actors

| Trigger | Schedule | Command | Source |
|---|---|---|---|
| pegleg question runner | **inline**, at end of every CRQ run | `SnowflakeQueryRunner` | `B/pegleg/pegleg-backend/src/main/java/com/habu/pegleg/jobs/SnowflakeQueryRunner.java:232` |
| `question-user-list-syncher` | **every 20 min** (`*/20 * * * *`) | tenansix `QuestionUserListSyncCommand` | `A/cacofonix/habuairflow/dags/picanmix/question_userlist_syncher.py:95,109` |
| `main-question-ul-activation-dag` | **@hourly** | tenansix `QuestionUserListSenderCommand` | `A/cacofonix/habuairflow/dags/picanmix/main_question_userlist_activation_dag.py:55`; child `question_userlist_activation_dag.py:121` |
| `main-question-export-dag` | **@daily** | tenansix `ExportCommand` | `A/cacofonix/habuairflow/dags/picanmix/main_question_export_dag.py:45,50`; child `question_export_dag.py:103` |

## Q: who calls the "this run hasn't been fanned out yet" check?

`A/picanmix/api/server/job.go:2245` `FetchQuestionUserListDetails(crqr_id, partner_account_id, identity_type)`:

```
pegleg  SnowflakeQueryRunner.java:232                    (synchronous, once per question run)
  └─ pegleg  util/Utils.java:26  createQuestionUserListJobs
       └─ zabra  .../grpc/PicanmixClient.java:596  createQuestionUserListJobs
            └─ picanmix  POST /picanmix/question_run/job/activate   (proto/job.proto:1188-1193)
                 └─ picanmix  api/server/job.go:2224  CreateQuestionUserListJobs
                      └─ :2245  the check
```

Not a cron. `CreateQuestionUserListsJobs` (plural, `api/server/job.go:2540`) has **no** HTTP
annotation (`proto/job.proto:1224` is a bare `rpc`) and nothing in these repos calls it — a
batch replay wrapper, reachable only by hand.

## Q: who calls the "this job hasn't been sent yet" check?

`A/picanmix/db/activation.go:596-599`:

```go
checkIfRan := db.Table("job_runs").Select("1").
    Where("job_id = j.id AND source_job_run_id = q.clean_room_question_run_id AND job_status != ?", proto.QUEUED.String()).
    QueryExpr()
...
.Where("NOT EXISTS (?)", checkIfRan)
```

```
cacofonix  main_question_userlist_activation_dag.py:55   schedule='@hourly'
  └─ cacofonix  habuairflow/lib/habu/http/picanmix.py:70  GET /picanmix/activation/question-userlist-jobs
       └─ picanmix  api/server/activation.go:520  FetchQuestionUserListActivationJobs
            └─ picanmix  db/activation.go:596  checkIfRan / NOT EXISTS
```

Both are gated by `isAuthorizedServiceUser` — service-to-service, never user-facing.

**Nothing is "marked false".** There is no boolean. The signal is the **absence** of a
matching `job_runs` row (or the presence of one still `QUEUED`).

## The export side decides elsewhere

`A/picanmix/db/activation.go:382-401` `FetchExportPartners` — the entire query:

```go
db.Table("partners").
   Select("partner_accounts.organization_id, partner_accounts.id as partner_account_id").
   Joins("JOIN partner_accounts ON partners.id = partner_accounts.partner_id").
   Where("partner_accounts.deleted_at IS NULL").
   Where("partners.deleted_at IS NULL").
   Where("partners.type = ?", proto.EXPORTS.String()).
   Where("(partners.deprecated = ? OR (partners.deprecated = ? AND partner_accounts.organization_id IN (?)))", ...)
```

No run state, no `job_runs`, no `NOT EXISTS`. It returns **every live EXPORTS partner
account**, unconditionally, every midnight; "what is new" is decided inside tenansix
`ExportCommand`. Matching decision at `A/picanmix/api/server/job_run.go:121-127`:

```go
} else if job.JobType == proto.EXPORTS.String() {
	_, notFound := db.FetchExportDetailsByJobID(s.DB, in.JobID)
	if notFound { ... }
	// TODO Do we need a source job run id? Do not think so as we are doing exports at the Question level
}
```

Export `job_runs` therefore carry an **empty** `source_job_run_id`.

## CRQ-5 with both a QUL and an export configured — wall clock

| Wall clock | What fires | Code | Effect |
|---|---|---|---|
| 09:00:00 | user runs CRQ-5 | `SnowflakeQueryRunner.java` | Snowflake query starts, `runId = RUN-9` |
| 09:04:10 | results + post-run queries land | `SnowflakeQueryRunner.java:206-229` | CRQ results table populated |
| 09:04:12 | **QUL branch only** | `SnowflakeQueryRunner.java:232` → `Utils.java:26-43` | `POST /picanmix/question_run/job/activate` per QUL |
| 09:04:12 | dedupe + mint | `api/server/job.go:2245` → `:2258` | `jobs J-12` + `question_user_list_details(J-12, RUN-9, QUL-3)` created |
| 09:04:12 | **export branch** | — | **nothing.** pegleg never touches exports. `J-EX` unchanged |
| 09:20:00 | 20-min syncher | `question_userlist_syncher.py:95` → tenansix `QuestionUserListSyncCommand` | creates the audience at Meta, writes back the segment code |
| 10:00:00 | hourly sweep | `main_question_userlist_activation_dag.py:55` → `db/activation.go:574` | J-12 matches → conf `{Adidas, PA-77}` |
| 10:00:10 | sender | `question_userlist_activation_dag.py:121` → tenansix `QuestionUserListSender` | pushes audience; writes `job_runs(job_id=J-12, source_job_run_id=RUN-9)` |
| 11:00:00 | same hourly DAG | `db/activation.go:596-599` `NOT EXISTS` now fails | **J-12 skipped** |
| 00:00:00 next day | `main-question-export-dag` (`@daily`) | `main_question_export_dag.py:45` → `db/activation.go:382` | conf `{Adidas, PA-90}` → tenansix `ExportCommand` writes the files |

Both run. Never in the same act, never on the same clock, and "is there work?" is decided
in SQL inside picanmix for QUL and in Java inside tenansix for exports.

## `job_runs` lifecycle for a QUL job

Yes — QUL job runs do go to `job_runs`, and `source_job_run_id` is the idempotency latch.

| Time | Layer | Code | Effect |
|---|---|---|---|
| T1 | tenansix sender | `B/tenansix/src/main/java/com/habu/activation/jobs/QuestionUserListSender.java:76-81` | `pc.newJobRun(orgId, jobId, job.getCleanRoomQuestionRunId(), …)` — **RUN-9 as sourceJobRunID** |
| T2 | tenansix client | `B/tenansix/src/main/java/com/habu/tenansix/grpc/PicanmixClient.java:94-96` | `builder.setSourceJobRunID(sourceJobRunID)` |
| T3 | picanmix checks | `A/picanmix/api/server/job_run.go:91` | `sourceJobRunID := in.SourceJobRunID` |
| T4 | QUL branch | `A/picanmix/api/server/job_run.go:129-134` | **only validates** the detail row exists; never reassigns → RUN-9 survives |
| T5 | create | `job_run.go:150` → `models.NewJobRunForJobID` (`models/job.go:120-131`) | `job_runs` row, `job_status = QUEUED` |
| T6 | start | `PicanmixClient.java:107` `startJobRun` → `api/server/job_run.go:180` | `job_status = RUNNING` |
| T7 | end | `QuestionUserListSender.java:129` `endJobRun` | `COMPLETE` / `FAILED` + `num_records_sent` |
| T8 | next hourly sweep | `db/activation.go:596-599` | J-12 no longer matches → skipped |

**Status when it has never been called: there is no row.** Not `FAILED`, not any status —
absent. `NOT EXISTS` is satisfied by absence.

### Why a QUEUED row produces a *second* `job_runs` row

The predicate is `job_status != QUEUED`. A `QUEUED` row does **not** satisfy the inner
`EXISTS`, so `NOT EXISTS` remains true and the job is returned again.

That is deliberate: `QUEUED` means *created but never started* — the send definitively did
not happen, so it must be retried. Treating `QUEUED` as "already ran" would silently drop
the audience forever.

The cost is that the retry **creates a new row** rather than reusing the orphan, because
tenansix calls V1 `createJobRun` (`PicanmixClient.java:99`). `CreateJobRunV2`
(`A/picanmix/api/server/job_run.go:160-178`) does exactly the right dedupe —
`FetchJobRunByJobIDSourceID` first — but has a **variable-shadowing bug** at `:171`
(`jobRun := models.NewJobRunForJobID(...)` inside the `if notFound` block), so the outer
`jobRun` stays zero-valued and `:176` returns an empty `JobRun`. tenansix
`PicanmixClient.java:100-104` requires `response.getJobRun().getStatus() == QUEUED` to
return an ID, so V2 would return `null` — which plausibly explains why V1 is still in use.

Window: `newJobRun` does create-then-start back to back
(`PicanmixClient.java:74-78`), so T5→T6 is milliseconds. But if the pod dies in that gap,
the row sits `QUEUED` forever and each subsequent hourly sweep adds another.

## Where `partner_segment_code` is set

There are **two** columns with this name and two different writers.

### 1. Config level — `question_user_lists.partner_segment_code`

`A/picanmix/db/activation.go:673-692` `SetQuestionUserListPartnerCodes`:

```go
tx.Model(&models.QuestionUserList{}).
   Scopes(CleanRoomQuestionIDScope(obj.CleanRoomQuestionID), IDScope(obj.JobID)).
   Updates(map[string]interface{}{"partner_segment_code": obj.PartnerSegmentCode})
```

Producer chain:

```
cacofonix question_userlist_syncher.py:95        every 20 min
 └─ tenansix QuestionUserListSyncCommand:24  -> QuestionUserListSyncher.syncUserLists()  (:84)
      └─ PicanmixClient.java:452  fetchPartnerJobsForQuestionUserListSync()
           └─ picanmix api/server/activation.go:87  -> db.FetchQuestionJobsForSegmentSync
                └─ db/activation.go:201-221   reads question_user_lists
                     WHERE partner_segment_code IS NULL OR LENGTH(...) = 0     (:220)
      └─ QuestionUserListSyncher.java:153  activationPartner.createUserList(hul)  -> real audience at Meta/LinkedIn/...
      └─ PicanmixClient.java:441  setQuestionUserListPartnerCodes  -> the UPDATE above
```

`db/activation.go:220` is the gate: only QULs whose code is still empty are synced.

### 2. Run level — `question_user_list_details.partner_segment_code`

Set **at INSERT**, `A/picanmix/db/job.go:735-737`: `listDetail.PartnerSegmentCode` is copied
from the `CreateQuestionUserListJobs` request, which pegleg populates from
`ul.getPartnerSegmentCode()` — i.e. the config row's value at run time.

The function `SetQuestionUserListDetailsPartnerCodes`
(`A/picanmix/db/activation.go:108-126`, handler `api/server/activation.go:432-449`) is the
run-level **back-fill**:

```go
tx.Model(&models.QuestionUserListDetails{}).
   Scopes(QuestionUserListDetailScope(obj.CleanRoomID, obj.CleanRoomQuestionID, obj.CleanRoomQuestionRunID),
          JobIDScope(obj.JobID)).
   Updates(map[string]interface{}{"partner_segment_code": obj.PartnerSegmentCode})
```

`QuestionUserListDetailScope` (`A/picanmix/db/scopes.go:174-184`) matches on
`clean_room_id`, `clean_room_question_id`, `clean_room_question_run_id`; `JobIDScope` adds
`job_id`. Four predicates ⇒ one specific run's detail row for one job. It is a plain
`UPDATE` of a single column, one row per iteration, all inside one transaction
(`BeginTxDB` … `tx.Commit()`), rolled back wholesale on any error.

**Which branch is taken** — tenansix `PicanmixClient.java:439-446`:

```java
if (job.getCleanRoomQuestionRunId() == null || job.getCleanRoomQuestionRunId().length() == 0) {
    ... setQuestionUserListPartnerCodes(...)          // config table
} else {
    ... setQuestionUserListDetailsPartnerCodes(...)   // details table
}
```

And `cleanRoomQuestionRunId` is only set when the proto carries it
(`PicanmixClient.java:511-513`). On the syncher path it never does:
`A/picanmix/db/activation.go:249-257` builds `models.PartnerQuestionUserListJob` with
`JobID, CleanRoomID, CleanRoomQuestionID, IdentityType, CleanRoomQuestionName, Price` —
**no `CleanRoomQuestionRunID`** — and the SELECT at `:202-215` never asks for it.

⇒ **The `_Details` back-fill has no live producer from the 20-minute syncher.** It is
reachable only by a caller that supplies a run id, and none was found in these repos.

Note also `db/activation.go:205`: `question_user_lists.id as job_id`. On this path "job_id"
on the wire is the **QUL id**, not a `jobs.id`.
