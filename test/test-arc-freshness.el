;;; test-arc-freshness.el --- staleness must be visible -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar afr-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path afr-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-test-helpers)

(ert-deftest afr-schema-is-v3-with-provenance ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (should (= 3 (caar (sqlite-select (arc-db) "PRAGMA user_version;"))))
     (should (arc--column-exists-p (arc-db) "collections" "provenance")))))

(ert-deftest afr-migration-adds-provenance-to-a-v2-database ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let ((db (arc-db)))
       (sqlite-execute db "DROP TABLE IF EXISTS collections;")
       (sqlite-execute db "CREATE TABLE collections (id INTEGER PRIMARY KEY, name TEXT UNIQUE);")
       (sqlite-execute db "INSERT INTO collections (name) VALUES ('kept');")
       (sqlite-execute db "PRAGMA user_version = 2;")
       (should-not (arc--column-exists-p db "collections" "provenance"))
       (arc--migrate-db db)
       (should (arc--column-exists-p db "collections" "provenance"))
       (should (= 1 (caar (sqlite-select db "SELECT count(*) FROM collections;"))))
       (should (= 3 (caar (sqlite-select db "PRAGMA user_version;"))))))))

(ert-deftest afr-provenance-round-trips ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (arc--collection-id "c")
     (should (null (arc-collection-provenance "c")))
     (arc-set-collection-provenance "c" "flake.lock:abc")
     (should (equal "flake.lock:abc" (arc-collection-provenance "c"))))))

