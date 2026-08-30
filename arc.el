;;; arc.el --- Local config-aware oracle for eminix -*- lexical-binding: t -*-

;; Copyright (C) 2024, 2025 Free Software Foundation, Inc.
;; Copyright (C) 2026 Scott Whitson

;; Author: Sergey Kostyaev <sskostyaev@gmail.com>
;; Maintainer: Scott Whitson
;; URL: http://github.com/scott-whitson/arc
;; Keywords: help local tools
;; Package-Requires: ((emacs "29.2") (ellama "0.11.2") (llm "0.18.1") (async "1.9.8") (plz "0.9"))
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
;; Home-Manager option source kinds were added; the answer UI was replaced.

;;; Commentary:
;;
;; arc is a local, offline, config-aware oracle.  It answers Emacs, Elisp,
;; Linux, NixOS and org-roam questions grounded in this machine's actual
;; configuration, and cites sources you can jump to.

;;; Code:
(require 'ellama)
(require 'llm)
(require 'llm-provider-utils)
(require 'info)
(require 'async)
(require 'plz)
(require 'json)
(require 'sqlite)
(require 'arc-db)
;; arc-source's job -- rendering a citation as an org link, and (as of the
;; whole-branch fix round) registering the `nixopt:'/`hmopt:' link types as
;; a side effect of being loaded at all -- belongs to this file, which is
;; required unconditionally before any entry point (`eminix/arc--setup')
;; goes on to require `arc-index'.  `arc-index.el' used to require
;; `arc-source' too, despite calling nothing in it; that accidentally made
;; it the ONLY thing in the real load path that registered the link
;; types, which would have silently broken the moment that unrelated
;; require was ever cleaned up.
(require 'arc-source)
(require 'arc-source-file) ; arc--file-list, for arc-parse-directory below
(require 'arc-source-info) ; arc-find-executable, injected into async workers

(defgroup arc nil
  "RAG implementation for `ellama'."
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
removed its guard.  `arc-retrieve-ask' was here too, until Task 11
rewrote its query across `data' and `sources' (see `arc--retrieve-rows'
and `arc--add-context-row' below) and removed its guard -- it is the
query path, and arc cannot answer a question while it stays guarded.
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

(defcustom arc-prompt-rewriting-enabled t
  "Enable prompt rewriting for better retrieving."
  :type 'boolean)

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

(defcustom arc-rewrite-prompt-template
  "<INSTRUCTIONS>
You are professional search agent. With given context and user
prompt you need to create new prompt for search **IN THE SAME
LANGUAGE AS ORIGINAL USER PROMPT**. It should be concise and
useful without additional context. Response with prompt only. You
should replace all words like 'this' or 'it' to its values to
make search successful. If user prompt contains question your
prompt should also be in form of question.
 </INSTRUCTIONS>
<EXAMPLE>
 - What is pony?
 - Pony is ...
 - How to buy it?

How to buy a pony?
</EXAMPLE>
<USER_PROMPT>
%s
</USER_PROMPT>"
  "Prompt template for prompt rewriting."
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

(defcustom arc-reranker-similarity-threshold 0
  "Reranker similarity threshold.
If set, all quotes with similarity less than threshold will be filtered out."
  :type 'number)

(defcustom arc-reranker-limit 20
  "Number of quotes for send to reranker."
  :type 'integer)

(defcustom arc-enabled-collections '("builtin manuals")
  "Enabled collections for arc chat.
Used to default to `(\"builtin manuals\" \"external manuals\")', but
nothing in `arc-index-plan' has ever created an \"external manuals\"
collection -- it matches no `collections.name' row and silently
retrieves nothing, same failure mode as a stale directory-path entry."
  :type '(repeat string))

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

(defun arc--find-similar (text collections)
  "Find similar to TEXT results in COLLECTIONS.
Return sqlite query.  For asyncronous execution."
  (let* ((rowids (flatten-tree
		  (sqlite-select
		   (arc-db)
		   (format "SELECT rowid FROM data WHERE collection_id IN
 (
SELECT rowid FROM collections WHERE name IN %s
);"
			   (arc-sqlite-format-string-list collections)))))
	 (query (format "WITH
vector_search AS (
  SELECT rowid, distance
  FROM data_embeddings
  WHERE embedding MATCH %s
    AND k = 40
  ORDER BY distance ASC
),
semantic_search AS (
  SELECT rowid, RANK () OVER (ORDER BY distance ASC) AS rank
  FROM vector_search
  WHERE rowid IN %s
  ORDER BY distance ASC
  LIMIT 20
),
keyword_search AS (
  SELECT rowid, RANK () OVER (ORDER BY bm25(data_fts) ASC) AS rank
  FROM data_fts
  WHERE rowid in %s and data_fts MATCH '%s'
  ORDER BY bm25(data_fts) ASC
  LIMIT 20
),
hybrid_search AS (
SELECT
  COALESCE(semantic_search.rowid, keyword_search.rowid) AS rowid,
  COALESCE(1.0 / (60 + semantic_search.rank), 0.0) +
  COALESCE(1.0 / (60 + keyword_search.rank), 0.0) AS score
FROM semantic_search
FULL OUTER JOIN keyword_search ON semantic_search.rowid = keyword_search.rowid
ORDER BY score DESC
LIMIT %d
)
SELECT
  hybrid_search.rowid
FROM hybrid_search
;
"
			(arc-vector-to-sqlite
			 (llm-embedding arc-embeddings-provider text))
			(arc-sqlite-format-int-list rowids)
			(arc-sqlite-format-int-list rowids)
			(arc-fts-query text)
			(arc-get-limit))))
    query))

(defun arc-find-similar (text collections on-done)
  "Find similar to TEXT results in COLLECTIONS.
Evaluate ON-DONE with result."
  (message "searching in collected data")
  (arc--async-do
   (lambda () (arc--find-similar text collections))
   on-done))

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
    (seq--into-list
     (alist-get 'data
		(plz 'post (format "%s/api/v1/rerank"
				   (string-remove-suffix "/" arc-reranker-url))
		  :headers `(("Content-Type" . "application/json"))
		  :body-type 'text
		  :body (arc--rerank-request prompt ids)
		  :as #'json-read)))))

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

(defun arc--rewrite-prompt (prompt action)
  "Rewrite PROMPT if `arc-prompt-rewriting-enabled'.
Call ACTION with new prompt."
  (let ((session (and ellama--current-session-id
		      (with-current-buffer (ellama-get-session-buffer
					    ellama--current-session-id)
			ellama--current-session))))
    (if (and arc-prompt-rewriting-enabled
	     ellama--current-session-id
	     (string= (llm-name (ellama-session-provider session))
		      (llm-name arc-chat-provider)))
	(with-current-buffer (get-buffer-create (make-temp-name "arc"))
	  (ellama-stream
	   (format arc-rewrite-prompt-template prompt)
	   :session session
	   :buffer (current-buffer)
	   :provider arc-chat-provider
	   :on-done action))
      (funcall action prompt))))

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

(defun arc--add-context-row (row)
  "Add one ROW from `arc--retrieve-rows' to the ellama context.
A row with no chunk text (the join found no data, which should not
happen for a live id, but is not this function's place to signal
that) is silently skipped.  `file' and `info' get arc's pre-existing,
jump-to-source-noninteractive quote types; the remaining kinds have no
such type yet, so they go in as plain labelled text -- a citation you
can read but not yet jump to."
  (pcase-let ((`(,kind ,path ,info-node ,org-id ,option-name ,chunk) row))
    (when chunk
      (pcase kind
        ("file"
         (ellama-context-add-file-quote-noninteractive path chunk))
        ("info"
         (ellama-context-add-info-node-quote-noninteractive info-node chunk))
        ("org-node"
         (ellama-context-add-text (format "org-roam node %s:\n%s" org-id chunk)))
        ((or "nix-option" "hm-option")
         (ellama-context-add-text (format "Option %s:\n%s" option-name chunk)))))))

(defun arc-retrieve-ask (query prompt)
  "Retrieve data with QUERY and ask arc for PROMPT."
  (arc--async-do
   (lambda () (let* ((raw-ids (flatten-tree (sqlite-select (arc-db) query)))
		     (ids (if arc-reranker-enabled
			      (arc-rerank prompt raw-ids)
			    (take arc-limit raw-ids))))
		(arc--retrieve-rows ids)))
   (lambda (result)
     (if result
         (mapc #'arc--add-context-row result)
       (ellama-context-add-text "No related documents found."))
     (ellama-chat
      (format arc-chat-prompt-template prompt)
      nil :provider arc-chat-provider))))

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

(defun arc--async-do (func &optional on-done)
  "Do FUNC asyncronously.
Call ON-DONE callback with result as an argument after FUNC evaluation done."
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
		    ,(async-inject-variables "arc-prompt-rewriting-enabled")
		    ,(async-inject-variables "arc-batch-embeddings-enabled")
		    ,(async-inject-variables "arc-batch-size")
		    ,(async-inject-variables "arc-rewrite-prompt-template")
		    ,(async-inject-variables "arc-semantic-split-function")
		    ,(async-inject-variables "arc-breakpoint-threshold-amount")
		    ,(async-inject-variables "arc-reranker-enabled")
		    ,(async-inject-variables "arc-sqlite-vec-path")
		    ,(async-inject-variables "load-path")
		    ,(async-inject-variables "Info-directory-list")
		    (require 'arc)
		    (,func))
		 (lambda (res)
		   (cancel-timer timer)
		   (progress-reporter-done reporter)
		   (arc-close-db)
		   (arc--reopen-db)
		   (when on-done
		     (funcall on-done res))))))

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

(defun arc--gen-chat (&optional collections)
  "Generate function for chat with arc based on COLLECTIONS."
  (let ((cols (or collections arc-enabled-collections)))
    (lambda (prompt)
      (arc-find-similar
       prompt cols
       (lambda (query) (arc-retrieve-ask query prompt))))))

;;;###autoload
(defun arc-chat (prompt &optional collections)
  "Send PROMPT to arc.
Find similar quotes in COLLECTIONS and add it to context."
  (interactive "sAsk arc: ")
  (let ((cols (or collections arc-enabled-collections)))
    (arc--rewrite-prompt prompt (arc--gen-chat cols))))

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
