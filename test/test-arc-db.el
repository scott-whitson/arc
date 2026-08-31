;;; test-arc-db.el --- schema and source-row round trips -*- lexical-binding: t; -*-
(require 'ert)
(defvar adb-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path adb-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest adb-schema-version-is-set ()
  (arc-test-with-temp-db
   (should (= (arc-db-schema-version) arc-db-schema-version))))

(ert-deftest adb-sources-table-exists ()
  (arc-test-with-temp-db
   (let ((sql (caar (sqlite-select (arc-db)
                     "SELECT sql FROM sqlite_master WHERE name='sources';"))))
     (should sql)
     (should (string-match-p "kind" sql))
     (should (string-match-p "org_id" sql))
     (should (string-match-p "option_name" sql)))))

(ert-deftest adb-source-round-trip ()
  (arc-test-with-temp-db
   (let* ((id (arc-source-upsert
               '(:kind "file" :path "/tmp/x.nix" :hash "abc" :mtime 100)))
          (got (arc-source-get id)))
     (should (integerp id))
     (should (equal (plist-get got :kind) "file"))
     (should (equal (plist-get got :path) "/tmp/x.nix"))
     (should (equal (plist-get got :hash) "abc"))
     (should (null (plist-get got :org-id))))))

(ert-deftest adb-source-upsert-is-idempotent-on-path ()
  (arc-test-with-temp-db
   (let ((a (arc-source-upsert '(:kind "file" :path "/tmp/x.nix" :hash "abc")))
         (b (arc-source-upsert '(:kind "file" :path "/tmp/x.nix" :hash "def"))))
     (should (= a b))
     (should (equal (plist-get (arc-source-get a) :hash) "def")))))

(ert-deftest adb-source-upsert-is-idempotent-on-option-name ()
  (arc-test-with-temp-db
   (let ((a (arc-source-upsert '(:kind "nix-option" :option-name "services.foo.enable")))
         (b (arc-source-upsert '(:kind "nix-option" :option-name "services.foo.enable"))))
     (should (= a b)))))

(ert-deftest adb-delete-cascades-to-data ()
  (arc-test-with-temp-db
   (let ((id (arc-source-upsert '(:kind "file" :path "/tmp/x.nix"))))
     (sqlite-execute (arc-db)
      (format "INSERT INTO data (source_id, chunk, line_start, line_end) VALUES (%d, 'hi', 1, 2);" id))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (arc-source-delete id)
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))))))

(ert-deftest adb-delete-also-removes-orphan-embeddings-and-fts-rows ()
  "data_embeddings and data_fts are virtual tables with no foreign key,
so `arc-source-delete' must remove their rows explicitly by rowid --
relying on `data's ON DELETE CASCADE alone leaves them behind forever."
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let ((id (arc-source-upsert '(:kind "file" :path "/tmp/x.nix"))))
       (sqlite-execute (arc-db)
        (format "INSERT INTO data (source_id, chunk, line_start, line_end) VALUES (%d, 'hi', 1, 2);" id))
       (let ((rowid (caar (sqlite-select (arc-db) "SELECT last_insert_rowid();"))))
         (sqlite-execute (arc-db)
          (format "INSERT INTO data_embeddings (rowid, embedding) VALUES (%d, vec_f32('[0.1,0.2,0.3]'));" rowid))
         (sqlite-execute (arc-db)
          (format "INSERT INTO data_fts (rowid, data) VALUES (%d, 'hi');" rowid))
         (arc-source-delete id)
         (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))
         (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))))))))

(ert-deftest adb-foreign-keys-pragma-is-on ()
  (arc-test-with-temp-db
   (should (= (caar (sqlite-select (arc-db) "PRAGMA foreign_keys;")) 1))))

(ert-deftest adb-journal-mode-is-wal ()
  (arc-test-with-temp-db
   (should (string-equal (caar (sqlite-select (arc-db) "PRAGMA journal_mode;")) "wal"))))

(ert-deftest adb-raw-delete-cascades-to-data ()
  "The ON DELETE CASCADE itself must fire, not just `arc-source-delete's
explicit DELETE FROM data.  Deleting straight out of `sources' with no
help from arc-source-delete must still remove the row's `data' via the
foreign key -- this is the only thing that can catch `foreign_keys'
silently failing to turn on."
  (arc-test-with-temp-db
   (let ((id (arc-source-upsert '(:kind "file" :path "/tmp/x.nix"))))
     (sqlite-execute (arc-db)
      (format "INSERT INTO data (source_id, chunk, line_start, line_end) VALUES (%d, 'hi', 1, 2);" id))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (sqlite-execute (arc-db) (format "DELETE FROM sources WHERE id = %d;" id))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))))))

(ert-deftest adb-bad-vec-path-signals-a-hard-error-not-a-broken-handle ()
  "A missing or nonexistent `arc-sqlite-vec-path' must signal at open
time, naming the variable and the path -- not warn and hand back a
db with no tables, which is exactly how the previous run's confusing
\"no such table: collections\" error came about far from its cause."
  (arc-test-with-temp-db
   (let ((arc-sqlite-vec-path "/nonexistent/vec0.so"))
     (let ((err (should-error (arc-db) :type 'error)))
       (should (string-match-p "arc-sqlite-vec-path" (cadr err)))
       (should (string-match-p "/nonexistent/vec0.so" (cadr err)))))
   ;; the failed attempt must not leave a broken handle behind: arc--db
   ;; stays nil, so a caller who fixes the path and retries gets a
   ;; fresh, fully-initialized database rather than a table-less one.
   (should (null arc--db))
   (let ((arc-sqlite-vec-path (getenv "ARC_VEC0_PATH")))
     (should (= (arc-db-schema-version) arc-db-schema-version)))))

(ert-deftest adb-broken-vec0-extension-signals-clear-error-naming-path ()
  "A file that exists, passes Emacs's own `sqlite-load-extension' \
basename allow-list, and \"loads\" without Emacs ever signalling --
but does not actually register a working vec0 module, because SQLite
resolves its entry point from the (wrong) basename -- must be caught
immediately by `arc--init-db' checking `sqlite-load-extension's return
value (nil in exactly this case, measured on Emacs 30.2 by copying a
real vec0.so to `rtree.so'), not left to surface much later and far
from its cause as `(sqlite-error \"no such module: vec0\")' from
`CREATE VIRTUAL TABLE ... USING vec0'."
  (let* ((real-vec0 (getenv "ARC_VEC0_PATH"))
         (dir (make-temp-file "arc-vec0-wrongname" t))
         (wrong-path (expand-file-name "rtree.so" dir)))
    (unwind-protect
        (progn
          (copy-file real-vec0 wrong-path)
          (arc-test-with-temp-db
           (let ((arc-sqlite-vec-path wrong-path))
             (let ((err (should-error (arc-db) :type 'error)))
               (should (string-match-p (regexp-quote wrong-path) (cadr err)))
               (should (string-match-p "returned nil" (cadr err)))
               ;; must not be confused with the "missing path" error --
               ;; this path DOES exist, so that message would be wrong.
               (should-not (string-match-p "does not point to an existing" (cadr err)))))
           (should (null arc--db))))
      (delete-directory dir t))))

(ert-deftest adb-sqlite-escape-round-trips-backslash-quote-and-apostrophe ()
  "SQLite string literals have no backslash-escape rule -- only a
doubled single quote means anything.  `arc-sqlite-escape' used to map
`\\=\\' to `\\=\\\\' anyway, so a stored chunk containing a backslash
came back with it doubled.  Storing this text and reading it back via
a real round trip through `arc-db' must reproduce it byte-identical."
  (arc-test-with-temp-db
   (let* ((text "C:\\Users\\swhitson, a \"quote\", and it's got an apostrophe")
          (id (arc-source-upsert '(:kind "file" :path "/tmp/rt.nix"))))
     (sqlite-execute
      (arc-db)
      (format "INSERT INTO data (source_id, chunk, line_start, line_end) VALUES (%d, %s, 1, 1);"
              id (arc--sql-quote text)))
     (should (equal (caar (sqlite-select (arc-db) "SELECT chunk FROM data;")) text)))))

(ert-deftest ed-tags-string-formats-org-style ()
  (should (equal (arc-source-tags-string '("emacs" "nix")) ":emacs:nix:"))
  (should (equal (arc-source-tags-string '("solo")) ":solo:"))
  (should (null (arc-source-tags-string nil)))
  (should (null (arc-source-tags-string '()))))

(ert-deftest ed-upsert-persists-tags ()
  (arc-test-with-temp-db
   (let ((sid (arc-source-upsert
               (list :kind "org-node" :org-id "abc-123" :path "/tmp/n.org"
                     :tags '("emacs" "nix")))))
     (should (equal (caar (sqlite-select
                           (arc-db)
                           (format "SELECT tags FROM sources WHERE id = %d;" sid)))
                    ":emacs:nix:")))))

(ert-deftest ed-upsert-tags-nil-stays-null ()
  (arc-test-with-temp-db
   (let ((sid (arc-source-upsert (list :kind "file" :path "/tmp/x.txt"))))
     (should (null (caar (sqlite-select
                          (arc-db)
                          (format "SELECT tags FROM sources WHERE id = %d;" sid))))))))

(ert-deftest ed-upsert-updates-tags-on-conflict ()
  "Re-indexing a node whose tags changed must not keep the old ones."
  (arc-test-with-temp-db
   (arc-source-upsert (list :kind "org-node" :org-id "abc-123" :tags '("old")))
   (let ((sid (arc-source-upsert (list :kind "org-node" :org-id "abc-123" :tags '("new")))))
     (should (equal (caar (sqlite-select
                           (arc-db)
                           (format "SELECT tags FROM sources WHERE id = %d;" sid)))
                    ":new:")))))

(ert-deftest ed-source-row-plist-carries-tags ()
  (arc-test-with-temp-db
   (arc-source-upsert (list :kind "org-node" :org-id "t-1" :tags '("a" "b")))
   (let* ((row (car (sqlite-select
                     (arc-db)
                     "SELECT id, kind, path, org_id, option_name, info_node, hash, mtime, tags
                      FROM sources WHERE org_id = 't-1';")))
          (pl (arc--source-row-to-plist row)))
     (should (equal (plist-get pl :tags) '("a" "b"))))))

(ert-deftest ed-getters-carry-tags ()
  "arc-source-get and arc-source-by-path must not silently drop tags --
each is a distinct SELECT that has to list `tags' itself; a passing
`ed-source-row-plist-carries-tags' does not exercise either one."
  (arc-test-with-temp-db
   (let ((id (arc-source-upsert
              (list :kind "org-node" :org-id "get-1" :tags '("a" "b")))))
     (should (equal (plist-get (arc-source-get id) :tags) '("a" "b")))))
  (arc-test-with-temp-db
   (arc-source-upsert
    (list :kind "file" :path "/tmp/getters.txt" :tags '("c" "d")))
   (should (equal (plist-get (arc-source-by-path "/tmp/getters.txt") :tags)
                  '("c" "d")))))
