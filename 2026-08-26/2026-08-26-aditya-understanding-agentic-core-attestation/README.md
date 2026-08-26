# Agentic Attestation — agentic-core PR #1160

Session: 2026-08-25 → 2026-08-26

Understanding LiveRamp's `attestation-agent` (agentic-core PR #1160) — how to run
it locally, how unhygienix calls it, and what is deterministic Python versus what
is an LLM call.

## Contents

| File | What |
|---|---|
| [SUMMARY.md](SUMMARY.md) | **Start here.** Self-contained executive summary. |
| [01-local-launch.md](01-local-launch.md) | Full local launch runbook, prereq status, gotchas. |
| [02-request-path.md](02-request-path.md) | End-to-end call trace with file:line for every step. |
| [03-rule-engine.md](03-rule-engine.md) | Deterministic vs LLM checks, with worked examples. |

## Key finding

The agent never sees data — only SQL text and column metadata. A query is
flagged for PII because it selects a column a human marked `isPii: true` at
dataset setup, not because of anything in the returned values. And the PII
check is plain Python, not an LLM call.
