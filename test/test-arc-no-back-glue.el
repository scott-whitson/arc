;;; test-arc-no-back-glue.el --- arc answers nothing, it retrieves -*- lexical-binding: t; -*-
;;
;; arc used to assemble a prompt, stream a reply and render it in its own
;; buffer.  That layer is gone: arc returns ranked chunks through `arc-tool.el'
;; and `bin/arc', and whatever agent drives it writes the prose.  A single-shot
;; tool-calling model cannot take ten retrieved chunks and write a paragraph,
;; so there is nothing to replace it WITH -- which is the point, not a gap.
;;
;; This suite pins the absence.  Deletions rot back in through a stray require
;; or a docstring example far more easily than features rot out.
(require 'ert)
(defvar anb-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path anb-root)
(require 'arc)
;; `arc-search-show' is the unconditional results-buffer entry point in the
;; separate search UI file.  Load that file explicitly here so this test
;; checks the search surface itself, not whether `arc' happens to require it.
(require 'arc-search-ui)
(require 'arc-tool)

(ert-deftest anb-the-answer-buffer-is-gone ()
  "arc-ui.el owned every part of the prose-answer surface."
  (should-not (featurep 'arc-ui))
  (should-not (file-exists-p (expand-file-name "arc-ui.el" anb-root)))
  (dolist (symbol '(arc-answer-mode arc-answer-mode-map arc-ui-buffer
                    arc-ui-begin-answer arc-ui-stream-answer
                    arc-ui-render-sources arc-ui-follow-citation
                    arc-ui-reask arc-ui-follow-up arc-ui-change-scope))
    (should-not (fboundp symbol))
    (should-not (boundp symbol))))

(ert-deftest anb-the-search-surface-survives ()
  "arc-search-ui.el is a different file and is NOT part of this deletion.
`arc-search' itself is deliberately nested inside `(when (require
'consult nil t) ...)' (arc-search-ui.el:376), so it does NOT exist on a
machine without consult -- assert the file and its unconditional entry
point, never `arc-search' itself."
  (should (file-exists-p (expand-file-name "arc-search-ui.el" anb-root)))
  (should (fboundp 'arc-search-show)))

(ert-deftest anb-the-prompt-layer-is-gone ()
  "arc-answer.el assembled the prompt and streamed the reply."
  (should-not (featurep 'arc-answer))
  (should-not (file-exists-p (expand-file-name "arc-answer.el" anb-root)))
  (dolist (symbol '(arc-answer-context-block arc-answer-build-prompt
                    arc-answer-request arc-chat-prompt-template))
    (should-not (fboundp symbol))
    (should-not (boundp symbol))))

(ert-deftest anb-the-ask-commands-are-gone ()
  "Nothing in arc takes a question and returns prose."
  (dolist (symbol '(arc-ask arc-ask-vault arc-ask-options))
    (should-not (fboundp symbol))
    (should-not (commandp symbol))))

(ert-deftest anb-retrieval-still-answers-to-its-callers ()
  "The whole point of the deletion: retrieval is untouched."
  (should (fboundp 'arc--find-similar))
  (should (fboundp 'arc-scope-normalize))
  (should (fboundp 'arc-tool-search)))

(ert-deftest anb-nothing-can-reach-a-chat-model ()
  "The provider, its model list, and the command that cycled them."
  (dolist (symbol '(arc-chat-provider arc-chat-models))
    (should-not (boundp symbol)))
  (should-not (fboundp 'arc-toggle-chat-model)))

(ert-deftest anb-the-chat-model-reranker-is-gone ()
  "It existed to rerank with the chat model already installed.
There is no chat model installed."
  (should-not (featurep 'arc-rerank-llm))
  (should-not (file-exists-p (expand-file-name "arc-rerank-llm.el" anb-root)))
  (should-not (fboundp 'arc-rerank-llm)))

(ert-deftest anb-the-reranker-hook-survives ()
  "Provider-agnostic, and the door a later plan walks through."
  (dolist (symbol '(arc-reranker-function arc-reranker-enabled
                    arc-reranker-limit))
    (should (boundp symbol)))
  (should-not arc-reranker-function))

(ert-deftest anb-no-source-file-mentions-a-chat-provider ()
  "A deletion rots back in through a docstring long before it does
through code."
  (let ((offenders '()))
    (dolist (file (directory-files anb-root t "\\`arc.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (re-search-forward "arc-chat-provider\\|arc-chat-models" nil t)
          (push (file-relative-name file anb-root) offenders))))
    (should (equal offenders '()))))

(ert-deftest anb-no-live-doc-promises-an-answer ()
  "Live code and docs do not resurrect the deleted answer surface.
Historical design records are intentionally outside this scan.  The README's
explicit migration note is the one scoped place allowed to name removed public
commands, and `arc-scope.el' is the one scoped place allowed to name the
obsolete compatibility alias.  Everything else must describe retrieval, not
the old answer buffer or its status header."
  (let ((stale '("arc-ask" "arc-chat-provider" "arc-chat-models"
                 "arc-answer-mode" "arc-rerank-llm"
                 "arc-answer.el" "arc-ui.el" "answer buffer" "answer-buffer"
                 "header line" "header-line" "arc-ui-header-line"))
        (files (append (directory-files anb-root t "\\`arc.*\\.el\\'")
                       (list (expand-file-name "README.org" anb-root))))
        offenders)
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((text (buffer-string)))
          ;; The migration note is intentionally allowed to name the removed
          ;; commands, but only between its two explicit markers.
          (when (equal (file-name-nondirectory file) "README.org")
            (let ((start (string-match "^#\\+BEGIN: arc-migration-note$" text))
                  (end nil))
              (when start
                (setq end (and (string-match "^#\\+END: arc-migration-note$" text start)
                               (match-end 0)))
                (when end
                  (setq text (concat (substring text 0 start)
                                     (substring text end)))))))
          ;; This alias remains executable API during migration; exempt only
          ;; its defining source file, and only the old name itself.
          (when (equal (file-name-nondirectory file) "arc-scope.el")
            (setq text (replace-regexp-in-string
                        "arc-ask-normalize-scope" "" text t t)))
          (dolist (name stale)
            (when (string-match-p (regexp-quote name) text)
              (push (format "%s: %s" (file-relative-name file anb-root) name)
                    offenders))))))
    (should (equal offenders nil))))

(provide 'test-arc-no-back-glue)
;;; test-arc-no-back-glue.el ends here
