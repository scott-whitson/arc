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
      (unless (plist-get q :expect)
        (user-error "arc-eval: %S has no :expect clauses" (plist-get q :question))))
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

;;; Retrieval ---------------------------------------------------------------

(defun arc-eval--retrieve (question scope k)
  "Return up to K source plists arc retrieves for QUESTION at SCOPE.
Goes through the real query builder and the real row fetch -- the point
is to measure what arc does, not a reimplementation of it."
  (let* ((arc-limit k)
         (scope (arc-ask-normalize-scope scope))
         (sql (arc--find-similar question scope))
         (ids (arc--retrieve-ids sql question)))
    (mapcar #'arc-row-to-source (arc--retrieve-rows ids))))

(defun arc-eval-run (&optional set)
  "Run SET (default `arc-eval-set-file') and return a result alist.
Each result is (:question :expect-count :ranks :sources), where :ranks is
one entry per :expect clause holding its 1-based rank or nil."
  (let* ((set (or set (arc-eval-read-set arc-eval-set-file)))
         (kmax (apply #'max arc-eval-k)))
    (mapcar
     (lambda (q)
       (let* ((question (plist-get q :question))
              (sources (arc-eval--retrieve question (plist-get q :scope) kmax))
              (expects (plist-get q :expect)))
         (list :question question
               :expect-count (length expects)
               :ranks (mapcar (lambda (e) (cons e (arc-eval--rank-of e sources))) expects)
               :sources sources)))
     set)))

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
        (let ((any (cl-count-if (lambda (r)
                                  (cl-some #'cdr (plist-get r :ranks)))
                                results)))
          (insert (format "  at least one hit: %d/%d\n\n" any (length results))))
        (dolist (r results)
          (let* ((ranks (plist-get r :ranks))
                 (all (cl-every #'cdr ranks)))
            (insert (format "%s %s\n" (if all "PASS" "FAIL") (plist-get r :question)))
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
