;;; arc-source.el --- source identity and org-link rendering -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; One invariant carries arc's whole navigation feature: every chunk knows
;; how to render itself as an org link.  Because the answer buffer derives
;; from org-mode, that is all the navigation code there is.
;;
;; The `arc' customize group is declared in arc.el; this file's two
;; defcustoms attach to it via :group so nothing here re-declares it.
;;; Code:

(require 'org)

(defcustom arc-nixpkgs-directory nil
  "Optional nixpkgs checkout, used to open a NixOS option's declaration."
  :type '(choice (const nil) directory) :group 'arc)

(defcustom arc-hm-directory nil
  "Optional home-manager checkout, used to open an HM option's declaration."
  :type '(choice (const nil) directory) :group 'arc)

(defun arc-source-link (source &optional line)
  "Return an org link string for SOURCE, a source plist.
LINE, when given, is the line number a file link should target."
  (let ((kind (plist-get source :kind)))
    (pcase kind
      ("file"       (format "[[file:%s::%d]]" (plist-get source :path) (or line 1)))
      ("info"       (format "[[info:%s]]" (plist-get source :info-node)))
      ("org-node"   (format "[[id:%s][%s]]" (plist-get source :org-id)
                            (or (plist-get source :title) "note")))
      ("nix-option" (format "[[nixopt:%s]]" (plist-get source :option-name)))
      ("hm-option"  (format "[[hmopt:%s]]" (plist-get source :option-name)))
      (_ (error "arc: cannot render a link for kind %S" kind)))))

(defun arc-source-label (source)
  "Return a short human label for SOURCE."
  (pcase (plist-get source :kind)
    ("file"     (file-name-nondirectory (plist-get source :path)))
    ("info"     (plist-get source :info-node))
    ("org-node" (or (plist-get source :title) (plist-get source :org-id)))
    (_          (plist-get source :option-name))))

(defun arc--follow-option (root option)
  "Open OPTION's declaration under ROOT, or report it when ROOT is unset.
`process-lines' signals an error when the process it runs exits
non-zero, and `grep' exits 1 whenever it finds nothing -- the routine
\"not declared here\" case, not a failure.  `ignore-errors' turns that
into the same \"no declaration found\" report a genuine miss produces,
rather than letting a plain grep miss surface as a stack trace."
  (if (and root (file-directory-p root))
      (let ((hit (car (ignore-errors
                         (process-lines "grep" "-rl" "--include=*.nix"
                                        (format "%s" option) root)))))
        (if hit (find-file hit) (message "arc: no declaration found for %s" option)))
    (message "arc: %s (set arc-nixpkgs-directory to jump to declarations)" option)))

(defun arc-source-register-link-types ()
  "Register arc's `nixopt:' and `hmopt:' org link types."
  (org-link-set-parameters
   "nixopt" :follow (lambda (opt _) (arc--follow-option arc-nixpkgs-directory opt)))
  (org-link-set-parameters
   "hmopt" :follow (lambda (opt _) (arc--follow-option arc-hm-directory opt))))

(provide 'arc-source)
;;; arc-source.el ends here
