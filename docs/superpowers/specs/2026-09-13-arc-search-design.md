# arc search — design

**Status:** approved, not built
**Date:** 2026-09-13

arc gains a search surface: fast, document-level, LLM-free, usable from the
minibuffer and callable by an external agent. `arc-ask` and its pipeline are
untouched — this is a second front door onto the index that already exists, not
a replacement for the first.

## Motivation

arc today ends in an LLM. Every question costs an Ollama round trip and returns
prose, when the thing wanted most of the time is *where is this, quickly*. The
retrieval half of arc — chunking, BM25, vectors, RRF fusion, scoping, freshness,
and an eval harness to keep all of it honest — is already built and already
good. It just has no mouth that isn't `arc-ask`.

Two consumers want that mouth:

1. **Emacs, interactively.** Universal search over the indexed corpus: the
   vault, the Emacs and Elisp manuals, the NixOS and Home-Manager options, the
   dotfiles. One keybinding, results in tens of milliseconds.
2. **An external agent** (Claude Code, pi) that already *is* an LLM and wants
   arc as a retrieval tool, not as a second, weaker model in the path.

## Corpus

Unchanged. The five existing collections, as indexed today:

| Collection | Sources | Chunks | Chunks/source |
|---|---:|---:|---:|
| nix options | 24,661 | 24,661 | 1.0 |
| builtin manuals | 7,606 | 7,606 | 1.0 |
| hm options | 5,513 | 5,513 | 1.0 |
| vault | 432 | 17,058 | 39.5 |
| dotfiles | 154 | 7,045 | 45.7 |
| emanix | 70 | 1,646 | 23.5 |
| **total** | **38,437** | **63,529** | |

No new source kinds. In particular **no PDFs and no complex documents** — that
remains rejected (see `2026-08-29-design.md`), and this work does not reopen it.
No schema change, no migration, no reindex: everything below reads tables that
already exist.

That table drives the central design decision. The corpus is two shapes wearing
one schema. For options and manuals a chunk *is* a document, 1:1. For the vault,
dotfiles and emanix a document shatters into 24–46 chunks, which means that at
the current `arc-limit` of 10 a single well-matched note can consume the entire
result set and crowd out every other document. Rollup exists to fix that, and
the asymmetry is why the rollup function cannot be chosen by intuition.

## Measurements

Taken against the live index (63,529 chunks), unscoped, before any of this was
designed. All figures are milliseconds.

**Per-arm latency**, mean of five queries:

| Stage | Cost |
|---|---:|
| Embedding round trip (Ollama, `nomic-embed-text`) | 26–30 |
| Keyword arm, total | 4–63 |
| Fused arm, total | 118–181 |

The keyword arm skips embedding entirely — `arc--find-similar` already takes an
`arm` argument (`keyword` / `semantic` / `fused`) built for eval attribution,
and it is exactly the lever a two-speed search needs. No engine change is
required to get both speeds.

**Candidate pool depth**, mean over four queries, execution only:

| Pool (chunks) | Keyword | Fused |
|---:|---:|---:|
| 40 (current `arc-knn-candidates`) | 38 | 126 |
| 100 | 46 | 139 |
| **200 (chosen)** | **46** | **148** |
| 400 | 46 | 171 |

Deepening 40 → 200 costs +8ms keyword and +22ms fused. The brute-force vector
scan already touches every row; `LIMIT` only changes the sort. A pool deep
enough to roll up is therefore close to free, and stage 1 stays under the
threshold where typing feels live.

## Architecture

Five new units. Nothing existing is rewritten.

| File | Purpose | Depends on |
|---|---|---|
| `arc-rollup.el` | Chunk scores → ranked documents. Pure: no I/O, no UI, no database. | none |
| `arc-search.el` | Orchestration: `arc-search-documents`, query + scope + arm → document plists | `arc`, `arc-scope`, `arc-rollup` |
| `arc-search-ui.el` | `arc-results-mode` buffer; consult source behind a soft require | `arc-search`, `arc-ui` |
| `arc-tool.el` | The three JSON verbs | `arc-search`, `arc-index` |
| `bin/arc` | Shell shim to the daemon | none |

