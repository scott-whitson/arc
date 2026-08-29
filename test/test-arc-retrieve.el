;;; test-arc-retrieve.el --- arc-retrieve-ask's schema-aware row lookup -*- lexical-binding: t; -*-
(require 'ert)
(defvar ar-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ar-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
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

(ert-deftest ar-add-context-row-dispatches-file-to-file-quote ()
  (let (captured)
    (cl-letf (((symbol-function 'ellama-context-add-file-quote-noninteractive)
               (lambda (path content) (setq captured (list path content)))))
      (arc--add-context-row '("file" "/tmp/x.nix" nil nil nil "alpha")))
    (should (equal captured '("/tmp/x.nix" "alpha")))))

(ert-deftest ar-add-context-row-dispatches-info-to-info-node-quote ()
  (let (captured)
    (cl-letf (((symbol-function 'ellama-context-add-info-node-quote-noninteractive)
               (lambda (node content) (setq captured (list node content)))))
      (arc--add-context-row '("info" nil "(emacs)Top" nil nil "welcome")))
    (should (equal captured '("(emacs)Top" "welcome")))))

(ert-deftest ar-add-context-row-dispatches-org-node-to-text ()
  (let (captured)
    (cl-letf (((symbol-function 'ellama-context-add-text)
               (lambda (text) (setq captured text))))
      (arc--add-context-row '("org-node" nil nil "abc-123" nil "note body")))
    (should (string-match-p "abc-123" captured))
    (should (string-match-p "note body" captured))))

(ert-deftest ar-add-context-row-dispatches-nix-option-to-text ()
  (let (captured)
    (cl-letf (((symbol-function 'ellama-context-add-text)
               (lambda (text) (setq captured text))))
      (arc--add-context-row '("nix-option" nil nil nil "services.foo.enable" "Option text")))
    (should (string-match-p "services.foo.enable" captured))
    (should (string-match-p "Option text" captured))))

(ert-deftest ar-add-context-row-with-no-chunk-does-nothing ()
  (let (called)
    (cl-letf (((symbol-function 'ellama-context-add-text)
               (lambda (_text) (setq called t))))
      (arc--add-context-row '("file" "/tmp/x.nix" nil nil nil nil)))
    (should-not called)))

(ert-deftest ar-retrieve-ask-is-no-longer-guarded ()
  (should-not (memq 'arc-retrieve-ask arc--unmigrated-functions)))

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
