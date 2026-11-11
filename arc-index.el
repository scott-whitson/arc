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
;; relying on `arc.el', which requires only one of them (`arc-source-info',
;; for the `arc-find-executable' value it injects into its async workers)
;; and never required `arc-source-org' or `arc-source-nixopt' at all.
;; It does NOT require `arc-source' --
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
;; pattern `arc-find-similar' and `arc-async-recalculate-embeddings' use).
;; That would fork a second Emacs process to do the writing, which raises
;; exactly the question this file's `arc--write-chunk' exists to make
;; moot: two different sqlite handles -- one per process -- writing to the
;; same file.  WAL supports one writer at a time across processes (a second
;; writer just gets SQLITE_BUSY, it does not corrupt anything), but the
;; parent process in `arc--async-do''s own pattern keeps its handle
;; open across the whole child run and only closes and reopens it in
;; the done callback -- so interactive retrieval in the parent racing the
;; child's write is a real scenario that pattern has
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

(defcustom arc-embed-locator nil
  "Whether a chunk's locator is included in the text that gets EMBEDDED.
The stored chunk is unaffected either way -- only the vector changes, so
what the model is shown and what citations quote never move.

THE FINDING: embedding the locator improves RANKING and not FINDING --
the same candidates, better ordered -- which is exactly what an
embedding change should look like, and the gain sat entirely below
`arc-limit'.  At a limit of 10 the model already receives all ten
chunks, so a 40-minute re-embed of the corpus bought nothing
measurable at k=10.  That is why this is off.

THE NUMBERS ARE HISTORICAL.  They were measured over the `dotfiles'
collection and its eight scoped eval questions -- recall@3 0.12, @5
0.25, @10 0.75 text-only against 0.38 / 0.38 / 0.75 with the locator
embedded, 6 of 8 found either way.  That collection no longer exists:
this branch replaced it with `home', on a corpus roughly five times the
size (310,767 chunks, measured 2026-09-17), against a different eval
set.  Treat the figures as the record of where the finding came from,
not as a current measurement of anything -- nothing has been measured
on the corpus arc actually has.

WHERE THEY GET RE-MEASURED: the four-arm embedding bake-off, which
runs every arm over the new corpus in one pass.  Until it does, the
default stands on the SHAPE of the old finding (a ranking gain below
the cutoff) rather than on any number here.

Turn it on if `arc-limit' ever drops to 5 or 3, where a ranking gain
would land inside the cutoff.  And note what recall@k cannot say: it
measures retrieval, not answer quality, so better ordering WITHIN the
context window may help a model that attends more to early content.
That is a limit of the instrument, not evidence of no effect.

Changing this requires re-embedding; `arc-index-rebuild-fts' will not do
it, because embeddings are not derived data."
  :type 'boolean :group 'arc)

(defconst arc--fts-locator-sql
  "COALESCE(s.path,'') || ' ' || COALESCE(s.option_name,'') || ' ' || \
COALESCE(s.info_node,'') || ' ' || COALESCE(s.org_id,'') || ' ' || \
COALESCE(d.title,'')"
  "SQL form of `arc--fts-locator', for `arc-index-rebuild-fts'.
Kept beside the elisp so the two cannot drift unnoticed;
`test/test-arc-fts-locator.el' builds an index each way and compares.")

(defun arc--fts-locator (source title)
  "Return SOURCE's identifying text, for the keyword index.
The vector arm searches meaning; the keyword arm should search
IDENTIFIERS, and it could not, because `data_fts' held the chunk text
alone. Measured on a 63k-chunk corpus: 0 of 8548 file chunks contained
their own path. So \"where is the disk layout for rafik defined\" had no
way to match `hi-hardware/disko/rafik.nix' -- the answer is the
FILENAME, and the filename was invisible to search. Option chunks
happened to embed their own name already, which is why options fared
better than files.

FTS5's default tokenizer splits on non-alphanumerics, so a path needs no
transformation: /home/u/config/hosts/hardware/disko.nix tokenizes to
home, u, config, hosts, hardware, disko, nix.

Deliberately NOT added to the embedded text: that would need a full
re-embed of the corpus, and the free half is worth measuring first."
  ;; Every field, empty where absent, rather than dropping nils: the SQL in
  ;; `arc--fts-locator-sql' concatenates five COALESCEd columns and cannot
  ;; cheaply skip blanks, so the elisp matches ITS shape rather than the other
  ;; way round. The stray spaces are irrelevant to FTS5's tokenizer, and
  ;; `afl-rebuild-agrees-with-the-insert-path' caught this exact mismatch the
  ;; first time it ran.
  (string-join
   (mapcar (lambda (x) (or x ""))
           (list (plist-get source :path)
                 (plist-get source :option-name)
                 (plist-get source :info-node)
                 (plist-get source :org-id)
                 title))
   " "))

(defun arc--fts-text (locator chunk)
  "Combine LOCATOR and CHUNK into the text stored in `data_fts'."
  (concat locator "\n" chunk))

(defun arc--insert-chunk-row (sid cid text line-start line-end title vec &optional locator)
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
                            rowid (arc--sql-quote
                                   (arc--fts-text (or locator "") text))))))

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
`arc--prune-departed', joining through `data', can never see and so
can never remove.  CHUNKS being empty (a producer -- `arc-file-sources'
for an empty or whitespace-only file, say -- can legitimately yield
zero of them for an otherwise-valid source) is handled the same way,
for the same reason: a source with no content gets no row and no
transaction at all here, rather than an upsert immediately followed by
zero inserts, which is exactly how a phantom row -- one `sources' row
with nothing in `data' for it to join through -- used to get created
even after the fix above.  A source that already had real content and
is reindexed down to zero chunks keeps its old row and old chunks
here (nothing here decides whether that is now stale); the
collection-level `arc--prune-departed' pass resolves that, because a
source enumerated with no chunks is not in the set it keeps -- and that
now holds even when the emptied source was the collection's only one,
which used to stay indexed and citable indefinitely."
  (if (null chunks)
      nil
    (with-sqlite-transaction (arc-db)
      (let ((sid (arc-source-upsert source)))
        (arc--delete-data-for-source sid)
        (dolist (c chunks)
          (arc--insert-chunk-row sid cid (nth 0 c) (nth 1 c) (nth 2 c)
                                 (plist-get source :title) (nth 3 c)
                                 (arc--fts-locator source (plist-get source :title))))
        (arc-index--bump-write-generation)
        sid))))

