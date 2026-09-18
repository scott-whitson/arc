;;; test-arc-collections.el --- the corpus is every part of ~ that is data -*- lexical-binding: t; -*-
;;
;; arc used to index three directories, one of which (`eminix') did not exist.
;; The layout now covers $HOME whole, split by chunker rather than by topic:
;; `vault' keeps the org chunker over ~/docs/org, `home' takes everything else
;; visible under ~, and the three dotted roots that hold data get their own
;; collections because `arc-ignore-invisible-files' excludes them from `home' by
;; construction.  `mail' is configured but out of the plan: indexing mail should
;; be a deliberate act.
(require 'ert)
(defvar acl-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path acl-root)
(require 'arc-index)

(ert-deftest acl-every-planned-collection-has-a-directory ()
  "A plan entry with no directory signals at index time; catch it here."
  (dolist (entry arc-index-plan)
    (let ((name (car entry)))
      ;; The option collections are synthesised, not read from a directory.
      (unless (memq (cdr entry) '(nixopt hmopt info))
        (should (arc-collection-directory name))))))

(ert-deftest acl-vault-keeps-the-org-chunker ()
  "Dropping ~/docs/org to the file chunker would lose org ids and titles,
which `arc-eval''s :org-id matching depends on."
  (should (eq 'org (alist-get "vault" arc-index-plan nil nil #'equal))))

(ert-deftest acl-dotted-data-roots-are-their-own-collections ()
  "`home' cannot reach them: `arc-ignore-invisible-files' is t."
  (dolist (name '("emacs" "claude" "agent-shell"))
    (should (assoc name arc-collection-directory-alist))
    (should (eq 'file (alist-get name arc-index-plan nil nil #'equal)))))

(ert-deftest acl-mail-is-configured-but-not-planned ()
  "Opt-in, not surprise."
  (should (assoc "mail" arc-collection-directory-alist))
  (should-not (assoc "mail" arc-index-plan)))

(ert-deftest acl-retired-collections-are-gone ()
  "`home' subsumes both; `eminix' never existed on this host anyway."
  (should-not (assoc "dotfiles" arc-collection-directory-alist))
  (should-not (assoc "eminix" arc-collection-directory-alist))
  (should-not (assoc "dotfiles" arc-index-plan))
  (should-not (assoc "eminix" arc-index-plan)))

(ert-deftest acl-no-collection-hardcodes-a-home-path ()
  "This repo is public; every path derives from $HOME."
  (dolist (cell arc-collection-directory-alist)
    (should (string-prefix-p (expand-file-name "~") (cdr cell)))))

(provide 'test-arc-collections)
;;; test-arc-collections.el ends here
