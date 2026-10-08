;;; arc-test-helpers.el --- shared test isolation helpers -*- lexical-binding: t; -*-
(require 'arc)

(defmacro arc-test-with-temp-db (&rest body)
  "Run BODY against a throwaway arc database.
Binds `arc-db-directory' to a fresh temp directory and `arc--db' to
nil, so BODY can never read or write the user's real arc.sqlite, then
cleans up unconditionally, regardless of how BODY exits."
  `(let* ((arc-db-directory (make-temp-file "arc-test" t))
          (arc--db nil)
          ;; A fresh database must not see a previous test's cached stats or
          ;; freshness report: both caches are keyed by the write generation,
          ;; and opening a new temp DB does not move it.  Without these the
          ;; tool tests read whichever report the last suite left behind.
          (arc-index--stats-cache nil)
          (arc--freshness-cache nil))
     (unwind-protect (progn ,@body)
       (arc-close-db)
       (delete-directory arc-db-directory t))))

(provide 'arc-test-helpers)
;;; arc-test-helpers.el ends here
