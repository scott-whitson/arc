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
;;; Code:

(require 'org)
(require 'org-element)
(require 'subr-x)

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

(defun arc--org-file-node (path)
  "Return the file-level node plist for PATH, or nil if it has no ID."
  (save-excursion
    (goto-char (point-min))
    (let ((id (org-entry-get (point-min) "ID")))
      (when id
        (list :kind "org-node" :org-id id :path path
              :title (or (arc--org-file-keyword "title")
                         (file-name-base path))
              :tags (arc--org-filetags)
              :text (buffer-substring-no-properties (point-min) (point-max)))))))

(defun arc--org-heading-nodes (path)
  "Return node plists for every ID-carrying heading in the current buffer."
  (let (nodes)
    (org-map-entries
     (lambda ()
       (let ((id (org-entry-get (point) "ID")))
         (when id
           (push (list :kind "org-node" :org-id id :path path
                       :title (org-get-heading t t t t)
                       :tags (org-get-tags)
                       :text (save-restriction
                               (org-narrow-to-subtree)
                               (buffer-substring-no-properties (point-min) (point-max))))
                 nodes))))
     nil nil)
    (nreverse nodes)))

(defun arc-org-nodes (directory)
  "Return node plists for every org file under DIRECTORY."
  (let (out)
    (dolist (path (directory-files-recursively directory "\\.org\\'"))
      (with-temp-buffer
        (insert-file-contents path)
        (let ((org-inhibit-startup t))
          (org-mode))
        (setq out (nconc out
                         (delq nil (list (arc--org-file-node path)))
                         (arc--org-heading-nodes path)))))
    out))

(provide 'arc-source-org)
;;; arc-source-org.el ends here
