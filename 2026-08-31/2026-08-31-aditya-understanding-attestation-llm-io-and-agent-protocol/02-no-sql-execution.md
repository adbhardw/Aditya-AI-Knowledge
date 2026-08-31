# The agent never executes SQL — and where sqlglot actually runs

Paths relative to
`/Users/adbhar/Documents/Habu_Cloned_Repo/agentic-core/core/agents/attestation-agent/`.

---

## Proof, not assertion

Searched the whole agent directory (excluding `tests/`) for anything capable of
running a query:

```
snowflake | duckdb | psycopg | sqlalchemy | bigquery | pymysql |
asyncpg | databricks | .execute( | .connect( | fetchall |
cursor( | create_engine
```

**Zero matches.** No driver, no connection, no cursor. There is nothing present
that *could* execute a query even if the code wanted to.

## Complete outbound network surface

| File:line | Destination | Purpose |
|---|---|---|
| `unhygienix_client.py:172` | unhygienix | fetch Golden Set examples |
| — (via LangChain model object) | Gemini | the two LLM calls |

Everything else matching `httpx` is out of the production path:
`scripts/invoke_attestation_local.py:108` (local dev script) and
`evaluation/eval_config.py:37,74` (eval harness).

No data warehouse is reachable.

---

## What happens to the SQL instead

`tools/code_parser.py:266`:

```python
statements = [s for s in sqlglot.parse(code, error_level="ignore") if s is not None]
```

`sqlglot.parse` turns text into a syntax tree. That is the entire operation — it
inspects grammar, it does not act on meaning. `error_level="ignore"` means
malformed SQL degrades to less information rather than raising.

Facts extracted from the tree, and who consumes each:

| Fact | Consumer |
|---|---|
| columns named | PII check (`tools/field_policy.py:104`) |
| tables named | Job A prompt (`agents/intent_analyzer.py:359`) |
| presence of `GROUP BY` | re-identification check (`field_policy.py:132`) |
| presence of aggregation | `k_min` (`field_policy.py:165`) |
| `HAVING COUNT(...) >= N` | `k_min` threshold (`field_policy.py:65-69`) |

---

## Why this is the correct design

The premise of a Clean Room is that the reviewing party must not be able to see
the other party's data. **If attestation ran the query to check it, the check
itself would be the leak.**

There is also an ordering constraint: attestation runs at question
approval time, before any execution. There is no result set to look at even if
looking were permitted.

## The cost

Everything rests on the field flags being correct. If a dataset is configured
without `isPii: true` on a name column, `field_policy.py:111` skips it and the
query passes. The agent has no independent way to notice — it cannot sample the
column and observe that it contains names.

**Trade: zero leak risk, total dependence on correct dataset setup.**

---

## Where sqlglot is handed to `intent_analyzer`

It is not. `agents/intent_analyzer.py` imports neither `sqlglot` nor
`code_parser` (verified by grep — no matches).

sqlglot runs **once per dataset**, three nodes earlier, in the orchestrator.

| Step | File:line | What |
|---|---|---|
| 1 | `agents/orchestrator.py:9` | imports `CodeParser` |
| 2 | `agents/orchestrator.py:46` | `CodeParser().parse(...)` — sqlglot runs here |
| 3 | `agents/orchestrator.py:56-75` | flattens the result to plain dicts and **returns** them |
| 4 | (LangGraph) | merges the returned dict onto graph state |
| 5 | `agents/intent_analyzer.py:400` | `metadata = state.code_metadata or {}` |
| 6 | `agents/intent_analyzer.py:409, 417` | passes it into both LLM functions |

Steps 3→4 are the wire. `orchestrator.py:59` writes the key `code_metadata`;
`intent_analyzer.py:400` reads `state.code_metadata`. The fields are declared on
the state model at `state.py:99-100`.

### What crosses that wire

`orchestrator.py:59-75` — fifteen scalars and lists, no objects:

```
language, line_count, char_count, has_imports, has_functions, has_classes,
tables_referenced, columns_referenced, aggregations_used, has_aggregation,
statement_type, has_joins, has_where, has_group_by, has_limit
```

Of those fifteen, the LLM functions use **three**:

| Used | Where | Line |
|---|---|---|
| `tables_referenced` | Job A prompt | `intent_analyzer.py:359` |
| `has_aggregation` | Job A prompt | `intent_analyzer.py:360` |
| `columns_referenced` | Job B prompt | `intent_analyzer.py:217` |

The remaining twelve serve the deterministic checks and the report.

### The AST never leaves the orchestrator

`parsed_code.to_dict()` at `orchestrator.py:58` is the boundary. The tree is
converted to a dictionary there and never rebuilt. By the time
`intent_analyzer` runs, only names and booleans survive.

That is why Job A's prompt fence at `intent_analyzer.py:328-330` says *"Describe
ONLY constructs that appear in the code"* — the model is handed raw SQL text plus
a few extracted facts, and must read the SQL itself for anything else. It is not
given a structured tree it could reason over reliably.

### Parse failure short-circuits the LLM entirely

`orchestrator.py:47-54`: if `parsed_code.is_valid` is false, the node returns
`REJECTED` and the graph routes straight to `report_generator`. `intent_analyzer`
never runs.

**So both LLM calls only ever see SQL that parsed cleanly.**
