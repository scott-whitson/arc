;;; test-arc-lazy.el --- loading arc must not touch the model -*- lexical-binding: t; -*-
(require 'ert)
(defvar al-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path al-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))

(ert-deftest al-require-does-not-embed ()
  "Requiring arc must not call the embedding provider."
  (let ((called nil))
    (cl-letf (((symbol-function 'llm-embedding)
               (lambda (&rest _) (setq called t) (make-vector 768 0.0))))
      (require 'arc)
      (should-not called))))

(ert-deftest al-db-is-a-function ()
  (require 'arc)
  (should (fboundp 'arc-db))
  (should-not (and (boundp 'arc-db) (sqlitep (symbol-value 'arc-db)))))

(ert-deftest al-embedding-size-is-configurable ()
  (require 'arc)
  (should (integerp arc-embedding-size)))
