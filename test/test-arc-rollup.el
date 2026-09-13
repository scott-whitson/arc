;;; test-arc-rollup.el --- chunk scores to ranked documents -*- lexical-binding: t; -*-
;;
;; arc's corpus is two shapes in one schema: nix options and Info manuals are
;; one chunk per document, the vault and dotfiles are 24-46.  A chunk-level
;; result set therefore lets one long note consume every slot.  Rollup groups
;; chunks back into documents, and the choice of aggregation is exactly where
;; that asymmetry can be re-introduced by accident -- see
;; arb-sum-rewards-length-and-the-others-do-not.
(require 'ert)
(defvar arb-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path arb-root)
(require 'arc-rollup)

(defun arb--chunks (&rest specs)
  "Build a chunk list from SPECS, each (SOURCE-ID SCORE)."
  (let ((id 0))
    (mapcar (lambda (s)
              (setq id (1+ id))
              (list :id id :source-id (nth 0 s) :score (nth 1 s)))
            specs)))

(ert-deftest arb-max-takes-the-best-chunk ()
  (let ((arc-rollup-function 'max))
    (should (= (arc-rollup-score '(0.5 0.4 0.1)) 0.5))))

(ert-deftest arb-top-n-sums-only-the-best-n ()
  (let ((arc-rollup-function 'top-n) (arc-rollup-top-n 3))
    (should (= (arc-rollup-score '(0.5 0.4 0.1 99.0)) 1.0))))

(ert-deftest arb-top-n-handles-fewer-chunks-than-n ()
  (let ((arc-rollup-function 'top-n) (arc-rollup-top-n 3))
    (should (= (arc-rollup-score '(0.5)) 0.5))))

(ert-deftest arb-sum-takes-everything ()
  (let ((arc-rollup-function 'sum))
    (should (= (arc-rollup-score '(0.5 0.4 0.1)) 1.0))))

(ert-deftest arb-unknown-function-signals ()
  (let ((arc-rollup-function 'median))
    (should-error (arc-rollup-score '(0.5)))))

(ert-deftest arb-groups-chunks-into-documents ()
  (let* ((arc-rollup-function 'max)
         (docs (arc-rollup (arb--chunks '(7 0.9) '(7 0.8) '(9 0.5)))))
    (should (= (length docs) 2))
    (should (= (plist-get (car docs) :source-id) 7))
    (should (= (plist-get (car docs) :chunk-count) 2))
    (should (= (plist-get (car docs) :score) 0.9))))

(ert-deftest arb-passages-are-capped-and-keep-input-order ()
  (let* ((arc-rollup-function 'max)
         (arc-rollup-passages 2)
         (docs (arc-rollup (arb--chunks '(7 0.9) '(7 0.8) '(7 0.7))))
         (passages (plist-get (car docs) :passages)))
    (should (= (length passages) 2))
    (should (= (plist-get (nth 0 passages) :score) 0.9))
    (should (= (plist-get (nth 1 passages) :score) 0.8))))

(ert-deftest arb-sum-rewards-length-and-the-others-do-not ()
  "The whole reason the default is not `sum'.
Source 1 is a one-chunk option that matched well.  Source 2 is a
forty-chunk note that matched weakly forty times.  Under `sum' the note
wins on structure alone; under `max' and `top-n' it does not."
  (let ((chunks (append (arb--chunks '(1 0.5))
                        (apply #'arb--chunks
                               (make-list 40 '(2 0.05))))))
    (let ((arc-rollup-function 'sum))
      (should (= (plist-get (car (arc-rollup chunks)) :source-id) 2)))
    (let ((arc-rollup-function 'max))
      (should (= (plist-get (car (arc-rollup chunks)) :source-id) 1)))
    (let ((arc-rollup-function 'top-n) (arc-rollup-top-n 3))
      (should (= (plist-get (car (arc-rollup chunks)) :source-id) 1)))))

(ert-deftest arb-ties-break-on-chunk-count-then-best-rank ()
  "Equal scores: more chunks first; equal there too, earlier rank first."
  (let* ((arc-rollup-function 'max)
         (docs (arc-rollup (arb--chunks '(1 0.5) '(2 0.5) '(2 0.4)))))
    (should (equal (mapcar (lambda (d) (plist-get d :source-id)) docs) '(2 1))))
  (let* ((arc-rollup-function 'max)
         (docs (arc-rollup (arb--chunks '(1 0.5) '(2 0.5)))))
    (should (equal (mapcar (lambda (d) (plist-get d :source-id)) docs) '(1 2)))))

(ert-deftest arb-empty-input-yields-nil ()
  (should (null (arc-rollup nil))))

(provide 'test-arc-rollup)
;;; test-arc-rollup.el ends here
