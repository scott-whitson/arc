;;; test-arc-retrieve.el --- arc--retrieve-rows' schema-aware row lookup -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar ar-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ar-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-test-helpers)

(ert-deftest ar-retrieve-rows-joins-source-and-chunk-for-a-file ()
  "A file chunk's row must carry its path and text, across the sources join."
  (arc-test-with-temp-db
   (let* ((id (arc-index-source
               '(:kind "file" :path "/tmp/x.nix"
                 :chunks ((:text "alpha" :line-start 1 :line-end 1)))
               "test"))
          (rowid (caar (sqlite-select (arc-db) "SELECT id FROM data;")))
          (rows (arc--retrieve-rows (list rowid))))
     (ignore id)
     (should (= (length rows) 1))
     (should (equal (nth 0 (car rows)) "file"))
     (should (equal (nth 1 (car rows)) "/tmp/x.nix"))
     (should (equal (nth 5 (car rows)) "alpha")))))

(ert-deftest ar-retrieve-rows-joins-source-and-chunk-for-info ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "info" :info-node "(emacs)Top"
      :chunks ((:text "welcome to emacs" :line-start 1 :line-end 1)))
    "test")
   (let* ((rowid (caar (sqlite-select (arc-db) "SELECT id FROM data;")))
          (row (car (arc--retrieve-rows (list rowid)))))
     (should (equal (nth 0 row) "info"))
     (should (equal (nth 2 row) "(emacs)Top"))
     (should (equal (nth 5 row) "welcome to emacs")))))

(ert-deftest ar-retrieve-rows-empty-ids-yields-nil ()
  (arc-test-with-temp-db
   (should (null (arc--retrieve-rows nil)))))

;; ar-add-context-row-* and ar-retrieve-ask-is-no-longer-guarded used to
;; live here, exercising `arc--add-context-row' and `arc-retrieve-ask'.
;; Task 6 deleted both functions outright -- they existed only to feed
;; ellama's buffer and context, and `arc-ask' (see test-arc-ui.el) replaced
;; the whole path they fed -- so the tests that dispatched fake
;; `ellama-context-add-*' calls through them, and the one asserting
;; `arc-retrieve-ask' was no longer in the migration guard list, went with
;; them rather than being left to assert against void functions.

(ert-deftest ar-rerank-request-query-shape-matches-the-real-schema ()
  "`arc--rerank-request' selected `rowid, data FROM data' -- the `data'
table has had no `data' column since Task 4 (it is `chunk'), so this
raised `sqlite-error' the moment the reranker actually ran.
`arc-reranker-enabled' defaults to nil, which is exactly why nothing
caught it: this test exercises the query shape against a real schema
so it cannot rot silently again, reranker on or not."
  (arc-test-with-temp-db
   (let ((arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding) (lambda (&rest _) (vector 0.1 0.2 0.3))))
       (arc-index-source
        '(:kind "file" :path "/tmp/x.nix"
          :chunks ((:text "alpha" :line-start 1 :line-end 1)
                   (:text "beta"  :line-start 2 :line-end 2)))
        "test")))
   (let* ((ids (flatten-tree (sqlite-select (arc-db) "SELECT id FROM data ORDER BY id;")))
          (body (json-parse-string (arc--rerank-request "a prompt" ids)
                                    :object-type 'alist :array-type 'list))
          (docs (alist-get 'documents body)))
     (should (equal (alist-get 'query body) "a prompt"))
     (should (= (length docs) 2))
     (should (member "alpha" (mapcar (lambda (d) (alist-get 'text d)) docs)))
     (should (member "beta" (mapcar (lambda (d) (alist-get 'text d)) docs))))))

(ert-deftest er-normalize-scope-accepts-a-name-list ()
  "README documents (arc-ask \"prompt\" '(\"vault\")).  That must keep working."
  (should (equal (arc-ask-normalize-scope '("vault"))
                 (arc-scope :collections '("vault"))))
  (should (equal (arc-ask-normalize-scope '("a" "b"))
                 (arc-scope :collections '("a" "b")))))

(ert-deftest er-normalize-scope-passes-a-plist-through ()
  (let ((s (arc-scope :kinds '("org-node"))))
    (should (equal (arc-ask-normalize-scope s) s))))

(ert-deftest er-normalize-scope-nil-uses-enabled-collections ()
  (let ((arc-enabled-collections '("builtin manuals")))
    (should (equal (arc-ask-normalize-scope nil)
                   (arc-scope :collections '("builtin manuals"))))))

(ert-deftest er-no-sources-refuses-without-calling-the-model ()
  "The single behaviour most worth protecting: a config oracle that
confabulates a NixOS option is worse than no oracle."
  (let ((model-called nil)
        (rendered ""))
    (cl-letf (((symbol-function 'arc-answer-request)
               (lambda (&rest _) (setq model-called t)))
              ((symbol-function 'arc-find-similar)
               (lambda (_text _scope on-done &optional _on-error) (funcall on-done "SELECT 1 WHERE 0")))
              ((symbol-function 'arc--retrieve-ids) (lambda (&rest _) nil))
              ((symbol-function 'arc--retrieve-rows) (lambda (&rest _) nil))
              ((symbol-function 'arc-ui-begin-answer) (lambda (_q) (cons 1 1)))
              ((symbol-function 'arc-ui-buffer) (lambda () (current-buffer)))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil))
              ((symbol-function 'arc-ui-stream-answer)
               (lambda (_a text) (setq rendered text))))
      (arc-ask "anything" (arc-scope :collections '("vault")))
      (should-not model-called)
      (should (string-match-p "not enough data" rendered))
      (should (string-match-p "vault" rendered)))))
