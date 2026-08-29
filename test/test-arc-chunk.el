;;; test-arc-chunk.el --- chunking preserves line numbers -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar ac-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path ac-root)
(require 'arc-chunk)

(defun ac-fixture (name) (expand-file-name (concat "test/fixtures/" name) ac-root))

(ert-deftest ac-paragraph-chunks-have-line-numbers ()
  (let ((chunks (arc-chunk-file (ac-fixture "sample.txt"))))
    (should (= (length chunks) 2))
    (should (= (plist-get (nth 0 chunks) :line-start) 1))
    (should (= (plist-get (nth 1 chunks) :line-start) 4))
    (should (string-match-p "Second paragraph" (plist-get (nth 1 chunks) :text)))))

(ert-deftest ac-no-empty-chunks ()
  (dolist (f '("sample.txt" "sample.nix" "sample.el"))
    (dolist (c (arc-chunk-file (ac-fixture f)))
      (should (string-match-p "[^ \t\n]" (plist-get c :text))))))

(ert-deftest ac-elisp-splits-on-toplevel-forms ()
  (let ((chunks (arc-chunk-file (ac-fixture "sample.el"))))
    (should (= (length chunks) 2))
    (should (string-match-p "defun alpha" (plist-get (nth 0 chunks) :text)))
    (should (string-match-p "defun beta" (plist-get (nth 1 chunks) :text)))
    (should (= (plist-get (nth 1 chunks) :line-start) 5))))

(ert-deftest ac-nix-splits-on-toplevel-attributes ()
  (let* ((chunks (arc-chunk-file (ac-fixture "sample.nix")))
         (texts (mapcar (lambda (c) (plist-get c :text)) chunks)))
    (should (cl-some (lambda (s) (string-match-p "services\\.syncthing" s)) texts))
    (should (cl-some (lambda (s) (string-match-p "services\\.openssh" s)) texts))
    ;; the two services must not land in one chunk
    (should-not (cl-some (lambda (s) (and (string-match-p "syncthing" s)
                                          (string-match-p "openssh" s)))
                         texts))))

(ert-deftest ac-line-end-is-not-before-line-start ()
  (dolist (c (arc-chunk-file (ac-fixture "sample.nix")))
    (should (<= (plist-get c :line-start) (plist-get c :line-end)))))

(ert-deftest ac-file-with-no-trailing-newline-chunks-cleanly ()
  (let ((chunks (arc-chunk-file (ac-fixture "sample-no-newline.txt"))))
    (should (= (length chunks) 1))
    (should (= (plist-get (nth 0 chunks) :line-start) 1))
    (should (= (plist-get (nth 0 chunks) :line-end) 1))
    (should (string-match-p "No trailing newline" (plist-get (nth 0 chunks) :text)))))

(ert-deftest ac-single-line-file-chunks-cleanly ()
  (let ((chunks (arc-chunk-file (ac-fixture "sample-single-line.txt"))))
    (should (= (length chunks) 1))
    (should (= (plist-get (nth 0 chunks) :line-start) 1))
    (should (= (plist-get (nth 0 chunks) :line-end) 1))
    (should (string-match-p "Only one line here" (plist-get (nth 0 chunks) :text)))))

(ert-deftest ac-all-blank-file-produces-no-chunks ()
  (should (equal (arc-chunk-file (ac-fixture "sample-blank.txt")) nil)))


;; Exact :line-end values, counted by hand from the fixtures (not derived
;; by running the code): a chunk's :line-end must name its own last
;; non-blank content line, never the next chunk's first line.
;;
;; test/fixtures/sample.nix, 12 lines:
;;   1  { pkgs, ... }:
;;   2  {
;;   3    services.syncthing = {
;;   4      enable = true;
;;   5      guiAddress = "127.0.0.1:8385";
;;   6    };
;;   7  (blank)
;;   8    services.openssh = {
;;   9      enable = true;
;;   10     ports = [ 2222 ];
;;   11   };
;;   12 }
;; -> chunk1 (preamble) lines 1-2, chunk2 (syncthing block) lines 3-6,
;;    chunk3 (openssh block) lines 8-12.
(ert-deftest ac-nix-chunk-line-numbers-are-exact ()
  (let ((chunks (arc-chunk-file (ac-fixture "sample.nix"))))
    (should (= (length chunks) 3))
    (should (equal (list (plist-get (nth 0 chunks) :line-start)
                         (plist-get (nth 0 chunks) :line-end))
                   '(1 2)))
    (should (equal (list (plist-get (nth 1 chunks) :line-start)
                         (plist-get (nth 1 chunks) :line-end))
                   '(3 6)))
    (should (equal (list (plist-get (nth 2 chunks) :line-start)
                         (plist-get (nth 2 chunks) :line-end))
                   '(8 12)))))

;; test/fixtures/sample.el, 7 lines:
;;   1  (defun alpha ()
;;   2    "First."
;;   3    1)
;;   4  (blank)
;;   5  (defun beta ()
;;   6    "Second."
;;   7    2)
;; -> chunk1 (alpha) lines 1-3, chunk2 (beta) lines 5-7.
(ert-deftest ac-el-chunk-line-numbers-are-exact ()
  (let ((chunks (arc-chunk-file (ac-fixture "sample.el"))))
    (should (= (length chunks) 2))
    (should (equal (list (plist-get (nth 0 chunks) :line-start)
                         (plist-get (nth 0 chunks) :line-end))
                   '(1 3)))
    (should (equal (list (plist-get (nth 1 chunks) :line-start)
                         (plist-get (nth 1 chunks) :line-end))
                   '(5 7)))))
