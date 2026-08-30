# arc Phase 4 — Answer UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ellama's generic chat buffer with `arc-answer-mode` — an org-derived answer buffer whose citations are real org links you can jump to, driven by a transient.

**Architecture:** arc owns its answer surface end to end. Retrieval starts returning the line numbers and titles already sitting in the schema; a new `arc-answer.el` assembles the prompt and streams the reply through `llm-chat-streaming`; `arc-ui.el` renders the question, the streamed answer and a `*** Sources` subtree of org links into `*arc*`. Because arc no longer borrows ellama's buffer or its context functions, the `ellama` dependency is removed.

**Tech Stack:** Emacs Lisp (ERT), `org-mode` (major-mode parent and link engine), `llm` / `llm-ollama` (streaming), `transient` (command menu), sqlite + sqlite-vec.

**Spec:** `docs/design/2026-08-29-design.md` — see its **Interface** section.

## Global Constraints

- **Emacs 29.2 minimum.** Do not raise `Package-Requires` without evidence.
- **GPL-3.0-or-later.** New files carry `Copyright (C) 2026 Scott Whitson` and an SPDX line. Any file carrying code moved out of `arc.el` also keeps upstream's FSF copyright line and the Sergey Kostyaev author line, plus a `;;; Changes:` note. `arc.el`'s own header stays untouched.
- **Every symbol is prefixed `arc-`.**
- **NEVER create a file named `arc-mode.el`, and NEVER write `(provide 'arc-mode)`.** `arc-mode` is a **built-in Emacs library** (archive support); shadowing its feature symbol makes `(require 'arc-mode)` load the wrong library silently. The major mode here is **`arc-answer-mode`**, defined in **`arc-ui.el`**.
- **Never hardcode a home directory.** Derive from `$HOME`.
- **Do not modify the live index** at `~/.config/emacs/arc/arc.sqlite`. Use throwaway databases. `~/dotfiles` and `~/docs/org` are live user data — read only.
- **Test command:** `ARC_VEC0_PATH=<vec0.so> ./test/run.sh` from the repo root. Baseline entering this plan: **16 suites, 164 tests, exit 0.** It must not drop.
- **Never background a job or write a polling loop.** Bounded foreground `timeout` runs; `emacs -Q -batch` only, never the user's live Emacs daemon. Leave nothing running.
- **Commits:** conventional-commit subject. **No `Co-Authored-By` trailer.** Not negotiable.

## Out of scope — phase 5 owns these

Corpus **freshness** tracking (`after-save-hook`, the idle sweep, `flake.lock` watching) and the **eval harness**. Task 5's header line reports corpus *size*, not staleness; staleness is wired in phase 5.

Also deferred, because they need scoped retrieval that does not exist yet: the
spec's in-buffer **`s`** key (change scope and re-ask) and the global **`n`** /
**`o`** entry points (vault only, options only). Phase 3 builds the scope filter;
binding those keys before it exists would mean shipping keys that cannot work.
Everything else in the spec's Interface section is covered here.

## File Structure

| File | Responsibility |
|---|---|
| `arc.el` (modify) | Retrieval returns citable records; the ellama answer path is removed. |
| `arc-answer.el` (new) | Prompt assembly and streaming via `llm`. Knows nothing about buffers. |
| `arc-ui.el` (new) | `arc-answer-mode`, rendering, keymap, transient, header line. |
| `test/test-arc-retrieve-source.el`, `test/test-arc-answer.el`, `test/test-arc-ui.el` (new) | ERT suites. |

---

### Task 1: Retrieval returns citable source records

**Files:**
- Modify: `arc.el` (`arc--retrieve-rows`)
- Test: `test/test-arc-retrieve-source.el`

**Interfaces:**
- Consumes: `arc-source-link`, `arc-source-label` from `arc-source.el`.
- Produces: `(arc-row-to-source ROW)` → plist `(:kind :path :info-node :org-id :option-name :title :line-start :line-end :chunk)`. Every later task consumes this shape.

