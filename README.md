# Aditya AI Knowledge

A searchable, long-term engineering knowledge base. Each entry is a self-contained
documentation folder produced during a deep-dive analysis, architecture, or learning
session, preserved exactly as generated.

## How this repository is organised

```
Aditya-AI-Knowledge/
    YYYY-MM-DD/                     <- date the knowledge was published
        <generated-folder>/         <- the session's documentation, preserved as-is
            SUMMARY.md              <- START HERE: 1-2 page executive summary
            README.md               <- folder index
            NN-*.md                 <- the detailed documents
```

## How to use this (for humans and for AI assistants)

Every documentation folder contains a **`SUMMARY.md`**. It is written to be
self-contained: an assistant (Claude, ChatGPT, Gemini, …) should read `SUMMARY.md`
first to understand the whole session, and only open the numbered detail documents
when it needs line-level evidence for a specific claim.

Summaries follow a consistent shape: problem statement → first-principles
explanation → high-level architecture → end-to-end runtime flow → design options →
trade-offs → final recommendation → bugs/root cause → open questions → next steps,
with repository files, classes, methods and line numbers cited where applicable.

Diagrams are Mermaid, inline in the Markdown, so they render directly on GitHub.

---

## Index

Reverse chronological — newest first.

### 2026-07-31

| Folder | Summary |
|---|---|
| [2026-07-30-aditya-architect-followup](2026-07-31/2026-07-30-aditya-architect-followup/) — [SUMMARY](2026-07-31/2026-07-30-aditya-architect-followup/SUMMARY.md) | orinix event production for the XMI partner notification pipeline (DV-13856 / DV-15090 / DV-15091): should change events be emitted from the **service layer** or from **Hank's automatic row hooks**, **change data capture**, or **database triggers**? Traces one Data Connection create end to end (5 row writes across 2 tables, 5 hook firings via the V2 route and 10 via V1), scores five options against seven requirements, and recommends service-layer emission with Level 1 detail for state transitions and Level 2 for create/update/delete. Also surfaces a pre-existing audit-log bug: delete records carry an empty `ObjectID`. |