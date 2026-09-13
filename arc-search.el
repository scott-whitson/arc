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
