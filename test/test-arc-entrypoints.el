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

(ert-deftest ae-command-map-has-surviving-entry-points ()
  (should (eq (keymap-lookup arc-command-map "R") #'arc-reindex-all))
  (should (eq (keymap-lookup arc-command-map "c") #'arc-reindex-cancel))
  (should-not (keymap-lookup arc-command-map "m"))
  (should-not (keymap-lookup arc-command-map "i"))
  (should-not (keymap-lookup arc-command-map "n"))
  (should-not (keymap-lookup arc-command-map "o")))

(ert-deftest ae-every-surviving-entry-point-is-interactive ()
  (dolist (cmd '(arc-reindex-all arc-reindex-cancel))
    (should (commandp cmd))))
