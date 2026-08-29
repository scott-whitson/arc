;;; test-arc-migration.el --- unmigrated-function guards stay honest -*- lexical-binding: t; -*-
(require 'ert)
(defvar am-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path am-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'arc)

(ert-deftest am-unmigrated-list-has-exactly-six-entries ()
  "This list may only shrink as Tasks 10/11 migrate each function.
If it grows, or a migrated entry is left in it, this test should be
the thing that says so -- update the expected count deliberately.
Task 10 migrated `arc-parse-info-manual' (it is now a pure function
returning an alist, with its SQL moved to Task 11's indexer), so the
count drops from 7 to 6."
  (should (= (length arc--unmigrated-functions) 6)))

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
    (arc-retrieve-ask . (nil nil))
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
