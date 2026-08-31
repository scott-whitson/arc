;;; test-arc-fts-locator.el --- the keyword arm must see identifiers -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar afl-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path afl-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-test-helpers)

(defmacro afl-with-indexed (&rest body)
  "Index one file source whose CONTENT never names its own path, then BODY."
  (declare (indent 0))
  `(let ((arc-embedding-size 3))
     (arc-test-with-temp-db
      (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
        (arc-index-source
         (list :kind "file" :path "/home/u/dotfiles/ioshi/hi-hardware/disko/rafik.nix"
               :chunks (list (list :text "fileSystems.\"/\".device = \"/dev/disk/by-label/nixos\";"
                                   :line-start 1 :line-end 1)))
         "dots")
        (arc-index-source
         (list :kind "hm-option" :option-name "programs.zsh.enable"
               :chunks (list (list :text "Whether to enable Z shell." :line-start nil :line-end nil)))
         "hm")
        ,@body))))

(defun afl--fts-search (q)
  "Return the chunk ids matching Q, via the real FTS query builder."
  (flatten-tree
   (sqlite-select (arc-db)
                  (format "SELECT rowid FROM data_fts WHERE data_fts MATCH '%s';"
                          (arc-fts-query q)))))

(ert-deftest afl-a-path-is-searchable-though-the-content-never-names-it ()
  "The defect this exists for: 0 of 8548 file chunks contained their own
path, so a question naming a FILE could not match it."
  (afl-with-indexed
    (should (afl--fts-search "disko rafik"))
    ;; and the chunk text really does not contain those words
    (let ((chunk (caar (sqlite-select (arc-db)
                                      "SELECT chunk FROM data WHERE chunk LIKE '%fileSystems%';"))))
      (should-not (string-match-p "disko" chunk))
      (should-not (string-match-p "rafik" chunk)))))

(ert-deftest afl-an-option-name-is-searchable ()
  (afl-with-indexed
    (should (afl--fts-search "programs zsh enable"))))

(ert-deftest afl-the-chunk-text-itself-is-unchanged ()
  "Only `data_fts' gains the locator. `data.chunk' is what the model is
shown and what citations quote; polluting it would change answers."
  (afl-with-indexed
    (let ((chunks (flatten-tree (sqlite-select (arc-db) "SELECT chunk FROM data;"))))
      (should (cl-every (lambda (c) (not (string-match-p "disko/rafik" c))) chunks)))))

(ert-deftest afl-rebuild-agrees-with-the-insert-path ()
  "`arc--fts-locator' (elisp, insert time) and `arc--fts-locator-sql'
(SQL, rebuild time) are two spellings of one rule. If they drift, a
rebuild silently changes what is searchable."
  (afl-with-indexed
    (let ((before (sqlite-select (arc-db) "SELECT rowid, data FROM data_fts ORDER BY rowid;")))
      (arc-index-rebuild-fts)
      (should (equal before
                     (sqlite-select (arc-db) "SELECT rowid, data FROM data_fts ORDER BY rowid;"))))))

(ert-deftest afl-rebuild-does-not-touch-embeddings ()
  "The whole point of the rebuild being cheap."
  (afl-with-indexed
    (let ((before (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;")))
      (arc-index-rebuild-fts)
      (should (equal before (sqlite-select (arc-db) "SELECT count(*) FROM data_embeddings;"))))))

(ert-deftest afl-rebuild-is-idempotent ()
  (afl-with-indexed
    (arc-index-rebuild-fts)
    (let ((once (sqlite-select (arc-db) "SELECT rowid, data FROM data_fts ORDER BY rowid;")))
      (arc-index-rebuild-fts)
      (should (equal once (sqlite-select (arc-db) "SELECT rowid, data FROM data_fts ORDER BY rowid;"))))))

(ert-deftest afl-rebuild-bumps-the-write-generation ()
  "The header line's cache must notice."
  (afl-with-indexed
    (let ((before arc-index--write-generation))
      (arc-index-rebuild-fts)
      (should (> arc-index--write-generation before)))))
