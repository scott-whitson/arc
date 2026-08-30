# arc — design and history

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

## history/

- `execution-ledger.md` — the decision record for the phases 1–2 build: every
  ruling made during execution, with its cost-if-wrong, plus every deferred and
  parked finding.
- `task-*-report.md`, `final-fix-report.md` — per-task implementation reports,
  including red-before/green-after evidence.

Task briefs and review packages are omitted: briefs are extracts of the plan,
and review packages are diffs of commits already in this history.

## Status

Phases 1–2 complete: 163 tests across 16 suites, and a working index verified
answering real questions with citations confirmed at file and line. Known open
items are recorded at the end of the execution ledger.
