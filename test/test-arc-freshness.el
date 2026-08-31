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

(ert-deftest afr-summary-is-nil-when-everything-is-fresh ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let ((arc-index-plan nil))
       (should (null (arc-freshness-summary)))))))

(ert-deftest afr-header-line-shows-staleness-and-caches-it ()
  (require 'arc-ui)
  (let ((calls 0)
        (arc--freshness-cache nil)
        (arc-index--stats-cache nil)
        (arc-index--write-generation 0)
        (arc-freshness-cache-ttl 60))
    (cl-letf (((symbol-function 'arc-index-stats) (lambda () '(("file" . 3))))
              ((symbol-function 'arc-freshness-summary)
               (lambda () (setq calls (1+ calls)) "dotfiles stale")))
      (should (string-match-p "dotfiles stale" (arc-ui-header-line)))
      (dotimes (_ 5) (arc-ui-header-line))
      (should (= calls 1)))))

(ert-deftest afr-header-line-says-fresh-when-it-is ()
  (require 'arc-ui)
  (let ((arc--freshness-cache nil) (arc-index--stats-cache nil))
    (cl-letf (((symbol-function 'arc-index-stats) (lambda () '(("file" . 3))))
              ((symbol-function 'arc-freshness-summary) (lambda () nil)))
      (should (string-match-p "fresh" (arc-ui-header-line))))))

(ert-deftest afr-header-line-survives-a-freshness-error ()
  "It must never break the buffer it heads."
  (require 'arc-ui)
  (let ((arc--freshness-cache nil) (arc-index--stats-cache nil))
    (cl-letf (((symbol-function 'arc-index-stats) (lambda () '(("file" . 3))))
              ((symbol-function 'arc-freshness-summary)
               (lambda () (error "no such column"))))
      (should (string-match-p "unknown" (arc-ui-header-line))))))
