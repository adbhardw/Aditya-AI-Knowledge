# forebitt — events/SNS config wiring, from `.env` to `hsns.NewSNS(&cfg.SNS)`

**Session date:** 2026-08-20 · **Repo:** `deklareddotcom/forebitt` @ `enforced-ptp/dv-12695` · **Library:** `hank v1.23.1-0.20250813161745-c53aa6f6741a` · **Config stack:** cobra + pflag v1.0.5 + viper v1.12.0 + godotenv

## Start here

**[SUMMARY.md](SUMMARY.md)** — self-contained 1–2 page executive summary: problem, first principles, architecture diagram, runtime flow, options, trade-offs, recommendation, the five findings, and every cited file/line. Read this first; open the detail files below only for line-level evidence.

## Files

| File | Contents |
|---|---|
| [SUMMARY.md](SUMMARY.md) | Executive summary and entry point. Mermaid architecture diagram, full file/line index across forebitt + hank + viper, verified-vs-inferred ledger. |
| [2026-08-20_flag_registration_and_key_derivation.txt](2026-08-20_flag_registration_and_key_derivation.txt) | How `AddEvents(flags,"events")` → `AddSNS` → `AddAWS` builds the keys `events.sns.aws.*` via `MakePrefixKey`. The complete registered key set, why `disablessl` is absent, and where the key strings physically live (pflag `formal` map + `viper.pflags`; values stay in `os.Environ()`). |
| [2026-08-20_viper_env_binding_internals.txt](2026-08-20_viper_env_binding_internals.txt) | Where `Setup` runs (`PersistentPreRunE`, from the root command's name), what it sets, and the exact per-lookup transform `events.sns.aws.rolearn` → `FOREBITT_EVENTS_SNS_AWS_ROLEARN` (`mergeWithEnvPrefix` → replacer → `os.LookupEnv`). Includes the full 7-layer precedence order inside `viper.find()` and the empty-string-is-unset rule. |
| [2026-08-20_unmarshal_nesting_and_cfg_identity.txt](2026-08-20_unmarshal_nesting_and_cfg_identity.txt) | Why `hank/aws/service.go:48` reads plain `cfg.Region` and not the dotted path: `AllSettings`/`deepSearch` rebuild a nested map, each dot segment is consumed by one struct hop, and **four different variables are all named `cfg`** with four different types. |
| [2026-08-20_env_audit_localstack_findings.txt](2026-08-20_env_audit_localstack_findings.txt) | Audit of `.env:96-103`: binding status per variable, the two dead vars, the STS/RoleArn and topic-ARN issues, the duplicate block, one disproved hypothesis, and the proposed corrected block. |

## Findings at a glance

- `FOREBITT_EVENTS_SNS_ENDPOINT` is **dead** — `Endpoint` lives one level lower, at `events.sns.aws.endpoint`. The endpoint stays `""`, so the SDK targets real AWS rather than LocalStack.
- `FOREBITT_EVENTS_SNS_DISABLESSL` is **dead and unfixable via env** — `AddAWS` registers no such flag, and `AutomaticEnv` keys are invisible to `viper.Unmarshal`.
- Three further local-setup defects: dummy `ROLEARN` forces a lazy STS AssumeRole, `TOPIC` is a name where an ARN is required, and `.env` carries a duplicate events block.

**Nothing was executed this session** — no server started, no message published. Runtime-failure claims are marked INFERRED in SUMMARY.md §8.
