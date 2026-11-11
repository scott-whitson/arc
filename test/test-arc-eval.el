;;; test-arc-eval.el --- the eval harness -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar ae2-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ae2-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc-eval)

(defconst ae2-sample (expand-file-name "test/fixtures/eval-set-sample.eld" ae2-root))

;;; Matching -----------------------------------------------------------------

(ert-deftest ae2-matches-on-kind-and-option-name ()
  (let ((s '(:kind "nix-option" :option-name "services.foo.enable")))
    (should (arc-eval--source-matches-p s '(:kind "nix-option")))
    (should (arc-eval--source-matches-p s '(:option-name "services.foo.enable")))
    (should (arc-eval--source-matches-p
             s '(:kind "nix-option" :option-name "services.foo.enable")))))

(ert-deftest ae2-every-key-must-match-not-any ()
  "A clause is an AND.  If it were an OR, a set would report hits it did
not get."
  (let ((s '(:kind "nix-option" :option-name "services.foo.enable")))
    (should-not (arc-eval--source-matches-p
                 s '(:kind "nix-option" :option-name "services.bar.enable")))
    (should-not (arc-eval--source-matches-p
                 s '(:kind "hm-option" :option-name "services.foo.enable")))))

(ert-deftest ae2-path-suffix-matches-the-tail-only ()
  "Sets must stay portable across machines, so paths match by suffix."
  (let ((s '(:kind "file" :path "/home/someone/dotfiles/ioshi/net/sync.nix")))
    (should (arc-eval--source-matches-p s '(:path-suffix "ioshi/net/sync.nix")))
    (should-not (arc-eval--source-matches-p s '(:path-suffix "ioshi/net/other.nix")))
    ;; A bare :path is exact, and must NOT accidentally suffix-match.
    (should-not (arc-eval--source-matches-p s '(:path "ioshi/net/sync.nix")))))

(ert-deftest ae2-path-suffix-on-a-source-with-no-path ()
  (should-not (arc-eval--source-matches-p
               '(:kind "nix-option" :option-name "x") '(:path-suffix "y.nix"))))

(ert-deftest ae2-unknown-expect-key-is-an-error ()
  "A typo in a question set must not read as a permanent retrieval failure."
  (should-error (arc-eval--source-matches-p '(:kind "file") '(:pathsuffix "x"))))

;;; Ranking ------------------------------------------------------------------

(ert-deftest ae2-rank-is-one-based-and-first-match-wins ()
  (let ((sources '((:kind "file" :path "/a/x.nix")
                   (:kind "nix-option" :option-name "services.foo.enable")
                   (:kind "nix-option" :option-name "services.foo.enable"))))
    (should (= 1 (arc-eval--rank-of '(:kind "file") sources)))
    (should (= 2 (arc-eval--rank-of '(:option-name "services.foo.enable") sources)))
    (should (null (arc-eval--rank-of '(:option-name "nope") sources)))))

;;; Recall -------------------------------------------------------------------

(ert-deftest ae2-recall-respects-the-cutoff ()
  (let ((results (list (list :question "q1" :ranks '((nil . 1) (nil . 7)))
                       (list :question "q2" :ranks '((nil . nil))))))
    ;; 3 expectations total; at k=5 only rank 1 counts; at k=10 ranks 1 and 7.
    (should (= 0 (round (* 100 (- (arc-eval-recall results 5) (/ 1.0 3))))))
    (should (= 0 (round (* 100 (- (arc-eval-recall results 10) (/ 2.0 3))))))))

(ert-deftest ae2-recall-of-nothing-is-zero-not-an-error ()
  (should (= 0.0 (arc-eval-recall nil 5))))

;;; Reading the set ----------------------------------------------------------

(ert-deftest ae2-sample-set-parses-and-validates ()
  (let ((set (arc-eval-read-set ae2-sample)))
    (should (= 3 (length set)))
    (should (stringp (plist-get (car set) :question)))))

(ert-deftest ae2-missing-file-is-a-user-error-naming-the-defcustom ()
  (let ((err (should-error (arc-eval-read-set "/nonexistent/arc-eval.eld")
                           :type 'user-error)))
    (should (string-match-p "arc-eval-set-file" (error-message-string err)))))

(ert-deftest ae2-rejects-a-set-whose-entry-has-no-expect ()
  (let ((f (make-temp-file "arc-eval" nil ".eld")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "((:question \"q with no expect\"))"))
          (should-error (arc-eval-read-set f) :type 'user-error))
      (delete-file f))))

(ert-deftest ae2-rejects-a-set-whose-entry-has-no-question ()
  (let ((f (make-temp-file "arc-eval" nil ".eld")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "((:expect ((:kind \"file\"))))"))
          (should-error (arc-eval-read-set f) :type 'user-error))
      (delete-file f))))

(ert-deftest ae2-rejects-an-empty-set ()
  (let ((f (make-temp-file "arc-eval" nil ".eld")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "()"))
          (should-error (arc-eval-read-set f) :type 'user-error))
      (delete-file f))))

;;; Run ---------------------------------------------------------------------

(ert-deftest ae2-run-uses-retrieval-only-results ()
  "Retrieval-only runs consume the retrieval result for each question."
  (let ((retrieved 0))
    (cl-letf (((symbol-function 'arc-eval--retrieve)
               (lambda (&rest _)
                 (setq retrieved (1+ retrieved))
                 '((:kind "nix-option" :option-name "services.example.enable")))))
      (let* ((set (arc-eval-read-set ae2-sample))
             (results (arc-eval-run set)))
        (should (= retrieved (length results)))
        (should (= retrieved (length set)))))))

(ert-deftest ae2-run-reports-hits-and-misses ()
  (cl-letf (((symbol-function 'arc-eval--retrieve)
             (lambda (&rest _)
               '((:kind "nix-option" :option-name "services.example.enable")))))
    (let* ((results (arc-eval-run (arc-eval-read-set ae2-sample)))
           (first (car results))
           (second (nth 1 results)))
      (should (= 1 (cdar (plist-get first :ranks))))       ; option found at 1
      (should (null (cdar (plist-get second :ranks))))     ; the file was not
      (should (= 1.0 (arc-eval-recall (list first) 5))))))

(ert-deftest ae2-run-asks-for-the-largest-k ()
  "Recall@10 is meaningless if retrieval only ever fetched 5."
  (let (asked)
    (cl-letf (((symbol-function 'arc-eval--retrieve)
               (lambda (_q _s k &optional _arm) (setq asked k) nil)))
      (let ((arc-eval-k '(5 10 25)))
        (arc-eval-run (arc-eval-read-set ae2-sample)))
      (should (= asked 25)))))

(ert-deftest ae2-document-recall-ignores-priority-rules ()
  "Eval measures baseline retrieval, never explicit display personalization."
  (let (seen)
    (cl-letf (((symbol-function 'arc-search-documents)
               (lambda (&rest _)
                 (setq seen arc-search-priority-rules)
                 '((:kind "file" :path "/tmp/expected.nix")))))
      (let ((arc-search-priority-rules
             '((:query "q" :path-prefix "/tmp" :boost 100)))
            (set '((:question "q"
                    :expect ((:kind "file" :path "/tmp/expected.nix"))))))
        (should (= 1.0 (arc-eval-document-recall set 1)))
        (should (null seen))))))

;;; AND-of-OR groups -----------------------------------------------------------

(ert-deftest ae2-a-plain-clause-is-a-group-of-one ()
  "Backward compatibility: a set written before groups existed reads as
one group per clause, which is exactly what it always meant."
  (let ((q '(:question "q" :expect ((:kind "file") (:option-name "x")))))
    (should (equal '(((:kind "file")) ((:option-name "x"))) (arc-eval--groups q)))))

(ert-deftest ae2-an-any-group-is-hit-by-any-member ()
  (let* ((q '(:question "q" :expect ((:any (:path-suffix "a.nix") (:path-suffix "b.nix"))
                                     (:option-name "opt"))))
         (sources '((:kind "file" :path "/x/b.nix")
                    (:kind "nix-option" :option-name "opt")
                    (:kind "file" :path "/x/a.nix")))
         (groups (arc-eval--groups q)))
    (should (= 1 (arc-eval--group-rank (car groups) sources)))
    (should (= 2 (arc-eval--group-rank (cadr groups) sources)))))

(ert-deftest ae2-run-reports-one-rank-per-group ()
  (cl-letf (((symbol-function 'arc-eval--retrieve)
             (lambda (&rest _) '((:kind "file" :path "/x/b.nix")))))
    (let* ((set '((:question "q"
                   :expect ((:any (:path-suffix "a.nix") (:path-suffix "b.nix"))
                            (:option-name "missing")))))
           (r (car (arc-eval-run set))))
      (should (equal '(1 nil) (mapcar #'cdr (plist-get r :ranks))))
      ;; one of two groups found: recall is per group, not per member
      (should (= 0.5 (arc-eval-recall (list r) 10))))))

(ert-deftest ae2-sample-set-scores-as-it-always-did ()
  "The shipped synthetic set, which has no groups, must produce the
same ranks and recall it did before groups existed."
  (cl-letf (((symbol-function 'arc-eval--retrieve)
             (lambda (&rest _)
               '((:kind "file" :path "/r/modules/example.nix")
                 (:kind "nix-option" :option-name "services.example.enable")))))
    (let ((results (arc-eval-run (arc-eval-read-set ae2-sample))))
      (should (equal '((2) (1) (2 1))
                     (mapcar (lambda (r) (mapcar #'cdr (plist-get r :ranks))) results)))
      (should (= 1.0 (arc-eval-recall results 5))))))

(ert-deftest ae2-an-empty-any-group-is-rejected ()
  (let ((f (make-temp-file "arc-eval" nil ".eld")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "((:question \"q\" :expect ((:any))))"))
          (should-error (arc-eval-read-set f) :type 'user-error))
      (delete-file f))))

(ert-deftest ae2-validate-checks-every-group-member ()
  (let ((set '((:question "q"
                :expect ((:any (:path-suffix "real.nix") (:path-suffix "typo.nix"))))))
        (sources '((:kind "file" :path "/x/real.nix"))))
    (should (equal '(("q" :path-suffix "typo.nix")) (arc-eval-validate set sources)))))

;;; Negatives and splits ---------------------------------------------------------

(ert-deftest ae2-a-negative-needs-no-expect-and-scores-no-recall ()
  (let ((f (make-temp-file "arc-eval" nil ".eld")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "((:question \"nothing here\" :negative t)
                                      (:question \"q\" :expect ((:kind \"file\"))))"))
          (let ((set (arc-eval-read-set f)))
            (cl-letf (((symbol-function 'arc-eval--retrieve)
                       (lambda (&rest _) '((:kind "file" :path "/a")))))
              (let ((results (arc-eval-run set)))
                (should (plist-get (car results) :negative))
                (should (null (plist-get (car results) :ranks)))
                (should (= 1.0 (arc-eval-recall results 5)))))))
      (delete-file f))))

(ert-deftest ae2-a-negative-with-expectations-is-rejected ()
  (let ((f (make-temp-file "arc-eval" nil ".eld")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "((:question \"q\" :negative t :expect ((:kind \"file\"))))"))
          (should-error (arc-eval-read-set f) :type 'user-error))
      (delete-file f))))

(ert-deftest ae2-split-is-explicit-or-a-stable-hash ()
  (should (eq 'test (arc-eval-question-split '(:question "anything" :split test))))
  (let* ((qs (cl-loop for i below 1000 collect (list :question (format "question number %d" i))))
         (dev (cl-count 'dev (mapcar #'arc-eval-question-split qs))))
    (should (< 630 dev 770))
    ;; stable: same text, same answer, whatever else is in the set
    (should (eq (arc-eval-question-split '(:question "question number 7"))
                (arc-eval-question-split (nth 7 qs))))))

(ert-deftest ae2-a-bad-split-is-rejected ()
  (let ((f (make-temp-file "arc-eval" nil ".eld")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "((:question \"q\" :split train :expect ((:kind \"file\"))))"))
          (should-error (arc-eval-read-set f) :type 'user-error))
      (delete-file f))))

;;; Metrics ----------------------------------------------------------------------

(defun ae2-near (a b) (< (abs (- a b)) 1e-6))

(ert-deftest ae2-ndcg-ideal-is-the-number-of-groups ()
  "One (:any A B C) group found first is a perfect ranking.  Taking the
ideal from the three flattened members would score it 1/2.13 instead."
  (should (ae2-near 1.0 (arc-eval--ndcg '(1) 10)))
  (should (ae2-near (/ 1.0 (+ 1 (/ 1.0 (log 3 2)))) (arc-eval--ndcg '(1 nil) 10)))
  (should (ae2-near (/ (/ 1.0 (log 3 2)) 1.0) (arc-eval--ndcg '(2) 10)))
  (should (ae2-near 0.0 (arc-eval--ndcg '(11) 10))))

(ert-deftest ae2-ndcg-is-capped-when-groups-share-a-rank ()
  (should (ae2-near 1.0 (arc-eval--ndcg '(1 1) 10))))

(ert-deftest ae2-mrr-averages-reciprocal-ranks-over-groups ()
  (let ((m (arc-eval-metrics '((1 nil) (2) (nil)) '(5 10))))
    (should (ae2-near (/ (+ 0.5 0.5 0.0) 3) (plist-get m :mrr)))
    (should (= 4 (plist-get m :groups)))
    (should (ae2-near 0.5 (alist-get 5 (plist-get m :recall))))))

;;; Offline fusion -----------------------------------------------------------------

(defun ae2-entry (sem kw)
  "A cache entry with arms SEM ((ID RANK DISTANCE)...) and KW ((ID RANK BM25)...)."
  (list :q '(:question "q") :semantic sem :keyword kw
        :sources (make-hash-table)))

(ert-deftest ae2-rrf-is-the-shipped-formula ()
  (let* ((e (ae2-entry '((1 1 0.1) (2 2 0.2)) '((2 1 -5.0) (3 2 -1.0))))
         (fused (arc-eval-fuse e '(:method rrf :k 60 :w 2) 40)))
    (should (equal '(2 1 3) (mapcar #'car fused)))
    (should (ae2-near (+ (/ 2.0 62) (/ 1.0 61)) (cdr (assq 2 fused))))
    (should (ae2-near (/ 2.0 61) (cdr (assq 1 fused))))))

(ert-deftest ae2-fusion-respects-the-arm-depth ()
  (let ((e (ae2-entry '((1 1 0.1) (2 2 0.2) (3 3 0.3)) nil)))
    (should (equal '(1 2) (mapcar #'car (arc-eval-fuse e '(:method rrf :k 60 :w 1) 2))))))

(ert-deftest ae2-convex-combination-at-the-extremes-is-one-arm ()
  (let ((e (ae2-entry '((1 1 0.1) (2 2 0.5) (3 3 0.9)) '((3 1 -9.0) (2 2 -4.0) (1 3 -1.0)))))
    (dolist (norm '(minmax tmm zscore dbsf))
      (should (equal '(1 2 3) (mapcar #'car (arc-eval-fuse e (list :method 'cc :norm norm :w 1.0) 40))))
      (should (equal '(3 2 1) (mapcar #'car (arc-eval-fuse e (list :method 'cc :norm norm :w 0.0) 40)))))))

(ert-deftest ae2-normalizations-have-their-definitions ()
  (let ((scores '((1 . 1.0) (2 . 2.0) (3 . 3.0))))
    (let ((n (arc-eval--normalize scores 'minmax nil)))
      (should (ae2-near 0.5 (gethash 2 (car n)))) (should (= 0.0 (cdr n))))
    ;; theoretical floor -1, observed ceiling 3
    (should (ae2-near 0.5 (gethash 1 (car (arc-eval--normalize scores 'tmm -1.0)))))
    (let ((n (arc-eval--normalize scores 'zscore nil)))
      (should (ae2-near 0.0 (gethash 2 (car n))))
      (should (ae2-near (gethash 1 (car n)) (cdr n))))
    (should (ae2-near 0.5 (gethash 2 (car (arc-eval--normalize scores 'dbsf nil)))))))

(ert-deftest ae2-sweep-tunes-on-dev-only ()
  (let (splits)
    (cl-letf (((symbol-function 'arc-eval-score-config)
               (lambda (_c _config split) (push split splits)
                 '(:chunk (:ndcg ((10 . 0.0))) :document (:ndcg ((10 . 0.0)) :recall ((10 . 0.0)))))))
      (let ((best (arc-eval-sweep nil)))
        (should (equal '(rrf cc-minmax cc-tmm cc-zscore cc-dbsf) (mapcar #'car best)))
        ;; every config tied, so the first tried -- the shipped one -- wins rrf
        (should (equal (arc-eval-shipped-config) (cadr (assq 'rrf best))))))
    (should (equal '(dev) (delete-dups splits)))))

(ert-deftest ae2-latency-drops-the-warmup-query ()
  (should (equal '(4 2.0 4.0) (arc-eval-latency '(100.0 1.0 2.0 3.0 4.0)))))

(ert-deftest ae2-quantiles-by-nearest-rank ()
  (should (equal '(1 2 3 4 5) (arc-eval--quantiles '(5 3 1 4 2 2.5 3.5 4.5)))))
