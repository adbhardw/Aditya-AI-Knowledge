# 08 — Decisions, Follow-ups and Verification Items

## 1. Decisions needed in the meeting

| ID | Decision | Options | My recommendation | Blocks |
|---|---|---|---|---|
| **D1** | Where do events come from? | Service function / Hank hooks / change data capture / DB triggers / request buffer | **Service function** (Option 1) | everything |
| **D2** | Is a Data Connection event org-scoped or cleanroom-scoped? | org / fan out per cleanroom / expand at read time | **org-scoped**, with cleanroom references in context fields | the table's primary query key |
| **D3** | How much detail in the message? | Level 0 / 1 / 2 | **Level 1** for state transitions, **Level 2** for object create/update/delete | payload code, security review |
| **D4** | Delivery guarantee for M1? | best-effort / retry / transactional outbox | **best-effort, stated honestly in the contract**, plus a failure metric | scope, XMI contract wording |
| **D5** | Where does the message contract live? | forebitt only / shared Go module / written JSON schema | **written schema**, each service owns its struct | second producer onboarding |
| **D6** | Per-handler emit, or request-scoped buffer? | Option 1 / Option 5 | **Option 1** for 7 sites; revisit if it grows | code shape |

---

## 2. Verification items — things I have claimed as open

These are all marked **[UNVERIFIED]** in the other documents. Each needs closing
before the corresponding piece of work starts.

| ID | Item | Why it matters | How to check |
|---|---|---|---|
| **V1** | Do the V1 doors (`CreateDataConnection`, `UpdateDataConnection`) and `CreateImportJobV2` / `UpdateImportJobV2` receive live traffic? | 3 sites versus 7; whether the double-emit guard is needed at all | API gateway / ALB access logs for the two route patterns; ask the UI team |
| **V2** | Do flow-run state changes carry parsed auth claims? | If not, Hank's hooks emit **nothing** for XMI's most important event — and our own `authUser` may also be absent, needing a system actor | Trace the flow-run completion path; check whether it goes through `BeginTxDB` with a context carrying claims |
| **V3** | Is `requestId` reliably populated in the audit record? | Decides whether the "correlate by request ID" counter-argument has any force | Query Loki for `Audit Log:` lines in prod and inspect the field |
| **V4** | p99 latency of `UpdateDataConnectionV2` today | So the "one extra read" claim has a number behind it | Existing dashboards, or add a timer |
| **V5** | Is `(ImportDataSourceParameterID, Name)` genuinely unique per job? | The settings diff depends on it as a stable key | `SELECT data_import_job_id, import_data_source_parameter_id, name, count(*) … HAVING count(*) > 1` |
| **V6** | Does anything parse the `Audit Log:` stdout lines today (Datadog monitors, the internal audit log delivered to Pegleg)? | Bounds how freely the hook output could change for Josh's M3 | Ask Josh; search Datadog monitor definitions |
| **V7** | Real Grafana Cloud Loki retention | The self-hosted chart's 168h is dead config; we should not quote it | Grafana Cloud org settings |
| **V8** | Expected event volume per day | Whether FIFO-versus-Standard and cost matter in practice | Count mutations per day from the audit lines in Loki |

---

## 3. Work breakdown, once D1-D3 are agreed

### Phase 0 — verify (before writing code)
- [ ] V1, V2, V5 — these three change the design, not just the estimate

### Phase 1 — the contract and helpers
- [ ] New package `forebitt/services/observability/`
- [ ] Event structs (CloudEvents envelope + `DATA_CONNECTION` data)
- [ ] `diffJob(before, after)` — explicit field list, doubles as the allow-list
- [ ] `diffParams(before, after)` keyed on `(ImportDataSourceParameterID, Name)`
- [ ] `applyPatch(before, patch)` — the six-field overlay, per `02 §5`
- [ ] `emitDataConnectionEvent(...)` — fire-and-forget, suppression-aware
- [ ] `WithSuppressed` / `IsSuppressed`
- [ ] Unit tests: create-with-N-settings, one field changed, one setting changed,
      setting added, setting removed, no-op update

### Phase 2 — transport wiring
- [ ] `forebitt/api/server/server.go:72` — add `ObservabilityEvents *hevent.Config`
      beside the existing `Events`
