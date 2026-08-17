# agentic-core MLOps workstream — PR #1052 (2026-08-17)

**Start here: [SUMMARY.md](SUMMARY.md)** — self-contained account of the whole session, written so another AI assistant can pick it up without reading anything else.

What Varsha Kota and the MLOps team are building inside `LiveRamp/agentic-core`, and why — from first principles. Centred on [PR #1052](https://github.com/LiveRamp/agentic-core/pull/1052) ("Mlop 461 agentic boundaries checks ci hooks"), which introduces namespace-boundary enforcement for a multi-tenant agent platform and migrates the eval gates from GitHub Actions to Jenkins.

**Correction that frames the whole session:** Varsha is the **author** of #1052, not a reviewer. At the time of analysis no human had reviewed it — only CodeRabbit.

## Contents

| File | What it contains |
|---|---|
| [SUMMARY.md](SUMMARY.md) | Executive summary — problem statement, first-principles reasoning, two Mermaid architecture diagrams, runtime flow, design options and trade-offs, the review finding, verified-vs-inferred ledger, open questions, next steps |
| [2026-08-17_pr1052_boundary_middleware_first_principles.txt](2026-08-17_pr1052_boundary_middleware_first_principles.txt) | Why namespace isolation cannot be a convention when the namespace is a model-chosen tool argument. The 8-step runtime path with verified line numbers, the three design choices (auth-derived identity, deliberate opt-in-gate bypass, auditable BLOCK), the fail-open arg-name hole and two proposed hardenings, plus secondary observations on the singleton catalog, hyphen/underscore equivalence and the PEP 562 lazy re-export |
| [2026-08-17_mlop411_epic_team_and_eval_gate_migration.txt](2026-08-17_mlop411_epic_team_and_eval_gate_migration.txt) | The team map — three workstreams under epic MLOP-411 with named owners. The four separate changes bundled into one 76-file PR, the three-deep PR stack and why it is a review hazard, why eval gates moved to Jenkins, coverage-by-default vs opt-in, graduated enforcement (`advisory = true`), the failure-triage table, why the eval harness needs its own monitoring, the 7 CodeRabbit findings, and process observations |

## The one-line version

`agentic-core` is a multi-tenant agent platform (18+ graphs, many owning teams) and the MLOps epic is retrofitting the three things such a platform needs before it can be trusted in production — **cost attribution** (Manoj Kumar), **quality regression gates** (Varsha Kota), and **tenant isolation** (Varsha Kota's middleware enforcing Geetha Vardhan's memory-namespace design).

## Scope note

Everything here is **read-only analysis** of a PR that was open and unmerged at the time. No code was written or changed, and nothing was posted to the PR.

Source reading was **partial by design**: `boundary.py` and `middleware.py` were read in full and their line numbers verified by grep; the eval-service modules (`detectors.py`, `cost_metrics.py`, `baseline_store.py`, `job_store.py`) and the CI scripts were **not** read — those sections are reconstructed from Jira ticket text, the PR docs and CodeRabbit's walkthrough. Section 12 of `SUMMARY.md` and section 9 of the epic file carry the full verified-vs-inferred ledger. **Read that before citing anything from this folder as fact.**

Only 10 of ~22 child stories under epic MLOP-411 were enumerated — the Jira API paged out. The three-workstream split is complete for what was read, not for the epic.
