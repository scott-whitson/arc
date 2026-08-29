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

(ert-deftest an-hm-path-is-a-function ()
  (should (fboundp (quote arc-hm-options-json-path))))

(ert-deftest an-hm-path-returns-nil-on-bogus-attr ()
  ;; a bogus flake attribute must fail the nix build without signalling
  (let ((arc-hm-options-attr "definitely-not-a-real-attribute"))
    (should (null (arc-hm-options-json-path)))))

(ert-deftest an-hm-parses-the-shared-fixture ()
  ;; the HM schema matches the NixOS one, so the same fixture exercises it
  (let ((opts (arc-nixopt-parse-json an-fixture "hm-option")))
    (should (cl-every (lambda (o) (equal (plist-get o :kind) "hm-option")) opts))
    (should (string-match-p "Type: boolean"
                            (plist-get (cl-find "services.syncthing.enable" opts
                                                :key (lambda (x) (plist-get x :option-name))
                                                :test (quote equal))
                                       :text)))))

(ert-deftest an-sources-carry-chunks ()
  "Every source `arc-nixopt-parse-json' returns must carry :chunks, not
just :text -- `arc-index-source' reads only :chunks."
  (dolist (o (arc-nixopt-parse-json an-fixture "nix-option"))
    (should (= (length (plist-get o :chunks)) 1))
    (should (equal (plist-get (car (plist-get o :chunks)) :text) (plist-get o :text)))))
