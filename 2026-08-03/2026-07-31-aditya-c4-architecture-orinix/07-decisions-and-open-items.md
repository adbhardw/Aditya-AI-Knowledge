# 07 — Decisions, Open Items and Architectural Risk Register

**Question this answers:** *What is settled, what is being asked for, what is
genuinely unknown — and which diagram changes if each answer changes?*

---

## 1. Decisions required — and what each one moves on the diagrams

| ID | Decision | Recommendation | If decided otherwise, this changes |
|---|---|---|---|
| **D1** | Where do events come from? | **Service function** (Option 1) | `04-components-producer.md` §2 entirely; `02-containers.md` producer edge; Orinix would need an **assembler component** it does not have today |
| **D2** | Data Connection event scoped to **org** or **cleanroom**? | **Org-scoped**, cleanroom refs in context fields | `object_events` **primary query key** (`03-components-orinix.md` §1); possibly a fan-out-per-cleanroom step in delivery |
| **D3** | How much detail? | **Level 1** for state transitions, **Level 2** for create/update/delete | Payload shape everywhere; whether a **security review** is needed at all; the update-path before-image read |
| **D4** | Delivery guarantee for M1? | **Best-effort, stated honestly**, + a failure metric | Flow 6 in `05-runtime-flows.md`; an outbox adds a component **inside forebitt's transaction** |
| **D5** | Where does the message contract live? | **Written JSON schema**, each service owns its struct | Onboarding of unhygienix/picanmix as producers (M2+) |
| **D6** | Per-handler emit, or request-scoped buffer? | **Option 1** for 7 sites; revisit if it grows | Removes the suppression flag from `04-components-producer.md` §7 and centralises publish |

### D2 deserves special attention

`DataImportJob` carries `OrganizationID` and **no cleanroom ID at all**
(`forebitt/models/data_import_job.go:20`), yet the event format uses
`source: urn:habu:cleanroom:<cleanroom-id>` and `object_events` is queried by
`cleanroom_id`. A connection is org-scoped and can serve several cleanrooms.

Three options: (a) emit as an organisation event with a null cleanroom, (b) emit one
copy per attached cleanroom, (c) emit once and let Orinix expand at read time.

> The review names this *"the riskiest thing on the list"* — building before deciding
> it is worse than the delay, because it sets the primary query key of the table
> everything reads from. **Cheap now, expensive later.**

---

## 2. Verification items — open questions with design consequences

| ID | Item | Why it matters | How to close |
|---|---|---|---|
| **V1** | Do the V1 doors and `CreateImportJobV2` / `UpdateImportJobV2` receive live traffic? | **3 emit sites vs 7**; whether the double-emit guard is needed at all | API gateway / ALB access logs; ask the UI team |
| **V2** | Do flow-run state changes carry parsed auth claims? | If not, **hooks emit nothing** for XMI's most important event — and Option 1 may need a system actor | Trace the flow-run completion path; check `BeginTxDB` context |
| **V3** | Is `requestId` reliably populated in the audit record? | Decides whether "correlate by request ID" has any force | Query Loki for `Audit Log:` lines in prod |
| **V4** | p99 latency of `UpdateDataConnectionV2` | So "one extra read" has a **number** behind it | Existing dashboards, or add a timer |
| **V5** | Is `(ImportDataSourceParameterID, Name)` unique per job? | The settings diff depends on it as a **stable key** | `SELECT … HAVING count(*) > 1` |
| **V6** | Does anything parse the `Audit Log:` stdout lines today? | Bounds how freely hook output can change for Josh's M3 | Ask Josh; search Datadog monitors |
| **V7** | Real Grafana Cloud Loki retention | The self-hosted chart's 168h is **dead config** — do not quote it | Grafana Cloud org settings |
| **V8** | Expected event volume per day | Whether FIFO-vs-Standard and cost matter in practice | Count mutations/day from Loki |

**Phase 0 gate: V1, V2, V5** — these three change the design, not just the estimate.

---

## 3. Architectural risk register

| # | Risk | Likelihood | Impact | Mitigation | Owner |
|---|---|---|---|---|---|
| **R1** | Flow-run events emit nothing because no auth claims reach the context | **[UNVERIFIED], assessed high** | **Critical** — kills XMI's primary use case | Close V2 before building; system actor fallback | Producer |
| **R2** | Silent event loss; we cannot say how many | Certain today | High — an *observability* product on a best-effort transport | Failure counter + alert (min); outbox (proper) | Producer |
| **R3** | Suppression flag forgotten on a new write path → double emit with distinct IDs, **idempotency key does not help** | Medium | Medium-High | Option 5 removes it structurally | Producer |
| **R4** | New write path added without an emit block → **silence** | Medium over time | Medium | Two files only; a test that fails when a handler writes without emitting; volume monitoring | Producer |
| **R5** | `object_events` 90-day delete hits mid-integration | Certain at day 91 | Medium | Hot/cold tier split | Orinix |
| **R6** | D2 decided late → primary query key wrong | Medium | **High** — expensive to change after XMI integrates | Decide in this meeting | Architecture |
| **R7** | Emit block drifts from the handler on refactor | Medium | Medium | Emit reads the same variables as the response, so a breaking refactor also breaks tested response behaviour | Producer |
| **R8** | Customer-identifying values (S3 URIs, table names) sent to partner without sign-off | Medium | **High** (compliance) | Explicit field allow-list; close Q13/Q14 | Security |
| **R9** | No end-to-end health check | Certain today | Medium | Design one (Q9) | Platform |
| **R10** | Consumer falls behind; no back-pressure design | Low now, rises with volume | Medium | Q12 | Orinix |
| **R11** | `Stage` can land empty (`dataConnections_v2.go:337-341` dead fallback) and **`Stage` is what XMI keys off** | Confirmed defect | Medium | Separate ticket; **do not ship a known-wrong value to a partner** | Producer |

