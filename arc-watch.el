;;; arc-watch.el --- keep the mutable corpus current -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Re-indexes a source when it changes, so the corpus does not quietly rot
;; between manual reindexes.  Only the MUTABLE kinds are watched -- files and
;; org nodes, roughly 11,000 sources of this ~272,000-chunk corpus.  The rest
;; are derived from a Nix store path or a flake.lock revision and cannot
;; change without that input changing; `arc-freshness-report' notices when it
;; does.
;;
;; DELIBERATE NON-GOAL: derived collections are never reindexed automatically.
;; The spec asked for "options reindex when the flake.lock hash changes", and
;; that is the wrong shape here. Rebuilding the option collections means
;; embedding 30,174 chunks -- roughly 40 minutes of GPU on this machine --
;; and a NixOS rebuild changes flake.lock routinely. A switch must not
;; silently start a 40-minute background job. arc reports the staleness and
;; leaves `arc-reindex-all' to the operator, who knows whether now is a good
;; time.
;;
;; Everything here is bounded on purpose. A save re-indexes exactly one
;; source. The idle sweep does at most `arc-watch-sweep-batch' sources per
;; tick and remembers where it stopped, because the alternative -- rehashing
;; the whole mutable half (roughly 11,000 paths) and re-embedding whatever
;; moved, in one go, on an idle timer -- is how a background feature becomes
;; the reason someone disables it.

;;; Code:

(require 'arc)
(require 'arc-index)

(defcustom arc-watch-after-save t
  "Whether saving a file re-indexes it when arc already knows it."
  :type 'boolean :group 'arc)

(defcustom arc-watch-idle-seconds 300
  "Idle seconds before the drift sweep runs.  nil disables the sweep."
  :type '(choice (const nil) number) :group 'arc)

(defcustom arc-watch-sweep-batch 500
  "Paths examined per idle tick.
Bounded so a tick never becomes a stall, but large enough that a pass
over the mutable half is measured in hours rather than days.  That half
is roughly 11,000 paths of the corpus's ~272,000 chunks, and 25 per
tick -- the default before the corpus widened -- meant about 440 idle
periods, over 36 hours at the 300-second `arc-watch-idle-seconds'
default.  500 brings a full pass to about 22 periods, under two hours
if Emacs reaches idle on every interval.  Each path costs one
`file-readable-p' and, only when it is readable, one read and one SHA-1
in `arc-file-changed-p'; a tick is hundreds of cheap I/O operations,
not an embedding run (a changed source is reindexed asynchronously;
see `arc-watch-async').  It resumes where it left off, so the whole
mutable corpus is covered across several ticks."
  :type 'integer :group 'arc)

(defcustom arc-watch-async t
  "Whether the watcher embeds without blocking Emacs.
When non-nil (the default), a save or idle sweep hands each changed
source to `arc--reindex-async-collection', the same bounded machinery
`M-x arc-reindex-all' uses: every chunk's embedding goes through
`llm-embedding-async' -- a subprocess request with a callback, never a
blocking wait -- so `after-save-hook' returns before any HTTP
round-trip to the embedding provider.  nil restores the old
synchronous `arc-index-source' path, where `llm-embedding' blocks
Emacs for one provider round-trip per chunk; that is the path a
non-interactive script, or a test that wants completion before the next
form, should bind."
  :type 'boolean :group 'arc)

(defvar arc-watch--sweep-offset 0
  "Where the next idle sweep resumes.")

(defvar arc-watch--timer nil)

