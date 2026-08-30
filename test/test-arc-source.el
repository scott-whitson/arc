;;; test-arc-source.el --- source plists render as org links -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar as-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path as-root)
(require 'arc-source)

(ert-deftest as-file-link-carries-line ()
  (should (equal (arc-source-link '(:kind "file" :path "/home/u/x.nix") 12)
                 "[[file:/home/u/x.nix::12]]")))

(ert-deftest as-file-link-without-line-defaults-to-one ()
  (should (equal (arc-source-link '(:kind "file" :path "/home/u/x.nix"))
                 "[[file:/home/u/x.nix::1]]")))

(ert-deftest as-info-link ()
  ;; Org's `info:' link syntax is FILE#NODE, not Info-mode's own
  ;; parenthesised (MANUAL)NODE shape -- `info:(emacs)Directory
  ;; Variables' parses as a literal filename in org and errors.  This
  ;; used to assert the broken parenthesised form as if it were
  ;; correct; see `as-info-link-is-followable' below for proof this
  ;; form actually opens.
  (should (equal (arc-source-link '(:kind "info" :info-node "(emacs)Directory Variables"))
                 "[[info:emacs#Directory Variables]]")))

(ert-deftest as-info-link-target-leaves-a-malformed-node-unchanged ()
  (should (equal (arc-source--info-link-target "no-parens-here") "no-parens-here")))

(ert-deftest as-info-link-is-followable ()
  "Render an info citation and actually follow it through org, rather
than only comparing strings -- a string comparison alone previously
missed that the parenthesised form org's `info:' link renders to is
parsed as a literal filename and errors."
  (require 'info)
  (with-temp-buffer
    (org-mode)
    (insert (arc-source-link '(:kind "info" :info-node "(info)Top")) "\n")
    (goto-char (point-min))
    (should (re-search-forward org-link-bracket-re nil t))
    (goto-char (match-beginning 0))
    (unwind-protect
        (progn
          (org-open-at-point)
          (should (eq major-mode 'Info-mode))
          (should (equal Info-current-node "Top")))
      (when (get-buffer "*info*") (kill-buffer "*info*")))))

(ert-deftest as-org-node-link-uses-title-as-description ()
  (should (equal (arc-source-link '(:kind "org-node" :org-id "a977180f" :title "elisa"))
                 "[[id:a977180f][elisa]]")))

(ert-deftest as-nix-option-link ()
  (should (equal (arc-source-link '(:kind "nix-option" :option-name "services.syncthing.enable"))
                 "[[nixopt:services.syncthing.enable]]")))

(ert-deftest as-hm-option-link ()
  (should (equal (arc-source-link '(:kind "hm-option" :option-name "programs.git.enable"))
                 "[[hmopt:programs.git.enable]]")))

(ert-deftest as-unknown-kind-signals ()
  (should-error (arc-source-link '(:kind "web" :path "http://x")) :type 'error))

(ert-deftest as-label-is-short ()
  (should (equal (arc-source-label '(:kind "file" :path "/home/u/a/b/x.nix")) "x.nix"))
  (should (equal (arc-source-label '(:kind "nix-option" :option-name "services.syncthing.enable"))
                 "services.syncthing.enable")))

(ert-deftest as-link-types-are-registered ()
  (require 'org)
  (arc-source-register-link-types)
  (should (assoc "nixopt" org-link-parameters))
  (should (assoc "hmopt" org-link-parameters)))

(ert-deftest as-link-types-are-registered-just-by-requiring-the-module ()
  "Requiring `arc-source' -- with no explicit call to
`arc-source-register-link-types' in this test -- must be sufficient:
that call used to exist only as a definition nobody ever invoked, so a
real Emacs that required `arc-source' still had unregistered `nixopt:'
and `hmopt:' link types and `C-c C-o' on either errored."
  (require 'org)
  (should (assoc "nixopt" org-link-parameters))
  (should (assoc "hmopt" org-link-parameters)))

(ert-deftest as-follow-option-no-root-reports-message ()
  "With no root configured, report the option instead of erroring."
  (let ((captured nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (setq captured (apply #'format fmt args)))))
      (should (arc--follow-option nil "services.syncthing.enable"))
      (should (stringp captured))
      (should (string-match-p "services.syncthing.enable" captured)))))

(ert-deftest as-follow-option-hit-opens-file ()
  "grep exit 0 -- a genuine hit -- opens the file it found."
  (let* ((tmp (make-temp-file "arc-source-test" t))
         (nix (expand-file-name "opt.nix" tmp))
         (opened nil))
    (unwind-protect
        (progn
          (with-temp-file nix (insert "services.syncthing.enable = true;\n"))
          (cl-letf (((symbol-function 'find-file)
                     (lambda (file) (setq opened file))))
            (arc--follow-option tmp "services.syncthing.enable"))
          (should (equal opened nix)))
      (delete-directory tmp t))))

(ert-deftest as-follow-option-grep-miss-produces-message-not-error ()
  "grep exit 1 (the normal \"not declared here\" case) is reported via
`message', not raised as an error."
  (let* ((tmp (make-temp-file "arc-source-test" t))
         (captured nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (setq captured (apply #'format fmt args)))))
          (should (arc--follow-option tmp "no.such.option.anywhere.at.all"))
          (should (stringp captured))
          (should (string-match-p "no declaration found" captured)))
      (delete-directory tmp t))))

(ert-deftest as-follow-option-grep-failure-reports-status-and-output ()
  "A grep exit status of 2 or more is a genuine tool failure -- grep
missing, a permission error, a bad pattern -- and must be reported as
one, not misrepresented as \"no declaration found\"."
  (let ((tmp (make-temp-file "arc-source-test" t))
        (captured nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (setq captured (apply #'format fmt args))))
                  ((symbol-function 'call-process)
                   (lambda (&rest _args)
                     (insert "grep: /no/such/dir: No such file or directory")
                     2)))
          (arc--follow-option tmp "services.syncthing.enable")
          (should (stringp captured))
          (should (string-match-p "grep failed" captured))
          (should (string-match-p "status 2" captured))
          (should (string-match-p "No such file or directory" captured)))
      (delete-directory tmp t))))

(provide 'test-arc-source)
;;; test-arc-source.el ends here
