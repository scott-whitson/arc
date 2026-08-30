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
;; `arc--reindex-all-async', which drives the very same producers but
;; gets each chunk's embedding via `llm-embedding-async' (a subprocess
;; `curl' call driven by `plz', with a callback -- never a blocking
;; wait) and keeps at most `arc-index-max-in-flight' requests
;; outstanding at once, spanning several sources concurrently.  Emacs's
;; single command loop is therefore never occupied by the embedding
;; step; between any two chunks it is exactly as free to redisplay,
;; accept a keystroke or run a timer as it would be sitting idle at a
;; prompt.  This is what actually fixes the freeze: options.json alone
;; is 24,661 NixOS options plus 5,513 Home-Manager ones, and the 94
;; builtin Info manuals are thousands more nodes on top of that -- each
;; one a blocking network call under the old synchronous path, and
;; tens of minutes of a completely unusable Emacs.
;;
;; Both paths replace a source atomically, via `arc--replace-source-
;; chunks': every one of a source's chunks is embedded first -- one at
;; a time for the synchronous path, several at once (bounded) for the
;; asynchronous one -- and only once all of them are in hand does
;; `arc--replace-source-chunks' upsert the source, delete its old
;; content and insert every new chunk, all as a single transaction.  A
;; source neither path finishes reaching -- a `C-g' for the synchronous
;; one, a cancelled run or an embedding failure for the asynchronous
;; one -- therefore keeps its old content exactly as it was.  Earlier
;; versions of both paths deleted a source's old chunks eagerly, the
;; moment they started on it, and both ways of doing that were
;; reproduced live losing real content: the asynchronous path,
;; cancelled two minutes into a run over a large multi-chunk source
;; (477 chunks), kept only whatever had settled by then (6, from 477);
;; the synchronous path, interrupted with `C-g' mid-source, lost 7 of
;; 10 chunks the same way.
;;
;; The asynchronous path also does not prune: see `arc-reindex-all''s
;; docstring and `arc--reindex-async-next-cell'.
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

(defun arc--insert-chunk-row (sid cid text line-start line-end title vec)
  "Insert one chunk row for source SID/collection CID plus its
`data_embeddings' and `data_fts' rows.  Does NOT wrap this in a
transaction of its own: `arc--replace-source-chunks' is the only
caller, and wraps its own whole run of these -- a source's upsert, the
delete of its old content, and every one of these inserts -- in one
shared transaction, since none of that may be partial."
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
                            rowid (arc--sql-quote text)))))

(defun arc--replace-source-chunks (source cid chunks)
  "Upsert SOURCE into collection CID and atomically replace every
`data'/`data_embeddings'/`data_fts' row belonging to it with CHUNKS --
a list of \(TEXT LINE-START LINE-END VEC\), one already-embedded
replacement chunk each -- as a single sqlite transaction spanning the
upsert, the delete of SOURCE's old content, and every new insert
together.  Return the source id, or nil without touching the database
at all when CHUNKS is empty -- see below.

This is the one place either indexing path (the synchronous
`arc-index-source', or the asynchronous `arc--reindex-async-
collection') actually writes a source, and it is what makes a whole
source's reindex atomic, not merely chunk-by-chunk: both callers embed
every one of a source's chunks first and call this only once all of
them are in hand, never before, so nothing about SOURCE is created,
deleted or rewritten until its full replacement content already is.
An interruption partway through embedding a source's chunks -- a
`C-g' for the synchronous path, a cancelled run or an embedding
failure for the asynchronous one -- therefore never reaches this
function for that source at all: its old content survives completely
intact, not cut down to whatever had settled before the interruption,
which is what an eagerly-deleting version of both paths used to do --
reproduced live, a 477-chunk source cancelled after only 2 of its
chunks had settled was left with 6 (asynchronous), and `C-g' mid-source
lost 7 of a 10-chunk source's chunks the same way (synchronous).

