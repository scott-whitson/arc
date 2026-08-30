;;; test-arc-index-async.el --- asynchronous reindex is deterministic and safe -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; These tests never let a real timer decide when anything runs.  A
;; fake `llm-embedding-async' queues each request's completion as a
;; thunk on `aia-pending' instead of calling its callback right away;
;; the test itself decides when (and in what order) each one "arrives"
;; by popping and calling those thunks.  That keeps every test in this
;; file exactly as deterministic as the synchronous suite -- nothing
;; here depends on a timer actually firing, real wall-clock delay, or
;; `sit-for' -- while still genuinely exercising the bounded in-flight
;; queue in `arc--reindex-async-chunks': a request that has not yet had
;; its thunk popped is, as far as that queue is concerned, still
;; outstanding.
;;; Code:
(require 'ert)
(defvar aia-root (expand-file-name ".." (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path aia-root)
(setenv "ARC_VEC0_PATH"
        (or (getenv "ARC_VEC0_PATH")
            "/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so"))
(require 'arc)
(require 'arc-index)

(defvar aia-pending nil
  "FIFO queue of zero-argument thunks, one per outstanding fake embedding
request, oldest first.")
(defvar aia-current-concurrent 0)
(defvar aia-max-concurrent 0)
(defvar aia-issued 0 "Total number of embedding requests issued.")

(defun aia-reset ()
  (setq aia-pending nil aia-current-concurrent 0 aia-max-concurrent 0 aia-issued 0))

(defun aia-fake-embedding-async (_provider _text vector-callback _error-callback)
  "A `llm-embedding-async' stand-in that never calls back on its own.
Records concurrency and appends a thunk to `aia-pending' that
`aia-drain' or `aia-drain-one' can invoke later, in any order the test
chooses."
  (cl-incf aia-issued)
  (cl-incf aia-current-concurrent)
  (setq aia-max-concurrent (max aia-max-concurrent aia-current-concurrent))
  (setq aia-pending
        (append aia-pending
                (list (lambda ()
                        (cl-decf aia-current-concurrent)
                        (funcall vector-callback (vector 0.1 0.2 0.3)))))))

(defun aia-drain-one ()
  "Pop and call the oldest pending fake request's callback.  Return t if
one was popped, nil if `aia-pending' was empty."
  (when aia-pending
    (let ((thunk (car aia-pending)))
      (setq aia-pending (cdr aia-pending))
      (funcall thunk)
      t)))

(defun aia-drain-all ()
  "Call every pending fake request's callback, including ones that only
become pending as a side effect of an earlier one completing (the
queue refilling up to `arc-index-max-in-flight'), until none are left."
  (while (aia-drain-one)))

(defmacro aia-with-temp-db (&rest body)
  `(let* ((arc-db-directory (make-temp-file "arc-idx-async" t))
          (arc--db nil)
          (arc-embedding-size 3)
          (arc--reindex-async-active nil))
     (aia-reset)
     (cl-letf (((symbol-function 'llm-embedding-async) #'aia-fake-embedding-async))
       (unwind-protect (progn ,@body)
         (arc-close-db)
         (delete-directory arc-db-directory t)))))

(defun aia-fake-sources (n &optional prefix)
  "Return N one-chunk info-kind source plists, distinctly identified."
  (cl-loop for i from 1 to n
           collect (list :kind "info" :info-node (format "(%s)Node%d" (or prefix "m") i)
                         :chunks (list (list :text (format "text %d" i) :line-start 1 :line-end 1)))))

(defun aia-consistency-ok-p ()
  "Return non-nil iff `data', `data_embeddings' and `data_fts' row counts
all agree and no `data' row's `source_id' is orphaned."
  (let ((nd (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))
        (ne (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;")))
        (nf (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))
        (orphans (caar (sqlite-select
                        (arc-db)
                        "SELECT count(*) FROM data d
                         LEFT JOIN sources s ON s.id = d.source_id
                         WHERE s.id IS NULL;"))))
    (and (= nd ne) (= ne nf) (= orphans 0))))

;;; --- async run reaches the same end state as the sync one ----------

(ert-deftest aia-async-reindex-indexes-every-source ()
  (aia-with-temp-db
   (let ((arc-index-plan '(("m" . info)))
         (arc-index-info-cap nil)
         (fake (aia-fake-sources 5)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (should arc--reindex-async-active)
       (aia-drain-all)
       (should-not arc--reindex-async-active))
     (should (= 5 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (= 5 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (aia-consistency-ok-p)))))

(ert-deftest aia-async-reindex-prunes-like-the-sync-path ()
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (arc-index-info-cap nil)
          (fake (aia-fake-sources 3)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) (aia-fake-sources 1))))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (aia-consistency-ok-p)))))

;;; --- the in-flight window is actually bounded ------------------------

(ert-deftest aia-async-reindex-bounds-in-flight-requests ()
  "`arc-index-max-in-flight' requests may be outstanding at once, never
more -- and, to prove this is a real bound and not an accident of a
tiny corpus, at least that many really do overlap."
  (aia-with-temp-db
   (let ((arc-index-plan '(("m" . info)))
         (arc-index-info-cap nil)
         (arc-index-max-in-flight 2)
         (fake (aia-fake-sources 9)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       ;; drain slowly, one at a time, so concurrency is observed rather
       ;; than collapsed by draining everything in one shot
       (while (aia-drain-one))
       (should (<= aia-max-concurrent 2))
       (should (= aia-max-concurrent 2))
       (should (= 9 aia-issued))))))

;;; --- an interrupted (cancelled) run corrupts nothing ------------------

(ert-deftest aia-cancel-mid-run-leaves-a-consistent-db ()
  "A user's `C-g' has nothing to interrupt in the async path -- Emacs is
never blocked waiting on it -- so `arc-reindex-cancel' is the actual
interrupt affordance; simulate pressing it partway through a run and
confirm the invariants `arc-reindex-all' promises still hold: every
written chunk has both an embedding and an FTS row, and no orphans."
  (aia-with-temp-db
   (let ((arc-index-plan '(("m" . info)))
         (arc-index-info-cap nil)
         (arc-index-max-in-flight 2)
         (fake (aia-fake-sources 10)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       ;; let a few requests land, then cancel before the run finishes
       (aia-drain-one)
       (aia-drain-one)
       (aia-drain-one)
       (should arc--reindex-async-active) ; run is still going
       (arc-reindex-cancel)
       ;; anything already in flight is still honored...
       (aia-drain-all)
       ;; ...but the run stopped short of all 10 sources
       (should-not arc--reindex-async-active)
       (let ((indexed (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
         (should (< indexed 10))
         (should (> indexed 0)))
       (should (aia-consistency-ok-p))))))

(ert-deftest aia-cancel-with-nothing-running-just-messages ()
  (aia-with-temp-db
   (should-not arc--reindex-async-active)
   ;; must not signal
   (arc-reindex-cancel)))

(ert-deftest aia-second-concurrent-async-run-is-rejected ()
  (aia-with-temp-db
   (let ((arc-index-plan '(("m" . info)))
         (fake (aia-fake-sources 3)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (should-error (arc-reindex-all nil t) :type 'user-error)
       (aia-drain-all)))))

;;; --- interactive M-x arc-reindex-all is the async path ---------------

(ert-deftest aia-interactive-call-dispatches-to-async ()
  "The whole point: `M-x arc-reindex-all' -- an ordinary interactive
call with no arguments -- must be the non-blocking path, not the one
that freezes Emacs for tens of minutes."
  (let ((called nil))
    (cl-letf (((symbol-function 'arc--reindex-all-async) (lambda (&optional _c) (setq called 'async)))
              ((symbol-function 'arc--reindex-all-sync) (lambda (&optional _c) (setq called 'sync))))
      (call-interactively #'arc-reindex-all)
      (should (eq called 'async)))))

(ert-deftest aia-programmatic-call-with-no-async-arg-stays-sync ()
  "`(arc-reindex-all)' and `(arc-reindex-all COLLECTIONS)' -- exactly how
the rest of the test suite and any scripted ingest call it -- must
still be the deterministic synchronous path with no argument change
required on their part."
  (let ((called nil))
    (cl-letf (((symbol-function 'arc--reindex-all-async) (lambda (&optional _c) (setq called 'async)))
              ((symbol-function 'arc--reindex-all-sync) (lambda (&optional _c) (setq called 'sync))))
      (arc-reindex-all)
      (should (eq called 'sync))
      (setq called nil)
      (arc-reindex-all '("some-collection"))
      (should (eq called 'sync)))))

;;; --- the write itself is all-or-nothing under a quit ------------------

(ert-deftest aia-write-chunk-rolls-back-a-quit-partway-through ()
  "`arc--write-chunk' is a single sqlite transaction spanning `data',
`data_embeddings' and `data_fts'; a `quit' signal (what `C-g' raises)
landing after the `data' insert but before the embedding/FTS inserts
must roll the whole thing back rather than leaving an orphaned `data'
row with no vector and no FTS row."
  (aia-with-temp-db
   (let ((cid (arc--collection-id "test"))
         (sid (arc-source-upsert '(:kind "info" :info-node "(m)X"))))
     (cl-letf (((symbol-function 'arc-vector-to-sqlite)
                (lambda (&rest _) (signal 'quit nil))))
       (condition-case nil
           (arc--write-chunk sid cid "hello" 1 1 nil (vector 0.1 0.2 0.3))
         (quit nil)))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))))))

(ert-deftest aia-write-chunk-succeeds-normally ()
  (aia-with-temp-db
   (let ((cid (arc--collection-id "test"))
         (sid (arc-source-upsert '(:kind "info" :info-node "(m)X"))))
     (arc--write-chunk sid cid "hello" 1 1 nil (vector 0.1 0.2 0.3))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (aia-consistency-ok-p)))))

(provide 'test-arc-index-async)
;;; test-arc-index-async.el ends here
