;;; test-arc-emanix.el --- the distribution is emanix, never eminix -*- lexical-binding: t; -*-
;;
;; `eminix' was the distribution's old name.  It is `emanix' now
;; (emanix/flake.nix: "emanix -- a NixOS distribution"), and the stale spelling
;; was not harmless: arc-collection-directory-alist pointed at ~/projects/eminix,
;; a directory that exists on no host here, and arc-index.el treats a missing
;; directory as an ordinary reported skip -- so that collection indexed nothing
;; and said nothing.  docs/design/ is deliberately exempt: those are dated
;; records, and 2026-08-29-design.md is ABOUT a hardcoded-path bug, so rewriting
;; it would destroy the evidence.
;;
;; Two files are exempt from the scan below by basename, not by directory,
;; because each asserts ABOUT the retired name rather than reintroducing it:
;; this file necessarily contains the literal string "eminix" in both its
;; own `search-forward' call and this explanatory comment, and
;; test-arc-collections.el legitimately asserts
;; `(should-not (assoc "eminix" arc-collection-directory-alist))'.  The
;; exemption is scoped to exactly those two basenames; every other .el file,
;; README.org and every fixture stays in scope, and the search itself is not
;; weakened.
(require 'ert)
(defvar aem-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(defconst aem-exempt-basenames '("test-arc-emanix.el" "test-arc-collections.el")
  "Basenames of files that assert ABOUT the retired `eminix' name rather
than using it, and so must contain the literal string on purpose.")

(ert-deftest aem-no-stale-distribution-name ()
  "Live code, docs, tests and fixtures say emanix."
  (let ((default-directory aem-root)
        (offenders '()))
    (dolist (file (append (directory-files aem-root t "\\.el\\'")
                          (list (expand-file-name "README.org" aem-root))
                          (directory-files (expand-file-name "test" aem-root) t "\\.el\\'")
                          (directory-files-recursively
                           (expand-file-name "test/fixtures" aem-root) "\\.org\\'")))
      (when (and (file-regular-p file)
                 (not (member (file-name-nondirectory file) aem-exempt-basenames)))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (search-forward "eminix" nil t)
            (push (file-relative-name file aem-root) offenders)))))
    (should (equal offenders '()))))

(provide 'test-arc-emanix)
;;; test-arc-emanix.el ends here
