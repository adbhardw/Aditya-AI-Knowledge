# Agent Protocol design questions

Two questions raised about why the transport looks the way it does.

---

## Q1: why `POST /threads` then `POST /runs/wait`, rather than a per-agent endpoint?

The challenge, stated fairly: if `cleanroom-assistant` shares context *because you
never leave the agent*, why is a thread needed at all? Why not
`POST /cleanroom-assistant` and `POST /attestation-agent` directly? Is the only
benefit that Aegra avoids hosting many endpoints?

**Hosting economy is real but is the smaller half.**
`deployments/aegra/local.aegra.json` lists ~24 graphs. One set of routes plus a
lookup beats 24 sets of routes.

**The larger half: routing and memory are orthogonal problems.**

| Concern | Carried by |
|---|---|
| **Who** answers | `assistant_id` (a body field) |
| **Which** conversation | `thread_id` (the URL) |

A per-agent URL solves *who*. It solves nothing about *which*. So
`POST /cleanroom-assistant` would still need a conversation identifier in the
body — otherwise a second message has no way to find the first.

The result would be 24 URLs **and** threads. Nothing saved, 23 routes added.

**This also answers the challenge directly.** Staying inside one agent does not,
by itself, store anything. The thread *is* the storage. It is what makes "never
leaving the agent" mean something rather than being a figure of speech.

### Does a thread pool memory across different agents?

Aegra's thread record (`ibbybuilds/aegra` @ `3d803a09`,
`libs/aegra-api/src/aegra_api/models/threads.py`) carries `thread_id`, `status`,
`metadata`, `user_id`, `created_at`, `updated_at` — **no agent field**. So
different `assistant_id`s *can* post to one thread.

But each graph has its own state shape (attestation's is
`core/agents/attestation-agent/state.py:76-108`), so only `messages` would
meaningfully carry across.

Moot for this code regardless:
`/Users/adbhar/Documents/Habu_Cloned_Repo/unhygienix-attestation/api/server/attestation.go:1381`
sends `threadBody := []byte("{}")` — **a brand new thread on every Apply**. No
reuse, no shared memory, not even between two Applies on the same question.

The shared-context pattern does exist at LiveRamp, built the other way round:
`cleanroom-assistant` is **one** agent routing internally to flow-diagnosis,
DAR-assist and intelligence subgraphs. **One agent, many skills — not many agents
sharing a thread.**

---

## Q2: `runRaw` is already in hand — why call `fetchAttestationThreadState`?

Sharpened form of the question: at
`unhygienix-attestation/api/server/attestation.go:1446` the whole response body
has been read into `runRaw`. Why go fetch anything else?

**Because `runRaw` may genuinely not contain the report.** The second call is not
a redundant re-read of the same bytes.

### The search that happens first

`extractAttestationEnvelope`, `api/server/attestation_envelope.go:15`:

| Step | Line | What |
|---|---|---|
| 1 | `:17` | parse `runRaw`; unparseable → stub with `datasets: []` |
| 2 | `:31-36` | unwrap `values`, else `output`, else use top level |
| 3 | `:38` | call `pickReportEnvelope` |

`pickReportEnvelope` (`:49-75`) searches **four places in order**:

| Try | Looks at | Line |
|---|---|---|
| 1 | `report_envelope` | `:50-55` |
| 2 | last AI message's content | `:56-61` |
| 3 | `dataset_reports` | `:62-67` |
| 4 | `datasets` | `:68-73` |

All four miss → `:74` returns `nil` → `:40-43` substitutes a stub with **empty
datasets**.

Back at `attestation.go:1455`, `envelopeHasReportDatasets`
(`attestation_envelope.go:809-814`) counts them. Zero → false → fetch thread
state.

**So the guard means "I searched four places in the body and the report was in
none of them", not "I did not bother to read it".**

### Why four misses can happen

`extractEnvelopeFromMessages` (`attestation_envelope.go:77-99`) walks messages
backwards, requires `type == "ai"` (`:81`), then handles content two ways — an
object (`:85-88`) or a JSON string it re-parses (`:89-95`).

LangGraph does not always serialize a message identically. One known shape wraps
content a level deeper under `kwargs`; that matches neither branch and is
invisible to the extractor. (unhygienix PR #3768 adds explicit handling for
exactly this "constructor" form.)

`GET /threads/{id}/state` returns a **different representation** — the
accumulated graph state rather than the run's output — so the report surfaces as
`report_envelope` or `dataset_reports`, i.e. try 1 or try 3.

**Same information, different packaging. The first package had no door the
parser could open; the second did.**

### What it is NOT

Not a slowness or timeout fallback. It sits *below* every failure path:

| Line | Condition | Behaviour |
|---|---|---|
| `1441-1444` | network error or 180s timeout (`:1379`) | returns the error — no fallback |
| `1450-1452` | HTTP >= 300 | returns the error — no fallback |
| `1455` | report absent from an otherwise-fine 200 | **falls back** at `:1456` |

`fetchAttestationThreadState` itself (`:1474-1496`) swallows all its own errors
and returns `nil` — a best-effort second look, never a retry.
