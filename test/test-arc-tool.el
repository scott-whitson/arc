;;; test-arc-tool.el --- the agent-facing JSON verbs -*- lexical-binding: t; -*-
;;
;; These verbs are an interface something outside Emacs depends on, so the
;; shape is asserted, not assumed: an agent that cannot parse the output
;; has no other way to find out.
(require 'ert)
(require 'cl-lib)
(require 'json)
(defvar att-root (expand-file-name ".." (file-name-directory
                                         (or load-file-name buffer-file-name))))
(add-to-list 'load-path att-root)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'arc-test-vec0)
(arc-test-ensure-vec0-or-skip!)
(require 'arc)
(require 'arc-index)
(require 'arc-tool)
(require 'arc-test-helpers)

(defun att--parse (s)
  (let ((json-object-type 'alist) (json-array-type 'list))
    (json-read-from-string s)))

(ert-deftest att-search-returns-parseable-json-with-results ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (out (att--parse (arc-tool-search "alpha" "everything" 10 'keyword)))
          (results (alist-get 'results out)))
     (should (equal (alist-get 'query out) "alpha"))
     (should (= (length results) 1))
     (let ((r (car results)))
       (should (equal (alist-get 'source_id r) 1))
       (should (equal (alist-get 'path r) "/tmp/a.txt"))
       (should (numberp (alist-get 'score r)))
       (should (numberp (alist-get 'best_rank r)))
       (should (= (alist-get 'chunks r) 1))
       (should (equal (alist-get 'status (alist-get 'trust r)) "untrusted"))
       (should (equal (alist-get 'scope (alist-get 'trust r))
                      "retrieved corpus text"))
       (should
        (stringp
         (alist-get 'text (car (alist-get 'passages r)))))))))

(ert-deftest att-search-preserves-org-node-identity ()
  "Search results retain the org-roam id needed for preview/navigation."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "org-node" :org-id "org-node-42" :title "A note"
      :chunks ((:text "org search token" :line-start 1 :line-end 1)))
    "test")
   (let* ((arc-rollup-function 'max)
          (out (att--parse (arc-tool-search "org search token" "everything"
                                             10 'keyword)))
          (result (car (alist-get 'results out))))
     (should (= (length (alist-get 'results out)) 1))
     (should (equal (alist-get 'org_id result) "org-node-42")))))

(defun att--filter-fixtures ()
  "Index sources covering every typed filter dimension."
  (arc-index-source
   '(:kind "file" :path "/srv/emanix/a.nix"
     :chunks ((:text "filter-token" :line-start 1 :line-end 1)))
   "vault")
  (arc-index-source
   '(:kind "org-node" :org-id "filter-note" :tags ("work")
     :chunks ((:text "filter-token" :line-start 1 :line-end 1)))
   "vault")
  (arc-index-source
   '(:kind "file" :path "/home/other/b.nix"
     :chunks ((:text "filter-token" :line-start 1 :line-end 1)))
   "other"))

(ert-deftest att-filtered-search-selects-each-typed-dimension ()
  "Collections, kinds, tags and path-prefix all constrain retrieval."
  (arc-test-with-temp-db
   (att--filter-fixtures)
   (dolist (case '((:collections ("other") "/home/other/b.nix")
                   (:kinds ("org-node") "filter-note")
                   (:tags ("work") "filter-note")
                   (:path-prefix "/srv/" "/srv/emanix/a.nix")))
     (let* ((key (car case))
            (value (cadr case))
            (expected (caddr case))
            (out (att--parse
                  (arc-tool-search-filtered
                   "filter-token" "everything" 10 'keyword
                   (list key value))))
            (results (alist-get 'results out)))
       (should (= (length results) 1))
       (should (equal (or (alist-get 'path (car results))
                          (alist-get 'org_id (car results)))
                      expected))))))

(ert-deftest att-filtered-search-intersects-a-preset ()
  "A distinct filter dimension narrows, never broadens, a preset."
  (arc-test-with-temp-db
   (att--filter-fixtures)
   (let* ((out (att--parse
                 (arc-tool-search-filtered
                  "filter-token" "vault" 10 'keyword
                  '(:kinds ("org-node")))))
          (result (car (alist-get 'results out))))
     (should (= (length (alist-get 'results out)) 1))
     (should (equal (alist-get 'org_id result) "filter-note"))
     (should (equal (alist-get 'scope_description out) "vault; kinds org-node"))
     (should (equal (alist-get 'kinds (alist-get 'filters out)) '("org-node"))))))

(ert-deftest att-filtered-search-rejects-ambiguous-dimensions ()
  "A preset and filter cannot silently replace the same dimension."
  (arc-test-with-temp-db
   (att--filter-fixtures)
   (should-error
    (arc-tool-search-filtered "filter-token" "vault" 10 'keyword
                              '(:collections ("other"))))
   (should-error
    (arc-tool-search-filtered "filter-token" "everything" 10 'keyword
                              '(:kinds ("file") :kinds ("org-node"))))))

(ert-deftest att-filtered-search-rejects-invalid-filter-values ()
  (arc-test-with-temp-db
   (should-error (arc-tool-search-filtered "x" nil 10 'keyword
                                           '(:kinds ("bogus"))))
   (should-error (arc-tool-search-filtered "x" nil 10 'keyword
                                           '(:path-prefix "")))
   (should-error (arc-tool-search-filtered "x" nil 10 'keyword
                                           '(:unknown ("x"))))))

(ert-deftest att-search-with-no-match-returns-an-empty-array ()
  "An empty result must serialise as [] and not as null -- a consumer
that has to distinguish them will get it wrong otherwise."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha" :line-start 1 :line-end 1)))
    "test")
   (let ((out (arc-tool-search "zzzznomatch" "everything" 10 'keyword)))
     (should (string-match-p "\"results\":\\[\\]" out))
     (should (null (alist-get 'results (att--parse out)))))))

(ert-deftest att-legacy-search-still-accepts-the-semantic-arm ()
  "The original in-Emacs four-argument entry point keeps semantic retrieval.
The CLI-facing filtered entry point remains deliberately limited to keyword
and fused so its wire contract is explicit."
  (cl-letf (((symbol-function 'arc-search-documents)
             (lambda (_query _scope arm)
               (should (eq arm 'semantic))
               nil)))
    (let ((out (att--parse (arc-tool-search "semantic query" "everything"
                                            3 'semantic))))
      (should (equal (alist-get 'arm out) "semantic"))
      (should (= (alist-get 'count out) 0)))))

(ert-deftest att-search-rejects-a-nonpositive-limit ()
  (should-error (arc-tool-search-filtered "x" nil 0 'keyword))
  (should-error (arc-tool-search-filtered "x" nil -1 'keyword)))

(ert-deftest att-search-rejects-malformed-filter-values ()
  (dolist (filters '(42
                     (:collections "vault")
                     (:collections nil)
                     (:kinds (42))
                     (:tags (""))
                     (:path-prefix 42)
                     (:path-prefix "")
                     (:unknown ("x"))))
    (should-error (arc-tool-search-filtered "x" nil 10 'keyword filters))))

(ert-deftest att-filtered-search-escapes-literal-path-prefixes ()
  "Percent, underscore and backslash are literals, not LIKE wildcards."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/srv/100%_safe\\path/a.nix"
      :chunks ((:text "literal-filter-token" :line-start 1 :line-end 1)))
    "test")
   (let* ((out (att--parse
                 (arc-tool-search-filtered
                  "literal-filter-token" "everything" 10 'keyword
                  '(:path-prefix "/srv/100%_safe\\path/"))))
          (results (alist-get 'results out)))
     (should (= (length results) 1))
     (should (equal (alist-get 'path (car results))
                    "/srv/100%_safe\\path/a.nix")))))

(ert-deftest att-filtered-search-rejects-preset-conflicts-for-all-dimensions ()
  "A preset cannot be silently replaced on any typed dimension."
  (cl-letf (((symbol-function 'arc-search-documents) (lambda (&rest _) nil)))
    (let ((arc-scope-presets
           '(("by-kind" . (:kinds ("file")))
             ("by-tag" . (:tags ("work")))
             ("by-path" . (:path-prefix "/srv/")))))
      (dolist (case '(("by-kind" :kinds ("file"))
                      ("by-tag" :tags ("work"))
                      ("by-path" :path-prefix "/srv/")))
        (should-error
         (apply #'arc-tool-search-filtered
                "x" (car case) 10 'keyword
                (list (cadr case) (caddr case))))))))

(ert-deftest att-search-rejects-an-unknown-scope-by-name ()
  (arc-test-with-temp-db
   (should-error (arc-tool-search "alpha" "nosuchscope" 10 'keyword))))

(ert-deftest att-search-rejects-an-unrecognised-arm-rather-than-mislabel-it ()
  "`arc--find-similar' silently falls through an unrecognised arm to
`fused'; `arc-tool-search' must not echo the caller's typo back in its
`:arm' field as though that arm had actually run."
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (should-error (arc-tool-search "alpha" "everything" 10 'bogus))))

(ert-deftest att-search-normalises-a-nil-arm-to-fused-in-its-own-report ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha one" :line-start 1 :line-end 1)))
    "test")
   (cl-letf (((symbol-function 'llm-embedding) (lambda (_p _t) [1.0 0.0 0.0])))
     (let ((out (att--parse (arc-tool-search "alpha" "everything" 10 nil))))
       (should (equal (alist-get 'arm out) "fused"))))))

(ert-deftest att-scopes-lists-every-preset ()
  "Every configured preset is listed in configured order without the live database."
  (arc-test-with-temp-db
   (let* ((out (att--parse (arc-tool-scopes)))
          (names (mapcar (lambda (s) (alist-get 'name s))
                         (alist-get 'scopes out))))
     (should (equal names (mapcar #'car arc-scope-presets))))))

(ert-deftest att-stats-reports-collections-and-freshness ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/a.txt"
      :chunks ((:text "alpha" :line-start 1 :line-end 1)))
    "test")
   (let ((out (att--parse (arc-tool-stats))))
     (should (assq 'kinds out))
     (should (assq 'freshness out)))))

(ert-deftest att-preview-returns-source-metadata-and-bounded-passages ()
  "Preview reads indexed rows, not the source file or embedding provider."
  (arc-test-with-temp-db
   (let ((arc-index-plan '(("test" . file))))
     (arc-index-source
      '(:kind "file" :path "/tmp/a.txt" :hash "hash-a" :mtime 42
        :chunks ((:text "alpha" :line-start 1 :line-end 1)
                 (:text "beta" :line-start 2 :line-end 2)
                 (:text "gamma" :line-start 3 :line-end 3)))
      "test")
     (arc-set-collection-provenance "test" "fixture-provenance")
     (let* ((source-id (caar (sqlite-select (arc-db)
                                            "SELECT id FROM sources;")))
            (out (att--parse (arc-tool-preview source-id 2)))
            (passages (alist-get 'passages out)))
       (should (= (alist-get 'source_id out) source-id))
       (should (equal (alist-get 'kind out) "file"))
       (should (equal (alist-get 'path out) "/tmp/a.txt"))
       (should (equal (alist-get 'hash out) "hash-a"))
       (should (= (alist-get 'mtime out) 42))
       (should (member "test" (alist-get 'collections out)))
       (should (equal (alist-get 'status (alist-get 'trust out)) "untrusted"))
       (should (string-prefix-p "[[file:/tmp/a.txt::1]]"
                                (alist-get 'source_link out)))
       (should (= (length passages) 2))
       (should (equal (alist-get 'text (car passages)) "alpha"))
       (should (equal (alist-get 'text (cadr passages)) "beta"))))))

(ert-deftest att-preview-with-zero-passages-returns-an-empty-array ()
  "A valid source with no data rows still has JSON array shape."
  (arc-test-with-temp-db
   (let ((source-id (arc-source-upsert
                     '(:kind "file" :path "/tmp/empty.txt"))))
     (let* ((out (att--parse (arc-tool-preview source-id)))
            (passages (alist-get 'passages out)))
       (should (equal passages nil))
       (should (string-match-p "\\\"passages\\\":\\[\\]"
                               (arc-tool-preview source-id)))))))

(ert-deftest att-preview-is-read-only-and-never-embeds-or-reads-source-files ()
  "Preview uses indexed rows only, even when forbidden APIs are stubbed."
  (arc-test-with-temp-db
   (let ((arc-index-plan '( ("test" . file))))
     (arc-index-source
      '(:kind "file" :path "/tmp/preview.txt"
        :chunks ((:text "preview text" :line-start 1 :line-end 1)))
      "test")
     (let ((source-id (caar (sqlite-select (arc-db) "SELECT id FROM sources;")))
           (failed "preview called a forbidden API"))
       (cl-letf (((symbol-function 'llm-embedding)
                  (lambda (&rest _) (error failed)))
                 ((symbol-function 'insert-file-contents)
                  (lambda (&rest _) (error failed)))
                 ((symbol-function 'find-file-noselect)
                  (lambda (&rest _) (error failed))))
         (let ((out (att--parse (arc-tool-preview source-id))))
           (should (equal (alist-get 'text (car (alist-get 'passages out)))
                          "preview text"))))))))

(ert-deftest att-preview-rejects-missing-and-invalid-source-ids ()
  (arc-test-with-temp-db
   (should-error (arc-tool-preview 999))
   (should-error (arc-tool-preview 0))
   (should-error (arc-tool-preview "1"))
   (should-error (arc-tool-preview 1 0))
   (should-error (arc-tool-preview 1 (1+ arc-tool-preview-max-limit)))))

(ert-deftest att-stats-reports-collection-provenance ()
  (arc-test-with-temp-db
   (let ((arc-index-plan '(("test" . file))))
     (arc-index-source
      '(:kind "file" :path "/tmp/a.txt"
        :chunks ((:text "alpha" :line-start 1 :line-end 1)))
      "test")
     (arc-set-collection-provenance "test" "fixture-provenance")
     (let* ((out (att--parse (arc-tool-stats)))
            (row (car (alist-get 'collections out))))
       (should (equal (alist-get 'provenance row) "fixture-provenance"))))))

(ert-deftest att-stats-reports-per-collection-sources-chunks-and-last-indexed ()
  "Controller Ruling F-1: `arc tool stats' must report per-collection
sources, chunks and last-indexed time, additive to the existing
`:kinds' (keyed by source kind, not collection) and `:freshness'
fields."
  (arc-test-with-temp-db
   (let ((arc-index-plan '(("test" . file))))
     (arc-index-source
      '(:kind "file" :path "/tmp/a.txt"
        :chunks ((:text "alpha" :line-start 1 :line-end 1)
                  (:text "beta" :line-start 2 :line-end 2)))
      "test")
     (let* ((out (att--parse (arc-tool-stats)))
            (rows (alist-get 'collections out))
            (row (car rows)))
       (should (assq 'kinds out))
       (should (assq 'freshness out))
       (should (= (length rows) 1))
       (should (equal (alist-get 'collection row) "test"))
       (should (= (alist-get 'sources row) 1))
       (should (= (alist-get 'chunks row) 2))
       (should (numberp (alist-get 'last_indexed_at row)))
       (should (assq 'provenance row))))))

(ert-deftest att-stats-collections-row-is-zeroed-for-a-never-indexed-collection ()
  "A collection nothing has been indexed into yet must still get a row
-- zeroed, not omitted -- the same choice `arc-freshness-report' makes
for `absent'."
  (arc-test-with-temp-db
   (let* ((arc-index-plan '(("ghost" . org)))
          (out (att--parse (arc-tool-stats)))
          (row (car (alist-get 'collections out))))
     (should (equal (alist-get 'collection row) "ghost"))
     (should (= (alist-get 'sources row) 0))
     (should (= (alist-get 'chunks row) 0))
     (should (null (alist-get 'last_indexed_at row))))))

(ert-deftest att-mcp-initialize-tools-and-notification ()
  (let* ((init (att--parse
                (arc-tool-mcp-dispatch
                 "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")))
         (tools (att--parse
                 (arc-tool-mcp-dispatch
                  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"))))
    (should (= (alist-get 'id init) 1))
    (should (equal (alist-get 'protocolVersion (alist-get 'result init))
                   "2024-11-05"))
    (should (equal (alist-get 'name (alist-get 'serverInfo (alist-get 'result init)))
                   "arc"))
    (let ((names (mapcar (lambda (tool) (alist-get 'name tool))
                         (alist-get 'tools (alist-get 'result tools)))))
      (should (equal names '("arc_search" "arc_preview" "arc_scopes"
                             "arc_stats" "arc_lifecycle"))))
    (should (null (arc-tool-mcp-dispatch
                  "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")))
    ;; An id-bearing notification-shaped method is a request, not a
    ;; notification: it must receive the normal unknown-method error.
    (let ((response (att--parse
                     (arc-tool-mcp-dispatch
                      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"notifications/initialized\"}"))))
      (should (= (alist-get 'id response) 3))
      (should (= (alist-get 'code (alist-get 'error response)) -32601)))
    ;; A valid request without an id is a notification regardless of method
    ;; name.  In particular, it must not emit an error response for a method
    ;; that would otherwise be unknown.
    (should (null (arc-tool-mcp-dispatch
                  "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}")))
    (should (null (arc-tool-mcp-dispatch
                  "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\"}")))))

(ert-deftest att-mcp-null-id-round-trips-as-json-null ()
  "A present JSON null id is request identity, not an absent id."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-null :json-null))
    (let ((success (json-read-from-string
                    (arc-tool-mcp-dispatch
                     "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}")))
          (failure (json-read-from-string
                    (arc-tool-mcp-dispatch
                     "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"bogus\"}"))))
      (should (eq (alist-get 'id success) :json-null))
      (should (assq 'result success))
      (should (eq (alist-get 'id failure) :json-null))
      (should (= (alist-get 'code (alist-get 'error failure)) -32601)))))

(ert-deftest att-mcp-tool-schemas-are-explicit-and-read-only ()
  (let* ((out (att--parse
               (arc-tool-mcp-dispatch
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")))
         (tools (alist-get 'tools (alist-get 'result out)))
         (search (car tools))
         (schema (alist-get 'inputSchema search)))
    (should (equal (alist-get 'type schema) "object"))
    (should (equal (alist-get 'required schema) '("query")))
    (let* ((properties (alist-get 'properties schema))
           (filters (alist-get 'filters properties))
           (filter-properties (alist-get 'properties filters))
           (collections (alist-get 'collections filter-properties)))
      (should (equal (alist-get 'type filters) "object"))
      (should (equal (alist-get 'type collections) "array"))
      (should (equal (alist-get 'type (alist-get 'items collections)) "string"))
      (should (equal (alist-get 'type (alist-get 'path_prefix filter-properties)) "string")))
    (dolist (tool tools)
      (should (string-match-p "read-only"
                             (downcase (or (alist-get 'description tool) "")))))))

(ert-deftest att-mcp-wire-uses-json-objects-not-null-for-empty-shapes ()
  "MCP capabilities and no-argument schemas must carry `{}`, not null."
  (let* ((json-null :json-null)
         (init (let ((json-object-type 'alist) (json-array-type 'list))
                 (json-read-from-string
                  (arc-tool-mcp-dispatch
                   "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"))))
         (listed (let ((json-object-type 'alist) (json-array-type 'list))
                   (json-read-from-string
                    (arc-tool-mcp-dispatch
                     "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")))))
    (should (null (alist-get 'tools (alist-get 'capabilities (alist-get 'result init)))))
    (dolist (tool (alist-get 'tools (alist-get 'result listed)))
      (let ((schema (alist-get 'inputSchema tool)))
        (should (equal (alist-get 'type schema) "object"))
        (should-not (eq (alist-get 'properties schema) json-null))))))

(ert-deftest att-mcp-invalid-requests-return-json-rpc-errors ()
  (let ((malformed (att--parse (arc-tool-mcp-dispatch "not-json")))
        (bad-version (att--parse
                      (arc-tool-mcp-dispatch
                       "{\"jsonrpc\":\"1.0\",\"id\":4,\"method\":\"ping\"}"))))
    (should (= (alist-get 'code (alist-get 'error malformed)) -32700))
    (should (= (alist-get 'code (alist-get 'error bad-version)) -32600))))

(ert-deftest att-mcp-rejects-top-level-non-objects-as-invalid-request ()
  "Arrays, null and primitive JSON values are not notifications.
An empty array parses to the same Lisp nil as an empty object when arrays
are represented as lists, so the dispatcher must preserve the wire shape
long enough to reject it as -32600 rather than treating it as an id-less
notification."
  (dolist (line '("[]" "[\"x\"]" "null" "\"x\"" "1"))
    (let* ((response (att--parse (arc-tool-mcp-dispatch line)))
           (error (alist-get 'error response)))
      (should (= (alist-get 'code error) -32600)))))

(ert-deftest att-mcp-rejects-idless-invalid-objects-but-keeps-valid-notifications-silent ()
  (dolist (line '("{}"
                  "{\"jsonrpc\":\"2.0\"}"
                  "{\"method\":\"ping\"}"
                  "{\"jsonrpc\":\"1.0\",\"method\":\"ping\"}"))
    (let* ((response (att--parse (arc-tool-mcp-dispatch line)))
           (error (alist-get 'error response)))
      (should (= (alist-get 'code error) -32600))))
  (should-not (arc-tool-mcp-dispatch
               "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}")))

(ert-deftest att-mcp-malformed-request-does-not-desynchronise-dispatcher ()
  "A parse error must be one response; the next valid request still works."
  (let ((bad (att--parse (arc-tool-mcp-dispatch "not-json")))
        (good (att--parse
               (arc-tool-mcp-dispatch
                "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"ping\"}"))))
    (should (= (alist-get 'code (alist-get 'error bad)) -32700))
    (should (= (alist-get 'id good) 12))
    (should (assq 'result good))))

(ert-deftest att-mcp-rejects-invalid-id-types-with-null-response-id ()
  "Only string, number and JSON null identifiers are valid JSON-RPC ids."
  (dolist (id-json '("true" "false" "[]" "{}"))
    (let* ((line (format "{\"jsonrpc\":\"2.0\",\"id\":%s,\"method\":\"ping\"}"
                        id-json))
           (response (att--parse (arc-tool-mcp-dispatch line)))
           (error (alist-get 'error response)))
      (should (null (alist-get 'id response)))
      (should (= (alist-get 'code error) -32600)))))

(ert-deftest att-mcp-rejects-scalar-or-null-params-preserving-id ()
  "Present params must be a JSON object or array, never a scalar or null."
  (dolist (params-json '("null" "false" "0" "\"text\""))
    (let* ((line (format "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"ping\",\"params\":%s}"
                        params-json))
           (response (att--parse (arc-tool-mcp-dispatch line)))
           (error (alist-get 'error response)))
      (should (= (alist-get 'id response) 17))
      (should (= (alist-get 'code error) -32600))))
  (should (assq 'result
                (att--parse
                 (arc-tool-mcp-dispatch
                  "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"ping\",\"params\":[]}")))))

(ert-deftest att-mcp-search-call-preserves-structured-untrusted-data ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/mcp.txt"
      :chunks ((:text "mcp search token" :line-start 3 :line-end 3)))
    "test")
   (let* ((response (arc-tool-mcp-dispatch
                     "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"arc_search\",\"arguments\":{\"query\":\"mcp search token\",\"scope\":\"everything\",\"arm\":\"keyword\",\"filters\":{\"kinds\":[\"file\"]}}}}"))
          (out (att--parse response))
          (result (alist-get 'result out))
          (structured (alist-get 'structuredContent result))
          (text (alist-get 'text (car (alist-get 'content result))))
          (row (car (alist-get 'results structured))))
     (should (= (alist-get 'id out) 7))
     (should (equal (alist-get 'path row) "/tmp/mcp.txt"))
     (should (equal (alist-get 'status (alist-get 'trust row)) "untrusted"))
     (should (string-match-p "untrusted data" (downcase text))))))

(ert-deftest att-mcp-preview-call-and-errors ()
  (arc-test-with-temp-db
   (arc-index-source
    '(:kind "file" :path "/tmp/mcp-preview.txt"
      :chunks ((:text "preview token" :line-start 2 :line-end 2)))
    "test")
   (let* ((source-id (caar (sqlite-select (arc-db) "SELECT id FROM sources;")))
          (request (format "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"arc_preview\",\"arguments\":{\"source_id\":%d,\"limit\":1}}}" source-id))
          (out (att--parse (arc-tool-mcp-dispatch request)))
          (structured (alist-get 'structuredContent (alist-get 'result out))))
     (should (= (alist-get 'source_id structured) source-id))
     (should (equal (alist-get 'status (alist-get 'trust structured)) "untrusted")))
   (let ((unknown (att--parse
                   (arc-tool-mcp-dispatch
                    "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"bogus\"}")))
         (bad-tool (att--parse
                    (arc-tool-mcp-dispatch
                     "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\",\"arguments\":{}}}")))
         (bad-args (att--parse
                    (arc-tool-mcp-dispatch
                     "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"arc_search\",\"arguments\":{}}}"))))
     (should (= (alist-get 'code (alist-get 'error unknown)) -32601))
     (should (= (alist-get 'code (alist-get 'error bad-tool)) -32602))
     (should (= (alist-get 'code (alist-get 'error bad-args)) -32602)))))

(ert-deftest att-stats-freshness-row-maps-kind-and-detail-correctly ()
  "`arc-freshness-report' rows are (NAME KIND STATE DETAIL).  KIND (the
chunker, e.g. `org') and DETAIL (a reason string, e.g. \"never
indexed\") are different claims; a row that emits KIND under the
`:detail' key -- and drops the real detail -- would tell a caller a
collection's kind is its freshness reason.  A never-indexed collection
makes KIND and DETAIL two different, unmistakable strings so that
mislabeling cannot pass by coincidence."
  (arc-test-with-temp-db
   (let* ((arc-index-plan '(("ghost-collection" . org)))
          (out (att--parse (arc-tool-stats)))
          (rows (alist-get 'freshness out))
          (row (car rows)))
     (should (= (length rows) 1))
     (should (equal (alist-get 'collection row) "ghost-collection"))
     (should (equal (alist-get 'kind row) "org"))
     (should (equal (alist-get 'state row) "absent"))
     (should (equal (alist-get 'detail row) "never indexed")))))

(ert-deftest att-lifecycle-clean-corpus-is-empty-and-read-only ()
  "A complete corpus reports zero actionable hygiene findings."
  (arc-test-with-temp-db
   (let ((arc-index-plan '(("test" . file)))
         (path (make-temp-file "arc-lifecycle-clean")))
     (unwind-protect
         (progn
           (arc-index-source
            (list :kind "file" :path path
                  :chunks '((:text "clean" :line-start 1 :line-end 1)))
            "test")
           (cl-letf (((symbol-function 'arc-file-hash)
                      (lambda (&rest _) (error "lifecycle read source contents"))))
             (let ((out (att--parse (arc-tool-lifecycle 5))))
               (should (eq (alist-get 'read_only out) t))
             (should (stringp (alist-get 'contract out)))
             (dolist (key '(missing_file_sources freshness phantom_sources orphan_data))
               (let ((group (alist-get key out)))
                 (should (= (alist-get 'count group) 0))
                 (should-not (alist-get 'truncated group))
                 (should (equal (alist-get 'items group) '()))))))
       (delete-file path))))))

(ert-deftest att-lifecycle-reports-missing-and-freshness-rows ()
  "Missing files and stale/absent freshness rows are named without pruning."
  (arc-test-with-temp-db
   (let* ((path (make-temp-file "arc-lifecycle-gone"))
          (arc-index-plan '(("test" . file) ("ghost" . file))))
     (unwind-protect
         (progn
           (arc-index-source
            (list :kind "file" :path path
                  :chunks '((:text "gone" :line-start 1 :line-end 1)))
            "test")
           (delete-file path)
           (let* ((out (att--parse (arc-tool-lifecycle)))
                  (missing (alist-get 'missing_file_sources out))
                  (freshness (alist-get 'freshness out)))
             (should (= (alist-get 'count missing) 1))
             (should (equal (alist-get 'path (car (alist-get 'items missing))) path))
             (should (= (alist-get 'count freshness) 2))
             (should (equal (mapcar (lambda (row) (alist-get 'state row))
                                    (alist-get 'items freshness))
                            '("stale" "absent")))))
       (when (file-exists-p path) (delete-file path))))))

(ert-deftest att-lifecycle-reports-phantoms-orphans-and-bounds-items ()
  "Referential-integrity findings include stable ids and bounded arrays."
  (arc-test-with-temp-db
   (dotimes (i 3)
     (arc-source-upsert (list :kind "file"
                              :path (format "/missing/phantom-%d" i))))
   (let ((cid (caar (sqlite-select (arc-db)
                                   "SELECT id FROM collections WHERE name = 'test';"))))
     (unless cid
       (sqlite-execute (arc-db) "INSERT INTO collections (name) VALUES ('test');")
       (setq cid (caar (sqlite-select (arc-db)
                                      "SELECT id FROM collections WHERE name = 'test';"))))
     ;; The production schema correctly enforces this relationship.  Disable
     ;; enforcement only long enough to construct the corruption this
     ;; read-only report must surface; no production path does this.
     (sqlite-execute (arc-db) "PRAGMA foreign_keys = OFF;")
     (sqlite-execute (arc-db)
                     (format "INSERT INTO data (source_id, collection_id, chunk)
                              VALUES (999999, %d, 'orphan');" cid))
     (sqlite-execute (arc-db) "PRAGMA foreign_keys = ON;"))
   (let* ((out (att--parse (arc-tool-lifecycle 1)))
          (phantoms (alist-get 'phantom_sources out))
          (orphans (alist-get 'orphan_data out)))
     (should (= (alist-get 'count phantoms) 3))
     (should (alist-get 'truncated phantoms))
     (should (= (length (alist-get 'items phantoms)) 1))
     (should (= (alist-get 'count orphans) 1))
     (should-not (alist-get 'truncated orphans))
     (should (= (alist-get 'source_id (car (alist-get 'items orphans))) 999999)))))

(provide 'test-arc-tool)
;;; test-arc-tool.el ends here
