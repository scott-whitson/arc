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
     (should (string= (buffer-substring-no-properties m (point-max))
                      "Syncthing enables real-time file sync.")))))

(ert-deftest aui-sources-render-as-org-links ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")
          '(:kind "nix-option" :option-name "services.foo.enable" :chunk "b")))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\*\\* Sources" nil t))
   (goto-char (point-min))
   (should (search-forward "[[file:/tmp/x.nix::12]]" nil t))
   (goto-char (point-min))
   (should (search-forward "[[nixopt:services.foo.enable]]" nil t))))

(ert-deftest aui-rendered-links-are-parseable-by-org ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")))
   (goto-char (point-min))
   (should (re-search-forward org-link-bracket-re nil t))))

(ert-deftest aui-no-sources-says-so-rather-than-rendering-an-empty-subtree ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources nil)
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
      (list '(:kind "nix-option" :option-name "a.b.c" :chunk "b")))
     (arc-ui-stream-answer m "final full answer")
     (goto-char (point-min))
     (should (search-forward "final full answer" nil t))
     (goto-char (point-min))
     (should-not (search-forward "partial answer" nil t))
     (goto-char (point-min))
     (should (re-search-forward "^\\*\\*\\* Sources" nil t))
     (goto-char (point-min))
     (should (search-forward "[[nixopt:a.b.c]]" nil t)))))

(ert-deftest aui-mode-map-binds-the-documented-keys ()
  (dolist (cell '(("q" . arc-ui-quit)
                  ("TAB" . org-cycle)))
    (should (eq (lookup-key arc-answer-mode-map (kbd (car cell))) (cdr cell)))))

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
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")))
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
     (arc-ui-stream-answer m "plain answer text, no links here"))
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")))
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
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")))
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
              (lambda (_text _cols on-done) (funcall on-done 'QUERY)))
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
              (lambda (_text _cols on-done) (funcall on-done 'QUERY)))
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
