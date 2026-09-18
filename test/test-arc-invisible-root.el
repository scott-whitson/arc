;;; test-arc-invisible-root.el --- a dotted collection root is indexable -*- lexical-binding: t; -*-
;;
;; `arc--file-list' tested the invisible-file patterns against each file's
;; ABSOLUTE path on purpose.  That silently made any collection rooted at a
;; dotted directory index nothing: every file under ~/.config/emacs has
;; "/.config" in its absolute path, so the "/\\.[^/]*" pattern matched all of
;; them.  Three of arc's five collections live under dotted roots, so the
;; patterns now run against the slash-prefixed RELATIVE path instead.  Both
;; halves are pinned here: a dotted root indexes its files, and a dotted entry
;; INSIDE any root -- including a top-level one, which is why the relative name
;; is slash-prefixed -- is still skipped.
(require 'ert)
(defvar air-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path air-root)
(require 'arc-source-file)

(defmacro air-with-tree (spec &rest body)
  "Create a temp dir, populate it from SPEC, bind it to `root', run BODY.
SPEC is a list of (RELATIVE-PATH . CONTENTS)."
  (declare (indent 1))
  `(let ((root (make-temp-file "air" t)))
     (unwind-protect
         (progn
           (dolist (cell ,spec)
             (let ((f (expand-file-name (car cell) root)))
               (make-directory (file-name-directory f) t)
               (with-temp-file f (insert (cdr cell)))))
           ,@body)
       (delete-directory root t))))

(ert-deftest air-dotted-root-still-lists-its-files ()
  "A collection root that is itself dotted must index its contents."
  (air-with-tree '(("lisp/config.el" . "(provide 'config)"))
    ;; Stage the tree under a dotted parent, the shape of ~/.config/emacs.
    (let* ((dotted (expand-file-name ".config/emacs" root)))
      (make-directory dotted t)
      (rename-file (expand-file-name "lisp" root) (expand-file-name "lisp" dotted))
      (should (equal (mapcar (lambda (f) (file-relative-name f dotted))
                             (arc--file-list dotted))
                     '("lisp/config.el"))))))

(ert-deftest air-dotted-entry-inside-a-root-is-still-skipped ()
  "A dotted directory INSIDE a collection stays excluded."
  (air-with-tree '(("keep.el" . "keep")
                   (".git/config" . "secret")
                   ("sub/.hidden/x.el" . "hidden"))
    (should (equal (mapcar (lambda (f) (file-relative-name f root))
                           (arc--file-list root))
                   '("keep.el")))))

(ert-deftest air-top-level-dotfile-is-still-skipped ()
  "The slash prefix is what keeps a top-level dotfile excluded."
  (air-with-tree '(("keep.el" . "keep") (".envrc" . "use nix"))
    (should (equal (mapcar (lambda (f) (file-relative-name f root))
                           (arc--file-list root))
                   '("keep.el")))))

(provide 'test-arc-invisible-root)
;;; test-arc-invisible-root.el ends here
