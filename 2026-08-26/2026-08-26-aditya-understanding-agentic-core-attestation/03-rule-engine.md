# What is deterministic, what is an LLM

Paths are relative to
`/Users/adbhar/Documents/Habu_Cloned_Repo/agentic-core/core/agents/attestation-agent/`.

---

## The single most important fact

**The agent never sees data.** No rows, no values, no results. Its entire input
is:

1. the query text (`input.code.text`), and
2. a description of each column (`datasets[].fields`).

So a question that would return the name "Aditya" is not caught because the agent
saw that string. It is caught because the query selects a column that a human
flagged `isPii: true` when the dataset was configured.

---

## The split

| Check | Mechanism | File:line |
|---|---|---|
| SQL touches a column flagged `isPii` | **Python** | `tools/field_policy.py:109-122` |
| Identifier column selected with no aggregation / group by | **Python** | `tools/field_policy.py:124-161` |
| Minimum group size (`k_min`) | **Python** | `tools/field_policy.py:163-183` |
| Raw extraction / `SELECT *` | **Python** | `agents/privacy_agent.py:38-44` |
| Regex patterns attached to a rule | **Python** | `agents/policy_engine.py` + `tools/policy_matcher.py` |
| Stated purpose matches the query | **LLM** | `agents/intent_analyzer.py:297` |
| Rules written as free English sentences | **LLM** | `agents/intent_analyzer.py:178` |

`agents/privacy_agent.py` is 46 lines and imports no model at all — see its
imports at lines 7-10.

Why: for "did you select a column marked personal," you want the same answer
every time. A model would not guarantee that.

---

## Worked example 1 — PII column

Payload field:

```json
{ "name": "FIRST_NAME", "isPii": true }
```

Query:

```sql
SELECT FIRST_NAME, COUNT(*) FROM audience GROUP BY FIRST_NAME
```

| Step | Line | What happens |
|---|---|---|
| 1 | `field_policy.py:96` | Collect columns the SQL touches → `{first_name}` |
| 2 | `field_policy.py:110` | Loop the fields |
| 3 | `field_policy.py:106` | Skip any field where `isPii` is false |
| 4 | — | `FIRST_NAME` is flagged **and** is in the touched set |
| 5 | `field_policy.py:117` | Record: `"Code accesses PII column 'FIRST_NAME'"` |

**Flip `isPii` to `false` and the same SQL passes.** Step 3 skips the field. The
column *name* is irrelevant — a column literally called `email` does not fail
when `isPii` is false. This is stated explicitly in the PR description and
enforced again in the LLM prompt at `intent_analyzer.py:331-334`.

`SELECT *` is handled at `field_policy.py:66-71` — it expands to every field on
the dataset, so it cannot be used to dodge the check.

---

## Worked example 2 — identifier / re-identification

Field:

```json
{ "name": "USER_ID", "isUserId": true, "identifierType": "RAMP_ID" }
```

The condition is at `field_policy.py:132`: identifier column touched **and** no
aggregation **and** no group by → fail.

| Query | Result |
|---|---|
| `SELECT USER_ID FROM aud` | **Fail** — row-level identifier access |
| `SELECT USER_ID, COUNT(*) FROM aud GROUP BY USER_ID` | Not caught by that branch — but caught by `field_policy.py:141-147`, grouping *by* an identifier |
| `SELECT region, COUNT(DISTINCT USER_ID) FROM aud GROUP BY region` | **Pass** |

Three further sub-checks, each its own finding:

| Pattern | Line |
|---|---|
| `GROUP BY <identifier>` | `field_policy.py:141-147` |
| `WHERE <identifier> = ...` | `field_policy.py:148-154` |
| `JOIN ... ON <identifier>` | `field_policy.py:155-161` |

Identifier names are normalised at `field_policy.py:30-46` — `rampid`, `ramp_id`
→ `RAMP_ID`; `email`, `raw_email` → `RAW_EMAIL`.

---

## Worked example 3 — k_min

`field_policy.py:163-183`.

