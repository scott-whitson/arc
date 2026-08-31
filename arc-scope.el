;;; arc-scope.el --- what a query is allowed to look at -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A scope is a plist naming restrictions -- collections, kinds, org tags, a
;; path prefix -- that compiles to exactly one SQL predicate over `data'
;; joined to `sources'.  Retrieval puts that predicate in a `scoped' CTE and
;; joins both the vector side and the FTS side against it explicitly.
;;
;; Before this file existed, the only scoping in the codebase was by whole
;; collection, and it worked by inlining the scoped rowids directly into the
;; query text as an `IN (...)' list -- 6,427 integers, twice, on the live
;; index.  `:kinds', `:tags' and `:path-prefix' scoping did not exist in any
;; form.  It was believed, and written into this phase's design, that the
;; old inlined-list query also filtered the vec0 KNN operator's results
;; *after* an unscoped global search, so a vault-scoped question whose
;; nearest global neighbours were all dotfiles would return no semantic
;; candidates at all.  That specific belief was checked against the real,
;; filtered query and found false: SQLite deterministically flattens a CTE
;; referenced exactly once and pushes the resulting `rowid IN (...)'
;; predicate down into vec0's own scan via `sqlite3_vtab_in', so the old
;; query's scope reached the search after all, by a route it never asked
;; for. Measured on the live index (428 vault rows of 7,405 chunks): the old
;; query's semantic arm returned 20 rows, all vault, in the same order as
;; brute-force cosine distance -- not zero. Forcing that same CTE
;; `AS MATERIALIZED', which defeats the flattening, reproduces the believed
;; defect on the identical query text and returns zero rows; that is what
;; made the old correctness an accident of an optimizer's choice rather than
;; a designed property, and that dependency, not a missing semantic result,
;; is what this file actually removes. The genuinely new things here are the
;; scoping dimensions that did not exist before (`:kinds', `:tags',
;; `:path-prefix'), an explicit join that does not depend on SQLite choosing
;; to flatten anything, and no more inlined rowid lists.
;;
;; Tags are stored the way org itself writes them, colon-delimited and
;; colon-anchored (":emacs:nix:"), so a tag match is a substring match that
;; cannot accidentally match a longer tag with the same ending.

;;; Code:

(require 'subr-x)
(require 'arc-db)

(defun arc-scope (&rest keys)
  "Return a scope plist built from KEYS.
Recognized keys: :collections, :kinds, :tags (each a list of strings),
:path-prefix (a string), and :all (any non-nil value).  A scope with
none of :collections, :kinds, :tags or :path-prefix restricts
nothing -- nil itself is exactly this, the empty plist, and means the
whole corpus.

:all exists because nil is ambiguous to some callers even though it
is unambiguous here: `arc-ask-normalize-scope' treats a bare nil
SECOND ARGUMENT to `arc-ask' as \"caller specified no scope, use
`arc-enabled-collections'\" -- a different meaning than this
function's own \"restricts nothing\". `(arc-scope :all t)' is a
non-nil plist whose first element is a keyword, so it passes straight
through `arc-ask-normalize-scope' unchanged, while still restricting
nothing: `arc-scope-empty-p' still reports it empty, because :all
names no actual restriction for `arc-scope-predicate' to compile. It
is the one value a caller of `arc-ask' can pass to unambiguously mean
\"the whole corpus\", which is what `arc-scope-presets''s
\"everything\" entry uses."
  keys)

(defun arc-scope-empty-p (scope)
  "Return non-nil when SCOPE restricts nothing."
  (not (or (plist-get scope :collections)
           (plist-get scope :kinds)
           (plist-get scope :tags)
           (plist-get scope :path-prefix))))

(defun arc--scope-like-literal (string)
  "Return STRING as a LIKE pattern body with wildcards neutralised.
`%' and `_' are LIKE metacharacters and both occur in real data -- `_'
in org tags, both in paths -- so they are backslash-escaped and every
generated LIKE carries an explicit ESCAPE clause.  The backslash
itself is escaped first, or escaping the others would corrupt it."
  (let* ((s (arc-sqlite-escape string))
         (s (string-replace "\\" "\\\\" s))
         (s (string-replace "%" "\\%" s))
         (s (string-replace "_" "\\_" s)))
    s))

