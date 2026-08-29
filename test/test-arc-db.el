;;; test-arc-db.el --- schema and source-row round trips -*- lexical-binding: t; -*-
(require 'ert)
(defvar adb-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path adb-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest adb-schema-version-is-set ()
  (arc-test-with-temp-db
   (should (= (arc-db-schema-version) 1))))

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
     (should (= (arc-db-schema-version) 1)))))
