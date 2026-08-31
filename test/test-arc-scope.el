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
