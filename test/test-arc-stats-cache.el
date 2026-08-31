;;; test-arc-stats-cache.el --- the header line must not query on every redisplay -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar asc-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path asc-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-test-helpers)

(defmacro asc-with-counted-stats (var &rest body)
  "Run BODY with `arc-index-stats' counted into VAR and the cache cleared.
The real query is replaced, so these tests never touch a database --
what is under test is the caching, not the SQL."
  (declare (indent 1))
  `(let ((,var 0)
         (arc-index--stats-cache nil)
         (arc-index--write-generation 0))
     (cl-letf (((symbol-function 'arc-index-stats)
                (lambda () (setq ,var (1+ ,var)) '(("file" . 7)))))
       ,@body)))

(ert-deftest asc-cached-agrees-with-uncached ()
  (asc-with-counted-stats calls
    (should (equal (arc-index-stats-cached) (arc-index-stats)))))

(ert-deftest asc-second-call-inside-ttl-does-not-query ()
  "The whole point: `:eval' in `header-line-format' runs on every
redisplay, and the underlying GROUP BY costs ~30 ms warm / ~810 ms cold
on a real corpus."
  (asc-with-counted-stats calls
    (let ((arc-index-stats-cache-ttl 60))
      (arc-index-stats-cached)
      (arc-index-stats-cached)
      (arc-index-stats-cached)
      (should (= calls 1)))))

(ert-deftest asc-write-generation-bump-invalidates ()
  (asc-with-counted-stats calls
    (let ((arc-index-stats-cache-ttl 60))
      (arc-index-stats-cached)
      (should (= calls 1))
      (arc-index--bump-write-generation)
      (arc-index-stats-cached)
      (should (= calls 2)))))

(ert-deftest asc-ttl-expiry-invalidates ()
  "Covers writes this Emacs cannot see -- a reindex from a second Emacs,
or a batch job -- which the generation counter alone would miss."
  (asc-with-counted-stats calls
    (let ((arc-index-stats-cache-ttl 60))
      (arc-index-stats-cached)
      (should (= calls 1))
      ;; Backdate the cache rather than sleeping.
      (setf (nth 1 arc-index--stats-cache) (time-subtract (current-time) 3600))
      (arc-index-stats-cached)
      (should (= calls 2)))))

(ert-deftest asc-zero-ttl-disables-caching ()
  (asc-with-counted-stats calls
    (let ((arc-index-stats-cache-ttl 0))
      (arc-index-stats-cached)
      (arc-index-stats-cached)
      (should (= calls 2)))))

(ert-deftest asc-header-line-uses-the-cached-variant ()
  "A header line calling the uncached query is the defect; assert the
call actually goes through the cache rather than trusting the source."
  (require 'arc-ui)
  (asc-with-counted-stats calls
    (let ((arc-index-stats-cache-ttl 60))
      (dotimes (_ 5) (arc-ui-header-line))
      (should (= calls 1))
      (should (string-match-p "chunks" (arc-ui-header-line))))))

(ert-deftest asc-header-line-still-survives-a-broken-index ()
  "It must never break the buffer it heads."
  (require 'arc-ui)
  (let ((arc-index--stats-cache nil))
    (cl-letf (((symbol-function 'arc-index-stats)
               (lambda () (error "no such table: sources"))))
      (should (string-match-p "corpus unavailable" (arc-ui-header-line))))))

(ert-deftest asc-indexing-a-source-bumps-the-generation ()
  "Integration: the counter is only useful if the real write path moves it."
  (let ((arc-embedding-size 3))
    (arc-test-with-temp-db
     (let ((before arc-index--write-generation))
       (cl-letf (((symbol-function 'llm-embedding)
                  (lambda (_p _t) [0.1 0.2 0.3])))
         (arc-index-source
          (list :kind "file" :path "/tmp/asc.txt"
                :chunks (list (list :text "hello" :line-start 1 :line-end 1)))
          "asc-coll"))
       (should (> arc-index--write-generation before))))))

(ert-deftest asc-deleting-data-bumps-the-generation ()
  (let ((before arc-index--write-generation))
    (arc--delete-data nil)
    (should (= arc-index--write-generation before))   ; nothing deleted, no bump
    (cl-letf (((symbol-function 'arc--delete-from-table) (lambda (&rest _) nil)))
      (arc--delete-data '(1 2 3))
      (should (> arc-index--write-generation before)))))
