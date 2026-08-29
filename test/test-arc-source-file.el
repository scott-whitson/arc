;;; test-arc-source-file.el --- file walking and change detection -*- lexical-binding: t; -*-
(require 'ert)
(defvar asf-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asf-root)
(require 'arc-source-file)

(defmacro asf-with-tree (&rest body)
  "Run BODY with `dir' bound to a temporary tree containing two files."
  `(let ((dir (make-temp-file "arc-tree" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "a.nix" dir) (insert "{ x = 1; }\n"))
           (with-temp-file (expand-file-name "b.txt" dir) (insert "hello\n\nworld\n"))
           (with-temp-file (expand-file-name ".ignore" dir) (insert "b.txt\n"))
           ,@body)
       (delete-directory dir t))))

(ert-deftest asf-walks-text-files ()
  (asf-with-tree
   (let ((paths (mapcar (lambda (s) (file-name-nondirectory (plist-get s :path)))
                        (arc-file-sources dir))))
     (should (member "a.nix" paths)))))

(ert-deftest asf-honours-ignore-files ()
  (asf-with-tree
   (let ((paths (mapcar (lambda (s) (file-name-nondirectory (plist-get s :path)))
                        (arc-file-sources dir))))
     (should-not (member "b.txt" paths)))))

(ert-deftest asf-sources-carry-chunks-and-hash ()
  (asf-with-tree
   (let ((s (car (arc-file-sources dir))))
     (should (stringp (plist-get s :hash)))
     (should (consp (plist-get s :chunks)))
     (should (plist-get (car (plist-get s :chunks)) :line-start)))))

(ert-deftest asf-hash-changes-with-content ()
  (asf-with-tree
   (let ((h1 (plist-get (car (arc-file-sources dir)) :hash)))
     (with-temp-file (expand-file-name "a.nix" dir) (insert "{ x = 2; }\n"))
     (should-not (equal h1 (plist-get (car (arc-file-sources dir)) :hash))))))

;;; --- Fix round 1: ordinary gitignore pattern shapes -----------------
;; A trailing-slash directory, a bare name (path-component matching, not
;; whole-relative-path matching), and a leading-slash anchor were all
;; silently inert before this fix -- discovered on ~/dotfiles' real
;; .gitignore, which uses all three (`.claude/', `result', and -- had it
;; been present -- a leading-slash pattern).  These tests are written
;; against `arc-file-sources' end to end, not just the regexp helper, and
;; each shape gets both a case that must be excluded and a nearby case
;; that must NOT be -- over-exclusion is exactly as damaging as the
;; original under-exclusion bug and much harder to notice.

(defmacro asf-with-gitignore-tree (&rest body)
  "Run BODY with `dir' bound to a tree exercising the three gitignore
pattern shapes this fix adds: a trailing-slash directory (`foo/'), a
bare name matched as a path component at any depth (`result'), and a
root-anchored leading slash (`/anchored')."
  `(let ((dir (make-temp-file "arc-gitignore-tree" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name ".gitignore" dir)
             (insert "# a comment, and a blank line above and below\n\n"
                     "result\n"
                     "foo/\n"
                     "/anchored\n"))
           (with-temp-file (expand-file-name "result" dir) (insert "top-level result\n"))
           (with-temp-file (expand-file-name "results.nix" dir) (insert "not the pattern\n"))
           (make-directory (expand-file-name "src" dir))
           (with-temp-file (expand-file-name "src/result-handler.el" dir) (insert "kept\n"))
           (make-directory (expand-file-name "sub" dir))
           (with-temp-file (expand-file-name "sub/result" dir) (insert "nested result\n"))
           (with-temp-file (expand-file-name "sub/foo" dir) (insert "a FILE named foo, not a dir\n"))
           (make-directory (expand-file-name "foo" dir))
           (with-temp-file (expand-file-name "foo/inside.txt" dir) (insert "under foo/\n"))
           (make-directory (expand-file-name "notfoo" dir))
           (with-temp-file (expand-file-name "notfoo/inside.txt" dir) (insert "kept\n"))
           (with-temp-file (expand-file-name "anchored" dir) (insert "root-level anchored\n"))
           (with-temp-file (expand-file-name "sub/anchored" dir) (insert "nested, same leaf name\n"))
           ,@body)
       (delete-directory dir t))))

(defun asf-relative-paths (dir)
  "Return the file-relative-name of every source `arc-file-sources' finds in DIR."
  (mapcar (lambda (s) (file-relative-name (plist-get s :path) dir))
          (arc-file-sources dir)))

(ert-deftest asf-bare-name-excludes-top-level-match ()
  (asf-with-gitignore-tree
   (should-not (member "result" (asf-relative-paths dir)))))

(ert-deftest asf-bare-name-excludes-nested-match ()
  "A bare name with no slash matches as a path component at ANY depth."
  (asf-with-gitignore-tree
   (should-not (member "sub/result" (asf-relative-paths dir)))))

(ert-deftest asf-bare-name-does-not-over-exclude-similar-names ()
  "`result' must not exclude `results.nix' or `src/result-handler.el'."
  (asf-with-gitignore-tree
   (let ((paths (asf-relative-paths dir)))
     (should (member "results.nix" paths))
     (should (member "src/result-handler.el" paths)))))

(ert-deftest asf-directory-pattern-excludes-everything-beneath ()
  (asf-with-gitignore-tree
   (should-not (member "foo/inside.txt" (asf-relative-paths dir)))))

(ert-deftest asf-directory-pattern-does-not-exclude-a-file-of-the-same-name ()
  "`foo/' must not exclude a plain FILE named `foo' with nothing beneath it."
  (asf-with-gitignore-tree
   (should (member "sub/foo" (asf-relative-paths dir)))))

(ert-deftest asf-directory-pattern-does-not-over-exclude-a-different-directory ()
  (asf-with-gitignore-tree
   (should (member "notfoo/inside.txt" (asf-relative-paths dir)))))

(ert-deftest asf-leading-slash-anchors-to-the-walked-directory ()
  (asf-with-gitignore-tree
   (should-not (member "anchored" (asf-relative-paths dir)))))

(ert-deftest asf-leading-slash-does-not-exclude-a-nested-same-name-file ()
  "`/anchored' is anchored to DIRECTORY itself; a nested file with the
same leaf name is a different path and must be kept."
  (asf-with-gitignore-tree
   (should (member "sub/anchored" (asf-relative-paths dir)))))

(ert-deftest asf-comment-and-blank-lines-are-not-patterns ()
  "The `#'-comment and blank line in the fixture's `.gitignore' must not
themselves exclude anything, nor cause a parse error."
  (asf-with-gitignore-tree
   (should (arc-file-sources dir))))

(ert-deftest asf-interior-slash-pattern-still-works ()
  "Regression: a pattern with an interior, non-leading slash (the
existing `keys/*_host_ed25519' shape from Task 10) is untouched by
this fix -- it still matches the whole relative path exactly."
  (let ((dir (make-temp-file "arc-keys-tree" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "keys" dir))
          (with-temp-file (expand-file-name "keys/rafik_host_ed25519" dir) (insert "secret\n"))
          (with-temp-file (expand-file-name "keys/rafik_host_ed25519.pub" dir) (insert "public\n"))
          (with-temp-file (expand-file-name ".gitignore" dir) (insert "keys/*_host_ed25519\n"))
          (let ((paths (asf-relative-paths dir)))
            (should-not (member "keys/rafik_host_ed25519" paths))
            (should (member "keys/rafik_host_ed25519.pub" paths))))
      (delete-directory dir t))))

;;; --- Fix round 2: undecodable content excludes a file, even with no
;;; null byte -- discovered indexing a real agenix `.age' secret. ------

(ert-deftest asf-undecodable-content-is-excluded-even-without-a-null-byte ()
  "An agenix `.age' secret's ciphertext payload has no null byte, but is
never valid UTF-8; it must be excluded exactly like a null-byte binary
file, not chunked and handed to the embeddings API where it crashed
the whole indexing run when this was still a bug."
  (let ((dir (make-temp-file "arc-binary-tree" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.nix" dir) (insert "{ x = 1; }\n"))
          (let ((coding-system-for-write 'no-conversion))
            (write-region (unibyte-string ?\x81 ?\x82 ?\xfe ?\xff)
                          nil (expand-file-name "secret.age" dir)))
          (let ((paths (mapcar (lambda (s) (file-name-nondirectory (plist-get s :path)))
                                (arc-file-sources dir))))
            (should (member "a.nix" paths))
            (should-not (member "secret.age" paths))))
      (delete-directory dir t))))

(ert-deftest asf-text-file-p-rejects-undecodable-bytes-directly ()
  (let ((f (make-temp-file "arc-binary")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region (unibyte-string ?\x81 ?\x82 ?\xfe ?\xff) nil f))
          (should-not (arc--text-file-p f)))
      (delete-file f))))
