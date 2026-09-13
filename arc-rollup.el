;;; arc-rollup.el --- chunk scores to ranked documents -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Retrieval ranks chunks.  A reader wants documents.  This file is the
;; conversion, and nothing else: no database, no I/O, no UI, so the
;; aggregation can be measured in isolation and swapped when measurement
;; says to.
;;
;; The conversion matters because arc's corpus is two shapes wearing one
;; schema.  Options and Info nodes are one chunk per document; vault
;; notes and dotfiles are twenty-four to forty-six.  At a chunk-level
;; limit of ten, one well-matched note can take every slot and hide five
;; other documents that also matched.

;;; Code:

(require 'cl-lib)

(defcustom arc-rollup-function 'max
  "How a document's score is aggregated from its chunks' scores.

`max'    -- the best chunk's score.  Safe: it cannot be inflated by
            document length, but it discards the signal in a document
            that matched in twelve places rather than one.
`top-n'  -- the sum of the best `arc-rollup-top-n' scores.  Bounded, so
            a forty-six-chunk dotfile cannot run away with the ranking.
`sum'    -- every chunk.  Expected to lose, and provided so the eval
            harness can demonstrate that rather than this docstring
            asserting it: summing rewards documents for being long, so
            every thirty-nine-chunk note outranks every one-chunk option
            on structure alone.

`max' is the measured default, not a placeholder.  `arc-eval-rollup-sweep'
against the 33-question eval set gave max 0.73/0.82 recall at k=5/10,
against 0.64/0.73 for `top-n' (n=3) and 0.58/0.67 for `sum' -- max ahead
at both cutoffs, no tie to break.  See
docs/design/2026-09-13-rollup-measurement.md for the full table and what
lost."
  :type '(choice (const max) (const top-n) (const sum))
  :group 'arc)

(defcustom arc-rollup-top-n 3
  "How many of a document's best chunks `top-n' aggregation sums."
  :type 'integer :group 'arc)

(defcustom arc-rollup-passages 3
  "How many chunks of a document are kept as displayable passages."
  :type 'integer :group 'arc)

(defun arc-rollup-score (scores)
  "Aggregate SCORES, a list of floats best-first, per `arc-rollup-function'."
  (pcase arc-rollup-function
    ('max (or (car scores) 0.0))
    ('top-n (apply #'+ 0.0 (take arc-rollup-top-n scores)))
    ('sum (apply #'+ 0.0 scores))
    (other (error "arc-rollup: unknown `arc-rollup-function': %S" other))))

(defun arc-rollup--better-p (a b)
  "Rank document A before B.
Score descending, then chunk count descending, then best-rank
ascending.  Fully determined, so a ranking never depends on hash
order and the tests do not flake."
  (let ((sa (plist-get a :score)) (sb (plist-get b :score))
        (ca (plist-get a :chunk-count)) (cb (plist-get b :chunk-count)))
    (cond ((/= sa sb) (> sa sb))
          ((/= ca cb) (> ca cb))
          (t (< (plist-get a :best-rank) (plist-get b :best-rank))))))

(defun arc-rollup (chunks)
  "Group CHUNKS into ranked documents.

CHUNKS is an ordered list of plists (:id :source-id :score), best
first.  Return a list of plists (:source-id :score :chunk-count
:best-rank :passages), ranked by `arc-rollup--better-p'.  :passages
holds at most `arc-rollup-passages' of the input chunks, in input
order.  :best-rank is the input position of the document's best chunk,
kept because it is the last tie-break and because a caller may want to
know how far down the pool a document first appeared."
  (let ((table (make-hash-table :test #'eql))
        (order '())
        (n 0))
    (dolist (c chunks)
      (let ((sid (plist-get c :source-id)))
        (unless (gethash sid table)
          (puthash sid (list n) table)
          (push sid order))
        (let ((cell (gethash sid table)))
          (setcdr cell (cons c (cdr cell)))))
      (setq n (1+ n)))
    (sort
     (mapcar
      (lambda (sid)
        (let* ((cell (gethash sid table))
               (cs (reverse (cdr cell))))
          (list :source-id sid
                :score (arc-rollup-score
                        (mapcar (lambda (c) (plist-get c :score)) cs))
                :chunk-count (length cs)
                :best-rank (car cell)
                :passages (take arc-rollup-passages cs))))
      (nreverse order))
     #'arc-rollup--better-p)))

(provide 'arc-rollup)
;;; arc-rollup.el ends here
