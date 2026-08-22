# 07 — The export path, at the same depth as QUL

Companion to [`03`](03-question-user-list-vs-export-job-model.md) and
[`04`](04-orchestration-segment-code-and-job-runs.md). Roots: **A** =
`/Users/adbhar/Documents/project-sprint-understanding-1/`, **B** = `/Users/adbhar/Documents/GitHub/`.

## Config time — `CreateExportJobs`

`A/picanmix/api/server/job.go:635-782`. Walk of the guards, in order:

| Step | Line | What it does |
|---|---|---|
| 1 | `:641` | `isUserAuthorizedWriteV2` — on failure calls `setCRQAssetFalse` **before** returning |
| 2 | `:649` | `fetchUserIDForJobCreation` — handles both service users and regular users |
| 3 | `:656` | empty `PartnerAccountIDs` ⇒ `InvalidArgument` |
| 4 | `:662` | `isSuperUser` — superuser/support mode bypasses clean-room access validation |
| 5 | `:672-682` | per partner account: `FetchPartnerAccountByID`, `FetchPartnerByID` |
| 6 | `:683-686` | **`partner.Type != EXPORTS` ⇒ `InvalidArgument`** — the type gate |
| 7 | `:688-699` | `ValidateCleanRoomAccess` unless superuser/support |
| 8 | `:701-724` | job name = `"<partnerAccount.Name> / <question.Title>"` **or** `"… / <dataset.Name>"` — a job targets a question **or** a dataset |
| 9 | `:726` | `GetDomainIdentifier` for the partner account's org |
| 10 | `:728-737` | build `models.Job{JobType: EXPORTS, Granularity: DAILY, Status: ACTIVE, DomainIdentifier: …}` |
| 11 | `:740-748` | if no `ExportParameters` supplied, fall back to `FetchPartnerParameters` ("mostly … the LR Activation use case") |
| 12 | `:757-765` | `db.CreateExportJobs` |

Note the pattern at steps 1–3: **every** early return calls `s.setCRQAssetFalse(ctx, in)`
(`A/picanmix/api/server/job.go:614`) first. The comment at `:639-640` explains it — a failed
export-job creation must clear `isAsset` on the clean-room question so the UI does not show
the question as exportable.

## What `db.CreateExportJobs` writes

`A/picanmix/db/job.go:438-475`, one transaction, three tables per job:

| Order | Line | Table | Row |
|---|---|---|---|
| 1 | `:442` | `jobs` | the job, `job_type = EXPORTS` |
| 2 | `:448-453` | `export_details` | `{job_id, clean_room_id, clean_room_question_id, clean_room_dataset_id}` |
| 3 | `:459-469` | `export_detail_parameters` | one row per parameter `{job_id, name, value}` |

Models — `A/picanmix/models/job.go`:

```go
type ExportDetail struct {           // :85-91   hdb.Audit only -> NO deleted_at
	hdb.Audit
	JobID               string `gorm:"...;unique_index:uix_job_export_detail"`
	CleanRoomID         string `gorm:"...;unique_index:uix_job_export_detail"`
	CleanRoomQuestionID string `gorm:"...;unique_index:uix_job_export_detail"`
	CleanRoomDatasetID  string `gorm:"...;unique_index:uix_job_export_detail"`
}

type ExportDetailParameter struct {  // :78-83   hdb.Audit only -> NO deleted_at
	hdb.Audit
	JobID string `gorm:"...;unique_index:uix_job_export_detail_parameter"`
	Name  string `gorm:"...;unique_index:uix_job_export_detail_parameter"`
	Value string
}
```

Both embed `hdb.Audit` only — like every detail table, they are **hard-delete-only** by
construction (`gorm@v1.9.16/callback_delete.go:38` sees no `DeletedAt`). Compare
`A/picanmix/models/job.go:106-118` `QuestionUserListDetails`, identical in that respect.

The composite `unique_index` on `ExportDetail` is the real config-level dedupe key: one
export job per (job, clean room, question, dataset).

## Run time — the daily DAG chain

```
A/cacofonix/.../main_question_export_dag.py:45,50    schedule_interval = "@daily" (midnight)
 └─ :19  PicanmixClient.get_question_export_jobs_to_run()
      └─ A/cacofonix/habuairflow/lib/habu/http/picanmix.py:61-68
           GET /picanmix/activation/export-jobs-to-run     (A/picanmix/proto/activation.proto:603-605)
             └─ A/picanmix/api/server/activation.go:406-430  GetActivationExportJobsToRun
                  └─ A/picanmix/db/activation.go:382-401     FetchExportPartners
 └─ :61-68  TriggerMultipleDagRunOperator -> trigger_dag_id "question-export-dag", delay 10s
      └─ A/cacofonix/.../question_export_dag.py:88 (schedule=None), :103
           tenansix com.habu.activation.commands.ExportCommand
```

`FetchExportPartners` in full (`A/picanmix/db/activation.go:382-401`) — note what is
**absent**:

