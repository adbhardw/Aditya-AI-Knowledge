# Habu API gateway rate limiting — reference + prod audit (2026-08-04)

How rate limiting actually works in `deklareddotcom/api-gateway`, and an audit of the
production configuration read from the Internal Admin screen.

## Start here

- **[SUMMARY.md](SUMMARY.md)** — the full write-up: two-filter model, resolution order,
  how to read the token-bucket numbers, the disjoint-orgs finding, source references
  with the behaviours that surprise people.
- **[aditya-rate-limit-habu-all.txt](aditya-rate-limit-habu-all.txt)** — the same content
  as a one-page plain-text reference, for pasting into a runbook or ticket.

## The headline

Every request passes through **two independent limiters** — org-wide `QUOTA` (runs first)
and per-URL `PATH` — and an org missing from one table still gets that filter's `ALL` default.

In production the two sets are **disjoint**: 3 orgs have a quota row, 16 have a path row,
**none have both**. So every uplift is cancelled by the other filter's default:

| Org has | Intended | Actually binds |
|---|---|---|
| quota row only | 28,800/day | **480/day** (path `ALL`, 20/hr) |
| path row only | 86.4M/day | **5,082/day** (quota `ALL`) |
| neither | — | 480/day |
| both | 28,800/day | *nobody is configured this way* |

Also flagged: one regex with doubled backslashes that can never match, per-URL bucketing
that makes path limits weak against ID enumeration, and uppercased config keys that would
invert `\d` / `\w` / `\s` if anyone used them.