`arc-rollup.el` is separate from `arc-search.el` because it is the one piece
that gets measured and swapped. It must be testable without a database.

Naming, pinned so the two halves are not confused: `arc-search.el` defines
`arc-search-documents`, the non-interactive core that returns document plists
and is what `arc-tool.el` calls. The interactive command `arc-search` lives in
`arc-search-ui.el`. The file that carries the feature's name deliberately does
not define the command of that name, because the command is a UI concern and the
core must be callable with no UI present.

### Getting scores out of retrieval

`arc--find-similar` computes RRF scores and then discards them — the fused arm
selects `hybrid_search.id` alone. Rollup needs the score.

Add an optional `scored` argument that appends `, hybrid_search.score` to the
`SELECT`. Existing callers pass nothing and observe no change; `arc-ask` and
`arc-eval` are unaffected. This is deliberately additive rather than a change to
the existing return shape, because that shape is load-bearing for two tested
consumers.

For the single-arm cases, which have a rank but no RRF score, the score is
`1.0 / (arc-rrf-k + rank)`. Same shape and same magnitude, so rollup never
branches on which arm produced its input.

### Rollup

`arc-rollup-function`, a defcustom:

| Strategy | Document score | Expectation |
|---|---|---|
| `max` (ships as default) | best chunk's score | Safe. Discards the "matched in twelve places" signal. |
| `top-n` (`arc-rollup-top-n`, default 3) | sum of the best n chunk scores | Likely winner. Bounded, so a 46-chunk dotfile cannot run away. |
| `sum` | every chunk | Included to be measured, and expected to lose. |

`sum` is expected to fail for this corpus specifically, and the corpus table
says why: summing rewards documents for having many chunks, so every 39-chunk
vault note outranks every 1-chunk nix option on structural grounds alone,
regardless of relevance. It ships so the harness can demonstrate that rather
than this document asserting it.

The default is `max` only until measurement replaces it. Choosing the
aggregation by intuition is precisely the mistake `arc-fts-query`'s docstring
already records three times — stopword filtering, oversized-document filtering
and prefix matching each lost to BM25's own weighting. That prior applies here.

**Tie-break:** chunk count descending, then best-chunk rank ascending.
Deterministic, so tests do not flake.

**Pool:** `arc-search-pool` (default 200) let-binds `arc-knn-candidates` and
`arc-limit` for the duration of the query. Rollup then returns the top
`arc-search-limit` (default 10) documents.

**Output**, one plist per document:

```
(:source-id :kind :path :title :org-id :option-name :info-node
 :score :chunk-count :passages)
```

`:passages` holds the top `arc-rollup-passages` (default 3) chunks, each with
text and line range. Hydration reuses `arc--retrieve-rows` and
`arc-row-to-source`, so the org-link citation invariant carries over unchanged.

### Interaction

**Front door.** `arc-search`, a consult dynamic source:

- Each keystroke runs the keyword arm (~46ms) and rolls up live.
- 300ms idle runs the fused arm (~148ms) and replaces the results.
- Selection is preserved **by source-id, not list position**, so the stage-2
  swap does not move what is under the cursor.
- The active stage is visible in the marginalia annotation.
- `M-RET` dumps the current result set into the results buffer, scope intact.

**Stage 2 fails soft.** An unreachable embedding endpoint must keep the stage-1
results, show a note, and leave the minibuffer alive. It must never throw.
`arc-find-similar` already carries an `on-error` path documented for this exact
case.

**Escape hatch.** `arc-results-mode`, deriving from `special-mode`: documents
with their passages; `TAB` expands a document to all of its passages; `RET`
jumps to file and line; `g` re-runs; `s` re-scopes. The scope-change and
re-query keys reuse `arc-ui.el`'s existing machinery rather than growing a
second copy of it.

Consult is loaded with `(require 'consult nil t)` and the source is defined only
if it is present. arc stays installable without consult.

### Agent interface

```
arc search QUERY [--scope NAME] [--limit N] [--arm keyword|fused] [--json]
arc scopes [--json]
arc stats  [--json]
```

