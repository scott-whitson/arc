# arc — Needle as the glue, and the whole of `~` as the corpus

Date: 2026-09-17
Status: agreed, not yet planned
Supersedes in part: `docs/design/2026-08-29-design.md` ("Evaluated and rejected → Cactus / Needle 2")

## Why this exists

Two complaints, one design.

1. **Retrieval is weak and the repo already says so.** `arc-index.el:131` records
   `recall@3 0.12  @5 0.25  @10 0.75  6/8 found` over the dotfiles eval set — two
   of eight questions are never retrieved at any k. `arc-chunk.el:79` records a
   436 KB org-roam note embedding "to a vector describing about 2% of its actual
   content" because `nomic-embed-text` truncates. The embedding model is the
   search engine, and this one has a documented defect.
2. **The corpus is three directories.** `arc-collection-directory-alist` covers
   `~/dotfiles`, `~/projects/eminix` (a directory that does not exist) and
   `~/docs/org`. The operator wants to search anything under `~`.

The framing that settles the architecture: *the LLM is glue; the search tools are
the product.* arc should be a small, fast, accurate retrieval engine that a
larger agent drives.

## The three layers, and what serves each

| Layer | Job | Decision |
|---|---|---|
| Front glue | natural language → structured `arc_search(...)` call | **Needle 3** |
| Retrieval | embed + BM25 + fuse + rerank | **Needle 3 `agent.embed`**, gated on measurement |
| Back glue | retrieved chunks → prose answer | **Deleted** |

### Front glue: Needle 3

Needle 3 is a laddered Simple Attention Network, 29–121M parameters, 8–29 MB in
CQ2-bit, with a Python API (`@needle.tool` decorators, `Field` constraints),
a C static library (`libneedle.a` + `needle.h`), and Linux x86_64 support.
Argument bounds compile into decode grammar, so invalid values are
unrepresentable rather than discouraged. It is single-shot intent extraction:
it turns a request into a call and does not take results back.

