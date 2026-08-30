;;; test-arc-offline.el --- arc makes no outbound requests -*- lexical-binding: t; -*-
(require 'ert)
(defvar ao-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ao-root)

(defconst ao-forbidden
  '("arc-tika-url" "arc-searxng-url" "arc-pandoc-executable"
    "arc-web-search-function" "arc-webpage-extraction-function"
    "arc-complex-file-extraction-function" "arc-web-pages-limit"
    "arc-supported-complex-document" "duckduckgo" "searxng"
    "ellama" "arc-retrieve-ask" "arc--add-context-row")
  "Identifiers that must not survive in arc's code.

Scanned only from `;;; Code:' onward: the `;;; Changes:' block above it
is a GPL-3 statement of changes and accurately says Apache Tika,
pandoc and web search were removed -- that is prose naming what was
deleted, not a reintroduction of the deleted machinery, so it is out
of scope for this scan on purpose.

Loopback HTTP to a locally-running service is not \"network\" in the
sense this test polices: \"no network at query time\" means no
outbound internet access, not no localhost. Ollama on
localhost:11434 and the optional reranker's POST to 127.0.0.1 are
both loopback-only and are intentionally left alone -- do not add
them here.")

(defconst ao-policed-files '("arc.el" "arc-ui.el" "arc-answer.el")
  "Files scanned for `ao-forbidden' identifiers.
Used to be `arc.el' alone; `arc-ui.el' and `arc-answer.el' also talk
to the model or render into the answer buffer and were entirely
unpoliced by this guard, which is exactly the kind of place a
reintroduced network dependency (an ellama-style chat package, say)
would show up first.")

(ert-deftest ao-no-network-identifiers ()
  (dolist (file ao-policed-files)
    (with-temp-buffer
      (insert-file-contents (expand-file-name file ao-root))
      (goto-char (point-min))
      (search-forward ";;; Code:")
      (let ((code-start (point)))
        (dolist (needle ao-forbidden)
          (goto-char code-start)
          (should-not (search-forward needle nil t)))))))

(ert-deftest ao-kinds-are-local-only ()
  (require 'arc)
  (should (equal (arc-kinds) '("file" "info" "org-node" "nix-option" "hm-option"))))
