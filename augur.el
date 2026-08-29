;;; augur.el --- Local config-aware oracle for eminix -*- lexical-binding: t -*-

;; Copyright (C) 2024, 2025 Free Software Foundation, Inc.
;; Copyright (C) 2026 Scott Whitson

;; Author: Sergey Kostyaev <sskostyaev@gmail.com>
;; Maintainer: Scott Whitson
;; URL: http://github.com/scott-whitson/augur
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
;; augur is a fork of ELISA by Sergey Kostyaev
;; (http://github.com/s-kostyaev/elisa).  Changes from upstream: the vector
;; backend was ported from sqlite-vss to sqlite-vec; the schema gained a
;; `sources' table carrying per-chunk source identity; web search, Apache
;; Tika and pandoc extraction were removed; org-roam node, NixOS option and
;; Home-Manager option source kinds were added; the answer UI was replaced.

;;; Commentary:
;;
;; augur is a local, offline, config-aware oracle.  It answers Emacs, Elisp,
;; Linux, NixOS and org-roam questions grounded in this machine's actual
;; configuration, and cites sources you can jump to.

;;; Code:
(require 'ellama)
(require 'llm)
(require 'llm-provider-utils)
(require 'info)
(require 'async)
(require 'dom)
(require 'shr)
(require 'plz)
(require 'json)
(require 'sqlite)

(defgroup augur nil
  "RAG implementation for `ellama'."
  :group 'tools)

(defcustom augur-embeddings-provider (progn (require 'llm-ollama)
					    (make-llm-ollama
					     :embedding-model "nomic-embed-text"))
  "Embeddings provider to generate embeddings."
  :type '(sexp :validate llm-standard-provider-p))

(defcustom augur-chat-provider (progn (require 'llm-ollama)
				      (make-llm-ollama
				       :chat-model "sskostyaev/openchat:8k-rag"
				       :embedding-model "nomic-embed-text"))
  "Chat provider."
  :type '(sexp :validate llm-standard-provider-p))

(defcustom augur-db-directory (file-truename
			       (file-name-concat
				user-emacs-directory "augur"))
  "Directory for augur database."
  :type 'directory)

(defcustom augur-limit 5
  "Count quotes to pass into llm context for answer."
  :type 'natnum)

(defcustom augur-find-executable find-program
  "Path to find executable."
  :type 'string)

(defcustom augur-tar-executable "tar"
  "Path to tar executable."
  :type 'string)

(defcustom augur-sqlite-vec-path (getenv "AUGUR_VEC0_PATH")
  "Path to the sqlite-vec (vec0) loadable extension.
Defaults to the AUGUR_VEC0_PATH environment variable (set by Nix)."
  :type '(choice (const nil) file))

(defcustom augur-semantic-split-function #'augur-split-by-paragraph
  "Function for semantic text split."
  :type 'function)

(defcustom augur-prompt-rewriting-enabled t
  "Enable prompt rewriting for better retrieving."
  :type 'boolean)

(defcustom augur-chat-prompt-template
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

(defcustom augur-rewrite-prompt-template
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

(defcustom augur-tika-url "http://localhost:9998/"
  "Apache tika url for file parsing."
  :type 'string)

(defcustom augur-searxng-url "http://localhost:8080/"
  "Searxng url for web search.  Json format should be enabled for this instance."
  :type 'string)

(defcustom augur-pandoc-executable "pandoc"
  "Path to pandoc (https://pandoc.org/) executable."
  :type 'string)

(defcustom augur-webpage-extraction-function #'augur-get-webpage-buffer
  "Function to get buffer with webpage content."
  :type 'function)

(defcustom augur-complex-file-extraction-function #'augur-parse-with-tika-buffer
  "Function to get buffer with complex file (like pdf, odt etc.) content."
  :type 'function)

(defcustom augur-web-search-function #'augur-search-duckduckgo
  "Function to search the web.
Function should get prompt and return list of urls."
  :type 'function)

(defcustom augur-web-pages-limit 10
  "Limit of web pages to parse during web search."
  :type 'natnum)

(defcustom augur-breakpoint-threshold-amount 0.4
  "Breakpoint threshold amount.
Increase it if you need decrease semantic split granularity."
  :type 'number)

(defcustom augur-reranker-enabled nil
  "Enable reranker to improve retrieving quality.
Reranker is a service to improve answer quality by mesure
relevance of text chunks to user query and sort chunks by
relevance.  See https://github.com/s-kostyaev/reranker for more
details."
  :type 'boolean)

(defcustom augur-reranker-url "http://127.0.0.1:8787/"
  "Reranker service url.
Reranker is a service to improve answer quality by mesure
relevance of text chunks to user query and sort chunks by
relevance.  See https://github.com/s-kostyaev/reranker for more
details."
  :type 'string)

(defcustom augur-reranker-similarity-threshold 0
  "Reranker similarity threshold.
If set, all quotes with similarity less than threshold will be filtered out."
  :type 'number)

(defcustom augur-reranker-limit 20
  "Number of quotes for send to reranker."
  :type 'integer)

(defcustom augur-ignore-patterns-files '(".gitignore" ".ignore" ".rgignore")
  "Files with patterns to ignore during file parsing."
  :type '(repeat string))

(defcustom augur-ignore-invisible-files t
  "Ignore invisible files and directories during file parsing."
  :type 'boolean)

(defcustom augur-enabled-collections '("builtin manuals" "external manuals")
  "Enabled collections for augur chat."
  :type '(repeat string))

(defcustom augur-supported-complex-document-extensions '("doc" "dot" "ppt" "xls" "rtf" "docx" "pptx" "xlsx" "xlsm" "pdf" "epub" "msg" "odt" "odp" "ods" "odg" "docm")
  "Supported complex document file extensions."
  :type '(repeat string))

(defcustom augur-batch-embeddings-enabled nil
  "Enable batch embeddings if supported."
  :type 'boolean)

(defcustom augur-batch-size 300
  "Batch size to send to provider during batch embeddings calculation."
  :type 'integer)

(defun augur-supported-complex-document-p (path)
  "Check if PATH contain supported complex document."
  (cl-find (file-name-extension path)
	   augur-supported-complex-document-extensions :test #'string=))


(defun augur-get-embedding-size ()
  "Get embedding size."
  (length (llm-embedding augur-embeddings-provider "test")))

(defun augur-embeddings-create-table-sql ()
  "Generate sql for create embeddings table."
  "DROP TABLE IF EXISTS augur_embeddings;")

(defun augur-data-embeddings-create-table-sql ()
  "Generate sql for create data embeddings table."
  (format "CREATE VIRTUAL TABLE IF NOT EXISTS data_embeddings USING vec0(embedding float[%d]);"
	  (augur-get-embedding-size)))

(defun augur-data-embeddings-drop-table-sql ()
  "Generate sql for drop data embeddings table."
  "DROP TABLE IF EXISTS data_embeddings;")

(defun augur-data-fts-create-table-sql ()
  "Generate sql for create full text search table."
  "CREATE VIRTUAL TABLE IF NOT EXISTS data_fts USING FTS5(data);")

(defun augur-info-create-table-sql ()
  "Generate sql for create info table."
  "DROP TABLE IF EXISTS info;")

(defun augur-collections-create-table-sql ()
  "Generate sql for create collections table."
  "CREATE TABLE IF NOT EXISTS collections (name TEXT UNIQUE);")

(defun augur-kinds-create-table-sql ()
  "Generate sql for create kinds table."
  "CREATE TABLE IF NOT EXISTS kinds (name TEXT UNIQUE);")

(defun augur-fill-kinds-sql ()
  "Generate sql for fill kinds table."
  "INSERT INTO KINDS (name) VALUES ('web'), ('file'), ('info') ON CONFLICT DO NOTHING;")

(defun augur-files-create-table-sql ()
  "Generate sql for create files table."
  "CREATE TABLE IF NOT EXISTS files (path TEXT UNIQUE, hash TEXT)")

(defun augur-data-create-table-sql ()
  "Generate sql for create data table."
  "CREATE TABLE IF NOT EXISTS data (
kind_id INTEGER,
collection_id INTEGER,
path TEXT,
hash TEXT,
data TEXT,
FOREIGN KEY(kind_id) REFERENCES kinds(rowid),
FOREIGN KEY(collection_id) REFERENCES collections(rowid)
);")

(defun augur--init-db (db)
  "Initialize augur DB."
  (if (not (and augur-sqlite-vec-path (file-exists-p augur-sqlite-vec-path)))
      (warn "Set `augur-sqlite-vec-path' (or AUGUR_VEC0_PATH) to the sqlite-vec vec0 extension")
    (sqlite-pragma db "PRAGMA journal_mode=WAL;")
    (sqlite-load-extension db augur-sqlite-vec-path)
    (sqlite-execute db (augur-embeddings-create-table-sql))
    (sqlite-execute db (augur-info-create-table-sql))
    (sqlite-execute db (augur-collections-create-table-sql))
    (sqlite-execute db (augur-kinds-create-table-sql))
    (sqlite-execute db (augur-fill-kinds-sql))
    (sqlite-execute db (augur-files-create-table-sql))
    (sqlite-execute db (augur-data-create-table-sql))
    (sqlite-execute db (augur-data-embeddings-create-table-sql))
    (sqlite-execute db (augur-data-fts-create-table-sql))))

(defvar augur-db
  (let ((_ (make-directory augur-db-directory t))
        (db (sqlite-open (file-name-concat augur-db-directory "augur.sqlite"))))
    (augur--init-db db)
    db))

(defun augur-vector-to-sqlite (data)
  "Convert DATA to sqlite vector representation."
  (format "vec_f32('%s')" (json-encode data)))

(defun augur-sqlite-escape (string)
  "Escape single quotes in STRING for sqlite."
  (let ((reps '(("'" . "''")
                ("\\" . "\\\\")
                ("\0" . "\n"))))
    (replace-regexp-in-string
     (regexp-opt (mapcar #'car reps))
     (lambda (str) (alist-get str reps nil nil #'string=))
     string nil t)))

(defun augur-sqlite-format-int-list (ids)
  "Convert list of integer IDS list to sqlite list representation."
  (format
   "(%s)"
   (mapconcat (lambda (id) (format "%d" id)) ids ", ")))

(defun augur-sqlite-format-string-list (names)
  "Convert list of string NAMES list to sqlite list representation."
  (format
   "(%s)"
   (mapconcat (lambda (name)
		(format "'%s'"
			(augur-sqlite-escape name)))
              names ", ")))

(defun augur-avg (list)
  "Calculate arithmetic average value of LIST."
  (cl-loop for elem in list for count from 0
           summing elem into sum
           finally (return (/ sum (float count)))))

(defun augur-std-dev (lst)
  "Calculate standart deviation value of LST."
  (let ((avg (augur-avg lst))
	(len (length lst)))
    (sqrt (/ (cl-reduce
	      #'+
	      (mapcar
	       (lambda (x) (expt (- x avg) 2))
	       lst))
	     len))))

(defun augur-calculate-threshold (k distances)
  "Calculate breakpoint threshold for DISTANCES based on K standard deviations."
  (+ (augur-avg distances) (* k (augur-std-dev distances))))

(defun augur-string-empty-p (s)
  "Check if string S contain only spacing."
  (length= (string-trim s) 0))

(defun augur-filter-strings (chunks)
  "Filter out empty CHUNKS."
  (cl-remove-if #'augur-string-empty-p chunks))

(defun augur-embeddings (chunks)
  "Calculate embeddings for CHUNKS.
Return list of vectors."
  (let ((provider augur-embeddings-provider))
    (if (and augur-batch-embeddings-enabled
	     (member 'embeddings-batch (llm-capabilities provider)))
	(let ((batches (seq-partition chunks augur-batch-size)))
	  (flatten-list (mapcar (lambda (batch) (llm-batch-embeddings provider (vconcat batch)))
				batches)))
      (mapcar (lambda (chunk) (llm-embedding provider chunk)) chunks))))

(defun augur-parse-info-manual (name collection-name)
  "Parse info manual with NAME and save index to COLLECTION-NAME."
  (with-temp-buffer
    (ignore-errors
      (info name (current-buffer))
      (let ((collection-id (or (caar (sqlite-select
				      augur-db
				      (format
				       "SELECT rowid FROM collections WHERE name = '%s';"
				       collection-name)))
			       (progn
				 (sqlite-execute
				  augur-db
				  (format
				   "INSERT INTO collections (name) VALUES ('%s');"
				   collection-name))
				 (caar (sqlite-select
					augur-db
					(format
					 "SELECT rowid FROM collections WHERE name = '%s';"
					 collection-name))))))
	    (kind-id (caar (sqlite-select
			    augur-db "SELECT rowid FROM kinds WHERE name = 'info';")))
	    (continue t)
	    (parsed-nodes nil))
	(while continue
	  (let* ((node-name (concat "(" (file-name-sans-extension
					 (file-name-nondirectory Info-current-file))
				    ") "
				    Info-current-node))
		 (chunks (augur-split-semantically)))
	    (if (not (cl-find node-name parsed-nodes :test 'string-equal))
		(progn
		  (mapc
		   (lambda (text)
		     (let* ((hash (secure-hash 'sha256 text))
			    (embedding (llm-embedding augur-embeddings-provider text))
			    (rowid
			     (if-let ((rowid (caar (sqlite-select
						    augur-db
						    (format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';"
							    kind-id collection-id
							    (augur-sqlite-escape node-name) hash)))))
				 nil
			       (sqlite-execute
				augur-db
				(format
				 "INSERT INTO data(kind_id, collection_id, path, hash, data) VALUES (%s, %s, '%s', '%s', '%s');"
				 kind-id collection-id
				 (augur-sqlite-escape node-name) hash (augur-sqlite-escape text)))
			       (caar (sqlite-select
				      augur-db
				      (format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';"
					      kind-id collection-id
					      (augur-sqlite-escape node-name) hash))))))
		       (when rowid
			 (sqlite-execute
			  augur-db
			  (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%s, %s);"
				  rowid (augur-vector-to-sqlite embedding)))
			 (sqlite-execute
			  augur-db
			  (format "INSERT INTO data_fts(rowid, data) VALUES (%s, '%s');"
				  rowid (augur-sqlite-escape text))))))
		   chunks)
		  (push node-name parsed-nodes)
		  (condition-case nil
		      (funcall-interactively #'Info-forward-node)
		    (error
		     (setq continue nil))))
	      (setq continue nil))))))))

(defun augur--find-similar (text collections)
  "Find similar to TEXT results in COLLECTIONS.
Return sqlite query.  For asyncronous execution."
  (let* ((rowids (flatten-tree
		  (sqlite-select
		   augur-db
		   (format "SELECT rowid FROM data WHERE collection_id IN
 (
SELECT rowid FROM collections WHERE name IN %s
);"
			   (augur-sqlite-format-string-list collections)))))
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
			(augur-vector-to-sqlite
			 (llm-embedding augur-embeddings-provider text))
			(augur-sqlite-format-int-list rowids)
			(augur-sqlite-format-int-list rowids)
			(augur-fts-query text)
			(augur-get-limit))))
    query))

(defun augur-find-similar (text collections on-done)
  "Find similar to TEXT results in COLLECTIONS.
Evaluate ON-DONE with result."
  (message "searching in collected data")
  (augur--async-do
   (lambda () (augur--find-similar text collections))
   on-done))

(defun augur--split-by (func)
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

(defun augur-split-by-sentence ()
  "Split byffer to list of sentences."
  (augur--split-by #'forward-sentence))

(defun augur-split-by-paragraph ()
  "Split buffer to list of paragraphs."
  (augur--split-by #'forward-paragraph))

(defun augur-dot-product (v1 v2)
  "Calculate the dot produce of vectors V1 and V2."
  (let ((result 0))
    (dotimes (i (length v1))
      (setq result (+ result (* (aref v1 i) (aref v2 i)))))
    result))

(defun augur-magnitude (v)
  "Calculate magnitude of vector V."
  (let ((sum 0))
    (dotimes (i (length v))
      (setq sum (+ sum (* (aref v i) (aref v i)))))
    (sqrt sum)))

(defun augur-cosine-similarity (v1 v2)
  "Calculate the cosine similarity of V1 and V2.
The return is a floating point number between 0 and 1, where the
closer it is to 1, the more similar it is."
  (let ((dot-product (augur-dot-product v1 v2))
        (v1-magnitude (augur-magnitude v1))
        (v2-magnitude (augur-magnitude v2)))
    (if (and v1-magnitude v2-magnitude)
        (/ dot-product (* v1-magnitude v2-magnitude))
      0)))

(defun augur-cosine-distance (v1 v2)
  "Calculate cosine-distance between V1 and V2."
  (- 1 (augur-cosine-similarity v1 v2)))

(defun augur--similarities (list)
  "Calculate cosine similarities between neighbour elements in LIST."
  (let ((head (car list))
	(tail (cdr list))
	(result nil))
    (while tail
      (push (augur-cosine-similarity head (car tail)) result)
      (setq head (car tail))
      (setq tail (cdr tail)))
    (nreverse result)))

(defun augur--distances (list)
  "Calculate cosine distances between neighbour elements in LIST."
  (let ((head (car list))
	(tail (cdr list))
	(result nil))
    (while tail
      (push (augur-cosine-distance head (car tail)) result)
      (setq head (car tail))
      (setq tail (cdr tail)))
    (nreverse result)))

(defun augur-split-semantically (&rest args)
  "Split buffer data semantically.
ARGS contains keys for fine control.

:function FUNC -- FUNC is a function for split buffer into chunks.

:threshold-amount K -- K is a breakpoint threshold amount.

than T, it will be packed into single semantic chunk."
  (if-let* ((func (or (plist-get args :function) augur-semantic-split-function))
	    (k (or (plist-get args :threshold-amount) augur-breakpoint-threshold-amount))
	    (chunks (augur-filter-strings (funcall func)))
	    (embeddings (augur-embeddings chunks))
	    (distances (augur--distances embeddings))
	    (threshold (augur-calculate-threshold k distances))
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

(defun augur--read-ignore-file-regexps (directory)
  "Read ignore patterns from `augur-ignore-patterns-files' in DIRECTORY."
  (mapcar #'wildcard-to-regexp
	  (flatten-tree
	   (mapcar (lambda (file)
		     (let ((filepath (expand-file-name file directory)))
		       (when (file-exists-p filepath)
			 (with-temp-buffer
			   (insert-file-contents filepath)
			   (split-string (buffer-string) "\n" t)))))
		   augur-ignore-patterns-files))))

(defun augur--text-file-p (filename)
  "Check if FILENAME contain text."
  (or (and (get-file-buffer filename) t) ;; if file opened assume it text
      (with-current-buffer (find-file-noselect filename t t)
	(prog1
	    ;; if there is null byte in file, file is binary
	    (not (search-forward "\0" nil t 1))
	  (kill-buffer)))))

(defun augur--file-list (directory)
  "List of files to parse in DIRECTORY."
  (let ((ignore-regexps (augur--read-ignore-file-regexps directory)))
    (when augur-ignore-invisible-files
      (push "$\\.[^/]*" ignore-regexps)
      (push "/\\.[^/]*" ignore-regexps))
    (seq-filter (lambda (file)
		  (and (not (seq-some (lambda (regexp)
					(string-match-p regexp file))
				      ignore-regexps))
		       (or
			(augur-supported-complex-document-p file)
			(augur--text-file-p file))))
		(directory-files-recursively directory ".*"))))

(defun augur-parse-file (collection-id path &optional force)
  "Parse file PATH for COLLECTION-ID.
When FORCE parse even if already parsed."
  (let* ((opened (get-file-buffer path))
	 (buf (if (augur-supported-complex-document-p path)
		  (funcall augur-complex-file-extraction-function path)
		(or opened (find-file-noselect path t t))))
	 (hash (secure-hash 'sha256 buf))
	 (prev-hash (caar (sqlite-select
			   augur-db
			   (format "SELECT hash FROM files WHERE path = '%s';"
				   (augur-sqlite-escape path))))))
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
	(let ((chunks (augur-split-semantically))
	      (old-row-ids
	       (flatten-tree (sqlite-select
			      augur-db
			      (format "SELECT rowid FROM data WHERE path = '%s';"
				      (augur-sqlite-escape path)))))
	      (row-ids nil)
	      (kind-id (caar (sqlite-select
			      augur-db
			      "SELECT rowid FROM kinds WHERE name = 'file';"))))
	  ;; remove old data
	  (when prev-hash
	    (sqlite-execute
	     augur-db
	     (format "DELETE FROM files WHERE path = '%s';"
		     (augur-sqlite-escape path))))
	  ;; add new data
          (dolist (text chunks)
            (let* ((hash (secure-hash 'sha256 text))
		   (rowid
		    (if-let ((rowid (caar (sqlite-select
					   augur-db
					   (format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';"
						   kind-id collection-id
						   (augur-sqlite-escape path) hash)))))
			(progn
			  (push rowid row-ids)
			  nil)
		      (sqlite-execute
		       augur-db
		       (format
			"INSERT INTO data(kind_id, collection_id, path, hash, data) VALUES (%s, %s, '%s', '%s', '%s');"
			kind-id collection-id
			(augur-sqlite-escape path) hash (augur-sqlite-escape text)))
		      (caar (sqlite-select
			     augur-db
			     (format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';"
				     kind-id collection-id
				     (augur-sqlite-escape path) hash))))))
	      (when rowid
		(sqlite-execute
		 augur-db
		 (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%s, %s);"
			 rowid (augur-vector-to-sqlite
				(llm-embedding augur-embeddings-provider text))))
		(sqlite-execute
		 augur-db
		 (format "INSERT INTO data_fts(rowid, data) VALUES (%s, '%s');"
			 rowid (augur-sqlite-escape text)))
		(push rowid row-ids))))
	  ;; remove old data
	  (when row-ids
	    (let ((delete-rows (cl-remove-if (lambda (id)
					       (cl-find id row-ids))
					     old-row-ids)))
	      (augur--delete-data delete-rows)))
	  ;; save hash to files table
	  (sqlite-execute
	   augur-db
	   (format "INSERT INTO files (path, hash) VALUES ('%s', '%s');"
		   (augur-sqlite-escape path) hash)))))
    ;; kill buffer if it was not open before parsing
    (when (not opened)
      (kill-buffer buf))))

(defun augur--delete-from-table (table ids)
  "Delete IDS from TABLE."
  (sqlite-execute
   augur-db
   (format "DELETE FROM %s WHERE rowid IN %s;"
	   table
	   (augur-sqlite-format-int-list ids))))

(defun augur--delete-data (ids)
  "Delete data with IDS."
  (augur--delete-from-table "data_fts" ids)
  (augur--delete-from-table "data_embeddings" ids)
  (augur--delete-from-table "data" ids))

(defun augur-parse-directory (dir)
  "Parse DIR as new collection syncronously."
  (setq dir (expand-file-name dir))
  (let* ((collection-id (progn
			  (sqlite-execute
			   augur-db
			   (format
			    "INSERT INTO collections (name) VALUES ('%s') ON CONFLICT DO NOTHING;"
			    (augur-sqlite-escape dir)))
			  (caar (sqlite-select
				 augur-db
				 (format
				  "SELECT rowid FROM collections WHERE name = '%s';"
				  (augur-sqlite-escape dir))))))
	 (files (augur--file-list dir))
	 (delete-ids (flatten-tree
		      (sqlite-select
		       augur-db
		       (format
			"SELECT rowid FROM data WHERE collection_id = %d AND path NOT IN %s;"
			collection-id
			(augur-sqlite-format-string-list files))))))
    (augur--delete-data delete-ids)
    (dolist (file files)
      (message "parsing %s" file)
      (augur-parse-file collection-id file))))

;;;###autoload
(defun augur-async-parse-directory (dir)
  "Parse DIR as new collection asyncronously."
  (interactive "DSelect directory: ")
  (augur--async-do (lambda ()
		     (augur-parse-directory
		      (expand-file-name dir)))))

(defvar eww-accept-content-types)

(defun augur-search-duckduckgo (prompt)
  "Search duckduckgo for PROMPT and return list of urls."
  (require 'eww)
  (let* ((url (format "https://duckduckgo.com/html/?q=%s" (url-hexify-string prompt)))
	 (buffer-name (plz 'get url :as 'buffer
			:headers `(("Accept" . ,eww-accept-content-types)
				   ("Accept-Encoding" . "gzip")
				   ("User-Agent" . ,(url-http--user-agent-default-string))))))
    (with-current-buffer buffer-name
      (goto-char (point-min))
      (search-forward "<!DOCTYPE")
      (beginning-of-line)
      (cl-remove-if
       #'string-empty-p
       (cl-remove-duplicates
	(mapcar
	 (lambda (el)
	   (when el
	     (string-trim-right
	      (url-unhex-string
	       (cdar (url-parse-args (or (dom-attr el 'href) ""))))
	      "[&\\?].*")))
	 (dom-by-tag
	  (libxml-parse-html-region
	   (point) (point-max))
	  'a))
	:test #'string-equal)))))

(defun augur-starts-with-lowercase-p (string)
  "Check if STRING start with lowercase character."
  (let ((category (get-char-code-property (seq-first string) 'general-category)))
    (or (eq 'Ll category)
	(eq 'Ps category))))

(defun augur-dehyphen (text)
  "Dehyphen TEXT."
  (ignore-errors (with-temp-buffer
		   (insert (string-join
			    (mapcar #'string-trim (string-split text "\n"))
			    "\n"))
		   (goto-char (point-min))
		   (while (not (eobp))
		     (end-of-line)
		     (if (eq (preceding-char) ?-)
			 (progn
			   (delete-char 1)
			   (delete-char -1))
		       (forward-line)))
		   (buffer-substring-no-properties (point-min) (point-max)))))

(defun augur-parse-with-tika-buffer (file)
  "Parse FILE with tika."
  (let* ((url (format "%s/tika" (string-trim-right augur-tika-url "/")))
	 (buf (plz 'put url :body (list 'file file) :as 'buffer))
	 (shr-use-fonts nil)
	 (shr-width (- ellama-long-lines-length 5))
	 (data (with-current-buffer buf
		 (libxml-parse-html-region (point-min) (point-max))))
	 (prev-elt nil))
    (dolist (elt (dom-by-tag data 'p))
      (dolist (text (dom-children elt))
	;; trim string content
	(when-let* ((trimmed-text (string-trim text))
		    (new-elt (if (or (string-match "^[0-9]+$" trimmed-text)
				     (string= "" trimmed-text))
				 (progn (dom-remove-node data elt)
					nil)
			       (if (augur-starts-with-lowercase-p trimmed-text)
				   (progn
				     (dom-remove-node data prev-elt)
				     (dom-node 'p nil (augur-dehyphen
						       (concat
							(car (dom-children prev-elt))
							"\n" trimmed-text))))
				 (dom-node 'p nil (augur-dehyphen trimmed-text))))))
	  (setq prev-elt new-elt)
	  (setq data (cl-nsubst new-elt elt data :test #'equal))))
      (when (eq (length (dom-children elt)) 0)
	(dom-remove-node data elt)))
    (with-current-buffer buf
      (delete-region (point-min) (point-max))
      (ignore-errors
	(shr-insert-document data))
      buf)))

(defun augur-search-searxng (prompt)
  "Search searxng for PROMPT and return list of urls.
You can customize `augur-searxng-url' to use non local instance."
  (let ((url (format "%s/search?format=json&q=%s" augur-searxng-url (url-hexify-string prompt))))
    (thread-last
      (plz 'get url :as #'json-read)
      (alist-get 'results)
      (mapcar (lambda (el) (alist-get 'url el))))))

(defun augur-get-webpage-buffer (url)
  "Get buffer with URL content."
  (require 'eww)
  (let ((buffer-name (ignore-errors
		       (plz 'get url :as 'buffer
			 :headers `(("Accept" . ,eww-accept-content-types)
				    ("Accept-Encoding" . "gzip")
				    ("User-Agent" . ,(url-http--user-agent-default-string))))))
	;; fix one word lines for async execution
	(shr-use-fonts nil)
	(shr-width (- ellama-long-lines-length 5)))
    (when buffer-name
      (with-current-buffer buffer-name
	(goto-char (point-min))
	(or (search-forward "<!DOCTYPE" nil t)
            (search-forward "<html" nil t))
	(beginning-of-line)
	(kill-region (point-min) (point))
	(ignore-errors
	  (shr-insert-document (libxml-parse-html-region (point-min) (point-max))))
	(goto-char (point-min))
	(or (search-forward "<!DOCTYPE" nil t)
            (search-forward "<html" nil t))
	(beginning-of-line)
	(kill-region (point) (point-max))
	buffer-name))))

(defun augur-get-webpage-buffer-pandoc (url)
  "Get buffer with URL content translated to markdown with pandoc."
  (let ((buffer-name (plz 'get url :as 'buffer)))
    (with-current-buffer buffer-name
      (shell-command-on-region
       (point-min) (point-max)
       (format "%s --from html --to plain" augur-pandoc-executable)
       buffer-name t)
      buffer-name)))

(defun augur-fts-query (prompt)
  "Return fts match query for PROMPT."
  (thread-last
    prompt
    (string-trim)
    (downcase)
    (string-replace "-" " ")
    (replace-regexp-in-string "[^[:alnum:] ]+" "")
    (string-trim)
    (replace-regexp-in-string "[[:space:]]+" " OR ")))

(defun augur--rerank-request (prompt ids)
  "Generate rerank request body for PROMPT and IDS."
  (let ((docs
	 (mapcar
	  (lambda (row)
	    (let ((id (cl-first row))
		  (text (cl-second row)))
	      `(("id" . ,id) ("text" . ,text))))
	  (sqlite-select
	   augur-db
	   (format
	    "SELECT rowid, data FROM data WHERE rowid IN %s;"
	    (augur-sqlite-format-int-list ids))))))
    (json-encode `(("query" . ,prompt)
		   ("documents" . ,docs)))))

(defun augur--do-rerank-request (prompt ids)
  "Call rerank service for PROMPT and IDS."
  (when ids
    (seq--into-list
     (alist-get 'data
		(plz 'post (format "%s/api/v1/rerank"
				   (string-remove-suffix "/" augur-reranker-url))
		  :headers `(("Content-Type" . "application/json"))
		  :body-type 'text
		  :body (augur--rerank-request prompt ids)
		  :as #'json-read)))))

(defun augur-rerank (prompt ids)
  "Rerank IDS according to PROMPT and return top `augur-limit' IDS."
  (let ((data (augur--do-rerank-request prompt ids)))
    (mapcar (lambda (elt)
	      (alist-get 'id elt))
	    (take augur-limit
		  (if augur-reranker-similarity-threshold
		      (cl-remove-if (lambda (obj)
				      (< (alist-get 'similarity obj)
					 augur-reranker-similarity-threshold))
				    data)
		    data)))))

(defun augur-get-limit ()
  "Limit for augur hybrid search."
  (if augur-reranker-enabled
      augur-reranker-limit
    augur-limit))

(defun augur--parse-web-page (collection-id url)
  "Parse URL into collection with COLLECTION-ID."
  (let ((kind-id (caar (sqlite-select
			augur-db "SELECT rowid FROM kinds WHERE name = 'web';"))))
    (message "collecting data from %S..." url)
    (dolist (chunk (augur-extact-webpage-chunks url))
      (let* ((hash (secure-hash 'sha256 chunk))
	      (embedding (llm-embedding augur-embeddings-provider chunk))
	      (rowid
	       (if-let ((rowid (caar (sqlite-select
				      augur-db
				      (format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';" kind-id collection-id url hash)))))
		   nil
		 (sqlite-execute
		  augur-db
		  (format
		   "INSERT INTO data(kind_id, collection_id, path, hash, data) VALUES (%s, %s, '%s', '%s', '%s');"
		   kind-id collection-id url hash (augur-sqlite-escape chunk)))
		 (caar (sqlite-select
			augur-db
			(format "SELECT rowid FROM data WHERE kind_id = %s AND collection_id = %s AND path = '%s' AND hash = '%s';" kind-id collection-id url hash))))))
	 (when rowid
	   (sqlite-execute
	    augur-db
	    (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%s, %s);"
		    rowid (augur-vector-to-sqlite embedding)))
	   (sqlite-execute
	    augur-db
	    (format "INSERT INTO data_fts(rowid, data) VALUES (%s, '%s');"
		    rowid (augur-sqlite-escape chunk))))))))

(defun augur--web-search (prompt)
  "Search the web for PROMPT.
Return sqlite query that extract data for adding to context."
  (sqlite-execute
   augur-db
   (format
    "INSERT INTO collections (name) VALUES ('%s') ON CONFLICT DO NOTHING;"
    (augur-sqlite-escape prompt)))
  (let* ((collection-id (caar (sqlite-select
			       augur-db
			       (format
				"SELECT rowid FROM collections WHERE name = '%s';"
				(augur-sqlite-escape prompt)))))
	 (urls (funcall augur-web-search-function prompt))
	 (collected-pages 0))
    (dolist (url urls)
      (when (<= collected-pages augur-web-pages-limit)
	(augur--parse-web-page collection-id url)
	(cl-incf collected-pages)))))

(defun augur--rewrite-prompt (prompt action)
  "Rewrite PROMPT if `augur-prompt-rewriting-enabled'.
Call ACTION with new prompt."
  (let ((session (and ellama--current-session-id
		      (with-current-buffer (ellama-get-session-buffer
					    ellama--current-session-id)
			ellama--current-session))))
    (if (and augur-prompt-rewriting-enabled
	     ellama--current-session-id
	     (string= (llm-name (ellama-session-provider session))
		      (llm-name augur-chat-provider)))
	(with-current-buffer (get-buffer-create (make-temp-name "augur"))
	  (ellama-stream
	   (format augur-rewrite-prompt-template prompt)
	   :session session
	   :buffer (current-buffer)
	   :provider augur-chat-provider
	   :on-done action))
      (funcall action prompt))))

;;;###autoload
(defun augur-web-search (prompt)
  "Search the web for PROMPT."
  (interactive "sAsk augur with web search: ")
  (augur--rewrite-prompt prompt #'augur--web-search-internal))

(defun augur--web-search-internal (prompt)
  "Search the web for PROMPT."
  (message "searching the web")
  (augur--async-do
   (lambda () (augur--web-search prompt))
   (lambda (_)
     (augur-find-similar
      prompt (list prompt)
      (lambda (query) (augur-retrieve-ask query prompt))))))

(defun augur-retrieve-ask (query prompt)
  "Retrieve data with QUERY and ask augur for PROMPT."
  (augur--async-do
   (lambda () (let* ((raw-ids (flatten-tree (sqlite-select augur-db query)))
		     (ids (if augur-reranker-enabled
			      (augur-rerank prompt raw-ids)
			    (take augur-limit raw-ids))))
		(when ids
		  (sqlite-select
		   augur-db
		   (format
		    "SELECT k.name, d.path, d.data
FROM data AS d
LEFT JOIN kinds k ON k.rowid = d.kind_id
WHERE d.rowid in %s;"
		    (augur-sqlite-format-int-list ids))))))
   (lambda (result)
     (if result (mapc
		 (lambda (row)
		   (when-let ((kind (cl-first row))
			      (path (cl-second row))
			      (text (cl-third row)))
		     (pcase kind
		       ("web"
			(ellama-context-add-webpage-quote-noninteractive path path text))
		       ("file"
			(ellama-context-add-file-quote-noninteractive path text))
		       ("info"
			(ellama-context-add-info-node-quote-noninteractive path text)))))
		 result)
       (ellama-context-add-text "No related documents found."))
     (ellama-chat
      (format augur-chat-prompt-template prompt)
      nil :provider augur-chat-provider))))

(defun augur--info-valid-p (name)
  "Return NAME if info is valid."
  (with-temp-buffer
    (ignore-errors
      (info name (current-buffer))
      name)))

(defun augur-get-builtin-manuals ()
  "Get builtin manual names list."
  (mapcar
   #'file-name-base
   (cl-remove-if-not
    (lambda (s)
      (or (string-suffix-p ".info" s)
	  (string-suffix-p ".info.gz" s)))
    (directory-files (with-temp-buffer
		       (info "emacs" (current-buffer))
		       (file-name-directory Info-current-file))))))

(defun augur-get-external-manuals ()
  "Get external manual names list."
  (thread-last
    (process-lines
     augur-find-executable
     (file-truename (file-name-concat user-emacs-directory "elpa"))
     "-name" "*.info")
    (mapcar #'file-name-base)
    (seq-uniq)
    (mapcar #'augur--info-valid-p)
    (cl-remove-if #'not)))

(defun augur-parse-builtin-manuals ()
  "Parse builtin manuals."
  (mapc (lambda (s)
	  (augur-parse-info-manual s "builtin manuals"))
	(augur-get-builtin-manuals)))

(defun augur-parse-external-manuals ()
  "Parse external manuals."
  (mapc (lambda (s)
	  (augur-parse-info-manual s "external manuals"))
	(augur-get-external-manuals)))

(defun augur-parse-all-manuals ()
  "Parse all manuals."
  (augur-parse-builtin-manuals)
  (augur-parse-external-manuals))

(defun augur--reopen-db ()
  "Reopen database."
  (let ((db (sqlite-open (file-name-concat augur-db-directory "augur.sqlite"))))
    (augur--init-db db)
    (setq augur-db db)))

(defun augur--async-do (func &optional on-done)
  "Do FUNC asyncronously.
Call ON-DONE callback with result as an argument after FUNC evaluation done."
  (let* ((command real-this-command)
	 (reporter (make-progress-reporter (if command
					       (prin1-to-string command)
					     "augur async processing")))
	 (timer (run-at-time t 0.2 (lambda () (progress-reporter-update reporter)))))
    (async-start `(lambda ()
		    ,(async-inject-variables "augur-embeddings-provider")
		    ,(async-inject-variables "augur-db-directory")
		    ,(async-inject-variables "augur-find-executable")
		    ,(async-inject-variables "augur-tar-executable")
		    ,(async-inject-variables "augur-prompt-rewriting-enabled")
		    ,(async-inject-variables "augur-batch-embeddings-enabled")
		    ,(async-inject-variables "augur-batch-size")
		    ,(async-inject-variables "augur-rewrite-prompt-template")
		    ,(async-inject-variables "augur-semantic-split-function")
		    ,(async-inject-variables "augur-webpage-extraction-function")
		    ,(async-inject-variables "augur-supported-complex-document-extensions")
		    ,(async-inject-variables "augur-complex-file-extraction-function")
		    ,(async-inject-variables "augur-web-search-function")
		    ,(async-inject-variables "augur-tika-url")
		    ,(async-inject-variables "augur-searxng-url")
		    ,(async-inject-variables "augur-web-pages-limit")
		    ,(async-inject-variables "augur-breakpoint-threshold-amount")
		    ,(async-inject-variables "augur-pandoc-executable")
		    ,(async-inject-variables "ellama-long-lines-length")
		    ,(async-inject-variables "augur-reranker-enabled")
		    ,(async-inject-variables "augur-sqlite-vec-path")
		    ,(async-inject-variables "load-path")
		    ,(async-inject-variables "Info-directory-list")
		    (require 'augur)
		    (,func))
		 (lambda (res)
		   (cancel-timer timer)
		   (progress-reporter-done reporter)
		   (sqlite-close augur-db)
		   (augur--reopen-db)
		   (when on-done
		     (funcall on-done res))))))

(defun augur-extact-webpage-chunks (url)
  "Extract semantic chunks for webpage fetched from URL."
  (when-let ((buf (funcall augur-webpage-extraction-function url)))
    (with-current-buffer buf
      (augur-split-semantically))))

;;;###autoload
(defun augur-async-parse-builtin-manuals ()
  "Parse builtin manuals asyncronously."
  (interactive)
  (message "Begin parsing builtin manuals.")
  (augur--async-do 'augur-parse-builtin-manuals))

;;;###autoload
(defun augur-async-parse-external-manuals ()
  "Parse external manuals asyncronously."
  (interactive)
  (message "Begin parsing external manuals.")
  (augur--async-do 'augur-parse-external-manuals))

;;;###autoload
(defun augur-async-parse-all-manuals ()
  "Parse all manuals asyncronously."
  (interactive)
  (message "Begin parsing manuals.")
  (augur--async-do 'augur-parse-all-manuals))

;;;###autoload
(defun augur-reparse-current-collection ()
  "Incrementally reparse current directory collection.
It does nothing if buffer file not inside one of existing collections."
  (interactive)
  (when-let* ((collections (flatten-tree
			    (sqlite-select
			     augur-db
			     "SELECT name FROM collections;")))
	      (dirs (cl-remove-if-not #'file-directory-p collections))
	      (file (buffer-file-name))
	      (collection (cl-find-if (lambda (dir)
					(file-in-directory-p file dir))
				      dirs)))
    (augur-async-parse-directory collection)))

;;;###autoload
(defun augur-disable-collection (&optional collection)
  "Disable COLLECTION."
  (interactive)
  (let ((col (or collection
		 (completing-read
		  "Disable collection: "
		  augur-enabled-collections))))
    (setq augur-enabled-collections
	  (cl-remove col augur-enabled-collections :test #'string=))))

;;;###autoload
(defun augur-disable-all-collections ()
  "Disable all collections."
  (interactive)
  (mapc #'augur-disable-collection augur-enabled-collections))

;;;###autoload
(defun augur-enable-collection (&optional collection)
  "Enable COLLECTION."
  (interactive)
  (let ((col (or collection
		 (completing-read
		  "Enable collection: "
		  (cl-remove-if
		   (lambda (c)
		     (cl-find c augur-enabled-collections :test #'string=))
		   (flatten-tree
		    (sqlite-select
		     augur-db
		     "SELECT name FROM collections;")))))))
    (push col augur-enabled-collections)))

;;;###autoload
(defun augur-enable-all-collections ()
  "Enable all collections."
  (interactive)
  (let ((all-collections
	 (flatten-tree
	  (sqlite-select
	   augur-db
	   "SELECT DISTINCT name FROM collections;"))))
    (setq augur-enabled-collections
	  (cl-set-difference all-collections augur-enabled-collections :test #'string=))
    (mapc #'augur-enable-collection all-collections)))

;;;###autoload
(defun augur-create-empty-collection (&optional collection)
  "Create new empty COLLECTION."
  (interactive "sNew collection name: ")
  (save-window-excursion
    (sqlite-execute
     augur-db
     (format
      "INSERT INTO collections (name) VALUES ('%s') ON CONFLICT DO NOTHING;"
      (augur-sqlite-escape collection)))))

;;;###autoload
(defun augur-add-file-to-collection (file collection)
  "Add FILE to COLLECTION."
  (interactive
   (list
    (read-file-name "File: ")
    (completing-read
     "Enable collection: "
     (flatten-tree
      (sqlite-select
       augur-db
       "SELECT name FROM collections;")))))
  (let ((collection-id (caar (sqlite-select
			      augur-db
			      (format
			       "SELECT rowid FROM collections WHERE name = '%s';"
			       (augur-sqlite-escape collection))))))
    (augur--async-do (lambda () (augur-parse-file collection-id file)))))

;;;###autoload
(defun augur-add-webpage-to-collection (url collection)
  "Add webpage by URL to COLLECTION."
  (interactive
   (list
    (if-let ((url (or (thing-at-point 'url)
                      (shr-url-at-point nil))))
        url
      (read-string "Enter URL you want to summarize: "))
    (completing-read
     "Enable collection: "
     (flatten-tree
      (sqlite-select
       augur-db
       "SELECT name FROM collections;")))))
  (let ((collection-id (caar (sqlite-select
			      augur-db
			      (format
			       "SELECT rowid FROM collections WHERE name = '%s';"
			       (augur-sqlite-escape collection))))))
    (augur--async-do (lambda () (augur--parse-web-page collection-id url)))))

;;;###autoload
(defun augur-remove-collection (&optional collection)
  "Remove COLLECTION."
  (interactive)
  (let* ((col (or collection
		  (completing-read
		   "Enable collection: "
		   (flatten-tree
		    (sqlite-select
		     augur-db
		     "SELECT name FROM collections;")))))
	 (collection-id (caar (sqlite-select
			       augur-db
			       (format
				"SELECT rowid FROM collections WHERE name = '%s';"
				(augur-sqlite-escape col)))))
	 (delete-ids (flatten-tree
		      (sqlite-select
		       augur-db
		       (format
			"SELECT rowid FROM data WHERE collection_id = %d;"
			collection-id)))))
    (augur-disable-collection col)
    (when (file-directory-p col)
      (let ((files
	     (flatten-tree
	      (sqlite-select
	       augur-db
	       (format
		"SELECT DISTINCT path FROM data WHERE collection_id = %d;"
		collection-id)))))
	(sqlite-execute
	 augur-db
	 (format
	  "DELETE FROM files WHERE path IN %s;"
	  (augur-sqlite-format-string-list files)))))
    (augur--delete-data delete-ids)
    (sqlite-execute
     augur-db
     (format
      "DELETE FROM collections WHERE rowid = %d;"
      collection-id))))

(defun augur--gen-chat (&optional collections)
  "Generate function for chat with augur based on COLLECTIONS."
  (let ((cols (or collections augur-enabled-collections)))
    (lambda (prompt)
      (augur-find-similar
       prompt cols
       (lambda (query) (augur-retrieve-ask query prompt))))))

;;;###autoload
(defun augur-chat (prompt &optional collections)
  "Send PROMPT to augur.
Find similar quotes in COLLECTIONS and add it to context."
  (interactive "sAsk augur: ")
  (let ((cols (or collections augur-enabled-collections)))
    (augur--rewrite-prompt prompt (augur--gen-chat cols))))

(defun augur-recalculate-embeddings ()
  "Recalculate and save new embeddings after embedding provider change."
  (sqlite-execute augur-db "DELETE FROM data WHERE data = '';") ;; remove rows without data
  (let* ((data-rows (sqlite-select augur-db "SELECT rowid, data FROM data;"))
	 (texts (mapcar #'cadr data-rows))
	 (rowids (mapcar #'car data-rows))
	 (embeddings (augur-embeddings texts))
	 (len (length rowids))
	 (i 0))
    ;; Recreate embeddings table
    (sqlite-execute augur-db (augur-data-embeddings-drop-table-sql))
    (sqlite-execute augur-db (augur-data-embeddings-create-table-sql))
    ;; Recalculate embeddings
    (with-sqlite-transaction augur-db
      (while (< i len)
	(let ((rowid (nth i rowids))
	      (embedding (nth i embeddings)))
	  (sqlite-execute
	   augur-db
	   (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%s, %s);"
		   rowid (augur-vector-to-sqlite embedding)))
	  (setq i (1+ i)))))))

;;;###autoload
(defun augur-async-recalculate-embeddings ()
  "Recalculate embeddings asynchronously."
  (interactive)
  (augur--async-do 'augur-recalculate-embeddings))

(provide 'augur)
;;; augur.el ends here.
