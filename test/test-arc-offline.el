;;; test-arc-offline.el --- arc makes no outbound requests -*- lexical-binding: t; -*-
(require 'ert)
(defvar ao-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ao-root)

(defconst ao-forbidden
  '("duckduckgo" "searxng" "tika" "pandoc" "web-search" "webpage"
    "arc-web-pages-limit" "arc-supported-complex-document")
  "Identifiers that must not survive anywhere in the package source.")

(ert-deftest ao-no-network-identifiers ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "arc.el" ao-root))
    (dolist (needle ao-forbidden)
      (goto-char (point-min))
      (should-not (search-forward needle nil t)))))

(ert-deftest ao-kinds-are-local-only ()
  (require 'arc)
  (should (equal (arc-kinds) '("file" "info" "org-node" "nix-option" "hm-option"))))
