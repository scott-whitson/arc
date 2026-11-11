;;; test-arc-search.el -*- lexical-binding: t; -*-
(require 'ert)
(defvar es-repo-root
  ;; captured at load time: load-file-name is nil once a test body runs
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path es-repo-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)

(ert-deftest es-vector-literal ()
  (should (equal (arc-vector-to-sqlite [1.0 0.0])
                 "vec_f32('[1.0,0.0]')")))

(defun es-norm (v) (sqrt (seq-reduce (lambda (a x) (+ a (* x x))) v 0.0)))

(ert-deftest es-vector-literal-is-unit-length ()
  "A provider's unscaled vector reaches sqlite scaled to unit length."
  (let* ((lit (arc-vector-to-sqlite [3.0 4.0]))
         (v (json-read-from-string
             (progn (string-match "vec_f32('\\(.*\\)')" lit) (match-string 1 lit)))))
    (should (< (abs (- (es-norm v) 1.0)) 1e-12))
    (should (< (abs (- (aref v 0) 0.6)) 1e-12))))

(ert-deftest es-unit-and-zero-vectors-pass-through-untouched ()
  "What is already stored is unit length; normalising must not rewrite it."
  (let ((unit [0.6 0.8]) (zero [0.0 0.0]))
    (should (eq (arc--unit-vector unit) unit))
    (should (eq (arc--unit-vector zero) zero))))

(ert-deftest es-knn-and-brute-force-rank-alike-on-unscaled-input ()
  "The two vector paths cannot disagree.  These vectors are chosen so
they WOULD: unscaled, rowid 2 is nearest the query by L2 (vec0's KNN
metric) but farthest by cosine (brute force's), because it is short
and pointing away.  Through `arc-vector-to-sqlite' both orders match."
  (let ((db (sqlite-open))
        (rows '((1 . [10.0 1.0 0.0]) (2 . [0.3 0.3 0.0]) (3 . [5.0 2.0 0.0])))
        (q [1.0 0.0 0.0]))
    (sqlite-load-extension db arc-sqlite-vec-path)
    (sqlite-execute db "CREATE VIRTUAL TABLE data_embeddings USING vec0(embedding float[3]);")
    ;; the premise: raw vectors order differently under the two metrics
    (let ((raw-l2 (sort (mapcar #'car rows)
                        (lambda (a b)
                          (< (es-norm (cl-map 'vector #'- (alist-get a rows) q))
                             (es-norm (cl-map 'vector #'- (alist-get b rows) q)))))))
      (should (equal (car raw-l2) 2)))
    (dolist (row rows)
      (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%d, %s);"
                                 (car row) (arc-vector-to-sqlite (cdr row)))))
    (let* ((lit (arc-vector-to-sqlite q))
           (knn (mapcar #'car (sqlite-select
                               db (format "SELECT rowid FROM data_embeddings
                                           WHERE embedding MATCH %s AND k = 3
                                           ORDER BY distance ASC;" lit))))
           (brute (mapcar #'car (sqlite-select
                                 db (format "SELECT rowid FROM data_embeddings
                                             ORDER BY vec_distance_cosine(embedding, %s) ASC;"
                                            lit))))
           (pairs (sqlite-select
                   db (format "SELECT distance, vec_distance_cosine(embedding, %s)
                               FROM data_embeddings WHERE embedding MATCH %s AND k = 3;"
                              lit lit))))
      (should (equal knn brute))
      (should (equal knn '(1 3 2)))
      ;; and the threshold relation `arc-retrieval-max-distance' documents
      (dolist (p pairs)
        (should (< (abs (- (/ (* (car p) (car p)) 2) (cadr p))) 1e-5))))))

(ert-deftest es-knn-roundtrip ()
  (let ((db (sqlite-open)))
    (sqlite-load-extension db arc-sqlite-vec-path)
    (sqlite-execute db "CREATE VIRTUAL TABLE data_embeddings USING vec0(embedding float[3]);")
    (dolist (row '((1 . [1.0 0.0 0.0]) (2 . [0.0 1.0 0.0]) (3 . [0.9 0.1 0.0])))
      (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%d, %s);"
                                 (car row) (arc-vector-to-sqlite (cdr row)))))
    (let ((res (sqlite-select
                db (format "SELECT rowid, distance FROM data_embeddings WHERE embedding MATCH %s AND k = 2 ORDER BY distance ASC;"
                           (arc-vector-to-sqlite [1.0 0.0 0.0])))))
      (should (equal (mapcar #'car res) '(1 3))))))

(ert-deftest es-async-injects-vec-path ()
  ;; the async worker must no longer reference the removed vars
  (with-temp-buffer
    (insert-file-contents (expand-file-name "arc.el" es-repo-root))
    (should (search-forward "async-inject-variables \"arc-sqlite-vec-path\"" nil t))
    (goto-char (point-min))
    (should-not (search-forward "arc-sqlite-vss-path" nil t))
    (goto-char (point-min))
    (should-not (search-forward "arc-sqlite-vector-path" nil t))))
