# What the model is actually given

All paths relative to
`/Users/adbhar/Documents/Habu_Cloned_Repo/agentic-core/core/agents/attestation-agent/`.

The agent makes **two** LLM calls per dataset, from one node
(`agents/intent_analyzer.py:387`). They are dispatched together at `:403-420`.

Worked example used throughout:

```sql
SELECT age_band, COUNT(DISTINCT USER_ID) AS reach FROM audience GROUP BY age_band
```

Fields on the payload:

| Column | Flags |
|---|---|
| `AGE_BAND` | none |
| `USER_ID` | `isUserId: true`, `identifierType: RAMP_ID` |
| `FIRST_NAME` | `isPii: true` |

---

## Job A — purpose match

System prompt: `intent_analyzer.py:322-350`. User prompt: `:351-364`.

Fully assembled user message:

```
Analyze this sql code:

```sql
SELECT age_band, COUNT(DISTINCT USER_ID) AS reach FROM audience GROUP BY age_band
```

Stated purpose (BusinessDesc / DataScienceDesc / TechnicalDesc):
BusinessDesc: Measure campaign reach by age band
Tables: audience
Has aggregation: True

Dataset fields (authoritative PII / identifier flags):
PII columns (isPii=true): FIRST_NAME
Identifier columns (isUserId or identifierType): USER_ID identifierType=RAMP_ID
Other mapped columns: AGE_BAND (isPii=false)
A column is PII only if listed under PII columns. Do not treat
EMAIL/ADDRESS/PHONE/NAME columns as PII unless listed.
```

Where each line comes from:

| Prompt line | Built at | Source of the value |
|---|---|---|
| `Analyze this {language} code:` | `:351` | `input_code(state)` at `:398` |
| the fenced SQL | `:353-355` | `input.code.text` on the payload |
| stated purpose | `:357-358` | `_stated_description(state, dataset)` at `:399`; literal `Not provided` when empty |
| `Tables:` | `:359` | `metadata['tables_referenced']` |
| `Has aggregation:` | `:360` | `metadata['has_aggregation']` |
| the field block | `:362-363` | `format_field_metadata(fields)` |

`format_field_metadata` is `:35-66`. It sorts every field into three buckets —
PII (`:49-50`), identifiers (`:51-54`), everything else (`:55-56`) — then appends
a closing instruction at `:64-65`. With no fields at all it returns an explicit
"do not infer PII from column names" string (`:39-42`).

Expected JSON response shape is pinned in the system prompt at `:341-350`.

---

## Job B — custom natural-language rules

System prompt: `intent_analyzer.py:218-240`. User prompt: `:241-250`.

With one custom rule, assembled user message:

```
Code (sql):

```sql
SELECT age_band, COUNT(DISTINCT USER_ID) AS reach FROM audience GROUP BY age_band
```

Columns referenced: age_band, USER_ID

Rules:
- policy_id: consent_check
  description: Queries must exclude records where consent_flag = false
  value: —
```

The rule block is assembled at `:210-216` — **one entry per rule, one call for
all of them**, not one call per rule.

`Columns referenced` comes from `metadata['columns_referenced']` at `:217`.

---

## The difference between the two calls

| Sent to the model | Job A | Job B |
|---|---|---|
| The SQL text | yes | yes |
| Stated purpose | yes | **no** |
| Tables referenced | yes | no |
| `has_aggregation` | yes | no |
| Columns referenced | via metadata | yes |
| **PII / identifier flags** | yes | **no** |

Job A's signature is `:297-305` and includes `fields`.
Job B's signature is `:178-185` — `rules`, `code`, `language`, `metadata`,
`model`. **There is no `fields` parameter.**

This is deliberate on the purpose side: `:220-221` instructs Job B to *ignore*
purpose and business intent, which is exactly the input Job A is built around.
Same model, opposite instruction.

---

## FINDING — an unfollowable instruction in Job B

`intent_analyzer.py:227`, inside Job B's system prompt:

> Do not infer PII from column names. PII is only what dataset field flags say.

But Job B is never given the field flags. `evaluate_nl_rules` (`:178-185`) has no
`fields` parameter, and the user prompt (`:241-250`) contains only code, column
names, and rule text.

The model is told to consult a list it does not have.

**Practical consequence:** a custom natural-language rule that depends on knowing
which column is PII cannot be evaluated correctly. The model can only fall back
on column names — which is precisely what the line forbids.

Status: **verified by reading the signature and the prompt**, not by running the
agent. Worth raising with the PR author (Anji Evana).

---

## Fail-direction asymmetry (restated with lines)

When `model is None` — no credentials, or `ATTESTATION_SKIP_LLM=1`:

| Job | Behaviour | Line |
|---|---|---|
| A (purpose) | returns `is_permitted: True`, reasoning `"LLM skipped; intent treated as permitted unless other policies fail"` | `:309-321` |
| B (custom rules) | every scorable rule fails closed | `:199-206` |

A rule with an empty `description` fails closed even before the model check
(`:192-197`).

Job A also swallows exceptions: any error inside `model.invoke` is caught at
`:370-382` and returns `is_permitted: True` with confidence `0.0`. So a Gemini
outage silently passes the purpose check.