- No aggregation and no group by at all → fail immediately (line 165), severity `high`.
- Otherwise, find the largest `HAVING COUNT(...) >= N` in the SQL
  (`field_policy.py:83-88`; `> N` is read as `N+1`). If that is missing or below
  the configured threshold → fail (line 176).

Threshold comes from the rule's `value` on the payload, read at
`agents/privacy_agent.py:23-28`.

---

## The two LLM jobs compare against different things

### Job A — purpose match (`intent_analyzer.py:297`)

SQL vs **the stated purpose**. Permitted list at `intent_analyzer.py:18-25`:

```
model_training, inference, attribution_measurement,
statistical_analysis, aggregate_reporting, anonymized_analytics
```

Passes:

> Stated: "Measure campaign reach by age band"
> SQL: `SELECT age_band, COUNT(DISTINCT user_id) FROM aud GROUP BY age_band`

Reads as aggregate reporting — on the list.

Fails:

> Stated: "Measure campaign reach by age band"
> SQL: `SELECT email, purchase_ts FROM aud ORDER BY purchase_ts DESC LIMIT 1000`

Stated reach measurement; actually an extract of individuals. Mismatch.

Guardrails in the prompt, `intent_analyzer.py:328-341`:

| Guardrail | Line |
|---|---|
| Describe only constructs present — do not invent SQL | 328-330 |
| PII only from field flags, never column names | 331-334 |
| This rule scores purpose, not PII | 333-334 |
| No stated purpose → mismatch must be false | 335-336 |
| `unknown` is not a failure | 340-341 |

### Job B — custom English rules (`intent_analyzer.py:178`)

SQL vs **the rule text a clean room owner typed**. The sentence *is* the policy.

| Rule text | SQL | Result |
|---|---|---|
| "Queries must exclude records where consent_flag = false" | never mentions `consent_flag` | **Fail** — required construct absent (prompt line 224) |
| "Do not join more than two datasets" | three JOINs | **Fail** — forbidden construct present (line 225) |

Critical instruction at `intent_analyzer.py:220-221`:

> Ignore question purpose, business intent, and stated use case.

So Job B deliberately ignores the description that Job A is built around. Same
model, opposite instruction.

Which rules count as "custom": anything whose name is not one of the five seeded
defaults — `no_raw_extraction`, `no_pii_access`, `k_min`, `no_reidentification`,
`permitted_purposes` (`payload.py:18-24`).

---

## Fail-direction asymmetry

When the model is unavailable (no credentials, or `ATTESTATION_SKIP_LLM=1`):

| Check | Result | Line |
|---|---|---|
| Custom English rules | **Fail closed** | `intent_analyzer.py:199-206` |
| Purpose match | **Fail open — passes** | `intent_analyzer.py:309-321` |

The purpose branch returns `is_permitted: True` with
`"LLM skipped; intent treated as permitted unless other policies fail"`.

Deliberate, but worth knowing before trusting a run made with the LLM off.

---

## Running with no credentials

`agent.py:19`:

```python
def skip_llm() -> bool:
    return os.getenv("ATTESTATION_SKIP_LLM", "").lower() in ("1", "true", "yes")
```

`agent.py:33-36` — even without the env var, missing credentials degrade to a
warning and return `None` rather than crashing.

So `ATTESTATION_SKIP_LLM=1` still exercises: validate, orchestrator (sqlglot SQL
parse / Python AST), policy_engine, privacy_agent, report_generator, finalize,
enforcement mapping, and the whole wire format.

---

## Scoring and final status

- Per dataset: `score = passed / total * 100` (`agents/report_generator.py`).
- Enforcement mode → `nextAction` (`enforcement.py`):

| Mode | `nextAction` |
|---|---|
| `human_review` | always `HUMAN_REVIEW` |
| `auto_approve` | `AUTO_APPROVE` if score >= `confidence_threshold` (default 85) |
| `bootstrapped` | `BOOTSTRAP_HOLD` until enough approved questions, then as `auto_approve` |

- Across datasets: any `REJECTED` wins; all `APPROVED` → `APPROVED`; else
  `INREVIEW`.
