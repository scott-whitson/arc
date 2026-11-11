;;; test-arc-eval-doc.el --- document-level recall -*- lexical-binding: t; -*-
;;
;; The eval set already expresses document-level ground truth: :expect
;; clauses match :kind, :option-name and :path-suffix, which are source
;; identity, not chunk identity.  Document recall therefore needs no new
;; question set, only a scorer that reads arc-search-documents' output.
(require 'ert)
(require 'cl-lib)
(defvar aed-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aed-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-eval)
(require 'arc-search)
(require 'arc-test-helpers)

(ert-deftest aed-recall-is-one-when-the-expected-document-is-found ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/syncthing.nix"
      :chunks ((:text "services syncthing enable" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (set '((:question "syncthing"
                  :scope (:all t)
                  :expect ((:kind "file" :path-suffix "syncthing.nix"))))))
     (should (= (arc-eval-document-recall set 5 'keyword) 1.0)))))

(ert-deftest aed-recall-is-zero-when-it-is-not ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/other.nix"
      :chunks ((:text "something unrelated" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (set '((:question "syncthing"
                  :scope (:all t)
                  :expect ((:kind "file" :path-suffix "syncthing.nix"))))))
     (should (= (arc-eval-document-recall set 5 'keyword) 0.0)))))

;;; End to end over a synthetic index: cache, fuse, sweep, report -------

(defun aed-vec (text)
  "A deterministic 3-d embedding: which of three topics TEXT is about.
TEXT's length perturbs every axis, so no two texts tie on distance and
the rankings under test are fully determined."
  (let ((l (/ (length text) 100.0)))
    (vector (+ (if (string-match-p "syncthing" text) 1.0 0.0) l)
            (+ (if (string-match-p "firewall" text) 1.0 0.0) (/ l 2))
            (+ (if (string-match-p "bread\\|peru" text) 1.0 0.0) (/ l 3)))))

(defmacro aed-with-corpus (&rest body)
  `(let ((arc-embedding-size 3))
     (arc-test-with-temp-db
      (cl-letf (((symbol-function 'llm-embedding) (lambda (_p text) (aed-vec text))))
        (dolist (src '(("/c/syncthing.nix" "services syncthing enable devices folders")
                       ("/c/firewall.nix" "networking firewall allowed ports")
                       ("/c/other.txt" "an unrelated note about bread")))
          (arc-index-source (list :kind "file" :path (car src)
                                  :chunks (list (list :text (cadr src) :line-start 1 :line-end 1)))
                            "test"))
        ,@body))))

(defconst aed-set
  '((:question "how is syncthing set up" :scope (:all t) :split dev
     :expect ((:path-suffix "syncthing.nix")))
    (:question "which firewall ports are open" :scope (:all t) :split test
     :expect ((:any (:path-suffix "firewall.nix") (:path-suffix "nope.nix"))))
    (:question "what is the capital of peru" :scope (:all t) :split dev :negative t)))

(ert-deftest aed-cached-arms-reproduce-the-live-fused-ranking ()
  "The offline RRF at the shipped settings must give the same top chunks
the live fused query does -- otherwise every sweep number is about a
different ranker."
  (aed-with-corpus
   (let ((cache (arc-eval-cache-arms aed-set)))
     (should (= 3 (length cache)))
     (dolist (e cache)
       (should (plist-get e :semantic))
       (should (equal (plist-get e :live-ids)
                      (take 10 (mapcar #'car (arc-eval-fuse e (arc-eval-shipped-config)
                                                            arc-knn-candidates)))))))))

(ert-deftest aed-semantic-arm-distance-is-cosine-distance ()
  (aed-with-corpus
   (let* ((cache (arc-eval-cache-arms (list (car aed-set))))
          (top (car (plist-get (car cache) :semantic))))
     ;; nearest is the syncthing chunk, and the distance is cosine's:
     ;; 1 - cos between the two vectors, recomputed here by hand
     (let* ((a (aed-vec "how is syncthing set up"))
            (b (aed-vec "services syncthing enable devices folders"))
            (dot (cl-loop for i below 3 sum (* (aref a i) (aref b i))))
            (norm (lambda (v) (sqrt (cl-loop for i below 3 sum (* (aref v i) (aref v i)))))))
       (should (< (abs (- (nth 2 top) (- 1 (/ dot (* (funcall norm a) (funcall norm b))))))
                  1e-4))))))

(ert-deftest aed-keyword-arm-matches-the-shipped-keyword-query ()
  (aed-with-corpus
   (let* ((q "firewall ports")
          (scope (arc-scope-normalize '(:all t)))
          (shipped (flatten-tree (sqlite-select (arc-db) (arc--find-similar q scope 'keyword))))
          (cached (mapcar #'car (sqlite-select (arc-db) (arc-eval--arm-sql-keyword scope q 40)))))
     (should (equal shipped (take (length shipped) cached))))))

(ert-deftest aed-report-runs-end-to-end ()
  (aed-with-corpus
   (let ((report (arc-eval-report-string aed-set)))
     (should (string-match-p "dev 1 positive \\+ 1 negative, test 1 positive \\+ 0 negative" report))
     (should (string-match-p "^shipped" report))
     (should (string-match-p "^cc-dbsf" report))
     (should (string-match-p "test document +R@5 1\\.000" report))
     (should (string-match-p "negative n=1" report))
     (should (string-match-p ":live-seconds" report)))))

(ert-deftest aed-document-level-run-scores-groups ()
  (aed-with-corpus
   (let* ((results (arc-eval-run-documents (take 2 aed-set) 'keyword))
          (m (arc-eval-metrics (arc-eval--positive-ranks results))))
     (should (= 1.0 (alist-get 10 (plist-get m :recall)))))))

(provide 'test-arc-eval-doc)
;;; test-arc-eval-doc.el ends here
