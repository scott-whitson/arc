;;; test-arc-text-file-noninteractive.el --- arc--text-file-p never prompts -*- lexical-binding: t; -*-
;;
;; A corpus walk over $HOME died three times with `(end-of-file "Error
;; reading from stdin")', once right after printing `Select coding
;; system (default raw-text):'.  That is `find-file-noselect' resolving
;; a coding system interactively when its own detection is not
;; confident enough to pick one silently: in batch Emacs the resulting
;; minibuffer read hits a stdin nothing is attached to and dies exactly
;; that way (reproduced directly below against `y-or-n-p', to pin the
;; mechanism, not just the symptom); in the operator's live daemon it
;; would instead block the whole session on a modal prompt mid-run.
;;
;; `arc--text-file-p' no longer calls `find-file-noselect' at all -- it
;; reads a bounded prefix via `insert-file-contents' with
;; `coding-system-for-read' pinned to `utf-8', which removes the
;; detection step that could ever ask anyone anything, and wraps the
;; read in `ignore-errors' so one bad file can never abort a walk.
;;
;; Multiple attempts to synthesize content that reproduces the actual
;; interactive prompt under this Emacs (mixed high bytes, UTF-16
;; without a BOM, Shift-JIS, and literal ISO-2022 designation escapes)
;; all resolved silently under `find-file-noselect' here -- the exact
;; trigger is content- and possibly version-dependent and was not
;; reproduced.  `att-no-prompt-on-provocative-content' below tests the
;; guarantee directly instead of faking a reproduction: it advises
;; `find-file-noselect' and `read-coding-system' to signal loudly if
;; either is ever called, then runs `arc--text-file-p' over every one
;; of those fixtures.  If a future change reintroduces a route through
;; either function, this test fails immediately regardless of whether
;; the specific content that provoked the original prompt is in hand.
(require 'ert)
(defvar atn-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path atn-root)
(require 'arc-source-file)

(defmacro atn-with-temp-file (var content &rest body)
  "Bind VAR to a temp file holding raw bytes CONTENT for BODY, then delete it."
  (declare (indent 2))
  `(let ((,var (make-temp-file "arc-noninteractive")))
     (unwind-protect
         (progn
           (let ((coding-system-for-write 'no-conversion))
             (write-region ,content nil ,var))
           ,@body)
       (delete-file ,var))))

;;; --- The two ordinary verdicts, pinned again for this rewrite ------

(ert-deftest atn-ordinary-text-file-is-text ()
  (atn-with-temp-file f "an ordinary short text file\nwith two lines\n"
    (should (arc--text-file-p f))))

(ert-deftest atn-null-byte-is-not-text ()
  (atn-with-temp-file f (unibyte-string ?a ?b ?\0 ?c)
    (should-not (arc--text-file-p f))))

(ert-deftest atn-undecodable-bytes-are-not-text ()
  "Bytes that are not valid UTF-8 decode to raw-byte `eight-bit'
characters and must be excluded exactly like a null-byte binary --
this is the check the docstring's real indexing crash exists for."
  (atn-with-temp-file f (unibyte-string ?\x81 ?\x82 ?\xfe ?\xff)
    (should-not (arc--text-file-p f))))

;;; --- Error safety: one bad file must never signal -------------------

(ert-deftest atn-unreadable-file-returns-nil-not-signal ()
  "A file this process cannot read (permissions) must come back nil,
not raise -- one unreadable file must never abort a whole directory
walk (`arc--file-list' calls this on every candidate in sequence)."
  (skip-unless (not (zerop (user-uid)))) ; root can read anything; this
                                          ; test is meaningless as root
  (atn-with-temp-file f "content that would otherwise read as text\n"
    (set-file-modes f #o000)
    (unwind-protect
        (should (eq nil (arc--text-file-p f)))
      (set-file-modes f #o600))))

;;; --- Never prompt: structural guarantee, not a reproduced prompt ---

(defmacro atn-forbidding (fns &rest body)
  "Run BODY with each function in FNS advised to signal if called.
Used to prove `arc--text-file-p' cannot reach any of the interactive
machinery that used to raise `Select coding system' -- if it can no
longer even call `find-file-noselect' or `read-coding-system', it
cannot prompt through them, independent of whether any specific
fixture here happens to reproduce the original prompt."
  (declare (indent 1))
  `(let ((probes nil))
     (unwind-protect
         (progn
           (dolist (fn ,fns)
             (let ((probe (lambda (&rest args)
                            (error "forbidden function called: %S %S" fn args))))
               (push (cons fn probe) probes)
               (advice-add fn :before probe)))
           ,@body)
       (dolist (cell probes)
         (advice-remove (car cell) (cdr cell))))))

(ert-deftest atn-y-or-n-p-eofs-in-batch-confirming-the-failure-mechanism ()
  "Pins the mechanism the bug report described: in batch Emacs, any
function that tries to read a yes/no or coding-system answer from the
minibuffer reads from stdin, and with nothing attached to stdin that
is `(end-of-file \"Error reading from stdin\")' -- not a hang, not a
silent default.  This is what made the original crash look like an
unrelated stdin error far from `arc--text-file-p'."
  (skip-unless noninteractive)
  (should-error (y-or-n-p "does this eof in batch? ") :type 'end-of-file))

(ert-deftest atn-no-prompt-on-provocative-content ()
  "None of these fixtures may reach `find-file-noselect' or
`read-coding-system' -- the two functions capable of raising the
interactive coding-system prompt this task exists to remove."
  (atn-forbidding '(find-file-noselect read-coding-system)
    (dolist (bytes
             (list
              ;; mixed high bytes with no null byte
              (unibyte-string ?h ?i ?\x81 ?\x8d ?\x8f ?\x90 ?\x9d ?\n)
              ;; UTF-16LE text with no BOM -- plentiful embedded nulls
              (encode-coding-string "hello world, no bom here\n" 'utf-16le)
              ;; Shift-JIS encoded Japanese text
              (encode-coding-string "これはテストです。\n" 'japanese-shift-jis)
              ;; literal ISO-2022 designation escapes, never resolved
              (concat "plain text before\n"
                      "\x1b$(C" "\x30\x30" "\x1b$(D" "\x30\x30" "\x1b(B"
                      "\ntext after\n")))
      (atn-with-temp-file f bytes
        ;; The call must return a plain t/nil verdict, not signal --
        ;; the advice above would turn a forbidden call into an error,
        ;; and `should' below would then fail loudly with which one.
        (should (memq (arc--text-file-p f) '(nil t)))))))

;;; --- Bounded read: the documented tradeoff really holds -------------

(ert-deftest atn-probe-size-bounds-the-read ()
  "A null byte past `arc-text-file-probe-size' must not be seen -- the
docstring's stated tradeoff (text-then-binary is admitted as text) is
this test, made concrete."
  (let ((arc-text-file-probe-size 8))
    (atn-with-temp-file f (concat (make-string 8 ?a) (unibyte-string ?\0))
      (should (arc--text-file-p f)))))

(ert-deftest atn-probe-size-still-catches-a-null-byte-inside-it ()
  (let ((arc-text-file-probe-size 8))
    (atn-with-temp-file f (concat (make-string 4 ?a) (unibyte-string ?\0)
                                   (make-string 3 ?a))
      (should-not (arc--text-file-p f)))))

(provide 'test-arc-text-file-noninteractive)
;;; test-arc-text-file-noninteractive.el ends here