(ert-deftest afr-derived-kinds-have-a-provenance-and-mutable-ones-do-not ()
  "The whole design: two mechanisms, chosen by kind."
  (should (member "file" arc-freshness-per-source-kinds))
  (should (member "org-node" arc-freshness-per-source-kinds))
  (should (null (arc-collection-provenance-now 'file)))
  (should (null (arc-collection-provenance-now 'org)))
  (should (stringp (arc-collection-provenance-now 'info))))

(ert-deftest afr-a-changed-file-reads-as-stale ()
  (let* ((arc-embedding-size 3)
         (dir (make-temp-file "afr" t))
         (f (expand-file-name "a.txt" dir)))
    (unwind-protect
        (arc-test-with-temp-db
         (with-temp-file f (insert "original content"))
         (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
           (arc-index-source (list :kind "file" :path f
                                   :hash (arc-file-hash f)
                                   :chunks (list (list :text "original content"
                                                       :line-start 1 :line-end 1)))
                             "docs"))
         (let ((arc-index-plan '(("docs" . file))))
           (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))
           (with-temp-file f (insert "edited content"))
           (should (eq 'stale (nth 2 (car (arc-freshness-report)))))
           (should (string-match-p "1 changed" (nth 3 (car (arc-freshness-report)))))))
      (delete-directory dir t))))

(ert-deftest afr-a-deleted-file-reads-as-stale-too ()
  (let* ((arc-embedding-size 3)
         (dir (make-temp-file "afr" t))
         (f (expand-file-name "b.txt" dir)))
    (unwind-protect
        (arc-test-with-temp-db
         (with-temp-file f (insert "hello"))
         (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
           (arc-index-source (list :kind "file" :path f :hash (arc-file-hash f)
                                   :chunks (list (list :text "hello" :line-start 1 :line-end 1)))
                             "docs"))
         (delete-file f)
         (let ((arc-index-plan '(("docs" . file))))
           (should (eq 'stale (nth 2 (car (arc-freshness-report)))))
           (should (string-match-p "1 gone" (nth 3 (car (arc-freshness-report)))))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest afr-changed-provenance-reads-as-stale ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3]))
               ((symbol-function 'arc-collection-provenance-now) (lambda (_) "gen-1")))
       (arc-index-source (list :kind "nix-option" :option-name "services.x.enable"
                               :chunks (list (list :text "opt" :line-start nil :line-end nil)))
                         "nix options")
       (arc-set-collection-provenance "nix options" "gen-1")
       (let ((arc-index-plan '(("nix options" . nixopt))))
         (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))))
     ;; the input moved
     (cl-letf (((symbol-function 'arc-collection-provenance-now) (lambda (_) "gen-2")))
       (let ((arc-index-plan '(("nix options" . nixopt))))
         (should (eq 'stale (nth 2 (car (arc-freshness-report))))))))))

(ert-deftest afr-missing-provenance-is-unknown-not-fresh ()
  "An index built before provenance existed must not claim freshness."
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3]))
               ((symbol-function 'arc-collection-provenance-now) (lambda (_) "gen-1")))
       (arc-index-source (list :kind "info" :info-node "(x)Y"
                               :chunks (list (list :text "t" :line-start nil :line-end nil)))
                         "builtin manuals")
       (let ((arc-index-plan '(("builtin manuals" . info))))
         (should (eq 'unknown (nth 2 (car (arc-freshness-report))))))))))

(ert-deftest afr-never-indexed-reads-as-absent ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let ((arc-index-plan '(("nothing here" . file))))
       (should (eq 'absent (nth 2 (car (arc-freshness-report)))))))))

;;; partial: indexed content current, but the walk would index more ------

(defmacro afr-with-dir-collection (dir-var &rest body)
  "Run BODY with DIR-VAR a fresh directory planned as collection \"docs\"."
  (declare (indent 1))
  `(let* ((arc-embedding-size 3)
          (,dir-var (file-name-as-directory (make-temp-file "afr-dir" t)))
          (arc-index-plan '(("docs" . file)))
          (arc-collection-directory-alist (list (cons "docs" ,dir-var))))
     (unwind-protect
         (arc-test-with-temp-db
          (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
            ,@body))
       (delete-directory ,dir-var t))))

(defun afr-write (dir name text)
  (let ((f (expand-file-name name dir)))
    (with-temp-file f (insert text))
    f))

(ert-deftest afr-a-collection-missing-files-on-disk-is-partial-not-fresh ()
  "The bug: freshness compared only sources already indexed, so a
collection holding 1 source out of thousands on disk read `fresh'."
  (afr-with-dir-collection dir
    (let ((a (afr-write dir "a.txt" "alpha"))
          (_b (afr-write dir "b.txt" "beta"))
          (_c (afr-write dir "c.txt" "gamma")))
      (arc-index-source (arc-file-source a) "docs")
      (let ((row (car (arc-freshness-report))))
        (should (eq 'partial (nth 2 row)))
        (should (equal "2 unindexed" (nth 3 row))))
      (should (string-match-p "1 partial" (arc-freshness-summary))))))

(ert-deftest afr-a-fully-indexed-collection-is-still-fresh ()
  (afr-with-dir-collection dir
    (afr-write dir "a.txt" "alpha")
    (afr-write dir "b.txt" "beta")
    (arc-reindex-all)
    (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))))

(ert-deftest afr-files-that-yield-no-source-are-not-unindexed ()
  "An empty file, a whitespace-only one and a binary one are candidates
by path and still produce nothing: they must not hold a collection in
`partial' forever."
  (afr-with-dir-collection dir
    (afr-write dir "a.txt" "alpha")
    (afr-write dir "empty.txt" "")
    (afr-write dir "blank.txt" "  \n\n \t\n")
    (afr-write dir "bin.dat" (concat "x" (string 0) "y"))
    (arc-reindex-all)
    (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))))

(ert-deftest afr-an-org-file-with-no-id-is-not-unindexed ()
  (let* ((arc-embedding-size 3)
         (dir (file-name-as-directory (make-temp-file "afr-org" t)))
         (arc-index-plan '(("notes" . org)))
         (arc-collection-directory-alist (list (cons "notes" dir))))
    (unwind-protect
        (arc-test-with-temp-db
         (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
           (afr-write dir "with-id.org" ":PROPERTIES:\n:ID: aaaa-1\n:END:\n#+title: A\nbody\n")
           (afr-write dir "no-id.org" "#+title: B\njust text\n")
           (arc-reindex-all)
           (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))
           (afr-write dir "new.org" ":PROPERTIES:\n:ID: bbbb-2\n:END:\n#+title: C\nmore\n")
           (should (eq 'partial (nth 2 (car (arc-freshness-report)))))))
      (delete-directory dir t))))

(ert-deftest afr-drift-plus-missing-is-stale-and-says-both ()
  (afr-with-dir-collection dir
    (let ((a (afr-write dir "a.txt" "alpha")))
      (arc-index-source (arc-file-source a) "docs")
      (afr-write dir "a.txt" "alpha edited")
      (afr-write dir "b.txt" "beta")
      (let ((row (car (arc-freshness-report))))
        (should (eq 'stale (nth 2 row)))
        (should (equal "1 changed, 1 unindexed" (nth 3 row)))))))

(ert-deftest afr-the-probe-bound-turns-the-count-into-a-floor ()
  (afr-with-dir-collection dir
    (let ((a (afr-write dir "a.txt" "alpha"))
          (arc-freshness-unindexed-probe-max 2))
      (dotimes (i 5) (afr-write dir (format "n%d.txt" i) "new"))
      (arc-index-source (arc-file-source a) "docs")
      (let ((row (car (arc-freshness-report))))
        (should (eq 'partial (nth 2 row)))
        (should (equal "at least 2 unindexed" (nth 3 row)))))))

(ert-deftest afr-unread-candidates-that-yielded-nothing-are-unknown ()
  "Every candidate read so far yielded no source, and the bound stopped
the reading: that is no evidence either way, so neither fresh nor partial."
  (afr-with-dir-collection dir
    (let ((a (afr-write dir "a.txt" "alpha"))
          (arc-freshness-unindexed-probe-max 1))
      (afr-write dir "e1.txt" "")
      (afr-write dir "e2.txt" "")
      (arc-index-source (arc-file-source a) "docs")
      (should (eq 'unknown (nth 2 (car (arc-freshness-report))))))))

(ert-deftest afr-summary-is-nil-when-everything-is-fresh ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let ((arc-index-plan nil))
       (should (null (arc-freshness-summary)))))))
