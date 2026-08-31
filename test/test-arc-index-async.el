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
;; queue in `arc--reindex-async-collection': a request that has not yet
;; had its thunk popped is, as far as that queue is concerned, still
;; outstanding.
;;
;; A first round of review found the original version of this file's
;; cancellation test unfalsifiable: it cancelled against an otherwise
;; *empty* database, where a prune has nothing to delete, so it passed
;; equally well whether or not the run's own prune correctly skipped a
;; cancelled collection.  `aia-cancel-mid-run-does-not-prune-sources-
;; the-run-never-reached' below instead builds a real baseline first
;; and asserts on *which* sources survive a cancelled second run, by
;; identity, not merely that a row count happens to match.
;;; Code:
(require 'ert)
(defvar aia-root (expand-file-name ".." (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path aia-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
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
`aia-drain-all' or `aia-drain-one' can invoke later, in any order the
test chooses."
  (cl-incf aia-issued)
  (cl-incf aia-current-concurrent)
  (setq aia-max-concurrent (max aia-max-concurrent aia-current-concurrent))
  (setq aia-pending
        (append aia-pending
                (list (lambda ()
                        (cl-decf aia-current-concurrent)
                        (funcall vector-callback (vector 0.1 0.2 0.3)))))))

(defvar aia-error-texts nil
  "Chunk texts (see `aia-fake-sources') whose embedding should fail via
the error callback instead of succeeding, for
`aia-fake-embedding-async-with-errors'.")

(defun aia-fake-embedding-async-with-errors (_provider text vector-callback error-callback)
  "Like `aia-fake-embedding-async', but calls ERROR-CALLBACK instead of
VECTOR-CALLBACK for any TEXT listed in `aia-error-texts', simulating a
real Ollama/HTTP failure for that one chunk without touching the
others."
  (cl-incf aia-issued)
  (cl-incf aia-current-concurrent)
  (setq aia-max-concurrent (max aia-max-concurrent aia-current-concurrent))
  (setq aia-pending
        (append aia-pending
                (list (lambda ()
                        (cl-decf aia-current-concurrent)
                        (if (member text aia-error-texts)
                            (funcall error-callback 'error "induced embedding failure")
                          (funcall vector-callback (vector 0.1 0.2 0.3))))))))

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
  "Return N one-chunk info-kind source plists, distinctly identified.
PREFIX (default \"m\") sets the fake manual name each source's
`:info-node' claims to be from, so two calls with different PREFIXes
never collide on identity even if both use index 1..N -- `sources' is
collection-agnostic (see arc-db.el), so that distinctness matters
whenever a test cares which underlying source survived, not just how
many did."
  (cl-loop for i from 1 to n
           collect (list :kind "info" :info-node (format "(%s)Node%d" (or prefix "m") i)
                         :chunks (list (list :text (format "%s text %d" (or prefix "m") i)
                                             :line-start 1 :line-end 1)))))

(defun aia-fake-multi-chunk-source (info-node n-chunks)
  "Return one info-kind source plist identified by INFO-NODE with
N-CHUNKS distinct chunks."
  (list :kind "info" :info-node info-node
        :chunks (cl-loop for i from 1 to n-chunks
                         collect (list :text (format "%s chunk %d" info-node i)
                                       :line-start i :line-end i))))

(defun aia-source-count-for-node (node)
  (caar (sqlite-select
         (arc-db)
         (format "SELECT count(*) FROM sources WHERE info_node = %s;" (arc--sql-quote node)))))

(defun aia-chunk-texts-for-node (node)
  "Return the list of `data.chunk' texts currently stored for the
source identified by NODE (an `:info-node' value), in no particular
order.  Used to assert on *content survival*, not just a row count --
both C1 (round 2) and C1-residual (round 3) held \"row counts agree\"
under the bug, since a destroyed source's rows were destroyed cleanly."
  (mapcar #'car
          (sqlite-select
           (arc-db)
           (format "SELECT d.chunk FROM data d JOIN sources s ON s.id = d.source_id
                    WHERE s.info_node = %s;" (arc--sql-quote node)))))

(defun aia-consistency-ok-p ()
  "Return non-nil iff `data', `data_embeddings' and `data_fts' row counts
all agree and no `data' row's `source_id' is orphaned.  Necessary, but
-- as both Critical bugs a first review round found demonstrated --
not sufficient: both deleted whole sources cleanly, so this held under
either bug.  Callers must also assert on *which* sources survive."
  (let ((nd (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))
        (ne (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;")))
        (nf (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))
        (orphans (caar (sqlite-select
                        (arc-db)
                        "SELECT count(*) FROM data d
                         LEFT JOIN sources s ON s.id = d.source_id
                         WHERE s.id IS NULL;"))))
    (and (= nd ne) (= ne nf) (= orphans 0))))

(defmacro aia-capturing-messages (var &rest body)
  "Run BODY with every `message' call also pushed (formatted) onto VAR,
in addition to its normal *Messages* behavior, so a test can assert on
what was reported to the user without it being just one line among
hundreds in a buffer."
  (declare (indent 1))
  `(cl-letf* ((aia--orig-message (symbol-function 'message))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (when fmt (push (apply #'format fmt args) ,var))
                 (apply aia--orig-message fmt args))))
     ,@body))

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

(ert-deftest aia-async-reindex-never-prunes-a-source-the-producer-stopped-returning ()
  "The asynchronous path does not prune at all, by design (see
`arc-reindex-all''s and `arc--prune-collection''s docstrings): a
second, full (uncancelled) run whose producer legitimately stopped
returning some sources must leave them exactly as they were, not
delete them.  Only a synchronous reindex prunes -- see
`ai-reindex-all-prunes-sources-removed-from-the-corpus' in
test-arc-index.el for that."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (arc-index-info-cap nil)
          (first-run (aia-fake-sources 3 "stillhere")) ; (stillhere)Node1..3
          (second-run (aia-fake-sources 1 "new")))     ; (new)Node1
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) first-run)))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) second-run)))
       (arc-reindex-all nil t)
       (aia-drain-all))
     ;; the second run's producer never mentioned (stillhere)Node1..3 at
     ;; all -- an async prune, if one existed, would read that as "gone"
     (should (= 4 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;")))) ; 3 + 1
     (should (= 1 (aia-source-count-for-node "(new)Node1")))
     (should (= 1 (aia-source-count-for-node "(stillhere)Node1")))
     (should (= 1 (aia-source-count-for-node "(stillhere)Node2")))
     (should (= 1 (aia-source-count-for-node "(stillhere)Node3")))
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

;;; --- cancel never removes a source, by design (async never prunes) --

(ert-deftest aia-cancel-mid-run-does-not-remove-sources-the-run-never-reached ()
  "Originally a C1 regression test against a since-deleted prune call:
`arc-reindex-cancel' partway through a collection used to delete
sources this run had not gotten to yet, because the run's own
(now-removed) prune ran against an incomplete kept-list.  Pruning is
gone from the asynchronous path entirely now (see `arc-reindex-all''s
docstring), so nothing here CAN delete anything -- this test now
checks the more basic property that a cancel genuinely leaves
untouched sources untouched, end to end, by `info_node' identity and
not just a count.

Build a real baseline of 10 sources via a completed run first -- a
cancel against an empty database proves nothing: there is nothing yet
to lose, so it would pass regardless.  Then start a second run over the
very same 10 sources, cancel after only a few have settled, and assert
every one of the original 10 survives with exactly one chunk."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (arc-index-info-cap nil)
          (arc-index-max-in-flight 2)
          (fake (aia-fake-sources 10)))
     ;; baseline: fully index all 10, uncancelled
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (aia-consistency-ok-p))
     ;; second run over the SAME 10 sources; cancel after only 3 settle
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (aia-drain-one) (aia-drain-one) (aia-drain-one)
       (should arc--reindex-async-active) ; run is still going -- a real cancel, not a no-op
       (arc-reindex-cancel)
       (aia-drain-all))
     (should-not arc--reindex-async-active)
     ;; every one of the original 10, by identity, with exactly one chunk
     (dotimes (i 10)
       (let ((node (format "(m)Node%d" (1+ i))))
         (should (= 1 (aia-source-count-for-node node)))))
     (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (aia-consistency-ok-p)))))

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

;;; --- M1: a non-positive `arc-index-max-in-flight' is rejected --------

(ert-deftest aia-zero-max-in-flight-is-rejected-not-a-silent-wedge ()
  "0 would issue no requests at all and leave `arc--reindex-async-active'
set forever with nothing to converge on -- caught explicitly instead."
  (aia-with-temp-db
   (let ((arc-index-plan '(("m" . info)))
         (arc-index-max-in-flight 0))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) (aia-fake-sources 1))))
       (should-error (arc-reindex-all nil t) :type 'user-error)
       (should-not arc--reindex-async-active)))))

