# Attestation agent — LLM inputs, SQL handling, Agent Protocol design

Session: 2026-08-31. Follow-up to
[2026-08-26-aditya-understanding-agentic-core-attestation](../../2026-08-26/2026-08-26-aditya-understanding-agentic-core-attestation/).

## Contents

| File | What |
|---|---|
| [SUMMARY.md](SUMMARY.md) | **Start here.** Self-contained executive summary. |
| [01-llm-inputs.md](01-llm-inputs.md) | Both LLM prompts fully assembled, line by line, with a worked example. Contains the Job B finding. |
| [02-no-sql-execution.md](02-no-sql-execution.md) | Proof the agent never runs SQL; where sqlglot runs and how its output reaches the LLM node. |
| [03-agent-protocol-design.md](03-agent-protocol-design.md) | Why `/threads` + `/runs/wait`; why `fetchAttestationThreadState` exists. |

## Headline finding

`intent_analyzer.py:226` tells the model *"PII is only what dataset field flags
say"* — but `evaluate_nl_rules` (`:178-185`) is never given the field flags. The
instruction cannot be followed.