`arc--retrieve-rows` currently selects six columns and drops `line_start`, `line_end` and `title` — the values that make a citation jumpable, already in the schema.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-retrieve-source.el`:

```elisp
;;; test-arc-retrieve-source.el --- rows convert to citable sources -*- lexical-binding: t; -*-
(require 'ert)
(defvar ars-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ars-root)
(require 'arc-source)
(require 'arc)

(ert-deftest ars-row-to-source-file ()
  (let ((s (arc-row-to-source '("file" "/tmp/x.nix" nil nil nil "body" 12 20 nil))))
    (should (equal (plist-get s :kind) "file"))
    (should (equal (plist-get s :path) "/tmp/x.nix"))
    (should (= (plist-get s :line-start) 12))
    (should (equal (plist-get s :chunk) "body"))))

(ert-deftest ars-row-renders-a-file-link-at-its-line ()
  (let ((s (arc-row-to-source '("file" "/tmp/x.nix" nil nil nil "body" 12 20 nil))))
    (should (equal (arc-source-link s (plist-get s :line-start))
                   "[[file:/tmp/x.nix::12]]"))))

(ert-deftest ars-row-org-node-keeps-title ()
  (let ((s (arc-row-to-source '("org-node" nil nil "abc123" nil "body" 1 1 "My Note"))))
    (should (equal (plist-get s :title) "My Note"))
    (should (equal (arc-source-link s) "[[id:abc123][My Note]]"))))

(ert-deftest ars-row-nix-option ()
  (let ((s (arc-row-to-source '("nix-option" "nixos/modules/x.nix" nil nil
                                "services.foo.enable" "body" 1 1 nil))))
    (should (equal (arc-source-link s) "[[nixopt:services.foo.enable]]"))))

(ert-deftest ars-retrieve-rows-selects-the-citation-columns ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "arc.el" ars-root))
    (dolist (col '("d.line_start" "d.line_end" "d.title"))
      (goto-char (point-min))
      (should (search-forward col nil t)))))
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-retrieve-source.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function arc-row-to-source`.

- [ ] **Step 3: Extend the query and add the converter**

In `arc.el`, change `arc--retrieve-rows`'s SQL to select nine columns:

```
SELECT s.kind, s.path, s.info_node, s.org_id, s.option_name, d.chunk,
       d.line_start, d.line_end, d.title
FROM data AS d
JOIN sources AS s ON s.id = d.source_id
WHERE d.id IN %s;
```

Update its docstring to name all nine, then add:

```elisp
(defun arc-row-to-source (row)
  "Convert an `arc--retrieve-rows' ROW into a source plist.
The plist is the shape `arc-source-link' and `arc-source-label'
consume, carrying the chunk text and its line range alongside so a
citation can name the line it actually came from."
  (pcase-let ((`(,kind ,path ,info-node ,org-id ,option-name ,chunk ,ls ,le ,title) row))
    (list :kind kind :path path :info-node info-node :org-id org-id
          :option-name option-name :title title
          :line-start ls :line-end le :chunk chunk)))
```

- [ ] **Step 4: Run the suite**

Run: `ARC_VEC0_PATH=<vec0.so> ./test/run.sh`
Expected: PASS, count up by 5.

- [ ] **Step 5: Commit**

```bash
git add arc.el test/test-arc-retrieve-source.el
git commit -m "feat(arc): retrieval returns line numbers and titles for citations"
```

---

### Task 2: Prompt assembly and streaming, without ellama

**Files:**
- Create: `arc-answer.el`
- Test: `test/test-arc-answer.el`

**Interfaces:**
- Consumes: `arc-row-to-source` (Task 1), `arc-source-label`, and `arc-chat-provider` / `arc-chat-prompt-template` (both defined in `arc.el`).
- Produces:
  - `(arc-answer-context-block SOURCES)` → string
  - `(arc-answer-build-prompt QUESTION SOURCES)` → string
  - `(arc-answer-request QUESTION SOURCES ON-PARTIAL ON-DONE ON-ERROR)` → starts a streaming request

`llm-chat-streaming` is available, which is what lets arc render into its own buffer instead of ellama's.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-answer.el`:

```elisp
;;; test-arc-answer.el --- prompt assembly and streaming -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar aa-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path aa-root)
(require 'arc-answer)

(defvar aa-file-src
  '(:kind "file" :path "/tmp/x.nix" :line-start 12 :line-end 20 :chunk "alpha body"))
(defvar aa-opt-src
  '(:kind "nix-option" :option-name "services.foo.enable" :chunk "beta body"))

(ert-deftest aa-context-block-labels-and-includes-every-chunk ()
  (let ((b (arc-answer-context-block (list aa-file-src aa-opt-src))))
    (should (string-match-p "alpha body" b))
    (should (string-match-p "beta body" b))
    (should (string-match-p "x\\.nix" b))
    (should (string-match-p "services\\.foo\\.enable" b))))

(ert-deftest aa-build-prompt-puts-context-before-the-question ()
  (let ((p (arc-answer-build-prompt "why is it 8385?" (list aa-file-src))))
    (should (string-match-p "alpha body" p))
    (should (string-match-p "why is it 8385?" p))
    (should (< (string-match "alpha body" p)
               (string-match "why is it 8385?" p)))))

(ert-deftest aa-build-prompt-with-no-sources-still-asks ()
  (should (string-match-p "why?" (arc-answer-build-prompt "why?" nil))))

(ert-deftest aa-request-streams-partials-then-done ()
  (let ((partials nil) (done nil))
    (cl-letf (((symbol-function 'llm-chat-streaming)
               (lambda (_provider _prompt on-partial on-done _on-error)
                 (funcall on-partial "Hel")
                 (funcall on-partial "Hello")
                 (funcall on-done "Hello"))))
      (arc-answer-request "q" (list aa-file-src)
                          (lambda (txt) (push txt partials))
                          (lambda (txt) (setq done txt))
                          #'ignore))
    (should (equal (nreverse partials) '("Hel" "Hello")))
    (should (equal done "Hello"))))

(ert-deftest aa-request-surfaces-errors ()
  (let ((err nil))
    (cl-letf (((symbol-function 'llm-chat-streaming)
               (lambda (_p _pr _op _od on-error) (funcall on-error 'error "boom"))))
      (arc-answer-request "q" nil #'ignore #'ignore
                          (lambda (_sym msg) (setq err msg))))
    (should (equal err "boom"))))
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-answer.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: arc-answer`.

- [ ] **Step 3: Write `arc-answer.el`**

```elisp
;;; arc-answer.el --- prompt assembly and streaming for arc -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; arc renders its own answer buffer, so it assembles its own prompt and
;; streams the reply itself rather than handing both to ellama.  This file
;; knows nothing about buffers; `arc-ui.el' owns presentation.

;;; Code:

(require 'llm)
(require 'arc-source)

(defvar arc-chat-provider)
(defvar arc-chat-prompt-template)

(defun arc-answer-context-block (sources)
  "Render SOURCES as the context block placed above the question.
Each chunk is labelled so the model can refer to it, and so a reader
checking the answer against the citations can follow along."
  (mapconcat (lambda (s)
               (format "%s\n%s" (arc-source-label s) (or (plist-get s :chunk) "")))
             sources "\n\n"))

(defun arc-answer-build-prompt (question sources)
  "Build the full prompt for QUESTION grounded in SOURCES."
  (concat (arc-answer-context-block sources)
          "\n\n"
          (format arc-chat-prompt-template question)))

(defun arc-answer-request (question sources on-partial on-done on-error)
  "Ask the model QUESTION grounded in SOURCES, streaming the reply.
ON-PARTIAL receives the accumulated text so far, ON-DONE the final
text, ON-ERROR a symbol and a message."
  (llm-chat-streaming arc-chat-provider
                      (llm-make-chat-prompt (arc-answer-build-prompt question sources))
                      on-partial on-done on-error))

(provide 'arc-answer)
;;; arc-answer.el ends here
```

The two `defvar` forms without values declare `arc.el`'s variables as special so byte-compilation is clean without a circular `require`.

- [ ] **Step 4: Run the suite and byte-compile**

Run: `ARC_VEC0_PATH=<vec0.so> ./test/run.sh`
Then: `emacs -Q -batch -L . -f batch-byte-compile arc-answer.el 2>&1 | grep -i "not known\|undefined\|free variable"; rm -f *.elc`
Expected: suite PASS; byte-compile prints nothing.

- [ ] **Step 5: Commit**

```bash
git add arc-answer.el test/test-arc-answer.el
git commit -m "feat(arc-answer): assemble prompts and stream replies without ellama"
```

---

### Task 3: `arc-answer-mode` and the answer buffer

**Files:**
- Create: `arc-ui.el`
- Test: `test/test-arc-ui.el`

**Interfaces:**
- Consumes: `arc-source-link`, `arc-source-label`, `arc-row-to-source` (Task 1).
- Produces:
  - `arc-answer-mode` — major mode derived from `org-mode`
  - `arc-ui-buffer` — the `*arc*` buffer (creating it if needed)
  - `(arc-ui-begin-answer QUESTION)` → inserts the question heading, returns the marker where answer text accumulates
  - `(arc-ui-stream-answer MARKER TEXT)` → replaces the answer body with TEXT
  - `(arc-ui-render-sources SOURCES)` → appends the `*** Sources` subtree

**The mode is `arc-answer-mode` in `arc-ui.el`.** Do not name either the file or the mode `arc-mode` — that is a built-in Emacs library.

- [ ] **Step 1: Write the failing test**

Create `test/test-arc-ui.el`:

```elisp
;;; test-arc-ui.el --- the answer buffer -*- lexical-binding: t; -*-
(require 'ert)
(defvar aui-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aui-root)
(require 'arc-ui)

(defmacro aui-with-fresh-buffer (&rest body)
  "Run BODY in a freshly emptied *arc* buffer."
  `(let ((buf (arc-ui-buffer)))
     (unwind-protect
         (with-current-buffer buf
           (let ((inhibit-read-only t)) (erase-buffer))
           ,@body)
       (kill-buffer buf))))

(ert-deftest aui-mode-derives-from-org ()
  (aui-with-fresh-buffer
   (should (eq major-mode 'arc-answer-mode))
   (should (provided-mode-derived-p major-mode 'org-mode))))

(ert-deftest aui-never-defines-a-mode-called-arc-mode ()
  (should-not (fboundp 'arc-mode))
  (should-not (featurep 'arc-mode-shadow)))

(ert-deftest aui-question-is-a-second-level-heading ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "how do I enable syncthing?")
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\* how do I enable syncthing\\?$" nil t))))

(ert-deftest aui-streaming-replaces-rather-than-appends ()
  (aui-with-fresh-buffer
   (let ((m (arc-ui-begin-answer "q")))
     (arc-ui-stream-answer m "Hel")
     (arc-ui-stream-answer m "Hello")
     (goto-char (point-min))
     (should (re-search-forward "Hello" nil t))
     (goto-char (point-min))
     (should-not (re-search-forward "HelHello" nil t)))))

(ert-deftest aui-sources-render-as-org-links ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")
          '(:kind "nix-option" :option-name "services.foo.enable" :chunk "b")))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\*\\* Sources" nil t))
   (goto-char (point-min))
   (should (search-forward "[[file:/tmp/x.nix::12]]" nil t))
   (goto-char (point-min))
   (should (search-forward "[[nixopt:services.foo.enable]]" nil t))))

(ert-deftest aui-rendered-links-are-parseable-by-org ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")))
   (goto-char (point-min))
   (should (re-search-forward org-link-bracket-re nil t))))

(ert-deftest aui-no-sources-says-so-rather-than-rendering-an-empty-subtree ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources nil)
   (goto-char (point-min))
   (should (re-search-forward "no sources" nil t))))
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-ui.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `Cannot open load file: arc-ui`.

- [ ] **Step 3: Write `arc-ui.el`**

```elisp
;;; arc-ui.el --- the arc answer buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The answer buffer derives from `org-mode', which is the whole trick: a
;; citation is a real org link, so jumping to it needs no navigation code of
;; arc's own.  file, info and id links are org's; nixopt: and hmopt: are
;; registered by `arc-source.el'.
;;
;; The major mode is `arc-answer-mode'.  It is deliberately NOT called
;; `arc-mode': that is a built-in Emacs library (archive support), and
;; shadowing its feature symbol would make `(require 'arc-mode)' load the
;; wrong thing silently.

;;; Code:

(require 'org)
(require 'arc-source)

(defconst arc-ui-buffer-name "*arc*"
  "Name of the buffer arc renders answers into.")

(define-derived-mode arc-answer-mode org-mode "arc"
  "Major mode for arc's answers.
Derived from `org-mode' so that citations are ordinary org links."
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t))

(defun arc-ui-buffer ()
  "Return the arc answer buffer, creating it in `arc-answer-mode' if needed."
  (let ((buf (get-buffer-create arc-ui-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'arc-answer-mode)
        (arc-answer-mode)))
    buf))

(defun arc-ui-begin-answer (question)
  "Insert QUESTION as a heading and return a marker for the answer body.
The marker is where `arc-ui-stream-answer' replaces text as it arrives."
  (with-current-buffer (arc-ui-buffer)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "** %s\n\n" question))
    (let ((m (point-marker)))
      (set-marker-insertion-type m nil)
      m)))

(defun arc-ui-stream-answer (marker text)
  "Replace the answer body at MARKER with TEXT.
Streaming providers hand back the whole accumulated string each time,
so this replaces rather than appends -- appending would repeat every
prefix."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (goto-char marker)
      (delete-region marker (point-max))
      (insert text))))

(defun arc-ui-render-sources (sources)
  "Append a `*** Sources' subtree listing SOURCES as org links."
  (with-current-buffer (arc-ui-buffer)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "\n*** Sources                              [%d retrieved]\n"
                    (length sources)))
    (if (null sources)
        (insert "    (no sources retrieved)\n")
      (let ((n 0))
        (dolist (s sources)
          (setq n (1+ n))
          (insert (format "    %d. %s\n" n
                          (arc-source-link s (plist-get s :line-start)))))))))

(provide 'arc-ui)
;;; arc-ui.el ends here
```

- [ ] **Step 4: Run the suite and byte-compile**

Run: `ARC_VEC0_PATH=<vec0.so> ./test/run.sh`
Then byte-compile `arc-ui.el` and confirm no warnings.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add arc-ui.el test/test-arc-ui.el
git commit -m "feat(arc-ui): arc-answer-mode with org-link citations"
```

---

### Task 4: Keymap and transient

**Files:**
- Modify: `arc-ui.el`, `test/test-arc-ui.el`

**Interfaces:**
- Consumes: `arc-answer-mode` (Task 3).
- Produces: `arc-answer-mode-map`; `arc-transient` (a `transient-define-prefix` command); commands `arc-ui-follow-citation`, `arc-ui-quit`.

The spec's two keymaps: a global `C-c i` prefix for entry points, and in-buffer keys acting on the answer at point. This task builds the in-buffer map and the transient; Task 6 wires the global prefix once `arc-ask` exists.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-ui.el`:

```elisp
(ert-deftest aui-mode-map-binds-the-documented-keys ()
  (dolist (cell '(("q" . arc-ui-quit)
                  ("TAB" . org-cycle)))
    (should (eq (lookup-key arc-answer-mode-map (kbd (car cell))) (cdr cell)))))

(ert-deftest aui-mode-map-keys-are-all-real-commands ()
  (map-keymap
   (lambda (_key def)
     (when (symbolp def)
       (should (commandp def))))
   arc-answer-mode-map))

(ert-deftest aui-transient-is-defined-and-is-a-command ()
  (should (fboundp 'arc-transient))
  (should (commandp 'arc-transient)))

(ert-deftest aui-follow-citation-is-org-open-at-point ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")))
   (goto-char (point-min))
   (should (re-search-forward org-link-bracket-re nil t))
   (goto-char (match-beginning 0))
   (let ((called nil))
     (cl-letf (((symbol-function 'org-open-at-point)
                (lambda (&rest _) (setq called t))))
       (arc-ui-follow-citation))
     (should called))))
```

`test/test-arc-ui.el` needs `(require 'cl-lib)` at the top for `cl-letf`.

- [ ] **Step 2: Run it and confirm it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-ui.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `arc-answer-mode-map` has no `q` binding; `arc-transient` is void.

- [ ] **Step 3: Add the keymap, the commands and the transient**

In `arc-ui.el`, before `define-derived-mode`:

```elisp
(defvar arc-answer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'arc-ui-follow-citation)
    (define-key m (kbd "TAB") #'org-cycle)
    (define-key m (kbd "q")   #'arc-ui-quit)
    m)
  "Keymap for `arc-answer-mode'.
Acts on the answer at point.  Entry points live on the global `C-c i'
prefix instead.")
```

and after it:

```elisp
(defun arc-ui-follow-citation ()
  "Follow the citation at point.
A thin wrapper over `org-open-at-point': citations are org links, so
org already knows how to open every kind arc renders."
  (interactive)
  (org-open-at-point))

(defun arc-ui-quit ()
  "Bury the arc answer buffer."
  (interactive)
  (quit-window))

(require 'transient)

(transient-define-prefix arc-transient ()
  "arc."
  ["arc"
   ("i" "ask" arc-ask)
   ("r" "reindex" arc-reindex-all)
   ("c" "cancel reindex" arc-reindex-cancel)])
```

`arc-ask` arrives in Task 6. Until then the transient entry is defined but its command is void, which `transient` tolerates; Task 6's tests confirm it resolves.

- [ ] **Step 4: Run the suite**

Run: `ARC_VEC0_PATH=<vec0.so> ./test/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add arc-ui.el test/test-arc-ui.el
git commit -m "feat(arc-ui): in-buffer keymap and transient"
```

---

### Task 5: Header line reporting corpus size

**Files:**
- Modify: `arc-ui.el`, `test/test-arc-ui.el`

**Interfaces:**
- Consumes: `arc-index-stats` from `arc-index.el` → alist of `(KIND . CHUNK-COUNT)`.
- Produces: `(arc-ui-header-line)` → string.

The spec's header line also shows staleness. Staleness tracking is **phase 5**; this task reports only what the index can answer today — total chunks and per-kind counts.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-ui.el`:

```elisp
(ert-deftest aui-header-line-summarises-the-corpus ()
  (cl-letf (((symbol-function 'arc-index-stats)
             (lambda () '(("file" . 6427) ("org-node" . 428)))))
    (let ((h (arc-ui-header-line)))
      (should (string-match-p "6855" h))
      (should (string-match-p "file" h))
      (should (string-match-p "org-node" h)))))

(ert-deftest aui-header-line-survives-an-empty-corpus ()
  (cl-letf (((symbol-function 'arc-index-stats) (lambda () nil)))
    (should (stringp (arc-ui-header-line)))))

(ert-deftest aui-header-line-survives-an-unreadable-index ()
  (cl-letf (((symbol-function 'arc-index-stats)
             (lambda () (error "no database"))))
    (should (stringp (arc-ui-header-line)))))
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: FAIL — `void-function arc-ui-header-line`.

- [ ] **Step 3: Implement it**

```elisp
(declare-function arc-index-stats "arc-index")

(defun arc-ui-header-line ()
  "Return a one-line corpus summary for the answer buffer's header.
Reports size only.  Staleness needs the freshness tracking that phase 5
adds; until then this must not imply the corpus is current.  An index
that cannot be read reports that rather than signalling, because a
header line must never break the buffer it heads."
  (condition-case err
      (let* ((stats (arc-index-stats))
             (total (apply #'+ (mapcar #'cdr stats))))
        (if (null stats)
            "arc · corpus empty — run M-x arc-reindex-all"
          (format "arc · %d chunks · %s"
                  total
                  (mapconcat (lambda (c) (format "%s %d" (car c) (cdr c)))
                             stats " · "))))
    (error (format "arc · corpus unavailable (%s)"
                   (error-message-string err)))))
```

Set it in the mode body:

```elisp
(setq-local header-line-format '(:eval (arc-ui-header-line)))
```

- [ ] **Step 4: Run the suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add arc-ui.el test/test-arc-ui.el
git commit -m "feat(arc-ui): header line reporting corpus size"
```

---

### Task 6: Wire it together as `arc-ask`, and remove ellama

**Files:**
- Modify: `arc.el`, `arc-ui.el`, `README.org`, `test/test-arc-ui.el`
- Test: `test/test-arc-offline.el` (extend the banned-identifier list)

**Interfaces:**
- Consumes: everything above.
- Produces: `(arc-ask QUESTION &optional COLLECTIONS)` — the entry point `C-c i i` invokes.

This is where the ellama path dies. `arc-retrieve-ask` and `arc--add-context-row` exist only to feed ellama's buffer and context; both go.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-ui.el`:

```elisp
(ert-deftest aui-arc-ask-is-an-interactive-command ()
  (require 'arc)
  (should (commandp 'arc-ask)))

(ert-deftest aui-arc-ask-renders-question-answer-and-sources ()
  (require 'arc)
  (aui-with-fresh-buffer
   (cl-letf (((symbol-function 'arc-find-similar)
              (lambda (_text _cols on-done) (funcall on-done 'QUERY)))
             ((symbol-function 'arc--retrieve-ids)
              (lambda (_query _prompt) '(1)))
             ((symbol-function 'arc--retrieve-rows)
              (lambda (_ids)
                '(("file" "/tmp/x.nix" nil nil nil "chunk body" 12 20 nil))))
             ((symbol-function 'arc-answer-request)
              (lambda (_q _s on-partial on-done _on-error)
                (funcall on-partial "Because")
                (funcall on-done "Because 8385."))))
     (arc-ask "why 8385?"))
   (goto-char (point-min))
   (should (re-search-forward "^\\*\\* why 8385\\?$" nil t))
   (goto-char (point-min))
   (should (search-forward "Because 8385." nil t))
   (goto-char (point-min))
   (should (search-forward "[[file:/tmp/x.nix::12]]" nil t))))
```

Add to `arc-ban-list` in `test/test-arc-offline.el` (whatever the banned-identifier constant is named there): `"ellama"`, `"arc-retrieve-ask"`, `"arc--add-context-row"`.

- [ ] **Step 2: Run and confirm it fails**

Expected: FAIL — `void-function arc-ask`, and the offline suite fails on surviving `ellama` identifiers.

- [ ] **Step 3: Implement `arc-ask` and delete the ellama path**

In `arc.el`, split the id-selection out of the old `arc-retrieve-ask` so it is testable, then add the entry point:

```elisp
(defun arc--retrieve-ids (query prompt)
  "Return the data ids QUERY selects, reranked against PROMPT if enabled."
  (let ((raw (flatten-tree (sqlite-select (arc-db) query))))
    (if arc-reranker-enabled
        (arc-rerank prompt raw)
      (take arc-limit raw))))

;;;###autoload
(defun arc-ask (question &optional collections)
  "Ask arc QUESTION, grounded in COLLECTIONS, rendering into the arc buffer."
  (interactive "sAsk arc: ")
  (let ((cols (or collections arc-enabled-collections)))
    (arc-find-similar
     question cols
     (lambda (query)
       (let* ((ids (arc--retrieve-ids query question))
              (sources (mapcar #'arc-row-to-source (arc--retrieve-rows ids)))
              (marker (arc-ui-begin-answer question)))
         (pop-to-buffer (arc-ui-buffer))
         (arc-answer-request
          question sources
          (lambda (text) (arc-ui-stream-answer marker text))
          (lambda (text)
            (arc-ui-stream-answer marker text)
            (arc-ui-render-sources sources))
          (lambda (_sym msg)
            (arc-ui-stream-answer marker (format "arc: request failed: %s" msg)))))))))
```

Then delete `arc-retrieve-ask` and `arc--add-context-row` entirely, remove every `ellama` require, remove `ellama` from `Package-Requires` in `arc.el`, and add `(require 'arc-ui)` and `(require 'arc-answer)` where `arc.el` sets up.

Bind the global prefix:

```elisp
;;;###autoload
(defvar arc-command-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "i") #'arc-ask)
    (define-key m (kbd "R") #'arc-reindex-all)
    (define-key m (kbd "c") #'arc-reindex-cancel)
    m)
  "Prefix map for arc's entry points; bind it where you like.")
```

Do **not** bind `C-c i` globally from the package — say in the README that a user binds `arc-command-map` themselves. arc is a library; claiming a global key is the consumer's decision.

- [ ] **Step 4: Verify the suite and that ellama is gone**

Run: `ARC_VEC0_PATH=<vec0.so> ./test/run.sh`, then
`grep -rn "ellama" *.el` — expected: no hits outside a `;;; Changes:` note recording the removal.
Also byte-compile every changed file.

- [ ] **Step 5: End-to-end against the real model**

Run a real question in batch against the live Ollama and a **copy** of the index, and confirm the buffer contains a question heading, answer text, and at least one citation whose file and line you then open and check. Report the question, the answer and the citation verbatim. Do not use the live index in place.

- [ ] **Step 6: Update `README.org`**

Replace the `arc-chat` usage with `arc-ask`, document `arc-command-map` and how to bind it, and state that answers render in `*arc*` with citations you follow using `RET`. Remove ellama from the dependency list.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(arc): arc-ask renders into the arc buffer; drop ellama"
```

---

### Task 7: Capture an answer to the vault

**Files:**
- Modify: `arc-ui.el`, `test/test-arc-ui.el`, `README.org`

**Interfaces:**
- Consumes: `arc-answer-mode` and its buffer.
- Produces: `(arc-ui-capture)` bound to `w`; `arc-ui-capture-function` defcustom.

The spec's `w` key. arc must not assume a capture target — a library that writes into someone's vault by guessing is exactly what phase 2's path bug taught us to avoid.

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest aui-capture-is-bound-and-a-command ()
  (should (eq (lookup-key arc-answer-mode-map (kbd "w")) 'arc-ui-capture))
  (should (commandp 'arc-ui-capture)))

(ert-deftest aui-capture-passes-the-answer-subtree-to-the-configured-function ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "why 8385?")
   (let ((m (point-marker)))
     (arc-ui-stream-answer m "Because 8385."))
   (arc-ui-render-sources
    (list '(:kind "file" :path "/tmp/x.nix" :line-start 12 :chunk "b")))
   (let ((got nil))
     (let ((arc-ui-capture-function (lambda (text) (setq got text))))
       (goto-char (point-min))
       (arc-ui-capture))
     (should (string-match-p "why 8385\\?" got))
     (should (string-match-p "Because 8385\\." got))
     (should (string-match-p "\\[\\[file:/tmp/x\\.nix::12\\]\\]" got)))))

(ert-deftest aui-capture-without-a-configured-function-says-so ()
  (aui-with-fresh-buffer
   (arc-ui-begin-answer "q")
   (let ((arc-ui-capture-function nil))
     (goto-char (point-min))
     (should-error (arc-ui-capture) :type 'user-error))))
```

- [ ] **Step 2: Run and confirm it fails** — `void-function arc-ui-capture`.

- [ ] **Step 3: Implement**

```elisp
(defcustom arc-ui-capture-function nil
  "Function called with the answer subtree as a string, or nil.
arc does not guess where your notes live.  Set this to something like
a wrapper around `org-capture' to file an answer.  While nil, the `w'
key reports that it is unconfigured rather than writing anywhere."
  :type '(choice (const :tag "Not configured" nil) function)
  :group 'arc)

(defun arc-ui-answer-at-point ()
  "Return the current answer subtree as a string, including its sources."
  (save-excursion
    (save-restriction
      (widen)
      (org-back-to-heading t)
      (while (and (> (org-current-level) 2) (org-up-heading-safe)))
      (org-narrow-to-subtree)
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun arc-ui-capture ()
  "Send the answer at point to `arc-ui-capture-function'."
  (interactive)
  (unless arc-ui-capture-function
    (user-error "arc: set `arc-ui-capture-function' to capture answers"))
  (funcall arc-ui-capture-function (arc-ui-answer-at-point)))
```

Bind `w` to `arc-ui-capture` in `arc-answer-mode-map`.

- [ ] **Step 4: Run the suite** — expected PASS.

- [ ] **Step 5: Document it** in `README.org`'s usage section, with a worked `org-capture` example.

- [ ] **Step 6: Commit**

```bash
git add arc-ui.el test/test-arc-ui.el README.org
git commit -m "feat(arc-ui): capture an answer to a configured target"
```

---

### Task 8: Follow-up and re-ask

**Files:**
- Modify: `arc-ui.el`, `arc.el`, `test/test-arc-ui.el`

**Interfaces:**
- Consumes: `arc-ask` (Task 6), `arc-answer-request` (Task 2).
- Produces: `(arc-ui-follow-up)` bound to `f`; `(arc-ui-reask)` bound to `r`; the buffer-local `arc-ui--last-question` and `arc-ui--last-sources`.

The spec's remaining two in-buffer keys. `f` asks a new question carrying the
current answer forward as context; `r` re-runs the same question, which is how
you recover from a bad sampling or a model swap without retyping.

- [ ] **Step 1: Write the failing test**

Append to `test/test-arc-ui.el`:

```elisp
(ert-deftest aui-follow-up-and-reask-are-bound-commands ()
  (should (eq (lookup-key arc-answer-mode-map (kbd "f")) 'arc-ui-follow-up))
  (should (eq (lookup-key arc-answer-mode-map (kbd "r")) 'arc-ui-reask))
  (should (commandp 'arc-ui-follow-up))
  (should (commandp 'arc-ui-reask)))

(ert-deftest aui-reask-reuses-the-last-question ()
  (require 'arc)
  (aui-with-fresh-buffer
   (setq arc-ui--last-question "why 8385?")
   (let ((asked nil))
     (cl-letf (((symbol-function 'arc-ask)
                (lambda (q &rest _) (setq asked q))))
       (arc-ui-reask))
     (should (equal asked "why 8385?")))))

(ert-deftest aui-reask-without-a-previous-question-says-so ()
  (aui-with-fresh-buffer
   (setq arc-ui--last-question nil)
   (should-error (arc-ui-reask) :type 'user-error)))

(ert-deftest aui-follow-up-carries-the-previous-answer-as-context ()
  (require 'arc)
  (aui-with-fresh-buffer
   (setq arc-ui--last-question "why 8385?")
   (arc-ui-begin-answer "why 8385?")
   (let ((m (point-marker))) (arc-ui-stream-answer m "Because the WSL profile sets it."))
   (let ((prompt nil))
     (cl-letf (((symbol-function 'arc-ask)
                (lambda (q &rest _) (setq prompt q))))
       (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "and the listen port?")))
         (arc-ui-follow-up)))
     (should (string-match-p "and the listen port\\?" prompt))
     (should (string-match-p "why 8385\\?" prompt)))))
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `emacs -Q -batch -L . -l test/test-arc-ui.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `void-function arc-ui-follow-up`.

- [ ] **Step 3: Implement**

In `arc-ui.el`:

```elisp
(defvar-local arc-ui--last-question nil
  "The question the current answer answers, for `arc-ui-reask'.")

(defvar-local arc-ui--last-sources nil
  "Sources retrieved for the current answer.")

(defun arc-ui-reask ()
  "Ask the last question again, retrieving afresh."
  (interactive)
  (unless arc-ui--last-question
    (user-error "arc: no previous question to re-ask"))
  (arc-ask arc-ui--last-question))

(defun arc-ui-follow-up ()
  "Ask a follow-up, carrying the current question and answer as context."
  (interactive)
  (unless arc-ui--last-question
    (user-error "arc: no answer to follow up on"))
  (let ((next (read-string "Follow up: "))
        (previous (arc-ui-answer-at-point)))
    (arc-ask (format "Earlier question: %s\n\nEarlier answer:\n%s\n\nFollow-up: %s"
                     arc-ui--last-question previous next))))
```

Bind both in `arc-answer-mode-map`, and have `arc-ask` (Task 6) set
`arc-ui--last-question` and `arc-ui--last-sources` in the answer buffer as it
renders, so these commands have something to work from.

- [ ] **Step 4: Run the suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add arc-ui.el arc.el test/test-arc-ui.el
git commit -m "feat(arc-ui): follow-up and re-ask"
```

---

## Phase 4 exit criteria

1. `./test/run.sh` green, count up from 164.
2. `grep -rn "ellama" *.el` returns nothing outside a `;;; Changes:` note.
3. No file named `arc-mode.el`; no `(provide 'arc-mode)`; the mode is `arc-answer-mode`.
4. `M-x arc-ask` on a real question renders a question heading, streamed answer, and a `*** Sources` subtree; `RET` on a `file` citation opens the right file at the right line; `RET` on a `nixopt:` citation opens its declaration.
5. Every in-buffer key the spec names except `s` is bound and works: `f`, `r`, `w`, `TAB`, `q`, plus `RET`. `s` and the `n` / `o` entry points are deferred to phase 3 with scoped retrieval, and that deferral is stated in the README.
6. The header line reports corpus size and does not claim freshness.
7. `README.org` documents `arc-ask`, `arc-command-map`, `RET`, and `arc-ui-capture-function`, and no longer lists ellama.
