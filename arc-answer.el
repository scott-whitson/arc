;;; arc-answer.el --- prompt assembly and streaming for arc -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;;
;; arc renders its own answer buffer, so it assembles its own prompt and
;; streams the reply itself rather than handing both off to a separate chat
;; package.  This file knows nothing about buffers; `arc-ui.el' owns
;; presentation.
;;; Code:

(require 'llm)
(require 'arc-source)
(require 'arc-scope)

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

(provide 'arc-answer)
;;; arc-answer.el ends here
