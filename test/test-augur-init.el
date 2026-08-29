;;; test-augur-init.el -*- lexical-binding: t; -*-
(require 'ert)
(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))
(setenv "AUGUR_VEC0_PATH"
        (or (getenv "AUGUR_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))

(ert-deftest ei-no-vss-symbols ()
  (require 'augur)
  (should (boundp 'augur-sqlite-vec-path))
  (should-not (fboundp 'augur--vss-path))
  (should-not (fboundp 'augur-download-sqlite-vss))
  (should-not (boundp 'augur-sqlite-vss-path)))

(ert-deftest ei-embeddings-table-is-vec0 ()
  (require 'augur)
  ;; data_embeddings must exist and be a vec0 virtual table
  (let ((sql (caar (sqlite-select
                    augur-db
                    "SELECT sql FROM sqlite_master WHERE name = 'data_embeddings';"))))
    (should (string-match-p "USING vec0" sql))))
