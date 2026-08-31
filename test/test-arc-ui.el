;;; test-arc-ui.el --- the answer buffer -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar aui-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aui-root)
(require 'arc-ui)

(defmacro aui-with-fresh-buffer (&rest body)
  "Run BODY in a freshly emptied *arc* buffer."
  `(let ((buf (arc-ui-buffer)))
     (unwind-protect
         (with-current-buffer buf
           (let ((inhibit-read-only t)) (erase-buffer))
           ,@body)
       (kill-buffer buf))))

(ert-deftest aui-mode-derives-from-org ()
  (aui-with-fresh-buffer
   (should (eq major-mode 'arc-answer-mode))
   (should (provided-mode-derived-p major-mode 'org-mode))))

(ert-deftest aui-never-defines-a-mode-called-arc-mode ()
  (should-not (fboundp 'arc-mode))
  (should-not (featurep 'arc-mode-shadow)))

(ert-deftest aui-question-is-a-second-level-heading ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "how do I enable syncthing?")
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\* how do I enable syncthing\\?$" nil t))))

(ert-deftest aui-streaming-replaces-rather-than-appends ()
  ;; A realistic growing-partial sequence (four chunks, not two), asserting
  ;; exact equality on the answer body -- not just "the final text is
  ;; present somewhere", which a stray append could also satisfy.  Nothing
  ;; is rendered after the answer in this test, so the region from the
  ;; marker to `point-max' *is* the whole answer body.
  (aui-with-fresh-buffer
   (let ((m (arc-ui-begin-answer "q")))
     (arc-ui-stream-answer m "Sync")
     (arc-ui-stream-answer m "Syncthing en")
     (arc-ui-stream-answer m "Syncthing enables")
     (arc-ui-stream-answer m "Syncthing enables real-time file sync.")
     (should (string= (buffer-substring-no-properties (car m) (point-max))
                      "Syncthing enables real-time file sync.")))))

(ert-deftest aui-sources-render-as-org-links ()
  (aui-with-fresh-buffer
   (let ((a (arc-ui-begin-answer "q")))
     (arc-ui-render-sources
      a
      (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")
            '(:kind "nix-option" :option-name "services.foo.enable" :chunk "b"))))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\*\\* Sources" nil t))
   (goto-char (point-min))
   (should (search-forward "[[file:/tmp/x.nix::12]]" nil t))
   (goto-char (point-min))
   (should (search-forward "[[nixopt:services.foo.enable]]" nil t))))

(ert-deftest aui-rendered-links-are-parseable-by-org ()
  (aui-with-fresh-buffer
   (let ((a (arc-ui-begin-answer "q")))
     (arc-ui-render-sources
      a (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b"))))
   (goto-char (point-min))
   (should (re-search-forward org-link-bracket-re nil t))))

(ert-deftest aui-no-sources-says-so-rather-than-rendering-an-empty-subtree ()
  (aui-with-fresh-buffer
   (let ((a (arc-ui-begin-answer "q")))
     (arc-ui-render-sources a nil))
   (goto-char (point-min))
   (should (re-search-forward "no sources" nil t))))

(ert-deftest aui-streaming-after-sources-does-not-eat-them ()
  ;; Task 8's follow-up shape: begin, stream twice, render sources, then
  ;; stream *again* on the same marker.  The final stream must replace only
  ;; the stale answer text -- the Sources subtree rendered in between must
  ;; survive untouched.
  (aui-with-fresh-buffer
   (let ((m (arc-ui-begin-answer "q4")))
     (arc-ui-stream-answer m "partial")
     (arc-ui-stream-answer m "partial answer")
     (arc-ui-render-sources
      m (list '(:kind "nix-option" :option-name "a.b.c" :chunk "b")))
     (arc-ui-stream-answer m "final full answer")
     (goto-char (point-min))
     (should (search-forward "final full answer" nil t))
     (goto-char (point-min))
     (should-not (search-forward "partial answer" nil t))
     (goto-char (point-min))
     (should (re-search-forward "^\\*\\*\\* Sources" nil t))
     (goto-char (point-min))
     (should (search-forward "[[nixopt:a.b.c]]" nil t)))))

(ert-deftest aui-concurrent-answers-do-not-share-a-stream-end-marker ()
  ;; Critical 1's reproduction: two answers begin in the same buffer while
  ;; the first is still streaming (arc-ask is fully async and the buffer
  ;; stays focused and usable throughout, so this is an ordinary sequence
  ;; of events, not a contrived race).  Before the fix, `arc-ui-begin-
  ;; answer' reset a single buffer-local `arc-ui--stream-end', so every
  ;; write keyed off answer 1's marker actually used answer 2's end
  ;; boundary once answer 2 began -- reproduced live as one destroyed
  ;; question heading, one destroyed answer body, and two `*** Sources'
  ;; subtrees left under a single question in reverse order.  This proves
  ;; each answer's writes stay bounded to that answer alone under
  ;; exactly that interleaving: a late partial for answer 1 arriving
  ;; after answer 2 has already begun.
  (aui-with-fresh-buffer
   (let ((a1 (arc-ui-begin-answer "question one")))
     (arc-ui-stream-answer a1 "partial one")
     (let ((a2 (arc-ui-begin-answer "question two")))
       (arc-ui-stream-answer a2 "partial two")
       ;; the late partial: answer 1 is written to again after answer 2
       ;; has already begun streaming
       (arc-ui-stream-answer a1 "final answer one")
       (arc-ui-render-sources
        a1 (list '(:kind "file" :path "/tmp/a.nix" :line-start 1 :chunk "b")))
       (arc-ui-stream-answer a2 "final answer two")
       (arc-ui-render-sources
        a2 (list '(:kind "file" :path "/tmp/b.nix" :line-start 2 :chunk "b")))))
   ;; both headings intact, in order
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\* question one$" nil t))
   (should (search-forward "final answer one" nil t))
   (should (re-search-forward "^\\*\\*\\* Sources" nil t))
   (should (search-forward "[[file:/tmp/a.nix::1]]" nil t))
   (should (re-search-forward "^\\*\\* question two$" nil t))
   (should (search-forward "final answer two" nil t))
   (should (re-search-forward "^\\*\\*\\* Sources" nil t))
   (should (search-forward "[[file:/tmp/b.nix::2]]" nil t))
   ;; exactly one Sources subtree per answer -- not two under one, and
   ;; not reversed
   (goto-char (point-min))
   (let ((count 0))
     (while (re-search-forward "^\\*\\*\\* Sources" nil t)
       (setq count (1+ count)))
     (should (= count 2)))
   ;; neither answer's stale partial text survived
   (goto-char (point-min))
   (should-not (search-forward "partial one" nil t))
   (goto-char (point-min))
   (should-not (search-forward "partial two" nil t))))

(ert-deftest aui-mode-map-binds-the-documented-keys ()
  (dolist (cell '(("q" . arc-ui-quit)
                  ("TAB" . org-cycle)
                  ("RET" . arc-ui-follow-citation)))
    (should (eq (lookup-key arc-answer-mode-map (kbd (car cell))) (cdr cell)))))

(ert-deftest aui-ret-follows-a-citation-through-the-keymap ()
  ;; The equality check above catches RET being unbound; this exercises
  ;; it the way a user actually would -- dispatching through the keymap
  ;; binding itself, not by calling `arc-ui-follow-citation' directly the
  ;; way the other citation tests do (which would keep passing even if
  ;; RET were unbound).
  (aui-with-fresh-buffer
   (let ((a (arc-ui-begin-answer "q")))
     (arc-ui-render-sources
      a (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b"))))
   (goto-char (point-min))
   (should (re-search-forward org-link-bracket-re nil t))
   (goto-char (match-beginning 0))
   (let ((called nil))
     (cl-letf (((symbol-function 'org-open-at-point)
                (lambda (&rest _) (setq called t))))
       (call-interactively (lookup-key arc-answer-mode-map (kbd "RET"))))
     (should called))))

(ert-deftest aui-mode-map-keys-are-all-real-commands ()
  (map-keymap
   (lambda (_key def)
     (when (symbolp def)
       (should (commandp def))))
   arc-answer-mode-map))

(ert-deftest aui-transient-is-defined-and-is-a-command ()
  (should (fboundp 'arc-transient))
  (should (commandp 'arc-transient)))

(ert-deftest aui-follow-citation-is-org-open-at-point ()
  (aui-with-fresh-buffer
   (let ((a (arc-ui-begin-answer "q")))
     (arc-ui-render-sources
      a (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b"))))
   (goto-char (point-min))
   (should (re-search-forward org-link-bracket-re nil t))
   (goto-char (match-beginning 0))
   (let ((called nil))
     (cl-letf (((symbol-function 'org-open-at-point)
                (lambda (&rest _) (setq called t))))
       (arc-ui-follow-citation))
     (should called))))

(ert-deftest aui-follow-citation-does-nothing-off-a-link ()
  ;; Point on ordinary answer prose, no link there, but a link does exist
  ;; elsewhere in the entry (the rendered Sources citation).
  (aui-with-fresh-buffer
   (let ((m (arc-ui-begin-answer "q")))
     (arc-ui-stream-answer m "plain answer text, no links here")
     (arc-ui-render-sources
      m (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b"))))
   (goto-char (point-min))
   (should (search-forward "plain answer text" nil t))
   (goto-char (match-beginning 0))
   (let ((called nil))
     (cl-letf (((symbol-function 'org-open-at-point)
                (lambda (&rest _) (setq called t))))
       (arc-ui-follow-citation))
     (should-not called))))

(ert-deftest aui-follow-citation-does-nothing-on-the-sources-header-line ()
  ;; This is the reproduction of the silent-jump bug: exactly one link in
  ;; the entry (the single rendered citation), and point on a non-link
  ;; line inside the Sources subtree -- the header line itself.  Left
  ;; unguarded, `org-open-at-point' resolves this via
  ;; `org-offer-links-in-entry' and silently follows that one link even
  ;; though point is nowhere near it.
  (aui-with-fresh-buffer
   (let ((a (arc-ui-begin-answer "q")))
     (arc-ui-render-sources
      a (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b"))))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\*\\* Sources" nil t))
   (goto-char (match-beginning 0))
   (let ((called nil))
     (cl-letf (((symbol-function 'org-open-at-point)
                (lambda (&rest _) (setq called t))))
       (arc-ui-follow-citation))
     (should-not called))))

(ert-deftest aui-quit-calls-quit-window ()
  (aui-with-fresh-buffer
   (let ((called nil))
     (cl-letf (((symbol-function 'quit-window)
                (lambda (&rest _) (setq called t))))
       (arc-ui-quit))
     (should called))))

(ert-deftest aui-mode-installs-the-header-line ()
  ;; The tests below call `arc-ui-header-line' directly, so none of them
  ;; would notice `header-line-format' being set to nil in
  ;; `arc-answer-mode' itself; this checks the mode actually wires it up.
  (aui-with-fresh-buffer
   (should (equal header-line-format '(:eval (arc-ui-header-line))))))

(ert-deftest aui-header-line-summarises-the-corpus ()
  (cl-letf (((symbol-function 'arc-index-stats)
             (lambda () '(("file" . 6427) ("org-node" . 428)))))
    (let ((h (arc-ui-header-line)))
      (should (string-match-p "6855" h))
      (should (string-match-p "file" h))
      (should (string-match-p "org-node" h)))))

(ert-deftest aui-header-line-survives-an-empty-corpus ()
  (cl-letf (((symbol-function 'arc-index-stats) (lambda () nil)))
    (should (stringp (arc-ui-header-line)))))

(ert-deftest aui-header-line-survives-an-unreadable-index ()
  (cl-letf (((symbol-function 'arc-index-stats)
             (lambda () (error "no database"))))
    (should (stringp (arc-ui-header-line)))))

(ert-deftest aui-arc-ask-is-an-interactive-command ()
  (require 'arc)
  (should (commandp 'arc-ask)))

(ert-deftest aui-arc-ask-renders-question-answer-and-sources ()
  (require 'arc)
  (aui-with-fresh-buffer
   (cl-letf (((symbol-function 'arc-find-similar)
              (lambda (_text _cols on-done &optional _on-error) (funcall on-done 'QUERY)))
             ((symbol-function 'arc--retrieve-ids)
              (lambda (_query _prompt) '(1)))
             ((symbol-function 'arc--retrieve-rows)
              (lambda (_ids)
                '(("file" "/tmp/x.nix" nil nil nil "chunk body" 12 20 nil))))
             ((symbol-function 'arc-answer-request)
              (lambda (_q _s on-partial on-done _on-error)
                (funcall on-partial "Because")
                (funcall on-done "Because 8385."))))
     (arc-ask "why 8385?"))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\* why 8385\\?$" nil t))
   (goto-char (point-min))
   (should (search-forward "Because 8385." nil t))
   (goto-char (point-min))
   (should (search-forward "[[file:/tmp/x.nix::12]]" nil t))))

(ert-deftest aui-arc-ask-sets-buffer-local-last-question-and-sources ()
  ;; Task 8 reads `arc-ui--last-question' and `arc-ui--last-sources' for
  ;; its `r' (re-ask) and `f' (follow-up) keys.  If `arc-ask' does not set
  ;; them, those keys would only ever work in tests that seed the
  ;; variables by hand -- this proves the real entry point sets them.
  (require 'arc)
  (aui-with-fresh-buffer
   (cl-letf (((symbol-function 'arc-find-similar)
              (lambda (_text _cols on-done &optional _on-error) (funcall on-done 'QUERY)))
             ((symbol-function 'arc--retrieve-ids)
              (lambda (_query _prompt) '(1)))
             ((symbol-function 'arc--retrieve-rows)
              (lambda (_ids)
                '(("file" "/tmp/x.nix" nil nil nil "chunk body" 12 20 nil))))
             ((symbol-function 'arc-answer-request)
              (lambda (_q _s on-partial on-done _on-error)
                (funcall on-partial "Because")
                (funcall on-done "Because 8385."))))
     (arc-ask "why 8385?"))
   (should (equal arc-ui--last-question "why 8385?"))
   (should (= (length arc-ui--last-sources) 1))
   (should (equal (plist-get (car arc-ui--last-sources) :path) "/tmp/x.nix"))))

(ert-deftest aui-arc-ask-model-failure-renders-into-the-buffer ()
  ;; The on-error callback `arc-ask' hands to `arc-answer-request' had no
  ;; test at all covering it -- a mutation reducing it to a no-op
  ;; survived.  This calls that callback directly, the way a real model
  ;; failure would, and checks the buffer says so.
  (require 'arc)
  (aui-with-fresh-buffer
   (cl-letf (((symbol-function 'arc-find-similar)
              (lambda (_text _cols on-done &optional _on-error) (funcall on-done 'QUERY)))
             ((symbol-function 'arc--retrieve-ids)
              (lambda (_query _prompt) '(1)))
             ((symbol-function 'arc--retrieve-rows)
              (lambda (_ids)
                '(("file" "/tmp/x.nix" nil nil nil "chunk body" 12 20 nil))))
             ((symbol-function 'arc-answer-request)
              (lambda (_q _s _on-partial _on-done on-error)
                (funcall on-error 'error "connection refused"))))
     (arc-ask "why 8385?"))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\* why 8385\\?$" nil t))
   (goto-char (point-min))
   (should (search-forward "arc: request failed: connection refused" nil t))))

(ert-deftest aui-arc-ask-renders-a-buffer-when-retrieval-fails ()
  ;; Important 5: an unreachable embedding endpoint (or any retrieval
  ;; failure) previously produced no `*arc*' buffer at all -- the only
  ;; signal was an unhandled process-sentinel error.  Retrieval failure
  ;; now gets the same treatment as model failure: a buffer, and a
  ;; message in it saying what failed.
  (require 'arc)
  (aui-with-fresh-buffer
   (cl-letf (((symbol-function 'arc-find-similar)
              (lambda (_text _cols _on-done on-error)
                (funcall on-error 'error "connection refused"))))
     (arc-ask "why 8385?"))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\* why 8385\\?$" nil t))
   (goto-char (point-min))
   (should (search-forward "arc: retrieval failed: connection refused" nil t))
   (should (equal arc-ui--last-question "why 8385?"))
   (should (null arc-ui--last-sources))))

(ert-deftest aui-capture-is-bound-and-a-command ()
  (should (eq (lookup-key arc-answer-mode-map (kbd "w")) 'arc-ui-capture))
  (should (commandp 'arc-ui-capture)))

(ert-deftest aui-capture-passes-the-answer-subtree-to-the-configured-function ()
  (aui-with-fresh-buffer
   (let ((a (arc-ui-begin-answer "why 8385?")))
     (arc-ui-stream-answer a "Because 8385.")
     (arc-ui-render-sources
      a (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b"))))
   (let ((got nil))
     (let ((arc-ui-capture-function (lambda (text) (setq got text))))
       (goto-char (point-min))
       (arc-ui-capture))
     (should (string-match-p "why 8385\\?" got))
     (should (string-match-p "Because 8385\\." got))
     (should (string-match-p "\\[\\[file:/tmp/x\\.nix::12\\]\\]" got)))))

(ert-deftest aui-capture-sends-only-the-answer-at-point-not-the-whole-buffer ()
  ;; Regression for `arc-ui-capture' wired to `(buffer-string)' instead of
  ;; `(arc-ui-answer-at-point)': on a single-answer buffer the two happen
  ;; to be equal and that mistake is invisible, which is exactly the gap
  ;; the whole-branch review found -- three answers, capturing the middle
  ;; one, is the smallest buffer that can actually catch it.
  (aui-with-fresh-buffer
   (let ((a1 (arc-ui-begin-answer "q1")))
     (arc-ui-stream-answer a1 "answer one")
     (arc-ui-render-sources
      a1 (list '(:kind "file" :path "/tmp/a.nix" :line-start 1 :chunk "b"))))
   (let ((a2 (arc-ui-begin-answer "q2")))
     (arc-ui-stream-answer a2 "answer two")
     (arc-ui-render-sources
      a2 (list '(:kind "file" :path "/tmp/b.nix" :line-start 2 :chunk "b"))))
   (let ((a3 (arc-ui-begin-answer "q3")))
     (arc-ui-stream-answer a3 "answer three")
     (arc-ui-render-sources
      a3 (list '(:kind "file" :path "/tmp/c.nix" :line-start 3 :chunk "b"))))
   (goto-char (point-min))
   (should (search-forward "answer two" nil t))
   (let ((got nil))
     (let ((arc-ui-capture-function (lambda (text) (setq got text))))
       (arc-ui-capture))
     (should (string-match-p "q2" got))
     (should (string-match-p "answer two" got))
     (should (string-match-p "/tmp/b\\.nix" got))
     (should-not (string-match-p "q1" got))
     (should-not (string-match-p "q3" got))
     (should-not (string-match-p "answer one" got))
     (should-not (string-match-p "answer three" got))
     (should-not (string-match-p "/tmp/a\\.nix" got))
     (should-not (string-match-p "/tmp/c\\.nix" got)))))

(ert-deftest aui-capture-without-a-configured-function-says-so ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (let ((arc-ui-capture-function nil))
     (goto-char (point-min))
     (should-error (arc-ui-capture) :type 'user-error))))

(ert-deftest aui-answer-at-point-picks-the-answer-at-point-in-a-multi-answer-buffer ()
  ;; Three answers appended to the same buffer (Task 6's `arc-ask' appends).
  ;; Point lands inside the *second* answer's Sources subtree -- the exact
  ;; case the brief calls out -- and `arc-ui-answer-at-point' must return
  ;; only that answer's subtree, not the whole buffer and not a neighbour.
  (aui-with-fresh-buffer
   (let ((m1 (arc-ui-begin-answer "q1")))
     (arc-ui-stream-answer m1 "answer one")
     (arc-ui-render-sources
      m1 (list '(:kind "file" :path "/tmp/a.nix" :line-start 1 :chunk "b"))))
   (let ((m2 (arc-ui-begin-answer "q2")))
     (arc-ui-stream-answer m2 "answer two")
     (arc-ui-render-sources
      m2 (list '(:kind "file" :path "/tmp/b.nix" :line-start 2 :chunk "b"))))
   (let ((m3 (arc-ui-begin-answer "q3")))
     (arc-ui-stream-answer m3 "answer three")
     (arc-ui-render-sources
      m3 (list '(:kind "file" :path "/tmp/c.nix" :line-start 3 :chunk "b"))))
   (goto-char (point-min))
   (should (search-forward "answer two" nil t))
   (should (re-search-forward "^\\*\\*\\* Sources" nil t))
   (let ((got (arc-ui-answer-at-point)))
     (should (string-match-p "q2" got))
     (should (string-match-p "answer two" got))
     (should (string-match-p "/tmp/b\\.nix" got))
     (should-not (string-match-p "answer one" got))
     (should-not (string-match-p "answer three" got))
     (should-not (string-match-p "/tmp/a\\.nix" got))
     (should-not (string-match-p "/tmp/c\\.nix" got)))))

(ert-deftest aui-follow-up-and-reask-are-bound-commands ()
  (should (eq (lookup-key arc-answer-mode-map (kbd "f")) 'arc-ui-follow-up))
  (should (eq (lookup-key arc-answer-mode-map (kbd "r")) 'arc-ui-reask))
  (should (commandp 'arc-ui-follow-up))
  (should (commandp 'arc-ui-reask)))

(ert-deftest aui-reask-reuses-the-last-question ()
  (require 'arc)
  (aui-with-fresh-buffer
   (setq arc-ui--last-question "why 8385?")
   (let ((asked nil))
     (cl-letf (((symbol-function 'arc-ask)
                (lambda (q &rest _) (setq asked q))))
       (arc-ui-reask))
     (should (equal asked "why 8385?")))))

(ert-deftest aui-reask-without-a-previous-question-says-so ()
  (aui-with-fresh-buffer
   (setq arc-ui--last-question nil)
   (should-error (arc-ui-reask) :type 'user-error)))

(ert-deftest aui-follow-up-carries-the-previous-answer-as-context ()
  (require 'arc)
  (aui-with-fresh-buffer
   (setq arc-ui--last-question "why 8385?")
   (let ((a (arc-ui-begin-answer "why 8385?")))
     (arc-ui-stream-answer a "Because the WSL profile sets it."))
   (let ((prompt nil) (heading 'not-set))
     (cl-letf (((symbol-function 'arc-ask)
                (lambda (q &optional _cols h) (setq prompt q) (setq heading h))))
       (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "and the listen port?")))
         (arc-ui-follow-up)))
     (should (string-match-p "and the listen port\\?" prompt))
     (should (string-match-p "why 8385\\?" prompt))
     (should (string-match-p "Because the WSL profile sets it\\." prompt))
     ;; Critical 2: the model's context (PROMPT) may carry the whole
     ;; quoted exchange, but the buffer HEADING must stay the plain
     ;; follow-up line -- never the thing that would render the quoted
     ;; structure as this answer's own heading.
     (should (equal heading "and the listen port?")))))

(ert-deftest aui-follow-up-end-to-end-renders-one-new-heading-and-fresh-sources ()
  ;; Critical 2's full reproduction and proof, driven through the real
  ;; `arc-ui-follow-up' key rather than by hand-building a prompt: after a
  ;; follow-up, the buffer must have exactly one new `**' heading holding
  ;; the follow-up's own plain question text, exactly one new `*** Sources'
  ;; subtree holding only the new citation, and `arc-ui-answer-at-point'
  ;; in the new answer must return the new question and new citation --
  ;; never the quoted earlier exchange rendered as live org structure of
  ;; its own.
  (require 'arc)
  (aui-with-fresh-buffer
   (cl-letf (((symbol-function 'arc-find-similar)
              (lambda (_text _cols on-done &optional _on-error) (funcall on-done 'QUERY1)))
             ((symbol-function 'arc--retrieve-ids) (lambda (_q _p) '(1)))
             ((symbol-function 'arc--retrieve-rows)
              (lambda (_ids) '(("file" "/tmp/a.nix" nil nil nil "chunk a" 1 1 nil))))
             ((symbol-function 'arc-answer-request)
              (lambda (_q _s on-partial on-done _on-error)
                (funcall on-partial "Because")
                (funcall on-done "Because the WSL profile sets it."))))
     (arc-ask "why 8385?"))
   (cl-letf (((symbol-function 'arc-find-similar)
              (lambda (_text _cols on-done &optional _on-error) (funcall on-done 'QUERY2)))
             ((symbol-function 'arc--retrieve-ids) (lambda (_q _p) '(2)))
             ((symbol-function 'arc--retrieve-rows)
              (lambda (_ids) '(("file" "/tmp/b.nix" nil nil nil "chunk b" 2 2 nil))))
             ((symbol-function 'arc-answer-request)
              (lambda (_q _s on-partial on-done _on-error)
                (funcall on-partial "The port")
                (funcall on-done "The port is 8385.")))
             ((symbol-function 'read-string) (lambda (&rest _) "and the listen port?")))
     (goto-char (point-min))
     (arc-ui-follow-up))
   ;; exactly two `**' headings: the original question, then the plain
   ;; one-line follow-up -- never "Earlier exchange:" or any quoted blob
   (goto-char (point-min))
   (let (headings)
     (while (re-search-forward "^\\*\\* \\(.*\\)$" nil t)
       (push (match-string 1) headings))
     (should (equal (nreverse headings) '("why 8385?" "and the listen port?"))))
   ;; exactly two Sources subtrees, the second holding only the new
   ;; citation
   (goto-char (point-min))
   (let ((count 0))
     (while (re-search-forward "^\\*\\*\\* Sources" nil t) (setq count (1+ count)))
     (should (= count 2)))
   (goto-char (point-min))
   (should (search-forward "[[file:/tmp/a.nix::1]]" nil t))
   (should (search-forward "[[file:/tmp/b.nix::2]]" nil t))
   ;; and `arc-ui-answer-at-point' in the new answer returns the new
   ;; question and the new citation only
   (goto-char (point-max))
   (let ((sub (arc-ui-answer-at-point)))
     (should (string-match-p "and the listen port\\?" sub))
     (should (string-match-p "/tmp/b\\.nix" sub))
     (should-not (string-match-p "why 8385" sub))
     (should-not (string-match-p "/tmp/a\\.nix" sub)))))

(ert-deftest aui-follow-up-quotes-the-answer-at-point-not-the-last-asked-question ()
  ;; Regression: `arc-ui--last-question' tracks the most recently *asked*
  ;; question, buffer-local across the whole buffer -- not whichever
  ;; answer point happens to sit in. A multi-answer buffer actively
  ;; invites scrolling back to an earlier answer before following up on
  ;; it, so the follow-up prompt must be built entirely from the answer
  ;; at point (`arc-ui-answer-at-point', question heading included) and
  ;; must never name a different question by pulling it from
  ;; `arc-ui--last-question'.
  (require 'arc)
  (aui-with-fresh-buffer
   (let ((m1 (arc-ui-begin-answer "q1?")))
     (arc-ui-stream-answer m1 "answer one text")
     (arc-ui-render-sources m1 nil))
   (let ((m2 (arc-ui-begin-answer "q2?")))
     (arc-ui-stream-answer m2 "answer two text")
     (arc-ui-render-sources m2 nil))
   (let ((m3 (arc-ui-begin-answer "q3?")))
     (arc-ui-stream-answer m3 "answer three text")
     (arc-ui-render-sources m3 nil))
   (setq arc-ui--last-question "q3?")
   (goto-char (point-min))
   (should (search-forward "answer one text" nil t))
   (let ((prompt nil))
     (cl-letf (((symbol-function 'arc-ask)
                (lambda (q &rest _) (setq prompt q))))
       (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "a follow-up question")))
         (arc-ui-follow-up)))
     (should (string-match-p "q1\\?" prompt))
     (should (string-match-p "answer one text" prompt))
     (should-not (string-match-p "q3\\?" prompt))
     (should-not (string-match-p "answer three text" prompt)))))

(ert-deftest aui-follow-up-without-a-previous-question-says-so ()
  (aui-with-fresh-buffer
   (setq arc-ui--last-question nil)
   (should-error (arc-ui-follow-up) :type 'user-error)))

(ert-deftest eu-s-is-bound-to-change-scope ()
  (should (eq (keymap-lookup arc-answer-mode-map "s") #'arc-ui-change-scope)))

(ert-deftest eu-change-scope-requires-a-previous-question ()
  (with-temp-buffer
    (arc-answer-mode)
    (setq arc-ui--last-question nil)
    (should-error (arc-ui-change-scope) :type 'user-error)))

(ert-deftest eu-change-scope-reasks-the-last-question-at-the-new-scope ()
  (let (asked-question asked-scope)
    (with-temp-buffer
      (arc-answer-mode)
      (setq arc-ui--last-question "how do I enable syncthing")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "vault"))
                ((symbol-function 'arc-ask)
                 (lambda (q &optional s &rest _)
                   (setq asked-question q asked-scope s))))
        (arc-ui-change-scope)))
    (should (equal asked-question "how do I enable syncthing"))
    (should (equal asked-scope (alist-get "vault" arc-scope-presets nil nil #'equal)))))

(ert-deftest eu-presets-cover-the-documented-scopes ()
  (dolist (name '("everything" "vault" "options" "dotfiles"))
    (should (assoc name arc-scope-presets))))

(ert-deftest eu-everything-preset-actually-searches-the-whole-corpus ()
  "The old version of this test asserted a datum, not a behaviour: it
checked that the \"everything\" preset's plist satisfies
`arc-scope-empty-p', which passes just as well if the preset entry is
deleted outright -- a missing alist key returns nil, and
`arc-scope-empty-p' of nil is t.  That is exactly how finding #1
(the \"everything\" preset mapping to nil, which `arc-ask-normalize-
scope' then silently rewrites to `arc-enabled-collections') slipped
past ten reviews: no test ever went through `arc-ask-normalize-scope',
the function `arc-ui-change-scope' actually calls on its way to
`arc-ask', to ask what \"everything\" really retrieves.

This version does: it normalises the preset the same way `arc-ask'
would, and asserts the result is NOT `arc-enabled-collections' --
bound here to a distinctive value so the two are visibly different --
as well as still being an empty (unrestricted) scope."
  (require 'arc)
  (let* ((arc-enabled-collections '("distinctive-marker-collection"))
         (preset (alist-get "everything" arc-scope-presets nil nil #'equal))
         (normalized (arc-ask-normalize-scope preset)))
    (should (arc-scope-empty-p normalized))
    (should-not (equal normalized (arc-scope-from-collections arc-enabled-collections)))))