---

## 4. Edge cases carried from the review

| # | Edge case | Status |
|---|---|---|
| **E1** | Door B's draft-then-final double save → `CREATED` then `UPDATED` for one user create | **Real** — handled by emitting once from the outer handler, *but only because of the suppression flag* |
| **E2** | Background worker changes flow-run state with no auth claims | **[UNVERIFIED], high risk** — see R1/V2 |
| **E3** | Settings containing customer-identifying data travelling to a partner | **Real** — needs an explicit allow-list, which Option 1 gives by construction |
| **E4** | A connection used by several cleanrooms when the format is keyed by cleanroom | **Real and unresolved** — D2 |
| **E5** | `object_events` hitting 90 days mid-integration | Known; two-tier archive addresses it, not built |
| **E6** | Two concurrent updates producing out-of-order events | Mitigated by producer-stamped `event_time`; XMI consumers are last-state-wins |
| **E7** | SNS 256 KB message limit with a large settings set | Unlikely; fallback is publishing a reference |
| **E8** | Event emitted for a transaction later rolled back | **Cannot happen** — publish is strictly after `COMMIT` |

Additional correctness questions the review raises and does **not** answer: what event
(if any) a **no-op update** should produce; whether a **client retry** should be
de-duplicated (it produces two events with different IDs); and **soft-delete
resurrection** — we send `DELETED` but the row still exists and could in principle be
undeleted.

---

## 5. Technical debt this design creates

| Debt | Severity | Note |
|---|---|---|
| Emit blocks duplicated across 7 sites | Low | Mechanical, reviewable, in two files |
| Suppression flag is correctness-critical but easy to forget | **Medium** | Option 5 removes it entirely |
| Fire-and-forget publish with no metric | **Medium** | Counter + alert at minimum |
| Event schema defined in forebitt, will need sharing | Low-Medium | D5 |

## 6. Pre-existing defects this work *revealed* (separate tickets)

| # | Finding | Where | Severity |
|---|---|---|---|
| 1 | **Delete audit records carry an empty `ObjectID`** — our shipped audit log cannot say which connection was deleted | `forebitt/db/job.go:185` + `hank/db/audit.go` | **Raise with Josh — worth a ticket on its own merits** |
| 2 | Dead-code stage fallback overwritten by `""` | `dataConnections_v2.go:337-341` | Medium |
| 3 | `UpdateImportJobStage` writes `Status`, not `Stage` | `job_service.go:1814` | Confirm intent |
| 4 | Phantom DELETE on every create | `job_parameters.go:121` | Low |
| 5 | Settings re-keyed with a new UUID every save → no ID-based history | `job_parameters.go:150` | Design constraint |
| 6 | V1 create saves the whole connection twice | `job_service.go:1418` + `:1425` | Low |
| 7 | New SNS client constructed on **every** publish | `hank/events/service.go:18` | Low |

---

## 7. The fallback position, if approval stalls

Smallest thing worth agreeing to (`06-meeting-preparation.md §7`):

> Instrument only `CreateDataConnectionV2`, `UpdateDataConnectionV2` and
> `DeleteImportJob`, at **Level 1**, behind an **empty-topic-ARN guard**.

Three blocks of code · no security review · no new infrastructure until the topic
exists · proves the end-to-end path with XMI. Everything else — V1 doors, Level 2
payloads, the audit tier — becomes a second conversation with real data behind it.

---

## 8. Traceability — diagram element → source document

| Diagram element | Source |
|---|---|
| C1–C6 constraints | `01-problem.md §4` |
| Two-table storage; delete-then-reinsert | `01-problem.md §3.1-3.2`; `job_parameters.go:109-167` |
| Three doors; 5-vs-10 event count | `02-current-design.md §1, §4` |
| "Free at line 378" | `02-current-design.md §2 Step 7` |
| Update-path six-field trap | `02-current-design.md §5` |
| Empty `ObjectID` on delete | `02-current-design.md §6, §7` |
| Two independent Hank pipelines | `02-current-design.md §8` |
| Five options; three payload levels | `03-design-options.md` |
| Seven-requirement scorecard | `04-tradeoffs.md §1` |
| Replication-slot disk failure | `04-tradeoffs.md §4.3` |
| FIFO `MessageGroupId` finding | `04-tradeoffs.md §5` |
| Risks, edge cases, tech debt | `05-architect-review.md` |
| Counter-arguments; fallback position | `06-meeting-preparation.md §3, §7` |
| Q1–Q18 open questions | `07-questions-to-ask.md` |
| D1–D6, V1–V8, phases, DoD | `08-next-steps.md` |

---

## 9. The question the author most wants answered

> Given that the row-level mechanisms give us either the values **or** the actor but
> never both, and the service layer gives us both **plus** the business object — is
> there a reason you would still prefer a row-level mechanism that I am not seeing?

If the answer is no, D1 is approved. If yes, that is the thing worth learning from
this review.
