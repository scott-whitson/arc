# arc home corpus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make arc index everything under `~` that is actually data — including the dotted directories that hold it — under five collections with the right chunker each, and retire the stale `eminix` name.

**Architecture:** One blocking defect first: the invisible-file filter matches absolute paths, so any collection rooted at a dotted directory excludes all of its own contents. Fix that to match relative to the collection root, add a `.arcignore` mechanism for per-directory exclusions, then rewrite the collection layout on top of both. No embedding change, no Needle, no production reindex.

**Tech Stack:** Emacs Lisp (29.2 floor), SQLite via `sqlite-select`, `sqlite-vec` `vec0`, FTS5, ERT.

**Spec:** `docs/superpowers/specs/2026-09-17-needle-and-home-corpus-design.md`

## Global Constraints

- **Emacs 29.2 minimum.** Do not use Emacs 30+ only APIs (notably the `sort` keyword calling convention — use `(sort LIST PREDICATE)`).
- **The byte-compile gate treats warnings as errors.** `test/run.sh` runs `emacs -Q -batch -L . -f batch-byte-compile arc*.el` and fails on any line matching `Warning:`. Every new file must `require` what it uses and leave no unused variables.
- **No hardcoded home paths anywhere**, in code or docs. Derive from `(getenv "HOME")`. This repo is public.
- **No private content in the repo.** No vault text, no real note paths, no real query strings.
- **No `Co-Authored-By` or AI-attribution trailers** in any commit message.
- **Tests must not require Ollama.** Nothing in this plan embeds.
- **No production reindex in this plan.** The spec pairs corpus growth with the embedding swap so the corpus is re-embedded once, not twice. Tasks here change configuration and the code that reads it; the real rebuild happens in the Needle plan.
- Branch is `feat/home-corpus`. Commit after every task.
- Run the full suite with `test/run.sh`; run one suite with `emacs -Q -batch -L . -l test/<file>.el -f ert-run-tests-batch-and-exit`.

---

### Task 1: The invisible-file filter must be relative to the collection root

`arc--file-list` (`arc-source-file.el:148`) tests the invisible-file patterns
against each file's **absolute** path, deliberately — its docstring says the
patterns "keep matching the absolute path instead, where that substring is
always present for a dotfile."

That choice makes a collection rooted at a dotted directory impossible. For a
collection rooted at `~/.config/emacs`, every file's absolute path contains
`/.config`, so the pattern `/\.[^/]*` matches all of them and the collection
indexes nothing at all — silently, because an empty file list is not an error.
`~/.claude` and `~/.agent-shell` fail the same way. This blocks three of the
five collections in the spec.

The fix is to match the invisible patterns against the path relative to
DIRECTORY, slash-prefixed. Slash-prefixing matters: a bare relative name like
`.gitignore` has no leading `/` for `/\.[^/]*` to match, so without the prefix a
top-level dotfile inside a collection would start being indexed — a second,
opposite regression. `(concat "/" (file-relative-name file directory))` makes
the collection root's own dottiness invisible to the filter while keeping every
dotted entry *inside* the collection excluded exactly as before.

**Files:**
- Modify: `arc-source-file.el` (`arc--file-list`, `arc-source-file.el:148-161`)
- Test: `test/test-arc-invisible-root.el` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `(arc--file-list DIRECTORY)` — unchanged signature and return type
  (a list of absolute path strings). Behaviour change only: a DIRECTORY whose
  own path contains a dotted component no longer excludes its entire contents.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-invisible-root.el`:

```elisp
;;; test-arc-invisible-root.el --- a dotted collection root is indexable -*- lexical-binding: t; -*-
;;
;; `arc--file-list' tested the invisible-file patterns against each file's
;; ABSOLUTE path on purpose.  That silently made any collection rooted at a
;; dotted directory index nothing: every file under ~/.config/emacs has
;; "/.config" in its absolute path, so the "/\\.[^/]*" pattern matched all of
;; them.  Three of arc's five collections live under dotted roots, so the
;; patterns now run against the slash-prefixed RELATIVE path instead.  Both
;; halves are pinned here: a dotted root indexes its files, and a dotted entry
;; INSIDE any root -- including a top-level one, which is why the relative name
;; is slash-prefixed -- is still skipped.
(require 'ert)
(defvar air-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path air-root)
(require 'arc-source-file)

(defmacro air-with-tree (spec &rest body)
  "Create a temp dir, populate it from SPEC, bind it to `root', run BODY.
