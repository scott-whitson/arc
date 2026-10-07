;;; test-arc-recalculate-embeddings.el --- a provider change rebuilds vectors -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar are-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path are-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(defun are--fake-embeddings (texts)
  "One fixed-width vector per TEXT, so no provider is contacted."
  (mapcar (lambda (_text) (make-vector arc-embedding-size 0.1)) texts))

(defun are--seed-chunks ()
  "Insert one source and two chunks, and return the source id."
  (let ((sid (arc-source-upsert '(:kind "file" :path "/tmp/are.nix" :hash "h"))))
    (sqlite-execute (arc-db)
     (format "INSERT INTO data (source_id, chunk, line_start, line_end)
              VALUES (%d, 'alpha', 1, 1);" sid))
    (sqlite-execute (arc-db)
     (format "INSERT INTO data (source_id, chunk, line_start, line_end)
              VALUES (%d, 'beta', 2, 2);" sid))
    sid))

(defun are--embedding-count ()
  (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;")))

(defun are--chunk-count ()
  (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))

(ert-deftest are-recalculate-embeds-every-stored-chunk ()
  "The stale body read a `data' column the schema renamed to `chunk';
this is the end-to-end path that would have failed on it."
  (arc-test-with-temp-db
   (are--seed-chunks)
   (should (= 0 (are--embedding-count)))
   (cl-letf (((symbol-function 'arc-embeddings) #'are--fake-embeddings))
     (arc-recalculate-embeddings))
   (should (= 2 (are--embedding-count)))
   (should (= 2 (are--chunk-count)))))

(ert-deftest are-recalculate-is-idempotent ()
  "Running it twice leaves one embedding per chunk, not two."
  (arc-test-with-temp-db
   (are--seed-chunks)
   (cl-letf (((symbol-function 'arc-embeddings) #'are--fake-embeddings))
     (arc-recalculate-embeddings)
     (arc-recalculate-embeddings))
   (should (= 2 (are--embedding-count)))
   (should (= 2 (are--chunk-count)))))

(ert-deftest are-recalculate-drops-emptied-chunks ()
  (arc-test-with-temp-db
   (let ((sid (arc-source-upsert '(:kind "file" :path "/tmp/are2.nix" :hash "h"))))
     (sqlite-execute (arc-db)
      (format "INSERT INTO data (source_id, chunk, line_start, line_end)
               VALUES (%d, '', 1, 1);" sid))
     (sqlite-execute (arc-db)
      (format "INSERT INTO data (source_id, chunk, line_start, line_end)
               VALUES (%d, 'keep', 2, 2);" sid)))
   (cl-letf (((symbol-function 'arc-embeddings) #'are--fake-embeddings))
     (arc-recalculate-embeddings))
   (should (= 1 (are--chunk-count)))
   (should (= 1 (are--embedding-count)))))

(ert-deftest are-recalculate-accepts-a-new-dimension ()
  "The point of the whole function: a width change is rebuilt, not rejected."
  (arc-test-with-temp-db
   (are--seed-chunks)
   (let ((arc-embedding-size 8))
     (cl-letf (((symbol-function 'arc-embeddings)
                (lambda (texts) (mapcar (lambda (_t) (make-vector 8 0.1)) texts))))
       (arc-recalculate-embeddings)))
   ;; The table now admits 8-wide vectors rather than the default 768.
   (should (string-match-p
            "float\\[8\\]"
            (caar (sqlite-select (arc-db)
                    "SELECT sql FROM sqlite_master WHERE name='data_embeddings';"))))
   (should (= 2 (are--embedding-count)))))

(provide 'test-arc-recalculate-embeddings)
;;; test-arc-recalculate-embeddings.el ends here
