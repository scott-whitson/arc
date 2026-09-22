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

(defconst arc--utf8-max-tail-bytes 3
  "Extra bytes read past `arc-text-file-probe-size' so a multi-byte
UTF-8 character starting inside the probe window, but extending past
it, can still be decoded to completion rather than cut off mid-
sequence.  A UTF-8 character is at most 4 bytes, so once its first
byte is known to be in the window, at most 3 more can still be
missing; reading this many further guarantees that.  Characters this
margin resolves are still excluded from the budget check below --
`arc--decoded-window-marks-binary-p' only reads them to tell a
genuinely undecodable byte apart from one that only looks that way
because the window ended mid-character.")

(defun arc--decoded-window-marks-binary-p (decoded budget)
  "Non-nil if DECODED holds a null byte or an undecodable byte within
its first BUDGET original bytes.  DECODED is a file's bytes decoded as
UTF-8, and may extend a little past BUDGET bytes' worth (see
`arc--utf8-max-tail-bytes') so a character starting right at the
boundary decodes correctly instead of being cut off.  This walks
DECODED once, tracking how many original bytes have been accounted
for; a character that starts within budget but whose full byte cost
would cross it is excluded whole, never partially -- which is what
keeps a read-boundary artifact from ever being mistaken for a genuine
undecodable byte, and, symmetrically, keeps a genuine undecodable byte
that truly sits at the edge of the window from being excluded along
with it: only content past the boundary is ever dropped, never
content actually within it. A run of plain, non-null ASCII -- the
common case for ordinary text -- is skipped in one `string-match'
rather than character by character, since every such character always
costs exactly one original byte; only a null byte or a non-ASCII
character (ordinary multi-byte or raw-byte alike) is priced
individually, via `encode-coding-string', to find out how many
original bytes it actually stands for."
  (let ((pos 0) (used 0) (len (length decoded)))
    (catch 'done
      (while (< pos len)
        ;; Bulk-skip a run of plain, non-null ASCII.
        (let* ((next (or (string-match "[^\x01-\x7f]" decoded pos) len))
               (run (- next pos)))
          (when (> (+ used run) budget) (throw 'done nil))
          (setq used (+ used run) pos next))
        (when (< pos len)
          (let ((ch (aref decoded pos)))
            (if (eq ch ?\0)
                (throw 'done (< used budget))
              (let ((cost (length (encode-coding-string (string ch) 'utf-8))))
                (when (> (+ used cost) budget) (throw 'done nil))
                (when (and (>= ch #x3FFF80) (<= ch #x3FFFFF)) (throw 'done t))
                (setq used (+ used cost) pos (1+ pos)))))))
      nil)))

(defun arc--text-file-p (filename)
  "Check if FILENAME contains text.
`get-file-buffer' is checked first, unconditionally: if FILENAME has a
live visiting buffer, it is assumed text without any read here at
all, regardless of `arc-text-file-size-ceiling'.  That is a deliberate
restore of the behaviour from before that ceiling existed -- checking
a live buffer costs no I/O no matter how large the file on disk claims
to be, so gating it behind a `file-attributes' call served no
protective purpose, and it kept a file the caller may be actively
editing (an open, oversized log, say) from being reclassified as
binary purely because of its size.

Past that, `file-attributes' is consulted for FILENAME's size.  A file
that has vanished between `arc--file-list''s directory walk and this
call -- an ordinary race on a live $HOME, not a contrived case -- has
no attributes at all; that is treated as \"not text\" directly, not
routed into the size comparison, which would otherwise signal
`wrong-type-argument' on a nil size and abort the whole walk that
called this.  (A dangling symlink is a different case: `lstat' still
succeeds for it, so `file-attributes' returns a size and this function
proceeds normally into the read below, which then fails and is caught
there.)

LARGER THAN `arc-text-file-size-ceiling', FILENAME is declared binary
without being read at all -- see that variable's docstring for why.  A
file of exactly the ceiling size is text: the check is `<=', matching
that variable's own \"larger than this many bytes\" wording.  At or
below it, at most `arc-text-file-probe-size' bytes (plus a small
margin, see `arc--utf8-max-tail-bytes') are read into a temporary
buffer, decoded the same way `arc-chunk-file' actually will -- not
literal -- because that mismatch is precisely the bug the undecodable-
byte check below closes.  A previous version opened FILENAME with
RAWFILE (unibyte, no decoding attempted) and only checked for a null
byte; an agenix `.age' secret's ciphertext payload contains no null
byte but is never valid UTF-8, so it passed as \"text\" here, then
failed to decode when `arc-chunk-file' read it normally for real,
producing Emacs's internal `eight-bit' raw-byte characters in the
chunked text.  Those cannot be JSON-encoded for the embeddings API, so
indexing crashed on the first such file it met -- far from FILENAME,
and far from this function.  A null byte OR any undecodable byte
(surfacing as a raw-byte character once decoded) now both mark
FILENAME binary, exactly as they did then -- see
`arc--decoded-window-marks-binary-p' for how a byte right at the probe
boundary is told apart from one that only looks undecodable because
the window ended mid-character.

A later version read FILENAME whole via `find-file-noselect', which
brought back two of its own defects: no bound on how much it read (see
`arc-text-file-size-ceiling'), and `find-file-noselect' resolving a
coding system interactively when detection is not confident enough to
pick one silently -- in batch Emacs that reads from a stdin nothing is
attached to and dies with `(end-of-file \"Error reading from stdin\")';
in the operator's live Emacs daemon, the one arc actually indexes
under, it would instead block the entire session on a modal
`Select coding system' prompt in the middle of an index run, with
nothing on screen to explain why.  `insert-file-contents-literally' is
used instead of `find-file-noselect' now specifically because it
carries none of the machinery a visited buffer gets -- no major mode,
no local variables, no auto-detected or interactively resolved coding
system, and no transparent decompression of a `.gz'-shaped candidate
either, which the plain, non-literal `insert-file-contents' used by an
earlier version of this fix still triggered.  The bytes it reads are
decoded here, explicitly, as `utf-8' -- a fixed coding system chosen
up front, never detected -- which is what removes the step that could
ever ask anyone anything.  Content that is genuinely UTF-8 decodes
exactly as it would have before; content in some other real text
encoding decodes with raw-byte characters standing in for whatever
does not fit UTF-8 and is therefore -- like any other undecodable
content -- marked binary.  That is a narrowing of what counts as
\"text\" relative to letting Emacs detect the actual encoding, but
arc's corpus is overwhelmingly UTF-8, and the alternative is the
prompt this rewrite exists to remove.  `arc-chunk-file', which reads
an accepted file for real, still auto-detects its coding system rather
than pinning `utf-8' the way this function now does, so the two can in
principle disagree about a borderline non-UTF-8 file that slips past
this check; that mismatch is unchanged from before this task and is
not what it set out to fix.

Any error signalled while reading FILENAME -- unreadable permissions,
a symlink that vanishes between the `file-attributes' call above and
this read, or any decoding failure narrower than the two checked above
-- is caught and treated as \"not text\": one bad file must never
abort a whole directory walk.

`file-regular-p' gates all of that, because `ignore-errors' cannot
catch a BLOCK.  `directory-files-recursively' returns FIFOs and
sockets along with ordinary files, and a FIFO's `file-attributes'
reports size 0 -- so `arc-text-file-size-ceiling' never fires for one,
and `insert-file-contents-literally' then blocks in `open(2)' waiting
for a writer that may never come.  Nothing recovers from that: no
error is signalled to catch, and `C-g' cannot interrupt it either, so
in a live Emacs daemon one named pipe under $HOME wedges the whole
session -- strictly worse than the oversized-video hang the size
ceiling exists for.  `file-attribute-type' does not distinguish a FIFO
from a regular file (it is nil for both); `file-regular-p' does."
  (or (and (get-file-buffer filename) t) ;; if file opened assume it text
      (and (file-regular-p filename)
           (let ((size (file-attribute-size (file-attributes filename))))
             (and size
                  (<= size arc-text-file-size-ceiling)
                  (ignore-errors
                    (let* ((budget (min size arc-text-file-probe-size))
                           (window-end (min size (+ arc-text-file-probe-size
                                                    arc--utf8-max-tail-bytes))))
                      (with-temp-buffer
                        (insert-file-contents-literally filename nil 0 window-end)
                        (not (arc--decoded-window-marks-binary-p
                              (decode-coding-string (buffer-string) 'utf-8)
                              budget))))))))))

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

(defun arc--path-indexable-p (file root ignore-regexps)
  "Return non-nil when FILE's PATH alone admits it to ROOT's corpus.
FILE is an absolute path; ROOT is the COLLECTION ROOT it is indexed
under, and every pattern here is resolved relative to that root rather
than to whatever directory FILE happens to sit in.  IGNORE-REGEXPS are
ROOT's, from `arc--read-ignore-file-regexps' -- the caller passes them
in so that a whole walk reads the ignore files once rather than once
per candidate.

Content is deliberately not consulted here; `arc--file-indexable-p'
adds that.  Splitting the two is what lets a caller ask whether a path
that does not exist WOULD be walked -- which is how
`arc-index--collection-overlaps' checks one collection root against
another's exclusions.

Patterns from an ignore file are matched against FILE's path relative
to ROOT, not its absolute path: `wildcard-to-regexp' anchors a pattern
to the whole matched string (\\=`...\\=', not a substring search), so a
bare filename in an ignore file -- e.g. `b.txt' -- would otherwise
need ROOT's entire absolute path prefix to be absent for it to ever
match, and would silently never exclude anything.  `arc-secret-denylist'
is checked unconditionally, independent of any ignore file or
invisibility rule.  The invisible-file pattern runs against the
relative path with a `/' prefixed, NOT the absolute path: it used to
match the absolute path, which meant a collection rooted at a dotted
directory -- `~/.config/emacs', `~/.claude' -- excluded every one of
its own files, because their absolute paths all contain `/.config' or
`/.claude'.  The `/' prefix is what still catches a dotfile sitting at
the root of a collection, whose bare relative name has no leading
slash for `/\\.[^/]*' to match.  A second pattern, `$\\.[^/]*', once
sat beside that one for the same job and never did it: a leading `$'
is literal in a regexp, so it matched no hidden file at all, while
false-excluding any path containing the two characters `$.'."
  (let ((relative (file-relative-name file root)))
    (and (not (seq-some (lambda (regexp) (string-match-p regexp relative))
                        ignore-regexps))
         (not (and arc-ignore-invisible-files
                   (string-match-p "/\\.[^/]*" (concat "/" relative))))
         (not (arc--denylisted-p file)))))

(defun arc--file-indexable-p (file root ignore-regexps)
  "Return non-nil when FILE belongs in the collection rooted at ROOT.
`arc--path-indexable-p' plus `arc--text-file-p''s content verdict --
the whole per-file predicate, for exactly one file and without
enumerating any directory.  `arc--file-list' is a walk filtered
through this and `arc-indexable-file-p' is this for a single path, so
the walk and the watcher cannot drift apart on what belongs in the
corpus.  IGNORE-REGEXPS are ROOT's; see `arc--path-indexable-p'."
  (and (arc--path-indexable-p file root ignore-regexps)
       (arc--text-file-p file)))

(defun arc--file-list (directory)
  "List of files to parse in DIRECTORY.
A walk plus a filter over `arc--file-indexable-p', which is where every
rule about what belongs in the corpus now lives.  DIRECTORY's ignore
files are read once for the whole walk rather than once per candidate."
  (let ((ignore-regexps (arc--read-ignore-file-regexps directory)))
    (seq-filter (lambda (file) (arc--file-indexable-p file directory ignore-regexps))
                (directory-files-recursively directory ".*"))))

(defun arc-file-hash-coding-system (&rest _)
  "Coding system `arc-file-hash' hashes with.
A named function rather than a lambda on purpose: Emacs requires
`select-safe-coding-system-function' to hold a SYMBOL, and rejects a
closure with `wrong-type-argument symbolp'."
  'utf-8-unix)

(defun arc-file-hash (path)
  "Return the SHA-1 of PATH's contents.

The read is literal, so every high byte arrives as an eight-bit
character, and `secure-hash' then ENCODES the buffer to hash it -- which
consults `select-safe-coding-system'.  That function normally chooses
silently, but it QUERIES the user when its choice is inconsistent with
what `find-auto-coding' would take from the file's own coding cookie
(`<meta charset=...>', `-*- coding: -*-').  A query is fatal to an
unattended walk: in the daemon it blocks the session on a modal
minibuffer, and in batch Emacs it dies with `end-of-file', reading an
answer from a stdin nothing is attached to.  Found live: one HTML template
carrying a `<meta charset>' cookie stopped a whole dotfiles reindex
part-way through.

This is the second instance of the class here -- `arc--text-file-p' was
the first, and `test-arc-text-file-noninteractive.el' records it.  The
rule both fixes encode: a corpus walk must never let Emacs choose a
coding system on its own.

The selector is pinned rather than defaulted so the hash of a given file
is the same in every context that computes it.  Its job is change
detection, not byte identity, and pinning reproduces the values already
stored: measured against 12 readable sampled sources, 11 hashed
identically and the one that differed had changed on disk."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (let ((select-safe-coding-system-function #'arc-file-hash-coding-system))
      (secure-hash 'sha1 (current-buffer)))))

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

(defun arc-indexable-file-p (path root)
  "Return non-nil when a walk of ROOT would index PATH.
ROOT is PATH's COLLECTION directory -- `arc-collection-directory''s
answer for the collection PATH resolved to -- not the directory PATH
itself happens to sit in.  Both halves of that matter, and both were
once wrong here.

This used to call `arc--file-list' on `(file-name-directory PATH)' and
ask whether PATH came back.  For a file directly in $HOME that
enumerated the ENTIRE home tree -- measured at 17.4 seconds warm --
synchronously, inside `after-save-hook', and `arc-watch-sweep' could
pay it up to `arc-watch-sweep-batch' times on a single idle tick.  It
was also wrong, not merely slow: `arc--file-list' reads ignore files
from the directory it is handed, so `.arcignore' at the COLLECTION
ROOT -- the only thing keeping `home' out of `vault''s territory --
was never consulted on this path, and the watcher indexed files the
walk correctly excludes.  Resolving both the ignore files and the
relative path against ROOT is what makes the watcher and the walk
answer the same question."
  (let ((path (expand-file-name path))
        (root (file-name-as-directory (expand-file-name root))))
    (and (file-readable-p path)
         (string-prefix-p root path)
         (arc--file-indexable-p path root (arc--read-ignore-file-regexps root)))))

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