The August design doc rejected Needle 2 on three grounds. Two are now stale —
Needle 3 supports Linux x86_64 (Needle 2 was ARM NEON only) and carries an
8,192-token embedding (Needle 2's window was 256 tokens). The third, that CQ2
quantization collapses general capability, was always an argument against
Needle as arc's *brain*, which is not what this spec proposes. That doc's own
escape clause is the thing being exercised here: *"if arc ever gains actions,
Needle is a strong candidate for the intent→structured-call layer."*
`arc-tool.el` and `bin/arc` are those actions.

**Confidence gating** is adopted: the engine scores each call and withholds
below 0.1, returning an empty call rather than a guess — the correct failure
mode for a search router. Bands: `>=0.7` execute, `0.1-0.7` confirm, `<0.1`
refuse. **Constraint to record:** the confidence head is calibrated on base
weights only; a tuned archive loaded with `weights=` reports `confidence` as
`None`. arc takes the gate and forgoes fine-tuning.

**Unverified, do not plan around it.** cactuscompute.com/blog/intelligence-ladders
reports Mobile Actions accuracy of 4L 36.8%, 8L 80.7%, 16L 86.0%, **20L 47.0%**.
A 20-layer rung scoring below the 8-layer rung contradicts the ladder's premise.
Worth confirming against the Hugging Face model card, but it does not gate the
choice of rung.

**Rung: 8L** (52M parameters, 48 MFLOPs/token, ~15 MB CQ2-bit). Decided, not
provisional. It is the best Mobile Actions score of the small rungs at 80.7%,
it is the depth Cactus's own guide recommends for a Raspberry Pi class target,
and the ~15 MB binary keeps the "small thing" property this design is for. 16L
buys 5.3 points for 46M more parameters and 9 more MB; the anomalous 20L number
is not a reason to reach past 8L either way.

### Retrieval: Needle, if and only if it measures better

`agent.embed(text)` is public — "a vector for text or a serialised tool schema,
from the retrieval head." So Needle can serve the embedding slot, and if it
does, arc drops Ollama entirely: one 8–29 MB binary replaces a multi-gigabyte
daemon.

The risk is specific and must be measured, not argued: that vector comes from a
head trained to match *requests against tool schemas*, not questions against
prose documents. It may be worse than `nomic-embed-text` at arc's actual job.

`arc-eval.el` exists for exactly this. Its own commentary: *"every remaining
question about arc — is a different embedding model better ... is unanswerable
without a measurement."*

**Bake-off arms:** `nomic-embed-text` (baseline, 768d), `bge-m3` (1024d, 8192
window — kills the truncation defect outright), `mxbai-embed-large` (1024d),
`needle-embed` (dimension TBD from `agent.embed`).

**Corpus measurement, 2026-09-17.** Measured over the five collections this
branch enables — `vault`, `home`, `emacs`, `claude`, `agent-shell`:

| | files | chunks |
|---|---:|---:|
| vault / home / emacs / claude / agent-shell | 11,102 | 272,282 |
| full `arc-index-plan` (adds nix options, hm options, builtin manuals) | 49,587 | 310,767 |

Per-collection detail worth keeping: `vault` 419 files / 16,468 chunks;
`agent-shell` 19 files / 53,141 chunks; nix options 25,274 chunks; hm options
5,572 chunks; builtin manuals 7,639 chunks.

**Embedding cost, same date.** Sampled with 20 real `llm-embedding` calls
against `nomic-embed-text`: 0.132 s/call serial, projecting roughly 600–680
minutes serial, or 150–170 minutes under the most favourable concurrent
reading. That is a 20-call sample extrapolated to ~310k chunks, not a
measured full run — soft enough to move, not soft enough to ignore. The
budget for doing this inside the corpus-widening plan was 90 minutes; the
projection blew it by 6–7x, so the embed did not run.

**No recall baseline was taken, deliberately.** *"The corpus growth and the
embedding-model swap both force a full rebuild, so they land in one run
rather than two"* (Scale, below) — a `nomic-embed-text` baseline measured now
would mean embedding the whole corpus once for the baseline and once more for
the bake-off. The Needle plan already measures all four arms —
`nomic-embed-text`, `bge-m3`, `mxbai-embed-large`, `needle-embed` — in one
pass over this corpus, with the `nomic-embed-text` arm serving as the
baseline. That is strictly better than a separate baseline run: same corpus,
same session, directly comparable.

**Gate:** Needle takes the embedding slot only if it does not regress
`recall@10` against the `nomic-embed-text` arm measured in that same pass. If
it regresses, Needle still ships as front glue and Ollama stays for
embeddings; "drop Ollama" is deferred, not abandoned.

A four-arm bake-off over ~310k chunks is, at this rate, a multi-hour job per
arm — the plan that runs it needs to schedule it as such, not as a coffee
break.

**Bake-off must not touch the live database.** `arc-embedding-size` is 768 and
`arc-db.el:43` states the vec0 table is created at a fixed width — every arm
with a different dimension needs its own database file, not a migration.

### Back glue: deleted

`arc-chat-provider` (`qwen2.5-coder:3b`), `arc-answer.el` and the prose-answer
path are removed. Needle cannot replace them — single-shot extraction cannot
take ten retrieved chunks and write a paragraph — and nothing should. arc
returns ranked chunks through `arc-tool.el` and `bin/arc`; Claude Code, pi or
agent-shell supplies the prose. This is the smallest arc that does the job.

## Transport

Needle ships a Python package and a C static library. No HTTP server, no
OpenAI-compatible endpoint.

**Chosen: a persistent local Python process exposing a minimal `/embeddings`
endpoint, reached by a custom `llm` provider.** Every existing call site keeps
calling `llm-embedding` against `arc-embeddings-provider`; only the provider
struct changes. `arc-index.el`, `arc.el` and `arc-search.el` are untouched by
the swap.

The August doc rejected turbovec because a Python sidecar "forfeits the property
this whole system is built on — one process tree, inside Emacs, nothing to
babysit." That objection is weaker than it reads, because it is not currently
true: Ollama is already a babysat daemon (emanix commit `cf0c7c2`, "Add ollama
auto-start"). This swaps a multi-gigabyte daemon for a ~29 MB one and leaves
the count of external processes exactly where it is, at one. It does not add a
dependency class that was absent.

**Rejected alternative:** an Emacs dynamic module wrapping `libneedle.a`. It
genuinely removes the daemon, and native code is not taboo here —
`arc-db.el:300` already does `sqlite-load-extension` on vec0 behind the
`arc-sqlite-vec-path` defcustom. But SQLite supplies that loader; Emacs supplies
no equivalent, so this means hand-writing `emacs_module_init`, packaging a `.so`
through Nix, and maintaining an FFI. Revisit once the measurement justifies it.

## Corpus

### Collections

| Collection | Directory | Chunker | Notes |
|---|---|---|---|
| `vault` | `~/docs/org` | `org` | unchanged; preserves org ids, titles, `arc-eval`'s `:org-id` matching |
| `home` | `~` | `file` | 12,593 visible files measured 2026-09-17 |
| `emacs` | `~/.config/emacs` | `file` | config, `lisp/`, `personal-lisp/` |
| `claude` | `~/.claude` | `file` | skills, memory, CLAUDE.md, transcripts |
| `agent-shell` | `~/.agent-shell` | `file` | transcripts |
| `mail` | `~/.mail` | `file` | **not in `arc-index-plan` by default; opt-in** |

`dotfiles` and `eminix` are removed — `home` subsumes both.

### Why `~` is safe, and where it is not

`arc-ignore-invisible-files` defaults to `t` (`arc-source-file.el:26`), so a
`home` collection rooted at `~` already excludes every dotted directory:
`~/.cache`, `~/.local` (124,521 files, 14 GB), `~/.pi` (41,982 files, 1.1 GB),
`~/.mail`, browser and password-manager caches. Blanket `~` does not drag those in.
`.gitignore`/`.ignore`/`.rgignore` handling and `arc-secret-denylist`
(`*.age`, `*.gpg`, `*.pem`, `id_rsa`, `.env`) apply on top.

That same exclusion is why the dotted directories that *do* hold data —
`~/.config/emacs`, `~/.claude`, `~/.agent-shell` — must be named as their own
collections. Turning `arc-ignore-invisible-files` off globally is rejected: it
would admit 14 GB of `~/.local` and every browser cache.

### Overlap and cache exclusion: `.arcignore`

Two overlaps need excluding, and one existing mechanism already handles both:
add `".arcignore"` to `arc-ignore-patterns-files`. A dedicated filename rather
than `.ignore` so nothing here changes ripgrep's behaviour for the operator.

- `~/.arcignore` — `docs/org/` (owned by `vault` with the org chunker; without
  this it is indexed twice, once with the wrong chunker), `downloads/`
  (2,330 files, installer and ISO junk).
- `~/.config/emacs/.arcignore` — `elpa/`, `eln-cache/`, `auto-save-list/`,
  `ellama-sessions/`, and `arc/`.

### Trap: arc must not read its own database

`~/.config/emacs/arc/arc.sqlite` is 467 MB. `arc--text-file-p`
(`arc-source-file.el:102`) calls `find-file-noselect` and scans the buffer for a
null byte — so it would read the entire 467 MB into memory to conclude the file
is binary, once per index run. The `.arcignore` entry above handles the common
case; add `*.sqlite`, `*.sqlite-wal`, `*.sqlite-shm` to `arc-secret-denylist`
as well, so no future collection can re-introduce it.

### Scale

49,587 visible files under `~` against a measured corpus of 310,767 chunks
(2026-09-17, full `arc-index-plan`). A full re-embed projects to roughly
600–680 minutes of sustained compute, serial (see Retrieval, above, for the
sampling method). The corpus growth and the embedding-model swap both force a
full rebuild, so they land in one run rather than two.

## The `eminix` → `emanix` rename

`eminix` is not a typo but a stale name. The distribution is `emanix`
(`~/projects/emanix/flake.nix:2`, "emanix — a NixOS distribution"), its manual
moved to emanix.net in commit `7cd671a`, and its Emacs layer ships
`emanix-welcome.el` with `emanix/`-prefixed symbols. arc still says `eminix`,
which is why `arc-collection-directory-alist` points at a directory that does
not exist and that collection has been silently indexing nothing —
`arc-index.el:619` treats a missing directory as an ordinary reported skip.

**Rename:** `arc-index.el:413,425,619`; `arc.el:1` (the package header line,
user-visible) and `arc.el:64`; `README.org:255,259,266`;
`test/test-arc-index.el:134,235`; `test/fixtures/roam/note-b.org:4,7`.

**Do not rename:** anything under `docs/design/`. Those are dated records of
what was true when written, and `2026-08-29-design.md:33` is specifically about
a hardcoded-path defect — rewriting it destroys the evidence of the bug that
motivated arc's redesign.

Note that `arc-index.el:413` also changes shape: the `eminix` collection is
deleted outright rather than renamed, because `home` subsumes it. The rename
survives only in `arc.el`'s header, the README prose, the tests and the fixture.

## Out of scope

- Fine-tuning Needle. It costs the confidence gate, and the gate is worth more.
- An Emacs dynamic module over `libneedle.a`. Recorded above, deferred.
- Indexing the three remaining web manuals from `M-x emanix-guides`
  (emanix.net, nix.dev, nixpkgs). arc is offline by construction; fetching them
  is a separate decision. The six Info targets in that list are already covered
  — `arc-index-info-cap` is nil, so all builtin manuals are indexed.
- Any change to `~/dotfiles` or `~/projects/emanix`. This spec touches the arc
  repo only.

## Success criteria

1. `arc-eval-run` reports all four embedding arms — `nomic-embed-text`,
   `bge-m3`, `mxbai-embed-large`, `needle-embed` — with `recall@5` and
   `recall@10`, each in its own database, measured in one pass over this
   corpus; the `nomic-embed-text` arm serves as the baseline the other three
   are judged against.
2. arc indexes `~` under the five collections enabled in `arc-index-plan`
   (`vault`, `home`, `emacs`, `claude`, `agent-shell`), with `mail` configured
   but off; excludes every cache named here; and never reads `arc.sqlite`.
3. `grep -rn eminix` over `*.el`, `README.org` and `test/` returns nothing.
4. `arc-chat-provider` and `arc-answer.el` are gone; `arc-tool.el` and `bin/arc`
   still return ranked chunks.
5. If and only if criterion 1 clears the gate: `arc-embeddings-provider` points
   at Needle and nothing in arc requires Ollama.
