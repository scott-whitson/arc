;;; arc-db.el --- arc schema and source rows -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The `sources' table is arc's departure from upstream ELISA: every chunk
;; points at a row that knows precisely where it came from, which is what
;; makes a jumpable citation possible.
;;; Code:

(require 'sqlite)
(require 'json)

(defcustom arc-embeddings-provider (progn (require 'llm-ollama)
					    (make-llm-ollama
					     :embedding-model "nomic-embed-text"))
  "Embeddings provider to generate embeddings."
  :type '(sexp :validate llm-standard-provider-p))

(defcustom arc-chat-provider (progn (require 'llm-ollama)
				      (make-llm-ollama
				       :chat-model "qwen2.5-coder:3b"
				       :embedding-model "nomic-embed-text"))
  "Chat provider."
  :type '(sexp :validate llm-standard-provider-p))

(defcustom arc-db-directory (file-truename
			       (file-name-concat
				user-emacs-directory "arc"))
  "Directory for arc database."
  :type 'directory)

(defcustom arc-embedding-size 768
  "Dimension of the embedding vectors arc stores.
Must match the embedding model.  nomic-embed-text is 768.  Changing
this requires reindexing, because the vec0 table is created with a
fixed width."
  :type 'integer :group 'arc)

(defcustom arc-sqlite-vec-path (getenv "ARC_VEC0_PATH")
  "Path to the sqlite-vec (vec0) loadable extension.
Defaults to the ARC_VEC0_PATH environment variable (set by Nix)."
  :type '(choice (const nil) file))

(defvar arc--db nil
  "Live sqlite connection, or nil before first use.")

(defun arc-embeddings-create-table-sql ()
  "Generate sql for create embeddings table."
  "DROP TABLE IF EXISTS arc_embeddings;")

(defun arc-data-embeddings-create-table-sql ()
  "Generate sql for creating the vec0 embeddings table."
  (format "CREATE VIRTUAL TABLE IF NOT EXISTS data_embeddings USING vec0(embedding float[%d]);"
	  arc-embedding-size))

(defun arc-data-fts-create-table-sql ()
  "Generate sql for create full text search table."
  "CREATE VIRTUAL TABLE IF NOT EXISTS data_fts USING FTS5(data);")

(defun arc-info-create-table-sql ()
  "Generate sql for create info table."
  "DROP TABLE IF EXISTS info;")

(defun arc-collections-create-table-sql ()
  "Generate sql for create collections table."
  "CREATE TABLE IF NOT EXISTS collections (name TEXT UNIQUE);")

(defun arc-kinds-create-table-sql ()
  "Generate sql for create kinds table."
  "CREATE TABLE IF NOT EXISTS kinds (name TEXT UNIQUE);")

(defconst arc-kind-list '("file" "info" "org-node" "nix-option" "hm-option")
  "The source kinds arc understands, in schema order.")

(defun arc-kinds ()
  "Return the list of source kinds arc understands."
  arc-kind-list)

(defun arc-fill-kinds-sql ()
  "Generate sql for filling the kinds table."
  (format "INSERT INTO kinds (name) VALUES %s ON CONFLICT DO NOTHING;"
          (mapconcat (lambda (k) (format "('%s')" k)) arc-kind-list ", ")))

(defconst arc-db-schema-version 1
  "Current schema version.  Bump when adding a migration.")

(defun arc-db-schema-version ()
  "Return the schema version recorded in the open database."
  (caar (sqlite-select (arc-db) "PRAGMA user_version;")))

(defun arc-sources-create-table-sql ()
  "Generate sql for creating the sources table."
  "CREATE TABLE IF NOT EXISTS sources (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  path TEXT,
  org_id TEXT,
  option_name TEXT,
  info_node TEXT,
  hash TEXT,
  mtime INTEGER,
  indexed_at INTEGER
);")

(defun arc-sources-create-index-sql ()
  "Generate sql for the sources uniqueness index.
A source is identified by its kind plus whichever locator that kind
uses; COALESCE folds the unused columns to a constant so one index
covers all five kinds."
  "CREATE UNIQUE INDEX IF NOT EXISTS sources_identity
   ON sources (kind,
               COALESCE(path,''),
               COALESCE(org_id,''),
               COALESCE(option_name,''),
               COALESCE(info_node,''));")

(defun arc-data-create-table-sql ()
  "Generate sql for creating the data table."
  "CREATE TABLE IF NOT EXISTS data (
  id INTEGER PRIMARY KEY,
  source_id INTEGER REFERENCES sources(id) ON DELETE CASCADE,
  collection_id INTEGER REFERENCES collections(id),
  chunk TEXT,
  line_start INTEGER,
  line_end INTEGER,
  title TEXT
);")

(defun arc--sql-quote (value)
  "Return VALUE as a SQL literal: a quoted string, or NULL when nil."
  (if (null value) "NULL" (format "'%s'" (arc-sqlite-escape (format "%s" value)))))

(defun arc-source-upsert (plist)
  "Insert or update the source described by PLIST.  Return its id.
PLIST keys: :kind (required), :path, :org-id, :option-name, :info-node,
:hash, :mtime."
  (let ((kind (or (plist-get plist :kind) (error "arc: source needs a :kind"))))
    (unless (member kind arc-kind-list)
      (error "arc: unknown source kind %S" kind))
    (sqlite-execute
     (arc-db)
     (format "INSERT INTO sources (kind, path, org_id, option_name, info_node, hash, mtime, indexed_at)
              VALUES (%s, %s, %s, %s, %s, %s, %s, %d)
              ON CONFLICT (kind, COALESCE(path,''), COALESCE(org_id,''),
                           COALESCE(option_name,''), COALESCE(info_node,''))
              DO UPDATE SET hash = excluded.hash,
                            mtime = excluded.mtime,
                            indexed_at = excluded.indexed_at;"
             (arc--sql-quote kind)
             (arc--sql-quote (plist-get plist :path))
             (arc--sql-quote (plist-get plist :org-id))
             (arc--sql-quote (plist-get plist :option-name))
             (arc--sql-quote (plist-get plist :info-node))
             (arc--sql-quote (plist-get plist :hash))
             (or (plist-get plist :mtime) "NULL")
             (truncate (float-time))))
    (caar (sqlite-select
           (arc-db)
           (format "SELECT id FROM sources WHERE kind = %s
                    AND COALESCE(path,'') = COALESCE(%s,'')
                    AND COALESCE(org_id,'') = COALESCE(%s,'')
                    AND COALESCE(option_name,'') = COALESCE(%s,'')
                    AND COALESCE(info_node,'') = COALESCE(%s,'');"
                   (arc--sql-quote kind)
                   (arc--sql-quote (plist-get plist :path))
                   (arc--sql-quote (plist-get plist :org-id))
                   (arc--sql-quote (plist-get plist :option-name))
                   (arc--sql-quote (plist-get plist :info-node)))))))

(defun arc--source-row-to-plist (row)
  "Convert a sources ROW to a plist."
  (when row
    (list :id (nth 0 row) :kind (nth 1 row) :path (nth 2 row)
          :org-id (nth 3 row) :option-name (nth 4 row)
          :info-node (nth 5 row) :hash (nth 6 row) :mtime (nth 7 row))))

(defun arc-source-get (id)
  "Return the source with ID as a plist, or nil."
  (arc--source-row-to-plist
   (car (sqlite-select
         (arc-db)
         (format "SELECT id, kind, path, org_id, option_name, info_node, hash, mtime
                  FROM sources WHERE id = %d;" id)))))

(defun arc-source-by-path (path)
  "Return the file source for PATH as a plist, or nil."
  (arc--source-row-to-plist
   (car (sqlite-select
         (arc-db)
         (format "SELECT id, kind, path, org_id, option_name, info_node, hash, mtime
                  FROM sources WHERE kind = 'file' AND path = %s;"
                 (arc--sql-quote path))))))

(defun arc-source-delete (id)
  "Delete the source with ID and every chunk that belongs to it."
  (sqlite-execute (arc-db) (format "DELETE FROM data WHERE source_id = %d;" id))
  (sqlite-execute (arc-db) (format "DELETE FROM sources WHERE id = %d;" id))
  nil)

(defun arc--init-db (db)
  "Initialize the arc DB."
  (if (not (and arc-sqlite-vec-path (file-exists-p arc-sqlite-vec-path)))
      (warn "Set `arc-sqlite-vec-path' (or ARC_VEC0_PATH) to the sqlite-vec vec0 extension")
    (sqlite-pragma db "PRAGMA journal_mode=WAL;")
    (sqlite-pragma db "PRAGMA foreign_keys=ON;")
    (sqlite-load-extension db arc-sqlite-vec-path)
    (sqlite-execute db (arc-collections-create-table-sql))
    (sqlite-execute db (arc-kinds-create-table-sql))
    (sqlite-execute db (arc-fill-kinds-sql))
    (sqlite-execute db (arc-sources-create-table-sql))
    (sqlite-execute db (arc-sources-create-index-sql))
    (sqlite-execute db (arc-data-create-table-sql))
    (sqlite-execute db (arc-data-embeddings-create-table-sql))
    (sqlite-execute db (arc-data-fts-create-table-sql))
    (sqlite-execute db (format "PRAGMA user_version = %d;" arc-db-schema-version))))

