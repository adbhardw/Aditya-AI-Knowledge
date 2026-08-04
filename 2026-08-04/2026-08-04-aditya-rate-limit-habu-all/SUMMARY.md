# SUMMARY — Habu API gateway rate limiting: how it works, and what prod actually does

**Date:** 2026-08-04
**Session type:** Source trace + production configuration audit
**Deliverable:** [`aditya-rate-limit-habu-all.txt`](aditya-rate-limit-habu-all.txt) — the one-page reference
**Related:** [2026-08-03 dashboard prompts + telemetry inventory](../../2026-08-03/2026-08-03-aditya-grafana-dashboard-prompts-and-telemetry-inventory/SUMMARY.md) · [api-gateway PR #95](https://github.com/deklareddotcom/api-gateway/pull/95)

---

## 1. Problem statement

Two questions, from an API-abuse investigation:

1. **How does rate limiting actually work** in `deklareddotcom/api-gateway` — what does a configured row in the Internal Admin "Rate Limiting" screen do to a real request?
2. **Is the production configuration doing what its authors intended?**

The answer to (2) is no, and for a structural reason that isn't visible from any single row.

---

## 2. First principles: two independent limiters

Every request passes through **both** filters. They are not alternatives, and each has its own `ALL` fallback.

| | Quota | Path |
|---|---|---|
| Class | `QuotaRateLimitFilter` | `PathRateLimitFilter` |
| Order | **−2 (first)** | −1 (second) |
| UI "Type" | `ORGANIZATION` | `REGEX` / `API` |
| Bucket key | `orgId` alone | `<raw path>:<method>:<orgId>` |
| Redis key | `rate-limit:QUOTA:ORGANIZATION:ORG_<org>` | `rate-limit:PATH:<TYPE>:<KEY>:<METHOD>:ORG_<org>` |
| Scope | one budget across **all** endpoints | per URL, per method, per org |

**An org missing from one table is not exempt from that filter** — it falls through to that filter's `ALL` default. This is the crux of the finding.

### Path resolution order

```
Step 1  exact API-type match on RAW path + method + orgId
Step 2  REGEX rows for THIS org (method must match, path must match regex)
        → if several match, LONGEST REGEX STRING wins
Step 3  REGEX rows with organization = ALL, same longest-wins rule
Step 4  nothing matched → hardcoded buildLimiter(50, 50) = 50 req/sec
```

Quota: org-specific row → `ALL` row → **pass through with no quota at all**.

### Reading the numbers

Spring Cloud Gateway's token bucket is **per second**:

```
sustained req/sec = replenishRate / requestedTokens
burst requests    = burstCapacity / requestedTokens
full refill secs  = burstCapacity / replenishRate
```

`requestedTokens` is the lever for sub-3600/hour limits, since `replenishRate` is an integer ≥ 1/sec. `burstCapacity 86400` = a day of tokens at 1/sec; `3600` = an hour.

---

## 3. The finding: every uplift is cancelled by the other filter's default

Decoding the full production table:

| Rule | r/b/t | Effective |
|---|---|---|
| `ORGANIZATION` per-org (3 orgs) | 1/86400/3 | 1,200/hr → **28,800/day** |
| `ORGANIZATION` **ALL** | 1/86400/17 | 212/hr → **5,082/day** |
| `REGEX` create-run POST **ALL** | 1/3600/180 | **20/hr → 480/day** |
| `REGEX` flow-runs POST **ALL** | 1/3600/180 | 20/hr → 480/day |
| `REGEX` `^/v1.*` GET/POST/PUT **ALL** | 100/100/1 | 100/sec |
| `REGEX` create-run / flow-runs per-org | 1000/1000/1 | 1,000/sec |
| `REGEX` `^/v1.*` POST `a3b98c27` | 1/5/2 | 0.5/sec, burst 2 |

**Orgs with a quota row: 3. Orgs with a path row: 16. Orgs in both: 0.**

The two sets are **disjoint**, so no org has both a raised quota and a raised path limit. Each is throttled by whichever it lacks:

- **The 3 quota-uplifted orgs** (`ee0b773e`, `19bf3c09`, `2ae652e8`) have no per-org REGEX row, so create-run falls to the `ALL` regex. Quota says 28,800/day; path says **480/day**. The path binds — the quota uplift is unreachable and **60× looser than the real ceiling**.
- **The 16 path-uplifted orgs** have no `ORGANIZATION` row, so they fall to the `ALL` quota. Path says 86.4M/day; quota says **5,082/day**. The 1,000/sec allowlist is almost entirely cosmetic.

Net effective ceiling on `POST /v1/cleanroom-questions/{id}/create-run`:

```
org with quota row only  →    480/day   (path ALL binds)
org with regex row only  →  5,082/day   (quota ALL binds)
org with neither         →    480/day
org with both            → 28,800/day   ← nobody is configured this way
```

If an `ORGANIZATION` row is meant to grant a customer headroom, **it currently does not**. It needs a matching per-org `REGEX` row.

---

## 4. Second finding: one regex appears broken

```
\\/v1\\/cleanroom-questions\\/[^\\/]+\\/create-run
POST  REGEX  d58c99f0-978a-4b86-b213-7fc661c3c494  1000/1000/1
```

**Double** backslashes where all 30 other rows use single. As a Java regex `\\` matches a *literal* backslash, so this requires a path containing `\/v1\/…` — which no URL does. It can never match, and `d58c99f0` silently gets the `ALL` rule (20/hour) instead of 1,000/sec.

⚠️ **Unverified** — could be a copy/paste artifact rather than stored data. Check Redis before acting.

---

## 5. Behaviours that surprise people

- **Path buckets are per raw URL**, not per route pattern. One rule at 5/sec gives *each distinct URL* its own 5/sec, so a client rotating 200 resource IDs gets 1,000/sec. Only the org quota constrains such a client — this is why quota is the real control.
- **Longest regex *string* wins**, not most-specific match. For `a3b98c27`, POST create-run resolves to the 44-char rule (1,000/sec) rather than the 6-char `^/v1.*` (0.5/sec) — correct here, but it's string length doing the work.
- **API-type rows match the raw path**, so `/v1/cleanrooms` will not match `/v1/cleanrooms/{id}`. Use REGEX for anything with an id.
- **DELETE and PATCH on `/v1`** match no `ALL` row → hardcoded 50/sec in code, not from the table.
- **Config keys are uppercased** before storage, with `(?i)` compensating at match time. Safe for `[^\/]+` and `.*`, but it **inverts shorthand classes**: `\d`→`\D`, `\w`→`\W`, `\s`→`\S`. Never use `\d` in a rule.
- **Do not delete the `ALL` ORGANIZATION row** — it is the only org-wide backstop. Without it, orgs with no quota row would have no ceiling at all.

---

## 6. Key source references

| File | Detail |
|---|---|
| `http/filters/ratelimiter/QuotaRateLimitFilter.java` | order −2; bucket `quota_organization` + orgId; no path/method |
| `http/filters/ratelimiter/PathRateLimitFilter.java` | order −1; bucket `path + ":" + method + ":" + organizationId` (raw path) |
| `http/filters/ratelimiter/AbstractRateLimitFilter.java` | `handleRateLimitExceeded` sets 429; null-headers branch returns `Mono.error` (a 500) — unreachable via `RedisRateLimiter`, whose `Response` constructor asserts non-null headers |
| `config/RateLimiterConfig.java` | `createPathRateLimiter` steps 1–3; `pathRateLimiter()` converts a `null` config into `buildLimiter(50, 50)` |
| `repository/RedisRateLimitConfigRepository.java` | `buildRedisKey` — key shapes, `.toUpperCase()`, `ORG_` / `ORG_ALL` |
| `models/RateLimitConfig.java` | `key`, `method`, `organization`, `replenishRate`, `burstCapacity`, `requestedTokens` |

**Known inconsistency:** `createPathRateLimiter`'s comment says an unmatched request passes "unlimited", but the caller converts `null` → `buildLimiter(50, 50)`. Comment and behaviour disagree.

---

## 7. Observability — api-gateway PR #95

Before: rejections could not be attributed to a tenant, and the path counter was tagged with the **raw URI path** (unbounded Prometheus cardinality — a series per resource UUID, live in production).

After: both filters log `key=value` with `organizationID`, and the counter is tagged with the bounded matched route (`GATEWAY_PREDICATE_MATCHED_PATH_ATTR`, mirroring `RouteIdWebFluxTagContributor`).

```logql
topk(10, sum by (organizationID) (count_over_time(
  {service_name="api-gateway"} |= "Rate limit exceeded"
    | json | line_format "{{.message}}"
    | pattern `<_>organizationID=<organizationID>,<_>` [$__range])))
```

```promql
sum by (route, method, source) (rate(rate_limit_exceeded_total[5m]))
```

The log says `outcome=REJECTED`, not `status=429` — the line is emitted before the response status is set, so it states the decision, not the code.

---

## 8. Open questions

- Are `ORGANIZATION` rows intended to grant headroom? If so, all three are currently ineffective.
- Is the `d58c99f0` double-backslash row real in Redis, or a copy artifact?
- Was the disjointness deliberate (two separate initiatives) or accidental?
- Should the path `ALL` default for create-run (20/hr) be raised, or should quota-uplifted orgs get matching REGEX rows? These are different policies.

## 9. Next steps

1. Decide the intent behind `ORGANIZATION` rows, then either add matching per-org `REGEX` rows or raise the path `ALL` default.
2. Verify `d58c99f0` against `redis-cli --scan --pattern 'rate-limit:PATH:REGEX:*'`.
3. Treat the `ALL` quota (5,082/day) as the platform's real ceiling — it binds for 16 of 19 configured orgs.
4. Merge PR #95 so throttling becomes attributable per tenant, then build the top-offenders panel.
5. Update the internal runbook: it still says per-org config is a "planned task" and omits both `requestedTokens` and the QUOTA strategy entirely.
