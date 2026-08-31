;;; arc-source-org.el --- org-roam nodes as chunks -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Upstream indexed .org files as flat text, discarding ids, titles and
;; structure -- so an answer could never cite a node.  arc indexes by NODE:
;; a file with an ID property is one node, and every heading with an ID is
;; another, scoped to its own subtree.
;;
;; Nodes are parsed with `org-entry-get'/`org-map-entries', not
;; `org-roam-db', so the chunker works on any org tree and the tests need
;; no database.  Fixtures are read via `insert-file-contents' into a temp
;; buffer, which leaves `buffer-file-name' nil -- `org-map-entries' SCOPE
;; `file' silently visits zero entries in that case, since it resolves
;; that scope to `(list buffer-file-name)'.  SCOPE nil ("the current
;; buffer, respecting the restriction if any") is used instead, and is
;; correct here because the buffer is freshly widened.
;;
;; The directory walk never descends into a dot-directory (.git,
;; .stversions, and anything of that shape).  Syncthing keeps stale
;; historical copies of every note under .stversions, some of them still
;; carrying their live original's :ID: -- walked in unfiltered, those
;; duplicate ids make `[[id:...]]' citations ambiguous, which is exactly
;; the capability this file exists to deliver.
;;; Code:

(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'arc-chunk) ; arc-chunk-text, for oversized nodes -- see arc--org-node-chunks
(require 'arc-source-file) ; arc-file-hash, so a node carries its file's hash

(defun arc--org-file-keyword (key)
  "Return the value of #+KEY in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.*\\)$" (regexp-quote key)) nil t)
      (string-trim (match-string-no-properties 1)))))

(defun arc--org-filetags ()
  "Return #+filetags of the current buffer as a list of strings."
  (let ((raw (arc--org-file-keyword "filetags")))
    (and raw (split-string raw ":" t))))

(defun arc--org-node-chunks (text)
  "Return TEXT as a list of chunk plists, splitting it if it is oversized.
`arc-chunk-text' (arc-chunk.el) keeps a small node -- the overwhelming
majority -- as exactly one chunk, and only splits on paragraph
boundaries once TEXT exceeds `arc-chunk-size-ceiling'.  This matters
for org-roam nodes specifically: live notes as large as 436 KB have
been seen as a single node, and `nomic-embed-text' truncates far below
that, so the one chunk arc used to emit for an oversized node embedded
a vector describing only a couple of percent of its actual content."
  (arc-chunk-text text))

(defun arc--org-file-node (path)
  "Return the file-level node plist for PATH, or nil if it has no ID."
  (save-excursion
    (goto-char (point-min))
    (let ((id (org-entry-get (point-min) "ID")))
      (when id
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (list :kind "org-node" :org-id id :path path
                :title (or (arc--org-file-keyword "title")
                           (file-name-base path))
                :tags (arc--org-filetags)
                :hash (arc-file-hash path)
                :mtime (truncate (float-time
                                  (file-attribute-modification-time
                                   (file-attributes path))))
                :text text
                :chunks (arc--org-node-chunks text)))))))

(defun arc--org-heading-nodes (path)
  "Return node plists for every ID-carrying heading in the current buffer."
  (let (nodes)
    (org-map-entries
     (lambda ()
       (let ((id (org-entry-get (point) "ID")))
         (when id
           (let ((text (save-restriction
                         (org-narrow-to-subtree)
                         (buffer-substring-no-properties (point-min) (point-max)))))
             (push (list :kind "org-node" :org-id id :path path
                         :title (org-get-heading t t t t)
                         :tags (org-get-tags)
                         ;; The FILE's hash, deliberately, not the node's:
                         ;; `arc-file-changed-p' then works identically for
                         ;; org nodes and plain files, and one staleness rule
                         ;; beats two. A file edit marks all its nodes stale,
                         ;; which is correct -- any of them may have moved.
                         :hash (arc-file-hash path)
                         :mtime (truncate (float-time
                                           (file-attribute-modification-time
                                            (file-attributes path))))
                         :text text
                         :chunks (arc--org-node-chunks text))
                   nodes)))))
     nil nil)
    (nreverse nodes)))

(defun arc--org-not-dotdir-p (dir)
  "Return non-nil unless DIR is a dot-directory such as .git or .stversions.
Used as `directory-files-recursively''s descend predicate so state that
a tool hides in a dot-directory -- Syncthing's .stversions, .git, and
anything of that shape -- is never walked into, whatever its name is."
  (not (string-prefix-p "." (file-name-nondirectory (directory-file-name dir)))))

(defun arc-org-nodes-in-file (path)
  "Return node plists for the single org file PATH.
Factored out of `arc-org-nodes' so re-indexing one saved file parses it
exactly as a full walk does."
  (with-temp-buffer
    (insert-file-contents path)
    (let ((org-inhibit-startup t))
      (org-mode))
    (append (delq nil (list (arc--org-file-node path)))
            (arc--org-heading-nodes path))))

(defun arc-org-nodes (directory)
  "Return node plists for every org file under DIRECTORY.
Dot-directories (.git, .stversions, and the like) are never descended
into, so a stale or hidden copy of a note never shadows or duplicates
its live :org-id."
  (let (out)
    (dolist (path (directory-files-recursively
                   directory "\\.org\\'" nil #'arc--org-not-dotdir-p))
      (setq out (nconc out (arc-org-nodes-in-file path))))
    out))

(provide 'arc-source-org)
;;; arc-source-org.el ends here
