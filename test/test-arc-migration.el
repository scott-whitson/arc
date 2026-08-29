;;; test-arc-migration.el --- unmigrated-function guards stay honest -*- lexical-binding: t; -*-
(require 'ert)
(defvar am-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path am-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'arc)

(ert-deftest am-unmigrated-list-has-exactly-seven-entries ()
  "This list may only shrink as Tasks 10/11 migrate each function.
If it grows, or a migrated entry is left in it, this test should be
the thing that says so -- update the expected count deliberately."
  (should (= (length arc--unmigrated-functions) 7)))

(ert-deftest am-unmigrated-functions-still-exist ()
  "Every guarded symbol must still be a real function.
Catches a rename or deletion that forgot to update the list."
  (dolist (fn arc--unmigrated-functions)
    (should (fboundp fn))))

(ert-deftest am-guard-signals-user-error ()
  "Calling an unmigrated function must fail loudly and immediately,
naming the owning task, rather than with a raw SQL error."
  (should-error (arc--not-yet-migrated 'arc-parse-file) :type 'user-error))
