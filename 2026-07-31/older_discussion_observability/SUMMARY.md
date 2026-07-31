# SUMMARY — orinix / Cleanroom Observability, Full Discussion Archive (May–July 2026)

**Published:** 2026-07-31
**Author:** Aditya Bhardwaj
**Tickets:** DV-13856 (platform), DV-15090 / DV-15091 (M1), DV-15496 (epic), DV-15621 (XMI polling), DV-15898, DV-16045–16056

> **What this folder is.** The complete working archive behind the orinix
> observability design — 106 files spanning May to July 2026: meeting notes, Q&A
> transcripts, design iterations, Confluence drafts, Miro prompts, presentations and
> schema examples.
>
> **This is an index, not an analysis.** It maps the archive so you can find the
> right document. The distilled conclusions live in the sibling folder
> [`../2026-07-30-aditya-architect-followup/SUMMARY.md`](../2026-07-30-aditya-architect-followup/SUMMARY.md)
> — **read that first**, then come here for the history behind any specific decision.

---

## The problem, in one paragraph

XMI (a partner team) polls our API to learn when a Data Connection, Flow or Question
changes; DV-15621 records the resulting rate-limiting pain. **orinix** is the service
built to push those change notifications instead — ingesting events from producer
services into an `object_events` table, then serving them via a pull API
(`GetCleanroomEvents`), webhooks with HMAC signing, and GCP Pub/Sub. This archive
tracks that design from first sketches in May through the architect review at the end
of July.

---

## Arc of the discussion

| Period | What was being decided |
|---|---|
| **May 2026** | Shape of the thing: webhooks vs queues, delivery log, DLQ, circuit breaker, at-least-once + HMAC + fan-out. Product framing, MVP Confluence page, presentations. |
| **Early June** | Schema and ownership: polymorphic vs clean table designs, CloudEvents payload shape, cross-cloud justification, TL-meeting review. |
| **Late June** | Delivery and transport: SNS/SQS deep dive, Pub/Sub delivery, Lambda-bridge vs orinix trade-off, billing approach, XMI follow-ups with Joel and Jon. |
| **Early July** | Build decisions: language (Java vs Go vs hybrid), module structure, gRPC vs alternatives, delivery design pattern, auth mechanism, Ousterhout retrospective, PR 1. |
| **Mid July** | Auth deep dive (CAC, nexus, sidecar vs centralized, JWKS), QE support ask, audit-log expansion for Josh/Jon, ER/UML diagrams, idempotency and DLQ. |
| **Late July** | **The producer question** — where do events come from? Hank hooks vs service layer vs CDC. Culminates in the 2026-07-29/30 meetings and the architect follow-up. |

---

## Where to look, by question

**"How should events be produced?"** (the late-July thread, and the live question)
- `2026-07-24_best_approach_hank_vs_orinix_vs_cdc_qa.txt`
- `2026-07-24_can_orinix_live_inside_hank_full_analysis.txt`
- `2026-07-24_hank_host_and_cdc_simple_qa.txt`
- `2026-07-28_dataconnection_create_event_emission_service_layer_vs_hank_hooks.txt`
- `2026-07-29_orinix_exact_emission_points_v1_vs_v2_handlers.txt` — line-level patches
- `2026-07-29_orinix_event_emission_implementation_analysis_qa.txt`
- `2026-07-29_aditya_anil_josh_meet.txt` — the plain-language comparison
- `2026-07-30_aditya-josh-anil-q-and-a-30-july.txt` — transport and topic decisions

**"How does the data actually flow today?"**
- `2026-07-27_data_connection_create_update_delete_worked_examples_qa.txt`
- `2026-07-27_data_import_job_create_and_stage_change_full_trace_qa.txt`

**"Why not just use logs / Datadog / Loki for this?"**
- `2026-07-27_loki-datadog-hank-event-comparision.txt` — why a log store cannot back
  the read API

**"How is it delivered, and what are the guarantees?"**
- `2026-05-12_webhook_and_queue_design_discussion.md`
- `2026-05-12_delivery_log_dlq_circuit_breaker_deep_dive.md`
- `final_good_design_dlq_hmac_fanout_atleast_once.md`
- `qa_callback_ack_delivery_log_2026-05-12.md`
- `june-post-followup-observability-2026/2026-06-22_sns_sqs_architecture_deep_dive.md`
- `june-post-followup-observability-2026/2026-06-22_orinix_pubsub_delivery_discussion.md`
- `june-post-followup-observability-2026/2026-06-22_tradeoff_lambda_bridge_vs_orinix.md`
- `2026-07-27_sns_only_delivery_thin_events_and_xmi_ask_qa.txt`
- `2026-07-22_idempotency_dlq_and_miro_diagram_prompts.txt`
- `verify_webhook.py` — disposable local receiver that verifies the HMAC signature
  (`X-Habu-Signature`); `SIGNING_SECRET` is a `REPLACE_ME` placeholder

**"What does the event look like?"**
- `2026-06-01/cloudevents_real_payload_examples_2026-06-01.md`
- `adidas_event_schema_examples.md`
- `xmi_event_schema_pitch.md`
- `18_may_q_a_events.md`
- `2026-07-20_er_diagram_uml_and_schema_examples.txt`
- `2026-07-22_uml_class_diagram_mermaid_CLEAN.txt`

