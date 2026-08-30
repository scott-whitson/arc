;;; arc-index.el --- write chunks and embeddings -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The brief this file implements has `arc--collection-id' insert
;; `(name, enabled)'; `collections' has no `enabled' column (see
;; `arc-collections-create-table-sql' in arc-db.el -- it is `(id, name)'
;; only, and "enabled" is `arc-enabled-collections', an in-memory list,
;; not a database column).  Inserting a nonexistent column would fail
;; every call, so the insert here only ever names `name'.
;;
;; `arc-reindex-all' below is the one caller of all five producers
;; (`arc-file-sources', `arc-org-nodes', `arc-nixopt-parse-json' (twice,
;; for NixOS and Home-Manager options) and `arc-info-sources'), so this
;; file requires all of their defining libraries itself rather than
;; relying on `arc.el', which only happens to require two of them (for
;; unrelated reasons of its own) and never required `arc-source-org' or
;; `arc-source-nixopt' at all.  It does NOT require `arc-source' --
;; nothing here calls any of that file's symbols; `arc.el' requires it
;; instead, which is also where `arc-source-link'/`arc-source-label'
;; will eventually be used to render a citation.
;;
;; `arc-reindex-all' has two implementations behind one name.  Called
;; from Lisp -- as the test suite and scripted ingests do -- it runs
;; `arc--reindex-all-sync': a plain sequential walk that calls
;; `llm-embedding' (a *blocking* HTTP round-trip to Ollama) once per
;; chunk, exactly as it always has.  That is fully deterministic and
;; depends on no timer ever firing, which is what a test suite needs.
;;
;; Called interactively -- `M-x arc-reindex-all', the first command a
;; new user is likely to run -- it instead runs
;; `arc--reindex-all-async', which drives the very same producers and
;; the very same per-chunk write (`arc--write-chunk') but gets each
;; chunk's embedding via `llm-embedding-async' (a subprocess `curl'
;; call driven by `plz', with a callback -- never a blocking wait) and
;; keeps at most `arc-index-max-in-flight' requests outstanding at
;; once.  Emacs's single command loop is therefore never occupied by
;; the embedding step; between any two chunks it is exactly as free to
;; redisplay, accept a keystroke or run a timer as it would be sitting
;; idle at a prompt.  This is what actually fixes the freeze: options.json
;; alone is 24,661 NixOS options plus 5,513 Home-Manager ones, and the
;; 94 builtin Info manuals are thousands more nodes on top of that --
;; each one a blocking network call under the old synchronous path, and
;; tens of minutes of a completely unusable Emacs.
;;
;; This is deliberately NOT built on `async-start' (the `arc--async-do'
;; pattern arc.el's still-unmigrated ELISA functions use).  That would
;; fork a second Emacs process to do the writing, which raises exactly
;; the question this file's `arc--write-chunk' exists to make moot: two
;; different sqlite handles -- one per process -- writing to the same
;; file.  WAL supports one writer at a time across processes (a second
;; writer just gets SQLITE_BUSY, it does not corrupt anything), but the
;; parent process in `arc--async-do''s own pattern keeps its handle
;; open across the whole child run and only closes and reopens it in
;; the done callback -- so an interactive read in the parent (`arc-chat',
;; say) racing the child's write is a real scenario that pattern has
;; never had to prove safe, because nothing before this ever ran a
;; write that long while the parent might still be reading.  Keeping
;; everything on arc's one existing `arc-db' connection in the one
;; process sidesteps that question entirely: there is only ever one
;; writer, and it is the same handle every reader already uses.
;;; Code:

(require 'cl-lib)
(require 'llm)
(require 'arc-db)
(require 'arc-source-file)
(require 'arc-source-org)
(require 'arc-source-nixopt)
(require 'arc-source-info)

(defun arc--collection-id (name)
  "Return the id of collection NAME, creating it if needed."
  (sqlite-execute (arc-db)
                  (format "INSERT INTO collections (name) VALUES (%s)
                           ON CONFLICT (name) DO NOTHING;" (arc--sql-quote name)))
  (caar (sqlite-select (arc-db)
                       (format "SELECT id FROM collections WHERE name = %s;"
                               (arc--sql-quote name)))))

(defun arc--sanitize-text (text)
  "Return TEXT with any undecodable byte replaced by U+FFFD.
Some source content -- a copy-pasted org-roam node, a file in a
legacy encoding -- can contain a byte sequence its buffer's coding
system could not decode, surfacing internally as Emacs's `eight-bit'
raw-byte characters.  `arc--text-file-p' already keeps a wholly
binary file (an agenix `.age' secret, say) out of the `file' kind
entirely, but a node or chunk that is otherwise good text with only a
handful of bad bytes deep inside it -- as happened with a real
org-roam node pasted from elsewhere -- reaches every kind through
this one function, not just `file'.  Those raw bytes cannot be
JSON-encoded for the embeddings API and crash indexing outright, far
from whatever chunk was responsible.  Replacing them here keeps the
rest of an otherwise-good chunk searchable instead of losing it
outright, and does so audibly via `message', not silently."
  (let ((cleaned (replace-regexp-in-string "[\x3FFF80-\x3FFFFF]" "\uFFFD" text)))
    (unless (equal cleaned text)
      (message "arc: replaced undecodable byte(s) in a chunk (%d chars)" (length text)))
    cleaned))

(defun arc--write-chunk (sid cid text line-start line-end title vec)
  "Write one chunk row for source SID/collection CID plus its
`data_embeddings' and `data_fts' rows, as a single sqlite transaction.
This is the one place either indexing path (`arc-index-source', the
synchronous per-chunk loop, or `arc--reindex-async-embed-chunk', the
asynchronous one) actually writes a chunk, and it must be all-or-
nothing: `data', `data_embeddings' and `data_fts' are three separate
statements with no foreign key tying the two virtual tables back to
`data' (see `arc--delete-data-for-source'), so anything that could
stop between them -- an error, or a `quit' from `C-g' landing mid-
write during a long reindex -- used to have a real chance of leaving a
`data' row with no embedding and no FTS row: exactly the corruption
`arc-reindex-all' promises never happens.  `with-sqlite-transaction'
rolls the whole triplet back on any non-local exit, `quit' included,
so an interrupted run ends with fewer chunks, never a broken one.

This is load-bearing on the Emacs 29.2 floor specifically, not just
\"29.x\": on 29.1, `with-sqlite-transaction' always committed regardless
of how BODY exited -- the rollback-on-non-local-exit behavior this
function depends on only landed in 29.2.  On 29.1 this whole function
would silently become a no-op guard against exactly nothing."
  ;; See the docstring above: rollback-on-quit here requires Emacs
  ;; 29.2, not merely "29.x" -- 29.1's `with-sqlite-transaction' always
  ;; committed.
  (with-sqlite-transaction (arc-db)
    (sqlite-execute
     (arc-db)
     (format "INSERT INTO data (source_id, collection_id, chunk, line_start, line_end, title)
              VALUES (%d, %d, %s, %s, %s, %s);"
             sid cid (arc--sql-quote text)
             (or line-start "NULL") (or line-end "NULL") (arc--sql-quote title)))
    (let ((rowid (caar (sqlite-select (arc-db) "SELECT last_insert_rowid();"))))
      (sqlite-execute (arc-db)
                      (format "INSERT INTO data_embeddings (rowid, embedding) VALUES (%d, %s);"
                              rowid (arc-vector-to-sqlite vec)))
      (sqlite-execute (arc-db)
                      (format "INSERT INTO data_fts (rowid, data) VALUES (%d, %s);"
                              rowid (arc--sql-quote text))))))

(defun arc-index-source (source collection)
  "Index SOURCE into COLLECTION.  Return the number of chunks written.
Existing chunks for the source are deleted first, so reindexing
replaces rather than duplicates.  This is the synchronous path: each
chunk's embedding is fetched with a blocking `llm-embedding' call
before the next chunk starts.  See `arc--reindex-all-async' for the
non-blocking counterpart driven by `llm-embedding-async'."
  (let* ((cid (arc--collection-id collection))
         (sid (arc-source-upsert source))
         (chunks (plist-get source :chunks))
         (n 0))
    (arc--delete-data-for-source sid)
    (dolist (c chunks)
      (let* ((text (arc--sanitize-text (plist-get c :text)))
             (vec (llm-embedding arc-embeddings-provider text)))
        (arc--write-chunk sid cid text (plist-get c :line-start) (plist-get c :line-end)
                          (plist-get source :title) vec)
        (setq n (1+ n))))
    n))

(defun arc-index-stats ()
  "Return an alist of (KIND . CHUNK-COUNT)."
  (mapcar (lambda (row) (cons (nth 0 row) (nth 1 row)))
          (sqlite-select (arc-db)
                         "SELECT s.kind, count(d.id) FROM sources s
                          LEFT JOIN data d ON d.source_id = s.id
                          GROUP BY s.kind;")))

(defcustom arc-collection-directory-alist
  `(("dotfiles" . ,(expand-file-name "dotfiles" (getenv "HOME")))
    ("eminix"   . ,(expand-file-name "projects/eminix" (getenv "HOME")))
    ("vault"    . ,(expand-file-name "docs/org" (getenv "HOME"))))
  "Map a collection name to the directory it indexes.
Derived from $HOME -- never hardcode an absolute home path here."
  :type '(alist :key-type string :value-type directory) :group 'arc)

(defun arc-collection-directory (name)
  "Return the directory NAME indexes, or signal if it is not configured."
  (or (alist-get name arc-collection-directory-alist nil nil #'equal)
      (error "arc: no directory configured for collection %S" name)))

(defcustom arc-index-plan
  '(("dotfiles" . file) ("eminix" . file) ("vault" . org)
    ("nix options" . nixopt) ("hm options" . hmopt) ("builtin manuals" . info))
  "Collections to build and the chunker each uses."
  :type '(alist :key-type string :value-type symbol) :group 'arc)

(defcustom arc-index-nixopt-cap nil
  "Maximum number of NixOS options to index, or nil for all of them.
options.json holds 24,661 options; embedding all of them is 20-40
minutes of sustained CPU/GPU.  Set this to a small number (e.g. 300)
to prove the ingestion path end-to-end without paying that cost, and
back to nil for a real full ingest."
  :type '(choice (const nil) natnum) :group 'arc)

(defcustom arc-index-hmopt-cap nil
  "Maximum number of Home-Manager options to index, or nil for all of them.
Home-Manager's options.json is the same shape and a similar order of
magnitude as NixOS's; see `arc-index-nixopt-cap' for the same
rationale.  Set this to a small number to prove the ingestion path
end-to-end without paying the full embedding cost, and back to nil for
a real full ingest."
  :type '(choice (const nil) natnum) :group 'arc)

(defcustom arc-index-info-cap nil
  "Maximum number of Info manual nodes to index, or nil for all of them.
`arc-get-builtin-manuals' names 94 manuals; embedding every node in all
of them is, like `arc-index-nixopt-cap', 20-40 minutes of sustained
CPU/GPU for a first full index.  nil (unlimited) is the honest default
for a tool whose whole value is completeness -- set this to a small
number only to prove the ingestion path end-to-end without paying that
cost.  See `arc-index-info-priority-manuals' for which manuals a capped
run indexes first."
  :type '(choice (const nil) natnum) :group 'arc)

(defcustom arc-index-info-priority-manuals '("emacs" "elisp" "org")
  "Manual base names indexed FIRST when `arc-index-info-cap' limits how
many Info nodes get indexed.
`arc-get-builtin-manuals' returns 94 manuals in directory order, not
relevance order; a capped run that takes the first N of them in that
order is an alphabetical/directory accident, not a choice -- on this
machine it landed on \"auth\", \"autotype\" and \"bash\", leaving the
Emacs, Elisp and Org manuals -- exactly what an Emacs/Elisp/org oracle
most needs -- out of the corpus entirely.  A name here matches a
manual either literally (\"emacs\") or as `file-name-base' renders a
gzip-compressed manual (\"emacs.info\"): `arc-get-builtin-manuals'
produces one spelling or the other depending on whether this host's
Info pages are compressed, and both are checked so the priority list
does not silently miss a manual over that accident too."
  :type '(repeat string) :group 'arc)

(defcustom arc-index-max-in-flight 4
  "Maximum number of concurrent embedding requests during an
asynchronous `arc-reindex-all' run (see its ASYNC argument, and
`arc--reindex-all-async').  Ollama itself generally only executes one
request at a time against a given model, so this mostly bounds how
many `curl' subprocesses (via `plz', underneath `llm-embedding-async')
and pending callbacks can exist at once, rather than real throughput --
but it must stay a small, finite number.  Issuing all of a collection's
embedding requests as fast as `llm-embedding-async' will accept them
would spawn thousands of simultaneous subprocesses for the NixOS or
Info branches, which is its own way of making Emacs miserable to use.
Must be at least 1: 0 would never issue a request at all, wedging an
async run forever with `arc--reindex-async-active' left non-nil (see
the guard in `arc--reindex-all-async', which is what actually enforces
this -- the widget below only steers the customize UI away from 0)."
  :type '(restricted-sexp :match-alternatives ((lambda (v) (and (integerp v) (> v 0))))
                           :tag "Maximum concurrent embedding requests")
  :group 'arc)

(defcustom arc-index-progress-every 25
  "Report indexing progress every this many sources.
See `arc--index-sources-with-progress' (the synchronous path) and
`arc--reindex-async-collection' (the asynchronous one).  A real full
ingest touches tens of thousands of sources; reporting only once per
*collection*, as `arc-reindex-all' used to, means long silences that
read exactly like a hang.  This does not throttle the async path's
per-chunk progress within one large source -- see
`arc--reindex-async-collection'."
  :type 'natnum :group 'arc)

(defun arc--prioritize-manuals (manuals priority)
  "Return MANUALS reordered so entries matching PRIORITY come first, in
PRIORITY's order, followed by the rest of MANUALS in their original
order.  See `arc-index-info-priority-manuals' for what \"matches\" means."
  (let* ((match (lambda (p m) (or (equal p m) (equal (concat p ".info") m))))
         (first (delq nil (mapcar (lambda (p) (cl-find-if (lambda (m) (funcall match p m)) manuals))
                                   priority))))
    (append first (cl-remove-if (lambda (m) (member m first)) manuals))))

(defun arc--prune-collection (cid kept-ids)
  "Delete every source belonging to collection CID that is not in
KEPT-IDS, cascading its chunks, embeddings and FTS rows via
`arc-source-delete'.  Return how many sources were removed.
Upstream's directory walk deleted `data' rows for paths the current
walk no longer yielded; nothing replaced that when `sources' gained
its own identity, so anything deleted, newly gitignored, or newly
excluded from the corpus stayed citable forever.  KEPT-IDS is the set
of source ids this run's own walk of CID just touched (threaded from
`arc-source-upsert', not recomputed), so a source that moved to a
different collection in the very same `arc-reindex-all' run is not
mistaken for one that vanished."
  (let ((stale (flatten-tree
                (sqlite-select
                 (arc-db)
                 (format "SELECT DISTINCT s.id FROM sources s
                          JOIN data d ON d.source_id = s.id
                          WHERE d.collection_id = %d%s;"
                         cid
                         (if kept-ids
                             (format " AND s.id NOT IN %s" (arc-sqlite-format-int-list kept-ids))
                           ""))))))
    (dolist (sid stale) (arc-source-delete sid))
    (length stale)))

(defconst arc--reindex-skipped :arc-reindex-skipped
  "Sentinel `arc--reindex-directory-collection' (and, for the
asynchronous path, `arc--plan-cell-source-list') returns for a missing
directory, distinct from an empty list of kept ids (a directory that
exists but genuinely has nothing left in it -- which IS a reason to
prune) so callers never mistake \"this collection's directory is not
on this host\" for \"everything in it was deleted\" and prune rows
that are still perfectly good.")

(defun arc--index-sources-with-progress (name sources)
  "Upsert and index each of SOURCES into collection NAME, in order.
Return the list of source ids (for `arc--prune-collection').  Reports
progress via `message' every `arc-index-progress-every' sources (and
always for the last one) plus an upfront total, since a real full
ingest can run thousands of sources through here and, before this,
`arc-reindex-all' said nothing at all between one collection finishing
and the next -- which is most of why a real run reads as a hang."
  (let ((total (length sources)) (i 0))
    (message "arc: %s: %d source(s) to index" name total)
    (mapcar (lambda (s)
              (prog1 (arc-source-upsert s)
                (arc-index-source s name)
                (setq i (1+ i))
                (when (or (= i total) (zerop (mod i arc-index-progress-every)))
                  (message "arc: %s: %d/%d source(s) indexed" name i total))))
            sources)))

(defun arc--reindex-directory-collection (name dir producer)
  "Index every source PRODUCER (a function of one DIR argument) returns
for collection NAME under DIR, or skip with a `message' when DIR does
not exist on this host.  Return the list of source ids indexed, or
`arc--reindex-skipped'.
`arc-collection-directory-alist' can name a directory that is simply
absent here -- `eminix' on a host with no such checkout, for instance
-- and `directory-files-recursively' used to signal `file-missing' the
moment such a plan entry's turn came up, aborting every collection
still queued behind it.  A missing directory is now an ordinary,
reported skip instead -- and, importantly, not a reason to prune every
row this collection already has: the corpus here is merely unbuilt,
not emptied."
  (if (not (file-directory-p dir))
      (progn (message "arc: skipping %s, directory does not exist: %s" name dir)
             arc--reindex-skipped)
    (arc--index-sources-with-progress name (funcall producer dir))))

;;;###autoload
(defun arc-reindex-all (&optional collections async)
  "Rebuild collections in `arc-index-plan'.  Reports per-kind counts.
With COLLECTIONS (a list of collection names), only rebuilds the
`arc-index-plan' entries whose name is a member of it, leaving every
other collection's rows untouched.  With no COLLECTIONS (the default),
rebuilds every entry in the plan.

With ASYNC nil (the default when called from Lisp -- this is what the
test suite and scripted ingests rely on), the whole rebuild runs
synchronously and deterministically via `arc--reindex-all-sync':
`llm-embedding' is called and awaited once per chunk, exactly as
before.  With ASYNC non-nil, it instead runs `arc--reindex-all-async':
each chunk's embedding is fetched with `llm-embedding-async' instead,
at most `arc-index-max-in-flight' of them outstanding at a time, so
the *embedding* step -- the tens-of-minutes-long part -- never blocks
the command loop.  Gathering each collection's sources first
(`arc--plan-cell-source-list': parsing options.json, walking the Info
manuals) is still a plain, synchronous call and does briefly block
Emacs, same as any other function call -- measured around 7.44s for
`info' on the real corpus, not nothing, but not the multi-minute
freeze this exists to fix either.  Called interactively -- `M-x
arc-reindex-all' -- ASYNC is always
non-nil: unlimited caps are the default (see `arc-index-nixopt-cap'
and friends), and a real full ingest is a 20-40 minute run that must
not freeze Emacs to get.  Progress is reported via `message' either
way; see `arc-index-progress-every'."
  (interactive (list nil t))
  (if async
      (arc--reindex-all-async collections)
    (arc--reindex-all-sync collections)))

(defun arc--reindex-all-sync (&optional collections)
  "Synchronous implementation of `arc-reindex-all'.  See its docstring."
  (dolist (cell (if collections
                     (seq-filter (lambda (c) (member (car c) collections)) arc-index-plan)
                   arc-index-plan))
    (let* ((name (car cell))
           (cid (arc--collection-id name))
           (kept
            (pcase (cdr cell)
              ('file (arc--reindex-directory-collection name (arc-collection-directory name)
                                                          #'arc-file-sources))
              ('org  (arc--reindex-directory-collection name (arc-collection-directory name)
                                                          #'arc-org-nodes))
              ('nixopt
               (arc--index-sources-with-progress
                name (let ((all (arc-nixopt-parse-json (arc-nixopt-options-json-path) "nix-option")))
                       (if arc-index-nixopt-cap (take arc-index-nixopt-cap all) all))))
              ('hmopt
               (arc--index-sources-with-progress
                name (let ((all (arc-nixopt-parse-json (arc-hm-options-json-path) "hm-option")))
                       (if arc-index-hmopt-cap (take arc-index-hmopt-cap all) all))))
              ('info
               (arc--index-sources-with-progress
                name (arc-info-sources
                      (arc--prioritize-manuals (arc-get-builtin-manuals)
                                                arc-index-info-priority-manuals)
                      arc-index-info-cap))))))
      (if (eq kept arc--reindex-skipped)
          nil ; already reported by arc--reindex-directory-collection; nothing to prune
        (progn
          (message "arc: %s: %d source(s) indexed" name (length kept))
          (let ((removed (arc--prune-collection cid kept)))
            (when (> removed 0)
              (message "arc: %s: removed %d stale source(s)" name removed)))))))
  (message "arc: %S" (arc-index-stats)))


;;; Asynchronous reindex

(defvar arc--reindex-async-active nil
  "Non-nil while an asynchronous `arc-reindex-all' run is in progress.
Holds the same mutable plist (a `:cancelled' flag, so far) that
`arc--reindex-async-next-cell' and its callees thread through the
whole run as their RUN argument; `arc-reindex-cancel' mutates it in
place via `plist-put' so every pending closure -- already holding the
same list object -- sees the flag flip without any of them needing to
poll this variable.  nil whenever no async run is active, including
the entire time the synchronous path runs.

This variable and a run's RUN plist are related but not the same
thing, and can go out of sync on purpose: `arc-reindex-cancel' clears
this variable immediately (so a fresh `M-x arc-reindex-all' is never
stuck waiting on a run that will not converge), while RUN itself lives
on, still reachable from that run's own pending closures, until its
own bookkeeping in `arc--reindex-async-next-cell' decides it is truly
finished -- which is why that cleanup checks `eq' against this
variable rather than setting it to nil unconditionally.")

(defun arc--plan-cell-source-list (name kind)
  "Return the list of source plists collection NAME's KIND would index,
or `arc--reindex-skipped' when its directory is absent.  This is the
asynchronous path's counterpart to the producer calls inlined in
`arc--reindex-all-sync': it only gathers sources -- parsing JSON,
walking a directory, walking Info manuals -- none of which talks to
the embedding model, so none of it is the *tens-of-minutes-long* part
-- but it is not free either, and it stays a plain, eager, synchronous
call that briefly blocks Emacs like any other: gathering `info''s
sources alone (walking 94 builtin manuals) measured around 7.44s on
the real corpus.  `arc--reindex-async-collection' is what then drives
the actual slow part, the per-chunk embedding step, without blocking,
one bounded batch at a time."
  (pcase kind
    ('file (let ((dir (arc-collection-directory name)))
             (if (not (file-directory-p dir))
                 (progn (message "arc: skipping %s, directory does not exist: %s" name dir)
                        arc--reindex-skipped)
               (arc-file-sources dir))))
    ('org (let ((dir (arc-collection-directory name)))
            (if (not (file-directory-p dir))
                (progn (message "arc: skipping %s, directory does not exist: %s" name dir)
                       arc--reindex-skipped)
              (arc-org-nodes dir))))
    ('nixopt (let ((all (arc-nixopt-parse-json (arc-nixopt-options-json-path) "nix-option")))
               (if arc-index-nixopt-cap (take arc-index-nixopt-cap all) all)))
    ('hmopt (let ((all (arc-nixopt-parse-json (arc-hm-options-json-path) "hm-option")))
              (if arc-index-hmopt-cap (take arc-index-hmopt-cap all) all)))
    ('info (arc-info-sources (arc--prioritize-manuals (arc-get-builtin-manuals)
                                                       arc-index-info-priority-manuals)
                              arc-index-info-cap))))

(defun arc--reindex-async-embed-chunk (chunk cid sid title settle)
  "Embed one CHUNK of source SID/collection CID via `llm-embedding-async'
and write it with `arc--write-chunk' when the vector arrives.  Calls
SETTLE with `ok' or `failed' exactly once, no matter what happens --
a successful write, an embedding error, or a *write* error (an sqlite
failure, any signal from `arc--write-chunk') -- via `unwind-protect',
so `arc--reindex-async-collection' can never lose track of an
in-flight slot: without this, an error inside the success callback
(the write happened before the call to SETTLE) skipped SETTLE
entirely, leaking that slot forever and eventually wedging the whole
run at less than `arc-index-max-in-flight' below its bound with
nothing left to fill it -- reproduced live: 3 induced write failures
stalled a 20-chunk run at 9, un-cancellable, since `in-flight' never
reached 0 either.  A failed embedding or a failed write is reported via
`message' and simply skipped rather than aborting the run -- one bad
chunk (an Ollama hiccup, a transient sqlite error) should not cost the
rest of the corpus -- but SETTLE's status lets
`arc--reindex-async-collection' count failures instead of only ever
seeing a clean multiple-of-nothing."
  (let ((text (arc--sanitize-text (plist-get chunk :text))))
    (llm-embedding-async
     arc-embeddings-provider text
     (lambda (vec)
       (let ((wrote nil))
         (unwind-protect
             (condition-case err
                 (progn
                   (arc--write-chunk sid cid text (plist-get chunk :line-start)
                                      (plist-get chunk :line-end) title vec)
                   (setq wrote t))
               (error (message "arc: writing a chunk of source %d failed: %s"
                                sid (error-message-string err))))
           (funcall settle (if wrote 'ok 'failed)))))
     (lambda (_type msg)
       (message "arc: embedding failed for a chunk of source %d: %s" sid msg)
       (funcall settle 'failed)))))

(defun arc--reindex-async-collection (run name cid sources total on-collection-done)
  "Index SOURCES (all of collection NAME/CID's sources for this run)
asynchronously, keeping at most `arc-index-max-in-flight' embedding
requests in flight *across* sources, not just within one.  Most of
arc's largest collections -- NixOS/HM options, Info manual nodes --
are exactly one chunk per source, so a window bounded per-source alone
would never let more than one request run at a time for precisely the
collections this exists to speed up: `arc-index-max-in-flight' sources
are advanced into concurrently instead, each contributing its chunks
to one shared queue.

A source is upserted -- and its stale chunks deleted via
`arc--delete-data-for-source' -- lazily, the moment it is first
advanced into, never upfront for the whole collection: a source this
run never reaches because RUN was cancelled first is therefore left
exactly as it was, not wiped and left with nothing.  A source that
*was* advanced into but then hit a chunk failure (see
`arc--reindex-async-embed-chunk') is a different, narrower problem
this does NOT fix: `arc--delete-data-for-source' already ran for it,
so it is left with only whichever of its chunks embedded successfully
-- possibly none -- rather than its old content.  That asymmetry with
the synchronous path (which signals and aborts the whole run instead
of skipping) is deliberate, but it must not also be silent: FAILED-
CHUNKS and FAILED-SOURCES below exist so ON-COLLECTION-DONE's caller
can say so loudly instead of it being one `message' buried among
hundreds of progress lines.

Calls ON-COLLECTION-DONE with (KEPT FAILED-CHUNKS FAILED-SOURCE-COUNT)
-- KEPT the list of source ids started, in starting order, FAILED-
CHUNKS the total number of chunks that never got a successful write,
FAILED-SOURCE-COUNT how many distinct sources had at least one -- once
every started source's every chunk has settled and either every
source in SOURCES has been started, or RUN was cancelled.  Called
exactly once: `finished' guards not just entry but the completion
branch itself, because a `settle' that fires synchronously (a stub, a
cache, any future local embedder that does not genuinely defer) would
otherwise re-enter `pump' before the outer call has unwound, and an
unguarded completion check at the end of that outer call would fire
ON-COLLECTION-DONE a second time against an already-mutated KEPT."
  (let ((remaining sources)
        (queue nil) ; list of (sid . chunk), oldest first
        (queue-tail nil)
        (remaining-in-source (make-hash-table :test 'eql))
        (source-title (make-hash-table :test 'eql))
        (kept nil)
        (sources-done 0)
        (failed-chunks 0)
        (failed-sources (make-hash-table :test 'eql))
        (in-flight 0)
        (finished nil))
    (cl-labels
        ((enqueue (sid chunks)
           (dolist (c chunks)
             (let ((cell (list (cons sid c))))
               (if queue-tail (setcdr queue-tail cell) (setq queue cell))
               (setq queue-tail cell))))
         (source-settled (sid)
           (cl-incf sources-done)
           (when (or (= sources-done total) (zerop (mod sources-done arc-index-progress-every)))
             (message "arc: %s: %d/%d source(s) indexed" name sources-done total))
           (remhash sid remaining-in-source)
           (remhash sid source-title))
         (chunk-settled (sid status)
           (cl-decf in-flight)
           (when (eq status 'failed)
             (cl-incf failed-chunks)
             (puthash sid t failed-sources))
           (let ((left (1- (gethash sid remaining-in-source 1))))
             (if (<= left 0) (source-settled sid) (puthash sid left remaining-in-source)))
           (pump))
         (start-next-source ()
           (let* ((source (car remaining))
                  (sid (arc-source-upsert source))
                  (chunks (plist-get source :chunks)))
             (setq remaining (cdr remaining))
             (arc--delete-data-for-source sid)
             (push sid kept)
             (if (null chunks)
                 (source-settled sid) ; a chunk-less source has nothing to wait on
               (puthash sid (plist-get source :title) source-title)
               (puthash sid (length chunks) remaining-in-source)
               (enqueue sid chunks))))
         (pump ()
           (unless finished
             (while (and (not (plist-get run :cancelled))
                         (< in-flight arc-index-max-in-flight)
                         (or queue remaining))
               (if queue
                   (let ((task (pop queue)))
                     (unless queue (setq queue-tail nil))
                     (cl-incf in-flight)
                     (arc--reindex-async-embed-chunk
                      (cdr task) cid (car task) (gethash (car task) source-title)
                      (let ((sid (car task))) (lambda (status) (chunk-settled sid status)))))
                 (start-next-source)))
             ;; `(not finished)' here, not just on entry: a `settle' that
             ;; fires synchronously re-enters `pump' from inside the
             ;; `while' loop above, and that reentrant call can itself
             ;; reach and pass this same check first.  Without repeating
             ;; the guard here, this (the outer, now-stale) call would
             ;; fire ON-COLLECTION-DONE a second time once it unwinds --
             ;; reproduced live: a synchronously-settling stub called
             ;; this branch 7 times for one 8-source collection.
             (when (and (not finished) (zerop in-flight)
                        (or (plist-get run :cancelled) (and (null queue) (null remaining))))
               (setq finished t)
               ;; `reverse', not the destructive `nreverse': KEPT must
               ;; not be mutated in place in case this branch is ever
               ;; reached more than once despite the guard above (belt
               ;; and suspenders -- `nreverse' on an already-reversed
               ;; list is exactly the kind of corruption that turned
               ;; the reentrancy bug above into an 8-source index
               ;; mangled down to 1).
               (funcall on-collection-done (reverse kept) failed-chunks
                        (hash-table-count failed-sources))))))
      (pump))))

(defun arc--reindex-async-next-cell (run cells)
  "Process CELLS (remaining `arc-index-plan' entries), one collection at
a time, then finish RUN.  See `arc--reindex-all-async'."
  (if (or (plist-get run :cancelled) (null cells))
      (progn
        (when (plist-get run :cancelled)
          (message "arc: reindex cancelled"))
        ;; Only clear this RUN's own claim on the variable: `eq', not a
        ;; blind (setq ... nil).  `arc-reindex-cancel' already cleared
        ;; `arc--reindex-async-active' itself as an escape hatch the
        ;; moment it was called (see its own commentary) so a new run
        ;; can start immediately even if this one is somehow still
        ;; unwinding its last in-flight requests; if that already
        ;; happened, a second run may be active in this variable by the
        ;; time this stale RUN finally gets here; blindly nil-ing it out
        ;; would clobber that unrelated, still-running run's flag.
        (when (eq arc--reindex-async-active run)
          (setq arc--reindex-async-active nil))
        (message "arc: %S" (arc-index-stats)))
    (let* ((cell (car cells))
           (name (car cell))
           (cid (arc--collection-id name))
           (sources (arc--plan-cell-source-list name (cdr cell))))
      (if (eq sources arc--reindex-skipped)
          (arc--reindex-async-next-cell run (cdr cells))
        (progn
          (message "arc: %s: %d source(s) to index" name (length sources))
          (arc--reindex-async-collection
           run name cid sources (length sources)
           (lambda (kept failed-chunks failed-sources)
             (message "arc: %s: %d source(s) indexed%s" name (length kept)
                      (if (> failed-chunks 0)
                          (format " -- %d chunk failure(s) across %d source(s), see messages above"
                                  failed-chunks failed-sources)
                        ""))
             (if (plist-get run :cancelled)
                 ;; C1: a cancelled run must NOT prune.  KEPT here is only
                 ;; the sources THIS run happened to start before it was
                 ;; told to stop -- every other source this collection
                 ;; already had, reached or not, is simply absent from it,
                 ;; and pruning against an incomplete KEPT would delete
                 ;; every one of them.  Reproduced live: 10 good sources
                 ;; indexed, cancel after 5, unconditional prune deleted
                 ;; the other 5 -- on the real corpus (`info' alone is
                 ;; 7,748 sources) that is thousands of fine rows gone
                 ;; for cancelling two minutes into a long run.
                 (message "arc: %s: reindex cancelled; leaving existing rows untouched (no prune)"
                          name)
               (let ((removed (arc--prune-collection cid kept)))
                 (when (> removed 0)
                   (message "arc: %s: removed %d stale source(s)" name removed))))
             (arc--reindex-async-next-cell run (cdr cells)))))))))

(defun arc--reindex-all-async (&optional collections)
  "Asynchronous implementation of `arc-reindex-all'.  See its docstring.
Signals a `user-error' if an asynchronous reindex is already running --
`arc-index-source''s per-chunk transaction makes a single writer safe
against `C-g', not against a second whole run's sources and prune
racing the first's.  Also signals if `arc-index-max-in-flight' is not
a positive integer: 0 (its `:type' widget alone does not actually
forbid this -- see its docstring) would issue no requests at all and
leave `arc--reindex-async-active' set with nothing ever going to clear
it, wedging every later `M-x arc-reindex-all' for the rest of the
session."
  (when arc--reindex-async-active
    (user-error "arc: an asynchronous reindex is already running (M-x arc-reindex-cancel to stop it)"))
  (unless (and (integerp arc-index-max-in-flight) (> arc-index-max-in-flight 0))
    (user-error "arc: `arc-index-max-in-flight' must be a positive integer, got %S"
                arc-index-max-in-flight))
  (let ((run (list :cancelled nil))
        (cells (if collections
                   (seq-filter (lambda (c) (member (car c) collections)) arc-index-plan)
                 arc-index-plan)))
    (setq arc--reindex-async-active run)
    (message "arc: starting asynchronous reindex of %d collection(s)" (length cells))
    (arc--reindex-async-next-cell run cells)
    nil))

;;;###autoload
(defun arc-reindex-cancel ()
  "Stop an in-progress asynchronous `arc-reindex-all' run as soon as
possible.  Any embedding request already in flight is still written
when its response arrives -- it was already paid for, and writing a
complete chunk is never the corruption this is guarding against -- but
no *new* request is issued after this is called, and no further
collection is started.  When the collection in progress is cancelled
partway, it is NOT pruned -- only a run that reaches the end of a
collection on its own prunes it; see `arc--reindex-async-next-cell'.
Sources not yet reached are simply left unindexed until the next run.

Also clears `arc--reindex-async-active' immediately, as an escape
hatch: ordinarily the run itself clears it once every in-flight
request has actually settled (see `arc--reindex-async-next-cell'), but
if something upstream of that ever leaks a slot the way the bug fixed
in `arc--reindex-async-embed-chunk' did -- `in-flight' never reaching
0, nothing left to converge on -- cancelling could never recover the
session; a stuck run's now-orphaned callbacks, if any ever do still
arrive, still see `:cancelled' on their own RUN object (unaffected by
this) and still stop issuing new work, they just no longer hold the
one flag a fresh `M-x arc-reindex-all' checks.

Does nothing (beyond a `message') if no asynchronous reindex is
active."
  (interactive)
  (if arc--reindex-async-active
      (let ((run arc--reindex-async-active))
        (plist-put run :cancelled t)
        (setq arc--reindex-async-active nil)
        (message "arc: cancelling reindex; any request already in flight will still be written"))
    (message "arc: no asynchronous reindex is running")))

(provide 'arc-index)
;;; arc-index.el ends here
