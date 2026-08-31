;;; arc.el --- Local config-aware oracle for eminix -*- lexical-binding: t -*-

;; Copyright (C) 2024, 2025 Free Software Foundation, Inc.
;; Copyright (C) 2026 Scott Whitson

;; Author: Sergey Kostyaev <sskostyaev@gmail.com>
;; Maintainer: Scott Whitson
;; URL: http://github.com/scott-whitson/arc
;; Keywords: help local tools
;; Package-Requires: ((emacs "29.2") (llm "0.18.1") (async "1.9.8") (plz "0.9") (transient "0.13.5"))
;; Version: 0.1.0
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Changes:
;;
;; arc is a fork of ELISA by Sergey Kostyaev
;; (http://github.com/s-kostyaev/elisa).  Changes from upstream: the vector
;; backend was ported from sqlite-vss to sqlite-vec; the schema gained a
;; `sources' table carrying per-chunk source identity; web search, Apache
;; Tika and pandoc extraction were removed; org-roam node, NixOS option and
;; Home-Manager option source kinds were added; the answer UI was replaced;
;; the ellama-based chat/context path (its buffer, its session-aware prompt
;; rewriting, and the query that fed its context) was removed once arc
;; gained `arc-ask' and its own answer buffer, and the `ellama' dependency
;; was dropped entirely.

;;; Commentary:
;;
;; arc is a local, offline, config-aware oracle.  It answers Emacs, Elisp,
;; Linux, NixOS and org-roam questions grounded in this machine's actual
;; configuration, and cites sources you can jump to.

;;; Code:
(require 'cl-lib)
(require 'llm)
(require 'llm-provider-utils)
(require 'info)
(require 'async)
(require 'plz)
(require 'json)
(require 'sqlite)
(require 'arc-db)
;; `arc-scope' compiles a scope plist (collections, kinds, tags, a path
;; prefix) to the single SQL predicate that both the vector and FTS sides
;; of retrieval join against.  Required unconditionally here, like every
;; other module in this file, rather than left for a caller to require
;; separately -- `arc-scope-predicate' with no scope at all (nil) still
;; has to work, so unscoped `arc-ask' keeps behaving exactly as before.
(require 'arc-scope)
;; `arc-index' is required unconditionally here, not left for some external
;; setup function (`eminix/arc--setup', say) to require separately: nothing
;; in this file called into it before, so `arc-index-stats' -- which
;; `arc-ui-header-line' calls on every header-line redisplay -- was void
;; the moment anyone required only `arc' and never happened to call
;; `arc-reindex-all' (which lives in `arc-index.el') first.  The header
;; line's own `condition-case' turned that into a message
;; ("corpus unavailable (Symbol's function definition is void:
;; arc-index-stats)") instead of a crash, which is exactly why it went
;; unnoticed: nothing about that message looks like a missing require
;; unless you already suspect one.  It is acyclic: `arc-index' requires
;; `arc-db' and the chunkers, never `arc'.
(require 'arc-index)
;; arc-source's job -- rendering a citation as an org link, and (as of the
;; whole-branch fix round) registering the `nixopt:'/`hmopt:' link types as
;; a side effect of being loaded at all -- belongs to this file, which is
;; required unconditionally too.  `arc-index.el' used to require
;; `arc-source' as well, despite calling nothing in it; that accidentally
;; made it the ONLY thing in the real load path that registered the link
;; types, which would have silently broken the moment that unrelated
;; require was ever cleaned up.
(require 'arc-source)
(require 'arc-source-file) ; arc--file-list, for arc-parse-directory below
(require 'arc-source-info) ; arc-find-executable, injected into async workers
(require 'arc-ui)
(require 'arc-answer)

(defgroup arc nil
  "Local, offline, config-aware RAG oracle."
  :group 'tools)

(defconst arc--unmigrated-functions
  '(arc-parse-file
    arc-parse-directory
    arc-remove-collection
    arc-add-file-to-collection
    arc-recalculate-embeddings)
  "Functions still written against the pre-`sources' schema.
Task 4 replaced `data(path, hash, data)' and dropped the `files' table;
these have not been rewritten yet.  Task 11 owns that work and deletes
each guard as it goes.  `arc-parse-info-manual' was here too, until
Task 10 rewrote it as a pure function (see `arc-source-info.el') and
removed its guard.  The old query-and-context function that fed arc's
former chat buffer was here too, until Task 11 rewrote its query across
`data' and `sources' (see `arc--retrieve-rows' below) and removed its
guard -- it was the query path, and arc could not answer a question
while it stayed guarded; Task 6 later deleted that function and its
context-feeding helper outright, once `arc-ask' replaced the whole
answer path they fed and their only remaining purpose went with it.
The remaining five are collection-management and bulk-reindex
functions that `arc-index.el''s `arc-index-source' and
`arc-reindex-all' already supersede; migrating them is not required to
prove the corpus real or to answer a question, so they stay guarded.
This list may only shrink.")

(defun arc--not-yet-migrated (fn)
  "Signal that FN has not been ported to the `sources' schema."
  (user-error "arc: `%s' has not been migrated to the sources schema yet \
(Task 10/11 owns this); it would fail against the current tables" fn))

(defcustom arc-limit 5
  "Count quotes to pass into llm context for answer."
  :type 'natnum)

(defcustom arc-tar-executable "tar"
  "Path to tar executable."
  :type 'string)

(defcustom arc-semantic-split-function #'arc-split-by-paragraph
  "Function for semantic text split."
  :type 'function)

(defcustom arc-chat-prompt-template
  "Answer user query based on context above. \
If you can answer it partially do it. \
Provide list of open questions if any. \
Say \"not enough data\" if you can't answer user \
query based on provided context. User query:
%s"
  "Chat prompt template.
Contains instructions to LLM to be more focused on data in
context, be able to say \"I don't know\" etc. User query will be
inserted at the end and all this result prompt will be sent to
LLM together with context."
  :type 'string)

(defcustom arc-breakpoint-threshold-amount 0.4
  "Breakpoint threshold amount.
Increase it if you need decrease semantic split granularity."
  :type 'number)

(defcustom arc-reranker-enabled nil
  "Enable reranker to improve retrieving quality.
Reranker is a service to improve answer quality by mesure
relevance of text chunks to user query and sort chunks by
relevance.  See https://github.com/s-kostyaev/reranker for more
details."
  :type 'boolean)

(defcustom arc-reranker-url "http://127.0.0.1:8787/"
  "Reranker service url.
Reranker is a service to improve answer quality by mesure
relevance of text chunks to user query and sort chunks by
relevance.  See https://github.com/s-kostyaev/reranker for more
details."
  :type 'string)

(defcustom arc-reranker-similarity-threshold nil
  "Drop reranked chunks scoring below this similarity.
nil disables the check.  It used to default to 0, which reads like
\"off\" but is not: it silently dropped every negatively-scored chunk,
and `nil' is the value that actually means no filtering."
  :type '(choice (const nil) number)
  :group 'arc)

(defcustom arc-reranker-limit 20
  "Number of quotes for send to reranker."
  :type 'integer)

(defcustom arc-retrieval-max-distance nil
  "Cosine distance past which a retrieved chunk is treated as no match.
nil disables the check, which is the default on purpose: the spec puts
the threshold's *value* behind phase 5's eval harness, because picking
one by intuition is how a retrieval layer quietly starts refusing
answers it had.  The mechanism lives here so phase 5 sets a number
rather than building a feature."
  :type '(choice (const nil) number)
  :group 'arc)

(defcustom arc-enabled-collections '("builtin manuals")
  "Enabled collections for arc chat.
Used to default to `(\"builtin manuals\" \"external manuals\")', but
nothing in `arc-index-plan' has ever created an \"external manuals\"
collection -- it matches no `collections.name' row and silently
retrieves nothing, same failure mode as a stale directory-path entry."
  :type '(repeat string))

(defcustom arc-vault-collections '("vault")
  "Collections `arc-ask-vault' searches."
  :type '(repeat string)
  :group 'arc)

(defcustom arc-option-collections '("nix options" "hm options")
  "Collections `arc-ask-options' searches."
  :type '(repeat string)
  :group 'arc)

(defcustom arc-chat-models '("qwen2.5-coder:3b" "qwen2.5:7b")
  "Chat models `arc-toggle-chat-model' cycles through, in order.
The 3B model answers fast enough to keep a question conversational;
the 7B one is the practical ceiling on 14 GiB with no swap."
  :type '(repeat string)
  :group 'arc)

(defcustom arc-batch-embeddings-enabled nil
  "Enable batch embeddings if supported."
  :type 'boolean)

(defcustom arc-batch-size 300
  "Batch size to send to provider during batch embeddings calculation."
  :type 'integer)

(defun arc-data-embeddings-drop-table-sql ()
  "Generate sql for drop data embeddings table."
  "DROP TABLE IF EXISTS data_embeddings;")

(defun arc-avg (list)
  "Calculate arithmetic average value of LIST."
  (cl-loop for elem in list for count from 0
           summing elem into sum
           finally (return (/ sum (float count)))))

(defun arc-std-dev (lst)
  "Calculate standart deviation value of LST."
  (let ((avg (arc-avg lst))
	(len (length lst)))
    (sqrt (/ (cl-reduce
	      #'+
	      (mapcar
	       (lambda (x) (expt (- x avg) 2))
	       lst))
	     len))))

(defun arc-calculate-threshold (k distances)
  "Calculate breakpoint threshold for DISTANCES based on K standard deviations."
  (+ (arc-avg distances) (* k (arc-std-dev distances))))

(defun arc-string-empty-p (s)
  "Check if string S contain only spacing."
  (length= (string-trim s) 0))

(defun arc-filter-strings (chunks)
  "Filter out empty CHUNKS."
  (cl-remove-if #'arc-string-empty-p chunks))

(defun arc-embeddings (chunks)
  "Calculate embeddings for CHUNKS.
Return list of vectors."
  (let ((provider arc-embeddings-provider))
    (if (and arc-batch-embeddings-enabled
	     (member 'embeddings-batch (llm-capabilities provider)))
	(let ((batches (seq-partition chunks arc-batch-size)))
	  (flatten-list (mapcar (lambda (batch) (llm-batch-embeddings provider (vconcat batch)))
				batches)))
      (mapcar (lambda (chunk) (llm-embedding provider chunk)) chunks))))

(defun arc--scoped-cte (scope)
  "Return the `scoped' CTE restricting `data' rows to SCOPE."
  (format "scoped AS (
  SELECT d.id AS id
  FROM data d JOIN sources s ON s.id = d.source_id
  WHERE %s
)" (arc-scope-predicate scope)))

(defun arc--semantic-cte (scope vec)
  "Return the semantic-search CTE for SCOPE against embedding VEC.
Which of the two shapes this returns is `arc-scope-vector-plan's
decision; see its docstring for why either can be the correct one."
  (pcase-let ((`(,strategy . ,k) (arc-scope-vector-plan scope)))
    (if (eq strategy 'brute)
        ;; Exact within the scope, cost proportional to the scope: SQLite
        ;; only evaluates the distance on rows the join admits.
        (format "semantic_search AS (
  SELECT e.rowid AS id,
         RANK () OVER (ORDER BY vec_distance_cosine(e.embedding, %s) ASC) AS rank
  FROM data_embeddings e JOIN scoped ON scoped.id = e.rowid
  ORDER BY vec_distance_cosine(e.embedding, %s) ASC
  LIMIT %d
)" vec vec arc-knn-candidates)
      (format "vector_search AS (
  SELECT rowid AS id, distance
  FROM data_embeddings
  WHERE embedding MATCH %s AND k = %d
  ORDER BY distance ASC
),
semantic_search AS (
  SELECT v.id, RANK () OVER (ORDER BY v.distance ASC) AS rank
  FROM vector_search v JOIN scoped ON scoped.id = v.id
  ORDER BY v.distance ASC
  LIMIT %d
)" vec k arc-knn-candidates))))

(defun arc--find-similar (text scope)
  "Return the SQL selecting chunks in SCOPE similar to TEXT.
SCOPE is a scope plist (see `arc-scope'); nil means the whole corpus.
The scope reaches the search rather than filtering its results: both
the vector side and the FTS side join against the `scoped' CTE."
  ;; For collection scoping specifically, the previous version's inlined
  ;; `rowid IN (...)' filter was already effective in practice: SQLite
  ;; inlines a CTE referenced exactly once and pushes that IN-list into
  ;; vec0's scan, so the old "unscoped k=40 KNN, filter after" query text
  ;; ran as an already-scoped one.  Confirmed by forcing that CTE to
  ;; MATERIALIZED, which defeats the inlining and reproduces the
  ;; "no semantic candidates" failure the flattening was quietly avoiding.
  ;; That correctness was an accident of query shape, not a designed
  ;; property -- a single future edit referencing the CTE a second time
  ;; would have silently unscoped the search with no error -- and it only
  ;; ever covered collections: a rowid IN-list has no way to express
  ;; `:kinds', `:tags' or `:path-prefix', which did not exist in any form
  ;; before this task.  The `scoped' CTE joined explicitly into both arms
  ;; is what makes scoping true regardless of what the planner chooses.
  (let ((vec (arc-vector-to-sqlite
              (llm-embedding arc-embeddings-provider text))))
    (format "WITH
%s,
%s,
keyword_search AS (
  SELECT f.rowid AS id, RANK () OVER (ORDER BY bm25(data_fts) ASC) AS rank
  FROM data_fts f JOIN scoped ON scoped.id = f.rowid
  WHERE data_fts MATCH '%s'
  ORDER BY bm25(data_fts) ASC
  LIMIT %d
),
hybrid_search AS (
  SELECT
    COALESCE(semantic_search.id, keyword_search.id) AS id,
    COALESCE(1.0 / (60 + semantic_search.rank), 0.0) +
    COALESCE(1.0 / (60 + keyword_search.rank), 0.0) AS score
  FROM semantic_search
  FULL OUTER JOIN keyword_search ON semantic_search.id = keyword_search.id
  ORDER BY score DESC
  LIMIT %d
)
SELECT hybrid_search.id FROM hybrid_search;"
            (arc--scoped-cte scope)
            (arc--semantic-cte scope vec)
            (arc-fts-query text)
            arc-knn-candidates
            (arc-get-limit))))

(defun arc-find-similar (text scope on-done &optional on-error)
  "Find chunks in SCOPE similar to TEXT, asynchronously.
SCOPE is a scope plist; nil searches everything.  Evaluate ON-DONE
with the resulting SQL, or ON-ERROR with an error symbol and message
when retrieval itself fails -- most commonly an unreachable embedding
endpoint, since building the query embeds TEXT."
  (message "searching in collected data")
  (arc--async-do
   (lambda () (arc--find-similar text scope))
   on-done on-error))

(defun arc--split-by (func)
  "Split buffer content to list by FUNC."
  (let ((pt (point-min))
	(result nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
	(funcall func)
	(push (buffer-substring-no-properties pt (point)) result)
	(setq pt (point)))
      (nreverse (cl-remove-if #'string-empty-p result)))))

(defun arc-split-by-sentence ()
  "Split byffer to list of sentences."
  (arc--split-by #'forward-sentence))

(defun arc-split-by-paragraph ()
  "Split buffer to list of paragraphs."
  (arc--split-by #'forward-paragraph))

(defun arc-dot-product (v1 v2)
  "Calculate the dot produce of vectors V1 and V2."
  (let ((result 0))
    (dotimes (i (length v1))
      (setq result (+ result (* (aref v1 i) (aref v2 i)))))
    result))

(defun arc-magnitude (v)
  "Calculate magnitude of vector V."
  (let ((sum 0))
    (dotimes (i (length v))
      (setq sum (+ sum (* (aref v i) (aref v i)))))
    (sqrt sum)))

(defun arc-cosine-similarity (v1 v2)
  "Calculate the cosine similarity of V1 and V2.
The return is a floating point number between 0 and 1, where the
closer it is to 1, the more similar it is."
  (let ((dot-product (arc-dot-product v1 v2))
        (v1-magnitude (arc-magnitude v1))
        (v2-magnitude (arc-magnitude v2)))
    (if (and v1-magnitude v2-magnitude)
        (/ dot-product (* v1-magnitude v2-magnitude))
      0)))

(defun arc-cosine-distance (v1 v2)
  "Calculate cosine-distance between V1 and V2."
  (- 1 (arc-cosine-similarity v1 v2)))

(defun arc--similarities (list)
  "Calculate cosine similarities between neighbour elements in LIST."
  (let ((head (car list))
	(tail (cdr list))
	(result nil))
    (while tail
      (push (arc-cosine-similarity head (car tail)) result)
      (setq head (car tail))
      (setq tail (cdr tail)))
    (nreverse result)))

(defun arc--distances (list)
  "Calculate cosine distances between neighbour elements in LIST."
  (let ((head (car list))
	(tail (cdr list))
	(result nil))
    (while tail
      (push (arc-cosine-distance head (car tail)) result)
      (setq head (car tail))
      (setq tail (cdr tail)))
    (nreverse result)))

(defun arc-split-semantically (&rest args)
  "Split buffer data semantically.
ARGS contains keys for fine control.

:function FUNC -- FUNC is a function for split buffer into chunks.

:threshold-amount K -- K is a breakpoint threshold amount.

than T, it will be packed into single semantic chunk."
  (if-let* ((func (or (plist-get args :function) arc-semantic-split-function))
	    (k (or (plist-get args :threshold-amount) arc-breakpoint-threshold-amount))
	    (chunks (arc-filter-strings (funcall func)))
	    (embeddings (arc-embeddings chunks))
	    (distances (arc--distances embeddings))
	    (threshold (arc-calculate-threshold k distances))
	    (current (car chunks))
	    (tail (cdr chunks)))
      (let* ((result nil))
        (dolist (el distances)
          (if (<= el threshold)
	      (setq current (concat current (car tail)))
	    (push current result)
	    (setq current (car tail)))
	  (setq tail (cdr tail)))
	(push current result)
	(cl-remove-if
	 #'string-empty-p
	 (mapcar (lambda (s)
		   (if s
		       (string-trim s)
		     ""))
		 (nreverse result))))
    (list (buffer-substring-no-properties (point-min) (point-max)))))

(defun arc-parse-file (collection-id path &optional force)
  "Parse file PATH for COLLECTION-ID.
When FORCE parse even if already parsed."
  (arc--not-yet-migrated 'arc-parse-file)
  (let* ((opened (get-file-buffer path))
	 (buf (or opened (find-file-noselect path t t)))
	 (hash (secure-hash 'sha256 buf))
	 (prev-hash (caar (sqlite-select
			   (arc-db)
			   (format "SELECT hash FROM files WHERE path = '%s';"
				   (arc-sqlite-escape path))))))
    (when (or force
	      (not prev-hash)
	      (not (string-equal hash prev-hash)))
      (with-current-buffer buf
	;; Opened rawfile (unibyte); decode to UTF-8 multibyte so non-ASCII
	;; content (em-dashes etc.) embeds cleanly — llm's json-serialize
	;; rejects raw unibyte bytes (wrong-type-argument json-value-p).
	(unless enable-multibyte-characters
	  (decode-coding-region (point-min) (point-max) 'utf-8)
	  (set-buffer-multibyte t))
	(let ((chunks (arc-split-semantically))
	      (old-row-ids
	       (flatten-tree (sqlite-select
			      (arc-db)
			      (format "SELECT rowid FROM data WHERE path = '%s';"
				      (arc-sqlite-escape path)))))
	      (row-ids nil)
	      (kind-id (caar (sqlite-select
			      (arc-db)
			      "SELECT rowid FROM kinds WHERE name = 'file';"))))
	  ;; remove old data
	  (when prev-hash
	    (sqlite-execute
	     (arc-db)
	     (format "DELETE FROM files WHERE path = '%s';"
		     (arc-sqlite-escape path))))
	  ;; add new data
          (dolist (text chunks)
            (let* ((hash (secure-hash 'sha256 text))
		   (rowid
		    (if-let ((rowid (caar (sqlite-select
					   (arc-db)
					   (format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';"
						   kind-id collection-id
						   (arc-sqlite-escape path) hash)))))
			(progn
			  (push rowid row-ids)
			  nil)
		      (sqlite-execute
		       (arc-db)
		       (format
			"INSERT INTO data(kind_id, collection_id, path, hash, data) VALUES (%s, %s, '%s', '%s', '%s');"
			kind-id collection-id
			(arc-sqlite-escape path) hash (arc-sqlite-escape text)))
		      (caar (sqlite-select
			     (arc-db)
			     (format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';"
				     kind-id collection-id
				     (arc-sqlite-escape path) hash))))))
	      (when rowid
		(sqlite-execute
		 (arc-db)
		 (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%s, %s);"
			 rowid (arc-vector-to-sqlite
				(llm-embedding arc-embeddings-provider text))))
		(sqlite-execute
		 (arc-db)
		 (format "INSERT INTO data_fts(rowid, data) VALUES (%s, '%s');"
			 rowid (arc-sqlite-escape text)))
		(push rowid row-ids))))
	  ;; remove old data
	  (when row-ids
	    (let ((delete-rows (cl-remove-if (lambda (id)
					       (cl-find id row-ids))
					     old-row-ids)))
	      (arc--delete-data delete-rows)))
	  ;; save hash to files table
	  (sqlite-execute
	   (arc-db)
	   (format "INSERT INTO files (path, hash) VALUES ('%s', '%s');"
		   (arc-sqlite-escape path) hash)))))
    ;; kill buffer if it was not open before parsing
    (when (not opened)
      (kill-buffer buf))))

(defun arc--delete-from-table (table ids)
  "Delete IDS from TABLE."
  (sqlite-execute
   (arc-db)
   (format "DELETE FROM %s WHERE rowid IN %s;"
	   table
	   (arc-sqlite-format-int-list ids))))

(defun arc--delete-data (ids)
  "Delete data with IDS."
  (arc--delete-from-table "data_fts" ids)
  (arc--delete-from-table "data_embeddings" ids)
  (arc--delete-from-table "data" ids))

(defun arc-parse-directory (dir)
  "Parse DIR as new collection syncronously."
  (arc--not-yet-migrated 'arc-parse-directory)
  (setq dir (expand-file-name dir))
  (let* ((collection-id (progn
			  (sqlite-execute
			   (arc-db)
			   (format
			    "INSERT INTO collections (name) VALUES ('%s') ON CONFLICT DO NOTHING;"
			    (arc-sqlite-escape dir)))
			  (caar (sqlite-select
				 (arc-db)
				 (format
				  "SELECT rowid FROM collections WHERE name = '%s';"
				  (arc-sqlite-escape dir))))))
	 (files (arc--file-list dir))
	 (delete-ids (flatten-tree
		      (sqlite-select
		       (arc-db)
		       (format
			"SELECT rowid FROM data WHERE collection_id = %d AND path NOT IN %s;"
			collection-id
			(arc-sqlite-format-string-list files))))))
    (arc--delete-data delete-ids)
    (dolist (file files)
      (message "parsing %s" file)
      (arc-parse-file collection-id file))))

;;;###autoload
(defun arc-async-parse-directory (dir)
  "Parse DIR as new collection asyncronously."
  (interactive "DSelect directory: ")
  (arc--async-do (lambda ()
		     (arc-parse-directory
		      (expand-file-name dir)))))

(defun arc-fts-query (prompt)
  "Return fts match query for PROMPT."
  (thread-last
    prompt
    (string-trim)
    (downcase)
    (string-replace "-" " ")
    (replace-regexp-in-string "[^[:alnum:] ]+" "")
    (string-trim)
    (replace-regexp-in-string "[[:space:]]+" " OR ")))

(defun arc--rerank-request (prompt ids)
  "Generate rerank request body for PROMPT and IDS."
  (let ((docs
	 (mapcar
	  (lambda (row)
	    (let ((id (cl-first row))
		  (text (cl-second row)))
	      `(("id" . ,id) ("text" . ,text))))
	  (sqlite-select
	   (arc-db)
	   (format
	    ;; `data' has had no `data' column since Task 4 -- the chunk text
	    ;; column is `chunk'.  This raised `sqlite-error' whenever the
	    ;; reranker actually ran; nothing caught it because
	    ;; `arc-reranker-enabled' defaults to nil.
	    "SELECT rowid, chunk FROM data WHERE rowid IN %s;"
	    (arc-sqlite-format-int-list ids))))))
    (json-encode `(("query" . ,prompt)
		   ("documents" . ,docs)))))

(defun arc--do-rerank-request (prompt ids)
  "Call rerank service for PROMPT and IDS."
  (when ids
    (seq-into
     (alist-get 'data
		(plz 'post (format "%s/api/v1/rerank"
				   (string-remove-suffix "/" arc-reranker-url))
		  :headers `(("Content-Type" . "application/json"))
		  :body-type 'text
		  :body (arc--rerank-request prompt ids)
		  :as #'json-read))
     'list)))

(defun arc-rerank (prompt ids)
  "Rerank IDS according to PROMPT and return top `arc-limit' IDS."
  (let ((data (arc--do-rerank-request prompt ids)))
    (mapcar (lambda (elt)
	      (alist-get 'id elt))
	    (take arc-limit
		  (if arc-reranker-similarity-threshold
		      (cl-remove-if (lambda (obj)
				      (< (alist-get 'similarity obj)
					 arc-reranker-similarity-threshold))
				    data)
		    data)))))

(defun arc-get-limit ()
  "Limit for arc hybrid search."
  (if arc-reranker-enabled
      arc-reranker-limit
    arc-limit))

(defun arc--retrieve-rows (ids)
  "Return a (KIND PATH INFO-NODE ORG-ID OPTION-NAME CHUNK LINE-START
LINE-END TITLE) row per id in IDS.
IDS are `data' row ids (the same rowids `data_embeddings' and
`data_fts' use).  Joins across to `sources' for whichever locator
column KIND actually uses; the other three come back nil.  Returns
nil, rather than erroring, when IDS is empty -- an empty SQL IN-list
is invalid syntax."
  (when ids
    (sqlite-select
     (arc-db)
     (format
      "SELECT s.kind, s.path, s.info_node, s.org_id, s.option_name, d.chunk,
       d.line_start, d.line_end, d.title
FROM data AS d
JOIN sources AS s ON s.id = d.source_id
WHERE d.id IN %s;"
      (arc-sqlite-format-int-list ids)))))

(defun arc-row-to-source (row)
  "Convert an `arc--retrieve-rows' ROW into a source plist.
The plist is the shape `arc-source-link' and `arc-source-label'
consume, carrying the chunk text and its line range alongside so a
citation can name the line it actually came from."
  (pcase-let ((`(,kind ,path ,info-node ,org-id ,option-name ,chunk ,ls ,le ,title) row))
    (list :kind kind :path path :info-node info-node :org-id org-id
          :option-name option-name :title title
          :line-start ls :line-end le :chunk chunk)))

(defun arc--retrieve-ids (query prompt)
  "Return the data ids QUERY selects, reranked against PROMPT if enabled."
  (let ((raw (flatten-tree (sqlite-select (arc-db) query))))
    (if arc-reranker-enabled
        (arc-rerank prompt raw)
      (take arc-limit raw))))

;; `arc-ui--last-scope' is defined with `defvar-local' in arc-ui.el as of
;; Task 9.  This forward declaration lets this task's `arc-ask' set it and
;; byte-compile clean on its own; remove it once Task 9 lands the real one.
(defvar arc-ui--last-scope)

(defun arc-ask-normalize-scope (scope)
  "Return SCOPE as a scope plist.
Accepts three shapes, because `arc-ask' is public and its documented
second argument used to be a plain list of collection names:
  nil                     -- `arc-enabled-collections'
  (\"vault\" \"dotfiles\")    -- those collections
  (:collections (\"vault\")) -- a scope plist, used as-is
A list of strings is unambiguous here: a scope plist's first element
is always a keyword."
  (cond
   ((null scope) (arc-scope-from-collections arc-enabled-collections))
   ((keywordp (car scope)) scope)
   (t (arc-scope-from-collections scope))))

;;;###autoload
(defun arc-ask (question &optional scope heading)
  "Ask arc QUESTION, grounded in SCOPE, rendering into the arc buffer.
QUESTION is what is sent to retrieval and to the model.  HEADING, when
non-nil, is what is rendered as the answer's heading and recorded as
`arc-ui--last-question' instead of QUESTION.

A caller that folds earlier context into QUESTION -- `arc-ui-follow-up'
does, so the model sees the earlier exchange -- passes its own plain,
one-line follow-up text as HEADING, so the buffer heading (and
anything a later `arc-ui-reask' resends) stays that one line rather
than the whole quoted exchange QUESTION carries.  `arc-ui-begin-answer'
enforces that whatever ends up as the heading is a single line, no
matter which of QUESTION or HEADING that turns out to be.

Both retrieval failure (an unreachable embedding endpoint, most
commonly) and model failure render into the answer buffer rather than
leaving it invisible -- retrieval failure never even reaches
`arc-answer-request', which is why it needs an error path of its own
here rather than reusing that function's.

SCOPE is a scope plist (see `arc-scope'), a plain list of collection
names, or nil for `arc-enabled-collections'.  It is normalised by
`arc-ask-normalize-scope'.

When retrieval returns nothing at all, the model is never called: the
buffer gets `arc-answer-refusal' instead.  Handing an empty context
block to a chat model and hoping its prompt talks it out of answering
is exactly the failure the spec's refusal contract exists to prevent."
  (interactive "sAsk arc: ")
  (let* ((scope (arc-ask-normalize-scope scope))
         (display (or heading question)))
    (arc-find-similar
     question scope
     (lambda (query)
       (let* ((ids (arc--retrieve-ids query question))
              (sources (mapcar #'arc-row-to-source (arc--retrieve-rows ids)))
              (answer (arc-ui-begin-answer display)))
         (pop-to-buffer (arc-ui-buffer))
         (setq arc-ui--last-question display)
         (setq arc-ui--last-sources sources)
         (setq arc-ui--last-scope scope)
         (if (null sources)
             (arc-ui-stream-answer answer (arc-answer-refusal scope))
           (arc-answer-request
            question sources
            (lambda (text) (arc-ui-stream-answer answer text))
            (lambda (text)
              (arc-ui-stream-answer answer text)
              (arc-ui-render-sources answer sources))
            (lambda (_sym msg)
              (arc-ui-stream-answer answer (format "arc: request failed: %s" msg)))))))
     (lambda (_sym msg)
       (let ((answer (arc-ui-begin-answer display)))
         (pop-to-buffer (arc-ui-buffer))
         (setq arc-ui--last-question display)
         (setq arc-ui--last-sources nil)
         (setq arc-ui--last-scope scope)
         (arc-ui-stream-answer answer (format "arc: retrieval failed: %s" msg)))))))

;;;###autoload
(defun arc-ask-vault (question)
  "Ask arc QUESTION against the org-roam vault only."
  (interactive "sAsk arc (vault): ")
  (arc-ask question (arc-scope :collections arc-vault-collections)))

;;;###autoload
(defun arc-ask-options (question)
  "Ask arc QUESTION against the NixOS and Home-Manager options only."
  (interactive "sAsk arc (options): ")
  (arc-ask question (arc-scope :collections arc-option-collections)))

;;;###autoload
(defun arc-toggle-chat-model ()
  "Switch `arc-chat-provider' to the next model in `arc-chat-models'.
A model not in the list -- or an `arc-chat-provider' the user has set
to something other than an Ollama provider -- is not silently worked
around: the first case starts the cycle over, the second is a
`user-error' naming the variable, because rebuilding an arbitrary
provider is not this command's business."
  (interactive)
  (unless (cl-typep arc-chat-provider 'llm-ollama)
    (user-error "arc: `arc-chat-provider' is not an Ollama provider; \
`arc-toggle-chat-model' cannot switch its model"))
  (let* ((current (llm-ollama-chat-model arc-chat-provider))
         (rest (cdr (member current arc-chat-models)))
         (next (or (car rest) (car arc-chat-models))))
    (setf (llm-ollama-chat-model arc-chat-provider) next)
    (message "arc: chat model is now %s" next)
    next))

;;;###autoload
(defvar arc-command-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "i") #'arc-ask)
    (define-key m (kbd "n") #'arc-ask-vault)
    (define-key m (kbd "o") #'arc-ask-options)
    (define-key m (kbd "m") #'arc-toggle-chat-model)
    (define-key m (kbd "R") #'arc-reindex-all)
    (define-key m (kbd "c") #'arc-reindex-cancel)
    m)
  "Prefix map for arc's entry points; bind it where you like.
arc is a library and does not claim a global key for you -- bind this
map to whatever prefix you like, e.g.:

  (keymap-set global-map \"C-c i\" arc-command-map)")

;; arc--info-valid-p, arc-get-builtin-manuals, arc-get-external-manuals and
;; arc-parse-info-manual moved to arc-source-info.el (Task 10).
;; arc-parse-builtin-manuals, arc-parse-external-manuals and
;; arc-parse-all-manuals are gone with them: their entire job was calling
;; the old two-argument arc-parse-info-manual to write a collection
;; directly to the database, which is precisely the SQL Task 11's indexer
;; now owns.  Task 11 rebuilds the real entry point on `arc-info-sources'.

(defun arc--reopen-db ()
  "Reopen database."
  (let ((db (sqlite-open (file-name-concat arc-db-directory "arc.sqlite"))))
    (arc--init-db db)
    (setq arc--db db)))

(defun arc--async-do (func &optional on-done on-error)
  "Do FUNC asyncronously.
Call ON-DONE with FUNC's return value once it completes successfully.

FUNC runs inside a forked Emacs process (`async-start').  An error FUNC
signals there does not reach ON-DONE, or this function's own caller, by
itself: `async-handle-result' (async.el) re-signals it from inside the
parent's process sentinel before ever calling the finish function
below, which Emacs reports as an unhandled \"Error in process
sentinel\" and nothing else -- no callback of any kind runs.  So FUNC
is wrapped in `condition-case' here, inside the child, turning an
error into an ordinary tagged return value instead of ever reaching
that path; when the tag says FUNC failed, ON-ERROR (if given) is
called with the error symbol and message, exactly like an ordinary
callback.  With no ON-ERROR given, the failure is reported with
`message' instead of being silently dropped, matching what every
caller of this function got before ON-ERROR existed."
  (let* ((command real-this-command)
	 (reporter (make-progress-reporter (if command
					       (prin1-to-string command)
					     "arc async processing")))
	 (timer (run-at-time t 0.2 (lambda () (progress-reporter-update reporter)))))
    (async-start `(lambda ()
		    ,(async-inject-variables "arc-embeddings-provider")
		    ,(async-inject-variables "arc-db-directory")
		    ,(async-inject-variables "arc-find-executable")
		    ,(async-inject-variables "arc-tar-executable")
		    ,(async-inject-variables "arc-batch-embeddings-enabled")
		    ,(async-inject-variables "arc-batch-size")
		    ,(async-inject-variables "arc-semantic-split-function")
		    ,(async-inject-variables "arc-breakpoint-threshold-amount")
		    ,(async-inject-variables "arc-reranker-enabled")
		    ,(async-inject-variables "arc-sqlite-vec-path")
		    ,(async-inject-variables "load-path")
		    ,(async-inject-variables "Info-directory-list")
		    (require 'arc)
		    (condition-case arc--async-do-err
			(list :arc-ok (,func))
		      (error (list :arc-error (car arc--async-do-err)
				   (error-message-string arc--async-do-err)))))
		 (lambda (res)
		   (cancel-timer timer)
		   (progress-reporter-done reporter)
		   (arc-close-db)
		   (arc--reopen-db)
		   (pcase res
		     (`(:arc-error ,sym ,msg)
		      (if on-error
			  (funcall on-error sym msg)
			(message "arc: async task failed (%s): %s" sym msg)))
		     (`(:arc-ok ,value)
		      (when on-done (funcall on-done value))))))))

;; arc-async-parse-builtin-manuals, arc-async-parse-external-manuals and
;; arc-async-parse-all-manuals are gone along with the sync functions they
;; wrapped (see the note above arc--reopen-db).

;;;###autoload
(defun arc-reparse-current-collection ()
  "Incrementally reparse current directory collection.
It does nothing if buffer file not inside one of existing collections."
  (interactive)
  (when-let* ((collections (flatten-tree
			    (sqlite-select
			     (arc-db)
			     "SELECT name FROM collections;")))
	      (dirs (cl-remove-if-not #'file-directory-p collections))
	      (file (buffer-file-name))
	      (collection (cl-find-if (lambda (dir)
					(file-in-directory-p file dir))
				      dirs)))
    (arc-async-parse-directory collection)))

;;;###autoload
(defun arc-disable-collection (&optional collection)
  "Disable COLLECTION."
  (interactive)
  (let ((col (or collection
		 (completing-read
		  "Disable collection: "
		  arc-enabled-collections))))
    (setq arc-enabled-collections
	  (cl-remove col arc-enabled-collections :test #'string=))))

;;;###autoload
(defun arc-disable-all-collections ()
  "Disable all collections."
  (interactive)
  (mapc #'arc-disable-collection arc-enabled-collections))

;;;###autoload
(defun arc-enable-collection (&optional collection)
  "Enable COLLECTION."
  (interactive)
  (let ((col (or collection
		 (completing-read
		  "Enable collection: "
		  (cl-remove-if
		   (lambda (c)
		     (cl-find c arc-enabled-collections :test #'string=))
		   (flatten-tree
		    (sqlite-select
		     (arc-db)
		     "SELECT name FROM collections;")))))))
    (push col arc-enabled-collections)))

;;;###autoload
(defun arc-enable-all-collections ()
  "Enable all collections."
  (interactive)
  (let ((all-collections
	 (flatten-tree
	  (sqlite-select
	   (arc-db)
	   "SELECT DISTINCT name FROM collections;"))))
    (setq arc-enabled-collections
	  (cl-set-difference all-collections arc-enabled-collections :test #'string=))
    (mapc #'arc-enable-collection all-collections)))

;;;###autoload
(defun arc-create-empty-collection (&optional collection)
  "Create new empty COLLECTION."
  (interactive "sNew collection name: ")
  (save-window-excursion
    (sqlite-execute
     (arc-db)
     (format
      "INSERT INTO collections (name) VALUES ('%s') ON CONFLICT DO NOTHING;"
      (arc-sqlite-escape collection)))))

;;;###autoload
(defun arc-add-file-to-collection (file collection)
  "Add FILE to COLLECTION."
  (interactive
   (list
    (read-file-name "File: ")
    (completing-read
     "Enable collection: "
     (flatten-tree
      (sqlite-select
       (arc-db)
       "SELECT name FROM collections;")))))
  (arc--not-yet-migrated 'arc-add-file-to-collection)
  (let ((collection-id (caar (sqlite-select
			      (arc-db)
			      (format
			       "SELECT rowid FROM collections WHERE name = '%s';"
			       (arc-sqlite-escape collection))))))
    (arc--async-do (lambda () (arc-parse-file collection-id file)))))

;;;###autoload
(defun arc-remove-collection (&optional collection)
  "Remove COLLECTION."
  (interactive)
  (arc--not-yet-migrated 'arc-remove-collection)
  (let* ((col (or collection
		  (completing-read
		   "Enable collection: "
		   (flatten-tree
		    (sqlite-select
		     (arc-db)
		     "SELECT name FROM collections;")))))
	 (collection-id (caar (sqlite-select
			       (arc-db)
			       (format
				"SELECT rowid FROM collections WHERE name = '%s';"
				(arc-sqlite-escape col)))))
	 (delete-ids (flatten-tree
		      (sqlite-select
		       (arc-db)
		       (format
			"SELECT rowid FROM data WHERE collection_id = %d;"
			collection-id)))))
    (arc-disable-collection col)
    (when (file-directory-p col)
      (let ((files
	     (flatten-tree
	      (sqlite-select
	       (arc-db)
	       (format
		"SELECT DISTINCT path FROM data WHERE collection_id = %d;"
		collection-id)))))
	(sqlite-execute
	 (arc-db)
	 (format
	  "DELETE FROM files WHERE path IN %s;"
	  (arc-sqlite-format-string-list files)))))
    (arc--delete-data delete-ids)
    (sqlite-execute
     (arc-db)
     (format
      "DELETE FROM collections WHERE rowid = %d;"
      collection-id))))

(defun arc-recalculate-embeddings ()
  "Recalculate and save new embeddings after embedding provider change."
  (arc--not-yet-migrated 'arc-recalculate-embeddings)
  (sqlite-execute (arc-db) "DELETE FROM data WHERE data = '';") ;; remove rows without data
  (let* ((data-rows (sqlite-select (arc-db) "SELECT rowid, data FROM data;"))
	 (texts (mapcar #'cadr data-rows))
	 (rowids (mapcar #'car data-rows))
	 (embeddings (arc-embeddings texts))
	 (len (length rowids))
	 (i 0))
    ;; Recreate embeddings table
    (sqlite-execute (arc-db) (arc-data-embeddings-drop-table-sql))
    (sqlite-execute (arc-db) (arc-data-embeddings-create-table-sql))
    ;; Recalculate embeddings
    (with-sqlite-transaction (arc-db)
      (while (< i len)
	(let ((rowid (nth i rowids))
	      (embedding (nth i embeddings)))
	  (sqlite-execute
	   (arc-db)
	   (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%s, %s);"
		   rowid (arc-vector-to-sqlite embedding)))
	  (setq i (1+ i)))))))

;;;###autoload
(defun arc-async-recalculate-embeddings ()
  "Recalculate embeddings asynchronously."
  (interactive)
  (arc--async-do 'arc-recalculate-embeddings))

(provide 'arc)
;;; arc.el ends here.
