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
