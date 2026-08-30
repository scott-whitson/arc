;;; arc-ui.el --- the arc answer buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The answer buffer derives from `org-mode', which is the whole trick: a
;; citation is a real org link, so jumping to it needs no navigation code of
;; arc's own.  file, info and id links are org's; nixopt: and hmopt: are
;; registered by `arc-source.el'.
;;
;; The major mode is `arc-answer-mode'.  It is deliberately NOT called
;; `arc-mode': that is a built-in Emacs library (archive support), and
;; shadowing its feature symbol would make `(require 'arc-mode)' load the
;; wrong thing silently.

;;; Code:

(require 'org)
(require 'arc-source)

(defconst arc-ui-buffer-name "*arc*"
  "Name of the buffer arc renders answers into.")

(define-derived-mode arc-answer-mode org-mode "arc"
  "Major mode for arc's answers.
Derived from `org-mode' so that citations are ordinary org links."
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t))

(defun arc-ui-buffer ()
  "Return the arc answer buffer, creating it in `arc-answer-mode' if needed."
  (let ((buf (get-buffer-create arc-ui-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'arc-answer-mode)
        (arc-answer-mode)))
    buf))

(defun arc-ui-begin-answer (question)
  "Insert QUESTION as a heading and return a marker for the answer body.
The marker is where `arc-ui-stream-answer' replaces text as it arrives."
  (with-current-buffer (arc-ui-buffer)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "** %s\n\n" question))
    (let ((m (point-marker)))
      (set-marker-insertion-type m nil)
      m)))

(defun arc-ui-stream-answer (marker text)
  "Replace the answer body at MARKER with TEXT.
Streaming providers hand back the whole accumulated string each time,
so this replaces rather than appends -- appending would repeat every
prefix."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (goto-char marker)
      (delete-region marker (point-max))
      (insert text))))

(defun arc-ui-render-sources (sources)
  "Append a `*** Sources' subtree listing SOURCES as org links."
  (with-current-buffer (arc-ui-buffer)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "\n*** Sources                              [%d retrieved]\n"
                    (length sources)))
    (if (null sources)
        (insert "    (no sources retrieved)\n")
      (let ((n 0))
        (dolist (s sources)
          (setq n (1+ n))
          (insert (format "    %d. %s\n" n
                          (arc-source-link s (plist-get s :line-start)))))))))

(provide 'arc-ui)
;;; arc-ui.el ends here
