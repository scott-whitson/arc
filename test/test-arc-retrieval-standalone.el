;;; test-arc-retrieval-standalone.el --- arc retrieves with no chat model -*- lexical-binding: t; -*-
;;
;; The deletion suite proves the answer path is absent.  This one proves the
;; remaining program is whole: that a caller can load arc, scope a query,
;; retrieve ranked chunks and get them back as JSON, without any chat model
;; existing in the image.  If arc had quietly depended on the answer layer for
;; something structural, this is where it shows.
(require 'ert)
(require 'cl-lib)
(require 'json)
(defvar ars-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ars-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc-test-helpers)
(require 'arc)
(require 'arc-tool)
(require 'arc-search-ui)

(ert-deftest ars-arc-loads-without-a-chat-model ()
  "Loading the package must not require, reference or construct one."
  (should (featurep 'arc))
  (should-not (boundp 'arc-chat-provider))
  (should (boundp 'arc-embeddings-provider)))

(defun ars--with-vault-fixture (function)
  "Index a temporary file through the real file-source path, then call FUNCTION.
The embedding function is stubbed so indexing itself stays Ollama-free; the
retrieval assertions below use the keyword arm and never call embeddings."
  (let ((path (make-temp-file "arc-standalone-vault-" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "arc standalone keyword fixture\n"))
          (cl-letf (((symbol-function 'llm-embedding)
                     (lambda (&rest _)
                       (make-vector arc-embedding-size 0.0))))
            (arc-index-source (arc-file-source path) "vault"))
          (funcall function path))
      (when (file-exists-p path)
        (delete-file path)))))

(defun ars--parse-json (string)
  "Parse STRING as an alist with list-valued JSON arrays."
  (let ((json-object-type 'alist)
        (json-array-type 'list))
    (json-read-from-string string)))

(ert-deftest ars-the-keyword-arm-retrieves-with-no-model-at-all ()
  "The `keyword' arm returns an indexed source without calling Ollama."
  (arc-test-with-temp-db
   (ars--with-vault-fixture
    (lambda (path)
      (cl-letf (((symbol-function 'llm-embedding)
                 (lambda (&rest _)
                   (error "standalone test must not call Ollama"))))
        (let* ((query-text "standalone keyword")
               (scope (arc-scope-normalize '("vault")))
               (query (arc--find-similar query-text scope 'keyword))
               (ids (flatten-tree (sqlite-select (arc-db) query)))
               (sources (mapcar #'arc-row-to-source
                                (arc--retrieve-rows ids))))
          (should sources)
          (should (equal (plist-get (car sources) :path) path))
          (should (string-match-p "arc standalone keyword fixture"
                                  (plist-get (car sources) :chunk)))))))))

(ert-deftest ars-the-tool-surface-returns-the-same-keyword-result ()
  "`arc-tool-search' returns parseable JSON for the indexed fixture."
  (arc-test-with-temp-db
   (ars--with-vault-fixture
    (lambda (path)
      (cl-letf (((symbol-function 'llm-embedding)
                 (lambda (&rest _)
                   (error "standalone test must not call Ollama"))))
        (let* ((out (ars--parse-json
                     (arc-tool-search "standalone keyword" "vault" 10 'keyword)))
               (results (alist-get 'results out))
               (first (car results))
               (passage (car (alist-get 'passages first))))
          (should (equal (alist-get 'query out) "standalone keyword"))
          (should (equal (alist-get 'arm out) "keyword"))
          (should results)
          (should (= (alist-get 'count out) 1))
          (should (equal (alist-get 'path first) path))
          (should (string-match-p "arc standalone keyword fixture"
                                  (alist-get 'text passage)))))))))

(ert-deftest ars-the-tool-surface-answers-a-caller ()
  "arc-tool.el is how an outside agent reaches retrieval now.
`arc-search' is guarded behind consult and must not be asserted here;
`arc-search-show' is the unconditional entry point."
  (should (fboundp 'arc-tool-search))
  (should (fboundp 'arc-tool-scopes))
  (should (fboundp 'arc-search-show)))

(provide 'test-arc-retrieval-standalone)
;;; test-arc-retrieval-standalone.el ends here
