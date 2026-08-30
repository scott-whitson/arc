;;; test-arc-retrieve-source.el --- rows convert to citable sources -*- lexical-binding: t; -*-
(require 'ert)
(defvar ars-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ars-root)
(require 'arc-source)
(require 'arc)

(ert-deftest ars-row-to-source-file ()
  (let ((s (arc-row-to-source '("file" "/tmp/x.nix" nil nil nil "body" 12 20 nil))))
    (should (equal (plist-get s :kind) "file"))
    (should (equal (plist-get s :path) "/tmp/x.nix"))
    (should (= (plist-get s :line-start) 12))
    (should (equal (plist-get s :chunk) "body"))))

(ert-deftest ars-row-renders-a-file-link-at-its-line ()
  (let ((s (arc-row-to-source '("file" "/tmp/x.nix" nil nil nil "body" 12 20 nil))))
    (should (equal (arc-source-link s (plist-get s :line-start))
                   "[[file:/tmp/x.nix::12]]"))))

(ert-deftest ars-row-org-node-keeps-title ()
  (let ((s (arc-row-to-source '("org-node" nil nil "abc123" nil "body" 1 1 "My Note"))))
    (should (equal (plist-get s :title) "My Note"))
    (should (equal (arc-source-link s) "[[id:abc123][My Note]]"))))

(ert-deftest ars-row-nix-option ()
  (let ((s (arc-row-to-source '("nix-option" "nixos/modules/x.nix" nil nil
                                "services.foo.enable" "body" 1 1 nil))))
    (should (equal (arc-source-link s) "[[nixopt:services.foo.enable]]"))))

(ert-deftest ars-retrieve-rows-selects-the-citation-columns ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "arc.el" ars-root))
    (dolist (col '("d.line_start" "d.line_end" "d.title"))
      (goto-char (point-min))
      (should (search-forward col nil t)))))
