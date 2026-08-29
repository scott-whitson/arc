;;; test-arc-index.el --- indexing writes chunks and embeddings -*- lexical-binding: t; -*-
(require 'ert)
(defvar ai-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ai-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'arc)
(require 'arc-index)

(defmacro ai-with-temp-db (&rest body)
  `(let* ((arc-db-directory (make-temp-file "arc-idx" t))
          (arc--db nil)
          (arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding)
                (lambda (&rest _) (vector 0.1 0.2 0.3))))
       (unwind-protect (progn ,@body)
         (arc-close-db)
         (delete-directory arc-db-directory t)))))

(ert-deftest ai-indexes-a-file-source ()
  (ai-with-temp-db
   (let ((n (arc-index-source
             '(:kind "file" :path "/tmp/x.nix" :hash "abc" :mtime 1
               :chunks ((:text "alpha" :line-start 1 :line-end 2)
                        (:text "beta"  :line-start 4 :line-end 5)))
             "test")))
     (should (= n 2))
     (should (= 2 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (= 2 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;")))))))

(ert-deftest ai-line-numbers-survive-the-round-trip ()
  (ai-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/x.nix" :chunks ((:text "alpha" :line-start 7 :line-end 9)))
    "test")
   (should (= 7 (caar (sqlite-select (arc-db) "SELECT line_start FROM data;"))))))

(ert-deftest ai-reindexing-replaces-rather-than-duplicates ()
  (ai-with-temp-db
   (let ((src '(:kind "file" :path "/tmp/x.nix" :hash "abc"
                :chunks ((:text "alpha" :line-start 1 :line-end 1)))))
     (arc-index-source src "test")
     (arc-index-source src "test")
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     ;; the virtual tables must not accumulate orphans across reindexes
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))))))

(ert-deftest ai-stats-report-per-kind-counts ()
  (ai-with-temp-db
   (arc-index-source '(:kind "file" :path "/tmp/x.nix"
                         :chunks ((:text "a" :line-start 1 :line-end 1))) "test")
   (arc-index-source '(:kind "nix-option" :option-name "services.foo.enable"
                         :chunks ((:text "b" :line-start 1 :line-end 1))) "test")
   (let ((stats (arc-index-stats)))
     (should (= (alist-get "file" stats 0 nil #'equal) 1))
     (should (= (alist-get "nix-option" stats 0 nil #'equal) 1)))))