SPEC is a list of (RELATIVE-PATH . CONTENTS)."
  (declare (indent 1))
  `(let ((root (make-temp-file "air" t)))
     (unwind-protect
         (progn
           (dolist (cell ,spec)
             (let ((f (expand-file-name (car cell) root)))
               (make-directory (file-name-directory f) t)
               (with-temp-file f (insert (cdr cell)))))
           ,@body)
       (delete-directory root t))))

(ert-deftest air-dotted-root-still-lists-its-files ()
  "A collection root that is itself dotted must index its contents."
  (air-with-tree '(("lisp/config.el" . "(provide 'config)"))
    ;; Stage the tree under a dotted parent, the shape of ~/.config/emacs.
    (let* ((dotted (expand-file-name ".config/emacs" root)))
      (make-directory dotted t)
      (rename-file (expand-file-name "lisp" root) (expand-file-name "lisp" dotted))
      (should (equal (mapcar (lambda (f) (file-relative-name f dotted))
                             (arc--file-list dotted))
                     '("lisp/config.el"))))))

(ert-deftest air-dotted-entry-inside-a-root-is-still-skipped ()
  "A dotted directory INSIDE a collection stays excluded."
  (air-with-tree '(("keep.el" . "keep")
                   (".git/config" . "secret")
                   ("sub/.hidden/x.el" . "hidden"))
    (should (equal (mapcar (lambda (f) (file-relative-name f root))
                           (arc--file-list root))
                   '("keep.el")))))

(ert-deftest air-top-level-dotfile-is-still-skipped ()
  "The slash prefix is what keeps a top-level dotfile excluded."
  (air-with-tree '(("keep.el" . "keep") (".envrc" . "use nix"))
    (should (equal (mapcar (lambda (f) (file-relative-name f root))
                           (arc--file-list root))
                   '("keep.el")))))

(provide 'test-arc-invisible-root)
;;; test-arc-invisible-root.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-invisible-root.el -f ert-run-tests-batch-and-exit`
Expected: FAIL. `air-dotted-root-still-lists-its-files` fails with the list being
`nil` rather than `("lisp/config.el")` — every file excluded by the absolute-path
match. The other two tests pass already; they are regression guards for the fix.

- [ ] **Step 3: Write minimal implementation**

In `arc-source-file.el`, replace the `seq-filter` body in `arc--file-list` so the
invisible patterns take the slash-prefixed relative name:

```elisp
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
```

Replace the docstring paragraph beginning "The invisible-file patterns are
unanchored substring regexps" with:

```elisp
`arc-secret-denylist' is checked unconditionally, independent of any
ignore file, invisibility, or `arc--text-file-p''s content-based
verdict.  The invisible-file patterns run against the relative path
with a `/' prefixed, NOT the absolute path: they used to match the
absolute path, which meant a collection rooted at a dotted directory
-- `~/.config/emacs', `~/.claude' -- excluded every one of its own
files, because their absolute paths all contain `/.config' or
`/.claude'.  The `/' prefix is what still catches a dotfile sitting at
the root of a collection, whose bare relative name has no leading
slash for `/\\.[^/]*' to match.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-invisible-root.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 3 tests.

Then confirm nothing else regressed: `test/run.sh`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add arc-source-file.el test/test-arc-invisible-root.el
git commit -m "fix(source-file): let a dotted directory be a collection root

The invisible-file patterns ran against each file's absolute path, so a
collection rooted at ~/.config/emacs matched /.config on every file and
indexed nothing, silently. They now run against the slash-prefixed
relative path, which leaves the root's own dottiness alone and still
skips every dotted entry inside it."
```

---

### Task 2: `.arcignore`, and never read arc's own database

Two exclusions the collection layout needs.

**`.arcignore`.** `~/docs/org` is owned by the `vault` collection with the `org`
chunker. A `home` collection rooted at `~` would index it a second time with the
`file` chunker, producing duplicate chunks with no org ids. `~/downloads` (2,330
files of installer junk) should not be indexed at all. `arc--read-ignore-file-regexps`
already reads per-directory ignore files listed in `arc-ignore-patterns-files`;
adding a dedicated `.arcignore` filename gets both exclusions with no new code
and, unlike reusing `.ignore`, changes nothing about ripgrep's behaviour for the
operator.

