# SUMMARY — Rate-limit defense layers & token-bucket mechanics under parallel load

**Date:** 2026-08-14
**Session type:** First-principles Q&A + live load-test verification + infra audit
**Repos referenced:** `api-gateway`, `external-api-server`, `orinjade` (Terraform infra), `dyogram` (Helm charts)

> Self-contained entry point. Read this first; drill into the two detail `.txt` files only when needed.

---

## 1. Problem statement

Two questions drove this session, both grounded in the earlier "why did a rate-limited API still 5xx" work (see the **2026-08-08** folder):

1. **Mechanics:** With a `2/2/1` token-bucket rule (replenish 2/sec, burst 2, 1 token/request), *why don't 100 requests produce ~98 × 429?* And under parallel calls, doesn't each request "see 2 available" and pass?
2. **Architecture:** *Where should each defense live* — should we let WAF/ALB handle rogue organizations, or handle them at the api-gateway? Should we block IPs at the WAF by reading metrics? And **do we even use a CDN/proxy/WAF?**

---

## 2. First-principles findings

### Token bucket is time-based, and atomic

- **`passed ≈ burst(2) + replenishRate(2/sec) × burst_duration(sec)`.** "Only 2 pass, 98 rejected" is true **only** if all 100 arrive within ~1 second. Any real duration lets the refill through. Verified: a stage burst of **100 requests over 13s → 26 passed / 74 × 429** (predicted `2 + 2×13 = 28` ✓).
- **The token count is atomic** (Redis Lua script). 30 *truly-simultaneous* requests do **not** each read "2 available" — they are serialized: 2 win the 2 tokens, ~28 get 429. Parallelism does not bypass or multiply the counter.
- **"Parallel" via curl/xargs is not simultaneous** — latency + TLS handshakes spread arrivals over seconds, so the 2/sec refill keeps up and observed 429 counts are far below the naive 98/100.

### You cannot compress a flood from one machine

Live prod test (`2/2/1`, test org): **200 requests at `xargs -P150` → 170 × 000, 18 × 429, 12 × 200, wall time 20.7s.** Compression failed because the **ALB refused 85% of the connections (`000`) before they reached the gateway.** One laptop tops out ~65–74 clean 429s. Real saturation of a per-second limit needs **distributed sources** (many IPs) — the same reason floods come from botnets.

- **Under a flood the order is: ALB refuses connections (`000`) → gateway rate-limits (`429`) → backend serves (`200`).**
- **`000` = connection refused at whichever layer saturated first** — ALB/Shield connection ceiling, or the backend accept-queue/backlog, or a connect-timeout. The observed "~30 connected" is **not** a documented ALB per-IP cap; it's adaptive AWS-edge/Shield throttling + client-side limits, and it floats run to run.

## 3. Architecture — match the defense to the identity the threat is known by

| Layer | Defends against | Keyed on | Sees the org? |
|---|---|---|---|
| **WAF / ALB / Shield** | volumetric DDoS, connection floods, bad IPs, scrapers | **IP + connection** | ❌ no |
| **api-gateway rate limit** | a rogue **organization / credential** | **org + sub + path** (JWT) | ✅ **yes — the layer for it** |
| **backend bulkhead** (external-api-server) | concurrency exhausting threads | **in-flight count** | protects regardless |

**Load-bearing insight:** the WAF **cannot see the org** — a rogue org with a valid credential from legitimate IPs looks like normal traffic. So rogue-org abuse is inherently a **gateway** problem. Block by IP **only** for IP-identifiable threats (and automate it with WAF **rate-based rules**, not manual metric-reading). For a rogue org, IP-blocking is wrong: an org spans many IPs, and one IP can carry many orgs (collateral damage). Enforce by tightening the **org/credential** limit instead.

### How WAF auto-blocking works (AWS rate-based rules)
A continuous **count → block → unblock** loop, no human in it: you set one rule (threshold + rolling window + "aggregate by source IP" + Block); WAF counts every IP, blocks any over threshold, and **auto-unblocks** when it drops back under. Tune in **Count mode** first, then flip to Block. Blocked requests get **403 at the edge**, never reaching the ALB/gateway.

### Network layers & TLS termination — why the model holds (detail: [OSI/TLS doc](2026-08-14_osi-layers-tls-termination-and-the-request-path.txt))

The layered defense maps directly onto the **OSI stack**: **L1** = physical bits on the wire (the cable whose length sets RTT), **L3** = IP, **L4** = TCP (ports, connections, the `000` refusals, the ALB ceiling), **L6** = TLS (encryption), **L7** = HTTP (paths, headers, the JWT). The key rule: **you can only do L7 work — path routing, WAF content inspection, reading the JWT to rate-limit by org — *after* TLS terminates (L6 decrypt).** An L4 device (TCP LB, or a CDN doing TLS passthrough) sees only IP+port — a dumb pipe.

