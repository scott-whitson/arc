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
;;
;; Streaming replaces the answer body in place (see `arc-ui-stream-answer'),
;; and that replacement is bounded by `arc-ui--stream-end', a private
;; buffer-local marker at the current end of the answer body.
;; `arc-ui-render-sources' inserts the Sources subtree immediately after
;; that same marker without moving it, so the marker always separates
;; "answer text streaming may still rewrite" from "chrome appended after
;; it" -- a later `arc-ui-stream-answer' call can only ever delete back to
;; that boundary, never past it into an already-rendered Sources subtree.

;;; Code:

(require 'org)
(require 'arc-source)

(defconst arc-ui-buffer-name "*arc*"
  "Name of the buffer arc renders answers into.")

(defvar arc-answer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'arc-ui-follow-citation)
    (define-key m (kbd "TAB") #'org-cycle)
    (define-key m (kbd "q")   #'arc-ui-quit)
    m)
  "Keymap for `arc-answer-mode'.
Acts on the answer at point.  Entry points live on the global `C-c i'
prefix instead.")

(define-derived-mode arc-answer-mode org-mode "arc"
  "Major mode for arc's answers.
Derived from `org-mode' so that citations are ordinary org links."
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t))

(defvar-local arc-ui--stream-end nil
  "Marker at the current end of the answer body being streamed.
Set fresh by every `arc-ui-begin-answer' call.  `arc-ui-stream-answer'
deletes only back to this marker (never past it), and
`arc-ui-render-sources' inserts immediately after it without moving
it -- so once a Sources subtree is rendered, a later stream call can
never reach far enough to delete it.")

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
      (setq arc-ui--stream-end (copy-marker m nil))
      m)))

(defun arc-ui-stream-answer (marker text)
  "Replace the answer body at MARKER with TEXT.
Streaming providers hand back the whole accumulated string each time,
so this replaces rather than appends -- appending would repeat every
prefix.

The deletion is bounded by `arc-ui--stream-end' rather than
`point-max', so it can never reach into a Sources subtree a prior
`arc-ui-render-sources' call already appended below the answer."
  (with-current-buffer (marker-buffer marker)
    (let ((end (or arc-ui--stream-end
                   (setq arc-ui--stream-end (copy-marker marker nil)))))
      (save-excursion
        (delete-region marker end)
        (goto-char marker)
        (insert text)
        (set-marker end (point))))))

(defun arc-ui-render-sources (sources)
  "Append a `*** Sources' subtree listing SOURCES as org links.
Inserted immediately after `arc-ui--stream-end' -- which, having
insertion type nil, does not advance past this insertion -- so the
marker keeps pointing at the answer/Sources boundary afterwards, and
a later `arc-ui-stream-answer' call cannot delete into it."
  (with-current-buffer (arc-ui-buffer)
    (goto-char (or arc-ui--stream-end (point-max)))
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

(defun arc-ui-follow-citation ()
  "Follow the citation link at point, if point is genuinely on one.
`org-open-at-point' resolves through `org-offer-links-in-entry' whenever
point falls anywhere inside a heading's entry -- which the answer body's
`** question' heading always does -- so, left unguarded, it can silently
jump to the one link elsewhere in the entry when there is exactly one, or
block on a link-selection prompt when there are several.  Requiring a
link at point first keeps this command inert everywhere except squarely
on a citation."
  (interactive)
  (if (org-in-regexp org-link-bracket-re)
      (org-open-at-point)
    (message "No citation at point")))

(defun arc-ui-quit ()
  "Bury the arc answer buffer."
  (interactive)
  (quit-window))

(require 'transient)

(transient-define-prefix arc-transient ()
  "arc."
  ["arc"
   ("i" "ask" arc-ask)
   ("r" "reindex" arc-reindex-all)
   ("c" "cancel reindex" arc-reindex-cancel)])

(provide 'arc-ui)
;;; arc-ui.el ends here
