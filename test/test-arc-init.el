;;; test-arc-init.el -*- lexical-binding: t; -*-
(require 'ert)
(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest ei-no-vss-symbols ()
  (arc-test-with-temp-db
   (should (boundp 'arc-sqlite-vec-path))
   (should-not (fboundp 'arc--vss-path))
   (should-not (fboundp 'arc-download-sqlite-vss))
   (should-not (boundp 'arc-sqlite-vss-path))))

(ert-deftest ei-embeddings-table-is-vec0 ()
  (arc-test-with-temp-db
   ;; data_embeddings must exist and be a vec0 virtual table
   (let ((sql (caar (sqlite-select
                     (arc-db)
                     "SELECT sql FROM sqlite_master WHERE name = 'data_embeddings';"))))
     (should (string-match-p "USING vec0" sql)))))
