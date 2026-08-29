;;; test-arc-db.el --- schema and source-row round trips -*- lexical-binding: t; -*-
(require 'ert)
(defvar adb-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path adb-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'arc)

(defmacro adb-with-temp-db (&rest body)
  "Run BODY against a throwaway arc database."
  `(let* ((arc-db-directory (make-temp-file "arc-test" t))
          (arc--db nil))
     (unwind-protect (progn ,@body)
       (arc-close-db)
       (delete-directory arc-db-directory t))))

(ert-deftest adb-schema-version-is-set ()
  (adb-with-temp-db
   (should (= (arc-db-schema-version) 1))))

(ert-deftest adb-sources-table-exists ()
  (adb-with-temp-db
   (let ((sql (caar (sqlite-select (arc-db)
                     "SELECT sql FROM sqlite_master WHERE name='sources';"))))
     (should sql)
     (should (string-match-p "kind" sql))
     (should (string-match-p "org_id" sql))
     (should (string-match-p "option_name" sql)))))

(ert-deftest adb-source-round-trip ()
  (adb-with-temp-db
   (let* ((id (arc-source-upsert
               '(:kind "file" :path "/tmp/x.nix" :hash "abc" :mtime 100)))
          (got (arc-source-get id)))
     (should (integerp id))
     (should (equal (plist-get got :kind) "file"))
     (should (equal (plist-get got :path) "/tmp/x.nix"))
     (should (equal (plist-get got :hash) "abc"))
     (should (null (plist-get got :org-id))))))

(ert-deftest adb-source-upsert-is-idempotent-on-path ()
  (adb-with-temp-db
   (let ((a (arc-source-upsert '(:kind "file" :path "/tmp/x.nix" :hash "abc")))
         (b (arc-source-upsert '(:kind "file" :path "/tmp/x.nix" :hash "def"))))
     (should (= a b))
     (should (equal (plist-get (arc-source-get a) :hash) "def")))))

(ert-deftest adb-source-upsert-is-idempotent-on-option-name ()
  (adb-with-temp-db
   (let ((a (arc-source-upsert '(:kind "nix-option" :option-name "services.foo.enable")))
         (b (arc-source-upsert '(:kind "nix-option" :option-name "services.foo.enable"))))
     (should (= a b)))))

(ert-deftest adb-delete-cascades-to-data ()
  (adb-with-temp-db
   (let ((id (arc-source-upsert '(:kind "file" :path "/tmp/x.nix"))))
     (sqlite-execute (arc-db)
      (format "INSERT INTO data (source_id, chunk, line_start, line_end) VALUES (%d, 'hi', 1, 2);" id))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (arc-source-delete id)
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))))))

(ert-deftest adb-foreign-keys-pragma-is-on ()
  (adb-with-temp-db
   (should (= (caar (sqlite-select (arc-db) "PRAGMA foreign_keys;")) 1))))

(ert-deftest adb-journal-mode-is-wal ()
  (adb-with-temp-db
   (should (string-equal (caar (sqlite-select (arc-db) "PRAGMA journal_mode;")) "wal"))))

(ert-deftest adb-raw-delete-cascades-to-data ()
  "The ON DELETE CASCADE itself must fire, not just `arc-source-delete's
explicit DELETE FROM data.  Deleting straight out of `sources' with no
help from arc-source-delete must still remove the row's `data' via the
foreign key -- this is the only thing that can catch `foreign_keys'
silently failing to turn on."
  (adb-with-temp-db
   (let ((id (arc-source-upsert '(:kind "file" :path "/tmp/x.nix"))))
     (sqlite-execute (arc-db)
      (format "INSERT INTO data (source_id, chunk, line_start, line_end) VALUES (%d, 'hi', 1, 2);" id))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (sqlite-execute (arc-db) (format "DELETE FROM sources WHERE id = %d;" id))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))))))
