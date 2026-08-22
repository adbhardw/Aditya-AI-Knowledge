# 01 — Soft vs hard delete: picanmix `DeletePartnerAccount` vs unhygienix `DeleteCleanRoomPartner`

Repo roots used throughout:
- **A** = `/Users/adbhar/Documents/project-sprint-understanding-1/` → `picanmix`, `unhygienix`, `cacofonix`, `hank`
- **B** = `/Users/adbhar/Documents/GitHub/` → `pegleg`, `tenansix`, `zabra`

## Verdict table

| | picanmix `DeletePartnerAccount` | picanmix `DeletePartner` | unhygienix `DeleteCleanRoomPartner` |
|---|---|---|---|
| Main row | **soft** (`deleted_at = now`) | **soft** | **HARD** (`Unscoped().Delete` → real SQL `DELETE`) |
| Marks inactive? | Not the account. Marks the *clean-room binding* `DEPROVISIONED` | No (`partners.deprecated` exists, untouched) | N/A — row is gone |
| Children | jobs + QULs soft; provisions status-updated | none allowed to exist | mixed: invitations/permissions/roles/flow-access **hard**; clean-room **users** and **datasets** **soft**; result-shares **soft** |
| Guard | blocks if any job exists for the account | blocks if any live account exists | **no authz check at all** |

## picanmix `DeletePartnerAccount` — state at each moment

Handler: `A/picanmix/api/server/partner_account.go:655-735`.

Concrete case: org Adidas, partner account `PA-77` ("Adidas → Meta Ads"), provisioned as an
activation channel into clean room `CR-9`, with `question_user_lists` row `QUL-3` and
activation job `J-12`.

| Time | Code | `partner_accounts` PA-77 | `activation_channel_provisions` (PA-77, CR-9) | `question_user_lists` QUL-3 | `jobs` J-12 |
|---|---|---|---|---|---|
| T1 | `partner_account.go:659` `isUserAuthorizedWriteV2` | live, `deleted_at` NULL | `status=PROVISIONED` | live | live |
| T2 | `:665` `FetchPartnerAccountByID` (gorm-scoped ⇒ `deleted_at IS NULL`) | live | PROVISIONED | live | live |
| T3 | `:669` org tenancy check | live | PROVISIONED | live | live |
| T4 | `:679` `FetchJobs(..., "ALL", ...)` — **non-empty ⇒ PermissionDenied, abort** | live | PROVISIONED | live | live |
| T5 | `:687` `FetchCleanRoomsByPartnerAccountID` → 1 provision row | live | PROVISIONED | live | live |
| T6 | `:698` `acProvision.Status = DEPROVISIONED` (**in memory only**) | live | PROVISIONED | live | live |
| T7 | `:710` `SoftDeleteJobsByQULID` → `db/job.go:858` **BEGIN…COMMIT #1** | live | PROVISIONED | live | **`deleted_at=now`** |
| T8 | `:717` `SoftDeleteQuestionUserListByID` → `db/job.go:844` **BEGIN…COMMIT #2** | live | PROVISIONED | **`deleted_at=now`** | deleted |
| T9 | `:724` `UpdateProvisionedPartner` → `db/partner_account.go:717` **BEGIN…COMMIT #3** | live | **`status=DEPROVISIONED`, `deleted_at` still NULL** | deleted | deleted |
| T10 | `:730` `SoftDeletePartnerAccount` → `db/partner_account.go:452` **BEGIN…COMMIT #4** | **`deleted_at=now`**, `config_status` UNCHANGED | DEPROVISIONED (row alive) | deleted | deleted |

**Does it mark inactive?** Two distinct answers:

- **The account itself: no.** `config_status` is never written; there is no `is_active`.
  The only liveness marker is `deleted_at`.
- **The binding into each clean room: yes.** T9 writes
  `activation_channel_provisions.status = DEPROVISIONED` and leaves the row alive.
  `GetProvisionedDestinations` (`partner_account.go:1805`) reads that column, and the
  hourly activation sweep requires `status = ACTIVE_CHANNEL`
  (`A/picanmix/db/activation.go:585-591`), so deprovisioning removes the account from
  activation *immediately*, before the soft delete lands.

**Four-transaction window.** T7–T10 are four independent `BeginTxDB`/`Commit` pairs, not
one. A crash between T8 and T9 leaves PA-77 alive, provisioned, with its QUL soft-deleted;
between T9 and T10 leaves a `DEPROVISIONED` binding pointing at a live account. Nothing
sweeps this.

## picanmix `DeletePartner`

