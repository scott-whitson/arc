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
