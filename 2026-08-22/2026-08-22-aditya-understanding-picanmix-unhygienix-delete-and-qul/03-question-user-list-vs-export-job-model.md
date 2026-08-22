# 03 — `question_user_lists` vs exports: why QUL needs a third table

## `QUESTION_USER_LIST` is a job *type*, not a kind of export

`A/picanmix/proto/domain.proto:45-51`:

```
USER_LIST = 1;  OFFLINE_CONVERSIONS = 2;  EXPORTS = 3;  QUESTION_USER_LIST = 4;
```

`QUESTION_USER_LIST` is a **peer of `EXPORTS`**. Every job type has an identically-shaped
per-type sidecar table — `A/picanmix/models/job.go`:

| Job type | Detail model | Embeds | Keyed by |
|---|---|---|---|
| `USER_LIST` | `UserListDetail` `:63-68` | `hdb.Audit` only | `job_id` + `user_list_id` |
| `OFFLINE_CONVERSIONS` | `OfflineConversionDetail` `:70-75` | `hdb.Audit` only | `job_id` + `data_import_job_id` |
| `EXPORTS` | `ExportDetail` `:85-91` | `hdb.Audit` only | `job_id` + `clean_room_id` + `crq_id` + `dataset_id` |
| `QUESTION_USER_LIST` | `QuestionUserListDetails` `:106-118` | `hdb.Audit` only | `job_id` + `clean_room_question_run_id` + `question_user_list_id` |

`question_user_list_details` occupies the same slot as `export_details`.

`question_user_lists` (no `_details`) is a different table with a different lifetime —
`A/picanmix/models/job.go:195-199` embeds `UUID` + `TimeAudit` + `UserAudit`, while all four
detail tables embed only `hdb.Audit`. It is a first-class entity; they are ledger rows.

A partner account is typed, so the two paths never mix:

| Path | Gate | Line |
|---|---|---|
| QUL activation | `partner.Type != USER_LIST` → `InvalidArgument` | `A/picanmix/api/server/job.go:2314-2320` |
| Export | `partner.Type != EXPORTS` → `InvalidArgument` | `A/picanmix/api/server/job.go:683-686` |

## The one column that explains the extra table

| | `ExportDetail` (`models/job.go:85-91`) | `QuestionUserListDetails` (`models/job.go:106-118`) |
|---|---|---|
| `CleanRoomQuestionID` | present | present |
| `CleanRoomQuestionRunID` | **absent** | present, **`not null`** (`:111`) |
| Written when | **config time**, `db/job.go:448` | **run time**, `db/job.go:743` |

`ExportDetail` can *be* the config because it has no run in it. A `not null` run id means
the row can only exist after a run — and config precedes any run. So QUL needed a second,
run-independent home for "who subscribed to this question". Exports never did.

## Structural comparison

| | `EXPORTS` | `QUESTION_USER_LIST` |
|---|---|---|
| Config entity | **the `jobs` row itself** | **`question_user_lists`** |
| Created by | user at config time, `api/server/job.go:635` `CreateExportJobs` | user at config time, `api/server/job.go:2331` `CreateUpdateQuestionUserList` |
| Detail row written | config time, `db/job.go:448` | run time, `db/job.go:743` |
| Jobs per CRQ run | **0 new** — one standing job gets a new `job_runs` row | **1 new `jobs` row per run**, `api/server/job.go:2258` |
| `Granularity` | `DAILY` (`api/server/job.go:731`) | not set |

## Shape

```
clean_room_question CRQ-5
 └── question_user_lists   QUL-3  (crq=CRQ-5, partner_account_id=PA-77, HEM)   <- config, 1 row forever
       ├── run RUN-9  -> jobs J-12 (job_type=QUESTION_USER_LIST, partner_account_id=PA-77)
       │                  └── question_user_list_details (job_id=J-12, crqr_id=RUN-9, question_user_list_id=QUL-3, price)
       └── run RUN-10 -> jobs J-13
                          └── question_user_list_details (job_id=J-13, crqr_id=RUN-10, question_user_list_id=QUL-3, price)
```

## One QUL through its whole life

