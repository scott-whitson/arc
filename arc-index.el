;;; arc-index.el --- write chunks and embeddings -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The brief this file implements has `arc--collection-id' insert
;; `(name, enabled)'; `collections' has no `enabled' column (see
;; `arc-collections-create-table-sql' in arc-db.el -- it is `(id, name)'
;; only, and "enabled" is `arc-enabled-collections', an in-memory list,
;; not a database column).  Inserting a nonexistent column would fail
;; every call, so the insert here only ever names `name'.
;;
;; `arc-reindex-all' below is the one caller of all five producers
;; (`arc-file-sources', `arc-org-nodes', `arc-nixopt-parse-json' (twice,
;; for NixOS and Home-Manager options) and `arc-info-sources'), so this
;; file requires all of their defining libraries itself rather than
;; relying on `arc.el', which only happens to require two of them (for
;; unrelated reasons of its own) and never required `arc-source-org' or
;; `arc-source-nixopt' at all.  It does NOT require `arc-source' --
;; nothing here calls any of that file's symbols; `arc.el' requires it
;; instead, which is also where `arc-source-link'/`arc-source-label'
;; will eventually be used to render a citation.
;;; Code:

(require 'cl-lib)
(require 'llm)
(require 'arc-db)
(require 'arc-source-file)
(require 'arc-source-org)
(require 'arc-source-nixopt)
(require 'arc-source-info)

(defun arc--collection-id (name)
  "Return the id of collection NAME, creating it if needed."
  (sqlite-execute (arc-db)
                  (format "INSERT INTO collections (name) VALUES (%s)
                           ON CONFLICT (name) DO NOTHING;" (arc--sql-quote name)))
  (caar (sqlite-select (arc-db)
                       (format "SELECT id FROM collections WHERE name = %s;"
                               (arc--sql-quote name)))))

(defun arc--sanitize-text (text)
  "Return TEXT with any undecodable byte replaced by U+FFFD.
Some source content -- a copy-pasted org-roam node, a file in a
legacy encoding -- can contain a byte sequence its buffer's coding
system could not decode, surfacing internally as Emacs's `eight-bit'
raw-byte characters.  `arc--text-file-p' already keeps a wholly
binary file (an agenix `.age' secret, say) out of the `file' kind
entirely, but a node or chunk that is otherwise good text with only a
handful of bad bytes deep inside it -- as happened with a real
org-roam node pasted from elsewhere -- reaches every kind through
this one function, not just `file'.  Those raw bytes cannot be
JSON-encoded for the embeddings API and crash indexing outright, far
from whatever chunk was responsible.  Replacing them here keeps the
rest of an otherwise-good chunk searchable instead of losing it
outright, and does so audibly via `message', not silently."
  (let ((cleaned (replace-regexp-in-string "[\x3FFF80-\x3FFFFF]" "\uFFFD" text)))
    (unless (equal cleaned text)
      (message "arc: replaced undecodable byte(s) in a chunk (%d chars)" (length text)))
    cleaned))

(defun arc-index-source (source collection)
  "Index SOURCE into COLLECTION.  Return the number of chunks written.
Existing chunks for the source are deleted first, so reindexing
replaces rather than duplicates."
  (let* ((cid (arc--collection-id collection))
         (sid (arc-source-upsert source))
         (chunks (plist-get source :chunks))
         (n 0))
    (arc--delete-data-for-source sid)
    (dolist (c chunks)
      (let* ((text (arc--sanitize-text (plist-get c :text)))
             (vec (llm-embedding arc-embeddings-provider text)))
        (sqlite-execute
         (arc-db)
         (format "INSERT INTO data (source_id, collection_id, chunk, line_start, line_end, title)
                  VALUES (%d, %d, %s, %s, %s, %s);"
                 sid cid (arc--sql-quote text)
                 (or (plist-get c :line-start) "NULL")
                 (or (plist-get c :line-end) "NULL")
                 (arc--sql-quote (plist-get source :title))))
        (let ((rowid (caar (sqlite-select (arc-db) "SELECT last_insert_rowid();"))))
          (sqlite-execute (arc-db)
                          (format "INSERT INTO data_embeddings (rowid, embedding) VALUES (%d, %s);"
                                  rowid (arc-vector-to-sqlite vec)))
          (sqlite-execute (arc-db)
                          (format "INSERT INTO data_fts (rowid, data) VALUES (%d, %s);"
                                  rowid (arc--sql-quote text))))
        (setq n (1+ n))))
    n))

(defun arc-index-stats ()
  "Return an alist of (KIND . CHUNK-COUNT)."
  (mapcar (lambda (row) (cons (nth 0 row) (nth 1 row)))
          (sqlite-select (arc-db)
                         "SELECT s.kind, count(d.id) FROM sources s
                          LEFT JOIN data d ON d.source_id = s.id
                          GROUP BY s.kind;")))

(defcustom arc-collection-directory-alist
  `(("dotfiles" . ,(expand-file-name "dotfiles" (getenv "HOME")))
    ("eminix"   . ,(expand-file-name "projects/eminix" (getenv "HOME")))
    ("vault"    . ,(expand-file-name "docs/org" (getenv "HOME"))))
  "Map a collection name to the directory it indexes.
Derived from $HOME -- never hardcode an absolute home path here."
  :type '(alist :key-type string :value-type directory) :group 'arc)

(defun arc-collection-directory (name)
  "Return the directory NAME indexes, or signal if it is not configured."
  (or (alist-get name arc-collection-directory-alist nil nil #'equal)
      (error "arc: no directory configured for collection %S" name)))

(defcustom arc-index-plan
  '(("dotfiles" . file) ("eminix" . file) ("vault" . org)
    ("nix options" . nixopt) ("hm options" . hmopt) ("builtin manuals" . info))
  "Collections to build and the chunker each uses."
  :type '(alist :key-type string :value-type symbol) :group 'arc)

(defcustom arc-index-nixopt-cap nil
  "Maximum number of NixOS options to index, or nil for all of them.
options.json holds 24,661 options; embedding all of them is 20-40
minutes of sustained CPU/GPU.  Set this to a small number (e.g. 300)
to prove the ingestion path end-to-end without paying that cost, and
back to nil for a real full ingest."
  :type '(choice (const nil) natnum) :group 'arc)

(defcustom arc-index-hmopt-cap nil
  "Maximum number of Home-Manager options to index, or nil for all of them.
Home-Manager's options.json is the same shape and a similar order of
magnitude as NixOS's; see `arc-index-nixopt-cap' for the same
rationale.  Set this to a small number to prove the ingestion path
end-to-end without paying the full embedding cost, and back to nil for
a real full ingest."
  :type '(choice (const nil) natnum) :group 'arc)

(defcustom arc-index-info-cap nil
  "Maximum number of Info manual nodes to index, or nil for all of them.
`arc-get-builtin-manuals' names 94 manuals; embedding every node in all
of them is, like `arc-index-nixopt-cap', 20-40 minutes of sustained
CPU/GPU for a first full index.  nil (unlimited) is the honest default
for a tool whose whole value is completeness -- set this to a small
number only to prove the ingestion path end-to-end without paying that
cost.  See `arc-index-info-priority-manuals' for which manuals a capped
run indexes first."
  :type '(choice (const nil) natnum) :group 'arc)

(defcustom arc-index-info-priority-manuals '("emacs" "elisp" "org")
  "Manual base names indexed FIRST when `arc-index-info-cap' limits how
many Info nodes get indexed.
`arc-get-builtin-manuals' returns 94 manuals in directory order, not
relevance order; a capped run that takes the first N of them in that
order is an alphabetical/directory accident, not a choice -- on this
machine it landed on \"auth\", \"autotype\" and \"bash\", leaving the
Emacs, Elisp and Org manuals -- exactly what an Emacs/Elisp/org oracle
most needs -- out of the corpus entirely.  A name here matches a
manual either literally (\"emacs\") or as `file-name-base' renders a
gzip-compressed manual (\"emacs.info\"): `arc-get-builtin-manuals'
produces one spelling or the other depending on whether this host's
Info pages are compressed, and both are checked so the priority list
does not silently miss a manual over that accident too."
  :type '(repeat string) :group 'arc)

(defun arc--prioritize-manuals (manuals priority)
  "Return MANUALS reordered so entries matching PRIORITY come first, in
PRIORITY's order, followed by the rest of MANUALS in their original
order.  See `arc-index-info-priority-manuals' for what \"matches\" means."
  (let* ((match (lambda (p m) (or (equal p m) (equal (concat p ".info") m))))
         (first (delq nil (mapcar (lambda (p) (cl-find-if (lambda (m) (funcall match p m)) manuals))
                                   priority))))
    (append first (cl-remove-if (lambda (m) (member m first)) manuals))))

(defun arc--prune-collection (cid kept-ids)
  "Delete every source belonging to collection CID that is not in
KEPT-IDS, cascading its chunks, embeddings and FTS rows via
`arc-source-delete'.  Return how many sources were removed.
Upstream's directory walk deleted `data' rows for paths the current
walk no longer yielded; nothing replaced that when `sources' gained
its own identity, so anything deleted, newly gitignored, or newly
excluded from the corpus stayed citable forever.  KEPT-IDS is the set
of source ids this run's own walk of CID just touched (threaded from
`arc-source-upsert', not recomputed), so a source that moved to a
different collection in the very same `arc-reindex-all' run is not
mistaken for one that vanished."
  (let ((stale (flatten-tree
                (sqlite-select
                 (arc-db)
                 (format "SELECT DISTINCT s.id FROM sources s
                          JOIN data d ON d.source_id = s.id
                          WHERE d.collection_id = %d%s;"
                         cid
                         (if kept-ids
                             (format " AND s.id NOT IN %s" (arc-sqlite-format-int-list kept-ids))
                           ""))))))
    (dolist (sid stale) (arc-source-delete sid))
    (length stale)))

(defconst arc--reindex-skipped :arc-reindex-skipped
  "Sentinel `arc--reindex-directory-collection' returns for a missing
directory, distinct from an empty list of kept ids (a directory that
exists but genuinely has nothing left in it -- which IS a reason to
prune) so `arc-reindex-all' never mistakes \"this collection's
directory is not on this host\" for \"everything in it was deleted\"
and prunes rows that are still perfectly good.")

(defun arc--reindex-directory-collection (name dir producer)
  "Index every source PRODUCER (a function of one DIR argument) returns
for collection NAME under DIR, or skip with a `message' when DIR does
not exist on this host.  Return the list of source ids indexed, or
`arc--reindex-skipped'.
`arc-collection-directory-alist' can name a directory that is simply
absent here -- `eminix' on a host with no such checkout, for instance
-- and `directory-files-recursively' used to signal `file-missing' the
moment such a plan entry's turn came up, aborting every collection
still queued behind it.  A missing directory is now an ordinary,
reported skip instead -- and, importantly, not a reason to prune every
row this collection already has: the corpus here is merely unbuilt,
not emptied."
  (if (not (file-directory-p dir))
      (progn (message "arc: skipping %s, directory does not exist: %s" name dir)
             arc--reindex-skipped)
    (mapcar (lambda (s) (prog1 (arc-source-upsert s) (arc-index-source s name)))
            (funcall producer dir))))

;;;###autoload
(defun arc-reindex-all (&optional collections)
  "Rebuild collections in `arc-index-plan'.  Reports per-kind counts.
With COLLECTIONS (a list of collection names), only rebuilds the
`arc-index-plan' entries whose name is a member of it, leaving every
other collection's rows untouched.  With no COLLECTIONS (the default),
rebuilds every entry in the plan.  Reports progress per collection via
`message', since a real full ingest -- unlimited caps are the default
-- is a 20-40 minute run in which silence would otherwise look hung."
  (interactive)
  (dolist (cell (if collections
                     (seq-filter (lambda (c) (member (car c) collections)) arc-index-plan)
                   arc-index-plan))
    (let* ((name (car cell))
           (cid (arc--collection-id name))
           (kept
            (pcase (cdr cell)
              ('file (arc--reindex-directory-collection name (arc-collection-directory name)
                                                          #'arc-file-sources))
              ('org  (arc--reindex-directory-collection name (arc-collection-directory name)
                                                          #'arc-org-nodes))
              ('nixopt
               (mapcar (lambda (s) (prog1 (arc-source-upsert s) (arc-index-source s name)))
                       (let ((all (arc-nixopt-parse-json (arc-nixopt-options-json-path) "nix-option")))
                         (if arc-index-nixopt-cap (take arc-index-nixopt-cap all) all))))
              ('hmopt
               (mapcar (lambda (s) (prog1 (arc-source-upsert s) (arc-index-source s name)))
                       (let ((all (arc-nixopt-parse-json (arc-hm-options-json-path) "hm-option")))
                         (if arc-index-hmopt-cap (take arc-index-hmopt-cap all) all))))
              ('info
               (mapcar (lambda (s) (prog1 (arc-source-upsert s) (arc-index-source s name)))
                       (arc-info-sources
                        (arc--prioritize-manuals (arc-get-builtin-manuals)
                                                  arc-index-info-priority-manuals)
                        arc-index-info-cap))))))
      (if (eq kept arc--reindex-skipped)
          nil ; already reported by arc--reindex-directory-collection; nothing to prune
        (progn
          (message "arc: %s: %d source(s) indexed" name (length kept))
          (let ((removed (arc--prune-collection cid kept)))
            (when (> removed 0)
              (message "arc: %s: removed %d stale source(s)" name removed)))))))
  (message "arc: %S" (arc-index-stats)))

(provide 'arc-index)
;;; arc-index.el ends here
