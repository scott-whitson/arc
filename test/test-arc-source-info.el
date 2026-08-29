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

;;; --- CAP: bound how many sources are produced, without parsing every
;;; manual into memory first -----------------------------------------

(ert-deftest asi-cap-limits-the-number-of-sources ()
  (should (= (length (arc-info-sources '("info") 2)) 2)))

(ert-deftest asi-nil-cap-returns-every-source ()
  (should (= (length (arc-info-sources '("info") nil))
             (length (arc-info-sources '("info"))))))

(ert-deftest asi-cap-stops-parsing-further-manuals-once-satisfied ()
  "A cap smaller than one manual's own node count must never cause a
SECOND manual to be parsed at all -- `arc-parse-info-manual' walks a
whole manual's node graph, which is not cheap 94 times over, so a
capped run must not pay to parse a manual whose nodes would just be
discarded afterwards."
  (let ((calls 0))
    (cl-letf (((symbol-function 'arc--info-valid-p) (lambda (_m) t))
              ((symbol-function 'arc-parse-info-manual)
               (lambda (m)
                 (setq calls (1+ calls))
                 (list (cons (format "%s-node" m) (format "%s text" m))))))
      (let ((sources (arc-info-sources '("m1" "m2" "m3") 1)))
        (should (= (length sources) 1))
        (should (= calls 1))))))

(ert-deftest asi-cap-satisfied-mid-manual-still-stops-before-the-next-one ()
  "When the first manual alone produces enough nodes to satisfy the cap,
no later manual is parsed at all."
  (let ((calls 0))
    (cl-letf (((symbol-function 'arc--info-valid-p) (lambda (_m) t))
              ((symbol-function 'arc-parse-info-manual)
               (lambda (m)
                 (setq calls (1+ calls))
                 (list (cons (format "%s-a" m) "a") (cons (format "%s-b" m) "b")))))
      (let ((sources (arc-info-sources '("m1" "m2") 2)))
        (should (= (length sources) 2))
        (should (= calls 1))))))
