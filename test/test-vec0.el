;;; test-vec0.el --- validate sqlite-vec SQL forms -*- lexical-binding: t; -*-
(require 'ert)
(require 'json)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)

(defvar tv-vec0 (arc-test-locate-vec0))
(unless tv-vec0
  (message "SKIP: no sqlite-vec (vec0) extension found -- set ARC_VEC0_PATH to run this suite")
  (kill-emacs 0))

(defun tv-lit (v) (format "vec_f32('%s')" (json-encode v)))

(ert-deftest tv-create-insert-knn ()
  (should (fboundp 'sqlite-load-extension))
  (should (file-exists-p tv-vec0))
  (let ((db (sqlite-open)))            ; in-memory
    (sqlite-load-extension db tv-vec0)
    (sqlite-execute db "CREATE VIRTUAL TABLE t USING vec0(embedding float[3]);")
    (sqlite-execute db (format "INSERT INTO t(rowid, embedding) VALUES (1, %s);" (tv-lit [1.0 0.0 0.0])))
    (sqlite-execute db (format "INSERT INTO t(rowid, embedding) VALUES (2, %s);" (tv-lit [0.0 1.0 0.0])))
    (sqlite-execute db (format "INSERT INTO t(rowid, embedding) VALUES (3, %s);" (tv-lit [0.9 0.1 0.0])))
    (let ((res (sqlite-select
                db (format "SELECT rowid, distance FROM t WHERE embedding MATCH %s AND k = 2 ORDER BY distance ASC;"
                           (tv-lit [1.0 0.0 0.0])))))
      ;; nearest to [1,0,0] is rowid 1, then rowid 3
      (should (equal (mapcar #'car res) '(1 3))))))
