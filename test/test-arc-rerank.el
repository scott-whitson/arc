;;; test-arc-rerank.el --- the reranker path, which has never run -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'ert)
(defvar ar-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ar-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest ar-request-body-selects-the-chunk-column ()
  "`data' has had no `data' column since the schema rewrite.  The
reranker asked for one anyway, and nothing noticed for two phases
because the feature defaults to off."
  (arc-test-with-temp-db
   (let* ((db (arc-db))
          (sid (arc-source-upsert (list :kind "file" :path "/x.txt"))))
     (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, NULL, 'hello world');" sid))
     (let* ((rid (caar (sqlite-select db "SELECT last_insert_rowid();")))
            (body (arc--rerank-request "q" (list rid))))
       (should (string-match-p "hello world" body))
       (should (string-match-p "\"query\":\"q\"" body))))))

(ert-deftest ar-threshold-nil-keeps-everything ()
  (let ((arc-reranker-similarity-threshold nil)
        (arc-limit 3))
    (cl-letf (((symbol-function 'arc--do-rerank-request)
               (lambda (_p _i) '(((id . 1) (similarity . 0.9))
                                 ((id . 2) (similarity . 0.1))
                                 ((id . 3) (similarity . -0.4))))))
      (should (equal (arc-rerank "q" '(1 2 3)) '(1 2 3))))))

(ert-deftest ar-threshold-drops-below-cutoff ()
  (let ((arc-reranker-similarity-threshold 0.5)
        (arc-limit 3))
    (cl-letf (((symbol-function 'arc--do-rerank-request)
               (lambda (_p _i) '(((id . 1) (similarity . 0.9))
                                 ((id . 2) (similarity . 0.1))))))
      (should (equal (arc-rerank "q" '(1 2)) '(1))))))

(ert-deftest ar-threshold-can-refuse-everything ()
  "A threshold that filters every candidate must yield nil, which
`arc-ask' then turns into a refusal -- not an empty context block."
  (let ((arc-reranker-similarity-threshold 0.99)
        (arc-limit 3))
    (cl-letf (((symbol-function 'arc--do-rerank-request)
               (lambda (_p _i) '(((id . 1) (similarity . 0.2))))))
      (should (null (arc-rerank "q" '(1)))))))

(ert-deftest ar-empty-ids-makes-no-request ()
  (let ((called nil))
    (cl-letf (((symbol-function 'plz) (lambda (&rest _) (setq called t) nil)))
      (should (null (arc--do-rerank-request "q" nil)))
      (should-not called))))

(ert-deftest ar-threshold-defaults-to-nil-not-zero ()
  "`0' reads as \"off\" but is not: it silently discards every
negatively-scored chunk.  `nil' is the value that means no filtering.
This test exists because every other test in this file `let'-binds the
threshold and so cannot notice the default regressing."
  (should (null (default-value 'arc-reranker-similarity-threshold))))
