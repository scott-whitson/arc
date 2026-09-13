;;; arc-tool.el --- arc's agent-facing verbs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Three verbs for a caller outside Emacs: search, scopes, stats.
;;
;; There is deliberately no `ask'.  When an external agent calls arc,
;; that agent is already a language model; routing it through a local 3B
;; one would put a weaker reasoner between it and the documents and throw
;; away the retrieval fidelity this whole surface exists to expose.
;; `arc-ask' remains an Emacs-side command.
;;
;; `scopes' and `stats' exist because a caller cannot see the screen.
;; Without enumeration it guesses collection names or defaults to
;; searching everything on every call; without freshness it quotes a
;; stale chunk as current configuration, which is a correctness bug
;; rather than a cosmetic one.

;;; Code:

(require 'arc)
(require 'arc-search)
(require 'arc-index)
(require 'arc-scope)

(defun arc-tool--arm (arm)
  "Normalise ARM to `keyword' or `fused', or signal for anything else.
`arc--find-similar' silently treats an unrecognised ARM as `fused' --
harmless there, since its only other callers pass a value they chose
themselves.  `arc-tool-search' instead echoes ARM back in its JSON
`:arm' field for a caller that cannot see the code, so doing the same
silent fallback here would mislabel a typo as the arm that actually
ran; e.g. `--arm bogus' would report `\"arm\":\"bogus\"' while quietly
having run the fused query."
  (pcase arm
    ((or 'nil 'fused) 'fused)
    ('keyword 'keyword)
    (_ (error "arc: unknown arm %S (try: keyword, fused)" arm))))

(defun arc-tool--scope (name)
  "Return the scope plist NAME names in `arc-scope-presets', or signal."
  (if (or (null name) (string-empty-p name))
      (arc-ask-normalize-scope nil)
    (or (alist-get name arc-scope-presets nil nil #'equal)
        (error "arc: unknown scope %S (try: %s)" name
               (string-join (mapcar #'car arc-scope-presets) ", ")))))

(defun arc-tool--document-json (doc)
  "Return DOC as a JSON-serialisable plist."
  (list :path (or (plist-get doc :path) :null)
        :kind (or (plist-get doc :kind) :null)
        :title (or (plist-get doc :title) :null)
        :option_name (or (plist-get doc :option-name) :null)
        :info_node (or (plist-get doc :info-node) :null)
        :org_id (or (plist-get doc :org-id) :null)
        :score (plist-get doc :score)
        :chunks (plist-get doc :chunk-count)
        :passages
        (vconcat
         (mapcar (lambda (p)
                   (list :text (or (plist-get p :chunk) "")
                         :line_start (or (plist-get p :line-start) :null)
                         :line_end (or (plist-get p :line-end) :null)))
                 (plist-get doc :passages)))))

(defun arc-tool-search (query &optional scope-name limit arm)
  "Search for QUERY and return the results as a JSON string.
SCOPE-NAME names an entry in `arc-scope-presets'.  LIMIT overrides
`arc-search-limit'.  ARM is normalised by `arc-tool--arm' -- `keyword'
or `fused' (nil), anything else signals -- and passed through to
`arc-search-documents'."
  (let* ((scope (arc-tool--scope scope-name))
         (arm (arc-tool--arm arm))
         (arc-search-limit (or limit arc-search-limit))
         (start (float-time))
         (docs (arc-search-documents query scope arm)))
    (json-serialize
     (list :query query
           :scope (or scope-name "default")
           :arm (symbol-name arm)
           :elapsed_ms (round (* 1000 (- (float-time) start)))
           :count (length docs)
           :results (vconcat (mapcar #'arc-tool--document-json docs))))))

(defun arc-tool-scopes ()
  "Return the available scopes, with their sizes, as a JSON string."
  (json-serialize
   (list :scopes
         (vconcat
          (mapcar (lambda (preset)
                    (list :name (car preset)
                          :chunks (arc-scope-count (cdr preset))
                          :describe (arc-scope-describe (cdr preset))))
                  arc-scope-presets)))))

(defun arc-tool-stats ()
  "Return corpus size, per-collection breakdown and freshness as a JSON string.
Freshness is here so a caller can tell a current answer from a stale
one before quoting it as configuration; the per-collection breakdown is
here so it can tell WHICH collection, and how recently, without
re-deriving it from `:kinds' (keyed by source kind, not collection) or
counting `:freshness' rows itself.

`arc-freshness-report' rows are (NAME KIND STATE DETAIL) -- see its
docstring.  KIND (the chunker a collection uses, e.g. `file' or
`org') and DETAIL (a human-readable reason, or nil when fresh) are
different claims about a collection; collapsing KIND into a field
named `:detail' and dropping the real detail would mislabel a
collection's kind as its freshness detail to a caller that cannot see
the source to tell the difference.

`arc-index-collection-stats' rows are (NAME SOURCES CHUNKS
LAST-INDEXED) -- see its docstring.  LAST-INDEXED is
`sources.indexed_at', seconds since the epoch, or `:null' for a
collection with nothing indexed yet."
  (json-serialize
   (list :chunks (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))
         :sources (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))
         :kinds (vconcat
                 (mapcar (lambda (kv)
                           (list :kind (car kv) :chunks (cdr kv)))
                         (arc-index-stats)))
         :collections (vconcat
                       (mapcar (lambda (r)
                                 (list :collection (format "%s" (nth 0 r))
                                       :sources (nth 1 r)
                                       :chunks (nth 2 r)
                                       :last_indexed_at (or (nth 3 r) :null)))
                               (arc-index-collection-stats)))
         :freshness (vconcat
                     (mapcar (lambda (r)
                               (list :collection (format "%s" (nth 0 r))
                                     :kind (format "%s" (nth 1 r))
                                     :state (format "%s" (nth 2 r))
                                     :detail (or (nth 3 r) :null)))
                             (arc-freshness-report))))))

(provide 'arc-tool)
;;; arc-tool.el ends here
