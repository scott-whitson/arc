;;; arc-search.el --- document search over the arc index -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file consumes arc's retrieval machinery as ranked documents rather
;; than prose.  It is the LLM-free search surface: no model is needed for
;; keyword search, and the fused arm makes only the embedding call needed to
;; rank the documents.
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

Ten chunks cannot produce ten documents: measured on the 63,302-chunk
corpus of 2026-09-13, a two-hundred chunk pool yielded about a hundred
and thirty distinct sources, and a forty-chunk one routinely yielded
fewer than ten.  Depth is close to free -- the brute-force vector scan
already touches every row and LIMIT only changes the sort -- measured
at +8 ms on the keyword arm and +22 ms on the fused arm going from
forty to two hundred, on that same corpus.

Those figures are historical.  The corpus measured 310,767 chunks on
2026-09-17, roughly five times the size they were taken at, and they
have not been re-measured since; nothing about the SHAPE of the
finding changed (a deeper pool is still most of a rollup's input, and
LIMIT is still not where the cost is), but treat the exact numbers as
an order of magnitude rather than a current measurement.  A reader who
needs them exact should re-measure and say against what size.

This is a ceiling, not a promise: `arc-search--effective-pool' lowers
it for scopes where depth would change the query plan."
  :type 'integer :group 'arc)

(defcustom arc-search-limit 10
  "How many documents a search returns."
  :type 'integer :group 'arc)

(defcustom arc-search-priority-rules nil
  "Explicit deterministic boosts applied after rollup and before the limit.

Each rule is a plist with a non-empty `:query' regexp, a positive numeric
`:boost', and at least one source matcher.  Supported matchers are
`:path-prefix', `:kind', `:option-name', `:org-id' and `:info-node'.  All
matchers present on one rule must match the document; boosts from every
matching rule are added.  Rules are data, not click history, and remain
outside the retrieval eval path.

Example:

  \='((:query \"disk layout\" :path-prefix \"/srv/notes/ioshi/\" :boost 100))

The default nil leaves the measured retrieval order unchanged.
Malformed rules signal an error naming the invalid field rather than being
silently ignored.

Priority rules are deliberately applied only to the document search surface.
The retrieval eval harness binds this variable to nil so its measurements
continue to describe the baseline ranker, not operator personalization."
  :type '(repeat plist) :group 'arc)

(defconst arc-search--priority-matcher-keys
  '(:path-prefix :kind :option-name :org-id :info-node)
  "Source fields allowed in `arc-search-priority-rules'.")

