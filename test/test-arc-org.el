;;; test-arc-org.el --- org-roam nodes become chunks -*- lexical-binding: t; -*-
(require 'ert)
(defvar ao2-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path ao2-root)
(require 'arc-source-org)

(defvar ao2-dir (expand-file-name "test/fixtures/roam" ao2-root))

(ert-deftest ao2-finds-file-and-heading-nodes ()
  (let ((nodes (arc-org-nodes ao2-dir)))
    (should (= (length nodes) 3))))

(ert-deftest ao2-ids-are-extracted ()
  (let ((ids (mapcar (lambda (n) (plist-get n :org-id)) (arc-org-nodes ao2-dir))))
    (should (member "11111111-1111-1111-1111-111111111111" ids))
    (should (member "22222222-2222-2222-2222-222222222222" ids))
    (should (member "33333333-3333-3333-3333-333333333333" ids))))

(ert-deftest ao2-file-node-title-comes-from-keyword ()
  (let* ((nodes (arc-org-nodes ao2-dir))
         (n (cl-find "11111111-1111-1111-1111-111111111111" nodes
                     :key (lambda (x) (plist-get x :org-id)) :test #'equal)))
    (should (equal (plist-get n :title) "syncthing on rafik"))))

(ert-deftest ao2-heading-node-title-comes-from-heading ()
  (let* ((nodes (arc-org-nodes ao2-dir))
         (n (cl-find "22222222-2222-2222-2222-222222222222" nodes
                     :key (lambda (x) (plist-get x :org-id)) :test #'equal)))
    (should (equal (plist-get n :title) "Backup gate"))
    (should (string-match-p "ten checks" (plist-get n :text)))))

(ert-deftest ao2-kind-is-org-node ()
  (should (cl-every (lambda (n) (equal (plist-get n :kind) "org-node"))
                    (arc-org-nodes ao2-dir))))

(ert-deftest ao2-filetags-are-captured ()
  (let* ((nodes (arc-org-nodes ao2-dir))
         (n (cl-find "33333333-3333-3333-3333-333333333333" nodes
                     :key (lambda (x) (plist-get x :org-id)) :test #'equal)))
    (should (member "distro" (plist-get n :tags)))))

(ert-deftest ao2-skips-dot-directories ()
  "A Syncthing .stversions copy must not become a node or duplicate an id."
  (let ((nodes (arc-org-nodes ao2-dir)))
    (should (= (length nodes) 3))
    (should (= 1 (cl-count "11111111-1111-1111-1111-111111111111" nodes
                           :key (lambda (n) (plist-get n :org-id)) :test #'equal)))
    (should (cl-notany (lambda (n) (string-match-p "\\.stversions" (plist-get n :path)))
                       nodes))))

(ert-deftest ao2-nodes-carry-chunks ()
  "Every node arc-org-nodes returns must carry :chunks, not just :text --
`arc-index-source' reads only :chunks, so anything producing a bare
:text silently writes zero chunks if called on it directly."
  (should (cl-every (lambda (n) (consp (plist-get n :chunks))) (arc-org-nodes ao2-dir))))

(ert-deftest ao2-small-node-is-exactly-one-chunk ()
  (let* ((nodes (arc-org-nodes ao2-dir))
         (n (cl-find "11111111-1111-1111-1111-111111111111" nodes
                     :key (lambda (x) (plist-get x :org-id)) :test #'equal)))
    (should (= (length (plist-get n :chunks)) 1))))

(ert-deftest ao2-oversized-node-is-split-into-multiple-chunks ()
  "A node whose text exceeds `arc-chunk-size-ceiling' must come back
chunked instead of as one giant chunk `nomic-embed-text' would mostly
truncate away -- live notes as large as 436 KB have been seen as a
single node.  This is a synthetic oversized fixture generated at test
time, not a giant file checked into the repo."
  (let ((dir (make-temp-file "arc-oversized-org" t))
        (arc-chunk-size-ceiling 2000))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "big.org" dir)
            (insert ":PROPERTIES:\n:ID: 44444444-4444-4444-4444-444444444444\n:END:\n"
                    "#+title: oversized note\n\n")
            (dotimes (n 200)
              (insert (format "Paragraph %d filler text to bulk this note up past the ceiling.\n\n" n))))
          (let* ((nodes (arc-org-nodes dir))
                 (n (cl-find "44444444-4444-4444-4444-444444444444" nodes
                             :key (lambda (x) (plist-get x :org-id)) :test #'equal))
                 (chunks (plist-get n :chunks)))
            (should n)
            (should (> (length chunks) 1))
            (should (cl-every (lambda (c) (stringp (plist-get c :text))) chunks))
            (should (cl-every (lambda (c) (<= (plist-get c :line-start) (plist-get c :line-end)))
                              chunks))))
      (delete-directory dir t))))

;;; The `#+id:' keyword fallback

;; A file's id can live in a `#+id:' keyword instead of an `:ID:' property
;; drawer. `org-entry-get' cannot see a keyword, so before the fallback those
;; files indexed as nothing at all -- and, worse, silently: an empty
;; collection looks the same as a collection whose documents do not exist.

(defun ao2-write-org (dir name content)
  "Write CONTENT to NAME inside DIR and return the file's path."
  (let ((path (expand-file-name name dir)))
    (with-temp-file path (insert content))
    path))

(defmacro ao2-with-org-file (content &rest body)
  "Call BODY with the path of a temp org file holding CONTENT.
BODY is evaluated with `ao2-file' bound to that path, and the temp
directory is removed afterwards."
  (declare (indent 1))
  `(let ((dir (make-temp-file "arc-org-id" t)))
     (unwind-protect
         (let ((ao2-file (ao2-write-org dir "page.org" ,content)))
           ,@body)
       (delete-directory dir t))))

(ert-deftest ao2-file-node-falls-back-to-the-id-keyword ()
  (ao2-with-org-file "#+title: A page\n#+id: keyword-only-id\n\nbody\n"
    (let* ((nodes (arc-org-nodes-in-file ao2-file))
           (node (car nodes)))
      (should (= (length nodes) 1))
      (should (equal (plist-get node :org-id) "keyword-only-id"))
      (should (equal (plist-get node :title) "A page")))))

(ert-deftest ao2-the-drawer-id-wins-over-the-keyword ()
  (ao2-with-org-file (concat ":PROPERTIES:\n:ID: drawer-id\n:END:\n"
                             "#+title: A page\n#+id: keyword-id\n\nbody\n")
    (let* ((nodes (arc-org-nodes-in-file ao2-file))
           (node (car nodes)))
      (should (= (length nodes) 1))
      (should (equal (plist-get node :org-id) "drawer-id")))))

(ert-deftest ao2-an-empty--id-keyword-is-not-an-id ()
  (dolist (blank '("" "   "))
    (ao2-with-org-file (format "#+title: A page\n#+id:%s\n\nbody\n" blank)
      (should (null (arc-org-nodes-in-file ao2-file))))))

(ert-deftest ao2-a-file-with-neither-drawer-nor-keyword-produces-no-node ()
  (ao2-with-org-file "#+title: A page\n\nbody\n"
    (should (null (arc-org-nodes-in-file ao2-file)))))

(ert-deftest ao2-keyword-fallback-does-not-invent-ids-for-headings ()
  "The keyword is file-level only; a heading still needs its own `:ID:'."
  (ao2-with-org-file (concat "#+title: A page\n#+id: file-id\n\n"
                             "* Plain heading with no id\n\ntext\n")
    (let ((nodes (arc-org-nodes-in-file ao2-file)))
      (should (= (length nodes) 1))
      (should (equal (plist-get (car nodes) :org-id) "file-id")))))

(ert-deftest ao2-a-keyword-inside-a-block-is-not-the-file-id ()
  "A note that DOCUMENTS the syntax must not lend the file an id.
`org-mode' reads this line as block content, so arc must not read it as a
keyword -- a fabricated id is a citation target that resolves to nothing."
  (ao2-with-org-file (concat "#+title: A page\n\n"
                             "#+begin_src org\n#+id: documented-not-real\n#+end_src\n\n"
                             "body\n")
    (should (null (arc-org-nodes-in-file ao2-file)))))

(ert-deftest ao2-a-keyword-after-a-headline-is-not-the-file-id ()
  "File-level keywords live in the header; one inside a section is not the file's."
  (ao2-with-org-file (concat "#+title: A page\n\n* A heading\n\n"
                             "#+id: section-not-file\n\nbody\n")
    (should (null (arc-org-nodes-in-file ao2-file)))))