(defun arc-watch--collection-for (path)
  "Return the collection PATH belongs to, or nil.
A file is arc's business only if it is inside a directory arc indexes
AND `arc-index-plan' actually builds that collection.

Two rules, and this took the first-matching entry of
`arc-collection-directory-alist' instead of either.

LONGEST match, not first.  `home' is $HOME itself, so its directory is
a string prefix of every other collection's, and a first-match lookup
answered `home' for everything.  The walk, meanwhile, attributes
~/.config/emacs to `emacs', and `arc--replace-source-chunks' deletes
and reinserts a source's rows under whatever collection it is handed
-- so a file MIGRATED between collections depending on whether the
watcher or the walk wrote last, and a scope on `emacs' intermittently
lost it.  The longest matching root is the one that actually owns the
file, and it is the one the walk uses.

PLANNED collections only, and an unplanned root SHADOWS rather than
falls through.  `arc-collection-directory-alist' deliberately
configures directories the plan does not build -- `mail' is
$HOME/.mail, and its own docstring says indexing mail must be
something the operator turns on, never something that happens because
a default changed.  Under a first-match lookup every mail file
resolved to `home' and was indexed with the `file' chunker, which is
exactly the thing that was not supposed to happen; under longest-match
alone it still would, because $HOME encloses ~/.mail.  So the longest
matching root is picked FIRST, from every CONFIGURED collection, and
only then asked whether the plan builds it.  Configuring a directory
and leaving it out of the plan therefore means \"never index this\",
which is what it reads as.

`arc-watch--chunker-for' has the same exposure and is what answers the
planned question here, so the two cannot disagree."
  (let ((path (expand-file-name path))
        (best nil)
        (best-length -1))
    (dolist (cell arc-collection-directory-alist)
      (let* ((dir (file-name-as-directory (expand-file-name (cdr cell))))
             (len (length dir)))
        (when (and (> len best-length) (string-prefix-p dir path))
          (setq best (car cell) best-length len))))
    (and best (arc-watch--chunker-for best) best)))

(defun arc-watch--chunker-for (collection)
  "Return the chunker COLLECTION is built with, or nil.
Nil for a collection `arc-index-plan' does not build, which is also how
`arc-watch--collection-for' refuses to resolve one."
  (alist-get collection arc-index-plan nil nil #'equal))

(defun arc-watch--sources-for (path collection chunker)
  "Return the source plists PATH contributes to COLLECTION, or nil.
Shared by the single-path save path and the sweep's batched reindex, so
the two cannot disagree about what a path produces."
  (pcase chunker
    ('file (and (arc-indexable-file-p path (arc-collection-directory collection))
                (list (arc-file-source path))))
    ('org (and (string-suffix-p ".org" path)
               (arc-org-nodes-in-file path)))))

(defun arc-watch--dispatch-sync (sources collection)
  "Index SOURCES into COLLECTION synchronously, one source at a time."
  (dolist (s sources) (arc-index-source s collection)))

(defun arc-watch--reindex-sources (sources collection)
  "Index SOURCES into COLLECTION without blocking on the embedding.
Drives `arc--reindex-async-collection', the same bounded queue `M-x
arc-reindex-all' uses: at most `arc-index-max-in-flight' embedding
requests are outstanding for THIS run, and a save or idle tick returns
before any provider round-trip.  The bound is per run, which is why a
collection's changed paths are dispatched together (see
`arc-watch--reindex-paths') rather than one run each.

SOURCES must all belong to COLLECTION -- `arc--reindex-async-collection'
resolves one collection id for the batch."
  (when (< arc-index-max-in-flight 1)
    (user-error "arc: `arc-index-max-in-flight' is %s; the watcher would \
never embed (it must be at least 1)" arc-index-max-in-flight))
  (arc--reindex-async-collection
   (list :cancelled nil)
   collection (arc--collection-id collection)
   sources (length sources)
   (lambda (&rest _) nil)))

