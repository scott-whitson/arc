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

;;; --- The ceiling applies to every chunk, not only to text blobs -------
;; The `file' chunker split on blank lines (or a boundary regexp) and
;; stopped there, so a file with no blank line in it -- a log, a lock
;; file, a long note written without paragraph breaks -- was one chunk
;; however long it was, and `nomic-embed-text' embedded only its head.

(defun ac-lines-of (text from to)
  "Return lines FROM..TO (1-based, inclusive) of TEXT, joined and trimmed."
  (string-trim (string-join (seq-subseq (split-string text "\n") (1- from) to) "\n")))

(defun ac-chunk-string (text &optional boundary)
  (with-temp-buffer (insert text) (arc-chunk-buffer boundary)))

(defun ac-numbered-lines (n)
  (mapconcat (lambda (i) (format "line %03d of a paragraph with no break" i))
             (number-sequence 1 n) "\n"))

(ert-deftest ac-oversized-paragraph-splits-at-line-breaks-under-the-ceiling ()
  (let* ((arc-chunk-size-ceiling 200)
         (text (ac-numbered-lines 40))
         (chunks (ac-chunk-string text)))
    (should (> (length chunks) 1))
    (dolist (c chunks)
      (should (<= (length (plist-get c :text)) 200))
      ;; cut at a line break: the chunk is exactly the lines it cites
      (should (equal (plist-get c :text)
                     (ac-lines-of text (plist-get c :line-start) (plist-get c :line-end)))))
    ;; contiguous and complete: no line lost, none repeated
    (should (= (plist-get (car chunks) :line-start) 1))
    (should (= (plist-get (car (last chunks)) :line-end) 40))
    (cl-loop for (a b) on chunks while b
             do (should (= (1+ (plist-get a :line-end)) (plist-get b :line-start))))))

(ert-deftest ac-ceiling-applies-to-a-real-file ()
  "Through `arc-chunk-file', the `file' chunker's own entry point."
  (let ((arc-chunk-size-ceiling 200)
        (f (make-temp-file "arc-chunk-ceiling" nil ".txt" (ac-numbered-lines 40))))
    (unwind-protect
        (let ((chunks (arc-chunk-file f)))
          (should (> (length chunks) 1))
          (should (cl-every (lambda (c) (<= (length (plist-get c :text)) 200)) chunks)))
      (delete-file f))))

