;;; test-arc-watch.el --- keeping the corpus current -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar awa-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path awa-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-watch)
(require 'arc-test-helpers)

(defmacro awa-with-corpus (&rest body)
  "A temp db plus a real directory arc indexes, bound to `dir' and `f'."
  (declare (indent 0))
  `(let* ((arc-embedding-size 3)
          (dir (make-temp-file "awa" t))
          (f (expand-file-name "note.txt" dir)))
     (unwind-protect
         (arc-test-with-temp-db
          (let ((arc-collection-directory-alist (list (cons "docs" dir)))
                (arc-index-plan '(("docs" . file))))
            (with-temp-file f (insert "first version"))
            (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
              ,@body)))
       (delete-directory dir t))))

(ert-deftest awa-a-saved-file-inside-the-corpus-is-reindexed ()
  (awa-with-corpus
    (should (equal "docs" (arc-watch-reindex-path f)))
    (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;"))))))

(ert-deftest awa-a-file-outside-every-indexed-directory-is-ignored ()
  "arc must not start indexing whatever the user happens to save."
  (awa-with-corpus
    (let ((outside (make-temp-file "awa-outside" nil ".txt")))
      (unwind-protect
          (progn
            (with-temp-file outside (insert "not arc's business"))
            (should (null (arc-watch-reindex-path outside)))
            (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources;")))))
        (delete-file outside)))))

(ert-deftest awa-reindexing-picks-up-the-new-content ()
  (awa-with-corpus
    (arc-watch-reindex-path f)
    (should (string-match-p "first" (caar (sqlite-select (arc-db) "SELECT chunk FROM data;"))))
    (with-temp-file f (insert "second version"))
    (arc-watch-reindex-path f)
    (should (string-match-p "second" (caar (sqlite-select (arc-db) "SELECT chunk FROM data;"))))
    ;; and not both: the source's old chunks are replaced, not appended
    (should (= 1 (caar (sqlite-select (arc-db) "SELECT count(*) FROM data;"))))))

(ert-deftest awa-reindexing-clears-the-staleness-it-was-reporting ()
  "The point of the whole thing."
  (awa-with-corpus
    (arc-watch-reindex-path f)
    (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))
    (with-temp-file f (insert "edited outside arc"))
    (should (eq 'stale (nth 2 (car (arc-freshness-report)))))
    (arc-watch-reindex-path f)
    (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))))

(ert-deftest awa-derived-collections-are-never-auto-reindexed ()
  "Deliberate non-goal: rebuilding the option collections is ~40 minutes
of embedding, and a NixOS rebuild changes flake.lock routinely. A switch
must not silently start that."
  (awa-with-corpus
    (let ((arc-index-plan '(("docs" . nixopt)))
          (arc-collection-directory-alist (list (cons "docs" dir))))
      (should (null (arc-watch-reindex-path f))))))

(ert-deftest awa-a-secret-is-not-indexed-just-because-it-was-saved ()
  "The watcher must inherit the walk's denylist, not reimplement it."
  (awa-with-corpus
    (let ((key (expand-file-name "id_rsa" dir)))
      (with-temp-file key (insert "-----BEGIN OPENSSH PRIVATE KEY-----\nplain text\n"))
      (should (null (arc-watch-reindex-path key)))
      (should (= 0 (caar (sqlite-select (arc-db) "SELECT count(*) FROM sources WHERE path LIKE '%id_rsa';")))))))

(ert-deftest awa-after-save-hook-survives-an-indexing-failure ()
  "A save must never fail because arc could not index."
  (awa-with-corpus
    (cl-letf (((symbol-function 'arc-watch-reindex-path)
               (lambda (&rest _) (error "induced"))))
      (let ((buffer-file-name f)
            (arc-watch-after-save t))
        (should (arc-watch--after-save))))))

(ert-deftest awa-sweep-is-bounded-and-resumes ()
  (awa-with-corpus
    (dotimes (i 7)
      (let ((p (expand-file-name (format "f%d.txt" i) dir)))
        (with-temp-file p (insert (format "content %d" i)))
        (arc-watch-reindex-path p :quiet)))
    (let ((arc-watch-sweep-batch 3)
          (arc-watch--sweep-offset 0))
      (arc-watch-sweep)
      (should (= 3 arc-watch--sweep-offset))
      (arc-watch-sweep)
      (should (= 6 arc-watch--sweep-offset)))))

(ert-deftest awa-sweep-wraps-rather-than-running-off-the-end ()
  (awa-with-corpus
    (arc-watch-reindex-path f :quiet)
    (let ((arc-watch-sweep-batch 10)
          (arc-watch--sweep-offset 999))
      (arc-watch-sweep)
      (should (<= arc-watch--sweep-offset 10)))))

(ert-deftest awa-sweep-refreshes-a-file-changed-outside-emacs ()
  "This is the sweep's whole reason: a git pull or a Syncthing update
never fires `after-save-hook'."
  (awa-with-corpus
    (arc-watch-reindex-path f :quiet)
    (with-temp-file f (insert "changed by something else entirely"))
    (let ((arc-watch-sweep-batch 10) (arc-watch--sweep-offset 0))
      (should (= 1 (arc-watch-sweep))))
    (should (eq 'fresh (nth 2 (car (arc-freshness-report)))))))

(ert-deftest awa-mode-installs-and-removes-its-hook-and-timer ()
  (let ((arc-watch-idle-seconds 300))
    (arc-watch-mode 1)
    (should (memq #'arc-watch--after-save after-save-hook))
    (should arc-watch--timer)
    (arc-watch-mode -1)
    (should-not (memq #'arc-watch--after-save after-save-hook))
    (should-not arc-watch--timer)))

;;; --- Final review C1: which collection a saved path belongs to -------
;; `home' is $HOME, so its directory is a string prefix of every other
;; collection's.  A first-match lookup over `arc-collection-directory-alist'
;; therefore answered `home' for everything -- including ~/.mail, which
;; `arc-index-plan' deliberately does not build.

(defmacro awa-with-home-shaped-plan (&rest body)
  "Bind `home' to a $HOME-shaped tree with three collection roots under it:
`home' at the top, `emacs' at .config/emacs, and `mail' at .mail --
configured but, like the real plan, not built."
  (declare (indent 0))
  `(let* ((home (make-temp-file "awa-home" t))
          (arc-collection-directory-alist
           (list (cons "home" home)
                 (cons "emacs" (expand-file-name ".config/emacs" home))
                 (cons "mail" (expand-file-name ".mail" home))))
          (arc-index-plan '(("home" . file) ("emacs" . file))))
     (unwind-protect (progn ,@body)
       (delete-directory home t))))

(ert-deftest awa-a-mail-path-resolves-to-no-collection ()
  "`mail' is configured and deliberately unplanned.  Resolving a mail
path to `home' indexes the operator's mail -- precisely what
`arc-collection-directory-alist''s docstring says must only happen when
the operator turns it on."
  (awa-with-home-shaped-plan
    (should (null (arc-watch--collection-for
                   (expand-file-name ".mail/inbox/1" home))))))

(ert-deftest awa-a-dotted-collection-root-wins-over-home ()
  "The walk files ~/.config/emacs under `emacs'.  The watcher must agree:
`arc--replace-source-chunks' reinserts a source's rows under whatever
collection it is handed, so disagreeing makes files migrate between
collections depending on which wrote last."
  (awa-with-home-shaped-plan
    (should (equal "emacs" (arc-watch--collection-for
                            (expand-file-name ".config/emacs/init.el" home))))))

(ert-deftest awa-collection-lookup-does-not-depend-on-alist-order ()
  "Longest match, not first -- so reordering the alist cannot change the
answer."
  (awa-with-home-shaped-plan
    (let ((arc-collection-directory-alist (reverse arc-collection-directory-alist)))
      (should (equal "emacs" (arc-watch--collection-for
                              (expand-file-name ".config/emacs/init.el" home))))
      (should (null (arc-watch--collection-for
                     (expand-file-name ".mail/inbox/1" home)))))))

(ert-deftest awa-an-ordinary-home-file-still-resolves-to-home ()
  "The narrowing must not cost `home' its own files."
  (awa-with-home-shaped-plan
    (should (equal "home" (arc-watch--collection-for
                           (expand-file-name "notes/todo.txt" home))))))

(ert-deftest awa-saving-a-mail-file-indexes-nothing ()
  "End to end: the whole point of the lookup.
`arc-ignore-invisible-files' is bound off here on purpose.  It happens
to exclude ~/.mail as well, being a dotted directory, and leaving it on
would let that rule pass this test while the collection lookup was
still wrong -- which is exactly the state the corpus was in."
  (let* ((arc-embedding-size 3)
         (arc-ignore-invisible-files nil)
         (home (make-temp-file "awa-home" t))
         (mail (expand-file-name ".mail/inbox/1" home)))
    (unwind-protect
        (arc-test-with-temp-db
         (let ((arc-collection-directory-alist
                (list (cons "home" home)
                      (cons "mail" (expand-file-name ".mail" home))))
               (arc-index-plan '(("home" . file))))
           (make-directory (file-name-directory mail) t)
           (with-temp-file mail (insert "Subject: private\n\nbody\n"))
           (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [0.1 0.2 0.3])))
             (should (null (arc-watch-reindex-path mail)))
             (should (= 0 (caar (sqlite-select
                                 (arc-db) "SELECT count(*) FROM sources;")))))))
      (delete-directory home t))))

;;; --- A sweep must not run inside someone else's prompt --------------

(ert-deftest awa-sweep-does-nothing-while-a-minibuffer-is-active ()
  "An idle timer fires DURING a prompt -- that is what idle means -- so the
sweep has to refuse to start while one is up.  Observed live: the sweep
fired under a save prompt raised by another tool, the abort that followed
landed in the sweep's own handler, and it was reported as `arc: sweep
failed (Save aborted)'.  An arc failure message for a failure that was not
arc's is exactly what made a background prompt read as arc asking a
question."
  (awa-with-corpus
    (let ((reached nil))
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
                ((symbol-function 'arc-watch--mutable-paths)
                 (lambda () (setq reached t) nil)))
        (should (null (arc-watch-sweep)))
        (should (null reached))))))
