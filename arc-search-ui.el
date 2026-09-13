;;; arc-search-ui.el --- search surfaces for arc -*- lexical-binding: t; -*-

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
      (insert (format "    %s:%s  %s\n"
                      (or (plist-get doc :path) "")
                      (or (plist-get p :line-start) "")
                      (string-trim
                       (replace-regexp-in-string
                        "[ \t\n]+" " " (or (plist-get p :chunk) ""))))))
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
  (let ((scope (arc-ask-normalize-scope scope)))
    (arc-search-render (arc-search-documents query scope) query scope)
    (display-buffer arc-search-results-buffer-name)))

(defun arc-search-visit ()
  "Visit the document at point."
  (interactive)
  (let ((doc (arc-search--document-at-point)))
    (org-link-open-from-string (arc-source-link doc))))

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

(provide 'arc-search-ui)
;;; arc-search-ui.el ends here
