;;; arc-source-info.el --- Info manuals as sources -*- lexical-binding: t; -*-
;; Copyright (C) 2024, 2025 Free Software Foundation, Inc.
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Changes:
;; The Info parser is ELISA's, moved here and rewritten: upstream's
;; `arc-parse-info-manual' opened a database connection and wrote each
;; node's chunks and embeddings directly (and stored the node name in a
;; generic `path' column, so a citation could not be rendered as an
;; [[info:]] link).  It is now a pure function that returns an alist of
;; (NODE . TEXT) for the caller to index -- the SQL it used to run is
;; Task 11's `arc-index-source' job -- and this file gives each node its
;; own identity via :info-node, which is what an [[info:]] link needs.
;; `arc--info-valid-p', `arc-get-builtin-manuals' and
;; `arc-get-external-manuals' are ELISA's, moved here unchanged.
;;; Code:

(require 'info)

(defcustom arc-find-executable find-program
  "Path to find executable."
  :type 'string :group 'arc)

(defun arc--info-valid-p (name)
  "Return NAME if info is valid."
  (with-temp-buffer
    (ignore-errors
      (info name (current-buffer))
      name)))

(defun arc-get-builtin-manuals ()
  "Get builtin manual names list."
  (mapcar
   #'file-name-base
   (cl-remove-if-not
    (lambda (s)
      (or (string-suffix-p ".info" s)
	  (string-suffix-p ".info.gz" s)))
    (directory-files (with-temp-buffer
		       (info "emacs" (current-buffer))
		       (file-name-directory Info-current-file))))))

(defun arc-get-external-manuals ()
  "Get external manual names list."
  (thread-last
    (process-lines
     arc-find-executable
     (file-truename (file-name-concat user-emacs-directory "elpa"))
     "-name" "*.info")
    (mapcar #'file-name-base)
    (seq-uniq)
    (mapcar #'arc--info-valid-p)
    (cl-remove-if #'not)))

(defun arc-parse-info-manual (name)
  "Return an alist of (NODE . TEXT) for every node in Info manual NAME.
Walks the manual with `Info-forward-node' starting at its Top node,
capturing each node's full text as a single entry.  Stops when moving
forward signals an error (the manual's end) or would revisit a node
already seen (a manual whose last `Info-forward-node' wraps back to
its start)."
  (with-temp-buffer
    (let (nodes (continue t))
      (ignore-errors
        (info name (current-buffer))
        (while continue
          (let ((node-name Info-current-node))
            (if (assoc node-name nodes)
                (setq continue nil)
              (push (cons node-name
                          (buffer-substring-no-properties (point-min) (point-max)))
                    nodes)
              (condition-case nil
                  (funcall-interactively #'Info-forward-node)
                (error (setq continue nil)))))))
      (nreverse nodes))))

(defun arc-info-sources (manuals &optional cap)
  "Return a source plist per node across MANUALS, a list of manual names.
Each plist has :kind, :info-node and :chunks.
With CAP, a positive integer, stop parsing further manuals as soon as
CAP sources have been produced, and return at most CAP of them: MANUALS
is walked one manual at a time rather than all 94 of them parsed into
memory up front and truncated afterwards, so a capped caller never
pays to parse a manual whose nodes would just be discarded.  CAP nil
(the default) parses every manual in MANUALS, same as before this
existed."
  (let (out)
    (catch 'arc-info-sources-done
      (dolist (manual manuals)
        (when (arc--info-valid-p manual)
          (pcase-dolist (`(,node . ,text) (arc-parse-info-manual manual))
            (push (list :kind "info"
                        :info-node (format "(%s)%s" manual node)
                        :chunks (list (list :text text :line-start 1 :line-end 1)))
                  out)
            (when (and cap (>= (length out) cap))
              (throw 'arc-info-sources-done nil))))))
    (let ((result (nreverse out)))
      (if cap (take cap result) result))))

(provide 'arc-source-info)
;;; arc-source-info.el ends here