| Time | Code | `question_user_lists` | `jobs` | `question_user_list_details` |
|---|---|---|---|---|
| T1 | `api/server/job.go:2426` → `db/job.go:788` **BEGIN…COMMIT** | **QUL-3** created | – | – |
| T2 | unhygienix finishes run `RUN-9` of CRQ-5 | QUL-3 | – | – |
| T3 | `api/server/job.go:2245` `FetchQuestionUserListDetails(RUN-9, PA-77, HEM)` → **0 rows** ⇒ proceed | QUL-3 | – | – |
| T4 | `:2258` build `Job{job_type: QUESTION_USER_LIST, partner_account_id: PA-77}`; `db/job.go:721` **BEGIN** | QUL-3 | – | – |
| T5 | `db/job.go:723` `tx.Create(job)` | QUL-3 | **J-12 (uncommitted)** | – |
| T6 | `db/job.go:743` `tx.Create(listDetail)` | QUL-3 | J-12 (uncommitted) | **(J-12, RUN-9, QUL-3) (uncommitted)** |
| T7 | `db/job.go:749` **COMMIT** | QUL-3 | J-12 durable | 1 row durable |
| T8 | run `RUN-10`; T3 re-checked for RUN-10 → 0 rows ⇒ new job | QUL-3 **unchanged** | J-12, **J-13** | 2 rows |
| T9 | fan-out for RUN-9 replayed; `:2245` finds the row ⇒ **skip** | QUL-3 | J-12, J-13 | 2 rows |
| T10 | `api/server/partner_account.go:703` `FetchQuestionUserListByPartnerAccountID(PA-77)` → QUL-3 | QUL-3 | J-12, J-13 | 2 rows |
| T11 | `:710` `SoftDeleteJobsByQULID` → `db/job.go:859` **reads the detail rows** to learn J-12, J-13 → soft-deletes them | QUL-3 alive | both `deleted_at` set | **2 rows untouched** |
| T12 | `:717` `SoftDeleteQuestionUserListByID` | **`deleted_at` set** | deleted | 2 rows untouched |

## Why `CreateQuestionUserList` cannot be folded into `CreateQuestionUserListJobs`

`B/pegleg/pegleg-backend/src/main/java/com/habu/pegleg/util/Utils.java:26`:

```java
public static void createQuestionUserListJobs(PicanmixClient picanmix,
        String cleanRoomQuestionId, String runId, String organizationId)
```

Three strings. The request it must build
(`B/zabra/zabra-grpc-client/src/main/java/com/habu/zabra/grpc/PicanmixClient.java:596-617`)
needs five more fields, **all of which come from the QUL row**:

| Field the RPC needs | pegleg reads | Source table |
|---|---|---|
| `questionUserListID` | `ul.getID()` | `question_user_lists` |
| `partnerAccountIDs` | `ul.getPartnerAccount().getID()` | `question_user_lists` |
| `identityType` | `ul.getIdentityType()` | `question_user_lists` |
| `partnerSegmentCode` | `ul.getPartnerSegmentCode()` | `question_user_lists` |
| `price` | `ul.getPrice()` | `question_user_lists` |

`Utils.java:28-29` is a single lookup — `picanmix.fetchQuestionUserList(orgId, crqId)` →
`A/picanmix/api/server/job.go:2498` → `A/picanmix/db/job.go:905`
(`WHERE clean_room_question_id = ? AND deleted_at IS NULL`). **`question_user_lists` is
pegleg's answer to "who subscribed to this question?"** Remove it and a Snowflake query
runner would have to be taught what an activation destination is.

Three further blockers to folding it into `jobs`:

1. **`jobs` has no clean-room-question column.** `models.Job`
   (`A/picanmix/models/job.go:15-29`) is `Name, OrganizationID, PartnerAccountID, JobType,
   Granularity, Status, EntityType, EntityID, DomainIdentifier`; for QUL jobs
   `EntityType/EntityID` are the **organization** (`api/server/job.go:2263-2264`).
   "Find the config for CRQ-5" is unanswerable from `jobs` alone — you would join through
   `question_user_list_details`, which only exist per run. Circular.
2. **N runs → N job rows.** A config row in `jobs` would need a "not a real job" flag, and
   every count query (`api/server/job.go:3018-3060`) would have to exclude it.
3. **Something must be deletable to stop future runs.** `DeletePartnerAccount`
   (`api/server/partner_account.go:703-722`) walks `question_user_lists` by
   `partner_account_id`. Past jobs cannot tell you what the next run will do.

## The details row is never deleted and cannot be soft-deleted

`grep` across `A/picanmix/db/` and `A/picanmix/api/` finds **zero** delete calls against
`QuestionUserListDetails`. It has no `DeletedAt` — `models/job.go:106-107` embeds
`hdb.Audit` only — so `gorm@v1.9.16/callback_delete.go:38` would evaluate
`hasDeletedAtField == false` and take the `DELETE FROM` branch. No soft delete is available
to it.

This is consistent, not accidental: `QuestionUserListDetails.Price float32`
(`models/job.go:117`) makes it the billing record for one push. After T12 you hold a live
detail row pointing at a soft-deleted job and a soft-deleted QUL, and can still answer
"run RUN-9 pushed to PA-77".
