;;; test-arc-scored.el --- retrieval can return its scores -*- lexical-binding: t; -*-
;;
;; arc--find-similar computed RRF scores and threw them away: the fused arm
;; selected hybrid_search.id alone.  Document rollup needs the score, so the
;; function grew an optional `scored' argument.  These tests pin both halves --
;; that scored SQL really returns (id score) pairs in rank order, and that an
;; unscored call is unchanged, because arc-ask and arc-eval both depend on the
;; single-column shape.
(require 'ert)
(require 'cl-lib)
(defvar asc-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asc-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-test-helpers)

(defun asc--index (text)
  "Index TEXT as a one-chunk file source in collection \"test\"."
  (arc-index-source
   (list :kind "file" :path (format "/tmp/%s.txt" (md5 text))
         :chunks (list (list :text text :line-start 1 :line-end 1)))
   "test"))

(ert-deftest asc-unscored-keyword-sql-selects-one-column ()
  "An unscored call must keep the single-column shape arc-ask depends on."
  (let ((sql (arc--find-similar "alpha" nil 'keyword)))
    (should (string-match-p "SELECT keyword_search\\.id FROM" sql))
    (should-not (string-match-p "AS score" sql))))

(ert-deftest asc-scored-keyword-sql-selects-a-score ()
  (let ((sql (arc--find-similar "alpha" nil 'keyword t)))
    (should (string-match-p "AS score" sql))))

(ert-deftest asc-scored-keyword-returns-id-score-pairs ()
  "Two columns per row, scores descending with rank."
  (arc-test-with-temp-db
   (asc--index "alpha beta gamma")
   (asc--index "alpha delta")
   (let* ((sql (arc--find-similar "alpha" nil 'keyword t))
          (rows (sqlite-select (arc-db) sql)))
     (should (= (length rows) 2))
     (should (= (length (car rows)) 2))
     (should (cl-every #'numberp (mapcar #'cadr rows)))
     (should (>= (cadr (nth 0 rows)) (cadr (nth 1 rows)))))))

(ert-deftest asc-unscored-keyword-returns-one-column ()
  (arc-test-with-temp-db
   (asc--index "alpha beta")
   (let* ((sql (arc--find-similar "alpha" nil 'keyword))
          (rows (sqlite-select (arc-db) sql)))
     (should (= (length (car rows)) 1)))))

(provide 'test-arc-scored)
;;; test-arc-scored.el ends here
