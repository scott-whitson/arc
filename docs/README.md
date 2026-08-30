# arc — design

arc is a local, offline, config-aware oracle for Emacs: it answers questions
about this machine's own configuration and notes, and cites sources you can
jump to. It is a hard fork of ELISA by Sergey Kostyaev.

## design/

- `2026-08-29-design.md` — the approved design. Covers the five source kinds,
  the `sources`+`data` schema, the org-link citation invariant, and the
  refusal contract. Also records what was evaluated and **rejected**
  (Cactus/Needle 2, turbovec, fine-tuning) so those are not re-litigated.
- `2026-08-29-plan-phases-1-2.md` — the implementation plan for phases 1 and 2
  (foundation and corpus), as executed.

Phases 3–5 — scoped retrieval, the `arc-answer-mode` UI, and freshness plus an
eval harness — are designed but not built.

## Status

Phases 1–2 complete: 164 tests across 16 suites, and a working index verified
answering real questions with citations confirmed at file and line.

The per-task implementation reports and the execution ledger from the phases 1–2
build are kept locally rather than published: they quote indexed source material
verbatim as evidence, including private notes.
