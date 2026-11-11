;;; arc-chunk.el --- split text into chunks that remember their lines -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Upstream ELISA chunked on paragraphs and kept no position.  arc keeps
;; line numbers, because a citation that cannot name a line cannot be jumped
;; to.  Structured languages get a boundary regexp so a chunk is one
;; definition rather than one paragraph.
;;; Code:

(require 'cl-lib)

(defcustom arc-chunk-boundary-alist
  '(("\\.nix\\'" . "^[ \t]\\{0,2\\}[A-Za-z_][A-Za-z0-9_.'\"-]*[ \t]*=[ \t]")
    ("\\.el\\'"  . "^("))
  "Alist of (FILE-REGEXP . BOUNDARY-REGEXP).
A line matching BOUNDARY-REGEXP starts a new chunk.  Files matching no
entry are split on blank lines instead."
  :type '(alist :key-type regexp :value-type regexp) :group 'arc)

(defun arc--boundary-for (path)
  "Return the boundary regexp for PATH, or nil for paragraph splitting."
  (cdr (cl-find-if (lambda (cell) (string-match-p (car cell) path))
                   arc-chunk-boundary-alist)))

(defcustom arc-chunk-size-ceiling 4000
  "No chunk is longer than this many characters.
`arc-chunk-buffer' -- which every chunker reaches, the `file' chunker
through `arc-chunk-file' and the org and text-blob producers through
`arc-chunk-text' -- splits any piece over the ceiling, preferring a
paragraph break, then a line break, then a space, and cutting mid-word
only when the piece has none of those.  `nomic-embed-text' truncates a
chunk far below the size of the largest ones arc used to emit: a real
436 KB org-roam note embedded to a vector describing about 2% of its
content, because the whole note was one chunk, and before this applied
to files the `file' chunker emitted chunks as long as a whole file
whenever the file had no blank line in it.  4000 characters is
comfortably inside the model's practical window and comfortably above a
typical note's size.

`arc-chunk-text' also uses it the other way: text at or under it stays
one chunk, paragraph breaks and all."
  :type 'natnum :group 'arc)

(defcustom arc-chunk-merge-target nil
  "When non-nil, merge adjacent small paragraphs up to this many characters.
Applies to paragraph splitting only -- a file with a boundary regexp
in `arc-chunk-boundary-alist' keeps one definition per chunk.  Adjacent
paragraphs are joined, in order, while the joined piece stays at or
under this target; a paragraph already at or over it stands alone.  nil
(the default) keeps one paragraph per chunk, which is what every index
built so far holds: changing it rechunks every prose file at its next
reindex, so it is a setting to measure with `arc-eval' before
adopting, not a default to flip.  It is capped at
`arc-chunk-size-ceiling' either way."
  :type '(choice (const nil) natnum) :group 'arc)

(defun arc--chunk-trim (start end)
  "Return (S . E): START..END with surrounding whitespace removed.
S equals E when the region is blank."
  (save-excursion
    (goto-char start)
    (skip-chars-forward " \t\n\r" end)
    (let ((s (point)))
      (goto-char end)
      (skip-chars-backward " \t\n\r" s)
      (cons s (point)))))

(defun arc--chunk-cut (start limit)
  "Return where a piece starting at START should end, at or before LIMIT.
START is non-blank and LIMIT - START is the ceiling.  The last
paragraph break before LIMIT wins, then the last line break, then the
last space or tab -- each only if it leaves the piece at least half the
ceiling, so a break near START does not produce a sliver followed by
another full-size cut.  Failing that, the latest break of any of those
kinds, and failing every one of them, LIMIT itself: a mid-word cut,
which only a single line longer than the ceiling ever needs."
  (let* ((half (+ start (/ (- limit start) 2)))
         (found
          (mapcar (lambda (re)
                    (save-excursion
                      (goto-char limit)
                      (and (re-search-backward re start t)
                           (> (match-beginning 0) start)
                           (match-beginning 0))))
                  '("\n[ \t]*\n" "\n" "[ \t]"))))
    (or (seq-find (lambda (pos) (and pos (>= pos half))) found)
        (seq-find #'identity found)
        limit)))

(defun arc--chunk-push (chunks start end)
  "Push the region START..END onto CHUNKS unless it is blank.  Return CHUNKS.
The region is trimmed first, and :line-start and :line-end are the
lines of its first and last non-blank characters: in boundary mode END
is the next chunk's first line, and after a run of blank lines START is
a blank line, so neither END nor START can be cited as they stand.

A region longer than `arc-chunk-size-ceiling' becomes several chunks,
cut by `arc--chunk-cut'; each piece is trimmed again, so a piece cut at
a paragraph break neither begins nor ends with the blank line."
  (pcase-let ((`(,s . ,e) (arc--chunk-trim start end)))
    (while (< s e)
      (let ((cut (if (> (- e s) arc-chunk-size-ceiling)
                     (arc--chunk-cut s (+ s arc-chunk-size-ceiling))
                   e)))
        (pcase-let ((`(,ps . ,pe) (arc--chunk-trim s cut)))
          (when (< ps pe)
            (push (list :text (buffer-substring-no-properties ps pe)
                        :line-start (line-number-at-pos ps)
                        :line-end (line-number-at-pos pe))
                  chunks)))
        (setq s (car (arc--chunk-trim cut e)))))
    chunks))

(defun arc--chunk-merge-regions (regions target)
  "Join adjacent REGIONS, a list of (START . END), while each stays <= TARGET.
A region's size is END - START, so a merged one is measured from its
first region's start to its last one's end, blank lines between
included -- the size of the text it will actually become."
  (let ((out nil))
    (dolist (r regions)
      (if (and out (<= (- (cdr r) (car (car out))) target))
          (setcdr (car out) (cdr r))
        (push (cons (car r) (cdr r)) out)))
    (nreverse out)))

(defun arc-chunk-buffer (&optional boundary)
  "Chunk the current buffer.
With BOUNDARY, a regexp, start a new chunk at each matching line.
Without it, split on blank lines, merging small paragraphs when
`arc-chunk-merge-target' is set.  Either way no chunk exceeds
`arc-chunk-size-ceiling'.  Return a list of plists with :text,
:line-start and :line-end."
  (save-excursion
    (goto-char (point-min))
    (let ((regions nil) (start (point-min)))
      (if boundary
          (progn
            ;; skip a boundary match at point-min: it opens the first chunk
            (when (looking-at boundary) (forward-line 1))
            (while (re-search-forward boundary nil 'move)
              (goto-char (match-beginning 0))
              (unless (= (point) start)
                (push (cons start (point)) regions)
                (setq start (point)))
              (forward-line 1))
            (push (cons start (point-max)) regions))
        (while (re-search-forward "\n[ \t]*\n" nil 'move)
          (push (cons start (match-beginning 0)) regions)
          (setq start (point)))
        (push (cons start (point-max)) regions))
      (setq regions
            (seq-remove (lambda (r) (= (car r) (cdr r)))
                        (mapcar (lambda (r) (arc--chunk-trim (car r) (cdr r)))
                                (nreverse regions))))
      (when (and arc-chunk-merge-target (not boundary))
        (setq regions (arc--chunk-merge-regions
                       regions (min arc-chunk-merge-target arc-chunk-size-ceiling))))
      (let ((chunks nil))
        (dolist (r regions)
          (setq chunks (arc--chunk-push chunks (car r) (cdr r))))
        (nreverse chunks)))))

(defun arc-chunk-file (path)
  "Return the chunks of the file at PATH.
The read bypasses `jka-compr', Emacs's transparent decompression.  A
file only reaches here once `arc--text-file-p' has read its bytes and
found text, so a name ending `.gz' or `.bz2' is a lie about its
contents -- and `jka-compr' believes the name, tries to decompress, and
signals.  Found live: a 9-byte text file named `yazi.tar.gz' under
$HOME aborted the whole walk, and with it every collection queued
behind it.  A genuinely compressed file is binary to the probe and
never gets this far."
  (with-temp-buffer
    (let ((inhibit-file-name-handlers
           (cons 'jka-compr-handler inhibit-file-name-handlers))
          (inhibit-file-name-operation 'insert-file-contents))
      (insert-file-contents path))
    (arc-chunk-buffer (arc--boundary-for path))))

(defun arc-chunk-text (text &optional boundary)
  "Return TEXT (an arbitrary string, not necessarily a file's contents)
as a list of chunk plists with :text, :line-start and :line-end.
When TEXT is at or under `arc-chunk-size-ceiling', it comes back as one
chunk covering the whole thing.  Otherwise it is split exactly as
`arc-chunk-buffer' would (on BOUNDARY when given, else paragraph
breaks), so a large node's chunks still carry correct, internally
consistent line numbers instead of a placeholder."
  (with-temp-buffer
    (insert text)
    (if (<= (length text) arc-chunk-size-ceiling)
        (arc--chunk-push nil (point-min) (point-max))
      (arc-chunk-buffer boundary))))

(provide 'arc-chunk)
;;; arc-chunk.el ends here
