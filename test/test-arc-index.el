;;; test-arc-index.el --- indexing writes chunks and embeddings -*- lexical-binding: t; -*-
(require 'ert)
(defvar ai-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ai-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
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
               ((symbol-function 'arc-info-sources)
                (lambda (_manuals &optional cap) (if cap (take cap fake-sources) fake-sources))))
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
               ((symbol-function 'arc-info-sources)
                (lambda (_manuals &optional cap) (if cap (take cap fake-sources) fake-sources))))
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
                (lambda (_manuals &optional _cap)
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

;;; --- I4: every producer's output carries :chunks, not just :text ----

(ert-deftest ai-every-producer-emits-chunks ()
  "`arc-index-source' reads only :chunks; a producer emitting bare :text
with no :chunks would silently write zero rows if `arc-index-source'
were ever called on its output directly -- which is exactly what used
to happen for org-node and nix/hm-option sources outside
`arc-reindex-all''s own three now-deleted `plist-put' adapters.  All
five kinds must carry :chunks straight from the producer."
  (let ((dir (make-temp-file "arc-chunks-file-tree" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.txt" dir) (insert "hello\n"))
          (should (cl-every (lambda (s) (consp (plist-get s :chunks))) (arc-file-sources dir))))
      (delete-directory dir t)))
  (should (cl-every (lambda (s) (consp (plist-get s :chunks)))
                    (arc-org-nodes (expand-file-name "test/fixtures/roam" ai-root))))
  (let ((fixture (expand-file-name "test/fixtures/options-sample.json" ai-root)))
    (should (cl-every (lambda (s) (consp (plist-get s :chunks)))
                      (arc-nixopt-parse-json fixture "nix-option")))
    (should (cl-every (lambda (s) (consp (plist-get s :chunks)))
                      (arc-nixopt-parse-json fixture "hm-option"))))
  (should (cl-every (lambda (s) (consp (plist-get s :chunks))) (arc-info-sources '("info")))))

;;; --- I6: arc-reindex-all prunes sources the corpus no longer yields --

(ert-deftest ai-reindex-all-prunes-sources-removed-from-the-corpus ()
  "Upstream's directory walk deleted rows for paths the current walk no
longer yielded; nothing replaced that when `sources' gained its own
identity, so anything deleted, newly gitignored, or newly excluded
from the corpus stayed citable forever.  Index two files, remove one
from the tree, reindex, and confirm its source -- and every row that
depended on it, including the virtual-table ones -- is gone, while the
other survives."
  (ai-with-temp-db
   (let ((dir (make-temp-file "arc-prune-tree" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "a.txt" dir) (insert "keep me\n"))
           (with-temp-file (expand-file-name "b.txt" dir) (insert "delete me\n"))
           (let ((arc-index-plan '(("prune-test" . file)))
                 (arc-collection-directory-alist `(("prune-test" . ,dir))))
             (arc-reindex-all)
             (should (= 2 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
             (delete-file (expand-file-name "b.txt" dir))
             (arc-reindex-all)
             (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
             (should (= 1 (caar (sqlite-select
                                 (arc-db) "SELECT count(*) FROM sources WHERE path LIKE '%a.txt';"))))
             (should (= 0 (caar (sqlite-select
                                 (arc-db) "SELECT count(*) FROM sources WHERE path LIKE '%b.txt';"))))
             (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
             (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))
             (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;"))))))
       (delete-directory dir t)))))

;;; --- I7: priority-ordered manuals + I8: skip a missing directory ----

(ert-deftest ai-prioritize-manuals-reorders-matches-first ()
  (should (equal (arc--prioritize-manuals '("auth" "autotype" "bash" "emacs" "elisp" "org" "zsh")
                                          '("emacs" "elisp" "org"))
                 '("emacs" "elisp" "org" "auth" "autotype" "bash" "zsh"))))

(ert-deftest ai-prioritize-manuals-matches-gzip-suffixed-spelling ()
  "On a host whose Info pages are gzip-compressed, `file-name-base'
leaves a manual as e.g. \"emacs.info\" rather than \"emacs\" -- the
priority list must still find it."
  (should (equal (arc--prioritize-manuals '("auth.info" "emacs.info" "elisp.info" "org.info" "zsh")
                                          '("emacs" "elisp" "org"))
                 '("emacs.info" "elisp.info" "org.info" "auth.info" "zsh"))))

(ert-deftest ai-prioritize-manuals-tolerates-a-missing-priority-entry ()
  (should (equal (arc--prioritize-manuals '("auth" "bash") '("emacs" "elisp" "org"))
                 '("auth" "bash"))))

(ert-deftest ai-reindex-all-skips-a-missing-collection-directory-without-erroring ()
  "`arc-collection-directory-alist' can name a directory absent on this
host (`eminix' on a machine with no such checkout, for instance); this
must be a reported skip, not a `file-missing' error that aborts every
collection still queued behind it in `arc-index-plan'."
  (ai-with-temp-db
   (let ((dir (make-temp-file "arc-present-tree" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "a.txt" dir) (insert "hello\n"))
           (let ((arc-index-plan '(("gone" . file) ("still-here" . file)))
                 (arc-collection-directory-alist
                  `(("gone" . ,(expand-file-name "nope" (make-temp-name (expand-file-name "arc-missing-"
                                                                                           temporary-file-directory))))
                    ("still-here" . ,dir))))
             ;; must not signal file-missing
             (arc-reindex-all)
             (should (= 1 (caar (sqlite-select
                                 (arc-db) "SELECT count(*) FROM sources WHERE kind = 'file';"))))))
       (delete-directory dir t)))))

(ert-deftest ai-reindex-all-does-not-prune-a-collection-whose-directory-went-missing ()
  "A collection directory present at the last full index but gone now
must be skipped, not mistaken for \"the walk found nothing\" and used
as a reason to delete every source this collection already has -- the
corpus here was never walked this run, not emptied."
  (ai-with-temp-db
   (let ((dir (make-temp-file "arc-vanishing-tree" t)))
     (with-temp-file (expand-file-name "a.txt" dir) (insert "hello\n"))
     (let ((arc-index-plan '(("vanishing" . file)))
           (arc-collection-directory-alist `(("vanishing" . ,dir))))
       (arc-reindex-all)
       (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
       (delete-directory dir t)
       (arc-reindex-all)
       (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))))))

;;; --- arc-index-source: a `C-g' mid-embedding must not truncate -------

(ert-deftest ai-index-source-quit-mid-embedding-leaves-old-content-intact ()
  "A `C-g' (signalled here as `quit') partway through embedding a
multi-chunk source's replacement chunks must leave that source's OLD
content completely intact -- not cut down to whichever chunks had
already been embedded when the quit landed.  Reproduced against the
unfixed version of `arc-index-source' (which deleted a source's old
chunks up front, then wrote each new one via a per-chunk transaction as
it was embedded): a 10-chunk source interrupted after chunk 3 lost 7 of
its chunks.  The fixed version embeds every chunk first and only then
calls `arc--replace-source-chunks' once, so a quit during embedding
never reaches that call at all for this reindex, and the source is
left exactly as the baseline run left it."
  (ai-with-temp-db
   (let ((source '(:kind "file" :path "/tmp/big.nix"
                    :chunks ((:text "one" :line-start 1 :line-end 1)
                             (:text "two" :line-start 2 :line-end 2)
                             (:text "three" :line-start 3 :line-end 3)
                             (:text "four" :line-start 4 :line-end 4)
                             (:text "five" :line-start 5 :line-end 5)
                             (:text "six" :line-start 6 :line-end 6)
                             (:text "seven" :line-start 7 :line-end 7)
                             (:text "eight" :line-start 8 :line-end 8)
                             (:text "nine" :line-start 9 :line-end 9)
                             (:text "ten" :line-start 10 :line-end 10)))))
     ;; baseline: fully index the source, no interruption
     (arc-index-source source "test")
     (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     ;; reindex again; `C-g' (quit) lands partway through embedding,
     ;; after only 3 of the 10 replacement chunks have been embedded
     (let ((calls 0))
       (cl-letf (((symbol-function 'llm-embedding)
                  (lambda (&rest _)
                    (cl-incf calls)
                    (if (= calls 4) (signal 'quit nil) (vector 0.1 0.2 0.3)))))
         (condition-case nil
             (arc-index-source source "test")
           (quit nil))))
     ;; old content -- all 10 chunks -- survives completely intact
     (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))
     (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))))))