;;; --- the replace itself is all-or-nothing under a quit ----------------

(ert-deftest aia-replace-source-chunks-rolls-back-a-quit-partway-through ()
  "`arc--replace-source-chunks' is a single sqlite transaction spanning
the upsert, the delete of old content, and every new chunk's insert; a
`quit' signal (what `C-g' raises) landing partway through -- here,
after the `data' insert but before the embedding/FTS inserts -- must
roll the whole thing back: no half-upserted `sources' row, no orphaned
`data' row with no vector and no FTS row."
  (aia-with-temp-db
   (let ((cid (arc--collection-id "test")))
     (cl-letf (((symbol-function 'arc-vector-to-sqlite)
                (lambda (&rest _) (signal 'quit nil))))
       (condition-case nil
           (arc--replace-source-chunks '(:kind "info" :info-node "(m)X") cid
                                        (list (list "hello" 1 1 (vector 0.1 0.2 0.3))))
         (quit nil)))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))
     (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;")))))))

(ert-deftest aia-replace-source-chunks-succeeds-normally ()
  (aia-with-temp-db
   (let ((cid (arc--collection-id "test")))
     (arc--replace-source-chunks '(:kind "info" :info-node "(m)X") cid
                                  (list (list "hello" 1 1 (vector 0.1 0.2 0.3))))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (aia-consistency-ok-p)))))

(ert-deftest aia-replace-source-chunks-genuinely-changes-content-on-success ()
  "Guards against an implementation that never actually writes: replace
a source that already has content with DIFFERENT content and confirm
the new text wins, not the old -- proves the success path really does
replace, not just that failure paths correctly do nothing."
  (aia-with-temp-db
   (let ((cid (arc--collection-id "test")))
     (arc--replace-source-chunks '(:kind "info" :info-node "(m)X")
                                  cid (list (list "old text" 1 1 (vector 0.1 0.2 0.3))))
     (should (equal '("old text") (aia-chunk-texts-for-node "(m)X")))
     (arc--replace-source-chunks '(:kind "info" :info-node "(m)X")
                                  cid (list (list "new text" 1 1 (vector 0.4 0.5 0.6))))
     (should (equal '("new text") (aia-chunk-texts-for-node "(m)X")))
     (should (aia-consistency-ok-p)))))

;;; --- C2: a failing write must not leak the in-flight slot -------------

(ert-deftest aia-write-failure-does-not-leak-in-flight-slot-and-run-still-converges ()
  "Critical regression test (C2): the success callback used to call the
write directly and only then `settle', so any signal out of the write
(an sqlite error, here induced) skipped `settle' entirely, leaking
that in-flight slot forever.  Reproduced live before the fix: 3
induced write failures stalled a 20-chunk run at 9 of 20, with
`arc-reindex-cancel' unable to recover it and every later
`M-x arc-reindex-all' rejected for the rest of the session because
`arc--reindex-async-active' never cleared.  Poisons
`arc--insert-chunk-row', the shared primitive `arc--replace-source-
chunks' uses -- not `arc--write-chunk', which the async path no longer
calls at all since C1-residual's atomic-per-source rewrite -- so this
also doubles as coverage that a failure inside
`arc--replace-source-chunks''s own transaction is caught and reported
by `source-settled' rather than escaping it.  With the fix, a run with
some induced write failures must still run every request to completion
and end with `arc--reindex-async-active' nil -- not wedged -- while the
sources whose replace failed never get a `sources' row at all now
(round 4 moved the upsert itself into `arc--replace-source-chunks',
inside the same transaction), so \"left untouched\" and \"never
created\" coincide for these fresh sources; see the C1-residual tests
below for the case (an existing source) that actually distinguishes
the two."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (arc-index-max-in-flight 3)
          (fake (aia-fake-sources 12))
          (poison-texts '("m text 3" "m text 6" "m text 9"))
          (real-insert (symbol-function 'arc--insert-chunk-row))
          (captured nil))
     (aia-capturing-messages captured
       (cl-letf (((symbol-function 'arc--insert-chunk-row)
                  ;; &rest, not a fixed arity: this stub wraps a production
                  ;; primitive, and pinning its argument list here means any
                  ;; future argument turns "the write failed" into a test
                  ;; failure that looks like a logic bug. That is exactly what
                  ;; happened when `arc--insert-chunk-row' gained LOCATOR.
                  (lambda (sid cid text &rest rest)
                    (if (member text poison-texts)
                        (error "aia: induced write failure for %s" text)
                      (apply real-insert sid cid text rest))))
                 ((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
                 ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
         (arc-reindex-all nil t)
         (aia-drain-all)))
     ;; the run converged -- not wedged -- despite 3 write failures
     (should-not arc--reindex-async-active)
     ;; only the 9 sources whose replace transaction succeeded exist at
     ;; all: the upsert itself is inside that same failed transaction
     ;; for the other 3, so it rolled back along with everything else
     (should (= 9 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (= 9 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (aia-consistency-ok-p))
     ;; a fresh async run -- a different collection entirely, so it
     ;; cannot be mistaken for the first one somehow still finishing --
     ;; is possible immediately: not rejected as "already running" the
     ;; way the un-fixed leak left it forever.
     (let ((arc-index-plan '(("other" . info))))
       (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
                 ((symbol-function 'arc-info-sources) (lambda (&rest _) (aia-fake-sources 1 "fresh"))))
         (arc-reindex-all nil t)
         (aia-drain-all)))
     (should (= 1 (aia-source-count-for-node "(fresh)Node1")))
     ;; I2: the original failure must be loud, not one message among hundreds
     (should (cl-some (lambda (m) (string-match-p "3 source(s) not replaced" m)) captured))
     ;; and the message must be a fair count, not a misleading one
     (should (cl-some (lambda (m) (string-match-p "9 source(s) replaced" m)) captured)))))

;;; --- I2/error-callback path: an embedding failure is skipped, loudly -

(ert-deftest aia-embedding-error-callback-is-skipped-not-fatal-and-is-reported ()
  "A per-chunk embedding failure (the error callback, not a write
failure) must be skipped rather than aborting the run, and must show
up in the completion summary rather than only as one `message' among
many progress lines."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (fake (aia-fake-sources 6))
          (aia-error-texts '("m text 2" "m text 4"))
          (captured nil))
     (aia-capturing-messages captured
       (cl-letf (((symbol-function 'llm-embedding-async) #'aia-fake-embedding-async-with-errors)
                 ((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
                 ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
         (arc-reindex-all nil t)
         (aia-drain-all)))
     (should-not arc--reindex-async-active)
     ;; the 2 sources whose one chunk failed to embed never get a
     ;; `sources' row at all: nothing about a source is created until
     ;; it is actually replaced.
     (should (= 4 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (= 4 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (aia-consistency-ok-p))
     (should (cl-some (lambda (m) (string-match-p "2 source(s) not replaced" m)) captured)))))

;;; --- multi-chunk sources: a source is only "done" after every chunk -

(ert-deftest aia-multi-chunk-source-writes-every-chunk-and-counts-as-one-source ()
  "A source with several chunks (unlike the one-chunk-per-source Info/
NixOS/HM cases the concurrency test above exercises) must have every
one of its chunks written, and must only be counted done -- for
progress and for `kept' -- once all of them have settled, not the
first."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (arc-index-max-in-flight 4)
          (fake (list (aia-fake-multi-chunk-source "(m)Big" 5)
                      (car (aia-fake-sources 1 "solo")))))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (should (= 2 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (= 6 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))) ; 5 + 1
     (should (= 5 (caar (sqlite-select
                         (arc-db)
                         (format "SELECT count(*) FROM data d JOIN sources s ON s.id = d.source_id
                                  WHERE s.info_node = %s;" (arc--sql-quote "(m)Big"))))))
     (should (aia-consistency-ok-p)))))

;;; --- multi-collection chaining: the async path advances past cell 1 -

(ert-deftest aia-async-reindex-chains-through-every-plan-entry ()
  "`arc--reindex-async-next-cell' must actually advance to the next
`arc-index-plan' entry once the current one's collection finishes, not
just process the first and stop -- both collections' producers must
run, and both collections' sources must end up indexed."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("collection one" . info) ("collection two" . info)))
          (fixtures (list (aia-fake-sources 3 "c1") (aia-fake-sources 2 "c2")))
          (calls 0))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources)
                (lambda (&rest _) (cl-incf calls) (pop fixtures))))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (should (= 2 calls)) ; both collections' producer ran
     (should (= 2 (caar (sqlite-select (arc-db) "SELECT count(*) FROM collections;"))))
     (should (= 5 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;")))) ; 3 + 2
     (should (= 5 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))
     (should (= 1 (aia-source-count-for-node "(c1)Node1")))
     (should (= 1 (aia-source-count-for-node "(c2)Node1")))
     (should (aia-consistency-ok-p)))))


;;; --- C1-residual: a source's replacement is atomic, not per-chunk ----

(ert-deftest aia-cancel-mid-large-multi-chunk-source-keeps-its-old-content-intact ()
  "C1-residual regression test: cancelling partway through a single
large multi-chunk source must not truncate that source's content.
Reproduced live against the real corpus's worst case: a 477-chunk
source, default in-flight 4, cancel after only 2 of its chunks had
settled -- `arc--delete-data-for-source' used to run the instant the
source was advanced into (not once its replacement was actually ready),
so the other 475 chunks, never even dispatched by the time cancel took
effect, were simply gone, while `arc-reindex-cancel' reported \"leaving
existing rows untouched\" for precisely the source that had just been
gutted.  Build a real baseline (20 chunks -- smaller, same shape),
reindex the identical source again with a small in-flight window,
cancel after only 2 of its chunks settle -- well before all 20 could
even be dispatched -- and assert the source's chunk *texts*, not just a
count, are still exactly the original 20."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (arc-index-max-in-flight 4)
          (big (aia-fake-multi-chunk-source "(m)Big" 20)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) (list big))))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (let ((baseline (sort (aia-chunk-texts-for-node "(m)Big") #'string<)))
       (should (= 20 (length baseline)))
       (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
                 ((symbol-function 'arc-info-sources) (lambda (&rest _) (list big))))
         (arc-reindex-all nil t)
         (aia-drain-one) (aia-drain-one)
         (should arc--reindex-async-active) ; well before all 20 could settle
         (arc-reindex-cancel)
         (aia-drain-all))
       (should-not arc--reindex-async-active)
       (should (equal baseline (sort (aia-chunk-texts-for-node "(m)Big") #'string<)))
       (should (aia-consistency-ok-p))))))

(ert-deftest aia-embedding-failure-in-one-chunk-of-a-multi-chunk-source-keeps-old-content ()
  "A source is replaced all-or-nothing: one failed chunk among several
must leave that source's OLD content exactly as it was, never a mix of
new-and-missing chunks."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (big (aia-fake-multi-chunk-source "(m)Big" 5)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) (list big))))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (let ((baseline (sort (aia-chunk-texts-for-node "(m)Big") #'string<))
           (aia-error-texts (list "(m)Big chunk 3")))
       (should (= 5 (length baseline)))
       (cl-letf (((symbol-function 'llm-embedding-async) #'aia-fake-embedding-async-with-errors)
                 ((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
                 ((symbol-function 'arc-info-sources) (lambda (&rest _) (list big))))
         (arc-reindex-all nil t)
         (aia-drain-all))
       (should-not arc--reindex-async-active)
       (should (equal baseline (sort (aia-chunk-texts-for-node "(m)Big") #'string<)))
       (should (aia-consistency-ok-p))))))

;;; --- I1 mutation-verified: a synchronously-settling callback ----------

(defun aia-fake-embedding-async-sync (_provider _text vector-callback _error-callback)
  "Calls VECTOR-CALLBACK synchronously, immediately -- unlike
`aia-fake-embedding-async', which defers via `aia-pending' for the test
to drain by hand.  A real embedding provider (plz) never calls back
this way, but a stub, a cache, or a future local embedder might; this
is what exercises I1's reentrancy guard, which real `plz' traffic never
touches (every fake elsewhere in this file defers, which is exactly why
I1 first shipped without a test that could catch it)."
  (cl-incf aia-issued)
  (funcall vector-callback (vector 0.1 0.2 0.3)))

(ert-deftest aia-synchronous-callback-does-not-fire-completion-twice ()
  "I1 regression test, mutation-verified by hand against both halves of
the fix (see the report): reverting either -- rechecking `(not
finished)' in the completion branch, or using non-destructive `reverse'
where `kept' once lived -- turns this red.  A synchronously-settling
stub re-enters `pump' from inside the dispatch loop before the outer
call has unwound; an unguarded completion check used to fire
`on-collection-done' more than once -- reproduced live: 7 firings for
one 8-source collection (back when `on-collection-done' still carried
a destructively-`nreverse'd `kept' list, a prune result mangled from 8
down to 1; `kept' and the prune it fed are both gone now, per round 4,
but the reentrancy this exercises is a property of `pump' itself, not
of what `on-collection-done' used to do with its arguments).
`arc--reindex-async-next-cell' calls itself with an empty CELLS exactly
once per genuine completion (the \"this collection is done, move on\"
step), so counting *that* is a direct, external proxy for how many
times `on-collection-done' actually fired that does not depend on
pruning existing at all."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (fake (aia-fake-sources 8))
          (finish-calls 0)
          (real-next-cell (symbol-function 'arc--reindex-async-next-cell)))
     (cl-letf (((symbol-function 'llm-embedding-async) #'aia-fake-embedding-async-sync)
               ((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake))
               ((symbol-function 'arc--reindex-async-next-cell)
                (lambda (run cells)
                  (when (null cells) (cl-incf finish-calls))
                  (funcall real-next-cell run cells))))
       (arc-reindex-all nil t))
     (should (= 1 finish-calls))
     (should (= 8 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (should (aia-consistency-ok-p)))))


;;; --- C-4: an upsert failure must not cascade into deleting anything --

(ert-deftest aia-induced-transient-upsert-failure-does-not-destroy-anything ()
  "C-4 regression test: an error out of `arc-source-upsert' for one
source used to leave that source out of a since-removed `kept' list;
the run's own (now-removed) end-of-collection prune then read the
incomplete kept-list and deleted every OTHER source in the collection
too -- measured before the fix: 30 chunks / 10 sources reindexed with
one upsert failure among them converged cleanly reporting \"removed 10
stale source(s)\".  Pruning is gone from the asynchronous path
entirely now, so this reproduction must be inert: build a baseline,
reindex again with one source's upsert failing exactly once (a
transient failure -- a momentary sqlite lock, say), and confirm every
OTHER source's chunk texts are byte-identical to baseline and nothing
at all was deleted."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (fake (aia-fake-sources 10))
          (real-upsert (symbol-function 'arc-source-upsert))
          (poisoned nil))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
     (let ((baseline (mapcar (lambda (n) (cons n (aia-chunk-texts-for-node (format "(m)Node%d" n))))
                              (number-sequence 1 10))))
       (cl-letf (((symbol-function 'arc-source-upsert)
                  (lambda (source)
                    (if (and (equal (plist-get source :info-node) "(m)Node5") (not poisoned))
                        (progn (setq poisoned t)
                               (error "aia: induced transient upsert failure"))
                      (funcall real-upsert source))))
                 ((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
                 ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
         (arc-reindex-all nil t)
         (aia-drain-all))
       (should-not arc--reindex-async-active)
       (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
       (dolist (pair baseline)
         (should (equal (cdr pair) (aia-chunk-texts-for-node (format "(m)Node%d" (car pair))))))
       (should (aia-consistency-ok-p))))))

(ert-deftest aia-induced-persistent-upsert-failure-does-not-destroy-anything ()
  "Same reproduction as the transient case, but the failure never
lifts -- a permanently locked path, say -- across two consecutive
runs, confirming repetition alone never cascades into deleting
anything either."
  (aia-with-temp-db
   (let* ((arc-index-plan '(("m" . info)))
          (fake (aia-fake-sources 10))
          (real-upsert (symbol-function 'arc-source-upsert)))
     (cl-letf (((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
               ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
       (arc-reindex-all nil t)
       (aia-drain-all))
     (let ((baseline (mapcar (lambda (n) (cons n (aia-chunk-texts-for-node (format "(m)Node%d" n))))
                              (number-sequence 1 10)))
           (poison (lambda (source)
                     (if (equal (plist-get source :info-node) "(m)Node5")
                         (error "aia: induced persistent upsert failure")
                       (funcall real-upsert source)))))
       (dotimes (_ 2)
         (cl-letf (((symbol-function 'arc-source-upsert) poison)
                   ((symbol-function 'arc-get-builtin-manuals) (lambda () '("m")))
                   ((symbol-function 'arc-info-sources) (lambda (&rest _) fake)))
           (arc-reindex-all nil t)
           (aia-drain-all))
         (should-not arc--reindex-async-active)
         (should (= 10 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))
         (dolist (pair baseline)
           (should (equal (cdr pair) (aia-chunk-texts-for-node (format "(m)Node%d" (car pair))))))
         (should (aia-consistency-ok-p)))))))

;;; --- a settle called twice must be inert, not destructive ------------

(ert-deftest aia-embed-chunk-settle-is-idempotent ()
  "Unit-level regression test for `arc--reindex-async-embed-chunk''s
own contract: SETTLE must be called exactly once, even when the
underlying `llm-embedding-async' misbehaves and invokes its success
callback twice (a buggy provider, or standing in for any other reason
a second call could happen).  This is the mechanism that keeps a
double-settle from being destructive one level up: without it,
`arc--reindex-async-collection''s `chunk-settled' would run twice for
one chunk, and a second run reads bookkeeping the first run already
cleared -- `remaining-in-source' back to a default \"1 remaining\",
`source-chunks' reset to empty -- re-triggering `source-settled' and a
second, premature `arc--replace-source-chunks' call built from
whatever the accumulator happens to hold at that moment, not the
source's true, complete set of chunks.  Testing this directly, at the
boundary that actually guarantees it, is more precise than trying to
predict the exact shape of the resulting corruption several calls
downstream."
  (let ((calls 0))
    (cl-letf (((symbol-function 'llm-embedding-async)
               (lambda (_provider _text vector-callback _error-callback)
                 (funcall vector-callback (vector 0.1 0.2 0.3))
                 (funcall vector-callback (vector 0.7 0.8 0.9)))))
      (arc--reindex-async-embed-chunk
       (list :text "hello" :line-start 1 :line-end 1)
       (lambda (&rest _) (cl-incf calls))))
    (should (= 1 calls))))

(provide 'test-arc-index-async)
;;; test-arc-index-async.el ends here
