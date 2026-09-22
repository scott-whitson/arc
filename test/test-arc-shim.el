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

;; A trailing option with no value must be rejected before the argument
;; loop ever loops back around on it. The shim's loop shifts two
;; arguments per flag, has no `set -e', and a `shift 2' with only one
;; positional left fails and shifts NOTHING -- so `$#' never decreases
;; and `while [ $# -gt 0 ]' spins at 100% CPU forever. `timeout' wraps
;; every invocation here (rather than bare `call-process') specifically
;; so that a regression reintroducing that bug fails this test loudly
;; and fast -- exit 124 -- instead of wedging the whole ERT run.

(defconst ash-shim-hang-guard-seconds "5"
  "Wall-clock ceiling for a shim invocation in this suite.
Generous enough that a correct, fast-failing shim never trips it, but
short enough that a hung one does not stall the test run.")

(defun ash-shim-call (args)
  "Run the shim with ARGS under `ash-shim-hang-guard-seconds', via `timeout'.
Return (STATUS . OUTPUT), OUTPUT being combined stdout+stderr."
  (with-temp-buffer
    (let ((status (apply #'call-process "timeout" nil '(t t) nil
                          ash-shim-hang-guard-seconds ash-shim args)))
      (cons status (buffer-string)))))

(ert-deftest ash-shim-does-not-hang-on-a-trailing---scope-with-no-value ()
  (let ((result (ash-shim-call '("search" "foo" "--scope"))))
    (should (/= (car result) 124))
    (should (= (car result) 1))
    (should (string-match-p "needs a value" (cdr result)))))

(ert-deftest ash-shim-does-not-hang-on-a-trailing---limit-with-no-value ()
  (let ((result (ash-shim-call '("search" "foo" "--limit"))))
    (should (/= (car result) 124))
    (should (= (car result) 1))
    (should (string-match-p "needs a value" (cdr result)))))

(ert-deftest ash-shim-does-not-hang-on-a-trailing---arm-with-no-value ()
  (let ((result (ash-shim-call '("search" "foo" "--arm"))))
    (should (/= (car result) 124))
    (should (= (car result) 1))
    (should (string-match-p "needs a value" (cdr result)))))

;; Minor 8: `--limit' and `--arm' are interpolated straight into an
;; elisp form (unlike `--scope' and the query, which go through
;; `elisp_string'), so a malformed value must be rejected here rather
;; than reaching the daemon as `void-variable' or, worse, an arbitrary
;; form to evaluate.

(ert-deftest ash-shim-rejects-a-non-numeric-preview-source-id ()
  (let ((result (ash-shim-call '("preview" "abc"))))
    (should (= (car result) 1))
    (should (string-match-p "positive integer SOURCE_ID" (cdr result)))))

(ert-deftest ash-shim-rejects-zero-preview-source-id ()
  (let ((result (ash-shim-call '("preview" "0"))))
    (should (= (car result) 1))
    (should (string-match-p "positive integer SOURCE_ID" (cdr result)))))

(ert-deftest ash-shim-rejects-a-non-numeric---limit ()
  (let ((result (ash-shim-call '("search" "foo" "--limit" "abc"))))
    (should (= (car result) 1))
    (should (string-match-p "positive integer" (cdr result)))))

(ert-deftest ash-shim-rejects-a-zero---limit ()
  (let ((result (ash-shim-call '("search" "foo" "--limit" "0"))))
    (should (= (car result) 1))
    (should (string-match-p "positive integer" (cdr result)))))

(ert-deftest ash-shim-rejects-a-negative---limit ()
  (let ((result (ash-shim-call '("search" "foo" "--limit" "-1"))))
    (should (= (car result) 1))
    (should (string-match-p "positive integer" (cdr result)))))

(ert-deftest ash-shim-rejects-an-elisp-form-as---limit ()
  (let ((result (ash-shim-call '("search" "foo" "--limit" "(shell-command \"true\")"))))
    (should (= (car result) 1))
    (should (string-match-p "positive integer" (cdr result)))))

(ert-deftest ash-shim-rejects-an-unrecognised---arm ()
  (let ((result (ash-shim-call '("search" "foo" "--arm" "bogus"))))
    (should (= (car result) 1))
    (should (string-match-p "keyword.*fused\\|fused.*keyword" (cdr result)))))

;; `--path-prefix' compiles to a LIKE against the absolute `sources.path'
;; column, so a relative prefix can only ever match nothing -- silently, and
;; indistinguishably from a prefix whose documents genuinely do not exist.
;; Rejecting it at parse time is the difference between a caller learning
;; their mistake and a caller concluding the corpus lacks the document.

(ert-deftest ash-shim-rejects-a-relative---path-prefix ()
  (let ((result (ash-shim-call '("search" "foo" "--path-prefix" "docs/org"))))
    (should (= (car result) 1))
    (should (string-match-p "absolute" (cdr result)))))

(ert-deftest ash-shim-accepts-an-absolute---path-prefix ()
  "An absolute prefix must survive validation and reach the daemon stage.
The socket is forced dead so this never touches the operator's real
daemon: exit 2 is itself the proof, since a rejected prefix would have
exited 1 before any `emacsclient' call was made."
  (let* ((process-environment
          (cons "EMACS_SOCKET_NAME=/nonexistent/arc-no-such-socket"
                process-environment))
         (result (ash-shim-call '("search" "foo" "--path-prefix" "/tmp"))))
    (should (= (car result) 2))
    (should (string-match-p "daemon not running" (cdr result)))))

;; Important 4: the shim must not misreport a genuine Lisp error signalled
;; by the daemon as a dead daemon. `case' patterns are unanchored and
;; first-match-wins in shell, so an unanchored `*"could not"*' branch can
;; shadow the `*ERROR*' branch for a message like "arc: could not open
;; database" (both `arc-index.el' and `arc-watch.el' emit exactly that
;; shape of text). These two tests stand in for a live daemon with a fake
;; `emacsclient' on PATH, so they run without one and without touching
;; the operator's real socket.

(defun ash-shim-with-fake-emacsclient (output status args)
  "Run the shim with ARGS against a stub `emacsclient' that prints OUTPUT
and exits STATUS, prepended onto PATH for the duration."
  (let* ((dir (make-temp-file "ash-fake-emacsclient" t))
         (stub (expand-file-name "emacsclient" dir)))
    (unwind-protect
        (progn
          (with-temp-file stub
            (insert (format "#!/usr/bin/env bash\nprintf '%%s' %s >&2\nexit %d\n"
                            (shell-quote-argument output) status)))
          (set-file-modes stub #o755)
          (let ((process-environment
                 (cons (format "PATH=%s:%s" dir (getenv "PATH"))
                       process-environment)))
            (with-temp-buffer
              (let ((status (apply #'call-process ash-shim nil '(t t) nil args)))
                (cons status (buffer-string))))))
      (delete-directory dir t))))

(defun ash-shim-with-fake-emacsclient-output (output status args)
  "Run the shim against a stub that writes successful OUTPUT to stdout.
OUTPUT is the quoted elisp string `emacsclient -e' would print."
  (let* ((dir (make-temp-file "ash-fake-emacsclient-output" t))
         (stub (expand-file-name "emacsclient" dir)))
    (unwind-protect
        (progn
          (with-temp-file stub
            (insert (format "#!/usr/bin/env bash\nprintf '%%s' %s\nexit %d\n"
                            (shell-quote-argument output) status)))
          (set-file-modes stub #o755)
          (let ((process-environment
                 (cons (format "PATH=%s:%s" dir (getenv "PATH"))
                       process-environment)))
            (with-temp-buffer
              (let ((status (apply #'call-process ash-shim nil '(t t) nil args)))
                (cons status (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest ash-shim-rejects-an-invalid---kind-before-transport ()
  (let ((result (ash-shim-call '("search" "foo" "--kind" "bogus"))))
    (should (= (car result) 1))
    (should (string-match-p "--kind" (cdr result)))))

(ert-deftest ash-shim-rejects-a-duplicate---path-prefix ()
  (let ((result (ash-shim-call '("search" "foo" "--path-prefix" "/a"
                                "--path-prefix" "/b"))))
    (should (= (car result) 1))
    (should (string-match-p "only once" (cdr result)))))

(ert-deftest ash-shim-transports-typed-filter-options ()
  "The parser accepts repeatable filters and safely builds the daemon form."
  (let ((result (ash-shim-with-fake-emacsclient-output
                 "\"{}\"" 0
                 '("search" "foo" "--scope" "everything"
                   "--collection" "vault" "--collection" "home"
                   "--kind" "file" "--tag" "work"
                   "--path-prefix" "/home/" "--json"))))
    (should (= (car result) 0))
    (should (equal (string-trim (cdr result)) "{}"))))

(ert-deftest ash-shim-lifecycle-successfully-transports-json ()
  "The lifecycle command unwraps daemon JSON without changing its exit code."
  (let ((result (ash-shim-with-fake-emacsclient-output
                 "\"{\\\"read_only\\\":true}\""
                 0 '("lifecycle" "--limit" "3" "--json"))))
    (should (= (car result) 0))
    (should (equal (string-trim (cdr result))
                   "{\"read_only\":true}"))))

(ert-deftest ash-shim-lifecycle-rejects-zero-limit ()
  (let ((result (ash-shim-call '("lifecycle" "--limit" "0"))))
    (should (= (car result) 1))
    (should (string-match-p "positive integer" (cdr result)))))

(ert-deftest ash-shim-preview-successfully-transports-json ()
  "The happy preview path unwraps emacsclient's quoted string output."
  (let ((result (ash-shim-with-fake-emacsclient-output
                 "\"{\\\"source_id\\\":7,\\\"passages\\\":[]}\""
                 0 '("preview" "7" "--json"))))
    (should (= (car result) 0))
    (should (equal (string-trim (cdr result))
                   "{\"source_id\":7,\"passages\":[]}"))))

(ert-deftest ash-shim-mcp-reads-newline-delimited-json-rpc ()
  "The MCP loop emits one response per non-empty input line and no logs.
A fake emacsclient stands in for the daemon; the real protocol dispatcher is
covered by `test-arc-tool.el'."
  (let* ((dir (make-temp-file "ash-fake-mcp-emacsclient" t))
         (stub (expand-file-name "emacsclient" dir))
         (input (make-temp-file "ash-mcp-input"))
         (output ""))
    (unwind-protect
        (progn
          (with-temp-file stub
            (insert "#!/usr/bin/env bash\nprintf '%s\\n' '\"{}\"'\n"))
          (set-file-modes stub #o755)
          (let ((process-environment
                 (cons (format "PATH=%s:%s" dir (getenv "PATH"))
                       process-environment)))
            (with-temp-buffer
              (insert "{\"jsonrpc\":\"2.0\",\"id\":1}\n")
              (should (= (call-process-region (point-min) (point-max)
                                               ash-shim t '(t t) nil "mcp")
                          0))
              (setq output (buffer-string))))
          (should (= (length (split-string (string-trim output) "\\n" t)) 1))
          (should-not (string-match-p "Error:" output)))
      (when (file-exists-p input) (delete-file input))
      (delete-directory dir t))))

(ert-deftest ash-shim-mcp-suppresses-all-notification-lines-and-keeps-reading ()
  "Notifications must not leak `nil' or stop the persistent stdio loop."
  (let* ((dir (make-temp-file "ash-fake-mcp-notifications" t))
         (stub (expand-file-name "emacsclient" dir))
         (count (expand-file-name "count" dir))
         (output ""))
    (unwind-protect
        (progn
          (with-temp-file stub
            (insert "#!/usr/bin/env bash\n"
                    "n=0\n"
                    "if [ -f \"" count "\" ]; then n=$(cat \"" count "\"); fi\n"
                    "n=$((n + 1))\n"
                    "printf '%s' \"$n\" > \"" count "\"\n"
                    "if [ \"$n\" -lt 3 ]; then printf '%s\\n' '\"\"'; "
                    "else printf '%s\\n' '\"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":9,\\\"result\\\":{}}\"'; fi\n"))
          (set-file-modes stub #o755)
          (let ((process-environment
                 (cons (format "PATH=%s:%s" dir (getenv "PATH"))
                       process-environment)))
            (with-temp-buffer
              (insert "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
                      "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n")
              (should (= (call-process-region (point-min) (point-max)
                                               ash-shim t '(t t) nil "mcp")
                          0))
              (setq output (buffer-string))))
          (should (equal (string-trim output)
                         "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}"))
          (should-not (string-match-p "nil" output)))
      (delete-directory dir t))))

(ert-deftest ash-shim-mcp-keeps-line-order-across-invalid-and-valid-json-rpc ()
  "The real stdio loop emits one JSON response per input and continues after errors.
The fake daemon returns the responses in invocation order: the dispatcher
coverage in `test-arc-tool.el' pins which input maps to each error, while this
pins the shell transport's line-by-line continuation and ordering."
  (let* ((dir (make-temp-file "ash-fake-mcp-errors" t))
         (stub (expand-file-name "emacsclient" dir))
         (output ""))
    (unwind-protect
        (progn
          (with-temp-file stub
            (insert "#!/usr/bin/env python3\n"
                    "import json, os\n"
                    "count = os.path.join(" (prin1-to-string dir) ", 'count')\n"
                    "try:\n"
                    "    n = int(open(count).read())\n"
                    "except FileNotFoundError:\n"
                    "    n = 0\n"
                    "n += 1\n"
                    "open(count, 'w').write(str(n))\n"
                    "responses = [\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700}},\n"
                    "    {'jsonrpc': '2.0', 'id': 6, 'result': {'ok': True}},\n"
                    "]\n"
                    "print(json.dumps(json.dumps(responses[n - 1], separators=(',', ':'))))\n"))
          (set-file-modes stub #o755)
          (let ((process-environment
                 (cons (format "PATH=%s:%s" dir (getenv "PATH"))
                       process-environment)))
            (with-temp-buffer
              (insert "[]\n"
                      "[\"x\"]\n"
                      "null\n"
                      "{\"jsonrpc\":\"2.0\"}\n"
                      "not-json\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ping\"}\n")
              (should (= (call-process-region (point-min) (point-max)
                                               ash-shim t '(t t) nil "mcp")
                          0))
              (setq output (buffer-string))))
          (should (equal (split-string (string-trim output) "\n" t)
                         '("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"ok\":true}}")))
          (should-not (string-match-p "nil" output)))
      (delete-directory dir t))))

(ert-deftest ash-shim-mcp-continues-after-invalid-id-and-params-shapes ()
  "The stdio loop preserves ordering across invalid requests and a valid one."
  (let* ((dir (make-temp-file "ash-fake-mcp-shapes" t))
         (stub (expand-file-name "emacsclient" dir))
         (output ""))
    (unwind-protect
        (progn
          (with-temp-file stub
            (insert "#!/usr/bin/env python3\n"
                    "import json, os\n"
                    "count = os.path.join(" (prin1-to-string dir) ", 'count')\n"
                    "try:\n"
                    "    n = int(open(count).read())\n"
                    "except FileNotFoundError:\n"
                    "    n = 0\n"
                    "n += 1\n"
                    "open(count, 'w').write(str(n))\n"
                    "responses = [\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': 4, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': 5, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': 6, 'error': {'code': -32600}},\n"
                    "    {'jsonrpc': '2.0', 'id': 7, 'result': {}}\n"
                    "]\n"
                    "print(json.dumps(json.dumps(responses[n - 1], separators=(',', ':'))))\n"))
          (set-file-modes stub #o755)
          (let ((process-environment
                 (cons (format "PATH=%s:%s" dir (getenv "PATH"))
                       process-environment)))
            (with-temp-buffer
              (insert "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":[],\"method\":\"ping\"}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\",\"params\":null}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\",\"params\":false}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ping\",\"params\":0}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\",\"params\":[]}\n")
              (should (= (call-process-region (point-min) (point-max)
                                               ash-shim t '(t t) nil "mcp")
                          0))
              (setq output (buffer-string))))
          (should (equal (split-string (string-trim output) "\n" t)
                         '("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32600}}"
                           "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}")))
          (should-not (string-match-p "nil" output)))
      (delete-directory dir t))))

(ert-deftest ash-shim-reports-a-signalled-lisp-error-as-exit-1-not-a-dead-daemon ()
  "A real `(error ...)' in the daemon, wearing the same \"could not\" words
`arc-index.el' and `arc-watch.el' actually emit, must come back as exit
1 with the error text -- not exit 2, which would send a caller off to
start a daemon that is already running while the real failure is
discarded."
  (let ((result (ash-shim-with-fake-emacsclient
                 "*ERROR*: arc: could not open database" 1
                 '("stats"))))
    (should (= (car result) 1))
    (should (string-match-p "could not open database" (cdr result)))
    (should-not (string-match-p "daemon not running" (cdr result)))))

(ert-deftest ash-shim-still-reports-a-real-transport-failure-as-exit-2 ()
  "emacsclient's own transport failure, anchored on its \"emacsclient:\"
self-identifying prefix, must still classify as a dead daemon."
  (let ((result (ash-shim-with-fake-emacsclient
                 "/nix/store/x/bin/emacsclient: can't find socket; have you started the server?"
                 1 '("stats"))))
    (should (= (car result) 2))
    (should (string-match-p "daemon not running" (cdr result)))))

(provide 'test-arc-shim)
;;; test-arc-shim.el ends here
