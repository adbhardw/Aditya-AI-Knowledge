================================================================================
Launching agentic-core locally — attestation-agent (PR #1160) + cleanroom-assistant
Date: 2026-08-25
Repo: /Users/adbhar/Documents/Habu_Cloned_Repo/agentic-core
PR:   https://github.com/LiveRamp/agentic-core/pull/1160  (DV-16464, branch hackathon_attestation, author Anji Evana, OPEN)
================================================================================

--------------------------------------------------------------------------------
0. HEADLINE
--------------------------------------------------------------------------------
Two agents, two very different difficulty levels:

  attestation-agent   -> EASY. Stateless graph, no Habu backend needed, runs
                         end-to-end with ZERO credentials. This is your target.
  cleanroom-assistant -> HARD. Needs a real LiveRamp JWT + Identity Bridge to
                         reach Habu microservices. Cannot be run "cold".

Start with attestation-agent.

--------------------------------------------------------------------------------
1. STATE OF YOUR LOCAL CLONE (before this session)
--------------------------------------------------------------------------------
HEAD              d4c3b9cd  "Merge pull request #602 ..."  (July 7, 2026)
origin/main now   01a94d47                                  (~1300 commits ahead)
Working tree      M  core/agents/__init__.py
                  ?? .agents/  .codex/  core/agents/habu-dc-export-assistant/

Your clone predates attestation-agent entirely. core/agents/ locally has 15
agents; the PR branch has 24, including attestation-agent, asset-search,
seceng-triage-agent, usb-sentinel-agent, activation, ax_chat_agent, example_ui.

--------------------------------------------------------------------------------
2. WHAT I DID FOR YOU THIS SESSION
--------------------------------------------------------------------------------
[x] git fetch origin hackathon_attestation:hackathon_attestation
        -> local branch created, head 7abde6f2
           "Honor owner Golden approve/reject on similar Golden Set rules."
[x] pip install uv                 -> /Users/adbhar/.pyenv/shims/uv
[x] cp core/.env.example core/.env  (gitignored, safe)
[x] mkdir -p .secrets

NOT done (your call):
[ ] git checkout hackathon_attestation   — you have uncommitted changes
[ ] start Docker Desktop                 — `docker info` reports NOT RUNNING
[ ] supply a Google credential            — optional, see section 5

--------------------------------------------------------------------------------
3. THE LAUNCH SEQUENCE (attestation-agent)
--------------------------------------------------------------------------------
Step 1 — stash your local work and switch branch
    cd /Users/adbhar/Documents/Habu_Cloned_Repo/agentic-core
    git stash push -u core/agents/__init__.py core/agents/habu-dc-export-assistant
    git checkout hackathon_attestation

Step 2 — start Docker Desktop (GUI), then confirm
    docker info | head -3

Step 3 — re-copy .env (branch's .env.example is 1300 commits newer)
    cp core/.env.example core/.env

Step 4 — bring up infra (postgres, langfuse, chromadb, clickhouse, redis)
    uv run infra

Step 5 — start the agent server with the attestation graph
    export ATTESTATION_SKIP_LLM=1        # no Gemini needed, see section 5
    uv run serve attestation-agent

Step 6 — verify the graph registered
    curl -s localhost:8080/health
    curl -s -X POST localhost:8080/assistants/search \
      -H 'Content-Type: application/json' \
      -d '{"graph_id":"attestation-agent"}' | python3 -m json.tool

Step 7 — fire a real /runs/wait payload
    python3 core/agents/attestation-agent/scripts/invoke_attestation_local.py
    python3 core/agents/attestation-agent/scripts/invoke_attestation_local.py --scenario fail_pii
    python3 core/agents/attestation-agent/scripts/invoke_attestation_local.py --scenario fail_kmin
    python3 core/agents/attestation-agent/scripts/invoke_attestation_local.py --print-request --scenario fail_raw

    Scenarios: pass | fail_all | fail_raw | fail_pii | fail_kmin | fail_reid | fail_purpose

Step 8 — unit tests (no Docker required at all)
    uv run test-unit attestation-agent

--------------------------------------------------------------------------------
4. WHAT EACH COMMAND ACTUALLY DOES — concrete trace
--------------------------------------------------------------------------------
`uv run infra` and `uv run serve` are NOT make targets. They are console_scripts
declared in pyproject.toml pointing into local_dev_mcp_server.py — the same file
is both an MCP server and a CLI.

    pyproject.toml:34   infra = "local_dev_mcp_server:cli_infra"
    pyproject.toml:36   serve = "local_dev_mcp_server:cli_serve"

TRACE: `uv run serve attestation-agent`

  T1  local_dev_mcp_server.py:935   cli_serve() -> _parse_agent_arg()
                                    argv[1] = "attestation-agent"
  T2  local_dev_mcp_server.py:401   _agent_override("attestation-agent")
                                    looks for core/agents/attestation-agent/docker-compose.override.yml
                                    -> does NOT exist in PR #1160 -> None (no sidecars)
  T3  local_dev_mcp_server.py:416   docker compose up -d <SERVE_SERVICES>
                                    brings up agent-server, agent-cors-proxy, UIs
  T4  docker-compose.yml:221        AEGRA_CONFIG=local.aegra.json
  T5  docker-compose.yml:250-251    volumes:
                                      ./core                          -> /app/core          (ro)
                                      ./deployments/aegra/local.aegra.json -> /app/local.aegra.json (ro)
  T6  local.aegra.json (PR branch)  "attestation-agent":
                                      "./core/agents/attestation-agent/graph.py:graph"
  T7  local_dev_mcp_server.py:410   uv run uvicorn search.search_server:app --port 8081 --reload
                                    (search server, local process, hot reload)
  T8  local_dev_mcp_server.py:430   waits on /health for 8080, 8081, 8085

The critical line is T5+T6. Because ./core is bind-mounted and local.aegra.json is
bind-mounted, adding the graph to local.aegra.json is ALL that registers it.
No image rebuild. After editing graph code:

    docker compose restart agent-server

TRACE: the invoke script (scripts/invoke_attestation_local.py)

  T1  POST /assistants/search  {"graph_id":"attestation-agent"}  -> assistant_id
  T2  POST /threads {}                                            -> thread_id
  T3  POST /threads/{id}/runs/wait  {assistant_id, input, config.configurable.org_id}
  T4  GET  /threads/{id}/state
  T5  _extract_envelope(): take last message with type=="ai", json.loads(content),
      require "datasets" key; fall back to values["report_envelope"]

  T5 is the same extraction path Unhygienix uses for DAR assist. That is the
  contract — the agent writes the camelCase report envelope onto the last AI
  message, not into a custom response field.

GRAPH SHAPE (core/agents/attestation-agent/graph.py):

  START -> validate -> orchestrator -> policy_engine -> privacy_agent
        -> intent_analyzer -> golden_set_judge -> report_generator
        -> (next dataset | finalize) -> END

  validate fails         -> fail_closed -> END
  parse/language fails   -> straight to report_generator (fail closed per dataset)
  skip_golden_eval=true  -> intent_analyzer skips golden_set_judge

  Deterministic nodes (no LLM): policy_engine (regex patterns[]),
                                privacy_agent (no_pii_access, no_reidentification,
                                               k_min, no_raw_extraction)
  LLM nodes:                    intent_analyzer (permitted_purposes + custom NL rules),
                                golden_set_judge

  Score = passed/total x 100. suggestedStatus across datasets: REJECTED wins,
  else all APPROVED -> APPROVED, else INREVIEW.

--------------------------------------------------------------------------------
5. CREDENTIALS — why you can skip Gemini entirely
--------------------------------------------------------------------------------
README quick-start says you need a Google service account or GOOGLE_API_KEY.
For attestation-agent that is FALSE. Two independent escape hatches:

  (a) core/agents/attestation-agent/agent.py:19
          def skip_llm(): return os.getenv("ATTESTATION_SKIP_LLM","").lower() in ("1","true","yes")
      get_model() returns None immediately -> intent_analyzer and
      golden_set_judge are no-ops.

  (b) core/agents/attestation-agent/agent.py:33-36
          except Exception as exc:
              logger.warning("Gemini unavailable; skipping LLM attestation checks: %s", exc)
              return None
      Even WITHOUT the env var, missing credentials degrade to a warning, not a
      crash. The graph still returns a full envelope.

So with ATTESTATION_SKIP_LLM=1 you exercise: validate, orchestrator (sqlglot SQL
parse / Python AST), policy_engine, privacy_agent, report_generator, finalize,
enforcement mapping, and the whole wire format. That is the majority of the graph.

What you LOSE without Gemini: permitted_purposes scoring and custom
natural-language rule scoring, plus golden-set LLM judging.

DEPENDENCY NOTE: sqlglot==25.0 is already in core/pyproject.toml:42 (it was added
for segmentation_agent's sql_to_tree). PR #1160 adds NO new dependencies. Nothing
to install.

--------------------------------------------------------------------------------
6. ENFORCEMENT MODES — what --enforcement-mode changes
--------------------------------------------------------------------------------
Per-dataset attestation_ds_enf_settings.mode -> nextAction:

  human_review   always HUMAN_REVIEW
  auto_approve   AUTO_APPROVE if score >= confidence_threshold (default 85)
  bootstrapped   BOOTSTRAP_HOLD until approved_questions[] reaches
                 reviews_before_auto_approve, then behaves as auto_approve

  python3 .../invoke_attestation_local.py --enforcement-mode auto_approve
  python3 .../invoke_attestation_local.py --enforcement-mode bootstrapped

Graduation state lives in Unhygienix, NOT in the agent. The agent only reads the
payload it is handed.

--------------------------------------------------------------------------------
7. GOLDEN SET / UNHYGIENIX — leave it off locally
--------------------------------------------------------------------------------
golden_set_judge fetches "fat" examples from Unhygienix by CRQ ID and overlays a
manual GOLDEN_APPROVE / GOLDEN_REJECT verdict onto a matching rule. Fetch path:

  - prefers Identity Bridge (ib_post) when config.configurable.access_token is set
  - IDENTITY_BRIDGE_BASE_URL is what dev-us Helm sets
  - ATTESTATION_UNHYGIENIX_BASE_URL / UNHYGIENIX_BASE_URL is a LOCAL-ONLY direct
    fallback. Do NOT set it in Kubernetes — Habu backends reject LiveRamp tokens.

If the fetch is empty or errors, the engine verdict stands. So it is safe to run
with no Unhygienix at all. Set skip_golden_eval=true (or just leave
ATTESTATION_SKIP_LLM=1) to bypass the node.

--------------------------------------------------------------------------------
8. CLEANROOM-ASSISTANT — the harder one
--------------------------------------------------------------------------------
graph_id: cleanroom-assistant. Already present in YOUR clone AND on the PR branch,
so it is already in local.aegra.json either way:

    uv run serve cleanroom-assistant

But it is an orchestrator that routes to subgraphs, and the subgraphs call real
Habu microservices through Identity Bridge:

  - Flow diagnostician    graph_flow_diagnostician.py   read-only flow tools
  - Habu Intelligence     graph_intelligence.py         needs CLEANROOM_INTELLIGENCE_MCP_URL
                          dev: https://mcp-cleanroom-intelligence.dev.liveramp.com/mcp
                          uses caller's LiveRamp JWT (resolve_lr_token / resolve_org_id
                          in shared/mcp/intelligence_auth.py, shared with xmi_agent)
  - DAR assist            graph_dar_assist.py           analysis-rule validation

Env it reads: IDENTITY_BRIDGE_BASE_URL, IDENTITY_BRIDGE_TIMEOUT_S,
CLEANROOM_INTELLIGENCE_MCP_URL, LR_ORG_ID, TOKEN, AGENT_BASE_URL,
GEN_TEST_TOKEN_SCRIPT, UNHYGIENIX_FIXTURES_DIR, INVOKE_TIMEOUT_S.

There is no SKIP_LLM-style escape hatch here — without a valid LR JWT the tools
fail. UNHYGIENIX_FIXTURES_DIR is the closest thing to an offline mode; worth
investigating if you want to run it cold.

Full onboarding doc: core/agents/cleanroom-assistant/README.md, "Cleanroom Agent —
End-to-End Guide for New Engineers", 16 sections, assumes zero LangGraph
knowledge. Section 13 is "Running Locally". Read that before attempting.

--------------------------------------------------------------------------------
9. PORT MAP
--------------------------------------------------------------------------------
  8080  agent-server (Aegra)         <- attestation-agent lives here
  8081  search-server (local uvicorn, hot reload)
  8082  Langfuse UI                  admin@example.com / admin123
  8083  ChromaDB
  8085  agent-cors-proxy             connect.dev -> local agent
  3000  Agent Chat UI
  5432  Postgres
  8123  ClickHouse
  6379  Redis

Note: attestation-agent is STATELESS — it does not use the Postgres checkpointer.
Postgres is still required because Aegra itself needs it.

--------------------------------------------------------------------------------
10. PREREQ STATUS SNAPSHOT (2026-08-25)
--------------------------------------------------------------------------------
  python3     3.11.9   OK  (pyenv)
  uv          OK       installed this session
  docker      OK       binary at /usr/local/bin/docker
  dockerd     BLOCKED  not running — start Docker Desktop
  core/.env   OK       created this session from .env.example
  .secrets/   OK       created, empty (fine with ATTESTATION_SKIP_LLM=1)
  branch      FETCHED  hackathon_attestation @ 7abde6f2, not checked out

--------------------------------------------------------------------------------
11. GOTCHAS
--------------------------------------------------------------------------------
- `uv run test` / `uv run serve` take a POSITIONAL agent name, not a flag.
      uv run test-unit attestation-agent      correct
      uv run test-unit --agent attestation... wrong
- Import path is agents.attestation_agent (underscore), directory is
  attestation-agent (hyphen). Handled by _HYPHEN_AGENTS in core/agents/__init__.py.
  PR #1160 adds one line there — if you cherry-pick files instead of checking out
  the branch, do not miss it.
- ./core is mounted READ-ONLY in the container. Edit on the host, then
  `docker compose restart agent-server`. Do not edit inside the container.
- Your local core/agents/__init__.py is already modified. That is the same file
  PR #1160 touches -> guaranteed conflict if you rebase rather than stash.
- The invoke script's default org id is 01FS8JAJKVRV8S1D9J3GFASB4C. Override with
  --lr-org-id or LR_ORG_ID.
- Do not set ATTESTATION_UNHYGIENIX_BASE_URL anywhere but locally.

--------------------------------------------------------------------------------
12. NEXT ACTIONS
--------------------------------------------------------------------------------
1. Start Docker Desktop.
2. git stash push -u ...  &&  git checkout hackathon_attestation
3. cp core/.env.example core/.env   (branch version)
4. uv run test-unit attestation-agent      <- fastest possible signal, no Docker
5. uv run infra && ATTESTATION_SKIP_LLM=1 uv run serve attestation-agent
6. python3 core/agents/attestation-agent/scripts/invoke_attestation_local.py
7. Only then look at cleanroom-assistant, and get an LR JWT first.

Companion PRs to read for the full picture: moonraker (flipper flag),
unhygienix (the APIs that hydrate the payload), cleanroom-ui (the UI).