Transport is `bin/arc` shelling to `emacsclient -e` against the running daemon.
This keeps the founding constraint — one process tree, inside Emacs, nothing to
babysit — that `turbovec` was rejected for violating. It also costs nothing: the
database is warm, there is no second process, and no `sqlite3` binary is
required. An `emacs --batch` CLI would pay cold start, reload `vec0`, contend
with the live WAL, and duplicate the retrieval code.

Output is plain text by default and JSON under `--json`, with `Error: ...` on
stderr and a non-zero exit, matching the conventions of the operator's existing
CLI-backed tooling.

Exit codes: `0` success, `1` error, `2` reserved for
`Error: arc: emacs daemon not running`.

`stats` reports per-collection sources, chunks, last-indexed time and stale
count, reading `arc-index.el`'s existing freshness tracking. Without it an agent
can quote a stale chunk as current configuration, which is a correctness bug
rather than a cosmetic one.

A skill definition accompanies the shim, documenting the three verbs and their
JSON shapes for the calling agent. It lives in the agent's own skills directory
rather than in this repository, since it describes one operator's installation
rather than the package.

`scopes` exists because an agent cannot see the screen. Without enumeration it
either guesses collection names wrong or defaults to `:all` on every call.
`arc-scope.el` already holds the presets and the refusal guard for a nil-ed
collection list, so this verb reads existing state rather than building new.

**There is deliberately no `ask` verb.** When an external agent calls arc, that
agent is already the LLM. Routing through a local 3B model would insert a weaker
reasoner between the agent and the documents and discard the retrieval fidelity
this work exists to expose. `arc-ask` remains an Emacs-side command.

## Measurement plan

The eval set already expresses document-level ground truth. `:expect` clauses
match on `:kind`, `:option-name` and `:path-suffix` — *source* identity, not
chunk identity. Document-level recall therefore needs no new ground truth; the
existing question set already describes exactly what rollup is asked to produce.

- Extend `arc-eval.el` with document-level recall at k=5 and k=10.
- Sweep `max`, `top-3` and `sum`.
- Ship the winner as the default for `arc-rollup-function`.
- Re-measure `arc-search-pool` across the full eval set rather than the four
  queries that produced the table above.
- Record the losers in `docs/`, as this repo already does for stopword
  filtering, prefix matching and reranking.

## Testing

| Suite | Covers |
|---|---|
| `test-arc-rollup.el` | Scoring math, tie-break determinism, and the 1:1-vs-39:1 asymmetry between collection shapes |
| `test-arc-search-core.el` | Pool depth, scope pass-through, soft failure when the embedding endpoint is unreachable, and strategy stability (see below) |
| `test-arc-tool.el` | JSON shape, error paths, daemon-down exit code |

Existing ERT conventions and `test/run.sh`.

One explicit test earns its place: a deeper pool interacts with
`arc-scope-bruteforce-max` (2000), which decides between the brute-force and KNN
vector plans. A scoped search must pick the same strategy at pool 200 as at pool
40, or the measurements above do not transfer to scoped queries.

Note: `test/test-arc-search.el` already exists but tests `vec0` vector
primitives under an `es-` prefix, not search. The name is misleading. This work
routes around it and does not rename it.

## Out of scope

- PDFs and complex documents. Still rejected.
- An `ask` verb for agents. See above.
- An MCP server. If wanted later it is a thin shim over `bin/arc`.
- Enabling the reranker. The seam stays as it is, off by default.
- Any indexing change: no new tables, no migration, no reindex.
- Renaming `test/test-arc-search.el`.

## Risks

| Risk | Mitigation |
|---|---|
| Daemon down means the agent interface is dead — a failure mode the Emacs-only design never had | Explicit exit code 2 and a plain message. This is the real cost of the one-process-tree constraint, named rather than hidden. |
| The stage-2 result swap feels jarring | Selection preserved by source-id. May still need tuning after live use. |
| Embedding endpoint unreachable mid-search | Stage-1 results persist, a note is shown, nothing throws. |
| `arc-search-pool` = 200 was chosen from four queries | Re-measured across the full eval set before it ships as the default. |
| A deeper pool shifts vector-plan selection under `arc-scope-bruteforce-max` | Explicit strategy-stability test. |
| Rollup default chosen before measurement | `max` is provisional and labelled as such; the harness replaces it. |
