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

(ert-deftest ae2-run-never-calls-the-chat-model ()
  "Retrieval only, by design: a run must stay fast and deterministic."
  (let ((model-called nil))
    (cl-letf (((symbol-function 'arc-answer-request)
               (lambda (&rest _) (setq model-called t)))
              ((symbol-function 'arc-eval--retrieve)
               (lambda (&rest _) '((:kind "nix-option" :option-name "services.example.enable")))))
      (arc-eval-run (arc-eval-read-set ae2-sample))
      (should-not model-called))))

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
