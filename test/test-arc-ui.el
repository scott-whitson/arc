;;; test-arc-ui.el --- the answer buffer -*- lexical-binding: t; -*-
(require 'ert)
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
