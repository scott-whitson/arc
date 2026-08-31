;;; test-arc-migration.el --- unmigrated-function guards stay honest -*- lexical-binding: t; -*-
(require 'ert)
(defvar am-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path am-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest am-unmigrated-list-has-exactly-five-entries ()
  "This list may only shrink as functions are migrated off the
pre-`sources' schema.  If it grows, or a migrated entry is left in
it, this test should be the thing that says so -- update the expected
count deliberately.  Task 10 migrated the info-manual parser (it is
now a pure function returning an alist, with its SQL moved to Task
11's indexer), dropping the count from 7 to 6.  Task 11 then migrated
the query-and-context path that fed arc's former chat buffer (its
query now joins `data' to `sources' via `arc--retrieve-rows'),
dropping the count from 6 to 5 -- before Task 6 deleted that whole
path outright, functions and all, once `arc-ask' replaced it."
  (should (= (length arc--unmigrated-functions) 5)))

(ert-deftest am-unmigrated-functions-still-exist ()
  "Every guarded symbol must still be a real function.
Catches a rename or deletion that forgot to update the list."
  (dolist (fn arc--unmigrated-functions)
    (should (fboundp fn))))

(ert-deftest am-guard-signals-user-error ()
  "Calling an unmigrated function must fail loudly and immediately,
naming the owning task, rather than with a raw SQL error."
  (should-error (arc--not-yet-migrated 'arc-parse-file) :type 'user-error))

(defconst am-dummy-args
  '((arc-parse-file . (1 "x"))
    (arc-parse-directory . ("x"))
    (arc-remove-collection . ())
    (arc-add-file-to-collection . ("x" "y"))
    (arc-recalculate-embeddings . ()))
  "Dummy arguments, matching each guarded function's arity, used only
to reach the `arc--not-yet-migrated' call at the top of its body.
Values are never used -- the guard must signal before anything reads
them -- but the arity must be right or a wrong-number-of-arguments
error would fire first and this test would (correctly) fail.")

(ert-deftest am-guard-call-still-present-in-every-listed-body ()
  "The count test above catches a shortened list; it does not catch a
guard call quietly deleted from a function's body while the symbol
stays listed.  This test calls every remaining entry with dummy
arguments and requires `arc--not-yet-migrated''s own message, naming
that exact function, to come back -- not merely `some' error.  A body
that was quietly migrated (or broken in some other way) would raise a
different error, or none, and this test would catch that instead."
  (should (= (length am-dummy-args) (length arc--unmigrated-functions)))
  (dolist (fn arc--unmigrated-functions)
    (let* ((args (alist-get fn am-dummy-args))
           ;; `format-message', not `format': `user-error' renders its
           ;; quotes via `text-quoting-style' (curly by default), so a
           ;; literal backtick/apostrophe here would never match.
           (expected (format-message "arc: `%s' has not been migrated to the sources schema yet \
(Task 10/11 owns this); it would fail against the current tables" fn))
           (actual (condition-case err
                       (progn (apply fn args) "NO ERROR WAS SIGNALED")
                     (error (error-message-string err)))))
      (should (equal actual expected)))))

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
