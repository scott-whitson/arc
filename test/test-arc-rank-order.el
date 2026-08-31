;;; test-arc-rank-order.el --- retrieval must keep the order it ranked in -*- lexical-binding: t; -*-
;;
;; This file exists because arc--retrieve-rows shipped for three phases with
;; `WHERE d.id IN (...)' and no ORDER BY, so SQLite returned rows in rowid
;; order and the hybrid ranking was discarded between the search and the
;; answer.  Nothing caught it: every suite asserted WHICH rows came back, none
;; asserted their ORDER.  It surfaced only when arc-eval's recall@5 changed
;; depending on how many candidates were requested -- impossible for a real
;; ranking.
;;
;; KNOWN LIMIT OF THESE TESTS, stated rather than discovered later: reverting
;; to the original bare `IN (...)' fails four of them, but deleting only the
;; `ORDER BY ordered.n' while keeping the ordinal CTE fails NONE.  Measured,
;; not assumed.  SQLite currently drives the join from the VALUES list and so
;; emits rows in ordinal order anyway, which makes the ORDER BY redundant in
;; practice and impossible to catch from here.  It stays exactly because of
;; that: this package has already been bitten once by output that was correct
;; only because of a query-planner choice nobody asked for -- see the comment
;; in `arc--find-similar' about CTE flattening -- and a second reliance on the
;; planner's goodwill is not a thing to leave uncommented.
(require 'ert)
(require 'cl-lib)
(defvar aro-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aro-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(defun aro--seed (n)
  "Insert N chunks whose text is their ordinal.  Return their ids, ascending."
  (let ((db (arc-db)) ids)
    (dotimes (i n)
      (let ((sid (arc-source-upsert (list :kind "file" :path (format "/tmp/aro-%d.txt" i)))))
        (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, NULL, 'chunk-%d');" sid i))
        (push (caar (sqlite-select db "SELECT last_insert_rowid();")) ids)))
    (nreverse ids)))

(defun aro--chunks-of (rows)
  "Return the chunk column of ROWS, in the order given."
  (mapcar (lambda (r) (nth 5 r)) rows))

(ert-deftest aro-preserves-a-reversed-order ()
  "Ask in descending id order; rows must come back descending."
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let* ((ids (aro--seed 6))
            (want (reverse ids)))
       (should (equal (aro--chunks-of (arc--retrieve-rows want))
                      (mapcar (lambda (i) (format "chunk-%d" i)) '(5 4 3 2 1 0))))))))

(ert-deftest aro-preserves-an-arbitrary-order ()
  "A ranking is not sorted by id, so an arbitrary permutation must survive."
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let* ((ids (aro--seed 6))
            (perm (list (nth 3 ids) (nth 0 ids) (nth 5 ids) (nth 1 ids))))
       (should (equal (aro--chunks-of (arc--retrieve-rows perm))
                      '("chunk-3" "chunk-0" "chunk-5" "chunk-1")))))))

(ert-deftest aro-order-is-not-merely-sqlite-agreeing-by-luck ()
  "Guard against a false pass: confirm SQLite's own unordered answer for the
same ids really is different, so the test is testing the ORDER BY."
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let* ((ids (aro--seed 6))
            (want (reverse ids))
            (unordered (aro--chunks-of
                        (sqlite-select
                         (arc-db)
                         (format "SELECT s.kind, s.path, s.info_node, s.org_id,
                                         s.option_name, d.chunk, d.line_start,
                                         d.line_end, d.title
                                  FROM data d JOIN sources s ON s.id = d.source_id
                                  WHERE d.id IN %s;"
                                 (arc-sqlite-format-int-list want))))))
       (should-not (equal unordered (aro--chunks-of (arc--retrieve-rows want))))))))

(ert-deftest aro-empty-ids-still-returns-nil ()
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (should (null (arc--retrieve-rows nil))))))

(ert-deftest aro-duplicate-ids-do-not-multiply-rows ()
  "The ordinal join would emit a row per (id, n) pair, so the same chunk
could reach the model twice.  `IN (...)' deduplicated for free; this must
too, keeping each id's best-ranked position."
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let ((ids (aro--seed 3)))
       (should (= 3 (length (arc--retrieve-rows (append ids ids)))))
       ;; and the surviving order is the first occurrence's
       (should (equal (aro--chunks-of
                       (arc--retrieve-rows (list (nth 2 ids) (nth 0 ids) (nth 2 ids))))
                      '("chunk-2" "chunk-0")))))))

;;; Per-arm SQL --------------------------------------------------------------

(ert-deftest aro-semantic-arm-omits-the-keyword-cte ()
  (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
    (let ((sql (arc--find-similar "q" nil 'semantic)))
      (should (string-match-p "semantic_search" sql))
      (should-not (string-match-p "keyword_search" sql)))))

(ert-deftest aro-keyword-arm-omits-the-semantic-cte-and-never-embeds ()
  "Embedding for a keyword-only run is wasted work, and on a large scope the
brute-force distance pass is not cheap."
  (let ((embedded nil))
    (cl-letf (((symbol-function 'llm-embedding)
               (lambda (_p _t) (setq embedded t) [1.0 0.0 0.0])))
      (let ((sql (arc--find-similar "q" nil 'keyword)))
        (should (string-match-p "keyword_search" sql))
        (should-not (string-match-p "semantic_search" sql))
        (should-not embedded)))))

(ert-deftest aro-fused-arm-has-both-and-carries-the-weight ()
  (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
    (let* ((arc-rrf-semantic-weight 3)
           (sql (arc--find-similar "q" nil)))
      (should (string-match-p "semantic_search" sql))
      (should (string-match-p "keyword_search" sql))
      ;; regexp-quote, not a hand-written pattern: `+' is a postfix operator
      ;; in an Emacs regexp, so " + " matches one-or-more spaces and never the
      ;; literal plus this SQL contains.
      (should (string-match-p
               (regexp-quote "3.000000 / (60 + semantic_search.rank)") sql)))))

(ert-deftest aro-defaults-are-the-measured-ones ()
  "Pinned deliberately: these three were chosen from a 33-question sweep, and
a silent revert would undo measured recall with nothing to notice."
  (should (= 10 (default-value 'arc-limit)))
  (should (= 2 (default-value 'arc-rrf-semantic-weight)))
  (should (= 60 (default-value 'arc-rrf-k))))
