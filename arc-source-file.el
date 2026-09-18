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

(defcustom arc-ignore-patterns-files '(".gitignore" ".ignore" ".rgignore" ".arcignore")
  "Files with patterns to ignore during file parsing.
`.arcignore' is arc's own, and is the one to reach for when an
exclusion should apply to indexing and to nothing else: the `home'
collection is rooted at $HOME and must skip `docs/org' -- which
`vault' already owns, with the org chunker -- without that exclusion
also changing what ripgrep and every other tool that honours
`.ignore' can see."
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

(defcustom arc-text-file-size-ceiling (* 10 1024 1024)
  "Files larger than this many bytes are treated as binary, unread.
Checked against `file-attributes' before `arc--text-file-p' opens
anything.  arc splits at `arc-chunk-size-ceiling' (4000 characters), so
no plausible prose file comes anywhere near this ceiling, while every
video, disk image, model weight and archive under $HOME comfortably
exceeds it.  Without this check, `arc--text-file-p' -- which has to
read a candidate file in decoded, not literal, form to tell text from
binary correctly (see its docstring) -- calls `find-file-noselect' on
whatever `arc--file-list' hands it, unconditionally.  For a small
config file that is instant; for a 234 MB `.mkv' it means decoding the
whole thing into a buffer, which one host measured at 20+ minutes
before anyone noticed, once `home' widened the corpus to include
directories with real video files in them.

The honest cost: a genuine multi-megabyte TEXT file -- a giant log, a
generated data dump -- silently drops out of the corpus rather than
slowly indexing it. That trade is deliberate: nothing arc chunks at
4000 characters benefits from a document this large staying whole
anyway, and the alternative is the hang this ceiling exists to stop."
  :type 'natnum :group 'arc)

(defcustom arc-text-file-probe-size (* 64 1024)
  "Bytes read from the start of a candidate file to decide if it is text.
`arc--text-file-p' reads at most this many bytes -- decoded, not
literal, see its docstring -- rather than the whole file. A null byte
or an undecodable byte (a raw-byte character once decoded) anywhere in
that prefix is a reliable binary signal: real prose does not contain
either, so there is no need to read further once one turns up.

The honest cost is the converse: a file that is ordinary text for its
first N bytes and something else after -- a text header glued to a
binary payload, say -- is admitted as text on the strength of the
prefix alone, because nothing past it is ever read to check. 64 KiB is
comfortably larger than any format's magic-number/header region while
staying far below `arc-text-file-size-ceiling'."
  :type 'natnum :group 'arc)

(defun arc--text-file-p (filename)
  "Check if FILENAME contains text.
Reads at most `arc-text-file-probe-size' bytes of FILENAME into a
temporary buffer, decoded the same way `arc-chunk-file' actually will
-- not literal -- because that mismatch is precisely the bug the
undecodable-byte check below closes.  A previous version opened
FILENAME with RAWFILE (unibyte, no decoding attempted) and only
checked for a null byte; an agenix `.age' secret's ciphertext payload
contains no null byte but is never valid UTF-8, so it passed as
\"text\" here, then failed to decode when `arc-chunk-file' read it
normally for real, producing Emacs's internal `eight-bit' raw-byte
characters in the chunked text.  Those cannot be JSON-encoded for the
embeddings API, so indexing crashed on the first such file it met --
far from FILENAME, and far from this function.  A null byte OR any
undecodable byte (surfacing as a raw-byte character once decoded) now
both mark FILENAME binary, exactly as they did then.

A later version read FILENAME whole via `find-file-noselect', which
brought back two of its own defects: no bound on how much it read (see
`arc-text-file-size-ceiling'), and `find-file-noselect' resolving a
coding system interactively when detection is not confident enough to
pick one silently -- in batch Emacs that reads from a stdin nothing is
attached to and dies with `(end-of-file \"Error reading from stdin\")';
in the operator's live Emacs daemon, the one arc actually indexes
under, it would instead block the entire session on a modal
`Select coding system' prompt in the middle of an index run, with
nothing on screen to explain why.  `insert-file-contents' is used
instead of `find-file-noselect' now specifically because it carries
none of the machinery a visited buffer gets -- no major mode, no
local variables, no auto-detected coding system -- and
`coding-system-for-read' is bound here to pin the decode to a fixed
coding system, `utf-8', rather than letting Emacs choose one, which is
what removes the detection step that could ever ask anyone anything.
Content that is genuinely UTF-8 decodes exactly as it would have
before; content in some other real text encoding decodes with
raw-byte characters standing in for whatever does not fit UTF-8 and is
therefore -- like any other undecodable content -- marked binary. That
is a narrowing of what counts as \"text\" relative to letting Emacs
detect the actual encoding, but arc's corpus is overwhelmingly UTF-8,
and the alternative is the prompt this rewrite exists to remove.

Any error signalled while reading FILENAME -- unreadable permissions,
a symlink that vanishes between the directory walk and this read, or
any decoding failure narrower than the two checked above -- is caught
and treated as \"not text\": one bad file must never abort a whole
directory walk.

`get-file-buffer' is still checked first and, if it returns a buffer,
FILENAME is assumed text without being read here at all: an already
open buffer is not reached through the path this rewrite changes (no
`find-file-noselect' call, so no size, boundedness, or prompt risk from
that check), and dropping it would mean re-reading a file the caller
may be actively editing purely to re-derive a verdict `arc-watch.el'
already has cheaper access to.

Below `arc-text-file-size-ceiling', that logic runs exactly as above,
unchanged.  At or above it, FILENAME is declared binary without being
read at all -- see that variable's docstring for why."
  (and (<= (file-attribute-size (file-attributes filename))
           arc-text-file-size-ceiling)
       (or (and (get-file-buffer filename) t) ;; if file opened assume it text
           (ignore-errors
             (let ((coding-system-for-read 'utf-8))
               (with-temp-buffer
                 (insert-file-contents filename nil 0 arc-text-file-probe-size)
                 (not (save-excursion
                        (goto-char (point-min))
                        (or (search-forward "\0" nil t 1)
                            (re-search-forward "[\x3FFF80-\x3FFFFF]" nil t))))))))))

(defcustom arc-secret-denylist
  '("*.age" "*.gpg" "*.pem" "*.key" "*_ed25519" "id_rsa" "id_ed25519" ".env"
    "*.sqlite" "*.sqlite-wal" "*.sqlite-shm")
  "Path/extension patterns always excluded from `arc--file-list',
regardless of what any ignore file says or does not say.
`arc--text-file-p' already keeps a WHOLLY BINARY secret (an agenix
`.age' file's usual ciphertext payload, say) out of the corpus as a
side effect of its undecodable-byte check, but that is a content
heuristic, not policy -- an ASCII-armored `.age' or `.gpg' file, or a
PEM/private-key file that happens to decode as plain text, would sail
through it untouched.  These patterns remove that whole class up
front instead of depending on one file's contents ever tripping the
heuristic.  Uses the same pattern language as
`arc-ignore-patterns-files' (see `arc--ignore-pattern-to-regexp'): a
bare name (no slash, e.g. `id_rsa') matches as a path component at any
depth; a glob (e.g. `*.age') matches a whole path component ending
that way, likewise at any depth.

The `*.sqlite' patterns are not about secrecy but about cost and
recursion: arc's own database lives under `arc-db-directory', which
defaults inside `user-emacs-directory' -- inside the `emacs'
collection.  It is a 467 MB file, and `arc--text-file-p' reads a
candidate whole into a buffer to look for a null byte, so indexing
would load all 467 MB per run purely to conclude `binary'.  A
`.arcignore' entry covers today's layout; this covers every layout,
because `arc-db-directory' can be set anywhere."
  :type '(repeat string) :group 'arc)

