;;; arc-source-nixopt.el --- NixOS and Home-Manager option ingestion -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; options.json is 11 MB and holds 24,661 options, and it comes from
;; cache.nixos.org with no local evaluation.  Every option is already a
;; self-contained chunk, so this file does no splitting at all -- one option
;; is one chunk, and its `declarations' entry is the navigation target.
;;; Code:

(require 'json)
(require 'subr-x)

(defcustom arc-nixopt-flake (expand-file-name "dotfiles" (getenv "HOME"))
  "Flake whose nixosConfigurations provide the options manual."
  :type 'directory :group 'arc)

(defcustom arc-nixopt-host (system-name)
  "Host attribute in `arc-nixopt-flake' to read options from."
  :type 'string :group 'arc)

(defun arc-nixopt-options-json-path (&optional flake host)
  "Build and return the path to options.json for HOST in FLAKE.
Returns nil if the build fails.  This is a cache fetch, not an
evaluation, on any host whose configuration is already in the binary
cache."
  (let* ((flake (expand-file-name (or flake arc-nixopt-flake)))
         (host (or host arc-nixopt-host))
         (attr (format "%s#nixosConfigurations.%s.config.system.build.manual.optionsJSON"
                       flake host))
         (out (with-temp-buffer
                (if (zerop (call-process "nix" nil (list t nil) nil "build" "--no-link"
                                         "--print-out-paths" attr))
                    (string-trim (buffer-string))
                  nil))))
    (when out
      (let ((f (expand-file-name "share/doc/nixos/options.json" out)))
        (and (file-exists-p f) f)))))

(defun arc--nixopt-text (name spec)
  "Render option NAME with SPEC (a hash-table) as chunk text."
  (let ((type (gethash "type" spec))
        (desc (gethash "description" spec))
        (default (let ((d (gethash "default" spec))) (and d (gethash "text" d))))
        (example (let ((e (gethash "example" spec))) (and e (gethash "text" e)))))
    (string-join
     (delq nil
           (list (format "Option: %s" name)
                 (and type (format "Type: %s" type))
                 (and default (format "Default: %s" default))
                 (and example (format "Example: %s" example))
                 (and desc (concat "\n" desc))))
     "\n")))

(defun arc-nixopt-parse-json (path kind)
  "Parse the options.json at PATH into source plists of KIND.
Each plist has :kind, :option-name, :path (the first declaration) and
:text."
  (let ((json (with-temp-buffer
                (insert-file-contents path)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'array
                                   :null-object nil
                                   :false-object nil)))
        (out nil))
    (maphash
     (lambda (name spec)
       (let ((decls (gethash "declarations" spec)))
         (push (list :kind kind
                     :option-name name
                     :path (and decls (> (length decls) 0) (aref decls 0))
                     :text (arc--nixopt-text name spec))
               out)))
     json)
    (nreverse out)))

(provide 'arc-source-nixopt)
;;; arc-source-nixopt.el ends here
