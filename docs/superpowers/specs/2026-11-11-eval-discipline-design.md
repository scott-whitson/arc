# arc eval discipline: what to measure, on which questions, and how to tune

**Status:** built (arc-eval.el, `arc-eval-final-report`); first full-corpus
measurement pending the reindex of 2026-11-11
**Date:** 2026-11-11

## Why this exists

Every retrieval default arc ships was picked by a harness that measured one
thing (recall@k), over one undivided set of 33 questions, and was tuned on the
same questions it was then scored on. The 33 questions held no org-node target,
21 of them were option lookups, and nine named files at paths the dotfiles repo
no longer has. The numbers in the README were taken on a 63,302-chunk corpus
that no longer exists. The live index on rafik had never been built in full at
all: `home` held 1 source and freshness called it `fresh`.

So nothing currently says whether `arc-rrf-k` 60 and `arc-rrf-semantic-weight`
2 are right, and nothing could. The harness has to tell a tuned number from a
memorised one before tuning means anything.

## What was adopted from AutoRAG, and why

AutoRAG (Marker-Inc-Korea) is a RAG AutoML framework. Its retrieval metrics,
its normalisation catalogue for hybrid fusion and its habit of filtering
generated questions are worth having; most of the rest of it is not.

| Adopted | Why |
|---|---|
| MRR and nDCG beside recall | recall@k cannot tell rank 1 from rank 10; a fusion change mostly moves ranks |
| Convex-combination fusion with min-max, theoretical-min-max, z-score and DBSF normalisation | RRF throws the arms' scores away; it is worth knowing whether keeping them helps |
| Question filters, applied by hand | drop questions that only make sense with the passage in view, and questions whose answer is not actually in the target |

## What was rejected

| Rejected | Why |
|---|---|
| The YAML AutoML framework | a pipeline config language for one Emacs package with one retrieval path is overhead with no consumer |
| Greedy node-by-node pipeline search | it optimises each stage given the previous stage's winner, which is not the joint optimum, and arc has two stages worth tuning, not seven |
| LLM query expansion (HyDE, multi-query) | arc is local and offline by construction and the query path makes one embedding call; expansion adds a chat model to every search |
| Generation metrics (BLEU, ROUGE, G-Eval, ...) | arc returns sources, not prose; there is nothing to score |
| The reranker catalogue | arc has one reranker seam, off by default, and no packaged cross-encoder; a catalogue of rerankers with no way to run any of them measures nothing |
| AutoRAG's nDCG ideal | it is computed from the flattened count of relevant items, so a question listing three interchangeable sources can never score 1; arc's ideal is the number of groups |

## The question set

The set stays outside the repo (`arc-eval-set-file`, default
`~/docs/org/arc-eval.eld`): a useful set names real paths and ids. The
synthetic sample under `test/fixtures` is a shape, not a measurement.

An entry's `:expect` is an AND of OR-groups. A plain clause is a group of one,
so a set written before groups existed scores exactly as it did. `(:any A B)` is
one need with interchangeable sources. `:negative t` marks a question whose
right answer is nothing in the corpus; it carries no `:expect`.

`arc-eval-validate` checks every member of every group. Given a source list
(`arc-eval-plan-sources`, the reindex's own enumeration) it checks against what
the reindex will build instead of what the database holds, which is how a set
is validated before a reindex finishes.

## Metric definitions

A group's rank is the 1-based position of its first matching item in the
retrieved list, which is max(`arc-eval-k`) long (10): chunks at chunk level,
documents (`arc-search-documents`, or the rolled-up fused pool offline) at
document level.

- **recall@k**: groups ranked at or above k, over all groups, pooled across
  questions. This is the micro average the harness always reported, so the old
  numbers stay comparable in kind.
- **MRR**: per question, the mean over its groups of 1/rank, 0 for a missed
  group (AutoRAG's definition); averaged over questions. Ranks past the list
  length score 0.
- **nDCG@k**: per question, binary gain at each group's rank, DCG = sum of
  1/log2(rank+1) over groups ranked at or above k, divided by IDCG = the same
  sum for ranks 1..min(groups, k). Capped at 1, since two groups first matched
  by one item share a rank. Averaged over questions.

Negatives contribute to none of these. They feed a separate profile: the top
hit's cosine distance (semantic arm), best bm25 relevance and fused score, for
negatives against positives, and a table of how many of each a refusal
threshold on nearest distance would refuse. That table is the input
`arc-retrieval-max-distance` has waited for since phase 3. The fused RRF score
is reported but cannot carry a threshold: it is a function of rank alone.

## The split rule

`:split dev` or `:split test` on a question wins. Otherwise the first 32 bits of
the SHA-1 of the question text, mod 100, under 70 is `dev`. The rule is stable
under reordering and growth, and reproducible outside Emacs. Questions added on
2026-11-11 carry explicit splits so a later edit cannot move one.

Tuning (`arc-eval-sweep`) reads `dev` only. The report scores the winners and
the shipped configuration on `dev` and on `test`. A default changes only when
`test` agrees with `dev`, by more than one or two groups, on the full corpus.

## The sweep method

Each question's two arms run once (`arc-eval-cache-arms`), at document-search
depth (`arc-search--effective-pool`), keeping each candidate's raw score:
cosine distance for the semantic arm (fused as similarity, 1 - distance, in
[-1, 1]), and FTS5 `bm25()` for the keyword arm, which is negated BM25 (fused
as -bm25(), in [0, inf)). Every fusion configuration is then scored offline
against identical candidates, so a difference between two configurations is
the fusion's and not the embedding service's, and a sweep of ~120
configurations costs one embedding call per question.

- **rrf**: W/(K + semantic rank) + 1/(K + keyword rank), K in
  `arc-eval-sweep-rrf-k`, W in `arc-eval-sweep-rrf-weights`. The shipped
  configuration is tried first, so it wins ties.
- **cc**: W·norm(semantic) + (1-W)·norm(keyword), W in
  `arc-eval-sweep-cc-weights`, norm one of min-max; theoretical-min-max
  (theoretical floor, observed ceiling: -1 for similarity, 0 for bm25
  relevance); z-score; DBSF ((x - (mean - 3sd)) / 6sd, clipped to [0, 1]). A
  candidate one arm did not return takes that arm's floor.

Chunk-level fusion cuts each arm to `arc-knn-candidates` as `arc--find-similar`
does; document-level fusion rolls the whole pool up with `arc-rollup` as
`arc-search-documents` does. The report checks that offline RRF at the shipped
settings reproduces the live fused ranking, question by question; a mismatch
means the sweep is measuring a different ranker. The objective is
document-level nDCG@10, then document recall@10, then chunk nDCG@10, because
documents are what a reader of search results sees.

Latency is recorded per question (embed, each arm, the live fused query) and
reported as median and p95 with the first query dropped as warm-up.

## Out of scope

- Changing any shipped default. That waits for the full corpus and a `test`
  split that agrees.
- The embedding bake-off of the 2026-09-17 spec. The cached-arm design is what
  makes it cheap: one cache per embedding model's database, the same sweep over
  each.
- Chunker changes. The census found the file chunker splitting agent-shell
  transcripts into 344,484 chunks averaging 203 characters; merging small
  paragraphs would change every file collection's numbers and needs its own
  measurement.
