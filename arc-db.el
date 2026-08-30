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

;; `make-llm-ollama' is only required lazily, inside the defcustom
;; default-value forms below, so the byte-compiler never sees a
;; top-level `require' for `llm-ollama' to resolve it against.
(declare-function make-llm-ollama "llm-ollama")

(defcustom arc-embeddings-provider (progn (require 'llm-ollama)
					    (make-llm-ollama
					     :embedding-model "nomic-embed-text"))
  "Embeddings provider to generate embeddings."
  :type '(sexp :validate llm-standard-provider-p)
  :group 'arc)

(defcustom arc-chat-provider (progn (require 'llm-ollama)
				      (make-llm-ollama
				       :chat-model "qwen2.5-coder:3b"
				       :embedding-model "nomic-embed-text"))
  "Chat provider."
  :type '(sexp :validate llm-standard-provider-p)
  :group 'arc)

(defcustom arc-db-directory (file-truename
			       (file-name-concat
				user-emacs-directory "arc"))
  "Directory for arc database."
  :type 'directory
  :group 'arc)

(defcustom arc-embedding-size 768
  "Dimension of the embedding vectors arc stores.
Must match the embedding model.  nomic-embed-text is 768.  Changing
this requires reindexing, because the vec0 table is created with a
fixed width."
  :type 'integer :group 'arc)

(defcustom arc-sqlite-vec-path (getenv "ARC_VEC0_PATH")
  "Path to the sqlite-vec (vec0) loadable extension.
Defaults to the ARC_VEC0_PATH environment variable (set by Nix)."
  :type '(choice (const nil) file)
  :group 'arc)

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
  "CREATE TABLE IF NOT EXISTS collections (id INTEGER PRIMARY KEY, name TEXT UNIQUE);")

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

(defun arc--delete-data-for-source (sid)
  "Delete every `data' row for source SID, plus its data_embeddings and
data_fts rows.  data_embeddings and data_fts are virtual tables: they
carry no foreign key, so ON DELETE CASCADE never reaches them, and
their rows must be deleted explicitly by rowid before `data' itself is
deleted -- otherwise reindexing (or removing a source) accumulates
orphan vectors and orphan FTS rows forever, silently corrupting
retrieval."
  (let ((ids (flatten-tree
              (sqlite-select (arc-db) (format "SELECT id FROM data WHERE source_id = %d;" sid)))))
    (when ids
      (let ((idlist (arc-sqlite-format-int-list ids)))
        (sqlite-execute (arc-db) (format "DELETE FROM data_embeddings WHERE rowid IN %s;" idlist))
        (sqlite-execute (arc-db) (format "DELETE FROM data_fts WHERE rowid IN %s;" idlist)))))
  (sqlite-execute (arc-db) (format "DELETE FROM data WHERE source_id = %d;" sid)))

(defun arc-source-delete (id)
  "Delete the source with ID and every chunk, embedding and FTS row that
belongs to it."
  (arc--delete-data-for-source id)
  (sqlite-execute (arc-db) (format "DELETE FROM sources WHERE id = %d;" id))
  nil)

(defun arc--init-db (db)
  "Initialize the arc DB.
A missing or nonexistent `arc-sqlite-vec-path' is a hard error, not a
warning: opening the database without loading vec0 used to silently
skip every CREATE TABLE, so the db \"opened\" successfully but every
table was missing -- the failure only surfaced much later as a
confusing \"no such table: collections\" far from its real cause.
Signal here instead, naming both the variable and the path it tried."
  (unless (and arc-sqlite-vec-path (file-exists-p arc-sqlite-vec-path))
    (error "arc: `arc-sqlite-vec-path' (or ARC_VEC0_PATH) does not point to an existing \
sqlite-vec vec0 extension: %S" arc-sqlite-vec-path))
  (sqlite-pragma db "journal_mode=WAL")
  (sqlite-pragma db "foreign_keys=ON")
  (unless (sqlite-load-extension db arc-sqlite-vec-path)
    ;; `sqlite-load-extension's return value is the *only* place this
    ;; failure surfaces.  It never signals for a file that exists, is on
    ;; Emacs's own basename allow-list, and dlopens cleanly, but does not
    ;; actually register a `vec0' module -- e.g. a real vec0.so copied to
    ;; a wrong-but-allow-listed name such as `rtree.so' or
    ;; `libsqlite3_mod_vec0.so', or an unrelated library (zlib, say)
    ;; copied to a file literally named `vec0.so'.  Left unchecked, that
    ;; keeps `arc--init-db' running for five more statements before it
    ;; fails at `CREATE VIRTUAL TABLE ... USING vec0' with a confusing
    ;; `(sqlite-error "no such module: vec0")' far from its real cause.
    ;; Catch it here instead, naming the path and the likely cause.
    (error "arc: `sqlite-load-extension' returned nil loading `arc-sqlite-vec-path' \
(%S) -- the file exists and its name passed Emacs's allow-list, but it does \
not actually provide a working vec0 module (wrong basename for its real \
entry point, or not a sqlite-vec build at all); keep the file named \
exactly `vec0.so' (or your platform's loadable-module suffix)"
           arc-sqlite-vec-path))
  (sqlite-execute db (arc-collections-create-table-sql))
  (sqlite-execute db (arc-kinds-create-table-sql))
  (sqlite-execute db (arc-fill-kinds-sql))
  (sqlite-execute db (arc-sources-create-table-sql))
  (sqlite-execute db (arc-sources-create-index-sql))
  (sqlite-execute db (arc-data-create-table-sql))
  (sqlite-execute db (arc-data-embeddings-create-table-sql))
  (sqlite-execute db (arc-data-fts-create-table-sql))
  (sqlite-execute db (format "PRAGMA user_version = %d;" arc-db-schema-version)))

(defun arc-db ()
  "Return the arc database connection, opening and initializing it if needed.
If initialization signals (a bad `arc-sqlite-vec-path', for instance),
the half-open handle is closed and `arc--db' is left nil rather than
holding a broken connection -- a caller who fixes the misconfiguration
and calls `arc-db' again must get a fresh, fully-initialized database,
not a table-less one silently reused from a failed first attempt."
  (unless (and arc--db (sqlitep arc--db))
    (make-directory arc-db-directory t)
    (let ((db (sqlite-open (file-name-concat arc-db-directory "arc.sqlite"))))
      (condition-case err
          (progn (arc--init-db db)
                 (setq arc--db db))
        (error (sqlite-close db)
               (signal (car err) (cdr err))))))
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
  "Escape single quotes in STRING for sqlite.
SQL string literals have exactly one escape rule: a single quote is
doubled.  Backslash is an ordinary character to SQLite -- it is NOT an
escape introducer -- so mapping `\\=\\' to `\\=\\\\' here used to
corrupt every backslash a stored chunk contained (46 live chunks did,
quoting shell or elisp) by literally doubling it in the text that
comes back out.  A literal NUL byte is still mapped to a newline: it
cannot survive as a C string inside the SQL text this function's
caller builds by interpolation, backslash or not."
  (let ((reps '(("'" . "''")
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
