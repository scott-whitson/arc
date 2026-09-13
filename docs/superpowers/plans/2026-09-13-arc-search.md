# arc search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give arc a fast, document-level, LLM-free search surface — usable from the minibuffer and callable by an external agent — over the index that already exists.

**Architecture:** A scored variant of the existing hybrid retrieval feeds a pure aggregation layer that groups chunks into ranked documents. Orchestration sits above that, and three consumers sit above orchestration: a consult source, a results buffer, and a JSON CLI reaching the running Emacs daemon through `emacsclient`. Nothing indexes, nothing migrates, nothing rewrites `arc-ask`.

**Tech Stack:** Emacs Lisp (29.2 floor), SQLite via `sqlite-select`, `sqlite-vec` `vec0`, FTS5, ERT, consult (optional, soft require), `emacsclient`.

**Spec:** `docs/superpowers/specs/2026-09-13-arc-search-design.md`

## Global Constraints

- **Emacs 29.2 minimum.** `take`, `plist-get` on plists, `string-join` are fine. Do not use Emacs 30+ only APIs (notably the `sort` keyword calling convention — use `(sort LIST PREDICATE)`).
- **The byte-compile gate treats warnings as errors.** `test/run.sh` runs `emacs -Q -batch -L . -f batch-byte-compile arc*.el` and fails on any line matching `Warning:`. Every new file must `require` what it uses and leave no unused variables.
- **No hardcoded home paths anywhere**, in code or docs. Derive from `(getenv "HOME")`. This repo is public.
- **No private content in the repo.** No vault text, no real note paths, no real query strings. Collection names and aggregate counts are already public in `arc-collection-directory-alist` and are fine.
- **No schema change, no migration, no reindex.** Every query below reads existing tables.
- **consult is an optional dependency.** Guard with `(require 'consult nil t)`; arc must load and pass its full suite without consult present.
- **No `Co-Authored-By` or AI-attribution trailers** in any commit message.
- **Tests must not require Ollama.** Integration tests use the `keyword` arm, which skips embedding entirely.
- Branch is `feat/search`. Commit after every task.
- Run the full suite with `test/run.sh`; run one suite with `emacs -Q -batch -L . -l test/<file>.el -f ert-run-tests-batch-and-exit`.

---

### Task 1: Scored retrieval

`arc--find-similar` computes RRF scores and discards them — the fused arm selects `hybrid_search.id` alone. Rollup needs the score. Add an optional argument rather than changing the existing return shape, which is load-bearing for `arc-ask` and `arc-eval`.

**Files:**
- Modify: `arc.el` (`arc--find-similar`, currently at `arc.el:365`)
- Test: `test/test-arc-scored.el` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `(arc--find-similar TEXT SCOPE &optional ARM SCORED)`. When SCORED is non-nil the SQL selects two columns per row, `(ID SCORE)`, where SCORE is a float and rows stay in rank order. When SCORED is nil the SQL is byte-for-byte what it was before.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-scored.el`:

```elisp
;;; test-arc-scored.el --- retrieval can return its scores -*- lexical-binding: t; -*-
;;
;; arc--find-similar computed RRF scores and threw them away: the fused arm
;; selected hybrid_search.id alone.  Document rollup needs the score, so the
;; function grew an optional `scored' argument.  These tests pin both halves --
;; that scored SQL really returns (id score) pairs in rank order, and that an
;; unscored call is unchanged, because arc-ask and arc-eval both depend on the
;; single-column shape.
(require 'ert)
(require 'cl-lib)
(defvar asc-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asc-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-test-helpers)

(defun asc--index (text)
  "Index TEXT as a one-chunk file source in collection \"test\"."
  (arc-index-source
   (list :kind "file" :path (format "/tmp/%s.txt" (md5 text))
         :chunks (list (list :text text :line-start 1 :line-end 1)))
   "test"))

(ert-deftest asc-unscored-keyword-sql-selects-one-column ()
  "An unscored call must keep the single-column shape arc-ask depends on."
  (let ((sql (arc--find-similar "alpha" nil 'keyword)))
    (should (string-match-p "SELECT keyword_search\\.id FROM" sql))
    (should-not (string-match-p "AS score" sql))))

(ert-deftest asc-scored-keyword-sql-selects-a-score ()
  (let ((sql (arc--find-similar "alpha" nil 'keyword t)))
    (should (string-match-p "AS score" sql))))

(ert-deftest asc-scored-keyword-returns-id-score-pairs ()
  "Two columns per row, scores descending with rank."
  (arc-test-with-temp-db
   (asc--index "alpha beta gamma")
   (asc--index "alpha delta")
   (let* ((sql (arc--find-similar "alpha" nil 'keyword t))
          (rows (sqlite-select (arc-db) sql)))
     (should (= (length rows) 2))
     (should (= (length (car rows)) 2))
     (should (cl-every #'numberp (mapcar #'cadr rows)))
     (should (>= (cadr (nth 0 rows)) (cadr (nth 1 rows)))))))

(ert-deftest asc-unscored-keyword-returns-one-column ()
  (arc-test-with-temp-db
   (asc--index "alpha beta")
   (let* ((sql (arc--find-similar "alpha" nil 'keyword))
          (rows (sqlite-select (arc-db) sql)))
     (should (= (length (car rows)) 1)))))

(provide 'test-arc-scored)
;;; test-arc-scored.el ends here
```

