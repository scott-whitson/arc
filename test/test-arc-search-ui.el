;;; test-arc-search-ui.el --- the results buffer -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar asu-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asu-root)
(require 'arc-search-ui)

(defvar asu--docs
  '((:source-id 1 :kind "file" :path "/tmp/a.nix" :title "a.nix"
     :org-id nil :option-name nil :info-node nil
     :score 0.5 :chunk-count 3 :best-rank 0
     :passages ((:chunk "alpha one" :line-start 1 :line-end 1 :score 0.5)
                (:chunk "alpha two" :line-start 9 :line-end 9 :score 0.4)))
    (:source-id 2 :kind "file" :path "/tmp/b.nix" :title "b.nix"
     :org-id nil :option-name nil :info-node nil
     :score 0.2 :chunk-count 1 :best-rank 5
     :passages ((:chunk "alpha three" :line-start 4 :line-end 4 :score 0.2))))
  "Two documents in the shape `arc-search-documents' returns.")

(ert-deftest asu-render-lists-every-document ()
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "a\\.nix" (buffer-string)))
    (should (string-match-p "b\\.nix" (buffer-string)))))

(ert-deftest asu-render-shows-the-query-and-the-count ()
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "alpha" (buffer-string)))
    (should (string-match-p "2 document" (buffer-string)))))

(ert-deftest asu-render-shows-chunk-counts ()
  "A document that matched three times must say so -- that signal is the
reason rollup exists, and hiding it in the ranking alone wastes it."
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "3 match" (buffer-string)))))

(ert-deftest asu-render-is-read-only-and-in-results-mode ()
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (eq major-mode 'arc-results-mode))
    (should buffer-read-only)))

(ert-deftest asu-render-of-nothing-says-so ()
  (arc-search-render nil "zzz" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (should (string-match-p "No documents" (buffer-string)))))

(ert-deftest asu-every-document-line-carries-its-plist ()
  "RET and TAB read the document off the line's text property."
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (goto-char (point-min))
    (should (re-search-forward "a\\.nix" nil t))
    (should (plist-get (get-text-property (point) 'arc-document) :source-id))))

;; F3 regression pin: the brief's `arc-search-toggle-passages' rendered
;; `(list full)' -- a one-element list holding only the expanded document
;; -- so expanding document 1 silently deleted document 2 from the
;; buffer. `arc-search--splice-document' and
;; `arc-search--rerender-preserving-point' are exercised directly here,
;; with no database and no live query, so this pins the fix without
;; needing `arc-search-toggle-passages' itself to run against a corpus.
(ert-deftest asu-toggle-passages-splice-preserves-other-documents ()
  "Expanding the first document must not discard the second."
  (arc-search-render asu--docs "alpha" '(:all t))
  (with-current-buffer arc-search-results-buffer-name
    (goto-char (point-min))
    (should (re-search-forward "a\\.nix" nil t))
    (let* ((full (list :source-id 1 :kind "file" :path "/tmp/a.nix" :title "a.nix"
                        :org-id nil :option-name nil :info-node nil
                        :score 0.5 :chunk-count 3 :best-rank 0
                        :passages '((:chunk "alpha one" :line-start 1 :line-end 1 :score 0.5)
                                    (:chunk "alpha two" :line-start 9 :line-end 9 :score 0.4)
                                    (:chunk "alpha extra" :line-start 20 :line-end 20 :score 0.3))))
           (spliced (arc-search--splice-document arc-search--docs full)))
      (should (= (length spliced) 2))
      (arc-search--rerender-preserving-point spliced)
      (should (string-match-p "a\\.nix" (buffer-string)))
      (should (string-match-p "b\\.nix" (buffer-string)))
      (should (string-match-p "alpha extra" (buffer-string)))
      ;; Point should have returned to document 1's line, not the top.
      (should (equal (plist-get (get-text-property (point) 'arc-document) :source-id) 1)))))

(ert-deftest asu-splice-document-leaves-other-documents-untouched-by-identity ()
  "The non-matching document is the very same plist, not a copy or a rebuild."
  (let* ((full (list :source-id 1 :kind "file" :path "/tmp/a.nix" :title "a.nix"
                      :org-id nil :option-name nil :info-node nil
                      :score 0.9 :chunk-count 9 :best-rank 0 :passages nil))
         (spliced (arc-search--splice-document asu--docs full)))
    (should (eq (nth 1 spliced) (nth 1 asu--docs)))
    (should (eq (nth 0 spliced) full))))

(ert-deftest asu-splice-document-with-no-match-returns-docs-unchanged ()
  "A corpus change that makes the re-query miss must not blank the buffer."
  (let* ((full (list :source-id 99 :kind "file" :path "/tmp/z.nix" :title "z.nix"
                      :org-id nil :option-name nil :info-node nil
                      :score 0.1 :chunk-count 1 :best-rank 0 :passages nil))
         (spliced (arc-search--splice-document asu--docs full)))
    (should (equal spliced asu--docs))))

(provide 'test-arc-search-ui)
;;; test-arc-search-ui.el ends here
