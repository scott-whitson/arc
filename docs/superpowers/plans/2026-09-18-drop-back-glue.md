# arc drops the back glue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete arc's prose-answer path entirely — the chat provider, the prompt assembly, the streaming answer buffer — leaving a retrieval engine that returns ranked chunks to whatever agent drives it.

**Architecture:** Two scope functions move down into `arc-scope.el` first, because four surviving callers depend on them and they currently live in the file being gutted. Then the answer layer is deleted leaf-first: UI, then prompt assembly, then the commands, then the provider itself. Nothing in retrieval changes.

**Tech Stack:** Emacs Lisp (29.2 floor), SQLite via `sqlite-select`, `sqlite-vec` `vec0`, FTS5, ERT.

**Spec:** `docs/superpowers/specs/2026-09-17-needle-and-home-corpus-design.md`, section "Back glue: deleted".

## Global Constraints

- **Emacs 29.2 minimum.** Do not use Emacs 30+ only APIs (notably the `sort` keyword calling convention — use `(sort LIST PREDICATE)`).
- **The byte-compile gate treats warnings as errors.** `test/run.sh` runs `emacs -Q -batch -L . -f batch-byte-compile arc*.el` and fails on any line matching `Warning:`. A deletion plan makes this gate unusually sharp: removing a function leaves every stale caller as a `Warning: reference to free variable` or an undefined-function warning. Treat a new warning as a missed call site, not as noise.
- **This machine runs Emacs 31.1; CI runs 29.2–29.4.** `when-let`/`if-let` are obsolete in 31, producing 22 pre-existing warning lines in files this plan mostly deletes or does not touch. `test/run.sh` exits 1 for that reason alone. Judge by the warning SET against the task's base commit, never by the exit code — and expect the set to SHRINK as files are deleted, which is correct.
- **No hardcoded home paths anywhere**, in code or docs. Derive from `(getenv "HOME")`. This repo is public.
- **No private content in the repo.** No vault text, no real note paths, no real query strings.
- **No `Co-Authored-By` or AI-attribution trailers** in any commit message.
- **Tests must not require Ollama.** After this plan nothing in arc can reach a chat model at all, which is the point.
- **Deprecate, do not silently break.** This package is public. A public function that moves gets a `define-obsolete-function-alias`; a public command that is deleted outright is named in the README's changes section. The prior branch broke `arc-indexable-file-p`'s arity with no note; do not repeat that.
- Branch is `feat/drop-back-glue`, cut from `feat/home-corpus`. Commit after every task.
- Run the full suite with `test/run.sh`; run one suite with `emacs -Q -batch -L . -l test/<file>.el -f ert-run-tests-batch-and-exit`.

## What survives, and must still work at every step

`arc-tool.el` and `bin/arc` (the agent-facing entry points), `arc-search.el` and `arc-search-ui.el` (the consult/minibuffer surface), `arc-eval.el`, `arc-index.el`, `arc-rollup.el`, `arc-watch.el`, and every source and chunker. If a task breaks one of these, the task is wrong, not the survivor.

---

### Task 1: Move the scope entry points down into `arc-scope.el`

`arc-ask-normalize-scope` (`arc.el:858`) and `arc-enabled-collections` (`arc.el:242`) are scope concepts stranded in the file this plan guts. Four surviving callers use the function — `arc-search.el:199`, `arc-search-ui.el:121` and `:397`, `arc-eval.el:168`, `arc-tool.el:46` — so it must move before anything is deleted, not after.

`arc-scope.el` is already required by `arc.el` (`arc.el:62`), so this moves down the dependency graph rather than creating a cycle. The function's whole body is `arc-enabled-collections` plus `arc-scope-from-collections`, which already lives in `arc-scope.el`; moving the defcustom with it avoids a forward declaration.

The name goes too. `arc-ask-normalize-scope` is named for `arc-ask`, a command that ceases to exist in Task 3.

