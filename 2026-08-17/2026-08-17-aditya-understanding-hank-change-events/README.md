# hank Change Events → XMI (2026-08-17)

**Start here: [SUMMARY.md](SUMMARY.md)** — self-contained account of the whole session, written so another AI assistant can pick it up without reading anything else.

How hank publishes CloudEvents change notifications to XMI from a gorm model-layer audit hook: how the single SNS client is wired (and why there is no per-operation client), what XMI can filter on, and an audit that found 7 write paths in forebitt that commit silently with no event and no audit log.

## Contents

| File | What it contains |
|---|---|
| [SUMMARY.md](SUMMARY.md) | Executive summary — architecture diagram, runtime flow, the 7 defects, filter-policy recommendation, trade-offs, open questions |
| [2026-08-17_publisher_wiring_and_gorm_values_map.txt](2026-08-17_publisher_wiring_and_gorm_values_map.txt) | Old per-call `hevent.New` vs new construction-site wiring, side by side. Why `InstantSet` not `Set`, how gorm's `clone()` propagates the publisher to every derived DB, how the same mechanism carries the request `context` at a different lifetime, the full 4-hop emit path, and the dead `publisher.Close()` |
| [2026-08-17_xmi_filtering_and_15_event_run.txt](2026-08-17_xmi_filtering_and_15_event_run.txt) | For the XMI team. Payload shape, three ID layers and which to dedupe on, why `subject` is not filterable, terraform filter policies, the `object` vs `objectType` naming mismatch, the 15-event run, and the proven cross-group ordering finding |
| [2026-08-17_method_find_silently_skipped_change_events.txt](2026-08-17_method_find_silently_skipped_change_events.txt) | **Reusable procedure.** Step-by-step greps and awk sweep to find writes that emit nothing, triage rules for false positives, the 7 forebitt findings, and how to run it against unhygienix and picanmix for FLOW / FLOW_RUN / DATASET |
| [2026-08-17_publish15_harness.sh](2026-08-17_publish15_harness.sh) | Publisher used for the verification run — 15 DATA_CONNECTION events over 6 request groups, mirroring exactly what `publishOne()` puts on the wire |
| [2026-08-17_consumer_run_output_15_dataconnection_events.log](2026-08-17_consumer_run_output_15_dataconnection_events.log) | Full Java consumer output, 15 events, 15/15 CloudEvents-valid, sorted by MessageId + per-group delivery order |
| [2026-08-15_consumer_run_output_23_events.log](2026-08-15_consumer_run_output_23_events.log) | Prior run, 23 mixed events over 13 groups, 23/23 valid |

## Scope note

Everything here was run against a **personal test topic and queue** in account `930272866731` (`aditya-change-events.fifo`), with a local forebitt, not against Clean Room stage or prod. The hank code paths and line numbers are real; the topic, queue, org id and object ids are test fixtures.

`DATA_CONNECTION` is verified clean end to end. `FLOW`, `FLOW_RUN` and `DATASET` were **not** swept — see the method doc before promising those to XMI.
