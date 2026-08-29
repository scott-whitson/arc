;;; test-augur-search.el -*- lexical-binding: t; -*-
(require 'ert)
(defvar es-repo-root
  ;; captured at load time: load-file-name is nil once a test body runs
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path es-repo-root)
(setenv "AUGUR_VEC0_PATH"
        (or (getenv "AUGUR_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'augur)

(ert-deftest es-vector-literal ()
  (should (equal (augur-vector-to-sqlite [0.5 0.25])
                 "vec_f32('[0.5,0.25]')")))

(ert-deftest es-knn-roundtrip ()
  (let ((db (sqlite-open)))
    (sqlite-load-extension db augur-sqlite-vec-path)
    (sqlite-execute db "CREATE VIRTUAL TABLE data_embeddings USING vec0(embedding float[3]);")
    (dolist (row '((1 . [1.0 0.0 0.0]) (2 . [0.0 1.0 0.0]) (3 . [0.9 0.1 0.0])))
      (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%d, %s);"
                                 (car row) (augur-vector-to-sqlite (cdr row)))))
    (let ((res (sqlite-select
                db (format "SELECT rowid, distance FROM data_embeddings WHERE embedding MATCH %s AND k = 2 ORDER BY distance ASC;"
                           (augur-vector-to-sqlite [1.0 0.0 0.0])))))
      (should (equal (mapcar #'car res) '(1 3))))))

(ert-deftest es-async-injects-vec-path ()
  ;; the async worker must no longer reference the removed vars
  (with-temp-buffer
    (insert-file-contents (expand-file-name "augur.el" es-repo-root))
    (should (search-forward "async-inject-variables \"augur-sqlite-vec-path\"" nil t))
    (goto-char (point-min))
    (should-not (search-forward "augur-sqlite-vss-path" nil t))
    (goto-char (point-min))
    (should-not (search-forward "augur-sqlite-vector-path" nil t))))
