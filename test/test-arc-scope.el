;;; test-arc-scope.el --- scope construction and its SQL -*- lexical-binding: t; -*-
(require 'ert)
(defvar as-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path as-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-scope)
(require 'arc-test-helpers)

(ert-deftest as-empty-scope-is-empty ()
  (should (arc-scope-empty-p nil))
  (should (arc-scope-empty-p (arc-scope)))
  (should (arc-scope-empty-p (arc-scope :collections nil :kinds nil)))
  (should-not (arc-scope-empty-p (arc-scope :collections '("vault")))))

(ert-deftest as-empty-scope-predicate-is-always-true ()
  (should (equal (arc-scope-predicate nil) "1"))
  (should (equal (arc-scope-predicate (arc-scope)) "1")))

(ert-deftest as-collection-predicate ()
  (should (equal (arc-scope-predicate (arc-scope :collections '("vault")))
                 "d.collection_id IN (SELECT id FROM collections WHERE name IN ('vault'))")))

(ert-deftest as-kind-predicate ()
  (should (equal (arc-scope-predicate (arc-scope :kinds '("nix-option" "hm-option")))
                 "s.kind IN ('nix-option', 'hm-option')")))

(ert-deftest as-tag-predicate-anchors-on-colons ()
  (should (equal (arc-scope-predicate (arc-scope :tags '("emacs")))
                 "(s.tags LIKE '%:emacs:%' ESCAPE '\\')")))

(ert-deftest as-tag-predicate-escapes-like-wildcards ()
  "Org tags may contain `_', which LIKE reads as a one-character wildcard."
  (should (equal (arc-scope-predicate (arc-scope :tags '("work_notes")))
                 "(s.tags LIKE '%:work\\_notes:%' ESCAPE '\\')")))

(ert-deftest as-path-prefix-predicate ()
  (should (equal (arc-scope-predicate (arc-scope :path-prefix "/home/u/docs"))
                 "s.path LIKE '/home/u/docs%' ESCAPE '\\'")))

(ert-deftest as-predicates-combine-with-and ()
  (should (equal (arc-scope-predicate (arc-scope :collections '("vault") :kinds '("org-node")))
                 "d.collection_id IN (SELECT id FROM collections WHERE name IN ('vault')) AND s.kind IN ('org-node')")))

(ert-deftest as-quotes-are-escaped ()
  (should (string-match-p "O''Brien" (arc-scope-predicate (arc-scope :collections '("O'Brien")))))
  (should (string-match-p "O''Brien" (arc-scope-predicate (arc-scope :tags '("O'Brien")))))
  (should (string-match-p "O''Brien" (arc-scope-predicate (arc-scope :path-prefix "/home/O'Brien")))))

(ert-deftest as-describe ()
  (should (equal (arc-scope-describe nil) "everything"))
  (should (equal (arc-scope-describe (arc-scope :collections '("vault"))) "vault"))
  (should (equal (arc-scope-describe (arc-scope :collections '("nix options" "hm options")))
                 "nix options, hm options"))
  (should (equal (arc-scope-describe (arc-scope :kinds '("org-node"))) "kinds org-node"))
  (should (equal (arc-scope-describe (arc-scope :tags '("emacs"))) "tags emacs"))
  (should (equal (arc-scope-describe (arc-scope :path-prefix "/x")) "under /x")))

(defun as--seed (db)
  "Seed DB with two collections of known size: vault 3 rows, dotfiles 5."
  (sqlite-execute db "INSERT INTO collections (name) VALUES ('vault'), ('dotfiles');")
  (let ((vault (caar (sqlite-select db "SELECT id FROM collections WHERE name='vault'")))
        (dots  (caar (sqlite-select db "SELECT id FROM collections WHERE name='dotfiles'"))))
    (dotimes (i 3)
      (let ((sid (arc-source-upsert (list :kind "org-node" :org-id (format "n%d" i)
                                          :path (format "/vault/n%d.org" i)
                                          :tags (if (= i 0) '("emacs") nil)))))
        (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'v%d');"
                                   sid vault i))))
    (dotimes (i 5)
      (let ((sid (arc-source-upsert (list :kind "file" :path (format "/dots/f%d.nix" i)))))
        (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'd%d');"
                                   sid dots i))))))

(ert-deftest as-count-and-total ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (should (= (arc-scope-total) 8))
   (should (= (arc-scope-count nil) 8))
   (should (= (arc-scope-count (arc-scope :collections '("vault"))) 3))
   (should (= (arc-scope-count (arc-scope :collections '("dotfiles"))) 5))
   (should (= (arc-scope-count (arc-scope :kinds '("org-node"))) 3))
   (should (= (arc-scope-count (arc-scope :tags '("emacs"))) 1))
   (should (= (arc-scope-count (arc-scope :path-prefix "/vault")) 3))
   (should (= (arc-scope-count (arc-scope :collections '("nope"))) 0))))

(ert-deftest as-total-and-count-agree-on-orphaned-data ()
  "A `data' row whose `source_id' resolves to no `sources' row must not
make `arc-scope-total' and an unscoped `arc-scope-count' disagree --
Task 4 divides one by the other to scale k, so any divergence between
what they each count would silently pick a wrong retrieval strategy."
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (sqlite-execute (arc-db) "INSERT INTO data (source_id, chunk) VALUES (NULL, 'orphan');")
   (should (= (arc-scope-total) (arc-scope-count nil)))))

(ert-deftest as-plan-unscoped-uses-plain-knn ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (should (equal (arc-scope-vector-plan nil) (cons 'knn arc-knn-candidates)))))

(ert-deftest as-plan-small-scope-uses-brute-force ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   ;; 3 rows is far under `arc-scope-bruteforce-max'.
   (should (equal (arc-scope-vector-plan (arc-scope :collections '("vault")))
                  '(brute . nil)))))

(ert-deftest as-plan-large-scope-raises-k-proportionally ()
  "A scope too big to brute-force gets a k scaled by how much of the
corpus it excludes, so roughly `arc-knn-candidates' land in scope."
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (let ((arc-scope-bruteforce-max 1)      ; force the knn branch
         (arc-knn-candidates 40))
     ;; vault is 3 of 8 rows; 40 * 8/3 = 106.67 -> 107
     (should (equal (arc-scope-vector-plan (arc-scope :collections '("vault")))
                    '(knn . 107))))))

(ert-deftest as-plan-falls-back-to-brute-force-past-the-k-ceiling ()
  "vec0 refuses k > 4096.  Correctness of the scope wins over speed."
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (let ((arc-scope-bruteforce-max 1)
         (arc-knn-candidates 40000))       ; forces a k far past the ceiling
     (should (equal (arc-scope-vector-plan (arc-scope :collections '("vault")))
                    '(brute . nil))))))

(ert-deftest as-plan-empty-scope-does-not-divide-by-zero ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (let ((arc-scope-bruteforce-max 0))
     (should (equal (arc-scope-vector-plan (arc-scope :collections '("nope")))
                    '(brute . nil))))))

(ert-deftest as-k-ceiling-matches-what-vec0-actually-enforces ()
  "Measured, not assumed: k = 4097 must be refused and k = 4096 accepted.

vec0 itself enforces this at the C level -- confirmed independently
via Python's `sqlite3' binding against this exact table, which raises
\"k value in knn query too large, provided 4097 and the limit is 4096\"
for k = 4097.  But Emacs 30.2's `sqlite-select' does not propagate that
particular vtab `xFilter' error as a Lisp signal when it is the very
first row fetched: in list mode (the default, `RETURN-TYPE' nil) it
silently returns nil, as if the query had matched zero rows, instead
of raising `sqlite-error'.  A plain SQL syntax error on the same
connection still signals normally -- `(sqlite-select db \"SLECT ...\")'
does raise -- so this is specific to an error surfaced from a virtual
table's `xFilter' on the first `sqlite3_step', not a general breakage
of error propagation.  `RETURN-TYPE' `set' plus `sqlite-next' does
propagate it correctly, and is what this test uses.

This matters beyond the test itself: it means `arc-scope-vector-plan'
must never depend on vec0 refusing an oversized `k' as a catchable
error.  In this Emacs, that failure mode is not an exception to catch
-- it is a silent, wrong, empty result set from ordinary list-mode
`sqlite-select'.  Whichever later task issues the real KNN query
against a computed `k' should use `set' plus `sqlite-next' (or
otherwise avoid ever asking for `k' > `arc-vec0-k-ceiling') for exactly
this reason."
  (let ((db (sqlite-open)))
    (sqlite-load-extension db arc-sqlite-vec-path)
    (sqlite-execute db "CREATE VIRTUAL TABLE data_embeddings USING vec0(embedding float[3]);")
    (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (1, %s);"
                               (arc-vector-to-sqlite [1.0 0.0 0.0])))
    (let ((q (arc-vector-to-sqlite [1.0 0.0 0.0])))
      (should (sqlite-next
               (sqlite-select db (format "SELECT rowid FROM data_embeddings WHERE embedding MATCH %s AND k = %d;"
                                        q arc-vec0-k-ceiling)
                              nil 'set)))
      (should-error (sqlite-next
                     (sqlite-select db (format "SELECT rowid FROM data_embeddings WHERE embedding MATCH %s AND k = %d;"
                                              q (1+ arc-vec0-k-ceiling))
                                    nil 'set))))))
