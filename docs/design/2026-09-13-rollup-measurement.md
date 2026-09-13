# Rollup aggregation, measured

`arc-rollup-function` chooses how a document's score is aggregated from its
chunks'. Three candidates were swept against the eval set with
`arc-eval-rollup-sweep`, at the cutoffs in `arc-eval-k`.

| function | recall@5 | recall@10 |
|---|---:|---:|
| max | 0.73 | 0.82 |
| top-n (n=3) | 0.64 | 0.73 |
| sum | 0.58 | 0.67 |

**Adopted:** `max`, ahead at both k=5 and k=10 by a wide margin (0.73/0.82
vs. the next best 0.64/0.73), so there is no tie to break.

**Rejected:** `top-n` (n=3), at 0.64 recall@5 and 0.73 recall@10. `sum`, at
0.58 recall@5 and 0.67 recall@10 -- the weakest of the three at both
cutoffs.

`top-n` (n=3) was the predicted favorite going in -- both the spec and the
plan expected it to win, on the theory that summing a bounded handful of a
document's best chunks would add real signal from multiple matches without
the unbounded length bias of `sum`. The measurement falsified that: `top-n`
came second at both cutoffs, and the mechanism is the same length
correlation in a milder form. Summing the best 3 chunk scores still lets a
document with three mediocre-but-present chunks outscore a document with one
excellent chunk, so `top-n` remains partially length-correlated where `max`
is fully length-invariant. Because arc's 1:1 collections (nix options, Info
nodes) compete directly against arc's 24-46:1 collections (vault notes,
dotfiles), that residual length correlation costs `top-n` recall on exactly
the documents length-invariance is meant to protect -- length-invariance beat
the extra signal from multiple matches.

`sum` was expected to lose before the sweep ran, and the prediction is worth
recording alongside the result. arc's corpus is two shapes in one schema: nix
options and Info nodes are one chunk per document, vault notes and dotfiles are
24 to 46. Summing every chunk rewards a document for being long, so a 39-chunk
note outranks a 1-chunk option on structure alone, regardless of relevance.