(defun arc--index-source-1 (source collection)
  "Like `arc-index-source' but return (SID . CHUNK-COUNT) instead of
just CHUNK-COUNT, SID being whatever `arc--replace-source-chunks'
returned (nil for a zero-chunk SOURCE).  `arc-index-source' is the
public, documented entry point and keeps its existing chunk-count
contract; this is the one other caller, `arc--index-sources-with-
progress', actually needs -- it reports the source ids indexing
*actually wrote*, not those of a separate, eager upsert of its own (see
`arc--index-sources-with-progress')."
  (let* ((cid (arc--collection-id collection))
         (locator (and arc-embed-locator
                       (arc--fts-locator source (plist-get source :title))))
         (embedded (mapcar (lambda (c)
                              (let ((text (arc--sanitize-text (plist-get c :text))))
                                (list text (plist-get c :line-start) (plist-get c :line-end)
                                      ;; The STORED chunk is always TEXT; only the
                                      ;; embedded input may carry the locator. What
                                      ;; the model is shown and what citations quote
                                      ;; must not change.
                                      (llm-embedding
                                       arc-embeddings-provider
                                       (if locator (arc--fts-text locator text) text)))))
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

(defun arc-index-rebuild-fts ()
  "Rebuild `data_fts' from `data' and `sources'.  Returns the row count.
Embeddings are NOT touched, so this is seconds rather than the 40
minutes a reindex costs on a real corpus -- the keyword index is pure
derived data. Run it after changing `arc--fts-locator', or to pick up
locator indexing on an index built before it existed."
  (interactive)
  (with-sqlite-transaction (arc-db)
    (sqlite-execute (arc-db) "DELETE FROM data_fts;")
    (sqlite-execute
     (arc-db)
     (format "INSERT INTO data_fts (rowid, data)
              SELECT d.id, %s || char(10) || d.chunk
              FROM data d JOIN sources s ON s.id = d.source_id;"
             arc--fts-locator-sql)))
  (arc-index--bump-write-generation)
  (let ((n (caar (sqlite-select (arc-db) "SELECT count(*) FROM data_fts;"))))
    (message "arc: rebuilt the keyword index over %d chunk(s)" n)
    n))

(defun arc-index-stats ()
  "Return an alist of (KIND . CHUNK-COUNT).
Always queries.  `arc-index-stats-cached' is the one to call from
anything that runs often."
  (mapcar (lambda (row) (cons (nth 0 row) (nth 1 row)))
          (sqlite-select (arc-db)
                         "SELECT s.kind, count(d.id) FROM sources s
                          LEFT JOIN data d ON d.source_id = s.id
                          GROUP BY s.kind;")))

(defun arc-index-collection-stats ()
  "Return a per-collection list of (NAME SOURCES CHUNKS LAST-INDEXED).

SOURCES is the count of distinct indexed sources in NAME's collection;
CHUNKS is its chunk count; LAST-INDEXED is `MAX(sources.indexed_at)'
among them, or nil when NAME has no chunks yet.

Iterates `arc-index-plan' rather than `SELECT DISTINCT collection FROM
data', the same choice `arc-freshness-report' makes and for the same
reason: a collection with nothing indexed yet still gets a zeroed row
here instead of silently vanishing from the report."
  (mapcar
   (lambda (cell)
     (let* ((name (car cell))
            (row (car (sqlite-select
                       (arc-db)
                       (format "SELECT count(DISTINCT d.source_id), count(d.id), MAX(s.indexed_at)
                                FROM data d JOIN sources s ON s.id = d.source_id
                                WHERE d.collection_id =
                                  (SELECT id FROM collections WHERE name = %s);"
                               (arc--sql-quote name))))))
       (list name (or (nth 0 row) 0) (or (nth 1 row) 0) (nth 2 row))))
   arc-index-plan))

(defvar arc-index--write-generation 0
  "Incremented by every function in arc that writes or deletes chunks.
`arc-index-stats-cached' compares against it to know its cached answer
is stale.  A counter rather than a timestamp because two writes inside
the same second must still invalidate.")

(defun arc-index--bump-write-generation ()
  "Record that the corpus changed."
  (setq arc-index--write-generation (1+ arc-index--write-generation)))

(defcustom arc-index-stats-cache-ttl 5
  "Seconds `arc-index-stats-cached' may reuse an answer.
The write-generation counter catches every change THIS Emacs makes, so
the TTL exists only for changes it cannot see: a reindex run from a
second Emacs, or a batch job.  Set to 0 to disable caching entirely."
  :type 'number :group 'arc)

(defvar arc-index--stats-cache nil
  "Cached `arc-index-stats' answer as (GENERATION TIMESTAMP STATS), or nil.")

(defun arc-index-stats-cached ()
  "Like `arc-index-stats', but reuse a recent result.
The tool and search callers ask for stats repeatedly, and the underlying
GROUP BY is not cheap once the corpus is real: measured on a
63,302-chunk / 327 MB index it took about 30 ms warm and 810 ms cold,
against 3.5 ms on the 7,405-chunk index it was written for.  Caching
keeps those status surfaces responsive without weakening freshness.

Invalidated by `arc-index--write-generation' (every write this Emacs
makes) or by `arc-index-stats-cache-ttl' elapsing (writes it cannot
see)."
  (unless (pcase arc-index--stats-cache
            (`(,gen ,ts ,_)
             (and (eq gen arc-index--write-generation)
                  (> arc-index-stats-cache-ttl 0)
                  (< (float-time (time-since ts)) arc-index-stats-cache-ttl)))
            (_ nil))
    (setq arc-index--stats-cache
          (list arc-index--write-generation (current-time) (arc-index-stats))))
  (nth 2 arc-index--stats-cache))

(defcustom arc-collection-directory-alist
  `(("vault"       . ,(expand-file-name "docs/org" (getenv "HOME")))
    ("home"        . ,(expand-file-name (getenv "HOME")))
    ("emacs"       . ,(expand-file-name ".config/emacs" (getenv "HOME")))
    ("claude"      . ,(expand-file-name ".claude" (getenv "HOME")))
    ("agent-shell" . ,(expand-file-name ".agent-shell" (getenv "HOME")))
    ("mail"        . ,(expand-file-name ".mail" (getenv "HOME"))))
  "Map a collection name to the directory it indexes.
Derived from $HOME -- never hardcode an absolute home path here.

`home' is $HOME itself.  That is safe rather than reckless because
`arc-ignore-invisible-files' defaults to t, so every dotted directory
is excluded from it -- ~/.cache, ~/.local, the per-tool state
directories, and the browser and password-manager caches never enter
the corpus.  On a developer's machine those hold tens of thousands of
files and several gigabytes between them, essentially none of it
prose; measure your own rather than trusting a number from someone
else's.  Its overlap with `vault' is excluded through
~/.arcignore; see `arc-ignore-patterns-files'.

That same exclusion is why `emacs', `claude' and `agent-shell' are
separate entries: they hold data, they live under dotted roots, and
`home' cannot see them.  Turning `arc-ignore-invisible-files' off
globally to reach them is not the alternative -- that would admit
every byte of cache under every dotted directory along with them.

`mail' is configured but deliberately absent from `arc-index-plan'.
Indexing mail should be something the operator turns on, not something
that happens because a default changed."
  :type '(alist :key-type string :value-type directory) :group 'arc)

(defun arc-collection-directory (name)
  "Return the directory NAME indexes, or signal if it is not configured."
  (or (alist-get name arc-collection-directory-alist nil nil #'equal)
      (error "arc: no directory configured for collection %S" name)))

(defcustom arc-index-plan
  '(("vault" . org) ("home" . file) ("emacs" . file)
    ("claude" . file) ("agent-shell" . file)
    ("nix options" . nixopt) ("hm options" . hmopt) ("builtin manuals" . info))
  "Collections to build and the chunker each uses.
`vault' must stay on the `org' chunker: the `file' chunker would index
the same text without org ids or titles, and `arc-eval''s `:org-id'
expectations match on exactly those.  `mail' is absent on purpose; see
`arc-collection-directory-alist'."
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

(defun arc--source-identity (source)
  "Return SOURCE's identity as a string, matching the `sources' unique key.
That key is (kind, path, org_id, option_name, info_node) with NULLs read
as empty strings -- see `arc-sources-create-index-sql' -- so two plists
with the same identity here are the same `sources' row, whichever
collection or run produced them.  A NUL separates the fields because no
field can contain one."
  (mapconcat (lambda (key) (or (plist-get source key) ""))
             '(:kind :path :org-id :option-name :info-node)
             "\0"))

(defun arc--prune-departed (cid keep enumerated)
  "Remove from collection CID every source whose identity is not in KEEP.
KEEP is a hash table of `arc--source-identity' strings: every source
this run's walk of CID ENUMERATED that has at least one chunk.
ENUMERATED is how many sources the walk produced at all, chunked or
not.  Return how many sources were removed, or 0 without touching the
database when ENUMERATED is zero.

Removal is per collection: the source's `data' rows in CID go, with
their `data_embeddings' and `data_fts' rows, and the `sources' row goes
only once no collection has data for it.  A file can legitimately move
between collections (an `.arcignore' edit hands it from `home' to
`emacs', say), and pruning the collection it left must not take the
copy the other one already wrote.

WHY IDENTITY AND NOT WRITTEN IDS.  This used to be
`arc--prune-collection', which kept the source ids a run had actually
WRITTEN.  Two holes followed from that choice, and both are closed by
keeping what the walk SAW instead:

- The asynchronous path could not prune at all.  A list of written ids
  is only complete once every source has been written, and a cancel, a
  producer error or one stubborn embedding failure each left it short
  -- three separate attempts each turned that into a reproduced way to
  delete sources the run had simply not reached.  The enumeration is
  complete from the start: it is gathered before any embedding begins.
  A source whose embedding fails is still in it, so it is kept, with
  its old content, exactly as before.
- A collection's only source, emptied to zero chunks, was never removed.
  Its walk wrote nothing, so the written-id list was empty, and an empty
  list is refused (below).  An emptied file is still ENUMERATED -- the
  walk found it, it just has nothing in it -- so ENUMERATED is 1, the
  guard does not fire, and the source's old content goes.

ENUMERATED zero is refused outright, and that guard is unchanged: a
walk that found nothing at all is indistinguishable, from here, from a
directory that was not ready yet -- unmounted, a sync tool mid-catch-up
-- and deleting a whole collection is never the right answer to that
ambiguity.  Reproduced live, that case once turned an org-roam
directory Syncthing had not finished syncing into 428 deleted sources."
  (if (zerop enumerated)
      0
    (let ((removed 0))
      (dolist (row (sqlite-select
                    (arc-db)
                    (format "SELECT DISTINCT s.id, s.kind, s.path, s.org_id,
                                    s.option_name, s.info_node
                             FROM sources s JOIN data d ON d.source_id = s.id
                             WHERE d.collection_id = %d;" cid)))
        (pcase-let ((`(,sid ,kind ,path ,org-id ,option-name ,info-node) row))
          (unless (gethash (arc--source-identity
                            (list :kind kind :path path :org-id org-id
                                  :option-name option-name :info-node info-node))
                           keep)
            (with-sqlite-transaction (arc-db)
              (let ((ids (flatten-tree
                          (sqlite-select
                           (arc-db)
                           (format "SELECT id FROM data WHERE source_id = %d
                                    AND collection_id = %d;" sid cid)))))
                (when ids
                  (let ((idlist (arc-sqlite-format-int-list ids)))
                    ;; The two virtual tables carry no foreign key, so
                    ;; their rows go explicitly, by rowid, before `data'.
                    (sqlite-execute (arc-db) (format "DELETE FROM data_embeddings WHERE rowid IN %s;" idlist))
                    (sqlite-execute (arc-db) (format "DELETE FROM data_fts WHERE rowid IN %s;" idlist))
                    (sqlite-execute (arc-db) (format "DELETE FROM data WHERE id IN %s;" idlist)))))
              (when (zerop (caar (sqlite-select
                                  (arc-db)
                                  (format "SELECT count(*) FROM data WHERE source_id = %d;"
                                          sid))))
                (sqlite-execute (arc-db) (format "DELETE FROM sources WHERE id = %d;" sid))))
            (setq removed (1+ removed)))))
      (when (> removed 0) (arc-index--bump-write-generation))
      removed)))

(defun arc--enumeration-keep (sources)
  "Return (KEEP . ENUMERATED) for SOURCES, a fully expanded source list.
See `arc--prune-departed' for what each half means."
  (let ((keep (make-hash-table :test 'equal)))
    (dolist (s sources)
      (when (plist-get s :chunks)
        (puthash (arc--source-identity s) t keep)))
    (cons keep (length sources))))

(defconst arc--reindex-skipped :arc-reindex-skipped
  "Sentinel `arc--candidate-paths' (and so `arc--plan-cell-entries' and
`arc--plan-cell-source-list') returns for a missing directory,
distinct from an empty enumeration, so callers never mistake \"this
collection's directory is not on this host\" for \"everything in it
was deleted\" and prune rows that are still perfectly good.  Note that
an empty enumeration is not itself treated as a reason to prune either
-- see `arc--prune-departed' -- this sentinel exists to keep a third,
still different case (no directory at all) from being folded into that
same empty value and skipping the \"directory does not exist\"
`message' that reports it.")

(defun arc--index-sources-with-progress (name sources)
  "Index each of SOURCES into collection NAME, in order.
Return the list of source ids actually written, omitting any SOURCES
entry that came back with no chunks to write --
`arc--replace-source-chunks' gives such a source no row at all, so
there is no id to include.  Pruning does not read this list (see
`arc--prune-departed'); the count is what the run reports.  Reports
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

(defun arc-index--collection-overlaps ()
  "Return the planned collection pairs whose corpora overlap unexcluded.

Each element is (OUTER INNER OUTER-DIR INNER-DIR): INNER's directory
lies under OUTER's, both are built by `arc-index-plan', and nothing in
OUTER's ignore files or invisibility rules keeps OUTER's walk out of
INNER's tree.  Computed from `arc-collection-directory-alist' and
`arc-index-plan' alone -- no database, no walk, no I/O beyond reading
OUTER's ignore files.

This exists because the default layout overlaps by design: `home' is
$HOME and `vault' is ~/docs/org inside it, and the ONLY thing
separating them is a `.arcignore' the operator writes by hand, outside
this repository.  Without it ~/docs/org is walked twice -- once by
`vault' with the org chunker, once by `home' with the `file' chunker,
the second copy carrying no org id, no title and no citable link while
competing in every ranking and doubling the embedding cost of the
largest curated collection.  All of that is silent: two collections
indexing the same file is not an error at any layer below this one.

The reach test is `arc--path-indexable-p', the same predicate the walk
filters with, asked about a hypothetical file inside INNER.  Sharing it
is what makes this agree with the walk rather than approximate it --
notably, it is why the three dotted roots (`emacs', `claude',
`agent-shell') do NOT report: `arc-ignore-invisible-files' already
keeps `home' out of them, and the predicate knows that."
  (let ((planned (seq-filter (lambda (cell)
                               (assoc (car cell) arc-collection-directory-alist))
                             arc-index-plan))
        (overlaps '()))
    (dolist (outer planned)
      (let* ((outer-name (car outer))
             (outer-dir (file-name-as-directory
                         (expand-file-name (arc-collection-directory outer-name))))
             (ignore-regexps (arc--read-ignore-file-regexps outer-dir)))
        (dolist (inner planned)
          (let* ((inner-name (car inner))
                 (inner-dir (file-name-as-directory
                             (expand-file-name (arc-collection-directory inner-name)))))
            (when (and (not (equal outer-dir inner-dir))
                       (string-prefix-p outer-dir inner-dir)
                       (arc--path-indexable-p
                        (expand-file-name "a-file" inner-dir)
                        outer-dir ignore-regexps))
              (push (list outer-name inner-name outer-dir inner-dir) overlaps))))))
    (nreverse overlaps)))

(defun arc-index--warn-overlapping-collections ()
  "Warn once for each pair `arc-index--collection-overlaps' reports.
A warning and not an error: an overlap is a misconfiguration, not a
corruption, and refusing to index would be a worse answer than indexing
and saying so.  Called from `arc-reindex-all' -- once per run, before
any work, so it is seen rather than buried under progress messages."
  (dolist (overlap (arc-index--collection-overlaps))
    (pcase-let ((`(,outer ,inner ,outer-dir ,inner-dir) overlap))
      (display-warning
       'arc
       (format "collection %S (%s) sits inside collection %S (%s) and nothing excludes it.

Every file under %s will be indexed TWICE: once by %S with its own
chunker, and once by %S with the %S chunker -- the second copy with no
org id, no title and no citable link, competing in every ranking and
doubling the embedding cost.

Fix: add a line excluding %s to %s.arcignore, then reindex."
               inner inner-dir outer outer-dir
               inner-dir inner outer
               (alist-get outer arc-index-plan nil nil #'equal)
               (file-relative-name inner-dir outer-dir)
               outer-dir)
       :warning))))

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
(`arc--plan-cell-entries': parsing options.json, walking the Info
manuals, listing a file collection's candidate paths) is still a plain,
synchronous call and does briefly block Emacs, same as any other
function call -- measured around 7.44s for `info' on the real corpus,
not nothing, but not the multi-minute freeze this exists to fix
either.  A file or org collection's per-file work -- reading, hashing,
chunking -- is deferred to the moment the run reaches that file.
Called interactively -- `M-x arc-reindex-all' -- ASYNC is always
non-nil: unlimited caps are the default (see `arc-index-nixopt-cap'
and friends), and a real full ingest is a 20-40 minute run that must
not freeze Emacs to get.  Progress is reported via `message' either
way; see `arc-index-progress-every'.

Warns, before any work, about a planned collection whose directory
sits inside another planned collection's with nothing excluding the
overlap -- see `arc-index--warn-overlapping-collections'.  A warning
and not a refusal: the default layout overlaps on purpose (`vault' is
inside `home'), and it is an operator-written `.arcignore', outside
this repository, that separates them.

Both paths prune: a source the collection's walk no longer yields --
deleted, gitignored, newly excluded, or emptied to zero chunks -- is
removed once that collection's pass completes.  The asynchronous path
prunes only a pass that ran to the end uncancelled with every deferred
entry expanded, and neither path prunes a walk that found nothing; see
`arc--prune-departed' for why keeping what the walk SAW, rather than
what the run wrote, is what made the asynchronous prune safe."
  (interactive (list nil t))
  (arc-index--warn-overlapping-collections)
  (if async
      (arc--reindex-all-async collections)
    (arc--reindex-all-sync collections)))

(defun arc--reindex-all-sync (&optional collections)
  "Synchronous implementation of `arc-reindex-all'.  See its docstring.
Gathers each collection through `arc--plan-cell-source-list', the same
enumeration the asynchronous path and `arc-index-plan-census' use, so
the three cannot disagree about what a collection contains."
  (dolist (cell (if collections
                     (seq-filter (lambda (c) (member (car c) collections)) arc-index-plan)
                   arc-index-plan))
    (let* ((name (car cell))
           (cid (arc--collection-id name))
           (sources (arc--plan-cell-source-list name (cdr cell)))
           (written (unless (eq sources arc--reindex-skipped)
                      (arc--index-sources-with-progress name sources))))
      ;; Record what this collection was built FROM, when that is the
      ;; freshness signal. Cheap, and it is what lets `arc-freshness-report'
      ;; answer for 37,780 derived sources with one string comparison.
      (when-let* ((prov (arc-collection-provenance-now (cdr cell))))
        (arc-set-collection-provenance name prov))
      (cond
       ((eq sources arc--reindex-skipped) nil) ; already reported; nothing to prune
       ((null sources)
        (message "arc: %s: 0 source(s) found; not pruning (see `arc--prune-departed')" name))
       (t
        (message "arc: %s: %d source(s) indexed" name (length written))
        (let* ((enumeration (arc--enumeration-keep sources))
               (removed (arc--prune-departed cid (car enumeration) (cdr enumeration))))
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

(defun arc--candidate-paths (name kind)
  "Return the paths collection NAME's KIND walk would read, unread.
Only the `file' and `org' kinds walk a directory; any other KIND
returns nil.  Returns `arc--reindex-skipped', with a `message', when
the collection's directory is absent on this host.  Nothing is opened:
for `file' this is `arc--file-candidates', the path rules alone, and
`arc--candidate-sources' applies the content rule per path."
  (pcase kind
    ((or 'file 'org)
     (let ((dir (arc-collection-directory name)))
       (if (not (file-directory-p dir))
           (progn (message "arc: skipping %s, directory does not exist: %s" name dir)
                  arc--reindex-skipped)
         (if (eq kind 'file) (arc--file-candidates dir) (arc-org-files dir)))))
    (_ nil)))

(defun arc--candidate-sources (kind path)
  "Return the source plists PATH yields under KIND (`file' or `org').
For `file' that is no source at all when `arc--text-file-p' says PATH
is not text, else exactly `arc-file-source''s; for `org' it is every
node `arc-org-nodes-in-file' finds.  `arc-file-sources' and
`arc-org-nodes' produce precisely the union of this over
`arc--candidate-paths' -- the same path rules, the same content rule,
the same constructors."
  (pcase kind
    ('file (when (arc--text-file-p path) (list (arc-file-source path))))
    ('org (arc-org-nodes-in-file path))))

(defun arc--plan-cell-entries (name kind)
  "Return collection NAME's KIND enumeration, with directory walks DEFERRED.
Like `arc--plan-cell-source-list', except that a `file' or `org'
collection comes back as one zero-argument function per candidate path,
each returning that path's source plists (see `arc--candidate-sources')
when called.  The other kinds come back as source plists, exactly as
before.  `arc--reindex-async-collection' calls each function only when
it reaches that entry.

Why: the asynchronous reindex used to gather every source of a
collection eagerly, before its first embedding -- and for a file
collection that meant reading, hashing and chunking EVERY file in one
synchronous call.  On a host where Emacs is the Wayland compositor that
is the whole display frozen for as long as the walk of $HOME takes.
Deferring the per-file work leaves only the path walk up front, and
`arc--directory-descendable-p' keeps that walk out of ignored trees."
  (let ((paths (arc--candidate-paths name kind)))
    (cond
     ((eq paths arc--reindex-skipped) paths)
     ((memq kind '(file org))
      (mapcar (lambda (path) (lambda () (arc--candidate-sources kind path))) paths))
     (t
      (pcase kind
        ('nixopt (let ((all (arc-nixopt-parse-json (arc-nixopt-options-json-path) "nix-option")))
                   (if arc-index-nixopt-cap (take arc-index-nixopt-cap all) all)))
        ('hmopt (let ((all (arc-nixopt-parse-json (arc-hm-options-json-path) "hm-option")))
                  (if arc-index-hmopt-cap (take arc-index-hmopt-cap all) all)))
        ('info (arc-info-sources (arc--prioritize-manuals (arc-get-builtin-manuals)
                                                           arc-index-info-priority-manuals)
                                  arc-index-info-cap)))))))

(defun arc--expand-entry (entry)
  "Return the source plists ENTRY stands for, as a list.
ENTRY is an element of `arc--plan-cell-entries': a deferred function,
called here, or a source plist, returned in a list of one."
  (if (functionp entry) (funcall entry) (list entry)))

(defun arc--plan-cell-source-list (name kind)
  "Return the list of source plists collection NAME's KIND would index,
or `arc--reindex-skipped' when its directory is absent.  This is
`arc--plan-cell-entries' with every deferred entry expanded: the
synchronous reindex and `arc-index-plan-census' want the whole list in
hand, the asynchronous one does not.  None of it talks to the embedding
model, so none of it is the tens-of-minutes-long part, but it is not
free either: gathering `info''s sources alone (walking 94 builtin
manuals) measured around 7.44s on the real corpus, and a `file'
collection reads, hashes and chunks every file it admits."
  (let ((entries (arc--plan-cell-entries name kind)))
    (if (eq entries arc--reindex-skipped)
        entries
      (mapcan #'arc--expand-entry entries))))

;;; Census: what a reindex WOULD produce

(defun arc--census-dir-key (path root depth)
  "Return PATH's first DEPTH directory components under ROOT, as a key.
A file directly in ROOT keys as \"./\"."
  (let* ((rel (file-relative-name path root))
         (parts (butlast (split-string rel "/"))))
    (if (null parts)
        "./"
      (concat (string-join (take depth parts) "/") "/"))))

(defun arc-index-plan-census (&optional collections depth)
  "Count what each `arc-index-plan' collection would index, embedding nothing.
Return one plist per collection -- COLLECTIONS, a list of names, or the
whole plan when nil -- with keys :collection, :chunker, :sources,
:chunks, :chars (characters across every chunk, the embedding input),
:walk-seconds (listing candidate paths, the part an asynchronous
reindex blocks on), :gather-seconds (reading, hashing and chunking
them), and :skipped (non-nil when the directory is absent).  With DEPTH,
a positive integer, a `file' or `org' collection also carries :by-dir,
an alist of (DIR SOURCES CHUNKS CHARS) keyed by a source's first DEPTH
directory components under the collection root, largest first -- what
an `.arcignore' is written from.

This goes through `arc--plan-cell-entries' and `arc--expand-entry', the
enumeration and the chunkers a real reindex uses, so the counts are the
corpus a reindex would build, not an estimate of it.  It costs what
gathering costs and nothing more: no embedding request is made, nothing
is written, and the database is never opened.  Derived collections
still build their inputs -- `nix options' and `hm options' run `nix
build' -- so leave them out of COLLECTIONS to count the directories
alone.

Why it exists: the corpus was widened to the whole of $HOME on
2026-09-17 and then measured AFTER the fact, at 310,767 chunks and a
projected ten hours of embedding, which is why that index was never
built.  Measuring before embedding is the only order in which an
`.arcignore' can be written from numbers."
  (mapcar
   (lambda (cell)
     (let* ((name (car cell))
            (kind (cdr cell))
            (root (and (memq kind '(file org))
                       (file-name-as-directory
                        (expand-file-name (arc-collection-directory name)))))
            (t0 (float-time))
            (entries (arc--plan-cell-entries name kind))
            (t1 (float-time))
            (by-dir (make-hash-table :test 'equal))
            (nsources 0) (nchunks 0) (nchars 0))
       (if (eq entries arc--reindex-skipped)
           (list :collection name :chunker kind :sources 0 :chunks 0 :chars 0
                 :walk-seconds (- t1 t0) :gather-seconds 0.0 :skipped t)
         (dolist (entry entries)
           (dolist (source (arc--expand-entry entry))
             (let* ((chunks (plist-get source :chunks))
                    (chars (apply #'+ (mapcar (lambda (c) (length (plist-get c :text)))
                                              chunks))))
               ;; A chunkless source is enumerated but writes nothing, so
               ;; it is no source of the index either.
               (when chunks
                 (setq nsources (1+ nsources)
                       nchunks (+ nchunks (length chunks))
                       nchars (+ nchars chars))
                 (when (and depth root (plist-get source :path))
                   (let* ((key (arc--census-dir-key (plist-get source :path) root depth))
                          (row (or (gethash key by-dir) (list 0 0 0))))
                     (puthash key (list (+ (nth 0 row) 1)
                                        (+ (nth 1 row) (length chunks))
                                        (+ (nth 2 row) chars))
                              by-dir)))))))
         (let ((t2 (float-time))
               (rows nil))
           (maphash (lambda (k v) (push (cons k v) rows)) by-dir)
           (append
            (list :collection name :chunker kind :sources nsources :chunks nchunks
                  :chars nchars :walk-seconds (- t1 t0) :gather-seconds (- t2 t1)
                  :skipped nil)
            (when depth
              (list :by-dir (sort rows (lambda (a b) (> (nth 2 a) (nth 2 b)))))))))))
   (if collections
       (seq-filter (lambda (c) (member (car c) collections)) arc-index-plan)
     arc-index-plan)))

(defun arc-index-census-format (census &optional seconds-per-chunk top)
  "Render CENSUS, from `arc-index-plan-census', as a plain-text table.
With SECONDS-PER-CHUNK, add the embedding time it projects -- measure
the rate on this machine rather than borrowing one; see the census's
own docstring for what a borrowed one cost.  TOP caps how many :by-dir
rows each collection lists (default 15)."
  (let ((total-chunks 0) (total-sources 0))
    (concat
     (format "%-16s %9s %9s %12s %7s %7s%s\n" "collection" "sources" "chunks"
             "chars" "walk s" "read s" (if seconds-per-chunk "  embed h" ""))
     (mapconcat
      (lambda (c)
        (setq total-chunks (+ total-chunks (plist-get c :chunks))
              total-sources (+ total-sources (plist-get c :sources)))
        (concat
         (format "%-16s %9d %9d %12d %7.1f %7.1f%s%s\n"
                 (plist-get c :collection) (plist-get c :sources) (plist-get c :chunks)
                 (plist-get c :chars) (plist-get c :walk-seconds)
                 (plist-get c :gather-seconds)
                 (if seconds-per-chunk
                     (format "  %7.2f" (/ (* seconds-per-chunk (plist-get c :chunks)) 3600.0))
                   "")
                 (if (plist-get c :skipped) "  (directory absent)" ""))
         (mapconcat (lambda (row)
                      (format "    %-40s %7d %8d %12d\n"
                              (truncate-string-to-width (nth 0 row) 40)
                              (nth 1 row) (nth 2 row) (nth 3 row)))
                    (take (or top 15) (plist-get c :by-dir))
                    "")))
      census "")
     (format "%-16s %9d %9d%s\n" "TOTAL" total-sources total-chunks
             (if seconds-per-chunk
                 (format "%35s%7.2f" "" (/ (* seconds-per-chunk total-chunks) 3600.0))
               "")))))

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

An element of SOURCES may also be a deferred entry from
`arc--plan-cell-entries' -- a function returning the source plists one
path yields.  It is called only when the run reaches it, and what it
returns is processed in its place; TOTAL, the progress denominator, is
adjusted to match.  A deferred entry that signals is reported and
skipped, and marks this pass's enumeration incomplete (below).

This does not prune: it is also the watcher's entry point, handed a
few changed paths rather than a whole collection, and pruning against
that would delete everything else.  It REPORTS what it enumerated
instead, and `arc--reindex-async-next-cell' -- which alone knows SOURCES
was a whole collection -- decides.

Calls ON-COLLECTION-DONE with (SOURCES-REPLACED NOT-REPLACED-COUNT
ENUMERATION) --
SOURCES-REPLACED how many sources were actually, successfully replaced
(not merely attempted: reporting otherwise once said \"2 source(s)
indexed\" after a cancel that had replaced only 1), NOT-REPLACED-COUNT
how many had at least one chunk fail to embed, or failed at the
replace itself -- once every source either has been fully replaced,
given up on, or RUN was cancelled, and either every source in SOURCES
has been started, or RUN was cancelled.  ENUMERATION is (KEEP .
ENUMERATED) in `arc--enumeration-keep''s shape, covering every source
this pass reached, or nil when it cannot be trusted as the whole
collection: RUN was cancelled, or a deferred entry failed to expand.
A source whose embedding failed IS in KEEP -- the enumeration is what
the walk found, not what got written.  Called exactly once: `finished'
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
        (keep (make-hash-table :test 'equal)) ; identities enumerated with chunks
        (enumerated 0)
        (incomplete nil)
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
           (let ((entry (car remaining)))
             (setq remaining (cdr remaining))
             (if (functionp entry)
                 (let ((expanded
                        (condition-case err
                            (arc--expand-entry entry)
                          ((error quit)
                           (setq incomplete t)
                           (message "arc: %s: could not read a source, skipped; this pass will not prune: %s"
                                    name (error-message-string err))
                           nil))))
                   (setq total (+ total (length expanded) -1))
                   (setq remaining (append expanded remaining)))
               (start-source entry))))
         (start-source (source)
           (let ((chunks (plist-get source :chunks)))
             (cl-incf enumerated)
             (when chunks (puthash (arc--source-identity source) t keep))
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
               (funcall on-collection-done sources-replaced (hash-table-count not-replaced)
                        (unless (or incomplete (plist-get run :cancelled))
                          (cons keep enumerated)))))))
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
mid-plan with `arc--reindex-async-active' left set.  A failure here
happens before the cell's pass and therefore before its prune, so it
cannot destroy anything -- but it must still not be silent, and it
does not try to skip the bad cell and continue with the rest of the
plan: a producer that fails once for a cell is likely to fail again,
and guessing otherwise is exactly the kind of recovery logic this
does not attempt."
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
               (sources (arc--plan-cell-entries name (cdr cell))))
          (if (eq sources arc--reindex-skipped)
              (arc--reindex-async-next-cell run (cdr cells))
            (progn
              (message "arc: %s: %d source(s) to index" name (length sources))
              (arc--reindex-async-collection
               run name cid sources (length sources)
               (lambda (sources-replaced not-replaced-count &optional enumeration)
                 (message "arc: %s: %d source(s) replaced%s%s" name sources-replaced
                          (if (plist-get run :cancelled) " (cancelled)" "")
                          (if (> not-replaced-count 0)
                              (format " -- %d source(s) not replaced (a chunk failed to embed, or the replace itself failed), old content kept, see messages above"
                                      not-replaced-count)
                            ""))
                 ;; The same prune the synchronous path runs, against the
                 ;; same kind of evidence: everything this pass's walk
                 ;; enumerated.  ENUMERATION is nil for a cancelled pass
                 ;; or one whose walk did not fully expand -- see
                 ;; `arc--reindex-async-collection' -- and then nothing
                 ;; is pruned at all.
                 (when (and enumeration (not (plist-get run :cancelled)))
                   (when-let* ((prov (arc-collection-provenance-now (cdr cell))))
                     (arc-set-collection-provenance name prov))
                   ;; This runs from an embedding callback, where an
                   ;; unhandled signal is swallowed by the `plz' sentinel
                   ;; and would stop the run silently with
                   ;; `arc--reindex-async-active' still set.
                   (condition-case err
                       (let ((removed (arc--prune-departed cid (car enumeration)
                                                           (cdr enumeration))))
                         (when (> removed 0)
                           (message "arc: %s: removed %d stale source(s)" name removed)))
                     (error (message "arc: %s: pruning departed sources failed: %s"
                                     name (error-message-string err)))))
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

(defconst arc-freshness-per-source-kinds '("file" "org-node")
  "Kinds whose freshness is a per-source content hash.
Everything else is derived from immutable inputs -- Info manuals from a
Nix store path, options from a flake.lock revision -- and cannot change
without that input changing. Measured on this corpus: roughly 11,000
sources are mutable and 37,780 are not, so hashing everything would be
three to four times the work to learn one bit per collection.")

(defun arc--flake-provenance (dir)
  "Return a provenance string for the flake at DIR, or nil."
  (let ((lock (expand-file-name "flake.lock" dir)))
    (when (file-readable-p lock)
      (concat "flake.lock:" (arc-file-hash lock)))))

(defun arc--info-provenance ()
  "Return a provenance string for the Info manuals arc can see.
Info files live in the Nix store, so the resolved directory list changes
exactly when the Emacs closure does -- which is the only way a manual's
content can change."
  (concat "info-dirs:"
          (secure-hash 'sha1 (mapconcat #'identity
                                        (sort (copy-sequence
                                               (or (bound-and-true-p Info-directory-list)
                                                   (bound-and-true-p Info-default-directory-list)
                                                   '()))
                                              #'string<)
                                        ":"))))

(defun arc-collection-provenance-now (chunker)
  "Return the CURRENT provenance for a collection built by CHUNKER.
nil means this collection's freshness is per-source instead."
  (pcase chunker
    ('info (arc--info-provenance))
    ('nixopt (arc--flake-provenance arc-nixopt-flake))
    ('hmopt (arc--flake-provenance arc-hm-flake))
    (_ nil)))

(defcustom arc-freshness-unindexed-probe-max 200
  "Most unindexed candidate paths one freshness report opens.
`arc-freshness-report' lists a file or org collection's candidate
paths -- the path rules only, see `arc--candidate-paths' -- and every
one with no indexed source is a file the collection may be missing.
Whether it really is takes a read (a binary, an empty file, an org file
with no id all yield no source), so this bounds how many such reads one
report may make.  The report is on `arc-tool-stats''s path, which an
MCP client polls; a collection that was never fully built can have
thousands of candidates, and a precise count of them is not worth a
stall.  When the bound is hit the count is reported as a floor."
  :type 'natnum :group 'arc)

(defun arc--collection-unindexed (name chunker indexed-paths)
  "Return (CONFIRMED . FLOOR-P) for collection NAME's unindexed sources.
CONFIRMED counts candidate paths of CHUNKER's walk (`file' or `org')
that are not among INDEXED-PATHS, a hash table, and that DO yield a
source with chunks when read; FLOOR-P is non-nil when
`arc-freshness-unindexed-probe-max' stopped the reading early, so
CONFIRMED is a lower bound.  Return nil when NAME has no configured,
existing directory -- there is then nothing to compare against."
  (let ((dir (alist-get name arc-collection-directory-alist nil nil #'equal)))
    (when (and (memq chunker '(file org)) dir (file-directory-p dir))
      (let ((confirmed 0) (probed 0) (floor nil))
        (catch 'done
          (dolist (path (arc--candidate-paths name chunker))
            (unless (gethash path indexed-paths)
              (when (>= probed arc-freshness-unindexed-probe-max)
                (setq floor t)
                (throw 'done nil))
              (setq probed (1+ probed))
              (when (seq-some (lambda (s) (plist-get s :chunks))
                              (ignore-errors (arc--candidate-sources chunker path)))
                (setq confirmed (1+ confirmed))))))
        (cons confirmed floor)))))

(defun arc-freshness-report ()
  "Return a per-collection freshness list of (NAME KIND STATE DETAIL).
STATE is `fresh', `stale', `partial', `unknown' or `absent'.

Two mechanisms, because the corpus holds two kinds of source. For
collections built from files or org nodes, recorded hashes are compared
against the files on disk. For collections derived from a flake.lock or
a Nix store path, the recorded provenance is compared against the
current one -- one string, not 37,780 hashes.

`unknown' is reported wherever there is no evidence: a collection
indexed before provenance recording, or sources indexed before hashing.
It is deliberately not folded into `stale'. They are different claims,
and an index predating hashing would otherwise read as \"everything just
changed\", which is noise a reader learns to ignore -- and a freshness
report nobody reads is the thing this replaces.

`partial' is a third claim: everything indexed is current, but the
collection's walk would index sources it does not have.  Comparing only
the sources already indexed could never see that, and it reported a
`home' collection holding 1 source out of thousands on disk as
`fresh'.  The walk is `arc--candidate-paths', the reindex's own, and
`arc--collection-unindexed' reads at most
`arc-freshness-unindexed-probe-max' of the candidates it finds missing.
A collection that is both drifted and missing sources is `stale', with
the missing count in its detail; one whose missing candidates could
not all be read, none of them confirmed, is `unknown'."
  (mapcar
   (lambda (cell)
     (let* ((name (car cell))
            (chunker (cdr cell))
            (indexed (caar (sqlite-select
                            (arc-db)
                            (format "SELECT count(*) FROM sources s
                                     JOIN data d ON d.source_id = s.id
                                     WHERE d.collection_id =
                                       (SELECT id FROM collections WHERE name = %s);"
                                    (arc--sql-quote name)))))
            (want (arc-collection-provenance-now chunker)))
       (cond
        ((or (null indexed) (zerop indexed))
         (list name chunker 'absent "never indexed"))
        (want
         (let ((have (arc-collection-provenance name)))
           (cond ((null have) (list name chunker 'unknown "no provenance recorded"))
                 ((equal have want) (list name chunker 'fresh nil))
                 (t (list name chunker 'stale "input changed")))))
        (t
         (let ((rows (sqlite-select
                      (arc-db)
                      (format "SELECT DISTINCT s.path, s.hash FROM sources s
                               JOIN data d ON d.source_id = s.id
                               WHERE s.path IS NOT NULL AND d.collection_id =
                                 (SELECT id FROM collections WHERE name = %s);"
                              (arc--sql-quote name))))
               (paths (make-hash-table :test 'equal))
               (gone 0) (changed 0) (unhashed 0))
           (dolist (row rows)
             (let ((path (nth 0 row)) (hash (nth 1 row)))
               (puthash path t paths)
               (cond ((not (file-readable-p path)) (setq gone (1+ gone)))
                     ((null hash) (setq unhashed (1+ unhashed)))
                     ((not (equal hash (arc-file-hash path)))
                      (setq changed (1+ changed))))))
           (let* ((missing (arc--collection-unindexed name chunker paths))
                  (unindexed (or (car missing) 0))
                  (unindexed-text
                   (and (> unindexed 0)
                        (format "%s%d unindexed" (if (cdr missing) "at least " "")
                                unindexed))))
             (cond
              ((and (zerop gone) (zerop changed) (zerop unhashed) (zerop unindexed))
               (if (cdr missing)
                   (list name chunker 'unknown
                         (format "the first %d unindexed candidate(s) yield nothing; the rest were not read"
                                 arc-freshness-unindexed-probe-max))
                 (list name chunker 'fresh nil)))
              ((and (zerop gone) (zerop changed) (zerop unhashed))
               (list name chunker 'partial unindexed-text))
              ((and (zerop gone) (zerop changed))
               (list name chunker 'unknown
                     (string-join
                      (delq nil (list (format "%d source(s) indexed before hashing" unhashed)
                                      unindexed-text))
                      ", ")))
              (t (list name chunker 'stale
                       (string-join
                        (delq nil
                              (list (and (> changed 0) (format "%d changed" changed))
                                    (and (> gone 0) (format "%d gone" gone))
                                    (and (> unhashed 0) (format "%d unhashed" unhashed))
                                    unindexed-text))
                        ", "))))))))))
   arc-index-plan))

(defun arc-freshness-report-metadata-only ()
  "Return freshness rows without reading source contents.
This is the lifecycle-report variant of `arc-freshness-report'.  Mutable
sources use existence and recorded modification times only; they are not
hashed.  A changed timestamp is actionable `stale', while a missing
recorded timestamp is `unknown'.  Derived collections still compare their
single recorded provenance value, as the normal freshness report does."
  (mapcar
   (lambda (cell)
     (let* ((name (car cell))
            (chunker (cdr cell))
            (indexed (caar (sqlite-select
                            (arc-db)
                            (format "SELECT count(*) FROM sources s
                                     JOIN data d ON d.source_id = s.id
                                     WHERE d.collection_id =
                                       (SELECT id FROM collections WHERE name = %s);"
                                    (arc--sql-quote name)))))
            (want (arc-collection-provenance-now chunker)))
       (cond
        ((or (null indexed) (zerop indexed))
         (list name chunker 'absent "never indexed"))
        (want
         (let ((have (arc-collection-provenance name)))
           (cond ((null have) (list name chunker 'unknown "no provenance recorded"))
                 ((equal have want) (list name chunker 'fresh nil))
                 (t (list name chunker 'stale "input changed")))))
        (t
         (let ((rows (sqlite-select
                      (arc-db)
                      (format "SELECT DISTINCT s.path, s.mtime
                               FROM sources s
                               JOIN data d ON d.source_id = s.id
                              WHERE s.path IS NOT NULL AND d.collection_id =
                                (SELECT id FROM collections WHERE name = %s);"
                              (arc--sql-quote name))))
               (gone 0) (changed 0) (unknown 0))
           (dolist (row rows)
             (let* ((path (nth 0 row))
                    (recorded (nth 1 row))
                    (attrs (and (file-exists-p path) (file-attributes path)))
                    (current (and attrs
                                  (truncate (float-time
                                             (file-attribute-modification-time attrs))))))
               (cond ((null attrs) (setq gone (1+ gone)))
                     ((null recorded) (setq unknown (1+ unknown)))
                     ((not (= recorded current)) (setq changed (1+ changed))))))
           (cond
            ((and (zerop gone) (zerop changed) (zerop unknown))
             (list name chunker 'fresh nil))
            ((and (zerop gone) (zerop changed))
             (list name chunker 'unknown
                   (format "%d source(s) missing modification time" unknown)))
            (t (list name chunker 'stale
                     (string-join
                      (delq nil
                            (list (and (> changed 0) (format "%d changed" changed))
                                  (and (> gone 0) (format "%d gone" gone))
                                  (and (> unknown 0) (format "%d unknown" unknown))))
                      ", ")))))))))
   arc-index-plan))

(defun arc-freshness--summarize (report)
  "Return a compact summary of REPORT, or nil if all fresh.
Counts rather than names: stats and search callers need a compact status,
and appending six collection names made it unreadable.  `M-x arc-freshness'
has the detail."
  (let* ((n (lambda (state) (cl-count-if (lambda (r) (eq (nth 2 r) state)) report)))
         (stale (funcall n 'stale))
         (partial (funcall n 'partial))
         (unknown (funcall n 'unknown))
         (absent (funcall n 'absent)))
    (when (> (+ stale partial unknown absent) 0)
      (string-join
       (delq nil (list (and (> stale 0) (format "%d stale" stale))
                       (and (> partial 0) (format "%d partial" partial))
                       (and (> unknown 0) (format "%d unknown" unknown))
                       (and (> absent 0) (format "%d unindexed" absent))))
       " · "))))

(defun arc-freshness-summary ()
  "Return a compact summary of `arc-freshness-report', or nil if all fresh.
See `arc-freshness--summarize'."
  (arc-freshness--summarize (arc-freshness-report)))

;;;###autoload
(defun arc-freshness ()
  "Report which collections are stale, and why."
  (interactive)
  (let ((report (arc-freshness-report)))
    (with-current-buffer (get-buffer-create "*arc-freshness*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "arc freshness\n\n")
        (dolist (r report)
          (insert (format "  %-9s %-18s %s%s\n"
                          (nth 2 r) (nth 0 r) (or (nth 3 r) "")
                          (if (member (format "%s" (nth 1 r)) '("file" "org"))
                              "  (per-source hash)" "  (input provenance)")))))
      (goto-char (point-min))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(defcustom arc-freshness-cache-ttl 30
  "Seconds `arc-freshness-report-cached' may reuse a result.
Longer than `arc-index-stats-cache-ttl' because the per-source half
re-hashes every mutable source -- roughly 11,000 of the corpus's
~272,000 chunks -- and the status callers ask repeatedly.  Staleness
that is 30 seconds out of date is still staleness you can see."
  :type 'number :group 'arc)

(defvar arc--freshness-cache nil
  "Cached `arc-freshness-report' answer as (GENERATION TIMESTAMP REPORT), or nil.")

(defun arc-freshness-report-cached ()
  "Like `arc-freshness-report', but reuse a recent answer.
The per-source half of a freshness report re-hashes every mutable
source, and `arc-tool-stats' -- what an MCP client polls -- asks for it
on every call.  Caching the whole report rather than only the summary
keeps that surface from reading and hashing the mutable corpus each
time while leaving the report's shape unchanged.  Invalidated by
`arc-index--write-generation' or by `arc-freshness-cache-ttl' elapsing,
exactly as `arc-index-stats-cached' is."
  (unless (pcase arc--freshness-cache
            (`(,gen ,ts ,_)
             (and (eq gen arc-index--write-generation)
                  (> arc-freshness-cache-ttl 0)
                  (< (float-time (time-since ts)) arc-freshness-cache-ttl)))
            (_ nil))
    (setq arc--freshness-cache
          (list arc-index--write-generation (current-time) (arc-freshness-report))))
  (nth 2 arc--freshness-cache))

(provide 'arc-index)
;;; arc-index.el ends here
