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

(defun arc--chunk-push (chunks start end)
  "Push the region START..END onto CHUNKS unless it is blank.  Return CHUNKS.
In boundary mode END is the next chunk's first line, not this chunk's
last one, so :line-end is derived from the last non-blank character
actually inside START..END rather than from END itself -- otherwise a
citation's :line-end would name a line belonging to the next chunk."
  (let ((text (string-trim (buffer-substring-no-properties start end))))
    (if (string-empty-p text)
        chunks
      (cons (list :text text
                  :line-start (line-number-at-pos start)
                  :line-end (save-excursion
                              (goto-char end)
                              (skip-chars-backward " \t\n\r" start)
                              (line-number-at-pos (point))))
            chunks))))

(defun arc-chunk-buffer (&optional boundary)
  "Chunk the current buffer.
With BOUNDARY, a regexp, start a new chunk at each matching line.
Without it, split on blank lines.  Return a list of plists with :text,
:line-start and :line-end."
  (save-excursion
    (goto-char (point-min))
    (let ((chunks nil) (start (point-min)))
      (if boundary
          (progn
            ;; skip a boundary match at point-min: it opens the first chunk
            (when (looking-at boundary) (forward-line 1))
            (while (re-search-forward boundary nil 'move)
              (goto-char (match-beginning 0))
              (unless (= (point) start)
                (setq chunks (arc--chunk-push chunks start (point)))
                (setq start (point)))
              (forward-line 1))
            (setq chunks (arc--chunk-push chunks start (point-max))))
        (while (re-search-forward "\n[ \t]*\n" nil 'move)
          (setq chunks (arc--chunk-push chunks start (match-beginning 0)))
          (setq start (point)))
        (setq chunks (arc--chunk-push chunks start (point-max))))
      (nreverse chunks))))

(defun arc-chunk-file (path)
  "Return the chunks of the file at PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (arc-chunk-buffer (arc--boundary-for path))))

(defcustom arc-chunk-size-ceiling 4000
  "Split text into multiple chunks once it exceeds this many characters.
Below the ceiling, `arc-chunk-text' returns the whole text as a single
chunk even when it contains internal paragraph breaks -- an ordinary
short node still becomes exactly one chunk, same as before this
existed.  `nomic-embed-text' truncates a chunk far below this: a real
436 KB org-roam note was seen embedding to a vector describing about
2% of its actual content, because the whole note was one chunk.  4000
characters is comfortably inside the embedding model's practical
window and comfortably above a typical note's size, so splitting only
kicks in once it would actually matter."
  :type 'natnum :group 'arc)

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
