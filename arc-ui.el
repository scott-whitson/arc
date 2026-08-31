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
;; and that replacement is bounded by an end marker private to the one
;; answer it belongs to.  `arc-ui-begin-answer' returns a (START . END)
;; pair -- an opaque "answer handle" -- rather than setting a single
;; buffer-local marker: a buffer can (and does; `arc-ask' is fully async)
;; hold several answers streaming at once, and a shared buffer-local
;; marker meant every `arc-ui-begin-answer' call silently redirected every
;; earlier answer's in-flight writes into whichever answer began most
;; recently.  `arc-ui-render-sources' inserts the Sources subtree
;; immediately after its handle's END marker without moving it, so END
;; always separates "answer text streaming may still rewrite" from
;; "chrome appended after it" for that one answer -- a later
;; `arc-ui-stream-answer' call on the same handle can only ever delete
;; back to that boundary, never past it into an already-rendered Sources
;; subtree, and never anywhere near a different answer's boundary.

;;; Code:

(require 'org)
(require 'arc-source)
(require 'arc-scope)

(declare-function arc-index-stats-cached "arc-index")
(declare-function arc-ask "arc" (question &optional scope heading))
(declare-function arc-ask-vault "arc" (question))
(declare-function arc-ask-options "arc" (question))
(declare-function arc-toggle-chat-model "arc")

(defconst arc-ui-buffer-name "*arc*"
  "Name of the buffer arc renders answers into.")

(defvar arc-answer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'arc-ui-follow-citation)
    (define-key m (kbd "TAB") #'org-cycle)
    (define-key m (kbd "q")   #'arc-ui-quit)
    (define-key m (kbd "w")   #'arc-ui-capture)
    (define-key m (kbd "f")   #'arc-ui-follow-up)
    (define-key m (kbd "r")   #'arc-ui-reask)
    (define-key m (kbd "s")   #'arc-ui-change-scope)
    m)
  "Keymap for `arc-answer-mode'.
Acts on the answer at point.  Entry points live on the global `C-c i'
prefix instead.")

(define-derived-mode arc-answer-mode org-mode "arc"
  "Major mode for arc's answers.
Derived from `org-mode' so that citations are ordinary org links."
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq-local header-line-format '(:eval (arc-ui-header-line))))

(defvar-local arc-ui--last-question nil
  "The question most recently rendered into this answer buffer.
This is always the plain, one-line text that was actually rendered as
a heading -- for a follow-up, that is the follow-up line itself, never
the larger prompt `arc-ask' sends to the model on its behalf (see
`arc-ask''s HEADING argument).  Set by `arc-ask' as it renders.  The
re-ask (`r') and follow-up (`f') keys read this rather than the last
heading's text, so it must be kept current by anything that begins a
new answer.")

