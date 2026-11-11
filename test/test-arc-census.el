;;; test-arc-census.el --- count a reindex before paying for it -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar acn-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path acn-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-test-helpers)

(defun acn-write (root rel text)
  (let ((f (expand-file-name rel root)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert text))))

(defmacro acn-with-tree (var &rest body)
  (declare (indent 1))
  `(let* ((,var (file-name-as-directory (make-temp-file "arc-census" t)))
          (arc-index-plan '(("tree" . file) ("notes" . org) ("gone" . file)))
          (arc-collection-directory-alist
           (list (cons "tree" ,var)
                 (cons "notes" (expand-file-name "test/fixtures/roam" acn-root))
                 (cons "gone" "/nonexistent/arc-census-absent"))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun acn-fill (root)
  (acn-write root ".arcignore" "build/\n")
  (acn-write root "a/one.txt" "para one\n\npara two\n")
  (acn-write root "a/two.txt" "single\n")
  (acn-write root "b/three.txt" "x\n\ny\n\nz\n")
  (acn-write root "empty.txt" "")
  (acn-write root "build/junk.txt" "never counted\n"))

(ert-deftest acn-counts-what-a-reindex-would-write ()
  "The census goes through the reindex's own enumeration and chunkers, so
its counts must equal what a real reindex then writes."
  (acn-with-tree root
    (acn-fill root)
    (let* ((census (arc-index-plan-census '("tree" "notes")))
           (tree (car census))
           (notes (cadr census)))
      (should (= 3 (plist-get tree :sources)))
      (should (= 6 (plist-get tree :chunks)))
      (let ((arc-embedding-size 3))
        (arc-test-with-temp-db
         (cl-letf (((symbol-function 'llm-embedding) (lambda (&rest _) [0.1 0.2 0.3])))
           (arc-reindex-all '("tree" "notes")))
         (pcase-dolist (`(,name ,sources ,chunks ,_) (arc-index-collection-stats))
           (pcase name
             ("tree" (should (= sources (plist-get tree :sources)))
                     (should (= chunks (plist-get tree :chunks))))
             ("notes" (should (= sources (plist-get notes :sources)))
                      (should (= chunks (plist-get notes :chunks)))))))))))

(ert-deftest acn-never-embeds-and-never-opens-the-database ()
  (acn-with-tree root
    (acn-fill root)
    (cl-letf (((symbol-function 'llm-embedding) (lambda (&rest _) (error "embedded")))
              ((symbol-function 'llm-embedding-async) (lambda (&rest _) (error "embedded")))
              ((symbol-function 'arc-db) (lambda () (error "opened the database"))))
      (should (= 3 (plist-get (car (arc-index-plan-census '("tree"))) :sources))))))

(ert-deftest acn-breaks-a-collection-down-by-directory ()
  (acn-with-tree root
    (acn-fill root)
    (let ((by-dir (plist-get (car (arc-index-plan-census '("tree") 1)) :by-dir)))
      (should (equal '("a/" 2 3) (take 3 (assoc "a/" by-dir))))
      (should (equal '("b/" 1 3) (take 3 (assoc "b/" by-dir))))
      (should-not (assoc "build/" by-dir)))))

(ert-deftest acn-reports-an-absent-directory-as-skipped ()
  (acn-with-tree root
    (let ((gone (car (arc-index-plan-census '("gone")))))
      (should (plist-get gone :skipped))
      (should (= 0 (plist-get gone :chunks))))))

(ert-deftest acn-format-projects-embedding-time ()
  (let ((text (arc-index-census-format
               (list (list :collection "c" :chunker 'file :sources 2 :chunks 3600
                           :chars 10 :walk-seconds 0.0 :gather-seconds 0.0))
               0.5)))
    (should (string-match-p "TOTAL +2 +3600" text))
    ;; 3600 chunks at 0.5 s each is half an hour
    (should (string-match-p "0\\.50" text))))

(provide 'test-arc-census)
;;; test-arc-census.el ends here
