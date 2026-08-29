;;; test-arc-nixopt.el --- NixOS option ingestion -*- lexical-binding: t; -*-
(require 'ert)
(defvar an-root (expand-file-name ".." (file-name-directory
                                        (or load-file-name buffer-file-name))))
(add-to-list 'load-path an-root)
(require 'arc-source-nixopt)

(defvar an-fixture (expand-file-name "test/fixtures/options-sample.json" an-root))

(ert-deftest an-parses-every-option ()
  (should (= (length (arc-nixopt-parse-json an-fixture "nix-option")) 2)))

(ert-deftest an-option-name-is-the-key ()
  (let ((names (mapcar (lambda (o) (plist-get o :option-name))
                       (arc-nixopt-parse-json an-fixture "nix-option"))))
    (should (member "services.syncthing.enable" names))
    (should (member "services.syncthing.guiAddress" names))))

(ert-deftest an-text-carries-type-default-and-description ()
  (let* ((opts (arc-nixopt-parse-json an-fixture "nix-option"))
         (o (cl-find "services.syncthing.guiAddress" opts
                     :key (lambda (x) (plist-get x :option-name)) :test #'equal))
         (text (plist-get o :text)))
    (should (string-match-p "Type: string" text))
    (should (string-match-p "127.0.0.1:8384" text))
    (should (string-match-p "serve the web interface" text))))

(ert-deftest an-declaration-becomes-the-path ()
  (let* ((opts (arc-nixopt-parse-json an-fixture "nix-option"))
         (o (car opts)))
    (should (equal (plist-get o :path)
                   "nixos/modules/services/networking/syncthing.nix"))))

(ert-deftest an-missing-example-is-tolerated ()
  ;; guiAddress has no "example" key; parsing must not signal
  (should (arc-nixopt-parse-json an-fixture "nix-option")))

(ert-deftest an-kind-is-passed-through ()
  (should (equal (plist-get (car (arc-nixopt-parse-json an-fixture "hm-option")) :kind)
                 "hm-option")))
