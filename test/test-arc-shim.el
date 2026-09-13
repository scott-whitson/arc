;;; test-arc-shim.el --- the CLI shim -*- lexical-binding: t; -*-

;;; Commentary:

;; The shim is shell, not elisp, so these tests cover only what is safe and
;; daemon-independent: that it exists and is executable, that it rejects bad
;; input before ever touching emacsclient, and that a dead socket is reported
;; as exit 2 rather than some emacsclient-specific noise.
;;
;; `usage' and `die' both write to stderr, so any test that asserts on
;; message text runs the child with destination `(t t)' -- stdout and
;; stderr both into the current buffer -- or the buffer would be empty and
;; a correct shim would fail the assertion anyway.
;;
;; None of this touches the operator's real daemon. The happy path (search,
;; scopes, stats against a live socket) is exercised manually against a
;; throwaway daemon, per Task 8's brief.

;;; Code:

(require 'ert)

(defvar ash-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))

(defvar ash-shim (expand-file-name "bin/arc" ash-root))

(ert-deftest ash-shim-exists-and-is-executable ()
  (should (file-exists-p ash-shim))
  (should (file-executable-p ash-shim)))

(ert-deftest ash-shim-rejects-an-unknown-subcommand ()
  (with-temp-buffer
    (should (= (call-process ash-shim nil '(t t) nil "frobnicate") 1))))

(ert-deftest ash-shim-with-no-arguments-prints-usage ()
  (with-temp-buffer
    (let ((status (call-process ash-shim nil '(t t) nil)))
      (should (= status 1))
      (should (string-match-p "usage" (downcase (buffer-string)))))))

(ert-deftest ash-shim-reports-a-dead-socket-as-exit-2 ()
  "A socket that cannot exist, forced via EMACS_SOCKET_NAME, must never
reach the operator's real daemon -- so this is the only path this suite
takes through `stats', and it takes it against a name nothing binds."
  (let* ((process-environment
          (cons "EMACS_SOCKET_NAME=/nonexistent/arc-no-such-socket"
                process-environment)))
    (with-temp-buffer
      (let ((status (call-process ash-shim nil '(t t) nil "stats")))
        (should (= status 2))
        (should (string-match-p "daemon not running" (buffer-string)))))))

(provide 'test-arc-shim)
;;; test-arc-shim.el ends here