Upserting here too, not before, also means a `sources' row is never
created without the `data' rows that go with it -- the \"phantom
source\" a version of this that upserted eagerly used to allow: a row
`arc--prune-collection', joining through `data', can never see and so
can never remove.  CHUNKS being empty (a producer -- `arc-file-sources'
for an empty or whitespace-only file, say -- can legitimately yield
zero of them for an otherwise-valid source) is handled the same way,
for the same reason: a source with no content gets no row and no
transaction at all here, rather than an upsert immediately followed by
zero inserts, which is exactly how a phantom row -- one `sources' row
with nothing in `data' for it to join through -- used to get created
even after the fix above.  A source that already had real content and
is reindexed down to zero chunks keeps its old row and old chunks
here (nothing here decides whether that is now stale); ordinarily the
synchronous path's `arc--prune-collection' pass, run once per whole
collection with a complete kept-ids list, is what resolves that -- this
source simply will not be in it.  That does not cover every case,
though: if the emptied source was the collection's *only* source,
KEPT-IDS comes back empty and `arc--prune-collection' refuses to prune
an empty KEPT-IDS at all (by design -- see its docstring), so the
emptied source's old content stays indexed and citable indefinitely.
See the README's Known Limitations for this."
  (if (null chunks)
      nil
    (with-sqlite-transaction (arc-db)
      (let ((sid (arc-source-upsert source)))
        (arc--delete-data-for-source sid)
        (dolist (c chunks)
          (arc--insert-chunk-row sid cid (nth 0 c) (nth 1 c) (nth 2 c) (plist-get source :title) (nth 3 c)))
        sid))))

(defun arc--index-source-1 (source collection)
  "Like `arc-index-source' but return (SID . CHUNK-COUNT) instead of
just CHUNK-COUNT, SID being whatever `arc--replace-source-chunks'
returned (nil for a zero-chunk SOURCE).  `arc-index-source' is the
public, documented entry point and keeps its existing chunk-count
contract; this is the one other caller, `arc--index-sources-with-
progress', actually needs -- it has to build a trustworthy KEPT-IDS
list for `arc--prune-collection' out of the source ids indexing
*actually wrote*, not out of a separate, eager upsert of its own (see
`arc--index-sources-with-progress')."
  (let* ((cid (arc--collection-id collection))
         (embedded (mapcar (lambda (c)
                              (let ((text (arc--sanitize-text (plist-get c :text))))
                                (list text (plist-get c :line-start) (plist-get c :line-end)
                                      (llm-embedding arc-embeddings-provider text))))
                            (plist-get source :chunks))))
    (cons (arc--replace-source-chunks source cid embedded) (length embedded))))

(defun arc-index-source (source collection)
  "Index SOURCE into COLLECTION.  Return the number of chunks written.
Every chunk is embedded first; SOURCE's upsert, the deletion of its
old content and every new chunk's insert then happen together as one
transaction via `arc--replace-source-chunks', so a `C-g' partway
through embedding leaves SOURCE's old content completely intact rather
than cut down to whatever had already been embedded.  This is the
synchronous path: each chunk's embedding is fetched with a blocking
`llm-embedding' call before the next chunk starts.  See
`arc--reindex-all-async' for the non-blocking counterpart driven by
`llm-embedding-async'."
  (cdr (arc--index-source-1 source collection)))

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
`arc-source-delete'.  Return how many sources were removed, or 0
without touching the database at all when KEPT-IDS is empty -- see
below.
Upstream's directory walk deleted `data' rows for paths the current
walk no longer yielded; nothing replaced that when `sources' gained
its own identity, so anything deleted, newly gitignored, or newly
excluded from the corpus stayed citable forever.  KEPT-IDS is the set
of source ids this run's own walk of CID just touched (threaded from
`arc-source-upsert', not recomputed), so a source that moved to a
different collection in the very same `arc-reindex-all' run is not
mistaken for one that vanished.

Only `arc--reindex-all-sync' calls this.  The asynchronous path does
not prune at all: it enumerates its sources up front but writes them
one at a time over what can be a very long run, so a KEPT-IDS built as
it goes is never trustworthy until every source has actually been
replaced -- a cancel, a producer error partway through the plan, or
even just an unusually persistent per-source failure each turned an
incomplete KEPT-IDS into a real, reproduced way to delete sources the
run had simply not gotten to yet, not sources that had left the corpus.
`arc-reindex-all''s synchronous path, by contrast, builds its KEPT-IDS
by walking the *entire* source list before writing anything and lets
any producer error propagate out and abort the whole run rather than
silently truncate KEPT-IDS, so its list is complete by construction --
see `arc-reindex-all''s docstring.

KEPT-IDS empty is refused outright rather than treated as \"nothing to
keep, so delete everything this collection has\": a walk that
genuinely found zero sources is indistinguishable, from here, from one
whose directory was simply not ready yet -- unmounted, a sync tool
mid-catch-up, a transient listing error a producer swallowed instead
of signalling -- and the two cases call for opposite actions.  Since
`arc--prune-collection' cannot tell them apart and deleting a whole
collection is never the right answer to that ambiguity, an empty
KEPT-IDS prunes nothing at all, every time, on purpose; reproduced
live, this is exactly what turned an org-roam directory Syncthing
simply had not finished syncing yet into 428 deleted sources on one
`(arc-reindex-all)' run."
  (if (null kept-ids)
      0
    (let ((stale (flatten-tree
                  (sqlite-select
                   (arc-db)
                   (format "SELECT DISTINCT s.id FROM sources s
                            JOIN data d ON d.source_id = s.id
                            WHERE d.collection_id = %d AND s.id NOT IN %s;"
                           cid
                           (arc-sqlite-format-int-list kept-ids))))))
      (dolist (sid stale) (arc-source-delete sid))
      (length stale))))

(defconst arc--reindex-skipped :arc-reindex-skipped
  "Sentinel `arc--reindex-directory-collection' (and, for the
asynchronous path, `arc--plan-cell-source-list') returns for a missing
directory, distinct from an empty list of kept ids, so callers never
mistake \"this collection's directory is not on this host\" for
\"everything in it was deleted\" and prune rows that are still
perfectly good.  Note that an empty list of kept ids is not itself
treated as a reason to prune either -- see `arc--prune-collection' --
this sentinel exists to keep a third, still different case (no
directory at all) from being folded into that same empty-list value
and skipping the \"directory does not exist\" `message' that reports
it.")

(defun arc--index-sources-with-progress (name sources)
  "Index each of SOURCES into collection NAME, in order.
Return the list of source ids actually written (for
`arc--prune-collection'), omitting any SOURCES entry that came back
with no chunks to write -- `arc--replace-source-chunks' gives such a
source no row at all, so there is no id to include, and it must not be
treated as \"kept\" (see `arc--replace-source-chunks').  Reports
progress via `message' every `arc-index-progress-every' sources (and
always for the last one) plus an upfront total, since a real full
ingest can run thousands of sources through here and, before this,
`arc-reindex-all' said nothing at all between one collection finishing
and the next -- which is most of why a real run reads as a hang.

Each source's id comes from `arc--index-source-1', i.e. from whatever
`arc--replace-source-chunks' actually wrote, not from a separate
eager `arc-source-upsert' call made before indexing -- an earlier
version of this function upserted first and indexed second, which left
two proven holes: a run interrupted between the two steps left a
`sources' row with no chunks behind it, and the eagerly-written row
already carried the *new* content's hash before any of that content
had actually been written, so `arc-file-changed-p' read the file as
unchanged and it never got re-indexed at all."
  (let ((total (length sources)) (i 0))
    (message "arc: %s: %d source(s) to index" name total)
    (delq nil
          (mapcar (lambda (s)
                    (prog1 (car (arc--index-source-1 s name))
                      (setq i (1+ i))
                      (when (or (= i total) (zerop (mod i arc-index-progress-every)))
                        (message "arc: %s: %d/%d source(s) indexed" name i total))))
                  sources))))

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
way; see `arc-index-progress-every'.

KNOWN LIMITATION: the asynchronous path never prunes.  A source that
has genuinely left the corpus (deleted, gitignored, excluded) keeps
whatever it was last indexed as and stays citable until a *synchronous*
reindex of that collection runs and prunes it -- `(arc-reindex-all
COLLECTIONS)' or `(arc-reindex-all)' with no ASYNC argument, exactly
how the test suite and any scripted ingest already call it.  This is
not an oversight: see `arc--prune-collection''s docstring for why a
long-running asynchronous walk cannot build a trustworthy kept-list to
prune against."
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
      (cond
       ((eq kept arc--reindex-skipped) nil) ; already reported; nothing to prune
       ((null kept)
        (message "arc: %s: 0 source(s) found; not pruning (see `arc--prune-collection')" name))
       (t
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

(defun arc--reindex-async-embed-chunk (chunk settle)
  "Embed one CHUNK via `llm-embedding-async'.  Calls SETTLE with `ok'
and the resulting (TEXT LINE-START LINE-END VEC) on success, or
`failed' and nil on any failure -- an embedding error, or any signal
escaping the setup here.  Guaranteed to call SETTLE exactly once no
matter what: a local one-shot guard makes every call after the first a
no-op, which is what actually matters here, more than where a second
call could come from -- a provider that (incorrectly) invokes both of
its own callbacks, or this function's own `condition-case' catching an
error that reached it from *inside* a synchronous callback's own
downstream processing after that processing had already settled once.
Without this, a second `settle' call for an already-settled chunk reads
default/absent bookkeeping in `arc--reindex-async-collection' as \"zero
chunks remain\", re-triggering that source's replacement with whatever
scraps are left in an accumulator the first call already cleared --
reachable with no stub at all needed beyond the deterministic one this
file's own test suite already uses to avoid real timers."
  (let ((settled nil))
    (cl-flet ((settle-once (status data)
                (unless settled (setq settled t) (funcall settle status data))))
      (condition-case err
          (let ((text (arc--sanitize-text (plist-get chunk :text))))
            (llm-embedding-async
             arc-embeddings-provider text
             (lambda (vec)
               (settle-once 'ok (list text (plist-get chunk :line-start)
                                       (plist-get chunk :line-end) vec)))
             (lambda (_type msg)
               (message "arc: embedding failed for a chunk: %s" msg)
               (settle-once 'failed nil))))
        (error
         (message "arc: could not start embedding a chunk: %s" (error-message-string err))
         (settle-once 'failed nil))))))

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

Every chunk of a source is embedded and accumulated (in SOURCE-CHUNKS,
keyed by the source's own plist -- there is no source id at all until
a source is actually replaced) before anything is written; once all of
a source's chunks have settled, `source-settled' hands the whole batch
to `arc--replace-source-chunks', which upserts the source and replaces
its content as a single transaction.  A source RUN never finishes
reaching -- cancelled, or one of its own chunks failed to embed -- is
therefore simply never passed to `arc--replace-source-chunks' at all,
and keeps whatever it already had, exactly as it was.

This does NOT prune: see `arc-reindex-all' and `arc--prune-collection's
docstrings for why -- a long-running asynchronous walk never has a
trustworthy \"every source this collection actually has\" list to prune
against, only a \"what this run has reached so far\" one, and three
separate ways of trying to use the latter for the former each turned
into a real, reproduced way to delete sources this run had simply not
gotten to yet.  Only `arc--reindex-all-sync' prunes.

Calls ON-COLLECTION-DONE with (SOURCES-REPLACED NOT-REPLACED-COUNT) --
SOURCES-REPLACED how many sources were actually, successfully replaced
(not merely attempted: reporting otherwise once said \"2 source(s)
indexed\" after a cancel that had replaced only 1), NOT-REPLACED-COUNT
how many had at least one chunk fail to embed, or failed at the
replace itself -- once every source either has been fully replaced,
given up on, or RUN was cancelled, and either every source in SOURCES
has been started, or RUN was cancelled.  Called exactly once: `finished'
guards not just entry but the completion branch itself, because a
`settle' that fires synchronously (a stub, a cache, any future local
embedder that does not genuinely defer) would otherwise re-enter `pump'
before the outer call has unwound, and an unguarded completion check at
the end of that outer call would fire ON-COLLECTION-DONE a second time."
  (let ((remaining sources)
        (queue nil) ; list of (source . chunk), oldest first
        (queue-tail nil)
        (remaining-in-source (make-hash-table :test 'eq))
        (source-chunks (make-hash-table :test 'eq)) ; source -> accumulated (TEXT LS LE VEC) list
        (not-replaced (make-hash-table :test 'eq)) ; source -> t, not (yet) replaced
        (sources-done 0)
        (sources-replaced 0)
        (in-flight 0)
        (finished nil))
    (cl-labels
        ((enqueue (source chunks)
           (dolist (c chunks)
             (let ((cell (list (cons source c))))
               (if queue-tail (setcdr queue-tail cell) (setq queue cell))
               (setq queue-tail cell))))
         (source-settled (source)
           (cl-incf sources-done)
           (if (gethash source not-replaced)
               (message "arc: %s: a source was not replaced -- a chunk failed to embed; its old content is untouched"
                        name)
             (condition-case err
                 (progn
                   ;; a zero-chunk source (e.g. a now-empty file) makes
                   ;; `arc--replace-source-chunks' write nothing and
                   ;; return nil -- that is not a replacement, so it
                   ;; must not count as one (see ON-COLLECTION-DONE above)
                   (when (arc--replace-source-chunks source cid (nreverse (gethash source source-chunks)))
                     (cl-incf sources-replaced)))
               ((error quit)
                (puthash source t not-replaced)
                (message "arc: %s: replacing a source's chunks failed: %s"
                         name (error-message-string err)))))
           (when (or (= sources-done total) (zerop (mod sources-done arc-index-progress-every)))
             (message "arc: %s: %d/%d source(s) processed" name sources-done total))
           (remhash source remaining-in-source)
           (remhash source source-chunks))
         (chunk-settled (source status data)
           (cl-decf in-flight)
           (if (eq status 'failed)
               (puthash source t not-replaced)
             (puthash source (cons data (gethash source source-chunks)) source-chunks))
           (let ((left (1- (gethash source remaining-in-source 1))))
             (if (<= left 0) (source-settled source) (puthash source left remaining-in-source)))
           (pump))
         (start-next-source ()
           (let* ((source (car remaining))
                  (chunks (plist-get source :chunks)))
             (setq remaining (cdr remaining))
             (if (null chunks)
                 ;; a chunk-less source has nothing to wait on; its
                 ;; (empty) replacement happens right away.
                 (source-settled source)
               (puthash source (length chunks) remaining-in-source)
               (enqueue source chunks))))
         (pump ()
           (unless finished
             (while (and (not (plist-get run :cancelled))
                         (< in-flight arc-index-max-in-flight)
                         (or queue remaining))
               (if queue
                   (let ((task (pop queue)))
                     (unless queue (setq queue-tail nil))
                     (cl-incf in-flight)
                     (let ((source (car task)))
                       (arc--reindex-async-embed-chunk
                        (cdr task) (lambda (status data) (chunk-settled source status data)))))
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
               (funcall on-collection-done sources-replaced (hash-table-count not-replaced))))))
      (pump))))

(defun arc--reindex-async-next-cell (run cells)
  "Process CELLS (remaining `arc-index-plan' entries), one collection at
a time, then finish RUN.  See `arc--reindex-all-async'.

Wrapped in `condition-case': `arc--collection-id' and
`arc--plan-cell-source-list' (gathering the next cell's sources -- for
`nixopt'/`hmopt', reading and parsing options.json) run right here, and
for every cell after the first, this runs from inside a previous
chunk's embedding callback -- reachable with no stub at all, since
`arc-nixopt-options-json-path' returns nil when `nix build' fails and
`arc-nixopt-parse-json' then calls `(insert-file-contents nil)'.  Left
unprotected, that signal used to be swallowed by the `plz' sentinel
that was calling this indirectly, silently stopping the whole run
mid-plan with `arc--reindex-async-active' left set.  Pruning is gone
from this path entirely now, so a failure here can no longer destroy
anything -- but it must still not be silent, and it does not try to
skip the bad cell and continue with the rest of the plan: a producer
that fails once for a cell is likely to fail again, and guessing
otherwise is exactly the kind of recovery logic this does not attempt."
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
    (condition-case err
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
               (lambda (sources-replaced not-replaced-count)
                 (message "arc: %s: %d source(s) replaced%s%s" name sources-replaced
                          (if (plist-get run :cancelled) " (cancelled)" "")
                          (if (> not-replaced-count 0)
                              (format " -- %d source(s) not replaced (a chunk failed to embed, or the replace itself failed), old content kept, see messages above"
                                      not-replaced-count)
                            ""))
                 (arc--reindex-async-next-cell run (cdr cells)))))))
      (error
       (message "arc: reindexing %s failed and the async run has stopped: %s"
                (if cells (car (car cells)) "a collection") (error-message-string err))
       (when (eq arc--reindex-async-active run)
         (setq arc--reindex-async-active nil))))))

(defun arc--reindex-all-async (&optional collections)
  "Asynchronous implementation of `arc-reindex-all'.  See its docstring.
Signals a `user-error' if an asynchronous reindex is already running --
`arc--replace-source-chunks''s per-source transaction makes a single
writer safe against `C-g', not against two whole runs' sources racing
each other.  Also signals if `arc-index-max-in-flight' is not a
positive integer: 0 (its `:type' widget alone does not actually forbid
this -- see its docstring) would issue no requests at all and leave
`arc--reindex-async-active' set with nothing ever going to clear it,
wedging every later `M-x arc-reindex-all' for the rest of the session."
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
possible: no *new* embedding request is issued after this is called,
and no further collection is started.

A source whose every chunk had already settled by the time this is
called was already fully, atomically replaced (see
`arc--replace-source-chunks') and stays that way.  A source caught
mid-embedding is a different story: any of its requests already in
flight are allowed to finish, but their results are simply discarded,
not written -- a source is replaced all-or-nothing, and since this run
will never dispatch the rest of that source's chunks now, the source
as a whole never reaches every chunk settled, so nothing about it is
ever created, deleted or rewritten.  Its old content survives
completely intact; the handful of embeddings already computed for it
are wasted, not written piecemeal the way an earlier version of this
used to risk.

This never prunes, cancelled or not -- the asynchronous path does not
prune at all; see `arc-reindex-all''s docstring.  Sources not yet
reached are simply left as they were until the next run.

Also clears `arc--reindex-async-active' immediately, as an escape
hatch: ordinarily the run itself clears it once every in-flight
request has actually settled (see `arc--reindex-async-next-cell'), but
if something upstream of that ever leaks a slot the way a bug once did
-- `in-flight' never reaching 0, nothing left to converge on --
cancelling could never recover the session; a stuck run's now-orphaned
callbacks, if any ever do still arrive, still see `:cancelled' on their
own RUN object (unaffected by this) and still stop issuing new work,
they just no longer hold the one flag a fresh `M-x arc-reindex-all'
checks.

Does nothing (beyond a `message') if no asynchronous reindex is
active."
  (interactive)
  (if arc--reindex-async-active
      (let ((run arc--reindex-async-active))
        (plist-put run :cancelled t)
        (setq arc--reindex-async-active nil)
        (message "arc: cancelling reindex; sources already fully embedded keep their new content, sources caught mid-embedding keep their old content"))
    (message "arc: no asynchronous reindex is running")))

(provide 'arc-index)
;;; arc-index.el ends here