**"How is the table designed, and who owns what?"**
- `2026-06-01/clean_schema.md`, `2026-06-01/both_approach.md`
- `2026-06-01/polymorphic_table_examples_and_service_ownership.md`
- `2026-06-01/tlm_cross_cloud_justification_2026-06-01.md`
- `2026-06-02/DV-13856_Cleanroom_Observability_Design.md`
- `version_evolution_tables_apis_2026-05-12.md`

**"Why Java / this module layout / gRPC?"** — `orinix-why-and-how/`
- `q1` language, `q2` dependencies and modules, `q3` gRPC vs alternatives,
  `q4` delivery design pattern, `q5` zabra vs grpcclient split, `q6` external API auth
- `orinix-why-and-how/2026-07-06d_q1_FINAL_java_vs_go_vs_hybrid.txt` — the resolved language decision
- `orinix-why-and-how/2026-07-07_ousterhout_principles_retrospective.txt` — design principles applied,
  including the misses
- `q7` cursor/idempotency/HMAC/DLQ/WIF · `q8` RegisterCallback vs delivery + a schema
  drift bug · `q9` audit-log expansion · `q10` SNS topic reuse, FIFO vs Standard,
  thin vs fat events

**"How does auth work between orinix and XMI?"** — `aditya_auth_authz_orinix/`
- CAC authn/authz, sidecar vs centralized moonraker, JWKS, nexus vs CAC,
  service accounts, credential grant types
- `aditya_auth_authz_orinix/2026-07-22_FINAL_orinix_xmi_callback_approach.txt` — the resolved approach
- `2026-07-21_xmi_callback_auth_cac_pattern_from_max.txt` (top level)
- `xmi_team_auth_followup/2026-07-17_xmi_callback_auth_followup.txt`

**"What about the audit-log expansion?"** (Josh / Jon's separate ask)
- `2026-07-18_for_jon_audit_log_findings_summary.txt`
- `2026-07-20_confluence_audit_logging_section_for_design_review.txt`
- `orinix-why-and-how/2026-07-18_q9_audit_log_expansion_datadog_source_and_chained_relationships.txt`
- `june-post-followup-observability-2026/2026-06-30_jon_slack_message.txt`

**"What went into the Confluence design doc?"**
- `Conflunece_Design_Doc_Pated_6_07.txt`, `2026-07-07_confluence_update_draft.txt`,
  `2026-07-20_confluence_page_addition_final.txt`
- `DV-13856_MVP_Confluence_Page.md`, `DV-13856_Observability_Design_Discussion.md`

**"What was shown to stakeholders?"**
- `DV-13856_Architecture_Diagram.html`, `DV-13856_Platform_Architecture.html`,
  `DV-13856_MVP_Presentation.html`, `DV13856_Product_Walkthrough.html`,
  `2026-07-08_backstage_ui_mockup_orinix.html`
- `DV13856_Observability_Presentation.pptx` (+ `build_pptx.py` that generates it)
- `miro-prompt-july/observability-design-presentation-8-07-pdf.pdf`
- Miro prompts: `mirro_observability_may_2026_12.md`,
  `miro_prompts_v1_v2_v3_2026-05-13_best_22_05.md`, `miro_prompt_simple.md`,
  `2026-06-01/miro_prompts_*`, `2026-06-02/miro_prompt_*`, `miro-prompt-july/`
- `enterprise_style_arch_product.md`

**"What was actually built / shipped?"**
- `aditya_pr_observability/2026-07-09_pr1_full_walkthrough.txt` and `aditya_pr_observability/2026-07-09_pr1_info.txt`
- `orinix-working-principle/2026-07-06_pr1_file_manifest.txt`,
  `orinix-working-principle/2026-07-06_m1_delivery_scope.txt`, `orinix-working-principle/2026-07-06_lidac_prep_qa.txt`
- `2026-07-08_atlantis_automation_orinix_pr53157.txt`
- `2026-07-15_qe_support_ask_orinix.txt` — the three QE verification asks
- `aditya_jira_items/2026-07-13_dv15898_subtasks.txt`

**Terminology** — `aditya_orinix_key_terminology_july7.txt` is the glossary; start
there if the vocabulary (orinix, hank, forebitt, CAC, nexus, zabra, pegleg, janus,
picanmix, primage, unhygienix) is unfamiliar.

---

## Where this landed

The producer-side question was still open at the close of this archive. The
recommendation carried into the 2026-07-30 architect review was:

- **Produce events from the service layer**, not Hank's automatic GORM row hooks,
  change data capture, or database triggers — because a Data Connection spans two
  tables (`data_import_jobs` + `organization_job_parameters`), so one create is 5 row
  writes via the V2 route and 10 via V1, and only the service layer holds the actor,
  the values and the business-object identity at the same moment.
- **Level 1 detail** (current state) for the state transitions XMI is blocked on,
  **Level 2** (before/after) for object create/update/delete.
- Best-effort delivery for M1, stated honestly in the contract, plus a
  publish-failure metric.

Full reasoning, evidence and open questions:
[`../2026-07-30-aditya-architect-followup/SUMMARY.md`](../2026-07-30-aditya-architect-followup/SUMMARY.md).

---

## Notes on this archive

- Files are **preserved exactly as generated** — no edits, no regeneration. Naming and
  formatting conventions vary because they were written across three months.
- Most documents are dated by filename (`YYYY-MM-DD_`); a few early ones are not.
- Excluded from the copy: `.DS_Store` and an Office lock file
  (`~$DV13856_Observability_Presentation.pptx`). Nothing else was filtered.
- Scanned for credentials before publishing — none found. `verify_webhook.py` carries
  a `REPLACE_ME` placeholder, not a real signing secret.
