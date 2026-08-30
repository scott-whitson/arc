# arc Phase 3 — Scoped Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a scoped query actually search its scope, and expose that as the `n` (vault) and `o` (options) entry points, the in-buffer `s` key, and an explicit refusal when nothing in scope matches.

**Architecture:** A scope is a plist compiled to one SQL predicate over `data` joined to `sources`. That predicate becomes a `scoped` CTE that both the vector side and the FTS side join against, replacing today's post-hoc filter and today's inlined rowid `IN`-lists. The vector side picks its strategy from the scope's measured row count: brute-force `vec_distance_cosine` inside a small scope, the vec0 KNN operator with a proportionally raised `k` for a large one.

**Tech Stack:** Emacs Lisp, SQLite 3.51 (FTS5, `json`-free), sqlite-vec `vec0` 0.1.6, `llm`/`llm-ollama`, ERT.

**Spec:** `docs/design/2026-08-29-design.md` — the **Retrieval**, **Interface** and **Refusal contract** sections. Phase 3 in its **Phasing** list is "scope filter, RRF fusion, reranker".

## Measured constraints

These were measured on 2026-08-30 against a copy of the live index (7,405 chunks: dotfiles 6,427 / vault 428 / hm options 200 / nix options 200 / builtin manuals 150). They are the reason this plan exists in its current shape; do not re-derive them, and do not design against different numbers without re-measuring.

| Measurement | Result |
|---|---|
| Global top-40 KNN for "how do I enable syncthing in home-manager" | 40/40 dotfiles, **0 vault, 0 options** |
| Global top-40 KNN for "what does services.openssh.settings.PermitRootLogin do" | 37 dotfiles, 2 nix options, 1 manual |
| Global top-40 KNN for "how is my backup strategy set up" | 36 dotfiles, 3 vault, 1 nix options |
| vec0 `k` ceiling | **4096** — `k = 7405` errors with `k value in knn query too large, provided 7405 and the limit is 4096` |
| KNN k=40 / k=200 / k=1000, unscoped | 13 ms / 13 ms / 24 ms |
| Vault-scoped hits at k=40 / 200 / 1000 | 0 / 2 / 7 |
| Brute-force `vec_distance_cosine` joined to the 428-row vault scope | 54 ms |
| Brute-force `vec_distance_cosine` across all 7,405 rows | **1.59 s** |
| SQLite version available to Emacs 30.2 on this host | 3.51.2 (`FULL OUTER JOIN` and `LIKE ... ESCAPE` both confirmed working) |

The load-bearing conclusion: **brute-force cost scales with scope size, not corpus size** (SQLite pushes the join filter, so `vec_distance_cosine` is only evaluated on rows in scope). That is what makes an adaptive strategy correct and cheap rather than a compromise.

## Global Constraints

- Emacs 29.2 floor. `Package-Requires` in `arc.el` is unchanged by this phase — add no new dependency.
- GPL-3.0-or-later. Files carrying `Copyright (C) 2024, 2025 Free Software Foundation, Inc.` keep that line and the Sergey Kostyaev author line; new files get `Copyright (C) 2026 Scott Whitson` and `SPDX-License-Identifier: GPL-3.0-or-later`.
- **Never** create `arc-mode.el`, never `(provide 'arc-mode)`, never define a function named `arc-mode`. `arc-mode` is a built-in Emacs library (archive support) and shadowing its feature symbol makes `(require 'arc-mode)` silently load the wrong thing.
- **No `Co-Authored-By` trailers in any commit**, ever.
- **eminix is out of scope.** No file outside the arc repo is created, modified or read for writing. Do not touch `~/dotfiles`, and do not check out or modify the `feature/arc` branch of the eminix repo.
- `~/dotfiles` and `~/docs/org` are live user data: **read-only**, and only when a test genuinely needs a real corpus (prefer fixtures).
- **Never modify, rebuild, or open read-write the live index at `~/.config/emacs/arc/arc.sqlite`.** Tests use `arc-test-with-temp-db`. If you need to measure against real data, copy the file to `/tmp` first and delete the copy afterwards.
- **Never** run work through the user's live Emacs daemon. `emacs -Q -batch` only.
- Every task ends with `./test/run.sh` green (exit 0). Suites skip cleanly without a vec0 extension; a skip is not a pass — set `ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so` so they actually run.
- Existing public signatures stay working. In particular `(arc-ask "prompt" '("vault"))` — a list of collection-name strings as the second argument — is documented in `README.org` and must keep working after this phase.

---

## File structure

**Created:**

| File | Responsibility |
|---|---|
| `arc-scope.el` | The scope plist, its SQL predicate, its row count, its human description, and the vector-strategy decision. Knows about SQL and the schema; knows nothing about answering or buffers. |
| `test/test-arc-scope.el` | Scope predicate construction, escaping, counting, strategy selection. |
| `test/test-arc-scoped-search.el` | End-to-end scoped retrieval against a temp db with real vectors. |

**Modified:**

| File | Change |
|---|---|
| `arc-db.el` | `tags` column on `sources`; column-presence migration; `arc-source-upsert` persists `:tags`; four defcustoms gain `:group`. |
| `arc.el` | `arc--find-similar` becomes scope-aware and drops its inlined rowid lists; `arc-ask` takes a scope; refusal short-circuit; `arc-ask-vault` / `arc-ask-options` / `arc-toggle-chat-model`; `arc-command-map` gains `n` `o` `m`. |
| `arc-answer.el` | `arc-answer-refusal`. |
| `arc-ui.el` | `arc-ui--last-scope`; `s` key; scope shown on the answer heading; `arc-transient` gains the new entries. |
| `test/run.sh` | Byte-compile gate. |
| `README.org` | The "what's built and what isn't" section, the key tables, the scope documentation. |

---

## Task 1: Byte-compile gate

The header-line defect in phase 4 was a missing `require` that six green suites did not notice, because `test/run.sh` never byte-compiles. This task closes that class before the rest of the phase adds code.

**Files:**
- Modify: `test/run.sh`
- Modify: `arc-db.el:13,19,26,39` (the four `defcustom` forms)

**Interfaces:**
- Consumes: nothing.
- Produces: `./test/run.sh` fails on any byte-compile warning. Later tasks depend on this staying green.

- [ ] **Step 1: See the current warnings**

```bash
cd ~/projects/arc
emacs -Q -batch -L . -f batch-byte-compile arc*.el 2>&1 | grep Warning
rm -f ./*.elc
```

Expected: exactly four warnings, all of one kind:

```
arc-db.el:13:12: Warning: in defcustom for ‘arc-embeddings-provider’: fails to specify containing group
arc-db.el:19:12: Warning: in defcustom for ‘arc-chat-provider’: fails to specify containing group
arc-db.el:26:12: Warning: in defcustom for ‘arc-db-directory’: fails to specify containing group
arc-db.el:39:12: Warning: in defcustom for ‘arc-sqlite-vec-path’: fails to specify containing group
```

If you see any warning **not** in that list, fix it in this task too — that is exactly what this gate is for. Do not suppress a warning to make the gate pass.

- [ ] **Step 2: Add `:group 'arc` to the four defcustoms**

`(defgroup arc ...)` lives in `arc.el:82`, which `arc-db.el` does not (and must not) require — `arc.el` requires `arc-db.el`, not the other way round. Naming the group in the `defcustom` is the correct fix; customize resolves the group lazily at runtime.

In `arc-db.el`, add `:group 'arc` as the last keyword of each of these four forms:

```elisp
(defcustom arc-embeddings-provider (progn (require 'llm-ollama)
					    (make-llm-ollama
					     :embedding-model "nomic-embed-text"))
  "Embeddings provider to generate embeddings."
  :type '(sexp :validate llm-standard-provider-p)
  :group 'arc)

(defcustom arc-chat-provider (progn (require 'llm-ollama)
				      (make-llm-ollama
				       :chat-model "qwen2.5-coder:3b"
				       :embedding-model "nomic-embed-text"))
  "Chat provider."
  :type '(sexp :validate llm-standard-provider-p)
  :group 'arc)

(defcustom arc-db-directory (file-truename
			       (file-name-concat
				user-emacs-directory "arc"))
  "Directory for arc database."
  :type 'directory
  :group 'arc)

(defcustom arc-sqlite-vec-path (getenv "ARC_VEC0_PATH")
  "Path to the sqlite-vec (vec0) loadable extension.
Defaults to the ARC_VEC0_PATH environment variable (set by Nix)."
  :type '(choice (const nil) file)
  :group 'arc)
```

- [ ] **Step 3: Verify the warnings are gone**

```bash
emacs -Q -batch -L . -f batch-byte-compile arc*.el 2>&1 | grep Warning; echo "warnings: $?"
rm -f ./*.elc
```

Expected: no output from `grep`, i.e. `warnings: 1` (grep found nothing).

- [ ] **Step 4: Add the gate to `test/run.sh`**

Insert this block immediately after the `ARC_VEC0_PATH` existence check and before `fail=0`... actually it needs `fail`, so insert it immediately after the line `fail=0`:

```bash
# Byte-compile gate. A missing `require' can leave every ERT suite green
# -- phase 4's header line shipped broken exactly that way, because
# nothing in the package required `arc-index' and six suites did not
# care. Warnings are errors here: this gate exists to catch the class,
# not to be negotiated with.
echo "== byte-compile"
bclog="$(mktemp)"
emacs -Q -batch -L . -f batch-byte-compile arc*.el >"$bclog" 2>&1
bcstatus=$?
rm -f ./*.elc
if grep -q 'Warning:' "$bclog" || [ "$bcstatus" -ne 0 ]; then
  cat "$bclog" >&2
  echo "byte-compile gate FAILED" >&2
  fail=1
fi
rm -f "$bclog"
```

- [ ] **Step 5: Run the full suite**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
```

Expected: `== byte-compile` appears first with no warning output, every suite runs, `exit=0`, and the summary line reports 208 tests across 19 suites.

- [ ] **Step 6: Prove the gate actually fails**

Temporarily break something, confirm the gate catches it, then revert:

```bash
printf '\n(defun arc-scratch-gate-probe () (undefined-function-xyz))\n' >> arc-db.el
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git checkout arc-db.el
```

Expected: `byte-compile gate FAILED` and `exit=1`. A gate never observed failing is not a gate. Re-apply Step 2's `:group` edits if `git checkout` reverted them — do Step 6 before Step 2's commit, or re-do Step 2.

- [ ] **Step 7: Commit**

```bash
git add test/run.sh arc-db.el
git commit -m "test: fail the suite on any byte-compile warning"
```

---

## Task 2: Persist source tags (schema v2)

`arc-source-org.el` already computes `:tags` for every node — `#+filetags` for a file node, `org-get-tags` for a heading node — and `arc-source-upsert` throws it away. Org-tag scoping is a spec requirement and this is the only thing standing between here and it.

**Files:**
- Modify: `arc-db.el` (`arc-sources-create-table-sql`, `arc-source-upsert`, `arc--source-row-to-plist`, `arc-db-schema-version`, `arc--init-db`)
- Test: `test/test-arc-db.el`, `test/test-arc-migration.el`

**Interfaces:**
- Consumes: `arc-source-upsert (PLIST)` and its existing `:kind :path :org-id :option-name :info-node :hash :mtime` keys.
- Produces:
  - `sources.tags` — org-style colon-delimited `TEXT`, e.g. `:emacs:nix:`, or `NULL` for a source with no tags. The leading and trailing colons are what make a substring match unambiguous.
  - `arc-source-tags-string (TAGS)` → string or nil. `("a" "b")` → `":a:b:"`, `nil` → `nil`, `()` → `nil`.
  - `arc--ensure-column (DB TABLE COLUMN DDL-TYPE)` → t when the column was added, nil when it was already present.
  - `arc-db-schema-version` is now `2`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test-arc-db.el`:

```elisp
(ert-deftest ed-tags-string-formats-org-style ()
  (should (equal (arc-source-tags-string '("emacs" "nix")) ":emacs:nix:"))
  (should (equal (arc-source-tags-string '("solo")) ":solo:"))
  (should (null (arc-source-tags-string nil)))
  (should (null (arc-source-tags-string '()))))

(ert-deftest ed-upsert-persists-tags ()
  (arc-test-with-temp-db
   (let ((sid (arc-source-upsert
               (list :kind "org-node" :org-id "abc-123" :path "/tmp/n.org"
                     :tags '("emacs" "nix")))))
     (should (equal (caar (sqlite-select
                           (arc-db)
                           (format "SELECT tags FROM sources WHERE id = %d;" sid)))
                    ":emacs:nix:")))))

(ert-deftest ed-upsert-tags-nil-stays-null ()
  (arc-test-with-temp-db
   (let ((sid (arc-source-upsert (list :kind "file" :path "/tmp/x.txt"))))
     (should (null (caar (sqlite-select
                          (arc-db)
                          (format "SELECT tags FROM sources WHERE id = %d;" sid))))))))

(ert-deftest ed-upsert-updates-tags-on-conflict ()
  "Re-indexing a node whose tags changed must not keep the old ones."
  (arc-test-with-temp-db
   (arc-source-upsert (list :kind "org-node" :org-id "abc-123" :tags '("old")))
   (let ((sid (arc-source-upsert (list :kind "org-node" :org-id "abc-123" :tags '("new")))))
     (should (equal (caar (sqlite-select
                           (arc-db)
                           (format "SELECT tags FROM sources WHERE id = %d;" sid)))
                    ":new:")))))

(ert-deftest ed-source-row-plist-carries-tags ()
  (arc-test-with-temp-db
   (arc-source-upsert (list :kind "org-node" :org-id "t-1" :tags '("a" "b")))
   (let* ((row (car (sqlite-select
                     (arc-db)
                     "SELECT id, kind, path, org_id, option_name, info_node, hash, mtime, tags
                      FROM sources WHERE org_id = 't-1';")))
          (pl (arc--source-row-to-plist row)))
     (should (equal (plist-get pl :tags) '("a" "b"))))))
```

Append to `test/test-arc-migration.el`:

```elisp
(ert-deftest am-adds-tags-column-to-a-v1-database ()
  "A database created before Task 2 must gain `tags' without losing rows."
  (arc-test-with-temp-db
   ;; Build a v1-shaped sources table by hand, then let arc open it.
   (let ((db (arc-db)))
     (sqlite-execute db "DROP TABLE IF EXISTS sources;")
     (sqlite-execute db "CREATE TABLE sources (
  id INTEGER PRIMARY KEY, kind TEXT NOT NULL, path TEXT, org_id TEXT,
  option_name TEXT, info_node TEXT, hash TEXT, mtime INTEGER, indexed_at INTEGER);")
     (sqlite-execute db "INSERT INTO sources (kind, path) VALUES ('file', '/tmp/pre-existing.txt');")
     (sqlite-execute db "PRAGMA user_version = 1;")
     (should-not (arc--column-exists-p db "sources" "tags"))
     (arc--migrate-db db)
     (should (arc--column-exists-p db "sources" "tags"))
     (should (= 1 (caar (sqlite-select db "SELECT count(*) FROM sources;"))))
     (should (= 2 (caar (sqlite-select db "PRAGMA user_version;")))))))

(ert-deftest am-migration-is-idempotent ()
  (arc-test-with-temp-db
   (let ((db (arc-db)))
     (arc--migrate-db db)
     (arc--migrate-db db)
     (should (arc--column-exists-p db "sources" "tags")))))
```

- [ ] **Step 2: Run them and watch them fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-db.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL — `arc-source-tags-string` is void, and `no such column: tags`.

- [ ] **Step 3: Implement**

In `arc-db.el`, bump the version constant:

```elisp
(defconst arc-db-schema-version 2
  "Current schema version.  Bump when adding a migration.
2 added `sources.tags' -- org tags, colon-delimited -- so a query can
be scoped to a tag without arc having to load org-roam's own database.")
```

Add `tags` to the fresh-database DDL, so a new database never needs the migration:

```elisp
(defun arc-sources-create-table-sql ()
  "Generate sql for creating the sources table."
  "CREATE TABLE IF NOT EXISTS sources (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  path TEXT,
  org_id TEXT,
  option_name TEXT,
  info_node TEXT,
  hash TEXT,
  mtime INTEGER,
  indexed_at INTEGER,
  tags TEXT
);")
```

Add the tag formatter and the migration helpers:

```elisp
(defun arc-source-tags-string (tags)
  "Render TAGS, a list of strings, as org's own colon-delimited form.
`(\"emacs\" \"nix\")' becomes \":emacs:nix:\".  The leading and trailing
colons matter: they are what let `:nix:' match as a substring without
also matching a tag merely ending in `nix'.  Returns nil for no tags,
so the column stays NULL rather than holding a meaningless \"::\"."
  (when tags (concat ":" (string-join tags ":") ":")))

(defun arc-source-tags-parse (string)
  "Inverse of `arc-source-tags-string'.  Return a list of tag strings."
  (and string (split-string string ":" t)))

(defun arc--column-exists-p (db table column)
  "Return non-nil when TABLE in DB has a column named COLUMN."
  (seq-some (lambda (row) (equal (nth 1 row) column))
            (sqlite-select db (format "PRAGMA table_info(%s);" table))))

(defun arc--ensure-column (db table column ddl-type)
  "Add COLUMN of DDL-TYPE to TABLE in DB unless it is already there.
Return non-nil when the column was added.  Checking the actual table
shape rather than trusting `user_version' makes this idempotent and
survivable: a database left half-migrated by an interrupted run is
repaired on the next open rather than skipped over because its version
number claims otherwise."
  (unless (arc--column-exists-p db table column)
    (sqlite-execute db (format "ALTER TABLE %s ADD COLUMN %s %s;" table column ddl-type))
    t))

(defun arc--migrate-db (db)
  "Bring DB's schema up to `arc-db-schema-version'.
Idempotent: safe to run on a fresh database, on a current one, and on
one interrupted midway through an earlier migration."
  (arc--ensure-column db "sources" "tags" "TEXT")
  (sqlite-execute db (format "PRAGMA user_version = %d;" arc-db-schema-version)))
```

Persist the tags in `arc-source-upsert` — add the column to the INSERT, the value to the VALUES, and, crucially, to the `DO UPDATE SET` clause so a retagged node does not keep its old tags:

```elisp
    (sqlite-execute
     (arc-db)
     (format "INSERT INTO sources (kind, path, org_id, option_name, info_node, hash, mtime, indexed_at, tags)
              VALUES (%s, %s, %s, %s, %s, %s, %s, %d, %s)
              ON CONFLICT (kind, COALESCE(path,''), COALESCE(org_id,''),
                           COALESCE(option_name,''), COALESCE(info_node,''))
              DO UPDATE SET hash = excluded.hash,
                            mtime = excluded.mtime,
                            indexed_at = excluded.indexed_at,
                            tags = excluded.tags;"
             (arc--sql-quote kind)
             (arc--sql-quote (plist-get plist :path))
             (arc--sql-quote (plist-get plist :org-id))
             (arc--sql-quote (plist-get plist :option-name))
             (arc--sql-quote (plist-get plist :info-node))
             (arc--sql-quote (plist-get plist :hash))
             (or (plist-get plist :mtime) "NULL")
             (truncate (float-time))
             (arc--sql-quote (arc-source-tags-string (plist-get plist :tags)))))
```

Extend the row-to-plist converter (it is fed a 9-column row now):

```elisp
(defun arc--source-row-to-plist (row)
  "Convert a sources ROW to a plist."
  (when row
    (list :id (nth 0 row) :kind (nth 1 row) :path (nth 2 row)
          :org-id (nth 3 row) :option-name (nth 4 row)
          :info-node (nth 5 row) :hash (nth 6 row) :mtime (nth 7 row)
          :tags (arc-source-tags-parse (nth 8 row)))))
```

Call the migration from `arc--init-db`, replacing its final unconditional `PRAGMA user_version` line:

```elisp
  (sqlite-execute db (arc-data-fts-create-table-sql))
  (arc--migrate-db db))
```

Add `(require 'seq)` near the top of `arc-db.el` if it is not already required — `arc--column-exists-p` uses `seq-some`.

- [ ] **Step 4: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-db.el -f ert-run-tests-batch-and-exit
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-migration.el -f ert-run-tests-batch-and-exit
```

Expected: both PASS.

- [ ] **Step 5: Mutation check**

Remove `tags = excluded.tags` from the `DO UPDATE SET` clause and re-run `test-arc-db.el`. `ed-upsert-updates-tags-on-conflict` **must** fail. If every test still passes, the test is not testing anything — fix the test, not the code. Restore the line.

- [ ] **Step 6: Full suite, then commit**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc-db.el test/test-arc-db.el test/test-arc-migration.el
git commit -m "feat(db): persist org tags on sources (schema v2)"
```

---

## Task 3: `arc-scope.el` — the scope object and its SQL

**Files:**
- Create: `arc-scope.el`
- Test: `test/test-arc-scope.el`

**Interfaces:**
- Consumes: `arc-sqlite-escape`, `arc-sqlite-format-string-list` (both `arc-db.el`), `arc-db`.
- Produces:
  - `arc-scope (&rest KEYS)` → a scope plist. Keys: `:collections` (list of names), `:kinds` (list from `arc-kind-list`), `:tags` (list of org tag strings), `:path-prefix` (a directory or path prefix string). A scope with no keys, and `nil`, both mean *everything*.
  - `arc-scope-empty-p (SCOPE)` → non-nil when SCOPE restricts nothing.
  - `arc-scope-predicate (SCOPE)` → a SQL boolean expression string over the aliases `d` (`data`) and `s` (`sources`); `"1"` for an empty scope.
  - `arc-scope-count (SCOPE)` → integer, the number of `data` rows in scope.
  - `arc-scope-total ()` → integer, the number of `data` rows in the whole corpus.
  - `arc-scope-describe (SCOPE)` → a human string for refusals and headings, e.g. `"vault"`, `"kinds nix-option, hm-option"`, `"everything"`.

- [ ] **Step 1: Write the failing tests**

Create `test/test-arc-scope.el`:

```elisp
;;; test-arc-scope.el --- scope construction and its SQL -*- lexical-binding: t; -*-
(require 'ert)
(defvar as-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path as-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest as-empty-scope-is-empty ()
  (should (arc-scope-empty-p nil))
  (should (arc-scope-empty-p (arc-scope)))
  (should (arc-scope-empty-p (arc-scope :collections nil :kinds nil)))
  (should-not (arc-scope-empty-p (arc-scope :collections '("vault")))))

(ert-deftest as-empty-scope-predicate-is-always-true ()
  (should (equal (arc-scope-predicate nil) "1"))
  (should (equal (arc-scope-predicate (arc-scope)) "1")))

(ert-deftest as-collection-predicate ()
  (should (equal (arc-scope-predicate (arc-scope :collections '("vault")))
                 "d.collection_id IN (SELECT id FROM collections WHERE name IN ('vault'))")))

(ert-deftest as-kind-predicate ()
  (should (equal (arc-scope-predicate (arc-scope :kinds '("nix-option" "hm-option")))
                 "s.kind IN ('nix-option', 'hm-option')")))

(ert-deftest as-tag-predicate-anchors-on-colons ()
  (should (equal (arc-scope-predicate (arc-scope :tags '("emacs")))
                 "(s.tags LIKE '%:emacs:%' ESCAPE '\\')")))

(ert-deftest as-tag-predicate-escapes-like-wildcards ()
  "Org tags may contain `_', which LIKE reads as a one-character wildcard."
  (should (equal (arc-scope-predicate (arc-scope :tags '("work_notes")))
                 "(s.tags LIKE '%:work\\_notes:%' ESCAPE '\\')")))

(ert-deftest as-path-prefix-predicate ()
  (should (equal (arc-scope-predicate (arc-scope :path-prefix "/home/u/docs"))
                 "s.path LIKE '/home/u/docs%' ESCAPE '\\'")))

(ert-deftest as-predicates-combine-with-and ()
  (should (equal (arc-scope-predicate (arc-scope :collections '("vault") :kinds '("org-node")))
                 "d.collection_id IN (SELECT id FROM collections WHERE name IN ('vault')) AND s.kind IN ('org-node')")))

(ert-deftest as-quotes-are-escaped ()
  (should (string-match-p "O''Brien" (arc-scope-predicate (arc-scope :collections '("O'Brien"))))))

(ert-deftest as-describe ()
  (should (equal (arc-scope-describe nil) "everything"))
  (should (equal (arc-scope-describe (arc-scope :collections '("vault"))) "vault"))
  (should (equal (arc-scope-describe (arc-scope :collections '("nix options" "hm options")))
                 "nix options, hm options"))
  (should (equal (arc-scope-describe (arc-scope :kinds '("org-node"))) "kinds org-node"))
  (should (equal (arc-scope-describe (arc-scope :tags '("emacs"))) "tags emacs"))
  (should (equal (arc-scope-describe (arc-scope :path-prefix "/x")) "under /x")))

(defun as--seed (db)
  "Seed DB with two collections of known size: vault 3 rows, dotfiles 5."
  (sqlite-execute db "INSERT INTO collections (name) VALUES ('vault'), ('dotfiles');")
  (let ((vault (caar (sqlite-select db "SELECT id FROM collections WHERE name='vault'")))
        (dots  (caar (sqlite-select db "SELECT id FROM collections WHERE name='dotfiles'"))))
    (dotimes (i 3)
      (let ((sid (arc-source-upsert (list :kind "org-node" :org-id (format "n%d" i)
                                          :path (format "/vault/n%d.org" i)
                                          :tags (if (= i 0) '("emacs") nil)))))
        (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'v%d');"
                                   sid vault i))))
    (dotimes (i 5)
      (let ((sid (arc-source-upsert (list :kind "file" :path (format "/dots/f%d.nix" i)))))
        (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'd%d');"
                                   sid dots i))))))

(ert-deftest as-count-and-total ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (should (= (arc-scope-total) 8))
   (should (= (arc-scope-count nil) 8))
   (should (= (arc-scope-count (arc-scope :collections '("vault"))) 3))
   (should (= (arc-scope-count (arc-scope :collections '("dotfiles"))) 5))
   (should (= (arc-scope-count (arc-scope :kinds '("org-node"))) 3))
   (should (= (arc-scope-count (arc-scope :tags '("emacs"))) 1))
   (should (= (arc-scope-count (arc-scope :path-prefix "/vault")) 3))
   (should (= (arc-scope-count (arc-scope :collections '("nope"))) 0))))
```

- [ ] **Step 2: Run and watch it fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-scope.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL, `arc-scope` is void.

- [ ] **Step 3: Implement `arc-scope.el`**

```elisp
;;; arc-scope.el --- what a query is allowed to look at -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A scope is a plist naming restrictions -- collections, kinds, org tags, a
;; path prefix -- that compiles to exactly one SQL predicate over `data'
;; joined to `sources'.  Retrieval puts that predicate in a `scoped' CTE and
;; joins both the vector side and the FTS side against it.
;;
;; The predicate is what makes scoping real rather than cosmetic.  Before
;; this file existed, a "scoped" query ran the vec0 KNN operator across the
;; whole corpus and filtered the survivors afterwards, so asking a
;; vault-scoped question whose nearest global neighbours were all dotfiles
;; returned no semantic candidates at all -- measured, on the live index:
;; "how do I enable syncthing in home-manager" put 40 of 40 global nearest
;; neighbours in dotfiles and none in the vault.  A scope has to reach the
;; search, not the results.
;;
;; Tags are stored the way org itself writes them, colon-delimited and
;; colon-anchored (":emacs:nix:"), so a tag match is a substring match that
;; cannot accidentally match a longer tag with the same ending.

;;; Code:

(require 'subr-x)
(require 'arc-db)

(defun arc-scope (&rest keys)
  "Return a scope plist built from KEYS.
Recognized keys: :collections, :kinds, :tags (each a list of strings)
and :path-prefix (a string).  A scope with none of them -- like nil
itself -- means the whole corpus."
  keys)

(defun arc-scope-empty-p (scope)
  "Return non-nil when SCOPE restricts nothing."
  (not (or (plist-get scope :collections)
           (plist-get scope :kinds)
           (plist-get scope :tags)
           (plist-get scope :path-prefix))))

(defun arc--scope-like-literal (string)
  "Return STRING as a LIKE pattern body with wildcards neutralised.
`%' and `_' are LIKE metacharacters and both occur in real data -- `_'
in org tags, both in paths -- so they are backslash-escaped and every
generated LIKE carries an explicit ESCAPE clause.  The backslash
itself is escaped first, or escaping the others would corrupt it."
  (let* ((s (arc-sqlite-escape string))
         (s (string-replace "\\" "\\\\" s))
         (s (string-replace "%" "\\%" s))
         (s (string-replace "_" "\\_" s)))
    s))

(defun arc-scope-predicate (scope)
  "Compile SCOPE to a SQL boolean expression.
The expression is written against the aliases `d' (`data') and `s'
(`sources'), which the caller must provide.  An empty scope compiles
to \"1\", so a caller never needs a special case for it."
  (let (parts)
    (when-let ((cols (plist-get scope :collections)))
      (push (format "d.collection_id IN (SELECT id FROM collections WHERE name IN %s)"
                    (arc-sqlite-format-string-list cols))
            parts))
    (when-let ((kinds (plist-get scope :kinds)))
      (push (format "s.kind IN %s" (arc-sqlite-format-string-list kinds)) parts))
    (when-let ((tags (plist-get scope :tags)))
      (push (format "(%s)"
                    (mapconcat (lambda (tag)
                                 (format "s.tags LIKE '%%:%s:%%' ESCAPE '\\'"
                                         (arc--scope-like-literal tag)))
                               tags " OR "))
            parts))
    (when-let ((prefix (plist-get scope :path-prefix)))
      (push (format "s.path LIKE '%s%%' ESCAPE '\\'" (arc--scope-like-literal prefix)) parts))
    (if parts (string-join (nreverse parts) " AND ") "1")))

(defun arc-scope-count (scope)
  "Return how many `data' rows SCOPE admits."
  (caar (sqlite-select
         (arc-db)
         (format "SELECT count(*) FROM data d JOIN sources s ON s.id = d.source_id WHERE %s;"
                 (arc-scope-predicate scope)))))

(defun arc-scope-total ()
  "Return how many `data' rows the corpus holds in total."
  (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;")))

(defun arc-scope-describe (scope)
  "Return a short human description of SCOPE, for refusals and headings."
  (if (arc-scope-empty-p scope)
      "everything"
    (string-join
     (delq nil
           (list (when-let ((c (plist-get scope :collections))) (string-join c ", "))
                 (when-let ((k (plist-get scope :kinds))) (concat "kinds " (string-join k ", ")))
                 (when-let ((tg (plist-get scope :tags))) (concat "tags " (string-join tg ", ")))
                 (when-let ((p (plist-get scope :path-prefix))) (concat "under " p))))
     "; ")))

(provide 'arc-scope)
;;; arc-scope.el ends here
```

- [ ] **Step 4: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-scope.el -f ert-run-tests-batch-and-exit
```

Expected: PASS, 11 tests.

- [ ] **Step 5: Mutation check**

Drop the `ESCAPE '\\'` clause from the tag branch and re-run. `as-tag-predicate-escapes-like-wildcards` must fail. Restore it.

- [ ] **Step 6: Full suite, then commit**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc-scope.el test/test-arc-scope.el
git commit -m "feat(scope): compile a scope plist to one SQL predicate"
```

---

## Task 4: Adaptive vector strategy

**Files:**
- Modify: `arc-scope.el`
- Test: `test/test-arc-scope.el`

**Interfaces:**
- Consumes: `arc-scope-count`, `arc-scope-total`, `arc-scope-empty-p` (Task 3).
- Produces:
  - `arc-vec0-k-ceiling` — the constant `4096`.
  - `arc-knn-candidates` — defcustom, default `40`.
  - `arc-scope-bruteforce-max` — defcustom, default `2000`.
  - `arc-scope-vector-plan (SCOPE)` → `(STRATEGY . K)`, where STRATEGY is `knn` or `brute` and K is the `k` to request (nil for `brute`).

- [ ] **Step 1: Write the failing tests**

Append to `test/test-arc-scope.el`:

```elisp
(ert-deftest as-plan-unscoped-uses-plain-knn ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (should (equal (arc-scope-vector-plan nil) (cons 'knn arc-knn-candidates)))))

(ert-deftest as-plan-small-scope-uses-brute-force ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   ;; 3 rows is far under `arc-scope-bruteforce-max'.
   (should (equal (arc-scope-vector-plan (arc-scope :collections '("vault")))
                  '(brute . nil)))))

(ert-deftest as-plan-large-scope-raises-k-proportionally ()
  "A scope too big to brute-force gets a k scaled by how much of the
corpus it excludes, so roughly `arc-knn-candidates' land in scope."
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (let ((arc-scope-bruteforce-max 1)      ; force the knn branch
         (arc-knn-candidates 40))
     ;; vault is 3 of 8 rows; 40 * 8/3 = 106.67 -> 107
     (should (equal (arc-scope-vector-plan (arc-scope :collections '("vault")))
                    '(knn . 107))))))

(ert-deftest as-plan-falls-back-to-brute-force-past-the-k-ceiling ()
  "vec0 refuses k > 4096.  Correctness of the scope wins over speed."
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (let ((arc-scope-bruteforce-max 1)
         (arc-knn-candidates 40000))       ; forces a k far past the ceiling
     (should (equal (arc-scope-vector-plan (arc-scope :collections '("vault")))
                    '(brute . nil))))))

(ert-deftest as-plan-empty-scope-does-not-divide-by-zero ()
  (arc-test-with-temp-db
   (as--seed (arc-db))
   (let ((arc-scope-bruteforce-max 0))
     (should (equal (arc-scope-vector-plan (arc-scope :collections '("nope")))
                    '(brute . nil))))))

(ert-deftest as-k-ceiling-matches-what-vec0-actually-enforces ()
  "Measured, not assumed: k = 4097 must be refused and k = 4096 accepted."
  (let ((db (sqlite-open)))
    (sqlite-load-extension db arc-sqlite-vec-path)
    (sqlite-execute db "CREATE VIRTUAL TABLE data_embeddings USING vec0(embedding float[3]);")
    (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (1, %s);"
                               (arc-vector-to-sqlite [1.0 0.0 0.0])))
    (let ((q (arc-vector-to-sqlite [1.0 0.0 0.0])))
      (should (sqlite-select db (format "SELECT rowid FROM data_embeddings WHERE embedding MATCH %s AND k = %d;"
                                        q arc-vec0-k-ceiling)))
      (should-error (sqlite-select db (format "SELECT rowid FROM data_embeddings WHERE embedding MATCH %s AND k = %d;"
                                              q (1+ arc-vec0-k-ceiling)))))))
```

- [ ] **Step 2: Run and watch it fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-scope.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL, `arc-scope-vector-plan` is void.

- [ ] **Step 3: Implement**

Append to `arc-scope.el`, before the `(provide 'arc-scope)` line:

```elisp
(defconst arc-vec0-k-ceiling 4096
  "The largest `k' sqlite-vec's KNN operator accepts.
Measured against sqlite-vec 0.1.6: `k = 4097' fails with \"k value in
knn query too large\".  This is why a sufficiently narrow scope cannot
simply raise `k' until enough in-scope rows appear, and why
`arc-scope-vector-plan' has a brute-force branch at all.")

(defcustom arc-knn-candidates 40
  "How many nearest neighbours retrieval wants to consider.
For an unscoped query this is `k' directly.  For a scoped one it is
the number of neighbours wanted *within the scope*, which is what
`arc-scope-vector-plan' scales `k' up to approximate."
  :type 'integer
  :group 'arc)

(defcustom arc-scope-bruteforce-max 2000
  "Largest scope, in chunks, searched by brute-force distance.
Brute force is exact -- it considers every row in scope and no row
outside it -- and its cost tracks the size of the scope rather than
the size of the corpus, because SQLite evaluates the distance function
only on the joined rows.  Measured on this corpus at roughly 0.2 ms per
row in scope: a 428-row scope took 54 ms, all 7,405 rows took 1.59 s.
2000 keeps the worst case near 400 ms."
  :type 'integer
  :group 'arc)

(defun arc-scope-vector-plan (scope)
  "Decide how to run vector search for SCOPE.
Return a cons (STRATEGY . K): either (knn . K), meaning run vec0's KNN
operator asking for K neighbours and keep the ones in scope, or
(brute . nil), meaning compute the distance directly over the scoped
rows.

An unscoped query always takes the KNN operator: there is nothing to
filter afterwards, so its result is already exact, and it is two
orders of magnitude faster than brute force across a whole corpus.

A scoped query has to get `arc-knn-candidates' rows *from inside the
scope*.  Brute force does that exactly, at a cost proportional to the
scope, so a scope up to `arc-scope-bruteforce-max' takes it.  A larger
scope asks the KNN operator for proportionally more neighbours --
enough that roughly `arc-knn-candidates' of them should land in scope
-- unless that number exceeds `arc-vec0-k-ceiling', in which case
there is no k that can work and brute force is the only correct
option, whatever it costs."
  (if (arc-scope-empty-p scope)
      (cons 'knn arc-knn-candidates)
    (let ((n (arc-scope-count scope)))
      (if (or (zerop n) (<= n arc-scope-bruteforce-max))
          (cons 'brute nil)
        (let* ((total (arc-scope-total))
               (k (ceiling (* arc-knn-candidates (/ (float total) n)))))
          (if (<= k arc-vec0-k-ceiling)
              (cons 'knn k)
            (cons 'brute nil)))))))
```

- [ ] **Step 4: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-scope.el -f ert-run-tests-batch-and-exit
```

Expected: PASS, 17 tests.

- [ ] **Step 5: Mutation check**

Change the ceiling comparison from `(<= k arc-vec0-k-ceiling)` to `t`. `as-plan-falls-back-to-brute-force-past-the-k-ceiling` must fail. Restore.

- [ ] **Step 6: Full suite, then commit**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc-scope.el test/test-arc-scope.el
git commit -m "feat(scope): pick the vector strategy from the scope's size"
```

---

## Task 5: Scoped hybrid search

The core of the phase. `arc--find-similar` stops filtering after the fact and stops inlining thousands of rowids into its own SQL text.

**Files:**
- Modify: `arc.el` (`arc--find-similar`, `arc-find-similar`)
- Test: `test/test-arc-scoped-search.el` (create)

**Interfaces:**
- Consumes: `arc-scope-predicate`, `arc-scope-vector-plan` (Tasks 3–4); `arc-vector-to-sqlite`, `arc-fts-query`, `arc-get-limit`.
- Produces:
  - `arc--find-similar (TEXT SCOPE)` → SQL string. **The second argument is now a scope plist, not a list of collection names.**
  - `arc-find-similar (TEXT SCOPE ON-DONE &optional ON-ERROR)` — same change.
  - `arc-scope-from-collections (COLLECTIONS)` → scope plist, for callers holding a plain name list.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-scoped-search.el`:

```elisp
;;; test-arc-scoped-search.el --- a scope must reach the search -*- lexical-binding: t; -*-
(require 'ert)
(defvar ass-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ass-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(defconst ass-dim 3)

(defun ass--seed ()
  "Seed a corpus where the global nearest neighbours are ALL out of scope.
This is the shape measured on the live index: a vault-scoped question
whose 40 nearest global neighbours were 40 dotfiles chunks.  20 near
`decoy' rows in `dotfiles' crowd out the 2 `vault' rows entirely at any
small k."
  (let ((db (arc-db)))
    (sqlite-execute db "INSERT INTO collections (name) VALUES ('vault'), ('dotfiles');")
    (let ((vault (caar (sqlite-select db "SELECT id FROM collections WHERE name='vault'")))
          (dots (caar (sqlite-select db "SELECT id FROM collections WHERE name='dotfiles'"))))
      ;; 20 dotfiles rows very close to the query vector [1 0 0]
      (dotimes (i 20)
        (let ((sid (arc-source-upsert (list :kind "file" :path (format "/dots/f%d.nix" i)))))
          (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'syncthing decoy %d');"
                                     sid dots i))
          (let ((rid (caar (sqlite-select db "SELECT last_insert_rowid();"))))
            (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%d, %s);"
                                       rid (arc-vector-to-sqlite
                                            (vector 1.0 (* 0.001 (1+ i)) 0.0))))
            (sqlite-execute db (format "INSERT INTO data_fts(rowid, data) VALUES (%d, 'syncthing decoy %d');"
                                       rid i)))))
      ;; 2 vault rows, further away but the only ones in scope
      (dotimes (i 2)
        (let ((sid (arc-source-upsert (list :kind "org-node" :org-id (format "v%d" i)
                                            :path (format "/vault/v%d.org" i)
                                            :tags '("infra")))))
          (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, %d, 'syncthing vault note %d');"
                                     sid vault i))
          (let ((rid (caar (sqlite-select db "SELECT last_insert_rowid();"))))
            (sqlite-execute db (format "INSERT INTO data_embeddings(rowid, embedding) VALUES (%d, %s);"
                                       rid (arc-vector-to-sqlite (vector 0.6 0.8 0.0))))
            (sqlite-execute db (format "INSERT INTO data_fts(rowid, data) VALUES (%d, 'syncthing vault note %d');"
                                       rid i))))))))

(defun ass--collections-of (ids)
  "Return the collection names the data rows IDS belong to."
  (when ids
    (mapcar #'car
            (sqlite-select
             (arc-db)
             (format "SELECT DISTINCT c.name FROM data d JOIN collections c ON c.id = d.collection_id
                      WHERE d.id IN %s;" (arc-sqlite-format-int-list ids))))))

(ert-deftest ass-vault-scope-returns-only-vault ()
  "The regression this phase exists for: at k=40 the global nearest
neighbours are all dotfiles, so a post-hoc filter returns nothing."
  (arc-test-with-temp-db
   (ass--seed)
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let* ((sql (arc--find-similar "syncthing" (arc-scope :collections '("vault"))))
            (ids (flatten-tree (sqlite-select (arc-db) sql))))
       (should ids)
       (should (equal (ass--collections-of ids) '("vault")))))))

(ert-deftest ass-unscoped-search-still-finds-the-nearest ()
  (arc-test-with-temp-db
   (ass--seed)
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let* ((sql (arc--find-similar "syncthing" nil))
            (ids (flatten-tree (sqlite-select (arc-db) sql))))
       (should ids)
       (should (member "dotfiles" (ass--collections-of ids)))))))

(ert-deftest ass-kind-scope-returns-only-that-kind ()
  (arc-test-with-temp-db
   (ass--seed)
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let* ((sql (arc--find-similar "syncthing" (arc-scope :kinds '("org-node"))))
            (ids (flatten-tree (sqlite-select (arc-db) sql))))
       (should ids)
       (should (equal (ass--collections-of ids) '("vault")))))))

(ert-deftest ass-tag-scope-returns-only-tagged ()
  (arc-test-with-temp-db
   (ass--seed)
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let* ((sql (arc--find-similar "syncthing" (arc-scope :tags '("infra"))))
            (ids (flatten-tree (sqlite-select (arc-db) sql))))
       (should ids)
       (should (equal (ass--collections-of ids) '("vault")))))))

(ert-deftest ass-knn-branch-also-respects-scope ()
  "Force the k-raising branch and confirm it filters just as exactly."
  (arc-test-with-temp-db
   (ass--seed)
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let* ((arc-scope-bruteforce-max 0)   ; never brute-force
            (sql (arc--find-similar "syncthing" (arc-scope :collections '("vault"))))
            (ids (flatten-tree (sqlite-select (arc-db) sql))))
       (should ids)
       (should (equal (ass--collections-of ids) '("vault")))))))

(ert-deftest ass-empty-scope-yields-no-rows-not-an-error ()
  (arc-test-with-temp-db
   (ass--seed)
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let* ((sql (arc--find-similar "syncthing" (arc-scope :collections '("nonesuch"))))
            (ids (flatten-tree (sqlite-select (arc-db) sql))))
       (should (null ids))))))

(ert-deftest ass-no-inlined-rowid-lists ()
  "The old query pasted every in-scope rowid into its own SQL text --
6,427 integers, twice, on the live index.  The scope is a join now."
  (arc-test-with-temp-db
   (ass--seed)
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let ((sql (arc--find-similar "syncthing" (arc-scope :collections '("vault")))))
       (should (string-match-p "scoped" sql))
       ;; Three consecutive integers in an IN-list is the shape of the old
       ;; inlined allowlist.  Match case-insensitively: the previous query
       ;; wrote `IN' upper-case, and a canary that cannot match the thing
       ;; it guards against is not a canary.
       (should-not (let ((case-fold-search t))
                     (string-match-p "in ([0-9]+, [0-9]+, [0-9]+" sql)))))))

(ert-deftest ass-scope-from-collections-round-trips ()
  (should (equal (arc-scope-from-collections '("vault"))
                 (arc-scope :collections '("vault"))))
  (should (arc-scope-empty-p (arc-scope-from-collections nil))))
```

- [ ] **Step 2: Run and watch it fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-scoped-search.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL — `ass-vault-scope-returns-only-vault` returns no ids at all under the current post-hoc filter, which is precisely the defect.

- [ ] **Step 3: Implement**

In `arc.el`, add `(require 'arc-scope)` alongside the existing requires, then replace `arc--find-similar` and `arc-find-similar` entirely:

```elisp
(defun arc-scope-from-collections (collections)
  "Return a scope restricting to COLLECTIONS, or an empty scope for nil.
Callers that hold a plain list of collection names -- `arc-ask' with
its documented list argument, `arc-enabled-collections' -- go through
here rather than building a plist inline."
  (if collections (arc-scope :collections collections) (arc-scope)))

(defun arc--scoped-cte (scope)
  "Return the `scoped' CTE restricting `data' rows to SCOPE."
  (format "scoped AS (
  SELECT d.id AS id
  FROM data d JOIN sources s ON s.id = d.source_id
  WHERE %s
)" (arc-scope-predicate scope)))

(defun arc--semantic-cte (scope vec)
  "Return the semantic-search CTE for SCOPE against embedding VEC.
Which of the two shapes this returns is `arc-scope-vector-plan's
decision; see its docstring for why either can be the correct one."
  (pcase-let ((`(,strategy . ,k) (arc-scope-vector-plan scope)))
    (if (eq strategy 'brute)
        ;; Exact within the scope, cost proportional to the scope: SQLite
        ;; only evaluates the distance on rows the join admits.
        (format "semantic_search AS (
  SELECT e.rowid AS id,
         RANK () OVER (ORDER BY vec_distance_cosine(e.embedding, %s) ASC) AS rank
  FROM data_embeddings e JOIN scoped ON scoped.id = e.rowid
  ORDER BY vec_distance_cosine(e.embedding, %s) ASC
  LIMIT %d
)" vec vec arc-knn-candidates)
      (format "vector_search AS (
  SELECT rowid AS id, distance
  FROM data_embeddings
  WHERE embedding MATCH %s AND k = %d
  ORDER BY distance ASC
),
semantic_search AS (
  SELECT v.id, RANK () OVER (ORDER BY v.distance ASC) AS rank
  FROM vector_search v JOIN scoped ON scoped.id = v.id
  ORDER BY v.distance ASC
  LIMIT %d
)" vec k arc-knn-candidates))))

(defun arc--find-similar (text scope)
  "Return the SQL selecting chunks in SCOPE similar to TEXT.
SCOPE is a scope plist (see `arc-scope'); nil means the whole corpus.
The scope reaches the search rather than filtering its results: both
the vector side and the FTS side join against the `scoped' CTE.  That
is the whole point of this function -- the previous version ran a
fixed k=40 KNN across the entire corpus and filtered afterwards, so a
narrow scope whose rows were not among the global top 40 came back
with no semantic candidates whatsoever."
  (let ((vec (arc-vector-to-sqlite
              (llm-embedding arc-embeddings-provider text))))
    (format "WITH
%s,
%s,
keyword_search AS (
  SELECT f.rowid AS id, RANK () OVER (ORDER BY bm25(data_fts) ASC) AS rank
  FROM data_fts f JOIN scoped ON scoped.id = f.rowid
  WHERE data_fts MATCH '%s'
  ORDER BY bm25(data_fts) ASC
  LIMIT %d
),
hybrid_search AS (
  SELECT
    COALESCE(semantic_search.id, keyword_search.id) AS id,
    COALESCE(1.0 / (60 + semantic_search.rank), 0.0) +
    COALESCE(1.0 / (60 + keyword_search.rank), 0.0) AS score
  FROM semantic_search
  FULL OUTER JOIN keyword_search ON semantic_search.id = keyword_search.id
  ORDER BY score DESC
  LIMIT %d
)
SELECT hybrid_search.id FROM hybrid_search;"
            (arc--scoped-cte scope)
            (arc--semantic-cte scope vec)
            (arc-fts-query text)
            arc-knn-candidates
            (arc-get-limit))))

(defun arc-find-similar (text scope on-done &optional on-error)
  "Find chunks in SCOPE similar to TEXT, asynchronously.
SCOPE is a scope plist; nil searches everything.  Evaluate ON-DONE
with the resulting SQL, or ON-ERROR with an error symbol and message
when retrieval itself fails -- most commonly an unreachable embedding
endpoint, since building the query embeds TEXT."
  (message "searching in collected data")
  (arc--async-do
   (lambda () (arc--find-similar text scope))
   on-done on-error))
```

Update the one existing caller in `arc-ask` for now, so the tree stays working — Task 6 revisits it:

```elisp
    (arc-find-similar
     question (arc-scope-from-collections cols)
```

- [ ] **Step 4: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-scoped-search.el -f ert-run-tests-batch-and-exit
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Mutation check**

Change the brute-force branch's `JOIN scoped ON scoped.id = e.rowid` to a plain `data_embeddings e` with no join. `ass-vault-scope-returns-only-vault` and `ass-kind-scope-returns-only-that-kind` must both fail. Restore.

- [ ] **Step 6: Full suite, then commit**

`test/test-arc-search.el` and any other suite calling `arc--find-similar` with a name list will now fail — a list is not a scope plist. Update those call sites to pass `(arc-scope :collections '(...))` or `nil`. Do not add a back-compatibility shim inside `arc--find-similar`: `arc-ask` is where the public list-argument contract is honoured (Task 6), and duplicating it here would leave two places to keep in step.

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc.el test/
git commit -m "feat(retrieval): search inside the scope instead of filtering after"
```

---

## Task 6: `arc-ask` takes a scope, and refuses honestly

**Files:**
- Modify: `arc.el` (`arc-ask`), `arc-answer.el`
- Test: `test/test-arc-answer.el`, `test/test-arc-retrieve.el`

**Interfaces:**
- Consumes: `arc-scope-from-collections`, `arc-scope-describe`, `arc-find-similar` (Tasks 3–5).
- Produces:
  - `arc-ask (QUESTION &optional SCOPE HEADING)` — SCOPE accepts a scope plist **or** a list of collection-name strings (the documented old form) **or** nil.
  - `arc-ask-normalize-scope (SCOPE)` → scope plist.
  - `arc-answer-refusal (SCOPE)` → the refusal string.
  - `arc-retrieval-max-distance` — defcustom, default `nil` (off).

- [ ] **Step 1: Write the failing tests**

Append to `test/test-arc-answer.el`:

```elisp
(ert-deftest ea-refusal-names-the-scope ()
  (should (equal (arc-answer-refusal (arc-scope :collections '("vault")))
                 "arc: not enough data — nothing in vault matched this question."))
  (should (equal (arc-answer-refusal nil)
                 "arc: not enough data — nothing in everything matched this question.")))
```

Append to `test/test-arc-retrieve.el`:

```elisp
(ert-deftest er-normalize-scope-accepts-a-name-list ()
  "README documents (arc-ask \"prompt\" '(\"vault\")).  That must keep working."
  (should (equal (arc-ask-normalize-scope '("vault"))
                 (arc-scope :collections '("vault"))))
  (should (equal (arc-ask-normalize-scope '("a" "b"))
                 (arc-scope :collections '("a" "b")))))

(ert-deftest er-normalize-scope-passes-a-plist-through ()
  (let ((s (arc-scope :kinds '("org-node"))))
    (should (equal (arc-ask-normalize-scope s) s))))

(ert-deftest er-normalize-scope-nil-uses-enabled-collections ()
  (let ((arc-enabled-collections '("builtin manuals")))
    (should (equal (arc-ask-normalize-scope nil)
                   (arc-scope :collections '("builtin manuals"))))))

(ert-deftest er-no-sources-refuses-without-calling-the-model ()
  "The single behaviour most worth protecting: a config oracle that
confabulates a NixOS option is worse than no oracle."
  (let ((model-called nil)
        (rendered ""))
    (cl-letf (((symbol-function 'arc-answer-request)
               (lambda (&rest _) (setq model-called t)))
              ((symbol-function 'arc-find-similar)
               (lambda (_text _scope on-done &optional _on-error) (funcall on-done "SELECT 1 WHERE 0")))
              ((symbol-function 'arc--retrieve-ids) (lambda (&rest _) nil))
              ((symbol-function 'arc--retrieve-rows) (lambda (&rest _) nil))
              ((symbol-function 'arc-ui-begin-answer) (lambda (_q) (cons 1 1)))
              ((symbol-function 'arc-ui-buffer) (lambda () (current-buffer)))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil))
              ((symbol-function 'arc-ui-stream-answer)
               (lambda (_a text) (setq rendered text))))
      (arc-ask "anything" (arc-scope :collections '("vault")))
      (should-not model-called)
      (should (string-match-p "not enough data" rendered))
      (should (string-match-p "vault" rendered)))))
```

- [ ] **Step 2: Run and watch them fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-retrieve.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL, `arc-ask-normalize-scope` is void.

- [ ] **Step 3: Implement the refusal**

In `arc-answer.el`, add before `(provide 'arc-answer)`:

```elisp
(declare-function arc-scope-describe "arc-scope" (scope))

(defun arc-answer-refusal (scope)
  "Return the answer arc gives when nothing in SCOPE matched.
The spec calls this the single behaviour most worth protecting: a
config oracle that confabulates a NixOS option is worse than no
oracle.  Naming the scope is the point -- \"not enough data\" alone
leaves the reader unable to tell an empty index from a scope that
simply did not hold the answer."
  (format "arc: not enough data — nothing in %s matched this question."
          (arc-scope-describe scope)))
```

Add `(require 'arc-scope)` to `arc-answer.el`'s requires.

- [ ] **Step 4: Implement the scope normalisation and short-circuit**

In `arc.el`, add the defcustom near the other retrieval defcustoms:

```elisp
(defcustom arc-retrieval-max-distance nil
  "Cosine distance past which a retrieved chunk is treated as no match.
nil disables the check, which is the default on purpose: the spec puts
the threshold's *value* behind phase 5's eval harness, because picking
one by intuition is how a retrieval layer quietly starts refusing
answers it had.  The mechanism lives here so phase 5 sets a number
rather than building a feature."
  :type '(choice (const nil) number)
  :group 'arc)
```

Add the normaliser:

```elisp
(defun arc-ask-normalize-scope (scope)
  "Return SCOPE as a scope plist.
Accepts three shapes, because `arc-ask' is public and its documented
second argument used to be a plain list of collection names:
  nil                     -- `arc-enabled-collections'
  (\"vault\" \"dotfiles\")    -- those collections
  (:collections (\"vault\")) -- a scope plist, used as-is
A list of strings is unambiguous here: a scope plist's first element
is always a keyword."
  (cond
   ((null scope) (arc-scope-from-collections arc-enabled-collections))
   ((keywordp (car scope)) scope)
   (t (arc-scope-from-collections scope))))
```

Rewrite `arc-ask`'s body (keeping its existing docstring and adding the two paragraphs below to it):

```elisp
(defun arc-ask (question &optional scope heading)
  "Ask arc QUESTION, grounded in SCOPE, rendering into the arc buffer.
...existing docstring text...

SCOPE is a scope plist (see `arc-scope'), a plain list of collection
names, or nil for `arc-enabled-collections'.  It is normalised by
`arc-ask-normalize-scope'.

When retrieval returns nothing at all, the model is never called: the
buffer gets `arc-answer-refusal' instead.  Handing an empty context
block to a chat model and hoping its prompt talks it out of answering
is exactly the failure the spec's refusal contract exists to prevent."
  (interactive "sAsk arc: ")
  (let* ((scope (arc-ask-normalize-scope scope))
         (display (or heading question)))
    (arc-find-similar
     question scope
     (lambda (query)
       (let* ((ids (arc--retrieve-ids query question))
              (sources (mapcar #'arc-row-to-source (arc--retrieve-rows ids)))
              (answer (arc-ui-begin-answer display)))
         (pop-to-buffer (arc-ui-buffer))
         (setq arc-ui--last-question display)
         (setq arc-ui--last-sources sources)
         (setq arc-ui--last-scope scope)
         (if (null sources)
             (arc-ui-stream-answer answer (arc-answer-refusal scope))
           (arc-answer-request
            question sources
            (lambda (text) (arc-ui-stream-answer answer text))
            (lambda (text)
              (arc-ui-stream-answer answer text)
              (arc-ui-render-sources answer sources))
            (lambda (_sym msg)
              (arc-ui-stream-answer answer (format "arc: request failed: %s" msg)))))))
     (lambda (_sym msg)
       (let ((answer (arc-ui-begin-answer display)))
         (pop-to-buffer (arc-ui-buffer))
         (setq arc-ui--last-question display)
         (setq arc-ui--last-sources nil)
         (setq arc-ui--last-scope scope)
         (arc-ui-stream-answer answer (format "arc: retrieval failed: %s" msg)))))))
```

`arc-ui--last-scope` is declared in Task 9; for now add `(defvar arc-ui--last-scope)` to `arc.el`'s existing block of `arc-ui--last-*` declarations so this task byte-compiles clean on its own.

- [ ] **Step 5: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-retrieve.el -f ert-run-tests-batch-and-exit
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-answer.el -f ert-run-tests-batch-and-exit
```

Expected: both PASS.

- [ ] **Step 6: Mutation check**

Delete the `(if (null sources) ...)` guard so `arc-answer-request` always runs. `er-no-sources-refuses-without-calling-the-model` must fail. Restore.

- [ ] **Step 7: Full suite, then commit**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc.el arc-answer.el test/
git commit -m "feat(ask): take a scope, and refuse rather than guess when it is empty"
```

---

## Task 7: Make the reranker path honest

`arc-reranker-enabled` has defaulted to nil since the fork, so this path has never run against a real service — and it already shipped one bug that nothing caught (`SELECT rowid, data` against a table whose column had been renamed to `chunk`). It stays off by default and unpackaged; this task makes it correct and covered, so enabling it later is a config change rather than a debugging session.

**Files:**
- Modify: `arc.el` (`arc-rerank`, `arc-reranker-similarity-threshold`)
- Test: `test/test-arc-rerank.el` (create)

**Interfaces:**
- Consumes: `arc--rerank-request`, `arc--do-rerank-request`, `arc-limit`.
- Produces: `arc-rerank (PROMPT IDS)` unchanged in signature; `arc-reranker-similarity-threshold` default becomes `nil`.

- [ ] **Step 1: Write the failing tests**

Create `test/test-arc-rerank.el`:

```elisp
;;; test-arc-rerank.el --- the reranker path, which has never run -*- lexical-binding: t; -*-
(require 'ert)
(defvar ar-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ar-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-test-helpers)

(ert-deftest ar-request-body-selects-the-chunk-column ()
  "`data' has had no `data' column since the schema rewrite.  The
reranker asked for one anyway, and nothing noticed for two phases
because the feature defaults to off."
  (arc-test-with-temp-db
   (let* ((db (arc-db))
          (sid (arc-source-upsert (list :kind "file" :path "/x.txt"))))
     (sqlite-execute db (format "INSERT INTO data (source_id, collection_id, chunk) VALUES (%d, NULL, 'hello world');" sid))
     (let* ((rid (caar (sqlite-select db "SELECT last_insert_rowid();")))
            (body (arc--rerank-request "q" (list rid))))
       (should (string-match-p "hello world" body))
       (should (string-match-p "\"query\":\"q\"" body))))))

(ert-deftest ar-threshold-nil-keeps-everything ()
  (let ((arc-reranker-similarity-threshold nil)
        (arc-limit 3))
    (cl-letf (((symbol-function 'arc--do-rerank-request)
               (lambda (_p _i) '(((id . 1) (similarity . 0.9))
                                 ((id . 2) (similarity . 0.1))
                                 ((id . 3) (similarity . -0.4))))))
      (should (equal (arc-rerank "q" '(1 2 3)) '(1 2 3))))))

(ert-deftest ar-threshold-drops-below-cutoff ()
  (let ((arc-reranker-similarity-threshold 0.5)
        (arc-limit 3))
    (cl-letf (((symbol-function 'arc--do-rerank-request)
               (lambda (_p _i) '(((id . 1) (similarity . 0.9))
                                 ((id . 2) (similarity . 0.1))))))
      (should (equal (arc-rerank "q" '(1 2)) '(1))))))

(ert-deftest ar-threshold-can-refuse-everything ()
  "A threshold that filters every candidate must yield nil, which
`arc-ask' then turns into a refusal -- not an empty context block."
  (let ((arc-reranker-similarity-threshold 0.99)
        (arc-limit 3))
    (cl-letf (((symbol-function 'arc--do-rerank-request)
               (lambda (_p _i) '(((id . 1) (similarity . 0.2))))))
      (should (null (arc-rerank "q" '(1)))))))

(ert-deftest ar-empty-ids-makes-no-request ()
  (let ((called nil))
    (cl-letf (((symbol-function 'plz) (lambda (&rest _) (setq called t) nil)))
      (should (null (arc--do-rerank-request "q" nil)))
      (should-not called))))
```

- [ ] **Step 2: Run and watch `ar-threshold-nil-keeps-everything` fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-rerank.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL. With the current default of `0`, `arc-reranker-similarity-threshold` is non-nil, so the filter runs and drops the `-0.4` row — a threshold of "0" reads as "off" but is not.

- [ ] **Step 3: Implement**

Change the defcustom in `arc.el`:

```elisp
(defcustom arc-reranker-similarity-threshold nil
  "Drop reranked chunks scoring below this similarity.
nil disables the check.  It used to default to 0, which reads like
\"off\" but is not: it silently dropped every negatively-scored chunk,
and `nil' is the value that actually means no filtering."
  :type '(choice (const nil) number)
  :group 'arc)
```

- [ ] **Step 4: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-rerank.el -f ert-run-tests-batch-and-exit
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Full suite, then commit**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc.el test/test-arc-rerank.el
git commit -m "fix(rerank): a 0 threshold is not 'off'; cover the path that never ran"
```

---

## Task 8: Scoped entry points and the model toggle

Delivers the three global keys elisa has that arc does not: `n` (vault), `o` (options), `m` (model).

**Files:**
- Modify: `arc.el` (`arc-command-map`, new commands, new defcustoms)
- Test: `test/test-arc-entrypoints.el` (create)

**Interfaces:**
- Consumes: `arc-ask`, `arc-scope`, `arc-chat-provider`.
- Produces:
  - `arc-vault-collections` — defcustom, default `'("vault")`.
  - `arc-option-collections` — defcustom, default `'("nix options" "hm options")`.
  - `arc-chat-models` — defcustom, default `'("qwen2.5-coder:3b" "qwen2.5:7b")`.
  - `arc-ask-vault (QUESTION)`, `arc-ask-options (QUESTION)`, `arc-toggle-chat-model ()` — all interactive.
  - `arc-command-map` gains `n`, `o`, `m`.

- [ ] **Step 1: Write the failing tests**

Create `test/test-arc-entrypoints.el`:

```elisp
;;; test-arc-entrypoints.el --- the scoped entry points -*- lexical-binding: t; -*-
(require 'ert)
(defvar ae-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ae-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)

(ert-deftest ae-command-map-has-every-entry-point ()
  (should (eq (keymap-lookup arc-command-map "i") #'arc-ask))
  (should (eq (keymap-lookup arc-command-map "n") #'arc-ask-vault))
  (should (eq (keymap-lookup arc-command-map "o") #'arc-ask-options))
  (should (eq (keymap-lookup arc-command-map "m") #'arc-toggle-chat-model))
  (should (eq (keymap-lookup arc-command-map "R") #'arc-reindex-all))
  (should (eq (keymap-lookup arc-command-map "c") #'arc-reindex-cancel)))

(ert-deftest ae-every-entry-point-is-interactive ()
  (dolist (cmd '(arc-ask arc-ask-vault arc-ask-options arc-toggle-chat-model
                 arc-reindex-all arc-reindex-cancel))
    (should (commandp cmd))))

(ert-deftest ae-ask-vault-scopes-to-the-vault ()
  (let (got)
    (cl-letf (((symbol-function 'arc-ask) (lambda (_q &optional s &rest _) (setq got s))))
      (arc-ask-vault "q")
      (should (equal got (arc-scope :collections arc-vault-collections))))))

(ert-deftest ae-ask-options-scopes-to-both-option-collections ()
  (let (got)
    (cl-letf (((symbol-function 'arc-ask) (lambda (_q &optional s &rest _) (setq got s))))
      (arc-ask-options "q")
      (should (equal got (arc-scope :collections arc-option-collections)))
      (should (member "nix options" (plist-get got :collections)))
      (should (member "hm options" (plist-get got :collections))))))

(ert-deftest ae-toggle-cycles-through-the-model-list ()
  (let* ((arc-chat-models '("a" "b" "c"))
         (arc-chat-provider (make-llm-ollama :chat-model "a" :embedding-model "e")))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "b"))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "c"))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "a"))))

(ert-deftest ae-toggle-from-an-unlisted-model-starts-at-the-first ()
  (let* ((arc-chat-models '("a" "b"))
         (arc-chat-provider (make-llm-ollama :chat-model "zzz" :embedding-model "e")))
    (arc-toggle-chat-model)
    (should (equal (llm-ollama-chat-model arc-chat-provider) "a"))))

(ert-deftest ae-toggle-refuses-a-non-ollama-provider ()
  (let ((arc-chat-provider "not a provider"))
    (should-error (arc-toggle-chat-model) :type 'user-error)))
```

- [ ] **Step 2: Run and watch it fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-entrypoints.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL, `arc-ask-vault` is void.

- [ ] **Step 3: Implement**

In `arc.el`, near `arc-enabled-collections`:

```elisp
(defcustom arc-vault-collections '("vault")
  "Collections `arc-ask-vault' searches."
  :type '(repeat string)
  :group 'arc)

(defcustom arc-option-collections '("nix options" "hm options")
  "Collections `arc-ask-options' searches."
  :type '(repeat string)
  :group 'arc)

(defcustom arc-chat-models '("qwen2.5-coder:3b" "qwen2.5:7b")
  "Chat models `arc-toggle-chat-model' cycles through, in order.
The 3B model answers fast enough to keep a question conversational;
the 7B one is the practical ceiling on 14 GiB with no swap."
  :type '(repeat string)
  :group 'arc)
```

Then the commands, next to `arc-ask`:

```elisp
;;;###autoload
(defun arc-ask-vault (question)
  "Ask arc QUESTION against the org-roam vault only."
  (interactive "sAsk arc (vault): ")
  (arc-ask question (arc-scope :collections arc-vault-collections)))

;;;###autoload
(defun arc-ask-options (question)
  "Ask arc QUESTION against the NixOS and Home-Manager options only."
  (interactive "sAsk arc (options): ")
  (arc-ask question (arc-scope :collections arc-option-collections)))

;;;###autoload
(defun arc-toggle-chat-model ()
  "Switch `arc-chat-provider' to the next model in `arc-chat-models'.
A model not in the list -- or an `arc-chat-provider' the user has set
to something other than an Ollama provider -- is not silently worked
around: the first case starts the cycle over, the second is a
`user-error' naming the variable, because rebuilding an arbitrary
provider is not this command's business."
  (interactive)
  (unless (cl-typep arc-chat-provider 'llm-ollama)
    (user-error "arc: `arc-chat-provider' is not an Ollama provider; \
`arc-toggle-chat-model' cannot switch its model"))
  (let* ((current (llm-ollama-chat-model arc-chat-provider))
         (rest (cdr (member current arc-chat-models)))
         (next (or (car rest) (car arc-chat-models))))
    (setf (llm-ollama-chat-model arc-chat-provider) next)
    (message "arc: chat model is now %s" next)
    next))
```

Add `(require 'cl-lib)` to `arc.el` if not already present (`cl-typep`).

Extend the keymap:

```elisp
;;;###autoload
(defvar arc-command-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "i") #'arc-ask)
    (define-key m (kbd "n") #'arc-ask-vault)
    (define-key m (kbd "o") #'arc-ask-options)
    (define-key m (kbd "m") #'arc-toggle-chat-model)
    (define-key m (kbd "R") #'arc-reindex-all)
    (define-key m (kbd "c") #'arc-reindex-cancel)
    m)
  "Prefix map for arc's entry points; bind it where you like.
arc is a library and does not claim a global key for you -- bind this
map to whatever prefix you like, e.g.:

  (keymap-set global-map \"C-c i\" arc-command-map)")
```

- [ ] **Step 4: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-entrypoints.el -f ert-run-tests-batch-and-exit
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Mutation check**

Change `arc-ask-options` to pass `arc-vault-collections`. `ae-ask-options-scopes-to-both-option-collections` must fail. Restore.

- [ ] **Step 6: Full suite, then commit**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc.el test/test-arc-entrypoints.el
git commit -m "feat(ui): vault, options and model-toggle entry points"
```

---

## Task 9: The in-buffer `s` key

**Files:**
- Modify: `arc-ui.el`
- Test: `test/test-arc-ui.el`

**Interfaces:**
- Consumes: `arc-ask`, `arc-scope`, `arc-scope-describe`, `arc-ui--last-question`.
- Produces:
  - `arc-ui--last-scope` — buffer-local, the scope the last answer was retrieved at.
  - `arc-scope-presets` — defcustom, an alist of `(NAME . SCOPE-PLIST)`.
  - `arc-ui-change-scope ()` — bound to `s` in `arc-answer-mode-map`.
  - `arc-transient` gains `n`, `o`, `m`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test-arc-ui.el`:

```elisp
(ert-deftest eu-s-is-bound-to-change-scope ()
  (should (eq (keymap-lookup arc-answer-mode-map "s") #'arc-ui-change-scope)))

(ert-deftest eu-change-scope-requires-a-previous-question ()
  (with-temp-buffer
    (arc-answer-mode)
    (setq arc-ui--last-question nil)
    (should-error (arc-ui-change-scope) :type 'user-error)))

(ert-deftest eu-change-scope-reasks-the-last-question-at-the-new-scope ()
  (let (asked-question asked-scope)
    (with-temp-buffer
      (arc-answer-mode)
      (setq arc-ui--last-question "how do I enable syncthing")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "vault"))
                ((symbol-function 'arc-ask)
                 (lambda (q &optional s &rest _)
                   (setq asked-question q asked-scope s))))
        (arc-ui-change-scope)))
    (should (equal asked-question "how do I enable syncthing"))
    (should (equal asked-scope (alist-get "vault" arc-scope-presets nil nil #'equal)))))

(ert-deftest eu-presets-cover-the-documented-scopes ()
  (dolist (name '("everything" "vault" "options" "dotfiles"))
    (should (assoc name arc-scope-presets))))

(ert-deftest eu-everything-preset-is-an-empty-scope ()
  (should (arc-scope-empty-p (alist-get "everything" arc-scope-presets nil nil #'equal))))
```

- [ ] **Step 2: Run and watch it fail**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-ui.el -f ert-run-tests-batch-and-exit
```

Expected: FAIL, `arc-ui-change-scope` is void.

- [ ] **Step 3: Implement**

In `arc-ui.el`, add `(require 'arc-scope)`, then:

```elisp
(defcustom arc-scope-presets
  '(("everything" . nil)
    ("vault"      . (:collections ("vault")))
    ("options"    . (:collections ("nix options" "hm options")))
    ("dotfiles"   . (:collections ("dotfiles"))))
  "Named scopes offered by `arc-ui-change-scope'.
Each entry is (NAME . SCOPE-PLIST); a nil plist means the whole
corpus.  These are the scopes a reader can reach from inside an
answer; `arc-ask' itself accepts any scope plist."
  :type '(alist :key-type string :value-type sexp)
  :group 'arc)

(defvar-local arc-ui--last-scope nil
  "The scope the most recent answer in this buffer was retrieved at.
Set by `arc-ask' as it renders, alongside `arc-ui--last-question'.
`arc-ui-change-scope' reads it only to offer a sensible default; the
scope it asks at is whatever the reader picks.")

(defun arc-ui-change-scope ()
  "Re-ask this buffer's last question at a different scope.
Deliberately re-asks `arc-ui--last-question' rather than the answer at
point: changing scope is a question about the same question, and
pairing one answer's text with a different scope's retrieval is the
confusion `f' and `r' already had to be kept apart to avoid."
  (interactive)
  (unless arc-ui--last-question
    (user-error "arc: no question asked in this buffer yet"))
  (let* ((name (completing-read
                (format "Re-ask %S at scope: "
                        (truncate-string-to-width arc-ui--last-question 40 nil nil t))
                (mapcar #'car arc-scope-presets) nil t))
         (scope (alist-get name arc-scope-presets nil nil #'equal)))
    (arc-ask arc-ui--last-question scope)))
```

Bind it:

```elisp
    (define-key m (kbd "s")   #'arc-ui-change-scope)
```

Remove the `(defvar arc-ui--last-scope)` forward declaration Task 6 added to `arc.el` — the real `defvar-local` now exists and `arc.el` requires `arc-ui` transitively. Verify with the byte-compile gate rather than by eye.

Add the three new entries to `arc-transient`, matching the keys in `arc-command-map`: `n` "ask the vault", `o` "ask the options", `m` "toggle chat model".

- [ ] **Step 4: Run the tests**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so \
  emacs -Q -batch -L . -L test -l test/test-arc-ui.el -f ert-run-tests-batch-and-exit
```

Expected: PASS.

- [ ] **Step 5: Full suite, then commit**

```bash
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add arc-ui.el test/test-arc-ui.el
git commit -m "feat(ui): change scope and re-ask from inside the answer buffer"
```

---

## Task 10: Documentation

**Files:**
- Modify: `README.org`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Update "What's built and what isn't"**

The section currently opens "This is a phase 1--4 project" and contains this clause, which is now false in both halves:

> There is no way to scope a single query to a subset of collections from a prompt (short of the Lisp-level ~COLLECTIONS~ argument below), no hooks that reindex a source automatically when it changes on disk, and no automated evaluation harness -- those are designed (see ~docs/design/~) but not built.

Rewrite it as a phase 1--4 **and 5-pending** project: scoping is built; the freshness hooks and the eval harness are what remain. Keep the existing sentence recording that the header line reports size and not freshness -- that is still true, and phase 5 is what changes it.

- [ ] **Step 2: Document scoping**

Add a "Scoping a question" subsection under Usage covering: the four scope dimensions; `arc-scope`; that `(arc-ask "prompt" '("vault"))` still works; `arc-vault-collections` / `arc-option-collections` / `arc-scope-presets`; and that a scope with no matching chunks produces an explicit refusal rather than an answer.

- [ ] **Step 3: Update both key tables**

Global map: `i` `n` `o` `m` `R` `c`. In-buffer map: add `s`. Delete the paragraph explaining that `s`, `n` and `o` are deliberately unbound.

- [ ] **Step 4: Document the strategy and its knobs**

A short subsection under Usage, aimed at someone tuning it: `arc-knn-candidates`, `arc-scope-bruteforce-max`, the measured 4096 `k` ceiling, and the one-line reason the two strategies exist (KNN filters after the fact, so a narrow scope needs an exact search inside it). Include the measured cost figures — 54 ms for a 428-row scope, 1.59 s for all 7,405 — so the default is a number someone can argue with rather than a magic constant.

- [ ] **Step 5: Note the reindex needed for tag scoping**

`sources.tags` is populated at index time. An index built before this phase has the column and no values in it, so `:tags` scoping silently matches nothing until the collection is reindexed. Say that, and say which reindex fixes it.

- [ ] **Step 6: Verify and commit**

```bash
emacs -Q -batch --eval '(progn (require (quote org)) (find-file "README.org") (org-lint))' 2>&1 | head -20
ARC_VEC0_PATH=/nix/store/77440dch8lnph95xaj5fs634iwvgvmja-sqlite-vec-0.1.6/lib/vec0.so ./test/run.sh; echo "exit=$?"
git add README.org
git commit -m "docs: scoped retrieval, the refusal contract, and the new keys"
```

---

## Notes for the executor

**Do not reindex the live corpus.** Tag scoping needs a vault reindex to become useful, but that is the owner's call to make on their own machine, after this branch is reviewed. Say so in the final report; do not run it.

**The `s`/`n`/`o` keys were deliberately unbound in phase 4** because they could not work. If you find yourself binding one before its scope actually reaches the search, stop — that is the failure this phase exists to correct.

**Deferred on purpose, not forgotten:** vec0 partition keys would make a collection-scoped KNN both exact and fast, and would not need the brute-force branch at all. They are not in this plan because they only help low-cardinality equality scopes — collection and kind — and would leave tag and path-prefix scopes on the adaptive path anyway, i.e. two mechanisms where one does. Revisit if the corpus grows enough that `arc-scope-bruteforce-max` starts costing real time.