(defun arc-scope-predicate (scope)
  "Compile SCOPE to a SQL boolean expression.
The expression is written against the aliases `d' (`data') and `s'
(`sources'), which the caller must provide.  An empty scope compiles
to \"1\", so a caller never needs a special case for it."
  (let (parts)
    (when-let ((cols (plist-get scope :collections)))
      (push (format "d.collection_id IN (SELECT id FROM collections WHERE name IN %s)"
                    (arc-sqlite-format-string-list cols))
            parts))
    (when-let ((kinds (plist-get scope :kinds)))
      (push (format "s.kind IN %s" (arc-sqlite-format-string-list kinds)) parts))
    (when-let ((tags (plist-get scope :tags)))
      (push (format "(%s)"
                    (mapconcat (lambda (tag)
                                 (format "s.tags LIKE '%%:%s:%%' ESCAPE '\\'"
                                         (arc--scope-like-literal tag)))
                               tags " OR "))
            parts))
    (when-let ((prefix (plist-get scope :path-prefix)))
      (push (format "s.path LIKE '%s%%' ESCAPE '\\'" (arc--scope-like-literal prefix)) parts))
    (if parts (string-join (nreverse parts) " AND ") "1")))

(defun arc-scope-count (scope)
  "Return how many `data' rows SCOPE admits."
  (caar (sqlite-select
         (arc-db)
         (format "SELECT count(*) FROM data d JOIN sources s ON s.id = d.source_id WHERE %s;"
                 (arc-scope-predicate scope)))))

(defun arc-scope-total ()
  "Return how many `data' rows the corpus holds in total.
Joined to `sources' the same way `arc-scope-count' is, so the two
agree by construction: a `data' row whose `source_id' does not
resolve to a `sources' row (the column carries no NOT NULL or FK
enforcement) would otherwise inflate this past what any scope,
including no scope at all, can ever count -- and Task 4 divides one
of these by the other to scale the KNN `k', so that divergence would
silently pick a wrong retrieval strategy rather than error."
  (caar (sqlite-select (arc-db) "SELECT count(*) FROM data d JOIN sources s ON s.id = d.source_id;")))

(defun arc-scope-describe (scope)
  "Return a short human description of SCOPE, for refusals and headings."
  (if (arc-scope-empty-p scope)
      "everything"
    (string-join
     (delq nil
           (list (when-let ((c (plist-get scope :collections))) (string-join c ", "))
                 (when-let ((k (plist-get scope :kinds))) (concat "kinds " (string-join k ", ")))
                 (when-let ((tg (plist-get scope :tags))) (concat "tags " (string-join tg ", ")))
                 (when-let ((p (plist-get scope :path-prefix))) (concat "under " p))))
     "; ")))

(defcustom arc-scope-presets
  '(("everything" . (:all t))
    ("vault"      . (:collections ("vault")))
    ("options"    . (:collections ("nix options" "hm options")))
    ("dotfiles"   . (:collections ("dotfiles"))))
  "Named scopes offered by `arc-ui-change-scope'.
Each entry is (NAME . SCOPE-PLIST).  \"everything\" is `(:all t)'
rather than nil: see `arc-scope''s docstring for why a bare nil here
would not survive `arc-ask-normalize-scope' as \"the whole corpus\".
These are the scopes a reader can reach from inside an answer;
`arc-ask' itself accepts any scope plist."
  :type '(alist :key-type string :value-type sexp)
  :group 'arc)

(defconst arc-vec0-k-ceiling 4096
  "The largest `k' sqlite-vec's KNN operator accepts.
Measured against sqlite-vec 0.1.6: `k = 4097' fails with \"k value in
knn query too large\".  This is why a sufficiently narrow scope cannot
simply raise `k' until enough in-scope rows appear, and why
`arc-scope-vector-plan' has a brute-force branch at all.")

(defcustom arc-knn-candidates 40
  "How many nearest neighbours retrieval wants to consider.
For an unscoped query this is `k' directly.  For a scoped one it is
the number of neighbours wanted *within the scope*, which is what
`arc-scope-vector-plan' scales `k' up to approximate."
  :type 'integer
  :group 'arc)

(defcustom arc-scope-bruteforce-max 2000
  "Largest scope, in chunks, searched by brute-force distance.
Brute force is exact -- it considers every row in scope and no row
outside it -- and its cost tracks the size of the scope rather than
the size of the corpus, because SQLite evaluates the distance function
only on the joined rows.  Measured on this corpus at roughly 0.2 ms per
row in scope: a 428-row scope took 54 ms, all 7,405 rows took 1.59 s.
2000 keeps the worst case near 400 ms."
  :type 'integer
  :group 'arc)

(defun arc-scope-vector-plan (scope)
  "Decide how to run vector search for SCOPE.
Return a cons (STRATEGY . K): either (knn . K), meaning run vec0's KNN
operator asking for K neighbours and keep the ones in scope, or
(brute . nil), meaning compute the distance directly over the scoped
rows.

An unscoped query always takes the KNN operator: there is nothing to
filter afterwards, so its result is already exact, and it is two
orders of magnitude faster than brute force across a whole corpus.

A scoped query has to get `arc-knn-candidates' rows *from inside the
scope*.  Brute force does that exactly, at a cost proportional to the
scope, so a scope up to `arc-scope-bruteforce-max' takes it.  A larger
scope asks the KNN operator for proportionally more neighbours --
enough that roughly `arc-knn-candidates' of them should land in scope
-- unless that number exceeds `arc-vec0-k-ceiling', in which case
there is no k that can work and brute force is the only correct
option, whatever it costs."
  (if (arc-scope-empty-p scope)
      (cons 'knn arc-knn-candidates)
    (let ((n (arc-scope-count scope)))
      (if (or (zerop n) (<= n arc-scope-bruteforce-max))
          (cons 'brute nil)
        (let* ((total (arc-scope-total))
               (k (ceiling (* arc-knn-candidates (/ (float total) n)))))
          (if (<= k arc-vec0-k-ceiling)
              (cons 'knn k)
            (cons 'brute nil)))))))

(defun arc-scope-from-collections (collections)
  "Return a scope restricting to COLLECTIONS, or an empty scope for nil.
Callers that hold a plain list of collection names -- `arc-ask' with
its documented list argument, `arc-enabled-collections' -- go through
here rather than building a plist inline."
  (if collections (arc-scope :collections collections) (arc-scope)))

(provide 'arc-scope)
;;; arc-scope.el ends here
