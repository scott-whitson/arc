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

(defun arc-source--info-link-target (info-node)
  "Convert INFO-NODE from Info-mode's (MANUAL)NODE shape to org's link form.
`arc-source-info.el' stores each info source's node the way Info-mode
writes it, e.g. \"(auth)Top\" -- that is what `Info-current-node'
paired with the manual name looks like, and it is also the form
Info-mode's own buffers and completion use, so keeping it as the
stored value costs nothing there.  But org's `info:' link syntax is
FILE#NODE, not Info-mode's parenthesised form: org parses
`info:(auth.info)Top' as a literal filename and errors with
\"Info file (auth.info)Top does not exist\", rather than opening the
auth manual's Top node.  Converting here, at render time, rather than
changing what `arc-source-info.el' stores, fixes every citation
already sitting in a live index immediately -- no reindex needed --
since only the rendering step, not the stored identity, was ever
wrong.
Returns INFO-NODE unchanged if it does not match the expected shape,
so a malformed value fails exactly as loudly downstream as it always
did rather than being silently swallowed here."
  (if (string-match "\\`(\\([^)]+\\))\\(.*\\)\\'" info-node)
      (format "%s#%s" (match-string 1 info-node) (match-string 2 info-node))
    info-node))

(defun arc-source-link (source &optional line)
  "Return an org link string for SOURCE, a source plist.
LINE, when given, is the line number a file link should target."
  (let ((kind (plist-get source :kind)))
    (pcase kind
      ("file"       (format "[[file:%s::%d]]" (plist-get source :path) (or line 1)))
      ("info"       (format "[[info:%s]]"
                            (arc-source--info-link-target (plist-get source :info-node))))
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
Branches explicitly on `grep''s exit status instead of treating every
failure as a miss: 0 is a hit (the first matching file is opened), 1
is a genuine miss (OPTION really has no declaration under ROOT, an
ordinary outcome reported via `message'), and anything else -- grep
missing, a permission error, a bad pattern, a signal -- is a tool
failure and is reported as one, with its status and whatever grep
wrote to its output, rather than being misreported as \"no declaration
found\"."
  (if (and root (file-directory-p root))
      (with-temp-buffer
        (let ((status (call-process "grep" nil (list t t) nil "-rl" "--include=*.nix"
                                     (format "%s" option) root)))
          (cond
           ((eq status 0)
            (find-file (car (split-string (buffer-string) "\n" t))))
           ((eq status 1)
            (message "arc: no declaration found for %s" option))
           (t
            (message "arc: grep failed (status %s) looking for %s: %s"
                     status option (string-trim (buffer-string)))))))
    (message "arc: %s (set arc-nixpkgs-directory to jump to declarations)" option)))

(defun arc-source-register-link-types ()
  "Register arc's `nixopt:' and `hmopt:' org link types."
  (org-link-set-parameters
   "nixopt" :follow (lambda (opt _) (arc--follow-option arc-nixpkgs-directory opt)))
  (org-link-set-parameters
   "hmopt" :follow (lambda (opt _) (arc--follow-option arc-hm-directory opt))))

;; Call this at load time, not just define it: before this, nothing in arc
;; ever called `arc-source-register-link-types', so `nixopt:' and `hmopt:'
;; were never registered org link types in a real running Emacs, and
;; `C-c C-o' (or a plain click) on one signalled "No link abbreviation"
;; instead of following it.  Requiring this file is now itself sufficient.
(arc-source-register-link-types)

(provide 'arc-source)
;;; arc-source.el ends here