- [ ] `forebitt/cmd/forebitt/commands/server.go:86` — add
      `events.AddEvents(flags, "observability-events")`
- [ ] Publish via `hank/aws/sns` directly — **[VERIFIED]**
      `hank/aws/sns/service.go:34` already takes `message any`, so **no change to
      Hank is needed**
- [ ] Hold one SNS client rather than constructing one per publish
      (`hank/events/service.go:18` does the latter)
- [ ] Empty-ARN guard so this can merge and deploy before the topic exists
- [ ] A counter and an alert on publish failure (the minimum answer to D4)

### Phase 3 — the emit sites
- [ ] `dataConnections_v2.go:378` — create
- [ ] `dataConnections_v2.go:405` — add the settings before-image read
- [ ] `dataConnections_v2.go:453` — update
- [ ] `job_service.go:1932` — delete, beside the existing thin publish
- [ ] *If V1 says the legacy doors are live:* `job_service.go:1505`, `:1698`,
      `:1388`, `:1672`

### Phase 4 — infrastructure
- [ ] orinjade Terraform: new **Standard** SNS topic `habu-observability-events`,
      SQS ingest queue, subscription, queue policy, DLQ and redrive
- [ ] IAM: forebitt's role needs `sns:Publish` on the new topic
- [ ] `dyogram/charts/forebitt/values.yaml` — new topic ARN key (mirrors `:188`)
- [ ] `fiddley` control-plane forebitt overrides, stage then prod (mirrors
      `prod-overrides.yaml:78`)

### Phase 5 — orinix side
- [ ] SQS listener on the new queue
- [ ] Insert into `object_events` with `ON CONFLICT DO NOTHING` on the idempotency key
- [ ] Nothing else changes — the pull API, delivery and replay already read from
      `object_events`

### Phase 6 — rollout
- [ ] Merge behind the empty-ARN guard
- [ ] Enable in stage, confirm `object_events` rows have correct diffs
- [ ] QE verification (the three asks in `../2026-07-15_qe_support_ask_orinix.txt`)
- [ ] Enable in prod

---

## 4. Separate tickets to raise, not part of this work

These were all found while tracing and are real, but they are not orinix's problem
to fix.

| # | Finding | Where | Severity |
|---|---|---|---|
| 1 | **Delete audit records carry an empty `ObjectID`** — our existing audit log cannot say which data connection was deleted | `forebitt/db/job.go:185` passes an empty struct; `hank/db/audit.go` reads the ID off it | **Worth raising with Josh in this meeting** |
| 2 | Dead-code stage fallback — the `CONFIGURATION_COMPLETE` default is overwritten by an empty string | `dataConnections_v2.go:337-341` | Medium; `Stage` is what XMI keys off |
| 3 | `UpdateImportJobStage` writes `Status`, not `Stage`, despite the name | `job_service.go:1814` | Confirm intent before building on it |
| 4 | A phantom DELETE fires on every create because the clear runs unconditionally | `job_parameters.go:121` | Low; noise in the audit log |
| 5 | Settings get a fresh UUID on every save, so no ID-based history is possible | `job_parameters.go:150` | Design note rather than a bug; constrains any future settings-level history |
| 6 | The V1 create saves the whole connection twice | `job_service.go:1418` + `:1425` | Low; a cleanup opportunity if V1 is live |

---

## 5. What I will do immediately after the meeting

1. Write the decisions from §1 into the v6 Confluence design doc, in the sections
   already drafted for it.
2. Close V1, V2 and V5 — they are the three that change the design.
3. Raise finding 1 above as its own ticket, with Josh's agreement.
4. Update the Jira tickets (DV-16045-16056) to match whatever D1-D3 land as.
5. Send Anil and Josh a one-page summary of what was decided, so there is a written
   record neither of them has to reconstruct from memory.

---

## 6. Definition of done for M1, on this piece

- A create, an update and a delete of a Data Connection each produce **exactly one**
  row in `object_events`, with correct `changedFields`, verified in stage.
- The same is true whichever route the request came through.
- Publish failures are counted and alert.
- XMI can pull those events through `GetCleanroomEvents` and receive them by
  webhook.
- The message schema is written down somewhere XMI can read it.
