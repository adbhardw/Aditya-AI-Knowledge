# 02 — How the soft delete physically happens (gorm v1), and why `PartnerAccount` has no `DeletedAt`

The question that prompted this: *"I don't see a `deletedAt` column for `PartnerAccount`."*

Answer: it is not declared on `PartnerAccount`. It is **inherited via an anonymous embed**,
and gorm v1 flattens embedded structs into columns.

## Declaration chain

`A/picanmix/models/partner.go:67-79`:

```go
type PartnerAccount struct {
	UUID        // line 68
	TimeAudit   // line 69   <-- this one
	UserAudit   // line 70
	hdb.Audit   // line 71
	Name           string
	OrganizationID string
	...
}
```

`TimeAudit` — `A/picanmix/models/audit.go:21-25`:

```go
type TimeAudit struct {
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time   // line 24
}
```

`partnerAccount.DeletedAt` is a legal Go expression — the compiler promotes the field.

**Sibling embeds that look similar but are NOT it:**
- `hdb.Audit` (line 71) → `audit_created_at`, `audit_updated_at`, `audit_created_by_user`,
  `audit_updated_by_user` (`A/hank/db/audit.go:84-89`)
- `UserAudit` (line 70) → `created_by_user_id`, `updated_by_user_id`
  (`A/picanmix/models/audit.go:56-59`)

Only `TimeAudit.DeletedAt` triggers soft delete.

## Layer trace for one row

Call: `SoftDeletePartnerAccount(ctx, s.DB, "PA-77")` from
`A/picanmix/api/server/partner_account.go:730`.

| Time | Layer | Code | What it sees / does |
|---|---|---|---|
| T1 | handler | `A/picanmix/api/server/partner_account.go:730` | `db.SoftDeletePartnerAccount(ctx, s.DB, "PA-77")` |
| T2 | picanmix db pkg | `A/picanmix/db/partner_account.go:452-463` | `tx.Scopes(IDScope("PA-77")).Delete(&models.PartnerAccount{})` — no `Unscoped()`, no mention of `deleted_at` |
| T3 | scope build | `A/picanmix/db/scopes.go:12-16` | adds `WHERE id = 'PA-77'` |
| T4 | ORM reflection | `gorm@v1.9.16/model_struct.go:242-244` | hits `TimeAudit`, `fieldStruct.Anonymous == true` → recurses and hoists `CreatedAt`/`UpdatedAt`/`DeletedAt` as if declared on `PartnerAccount`; `DeletedAt` → DBName `deleted_at` |
| T5 | delete callback | `gorm@v1.9.16/callback_delete.go:36` | `deletedAtField, hasDeletedAtField := scope.FieldByName("DeletedAt")` → **found** |
| T6 | the branch | `gorm@v1.9.16/callback_delete.go:38` | `if !scope.Search.Unscoped && hasDeletedAtField` → **true** → `UPDATE` branch (`:39-46`), not `DELETE FROM` (`:48-53`) |
| T7 | SQL emitted | `gorm@v1.9.16/callback_delete.go:40-46` | roughly `UPDATE "partner_accounts" SET "deleted_at" = $1 WHERE "partner_accounts"."deleted_at" IS NULL AND (id = $2)` |
| T8 | commit | `A/picanmix/db/partner_account.go:461` | row still physically present, `deleted_at` non-NULL |

The single deciding line is `callback_delete.go:38`. Note what it keys on: **the field
*name* `DeletedAt`**. gorm v1 has no marker type (no `gorm.DeletedAt`, no `soft_delete`
tag), which is exactly why nothing in `models/partner.go` looks like an opt-in.

T7's `WHERE` also carries `deleted_at IS NULL` (from `gorm@v1.9.16/scope.go:718-721`), so
deleting twice is a no-op the second time.

