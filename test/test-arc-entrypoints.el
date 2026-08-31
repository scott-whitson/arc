;;; test-arc-entrypoints.el --- the scoped entry points -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'ert)
(defvar ae-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ae-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)

(ert-deftest ae-command-map-has-every-entry-point ()
  (should (eq (keymap-lookup arc-command-map "i") #'arc-ask))
  (should (eq (keymap-lookup arc-command-map "n") #'arc-ask-vault))
  (should (eq (keymap-lookup arc-command-map "o") #'arc-ask-options))
  (should (eq (keymap-lookup arc-command-map "m") #'arc-toggle-chat-model))
  (should (eq (keymap-lookup arc-command-map "R") #'arc-reindex-all))
  (should (eq (keymap-lookup arc-command-map "c") #'arc-reindex-cancel)))

(ert-deftest ae-every-entry-point-is-interactive ()
  (dolist (cmd '(arc-ask arc-ask-vault arc-ask-options arc-toggle-chat-model
                 arc-reindex-all arc-reindex-cancel))
    (should (commandp cmd))))

(ert-deftest ae-ask-vault-scopes-to-the-vault ()
  (let (got)
    (cl-letf (((symbol-function 'arc-ask) (lambda (_q &optional s &rest _) (setq got s))))
      (arc-ask-vault "q")
      (should (equal got (arc-scope :collections arc-vault-collections)))
      (should (equal arc-vault-collections '("vault"))))))

(ert-deftest ae-ask-options-scopes-to-both-option-collections ()
  (let (got)
    (cl-letf (((symbol-function 'arc-ask) (lambda (_q &optional s &rest _) (setq got s))))
      (arc-ask-options "q")
      (should (equal got (arc-scope :collections arc-option-collections)))
      (should (equal arc-option-collections '("nix options" "hm options")))
      (should (member "nix options" (plist-get got :collections)))
      (should (member "hm options" (plist-get got :collections))))))

(ert-deftest ae-ask-vault-refuses-when-vault-collections-is-nil ()
  "A nil-ed `arc-vault-collections' must refuse, not widen to the whole
corpus: `(:collections nil)' is `arc-scope-empty-p', which compiles to
predicate \"1\" -- the same as no scope at all."
  (let ((arc-vault-collections nil))
    (should-error (arc-ask-vault "q") :type 'user-error)))

(ert-deftest ae-ask-options-refuses-when-option-collections-is-nil ()
  (let ((arc-option-collections nil))
    (should-error (arc-ask-options "q") :type 'user-error)))

(ert-deftest ae-toggle-cycles-through-the-model-list ()
  (let* ((arc-chat-models '("a" "b" "c"))
         (arc-chat-provider (make-llm-ollama :chat-model "a" :embedding-model "e")))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "b"))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "c"))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "a"))))

(ert-deftest ae-toggle-from-an-unlisted-model-starts-at-the-first ()
  (let* ((arc-chat-models '("a" "b"))
         (arc-chat-provider (make-llm-ollama :chat-model "zzz" :embedding-model "e")))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "a"))))

(ert-deftest ae-toggle-refuses-a-non-ollama-provider ()
  (let ((arc-chat-provider "not a provider"))
    (should-error (arc-toggle-chat-model) :type 'user-error)))
