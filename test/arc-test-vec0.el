;;; arc-test-vec0.el --- locate a usable sqlite-vec extension for tests -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Every suite that opens a real `arc-db' needs `ARC_VEC0_PATH' set to
;; a real sqlite-vec (vec0) loadable extension *before* `arc' is
;; required -- `arc-db.el''s `arc-sqlite-vec-path' defcustom reads the
;; environment variable at load time.  This used to be a single
;; hardcoded /nix/store/...-sqlite-vec-.../lib/vec0.so path, copied
;; verbatim into eight files: meaningless to anyone who clones this
;; (public) repo on a machine that never built that exact Nix
;; derivation.  `arc-test-locate-vec0' tries `ARC_VEC0_PATH' first,
;; then a handful of plausible locations, and returns nil -- never a
;; guess -- when nothing is found, so a caller can skip cleanly
;; instead of failing obscurely deep inside the first test that opens
;; a database.
;;; Code:

(defun arc-test-locate-vec0 ()
  "Return a path to a usable sqlite-vec (vec0) extension.
Checks `ARC_VEC0_PATH' first (the documented, explicit way to point at
one -- see `arc-sqlite-vec-path'): if it is set to a real, existing
file, that path is returned, full stop -- it is never silently
second-guessed by falling through to a search elsewhere.  If it is set
to something that does NOT exist, that is a real mistake worth failing
loudly on, not quietly working around: this signals an `error' naming
the bad value, exactly the way `test/run.sh' already does for the same
situation, rather than silently substituting a DIFFERENT extension the
caller never asked for and never being told.  Only when `ARC_VEC0_PATH'
is unset (or empty) does this fall back to searching a few common
install locations, returning nil -- never a guess -- if none exist,
so a caller can skip cleanly instead of failing obscurely deep inside
the first database a test opens."
  (let ((e (getenv "ARC_VEC0_PATH")))
    (if (and e (not (string-empty-p e)))
        (if (file-exists-p e)
            e
          (error "arc: ARC_VEC0_PATH is set to %S, which does not exist -- fix it or unset it; this will not silently try a different extension instead" e))
      (car (seq-filter
            #'file-exists-p
            (append
             ;; Any sqlite-vec derivation a Nix profile or system
             ;; happens to have built, regardless of its hash.
             (file-expand-wildcards "/nix/store/*-sqlite-vec-*/lib/vec0.so")
             (list (expand-file-name ".nix-profile/lib/vec0.so" (getenv "HOME"))
                   "/usr/lib/sqlite3/vec0.so"
                   "/usr/lib/x86_64-linux-gnu/vec0.so"
                   "/usr/local/lib/vec0.so"
                   "/opt/homebrew/lib/vec0.so")))))))

(defmacro arc-test-ensure-vec0-or-skip! ()
  "Set `ARC_VEC0_PATH' to a located vec0 extension for the rest of this
file, or report why this suite cannot run and exit the batch process
cleanly (status 0) before any test in it gets a chance to fail
obscurely deep inside the first database it opens."
  '(let ((arc-test--vec0-found (arc-test-locate-vec0)))
     (if arc-test--vec0-found
         (setenv "ARC_VEC0_PATH" arc-test--vec0-found)
       (message "SKIP: no sqlite-vec (vec0) extension found -- set ARC_VEC0_PATH to run this suite")
       (kill-emacs 0))))

(provide 'arc-test-vec0)
;;; arc-test-vec0.el ends here