(defun arc-search--validate-priority-rule (rule)
  "Validate and return one explicit priority RULE.
A rule's query and source matcher values are strings, its boost is positive,
and all matchers on the rule are ANDed.  Signal a descriptive error for
unknown keys or malformed data so a typo cannot silently alter ranking."
  (unless (and (listp rule) (zerop (% (length rule) 2)))
    (error "arc: priority rule must be an even-length plist: %S" rule))
  (let ((allowed (append '(:query :boost) arc-search--priority-matcher-keys)))
    (cl-loop for (key _value) on rule by #'cddr
             unless (memq key allowed)
             do (error "arc: unknown priority rule key %S" key)))
  (let ((query (plist-get rule :query))
        (boost (plist-get rule :boost)))
    (unless (and (stringp query) (not (string-empty-p query)))
      (error "arc: priority rule :query must be a non-empty regexp: %S" query))
    (condition-case err
        (string-match-p query "")
      (invalid-regexp
       (error "arc: priority rule :query is not a valid regexp %S: %s"
              query (error-message-string err))))
    (unless (and (numberp boost) (> boost 0))
      (error "arc: priority rule :boost must be positive: %S" boost)))
  (unless (cl-some (lambda (key) (plist-member rule key))
                   arc-search--priority-matcher-keys)
    (error "arc: priority rule needs a source matcher: %S" rule))
  (dolist (key arc-search--priority-matcher-keys)
    (when (plist-member rule key)
      (unless (and (stringp (plist-get rule key))
                   (not (string-empty-p (plist-get rule key))))
        (error "arc: priority rule %S matcher must be a non-empty string: %S"
               key (plist-get rule key)))))
  rule)

(defun arc-search--priority-source-match-p (rule doc)
  "Return non-nil when every source matcher in RULE matches DOC."
  (cl-every
   (lambda (key)
     (if-let* ((want (and (plist-member rule key) (plist-get rule key))))
         (let ((have (plist-get doc (if (eq key :path-prefix) :path key))))
           (if (eq key :path-prefix)
               (and have (string-prefix-p want have))
             (equal want have)))
       t))
   arc-search--priority-matcher-keys))

(defun arc-search--priority-boost (query doc rules)
  "Return the sum of RULES' boosts matching QUERY and DOC."
  (cl-loop for rule in rules
           when (and (string-match-p (plist-get rule :query) query)
                     (arc-search--priority-source-match-p rule doc))
           sum (plist-get rule :boost)))

(defun arc-search--apply-priority-rules (query docs)
  "Apply explicit priority boosts to DOCS for QUERY, before limiting.
When `arc-search-priority-rules' is nil, return DOCS unchanged.  Otherwise
validate all rules first, add matching boosts, and use the existing fully
deterministic document comparator (score, chunk count, best rank, source id).
The original score is retained as `:retrieval-score' whenever a boost was
applied so callers can explain why a result moved."
  (if (null arc-search-priority-rules)
      docs
    (let* ((rules (mapcar #'arc-search--validate-priority-rule
                          arc-search-priority-rules))
           (changed nil)
           (adjusted
            (mapcar
             (lambda (doc)
               (let ((boost (arc-search--priority-boost query doc rules)))
                 (if (and boost (> boost 0))
                     (progn
                       (setq changed t)
                       (let ((copy (copy-sequence doc)))
                         (plist-put copy :retrieval-score (plist-get doc :score))
                         (plist-put copy :priority-boost boost)
                         (plist-put copy :score (+ (plist-get doc :score) boost))
                         copy))
                   doc)))
             docs)))
      (if changed
          (sort adjusted #'arc-rollup--better-p)
        docs))))

(defun arc-search--minimum-pool (scope)
  "Return the shallowest pool that could yield `arc-search-limit' documents.

A pool is counted in CHUNKS and the answer is counted in DOCUMENTS, so
the conversion between them is SCOPE's own chunks-per-source ratio --
which is not a constant and cannot be one: `nix options' is one chunk
per document, `vault' is twenty-four to forty-six.  Ten documents from
a one-chunk-per-document scope need ten chunks; ten from a prose scope
need hundreds.

Measured from the scope rather than assumed, which is what keeps this
from going stale the way a hardcoded threshold does.  Never below
`arc-knn-candidates', the depth retrieval has always had."
  (let* ((chunks (arc-scope-count scope))
         (sources (arc-scope-source-count scope)))
    (if (or (null sources) (zerop sources))
        arc-knn-candidates
      (max arc-knn-candidates
           (ceiling (* arc-search-limit (/ (float chunks) sources)))))))

(defun arc-search--effective-pool (scope)
  "Return the pool to use for SCOPE.

`arc-scope-vector-plan' asks vec0 for k = ceil(`arc-knn-candidates' *
total/n) on a scoped query, and correctly falls back to brute force when
that exceeds `arc-vec0-k-ceiling'.  Brute force is exact but costs
roughly 0.2 ms per row in scope, so a scope just above
`arc-scope-bruteforce-max' would flip from a fast KNN query at the
default pool to a ~400 ms brute-force one at a deep pool -- a large,
silent regression caused by nothing but asking for more candidates.

So search is allowed to be deep, or to change the plan, not both --
with one exception, below.  An unscoped query and one already on the
brute-force branch cannot flip, so they take the full pool.  Anything
else is clamped to the largest pool whose k still fits under the
ceiling: floor(`arc-vec0-k-ceiling' * n/total).

THE EXCEPTION, and why it had to be added.  That clamp is a RATIO, so
it shrinks as the corpus grows while the scope stays the same size.
It engages below n/total = `arc-search-pool'/`arc-vec0-k-ceiling',
which is a fixed ratio but a moving number of chunks: 3,091 chunks on
the 63,302-chunk corpus this was written against, 15,174 on the
310,767-chunk corpus of 2026-09-17.  A scope of 5,572 chunks was
comfortably unclamped before and would now be handed a 73-chunk pool
against a ten-document limit.  For a one-chunk-per-document scope 73 is
still plenty; for a prose scope it is three or four documents where ten
were asked for -- a silently short answer, which is a worse failure
than a slow one, and just as invisible as the plan flip this clamp
exists to prevent.

`arc-search--minimum-pool' is therefore a floor under the clamp,
derived from the scope's own chunks-per-source ratio rather than from
any corpus-size constant.  When the two conflict, the floor wins and
the plan flips to brute force: exact, bounded by the scope, and the
clamped band is by construction under a twentieth of the corpus.
`arc-search-pool' remains a hard ceiling over both, so no scope can
ask for more depth than an unscoped query would."
  (let ((want (max arc-search-pool arc-knn-candidates)))
    (if (or (arc-scope-empty-p scope)
            (eq (car (arc-scope-vector-plan scope)) 'brute))
        want
      (let ((n (arc-scope-count scope))
            (total (arc-scope-total)))
        (if (or (zerop n) (zerop total))
            want
          (let ((plan-preserving (floor (* arc-vec0-k-ceiling (/ (float n) total)))))
            (if (>= plan-preserving want)
                want
              (min want (max plan-preserving (arc-search--minimum-pool scope))))))))))

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

SCOPE takes any shape `arc-scope-normalize' accepts; nil means
`arc-enabled-collections'.  ARM is passed through to
`arc--find-similar': `keyword' skips the embedding call entirely and is
what the live-typing stage uses, nil or `fused' is the full hybrid.

`arc-reranker-enabled' is bound off for the duration.  The reranker's
limit would otherwise truncate the pool through `arc-get-limit' before
rollup ever sees it, and the provider-agnostic reranker seam remains
separate from document search."
  (let* ((scope (arc-scope-normalize scope))
         (pool (arc-search--effective-pool scope))
         (arc-reranker-enabled nil)
         (arc-knn-candidates pool)
         (arc-limit pool)
         (rows (sqlite-select (arc-db) (arc--find-similar query scope arm t)))
         (docs (arc-search--hydrate
                (arc-rollup (arc-search--attach-sources rows)))))
    ;; Priority rules are a display-layer personalization applied before the
    ;; final document limit.  This keeps an explicitly pinned source able to
    ;; enter the result set while leaving the measured retrieval pool and eval
    ;; ranker untouched.
    (take arc-search-limit (arc-search--apply-priority-rules query docs))))

(provide 'arc-search)
;;; arc-search.el ends here
