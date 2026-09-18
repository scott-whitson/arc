;;; test-arc-size-guard.el --- the file-size ceiling on arc--text-file-p -*- lexical-binding: t; -*-
;;
;; Widening the corpus to all of `home' put real video files, disk
;; images and other huge binaries within `arc--file-list''s reach for
;; the first time. `arc--text-file-p' used to check `file-attributes'
;; nowhere: it opened every candidate with `find-file-noselect' first
;; and asked what it was afterwards, which meant fully decoding a 234
;; MB `.mkv' into a buffer just to conclude "binary" -- measured at
;; 20+ minutes on one host. `arc-text-file-size-ceiling' is checked
;; before any read; these tests are about THAT ordering, not about
;; the content heuristic below it, which is already covered by
;; test-arc-source-file.el and is deliberately left untouched.
(require 'ert)
(defvar asg-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path asg-root)
(require 'arc-source-file)

(defmacro asg-with-ceiling (bytes &rest body)
  "Run BODY with `arc-text-file-size-ceiling' bound to BYTES."
  (declare (indent 1))
  `(let ((arc-text-file-size-ceiling ,bytes))
     ,@body))

(defmacro asg-with-temp-file (var content &rest body)
  "Bind VAR to a temp file holding CONTENT (a string) for BODY, then delete it."
  (declare (indent 2))
  `(let ((,var (make-temp-file "arc-size-guard")))
     (unwind-protect
         (progn
           (let ((coding-system-for-write 'no-conversion))
             (write-region ,content nil ,var))
           ,@body)
       (delete-file ,var))))

;;; --- Below the ceiling: unchanged content-based classification -----

(ert-deftest asg-under-ceiling-text-content-still-classified-as-text ()
  (asg-with-ceiling 1000
    (asg-with-temp-file f "just an ordinary short text file\n"
      (should (arc--text-file-p f)))))

(ert-deftest asg-under-ceiling-binary-content-still-classified-as-binary ()
  "A null byte well under the ceiling must still fail exactly as before --
the guard must not change classification for anything it lets through."
  (asg-with-ceiling 1000
    (asg-with-temp-file f (unibyte-string ?a ?b ?\0 ?c)
      (should-not (arc--text-file-p f)))))

;;; --- At/above the ceiling: skipped, unread -------------------------

(ert-deftest asg-over-ceiling-zeros-are-skipped-without-being-read ()
  "A temp file of zeros above the ceiling is binary either way (it has a
null byte), but the point of this test is that classification never
gets that far: `find-file-noselect' must not be called at all once
`file-attributes' alone says the file is too large."
  (asg-with-ceiling 512
    (asg-with-temp-file f (make-string 1024 ?\0)
      (let* ((read-attempted nil)
             (probe (lambda (&rest args)
                      (when (equal (car args) f) (setq read-attempted t)))))
        (advice-add 'find-file-noselect :before probe)
        (unwind-protect
            (progn
              (should-not (arc--text-file-p f))
              (should-not read-attempted))
          (advice-remove 'find-file-noselect probe))))))

(ert-deftest asg-guard-fires-on-size-alone-not-on-content ()
  "An oversized file that is ENTIRELY valid, plain ASCII text -- content
that would sail through the null-byte/undecodable-byte heuristic if it
were ever read -- must still be excluded once it crosses the ceiling.
This is what distinguishes the guard from the existing content check:
size alone decides here, not what is inside the file."
  (asg-with-ceiling 512
    (asg-with-temp-file f (make-string 1024 ?a) ; 1024 bytes of plain "a"
      (let* ((read-attempted nil)
             (probe (lambda (&rest args)
                      (when (equal (car args) f) (setq read-attempted t)))))
        (advice-add 'find-file-noselect :before probe)
        (unwind-protect
            (progn
              (should-not (arc--text-file-p f))
              (should-not read-attempted))
          (advice-remove 'find-file-noselect probe))))))

(ert-deftest asg-file-exactly-at-ceiling-is-not-skipped-by-size ()
  "The ceiling is a maximum, not an exclusive bound: a file whose size
equals it exactly must still reach the content check (and pass, since
its content here is plain text)."
  (asg-with-ceiling 32
    (asg-with-temp-file f (make-string 32 ?a)
      (should (arc--text-file-p f)))))

(ert-deftest asg-default-ceiling-is-ten-megabytes ()
  (should (= arc-text-file-size-ceiling (* 10 1024 1024))))

(provide 'test-arc-size-guard)
;;; test-arc-size-guard.el ends here
