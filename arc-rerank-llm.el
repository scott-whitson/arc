;;; arc-rerank-llm.el --- rerank with the chat model already installed -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; arc's reranker seam was written for an HTTP cross-encoder service at
;; `arc-reranker-url'.  No such service exists in nixpkgs, Ollama serves no
;; rerank endpoint (404 on /api/rerank as of 0.31.1), and standing up a
;; cross-encoder means a Python/torch closure and a second resident model on a
;; machine with 14 GiB and no swap.  So this reranks with the chat model that
;; is already running.
;;
;; It is worth doing because the headroom was measured first, not assumed.
;; Over a 33-question set against a 63k-chunk corpus:
;;
;;   recall@10 0.79   recall@20 0.91   recall@40 0.94
;;
;; and of the seven questions missing at 10, five had their target sitting at
;; rank 11, 17, 17, 17 and 31 -- found, badly ordered.  A perfect reordering of
;; the top 40 is worth +0.15 at k=10.  Two of the seven were absent from all 40
;; and no reranker can reach them.
;;
;; MEASURED RESULT: this does not work, and is not recommended. Over the same
;; 33-question set, against the shipped baseline:
;;
;;   reranker off        r@3 0.42  r@5 0.58  r@10 0.79   26/33     7.9s
;;   LLM rerank, pool 20 r@3 0.36  r@5 0.58  r@10 0.76   25/33   127.3s
;;   LLM rerank, pool 40 r@3 0.52  r@5 0.55  r@10 0.61   20/33   150.8s
;;
;; Worse recall for 16-19x the latency. The pool-40 row is the instructive one:
;; asked to order forty snippets, a 3B general model loses track, and its
;; partial ordering EVICTS answers that were already in the top ten -- any-hit
;; falls from 26 to 20 of 33. More candidates made it worse, which is the
;; signature of a model that is not actually scoring pairs.
;;
;; That is a negative result worth keeping rather than deleting, for two
;; reasons. It is re-runnable against a larger chat model (`arc-chat-models'
;; has a 7B entry) if anyone wants to know whether capacity fixes it. And it is
;; the empirical case for the specialised alternative: a cross-encoder scores
;; each (query, document) pair independently, so it cannot lose track of
;; candidate thirty-seven, and at ~300M parameters it is an order of magnitude
;; cheaper than the 3B generalist that just failed. nixpkgs' llama-cpp ships
;; `llama-server --reranking' with `--pooling rank', which is that path without
;; a Python or torch closure.
;;
;; `arc-reranker-function' is left nil. Do not wire this in as a default.
;;
;; The contract is deliberately timid: on any failure -- an unreachable model,
;; an unparseable reply, a reply naming candidates that were never offered --
;; the original order is returned unchanged.  A reranker that can make
;; retrieval worse than not reranking is not worth having.

;;; Code:

(require 'cl-lib)
(require 'llm)
(require 'arc)

(defcustom arc-rerank-llm-snippet-chars 500
  "Characters of each candidate shown to the reranking model.
Chunks average 643 characters here but the corpus contains a
594,549-character Info index node, so an untruncated prompt is not
bounded by anything.  20 candidates at 500 characters is roughly 2,800
tokens of prompt."
  :type 'integer :group 'arc)

(defcustom arc-rerank-llm-prompt
  "You are ranking search results for relevance to a question.

Question: %s

Candidates:
%s

Reply with ONLY the candidate numbers, most relevant first, separated by
spaces. Include every number exactly once. No prose, no explanation."
  "Prompt template for LLM reranking.  Takes the question, then the candidates."
  :type 'string :group 'arc)

(defun arc-rerank-llm--candidates (ids)
  "Return ((ID . SNIPPET) ...) for IDS, in the order IDS gives."
  (let ((rows (sqlite-select
               (arc-db)
               (format "SELECT id, chunk FROM data WHERE id IN %s;"
                       (arc-sqlite-format-int-list ids)))))
    (delq nil
          (mapcar (lambda (id)
                    (when-let ((row (assoc id rows)))
                      (cons id (truncate-string-to-width
                                (or (cadr row) "") arc-rerank-llm-snippet-chars))))
                  ids))))

(defun arc-rerank-llm--parse (reply n)
  "Return the 1-based candidate numbers in REPLY, bounded by N.
Ignores anything that is not a number in range, and drops repeats --
a model that says \"3 3 3\" has not ranked anything."
  (let (out)
    (dolist (tok (split-string reply "[^0-9]+" t))
      (let ((i (string-to-number tok)))
        (when (and (>= i 1) (<= i n) (not (memq i out)))
          (push i out))))
    (nreverse out)))

(defun arc-rerank-llm (prompt ids)
  "Reorder IDS by asking `arc-chat-provider' to rank them against PROMPT.
Returns at most `arc-limit' ids.  Returns the head of IDS unchanged if
anything goes wrong -- see this file's commentary."
  (let* ((cands (arc-rerank-llm--candidates ids))
         (n (length cands)))
    (if (< n 2)
        (take arc-limit ids)
      (let* ((numbered
              (let ((i 0))
                (mapconcat (lambda (c)
                             (setq i (1+ i))
                             (format "%d. %s" i (cdr c)))
                           cands "\n\n")))
             (reply (condition-case err
                        (llm-chat arc-chat-provider
                                  (llm-make-chat-prompt
                                   (format arc-rerank-llm-prompt prompt numbered)))
                      (error (message "arc: reranker failed (%s); keeping search order"
                                      (error-message-string err))
                             nil)))
             (order (and reply (arc-rerank-llm--parse reply n))))
        (if (null order)
            (progn (when reply
                     (message "arc: reranker reply unusable; keeping search order"))
                   (take arc-limit ids))
          ;; Ranked ones first, then anything the model omitted, so a partial
          ;; reply degrades to "partly reranked" rather than "candidates lost".
          (let* ((ranked (mapcar (lambda (i) (car (nth (1- i) cands))) order))
                 (rest (cl-remove-if (lambda (id) (memq id ranked))
                                     (mapcar #'car cands))))
            (take arc-limit (append ranked rest))))))))

(provide 'arc-rerank-llm)
;;; arc-rerank-llm.el ends here
