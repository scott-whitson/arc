;;; Synthetic sample eval set — the SHAPE, not a real measurement.
;;
;; Committed so the harness stays tested without publishing anyone's real
;; paths or org ids. Point `arc-eval-set-file' at your own set; see the
;; README. Every key in an :expect clause must match a retrieved source.

((:question "which option enables the example service"
  :scope (:collections ("sample options"))
  :expect ((:kind "nix-option" :option-name "services.example.enable")))

 (:question "where is the example module defined"
  :scope (:collections ("sample files"))
  :expect ((:kind "file" :path-suffix "modules/example.nix")))

 (:question "unscoped question with two expected sources"
  :expect ((:kind "nix-option" :option-name "services.example.enable")
           (:kind "file" :path-suffix "modules/example.nix"))))
