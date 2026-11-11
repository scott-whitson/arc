;;; test-arc-walk-prune.el --- the walk skips trees no file of could pass -*- lexical-binding: t; -*-
;;
;; `arc--file-candidates' hands `directory-files-recursively' a descend
;; predicate, `arc--directory-descendable-p'.  It is an optimisation and
;; nothing else: these tests pin that it never changes WHICH files a walk
;; returns, and that it really does stop the walk entering an ignored tree.
(require 'ert)
(require 'cl-lib)
(defvar awp-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path awp-root)
(require 'arc-source-file)

(defun awp-write (root rel &optional text)
  (let ((f (expand-file-name rel root)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert (or text "some text\n")))
    f))

(defmacro awp-with-tree (var &rest body)
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "arc-walk" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun awp-unpruned (root)
  "What the walk returned before it pruned: list everything, filter after."
  (let ((ignore (arc--read-ignore-file-regexps root)))
    (seq-filter (lambda (f) (arc--file-indexable-p f root ignore))
                (directory-files-recursively root ".*"))))

(ert-deftest awp-directory-patterns-prune ()
  (awp-with-tree root
    (awp-write root ".arcignore" "build/\nnode_modules\n*.cache\n")
    (let ((ig (arc--read-ignore-file-regexps root)))
      (should-not (arc--directory-descendable-p (expand-file-name "build" root) root ig))
      (should-not (arc--directory-descendable-p (expand-file-name "a/node_modules" root) root ig))
      (should-not (arc--directory-descendable-p (expand-file-name "x.cache" root) root ig))
      (should-not (arc--directory-descendable-p (expand-file-name ".git" root) root ig))
      (should (arc--directory-descendable-p (expand-file-name "src" root) root ig))
      (should (arc--directory-descendable-p (expand-file-name "a/build-tools" root) root ig)))))

(ert-deftest awp-file-patterns-never-prune-a-directory ()
  "A pattern that excludes files by name, or one exact path, must leave
the directory holding them walkable: other files in it still count."
  (awp-with-tree root
    (awp-write root ".arcignore" "*.txt\nkeys/host_ed25519\n")
    (let ((ig (arc--read-ignore-file-regexps root)))
      (should (arc--directory-descendable-p (expand-file-name "docs" root) root ig))
      (should (arc--directory-descendable-p (expand-file-name "keys" root) root ig)))))

(ert-deftest awp-pruned-walk-returns-exactly-what-the-unpruned-one-did ()
  (awp-with-tree root
    (awp-write root ".arcignore" "build/\nnode_modules\n*.log\nsrc/secret.md\ndocs/org/\n")
    (dolist (rel '("README.md" "src/main.el" "src/secret.md" "src/deep/x.nix"
                   "build/out.txt" "build/sub/y.txt" "pkg/node_modules/m/index.js"
                   "logs/run.log" "logs/keep.md" ".hidden/z.txt" "docs/org/note.org"
                   "docs/other.org" "id_rsa" "certs/server.pem"))
      (awp-write root rel))
    (let ((pruned (sort (arc--file-list root) #'string<))
          (unpruned (sort (awp-unpruned root) #'string<)))
      (should (equal pruned unpruned))
      (should (member (expand-file-name "src/deep/x.nix" root) pruned))
      (should (member (expand-file-name "logs/keep.md" root) pruned))
      (should-not (member (expand-file-name "src/secret.md" root) pruned)))))

(ert-deftest awp-an-ignored-tree-is-never-entered ()
  "The point of pruning: no file under an ignored directory is even
offered to the per-file rules."
  (awp-with-tree root
    (awp-write root ".arcignore" "build/\n")
    (awp-write root "keep.md")
    (dotimes (i 5) (awp-write root (format "build/deep/f%d.txt" i)))
    (let ((asked nil)
          (orig (symbol-function 'arc--path-indexable-p)))
      (cl-letf (((symbol-function 'arc--path-indexable-p)
                 (lambda (file r ig) (push file asked) (funcall orig file r ig))))
        (should (equal (list (expand-file-name "keep.md" root))
                       (arc--file-list root))))
      (should-not (cl-some (lambda (f) (string-match-p "/build/" f)) asked)))))

(provide 'test-arc-walk-prune)
;;; test-arc-walk-prune.el ends here