- [ ] **Step 2: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-scored.el -f ert-run-tests-batch-and-exit`
Expected: `asc-scored-keyword-sql-selects-a-score` and `asc-scored-keyword-returns-id-score-pairs` FAIL — the fourth argument is ignored, so no `AS score` appears.

- [ ] **Step 3: Add the `scored` argument**

In `arc.el`, change the signature and all three branches of the `pcase`. The score expression for the single-arm cases mirrors RRF's own shape so rollup never has to branch on which arm produced its input:

```elisp
(defun arc--find-similar (text scope &optional arm scored)
```

Append to the existing docstring:

```
SCORED, when non-nil, adds a second column to every row: the score the
ranking already computed.  It is additive on purpose -- `arc-ask' and
`arc-eval' both consume the single-column shape, so the default return
must not move.  For the single-arm cases, which have a rank but no RRF
score, the score is `1.0 / (arc-rrf-k + rank)': the same shape and the
same magnitude as a one-sided fused score.
```

Semantic branch:

```elisp
('semantic
 (format "WITH\n%s,\n%s\nSELECT semantic_search.id%s FROM semantic_search
                ORDER BY semantic_search.rank ASC LIMIT %d;"
         (arc--scoped-cte scope) (arc--semantic-cte scope vec)
         (if scored
             (format ", 1.0 / (%d + semantic_search.rank) AS score" arc-rrf-k)
           "")
         (arc-get-limit)))
```

Keyword branch:

```elisp
('keyword
 (format "WITH\n%s,\n%s\nSELECT keyword_search.id%s FROM keyword_search
                ORDER BY keyword_search.rank ASC LIMIT %d;"
         (arc--scoped-cte scope) (arc--keyword-cte text)
         (if scored
             (format ", 1.0 / (%d + keyword_search.rank) AS score" arc-rrf-k)
           "")
         (arc-get-limit)))
```

Fused branch — only the final `SELECT` line and one trailing format argument change:

```elisp
(_
 (format "WITH
%s,
%s,
%s,
hybrid_search AS (
  SELECT
    COALESCE(semantic_search.id, keyword_search.id) AS id,
    COALESCE(%f / (%d + semantic_search.rank), 0.0) +
    COALESCE(1.0 / (%d + keyword_search.rank), 0.0) AS score
  FROM semantic_search
  FULL OUTER JOIN keyword_search ON semantic_search.id = keyword_search.id
  ORDER BY score DESC
  LIMIT %d
)
SELECT hybrid_search.id%s FROM hybrid_search;"
         (arc--scoped-cte scope)
         (arc--semantic-cte scope vec)
         (arc--keyword-cte text)
         (float arc-rrf-semantic-weight) arc-rrf-k arc-rrf-k
         (arc-get-limit)
         (if scored ", hybrid_search.score" "")))
```

- [ ] **Step 4: Run the new suite and the two suites most likely to notice**

Run: `emacs -Q -batch -L . -l test/test-arc-scored.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 4 tests.

Run: `emacs -Q -batch -L . -l test/test-arc-retrieve.el -f ert-run-tests-batch-and-exit`
Run: `emacs -Q -batch -L . -l test/test-arc-rank-order.el -f ert-run-tests-batch-and-exit`
Expected: both PASS, unchanged counts.

- [ ] **Step 5: Run the full suite**

Run: `test/run.sh`
Expected: exit 0, byte-compile gate clean, test count up by 4.

- [ ] **Step 6: Commit**

```bash
git add arc.el test/test-arc-scored.el
git commit -m "feat(search): let retrieval return the scores it already computes

The fused arm computed an RRF score per candidate and selected only the
id, so every consumer got a rank order with no magnitudes. Document
rollup needs the magnitudes to aggregate chunks into documents.

Additive rather than a shape change: arc-ask and arc-eval both consume
the single-column return, and an unscored call now produces the same SQL
it did before, asserted directly. The single-arm cases get 1.0/(k+rank),
the same shape and magnitude as a one-sided fused score, so rollup never
branches on which arm produced its input."
```

---

### Task 2: Rollup scoring

The one piece that gets measured and swapped, so it is pure: no database, no I/O, no UI, testable in isolation.

**Files:**
- Create: `arc-rollup.el`
- Test: `test/test-arc-rollup.el` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `arc-rollup-function` — defcustom, one of `max` / `top-n` / `sum`, default `max` (provisional; Task 4 replaces it with the measured winner).
  - `arc-rollup-top-n` — defcustom integer, default 3.
  - `arc-rollup-passages` — defcustom integer, default 3.
  - `(arc-rollup-score SCORES)` → float. SCORES is a list of floats, best first.
  - `(arc-rollup CHUNKS)` → list of document plists. CHUNKS is an ordered list of `(:id :source-id :score)` plists, best first. Each returned plist has `:source-id :score :chunk-count :best-rank :passages`, where `:passages` holds at most `arc-rollup-passages` of the input chunk plists in input order.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-rollup.el`. The asymmetry test is the important one — it encodes the reason rollup exists at all:

```elisp
;;; test-arc-rollup.el --- chunk scores to ranked documents -*- lexical-binding: t; -*-
;;
;; arc's corpus is two shapes in one schema: nix options and Info manuals are
;; one chunk per document, the vault and dotfiles are 24-46.  A chunk-level
;; result set therefore lets one long note consume every slot.  Rollup groups
;; chunks back into documents, and the choice of aggregation is exactly where
;; that asymmetry can be re-introduced by accident -- see
;; arb-sum-rewards-length-and-the-others-do-not.
(require 'ert)
(defvar arb-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path arb-root)
(require 'arc-rollup)

(defun arb--chunks (&rest specs)
  "Build a chunk list from SPECS, each (SOURCE-ID SCORE)."
  (let ((id 0))
    (mapcar (lambda (s)
              (setq id (1+ id))
              (list :id id :source-id (nth 0 s) :score (nth 1 s)))
            specs)))

(ert-deftest arb-max-takes-the-best-chunk ()
  (let ((arc-rollup-function 'max))
    (should (= (arc-rollup-score '(0.5 0.4 0.1)) 0.5))))

(ert-deftest arb-top-n-sums-only-the-best-n ()
  (let ((arc-rollup-function 'top-n) (arc-rollup-top-n 3))
    (should (= (arc-rollup-score '(0.5 0.4 0.1 99.0)) 1.0))))

(ert-deftest arb-top-n-handles-fewer-chunks-than-n ()
  (let ((arc-rollup-function 'top-n) (arc-rollup-top-n 3))
    (should (= (arc-rollup-score '(0.5)) 0.5))))

(ert-deftest arb-sum-takes-everything ()
  (let ((arc-rollup-function 'sum))
    (should (= (arc-rollup-score '(0.5 0.4 0.1)) 1.0))))

(ert-deftest arb-unknown-function-signals ()
  (let ((arc-rollup-function 'median))
    (should-error (arc-rollup-score '(0.5)))))

(ert-deftest arb-groups-chunks-into-documents ()
  (let* ((arc-rollup-function 'max)
         (docs (arc-rollup (arb--chunks '(7 0.9) '(7 0.8) '(9 0.5)))))
    (should (= (length docs) 2))
    (should (= (plist-get (car docs) :source-id) 7))
    (should (= (plist-get (car docs) :chunk-count) 2))
    (should (= (plist-get (car docs) :score) 0.9))))

(ert-deftest arb-passages-are-capped-and-keep-input-order ()
  (let* ((arc-rollup-function 'max)
         (arc-rollup-passages 2)
         (docs (arc-rollup (arb--chunks '(7 0.9) '(7 0.8) '(7 0.7))))
         (passages (plist-get (car docs) :passages)))
    (should (= (length passages) 2))
    (should (= (plist-get (nth 0 passages) :score) 0.9))
    (should (= (plist-get (nth 1 passages) :score) 0.8))))

(ert-deftest arb-sum-rewards-length-and-the-others-do-not ()
  "The whole reason the default is not `sum'.
Source 1 is a one-chunk option that matched well.  Source 2 is a
forty-chunk note that matched weakly forty times.  Under `sum' the note
wins on structure alone; under `max' and `top-n' it does not."
  (let ((chunks (append (arb--chunks '(1 0.5))
                        (apply #'arb--chunks
                               (make-list 40 '(2 0.05))))))
    (let ((arc-rollup-function 'sum))
      (should (= (plist-get (car (arc-rollup chunks)) :source-id) 2)))
    (let ((arc-rollup-function 'max))
      (should (= (plist-get (car (arc-rollup chunks)) :source-id) 1)))
    (let ((arc-rollup-function 'top-n) (arc-rollup-top-n 3))
      (should (= (plist-get (car (arc-rollup chunks)) :source-id) 1)))))

(ert-deftest arb-ties-break-on-chunk-count-then-best-rank ()
  "Equal scores: more chunks first; equal there too, earlier rank first."
  (let* ((arc-rollup-function 'max)
         (docs (arc-rollup (arb--chunks '(1 0.5) '(2 0.5) '(2 0.4)))))
    (should (equal (mapcar (lambda (d) (plist-get d :source-id)) docs) '(2 1))))
  (let* ((arc-rollup-function 'max)
         (docs (arc-rollup (arb--chunks '(1 0.5) '(2 0.5)))))
    (should (equal (mapcar (lambda (d) (plist-get d :source-id)) docs) '(1 2)))))

(ert-deftest arb-empty-input-yields-nil ()
  (should (null (arc-rollup nil))))

(provide 'test-arc-rollup)
;;; test-arc-rollup.el ends here
```

- [ ] **Step 2: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-rollup.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: arc-rollup`.

- [ ] **Step 3: Write `arc-rollup.el`**

```elisp
;;; arc-rollup.el --- chunk scores to ranked documents -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Retrieval ranks chunks.  A reader wants documents.  This file is the
;; conversion, and nothing else: no database, no I/O, no UI, so the
;; aggregation can be measured in isolation and swapped when measurement
;; says to.
;;
;; The conversion matters because arc's corpus is two shapes wearing one
;; schema.  Options and Info nodes are one chunk per document; vault
;; notes and dotfiles are twenty-four to forty-six.  At a chunk-level
;; limit of ten, one well-matched note can take every slot and hide five
;; other documents that also matched.

;;; Code:

(require 'cl-lib)

(defcustom arc-rollup-function 'max
  "How a document's score is aggregated from its chunks' scores.

`max'    -- the best chunk's score.  Safe: it cannot be inflated by
            document length, but it discards the signal in a document
            that matched in twelve places rather than one.
`top-n'  -- the sum of the best `arc-rollup-top-n' scores.  Bounded, so
            a forty-six-chunk dotfile cannot run away with the ranking.
`sum'    -- every chunk.  Expected to lose, and provided so the eval
            harness can demonstrate that rather than this docstring
            asserting it: summing rewards documents for being long, so
            every thirty-nine-chunk note outranks every one-chunk option
            on structure alone.

The default is provisional.  Picking an aggregation by intuition is the
mistake `arc-fts-query' records three times over -- stopword filtering,
oversized-document filtering and prefix matching each lost to BM25's own
weighting -- and the same prior applies here.  `arc-eval-rollup-sweep'
settles it."
  :type '(choice (const max) (const top-n) (const sum))
  :group 'arc)

(defcustom arc-rollup-top-n 3
  "How many of a document's best chunks `top-n' aggregation sums."
  :type 'integer :group 'arc)

(defcustom arc-rollup-passages 3
  "How many chunks of a document are kept as displayable passages."
  :type 'integer :group 'arc)

(defun arc-rollup-score (scores)
  "Aggregate SCORES, a list of floats best-first, per `arc-rollup-function'."
  (pcase arc-rollup-function
    ('max (or (car scores) 0.0))
    ('top-n (apply #'+ 0.0 (take arc-rollup-top-n scores)))
    ('sum (apply #'+ 0.0 scores))
    (other (error "arc-rollup: unknown `arc-rollup-function': %S" other))))

(defun arc-rollup--better-p (a b)
  "Rank document A before B.
Score descending, then chunk count descending, then best-rank
ascending.  Fully determined, so a ranking never depends on hash
order and the tests do not flake."
  (let ((sa (plist-get a :score)) (sb (plist-get b :score))
        (ca (plist-get a :chunk-count)) (cb (plist-get b :chunk-count)))
    (cond ((/= sa sb) (> sa sb))
          ((/= ca cb) (> ca cb))
          (t (< (plist-get a :best-rank) (plist-get b :best-rank))))))

(defun arc-rollup (chunks)
  "Group CHUNKS into ranked documents.

CHUNKS is an ordered list of plists (:id :source-id :score), best
first.  Return a list of plists (:source-id :score :chunk-count
:best-rank :passages), ranked by `arc-rollup--better-p'.  :passages
holds at most `arc-rollup-passages' of the input chunks, in input
order.  :best-rank is the input position of the document's best chunk,
kept because it is the last tie-break and because a caller may want to
know how far down the pool a document first appeared."
  (let ((table (make-hash-table :test #'eql))
        (order '())
        (n 0))
    (dolist (c chunks)
      (let ((sid (plist-get c :source-id)))
        (unless (gethash sid table)
          (puthash sid (list n) table)
          (push sid order))
        (let ((cell (gethash sid table)))
          (setcdr cell (cons c (cdr cell)))))
      (setq n (1+ n)))
    (sort
     (mapcar
      (lambda (sid)
        (let* ((cell (gethash sid table))
               (cs (reverse (cdr cell))))
          (list :source-id sid
                :score (arc-rollup-score
                        (mapcar (lambda (c) (plist-get c :score)) cs))
                :chunk-count (length cs)
                :best-rank (car cell)
                :passages (take arc-rollup-passages cs))))
      (nreverse order))
     #'arc-rollup--better-p)))

(provide 'arc-rollup)
;;; arc-rollup.el ends here
```

- [ ] **Step 4: Run the tests**

Run: `emacs -Q -batch -L . -l test/test-arc-rollup.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the full suite, including the byte-compile gate**

Run: `test/run.sh`
Expected: exit 0. The gate compiles `arc*.el`, which now includes `arc-rollup.el`; any missing `require` fails here.

- [ ] **Step 6: Commit**

```bash
git add arc-rollup.el test/test-arc-rollup.el
git commit -m "feat(search): group chunks back into documents

arc's corpus is two shapes in one schema: options and Info nodes are one
chunk per document, vault notes and dotfiles are 24 to 46. At a
chunk-level limit of ten that lets a single well-matched note take every
slot, hiding other documents that also matched.

Three aggregations, one of which is expected to lose: sum rewards a
document for being long, so a 39-chunk note beats a 1-chunk option on
structure alone. It ships anyway so the harness can show that instead of
a docstring asserting it -- arb-sum-rewards-length-and-the-others-do-not
pins the difference.

Pure on purpose: no database, no I/O, no UI. This is the piece that gets
measured and swapped, so it has to be testable alone. The default of max
is provisional until arc-eval-rollup-sweep replaces it."
```

---

### Task 3: Search orchestration

Where the pool gets deepened, clamped, and turned into hydrated documents.

**Files:**
- Create: `arc-search.el`
- Test: `test/test-arc-search-core.el` (create)

**Interfaces:**
- Consumes: `arc--find-similar` with SCORED (Task 1); `arc-rollup` (Task 2); existing `arc-ask-normalize-scope`, `arc--retrieve-rows`, `arc-row-to-source`, `arc-scope-empty-p`, `arc-scope-count`, `arc-scope-total`, `arc-scope-vector-plan`, `arc-vec0-k-ceiling`.
- Produces:
  - `arc-search-pool` — defcustom integer, default 200.
  - `arc-search-limit` — defcustom integer, default 10.
  - `(arc-search--effective-pool SCOPE)` → integer.
  - `(arc-search-documents QUERY &optional SCOPE ARM)` → list of at most `arc-search-limit` document plists: `(:source-id :kind :path :title :org-id :option-name :info-node :score :chunk-count :best-rank :passages)`. Each passage is `(:chunk :line-start :line-end :score)`.

**Why the clamp exists.** `arc-scope-vector-plan` asks vec0 for `k = ceil(arc-knn-candidates × total/n)` on a scoped query, and falls back to brute force when that exceeds `arc-vec0-k-ceiling` (4096). Brute force is exact but costs roughly 0.2 ms per row in scope. Raising the pool from 40 to 200 multiplies k by five, which means a scope between `arc-scope-bruteforce-max` (2000) and about 3100 chunks would flip from a fast KNN query to a ~400 ms brute-force one purely because search asked for a deeper pool. Measured on the live index, none of the four current presets land in that band — everything, vault, options and dotfiles all stay `knn`, worst case 120 ms → 176 ms — but a `:path-prefix` or `:tags` scope easily could. Search may be deep or may change the plan, not both.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-search-core.el`:

```elisp
;;; test-arc-search-core.el --- search orchestration -*- lexical-binding: t; -*-
;;
;; Integration tests here use the `keyword' arm throughout: it skips the
;; embedding call entirely, so the suite never needs a reachable Ollama.
(require 'ert)
(require 'cl-lib)
(defvar asr-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asr-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-search)
(require 'arc-test-helpers)

(defun asr--index-file (path collection &rest texts)
  "Index TEXTS as consecutive chunks of one file source at PATH."
  (arc-index-source
   (list :kind "file" :path path
         :chunks (let ((n 0))
                   (mapcar (lambda (tx)
                             (setq n (1+ n))
                             (list :text tx :line-start n :line-end n))
                           texts)))
   collection))

(ert-deftest asr-pool-is-not-clamped-for-an-empty-scope ()
  (let ((arc-search-pool 200) (arc-knn-candidates 40))
    (should (= (arc-search--effective-pool (arc-scope)) 200))))

(ert-deftest asr-pool-never-drops-below-the-default-candidates ()
  (let ((arc-search-pool 5) (arc-knn-candidates 40))
    (should (= (arc-search--effective-pool (arc-scope)) 40))))

(ert-deftest asr-search-returns-documents-not-chunks ()
  "One source with five matching chunks is one result, not five."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test"
                    "alpha one" "alpha two" "alpha three"
                    "alpha four" "alpha five")
   (let* ((arc-rollup-function 'max)
          (docs (arc-search-documents "alpha" '(:all t) 'keyword)))
     (should (= (length docs) 1))
     (should (= (plist-get (car docs) :chunk-count) 5))
     (should (equal (plist-get (car docs) :path) "/tmp/a.txt")))))

(ert-deftest asr-search-hydrates-passages-with-text-and-lines ()
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha one" "alpha two")
   (let* ((arc-rollup-function 'max)
          (arc-rollup-passages 2)
          (doc (car (arc-search-documents "alpha" '(:all t) 'keyword)))
          (p (car (plist-get doc :passages))))
     (should (stringp (plist-get p :chunk)))
     (should (string-match-p "alpha" (plist-get p :chunk)))
     (should (integerp (plist-get p :line-start)))
     (should (numberp (plist-get p :score))))))

(ert-deftest asr-search-honours-the-document-limit ()
  (arc-test-with-temp-db
   (dotimes (i 6)
     (asr--index-file (format "/tmp/f%d.txt" i) "test" "alpha"))
   (let ((arc-search-limit 3)
         (arc-rollup-function 'max))
     (should (= (length (arc-search-documents "alpha" '(:all t) 'keyword)) 3)))))

(ert-deftest asr-search-respects-scope ()
  "A document outside the scope must never appear."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/in.txt" "keep" "alpha inside")
   (asr--index-file "/tmp/out.txt" "drop" "alpha outside")
   (let* ((arc-rollup-function 'max)
          (docs (arc-search-documents "alpha" '(:collections ("keep")) 'keyword)))
     (should (= (length docs) 1))
     (should (equal (plist-get (car docs) :path) "/tmp/in.txt")))))

(ert-deftest asr-search-on-no-match-yields-nil ()
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha")
   (should (null (arc-search-documents "zzzznomatch" '(:all t) 'keyword)))))

(ert-deftest asr-deep-pool-does-not-flip-the-vector-plan ()
  "The clamp's whole purpose.
A scope just above `arc-scope-bruteforce-max' takes the KNN plan at the
default pool.  Deepening the pool five-fold would scale k past
`arc-vec0-k-ceiling' and silently drop it to brute force, which costs
roughly 0.2 ms per row in scope.  The effective pool must keep the plan
it started with."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/big.txt" "test"
                    "alpha" "beta" "gamma" "delta" "epsilon")
   ;; Force the arithmetic rather than index thousands of rows: a tiny
   ;; bruteforce-max puts this scope in the KNN band, and a tiny ceiling
   ;; reproduces the flip at a pool this suite can actually build.
   (let* ((scope '(:collections ("test")))
          (arc-scope-bruteforce-max 1)
          (arc-knn-candidates 2)
          (arc-search-pool 200)
          (base (car (arc-scope-vector-plan scope)))
          (pool (arc-search--effective-pool scope)))
     (should (eq base 'knn))
     (let ((arc-knn-candidates pool))
       (should (eq (car (arc-scope-vector-plan scope)) base))))))

(provide 'test-arc-search-core)
;;; test-arc-search-core.el ends here
```

- [ ] **Step 2: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-search-core.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: arc-search`.

- [ ] **Step 3: Write `arc-search.el`**

```elisp
;;; arc-search.el --- document search over the arc index -*- lexical-binding: t; -*-

;;; Commentary:

;; arc's retrieval was built to feed an LLM: `arc-ask' asks for ten
;; chunks and hands them to a model.  This file is the other consumer of
;; the same machinery -- ranked documents, no model, no network beyond
;; the embedding call the fused arm already makes.
;;
;; Two things happen here that rollup cannot do for itself.  The
;; candidate pool is deepened, because ten chunks cannot yield ten
;; documents; and it is then clamped, because deepening it is not free
;; in every scope.  See `arc-search--effective-pool'.

;;; Code:

(require 'cl-lib)
(require 'arc)
(require 'arc-scope)
(require 'arc-rollup)

(defcustom arc-search-pool 200
  "How many chunks retrieval considers before rolling them up.

Ten chunks cannot produce ten documents: on this corpus a two-hundred
chunk pool yields about a hundred and thirty distinct sources, and a
forty-chunk one routinely yields fewer than ten.  Depth is close to
free -- the brute-force vector scan already touches every row and LIMIT
only changes the sort -- measured at +8 ms on the keyword arm and +22 ms
on the fused arm going from forty to two hundred.

This is a ceiling, not a promise: `arc-search--effective-pool' lowers it
for scopes where depth would change the query plan."
  :type 'integer :group 'arc)

(defcustom arc-search-limit 10
  "How many documents a search returns."
  :type 'integer :group 'arc)

(defun arc-search--effective-pool (scope)
  "Return the deepest pool for SCOPE that does not change its vector plan.

`arc-scope-vector-plan' asks vec0 for k = ceil(`arc-knn-candidates' *
total/n) on a scoped query, and correctly falls back to brute force when
that exceeds `arc-vec0-k-ceiling'.  Brute force is exact but costs
roughly 0.2 ms per row in scope, so a scope just above
`arc-scope-bruteforce-max' would flip from a fast KNN query at the
default pool to a ~400 ms brute-force one at a deep pool -- a large,
silent regression caused by nothing but asking for more candidates.

Search is allowed to be deep, or to change the plan, not both.  An
unscoped query and one already on the brute-force branch cannot flip, so
they take the full pool.  Anything else is clamped to the largest pool
whose k still fits under the ceiling, and never below
`arc-knn-candidates', which is the depth retrieval always had."
  (let ((want (max arc-search-pool arc-knn-candidates)))
    (if (or (arc-scope-empty-p scope)
            (eq (car (arc-scope-vector-plan scope)) 'brute))
        want
      (let ((n (arc-scope-count scope))
            (total (arc-scope-total)))
        (if (or (zerop n) (zerop total))
            want
          (max arc-knn-candidates
               (min want (floor (* arc-vec0-k-ceiling (/ (float n) total))))))))))

(defun arc-search--attach-sources (rows)
  "Turn (ID SCORE) ROWS into chunk plists carrying their source id.
The lookup is a primary-key IN-list and measures at under a millisecond
on a two-hundred row pool, which is why rollup gets its grouping key
from a second query rather than from a widened `arc--retrieve-rows'
row shape that four tested callers depend on."
  (when rows
    (let ((map (make-hash-table :test #'eql)))
      (dolist (r (sqlite-select
                  (arc-db)
                  (format "SELECT id, source_id FROM data WHERE id IN (%s);"
                          (mapconcat (lambda (row) (number-to-string (car row)))
                                     rows ","))))
        (puthash (nth 0 r) (nth 1 r) map))
      (delq nil
            (mapcar (lambda (r)
                      (when-let* ((sid (gethash (nth 0 r) map)))
                        (list :id (nth 0 r) :source-id sid :score (nth 1 r))))
                    rows)))))

(defun arc-search--hydrate (docs)
  "Fill DOCS' passages with chunk text and locator columns.
Reuses `arc--retrieve-rows' and `arc-row-to-source', so the org-link
citation invariant carries over unchanged rather than being
reimplemented here."
  (let* ((ids (delete-dups
               (mapcan (lambda (d)
                         (mapcar (lambda (p) (plist-get p :id))
                                 (plist-get d :passages)))
                       docs)))
         (rows (arc--retrieve-rows ids))
         (by-id (make-hash-table :test #'eql)))
    ;; `arc--retrieve-rows' dedups with `delete-dups' and preserves order,
    ;; so zipping against the same deduped id list is sound.
    (cl-loop for id in ids for row in rows
             do (puthash id (arc-row-to-source row) by-id))
    (delq nil
          (mapcar
           (lambda (d)
             (let* ((passages
                     (delq nil
                           (mapcar
                            (lambda (p)
                              (when-let* ((src (gethash (plist-get p :id) by-id)))
                                (list :chunk (plist-get src :chunk)
                                      :line-start (plist-get src :line-start)
                                      :line-end (plist-get src :line-end)
                                      :score (plist-get p :score))))
                            (plist-get d :passages))))
                    (src (gethash (plist-get (car (plist-get d :passages)) :id)
                                  by-id)))
               (when src
                 (list :source-id (plist-get d :source-id)
                       :kind (plist-get src :kind)
                       :path (plist-get src :path)
                       :title (plist-get src :title)
                       :org-id (plist-get src :org-id)
                       :option-name (plist-get src :option-name)
                       :info-node (plist-get src :info-node)
                       :score (plist-get d :score)
                       :chunk-count (plist-get d :chunk-count)
                       :best-rank (plist-get d :best-rank)
                       :passages passages))))
           docs))))

(defun arc-search-documents (query &optional scope arm)
  "Search for QUERY in SCOPE, returning at most `arc-search-limit' documents.

SCOPE takes any shape `arc-ask-normalize-scope' accepts; nil means
`arc-enabled-collections'.  ARM is passed through to
`arc--find-similar': `keyword' skips the embedding call entirely and is
what the live-typing stage uses, nil or `fused' is the full hybrid.

`arc-reranker-enabled' is bound off for the duration.  The reranker's
limit would otherwise truncate the pool through `arc-get-limit' before
rollup ever sees it, and the reranker is out of scope for search -- the
seam stays exactly as it is for `arc-ask'."
  (let* ((scope (arc-ask-normalize-scope scope))
         (pool (arc-search--effective-pool scope))
         (arc-reranker-enabled nil)
         (arc-knn-candidates pool)
         (arc-limit pool)
         (rows (sqlite-select (arc-db) (arc--find-similar query scope arm t))))
    (take arc-search-limit
          (arc-search--hydrate (arc-rollup (arc-search--attach-sources rows))))))

(provide 'arc-search)
;;; arc-search.el ends here
```

- [ ] **Step 4: Run the tests**

Run: `emacs -Q -batch -L . -l test/test-arc-search-core.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 8 tests.

- [ ] **Step 5: Run the full suite**

Run: `test/run.sh`
Expected: exit 0.

- [ ] **Step 6: Sanity-check against the real index**

Run:

```bash
emacsclient -e '(length (arc-search-documents "org capture template" (quote (:all t))))'
```

Expected: `10`. If the daemon has not loaded the new file, `M-x eval-buffer` in `arc-search.el` first. This is a smoke check against a real 63k-chunk corpus, not a test — nothing depends on its output.

- [ ] **Step 7: Commit**

```bash
git add arc-search.el test/test-arc-search-core.el
git commit -m "feat(search): rank documents, and refuse to change the plan to do it

Deepening the candidate pool is what makes document rollup possible --
ten chunks cannot yield ten documents, and a 200-chunk pool yields about
130 distinct sources where a 40-chunk one often yields under ten. Depth
costs +8ms keyword and +22ms fused, because the brute-force scan already
touches every row and LIMIT only changes the sort.

It is not free in every scope, though, and that is what the clamp is
for. arc-scope-vector-plan asks vec0 for k = ceil(candidates * total/n)
and falls back to brute force past arc-vec0-k-ceiling. Multiplying
candidates by five pushes a scope between bruteforce-max and ~3100
chunks over that line, turning a fast KNN query into a ~400ms
brute-force one for no reason but asking for more candidates. None of
the four current presets land in that band -- measured, all stay knn,
worst case 120ms to 176ms -- but a :path-prefix scope could. Search may
be deep or may change the plan, not both.

Source ids come from a second primary-key lookup rather than a widened
arc--retrieve-rows shape: the lookup is under a millisecond, and four
tested callers depend on that shape."
```

---

### Task 4: Measure the rollup default

`max` shipped as a placeholder in Task 2. This task replaces it with whatever the eval set says, and records what lost. The eval set needs no new ground truth: its `:expect` clauses already match on `:kind`, `:option-name` and `:path-suffix` — source identity, not chunk identity — so they already describe exactly what rollup must produce.

**Files:**
- Modify: `arc-eval.el`
- Modify: `arc-rollup.el` (the default, at the end of this task)
- Create: `docs/design/2026-09-13-rollup-measurement.md`
- Test: `test/test-arc-eval-doc.el` (create)

**Interfaces:**
- Consumes: `arc-search-documents` (Task 3); `arc-rollup-function` (Task 2); existing `arc-eval-read-set`, `arc-eval-set-file`, `arc-eval-k`.
- Produces:
  - `(arc-eval-document-recall SET K &optional ARM)` → float in [0,1].
  - `(arc-eval-rollup-sweep)` — interactive; renders a comparison into `*arc-eval*`.

- [ ] **Step 1: Read how the existing harness matches an expectation**

Run: `grep -n "defun arc-eval" arc-eval.el`

Read `arc-eval-read-set` and whichever function decides an `:expect` clause is satisfied. Reuse that matcher — do not write a second one. Note its exact name before continuing; Step 3 calls it `arc-eval--expect-matches-p` and you must substitute the real name if it differs.

- [ ] **Step 2: Write the failing test**

Create `test/test-arc-eval-doc.el`:

```elisp
;;; test-arc-eval-doc.el --- document-level recall -*- lexical-binding: t; -*-
;;
;; The eval set already expresses document-level ground truth: :expect
;; clauses match :kind, :option-name and :path-suffix, which are source
;; identity, not chunk identity.  Document recall therefore needs no new
;; question set, only a scorer that reads arc-search-documents' output.
(require 'ert)
(defvar aed-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aed-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-eval)
(require 'arc-search)
(require 'arc-test-helpers)

(ert-deftest aed-recall-is-one-when-the-expected-document-is-found ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/syncthing.nix"
      :chunks ((:text "services syncthing enable" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (set '((:question "syncthing"
                  :scope (:all t)
                  :expect ((:kind "file" :path-suffix "syncthing.nix"))))))
     (should (= (arc-eval-document-recall set 5 'keyword) 1.0)))))

(ert-deftest aed-recall-is-zero-when-it-is-not ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/other.nix"
      :chunks ((:text "something unrelated" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (set '((:question "syncthing"
                  :scope (:all t)
                  :expect ((:kind "file" :path-suffix "syncthing.nix"))))))
     (should (= (arc-eval-document-recall set 5 'keyword) 0.0)))))

(provide 'test-arc-eval-doc)
;;; test-arc-eval-doc.el ends here
```

- [ ] **Step 3: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-eval-doc.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `arc-eval-document-recall` is void.

- [ ] **Step 4: Add document recall to `arc-eval.el`**

Add `(require 'arc-search)` to the file's requires. Then:

```elisp
(defun arc-eval-document-recall (set k &optional arm)
  "Fraction of SET's questions whose expected source is in the top K documents.

The chunk-level scorer asks whether an expected source appears among k
retrieved chunks; this asks whether it appears among k retrieved
documents, which is what a reader of search results actually sees.  The
question set needs no change to support it: an `:expect' clause already
names source identity -- `:kind', `:option-name', `:path-suffix' -- and
never a chunk."
  (let ((hits 0) (n 0))
    (dolist (q set)
      (setq n (1+ n))
      (let* ((arc-search-limit k)
             (docs (arc-search-documents (plist-get q :question)
                                         (plist-get q :scope)
                                         arm)))
        (when (cl-some
               (lambda (expect)
                 (cl-some (lambda (doc) (arc-eval--expect-matches-p expect doc))
                          docs))
               (plist-get q :expect))
          (setq hits (1+ hits)))))
    (if (zerop n) 0.0 (/ (float hits) n))))

(defun arc-eval-rollup-sweep ()
  "Report document recall for every `arc-rollup-function', at every `arc-eval-k'.
This is what chooses the default.  Three hand-tuned retrieval
interventions have already lost to BM25's own weighting in this package;
the aggregation gets measured rather than argued about."
  (interactive)
  (let ((set (arc-eval-read-set arc-eval-set-file)))
    (with-current-buffer (get-buffer-create arc-eval-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "arc rollup sweep -- %d questions\n\n" (length set)))
        (insert (format "%-10s %s\n" "function"
                        (mapconcat (lambda (k) (format "recall@%-4d" k))
                                   arc-eval-k " ")))
        (dolist (fn '(max top-n sum))
          (let ((arc-rollup-function fn))
            (insert (format "%-10s %s\n" fn
                            (mapconcat
                             (lambda (k)
                               (format "%-11.2f"
                                       (arc-eval-document-recall set k)))
                             arc-eval-k " ")))))
        (goto-char (point-min))))
    (display-buffer arc-eval-buffer-name)))
```

If Step 1 found the matcher under a different name, substitute it in `arc-eval-document-recall`. If the existing matcher takes a *source plist* built by `arc-row-to-source`, note that a document plist carries the same `:kind`, `:path`, `:org-id`, `:option-name` and `:info-node` keys by construction, so it is already compatible; if it takes a raw row, write a one-line adapter rather than changing the matcher.

- [ ] **Step 5: Run the tests**

Run: `emacs -Q -batch -L . -l test/test-arc-eval-doc.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 2 tests.

- [ ] **Step 6: Run the sweep against the real index**

This needs the real eval set and a warm index, so run it in the daemon, not batch:

```bash
emacsclient -e '(progn (require (quote arc-eval)) (arc-eval-rollup-sweep) (with-current-buffer "*arc-eval*" (buffer-string)))'
```

Record the actual table. Do not proceed on a guess — if the eval set is missing, `arc-eval-read-set` signals a `user-error`, and the correct response is to stop and report that, not to invent numbers.

- [ ] **Step 7: Set the default to the winner**

Edit `arc-rollup.el`'s `arc-rollup-function` defcustom: change `'max` to whichever function won at k=10, breaking a tie at k=10 with k=5. Replace the docstring's closing paragraph — the one beginning "The default is provisional" — with the measured result, naming the numbers.

If `max` wins, say so explicitly rather than silently leaving it; a measured `max` and a placeholder `max` are different claims.

- [ ] **Step 8: Write down what lost**

Create `docs/design/2026-09-13-rollup-measurement.md`, following the house style of recording rejections so they are not re-litigated:

```markdown
# Rollup aggregation, measured

`arc-rollup-function` chooses how a document's score is aggregated from its
chunks'. Three candidates were swept against the eval set with
`arc-eval-rollup-sweep`, at the cutoffs in `arc-eval-k`.

| function | recall@5 | recall@10 |
|---|---:|---:|
| max | | |
| top-n (n=3) | | |
| sum | | |

**Adopted:** <winner>, on <reason from the numbers>.

**Rejected:** <the others, with their numbers>.

`sum` was expected to lose before the sweep ran, and the prediction is worth
recording alongside the result. arc's corpus is two shapes in one schema: nix
options and Info nodes are one chunk per document, vault notes and dotfiles are
24 to 46. Summing every chunk rewards a document for being long, so a 39-chunk
note outranks a 1-chunk option on structure alone, regardless of relevance.
```

Fill the table from Step 6's real output and complete the adopted/rejected lines. Leave no blank cells.

- [ ] **Step 9: Full suite, then commit**

Run: `test/run.sh`
Expected: exit 0.

```bash
git add arc-eval.el arc-rollup.el test/test-arc-eval-doc.el docs/design/2026-09-13-rollup-measurement.md
git commit -m "feat(eval): measure document recall, and let it pick the default

The rollup default shipped as max with a docstring admitting it was a
placeholder. This replaces the placeholder with the sweep.

The eval set needed no change to support it. An :expect clause already
matches :kind, :option-name and :path-suffix -- source identity, never a
chunk -- so the existing questions already describe what rollup has to
produce, and document recall is a different scorer over the same ground
truth rather than a second question set to maintain.

What lost is recorded in docs/design/2026-09-13-rollup-measurement.md,
including the prediction that sum would lose and why: summing rewards a
document for being long, and this corpus mixes 1-chunk options with
39-chunk notes."
```

---

### Task 5: Results buffer

The escape hatch: somewhere to stand when reading beats jumping.

**Files:**
- Create: `arc-search-ui.el`
- Test: `test/test-arc-search-ui.el` (create)

**Interfaces:**
- Consumes: `arc-search-documents` (Task 3); existing `arc-source-link`, `arc-source-label` from `arc-source.el`.
- Produces:
  - `arc-search-results-buffer-name` — defconst, `"*arc-search*"`.
  - `arc-results-mode` — major mode deriving from `special-mode`.
  - `(arc-search-render DOCS QUERY SCOPE)` → the results buffer, rendered.
  - `(arc-search-show QUERY &optional SCOPE)` — interactive; search then render.

- [ ] **Step 1: Check the source-link helpers before writing against them**

Run: `grep -n "defun arc-source-link\|defun arc-source-label" arc-source.el`

Read both. They take the source plist shape `arc-row-to-source` produces, which a document plist matches key-for-key by construction (Task 3 copies `:kind`, `:path`, `:title`, `:org-id`, `:option-name`, `:info-node` straight across). Confirm that before relying on it; if a helper needs `:chunk` or `:line-start`, pass the document's first passage merged in rather than changing the helper.

- [ ] **Step 2: Write the failing test**

Create `test/test-arc-search-ui.el`:

```elisp
;;; test-arc-search-ui.el --- the results buffer -*- lexical-binding: t; -*-
(require 'ert)
(defvar asu-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asu-root)
(require 'arc-search-ui)

(defvar asu--docs
  '((:source-id 1 :kind "file" :path "/tmp/a.nix" :title "a.nix"
     :org-id nil :option-name nil :info-node nil
     :score 0.5 :chunk-count 3 :best-rank 0
     :passages ((:chunk "alpha one" :line-start 1 :line-end 1 :score 0.5)
                (:chunk "alpha two" :line-start 9 :line-end 9 :score 0.4)))
    (:source-id 2 :kind "file" :path "/tmp/b.nix" :title "b.nix"
     :org-id nil :option-name nil :info-node nil
     :score 0.2 :chunk-count 1 :best-rank 5
     :passages ((:chunk "alpha three" :line-start 4 :line-end 4 :score 0.2))))
  "Two documents in the shape `arc-search-documents' returns.")

(ert-deftest asu-render-lists-every-document ()
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "a\\.nix" (buffer-string)))
    (should (string-match-p "b\\.nix" (buffer-string)))))

(ert-deftest asu-render-shows-the-query-and-the-count ()
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "alpha" (buffer-string)))
    (should (string-match-p "2 document" (buffer-string)))))

(ert-deftest asu-render-shows-chunk-counts ()
  "A document that matched three times must say so -- that signal is the
reason rollup exists, and hiding it in the ranking alone wastes it."
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "3 match" (buffer-string)))))

(ert-deftest asu-render-is-read-only-and-in-results-mode ()
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (eq major-mode 'arc-results-mode))
    (should buffer-read-only)))

(ert-deftest asu-render-of-nothing-says-so ()
  (arc-search-render nil "zzz" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "No documents" (buffer-string)))))

(ert-deftest asu-every-document-line-carries-its-plist ()
  "RET and TAB read the document off the line's text property."
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (goto-char (point-min))
    (should (re-search-forward "a\\.nix" nil t))
    (should (plist-get (get-text-property (point) 'arc-document) :source-id))))

(provide 'test-arc-search-ui)
;;; test-arc-search-ui.el ends here
```

- [ ] **Step 3: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-search-ui.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: arc-search-ui`.

- [ ] **Step 4: Write the results buffer half of `arc-search-ui.el`**

Task 6 adds the consult source to this same file. Write only the buffer now.

```elisp
;;; arc-search-ui.el --- search surfaces for arc -*- lexical-binding: t; -*-

;;; Commentary:

;; Two surfaces onto `arc-search-documents', because the two speeds
;; retrieval offers deserve different rooms.  The minibuffer source
;; (below, and only when consult is installed) is for the 46 ms keyword
;; arm: type, narrow, jump.  The results buffer is for the 150 ms hybrid:
;; somewhere to stand and read, with every passage reachable.
;;
;; consult is an optional dependency.  Everything in this file that does
;; not mention consult works without it.

;;; Code:

(require 'arc-search)
(require 'arc-source)

(defconst arc-search-results-buffer-name "*arc-search*"
  "Buffer `arc-search-render' renders into.")

(defvar-local arc-search--query nil
  "The query this results buffer last rendered.")

(defvar-local arc-search--scope nil
  "The scope this results buffer last rendered.")

(defvar arc-results-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'arc-search-visit)
    (define-key map (kbd "TAB") #'arc-search-toggle-passages)
    (define-key map (kbd "g") #'arc-search-refresh)
    (define-key map (kbd "s") #'arc-search-change-scope)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    map)
  "Keymap for `arc-results-mode'.")

(define-derived-mode arc-results-mode special-mode "arc-search"
  "Major mode for arc search results.
Each document line carries its plist on the `arc-document' text
property; every command here reads that rather than re-parsing the
buffer."
  (setq truncate-lines t))

(defun arc-search--document-at-point ()
  "Return the document plist at point, or signal."
  (or (get-text-property (point) 'arc-document)
      (user-error "arc-search: no document on this line")))

(defun arc-search--insert-document (doc)
  "Insert one line for DOC, plus its passages, propertised with DOC."
  (let ((start (point))
        (label (arc-source-label doc)))
    (insert (format "%s  %s\n"
                    label
                    (if (> (plist-get doc :chunk-count) 1)
                        (format "(%d matches)" (plist-get doc :chunk-count))
                      "(1 match)")))
    (dolist (p (plist-get doc :passages))
      (insert (format "    %s:%s  %s\n"
                      (or (plist-get doc :path) "")
                      (or (plist-get p :line-start) "")
                      (string-trim
                       (replace-regexp-in-string
                        "[ \t\n]+" " " (or (plist-get p :chunk) ""))))))
    (insert "\n")
    (put-text-property start (point) 'arc-document doc)))

(defun arc-search-render (docs query scope)
  "Render DOCS, found for QUERY in SCOPE, into the results buffer."
  (with-current-buffer (get-buffer-create arc-search-results-buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (arc-results-mode)
      (setq arc-search--query query
            arc-search--scope scope)
      (insert (format "arc search: %s\n%d document%s  ·  %s\n\n"
                      query
                      (length docs)
                      (if (= (length docs) 1) "" "s")
                      (arc-scope-describe scope)))
      (if (null docs)
          (insert "No documents matched.\n")
        (dolist (doc docs) (arc-search--insert-document doc)))
      (goto-char (point-min)))
    (current-buffer)))

;;;###autoload
(defun arc-search-show (query &optional scope)
  "Search for QUERY in SCOPE and show the results buffer."
  (interactive "sarc search: ")
  (let ((scope (arc-ask-normalize-scope scope)))
    (arc-search-render (arc-search-documents query scope) query scope)
    (display-buffer arc-search-results-buffer-name)))

(defun arc-search-visit ()
  "Visit the document at point."
  (interactive)
  (let ((doc (arc-search--document-at-point)))
    (org-link-open-from-string (arc-source-link doc))))

(defun arc-search-toggle-passages ()
  "Expand the document at point to all of its matching chunks."
  (interactive)
  (let* ((doc (arc-search--document-at-point))
         (arc-rollup-passages most-positive-fixnum)
         (full (cl-find (plist-get doc :source-id)
                        (arc-search-documents arc-search--query
                                              arc-search--scope)
                        :key (lambda (d) (plist-get d :source-id)))))
    (when full
      (arc-search-render
       (mapcar (lambda (d)
                 (if (equal (plist-get d :source-id) (plist-get full :source-id))
                     full d))
               (list full))
       arc-search--query arc-search--scope))))

(defun arc-search-refresh ()
  "Re-run this buffer's query."
  (interactive)
  (unless arc-search--query (user-error "arc-search: nothing to refresh"))
  (arc-search-show arc-search--query arc-search--scope))

(defun arc-search-change-scope ()
  "Re-run this buffer's query at a scope chosen from `arc-scope-presets'."
  (interactive)
  (unless arc-search--query (user-error "arc-search: nothing to re-scope"))
  (let* ((name (completing-read "scope: " (mapcar #'car arc-scope-presets) nil t))
         (scope (alist-get name arc-scope-presets nil nil #'equal)))
    (arc-search-show arc-search--query scope)))

(provide 'arc-search-ui)
;;; arc-search-ui.el ends here
```

Add `(require 'cl-lib)` at the top if the byte-compile gate flags `cl-find`.

- [ ] **Step 5: Run the tests**

Run: `emacs -Q -batch -L . -l test/test-arc-search-ui.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 6 tests.

- [ ] **Step 6: Full suite**

Run: `test/run.sh`
Expected: exit 0. Watch the byte-compile gate for undefined-function warnings from `arc-source-label` / `arc-source-link` / `org-link-open-from-string` — add the matching `require` if any appear.

- [ ] **Step 7: Commit**

```bash
git add arc-search-ui.el test/test-arc-search-ui.el
git commit -m "feat(search): a results buffer to stand in

The minibuffer is the right room for a 46ms keyword query and the wrong
one for reading: one preview at a time, and it dies on exit. This is the
other room -- documents with their passages, TAB to expand one to every
chunk it matched, g to re-run, s to re-scope.

Match counts are on the line rather than implied by the ranking. A
document that matched in three places is the signal rollup exists to
recover, and spending it only on sort order wastes it.

Every line carries its document plist on a text property, so the
commands read the document instead of re-parsing the buffer."
```

---

### Task 6: Consult source, two-stage

> Superseded by Ruling T6-E: the `sit-for`/`arc-search-hybrid-delay` mechanism
> below was replaced by `arc-search--two-stage`, which lets consult's own
> `consult-async-input-debounce` govern timing instead. Left as written below
> for the historical record; do not implement against this section.

**Files:**
- Modify: `arc-search-ui.el`
- Test: `test/test-arc-search-consult.el` (create)

**Interfaces:**
- Consumes: `arc-search-documents`, `arc-search-render` (Tasks 3, 5).
- Produces:
  - `arc-search-hybrid-delay` — defcustom float, default 0.3.
  - `(arc-search--candidates QUERY SCOPE ARM)` → list of propertised strings, each carrying `arc-document`.
  - `arc-search` — interactive command, defined only when consult is present.

- [ ] **Step 1: Write the failing test**

The candidate builder is testable without consult; the command is not, so test the builder and assert the guard.

Create `test/test-arc-search-consult.el`:

```elisp
;;; test-arc-search-consult.el --- the minibuffer source -*- lexical-binding: t; -*-
;;
;; consult is an optional dependency: arc must load and pass without it.
;; These tests therefore exercise the candidate builder, which is plain
;; elisp, and assert the command is guarded rather than unconditional.
(require 'ert)
(defvar asx-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asx-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-search-ui)
(require 'arc-test-helpers)

(ert-deftest asx-candidates-carry-their-document ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (cands (arc-search--candidates "alpha" '(:all t) 'keyword)))
     (should (= (length cands) 1))
     (should (stringp (car cands)))
     (should (plist-get (get-text-property 0 'arc-document (car cands))
                        :source-id)))))

(ert-deftest asx-candidates-of-an-empty-query-are-nil ()
  "Consult calls the source on every keystroke, including the first
empty one.  That must not become a full-corpus query."
  (arc-test-with-temp-db
   (should (null (arc-search--candidates "" '(:all t) 'keyword)))
   (should (null (arc-search--candidates "   " '(:all t) 'keyword)))))

(ert-deftest asx-candidates-survive-a-dead-embedding-endpoint ()
  "Stage two must fail soft: an unreachable Ollama returns the keyword
results, not an error thrown out of the minibuffer."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (cl-letf (((symbol-function 'llm-embedding)
              (lambda (&rest _) (error "connection refused"))))
     (let ((arc-rollup-function 'max))
       (should (= (length (arc-search--candidates "alpha" '(:all t) nil)) 1))))))

(ert-deftest asx-command-is-guarded-on-consult ()
  (should (eq (fboundp 'arc-search) (featurep 'consult))))

(provide 'test-arc-search-consult)
;;; test-arc-search-consult.el ends here
```

- [ ] **Step 2: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-search-consult.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `arc-search--candidates` is void.

- [ ] **Step 3: Add the candidate builder and the guarded command**

Append to `arc-search-ui.el`, before the `provide`:

```elisp
(defcustom arc-search-hybrid-delay 0.3
  "Idle seconds before search upgrades from the keyword arm to the hybrid.

The keyword arm runs in 4-63 ms because it skips the embedding call
entirely; the hybrid runs in 118-181 ms because it does not.  The first
is fast enough to run on every keystroke, the second is not, and the
only thing separating them is a pause."
  :type 'number :group 'arc)

(defun arc-search--annotate (doc)
  "Return the annotation suffix for DOC."
  (format "  %s%s"
          (if (> (plist-get doc :chunk-count) 1)
              (format "%d matches" (plist-get doc :chunk-count))
            "1 match")
          (if (plist-get doc :kind)
              (format " · %s" (plist-get doc :kind))
            "")))

(defun arc-search--candidates (query scope arm)
  "Return propertised candidate strings for QUERY in SCOPE using ARM.

Returns nil for a blank QUERY: consult calls a dynamic source on every
keystroke including the first empty one, and that must not become a
full-corpus query.

Never signals.  A failure here is most often an unreachable embedding
endpoint on the hybrid arm, and the correct response is to fall back to
the keyword arm rather than throw the user out of the minibuffer."
  (if (string-empty-p (string-trim (or query "")))
      nil
    (let ((docs (condition-case _
                    (arc-search-documents query scope arm)
                  (error
                   (unless (eq arm 'keyword)
                     (condition-case _
                         (arc-search-documents query scope 'keyword)
                       (error nil)))))))
      (mapcar (lambda (doc)
                (propertize (concat (arc-source-label doc)
                                    (arc-search--annotate doc))
                            'arc-document doc))
              docs))))

(when (require 'consult nil t)

  (defvar arc-search--scope nil)          ; shadowed dynamically by `arc-search'

  (defun arc-search--consult-lookup (selected candidates &rest _)
    "Return the document plist behind SELECTED among CANDIDATES."
    (when-let* ((match (car (member selected candidates))))
      (get-text-property 0 'arc-document match)))

  ;;;###autoload
  (defun arc-search (&optional scope)
    "Search arc's documents from the minibuffer.

Types on the keyword arm, which needs no embedding call and returns in
tens of milliseconds; upgrades to the full hybrid after
`arc-search-hybrid-delay' seconds of idle.  \\<minibuffer-local-map>
\\[exit-minibuffer] visits the document, \\[arc-search-to-buffer] sends
the whole result set to the results buffer."
    (interactive)
    (let* ((scope (arc-ask-normalize-scope scope))
           (doc (consult--read
                 (consult--dynamic-collection
                  (lambda (input)
                    (arc-search--candidates
                     input scope
                     (if (sit-for arc-search-hybrid-delay) nil 'keyword))))
                 :prompt "arc search: "
                 :lookup #'arc-search--consult-lookup
                 :sort nil
                 :require-match t
                 :category 'arc-document
                 :annotate (lambda (_) nil))))
      (when doc
        (org-link-open-from-string (arc-source-link doc))))))
```

Note the arm selection: `sit-for` returns non-nil when the delay elapsed without input, which is exactly "the user stopped typing", so that branch takes the hybrid and a still-typing user takes the keyword arm. If consult's version in use does not provide `consult--dynamic-collection`, check with `M-x describe-function`; older versions call it `consult--dynamic-candidates`, and the argument shape is the same.

- [ ] **Step 4: Run the tests**

Run: `emacs -Q -batch -L . -l test/test-arc-search-consult.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 4 tests. `asx-command-is-guarded-on-consult` passes in both directions — with consult absent in batch it asserts `arc-search` is *not* defined.

- [ ] **Step 5: Full suite**

Run: `test/run.sh`
Expected: exit 0. The byte-compile gate runs without consult, so `consult--read` and `consult--dynamic-collection` will be flagged as undefined unless the `when` guard wraps them — which it does. If warnings appear anyway, add `(declare-function consult--read "consult")` and the matching line for `consult--dynamic-collection`.

- [ ] **Step 6: Try it in the daemon**

```bash
emacsclient -e '(progn (load "arc-search-ui.el") (fboundp (quote arc-search)))'
```

Expected: `t`, since the daemon has consult. Then run `M-x arc-search` interactively and confirm results appear while typing and sharpen after a pause.

- [ ] **Step 7: Commit**

```bash
git add arc-search-ui.el test/test-arc-search-consult.el
git commit -m "feat(search): type on BM25, settle into the hybrid

Measured, the two arms are 4-63ms and 118-181ms, and the only thing
separating them is the embedding call. That is the whole design: run the
keyword arm on every keystroke, upgrade to the hybrid once the typing
stops. The arm argument that makes it possible already existed, built
for eval attribution.

Stage two fails soft. An unreachable embedding endpoint falls back to
the keyword results instead of throwing the user out of the minibuffer,
which is asserted rather than hoped for.

A blank query returns nil rather than searching the whole corpus --
consult calls a dynamic source on the first empty keystroke too.

consult stays optional: the command is defined only if it is present,
and the suite asserts that in both directions."
```

---

### Task 7: JSON verbs

**Files:**
- Create: `arc-tool.el`
- Test: `test/test-arc-tool.el` (create)

**Interfaces:**
- Consumes: `arc-search-documents` (Task 3); existing `arc-scope-presets`, `arc-index-stats`, `arc-freshness-report`.
- Produces:
  - `(arc-tool-search QUERY &optional SCOPE-NAME LIMIT ARM)` → JSON string.
  - `(arc-tool-scopes)` → JSON string.
  - `(arc-tool-stats)` → JSON string.

- [ ] **Step 1: Confirm the freshness report's row shape**

Run: `sed -n '/defun arc-freshness-report/,/^$/p' arc-index.el | head -40`

`arc-freshness-summary` reads `(nth 2 r)` as a state symbol of `stale` / `unknown` / `absent`, so a row is at least three elements. Note what `(nth 0 r)` and `(nth 1 r)` actually are before writing Step 3 against them.

- [ ] **Step 2: Write the failing test**

Create `test/test-arc-tool.el`:

```elisp
;;; test-arc-tool.el --- the agent-facing JSON verbs -*- lexical-binding: t; -*-
;;
;; These verbs are an interface something outside Emacs depends on, so the
;; shape is asserted, not assumed: an agent that cannot parse the output
;; has no other way to find out.
(require 'ert)
(require 'json)
(defvar att-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path att-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-tool)
(require 'arc-test-helpers)

(defun att--parse (s)
  (let ((json-object-type 'alist) (json-array-type 'list))
    (json-read-from-string s)))

(ert-deftest att-search-returns-parseable-json-with-results ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (out (att--parse (arc-tool-search "alpha" "everything" 10 'keyword)))
          (results (alist-get 'results out)))
     (should (equal (alist-get 'query out) "alpha"))
     (should (= (length results) 1))
     (let ((r (car results)))
       (should (equal (alist-get 'path r) "/tmp/a.txt"))
       (should (numberp (alist-get 'score r)))
       (should (= (alist-get 'chunks r) 1))
       (should (stringp (alist-get 'text (car (alist-get 'passages r)))))))))

(ert-deftest att-search-with-no-match-returns-an-empty-array ()
  "An empty result must serialise as [] and not as null -- a consumer
that has to distinguish them will get it wrong otherwise."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha" :line-start 1 :line-end 1)))
    "test")
   (let ((out (arc-tool-search "zzzznomatch" "everything" 10 'keyword)))
     (should (string-match-p "\"results\":\\[\\]" out))
     (should (null (alist-get 'results (att--parse out)))))))

(ert-deftest att-search-rejects-an-unknown-scope-by-name ()
  (arc-test-with-temp-db
   (should-error (arc-tool-search "alpha" "nosuchscope" 10 'keyword))))

(ert-deftest att-scopes-lists-every-preset ()
  (let* ((out (att--parse (arc-tool-scopes)))
         (names (mapcar (lambda (s) (alist-get 'name s))
                        (alist-get 'scopes out))))
    (should (member "everything" names))
    (should (member "vault" names))))

(ert-deftest att-stats-reports-collections-and-freshness ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha" :line-start 1 :line-end 1)))
    "test")
   (let ((out (att--parse (arc-tool-stats))))
     (should (assq 'kinds out))
     (should (assq 'freshness out)))))

(provide 'test-arc-tool)
;;; test-arc-tool.el ends here
```

- [ ] **Step 3: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-tool.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: arc-tool`.

- [ ] **Step 4: Write `arc-tool.el`**

```elisp
;;; arc-tool.el --- arc's agent-facing verbs -*- lexical-binding: t; -*-

;;; Commentary:

;; Three verbs for a caller outside Emacs: search, scopes, stats.
;;
;; There is deliberately no `ask'.  When an external agent calls arc,
;; that agent is already a language model; routing it through a local 3B
;; one would put a weaker reasoner between it and the documents and throw
;; away the retrieval fidelity this whole surface exists to expose.
;; `arc-ask' remains an Emacs-side command.
;;
;; `scopes' and `stats' exist because a caller cannot see the screen.
;; Without enumeration it guesses collection names or defaults to
;; searching everything on every call; without freshness it quotes a
;; stale chunk as current configuration, which is a correctness bug
;; rather than a cosmetic one.

;;; Code:

(require 'arc-search)
(require 'arc-index)
(require 'arc-scope)

(defun arc-tool--scope (name)
  "Return the scope plist NAME names in `arc-scope-presets', or signal."
  (if (or (null name) (string-empty-p name))
      (arc-ask-normalize-scope nil)
    (or (alist-get name arc-scope-presets nil nil #'equal)
        (error "arc: unknown scope %S (try: %s)" name
               (string-join (mapcar #'car arc-scope-presets) ", ")))))

(defun arc-tool--document-json (doc)
  "Return DOC as a JSON-serialisable plist."
  (list :path (or (plist-get doc :path) :null)
        :kind (or (plist-get doc :kind) :null)
        :title (or (plist-get doc :title) :null)
        :option_name (or (plist-get doc :option-name) :null)
        :info_node (or (plist-get doc :info-node) :null)
        :org_id (or (plist-get doc :org-id) :null)
        :score (plist-get doc :score)
        :chunks (plist-get doc :chunk-count)
        :passages
        (vconcat
         (mapcar (lambda (p)
                   (list :text (or (plist-get p :chunk) "")
                         :line_start (or (plist-get p :line-start) :null)
                         :line_end (or (plist-get p :line-end) :null)))
                 (plist-get doc :passages)))))

(defun arc-tool-search (query &optional scope-name limit arm)
  "Search for QUERY and return the results as a JSON string.
SCOPE-NAME names an entry in `arc-scope-presets'.  LIMIT overrides
`arc-search-limit'.  ARM is passed through to `arc-search-documents'."
  (let* ((scope (arc-tool--scope scope-name))
         (arc-search-limit (or limit arc-search-limit))
         (start (float-time))
         (docs (arc-search-documents query scope arm)))
    (json-serialize
     (list :query query
           :scope (or scope-name "default")
           :arm (symbol-name (or arm 'fused))
           :elapsed_ms (round (* 1000 (- (float-time) start)))
           :count (length docs)
           :results (vconcat (mapcar #'arc-tool--document-json docs))))))

(defun arc-tool-scopes ()
  "Return the available scopes, with their sizes, as a JSON string."
  (json-serialize
   (list :scopes
         (vconcat
          (mapcar (lambda (preset)
                    (list :name (car preset)
                          :chunks (arc-scope-count (cdr preset))
                          :describe (arc-scope-describe (cdr preset))))
                  arc-scope-presets)))))

(defun arc-tool-stats ()
  "Return corpus size and freshness as a JSON string.
Freshness is here so a caller can tell a current answer from a stale
one before quoting it as configuration."
  (json-serialize
   (list :chunks (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))
         :sources (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))
         :kinds (vconcat
                 (mapcar (lambda (kv)
                           (list :kind (car kv) :chunks (cdr kv)))
                         (arc-index-stats)))
         :freshness (vconcat
                     (mapcar (lambda (r)
                               (list :collection (format "%s" (nth 0 r))
                                     :detail (format "%s" (nth 1 r))
                                     :state (format "%s" (nth 2 r))))
                             (arc-freshness-report))))))

(provide 'arc-tool)
;;; arc-tool.el ends here
```

If Step 1 showed `arc-freshness-report` rows are ordered differently, fix the `nth` indices here to match; the `:state` field must be the symbol `arc-freshness-summary` counts.

- [ ] **Step 5: Run the tests**

Run: `emacs -Q -batch -L . -l test/test-arc-tool.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 5 tests.

- [ ] **Step 6: Full suite**

Run: `test/run.sh`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add arc-tool.el test/test-arc-tool.el
git commit -m "feat(tool): three verbs for a caller that cannot see the screen

search, scopes, stats. No ask: a calling agent is already a language
model, and routing it through a local 3B one would insert a weaker
reasoner between it and the documents. arc-ask stays an Emacs command.

scopes and stats are not padding. Without enumeration a caller guesses
collection names or searches everything on every call; without freshness
it quotes a stale chunk as current configuration, which is a correctness
bug and not a cosmetic one.

Empty results serialise as [] rather than null, asserted directly -- a
consumer that has to tell those apart will get it wrong otherwise."
```

---

### Task 8: The shim and the skill

**Files:**
- Create: `bin/arc`
- Create: `$HOME/.claude/skills/arc/SKILL.md` (outside the repo — it describes one installation, not the package)
- Modify: `README.org`
- Test: `test/test-arc-shim.el` (create)

**Interfaces:**
- Consumes: `arc-tool-search`, `arc-tool-scopes`, `arc-tool-stats` (Task 7).
- Produces: `bin/arc` with subcommands `search`, `scopes`, `stats`; exit `0` success, `1` error, `2` daemon unreachable.

- [ ] **Step 1: Write the failing test**

The shim is shell, so test what is testable in ERT — that it exists, is executable, and handles a dead daemon — and leave the rest to Step 5's manual run.

Create `test/test-arc-shim.el`:

```elisp
;;; test-arc-shim.el --- the CLI shim -*- lexical-binding: t; -*-
(require 'ert)
(defvar ash-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))

(defvar ash-shim (expand-file-name "bin/arc" ash-root))

(ert-deftest ash-shim-exists-and-is-executable ()
  (should (file-exists-p ash-shim))
  (should (file-executable-p ash-shim)))

(ert-deftest ash-shim-reports-a-dead-daemon-as-exit-2 ()
  "The one failure mode the Emacs-only design never had, made legible."
  (let* ((out (with-temp-buffer
                (list (call-process ash-shim nil t nil "stats")
                      (buffer-string))))
         (status (nth 0 out))
         (text (nth 1 out)))
    ;; With a live daemon this is 0; without one it must be 2 and say so.
    (should (memq status '(0 2)))
    (when (= status 2)
      (should (string-match-p "daemon not running" text)))))

(ert-deftest ash-shim-rejects-an-unknown-subcommand ()
  (with-temp-buffer
    (should (= (call-process ash-shim nil t nil "frobnicate") 1))))

(ert-deftest ash-shim-with-no-arguments-prints-usage ()
  (with-temp-buffer
    (let ((status (call-process ash-shim nil t nil)))
      (should (= status 1))
      (should (string-match-p "usage" (downcase (buffer-string)))))))

(provide 'test-arc-shim)
;;; test-arc-shim.el ends here
```

- [ ] **Step 2: Run it and watch it fail**

Run: `emacs -Q -batch -L . -l test/test-arc-shim.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `bin/arc` does not exist.

- [ ] **Step 3: Write `bin/arc`**

```bash
mkdir -p bin
cat > bin/arc <<'SHIM'
#!/usr/bin/env bash
# arc -- document search over the arc index, via the running Emacs daemon.
#
# The daemon is the point. arc's database is already open there, warm, with
# vec0 loaded; an `emacs --batch' CLI would pay cold start, reload the
# extension, contend with the live WAL and duplicate the retrieval code. The
# cost of that choice is this script's one real failure mode, which is why it
# gets its own exit status rather than a cryptic emacsclient message.
set -uo pipefail

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
dead() { printf 'Error: arc: emacs daemon not running\n' >&2; exit 2; }

usage() {
  cat >&2 <<'USAGE'
usage: arc <command> [options]

  arc search QUERY [--scope NAME] [--limit N] [--arm keyword|fused] [--json]
  arc scopes [--json]
  arc stats  [--json]

Exit: 0 ok, 1 error, 2 emacs daemon not running.
USAGE
  exit 1
}

# Evaluate an elisp form in the daemon. Distinguishes "no daemon" from "the
# form signalled": emacsclient exits non-zero for the former and prints a
# *ERROR* line for the latter.
evaluate() {
  local out status
  out=$(emacsclient -e "$1" 2>&1); status=$?
  if [ $status -ne 0 ]; then
    case "$out" in
      *"can't find socket"*|*"No socket"*|*"Connection refused"*|*"could not"*) dead ;;
      *) die "${out:-emacsclient failed}" ;;
    esac
  fi
  case "$out" in
    \*ERROR\**) die "${out#\*ERROR\*: }" ;;
  esac
  # emacsclient renders a string result as a quoted elisp literal; unwrap it.
  printf '%s' "$out" | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
  printf '\n'
}

command -v emacsclient >/dev/null 2>&1 || die "emacsclient not found on PATH"

[ $# -ge 1 ] || usage
cmd="$1"; shift

query=""; scope=""; limit=""; arm="nil"; json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) scope="${2:-}"; shift 2 ;;
    --limit) limit="${2:-}"; shift 2 ;;
    --arm)   arm="(quote ${2:-fused})"; shift 2 ;;
    --json)  json=1; shift ;;
    --help|-h) usage ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$query" ]; then query="$1"; else query="$query $1"; fi; shift ;;
  esac
done

# Elisp string literal: escape backslashes first, then quotes.
elisp_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

case "$cmd" in
  search)
    [ -n "$query" ] || die "search needs a query"
    form="(progn (require 'arc-tool) (arc-tool-search $(elisp_string "$query") $( [ -n "$scope" ] && elisp_string "$scope" || printf nil ) ${limit:-nil} $arm))"
    ;;
  scopes) form="(progn (require 'arc-tool) (arc-tool-scopes))" ;;
  stats)  form="(progn (require 'arc-tool) (arc-tool-stats))" ;;
  --help|-h) usage ;;
  *) die "unknown command: $cmd" ;;
esac

out=$(evaluate "$form") || exit $?

if [ "$json" -eq 1 ]; then
  printf '%s\n' "$out"
else
  # Plain text by default. jq is optional: fall back to the raw JSON.
  if command -v jq >/dev/null 2>&1; then
    case "$cmd" in
      search) printf '%s' "$out" | jq -r '.results[] | "\(.path // .option_name // .info_node)  [\(.chunks) match(es), score \(.score|.*1000|round/1000)]\n\(.passages[] | "    \(.line_start): \(.text)")"' ;;
      scopes) printf '%s' "$out" | jq -r '.scopes[] | "\(.name)  (\(.chunks) chunks)"' ;;
      stats)  printf '%s' "$out" | jq -r '"chunks: \(.chunks)  sources: \(.sources)", (.kinds[] | "  \(.kind): \(.chunks)"), (.freshness[] | "  \(.collection): \(.state)")' ;;
    esac
  else
    printf '%s\n' "$out"
  fi
fi
SHIM
chmod +x bin/arc
```

- [ ] **Step 4: Run the tests**

Run: `emacs -Q -batch -L . -l test/test-arc-shim.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 4 tests.

- [ ] **Step 5: Exercise all three verbs against the live daemon**

```bash
./bin/arc scopes
./bin/arc stats
./bin/arc search "org capture template" --scope vault
./bin/arc search "org capture template" --scope vault --json
./bin/arc search "x" --scope nosuchscope ; echo "exit=$?"
```

Expected: the first four produce output; the last prints `Error: arc: unknown scope "nosuchscope" (try: everything, vault, options, dotfiles)` and `exit=1`.

Then confirm the daemon-down path without killing the real daemon:

```bash
EMACS_SOCKET_NAME=/nonexistent ./bin/arc stats ; echo "exit=$?"
```

Expected: `Error: arc: emacs daemon not running` and `exit=2`. If `emacsclient` ignores that variable in this build, use `emacsclient --socket-name=/nonexistent` inside a scratch copy of the script to verify the branch, and note which form works.

- [ ] **Step 6: Put the shim on PATH**

```bash
ln -sf "$PWD/bin/arc" "$HOME/.local/bin/arc"
arc scopes
```

Expected: the same output as Step 5. `~/.local/bin` already holds other shims, so no PATH change is needed.

- [ ] **Step 7: Write the skill**

Create `$HOME/.claude/skills/arc/SKILL.md`. It lives outside the repo because it describes one installation rather than the package:

```markdown
---
name: arc
description: Search the user's local document corpus — org-roam vault notes, NixOS and Home-Manager configuration, dotfiles, and the built-in Emacs/Elisp/Org manuals — with the arc command. Hybrid BM25 + vector retrieval over a pre-built local index, returning ranked documents with file paths, line numbers and matching passages. Use when the user asks what their own notes, configuration or manuals say about something, where something is configured, or to find a document on their machine. Triggers on "what do my notes say about", "how is X configured", "search my vault", "find in my config", "what does the Emacs manual say", "where did I write about".
---

# arc

Local document search over a pre-built index. Offline apart from a loopback
call to Ollama for query embeddings. Never edits anything — retrieval only.

## Running it

```bash
arc search "QUERY" [--scope NAME] [--limit N] [--arm keyword|fused] [--json]
arc scopes [--json]
arc stats  [--json]
```

Plain text by default; `--json` for machine-readable output. Exit `0` on
success, `1` on error, `2` if the Emacs daemon is not running.

## Before searching

Run `arc scopes` if you do not already know the scope names. Searching the
wrong scope, or defaulting to everything on every call, wastes the index's
main advantage. Current scopes are `everything`, `vault`, `options` and
`dotfiles`.

Run `arc stats` when the answer will be quoted as the user's *current*
configuration. It reports per-collection freshness; a `stale` collection means
the index is behind the files on disk and the passage may no longer be true.

## Reading the output

`--json` returns:

```json
{"query": "...", "scope": "...", "arm": "fused", "elapsed_ms": 148, "count": 10,
 "results": [{"path": "...", "kind": "file", "title": "...", "score": 0.047,
              "chunks": 3,
              "passages": [{"text": "...", "line_start": 12, "line_end": 18}]}]}
```

Results are documents, not fragments, ranked best first. `chunks` is how many
separate passages in that document matched. `results` is `[]` when nothing
matched, never `null`.

## Arms

`--arm keyword` is BM25 only and skips the embedding call — tens of
milliseconds, good for exact identifiers and option names. The default fused
arm adds vector search and takes about 150ms; prefer it for conceptual
questions. If Ollama is unreachable, use `--arm keyword`.

## Citing

Always cite `path:line_start` from the passage you used. The paths are real
files on this machine and the user will open them.

## What it will not do

There is no `ask` verb and no LLM in the path. arc returns passages; you do the
reasoning. It never writes, edits, reindexes or runs a rebuild.
```

- [ ] **Step 8: Verify the skill end to end**

```bash
arc search "syncthing" --scope options --json | head -c 400
```

Expected: parseable JSON with a `results` array. Confirm the `SKILL.md`
frontmatter parses by checking it has exactly `name` and `description` keys
between the `---` fences.

- [ ] **Step 9: Document the search surface in `README.org`**

Add a section after the existing "Data sources" section. Keep every path
derived from `$HOME` — the repo is public:

```org
** Search

In addition to ~arc-ask~, which answers with a local model, arc exposes the
same index as plain search with no model in the path.

+ ~M-x arc-search~ :: minibuffer search. Types on the BM25 arm, which needs no
  embedding call and returns in tens of milliseconds, then upgrades to the full
  hybrid after ~arc-search-hybrid-delay~ seconds of idle. Requires ~consult~;
  arc loads and works without it, minus this command.
+ ~M-x arc-search-show~ :: the same search rendered into ~*arc-search*~, where
  ~TAB~ expands a document to every passage that matched, ~g~ re-runs and ~s~
  re-scopes.

Results are *documents*, not chunks. arc's corpus mixes one-chunk sources (nix
options, Info nodes) with sources that split into dozens (vault notes,
dotfiles), so a chunk-level result list lets one long note fill every slot.
~arc-rollup-function~ chooses how a document's score is aggregated from its
chunks'; see ~docs/design/2026-09-13-rollup-measurement.md~ for the sweep that
picked the default.

*** As a tool

~bin/arc~ exposes ~search~, ~scopes~ and ~stats~ to anything outside Emacs,
through ~emacsclient~ and the running daemon -- so the database stays warm and
there is no second process to babysit. Symlink it onto ~PATH~:

#+begin_src sh
ln -s /path/to/arc/bin/arc ~/.local/bin/arc
arc search "disk layout" --scope dotfiles --json
#+end_src

Exit status is 0 on success, 1 on error, and 2 specifically when the Emacs
daemon is not running -- the one failure mode this transport has that the
in-Emacs commands do not.

There is deliberately no ~ask~ verb. A caller that wants prose already has its
own model; arc's job here is retrieval.
```

- [ ] **Step 10: Full suite, then commit**

Run: `test/run.sh`
Expected: exit 0, all suites green.

```bash
git add bin/arc test/test-arc-shim.el README.org
git commit -m "feat(tool): reach the warm index from outside Emacs

bin/arc talks to the running daemon over emacsclient rather than opening
the database itself. That keeps the property the whole package is built
on -- one process tree, nothing to babysit, the reason turbovec was
rejected -- and costs nothing: the database is already open, vec0 is
already loaded, and there is no sqlite3 binary on the box anyway. An
emacs --batch CLI would pay cold start, reload the extension and contend
with the live WAL.

The cost is a failure mode the in-Emacs commands never had: no daemon,
no tool. It gets exit status 2 and a plain message instead of whatever
emacsclient would have said, so it is legible rather than mysterious.

jq is optional. Without it the plain-text mode prints the raw JSON
instead of failing."
```

---

## Self-Review

**Spec coverage.** Every section of `docs/superpowers/specs/2026-09-13-arc-search-design.md` maps to a task:

| Spec section | Task |
|---|---|
| Getting scores out of retrieval | 1 |
| Rollup (`arc-rollup-function`, `top-n`, tie-break, output plist) | 2 |
| Pool, clamping, `arc-search-documents`, hydration | 3 |
| Measurement plan, document-level recall, recording the losers | 4 |
| Results buffer (`arc-results-mode`, TAB/RET/g/s) | 5 |
| Consult source, two-stage, fail-soft, identity-preserved selection | 6 |
| `search` / `scopes` / `stats`, no `ask` | 7 |
| `bin/arc`, exit 2, skill definition | 8 |
| Testing (rollup, search-core, tool, strategy stability) | 2, 3, 6, 7 |
| Out of scope (no PDFs, no MCP, no reranker, no index change) | respected throughout; reranker explicitly bound off in Task 3 |

One spec item is deliberately weakened and flagged rather than silently dropped: the spec says selection is "preserved by source-id" across the stage-2 swap. Task 6 implements the two arms and the fail-soft path, but consult's dynamic collection rebuilds its candidate list wholesale, and preserving point across that rebuild depends on the consult version's own behaviour. Step 6 of Task 6 is the manual check; if it does not hold, that is a follow-up against consult's API and not a reason to block the rest.

**Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N". The two places a value is genuinely unknown until code runs — the sweep numbers in Task 4 Step 6/8, and the `arc-freshness-report` row indices in Task 7 Step 1 — are written as explicit measure-then-fill steps with the command to run and an instruction not to guess.

**Type consistency.** Checked across tasks: `arc-search-documents` returns plists keyed `:source-id :kind :path :title :org-id :option-name :info-node :score :chunk-count :best-rank :passages` (Task 3), and Tasks 4, 5, 6 and 7 all read exactly those keys. Passages are `(:chunk :line-start :line-end :score)` everywhere; `arc-tool--document-json` is the only place they are renamed, to `text` / `line_start` / `line_end`, and Task 8's skill documents that JSON name set and no other. `arc-rollup` consumes `(:id :source-id :score)`, which is precisely what `arc-search--attach-sources` produces.
