;;; test-arc-search-consult.el --- the minibuffer source -*- lexical-binding: t; -*-
;;
;; consult is an optional dependency: arc must load and pass without it.
;; These tests therefore exercise the candidate builder, which is plain
;; elisp, and assert the command is guarded rather than unconditional.
(require 'ert)
(defvar asx-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asx-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-search-ui)
(require 'arc-test-helpers)

(ert-deftest asx-candidates-carry-their-document ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (cands (arc-search--candidates "alpha" '(:all t) 'keyword)))
     (should (= (length cands) 1))
     (should (stringp (car cands)))
     (should (plist-get (get-text-property 0 'arc-document (car cands))
                        :source-id)))))

(ert-deftest asx-candidates-of-an-empty-query-are-nil ()
  "Consult calls the source on every keystroke, including the first
empty one.  That must not become a full-corpus query."
  (arc-test-with-temp-db
   (should (null (arc-search--candidates "" '(:all t) 'keyword)))
   (should (null (arc-search--candidates "   " '(:all t) 'keyword)))))

(ert-deftest asx-candidates-survive-a-dead-embedding-endpoint ()
  "Stage two must fail soft: an unreachable Ollama returns the keyword
results, not an error thrown out of the minibuffer."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (cl-letf (((symbol-function 'llm-embedding)
              (lambda (&rest _) (error "connection refused"))))
     (let ((arc-rollup-function 'max))
       (should (= (length (arc-search--candidates "alpha" '(:all t) nil)) 1))))))

(defun asx--doc (id)
  "Return a minimal file-kind document plist identified by ID."
  (list :kind "file" :path (format "/tmp/%s.txt" id) :source-id id
        :chunk-count 1))

(ert-deftest asx-two-stage-calls-back-twice-with-disjoint-source-ids ()
  "The sink `arc-search--two-stage' feeds only clears on the FIRST
callback and APPENDS on every later one in the same invocation, so the
second callback must carry only what the first did not -- otherwise
every document both arms found would render twice."
  (let* ((calls nil)
         (keyword-docs (list (asx--doc "a") (asx--doc "b")))
         (fused-docs (list (asx--doc "b") (asx--doc "c"))))
    (cl-letf (((symbol-function 'arc-search-documents)
               (lambda (_query _scope &optional arm)
                 (if (eq arm 'keyword) keyword-docs fused-docs))))
      (arc-search--two-stage "alpha" '(:all t)
                             (lambda (docs) (push docs calls))))
    (setq calls (nreverse calls))
    (should (= (length calls) 2))
    (should (equal (mapcar (lambda (c)
                              (plist-get (get-text-property 0 'arc-document c)
                                        :source-id))
                           (nth 0 calls))
                   '("a" "b")))
    (should (equal (mapcar (lambda (c)
                              (plist-get (get-text-property 0 'arc-document c)
                                        :source-id))
                           (nth 1 calls))
                   '("c")))))

(ert-deftest asx-command-is-guarded-on-consult ()
  (should (eq (fboundp 'arc-search) (featurep 'consult))))

(provide 'test-arc-search-consult)
;;; test-arc-search-consult.el ends here
