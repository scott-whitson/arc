;;; test-arc-async-injection.el --- the async boundary must inject every tunable it reads -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Scott Whitson
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;;
;; `arc-find-similar' runs `arc--find-similar' inside a forked,
;; `emacs -Q'-equivalent process (`async-start' via `arc--async-do'),
;; which never loads the user's init file.  Any `defcustom' read
;; anywhere in that call graph therefore gets its compiled-in default
;; in the child, not whatever the real session has customized, unless
;; `arc--async-do' explicitly captures the current value with
;; `async-inject-variables' and hands it across.  `arc-knn-candidates'
;; and `arc-scope-bruteforce-max' shipped without that capture;
;; `arc-limit' and `arc-reranker-limit' (read via `arc-get-limit') and
;; `arc-embedding-size' (read via `arc-db' opening a fresh connection
;; in the child -- which always happens there, since the child starts
;; with no cached `arc--db') were the same defect, undetected because
;; nothing had ever asked what the child actually reads.
;;
;; This suite does not hardcode that list.  Hardcoding it would just be
;; today's answer to "what does the child read", indistinguishable
;; from an ordinary snapshot test, and exactly the shape of test that
;; let the missing injections ship in the first place.  Instead it
;; walks the real, live call graph reachable from `arc--find-similar'
;; -- by reading each reached function's own (uncompiled) definition
;; and recursing into every arc-prefixed function it calls -- and
;; collects every `defcustom' any of them reference.  It separately
;; extracts the actual injected-name list by reading `arc--async-do''s
;; own definition for its `(async-inject-variables "NAME")' calls,
;; rather than asserting that list here either.  A variable the walk
;; finds but the extraction does not fails the test by name.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(defvar aai-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path aai-root)
(require 'arc)

(defun aai--function-body (sym)
  "Return the body forms of SYM's function definition, as source sexps.
Works on an interpreted `defun' -- what `-Q -batch' loads straight
from a `.el' file, with no byte-compilation -- with no macro expansion
applied, so control-flow macros such as `when-let' or `pcase-let' still
appear as themselves rather than their expansion; that is exactly what
lets a plain tree walk see the same variable references the
interpreter itself will.

Two on-disk shapes exist depending on the Emacs this runs under.
Emacs < 30 hands `indirect-function' back the literal
`(closure ENV ARGLIST . BODY)' (or `(lambda ARGLIST . BODY)') cons the
reader produced.  Emacs 30 represents an interpreted lexical closure as
a distinct `interpreted-function' pseudovector instead -- printed with
`#[...]' syntax, easy to mistake for a byte-compiled function at a
glance, but still unexpanded source: its slot 1 is the body, already a
plain list of forms with no docstring or interactive spec mixed in
\(those live in slots 3 and 4 instead)."
  (let ((def (indirect-function sym)))
    (cond
     ((and (fboundp 'interpreted-function-p) (interpreted-function-p def))
      (aref def 1))
     ((and (consp def) (eq (car def) 'closure)) (cdddr def))
     ((and (consp def) (eq (car def) 'lambda)) (cddr def))
     (t (error "arc: %S is not a plain interpreted function this walker \
understands (got %S) -- run this suite the way `test/run.sh' does, \
uncompiled" sym def)))))

(defun aai--arc-defun-p (sym)
  "Return non-nil when SYM is one of arc's own interpreted functions.
Excludes macros (there are arc-prefixed macros in the test helpers,
though none reachable from production code) and anything that is not
an interpreted closure in one of the two shapes `aai--function-body'
understands -- built-ins, autoloads not yet loaded, and subrs all fail
that shape check, so recursion never wanders into code this walker
cannot read as a sexp."
  (and (symbolp sym)
       (fboundp sym)
       (string-prefix-p "arc" (symbol-name sym))
       (not (macrop sym))
       (let ((def (indirect-function sym)))
         (or (and (fboundp 'interpreted-function-p) (interpreted-function-p def))
             (and (consp def) (memq (car def) '(closure lambda)))))))

(defun aai--defcustom-p (sym)
  "Return non-nil when SYM was declared with `defcustom'.
`defcustom' (via `custom-declare-variable') always sets the
`standard-value' symbol property, regardless of `:type' or `:group';
plain `defvar' and `defconst' never do, so this is exactly the
customizable/non-customizable line the finding cares about."
  (and (symbolp sym) (get sym 'standard-value) t))

(defun aai--walk (form visit)
  "Call VISIT on every symbol anywhere inside FORM, cons cells and
vectors both descended into."
  (cond
   ((symbolp form) (funcall visit form))
   ((consp form)
    (aai--walk (car form) visit)
    (aai--walk (cdr form) visit))
   ((vectorp form)
    (seq-doseq (elt form) (aai--walk elt visit)))
   (t nil)))

(defun aai-reachable-defcustoms (root)
  "Return the `defcustom' symbols ROOT's call graph reads.
Walks ROOT's own body and every arc-prefixed function it calls,
transitively, collecting any symbol `aai--defcustom-p' recognises
along the way.  VISITED bounds the walk so a cycle -- there is none
today -- could not loop forever."
  (let ((visited (make-hash-table :test 'eq))
        (found (make-hash-table :test 'eq))
        (worklist (list root)))
    (while worklist
      (let ((fn (pop worklist)))
        (unless (gethash fn visited)
          (puthash fn t visited)
          (dolist (form (aai--function-body fn))
            (aai--walk
             form
             (lambda (sym)
               (when (aai--defcustom-p sym)
                 (puthash sym t found))
               (when (and (aai--arc-defun-p sym) (not (gethash sym visited)))
                 (push sym worklist))))))))
    (hash-table-keys found)))

(defun aai--collect-calls (form fn-name collect)
  "Call COLLECT with the argument list of every call to FN-NAME in FORM."
  (when (and (consp form) (eq (car form) fn-name))
    (funcall collect (cdr form)))
  (cond
   ((consp form)
    (aai--collect-calls (car form) fn-name collect)
    (aai--collect-calls (cdr form) fn-name collect))
   ((vectorp form)
    (seq-doseq (elt form) (aai--collect-calls elt fn-name collect)))))

(defun aai-injected-variables ()
  "Return the variable names `arc--async-do' actually injects.
Reads them out of its own live function definition -- every
`(async-inject-variables STRING)' call found in its body, the exact
calls `async-start' splices into the child's `lambda' -- rather than a
second hand-maintained list here."
  (let (names)
    (dolist (form (aai--function-body 'arc--async-do))
      (aai--collect-calls
       form 'async-inject-variables
       (lambda (args) (when (stringp (car args)) (push (car args) names)))))
    (delete-dups names)))

(ert-deftest aai-walker-actually-finds-the-known-tunables ()
  "A sanity check on the walker itself, independent of whether
`arc--async-do' currently injects any of them: if this fails, the
walker has stopped reaching code it used to reach, and the test below
would then pass vacuously by finding nothing left to check -- the
exact shape of test failure finding #6 is about."
  (let ((reached (mapcar #'symbol-name (aai-reachable-defcustoms 'arc--find-similar))))
    (dolist (name '("arc-embeddings-provider" "arc-knn-candidates"
                     "arc-scope-bruteforce-max" "arc-limit" "arc-reranker-limit"
                     "arc-embedding-size"))
      (should (member name reached)))))

(ert-deftest aai-async-injection-covers-every-defcustom-the-child-reads ()
  "Every `defcustom' reachable from `arc--find-similar' -- the function
`arc-find-similar' actually runs inside the async child -- must appear
in `arc--async-do''s `async-inject-variables' list, or the child
silently runs that variable at its compiled-in default no matter what
the real session has customized.  This discovers the reachable set by
walking live function definitions rather than asserting a fixed list,
so it fails the day a new callee reads a new tunable and nobody
remembers to inject it -- not only the day an existing injection is
removed."
  (let* ((reached (aai-reachable-defcustoms 'arc--find-similar))
         (injected (aai-injected-variables))
         (missing (seq-remove (lambda (sym) (member (symbol-name sym) injected))
                               reached)))
    (should (null missing))))

(provide 'test-arc-async-injection)
;;; test-arc-async-injection.el ends here
