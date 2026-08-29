;;; test-arc-source-file.el --- file walking and change detection -*- lexical-binding: t; -*-
(require 'ert)
(defvar asf-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asf-root)
(require 'arc-source-file)

(defmacro asf-with-tree (&rest body)
  "Run BODY with `dir' bound to a temporary tree containing two files."
  `(let ((dir (make-temp-file "arc-tree" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "a.nix" dir) (insert "{ x = 1; }\n"))
           (with-temp-file (expand-file-name "b.txt" dir) (insert "hello\n\nworld\n"))
           (with-temp-file (expand-file-name ".ignore" dir) (insert "b.txt\n"))
           ,@body)
       (delete-directory dir t))))

(ert-deftest asf-walks-text-files ()
  (asf-with-tree
   (let ((paths (mapcar (lambda (s) (file-name-nondirectory (plist-get s :path)))
                        (arc-file-sources dir))))
     (should (member "a.nix" paths)))))

(ert-deftest asf-honours-ignore-files ()
  (asf-with-tree
   (let ((paths (mapcar (lambda (s) (file-name-nondirectory (plist-get s :path)))
                        (arc-file-sources dir))))
     (should-not (member "b.txt" paths)))))

(ert-deftest asf-sources-carry-chunks-and-hash ()
  (asf-with-tree
   (let ((s (car (arc-file-sources dir))))
     (should (stringp (plist-get s :hash)))
     (should (consp (plist-get s :chunks)))
     (should (plist-get (car (plist-get s :chunks)) :line-start)))))

(ert-deftest asf-hash-changes-with-content ()
  (asf-with-tree
   (let ((h1 (plist-get (car (arc-file-sources dir)) :hash)))
     (with-temp-file (expand-file-name "a.nix" dir) (insert "{ x = 2; }\n"))
     (should-not (equal h1 (plist-get (car (arc-file-sources dir)) :hash))))))
