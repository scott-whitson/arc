;;; test-arc-arcignore.el --- per-directory arc-only exclusions -*- lexical-binding: t; -*-
;;
;; The `home' collection is rooted at $HOME and overlaps two things it must not
;; index: ~/docs/org, which `vault' already owns with the org chunker, and
;; ~/downloads.  `.arcignore' carries those exclusions through the ignore-file
;; machinery that already exists, under a filename of arc's own so nothing here
;; changes what ripgrep does.  Separately, arc's own 467 MB sqlite database sits
;; under ~/.config/emacs, which the `emacs' collection indexes -- and
;; `arc--text-file-p' would read all 467 MB into a buffer just to decide it is
;; binary.  `arc-db-directory' is a defcustom and can move, so the denylist
;; covers the database by pattern rather than trusting one path to stay put.
(require 'ert)
(defvar aai-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aai-root)
(require 'arc-source-file)

(defmacro aai-with-tree (spec &rest body)
  "Create a temp dir, populate it from SPEC, bind it to `root', run BODY."
  (declare (indent 1))
  `(let ((root (make-temp-file "aai" t)))
     (unwind-protect
         (progn
           (dolist (cell ,spec)
             (let ((f (expand-file-name (car cell) root)))
               (make-directory (file-name-directory f) t)
               (with-temp-file f (insert (cdr cell)))))
           ,@body)
       (delete-directory root t))))

(ert-deftest aai-arcignore-is-honoured ()
  "A .arcignore file excludes the directories it names."
  (aai-with-tree '((".arcignore" . "docs/org/\ndownloads/\n")
                   ("keep.txt" . "keep")
                   ("docs/org/note.org" . "owned by vault")
                   ("downloads/installer.txt" . "junk"))
    (should (equal (mapcar (lambda (f) (file-relative-name f root))
                           (arc--file-list root))
                   '("keep.txt")))))

(ert-deftest aai-arcignore-is-in-the-default-pattern-files ()
  "Shipping the mechanism is not enough; the filename must be a default."
  (should (member ".arcignore" arc-ignore-patterns-files)))

(ert-deftest aai-sqlite-database-is-denylisted ()
  "arc must never read its own database, wherever `arc-db-directory' points."
  (should (arc--denylisted-p "/anywhere/at/all/arc/arc.sqlite"))
  (should (arc--denylisted-p "/anywhere/at/all/arc/arc.sqlite-wal"))
  (should (arc--denylisted-p "/anywhere/at/all/arc/arc.sqlite-shm"))
  (should-not (arc--denylisted-p "/anywhere/at/all/notes/sqlite-tips.org")))

(provide 'test-arc-arcignore)
;;; test-arc-arcignore.el ends here
