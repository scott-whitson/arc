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

(ert-deftest asx-candidates-are-tagged-with-the-arm-that-found-them ()
  "Important-7(b): the marginalia must be able to say which arm a row
came from, which means the candidate has to carry that itself."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (let ((arc-rollup-function 'max))
     (should (eq (get-text-property
                  0 'arc-search-arm
                  (car (arc-search--candidates "alpha" '(:all t) 'keyword)))
                'keyword)))))

(ert-deftest asx-candidates-tag-a-fallback-to-keyword-honestly ()
  "A dead embedding endpoint on a requested fused search falls back to
the keyword arm's own results (see the previous test) -- those results
must be tagged `keyword', not `fused', or the marginalia would claim a
re-rank that never ran."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (cl-letf (((symbol-function 'llm-embedding)
              (lambda (&rest _) (error "connection refused"))))
     (let ((arc-rollup-function 'max))
       (should (eq (get-text-property
                    0 'arc-search-arm
                    (car (arc-search--candidates "alpha" '(:all t) nil)))
                  'keyword))))))

(ert-deftest asx-stage-annotation-reads-off-the-candidate ()
  (should (equal (arc-search--stage-annotation
                 (propertize "x" 'arc-search-arm 'keyword))
                "  keyword"))
  (should (equal (arc-search--stage-annotation
                 (propertize "x" 'arc-search-arm 'fused))
                "  fused"))
  (should (null (arc-search--stage-annotation (propertize "x" 'arc-document nil)))))

(defun asx--doc (id)
  "Return a minimal file-kind document plist identified by ID."
  (list :kind "file" :path (format "/tmp/%s.txt" id) :source-id id
        :chunk-count 1))

(defun asx--call-source-ids (call)
  "Return the `:source-id' list of candidates in CALL, a two-stage
callback argument -- nil unless CALL is a candidate list."
  (mapcar (lambda (c) (plist-get (get-text-property 0 'arc-document c) :source-id))
          call))

(ert-deftest asx-two-stage-paints-keyword-then-flushes-then-fused ()
  "Important-7(a): the fused arm must re-rank the WHOLE list, not just
the tail the keyword arm missed -- `consult--async-dynamic' only clears
its display on the FIRST callback and APPENDS on every later one, so an
earlier version sent only the fused arm's extras, freezing BM25's order
for everything it had already found. Sending `flush' between the two
calls clears the first paint (`consult--async-sink' treats the symbol
`flush' as \"clear the candidate list\"), so the second call's own
order -- the fused arm's real ranking, `b' before `a' here even though
the keyword arm found `a' first -- is what survives, not an append."
  (let* ((calls nil)
         (keyword-docs (list (asx--doc "a") (asx--doc "b")))
         (fused-docs (list (asx--doc "b") (asx--doc "a") (asx--doc "c"))))
    (cl-letf (((symbol-function 'arc-search-documents)
               (lambda (_query _scope &optional arm)
                 (if (eq arm 'keyword) keyword-docs fused-docs))))
      (arc-search--two-stage "alpha" '(:all t)
                             (lambda (docs) (push docs calls))))
    (setq calls (nreverse calls))
    (should (= (length calls) 3))
    (should (equal (asx--call-source-ids (nth 0 calls)) '("a" "b")))
    (should (eq (nth 1 calls) 'flush))
    (should (equal (asx--call-source-ids (nth 2 calls)) '("b" "a" "c")))))

(ert-deftest asx-command-is-guarded-on-consult ()
  (should (eq (fboundp 'arc-search) (featurep 'consult))))

(ert-deftest asx-no-autoload-cookie-hides-inside-a-conditional-block ()
  "Minor 10: `;;;###autoload' cookie extraction is line-based -- it does
not track that a defun is nested inside `(when (require \\='consult nil
t) ...)'. A cookie on an indented line here would generate an
unconditional autoload for `arc-search', so it would appear in `M-x'
completion, load this file, and only then fail as undefined on a
machine without consult. Every real autoload cookie in this file is at
column 0, directly above its top-level defun; an indented one is
exactly this bug."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "arc-search-ui.el" asx-root))
    (goto-char (point-min))
    (while (re-search-forward "^\\([ \t]*\\);;;###autoload" nil t)
      (should (string-empty-p (match-string 1))))))

(ert-deftest asx-arc-search-visits-the-best-matched-line-not-line-1 ()
  "Ruling T5-A extracted `arc-search--document-link' precisely because
`arc-source-link' defaults to line 1 when given no LINE, which is
wrong for a file result -- the passage that matched is almost never
the file's first line. `arc-search-visit' (the results-buffer path)
already goes through it; this is the consult front door, which must
resolve the same selected document to the same link. `consult--read'
is stubbed to hand back a canned document directly, so this covers the
selection-to-link step without driving an actual minibuffer session."
  (let* ((doc (list :kind "file" :path "/tmp/a.txt" :source-id "a"
                    :passages (list (list :line-start 42 :chunk "text"))))
         (opened nil))
    (cl-letf (((symbol-function 'consult--read) (lambda (&rest _) doc))
              ((symbol-function 'org-link-open-from-string)
               (lambda (link) (setq opened link))))
      (arc-search))
    (should (equal opened "[[file:/tmp/a.txt::42]]"))))

(provide 'test-arc-search-consult)
;;; test-arc-search-consult.el ends here
