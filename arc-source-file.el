;;; arc-source-file.el --- files as sources -*- lexical-binding: t; -*-
;; Copyright (C) 2024, 2025 Free Software Foundation, Inc.
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Changes:
;; The directory walk and ignore-file handling are ELISA's, moved here
;; (as `elisa--file-list', `elisa--text-file-p' and
;; `elisa--read-ignore-file-regexps', already renamed to `arc-' by Task 1),
;; with two ignore-matching bugs fixed: patterns were matched against each
;; file's absolute path, so `wildcard-to-regexp''s whole-string anchoring
;; meant a bare filename could never match; and three ordinary gitignore
;; pattern shapes -- a trailing-slash directory, a bare name (matches any
;; path component, not just the whole relative path), and a leading-slash
;; anchor -- were silently inert.  Content hashing and line-tracked chunk
;; attachment are new.
;;; Code:

(require 'arc-chunk)
(require 'arc-db)   ; arc-source-by-path, used by arc-file-changed-p

(defcustom arc-ignore-patterns-files '(".gitignore" ".ignore" ".rgignore")
  "Files with patterns to ignore during file parsing."
  :type '(repeat string) :group 'arc)

(defcustom arc-ignore-invisible-files t
  "Ignore invisible files and directories during file parsing."
  :type 'boolean :group 'arc)

(defun arc--ignore-pattern-to-regexp (pattern)
  "Convert one ignore-file PATTERN line to a regexp, or nil.
Nil is returned for a blank line or a `#' comment.

The regexp is meant to be tested with `string-match-p' against a
file's path relative to the ignore file's own directory.  Beyond
plain `wildcard-to-regexp' translation of the pattern text, this
also gives three gitignore shapes their ordinary meaning:

- a trailing slash marks a directory-only pattern: everything under
  that directory is excluded, so the match must be followed by a
  `/' (more path underneath) rather than end-of-string;
- a pattern with no slash at all is a bare name, matched as a whole
  path component at ANY depth -- bounded by `/' or a string edge on
  both sides -- not only when it happens to equal the entire
  relative path;
- a leading slash (or, per plain gitignore, any interior slash)
  anchors the pattern to the very start of the relative path
  instead of letting it match at any depth; the leading slash
  itself is stripped before translation, since it marks the anchor
  rather than being part of what is matched.

A pattern with an interior slash and no trailing slash -- e.g.
`keys/*_host_ed25519' -- needs none of this: matching the whole
relative path exactly, which `wildcard-to-regexp' already anchors
to on both ends, is already the correct behaviour for that shape."
  (let ((trimmed (string-trim pattern)))
    (unless (or (string-empty-p trimmed) (string-prefix-p "#" trimmed))
      (let* ((explicit-anchor (string-prefix-p "/" trimmed))
             (body (if explicit-anchor (substring trimmed 1) trimmed))
             (directory-only (string-suffix-p "/" body))
             (body (if directory-only (substring body 0 -1) body)))
        (unless (string-empty-p body)
          (let* ((bare-name (not (string-match-p "/" body)))
                 (anchored (or explicit-anchor (not bare-name)))
                 (wildcarded (wildcard-to-regexp body))
                 (core (string-remove-suffix
                        "\\'" (string-remove-prefix "\\`" wildcarded)))
                 (left (if anchored "\\`" "\\(?:\\`\\|/\\)"))
                 (right (cond (directory-only "/")
                              (bare-name "\\(?:\\'\\|/\\)")
                              (t "\\'"))))
            (concat left core right)))))))

(defun arc--read-ignore-file-regexps (directory)
  "Read ignore patterns from `arc-ignore-patterns-files' in DIRECTORY.
Return regexps ready to test against a path relative to DIRECTORY;
see `arc--ignore-pattern-to-regexp'."
  (delq nil
        (mapcar #'arc--ignore-pattern-to-regexp
                (flatten-tree
                 (mapcar (lambda (file)
                           (let ((filepath (expand-file-name file directory)))
                             (when (file-exists-p filepath)
                               (with-temp-buffer
                                 (insert-file-contents filepath)
                                 (split-string (buffer-string) "\n" t)))))
                         arc-ignore-patterns-files)))))

(defun arc--text-file-p (filename)
  "Check if FILENAME contain text."
  (or (and (get-file-buffer filename) t) ;; if file opened assume it text
      (with-current-buffer (find-file-noselect filename t t)
	(prog1
	    ;; if there is null byte in file, file is binary
	    (not (search-forward "\0" nil t 1))
	  (kill-buffer)))))

(defun arc--file-list (directory)
  "List of files to parse in DIRECTORY.
Patterns from an ignore file are matched against each file's path
relative to DIRECTORY, not its absolute path: `wildcard-to-regexp'
anchors a pattern to the whole matched string (\\=`...\\=', not a
substring search), so a bare filename in an ignore file -- e.g.
`b.txt' -- would otherwise need DIRECTORY's entire absolute path
prefix to be absent for it to ever match, and would silently never
exclude anything.  The invisible-file patterns are unanchored
substring regexps written to look for a `/.' inside a path, so they
keep matching the absolute path instead, where that substring is
always present for a dotfile."
  (let ((ignore-regexps (arc--read-ignore-file-regexps directory))
        (invisible-regexps (when arc-ignore-invisible-files
                              (list "$\\.[^/]*" "/\\.[^/]*"))))
    (seq-filter (lambda (file)
		  (and (not (seq-some (lambda (regexp)
					 (string-match-p
                                          regexp (file-relative-name file directory)))
				       ignore-regexps))
                       (not (seq-some (lambda (regexp) (string-match-p regexp file))
                                      invisible-regexps))
		       (arc--text-file-p file)))
		(directory-files-recursively directory ".*"))))

(defun arc-file-hash (path)
  "Return the SHA-1 of PATH's contents."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha1 (current-buffer))))

(defun arc-file-sources (directory)
  "Return a source plist for every indexable file under DIRECTORY.
Each plist has :kind, :path, :hash, :mtime and :chunks."
  (mapcar
   (lambda (path)
     (list :kind "file"
           :path path
           :hash (arc-file-hash path)
           :mtime (truncate (float-time (file-attribute-modification-time
                                         (file-attributes path))))
           :chunks (arc-chunk-file path)))
   (arc--file-list directory)))

(defun arc-file-changed-p (path)
  "Return non-nil when PATH's content differs from what is indexed."
  (let ((known (arc-source-by-path path)))
    (or (null known)
        (not (equal (plist-get known :hash) (arc-file-hash path))))))

(provide 'arc-source-file)
;;; arc-source-file.el ends here
