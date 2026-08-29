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

;;; --- arc-chunk-text: a size ceiling for oversized nodes ---------------
;; Live org-roam notes as large as 436 KB have been seen as a single node
;; with no chunking at all; `nomic-embed-text' truncates far below that, so
;; the note's one chunk embedded a vector describing about 2% of its real
;; content.  `arc-chunk-text' exists so a producer (arc-source-org.el) can
;; split an oversized node on paragraph boundaries while leaving an
;; ordinary small node as exactly one chunk.

(ert-deftest act-small-text-is-one-chunk-even-with-blank-lines ()
  "A node under the ceiling stays one chunk, even with paragraph breaks
inside it -- splitting every small note on its blank lines would be a
regression, not a fix."
  (let ((arc-chunk-size-ceiling 4000))
    (let ((chunks (arc-chunk-text "para one\n\npara two\n\npara three\n")))
      (should (= (length chunks) 1))
      (should (string-match-p "para one" (plist-get (car chunks) :text)))
      (should (string-match-p "para three" (plist-get (car chunks) :text))))))

(ert-deftest act-oversized-text-splits-on-paragraph-boundaries ()
  "Text over the ceiling is split like `arc-chunk-buffer' would, and no
chunk exceeds the ceiling."
  (let* ((arc-chunk-size-ceiling 50)
         (text (mapconcat (lambda (n) (format "paragraph number %d, padded out a bit" n))
                          (number-sequence 1 10) "\n\n"))
         (chunks (arc-chunk-text text)))
    (should (> (length chunks) 1))
    (should (cl-every (lambda (c) (<= (length (plist-get c :text)) 100)) chunks))
    ;; every non-blank line of the input shows up somewhere in the chunks
    (should (string-match-p "paragraph number 1," (plist-get (car chunks) :text)))
    (should (string-match-p "paragraph number 10," (plist-get (car (last chunks)) :text)))))

(ert-deftest act-oversized-text-line-numbers-are-internally-consistent ()
  (let* ((arc-chunk-size-ceiling 10)
         (chunks (arc-chunk-text "alpha\n\nbeta\n\ngamma\n")))
    (should (> (length chunks) 1))
    (dolist (c chunks)
      (should (<= (plist-get c :line-start) (plist-get c :line-end))))))

(ert-deftest act-empty-text-produces-no-chunks ()
  (should (null (arc-chunk-text "   \n\n  "))))
