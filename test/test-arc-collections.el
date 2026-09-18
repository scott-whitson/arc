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
(require 'cl-lib)
(defvar acl-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path acl-root)
(require 'arc-index)
(require 'arc-scope)

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

(ert-deftest acl-scope-presets-name-only-planned-collections ()
  "A preset naming a collection outside `arc-index-plan' matches nothing
and signals nothing -- see `arc-scope-presets''s docstring.  This is the
generalisation of the `dotfiles' bug: any future collection rename must
not leave a preset pointing at a name the plan no longer builds."
  (dolist (preset arc-scope-presets)
    (dolist (name (plist-get (cdr preset) :collections))
      (should (assoc name arc-index-plan)))))

;;; --- Final review I4: the overlap nothing repo-side could see -------
;; `vault' is ~/docs/org and `home' is $HOME, so `home' contains `vault'
;; and only an operator-written ~/.arcignore -- a file outside this
;; repository -- keeps the two apart.  A fresh operator who builds the
;; index before writing that file gets ~/docs/org walked twice, the second
;; copy chunked by `file' with no org id, no title and no citable link,
;; competing in every ranking and doubling the embedding cost of the
;; largest curated collection.  Silently: two collections indexing one
;; file is not an error at any other layer.

(defmacro acl-with-overlapping-plan (arcignore &rest body)
  "Run BODY with `home' and `vault' planned, `vault' inside `home'.
ARCIGNORE, when non-nil, is written to `home''s .arcignore first."
  (declare (indent 1))
  `(let* ((home (make-temp-file "acl-home" t))
          (vault (expand-file-name "docs/org" home))
          (arc-collection-directory-alist
           (list (cons "home" home) (cons "vault" vault)))
          (arc-index-plan '(("home" . file) ("vault" . org))))
     (unwind-protect
         (progn
           (make-directory vault t)
           (when ,arcignore
             (with-temp-file (expand-file-name ".arcignore" home)
               (insert ,arcignore)))
           ,@body)
       (delete-directory home t))))

(ert-deftest acl-an-unexcluded-overlap-is-reported ()
  (acl-with-overlapping-plan nil
    (let ((overlaps (arc-index--collection-overlaps)))
      (should (= 1 (length overlaps)))
      (should (equal "home" (nth 0 (car overlaps))))
      (should (equal "vault" (nth 1 (car overlaps)))))))

(ert-deftest acl-an-arcignored-overlap-is-not-reported ()
  "The documented fix must actually silence it, or the warning is noise."
  (acl-with-overlapping-plan "docs/org/\n"
    (should (null (arc-index--collection-overlaps)))))

(ert-deftest acl-a-dotted-collection-root-is-not-an-overlap ()
  "`arc-ignore-invisible-files' already keeps `home' out of ~/.config/emacs,
~/.claude and ~/.agent-shell.  Warning about those three on every
reindex would train the operator to ignore the warning that matters."
  (let* ((home (make-temp-file "acl-home" t))
         (emacs-dir (expand-file-name ".config/emacs" home))
         (arc-collection-directory-alist
          (list (cons "home" home) (cons "emacs" emacs-dir)))
         (arc-index-plan '(("home" . file) ("emacs" . file))))
    (unwind-protect
        (progn
          (make-directory emacs-dir t)
          (should (null (arc-index--collection-overlaps))))
      (delete-directory home t))))

(ert-deftest acl-a-collection-does-not-overlap-itself ()
  (let* ((dir (make-temp-file "acl-solo" t))
         (arc-collection-directory-alist (list (cons "home" dir)))
         (arc-index-plan '(("home" . file))))
    (unwind-protect (should (null (arc-index--collection-overlaps)))
      (delete-directory dir t))))

(ert-deftest acl-reindex-all-warns-about-an-unexcluded-overlap ()
  "Loudly, once, naming both collections and the fix -- and it must warn
rather than refuse: an overlap is a misconfiguration, not a corruption."
  (acl-with-overlapping-plan nil
    (let ((warnings '()))
      (cl-letf (((symbol-function 'arc--reindex-all-sync) (lambda (&rest _) nil))
                ((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (arc-reindex-all))
      (should (= 1 (length warnings)))
      (should (string-match-p "vault" (car warnings)))
      (should (string-match-p "home" (car warnings)))
      (should (string-match-p "\\.arcignore" (car warnings))))))

(ert-deftest acl-reindex-all-is-silent-when-the-overlap-is-excluded ()
  (acl-with-overlapping-plan "docs/org/\n"
    (let ((warnings '()))
      (cl-letf (((symbol-function 'arc--reindex-all-sync) (lambda (&rest _) nil))
                ((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (arc-reindex-all))
      (should (null warnings)))))

;;; --- Final review I2: no live reference to a retired collection ------

(defconst acl-retired-collection-exempt-basenames
  '("arc-scope.el" "arc-source-nixopt.el" "test-arc-collections.el")
  "Files that name the retired collection ON PURPOSE.
`arc-scope.el' records why the \"dotfiles\" preset became \"home\" and
what the old corpus's nearest neighbours looked like; `arc-source-nixopt.el'
uses `dotfiles' as what it still is, a DIRECTORY (`arc-nixopt-flake');
and this file asserts about the name rather than using it.")

(ert-deftest acl-no-live-reference-to-a-retired-collection ()
  "Task 3 deleted the `dotfiles' collection and a fix round caught
`arc-scope-presets' alone.  Six live references survived it, including
the README's only bin/arc example -- which errored with `unknown scope
\"dotfiles\"' -- an `arc-reindex-all' example that had become a silent
no-op, and an `arc-enabled-collections' example that set up exactly the
silently-empty scope `arc-scope-presets' warns about.

The name is only a defect when it names a COLLECTION, which in elisp
and in the README means the quoted string or a `--scope' argument; it
remains a perfectly good directory name, which is why the pattern is
narrow and the exemptions are by basename."
  (let ((offenders '()))
    (dolist (file (append (directory-files acl-root t "\\.el\\'")
                          (list (expand-file-name "README.org" acl-root))))
      (when (and (file-regular-p file)
                 (not (member (file-name-nondirectory file)
                              acl-retired-collection-exempt-basenames)))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          ;; The optional backslashes catch the name quoted INSIDE a
          ;; docstring, which is where arc.el's stale example lived.
          (while (re-search-forward "\\\\?\"dotfiles\\\\?\"\\|--scope +dotfiles" nil t)
            (push (format "%s:%d" (file-relative-name file acl-root)
                          (line-number-at-pos))
                  offenders)))))
    (should (equal offenders '()))))

(provide 'test-arc-collections)
;;; test-arc-collections.el ends here
