# Rate-limit defense layers & token-bucket mechanics under parallel load (2026-08-14)

Where each rate/abuse defense belongs — **WAF/ALB by IP, api-gateway by org, backend bulkhead by
concurrency** — plus the first-principles mechanics of the token bucket under parallel requests,
verified with live stage + prod load tests, and an audit of what the platform **actually** runs
(no WAF, no CDN, an internet-facing AWS ALB).

## Start here

- **[SUMMARY.md](SUMMARY.md)** — the executive summary and primary entry point: the problem,
  the token-bucket findings, the layered-defense model, the **verified infra reality**
  (CDN? no / WAF? no / proxy? AWS ALB), the final recommendation, key file:line references,
  and next steps.

## Detail documents

- **[2026-08-14_token-bucket-under-parallel-requests.txt](2026-08-14_token-bucket-under-parallel-requests.txt)** —
  why "100 → 98 rejected" is usually wrong; `passed ≈ burst + refill × duration`; the atomicity of
  the Redis token count; the failed burst-compression experiment (200 @ -P150 → 170 × 000);
  why one machine can't deliver a real flood; and `000` = connection refused at whichever layer
  saturates first.
- **[2026-08-14_defense-layers-waf-alb-gateway-bulkhead.txt](2026-08-14_defense-layers-waf-alb-gateway-bulkhead.txt)** —
  the layered model (match the defense to the identity the threat is known by); when to block IPs
  at the WAF vs when not to; **how AWS WAF rate-based auto-blocking works** (count → block →
  unblock, Count mode, 403 at the edge); the CDN / X-Forwarded-For caveat; and the **verified
  infra section** with exact file:line evidence from `orinjade` (Terraform) and `dyogram` (Helm).
- **[2026-08-14_osi-layers-tls-termination-and-the-request-path.txt](2026-08-14_osi-layers-tls-termination-and-the-request-path.txt)** —
  the **7 OSI layers** (L1 physical → L7 application) with a Habu example per layer; the **L4-vs-L7**
  distinction (dumb pipe vs smart hop); what **TLS termination** is and why terminating at the
  **edge** is faster (the distance-bound handshake); what breaks if TLS **doesn't** terminate
  (passthrough → dumb L4 relay; no CDN → terminate at the ALB); the **full request path annotated
  by layer**; and why each defense sits where it does (IP threats L3/L4, org threats L7).

## Headline

| Question | Answer |
|---|---|
| 100 requests, `2/2/1` → how many rejected? | Only ~2 **if simultaneous**; else `passed ≈ 2 + 2×duration` (stage: 100/13s → 26 passed) |
| Do parallel calls each "see 2 available"? | **No** — the Redis token count is atomic; only `burst` win |
| Can one machine compress a flood to force 98×429? | **No** — the ALB refuses connections (`000`) first; needs distributed IPs |
| Do we use a CDN? | **No** |
| Do we use a WAF? | **No** — only latent IAM permissions; no WebACL attached |
| What's in front? | An **internet-facing AWS ALB** (TLS on 443), routing to EKS services |

## Related

- [2026-08-08 — Concurrency vs rate limiting (parent post-mortem)](../../2026-08-08/2026-08-08-aditya-concurrency-vs-ratelimit-5xx/SUMMARY.md)
- [2026-08-06 — api-gateway rate-limit observability PR #95](../../2026-08-06/2026-08-06-aditya-api-gateway-ratelimit-observability-pr95/SUMMARY.md)
