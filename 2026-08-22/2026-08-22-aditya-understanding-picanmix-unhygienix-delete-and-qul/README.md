# picanmix / unhygienix — delete semantics, the QuestionUserList data model, and the activation pipeline

**Session date:** 2026-08-22

> **Start with [`SUMMARY.md`](SUMMARY.md).** It is self-contained: problem statement,
> first-principles explanation, architecture diagram, end-to-end runtime flow, trade-offs,
> all findings, and every file:line citation. Open the numbered documents below only when
> you need the full evidence for a specific claim.

## Scope and confidence

Everything here was read from source and verified with grep, with line numbers. **Nothing
was executed, no database was queried, and no finding was confirmed with the owning teams.**
Findings are labelled with severity but that is this analysis's judgement, not a triage
decision. Inferences drawn from absence-of-callers are labelled as inferences.

Repo roots referenced throughout:

- **A** = `/Users/adbhar/Documents/project-sprint-understanding-1/` → `picanmix`, `unhygienix`, `cacofonix`, `hank`
- **B** = `/Users/adbhar/Documents/GitHub/` → `pegleg`, `tenansix`, `zabra`
- gorm read from `/Users/adbhar/go/pkg/mod/github.com/jinzhu/gorm@v1.9.16`

## Contents

| File | What it contains |
|---|---|
| [`SUMMARY.md`](SUMMARY.md) | **Entry point.** Full executive summary with Mermaid architecture diagram, wall-clock runtime flow, trade-off tables, the complete findings table, and a file/line index across all seven repos. |
| [`01-soft-vs-hard-delete.md`](01-soft-vs-hard-delete.md) | picanmix `DeletePartnerAccount` (soft, + `DEPROVISIONED` on the clean-room binding) and `DeletePartner` (soft) vs unhygienix `DeleteCleanRoomPartner` (hard, with a soft tail). Two state-at-each-moment tables showing every row at every step, the four-transaction window, and the first-principles argument for why the two services differ. |
| [`02-gorm-v1-soft-delete-mechanism.md`](02-gorm-v1-soft-delete-mechanism.md) | Why `PartnerAccount` has no `DeletedAt` field yet soft-deletes: the anonymous-embed declaration chain, a handler→ORM→SQL layer trace, proof the physical column exists, the `DeletedAt` × `Unscoped` truth table (`Scopes` is a red herring), and the `Table()` vs `Model()` fail-open boundary. |
| [`03-question-user-list-vs-export-job-model.md`](03-question-user-list-vs-export-job-model.md) | `QUESTION_USER_LIST` is a peer of `EXPORTS`, not a kind of it. The four per-job-type detail tables side by side, the one `not null` column that forces QUL to need a third table, a T1–T12 lifecycle table, and why `CreateQuestionUserList` cannot be folded into `CreateQuestionUserListJobs` (pegleg only knows three strings). |
| [`04-orchestration-segment-code-and-job-runs.md`](04-orchestration-segment-code-and-job-runs.md) | The four triggers (pegleg inline, 20-min syncher, hourly sender, daily export) with schedules and commands; who calls each "has this run been handled" check; the wall-clock trace of a question with both a QUL and an export; the `job_runs` QUEUED→RUNNING→COMPLETE lifecycle and why a QUEUED row produces a second run row; and both `partner_segment_code` writers. |
| [`05-findings-and-bugs.md`](05-findings-and-bugs.md) | Eight findings (F1–F8) with severity, failure scenario, and suggested fix — over-broad job deletion, an unreachable segment-code back-fill, a "HardDelete" that soft-deletes, a missing authz check, a variable-shadowing bug, a four-transaction window, a dead `price` field, and a duplicated loop. |
| [`06-session-question-index.md`](06-session-question-index.md) | Every question asked in the session, in order, with the one-line answer and a link to the document holding the evidence. Start here if you remember a phrase but not where it was discussed. |
| [`07-export-path-in-depth.md`](07-export-path-in-depth.md) | The `EXPORTS` path traced to the same depth as QUL: the twelve guards in `CreateExportJobs`, the three tables one call writes, the `@daily` DAG chain into tenansix `ExportCommand`, the dataset-vs-question fork, the TEE clean-room exclusion, the `TriggerOnDemandExport` validation chain, and an export-vs-QUL comparison table. |
| [`08-explanation-method-and-environment.md`](08-explanation-method-and-environment.md) | Process, not picanmix: the three table formats used here (state-at-each-moment, wall-clock, layer trace), the rules that made the citations trustworthy, and the finding that Claude Code memory is per-working-directory (15 separate stores) while `~/.claude/CLAUDE.md` is the only globally-loaded file. |

## The two ideas worth remembering

1. **Delete strategy follows what the row is for.** Retain what you must be able to explain
   later (history-bearing rows → soft delete, fails closed); destroy what confers power
   (access grants → hard delete, because a missed filter fails open).
2. **`Model()` fails closed; `Table()`, joins and raw SQL fail open.** gorm injects
   `deleted_at IS NULL` for the primary model only. Grepping `db.Table(` is the practical
   audit for stale-row leaks.
