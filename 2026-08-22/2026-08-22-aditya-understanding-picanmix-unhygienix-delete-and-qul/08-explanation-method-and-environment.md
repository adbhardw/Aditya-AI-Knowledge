# 08 — The explanation method, and how Claude Code memory is scoped

This document is process, not picanmix. It records the reusable part of the session: the
table format that made these explanations land, and a concrete environment finding about
where Claude Code memory lives.

## The finding: memory is per-working-directory, `CLAUDE.md` is global

`ls -d /Users/adbhar/.claude/projects/*/memory` returns **15 separate memory directories**,
one per working directory, including:

```
-Users-adbhar-Documents-GitHub-picanmix/memory
-Users-adbhar-Documents-Habu-Cloned-Repo/memory
-Users-adbhar-Documents-lr-nov-jira/memory
-Users-adbhar-Documents-project-sprint-understanding-1/memory
-Users-adbhar-Documents-project-sprint-understanding-1-picanmix/memory
-Users-adbhar-stage-db/memory
...
```

**Consequence:** a memory file written while working in
`/Users/adbhar/Documents/project-sprint-understanding-1` does **not** load when a session
starts in `~/Documents/GitHub/picanmix`. Note the last two entries above — the *same repo*
reached by two different paths gets two independent memory stores.

The file that loads in **every** project is `/Users/adbhar/.claude/CLAUDE.md`. Anything that
should apply universally belongs there, not in a project memory directory.

Applied in this session: the "Explaining Mechanisms" and "Always show it as a time-based
flow" sections already lived in the global file; the **layer-trace** variant below was
appended to it on 2026-08-22, taking it from 77 to 107 lines.

## Format A — state at each moment (business flows)

Axis is **time**. Columns: `Time | Code (file:line) | one column per table/store touched`.
One row per meaningful step, `T1..Tn`. Fill **every** cell at **every** row, including `–`
for empty and explicit `(uncommitted)` / `NULL` / `ROW GONE` markers. Mark each `BEGIN` and
`COMMIT`.

Why it works: it makes transaction windows **visible**. The picanmix
`DeletePartnerAccount` table in [`01`](01-soft-vs-hard-delete.md) is the example — the fact
that it runs **four** separate `BeginTxDB`/`Commit` pairs is invisible in prose and obvious
in the table.

## Format B — wall-clock trace (failure and multi-actor flows)

Axis is **real clock time**. Use it for "what happens when X is down" and for flows spanning
several schedulers. Include the boring repeated ticks — the repetition *is* the mechanism.
The dual-pipeline trace in [`04`](04-orchestration-segment-code-and-job-runs.md) (09:00 run →
09:04 pegleg → 09:20 syncher → 10:00 sender → 11:00 skip → 00:00 export) is the example;
without the 11:00 row, the idempotency latch is just an assertion.

## Format C — layer trace (added 2026-08-22)

Axis is **depth**, but keep the `T1..Tn` numbering. Use it when the question is *where a
behaviour comes from*, not what happens next — "I don't see a `deletedAt` column", "who sets
this field", "why is this a soft delete".

Columns: `Time | Layer | Code (file:line) | What it sees / does`. Walk **one** call
downward: handler → repo/db package → ORM reflection → ORM callback → emitted SQL. The
worked example is in [`02`](02-gorm-v1-soft-delete-mechanism.md).

Three sections must accompany it:

1. **Declaration chain.** When a field looks missing, show the embed/inheritance hop that
   supplies it — *and* explicitly name the sibling embeds that look similar but are not it.
   Here: `hdb.Audit` gives `audit_created_at`, `UserAudit` gives `created_by_user_id`; only
   `TimeAudit` gives `deleted_at`.
2. **Proof the physical thing exists.** Do not stop at the struct. Point at hand-written SQL
   or a migration in the repo that would fail at runtime if the column were not real. Here:
   four `partner_accounts.deleted_at IS NULL` literals across `db/`.
3. **Where the free behaviour stops.** Framework magic covers one narrow case. Close on the
   **fail-open vs fail-closed** asymmetry — that is the part that predicts real bugs. Here:
   gorm injects `deleted_at IS NULL` for the primary model only, so `db.Table(...)`, joins
   and raw SQL fail **open**.

## Rules that made the citations trustworthy

- **Name the single deciding line.** Not "gorm handles soft deletes" but
  `gorm@v1.9.16/callback_delete.go:38`, `if !scope.Search.Unscoped && hasDeletedAtField`.
- **Read the library, don't recall it.** gorm was read from
  `/Users/adbhar/go/pkg/mod/github.com/jinzhu/gorm@v1.9.16`, version cross-checked against
  `picanmix/go.mod:24`.
- **Full repo-relative paths.** Sibling repos share filenames — `job.go` exists in both
  picanmix and unhygienix, `PicanmixClient.java` exists in both zabra and tenansix with
  different method sets. Bare filenames are ambiguous and were avoided throughout.
- **Absence is evidence, and must be labelled as inference.** "No live producer for
  `SetQuestionUserListDetailsPartnerCodes`" (F2) rests on grep finding no caller that sets
  `CleanRoomQuestionRunID`. That is weaker than a positive observation and is flagged as
  such in [`05`](05-findings-and-bugs.md).
- **Answer a misconception by pointing at the step where paths diverge**, not by restating
  the design. Q17 in [`06`](06-session-question-index.md) — "why a second `job_runs` row" —
  is answered by the `job_status != QUEUED` predicate at `db/activation.go:598`, not by a
  paragraph about idempotency.
