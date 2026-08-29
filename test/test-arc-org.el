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
