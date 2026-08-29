;;; test-arc-lazy.el --- loading arc must not touch the model -*- lexical-binding: t; -*-
(require 'ert)
(defvar al-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path al-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))

(ert-deftest al-require-does-not-touch-disk-or-model ()
  "Requiring arc must not create the database file or call the embedding model."
  (when (featurep 'arc)
    (unload-feature 'arc t))
  (let* ((tmp (make-temp-file "arc-lazy-test-" t))
         (arc-db-directory tmp))
    (unwind-protect
        (progn
          (require 'arc)
          (should-not (directory-files-recursively tmp "\\`arc\\.sqlite\\'"))
          (should (null arc--db)))
      (delete-directory tmp t))))

(ert-deftest al-db-is-a-function ()
  (require 'arc)
  (should (fboundp 'arc-db))
  (should-not (and (boundp 'arc-db) (sqlitep (symbol-value 'arc-db)))))

(ert-deftest al-embedding-size-is-configurable ()
  (require 'arc)
  (should (integerp arc-embedding-size)))