(defun arc--denylisted-p (file)
  "Return non-nil if FILE matches one of `arc-secret-denylist''s patterns."
  (seq-some (lambda (regexp) (string-match-p regexp file))
            (delq nil (mapcar #'arc--ignore-pattern-to-regexp arc-secret-denylist))))

(defun arc--file-list (directory)
  "List of files to parse in DIRECTORY.
Patterns from an ignore file are matched against each file's path
relative to DIRECTORY, not its absolute path: `wildcard-to-regexp'
anchors a pattern to the whole matched string (\\=`...\\=', not a
substring search), so a bare filename in an ignore file -- e.g.
`b.txt' -- would otherwise need DIRECTORY's entire absolute path
prefix to be absent for it to ever match, and would silently never
exclude anything.  `arc-secret-denylist' is checked unconditionally,
independent of any ignore file, invisibility, or
`arc--text-file-p''s content-based verdict.  The invisible-file
patterns run against the relative path with a `/' prefixed, NOT the
absolute path: they used to match the absolute path, which meant a
collection rooted at a dotted directory -- `~/.config/emacs',
`~/.claude' -- excluded every one of its own files, because their
absolute paths all contain `/.config' or `/.claude'.  The `/' prefix
is what still catches a dotfile sitting at the root of a collection,
whose bare relative name has no leading slash for `/\\.[^/]*' to
match."
  (let ((ignore-regexps (arc--read-ignore-file-regexps directory))
        (invisible-regexps (when arc-ignore-invisible-files
                              (list "$\\.[^/]*" "/\\.[^/]*"))))
    (seq-filter (lambda (file)
		  (let ((relative (file-relative-name file directory)))
                    (and (not (seq-some (lambda (regexp)
					  (string-match-p regexp relative))
				        ignore-regexps))
                         (not (seq-some (lambda (regexp)
                                          (string-match-p regexp (concat "/" relative)))
                                        invisible-regexps))
                         (not (arc--denylisted-p file))
		         (arc--text-file-p file))))
		(directory-files-recursively directory ".*"))))

(defun arc-file-hash (path)
  "Return the SHA-1 of PATH's contents."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha1 (current-buffer))))

(defun arc-file-source (path)
  "Return the source plist for the single file PATH.
Keys: :kind, :path, :hash, :mtime, :chunks.  Factored out of
`arc-file-sources' so re-indexing one saved file goes through exactly
the same construction as a full walk -- two spellings of a source plist
would drift, and the one used by the rarer path would drift unnoticed."
  (list :kind "file"
        :path path
        :hash (arc-file-hash path)
        :mtime (truncate (float-time (file-attribute-modification-time
                                      (file-attributes path))))
        :chunks (arc-chunk-file path)))

(defun arc-indexable-file-p (path)
  "Return non-nil when PATH is a file arc would index on a directory walk.
Asks `arc--file-list' about PATH's own directory rather than
reimplementing the ignore rules and the secret denylist, which is how a
watcher would otherwise start indexing an SSH key that the walk
correctly skips."
  (let ((path (expand-file-name path)))
    (and (file-readable-p path)
         (member path (arc--file-list (file-name-directory path))))))

(defun arc-file-sources (directory)
  "Return a source plist for every indexable file under DIRECTORY.
Each plist has :kind, :path, :hash, :mtime and :chunks."
  (mapcar #'arc-file-source (arc--file-list directory)))

(defun arc-file-changed-p (path)
  "Return non-nil when PATH's content differs from what is indexed."
  (let ((known (arc-source-by-path path)))
    (or (null known)
        (not (equal (plist-get known :hash) (arc-file-hash path))))))

(provide 'arc-source-file)
;;; arc-source-file.el ends here