```go
db.Table("partners").
   Select("partner_accounts.organization_id, partner_accounts.id as partner_account_id").
   Joins("JOIN partner_accounts ON partners.id = partner_accounts.partner_id").
   Where("partner_accounts.deleted_at IS NULL").
   Where("partners.deleted_at IS NULL").
   Where("partners.type = ?", proto.EXPORTS.String()).
   Where("(partners.deprecated = ? OR (partners.deprecated = ? AND partner_accounts.organization_id IN (?)))", false, true, legacyAccessOrgs)
```

No `jobs`, no `job_runs`, no `NOT EXISTS`, no status. It returns **every live EXPORTS partner
account in the platform** and lets tenansix figure out what is new. Contrast
`FetchQuestionUserListActivationJobs` (`A/picanmix/db/activation.go:574-645`), which does the
whole decision in SQL.

Note it uses `db.Table("partners")` and therefore hand-writes both `deleted_at IS NULL`
clauses — the fail-open boundary described in
[`02`](02-gorm-v1-soft-delete-mechanism.md).

## Inside tenansix `ExportCommand`

`B/tenansix/src/main/java/com/habu/activation/commands/ExportCommand.java`:

| Line | What |
|---|---|
| `:20-31` | options `-o/--organizationID`, `-j/--partnerAccountID`, `-t/--timeWindowStart`, `-d/--daysAgo` |
| `:42-50` | both `organizationID` and `partnerAccountID` are required — warn and exit otherwise |
| `:66-69` | `picanmixClient.fetchExportJobs(orgID, partnerAccountID)` |
| `:73-86` | per job: **if `cleanRoomDatasetId` is non-empty → `DatasetExporter`**, else if `cleanRoomQuestionId` non-null → `QuestionExporter` |

So the dataset-vs-question fork that `CreateExportJobs:701-724` encoded in the job *name* is
re-derived here from which detail column is populated. `DatasetExporter` is the only branch
that receives `_timeWindowStart` / `_daysAgo` — question exports have no time window.

`fetchExportJobs` lands on `A/picanmix/api/server/activation.go:215-270`
`GetActivationExportJobs` → `A/picanmix/db/activation.go:404` `FetchExportJobs`, and note the
post-filter at `A/picanmix/api/server/activation.go:264-268`:

```go
if _, ok := TEECleanRooms[cleanRoom.Type]; !ok {
    jobs = append(jobs, job)
}
```

**TEE clean rooms are excluded from this path entirely** — their exports go through
`GetTEEExportJobs` (`A/picanmix/proto/activation.proto:601`) instead. That is the same
`GetTEEExportJobs` vs `ListDataExportJobs` split that appears in the collaborator-removal
export-leak work.

## On-demand export

`A/picanmix/api/server/job.go:792-…` `TriggerOnDemandExport` — a separate, user-initiated
path that publishes an event to SNS/SQS consumed by pegleg (comment at `:790-791`). Its
validation chain, all before publishing anything:

| Line | Check |
|---|---|
| `:797` | `isUserAuthorizedWriteV2` |
| `:804`, `:808` | `ExportJobID` and `ExportPartnerID` required |
| `:813` | `FetchJobByID` — job must exist |
| `:820` | **`exportJob.JobType != EXPORTS` ⇒ `InvalidArgument`** |
| `:825` | `exportJob.OrganizationID != in.OrganizationID` ⇒ `PermissionDenied` (tenancy) |
| `:832` | `FetchExportDetailsByJobID` — detail row must exist |
| `:840` | `FetchPartnerAccountByID` — partner account must exist |
| `:847` | `len(in.Parameters) > 50` ⇒ rejected |

Corresponding DAG: `A/cacofonix/habuairflow/dags/picanmix/on_demand_export_dag.py`, and
tenansix `commands/OnDemandExportCommand.java`.

Contrast the tenancy check at `:825` with unhygienix `DeleteCleanRoomPartner`
(`A/unhygienix/api/server/cleanroom_partner.go:454-492`), which has **no** authorization
check at all — finding F4.

## Export vs QUL, side by side

| | `EXPORTS` | `QUESTION_USER_LIST` |
|---|---|---|
| Config entity | the `jobs` row itself | `question_user_lists` |
| Detail row written | config time (`db/job.go:448`) | run time (`db/job.go:743`) |
| Extra config table | none needed | `question_user_lists` |
| New job per CRQ run | **no** | **yes** (`api/server/job.go:2258`) |
| `Granularity` | `DAILY` (`api/server/job.go:731`) | not set |
| `source_job_run_id` on runs | **empty** — explicit TODO at `api/server/job_run.go:126` | `clean_room_question_run_id` |
| "Is there work?" decided | in tenansix `ExportCommand` (Java) | in picanmix SQL (`NOT EXISTS`, `db/activation.go:596-599`) |
| Trigger | `@daily` master DAG | pegleg inline + `@hourly` master DAG (+ 20-min syncher) |
| TEE clean rooms | excluded (`api/server/activation.go:264-268`) | LinkedIn Matched Audience skipped, "done in TEE" (`B/tenansix/.../QuestionUserListSender.java:59-61`) |
| Extra params table | `export_detail_parameters` (`models/job.go:78-83`) | none |
