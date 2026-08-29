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
  (should (equal (arc-source-link '(:kind "info" :info-node "(emacs)Directory Variables"))
                 "[[info:(emacs)Directory Variables]]")))

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

(ert-deftest as-follow-option-grep-miss-produces-message-not-error ()
  "A `grep' miss (exit 1, the normal 'not declared here' case) must
report via `message', not propagate `process-lines''s non-zero-exit
error as an uncaught signal."
  (let* ((tmp (make-temp-file "arc-source-test" t))
         (captured nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (setq captured (apply #'format fmt args)))))
          (should (arc--follow-option tmp "no.such.option.anywhere.at.all"))
          (should (stringp captured))
          (should (string-match-p "no declaration found" captured)))
      (delete-directory tmp t))))

(ert-deftest as-follow-option-no-root-reports-message ()
  "With no root configured, report the option instead of erroring."
  (let ((captured nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (setq captured (apply #'format fmt args)))))
      (should (arc--follow-option nil "services.syncthing.enable"))
      (should (stringp captured))
      (should (string-match-p "services.syncthing.enable" captured)))))

(provide 'test-arc-source)
;;; test-arc-source.el ends here
