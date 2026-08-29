;;; test-arc-index.el --- indexing writes chunks and embeddings -*- lexical-binding: t; -*-
(require 'ert)
(defvar ai-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ai-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'arc)
(require 'arc-index)

(defmacro ai-with-temp-db (&rest body)
  `(let* ((arc-db-directory (make-temp-file "arc-idx" t))
          (arc--db nil)
          (arc-embedding-size 3))
     (cl-letf (((symbol-function 'llm-embedding)
                (lambda (&rest _) (vector 0.1 0.2 0.3))))
       (unwind-protect (progn ,@body)
         (arc-close-db)
         (delete-directory arc-db-directory t)))))

(ert-deftest ai-indexes-a-file-source ()
  (ai-with-temp-db
   (let ((n (arc-index-source
             '(:kind "file" :path "/tmp/x.nix" :hash "abc" :mtime 1
               :chunks ((:text "alpha" :line-start 1 :line-end 2)
                        (:text "beta"  :line-start 4 :line-end 5)))
             "test")))
     (should (= n 2))
     (should (= 2 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (= 2 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;")))))))

(ert-deftest ai-line-numbers-survive-the-round-trip ()
  (ai-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/x.nix" :chunks ((:text "alpha" :line-start 7 :line-end 9)))
    "test")
   (should (= 7 (caar (sqlite-select (arc-db) "SELECT line_start FROM data;"))))))

(ert-deftest ai-reindexing-replaces-rather-than-duplicates ()
  (ai-with-temp-db
   (let ((src '(:kind "file" :path "/tmp/x.nix" :hash "abc"
                :chunks ((:text "alpha" :line-start 1 :line-end 1)))))
     (arc-index-source src "test")
     (arc-index-source src "test")
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     ;; the virtual tables must not accumulate orphans across reindexes
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))))))

(ert-deftest ai-stats-report-per-kind-counts ()
  (ai-with-temp-db
   (arc-index-source '(:kind "file" :path "/tmp/x.nix"
                         :chunks ((:text "a" :line-start 1 :line-end 1))) "test")
   (arc-index-source '(:kind "nix-option" :option-name "services.foo.enable"
                         :chunks ((:text "b" :line-start 1 :line-end 1))) "test")
   (let ((stats (arc-index-stats)))
     (should (= (alist-get "file" stats 0 nil #'equal) 1))
     (should (= (alist-get "nix-option" stats 0 nil #'equal) 1)))))

(ert-deftest ai-sanitize-text-replaces-undecodable-bytes ()
  "A raw-byte pseudo-character must be built via `unibyte-char-to-multibyte',
not the char literal `?\\x3FFF80' -- the Lisp reader normalizes that literal
straight back down to plain byte 128 (a real `?\\x80' Unicode char), which
never matches the sanitizer's raw-byte-only regexp, so a test built that
way silently tests nothing."
  (let ((bad (concat "hello " (string (unibyte-char-to-multibyte ?\x80)) " world")))
    (should (equal (arc--sanitize-text bad) (concat "hello " (string ?\uFFFD) " world")))
    (should (equal (arc--sanitize-text "plain ascii") "plain ascii"))))

(ert-deftest ai-indexing-a-chunk-with-undecodable-bytes-does-not-crash ()
  "A real org-roam node hit this: a byte sequence its buffer's coding
system could not decode reached `llm-embedding' as an Emacs internal
raw-byte character and could not be JSON-encoded, crashing the whole
run far from the node responsible. Indexing must sanitize instead of
crashing, and still write the (now-clean) chunk."
  (ai-with-temp-db
   (let ((n (arc-index-source
             (list :kind "org-node" :org-id "x"
                   :chunks (list (list :text (concat "alpha " (string (unibyte-char-to-multibyte ?\x80)) " beta")
                                       :line-start 1 :line-end 1)))
             "test")))
     (should (= n 1))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;")))))))

(ert-deftest ai-reindex-all-info-branch-honors-the-cap ()
  "arc-reindex-all's `info' branch had no bound of its own at all --
running it embedded every node in every builtin manual unconditionally.
A fake `arc-info-sources' returning more sources than the cap must
still only get `arc-index-info-cap' of them actually indexed."
  (ai-with-temp-db
   (let* ((arc-index-plan '(("builtin manuals" . info)))
          (arc-index-info-cap 2)
          (fake-sources
           (list '(:kind "info" :info-node "(m)One"
                   :chunks ((:text "one" :line-start 1 :line-end 1)))
                 '(:kind "info" :info-node "(m)Two"
                   :chunks ((:text "two" :line-start 1 :line-end 1)))
                 '(:kind "info" :info-node "(m)Three"
                   :chunks ((:text "three" :line-start 1 :line-end 1))))))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (_manuals) fake-sources)))
       (arc-reindex-all))
     (should (= 2 (caar (sqlite-select
                         (arc-db)
                         "SELECT count(*) FROM sources WHERE kind = 'info';")))))))

(ert-deftest ai-reindex-all-info-branch-nil-cap-means-unlimited ()
  "A nil `arc-index-info-cap' must index every source `arc-info-sources'
returns -- the full-ingest escape hatch has to actually be one edit."
  (ai-with-temp-db
   (let* ((arc-index-plan '(("builtin manuals" . info)))
          (arc-index-info-cap nil)
          (fake-sources
           (list '(:kind "info" :info-node "(m)One"
                   :chunks ((:text "one" :line-start 1 :line-end 1)))
                 '(:kind "info" :info-node "(m)Two"
                   :chunks ((:text "two" :line-start 1 :line-end 1)))
                 '(:kind "info" :info-node "(m)Three"
                   :chunks ((:text "three" :line-start 1 :line-end 1))))))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (_manuals) fake-sources)))
       (arc-reindex-all))
     (should (= 3 (caar (sqlite-select
                         (arc-db)
                         "SELECT count(*) FROM sources WHERE kind = 'info';")))))))

(ert-deftest ai-reindex-all-collections-argument-scopes-the-rebuild ()
  "Passing COLLECTIONS to arc-reindex-all must rebuild only the named
plan entries and leave every other collection alone -- this is what
lets a caller (eminix/arc-reindex, eminix/arc-reindex-notes) rebuild
just its own collections instead of the whole plan."
  (ai-with-temp-db
   (let* ((arc-index-plan '(("manuals-a" . info) ("manuals-b" . info)))
          (arc-index-info-cap nil)
          (calls 0))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources)
                (lambda (_manuals)
                  (setq calls (1+ calls))
                  (list (list :kind "info" :info-node "(m)Node"
                              :chunks (list (list :text "x" :line-start 1 :line-end 1)))))))
       (arc-reindex-all '("manuals-b")))
     ;; only the requested plan entry ran arc-info-sources at all
     (should (= 1 calls))
     (should (= 0 (caar (sqlite-select
                         (arc-db)
                         "SELECT count(*) FROM data WHERE collection_id =
                          (SELECT id FROM collections WHERE name = 'manuals-a');"))))
     (should (= 1 (caar (sqlite-select
                         (arc-db)
                         "SELECT count(*) FROM data WHERE collection_id =
                          (SELECT id FROM collections WHERE name = 'manuals-b');")))))))