**TLS termination** is where the encrypted session is decrypted. The TLS handshake costs ~2–3 **distance-bound** round trips before any data flows, so terminating at a **CDN edge near the user** turns a ~500–750ms cross-ocean handshake into ~25ms + a warm pooled origin connection. **Habu has no CDN**, so the **ALB is both the sole TLS-termination point and the global edge** — distant users pay the full handshake, and there's no edge layer to absorb a flood before the ALB. This is *why* IP threats (L3/L4) block early at the WAF/ALB while org threats (L7, needs the decrypted JWT) belong at the gateway.

## 4. Infra reality (verified from `orinjade` + `dyogram`, not assumed)

- **CDN? No.** No CloudFront/Fastly/Akamai/Cloudflare in the request path (CloudFront appears only in an egress allow-list + a read-only IAM permission).
- **WAF? No.** No `aws_wafv2_web_acl`/association declared or attached; **only latent IAM permissions** let the ALB controller *potentially* attach a WebACL. To use WAF auto-blocking you'd have to **add a WebACL first**.
- **Proxy? Yes — internet-facing AWS ALB** (AWS Load Balancer Controller, `scheme: internet-facing`, TLS on 443) fronts all services; `topgallant` also runs an in-pod nginx.
- **X-Forwarded-For:** `api-gateway` **trusts it** (`forward-headers-strategy: framework`, `application.yml:26`) → sees real client IP. `external-api-server` **does not** → sees the ALB socket IP. `topgallant` nginx parses XFF but its trusted CIDR is a placeholder `0.0.0.0/16` needing override.
- **Topology of record** (no diagram files exist in the repos): `client → ALB (TLS) → api-gateway → external-api-server → gRPC downstream`. **No WAF, no CDN.**

**Correction to the initial X-Forwarded-For caveat:** the "aggregate by XFF" workaround for WAF only matters when a **CDN sits in front of the ALB** — which is **not** the case here, so a WAF-on-the-ALB would see the true client IP by default. The XFF gap that *is* real is at **external-api-server** (no forwarded-header handling), relevant only if per-IP logic is ever added there.

## 5. Final recommendation

1. **WAF/ALB/Shield** own the network/IP/volumetric layer — enable WAF **rate-based rules** for automatic per-IP shedding (requires **adding a WebACL** — none exists today).
2. **api-gateway** owns rogue **organizations** — per-org quota + per-`sub`/credential rate limits (PR #95 + per-sub-as-child-of-org). Enforce by limit/quarantine, **not** IP-blocking.
3. **external-api-server** owns concurrency — the **Semaphore bulkhead** (`503 + Retry-After`, sized below `threads.max`); see the 2026-08-10 design in the 2026-08-08 folder.
4. **Rule of thumb:** block the threat by the identity it's known by — IP at the WAF, org at the gateway, in-flight count at the backend. Don't cross the wires.

## 6. Key repository references (verified)

| Fact | File:line |
|---|---|
| api-gateway trusts XFF | `api-gateway/src/main/resources/application.yml:26` |
| ALB ingress (internet-facing, 443) | `dyogram/charts/api-gateway/values.yaml:118-126` |
| external-api-server ALB ingress | `dyogram/charts/external-api-server/values.yaml:85-99` |
| ALB SG opens 443 from 0.0.0.0/0 | `orinjade/aws/modules/security-groups/http_alb_sg.tf:20-37` |
| Latent WAF IAM perms (no WebACL) | `orinjade/aws/modules/roles/policy_document.tf:185-188, 394-401` |
| CloudFront only in egress allow-list | `orinjade/azure/environments/habu/prod/westeu/prod.auto.tfvars:179` |
| Rate-limit rejection tag/attribution | `api-gateway/.../ratelimiter/PathRateLimitFilter.java` (PR #95) |
| Access log (org+status+latency) | `external-api-server/.../filters/AccessLogFilter.java` (PR #353) |

## 7. Open questions / next steps

1. **Decide whether to add a WAF** (WebACL + ALB annotation) — the IAM already permits it. If added, start rate-based rules in **Count** mode.
2. Confirm the **topgallant `set_real_ip_from` CIDR** is overridden per env (placeholder `0.0.0.0/16` is spoofable).
3. Proceed with the **api-gateway per-org/per-sub** limits and the **external-api-server bulkhead** (the two changes that actually stop the observed 5xx corner).
4. **Cleanup owed (user-owned):** revert the temporary `2/2` rule on **prod** (`77dc28af`) and **stage** (`c0699ec6`); **rotate both client secrets** used in the load tests.

## 8. Related

- [Concurrency vs rate limiting — why a rate-limited API still 5xx'd (2026-08-08)](../../2026-08-08/2026-08-08-aditya-concurrency-vs-ratelimit-5xx/SUMMARY.md) — the parent post-mortem; error-code taxonomy, the 5 load-test runs, the bulkhead design.
- [api-gateway rate-limit observability PR #95 (2026-08-06)](../../2026-08-06/2026-08-06-aditya-api-gateway-ratelimit-observability-pr95/SUMMARY.md)
