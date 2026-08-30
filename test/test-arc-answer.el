;;; test-arc-answer.el --- prompt assembly and streaming -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar aa-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path aa-root)
(require 'arc-answer)

(defvar aa-file-src
  '(:kind "file" :path "/tmp/x.nix" :line-start 12 :line-end 20 :chunk "alpha body"))
(defvar aa-opt-src
  '(:kind "nix-option" :option-name "services.foo.enable" :chunk "beta body"))

;; arc-answer.el declares these two as valueless defvars (special, no
;; value) so it can byte-compile cleanly without a circular require on
;; arc.el, which is where they normally get a real value.  This test file
;; is arc-answer's only caller here, so it must supply values itself.
(defvar arc-chat-provider 'aa-fake-provider)
(defvar arc-chat-prompt-template "Context above. Question:
%s")

(ert-deftest aa-context-block-labels-and-includes-every-chunk ()
  (let ((b (arc-answer-context-block (list aa-file-src aa-opt-src))))
    (should (string-match-p "alpha body" b))
    (should (string-match-p "beta body" b))
    (should (string-match-p "x\\.nix" b))
    (should (string-match-p "services\\.foo\\.enable" b))))

(ert-deftest aa-build-prompt-puts-context-before-the-question ()
  (let ((p (arc-answer-build-prompt "why is it 8385?" (list aa-file-src))))
    (should (string-match-p "alpha body" p))
    (should (string-match-p "why is it 8385?" p))
    (should (< (string-match "alpha body" p)
               (string-match "why is it 8385?" p)))))

(ert-deftest aa-build-prompt-with-no-sources-still-asks ()
  (should (string-match-p "why?" (arc-answer-build-prompt "why?" nil))))

(ert-deftest aa-request-streams-partials-then-done ()
  (let ((partials nil) (done nil))
    (cl-letf (((symbol-function 'llm-chat-streaming)
               (lambda (_provider _prompt on-partial on-done _on-error)
                 (funcall on-partial "Hel")
                 (funcall on-partial "Hello")
                 (funcall on-done "Hello"))))
      (arc-answer-request "q" (list aa-file-src)
                          (lambda (txt) (push txt partials))
                          (lambda (txt) (setq done txt))
                          #'ignore))
    (should (equal (nreverse partials) '("Hel" "Hello")))
    (should (equal done "Hello"))))

(ert-deftest aa-request-surfaces-errors ()
  (let ((err nil))
    (cl-letf (((symbol-function 'llm-chat-streaming)
               (lambda (_p _pr _op _od on-error) (funcall on-error 'error "boom"))))
      (arc-answer-request "q" nil #'ignore #'ignore
                          (lambda (_sym msg) (setq err msg))))
    (should (equal err "boom"))))