`A/picanmix/api/server/partner.go:370-394`. `:379` `FetchPartnerAccountsByPartner` is
gorm-scoped, so it counts only accounts with `deleted_at IS NULL` — any live account →
`PermissionDenied "There are active accounts for partner"`. Otherwise `:388` →
`A/picanmix/db/partner.go:73` → `partners.deleted_at = now`.

Consequence: soft-deleting all accounts first makes the partner deletable, because the
guard cannot see soft-deleted accounts. `models.Partner` has a real inactive flag —
`Deprecated *bool` (`A/picanmix/models/partner.go:19`) — which `DeletePartner` never touches.
Deprecation and deletion are separate lifecycle states.

## unhygienix `DeleteCleanRoomPartner` — hard, with a soft tail

Handler: `A/unhygienix/api/server/cleanroom_partner.go:454-492`.

| Time | Code | `clean_room_partners` CRP-4 | `clean_room_partner_invitations` | `clean_room_partner_permissions` | `clean_room_users` | `datasets` | result shares |
|---|---|---|---|---|---|---|---|
| T1 | `cleanroom_partner.go:459` `GetCleanRoom` | live | live | live | live | live | live |
| T2 | `:463/:465` lookup CRP-4 (two fallbacks) | live | live | live | live | live | live |
| T3 | `:471` → `db/cleanroom_partner.go:352` **BEGIN** | live | live | live | live | live | live |
| T4 | `:358` `Unscoped().Delete(CleanRoomPartner)` | **ROW GONE** | live | live | live | live | live |
| T5 | `:363` `Unscoped().Delete(Invitations)` | gone | **ROW GONE** | live | live | live | live |
| T6 | `:373` `Unscoped().Delete(Permissions)` | gone | gone | **ROW GONE** | live | live | live |
| T7 | `:391` `HardDeleteCleanRoomRoleInTransaction` | gone | gone | gone | live | live | live |
| T8 | `:400` `tx…Delete(CleanRoomUser{})` — **no `Unscoped()`** | gone | gone | gone | **soft** | live | live |
| T9 | `:422` + `:445` `Unscoped().Delete(FlowsNodeAccess)` (loop written **twice**) | gone | gone | gone | soft | live | live |
| T10 | `:437` `tx…Delete(Dataset{})` — **no `Unscoped()`** | gone | gone | gone | soft | **soft** | live |
| T11 | `:462` **COMMIT** | gone | gone | gone | soft | soft | live |
| T12 | handler `:485` `SoftDeleteCleanRoomResultShare…(crq.ID, crp.ID)` — separate tx, per question | gone | gone | gone | soft | soft | **soft** |

Three things worth flagging:

1. **`SoftDeleteCleanRoomPartner` (`db/cleanroom_partner.go:276`) is dead code** — only
   callers are `db/cleanroom_partner_test.go:336` and `:344`. Production has exactly two
   call sites, both hard: `api/server/cleanroom_partner.go:471` and `DeleteCleanRoom` at
   `api/server/cleanroom.go:1881` (which hard-deletes every partner then *soft*-deletes the
   clean room itself at `:1895`).
2. **The hard delete is not uniform.** T8 (`clean_room_users`) and T10 (`datasets`) are
   missing `Unscoped()`. `clean_room_users` is permission-bearing — exactly what the hard
   delete exists to eliminate.
3. **No authorization check.** Straight from `GetCleanRoom` to `HardDeleteCleanRoomPartner`;
   no `isUserAuthorizedWriteV2` equivalent, unlike picanmix `partner_account.go:659`. T12
   also dereferences `crp.ID` after T4 deleted that row.

## First principles — why the split

**`partner_accounts` is a history-bearing row.** Its ID is stamped onto things that must
outlive it: `jobs.partner_account_id`, `question_user_lists.partner_account_id`. A run
summary must still answer "which destination did this push to, under which credential".
The codebase says so out loud: `A/picanmix/db/partner_account.go:897` exists solely to read
a *deleted* account, commented *"We want to fetch the deleted partner account as well here
so gorm can't be used."* Soft delete keeps referential meaning; forgetting the
`deleted_at IS NULL` filter fails **closed** (you see less, not more).

**`clean_room_partners` is a power-bearing row.** It grants org X access to clean room Y.
Entirely present-tense; no historical-partnership report needs it. And the failure mode
inverts: a forgotten filter on an access grant fails **open** — cross-tenant data visible
to a removed org. Hard delete makes the leak impossible by construction rather than by
convention. Second reason: the row participates in uniqueness on
(clean_room_id, organization_id), so a lingering soft-deleted grant would block re-inviting
the same partner.

Compressed: **retain what you must be able to explain later; destroy what confers power.**

Where the code misses its own principle: T8/T10 leave `clean_room_users` and `datasets`
soft-deleted inside a function named `HardDelete...`, so the leak surface stays half-open.
