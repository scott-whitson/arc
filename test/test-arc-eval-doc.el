;;; test-arc-eval-doc.el --- document-level recall -*- lexical-binding: t; -*-
;;
;; The eval set already expresses document-level ground truth: :expect
;; clauses match :kind, :option-name and :path-suffix, which are source
;; identity, not chunk identity.  Document recall therefore needs no new
;; question set, only a scorer that reads arc-search-documents' output.
(require 'ert)
(defvar aed-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aed-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-eval)
(require 'arc-search)
(require 'arc-test-helpers)

(ert-deftest aed-recall-is-one-when-the-expected-document-is-found ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/syncthing.nix"
      :chunks ((:text "services syncthing enable" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (set '((:question "syncthing"
                  :scope (:all t)
                  :expect ((:kind "file" :path-suffix "syncthing.nix"))))))
     (should (= (arc-eval-document-recall set 5 'keyword) 1.0)))))

(ert-deftest aed-recall-is-zero-when-it-is-not ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/other.nix"
      :chunks ((:text "something unrelated" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (set '((:question "syncthing"
                  :scope (:all t)
                  :expect ((:kind "file" :path-suffix "syncthing.nix"))))))
     (should (= (arc-eval-document-recall set 5 'keyword) 0.0)))))

(provide 'test-arc-eval-doc)
;;; test-arc-eval-doc.el ends here