**The database.** `~/.config/emacs/arc/arc.sqlite` is 467 MB.
`arc--text-file-p` (`arc-source-file.el:102`) calls `find-file-noselect` and
scans the buffer for a null byte — so once the `emacs` collection exists, every
index run reads 467 MB into a buffer to conclude "binary". A `.arcignore` entry
covers the current layout, but `arc-db-directory` is a defcustom and can move,
so the denylist gets the pattern too and no future collection can reintroduce it.

**Files:**
- Modify: `arc-source-file.el` (`arc-ignore-patterns-files`, `arc-source-file.el:21`; `arc-secret-denylist`, `arc-source-file.el:111`)
- Test: `test/test-arc-arcignore.el` (create)

**Interfaces:**
- Consumes: `arc--file-list` from Task 1, unchanged signature.
- Produces: `arc-ignore-patterns-files` defaults to
  `'(".gitignore" ".ignore" ".rgignore" ".arcignore")`; `arc-secret-denylist`
  gains `"*.sqlite"`, `"*.sqlite-wal"`, `"*.sqlite-shm"`.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-arcignore.el`:

```elisp
;;; test-arc-arcignore.el --- per-directory arc-only exclusions -*- lexical-binding: t; -*-
;;
;; The `home' collection is rooted at $HOME and overlaps two things it must not
;; index: ~/docs/org, which `vault' already owns with the org chunker, and
;; ~/downloads.  `.arcignore' carries those exclusions through the ignore-file
;; machinery that already exists, under a filename of arc's own so nothing here
;; changes what ripgrep does.  Separately, arc's own 467 MB sqlite database sits
;; under ~/.config/emacs, which the `emacs' collection indexes -- and
;; `arc--text-file-p' would read all 467 MB into a buffer just to decide it is
;; binary.  `arc-db-directory' is a defcustom and can move, so the denylist
;; covers the database by pattern rather than trusting one path to stay put.
(require 'ert)
(defvar aai-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aai-root)
(require 'arc-source-file)

(defmacro aai-with-tree (spec &rest body)
  "Create a temp dir, populate it from SPEC, bind it to `root', run BODY."
  (declare (indent 1))
  `(let ((root (make-temp-file "aai" t)))
     (unwind-protect
         (progn
           (dolist (cell ,spec)
             (let ((f (expand-file-name (car cell) root)))
               (make-directory (file-name-directory f) t)
               (with-temp-file f (insert (cdr cell)))))
           ,@body)
       (delete-directory root t))))

(ert-deftest aai-arcignore-is-honoured ()
  "A .arcignore file excludes the directories it names."
  (aai-with-tree '((".arcignore" . "docs/org/\ndownloads/\n")
                   ("keep.txt" . "keep")
                   ("docs/org/note.org" . "owned by vault")
                   ("downloads/installer.txt" . "junk"))
    (should (equal (mapcar (lambda (f) (file-relative-name f root))
                           (arc--file-list root))
                   '("keep.txt")))))

(ert-deftest aai-arcignore-is-in-the-default-pattern-files ()
  "Shipping the mechanism is not enough; the filename must be a default."
  (should (member ".arcignore" arc-ignore-patterns-files)))

(ert-deftest aai-sqlite-database-is-denylisted ()
  "arc must never read its own database, wherever `arc-db-directory' points."
  (should (arc--denylisted-p "/anywhere/at/all/arc/arc.sqlite"))
  (should (arc--denylisted-p "/anywhere/at/all/arc/arc.sqlite-wal"))
  (should (arc--denylisted-p "/anywhere/at/all/arc/arc.sqlite-shm"))
  (should-not (arc--denylisted-p "/anywhere/at/all/notes/sqlite-tips.org")))

(provide 'test-arc-arcignore)
;;; test-arc-arcignore.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-arcignore.el -f ert-run-tests-batch-and-exit`
Expected: FAIL. All three tests fail — `.arcignore` is not read, is not in the
defaults, and `*.sqlite` is not denylisted.

- [ ] **Step 3: Write minimal implementation**

In `arc-source-file.el`, change the `arc-ignore-patterns-files` default:

```elisp
(defcustom arc-ignore-patterns-files '(".gitignore" ".ignore" ".rgignore" ".arcignore")
  "Files with patterns to ignore during file parsing.
`.arcignore' is arc's own, and is the one to reach for when an
exclusion should apply to indexing and to nothing else: the `home'
collection is rooted at $HOME and must skip `docs/org' -- which
`vault' already owns, with the org chunker -- without that exclusion
also changing what ripgrep and every other tool that honours
`.ignore' can see."
  :type '(repeat string) :group 'arc)
```

And extend `arc-secret-denylist`:

```elisp
(defcustom arc-secret-denylist
  '("*.age" "*.gpg" "*.pem" "*.key" "*_ed25519" "id_rsa" "id_ed25519" ".env"
    "*.sqlite" "*.sqlite-wal" "*.sqlite-shm")
```

Append to that defcustom's docstring, before the closing quote:

```elisp
The `*.sqlite' patterns are not about secrecy but about cost and
recursion: arc's own database lives under `arc-db-directory', which
defaults inside `user-emacs-directory' -- inside the `emacs'
collection.  It is a 467 MB file, and `arc--text-file-p' reads a
candidate whole into a buffer to look for a null byte, so indexing
would load all 467 MB per run purely to conclude `binary'.  A
`.arcignore' entry covers today's layout; this covers every layout,
because `arc-db-directory' can be set anywhere.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-arcignore.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 3 tests.

Then: `test/run.sh`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add arc-source-file.el test/test-arc-arcignore.el
git commit -m "feat(source-file): .arcignore, and keep arc.sqlite out of the corpus

.arcignore joins the ignore-file defaults so the home collection can
skip docs/org -- which vault owns with the org chunker -- without
changing what ripgrep sees. The sqlite patterns join the denylist
because arc-db-directory defaults inside the emacs collection, and
arc--text-file-p would read the whole 467 MB database per run to
decide it is binary."
```

---

### Task 3: The five collections

Rewrite the collection layout so arc covers everything under `~` that is data.
`dotfiles` and `eminix` are deleted rather than renamed — `home` subsumes both.
`mail` is configured but deliberately absent from `arc-index-plan`, so indexing
mail is a one-line opt-in and never a surprise.

Measured 2026-09-17: 12,593 visible files under `~` (`~/projects` 10,734,
`~/downloads` 2,330, `~/docs` 2,103, `~/dotfiles` 230), against a current corpus
of roughly 63,000 chunks.

**Files:**
- Modify: `arc-index.el` (`arc-collection-directory-alist`, `arc-index.el:411-417`; `arc-index-plan`, `arc-index.el:424-428`)
- Test: `test/test-arc-collections.el` (create)

**Interfaces:**
- Consumes: `arc-collection-directory` (`arc-index.el:419`), unchanged.
- Produces: `arc-collection-directory-alist` keys `"vault"`, `"home"`,
  `"emacs"`, `"claude"`, `"agent-shell"`, `"mail"`. `arc-index-plan` entries for
  the first five only, `"vault"` mapped to `org` and the rest to `file`.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-collections.el`:

```elisp
;;; test-arc-collections.el --- the corpus is every part of ~ that is data -*- lexical-binding: t; -*-
;;
;; arc used to index three directories, one of which (`eminix') did not exist.
;; The layout now covers $HOME whole, split by chunker rather than by topic:
;; `vault' keeps the org chunker over ~/docs/org, `home' takes everything else
;; visible under ~, and the three dotted roots that hold data get their own
;; collections because `arc-ignore-invisible-files' excludes them from `home' by
;; construction.  `mail' is configured but out of the plan: indexing mail should
;; be a deliberate act.
(require 'ert)
(defvar acl-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path acl-root)
(require 'arc-index)

(ert-deftest acl-every-planned-collection-has-a-directory ()
  "A plan entry with no directory signals at index time; catch it here."
  (dolist (entry arc-index-plan)
    (let ((name (car entry)))
      ;; The option collections are synthesised, not read from a directory.
      (unless (memq (cdr entry) '(nixopt hmopt info))
        (should (arc-collection-directory name))))))

(ert-deftest acl-vault-keeps-the-org-chunker ()
  "Dropping ~/docs/org to the file chunker would lose org ids and titles,
which `arc-eval''s :org-id matching depends on."
  (should (eq 'org (alist-get "vault" arc-index-plan nil nil #'equal))))

(ert-deftest acl-dotted-data-roots-are-their-own-collections ()
  "`home' cannot reach them: `arc-ignore-invisible-files' is t."
  (dolist (name '("emacs" "claude" "agent-shell"))
    (should (assoc name arc-collection-directory-alist))
    (should (eq 'file (alist-get name arc-index-plan nil nil #'equal)))))

(ert-deftest acl-mail-is-configured-but-not-planned ()
  "Opt-in, not surprise."
  (should (assoc "mail" arc-collection-directory-alist))
  (should-not (assoc "mail" arc-index-plan)))

(ert-deftest acl-retired-collections-are-gone ()
  "`home' subsumes both; `eminix' never existed on this host anyway."
  (should-not (assoc "dotfiles" arc-collection-directory-alist))
  (should-not (assoc "eminix" arc-collection-directory-alist))
  (should-not (assoc "dotfiles" arc-index-plan))
  (should-not (assoc "eminix" arc-index-plan)))

(ert-deftest acl-no-collection-hardcodes-a-home-path ()
  "This repo is public; every path derives from $HOME."
  (dolist (cell arc-collection-directory-alist)
    (should (string-prefix-p (expand-file-name "~") (cdr cell)))))

(provide 'test-arc-collections)
;;; test-arc-collections.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-collections.el -f ert-run-tests-batch-and-exit`
Expected: FAIL. `acl-vault-keeps-the-org-chunker` passes (vault already uses
`org`); `acl-dotted-data-roots-are-their-own-collections`,
`acl-mail-is-configured-but-not-planned` and `acl-retired-collections-are-gone`
all fail against the current three-collection layout.

- [ ] **Step 3: Write minimal implementation**

In `arc-index.el`, replace `arc-collection-directory-alist`:

```elisp
(defcustom arc-collection-directory-alist
  `(("vault"       . ,(expand-file-name "docs/org" (getenv "HOME")))
    ("home"        . ,(expand-file-name (getenv "HOME")))
    ("emacs"       . ,(expand-file-name ".config/emacs" (getenv "HOME")))
    ("claude"      . ,(expand-file-name ".claude" (getenv "HOME")))
    ("agent-shell" . ,(expand-file-name ".agent-shell" (getenv "HOME")))
    ("mail"        . ,(expand-file-name ".mail" (getenv "HOME"))))
  "Map a collection name to the directory it indexes.
Derived from $HOME -- never hardcode an absolute home path here.

`home' is $HOME itself.  That is safe rather than reckless because
`arc-ignore-invisible-files' defaults to t, so every dotted directory
is excluded from it -- ~/.cache, ~/.local (124,521 files, 14 GB),
~/.pi (41,982 files) and the browser and password-manager caches never
enter the corpus.  Its overlap with `vault' is excluded through
~/.arcignore; see `arc-ignore-patterns-files'.

That same exclusion is why `emacs', `claude' and `agent-shell' are
separate entries: they hold data, they live under dotted roots, and
`home' cannot see them.  Turning `arc-ignore-invisible-files' off
globally to reach them is not the alternative -- that would admit all
14 GB of ~/.local.

`mail' is configured but deliberately absent from `arc-index-plan'.
Indexing mail should be something the operator turns on, not something
that happens because a default changed."
  :type '(alist :key-type string :value-type directory) :group 'arc)
```

And `arc-index-plan`:

```elisp
(defcustom arc-index-plan
  '(("vault" . org) ("home" . file) ("emacs" . file)
    ("claude" . file) ("agent-shell" . file)
    ("nix options" . nixopt) ("hm options" . hmopt) ("builtin manuals" . info))
  "Collections to build and the chunker each uses.
`vault' must stay on the `org' chunker: the `file' chunker would index
the same text without org ids or titles, and `arc-eval''s `:org-id'
expectations match on exactly those.  `mail' is absent on purpose; see
`arc-collection-directory-alist'."
  :type '(alist :key-type string :value-type symbol) :group 'arc)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-collections.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 6 tests.

Then: `test/run.sh`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add arc-index.el test/test-arc-collections.el
git commit -m "feat(index): index all of ~, split by chunker

vault keeps the org chunker, home takes everything else visible under
\$HOME, and emacs/claude/agent-shell get their own collections because
arc-ignore-invisible-files keeps home out of every dotted root. mail is
configured but left out of the plan. dotfiles and eminix are gone --
home subsumes both, and eminix pointed at a directory that does not
exist on any host here."
```

---

### Task 4: `eminix` is `emanix`

`eminix` is not a typo but a stale name. The distribution is `emanix`
(`~/projects/emanix/flake.nix:2`, "emanix — a NixOS distribution"), its manual
moved to emanix.net in commit `7cd671a`, and its Emacs layer ships
`emanix-welcome.el` with `emanix/`-prefixed symbols.

Task 3 already deleted the `eminix` collection entry. What remains is prose,
tests and a fixture.

**Do not touch anything under `docs/design/`.** Those are dated records of what
was true when written, and `docs/design/2026-08-29-design.md:33` is specifically
about a hardcoded-path defect — rewriting it destroys the evidence of the bug
that motivated arc's redesign.

**Files:**
- Modify: `arc.el:1` (package header line), `arc.el:64`
- Modify: `arc-index.el:619` (comment)
- Modify: `README.org:255,259,266`
- Modify: `test/test-arc-index.el:134,235`
- Modify: `test/fixtures/roam/note-b.org:4,7`
- Test: `test/test-arc-offline.el` (extend the existing forbidden-string suite)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. No symbol changes — `eminix` never appeared in a function
  or variable name in this repo, only in prose, one collection key (already
  gone) and a fixture's text.

- [ ] **Step 1: Write the failing test**

`test/test-arc-offline.el` already walks a list of forbidden strings
(`ao-forbidden`, `test/test-arc-offline.el:43`). Add a suite beside it rather
than overloading that one, because this check spans docs and tests too, not just
the shipped elisp. Create `test/test-arc-emanix.el`:

```elisp
;;; test-arc-emanix.el --- the distribution is emanix, never eminix -*- lexical-binding: t; -*-
;;
;; `eminix' was the distribution's old name.  It is `emanix' now
;; (emanix/flake.nix: "emanix -- a NixOS distribution"), and the stale spelling
;; was not harmless: arc-collection-directory-alist pointed at ~/projects/eminix,
;; a directory that exists on no host here, and arc-index.el treats a missing
;; directory as an ordinary reported skip -- so that collection indexed nothing
;; and said nothing.  docs/design/ is deliberately exempt: those are dated
;; records, and 2026-08-29-design.md is ABOUT a hardcoded-path bug, so rewriting
;; it would destroy the evidence.
(require 'ert)
(defvar aem-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))

(ert-deftest aem-no-stale-distribution-name ()
  "Live code, docs, tests and fixtures say emanix."
  (let ((default-directory aem-root)
        (offenders '()))
    (dolist (file (append (directory-files aem-root t "\\.el\\'")
                          (list (expand-file-name "README.org" aem-root))
                          (directory-files (expand-file-name "test" aem-root) t "\\.el\\'")
                          (directory-files-recursively
                           (expand-file-name "test/fixtures" aem-root) "\\.org\\'")))
      (when (file-regular-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (search-forward "eminix" nil t)
            (push (file-relative-name file aem-root) offenders)))))
    (should (equal offenders '()))))

(provide 'test-arc-emanix)
;;; test-arc-emanix.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-emanix.el -f ert-run-tests-batch-and-exit`
Expected: FAIL, listing `arc.el`, `arc-index.el`, `README.org`,
`test/test-arc-index.el` and `test/fixtures/roam/note-b.org` as offenders.

- [ ] **Step 3: Write minimal implementation**

`arc.el:1` — the package header line:

```elisp
;;; arc.el --- Local config-aware oracle for emanix -*- lexical-binding: t -*-
```

`arc.el:64` — in the comment, `eminix/arc--setup` becomes `emanix/arc--setup`.

`arc-index.el:619` — the comment example becomes:

```elisp
`arc-collection-directory-alist' can name a directory that is simply
absent here -- a collection whose checkout this host does not have,
for instance -- and `directory-files-recursively' used to signal
```

(The `eminix` example is replaced rather than renamed: Task 3 deleted that
collection, so naming it here would point at nothing.)

`README.org` — replace the whole worked example in section
`*** 2. Point arc at your own files, not the author's`. The existing
`#+begin_src elisp` block at `README.org:252-262` becomes:

```org
#+begin_src elisp
;; arc-collection-directory-alist defaults to:
(("vault"       . "~/docs/org")
 ("home"        . "~")
 ("emacs"       . "~/.config/emacs")
 ("claude"      . "~/.claude")
 ("agent-shell" . "~/.agent-shell")
 ("mail"        . "~/.mail"))

;; arc-index-plan defaults to (note: no "mail"):
(("vault" . org) ("home" . file) ("emacs" . file)
 ("claude" . file) ("agent-shell" . file)
 ("nix options" . nixopt) ("hm options" . hmopt)
 ("builtin manuals" . info))
#+end_src
```

and the paragraph immediately after it (`README.org:264-270`) becomes:

```org
Before indexing anything, either edit these two variables (in your
init file, with ~setopt~ or ~customize-set-variable~) to name your own
directories and collections, or remove the entries you have no
equivalent of. ~"mail"~ is configured but deliberately absent from
~arc-index-plan~: add it there to index mail, and nothing will do so
until you do. The ~"nix options"~ and ~"hm options"~ entries also need
a real flake: see ~arc-nixopt-flake~ and ~arc-hm-flake~ (both default
to ~~/dotfiles~ too) in ~arc-source-nixopt.el~ -- if you are not on
NixOS/Home-Manager, drop those two plan entries as well.
```

`test/test-arc-index.el:134` — the docstring's example callers:

```elisp
lets a caller (emanix/arc-reindex, emanix/arc-reindex-notes) rebuild
```

`test/test-arc-index.el:235` — replace the parenthetical
"(`eminix' on a machine with no such checkout, for instance)" with
"(a collection whose checkout this host does not have, for instance)".

`test/fixtures/roam/note-b.org:4,7` — retitle the fixture:

```org
#+title: emanix
```

and the body line:

```org
emanix is the distribution, never a host.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-emanix.el -f ert-run-tests-batch-and-exit`
Expected: PASS, 1 test.

The fixture retitle can break a suite that asserts on its text. Run the org and
retrieval suites explicitly:

Run: `emacs -Q -batch -L . -l test/test-arc-org.el -f ert-run-tests-batch-and-exit`
Run: `test/run.sh`
Expected: exit 0. If a suite asserted the literal string `eminix` from that
fixture, update the assertion — the fixture's name is the thing under test
nowhere, it is only a stand-in document.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: the distribution is emanix, not eminix

Stale name, not a typo: the distro renamed and arc did not follow, which
is why arc-collection-directory-alist pointed at ~/projects/eminix and
that collection silently indexed nothing for weeks -- a missing
directory is an ordinary reported skip. docs/design/ keeps the old
spelling on purpose; those are dated records and one of them is about
the hardcoded-path bug itself."
```

---

### Task 5: Document the operator's `.arcignore` files

The two `.arcignore` files live in `$HOME`, outside this repo. This repo is
public and must not hardcode home paths, so they cannot ship here — but a
mechanism nobody knows to use is worse than no mechanism. README gets the exact
content to write.

**Files:**
- Modify: `README.org` (the collections section, after the `arc-index-plan` example updated in Task 4)
- Test: none. This task ships documentation only; the mechanism it documents is
  already covered by `test/test-arc-arcignore.el` from Task 2.

**Interfaces:**
- Consumes: `arc-ignore-patterns-files` from Task 2, `arc-collection-directory-alist` from Task 3.
- Produces: nothing.

- [ ] **Step 1: Add a new section to README.org**

Insert this as a new `***` section between `*** 2. Point arc at your own files,
not the author's` and `*** 3. Build the index`:

```org
*** 2b. Exclude what the =home= collection overlaps

The =home= collection is rooted at =$HOME=, so two exclusions have to live
outside this repo, in files you write once:

=~/.arcignore=:
#+begin_example
docs/org/
downloads/
#+end_example

=docs/org/= is owned by =vault=, which indexes it with the org chunker; without
this line every note is indexed twice, and the second copy has no org id.
=downloads/= is installer and ISO junk.

=~/.config/emacs/.arcignore=:
#+begin_example
elpa/
eln-cache/
auto-save-list/
ellama-sessions/
arc/
#+end_example

=arc/= is where =arc-db-directory= puts =arc.sqlite=. Indexing it is also
blocked by =arc-secret-denylist=, which covers the case where you have pointed
=arc-db-directory= somewhere else; the line here is the cheap belt to that
braces.

Nothing else needs excluding: =arc-ignore-invisible-files= is =t=, so every
other dotted directory under =$HOME= -- =~/.cache=, =~/.local=, =~/.pi=,
browser and password-manager caches -- is already out of =home=.
```

- [ ] **Step 2: Verify the README still renders as valid org**

Run: `emacs -Q -batch -l org --eval '(with-temp-buffer (insert-file-contents "README.org") (org-mode) (org-element-parse-buffer) (message "README parses"))'`
Expected: prints `README parses`, no error.

- [ ] **Step 3: Commit**

```bash
git add README.org
git commit -m "docs: the two .arcignore files the home collection needs

The mechanism landed with the collections; the content has to live in
\$HOME, which a public repo cannot ship. Write it down instead."
```

---

### Task 6: Re-baseline the eval set on the new corpus, without rebuilding production

The Needle plan's bake-off compares embedding models against a recall baseline.
The existing one — `recall@3 0.12  @5 0.25  @10 0.75  6/8 found`
(`arc-index.el:131`) — was measured over the `dotfiles` collection, which no
longer exists. A comparison against a baseline from a different corpus measures
nothing.

This task produces the new baseline. It does **not** rebuild the production
database: the spec pairs corpus growth with the embedding swap precisely so the
corpus is re-embedded once, and that run belongs to the Needle plan.

**Files:**
- Modify: the file named by `arc-eval-set-file` — outside this repo by design
  (`arc-eval.el:20`: "this repo is public, so committing one would publish the
  shape of a private vault"). An operator step, not a repo change.
- Modify: `docs/superpowers/specs/2026-09-17-needle-and-home-corpus-design.md`
  (the baseline figures under "Retrieval: Needle, if and only if it measures
  better").
- No change to `arc-eval.el` itself: `arc-eval-run` already takes a set and an arm.
- Test: none. This task runs an existing harness and records a number.

**Interfaces:**
- Consumes: `arc-eval-run`, `arc-eval-recall` (`arc-eval.el:173`, `arc-eval.el:201`).
- Produces: a recorded baseline for the Needle plan to compare against.

- [ ] **Step 1: Repoint any `dotfiles`-scoped eval questions**

Open the file named by `arc-eval-set-file`. Any entry with
`:scope (:collections ("dotfiles"))` becomes `:scope (:collections ("home"))`.
Any entry scoped to `("eminix")` becomes `("home")` as well.

Run: `M-x arc-eval-check`
Expected: validation passes — every `:expect` clause still resolves to a source
that exists.

- [ ] **Step 2: Build a scratch index on the new layout**

Do not touch `~/.config/emacs/arc/arc.sqlite`. Point `arc-db-directory` at a
temporary directory for this run:

```elisp
(let ((arc-db-directory (make-temp-file "arc-baseline" t)))
  (arc-reindex-all)
  (arc-eval-run))
```

Expected: an index over the five collections, then a recall report. This is the
20–40 minute step; it embeds against the current `nomic-embed-text` provider, so
Ollama must be running.

- [ ] **Step 3: Record the baseline in the spec**

Append the measured `recall@5` and `recall@10` to
`docs/superpowers/specs/2026-09-17-needle-and-home-corpus-design.md`, under
"Retrieval: Needle, if and only if it measures better", replacing the
`0.25 / 0.75` figures with the new corpus's numbers and noting the date and the
collection set they were measured over.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-09-17-needle-and-home-corpus-design.md
git commit -m "docs(spec): re-baseline recall on the five-collection corpus

The 0.25/0.75 figures were measured over the dotfiles collection, which
no longer exists. The Needle bake-off compares against this instead."
```

---

## What this plan does not do

- **No production reindex.** Task 6 builds a scratch index for measurement only.
  The real rebuild happens once, in the Needle plan, when the embedding model is
  settled — the spec's reason for pairing them.
- **No back-glue deletion.** Removing `arc-ask`, `arc-answer.el` and
  `arc-chat-provider` is its own plan. It is a wider refactor than it looks:
  `arc-ask-normalize-scope` is consumed by `arc-tool.el:46` and `arc-eval.el:168`,
  both of which survive, so it needs rehoming rather than deleting.
- **No Needle.** Sidecar, embedding bake-off and front glue are the next two plans.
