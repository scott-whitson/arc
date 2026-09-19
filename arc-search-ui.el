;;; arc-search-ui.el --- search surfaces for arc -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Two surfaces onto `arc-search-documents', because the two speeds
;; retrieval offers deserve different rooms.  The minibuffer source
;; (below, and only when consult is installed) is for the 46 ms keyword
;; arm: type, narrow, jump.  The results buffer is for the 150 ms hybrid:
;; somewhere to stand and read, with every passage reachable.
;;
;; consult is an optional dependency.  Everything in this file that does
;; not mention consult works without it.

;;; Code:

(require 'cl-lib)
(require 'arc-search)
(require 'arc-scope)
(require 'arc-source)

(defconst arc-search-results-buffer-name "*arc-search*"
  "Buffer `arc-search-render' renders into.")

(defvar-local arc-search--query nil
  "The query this results buffer last rendered.")

(defvar-local arc-search--scope nil
  "The scope this results buffer last rendered.")

(defvar-local arc-search--docs nil
  "The document list this results buffer last rendered.
`arc-search-render' sets this to the exact list it just rendered, so
`arc-search-toggle-passages' can splice one expanded document back in
without discarding the rest -- see that function's commentary.")

(defvar arc-results-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'arc-search-visit)
    (define-key map (kbd "TAB") #'arc-search-toggle-passages)
    (define-key map (kbd "g") #'arc-search-refresh)
    (define-key map (kbd "s") #'arc-search-change-scope)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    map)
  "Keymap for `arc-results-mode'.")

(define-derived-mode arc-results-mode special-mode "arc-search"
  "Major mode for arc search results.
Each document line carries its plist on the `arc-document' text
property; every command here reads that rather than re-parsing the
buffer."
  (setq truncate-lines t))

(defun arc-search--document-at-point ()
  "Return the document plist at point, or signal."
  (or (get-text-property (point) 'arc-document)
      (user-error "arc-search: no document on this line")))

(defun arc-search--passage-locator (doc p)
  "Return a \"path:line\" locator string for passage P of DOC, or nil.

Only a \"file\" document has a `:path' at all -- `info', `nix-option'
and `hm-option' sources do not, which on a typical corpus is 37,780 of
38,437 sources.  Formatting `(or (plist-get doc :path) \"\")'
unconditionally rendered a bare \":1\" or \":\" for every one of them: a
locator built entirely out of punctuation, pointing at nothing.  Nil
here means \"this passage has no locator\", not \"an empty one\" --
`arc-search--insert-document' omits the prefix rather than printing it
with nothing on either side."
  (when-let* ((path (plist-get doc :path)))
    (format "%s:%s" path (or (plist-get p :line-start) ""))))

(defun arc-search--insert-document (doc)
  "Insert one line for DOC, plus its passages, propertised with DOC."
  (let ((start (point))
        (label (arc-source-label doc)))
    (insert (format "%s  %s\n"
                    label
                    (if (> (plist-get doc :chunk-count) 1)
                        (format "(%d matches)" (plist-get doc :chunk-count))
                      "(1 match)")))
    (dolist (p (plist-get doc :passages))
      (let ((locator (arc-search--passage-locator doc p)))
        (insert (format "    %s%s\n"
                        (if locator (concat locator "  ") "")
                        (string-trim
                         (replace-regexp-in-string
                          "[ \t\n]+" " " (or (plist-get p :chunk) "")))))))
    (insert "\n")
    (put-text-property start (point) 'arc-document doc)))

(defun arc-search-render (docs query scope)
  "Render DOCS, found for QUERY in SCOPE, into the results buffer.
Records DOCS on the buffer-local `arc-search--docs' as it renders
them, so `arc-search-toggle-passages' has the exact list it is
looking at to splice into rather than having to reconstruct it."
  (with-current-buffer (get-buffer-create arc-search-results-buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (arc-results-mode)
      (setq arc-search--query query
            arc-search--scope scope
            arc-search--docs docs)
      (insert (format "arc search: %s\n%d document%s  ·  %s\n\n"
                      query
                      (length docs)
                      (if (= (length docs) 1) "" "s")
                      (arc-scope-describe scope)))
      (if (null docs)
          (insert "No documents matched.\n")
        (dolist (doc docs) (arc-search--insert-document doc)))
      (goto-char (point-min)))
    (current-buffer)))

;;;###autoload
(defun arc-search-show (query &optional scope)
  "Search for QUERY in SCOPE and show the results buffer."
  (interactive "sarc search: ")
  (let ((scope (arc-scope-normalize scope)))
    (arc-search-render (arc-search-documents query scope) query scope)
    (display-buffer arc-search-results-buffer-name)))

(defun arc-search--document-link (doc)
  "Return an org link string for DOC, targeting its best-matched line.
`arc-source-link' defaults to line 1 when given no LINE, which is
wrong for a \"file\" result: the passage that actually matched is
almost never the first line of the file.  DOC's first passage is its
best-scoring chunk (`arc-rollup' keeps passages best-first), so its
`:line-start' is passed through as LINE.  A document with no passages,
or whose first passage carries no `:line-start', falls back to
`arc-source-link's own one-argument form rather than passing a nil
LINE through -- `arc-source-link's \"file\" branch does `(or line 1)'
so this fallback only matters for readability, not correctness, but a
nil arms-length LINE reads as a mistake even where it happens to work.
LINE is ignored by `arc-source-link' for every other kind, so passing
it through for those too is harmless."
  (let ((line (plist-get (car (plist-get doc :passages)) :line-start)))
    (if line (arc-source-link doc line) (arc-source-link doc))))

(defun arc-search-visit ()
  "Visit the document at point, jumping to its best-matched line."
  (interactive)
  (let ((doc (arc-search--document-at-point)))
    (org-link-open-from-string (arc-search--document-link doc))))

(defun arc-search--splice-document (docs full)
  "Return DOCS with the entry matching FULL's `:source-id' replaced by FULL.
Every other document is returned unchanged, in its original position --
this is the piece the brief's version skipped, mapping over a
one-element list and discarding the rest of the result set instead of
splicing into it.  If no entry in DOCS matches FULL's `:source-id',
DOCS is returned unchanged."
  (let ((sid (plist-get full :source-id)))
    (mapcar (lambda (d) (if (equal (plist-get d :source-id) sid) full d))
            docs)))

(defun arc-search--rerender-preserving-point (docs)
  "Re-render DOCS into the results buffer, keeping point on its document.
Reads the `:source-id' at point before re-rendering and searches for
that same source id afterwards, so an expand-in-place command does not
throw the reader back to the top of the buffer."
  (let ((sid (plist-get (arc-search--document-at-point) :source-id)))
    (arc-search-render docs arc-search--query arc-search--scope)
    (let ((pos (point-min)))
      (catch 'found
        (while (setq pos (next-single-property-change pos 'arc-document))
          (when (equal (plist-get (get-text-property pos 'arc-document) :source-id) sid)
            (goto-char pos)
            (throw 'found t)))))))

(defun arc-search-toggle-passages ()
  "Expand the document at point to all of its matching chunks.
Re-queries with `arc-rollup-passages' bound high enough to return
every chunk, then splices the expanded document into
`arc-search--docs' at its existing position via
`arc-search--splice-document' -- every other document on the buffer
is left untouched, unlike the version this replaces, which rendered
`(list full)' and so discarded every other result on the very first
TAB. If the re-query no longer finds a matching document (the corpus
changed underneath), the buffer is left exactly as it was rather than
erroring or blanking it."
  (interactive)
  (let* ((doc (arc-search--document-at-point))
         (arc-rollup-passages most-positive-fixnum)
         (full (cl-find (plist-get doc :source-id)
                        (arc-search-documents arc-search--query
                                              arc-search--scope)
                        :key (lambda (d) (plist-get d :source-id)))))
    (when full
      (arc-search--rerender-preserving-point
       (arc-search--splice-document arc-search--docs full)))))

(defun arc-search-refresh ()
  "Re-run this buffer's query."
  (interactive)
  (unless arc-search--query (user-error "arc-search: nothing to refresh"))
  (arc-search-show arc-search--query arc-search--scope))

(defun arc-search-change-scope ()
  "Re-run this buffer's query at a scope chosen from `arc-scope-presets'."
  (interactive)
  (unless arc-search--query (user-error "arc-search: nothing to re-scope"))
  (let* ((name (completing-read "scope: " (mapcar #'car arc-scope-presets) nil t))
         (scope (alist-get name arc-scope-presets nil nil #'equal)))
    (arc-search-show arc-search--query scope)))

(defun arc-search--annotate (doc)
  "Return the annotation suffix for DOC."
  (format "  %s%s"
          (if (> (plist-get doc :chunk-count) 1)
              (format "%d matches" (plist-get doc :chunk-count))
            "1 match")
          (if (plist-get doc :kind)
              (format " · %s" (plist-get doc :kind))
            "")))

(defun arc-search--stage-annotation (cand)
  "Return the marginalia annotation for CAND: which arm actually found it.

The spec calls for the active stage to be \"visible in the marginalia
annotation\" -- this is that surface.  Reads the `arc-search-arm' text
property `arc-search--candidates' propertizes each candidate with, so
it says `keyword' while the fast BM25-only paint is on screen and
`fused' once `arc-search--two-stage's flush-then-replace has landed
the hybrid's own ranking (see that function's commentary for why the
replacement, not an append, is what makes the fused arm's order the
one that survives)."
  (when-let* ((arm (get-text-property 0 'arc-search-arm cand)))
    (format "  %s" (symbol-name arm))))

(defun arc-search--candidates (query scope arm)
  "Return propertised candidate strings for QUERY in SCOPE using ARM.

Returns nil for a blank QUERY: consult calls a dynamic source on every
keystroke including the first empty one, and that must not become a
full-corpus query.

Never signals.  A failure here is most often an unreachable embedding
endpoint on the hybrid arm, and the correct response is to fall back to
the keyword arm rather than throw the user out of the minibuffer.

Each candidate carries the arm that *actually* produced it on its
`arc-search-arm' text property -- not necessarily the ARM requested,
since a dead embedding endpoint falls back to the keyword arm's
results, and tagging that fallback `fused' would claim a re-rank in the
marginalia annotation (`arc-search--stage-annotation') that never
happened."
  (if (string-empty-p (string-trim (or query "")))
      nil
    (let* ((actual-arm (or arm 'fused))
           (docs (condition-case _
                     (arc-search-documents query scope arm)
                   (error
                    (unless (eq arm 'keyword)
                      (setq actual-arm 'keyword)
                      (condition-case _
                          (arc-search-documents query scope 'keyword)
                        (error nil)))))))
      (mapcar (lambda (doc)
                (propertize (concat (arc-source-label doc)
                                    (arc-search--annotate doc))
                            'arc-document doc
                            'arc-search-arm actual-arm))
              docs))))

(defun arc-search--two-stage (input scope callback)
  "Compute two-stage candidates for INPUT in SCOPE, calling CALLBACK.

Calls CALLBACK once with the keyword arm's candidates -- the fast,
~50ms first paint that needs no embedding call -- then, still within
this same invocation, `flush' to clear that paint, then once more with
the fused arm's full, independently-ranked result set.

An earlier version sent only the fused documents the keyword arm had
missed, appended after the first paint, because the sink this feeds
(`consult--async-dynamic') only clears its display on the FIRST
callback and APPENDS on every later one. That kept BM25's order frozen
for every document it found and let the fused arm only order the tail
-- which discarded exactly the re-ranking this whole hybrid exists to
provide. `consult--async-dynamic' passes a non-nil callback argument
straight to the sink as an action (see its `compute' closure around
`(funcall sink response)'), and the sink's action protocol
(`consult--async-sink') treats the symbol `flush' as \"clear the
candidate list\" -- so calling CALLBACK with `flush' between the two
result sets clears the first paint before the second one lands, and
the fused arm's own order survives untouched. Verified against a real
`consult--dynamic-collection' pipeline (`consult--async-wrap' plus
`consult--async-sink') in a throwaway daemon: the resulting candidate
order after keyword-then-flush-then-fused was byte-for-byte the order
`arc-search-documents' returns for the fused arm alone, where the
previous append-only version was not.

No dedupe is needed on the second call now that it replaces rather
than appends -- every duplicate the fused arm and the keyword arm
share is exactly one entry in the fused arm's own ranked list.

Never calls CALLBACK after returning, matching the contract
`consult--async-dynamic' documents for its FUN argument. Never signals:
`arc-search--candidates' already fails soft per arm, so a dead
embedding endpoint here still delivers the keyword-arm callback, then
`flush', then whatever `arc-search--candidates' falls back to for a
failed fused arm -- which is the same keyword-arm query again, so the
display ends up back where it started rather than blanked."
  (funcall callback (arc-search--candidates input scope 'keyword))
  (funcall callback 'flush)
  (funcall callback (arc-search--candidates input scope nil)))

(when (require 'consult nil t)

  (declare-function consult--read "consult")
  (declare-function consult--dynamic-collection "consult")
  ;; `arc-search--consult-lookup' and `arc-search-to-buffer' are both
  ;; defined further down in this very `when' block, but the byte
  ;; compiler does not track defuns nested inside a runtime conditional
  ;; for forward-reference purposes -- each would otherwise be flagged
  ;; "not known to be defined" despite being defined right here.
  (declare-function arc-search--consult-lookup nil)
  (declare-function arc-search-to-buffer nil)

  (defvar arc-search--session-scope nil
    "Scope of the in-flight `arc-search' minibuffer session.

Plain `defvar', deliberately distinct from the Task 5 buffer-locals
\(`arc-search--query', `arc-search--scope', `arc-search--docs'\), which
belong to the results buffer and must not be redeclared here.  `arc-search'
lets this dynamically for the extent of its `consult--read' call so that
`arc-search-to-buffer', invoked from that session's minibuffer keymap,
can read the session's scope without threading it through consult's own
API.")

  (defun arc-search--consult-lookup (selected candidates &rest _)
    "Return the document plist behind SELECTED among CANDIDATES."
    (when-let* ((match (car (member selected candidates))))
      (get-text-property 0 'arc-document match)))

  (defun arc-search-to-buffer ()
    "Send the current `arc-search' minibuffer query to the results buffer.

Reads the minibuffer's current input, exits the minibuffer, and then
calls `arc-search-show' with that input and the session's scope
\(`arc-search--session-scope'\).

Deliberately re-queries rather than trying to extract consult's live
candidate list: re-querying is simpler, cannot desync from whatever
consult happens to be holding, and always hands the buffer the full
hybrid result set regardless of which arm the minibuffer was displaying
when M-RET was pressed.  Do not \"optimise\" this into reusing whatever
candidates are already on screen.

`exit-minibuffer' throws immediately, so the call to `arc-search-show'
is scheduled with `run-at-time' rather than placed after it in this
function's body -- code after `exit-minibuffer' in the same command
does not run."
    (interactive)
    (let ((query (minibuffer-contents-no-properties))
          (scope arc-search--session-scope))
      (run-at-time 0 nil #'arc-search-show query scope)
      (exit-minibuffer)))

  (defvar arc-search--session-keymap
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "M-RET") #'arc-search-to-buffer)
      map)
    "Keymap for the `arc-search' minibuffer session.
Passed as consult's `:keymap', which composes it on top of the ambient
minibuffer map rather than replacing it -- see `consult--setup-keymap'.")

  ;; Deliberately no `;;;###autoload' cookie here. Cookie extraction is
  ;; line-based and does not track that this defun is nested inside `(when
  ;; (require 'consult nil t) ...)': a cookie on this line would generate
  ;; an unconditional autoload, so `M-x arc-search' would appear in
  ;; completion, load this file, and only then fail as undefined on a
  ;; machine without consult installed.
  (defun arc-search (&optional scope)
    "Search arc's documents from the minibuffer.

Paints the keyword arm's results first -- no embedding call, tens of
milliseconds -- then the same invocation replaces that paint with the
fused arm's own, independently-ranked result set, per
`arc-search--two-stage'.  The replacement is a real re-rank, not just
an appended tail: the fused arm's ordering governs the whole list, BM25
hits included, rather than freezing BM25's order for what it already
found.  There is no idle delay to tune: `consult--async-dynamic' wraps
the computation in `while-no-input' and restarts it after
`consult-async-input-debounce' if a keystroke interrupts it, which is
what makes a still-typing user see the keyword arm and a paused one see
the sharpened result, without this command hand-rolling the same thing
on top.  Nothing is computed for the first
`consult-async-min-input' (3, by default) characters typed -- that is
consult's own standard behaviour, not a bug here.  \\<minibuffer-local-map>
\\[exit-minibuffer] visits the document; \\<arc-search--session-keymap>
\\[arc-search-to-buffer] sends the whole result set to the results
buffer."
    (interactive)
    (let* ((scope (arc-scope-normalize scope))
           (arc-search--session-scope scope)
           (doc (consult--read
                 (consult--dynamic-collection
                  (lambda (input callback)
                    (arc-search--two-stage input scope callback)))
                 :prompt "arc search: "
                 :lookup #'arc-search--consult-lookup
                 :sort nil
                 :require-match t
                 :keymap arc-search--session-keymap
                 :category 'arc-document
                 :annotate #'arc-search--stage-annotation)))
      (when doc
        (org-link-open-from-string (arc-search--document-link doc))))))

(provide 'arc-search-ui)
;;; arc-search-ui.el ends here