(defvar-local arc-ui--last-sources nil
  "The sources most recently retrieved for this answer buffer.
Set by `arc-ask' as it renders, alongside `arc-ui--last-question'.
Currently write-only: nothing yet reads it back.  It exists as a hook
for a later phase that grounds a follow-up in the same retrieval
without asking the index again, rather than (as today) always
retrieving afresh against the quoted answer-plus-follow-up text; that
is not phase 4, so treat this as reserved rather than dead.")

(defvar-local arc-ui--last-scope nil
  "The scope the most recent answer in this buffer was retrieved at.
Set by `arc-ask' as it renders, alongside `arc-ui--last-question'.
Read by `arc-ui-reask' and `arc-ui-follow-up', which pass it straight
back to `arc-ask' so re-asking or following up stays at whatever scope
the buffer is currently at, rather than silently falling back to
`arc-enabled-collections' -- passing nil here has never meant \"the
same scope again\", it means \"use the default\", so the last scope
this buffer actually used has to be threaded through explicitly.

A `rassoc' lookup against `arc-scope-presets' to offer a sensible
default to `completing-read' would still need exact structural
equality against a preset's plist, and would silently fall through --
with no default offered rather than an error -- for a scope built by
`arc-ask-vault', `arc-ask-options', or from a plain collection list,
none of which build a plist `equal' to any preset's; that use remains
unimplemented.")

(defun arc-ui-buffer ()
  "Return the arc answer buffer, creating it in `arc-answer-mode' if needed."
  (let ((buf (get-buffer-create arc-ui-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'arc-answer-mode)
        (arc-answer-mode)))
    buf))

(defun arc-ui-header-line ()
  "Return a one-line corpus summary for the answer buffer's header.
Reports size only.  Staleness needs the freshness tracking that phase 5
adds; until then this must not imply the corpus is current.  An index
that cannot be read reports that rather than signalling, because a
header line must never break the buffer it heads."
  (condition-case err
      (let* ((stats (arc-index-stats-cached))
             (total (apply #'+ (mapcar #'cdr stats))))
        (if (null stats)
            "arc · corpus empty — run M-x arc-reindex-all"
          (format "arc · %d chunks · %s"
                  total
                  (mapconcat (lambda (c) (format "%s %d" (car c) (cdr c)))
                             stats " · "))))
    (error (format "arc · corpus unavailable (%s)"
                   (error-message-string err)))))

(defun arc-ui-begin-answer (question)
  "Insert QUESTION as a heading and return a handle for the answer body.
The handle is a (START . END) marker pair private to this one answer;
`arc-ui-stream-answer' and `arc-ui-render-sources' take it as their
first argument.  Two answers begun in the same buffer -- `arc-ask' is
fully async, so the buffer stays focused and usable while an earlier
answer is still streaming -- each get their own pair, so writes to one
can never be misdirected into the other the way a single shared
buffer-local marker used to allow.

QUESTION becomes the heading text verbatim, so it must be a single
line: a `\\n' inside it inserts everything after the first line as
ordinary buffer text right below the heading, uncontrolled by anything
this function does.  If QUESTION happens to be, or quote, an earlier
answer's own `** question' heading and `*** Sources' subtree -- as a
naively-built follow-up prompt would -- that uncontrolled text is a
second, stale heading and a second, stale Sources subtree sitting
live under the new answer.  Signalling here catches that regardless of
which caller gets it wrong, rather than relying on every caller to
remember to keep its own text to one line; see `arc-ask''s HEADING
argument and `arc-ui-follow-up' for the caller this actually happened
to."
  (when (string-match-p "\n" question)
    (user-error "arc: a heading must be a single line, got: %S" question))
  (with-current-buffer (arc-ui-buffer)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "** %s\n\n" question))
    (let ((start (point-marker)))
      (set-marker-insertion-type start nil)
      (cons start (copy-marker start nil)))))

(defun arc-ui-stream-answer (answer text)
  "Replace the answer body belonging to ANSWER with TEXT.
ANSWER is the (START . END) handle `arc-ui-begin-answer' returned for
this one answer.  Streaming providers hand back the whole accumulated
string each time, so this replaces rather than appends -- appending
would repeat every prefix.

The deletion is bounded by ANSWER's own END marker rather than
`point-max', so it can never reach into a Sources subtree a prior
`arc-ui-render-sources' call already appended below the answer, and --
since END belongs to this ANSWER alone, not to the buffer as a whole --
it can never reach into a different answer's text either, no matter
how many other answers have begun or completed in this buffer since."
  (let ((start (car answer)) (end (cdr answer)))
    (with-current-buffer (marker-buffer start)
      (save-excursion
        (delete-region start end)
        (goto-char start)
        (insert text)
        (set-marker end (point))))))

(defun arc-ui-render-sources (answer sources)
  "Append a `*** Sources' subtree listing SOURCES as org links.
ANSWER is the handle `arc-ui-begin-answer' returned for the answer this
subtree belongs to; the subtree is inserted immediately after ANSWER's
own END marker.  Operates on ANSWER's buffer via `marker-buffer', the
same way `arc-ui-stream-answer' does, rather than `arc-ui-buffer' by
name, so the two can never target different buffers from each other.

END, having insertion type nil, does not advance past this insertion,
so it keeps pointing at the answer/Sources boundary afterwards, and a
later `arc-ui-stream-answer' call on this same ANSWER cannot delete
into it."
  (let ((end (cdr answer)))
    (with-current-buffer (marker-buffer end)
      (goto-char end)
      (unless (bolp) (insert "\n"))
      (insert (format "\n*** Sources                              [%d retrieved]\n"
                      (length sources)))
      (if (null sources)
          (insert "    (no sources retrieved)\n")
        (let ((n 0))
          (dolist (s sources)
            (setq n (1+ n))
            (insert (format "    %d. %s\n" n
                            (arc-source-link s (plist-get s :line-start))))))))))

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

(defcustom arc-ui-capture-function nil
  "Function called with the answer subtree as a string, or nil.
arc does not guess where your notes live.  Set this to something like
a wrapper around `org-capture' to file an answer.  While nil, the `w'
key reports that it is unconfigured rather than writing anywhere."
  :type '(choice (const :tag "Not configured" nil) function)
  :group 'arc)

(defun arc-ui-answer-at-point ()
  "Return the current answer subtree as a string, including its sources.
The answer buffer can hold several answers (`arc-ask' appends); this
walks up from point to the enclosing level-2 question heading before
narrowing, so it returns only the answer at point -- question, body
and its `Sources' subtree -- never the whole buffer or a neighbour."
  (save-excursion
    (save-restriction
      (widen)
      (org-back-to-heading t)
      (while (and (> (org-current-level) 2) (org-up-heading-safe)))
      (org-narrow-to-subtree)
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun arc-ui-capture ()
  "Send the answer at point to `arc-ui-capture-function'.
Signals a `user-error' instead of writing anywhere when that function
is unconfigured -- arc does not guess where your notes live."
  (interactive)
  (unless arc-ui-capture-function
    (user-error "arc: set `arc-ui-capture-function' to capture answers"))
  (funcall arc-ui-capture-function (arc-ui-answer-at-point)))

(defun arc-ui-reask ()
  "Ask the last question again, retrieving afresh.
Recovers from a bad sampling or a model swap without retyping.  Reasks
at `arc-ui--last-scope' -- the scope the buffer is currently at --
rather than `arc-ask''s default, so a question asked with `n' (the
vault) or moved to a different scope with `s' does not silently jump
back to `arc-enabled-collections' when re-asked."
  (interactive)
  (unless arc-ui--last-question
    (user-error "arc: no previous question to re-ask"))
  (arc-ask arc-ui--last-question arc-ui--last-scope))

(defun arc-ui-change-scope ()
  "Re-ask this buffer's last question at a different scope.
Deliberately re-asks `arc-ui--last-question' rather than the answer at
point: changing scope is a question about the same question, and
pairing one answer's text with a different scope's retrieval is the
confusion `f' and `r' already had to be kept apart to avoid."
  (interactive)
  (unless arc-ui--last-question
    (user-error "arc: no question asked in this buffer yet"))
  (let* ((name (completing-read
                (format "Re-ask %S at scope: "
                        (truncate-string-to-width arc-ui--last-question 40 nil nil t))
                (mapcar #'car arc-scope-presets) nil t))
         (scope (alist-get name arc-scope-presets nil nil #'equal)))
    (arc-ask arc-ui--last-question scope)))

(defun arc-ui-follow-up ()
  "Ask a follow-up, carrying the answer at point as context.
Reads the answer subtree at point (not necessarily the most recently
asked one -- a multi-answer buffer invites scrolling back to an
earlier answer before following up on it) via `arc-ui-answer-at-point'.
That subtree already opens with its own `** question' heading, so the
earlier question travels with the quoted text instead of being named
separately -- there is deliberately no second, independently-sourced
label for it that could name a different answer than the one quoted.

That quoted subtree -- heading, body and its own `*** Sources' subtree
included -- is folded into the text handed to the model as
`arc-ask''s QUESTION, never into what becomes this new answer's
heading: the follow-up's own one-line prompt is passed as `arc-ask''s
HEADING instead, so the buffer heading for this answer stays that one
line and the quoted structure never becomes live buffer content of its
own.

Retrieves at `arc-ui--last-scope', the same scope the buffer's last
answer used, for the same reason `arc-ui-reask' does: a bare nil here
would ask `arc-ask' for its default scope instead of staying at
whatever scope this buffer is actually following up within."
  (interactive)
  (unless arc-ui--last-question
    (user-error "arc: no answer to follow up on"))
  (let ((next (read-string "Follow up: "))
        (previous (arc-ui-answer-at-point)))
    (arc-ask (format "Earlier exchange:\n%s\n\nFollow-up: %s"
                     previous next)
             arc-ui--last-scope next)))

(require 'transient)

(transient-define-prefix arc-transient ()
  "arc."
  ["arc"
   ("i" "ask" arc-ask)
   ("n" "ask the vault" arc-ask-vault)
   ("o" "ask the options" arc-ask-options)
   ("m" "toggle chat model" arc-toggle-chat-model)
   ("r" "reindex" arc-reindex-all)
   ("c" "cancel reindex" arc-reindex-cancel)])

(provide 'arc-ui)
;;; arc-ui.el ends here