**Files:**
- Modify: `arc-scope.el` (add both definitions before the `(provide 'arc-scope)` line)
- Modify: `arc.el` (delete `arc-enabled-collections` at 242 and `arc-ask-normalize-scope` at 858)
- Modify: `arc-search.el:199`, `arc-search-ui.el:121`, `arc-search-ui.el:397`, `arc-eval.el:168`, `arc-tool.el:46`
- Test: `test/test-arc-scope.el` (extend), `test/test-arc-retrieve.el:80-91` (retarget existing assertions)

**Interfaces:**
- Consumes: `arc-scope-from-collections` (`arc-scope.el:211`), unchanged.
- Produces: `(arc-scope-normalize SCOPE)` in `arc-scope.el`, accepting the same three shapes and returning the same scope plist as `arc-ask-normalize-scope` did. `arc-ask-normalize-scope` survives only as a `define-obsolete-function-alias`. `arc-enabled-collections` keeps its name, its value and its `:group`; only its file changes.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-scope.el`:

```elisp
;;; --- the scope entry points now live here ---------------------------------
;;
;; `arc-ask-normalize-scope' was defined in arc.el and named for `arc-ask', a
;; command that no longer exists.  Four survivors call it -- arc-search,
;; arc-search-ui, arc-eval and arc-tool -- so it moved down here rather than
;; dying with the answer path.  `arc-enabled-collections' came with it: the
;; function's only other dependency, and a scope concept in its own right.

(ert-deftest as-normalize-accepts-all-three-shapes ()
  "nil, a bare list of names, and a scope plist."
  (let ((arc-enabled-collections '("vault")))
    (should (equal (arc-scope-normalize nil)
                   (arc-scope :collections '("vault")))))
  (should (equal (arc-scope-normalize '("vault" "home"))
                 (arc-scope :collections '("vault" "home"))))
  (let ((plist (arc-scope :collections '("home"))))
    (should (equal (arc-scope-normalize plist) plist))))

(ert-deftest as-normalize-is-reachable-without-loading-arc ()
  "arc-scope.el must not need arc.el for this; arc.el requires IT."
  (should (fboundp 'arc-scope-normalize))
  (should (boundp 'arc-enabled-collections)))

(ert-deftest as-old-normalize-name-is-obsolete-not-gone ()
  "This package is public; a moved function keeps a deprecation path."
  (should (fboundp 'arc-ask-normalize-scope))
  (should (get 'arc-ask-normalize-scope 'byte-obsolete-info)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-scope.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `arc-scope-normalize` is void, and `arc-enabled-collections` is unbound when only `arc-scope` is loaded.

- [ ] **Step 3: Write minimal implementation**

In `arc-scope.el`, immediately before `(provide 'arc-scope)`, add:

```elisp
(defcustom arc-enabled-collections '("builtin manuals")
  "Collections searched when a caller names no scope of its own.
Moved here from `arc.el' with `arc-scope-normalize', which is its only
consumer: a collection set IS a scope, and keeping the two in separate
files meant `arc-scope.el' could not answer the simplest scope question
without a forward declaration.

A name here that is not in `arc-index-plan' yields a scope matching
nothing, silently -- see `arc-scope-presets' for the same trap."
  :type '(repeat string) :group 'arc)

(defun arc-scope-normalize (scope)
  "Return SCOPE as a scope plist.
Accepts three shapes, because the public entry points that call this
documented their scope argument as a plain list of collection names
before scope plists existed:
  nil                     -- `arc-enabled-collections'
  (\"vault\" \"home\")        -- those collections
  (:collections (\"vault\")) -- a scope plist, used as-is
A list of strings is unambiguous here: a scope plist's first element
is always a keyword."
  (cond
   ((null scope) (arc-scope-from-collections arc-enabled-collections))
   ((keywordp (car scope)) scope)
   (t (arc-scope-from-collections scope))))

(define-obsolete-function-alias 'arc-ask-normalize-scope
  #'arc-scope-normalize "2026-09-18"
  "Renamed: it was named for `arc-ask', which no longer exists.")
```

Delete `arc-enabled-collections` from `arc.el:242` and `arc-ask-normalize-scope` from `arc.el:858`.

Replace the call in each of the five surviving sites with `arc-scope-normalize`:
`arc-search.el:199`, `arc-search-ui.el:121`, `arc-search-ui.el:397`, `arc-eval.el:168`, `arc-tool.el:46`.

`arc-search-ui.el`, `arc-eval.el` and `arc-tool.el` must each `(require 'arc-scope)` if they do not already — check before adding, and do not add a duplicate.

In `test/test-arc-retrieve.el:80-91`, retarget the four existing assertions from `arc-ask-normalize-scope` to `arc-scope-normalize`. Do not delete them; they test behaviour that still exists.

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-scope.el -f ert-run-tests-batch-and-exit`
Expected: PASS.

Run: `test/run.sh`
Expected: every suite 0 unexpected. The byte-compile warning set must contain no new undefined-function or free-variable warning — if it does, a call site was missed.

- [ ] **Step 5: Commit**

```bash
git add arc-scope.el arc.el arc-search.el arc-search-ui.el arc-eval.el arc-tool.el test/test-arc-scope.el test/test-arc-retrieve.el
git commit -m "refactor(scope): move the scope entry points out of arc.el

arc-ask-normalize-scope was named for a command that is about to stop
existing, and lived in the file being gutted, while four survivors call
it. It and arc-enabled-collections -- its only dependency, and a scope
concept in its own right -- move down into arc-scope.el, which arc.el
already requires. The old name stays as an obsolete alias."
```

---

### Task 2: Delete the answer buffer

`arc-ui.el` (350 lines) is entirely the prose-answer surface: `arc-answer-mode`, its keymap, the streaming render, citation following, re-ask and follow-up. `arc-search-ui.el` is a separate file and survives untouched — do not confuse them.

Three suites `require 'arc-ui` for reasons unrelated to answers: `test/test-arc-stats-cache.el:72,81` and `test/test-arc-freshness.el:128,142,150`. Those requires exist because the header line rendered index freshness. That behaviour has no home after this, so the assertions about it go with the file; the rest of each suite stays.

**Files:**
- Delete: `arc-ui.el`, `test/test-arc-ui.el`
- Modify: `arc.el:87` (drop `(require 'arc-ui)`)
- Modify: `test/test-arc-stats-cache.el`, `test/test-arc-freshness.el`
- Test: `test/test-arc-no-back-glue.el` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. This task only removes.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-no-back-glue.el`. It grows across Tasks 2, 3 and 4; this is its first form:

```elisp
;;; test-arc-no-back-glue.el --- arc answers nothing, it retrieves -*- lexical-binding: t; -*-
;;
;; arc used to assemble a prompt, stream a reply and render it in its own
;; buffer.  That layer is gone: arc returns ranked chunks through `arc-tool.el'
;; and `bin/arc', and whatever agent drives it writes the prose.  A single-shot
;; tool-calling model cannot take ten retrieved chunks and write a paragraph,
;; so there is nothing to replace it WITH -- which is the point, not a gap.
;;
;; This suite pins the absence.  Deletions rot back in through a stray require
;; or a docstring example far more easily than features rot out.
(require 'ert)
(defvar anb-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path anb-root)
(require 'arc)

(ert-deftest anb-the-answer-buffer-is-gone ()
  "arc-ui.el owned every part of the prose-answer surface."
  (should-not (featurep 'arc-ui))
  (should-not (file-exists-p (expand-file-name "arc-ui.el" anb-root)))
  (dolist (symbol '(arc-answer-mode arc-answer-mode-map arc-ui-buffer
                    arc-ui-begin-answer arc-ui-stream-answer
                    arc-ui-render-sources arc-ui-follow-citation
                    arc-ui-reask arc-ui-follow-up arc-ui-change-scope))
    (should-not (fboundp symbol))
    (should-not (boundp symbol))))

(ert-deftest anb-the-search-surface-survives ()
  "arc-search-ui.el is a different file and is NOT part of this deletion.
`arc-search' itself is deliberately nested inside `(when (require
'consult nil t) ...)' (arc-search-ui.el:376), so it does NOT exist on a
machine without consult -- assert the file and its unconditional entry
point, never `arc-search' itself."
  (should (file-exists-p (expand-file-name "arc-search-ui.el" anb-root)))
  (should (fboundp 'arc-search-show)))

(provide 'test-arc-no-back-glue)
;;; test-arc-no-back-glue.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `arc-ui.el` exists and `arc.el` requires it.

- [ ] **Step 3: Write minimal implementation**

```bash
git rm arc-ui.el test/test-arc-ui.el
```

Delete `(require 'arc-ui)` from `arc.el:87`.

In `test/test-arc-stats-cache.el` and `test/test-arc-freshness.el`, delete each `(require 'arc-ui)` and every test whose subject is the answer buffer's header line. Keep every test whose subject is the stats cache or index freshness itself — those behaviours survive in `arc-index.el`. Read each test before deleting it; if a test exercises freshness through the header line but is really about freshness, rewrite it to call the freshness function directly rather than deleting the coverage.

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: PASS.

Run: `test/run.sh`
Expected: 0 unexpected across every suite. Report how many tests the suite lost and confirm each loss was an answer-buffer test, not collateral.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(ui): delete the answer buffer

arc-ui.el was the prose-answer surface entire: the mode, the streaming
render, citation following, re-ask, follow-up. arc returns ranked chunks
now and the agent driving it writes the prose. arc-search-ui.el is a
different file and is untouched."
```

---

### Task 3: Delete the prompt assembly and the ask commands

`arc-answer.el` (54 lines) builds the prompt and streams the reply. `arc.el` holds the three commands that drive it — `arc-ask` (`arc.el:873`), `arc-ask-vault` (`933`) and `arc-ask-options` (`948`) — plus `arc-chat-prompt-template` (`185`), the prompt text itself.

**Files:**
- Delete: `arc-answer.el`, `test/test-arc-answer.el`
- Modify: `arc.el` (drop `(require 'arc-answer)` at 88, `arc-chat-prompt-template` at 185, and the three commands at 873/933/948)
- Modify: `test/test-arc-retrieve.el` (remove `arc-ask` tests; keep retrieval tests)
- Modify: `test/test-arc-entrypoints.el` (remove `arc-ask*` entry-point assertions)
- Test: `test/test-arc-no-back-glue.el` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. This task only removes.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-no-back-glue.el`:

```elisp
(ert-deftest anb-the-prompt-layer-is-gone ()
  "arc-answer.el assembled the prompt and streamed the reply."
  (should-not (featurep 'arc-answer))
  (should-not (file-exists-p (expand-file-name "arc-answer.el" anb-root)))
  (dolist (symbol '(arc-answer-context-block arc-answer-build-prompt
                    arc-answer-request arc-chat-prompt-template))
    (should-not (fboundp symbol))
    (should-not (boundp symbol))))

(ert-deftest anb-the-ask-commands-are-gone ()
  "Nothing in arc takes a question and returns prose."
  (dolist (symbol '(arc-ask arc-ask-vault arc-ask-options))
    (should-not (fboundp symbol))
    (should-not (commandp symbol))))

(ert-deftest anb-retrieval-still-answers-to-its-callers ()
  "The whole point of the deletion: retrieval is untouched."
  (should (fboundp 'arc--find-similar))
  (should (fboundp 'arc-scope-normalize))
  (should (fboundp 'arc-tool-search)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: FAIL on the two new tests; the Task 2 tests still pass.

- [ ] **Step 3: Write minimal implementation**

```bash
git rm arc-answer.el test/test-arc-answer.el
```

From `arc.el` delete: `(require 'arc-answer)` at line 88, the `arc-chat-prompt-template` defcustom at 185, and `arc-ask`, `arc-ask-vault` and `arc-ask-options` with their `;;;###autoload` cookies.

In `test/test-arc-retrieve.el`, delete every test whose subject is `arc-ask`'s rendering or its error handling. Keep every test of `arc--find-similar`, scope normalization and retrieval ordering.

In `test/test-arc-entrypoints.el`, delete the assertions that `arc-ask`, `arc-ask-vault` and `arc-ask-options` are autoloaded commands. Leave the surviving entry-point assertions alone.

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: PASS.

Run: `test/run.sh`
Expected: 0 unexpected. Confirm no new undefined-function warning — a surviving caller of a deleted command shows up here and nowhere else.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(answer): delete the prompt assembly and the ask commands

arc-answer.el built a prompt and streamed a reply; arc-ask, arc-ask-vault
and arc-ask-options drove it. All four are gone along with the prompt
template. Retrieval is untouched -- arc-tool.el and bin/arc still return
ranked chunks, and the caller writes the prose."
```

---

### Task 4: Delete the chat provider and the chat-model reranker

With the answer path gone, two things remain that can only speak to a chat model: `arc-chat-provider` (`arc-db.el:29`), its model list `arc-chat-models` (`arc.el:260`) and the model-toggling command around it (`arc-toggle-chat-model`, `arc.el:959`); and `arc-rerank-llm.el` (140 lines), whose subtitle is "rerank with the chat model already installed."

`arc-rerank-llm.el` goes. It calls `llm-chat` on `arc-chat-provider` (`arc-rerank-llm.el:121`), and after this there is no chat model installed to rerank with. It was never in the default path — `arc-reranker-enabled` defaults to nil (`arc.el:204`) and the file's own header says *"`arc-reranker-function' is left nil. Do not wire this in as a default."*

**`arc-reranker-function` itself stays**, along with `arc-reranker-enabled`, `arc-reranker-url`, `arc-reranker-limit` and `arc-reranker-similarity-threshold`. The hook is provider-agnostic; only the one implementation that needed a local chat model is being removed. A later plan can hand it Needle.

**Files:**
- Delete: `arc-rerank-llm.el`
- Modify: `arc-db.el` (drop `arc-chat-provider` at 29)
- Modify: `arc.el` (drop `arc-chat-models` at 260 and `arc-toggle-chat-model` at 959)
- Modify: `test/test-arc-entrypoints.el:54-69` (the chat-provider tests)
- Modify: `test/test-arc-rerank.el` (remove the LLM reranker's tests; keep the hook's)
- Test: `test/test-arc-no-back-glue.el` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. After this task no symbol in arc references a chat model.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-no-back-glue.el`:

```elisp
(ert-deftest anb-nothing-can-reach-a-chat-model ()
  "The provider, its model list, and the command that cycled them."
  (dolist (symbol '(arc-chat-provider arc-chat-models))
    (should-not (boundp symbol)))
  (should-not (fboundp 'arc-toggle-chat-model)))

(ert-deftest anb-the-chat-model-reranker-is-gone ()
  "It existed to rerank with the chat model already installed.
There is no chat model installed."
  (should-not (featurep 'arc-rerank-llm))
  (should-not (file-exists-p (expand-file-name "arc-rerank-llm.el" anb-root)))
  (should-not (fboundp 'arc-rerank-llm)))

(ert-deftest anb-the-reranker-hook-survives ()
  "Provider-agnostic, and the door a later plan walks through."
  (dolist (symbol '(arc-reranker-function arc-reranker-enabled
                    arc-reranker-limit))
    (should (boundp symbol)))
  (should-not arc-reranker-function))

(ert-deftest anb-no-source-file-mentions-a-chat-provider ()
  "A deletion rots back in through a docstring long before it does
through code."
  (let ((offenders '()))
    (dolist (file (directory-files anb-root t "\\`arc.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (re-search-forward "arc-chat-provider\\|arc-chat-models" nil t)
          (push (file-relative-name file anb-root) offenders))))
    (should (equal offenders '()))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: FAIL on the four new tests.

- [ ] **Step 3: Write minimal implementation**

```bash
git rm arc-rerank-llm.el
```

Delete `arc-chat-provider` from `arc-db.el:29`. Check whether `(require 'llm-ollama)` at `arc-db.el:21` is still needed — `arc-embeddings-provider` also calls `make-llm-ollama`, so it almost certainly is. Leave it if so; the byte-compile gate will say otherwise.

Delete `arc-chat-models` from `arc.el:260` and `arc-toggle-chat-model` (with its `;;;###autoload` cookie) from `arc.el:959`.

In `test/test-arc-entrypoints.el:54-69`, delete the four `arc-chat-provider` tests outright — they test a symbol that no longer exists.

In `test/test-arc-rerank.el`, delete the tests of `arc-rerank-llm` specifically. Keep every test of `arc-reranker-function` dispatch, `arc-reranker-enabled` gating and the HTTP reranker path — those survive.

`test/test-arc-rerank.el` holds 6 tests; count how many survive and report it. If none do, delete the file.

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: PASS, all suite tests.

Run: `test/run.sh`
Expected: 0 unexpected. The byte-compile warning set should now be SMALLER than at this branch's base — deleted files cannot warn. Report the set, not the count.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(db): delete the chat provider and the chat-model reranker

Nothing in arc speaks to a chat model any more. arc-rerank-llm.el goes
with the provider it called: its subtitle was 'rerank with the chat model
already installed', it was never wired in by default, and there is no
chat model installed now. arc-reranker-function survives -- the hook is
provider-agnostic and a later plan hands it a real reranker."
```

---

### Task 5: Say what arc is now

`arc.el:1` still calls arc a "Local config-aware oracle". It is not an oracle any more; it is a retrieval engine that an oracle calls. The README's structure follows the old shape too, and the prior branch's final review found six stale references that a code sweep missed because they lived in prose.

**Files:**
- Modify: `arc.el:1` (the package header line) and the Commentary block at `arc.el:40-46`
- Modify: `README.org` (the sections describing asking, answering and the chat model)
- Test: `test/test-arc-no-back-glue.el` (extend with a prose guard)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-no-back-glue.el`:

```elisp
(ert-deftest anb-no-live-doc-promises-an-answer ()
  "The prior branch shipped a README whose only bin/arc example errored,
because a code sweep cannot see prose.  This guard can.
Historical records under docs/design/ are exempt; they are dated."
  (let ((offenders '())
        (dead '("arc-ask" "arc-chat-provider" "arc-chat-models"
                "arc-answer-mode" "arc-rerank-llm")))
    (dolist (file (append (directory-files anb-root t "\\`arc.*\\.el\\'")
                          (list (expand-file-name "README.org" anb-root))))
      (with-temp-buffer
        (insert-file-contents file)
        (dolist (needle dead)
          (goto-char (point-min))
          (when (search-forward needle nil t)
            (push (format "%s: %s" (file-relative-name file anb-root) needle)
                  offenders)))))
    (should (equal offenders '()))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: FAIL, listing every surviving prose reference in `README.org` and any `arc*.el` docstring.

- [ ] **Step 3: Write minimal implementation**

Change `arc.el:1` to:

```elisp
;;; arc.el --- Local config-aware retrieval for emanix -*- lexical-binding: t -*-
```

Rewrite the Commentary block at `arc.el:40-46` to describe what arc does now: index a corpus, retrieve ranked chunks over a hybrid of vector and keyword search, and hand them to a caller — `arc-search` in Emacs, `arc-tool.el` or `bin/arc` outside it. Say plainly that arc does not generate prose and name why: a retrieval engine and a language model are different jobs, and arc is the first one.

In `README.org`, rewrite every section that describes asking a question and reading an answer. Delete the chat-model setup instructions. Add a short section recording what this change removed and what replaced it, naming `arc-ask`, `arc-ask-vault`, `arc-ask-options` and `arc-toggle-chat-model` as removed commands and `arc-ask-normalize-scope` as renamed to `arc-scope-normalize` — the Global Constraints require this, and the prior branch's silent arity break is why.

Read each README section before rewriting it. Some describe retrieval through an answer-flavoured framing and need rewording, not deletion.

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q -batch -L . -l test/test-arc-no-back-glue.el -f ert-run-tests-batch-and-exit`
Expected: PASS.

Verify the README still parses:
Run: `emacs -Q -batch -l org --eval '(with-temp-buffer (insert-file-contents "README.org") (org-mode) (org-element-parse-buffer) (message "README parses"))'`
Expected: prints `README parses`.

Run: `test/run.sh`
Expected: 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add arc.el README.org test/test-arc-no-back-glue.el
git commit -m "docs: arc retrieves, it does not answer

The header line still called arc an oracle and the README still taught
people to set a chat model. Both describe a program that no longer
exists. Records the removed commands and the one rename, which the last
branch neglected to do for arc-indexable-file-p."
```

---

### Task 6: Prove the survivors still work end to end

Every prior task asserted an absence. This one asserts the thing that matters: that arc still retrieves, from Emacs and from outside it, with no chat model anywhere in the process.

**Files:**
- Test: `test/test-arc-retrieval-standalone.el` (create)

**Interfaces:**
- Consumes: `arc-tool-search` (`arc-tool.el`), `arc-search` (`arc-search-ui.el`), `arc-scope-normalize` (`arc-scope.el`), `arc-eval-run` (`arc-eval.el`).
- Produces: nothing.

- [ ] **Step 1: Write the test**

Create `test/test-arc-retrieval-standalone.el`:

```elisp
;;; test-arc-retrieval-standalone.el --- arc retrieves with no model -*- lexical-binding: t; -*-
;;
;; The deletion suite proves the answer path is absent.  This one proves the
;; remaining program is whole: that a caller can load arc, scope a query,
;; retrieve ranked chunks and get them back as JSON, without any chat model
;; existing in the image.  If arc had quietly depended on the answer layer for
;; something structural, this is where it shows.
(require 'ert)
(defvar ars-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ars-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-tool)

(ert-deftest ars-arc-loads-without-a-chat-model ()
  "Loading the package must not require, reference or construct one."
  (should (featurep 'arc))
  (should-not (boundp 'arc-chat-provider))
  (should (boundp 'arc-embeddings-provider)))

(ert-deftest ars-the-keyword-arm-retrieves-with-no-model-at-all ()
  "The `keyword' arm skips embedding entirely, so this needs no Ollama."
  (arc-test-with-temp-db
   (let ((scope (arc-scope-normalize '("vault"))))
     (should (listp (arc--find-similar "anything" scope 'keyword))))))

(ert-deftest ars-the-tool-surface-answers-a-caller ()
  "arc-tool.el is how an outside agent reaches retrieval now.
`arc-search' is guarded behind consult and must not be asserted here;
`arc-search-show' is the unconditional entry point."
  (should (fboundp 'arc-tool-search))
  (should (fboundp 'arc-tool-scopes))
  (should (fboundp 'arc-search-show)))

(provide 'test-arc-retrieval-standalone)
;;; test-arc-retrieval-standalone.el ends here
```

- [ ] **Step 2: Run it**

Run: `emacs -Q -batch -L . -l test/test-arc-retrieval-standalone.el -f ert-run-tests-batch-and-exit`
Expected: PASS, or a clean SKIP if no vec0 extension is present.

- [ ] **Step 3: Exercise the CLI for real**

The suite cannot cover `bin/arc`, which reaches a running Emacs daemon through `emacsclient`. Run it by hand against the operator's daemon:

```bash
bin/arc search "disk layout" --scope home --json | head -20
```

Expected: valid JSON with ranked documents, no error mentioning a chat model or a missing function. Record the output shape in the report — not its content, which comes from a private corpus.

- [ ] **Step 4: Confirm the whole suite**

Run: `test/run.sh`
Expected: 0 unexpected across every suite. Report the byte-compile warning set and confirm it is a subset of the set at this branch's base — five files were deleted, so warnings can only have been removed.

- [ ] **Step 5: Commit**

```bash
git add test/test-arc-retrieval-standalone.el
git commit -m "test: arc retrieves with no chat model in the image

Every other suite in this branch asserts an absence. This one asserts
the program that is left is whole: load, scope, retrieve, and reach the
tool surface, with no chat provider bound anywhere."
```

---

## What this plan does not do

- **No Needle.** The sidecar, the embedding bake-off and the front glue are the next two plans. This plan removes; it adds no model.
- **No change to retrieval.** `arc--find-similar`, the hybrid fusion, the scoring and the rollup are untouched. If a task changes a retrieval result, the task is wrong.
- **No reindex.** Nothing here touches the database or the corpus.
- **`arc-reranker-function` survives unimplemented.** The hook stays; only the chat-model implementation behind it goes. Wiring Needle into it belongs to the front-glue plan.
