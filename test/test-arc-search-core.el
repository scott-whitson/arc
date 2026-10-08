;;; test-arc-search-core.el --- search orchestration -*- lexical-binding: t; -*-
;;
;; Integration tests here use the `keyword' arm throughout: it skips the
;; embedding call entirely, so the suite never needs a reachable Ollama.
(require 'ert)
(require 'cl-lib)
(defvar asr-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asr-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-search)
(require 'arc-test-helpers)

(defun asr--index-file (path collection &rest texts)
  "Index TEXTS as consecutive chunks of one file source at PATH."
  (arc-index-source
   (list :kind "file" :path path
         :chunks (let ((n 0))
                   (mapcar (lambda (tx)
                             (setq n (1+ n))
                             (list :text tx :line-start n :line-end n))
                           texts)))
   collection))

(ert-deftest asr-pool-is-not-clamped-for-an-empty-scope ()
  (let ((arc-search-pool 200) (arc-knn-candidates 40))
    (should (= (arc-search--effective-pool (arc-scope)) 200))))

(ert-deftest asr-pool-never-drops-below-the-default-candidates ()
  (let ((arc-search-pool 5) (arc-knn-candidates 40))
    (should (= (arc-search--effective-pool (arc-scope)) 40))))

(ert-deftest asr-search-returns-documents-not-chunks ()
  "One source with five matching chunks is one result, not five."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test"
                    "alpha one" "alpha two" "alpha three"
                    "alpha four" "alpha five")
   (let* ((arc-rollup-function 'max)
          (docs (arc-search-documents "alpha" '(:all t) 'keyword)))
     (should (= (length docs) 1))
     (should (= (plist-get (car docs) :chunk-count) 5))
     (should (equal (plist-get (car docs) :path) "/tmp/a.txt")))))

(ert-deftest asr-search-hydrates-passages-with-text-and-lines ()
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha one" "alpha two")
   (let* ((arc-rollup-function 'max)
          (arc-rollup-passages 2)
          (doc (car (arc-search-documents "alpha" '(:all t) 'keyword)))
          (p (car (plist-get doc :passages))))
     (should (stringp (plist-get p :chunk)))
     (should (string-match-p "alpha" (plist-get p :chunk)))
     (should (integerp (plist-get p :line-start)))
     (should (numberp (plist-get p :score))))))

(ert-deftest asr-search-honours-the-document-limit ()
  (arc-test-with-temp-db
   (dotimes (i 6)
     (asr--index-file (format "/tmp/f%d.txt" i) "test" "alpha"))
   (let ((arc-search-limit 3)
         (arc-rollup-function 'max))
     (should (= (length (arc-search-documents "alpha" '(:all t) 'keyword)) 3)))))

(ert-deftest asr-search-respects-scope ()
  "A document outside the scope must never appear."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/in.txt" "keep" "alpha inside")
   (asr--index-file "/tmp/out.txt" "drop" "alpha outside")
   (let* ((arc-rollup-function 'max)
          (docs (arc-search-documents "alpha" '(:collections ("keep")) 'keyword)))
     (should (= (length docs) 1))
     (should (equal (plist-get (car docs) :path) "/tmp/in.txt")))))

(ert-deftest asr-search-on-no-match-yields-nil ()
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha")
   (should (null (arc-search-documents "zzzznomatch" '(:all t) 'keyword)))))

(ert-deftest asr-priority-rules-nil-preserve-baseline ()
  "Disabled personalization leaves the measured document order untouched."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha")
   (asr--index-file "/tmp/b.txt" "test" "alpha")
   (let ((arc-search-priority-rules nil)
         (arc-rollup-function 'max))
     (should (equal
              (mapcar (lambda (d) (plist-get d :path))
                      (arc-search-documents "alpha" '(:all t) 'keyword))
              '("/tmp/a.txt" "/tmp/b.txt"))))))

(ert-deftest asr-priority-rule-promotes-a-matching-source ()
  "A configured source can enter the final limited result set."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha")
   (asr--index-file "/tmp/b.txt" "test" "alpha")
   (let* ((arc-search-limit 1)
          (arc-rollup-function 'max)
          (arc-search-priority-rules
           '((:query "alpha" :path-prefix "/tmp/b" :boost 100)))
          (doc (car (arc-search-documents "alpha" '(:all t) 'keyword))))
     (should (equal (plist-get doc :path) "/tmp/b.txt"))
     (should (= (plist-get doc :priority-boost) 100))
     (should (numberp (plist-get doc :retrieval-score)))
     (should (> (plist-get doc :score) (plist-get doc :retrieval-score))))))

(ert-deftest asr-priority-rule-nonmatches-do-not-change-docs ()
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha")
   (asr--index-file "/tmp/b.txt" "test" "alpha")
   (let* ((arc-rollup-function 'max)
          (arc-search-priority-rules
           '((:query "beta" :path-prefix "/tmp/b" :boost 100)))
          (docs (arc-search-documents "alpha" '(:all t) 'keyword)))
     (should-not (plist-member (car docs) :priority-boost))
     (should (equal (mapcar (lambda (d) (plist-get d :path)) docs)
                    '("/tmp/a.txt" "/tmp/b.txt"))))))

(ert-deftest asr-priority-rules-reject-malformed-data ()
  (dolist (rules
           '((( :query "alpha" :boost 0 :kind "file"))
             ((:query "[" :boost 1 :kind "file"))
             ((:query "alpha" :boost 1))
             ((:query "alpha" :boost 1 :unknown "x"))
             ((:query "alpha" :boost 1 :kind nil))))
    (let ((arc-search-priority-rules rules))
      (should-error
       (arc-search--apply-priority-rules "alpha" nil)))))

(ert-deftest asr-priority-rule-ties-use-source-id ()
  "Equal boosted scores use the rollup comparator's final stable tie-break."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/a.txt" "test" "alpha")
   (asr--index-file "/tmp/b.txt" "test" "alpha")
   (let* ((arc-rollup-function 'max)
          (arc-search-priority-rules
           '((:query "alpha" :kind "file" :boost 100)))
          (docs (arc-search-documents "alpha" '(:all t) 'keyword)))
     (should (equal (mapcar (lambda (d) (plist-get d :path)) docs)
                    '("/tmp/a.txt" "/tmp/b.txt"))))))

(ert-deftest asr-deep-pool-does-not-flip-the-vector-plan ()
  "The clamp's whole purpose, pinned so the clamp actually engages.

`arc-scope-vector-plan' picks its strategy from `arc-scope-count' and
`arc-scope-total', both real row counts this suite cannot inflate into
the thousands. So the fixture instead shrinks `arc-scope-bruteforce-max'
and `arc-vec0-k-ceiling' until a 5-chunk scope reproduces the same
arithmetic a huge corpus would: with `arc-scope-bruteforce-max' 1 and
`arc-knn-candidates' 2, the base plan is `knn' at k = ceil(2 * 5/5) = 2.
Deepening to the full `arc-search-pool' of 200 would ask for k = 200,
which blows past a `arc-vec0-k-ceiling' of 10 and silently flips the
plan to `brute'. The clamp must instead land at
floor(10 * 5/5) = 10 -- strictly less than the 200 asked for, so the
clamp actually engaged rather than passing the pool through unchanged
-- and re-running the plan with that clamped pool must still come back
`knn'."
  (arc-test-with-temp-db
   (asr--index-file "/tmp/big.txt" "test"
                    "alpha" "beta" "gamma" "delta" "epsilon")
   (let* ((scope '(:collections ("test")))
          (arc-scope-bruteforce-max 1)
          (arc-knn-candidates 2)
          (arc-search-pool 200)
          ;; One source of five chunks, so one document is five chunks:
          ;; a limit of one asks for a pool of five, under the clamp's
          ;; ten, and the clamp is what decides. The case where the
          ;; floor wins instead is
          ;; `asr-the-clamp-never-shallows-below-what-the-limit-needs'.
          (arc-search-limit 1)
          (arc-vec0-k-ceiling 10)
          (base (car (arc-scope-vector-plan scope)))
          (pool (arc-search--effective-pool scope)))
     (should (eq base 'knn))
     (should (< pool arc-search-pool))
     (let ((arc-knn-candidates pool))
       (should (eq (car (arc-scope-vector-plan scope)) base))))))

(ert-deftest asr-the-clamp-never-shallows-below-what-the-limit-needs ()
  "The clamp is a RATIO of the corpus, so it shrinks as the corpus grows
while the scope does not: its engagement threshold moved from 3,091
chunks to 15,174 when the corpus went from 63,302 to 310,767.  A scope
that was comfortably unclamped is now handed a pool too shallow to
produce `arc-search-limit' documents -- a silently short answer, which
is worse than the slow one the clamp exists to prevent.

The fixture is the same shrunken-constants trick as
`asr-deep-pool-does-not-flip-the-vector-plan': one source of ten
chunks, so ten chunks is ONE document, and a limit of two needs twenty.
The plan-preserving clamp lands at floor(10 * 10/10) = 10 -- one
document where two were asked for.  The floor must win."
  (arc-test-with-temp-db
   (apply #'asr--index-file "/tmp/prose.txt" "test"
          (mapcar #'number-to-string (number-sequence 1 10)))
   (let* ((scope '(:collections ("test")))
          (arc-scope-bruteforce-max 1)
          (arc-knn-candidates 2)
          (arc-search-pool 200)
          (arc-search-limit 2)
          (arc-vec0-k-ceiling 10))
     (should (eq 'knn (car (arc-scope-vector-plan scope))))
     ;; ten chunks, one source -> ten chunks per document
     (should (= 20 (arc-search--minimum-pool scope)))
     (should (= 20 (arc-search--effective-pool scope))))))

(ert-deftest asr-the-floor-is-still-capped-by-the-pool-ceiling ()
  "`arc-search-pool' is a hard ceiling over the floor as well: no scope
may ask for more depth than an unscoped query would."
  (arc-test-with-temp-db
   (apply #'asr--index-file "/tmp/prose.txt" "test"
          (mapcar #'number-to-string (number-sequence 1 10)))
   (let* ((scope '(:collections ("test")))
          (arc-scope-bruteforce-max 1)
          (arc-knn-candidates 2)
          (arc-search-pool 12)
          (arc-search-limit 5)          ; would want 50 chunks
          (arc-vec0-k-ceiling 10))
     (should (= 50 (arc-search--minimum-pool scope)))
     (should (= 12 (arc-search--effective-pool scope))))))

(ert-deftest asr-minimum-pool-is-measured-from-the-scope-not-assumed ()
  "A one-chunk-per-document scope needs `arc-search-limit' chunks, not
hundreds -- which is why this is measured rather than a constant, and
why the real `nix options'-shaped scopes keep the pool they have."
  (arc-test-with-temp-db
   (dotimes (i 10)
     (asr--index-file (format "/tmp/opt%d.txt" i) "test" "one chunk only"))
   (let ((arc-knn-candidates 2)
         (arc-search-limit 3))
     (should (= 3 (arc-search--minimum-pool '(:collections ("test"))))))))

;;; --- the exact arm -------------------------------------------------------
;;
;; `exact' is a literal, case-insensitive substring match over the stored
;; chunk text: the arm to reach for when the user already knows the string
;; and BM25's tokenizer would not land on it.  It never embeds, like
;; `keyword', so these tests stub only the indexing call.

(ert-deftest asr-exact-arm-finds-a-literal-substring-case-insensitively ()
  (arc-test-with-temp-db
   (let ((arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
       (asr--index-file "/tmp/a.txt" "test" "The Disko Layout")
       (let ((arc-rollup-function 'max))
         (should (= 1 (length (arc-search-documents "disko" '(:all t) 'exact))))
         ;; the case-insensitivity is the point: the chunk spells it `Disko'
         (should (= 1 (length (arc-search-documents "DISKO" '(:all t) 'exact)))))))))

(ert-deftest asr-exact-arm-respects-scope ()
  "A substring present in two collections is narrowed by the scope."
  (arc-test-with-temp-db
   (let ((arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
       (asr--index-file "/tmp/in.txt" "keep" "needle here")
       (asr--index-file "/tmp/out.txt" "drop" "needle too")
       (let* ((arc-rollup-function 'max)
              (docs (arc-search-documents "needle" '(:collections ("keep")) 'exact)))
         (should (= 1 (length docs)))
         (should (equal (plist-get (car docs) :path) "/tmp/in.txt")))))))

(ert-deftest asr-exact-arm-treats-like-wildcards-as-literal-text ()
  "`%' and `_' in the query match themselves, not any text."
  (arc-test-with-temp-db
   (let ((arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
       (asr--index-file "/tmp/pct.txt" "test" "50% off today")
       (asr--index-file "/tmp/plain.txt" "test" "no percent here")
       (let ((arc-rollup-function 'max))
         ;; An unescaped `%' would be a LIKE wildcard matching every chunk.
         (should (= 1 (length (arc-search-documents "%" '(:all t) 'exact)))))))))

(ert-deftest asr-exact-arm-quotes-a-single-quote-in-the-query ()
  "A `'' in the query must not end the SQL string literal early."
  (arc-test-with-temp-db
   (let ((arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
       (asr--index-file "/tmp/q.txt" "test" "it's a quote")
       (let ((arc-rollup-function 'max))
         (should (= 1 (length (arc-search-documents "it's" '(:all t) 'exact)))))))))

(ert-deftest asr-exact-arm-treats-a-backslash-as-literal ()
  "A `\\' is where the escape order matters: it is doubled first, so the
`%'/`_' escapes added after it are not themselves re-escaped."
  (arc-test-with-temp-db
   (let ((arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
       (asr--index-file "/tmp/bs.txt" "test" "path C:\\Users\\x")
       (asr--index-file "/tmp/nobs.txt" "test" "no backslash here")
       (let ((arc-rollup-function 'max))
         (should (= 1 (length (arc-search-documents "C:\\Users" '(:all t) 'exact)))))))))

(provide 'test-arc-search-core)
;;; test-arc-search-core.el ends here