(ert-deftest ac-a-line-longer-than-the-ceiling-is-hard-split-losslessly ()
  "With no paragraph, line or space break, the last resort is a cut at
the ceiling itself; the pieces still concatenate to the original."
  (let* ((arc-chunk-size-ceiling 100)
         (text (make-string 350 ?x))
         (chunks (ac-chunk-string text)))
    (should (equal (mapcar (lambda (c) (length (plist-get c :text))) chunks)
                   '(100 100 100 50)))
    (should (equal (apply #'concat (mapcar (lambda (c) (plist-get c :text)) chunks)) text))
    (should (cl-every (lambda (c) (= 1 (plist-get c :line-start) (plist-get c :line-end)))
                      chunks))))

(ert-deftest ac-a-long-line-prefers-a-space-to-a-mid-word-cut ()
  (let* ((arc-chunk-size-ceiling 50)
         (text (mapconcat #'identity (make-list 30 "word") " "))
         (chunks (ac-chunk-string text)))
    (dolist (c chunks)
      (should (<= (length (plist-get c :text)) 50))
      (should (string-match-p "\\`\\(word\\)\\( word\\)*\\'" (plist-get c :text))))))

(ert-deftest ac-an-oversized-definition-splits-at-its-own-blank-lines-first ()
  "Boundary mode: one huge top-level form with paragraph breaks inside is
cut at a paragraph break, and keeps its real line numbers."
  (let* ((arc-chunk-size-ceiling 120)
         (para (lambda (tag) (mapconcat (lambda (i) (format "  ;; %s %d" tag i))
                                        (number-sequence 1 4) "\n")))
         (text (concat "(defun small () 1)\n"
                       "(defun big ()\n" (funcall para "alpha") "\n\n"
                       (funcall para "beta") "\n\n" (funcall para "gamma") ")\n"))
         (chunks (ac-chunk-string text "^(")))
    (should (equal (plist-get (car chunks) :text) "(defun small () 1)"))
    (dolist (c (cdr chunks))
      (should (<= (length (plist-get c :text)) 120))
      (should (equal (plist-get c :text)
                     (ac-lines-of text (plist-get c :line-start) (plist-get c :line-end))))
      ;; never two paragraphs' tags torn across a line
      (should-not (string-match-p "\\`[ \t]*\n\\|\n[ \t]*\\'" (plist-get c :text))))
    (should (= (plist-get (nth 1 chunks) :line-start) 2))
    (should (= (plist-get (car (last chunks)) :line-end) 16))))

(ert-deftest ac-line-start-skips-leading-blank-lines ()
  "Two blank lines between paragraphs used to leave the second chunk's
:line-start on the blank line; it names the first line of text now."
  (let ((chunks (ac-chunk-string "\n\nfirst\n\n\n\nsecond\n")))
    (should (equal (mapcar (lambda (c) (plist-get c :line-start)) chunks) '(3 7)))
    (should (equal (mapcar (lambda (c) (plist-get c :line-end)) chunks) '(3 7)))))

(ert-deftest ac-merge-target-nil-keeps-one-paragraph-per-chunk ()
  (should (= 3 (length (ac-chunk-string "a\n\nb\n\nc\n")))))

(ert-deftest ac-merge-target-joins-adjacent-small-paragraphs ()
  (let* ((arc-chunk-merge-target 12)
         ;; "aaaa\n\nbbbb" is 10 <= 12; adding "\n\ncccc" makes 16 > 12
         (chunks (ac-chunk-string "aaaa\n\nbbbb\n\ncccc\n\ndddd\n\n\n\neeeeeeeeeeeeeeeeeeee\n")))
    (should (equal (mapcar (lambda (c) (plist-get c :text)) chunks)
                   '("aaaa\n\nbbbb" "cccc\n\ndddd" "eeeeeeeeeeeeeeeeeeee")))
    (should (equal (mapcar (lambda (c) (list (plist-get c :line-start) (plist-get c :line-end)))
                           chunks)
                   '((1 3) (5 7) (11 11))))))

(ert-deftest ac-merge-target-is-capped-by-the-ceiling ()
  (let ((arc-chunk-merge-target 1000)
        (arc-chunk-size-ceiling 12))
    (dolist (c (ac-chunk-string "aaaa\n\nbbbb\n\ncccc\n\ndddd\n"))
      (should (<= (length (plist-get c :text)) 12)))))

(ert-deftest ac-merge-target-leaves-boundary-chunks-alone ()
  (let ((arc-chunk-merge-target 1000))
    (should (= 2 (length (ac-chunk-string "(defun a () 1)\n(defun b () 2)\n" "^("))))))

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

(ert-deftest act-a-text-file-named-like-an-archive-is-read-as-text ()
  "A plain-text file whose name ends `.tar.gz' must chunk as the text it
is: transparent decompression believed the name and signalled, which
aborted a whole collection's walk."
  (let* ((plain (make-temp-file "arc-chunk" nil ".txt" "not gzip"))
         (f (concat (file-name-sans-extension plain) ".tar.gz")))
    ;; Written under a plain name and renamed: writing to a `.gz' name
    ;; directly would have `jka-compr' really compress it.
    (rename-file plain f)
    (unwind-protect
        (progn
          (require 'jka-compr)
          (auto-compression-mode 1)
          (should (equal "not gzip" (plist-get (car (arc-chunk-file f)) :text))))
      (delete-file f))))
