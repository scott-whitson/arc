;;; test-arc-source-info.el --- Info manuals as sources -*- lexical-binding: t; -*-
;; Uses the real, built-in "info" manual (the manual about the Info reader
;; itself) as its fixture. It ships with every Emacs, is tiny, and its
;; walk terminates well before any node repeats -- no network, no
;; embeddings provider, and nothing installed by this repo is needed.
(require 'ert)
(defvar asi-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asi-root)
(require 'arc-source-info)

(ert-deftest asi-parse-info-manual-returns-alist-of-node-and-text ()
  (let ((nodes (arc-parse-info-manual "info")))
    (should (consp nodes))
    (should (cl-every #'consp nodes))
    (should (cl-every (lambda (n) (stringp (car n))) nodes))
    (should (cl-every (lambda (n) (stringp (cdr n))) nodes))))

(ert-deftest asi-parse-info-manual-finds-top-node ()
  (should (assoc "Top" (arc-parse-info-manual "info"))))

(ert-deftest asi-parse-info-manual-has-no-duplicate-nodes ()
  (let ((names (mapcar #'car (arc-parse-info-manual "info"))))
    (should (= (length names) (length (delete-dups (copy-sequence names)))))))

(ert-deftest asi-parse-info-manual-does-not-write-to-a-database ()
  "This is now a pure function: it must not require `arc-db' to run."
  (should-not (featurep 'sqlite)))

(ert-deftest asi-info-valid-p-rejects-nonexistent-manual ()
  (should-not (arc--info-valid-p "arc-no-such-manual-xyz")))

(ert-deftest asi-info-valid-p-accepts-real-manual ()
  (should (arc--info-valid-p "info")))

(ert-deftest asi-sources-carry-kind-and-node-identity ()
  (let* ((sources (arc-info-sources '("info")))
         (s (car sources)))
    (should (equal (plist-get s :kind) "info"))
    (should (stringp (plist-get s :info-node)))
    (should (string-prefix-p "(info)" (plist-get s :info-node)))))

(ert-deftest asi-sources-carry-one-chunk-per-node ()
  (let* ((sources (arc-info-sources '("info")))
         (s (car sources))
         (chunks (plist-get s :chunks)))
    (should (= (length chunks) 1))
    (should (stringp (plist-get (car chunks) :text)))
    (should (plist-get (car chunks) :line-start))))

(ert-deftest asi-sources-count-matches-node-count ()
  (should (= (length (arc-info-sources '("info")))
             (length (arc-parse-info-manual "info")))))

(ert-deftest asi-invalid-manual-yields-no-sources ()
  (should-not (arc-info-sources '("arc-no-such-manual-xyz"))))

(ert-deftest asi-builtin-manuals-include-bash ()
  ;; Not "emacs": `file-name-base' only strips one extension, so a
  ;; gzipped manual (emacs.info.gz) comes back as "emacs.info", not
  ;; "emacs" -- a pre-existing upstream quirk, moved here unchanged
  ;; and out of this task's scope.  bash.info ships uncompressed.
  (should (member "bash" (arc-get-builtin-manuals))))