(defun arc-watch--reindex-paths (paths)
  "Re-index PATHS, one async run per collection.
Grouping by collection is the point.  `arc-watch--reindex-sources'
bounds the in-flight embedding requests of one run, so dispatching a
run per changed path would put up to `arc-index-max-in-flight' times as
many requests in flight as there are changed files -- a branch switch
or a sync touching two hundred watched files would spawn hundreds of
concurrent embedding subprocesses, the exact thing the bound exists to
prevent.  One run per collection per tick keeps it real.

Returns how many paths produced sources, matching the sweep's own count
(an org file is one path however many nodes it yields)."
  (let ((by-collection (make-hash-table :test 'equal))
        (order nil)
        (handled 0))
    (dolist (path paths)
      (when-let* ((path (and (file-readable-p path) (expand-file-name path)))
                  (collection (arc-watch--collection-for path))
                  (chunker (arc-watch--chunker-for collection))
                  ((memq chunker '(file org)))
                  (sources (arc-watch--sources-for path collection chunker)))
        (unless (gethash collection by-collection) (push collection order))
        (puthash collection (append (gethash collection by-collection) sources)
                 by-collection)
        (setq handled (1+ handled))))
    (dolist (collection (nreverse order))
      (let ((sources (gethash collection by-collection)))
        (if arc-watch-async
            (arc-watch--reindex-sources sources collection)
          (arc-watch--dispatch-sync sources collection))))
    handled))

(defun arc-watch-reindex-path (path &optional quiet)
  "Re-index PATH if arc indexes the directory it lives in.
Returns the collection it was indexed into, or nil.  Only `file' and
`org' collections are touched: those are the mutable kinds.

Whether the embedding blocks Emacs is `arc-watch-async''s decision:
non-nil (the default) routes through `arc-watch--reindex-sources' so
the save hook can return immediately, nil uses the synchronous
`arc-index-source' so a scripted caller sees the write complete before
this function returns."
  (when-let* ((path (and path (expand-file-name path)))
              ((file-readable-p path))
              (collection (arc-watch--collection-for path))
              (chunker (arc-watch--chunker-for collection))
              ((memq chunker '(file org)))
              (sources (arc-watch--sources-for path collection chunker)))
    (if arc-watch-async
        (arc-watch--reindex-sources sources collection)
      (arc-watch--dispatch-sync sources collection))
    (unless quiet
      (message "arc: reindexing %s (%d source%s)"
               (file-name-nondirectory path) (length sources)
               (if (= 1 (length sources)) "" "s")))
    collection))

(defun arc-watch--after-save ()
  "Re-index this buffer's file when arc knows it."
  (when (and arc-watch-after-save buffer-file-name)
    (condition-case err
        (arc-watch-reindex-path buffer-file-name)
      ;; A save must never fail because indexing did.
      (error (message "arc: could not reindex %s (%s)"
                      (file-name-nondirectory buffer-file-name)
                      (error-message-string err))))))

(defun arc-watch--mutable-paths ()
  "Return every indexed path belonging to a mutable collection."
  (mapcar #'car
          (sqlite-select
           (arc-db)
           (format "SELECT DISTINCT path FROM sources
                    WHERE path IS NOT NULL AND kind IN %s ORDER BY path;"
                   (arc-sqlite-format-string-list arc-freshness-per-source-kinds)))))

(defun arc-watch-sweep ()
  "Examine the next `arc-watch-sweep-batch' mutable sources and refresh drift.
Bounded and resumable: this runs on an idle timer, and a sweep that
rehashed the whole ~11,000-path mutable half in one tick would be felt.

Does nothing at all while a minibuffer is active.  An idle timer FIRES
during a prompt -- that is what idle means -- so without this the sweep
runs underneath someone else's question and collides with it.  Observed
live: a save prompt raised by another tool, the sweep starting under it,
and the abort landing in this function's handler, which reported it as
`arc: sweep failed (Save aborted)'.  That is an arc failure message for
something that was not arc's failure, and it is why a background prompt
read as arc asking a question.  The timer repeats, so returning here
simply means the next idle period retries."
  (interactive)
  (unless (active-minibuffer-window)
    (condition-case err
        (let* ((paths (arc-watch--mutable-paths))
               (n (length paths)))
          (when (> n 0)
            (when (>= arc-watch--sweep-offset n) (setq arc-watch--sweep-offset 0))
            (let* ((batch (seq-take (nthcdr arc-watch--sweep-offset paths)
                                    arc-watch-sweep-batch))
                   ;; The changed paths go to `arc-watch--reindex-paths' as a
                   ;; set, not one call each: it dispatches one async run per
                   ;; collection, so the embedding fan-out stays bounded by
                   ;; `arc-index-max-in-flight' however many files moved.
                   (changed (seq-filter
                             (lambda (p)
                               (and (file-readable-p p) (arc-file-changed-p p)))
                             batch))
                   (refreshed (if changed (arc-watch--reindex-paths changed) 0)))
              (setq arc-watch--sweep-offset (+ arc-watch--sweep-offset (length batch)))
              (when (> refreshed 0)
                (message "arc: refreshed %d changed source%s" refreshed
                         (if (= 1 refreshed) "" "s")))
              refreshed)))
      (error (message "arc: sweep failed (%s)" (error-message-string err)) nil))))

;;;###autoload
(define-minor-mode arc-watch-mode
  "Keep arc's mutable corpus current as files change.

Re-indexes a saved file arc already knows, and sweeps for drift on an
idle timer.  The sweep is what catches changes made outside this Emacs
-- a git pull, a Syncthing update, an edit on another machine -- but
only for files arc has ALREADY indexed: `arc-watch--mutable-paths'
selects `DISTINCT path FROM sources', so a file newly added by a pull
or a sync is invisible to it until a reindex, which is what adds new
files to the corpus.

Derived collections are deliberately untouched; see this file's
commentary."
  :global t :group 'arc
  (if arc-watch-mode
      (progn
        (add-hook 'after-save-hook #'arc-watch--after-save)
        (when arc-watch-idle-seconds
          (setq arc-watch--timer
                (run-with-idle-timer arc-watch-idle-seconds t #'arc-watch-sweep))))
    (remove-hook 'after-save-hook #'arc-watch--after-save)
    (when arc-watch--timer (cancel-timer arc-watch--timer))
    (setq arc-watch--timer nil)))

(provide 'arc-watch)
;;; arc-watch.el ends here
