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
  (aui-with-fresh-buffer
   (let ((m (arc-ui-begin-answer "q")))
     (arc-ui-stream-answer m "Hel")
     (arc-ui-stream-answer m "Hello")
     (goto-char (point-min))
     (should (re-search-forward "Hello" nil t))
     (goto-char (point-min))
     (should-not (re-search-forward "HelHello" nil t)))))

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
