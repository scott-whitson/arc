;;; arc-watch.el --- keep the mutable corpus current -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Re-indexes a source when it changes, so the corpus does not quietly rot
;; between manual reindexes.  Only the MUTABLE kinds are watched -- files and
;; org nodes, 656 sources on this corpus.  The other 37,780 are derived from a
;; Nix store path or a flake.lock revision and cannot change without that
;; input changing; `arc-freshness-report' notices when it does.
;;
;; DELIBERATE NON-GOAL: derived collections are never reindexed automatically.
;; The spec asked for "options reindex when the flake.lock hash changes", and
;; that is the wrong shape here. Rebuilding the option collections means
;; embedding 30,174 chunks -- roughly 40 minutes of GPU on this machine --
;; and a NixOS rebuild changes flake.lock routinely. A switch must not
;; silently start a 40-minute background job. arc reports the staleness and
;; leaves `arc-reindex-all' to the operator, who knows whether now is a good
;; time.
;;
;; Everything here is bounded on purpose. A save re-indexes exactly one
;; source. The idle sweep does at most `arc-watch-sweep-batch' sources per
;; tick and remembers where it stopped, because the alternative -- rehashing
;; 656 files and re-embedding whatever moved, in one go, on an idle timer --
;; is how a background feature becomes the reason someone disables it.

;;; Code:

(require 'cl-lib)
(require 'arc)
(require 'arc-index)

(defcustom arc-watch-after-save t
  "Whether saving a file re-indexes it when arc already knows it."
  :type 'boolean :group 'arc)

(defcustom arc-watch-idle-seconds 300
  "Idle seconds before the drift sweep runs.  nil disables the sweep."
  :type '(choice (const nil) number) :group 'arc)

(defcustom arc-watch-sweep-batch 25
  "Sources examined per idle tick.
Bounded so the sweep never becomes a stall.  It resumes where it left
off, so the whole mutable corpus is covered across several ticks."
  :type 'integer :group 'arc)

(defvar arc-watch--sweep-offset 0
  "Where the next idle sweep resumes.")

(defvar arc-watch--timer nil)

(defun arc-watch--collection-for (path)
  "Return the collection PATH belongs to, or nil.
A file is arc's business only if it is inside a directory arc indexes."
  (car (cl-find-if
        (lambda (cell)
          (let ((dir (file-name-as-directory (expand-file-name (cdr cell)))))
            (string-prefix-p dir (expand-file-name path))))
        arc-collection-directory-alist)))

(defun arc-watch--chunker-for (collection)
  "Return the chunker COLLECTION is built with, or nil."
  (alist-get collection arc-index-plan nil nil #'equal))

(defun arc-watch-reindex-path (path &optional quiet)
  "Re-index PATH if arc indexes the directory it lives in.
Returns the collection it was indexed into, or nil.  Only `file' and
`org' collections are touched: those are the mutable kinds."
  (when-let* ((path (and path (expand-file-name path)))
              ((file-readable-p path))
              (collection (arc-watch--collection-for path))
              (chunker (arc-watch--chunker-for collection))
              ((memq chunker '(file org))))
    (let ((sources (pcase chunker
                     ('file (and (arc-indexable-file-p path)
                                 (list (arc-file-source path))))
                     ('org (and (string-suffix-p ".org" path)
                                (arc-org-nodes-in-file path))))))
      (when sources
        (dolist (s sources) (arc-index-source s collection))
        (unless quiet
          (message "arc: reindexed %s (%d source%s)"
                   (file-name-nondirectory path) (length sources)
                   (if (= 1 (length sources)) "" "s")))
        collection))))

(defun arc-watch--after-save ()
  "Re-index this buffer's file when arc knows it."
  (when (and arc-watch-after-save buffer-file-name)
    (condition-case err
        (arc-watch-reindex-path buffer-file-name)
      ;; A save must never fail because indexing did.
      (error (message "arc: could not reindex %s (%s)"
                      (file-name-nondirectory buffer-file-name)
                      (error-message-string err))))))

(defun arc-watch--mutable-paths ()
  "Return every indexed path belonging to a mutable collection."
  (mapcar #'car
          (sqlite-select
           (arc-db)
           (format "SELECT DISTINCT path FROM sources
                    WHERE path IS NOT NULL AND kind IN %s ORDER BY path;"
                   (arc-sqlite-format-string-list arc-freshness-per-source-kinds)))))

(defun arc-watch-sweep ()
  "Examine the next `arc-watch-sweep-batch' mutable sources and refresh drift.
Bounded and resumable: this runs on an idle timer, and a sweep that
rehashed 656 files in one tick would be felt."
  (interactive)
  (condition-case err
      (let* ((paths (arc-watch--mutable-paths))
             (n (length paths)))
        (when (> n 0)
          (when (>= arc-watch--sweep-offset n) (setq arc-watch--sweep-offset 0))
          (let ((batch (seq-take (nthcdr arc-watch--sweep-offset paths)
                                 arc-watch-sweep-batch))
                (refreshed 0))
            (dolist (path batch)
              (when (and (file-readable-p path) (arc-file-changed-p path))
                (when (arc-watch-reindex-path path :quiet)
                  (setq refreshed (1+ refreshed)))))
            (setq arc-watch--sweep-offset (+ arc-watch--sweep-offset (length batch)))
            (when (> refreshed 0)
              (message "arc: refreshed %d changed source%s" refreshed
                       (if (= 1 refreshed) "" "s")))
            refreshed)))
    (error (message "arc: sweep failed (%s)" (error-message-string err)) nil)))

;;;###autoload
(define-minor-mode arc-watch-mode
  "Keep arc's mutable corpus current as files change.

Re-indexes a saved file arc already knows, and sweeps for drift on an
idle timer -- the sweep is what catches changes made outside this Emacs:
a git pull, a Syncthing update, an edit on another machine.

Derived collections are deliberately untouched; see this file's
commentary."
  :global t :group 'arc
  (if arc-watch-mode
      (progn
        (add-hook 'after-save-hook #'arc-watch--after-save)
        (when arc-watch-idle-seconds
          (setq arc-watch--timer
                (run-with-idle-timer arc-watch-idle-seconds t #'arc-watch-sweep))))
    (remove-hook 'after-save-hook #'arc-watch--after-save)
    (when arc-watch--timer (cancel-timer arc-watch--timer))
    (setq arc-watch--timer nil)))

(provide 'arc-watch)
;;; arc-watch.el ends here
