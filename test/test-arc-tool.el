;;; test-arc-tool.el --- the agent-facing JSON verbs -*- lexical-binding: t; -*-
;;
;; These verbs are an interface something outside Emacs depends on, so the
;; shape is asserted, not assumed: an agent that cannot parse the output
;; has no other way to find out.
(require 'ert)
(require 'cl-lib)
(require 'json)
(defvar att-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path att-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-tool)
(require 'arc-test-helpers)

(defun att--parse (s)
  (let ((json-object-type 'alist) (json-array-type 'list))
    (json-read-from-string s)))

(ert-deftest att-search-returns-parseable-json-with-results ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (out (att--parse (arc-tool-search "alpha" "everything" 10 'keyword)))
          (results (alist-get 'results out)))
     (should (equal (alist-get 'query out) "alpha"))
     (should (= (length results) 1))
     (let ((r (car results)))
       (should (equal (alist-get 'path r) "/tmp/a.txt"))
       (should (numberp (alist-get 'score r)))
       (should (= (alist-get 'chunks r) 1))
       (should (stringp (alist-get 'text (car (alist-get 'passages r)))))))))

(ert-deftest att-search-with-no-match-returns-an-empty-array ()
  "An empty result must serialise as [] and not as null -- a consumer
that has to distinguish them will get it wrong otherwise."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha" :line-start 1 :line-end 1)))
    "test")
   (let ((out (arc-tool-search "zzzznomatch" "everything" 10 'keyword)))
     (should (string-match-p "\"results\":\\[\\]" out))
     (should (null (alist-get 'results (att--parse out)))))))

(ert-deftest att-search-rejects-an-unknown-scope-by-name ()
  (arc-test-with-temp-db
   (should-error (arc-tool-search "alpha" "nosuchscope" 10 'keyword))))

(ert-deftest att-search-rejects-an-unrecognised-arm-rather-than-mislabel-it ()
  "`arc--find-similar' silently falls through an unrecognised arm to
`fused'; `arc-tool-search' must not echo the caller's typo back in its
`:arm' field as though that arm had actually run."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (should-error (arc-tool-search "alpha" "everything" 10 'bogus))))

(ert-deftest att-search-normalises-a-nil-arm-to-fused-in-its-own-report ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let ((out (att--parse (arc-tool-search "alpha" "everything" 10 nil))))
       (should (equal (alist-get 'arm out) "fused"))))))

(ert-deftest att-scopes-lists-every-preset ()
  (let* ((out (att--parse (arc-tool-scopes)))
         (names (mapcar (lambda (s) (alist-get 'name s))
                        (alist-get 'scopes out))))
    (should (member "everything" names))
    (should (member "vault" names))))

(ert-deftest att-stats-reports-collections-and-freshness ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha" :line-start 1 :line-end 1)))
    "test")
   (let ((out (att--parse (arc-tool-stats))))
     (should (assq 'kinds out))
     (should (assq 'freshness out)))))

(ert-deftest att-stats-freshness-row-maps-kind-and-detail-correctly ()
  "`arc-freshness-report' rows are (NAME KIND STATE DETAIL).  KIND (the
chunker, e.g. `org') and DETAIL (a reason string, e.g. \"never
indexed\") are different claims; a row that emits KIND under the
`:detail' key -- and drops the real detail -- would tell a caller a
collection's kind is its freshness reason.  A never-indexed collection
makes KIND and DETAIL two different, unmistakable strings so that
mislabeling cannot pass by coincidence."
  (arc-test-with-temp-db
   (let* ((arc-index-plan '(("ghost-collection" . org)))
          (out (att--parse (arc-tool-stats)))
          (rows (alist-get 'freshness out))
          (row (car rows)))
     (should (= (length rows) 1))
     (should (equal (alist-get 'collection row) "ghost-collection"))
     (should (equal (alist-get 'kind row) "org"))
     (should (equal (alist-get 'state row) "absent"))
     (should (equal (alist-get 'detail row) "never indexed")))))

(provide 'test-arc-tool)
;;; test-arc-tool.el ends here
