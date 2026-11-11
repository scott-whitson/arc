;;; arc-eval.el --- measure what retrieval actually returns -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A question set paired with the sources that SHOULD come back, and a recall
;; number over it.  This exists because every remaining question about arc --
;; is a different embedding model better, is a newer chat model better, is the
;; brute-force threshold right, does a scope change help -- is unanswerable
;; without a measurement, and this project has already shipped several things
;; that looked fine while retrieving nothing.
;;
;; It measures RETRIEVAL ONLY and never calls the chat model.  That keeps a run
;; fast and deterministic, and recall@k is a property of retrieval anyway; a
;; model that writes a lovely paragraph from the wrong five chunks is the
;; failure this is meant to catch, not hide.
;;
;; The question set lives OUTSIDE this repo by default.  A set worth having
;; names real targets -- vault paths, org ids, option names -- and this repo is
;; public, so committing one would publish the shape of a private vault.  A
;; small synthetic set ships under test/fixtures/ so the harness itself stays
;; tested without that.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'arc)
(require 'arc-scope)
(require 'arc-search)
(require 'arc-rollup)
(require 'arc-index)

(defcustom arc-eval-set-file
  (expand-file-name "docs/org/arc-eval.eld" (getenv "HOME"))
  "File holding the eval question set, as a single elisp list.
Deliberately outside this package: a real set names real paths and ids,
and this repo is public.  See `arc-eval-sample-file' for the shape."
  :type 'file :group 'arc)

(defcustom arc-eval-k '(5 10)
  "Cutoffs to report recall at."
  :type '(repeat integer) :group 'arc)

(defconst arc-eval-buffer-name "*arc-eval*"
  "Buffer the report renders into.")

;;; The question set ---------------------------------------------------------

;; One entry is a plist:
;;
;;   (:question "how do I enable syncthing in home-manager"
;;    :scope    (:collections ("hm options"))     ; optional; nil = enabled set
;;    :expect   ((:kind "hm-option" :option-name "services.syncthing.enable")))
;;
;; Every key in an :expect clause must match for that clause to count as
;; retrieved.  :path-suffix matches the tail of a source's path, so a set stays
;; portable across machines rather than hardcoding one operator's $HOME.
;;
;; :expect is an AND of OR-groups.  Each element is one group the question
;; needs; a plain clause is a group of one, and (:any CLAUSE CLAUSE ...) is a
;; group any of whose members counts.  So
;;
;;   :expect ((:any (:path-suffix "a.nix") (:path-suffix "b.nix"))
;;            (:option-name "services.foo.enable"))
;;
;; needs the option AND either file.  A set written before groups existed is
;; read exactly as before: one group per clause.
;;
;; :negative t marks a question whose correct answer is "nothing in this
;; corpus"; it carries no :expect.  Negatives score no recall -- there is
;; nothing to recall -- and exist to measure how a retrieval that should
;; refuse looks, which is what `arc-retrieval-max-distance' would be set from.
;;
;; :split dev or :split test assigns a question to a half; see
;; `arc-eval-question-split' for the rule when it is absent.

(defun arc-eval-read-set (file)
  "Read the question set in FILE.  Signal a `user-error' if it is unusable."
  (unless (file-exists-p file)
    (user-error "arc-eval: no question set at %s (see `arc-eval-set-file')" file))
  (let ((set (with-temp-buffer
               (insert-file-contents file)
               (goto-char (point-min))
               (read (current-buffer)))))
    (unless (and (listp set) set)
      (user-error "arc-eval: %s does not contain a non-empty list" file))
    (dolist (q set)
      (unless (stringp (plist-get q :question))
        (user-error "arc-eval: an entry has no :question string: %S" q))
      (if (plist-get q :negative)
          (when (plist-get q :expect)
            (user-error "arc-eval: %S is :negative and also has :expect clauses"
                        (plist-get q :question)))
        (unless (plist-get q :expect)
          (user-error "arc-eval: %S has no :expect clauses" (plist-get q :question))))
      (dolist (e (plist-get q :expect))
        (when (and (eq (car-safe e) :any) (null (cdr e)))
          (user-error "arc-eval: %S has an empty (:any) group" (plist-get q :question))))
      (unless (memq (plist-get q :split) '(nil dev test))
        (user-error "arc-eval: %S has :split %S (want dev or test)"
                    (plist-get q :question) (plist-get q :split))))
    set))

(defun arc-eval--groups (q)
  "Return question Q's expectation groups: a list of lists of clauses.
Every group must be retrieved; any one member of a group retrieves it.
A plain :expect clause is a group of one, which is how a set written
before groups existed keeps scoring exactly as it did."
  (mapcar (lambda (e) (if (eq (car-safe e) :any) (cdr e) (list e)))
          (plist-get q :expect)))

(defun arc-eval-question-split (q)
  "Return question Q's split, `dev' or `test'.
Q's own :split when it has one; otherwise decided by a stable hash of
the question text, about 70% `dev'.  Stable is the point: the
assignment must not move when the set is reordered, grown or re-read,
or a configuration tuned on `dev' could be scored on questions it was
tuned against.  The hash is the first 32 bits of the text's SHA-1, so
the rule is reproducible outside Emacs too."
  (or (plist-get q :split)
      (if (< (mod (string-to-number
                   (substring (secure-hash 'sha1 (plist-get q :question)) 0 8) 16)
                  100)
             70)
          'dev
        'test)))

(defun arc-eval-split (set split)
  "Return the questions of SET in SPLIT (`dev' or `test'); nil SPLIT is all."
  (if split
      (seq-filter (lambda (q) (eq (arc-eval-question-split q) split)) set)
    set))

;;; Matching ----------------------------------------------------------------

(defun arc-eval--source-matches-p (source expect)
  "Return non-nil when retrieved SOURCE satisfies every key in EXPECT.
Unknown keys are a hard error rather than a silent non-match: a typo in a
question set would otherwise read as a retrieval failure forever."
  (cl-loop for (key want) on expect by #'cddr
           always (pcase key
                    (:kind        (equal want (plist-get source :kind)))
                    (:option-name (equal want (plist-get source :option-name)))
                    (:org-id      (equal want (plist-get source :org-id)))
                    (:info-node   (equal want (plist-get source :info-node)))
                    (:path        (equal want (plist-get source :path)))
                    (:path-suffix (let ((p (plist-get source :path)))
                                    (and p (string-suffix-p want p))))
                    (_ (error "arc-eval: unknown :expect key %S" key)))))

(defun arc-eval--rank-of (expect sources)
  "Return the 1-based position of the first SOURCE matching EXPECT, or nil."
  (cl-loop for s in sources
           for i from 1
           when (arc-eval--source-matches-p s expect) return i))

(defun arc-eval--group-rank (group sources)
  "Return the 1-based position of the first SOURCE matching any of GROUP."
  (cl-loop for s in sources
           for i from 1
           when (cl-some (lambda (e) (arc-eval--source-matches-p s e)) group)
           return i))

(defun arc-eval--expect-sql (expect)
  "Return a SQL WHERE fragment matching sources satisfying EXPECT."
  (string-join
   (cl-loop for (key want) on expect by #'cddr
            collect (pcase key
                      (:kind        (format "kind = %s" (arc--sql-quote want)))
                      (:option-name (format "option_name = %s" (arc--sql-quote want)))
                      (:org-id      (format "org_id = %s" (arc--sql-quote want)))
                      (:info-node   (format "info_node = %s" (arc--sql-quote want)))
                      (:path        (format "path = %s" (arc--sql-quote want)))
                      (:path-suffix (format "path LIKE %s"
                                            (arc--sql-quote (concat "%" want))))
                      (_ (error "arc-eval: unknown :expect key %S" key))))
   " AND "))

(defun arc-eval-validate (&optional set sources)
  "Check every :expect clause in SET names a source that EXISTS.
Returns a list of (QUESTION . EXPECT) for the clauses that resolve to
nothing.  Every member of an (:any ...) group is checked on its own: a
typo in one member is still a typo, even when another member exists.

By default \"exists\" means a row in the database.  With SOURCES -- a
list of source plists, such as `arc-eval-plan-sources' returns -- it
means a match among them instead, which is how a set is checked
against what a reindex WILL build before the reindex has finished.

This is not optional rigour, it is the difference between a benchmark
and a wish. An expectation naming a source the corpus does not contain
is indistinguishable, in a recall number, from retrieval failing to
find one -- and it is unfixable by any amount of tuning. This set
shipped with `programs.git.userEmail', which does not exist in
Home-Manager's options at all, and a whole round of analysis was spent
treating that as a retrieval problem.

An empty return is the only result worth optimising against."
  (let ((set (or set (arc-eval-read-set arc-eval-set-file)))
        bad)
    (dolist (q set)
      (dolist (e (apply #'append (arc-eval--groups q)))
        (unless (if sources
                    (cl-some (lambda (s) (arc-eval--source-matches-p s e)) sources)
                  (> (caar (sqlite-select
                            (arc-db)
                            (format "SELECT count(*) FROM sources WHERE %s;"
                                    (arc-eval--expect-sql e))))
                     0))
          (push (cons (plist-get q :question) e) bad))))
    (nreverse bad)))

(defun arc-eval-plan-sources (&optional collections)
  "Return a light source plist for everything the plan would index.
COLLECTIONS limits it to those `arc-index-plan' names.  Each plist
carries the identity keys `arc-eval--source-matches-p' reads and no
chunk text.  This is `arc--plan-cell-source-list' -- the reindex's own
enumeration -- so it pays what gathering pays, including `nix build'
for the option collections; it never touches the database."
  (let (out)
    (dolist (cell (if collections
                      (seq-filter (lambda (c) (member (car c) collections)) arc-index-plan)
                    arc-index-plan))
      (let ((sources (arc--plan-cell-source-list (car cell) (cdr cell))))
        (unless (eq sources arc--reindex-skipped)
          (dolist (s sources)
            (when (plist-get s :chunks)
              (push (list :kind (plist-get s :kind) :path (plist-get s :path)
                          :org-id (plist-get s :org-id)
                          :option-name (plist-get s :option-name)
                          :info-node (plist-get s :info-node))
                    out))))))
    (nreverse out)))

;;;###autoload
(defun arc-eval-check ()
  "Report any eval expectation that names a source the corpus lacks."
  (interactive)
  (let ((bad (arc-eval-validate)))
    (if (null bad)
        (message "arc-eval: every expectation resolves to a real source")
      (with-current-buffer (get-buffer-create "*arc-eval-check*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "%d unresolvable expectation(s) -- fix the SET, not arc:\n\n"
                          (length bad)))
          (dolist (cell bad)
            (insert (format "  %s\n      %S\n" (car cell) (cdr cell)))))
        (goto-char (point-min))
        (special-mode)
        (pop-to-buffer (current-buffer))))))

;;; Retrieval ---------------------------------------------------------------

(defun arc-eval--retrieve (question scope k &optional arm)
  "Return up to K source plists arc retrieves for QUESTION at SCOPE.
Goes through the real query builder and the real row fetch -- the point
is to measure what arc does, not a reimplementation of it.  ARM is
passed to `arc--find-similar': nil for the real fused query, `semantic'
or `keyword' to measure one arm alone."
  (let* ((arc-limit k)
         (scope (arc-scope-normalize scope))
         (sql (arc--find-similar question scope arm))
         (ids (arc--retrieve-ids sql question)))
    (mapcar #'arc-row-to-source (arc--retrieve-rows ids))))

(defun arc-eval-run (&optional set arm)
  "Run SET (default `arc-eval-set-file') and return a result alist.
Each result is (:question :expect-count :ranks :sources :negative
:seconds), where :ranks is one (EXPECT . RANK) cell per :expect element
-- a clause, or an (:any ...) group -- RANK being the 1-based position
of its first match, or nil.  A negative question has no :ranks.  ARM is
passed through to `arc-eval--retrieve'."
  (let* ((set (or set (arc-eval-read-set arc-eval-set-file)))
         (kmax (apply #'max arc-eval-k)))
    (mapcar
     (lambda (q)
       (let* ((question (plist-get q :question))
              (t0 (float-time))
              (sources (arc-eval--retrieve question (plist-get q :scope) kmax arm))
              (seconds (- (float-time) t0))
              (expects (plist-get q :expect)))
         (list :question question
               :expect-count (length expects)
               :ranks (cl-mapcar (lambda (e g) (cons e (arc-eval--group-rank g sources)))
                                 expects (arc-eval--groups q))
               :sources sources
               :negative (and (plist-get q :negative) t)
               :seconds seconds)))
     set)))

(defun arc-eval-arms (&optional set)
  "Return ((ARM . RESULTS) ...) for the fused query and each arm alone.
This is the diagnosis that turns \"retrieval is bad\" into \"the keyword
arm is not contributing\": if fused recall barely beats one arm, the
other arm is dead weight, and if fused is WORSE than an arm alone, the
fusion is actively hurting."
  (let ((set (or set (arc-eval-read-set arc-eval-set-file))))
    (mapcar (lambda (arm) (cons arm (arc-eval-run set arm)))
            '(fused semantic keyword))))

(defun arc-eval-recall (results k)
  "Return recall at K over RESULTS: matched expectations / total expectations."
  (let ((total 0) (hit 0))
    (dolist (r results)
      (dolist (cell (plist-get r :ranks))
        (setq total (1+ total))
        (when (and (cdr cell) (<= (cdr cell) k)) (setq hit (1+ hit)))))
    (if (zerop total) 0.0 (/ (float hit) total))))

;;; Report ------------------------------------------------------------------

(defun arc-eval--render (results)
  "Render RESULTS into `arc-eval-buffer-name' and return the buffer."
  (let ((buf (get-buffer-create arc-eval-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "arc eval — %d question(s), %s\n\n"
                        (length results) (format-time-string "%F %R")))
        (dolist (k arc-eval-k)
          (insert (format "  recall@%-3d %.2f\n" k (arc-eval-recall results k))))
        (let ((m (arc-eval-metrics (arc-eval--positive-ranks results))))
          (insert (format "  mrr         %.2f\n" (plist-get m :mrr)))
          (dolist (k arc-eval-k)
            (insert (format "  ndcg@%-4d   %.2f\n" k (alist-get k (plist-get m :ndcg))))))
        (let ((any (cl-count-if (lambda (r)
                                  (cl-some #'cdr (plist-get r :ranks)))
                                results))
              (positives (cl-count-if-not (lambda (r) (plist-get r :negative)) results)))
          (insert (format "  at least one hit: %d/%d\n\n" any positives)))
        (dolist (r results)
          (let* ((ranks (plist-get r :ranks))
                 (all (cl-every #'cdr ranks)))
            (insert (format "%s %s\n"
                            (cond ((plist-get r :negative) "NEG ")
                                  (all "PASS")
                                  (t "FAIL"))
                            (plist-get r :question)))
            (dolist (cell ranks)
              (insert (format "     %-58s %s\n"
                              (format "%S" (car cell))
                              (if (cdr cell) (format "hit @%d" (cdr cell)) "MISS"))))
            (unless all
              (insert "     got:\n")
              (cl-loop for s in (plist-get r :sources)
                       for i from 1
                       do (insert (format "       %2d. %s\n" i (arc-source-label s)))))
            (insert "\n"))))
      (goto-char (point-min))
      (special-mode))
    buf))

(defun arc-eval-document-recall (set k &optional arm)
  "Fraction of SET's questions whose expected source is in the top K documents.

The chunk-level scorer asks whether an expected source appears among k
retrieved chunks; this asks whether it appears among k retrieved
documents, which is what a reader of search results actually sees.  The
question set needs no change to support it: an `:expect' clause already
names source identity -- `:kind', `:option-name', `:path-suffix' -- and
never a chunk."
  (let ((hits 0) (n 0))
    (dolist (q set)
      (setq n (1+ n))
      (let* ((arc-search-limit k)
             ;; Explicit priority rules are presentation personalization, not
             ;; retrieval quality.  Eval must always measure the baseline
             ;; ranker, even when an operator has configured boosts.
             (arc-search-priority-rules nil)
             (docs (arc-search-documents (plist-get q :question)
                                         (plist-get q :scope)
                                         arm)))
        (when (cl-some
               (lambda (expect)
                 (cl-some (lambda (doc) (arc-eval--source-matches-p doc expect))
                          docs))
               (plist-get q :expect))
          (setq hits (1+ hits)))))
    (if (zerop n) 0.0 (/ (float hits) n))))

(defun arc-eval-rollup-sweep ()
  "Report document recall for every `arc-rollup-function', at every `arc-eval-k'.
This is what chooses the default.  Three hand-tuned retrieval
interventions have already lost to BM25's own weighting in this package;
the aggregation gets measured rather than argued about."
  (interactive)
  (let ((set (arc-eval-read-set arc-eval-set-file)))
    (with-current-buffer (get-buffer-create arc-eval-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "arc rollup sweep -- %d questions\n\n" (length set)))
        (insert (format "%-10s %s\n" "function"
                        (mapconcat (lambda (k) (format "recall@%-4d" k))
                                   arc-eval-k " ")))
        (dolist (fn '(max top-n sum))
          (let ((arc-rollup-function fn))
            (insert (format "%-10s %s\n" fn
                            (mapconcat
                             (lambda (k)
                               (format "%-11.2f"
                                       (arc-eval-document-recall set k)))
                             arc-eval-k " ")))))
        (goto-char (point-min))))
    (display-buffer arc-eval-buffer-name)))

;;; Metrics ---------------------------------------------------------------
;;
;; Every metric here is over expectation GROUPS, never over the flattened
;; members of a group.  A group is one thing the question needs; an
;; (:any A B C) group that retrieves B has found what it needed, and
;; counting A and C as two further misses -- or as three relevant items
;; an ideal ranking would place -- would punish a question for having been
;; written honestly.  AutoRAG's nDCG takes its ideal from the flattened
;; member count, which is exactly that mistake; this takes it from the
;; number of groups.
;;
;; A group's RANK is the position of its first matching item.  Given those:
;;
;;   recall@k  groups ranked <= k / all groups, pooled over questions (the
;;             micro average the harness has always reported)
;;   MRR       per question, the mean over its groups of 1/rank (0 for a
;;             missed group) -- AutoRAG's definition -- averaged over
;;             questions.  Ranks are counted within the retrieved list,
;;             which is max(`arc-eval-k') long, so a group found deeper
;;             than that scores 0.
;;   nDCG@k    per question, binary gain at each group's rank:
;;             DCG = sum 1/log2(rank+1) over groups ranked <= k, over
;;             IDCG = the same sum for ranks 1..min(groups, k); averaged
;;             over questions.  Two groups first matched by one item share
;;             a rank, which could push DCG past IDCG, so it is capped at 1.

(defun arc-eval--positive-ranks (results)
  "Return the per-question group-rank lists of RESULTS' positive questions."
  (delq nil (mapcar (lambda (r)
                      (unless (plist-get r :negative)
                        (mapcar #'cdr (plist-get r :ranks))))
                    results)))

(defun arc-eval--ndcg (ranks k)
  "Return nDCG at K for one question's group RANKS (rank or nil each)."
  (let ((dcg 0.0) (idcg 0.0))
    (dolist (r ranks)
      (when (and r (<= r k)) (setq dcg (+ dcg (/ 1.0 (log (1+ r) 2))))))
    (dotimes (i (min (length ranks) k))
      (setq idcg (+ idcg (/ 1.0 (log (+ i 2) 2)))))
    (if (zerop idcg) 0.0 (min 1.0 (/ dcg idcg)))))

(defun arc-eval--rr (ranks)
  "Return one question's reciprocal rank: the mean of 1/rank over RANKS."
  (if (null ranks) 0.0
    (/ (apply #'+ (mapcar (lambda (r) (if r (/ 1.0 r) 0.0)) ranks))
       (float (length ranks)))))

(defun arc-eval-metrics (rank-lists &optional ks)
  "Return metrics over RANK-LISTS, one list of group ranks per question.
The plist has :questions, :groups, :recall and :ndcg (alists keyed by
each cutoff in KS, default `arc-eval-k') and :mrr.  See the commentary
above for the definitions."
  (let* ((ks (or ks arc-eval-k))
         (n (length rank-lists))
         (groups (apply #'+ (mapcar #'length rank-lists))))
    (list :questions n :groups groups
          :recall (mapcar (lambda (k)
                            (cons k (if (zerop groups) 0.0
                                      (/ (float (cl-loop for ranks in rank-lists
                                                         sum (cl-count-if (lambda (r) (and r (<= r k)))
                                                                          ranks)))
                                         groups))))
                          ks)
          :ndcg (mapcar (lambda (k)
                          (cons k (if (zerop n) 0.0
                                    (/ (apply #'+ (mapcar (lambda (rs) (arc-eval--ndcg rs k))
                                                          rank-lists))
                                       n))))
                        ks)
          :mrr (if (zerop n) 0.0
                 (/ (apply #'+ (mapcar #'arc-eval--rr rank-lists)) n)))))

(defun arc-eval-run-documents (&optional set arm)
  "Like `arc-eval-run', but over the DOCUMENTS `arc-search-documents' returns.
Each result carries :ranks per :expect element against the top
max(`arc-eval-k') documents, so `arc-eval-metrics' scores it the same
way.  Priority rules are bound off, as in `arc-eval-document-recall'."
  (let* ((set (or set (arc-eval-read-set arc-eval-set-file)))
         (kmax (apply #'max arc-eval-k)))
    (mapcar
     (lambda (q)
       (let* ((arc-search-limit kmax)
              (arc-search-priority-rules nil)
              (t0 (float-time))
              (docs (arc-search-documents (plist-get q :question) (plist-get q :scope) arm))
              (seconds (- (float-time) t0)))
         (list :question (plist-get q :question)
               :ranks (cl-mapcar (lambda (e g) (cons e (arc-eval--group-rank g docs)))
                                 (plist-get q :expect) (arc-eval--groups q))
               :sources docs
               :negative (and (plist-get q :negative) t)
               :seconds seconds)))
     set)))

;;; Cached arms and offline fusion -----------------------------------------
;;
;; Fusion is tuned offline.  Each question's semantic and keyword arms are
;; run ONCE, at the depth document search uses, with each arm's raw score
;; kept alongside its rank; every fusion configuration is then a pure
;; function of those cached lists.  A sweep of a hundred configurations
;; costs one embedding call per question instead of a hundred, and -- the
;; reason it is worth the code -- every configuration is scored against
;; byte-identical candidates, so a difference between two of them is the
;; fusion's and not the embedding service's.
;;
;; The raw scores, and which way they point:
;;
;;   semantic  cosine DISTANCE, `vec_distance_cosine', in [0, 2]; lower is
;;             better.  Fused as similarity, 1 - distance, in [-1, 1].
;;   keyword   FTS5 `bm25()', which is NEGATED BM25: more negative is
;;             better, and it is unbounded below.  Fused as relevance,
;;             -bm25(), in [0, inf).
;;
;; Two fusion families:
;;
;;   rrf  W/(K + semantic rank) + 1/(K + keyword rank) -- the shipped
;;        query's own formula, with `arc-rrf-k' and
;;        `arc-rrf-semantic-weight' as K and W.
;;   cc   convex combination W*norm(semantic) + (1-W)*norm(keyword), with
;;        norm one of:
;;          minmax  (x - min) / (max - min) over that arm's candidates
;;          tmm     theoretical-min-max, AutoRAG's: the theoretical floor
;;                  and the observed ceiling, (x - tmin)/(max - tmin);
;;                  tmin is -1 for similarity and 0 for bm25 relevance
;;          zscore  (x - mean) / sd
;;          dbsf    distribution-based: (x - (mean - 3sd)) / 6sd, clipped
;;                  to [0, 1]
;;        A candidate one arm did not return takes that arm's floor: 0 for
;;        minmax, tmm and dbsf, the lowest observed z for zscore.
;;
;; Fidelity to the shipped query: the chunk-level score truncates each arm
;; to `arc-knn-candidates' before fusing, exactly as `arc--find-similar'
;; does, and the document-level score fuses the whole pool and rolls it up
;; with `arc-rollup', exactly as `arc-search-documents' does.

(defun arc-eval--arm-sql-semantic (scope vec)
  "SQL for SCOPE's semantic arm against VEC: (ID RANK DISTANCE) rows.
`arc--semantic-cte' itself, so the strategy (KNN or brute force) is
whatever the shipped query would pick at the bound `arc-knn-candidates'."
  (format "WITH\n%s,\n%s\nSELECT s.id, s.rank, vec_distance_cosine(e.embedding, %s)
FROM semantic_search s JOIN data_embeddings e ON e.rowid = s.id
ORDER BY s.rank ASC, s.id ASC;"
          (arc--scoped-cte scope) (arc--semantic-cte scope vec) vec))

(defun arc-eval--arm-sql-keyword (scope text depth)
  "SQL for SCOPE's keyword arm for TEXT: (ID RANK BM25) rows, DEPTH deep.
The same MATCH and ranking as `arc--keyword-cte', plus `bm25()' itself,
which FTS5 only exposes inside the MATCH query.  The rank is computed
over the LIMITed rows in an outer query because, measured on SQLite
3.50, selecting `bm25()' beside a `RANK () OVER (ORDER BY bm25(...))'
in the MATCH query itself returns no rows at all.  The top DEPTH ranks
are the same either way."
  (format "WITH\n%s,
kw AS (
  SELECT f.rowid AS id, bm25(data_fts) AS score
  FROM data_fts f JOIN scoped ON scoped.id = f.rowid
  WHERE data_fts MATCH %s
  ORDER BY bm25(data_fts) ASC
  LIMIT %d
)
SELECT id, RANK () OVER (ORDER BY score ASC), score FROM kw ORDER BY score ASC;"
          (arc--scoped-cte scope) (arc--sql-quote (arc-fts-query text)) depth))

(defun arc-eval--id-sources (ids)
  "Return a hash table mapping each data id in IDS to its source plist."
  (let ((table (make-hash-table :test #'eql)))
    (when ids
      (dolist (row (sqlite-select
                    (arc-db)
                    (format "SELECT d.id, d.source_id, s.kind, s.path, s.info_node,
                                    s.org_id, s.option_name
                             FROM data d JOIN sources s ON s.id = d.source_id
                             WHERE d.id IN %s;"
                            (arc-sqlite-format-int-list (delete-dups (copy-sequence ids))))))
        (pcase-let ((`(,id ,sid ,kind ,path ,info ,org ,opt) row))
          (puthash id (list :source-id sid :kind kind :path path :info-node info
                            :org-id org :option-name opt)
                   table))))
    table))

(defun arc-eval-cache-arms (&optional set)
  "Run each question of SET's two arms once and return the cache.
One plist per question: :q (the question plist), :split, :semantic and
:keyword (lists of (ID RANK SCORE), best first, SCORE the raw arm score
described in this section's commentary), :sources (id -> source plist),
:embed-seconds, :semantic-seconds and :keyword-seconds, and
:live-seconds -- the wall time of the shipped fused chunk retrieval,
run once more for the latency report and as the reference the offline
`rrf' at the shipped settings is checked against (:live-ids)."
  (let ((set (or set (arc-eval-read-set arc-eval-set-file)))
        (kmax (apply #'max arc-eval-k)))
    (mapcar
     (lambda (q)
       (let* ((text (plist-get q :question))
              (scope (arc-scope-normalize (plist-get q :scope)))
              (pool (arc-search--effective-pool scope))
              (t0 (float-time))
              (vec (arc-vector-to-sqlite (llm-embedding arc-embeddings-provider text)))
              (t1 (float-time))
              (sem (let ((arc-knn-candidates pool))
                     (sqlite-select (arc-db) (arc-eval--arm-sql-semantic scope vec))))
              (t2 (float-time))
              (kw (sqlite-select (arc-db) (arc-eval--arm-sql-keyword scope text pool)))
              (t3 (float-time))
              (live (let ((arc-limit kmax))
                      (arc--retrieve-ids (arc--find-similar text scope) text)))
              (t4 (float-time)))
         (list :q q :split (arc-eval-question-split q)
               :semantic sem :keyword kw
               :sources (arc-eval--id-sources (append (mapcar #'car sem) (mapcar #'car kw)))
               :embed-seconds (- t1 t0) :semantic-seconds (- t2 t1)
               :keyword-seconds (- t3 t2) :live-seconds (- t4 t3)
               :live-ids live)))
     set)))

(defun arc-eval--stats (xs)
  "Return (MEAN . SD) of the numbers XS, population SD."
  (let* ((n (float (length xs)))
         (mean (/ (apply #'+ xs) n))
         (sd (sqrt (/ (apply #'+ (mapcar (lambda (x) (expt (- x mean) 2)) xs)) n))))
    (cons mean sd)))

(defun arc-eval--normalize (scores method tmin)
  "Return a hash id -> normalized score, and the arm floor, for SCORES.
SCORES is a list of (ID . RAW), higher better.  METHOD is `minmax',
`tmm' (with theoretical minimum TMIN), `zscore' or `dbsf'.  Returns
\(TABLE . FLOOR), FLOOR being what an id absent from SCORES gets."
  (let ((table (make-hash-table :test #'eql))
        (raws (mapcar #'cdr scores)))
    (if (null raws)
        (cons table 0.0)
      (let* ((lo (apply #'min raws)) (hi (apply #'max raws))
             (ms (arc-eval--stats raws)) (mean (car ms)) (sd (cdr ms))
             (f (pcase method
                  ('minmax (lambda (x) (if (= hi lo) 1.0 (/ (- x lo) (- hi lo)))))
                  ('tmm (lambda (x) (if (= hi tmin) 1.0 (/ (- x tmin) (- hi tmin)))))
                  ('zscore (lambda (x) (if (zerop sd) 0.0 (/ (- x mean) sd))))
                  ('dbsf (lambda (x)
                           (if (zerop sd) 1.0
                             (max 0.0 (min 1.0 (/ (- x (- mean (* 3 sd))) (* 6 sd)))))))
                  (_ (error "arc-eval: unknown normalization %S" method)))))
        (dolist (cell scores) (puthash (car cell) (funcall f (cdr cell)) table))
        (cons table (if (eq method 'zscore) (funcall f lo) 0.0))))))

(defun arc-eval-fuse (entry config depth)
  "Fuse cached ENTRY's arms under CONFIG, each arm cut to DEPTH.
Return a list of (ID . SCORE), best first.  CONFIG is (:method rrf :k K :w W)
or (:method cc :norm NORM :w W); see this section's commentary.  Ties
break on semantic rank, then keyword rank, then id, so the order is
fully determined."
  (let* ((sem (take depth (plist-get entry :semantic)))
         (kw (take depth (plist-get entry :keyword)))
         (srank (make-hash-table :test #'eql))
         (krank (make-hash-table :test #'eql))
         (ids nil)
         (w (float (plist-get config :w))))
    (dolist (r sem) (puthash (nth 0 r) (nth 1 r) srank) (push (nth 0 r) ids))
    (dolist (r kw) (puthash (nth 0 r) (nth 1 r) krank) (push (nth 0 r) ids))
    (setq ids (delete-dups (nreverse ids)))
    (let ((score
           (pcase (plist-get config :method)
             ('rrf
              (let ((k (plist-get config :k)))
                (lambda (id)
                  (+ (if-let* ((r (gethash id srank))) (/ w (+ k r)) 0.0)
                     (if-let* ((r (gethash id krank))) (/ 1.0 (+ k r)) 0.0)))))
             ('cc
              (let* ((norm (plist-get config :norm))
                     (sn (arc-eval--normalize
                          (mapcar (lambda (r) (cons (nth 0 r) (- 1.0 (nth 2 r)))) sem)
                          norm -1.0))
                     (kn (arc-eval--normalize
                          (mapcar (lambda (r) (cons (nth 0 r) (- (nth 2 r)))) kw)
                          norm 0.0)))
                (lambda (id)
                  (+ (* w (gethash id (car sn) (cdr sn)))
                     (* (- 1.0 w) (gethash id (car kn) (cdr kn)))))))
             (m (error "arc-eval: unknown fusion method %S" m)))))
      (mapcar (lambda (row) (cons (nth 0 row) (nth 1 row)))
              (sort (mapcar (lambda (id) (list id (funcall score id)
                                               (gethash id srank most-positive-fixnum)
                                               (gethash id krank most-positive-fixnum)))
                            ids)
                    (lambda (a b)
                      (cond ((/= (nth 1 a) (nth 1 b)) (> (nth 1 a) (nth 1 b)))
                            ((/= (nth 2 a) (nth 2 b)) (< (nth 2 a) (nth 2 b)))
                            ((/= (nth 3 a) (nth 3 b)) (< (nth 3 a) (nth 3 b)))
                            (t (< (nth 0 a) (nth 0 b))))))))))

(defun arc-eval--entry-ranks (entry config level)
  "Return ENTRY's group ranks under fusion CONFIG at LEVEL.
LEVEL `chunk' scores the top max(`arc-eval-k') chunks of a fusion cut
to `arc-knn-candidates' per arm; `document' rolls the whole fused pool
up with `arc-rollup' and scores the top max(`arc-eval-k') documents."
  (let* ((kmax (apply #'max arc-eval-k))
         (src (plist-get entry :sources))
         (groups (arc-eval--groups (plist-get entry :q))))
    (pcase level
      ('chunk
       (let ((sources (mapcar (lambda (id) (gethash id src))
                              (take kmax (mapcar #'car (arc-eval-fuse entry config arc-knn-candidates))))))
         (mapcar (lambda (g) (arc-eval--group-rank g sources)) groups)))
      ('document
       (let* ((ids (mapcar #'car (arc-eval-fuse entry config most-positive-fixnum)))
              (n (length ids))
              (docs (arc-rollup
                     (cl-loop for id in ids for i from 0
                              ;; `arc-rollup' needs scores best-first; the
                              ;; fused order is the ranking, so a rank-
                              ;; derived score carries it exactly.
                              collect (list :id id
                                            :source-id (plist-get (gethash id src) :source-id)
                                            :score (float (- n i))))))
              (sources (mapcar (lambda (d) (gethash (plist-get (car (plist-get d :passages)) :id)
                                                    src))
                               (take kmax docs))))
         (mapcar (lambda (g) (arc-eval--group-rank g sources)) groups))))))

(defun arc-eval-score-config (cache config &optional split)
  "Score fusion CONFIG over CACHE's positive questions in SPLIT.
Return (:chunk METRICS :document METRICS), each from `arc-eval-metrics'."
  (let ((entries (seq-filter (lambda (e)
                               (and (not (plist-get (plist-get e :q) :negative))
                                    (or (null split) (eq (plist-get e :split) split))))
                             cache)))
    (list :chunk (arc-eval-metrics
                  (mapcar (lambda (e) (arc-eval--entry-ranks e config 'chunk)) entries))
          :document (arc-eval-metrics
                     (mapcar (lambda (e) (arc-eval--entry-ranks e config 'document)) entries)))))

(defcustom arc-eval-sweep-rrf-k '(5 10 20 40 60 80 120)
  "RRF constants `arc-eval-sweep' tries."
  :type '(repeat integer) :group 'arc)

(defcustom arc-eval-sweep-rrf-weights '(0.5 1 1.5 2 3 4)
  "Semantic-arm RRF weights `arc-eval-sweep' tries."
  :type '(repeat number) :group 'arc)

(defcustom arc-eval-sweep-cc-weights '(0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0)
  "Semantic weights `arc-eval-sweep' tries for convex-combination fusion."
  :type '(repeat number) :group 'arc)

(defun arc-eval-shipped-config ()
  "Return the fusion configuration the shipped query uses."
  (list :method 'rrf :k arc-rrf-k :w arc-rrf-semantic-weight))

(defun arc-eval--objective (score)
  "Return the tuning key of SCORE: document nDCG@kmax, then recall@kmax.
Documents, because they are what a reader of search results sees."
  (let ((kmax (apply #'max arc-eval-k))
        (doc (plist-get score :document)))
    (list (alist-get kmax (plist-get doc :ndcg))
          (alist-get kmax (plist-get doc :recall))
          (alist-get kmax (plist-get (plist-get score :chunk) :ndcg)))))

(defun arc-eval--better-p (a b)
  "Non-nil when objective A beats objective B, compared lexicographically."
  (cl-loop for x in a for y in b
           unless (= x y) return (> x y)
           finally return nil))

(defun arc-eval-sweep (cache &optional split)
  "Return the best fusion configuration of each family on CACHE's SPLIT.
SPLIT defaults to `dev': tuning reads dev questions only, so `test'
stays an unbiased measurement of whatever wins here.  Returns an alist
\(FAMILY CONFIG . DEV-SCORE) for FAMILY `rrf', `cc-minmax', `cc-tmm',
`cc-zscore' and `cc-dbsf'.  A tie keeps the configuration tried first,
and the grids are ordered so that is the shipped one where it is in
the grid."
  (let ((split (or split 'dev))
        (families
         `((rrf . ,(cons (arc-eval-shipped-config)
                         (cl-loop for k in arc-eval-sweep-rrf-k
                                  append (cl-loop for w in arc-eval-sweep-rrf-weights
                                                  collect (list :method 'rrf :k k :w w)))))
           ,@(mapcar (lambda (norm)
                       (cons (intern (format "cc-%s" norm))
                             (mapcar (lambda (w) (list :method 'cc :norm norm :w w))
                                     arc-eval-sweep-cc-weights)))
                     '(minmax tmm zscore dbsf)))))
    (mapcar
     (lambda (family)
       (let (best best-score best-key)
         (dolist (config (cdr family))
           (let* ((score (arc-eval-score-config cache config split))
                  (key (arc-eval--objective score)))
             (when (or (null best) (arc-eval--better-p key best-key))
               (setq best config best-score score best-key key))))
         (cons (car family) (cons best best-score))))
     families)))

;;; Negatives and latency ---------------------------------------------------

(defun arc-eval--quantiles (xs)
  "Return (MIN P25 MEDIAN P75 MAX) of XS by nearest rank, or nil if empty."
  (when xs
    (let* ((v (vconcat (sort (copy-sequence xs) #'<)))
           (n (length v))
           (at (lambda (p) (aref v (min (1- n) (max 0 (1- (ceiling (* p n)))))))))
      (list (aref v 0) (funcall at 0.25) (funcall at 0.5) (funcall at 0.75) (aref v (1- n))))))

(defun arc-eval-negative-profile (cache)
  "Return top-hit score distributions for CACHE's negatives and positives.
An alist keyed `negative' and `positive', each a plist of
:nearest-distance (the semantic arm's best cosine distance -- what
`arc-retrieval-max-distance' would compare), :best-bm25 (the keyword
arm's best -bm25()) and :fused-score (the shipped RRF's top score),
each as `arc-eval--quantiles' over the questions that had one.

The fused score is reported because it was asked for and because the
answer is worth having on paper: RRF scores are a function of RANK
alone, so the top fused score of a query that matched nothing relevant
and one that matched exactly are the same number whenever both arms
put something first.  It cannot carry a threshold; the distance can."
  (let ((shipped (arc-eval-shipped-config)))
    (mapcar
     (lambda (neg)
       (let ((entries (seq-filter (lambda (e) (eq neg (and (plist-get (plist-get e :q) :negative) t)))
                                  cache)))
         (cons (if neg 'negative 'positive)
               (list :n (length entries)
                     :nearest-distance
                     (arc-eval--quantiles
                      (delq nil (mapcar (lambda (e) (nth 2 (car (plist-get e :semantic)))) entries)))
                     :best-bm25
                     (arc-eval--quantiles
                      (delq nil (mapcar (lambda (e) (let ((b (nth 2 (car (plist-get e :keyword)))))
                                                      (and b (- b))))
                                        entries)))
                     :fused-score
                     (arc-eval--quantiles
                      (delq nil
                            (mapcar (lambda (e)
                                      (cdr (car (arc-eval-fuse e shipped arc-knn-candidates))))
                                    entries)))))))
     '(t nil))))

(defun arc-eval-threshold-table (cache thresholds)
  "Return, for each of THRESHOLDS, what refusing above it would do.
A row is (THRESHOLD NEGATIVES-REFUSED NEGATIVES POSITIVES-REFUSED
POSITIVES): a question is refused when its nearest semantic distance
exceeds THRESHOLD, which is the check `arc-retrieval-max-distance'
exists to make."
  (let* ((dist (lambda (e) (nth 2 (car (plist-get e :semantic)))))
         (neg (seq-filter (lambda (e) (plist-get (plist-get e :q) :negative)) cache))
         (pos (seq-remove (lambda (e) (plist-get (plist-get e :q) :negative)) cache))
         (refused (lambda (es th) (cl-count-if (lambda (e) (let ((d (funcall dist e)))
                                                             (or (null d) (> d th))))
                                               es))))
    (mapcar (lambda (th) (list th (funcall refused neg th) (length neg)
                               (funcall refused pos th) (length pos)))
            thresholds)))

(defun arc-eval-latency (xs)
  "Return (N MEDIAN P95) seconds of XS, dropping the first as warm-up."
  (let ((xs (cdr xs)))
    (when xs
      (let* ((v (vconcat (sort (copy-sequence xs) #'<)))
             (n (length v))
             (at (lambda (p) (aref v (min (1- n) (max 0 (1- (ceiling (* p n)))))))))
        (list n (funcall at 0.5) (funcall at 0.95))))))

;;; The final report --------------------------------------------------------

(defun arc-eval--metrics-line (label m)
  "Format metrics M under LABEL as one line."
  (format "  %-30s %s  mrr %.3f\n" label
          (mapconcat (lambda (k)
                       (format "R@%d %.3f nDCG@%d %.3f" k (alist-get k (plist-get m :recall))
                               k (alist-get k (plist-get m :ndcg))))
                     arc-eval-k "  ")
          (plist-get m :mrr)))

(defun arc-eval--config-label (config)
  "Return a short label for fusion CONFIG."
  (pcase (plist-get config :method)
    ('rrf (format "rrf k=%s w=%s" (plist-get config :k) (plist-get config :w)))
    (_ (format "cc %s w=%s" (plist-get config :norm) (plist-get config :w)))))

(defun arc-eval-report-string (&optional set cache)
  "Return the full eval report for SET as a string; CACHE if already built.
Tunes every fusion family on `dev' with `arc-eval-sweep', then scores
the winners, and the shipped configuration, on `dev' AND `test' --
`test' is never read by the tuning.  Also reports the negative
questions' score profile, a refusal-threshold table and per-query
latency."
  (let* ((set (or set (arc-eval-read-set arc-eval-set-file)))
         (cache (or cache (arc-eval-cache-arms set)))
         (count (lambda (split neg)
                  (cl-count-if (lambda (e) (and (eq (plist-get e :split) split)
                                                (eq neg (and (plist-get (plist-get e :q) :negative) t))))
                               cache)))
         (shipped (arc-eval-shipped-config))
         (best (arc-eval-sweep cache 'dev))
         (kmax (apply #'max arc-eval-k))
         (agree (cl-loop for e in cache
                         unless (plist-get (plist-get e :q) :negative)
                         count (equal (plist-get e :live-ids)
                                      (take kmax (mapcar #'car (arc-eval-fuse e shipped arc-knn-candidates))))))
         (positives (cl-count-if-not (lambda (e) (plist-get (plist-get e :q) :negative)) cache)))
    (with-temp-buffer
      (insert (format "arc eval -- %s\n" (format-time-string "%F %R")))
      (insert (format "questions: dev %d positive + %d negative, test %d positive + %d negative\n"
                      (funcall count 'dev nil) (funcall count 'dev t)
                      (funcall count 'test nil) (funcall count 'test t)))
      (insert (format "offline rrf at the shipped settings reproduces the live top %d for %d/%d positive questions\n\n"
                      kmax agree positives))
      (dolist (row (cons (cons 'shipped (cons shipped nil)) best))
        (let ((config (cadr row)))
          (insert (format "%s  [%s]\n" (car row) (arc-eval--config-label config)))
          (dolist (split '(dev test))
            (let ((score (arc-eval-score-config cache config split)))
              (insert (arc-eval--metrics-line (format "%s chunk" split) (plist-get score :chunk)))
              (insert (arc-eval--metrics-line (format "%s document" split)
                                              (plist-get score :document)))))
          (insert "\n")))
      (insert "top-hit profile (min p25 median p75 max)\n")
      (pcase-dolist (`(,kind . ,p) (arc-eval-negative-profile cache))
        (insert (format "  %-8s n=%-3d nearest-distance %S\n           best-bm25 %S\n           fused-score %S\n"
                        kind (plist-get p :n)
                        (mapcar (lambda (x) (/ (round (* 1000 x)) 1000.0))
                                (plist-get p :nearest-distance))
                        (mapcar (lambda (x) (/ (round (* 100 x)) 100.0)) (plist-get p :best-bm25))
                        (mapcar (lambda (x) (/ (round (* 10000 x)) 10000.0))
                                (plist-get p :fused-score)))))
      (insert "\nrefuse when nearest distance > T  (negatives refused / positives wrongly refused)\n")
      (pcase-dolist (`(,th ,nr ,nn ,pr ,pn) (arc-eval-threshold-table
                                             cache '(0.2 0.25 0.3 0.35 0.4 0.45 0.5 0.6)))
        (insert (format "  T=%.2f  %d/%d  %d/%d\n" th nr nn pr pn)))
      (insert "\nlatency, seconds (n median p95), first query excluded\n")
      (dolist (key '(:embed-seconds :semantic-seconds :keyword-seconds :live-seconds))
        (insert (format "  %-18s %S\n" key
                        (arc-eval-latency (mapcar (lambda (e) (plist-get e key)) cache)))))
      (buffer-string))))

;;;###autoload
(defun arc-eval-final-report ()
  "Tune fusion on the dev split and show dev AND test, negatives and latency.
Retrieval only -- no chat model.  See `arc-eval-report-string'."
  (interactive)
  (let ((report (arc-eval-report-string)))
    (with-current-buffer (get-buffer-create arc-eval-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert report)
        (goto-char (point-min))
        (special-mode))
      (pop-to-buffer (current-buffer)))))

;;;###autoload
(defun arc-eval ()
  "Run the eval set and show a recall report.
Retrieval only -- the chat model is never called."
  (interactive)
  (let ((results (arc-eval-run)))
    (pop-to-buffer (arc-eval--render results))
    (message "arc-eval: recall@%d = %.2f over %d question(s)"
             (car arc-eval-k)
             (arc-eval-recall results (car arc-eval-k))
             (length results))))

(provide 'arc-eval)
;;; arc-eval.el ends here
