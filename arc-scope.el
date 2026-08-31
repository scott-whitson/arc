;;; arc-scope.el --- what a query is allowed to look at -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A scope is a plist naming restrictions -- collections, kinds, org tags, a
;; path prefix -- that compiles to exactly one SQL predicate over `data'
;; joined to `sources'.  Retrieval puts that predicate in a `scoped' CTE and
;; joins both the vector side and the FTS side against it.
;;
;; The predicate is what makes scoping real rather than cosmetic.  Before
;; this file existed, a "scoped" query ran the vec0 KNN operator across the
;; whole corpus and filtered the survivors afterwards, so asking a
;; vault-scoped question whose nearest global neighbours were all dotfiles
;; returned no semantic candidates at all -- measured, on the live index:
;; "how do I enable syncthing in home-manager" put 40 of 40 global nearest
;; neighbours in dotfiles and none in the vault.  A scope has to reach the
;; search, not the results.
;;
;; Tags are stored the way org itself writes them, colon-delimited and
;; colon-anchored (":emacs:nix:"), so a tag match is a substring match that
;; cannot accidentally match a longer tag with the same ending.

;;; Code:

(require 'subr-x)
(require 'arc-db)

(defun arc-scope (&rest keys)
  "Return a scope plist built from KEYS.
Recognized keys: :collections, :kinds, :tags (each a list of strings)
and :path-prefix (a string).  A scope with none of them -- like nil
itself -- means the whole corpus."
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

(provide 'arc-scope)
;;; arc-scope.el ends here
