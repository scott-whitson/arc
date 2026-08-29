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
;; `arc-reindex-all' below is the one caller of all four producers
;; (`arc-file-sources', `arc-org-nodes', `arc-nixopt-parse-json' and
;; `arc-info-sources'), so this file requires all four of their
;; defining libraries itself rather than relying on `arc.el', which
;; only happens to require two of them (for unrelated reasons of its
;; own) and never required `arc-source-org' or `arc-source-nixopt' at
;; all.
;;; Code:

(require 'llm)
(require 'arc-db)
(require 'arc-source)
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
    ;; data_embeddings and data_fts are virtual tables: they carry no foreign
    ;; key, so ON DELETE CASCADE never reaches them. Delete their rows by
    ;; rowid FIRST or reindexing accumulates orphan vectors and orphan FTS rows
    ;; forever, silently corrupting retrieval.
    (let ((ids (flatten-tree
                (sqlite-select (arc-db)
                               (format "SELECT id FROM data WHERE source_id = %d;" sid)))))
      (when ids
        (let ((idlist (arc-sqlite-format-int-list ids)))
          (sqlite-execute (arc-db) (format "DELETE FROM data_embeddings WHERE rowid IN %s;" idlist))
          (sqlite-execute (arc-db) (format "DELETE FROM data_fts WHERE rowid IN %s;" idlist)))))
    (sqlite-execute (arc-db) (format "DELETE FROM data WHERE source_id = %d;" sid))
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
    ("nix options" . nixopt) ("builtin manuals" . info))
  "Collections to build and the chunker each uses.
The hm-option entry is added by Task 12, which defines the path lookup it
needs; listing it here first would call an undefined function."
  :type '(alist :key-type string :value-type symbol) :group 'arc)

(defcustom arc-index-nixopt-cap nil
  "Maximum number of NixOS options to index, or nil for all of them.
options.json holds 24,661 options; embedding all of them is 20-40
minutes of sustained CPU/GPU.  Set this to a small number (e.g. 300)
to prove the ingestion path end-to-end without paying that cost, and
back to nil for a real full ingest."
  :type '(choice (const nil) natnum) :group 'arc)

(defcustom arc-index-info-cap 150
  "Maximum number of Info manual nodes to index, or nil for all of them.
`arc-get-builtin-manuals' names 94 manuals whose node counts add up to
far more than this; `arc-reindex-all' previously had no way to bound
this branch at all, so running it embedded every node in every manual
unconditionally.  This default keeps a verification run bounded the
same way `arc-index-nixopt-cap' does; set to nil for a real full
ingest."
  :type '(choice (const nil) natnum) :group 'arc)

;;;###autoload
(defun arc-reindex-all ()
  "Rebuild every collection in `arc-index-plan'.  Reports per-kind counts."
  (interactive)
  (dolist (cell arc-index-plan)
    (let ((name (car cell)))
      (message "arc: indexing %s" name)
      (pcase (cdr cell)
        ('file   (dolist (s (arc-file-sources (arc-collection-directory name)))
                   (arc-index-source s name)))
        ('org    (dolist (s (arc-org-nodes (arc-collection-directory name)))
                   (arc-index-source (plist-put s :chunks
                                                  (list (list :text (plist-get s :text)
                                                              :line-start 1 :line-end 1)))
                                       name)))
        ('nixopt (dolist (s (let ((all (arc-nixopt-parse-json (arc-nixopt-options-json-path) "nix-option")))
                              (if arc-index-nixopt-cap (take arc-index-nixopt-cap all) all)))
                   (arc-index-source (plist-put s :chunks
                                                  (list (list :text (plist-get s :text)
                                                              :line-start 1 :line-end 1)))
                                       name)))
        ('hmopt  (dolist (s (arc-nixopt-parse-json (arc-hm-options-json-path) "hm-option"))
                   (arc-index-source (plist-put s :chunks
                                                  (list (list :text (plist-get s :text)
                                                              :line-start 1 :line-end 1)))
                                       name)))
        ('info   (dolist (s (let ((all (arc-info-sources (arc-get-builtin-manuals))))
                              (if arc-index-info-cap (take arc-index-info-cap all) all)))
                   (arc-index-source s name))))))
  (message "arc: %S" (arc-index-stats)))

(provide 'arc-index)
;;; arc-index.el ends here