Module path verified at `/Users/adbhar/go/pkg/mod/github.com/jinzhu/gorm@v1.9.16`;
`A/picanmix/go.mod:24` pins `github.com/jinzhu/gorm v1.9.16`.

## Proof the physical column exists

The Go struct alone would not prove the table has the column. Hand-written SQL in the repo
does — these would fail at runtime otherwise:

- `A/picanmix/db/partner_account.go:776` — `question_user_lists.deleted_at IS NULL and partner_accounts.deleted_at IS NULL`
- `A/picanmix/db/partner_account.go:793` — same for `clean_room_question_id`
- `A/picanmix/db/activation.go:388` — `partner_accounts.deleted_at IS NULL`
- `A/picanmix/db/scopes.go:315` — `partner_accounts.deleted_at IS NULL` + `partners.deleted_at IS NULL`

The column is created by gorm itself: `A/picanmix/api/server/server.go:131` wires
`hdb.WithAutoMigrate(opts)`, emitting columns from the same flattened field list as T4.

## Soft vs hard is `DeletedAt` × `Unscoped`, never `Scopes`

Two gorm concepts with colliding names:

- **`Scopes(fn...)`** — `A/picanmix/db/scopes.go:12-16`. Plain closures appending `WHERE`
  clauses. **Zero influence on delete semantics.**
- **`Unscoped()`** — sets `search.Unscoped = true`, switching off soft-delete on both read
  and write.

Rule, `gorm@v1.9.16/callback_delete.go:38`:

| Model has field named `DeletedAt` | `.Unscoped()` called | Result | Example |
|---|---|---|---|
| yes | no | **soft** | `A/picanmix/db/partner_account.go:454`, `db/job.go:847`, `db/partner.go:75` |
| yes | **yes** | hard | `A/unhygienix/db/cleanroom_partner.go:358` |
| **no** | no | hard | `QuestionUserListDetails`, `UserListDetail`, `ExportDetail` — no `TimeAudit` embed |
| no | yes | hard | — |

The model's field list is the **primary switch**; `Unscoped()` is a per-call **override**.
Two consequences visible in the code:

- `grep -rn "Unscoped()" A/picanmix/db/` returns **nothing**. picanmix has no gorm hard
  deletes at all — its behaviour is decided once in `models/`, never at a call site.
- Because `Unscoped()` is per-statement, `HardDeleteCleanRoomPartner` had to repeat it on
  every statement, and the two that forgot (`A/unhygienix/db/cleanroom_partner.go:400`,
  `:437`) fell back to soft delete inside a function named "Hard".

## Where the free behaviour stops (fail-open boundary)

gorm injects `deleted_at IS NULL` for **one** table only — `scope.QuotedTableName()`, the
primary model (`gorm@v1.9.16/scope.go:719`).

`Table()` vs `Model()` silently changes this on reads:

- `gorm@v1.9.16/main.go:519-524` — `Table(name)` sets `clone.Value = nil`
- `gorm@v1.9.16/main.go:363-365` — `Scan(dest)` builds the scope from `s.Value` (now nil),
  **not** from `dest`
- ⇒ `FieldByName("DeletedAt")` finds nothing ⇒ **no automatic filter**

That is why `A/picanmix/db/job.go:905-911` `FetchQuestionUserList` uses
`db.Table("question_user_lists")` and must reach for `CleanRoomQuestionNotDeletedIDScope`
(`A/picanmix/db/scopes.go:210-214`), which hand-writes `and deleted_at IS NULL`.

**`Model()` fails closed; `Table()`, joins and raw SQL fail open.** When auditing picanmix
for stale-row leaks, `db.Table(` is the grep to run.

A live example of the cost — `A/picanmix/db/activation.go:601-607` hand-writes
`deleted_at IS NULL` for `j`, `qul`, `pa`, `p`, and writes `p.deleted_at` / `pa.deleted_at`
**twice** (`:604`, `:606`, `:607`) — the signature of patching a leak without reading the
line above.