(defun arc-db ()
  "Return the arc database connection, opening and initializing it if needed."
  (unless (and arc--db (sqlitep arc--db))
    (make-directory arc-db-directory t)
    (setq arc--db (sqlite-open (file-name-concat arc-db-directory "arc.sqlite")))
    (arc--init-db arc--db))
  arc--db)

(defun arc-close-db ()
  "Close the arc database connection, if open."
  (interactive)
  (when (and arc--db (sqlitep arc--db))
    (sqlite-close arc--db))
  (setq arc--db nil))

(defun arc-vector-to-sqlite (data)
  "Convert DATA to sqlite vector representation."
  (format "vec_f32('%s')" (json-encode data)))

(defun arc-sqlite-escape (string)
  "Escape single quotes in STRING for sqlite."
  (let ((reps '(("'" . "''")
                ("\\" . "\\\\")
                ("\0" . "\n"))))
    (replace-regexp-in-string
     (regexp-opt (mapcar #'car reps))
     (lambda (str) (alist-get str reps nil nil #'string=))
     string nil t)))

(defun arc-sqlite-format-int-list (ids)
  "Convert list of integer IDS list to sqlite list representation."
  (format
   "(%s)"
   (mapconcat (lambda (id) (format "%d" id)) ids ", ")))

(defun arc-sqlite-format-string-list (names)
  "Convert list of string NAMES list to sqlite list representation."
  (format
   "(%s)"
   (mapconcat (lambda (name)
		(format "'%s'"
			(arc-sqlite-escape name)))
              names ", ")))

(provide 'arc-db)
;;; arc-db.el ends here
