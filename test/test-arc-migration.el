;;; test-arc-migration.el --- schema migrations land and stay idempotent -*- lexical-binding: t; -*-
(require 'ert)
(defvar am-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path am-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest am-adds-tags-column-to-a-v1-database ()
  "A database created before Task 2 must gain `tags' without losing rows."
  (arc-test-with-temp-db
   ;; Build a v1-shaped sources table by hand, then let arc open it.
   (let ((db (arc-db)))
     (sqlite-execute db "DROP TABLE IF EXISTS sources;")
     (sqlite-execute db "CREATE TABLE sources (
  id INTEGER PRIMARY KEY, kind TEXT NOT NULL, path TEXT, org_id TEXT,
  option_name TEXT, info_node TEXT, hash TEXT, mtime INTEGER, indexed_at INTEGER);")
     (sqlite-execute db "INSERT INTO sources (kind, path) VALUES ('file', '/tmp/pre-existing.txt');")
     (sqlite-execute db "PRAGMA user_version = 1;")
     (should-not (arc--column-exists-p db "sources" "tags"))
     (arc--migrate-db db)
     (should (arc--column-exists-p db "sources" "tags"))
     (should (= 1 (caar (sqlite-select db "SELECT count(*) FROM sources;"))))
     ;; The constant, not a literal: a migration lands with its own test,
     ;; and pinning the number here means every future one also fails a
     ;; test about tags, which reads like an unrelated regression.
     (should (= arc-db-schema-version
                (caar (sqlite-select db "PRAGMA user_version;")))))))

(ert-deftest am-migration-is-idempotent ()
  (arc-test-with-temp-db
   (let ((db (arc-db)))
     (arc--migrate-db db)
     (arc--migrate-db db)
     (should (arc--column-exists-p db "sources" "tags")))))

(provide 'test-arc-migration)
;;; test-arc-migration.el ends here
