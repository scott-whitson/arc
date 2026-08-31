;;; test-arc-scoped-search.el --- a scope must reach the search -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'ert)
(defvar ass-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ass-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(defconst ass-dim 3)

(defun ass--seed ()
  "Seed a corpus where the global nearest neighbours are ALL out of scope.
This is the shape measured on the live index: a vault-scoped question
whose 40 nearest global neighbours were 40 dotfiles chunks.  20 near
`decoy' rows in `dotfiles' crowd out the 2 `vault' rows entirely at any
small k."
  (let ((db (arc-db)))
    (sqlite-execute db "INSERT INTO collections (name) VALUES ('vault'), ('dotfiles');")
    (let ((vault (caar (sqlite-select db "SELECT id FROM collections WHERE name='vault'")))
          (dots (caar (sqlite-select db "SELECT id FROM collections WHERE name='dotfiles'"))))
      ;; 20 dotfiles rows very close to the query vector [1 0 0]
      (dotimes (i 20)
        (let ((sid (arc-source-upsert (list :kind "file" :path (format "/dots/f%d.nix" i)))))
          (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'syncthing decoy %d');"
                                     sid dots i))
          (let ((rid (caar (sqlite-select db "SELECT last_insert_rowid();"))))
            (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%d, %s);"
                                       rid (arc-vector-to-sqlite
                                            (vector 1.0 (* 0.001 (1+ i)) 0.0))))
            (sqlite-execute db (format "INSERT INTO data_fts(rowid, data) VALUES (%d, 'syncthing decoy %d');"
                                       rid i)))))
      ;; 2 vault rows, further away but the only ones in scope
      (dotimes (i 2)
        (let ((sid (arc-source-upsert (list :kind "org-node" :org-id (format "v%d" i)
                                            :path (format "/vault/v%d.org" i)
                                            :tags '("infra")))))
          (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'syncthing vault note %d');"
                                     sid vault i))
          (let ((rid (caar (sqlite-select db "SELECT last_insert_rowid();"))))
            (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%d, %s);"
                                       rid (arc-vector-to-sqlite (vector 0.6 0.8 0.0))))
            (sqlite-execute db (format "INSERT INTO data_fts(rowid, data) VALUES (%d, 'syncthing vault note %d');"
                                       rid i))))))))

(defun ass--collections-of (ids)
  "Return the collection names the data rows IDS belong to."
  (when ids
    (mapcar #'car
            (sqlite-select
             (arc-db)
             (format "SELECT DISTINCT c.name FROM data d JOIN collections c ON c.id = d.collection_id
                      WHERE d.id IN %s;" (arc-sqlite-format-int-list ids))))))

(ert-deftest ass-vault-scope-returns-only-vault ()
  "The regression this phase exists for: at k=40 the global nearest
neighbours are all dotfiles, so a post-hoc filter returns nothing."
  (let ((arc-embedding-size ass-dim))
    (arc-test-with-temp-db
     (ass--seed)
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
       (let* ((sql (arc--find-similar "syncthing" (arc-scope :collections '("vault"))))
              (ids (flatten-tree (sqlite-select (arc-db) sql))))
         (should ids)
         (should (equal (ass--collections-of ids) '("vault"))))))))

(ert-deftest ass-unscoped-search-still-finds-the-nearest ()
  (let ((arc-embedding-size ass-dim))
    (arc-test-with-temp-db
     (ass--seed)
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
       (let* ((sql (arc--find-similar "syncthing" nil))
              (ids (flatten-tree (sqlite-select (arc-db) sql))))
         (should ids)
         (should (member "dotfiles" (ass--collections-of ids))))))))

(ert-deftest ass-kind-scope-returns-only-that-kind ()
  (let ((arc-embedding-size ass-dim))
    (arc-test-with-temp-db
     (ass--seed)
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
       (let* ((sql (arc--find-similar "syncthing" (arc-scope :kinds '("org-node"))))
              (ids (flatten-tree (sqlite-select (arc-db) sql))))
         (should ids)
         (should (equal (ass--collections-of ids) '("vault"))))))))

(ert-deftest ass-tag-scope-returns-only-tagged ()
  (let ((arc-embedding-size ass-dim))
    (arc-test-with-temp-db
     (ass--seed)
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
       (let* ((sql (arc--find-similar "syncthing" (arc-scope :tags '("infra"))))
              (ids (flatten-tree (sqlite-select (arc-db) sql))))
         (should ids)
         (should (equal (ass--collections-of ids) '("vault"))))))))

(ert-deftest ass-knn-branch-also-respects-scope ()
  "Force the k-raising branch and confirm it filters just as exactly."
  (let ((arc-embedding-size ass-dim))
    (arc-test-with-temp-db
     (ass--seed)
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
       (let* ((arc-scope-bruteforce-max 0)   ; never brute-force
              (sql (arc--find-similar "syncthing" (arc-scope :collections '("vault"))))
              (ids (flatten-tree (sqlite-select (arc-db) sql))))
         (should ids)
         (should (equal (ass--collections-of ids) '("vault"))))))))

(ert-deftest ass-empty-scope-yields-no-rows-not-an-error ()
  (let ((arc-embedding-size ass-dim))
    (arc-test-with-temp-db
     (ass--seed)
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
       (let* ((sql (arc--find-similar "syncthing" (arc-scope :collections '("nonesuch"))))
              (ids (flatten-tree (sqlite-select (arc-db) sql))))
         (should (null ids)))))))

(ert-deftest ass-no-inlined-rowid-lists ()
  "The old query pasted every in-scope rowid into its own SQL text --
6,427 integers, twice, on the live index.  The scope is a join now."
  (let ((arc-embedding-size ass-dim))
    (arc-test-with-temp-db
     (ass--seed)
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
       (let ((sql (arc--find-similar "syncthing" (arc-scope :collections '("vault")))))
         (should (string-match-p "scoped" sql))
         ;; Three consecutive integers in an IN-list is the shape of the old
         ;; inlined allowlist.  Match case-insensitively: the previous query
         ;; wrote `IN' upper-case, and a canary that cannot match the thing
         ;; it guards against is not a canary.
         (should-not (let ((case-fold-search t))
                       (string-match-p "in ([0-9]+, [0-9]+, [0-9]+" sql))))))))

(ert-deftest ass-scope-from-collections-round-trips ()
  (should (equal (arc-scope-from-collections '("vault"))
                 (arc-scope :collections '("vault"))))
  (should (arc-scope-empty-p (arc-scope-from-collections nil))))
