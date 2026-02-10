;;; jj-mode-test.el --- Tests for jj-mode -*- lexical-binding: t; -*-

;; This file is NOT part of GNU Emacs.

;;; Commentary:
;; Unit tests for jj-mode using ERT (Emacs Regression Testing)
;; These tests mock out jj command execution to test logic in isolation.
;; All tests pass without jj installed since process-file is fully mocked.

;;; Code:

(require 'ert)
(require 'jj-mode)
(require 'cl-lib)

;;; ============================================================
;;; Test Infrastructure
;;; ============================================================

(defvar jj-test--captured-commands nil
  "List of captured command invocations for verification.
Each entry is a plist with :executable, :args, :infile, :display.")

(defvar jj-test--mock-return-value ""
  "Return value for mocked jj commands.")

(defvar jj-test--mock-exit-code 0
  "Exit code for mocked jj commands.")

(defmacro jj-test-with-mock-commands (return-value exit-code &rest body)
  "Execute BODY with mocked jj command execution.
Commands return RETURN-VALUE and EXIT-CODE.
Captured commands are available in `jj-test--captured-commands'."
  (declare (indent 2))
  `(let ((jj-test--captured-commands nil)
         (jj-test--mock-return-value ,return-value)
         (jj-test--mock-exit-code ,exit-code))
     (cl-letf (((symbol-function 'process-file)
                (lambda (program &optional infile buffer display &rest args)
                  (push (list :executable program
                              :args args
                              :infile infile
                              :display display)
                        jj-test--captured-commands)
                  (cond
                   ((eq buffer t)
                    (insert jj-test--mock-return-value))
                   ((bufferp buffer)
                    (with-current-buffer buffer
                      (insert jj-test--mock-return-value)))
                   ((and (listp buffer) (bufferp (car buffer)))
                    (with-current-buffer (car buffer)
                      (insert jj-test--mock-return-value))))
                  jj-test--mock-exit-code))
               ((symbol-function 'start-file-process)
                (lambda (name buffer program &rest args)
                  (push (list :executable program
                              :args args
                              :name name)
                        jj-test--captured-commands)
                  (make-process :name name
                                :buffer buffer
                                :command (list "true")))))
       ,@body)))

(defvar jj-test--mock-return-sequence nil
  "Sequence of return values for successive mock calls.")

(defmacro jj-test-with-mock-command-sequence (return-sequence exit-code &rest body)
  "Execute BODY with mocked commands returning successive values from RETURN-SEQUENCE.
Each call to process-file pops the next value.  EXIT-CODE is constant."
  (declare (indent 2))
  `(let ((jj-test--captured-commands nil)
         (jj-test--mock-return-sequence (copy-sequence ,return-sequence))
         (jj-test--mock-exit-code ,exit-code))
     (cl-letf (((symbol-function 'process-file)
                (lambda (program &optional infile buffer display &rest args)
                  (let ((ret (or (pop jj-test--mock-return-sequence) "")))
                    (push (list :executable program
                                :args args
                                :infile infile
                                :display display)
                          jj-test--captured-commands)
                    (cond
                     ((eq buffer t)
                      (insert ret))
                     ((bufferp buffer)
                      (with-current-buffer buffer
                        (insert ret)))
                     ((and (listp buffer) (bufferp (car buffer)))
                      (with-current-buffer (car buffer)
                        (insert ret))))
                    jj-test--mock-exit-code)))
               ((symbol-function 'start-file-process)
                (lambda (name buffer program &rest args)
                  (push (list :executable program
                              :args args
                              :name name)
                        jj-test--captured-commands)
                  (make-process :name name
                                :buffer buffer
                                :command (list "true")))))
       ,@body)))

(defun jj-test--get-last-command-args ()
  "Get the args from the most recent captured command."
  (plist-get (car jj-test--captured-commands) :args))

(defun jj-test--get-nth-command-args (n)
  "Get the args from the Nth captured command (0-indexed, most recent first)."
  (plist-get (nth n jj-test--captured-commands) :args))

(defun jj-test--get-last-command-executable ()
  "Get the executable from the most recent captured command."
  (plist-get (car jj-test--captured-commands) :executable))

(defun jj-test--command-count ()
  "Return the number of captured commands."
  (length jj-test--captured-commands))

;;; ============================================================
;;; Fixture Data (from real jj output on this repo)
;;; ============================================================

(defconst jj-test--bookmark-names-output
  "bookmark-move-transient\nik/pretty\nset-up-tests\n"
  "Real `jj bookmark list -T \"name ++ '\\n'\"` output.")

(defconst jj-test--remote-bookmarks-output
  "main@origin\nmain@lazy\nbookmark-move-transient@origin\n"
  "Real remote bookmark list output.")

(defconst jj-test--git-remotes-output
  "lazy git@github.com:lazy/jj-mode.el.git (tracking)\norigin git@github.com:bolivier/jj-mode.el (tracking)\n"
  "Real `jj git remote list` output.")

(defconst jj-test--version-string "jj 0.28.2\n"
  "Real `jj --version` output.")

(defconst jj-test--version-string-new "jj 0.37.0\n"
  "Version string for jj >= 0.37.")

(defconst jj-test--error-no-revision "Error: No such revision: abc123\n"
  "Error output for missing revision.")

(defconst jj-test--error-stale-working-copy "Error: Working copy is stale\n"
  "Error output for stale working copy.")

(defconst jj-test--error-merge-conflict "Error: Merge conflict in file.txt\n"
  "Error output for merge conflict.")

(defconst jj-test--error-nothing-to-squash "Error: nothing to squash into parent\n"
  "Error output for empty squash.")

(defconst jj-test--error-loop "Error: Rebase would create a loop\n"
  "Error output for rebase loop.")

(defconst jj-test--push-refusing "Refusing to push bookmark main: new bookmark\n"
  "Push refusal output for new bookmark.")

(defconst jj-test--push-permission-denied "Permission denied (publickey)\n"
  "Push authentication failure output.")

(defconst jj-test--push-network-error "Could not resolve hostname github.com\n"
  "Push network error output.")

(defconst jj-test--push-non-fast-forward "non-fast-forward update rejected, fetch first\n"
  "Push non-fast-forward rejection.")

(defconst jj-test--push-nothing-changed "Nothing changed\n"
  "Push nothing-to-do output.")

(defconst jj-test--diff-stat-line
  "3 files changed, 57 insertions(+), 13 deletions(-)"
  "Real diff stat line.")

(defconst jj-test--bookmark-extract-text
  "bookmark: main, bookmark: feature-branch, bookmark: bugfix/issue-123"
  "Text containing bookmark names for extraction test.")

;;; ============================================================
;;; Pure Parsing Tests
;;; ============================================================

;; --- jj--extract-bookmark-names ---

(ert-deftest jj-test-extract-bookmark-names/basic ()
  "Extract multiple bookmark names from text."
  (let ((names (jj--extract-bookmark-names jj-test--bookmark-extract-text)))
    (should (= (length names) 3))
    (should (equal names '("main" "feature-branch" "bugfix/issue-123")))))

(ert-deftest jj-test-extract-bookmark-names/empty-input ()
  "Return nil for empty input."
  (should (null (jj--extract-bookmark-names ""))))

(ert-deftest jj-test-extract-bookmark-names/no-match ()
  "Return nil when no bookmark pattern is found."
  (should (null (jj--extract-bookmark-names "some random text without bookmarks"))))

(ert-deftest jj-test-extract-bookmark-names/single ()
  "Extract a single bookmark name."
  (let ((names (jj--extract-bookmark-names "bookmark: main")))
    (should (= (length names) 1))
    (should (equal (car names) "main"))))

;; --- jj--optional-string-trim ---

(ert-deftest jj-test-optional-string-trim/normal ()
  "Trim whitespace from string."
  (should (string= (jj--optional-string-trim "  test  ") "test")))

(ert-deftest jj-test-optional-string-trim/nil ()
  "Pass through nil without error."
  (should (null (jj--optional-string-trim nil))))

(ert-deftest jj-test-optional-string-trim/empty ()
  "Trim empty string returns empty string."
  (should (string= (jj--optional-string-trim "") "")))

(ert-deftest jj-test-optional-string-trim/no-whitespace ()
  "String without whitespace is returned as-is."
  (should (string= (jj--optional-string-trim "hello") "hello")))

;; --- jj--format-short-diff-stat ---

(ert-deftest jj-test-format-short-diff-stat/basic ()
  "Parse insertions and deletions from a diff stat line."
  (let ((result (jj--format-short-diff-stat jj-test--diff-stat-line)))
    (should (stringp result))
    (should (string-match-p "57" result))
    (should (string-match-p "13" result))))

(ert-deftest jj-test-format-short-diff-stat/nil-input ()
  "Return nil for nil input."
  (should (null (jj--format-short-diff-stat nil))))

(ert-deftest jj-test-format-short-diff-stat/no-match ()
  "Return nil for non-matching string."
  (should (null (jj--format-short-diff-stat "no stats here"))))

(ert-deftest jj-test-format-short-diff-stat/has-faces ()
  "Result should have font-lock-face properties."
  (let ((result (jj--format-short-diff-stat jj-test--diff-stat-line)))
    (should (get-text-property 0 'font-lock-face result))
    (should (eq (get-text-property 0 'font-lock-face result) 'jj-diff-stat-added))))

(ert-deftest jj-test-format-short-diff-stat/singular ()
  "Parse diff stat with singular insertion/deletion."
  (let ((result (jj--format-short-diff-stat "1 file changed, 1 insertion(+), 1 deletion(-)")))
    (should (stringp result))
    (should (string-match-p "1" result))))

;; --- jj--version>= and jj--get-version ---

(ert-deftest jj-test-get-version/parses-correctly ()
  "Parse version string into (major minor patch) list."
  (jj-test-with-mock-commands jj-test--version-string 0
    (let ((jj--version nil))
      (let ((version (jj--get-version)))
        (should (equal version '(0 28 2)))))))

(ert-deftest jj-test-get-version/caches-result ()
  "Version is cached after first call."
  (jj-test-with-mock-commands jj-test--version-string 0
    (let ((jj--version nil))
      (jj--get-version)
      (jj--get-version)
      ;; Only one call should have been made (cached)
      (should (= (jj-test--command-count) 1)))))

(ert-deftest jj-test-version>=/exact-match ()
  "Version >= returns t for exact match."
  (let ((jj--version '(0 28 2)))
    (should (jj--version>= 0 28 2))))

(ert-deftest jj-test-version>=/greater-patch ()
  "Version >= returns t when patch is greater."
  (let ((jj--version '(0 28 3)))
    (should (jj--version>= 0 28 2))))

(ert-deftest jj-test-version>=/greater-minor ()
  "Version >= returns t when minor is greater."
  (let ((jj--version '(0 29 0)))
    (should (jj--version>= 0 28 2))))

(ert-deftest jj-test-version>=/greater-major ()
  "Version >= returns t when major is greater."
  (let ((jj--version '(1 0 0)))
    (should (jj--version>= 0 28 2))))

(ert-deftest jj-test-version>=/lesser ()
  "Version >= returns nil when version is lesser."
  (let ((jj--version '(0 27 9)))
    (should-not (jj--version>= 0 28 0))))

;; --- jj--expand-log-entry-template ---

(ert-deftest jj-test-expand-log-entry-template/multiline ()
  "Multiline template expands to expected field list."
  (let ((fields (jj--expand-log-entry-template 'multiline)))
    (should (member 'change-id fields))
    (should (member 'author fields))
    (should (member 'newline fields))
    (should (member 'short-desc fields))))

(ert-deftest jj-test-expand-log-entry-template/oneline ()
  "Oneline template has no newline field."
  (let ((fields (jj--expand-log-entry-template 'oneline)))
    (should (member 'change-id fields))
    (should-not (member 'newline fields))))

(ert-deftest jj-test-expand-log-entry-template/custom-list ()
  "Custom list template is returned as-is."
  (let ((custom '(change-id short-desc)))
    (should (equal (jj--expand-log-entry-template custom) custom))))

(ert-deftest jj-test-expand-log-entry-template/invalid ()
  "Invalid template returns error string prepended to multiline."
  (let ((fields (jj--expand-log-entry-template "invalid")))
    (should (stringp (car fields)))
    (should (string-match-p "Invalid" (car fields)))))

;; --- jj--handle-command-result ---

(ert-deftest jj-test-handle-command-result/success ()
  "Successful command returns t."
  (should (jj--handle-command-result '("test") "success output" "OK" "FAIL")))

(ert-deftest jj-test-handle-command-result/error-prefix ()
  "Error: prefix is detected as failure."
  (should-not (jj--handle-command-result '("test") "Error: something broke" "OK" "FAIL")))

(ert-deftest jj-test-handle-command-result/warning-prefix ()
  "Warning: prefix is detected as failure."
  (should-not (jj--handle-command-result '("test") "Warning: something off" "OK" "FAIL")))

(ert-deftest jj-test-handle-command-result/fatal-prefix ()
  "fatal: prefix is detected as failure."
  (should-not (jj--handle-command-result '("test") "fatal: bad state" "OK" "FAIL")))

(ert-deftest jj-test-handle-command-result/empty-success ()
  "Empty result with success message shows success."
  (should (jj--handle-command-result '("test") "" "OK" "FAIL")))

(ert-deftest jj-test-handle-command-result/hint-not-error ()
  "Hint output is not treated as an error."
  (should (jj--handle-command-result '("test") "Hint: use --help" "OK" "FAIL")))

;; --- jj--handle-push-result ---

(ert-deftest jj-test-handle-push-result/success ()
  "Successful push returns t."
  (should (jj--handle-push-result '("git" "push") "" "Pushed!")))

(ert-deftest jj-test-handle-push-result/refusing ()
  "Refusing to push is detected."
  (should-not (jj--handle-push-result '("git" "push") jj-test--push-refusing "OK")))

(ert-deftest jj-test-handle-push-result/permission-denied ()
  "Permission denied is detected."
  (should-not (jj--handle-push-result '("git" "push") jj-test--push-permission-denied "OK")))

(ert-deftest jj-test-handle-push-result/network-error ()
  "Network error is detected."
  (should-not (jj--handle-push-result '("git" "push") jj-test--push-network-error "OK")))

(ert-deftest jj-test-handle-push-result/non-fast-forward ()
  "Non-fast-forward rejection is detected."
  (should-not (jj--handle-push-result '("git" "push") jj-test--push-non-fast-forward "OK")))

(ert-deftest jj-test-handle-push-result/nothing-changed ()
  "Nothing changed is treated as success."
  (should (jj--handle-push-result '("git" "push") jj-test--push-nothing-changed "OK")))

;;; ============================================================
;;; Command Execution Tests
;;; ============================================================

(ert-deftest jj-test-run-command/basic-args ()
  "jj--run-command passes --color=never, --no-pager, and --quiet."
  (jj-test-with-mock-commands "output" 0
    (jj--run-command "status")
    (let ((args (jj-test--get-last-command-args)))
      (should (member "--color=never" args))
      (should (member "--no-pager" args))
      (should (member "status" args))
      (should (member "--quiet" args)))))

(ert-deftest jj-test-run-command/uses-configured-executable ()
  "jj--run-command uses the jj-executable variable."
  (jj-test-with-mock-commands "" 0
    (let ((jj-executable "/usr/local/bin/jj"))
      (jj--run-command "status")
      (should (string= (jj-test--get-last-command-executable) "/usr/local/bin/jj")))))

(ert-deftest jj-test-run-command/filters-nil-args ()
  "jj--run-command filters out nil arguments."
  (jj-test-with-mock-commands "" 0
    (jj--run-command "status" nil "foo" nil)
    (let ((args (jj-test--get-last-command-args)))
      (should (member "status" args))
      (should (member "foo" args))
      (should-not (member nil args)))))

(ert-deftest jj-test-run-command/returns-buffer-string ()
  "jj--run-command returns the command output."
  (jj-test-with-mock-commands "hello world" 0
    (should (string= (jj--run-command "status") "hello world"))))

;; --- jj--run-command-color ---

(ert-deftest jj-test-run-command-color/uses-color-always ()
  "jj--run-command-color uses --color=always."
  (jj-test-with-mock-commands "colored" 0
    (jj--run-command-color "log")
    (let ((args (jj-test--get-last-command-args)))
      (should (member "--color=always" args))
      (should (member "log" args)))))

;;; ============================================================
;;; Arg Construction Tests — jj-git-push
;;; ============================================================

(ert-deftest jj-test-git-push/basic ()
  "Basic push with no flags."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '())
      (let ((args (jj-test--get-last-command-args)))
        (should (member "git" args))
        (should (member "push" args))))))

(ert-deftest jj-test-git-push/allow-new ()
  "Push with --allow-new flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--allow-new"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--allow-new" args))))))

(ert-deftest jj-test-git-push/all-bookmarks ()
  "Push with --all flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--all"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--all" args))))))

(ert-deftest jj-test-git-push/tracked ()
  "Push with --tracked flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--tracked"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--tracked" args))))))

(ert-deftest jj-test-git-push/deleted ()
  "Push with --deleted flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--deleted"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--deleted" args))))))

(ert-deftest jj-test-git-push/dry-run ()
  "Push with --dry-run flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--dry-run"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--dry-run" args))))))

(ert-deftest jj-test-git-push/allow-empty-description ()
  "Push with --allow-empty-description flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--allow-empty-description"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--allow-empty-description" args))))))

(ert-deftest jj-test-git-push/allow-private ()
  "Push with --allow-private flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--allow-private"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--allow-private" args))))))

(ert-deftest jj-test-git-push/remote-option ()
  "Push with --remote= splits into --remote <value>."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--remote=origin"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--remote" args))
        (should (member "origin" args))))))

(ert-deftest jj-test-git-push/bookmark-option ()
  "Push with --bookmark= splits into --bookmark <value>."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--bookmark=main"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--bookmark" args))
        (should (member "main" args))))))

(ert-deftest jj-test-git-push/revisions-option ()
  "Push with --revisions= splits into --revisions <value>."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--revisions=@"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--revisions" args))
        (should (member "@" args))))))

(ert-deftest jj-test-git-push/change-option ()
  "Push with --change= splits into --change <value>."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--change=abc123"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--change" args))
        (should (member "abc123" args))))))

(ert-deftest jj-test-git-push/named-option ()
  "Push with --named= splits into --named <value>."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--named=x=@"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--named" args))
        (should (member "x=@" args))))))

(ert-deftest jj-test-git-push/multiple-bookmarks ()
  "Push with multiple --bookmark= args."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--bookmark=main" "--bookmark=dev"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "main" args))
        (should (member "dev" args))))))

(ert-deftest jj-test-git-push/combined-flags ()
  "Push with a combination of flags and options."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-push '("--allow-new" "--remote=origin" "--bookmark=main" "--dry-run"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--allow-new" args))
        (should (member "--remote" args))
        (should (member "origin" args))
        (should (member "--bookmark" args))
        (should (member "main" args))
        (should (member "--dry-run" args))))))

;;; ============================================================
;;; Arg Construction Tests — jj-git-fetch
;;; ============================================================

(ert-deftest jj-test-git-fetch/basic ()
  "Basic fetch with no flags."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-fetch '())
      (let ((args (jj-test--get-last-command-args)))
        (should (member "git" args))
        (should (member "fetch" args))))))

(ert-deftest jj-test-git-fetch/all-remotes ()
  "Fetch with --all-remotes flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-fetch '("--all-remotes"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--all-remotes" args))))))

(ert-deftest jj-test-git-fetch/remote-option ()
  "Fetch with --remote= option."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-fetch '("--remote=origin"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--remote" args))
        (should (member "origin" args))))))

(ert-deftest jj-test-git-fetch/branch-option ()
  "Fetch with --branch= option."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-fetch '("--branch=main"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--branch" args))
        (should (member "main" args))))))

(ert-deftest jj-test-git-fetch/tracked ()
  "Fetch with --tracked flag."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-git-fetch '("--tracked"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--tracked" args))))))

;;; ============================================================
;;; Arg Construction Tests — jj-new-execute
;;; ============================================================

(ert-deftest jj-test-new-execute/defaults-to-changeset-at-point ()
  "With no args, appends changeset at point."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj-goto-current) #'ignore)
              ((symbol-function 'jj-get-changeset-at-point) (lambda () "abc123")))
      (jj-new-execute '())
      (let ((args (jj-test--get-last-command-args)))
        (should (member "new" args))
        (should (member "abc123" args))))))

(ert-deftest jj-test-new-execute/parent-option ()
  "Parent option is expanded into positional arg."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj-goto-current) #'ignore))
      (jj-new-execute '("--parent=xyz"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "new" args))
        (should (member "xyz" args))))))

(ert-deftest jj-test-new-execute/message-option ()
  "Message option is passed as -m <value>."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj-goto-current) #'ignore)
              ((symbol-function 'jj-get-changeset-at-point) (lambda () "abc")))
      (jj-new-execute '("--message=hello world"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "-m" args))
        (should (member "hello world" args))))))

(ert-deftest jj-test-new-execute/no-edit ()
  "No-edit flag is passed through."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj-goto-current) #'ignore)
              ((symbol-function 'jj-get-changeset-at-point) (lambda () "abc")))
      (jj-new-execute '("--no-edit"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--no-edit" args))))))

(ert-deftest jj-test-new-execute/insert-after ()
  "Insert-after option is expanded correctly."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj-goto-current) #'ignore))
      (jj-new-execute '("--insert-after=abc"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--insert-after" args))
        (should (member "abc" args))))))

(ert-deftest jj-test-new-execute/insert-before ()
  "Insert-before option is expanded correctly."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj-goto-current) #'ignore))
      (jj-new-execute '("--insert-before=xyz"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--insert-before" args))
        (should (member "xyz" args))))))

;;; ============================================================
;;; Arg Construction Tests — bookmark operations
;;; ============================================================

(ert-deftest jj-test-bookmark-move/from-and-to ()
  "Bookmark move with commit and bookmark names."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-bookmark-move "abc123" '("main"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "bookmark" args))
        (should (member "move" args))
        (should (member "abc123" args))
        (should (member "main" args))))))

(ert-deftest jj-test-bookmark-move/multiple-names ()
  "Bookmark move with multiple bookmark names."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-bookmark-move "abc123" '("main" "dev"))
      (let ((args (jj-test--get-last-command-args)))
        (should (member "bookmark" args))
        (should (member "move" args))
        (should (member "abc123" args))
        (should (member "main" args))
        (should (member "dev" args))))))

(ert-deftest jj-test-bookmark-set/basic ()
  "Bookmark set with name and revision."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj--root) (lambda () "/tmp/repo/")))
      (jj-bookmark-set "main" "abc123" nil)
      (let ((args (jj-test--get-last-command-args)))
        (should (member "bookmark" args))
        (should (member "set" args))
        (should (member "main" args))
        (should (member "-r" args))
        (should (member "abc123" args))))))

;;; ============================================================
;;; Arg Construction Tests — squash operations
;;; ============================================================

(ert-deftest jj-test-squash-into-parent/constructs-args ()
  "Squash into parent builds correct args."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-get-changeset-at-point) (lambda () "abc123"))
              ((symbol-function 'jj-log-refresh) #'ignore))
      (jj-squash-into-parent)
      (let ((args (jj-test--get-last-command-args)))
        (should (member "squash" args))
        (should (member "--from" args))
        (should (member "abc123" args))
        (should (member "--into" args))))))

(ert-deftest jj-test-do-squash/from-and-into ()
  "jj--do-squash with from and into builds correct args."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj--do-squash "abc" "def" nil "test message")
      (let ((args (jj-test--get-last-command-args)))
        (should (member "squash" args))
        (should (member "--from" args))
        (should (member "abc" args))
        (should (member "--into" args))
        (should (member "def" args))
        (should (member "-m" args))
        (should (member "test message" args))))))

(ert-deftest jj-test-do-squash/from-only ()
  "jj--do-squash with only from (squash into parent)."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj--do-squash "abc" nil nil "msg")
      (let ((args (jj-test--get-last-command-args)))
        (should (member "squash" args))
        (should (member "-r" args))
        (should (member "abc" args))
        (should-not (member "--into" args))))))

(ert-deftest jj-test-do-squash/keep-emptied ()
  "jj--do-squash with keep-commit adds --keep-emptied."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj--do-squash "abc" "def" t "msg")
      (let ((args (jj-test--get-last-command-args)))
        (should (member "--keep-emptied" args))))))

;;; ============================================================
;;; Arg Construction Tests — tug, undo, abandon, commit, describe
;;; ============================================================

(ert-deftest jj-test-tug/constructs-bookmark-move ()
  "jj-tug constructs a bookmark move command."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-get-changeset-at-point) (lambda () "abc123"))
              ((symbol-function 'jj-log-refresh) #'ignore))
      (jj-tug)
      (let ((args (jj-test--get-last-command-args)))
        (should (member "bookmark" args))
        (should (member "move" args))
        (should (member "--from" args))
        (should (member "--to" args))
        (should (member "abc123" args))))))

(ert-deftest jj-test-undo/basic ()
  "jj-undo calls undo command."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-log-refresh) #'ignore))
      (jj-undo)
      (let ((args (jj-test--get-last-command-args)))
        (should (member "undo" args))))))

(ert-deftest jj-test-abandon/basic ()
  "jj-abandon calls abandon with -r and changeset."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-get-changeset-at-point) (lambda () "abc123"))
              ((symbol-function 'jj-log-refresh) #'ignore))
      (jj-abandon)
      (let ((args (jj-test--get-last-command-args)))
        (should (member "abandon" args))
        (should (member "-r" args))
        (should (member "abc123" args))))))

(ert-deftest jj-test-commit/opens-message-buffer ()
  "jj-commit fetches current description then opens message buffer."
  (jj-test-with-mock-commands "current desc\n" 0
    (cl-letf (((symbol-function 'jj--open-message-buffer) #'ignore))
      (jj-commit)
      ;; Should have called jj log to get description
      (let ((args (jj-test--get-last-command-args)))
        (should (member "log" args))
        (should (member "-r" args))
        (should (member "@" args))
        (should (member "--no-graph" args))
        (should (member "-T" args))
        (should (member "description" args))))))

(ert-deftest jj-test-describe/opens-message-buffer ()
  "jj-describe fetches description for changeset at point."
  (jj-test-with-mock-commands "some desc\n" 0
    (cl-letf (((symbol-function 'jj-get-changeset-at-point) (lambda () "abc123"))
              ((symbol-function 'jj--open-message-buffer) #'ignore))
      (jj-describe)
      (let ((args (jj-test--get-last-command-args)))
        (should (member "log" args))
        (should (member "-r" args))
        (should (member "abc123" args))
        (should (member "description" args))))))

;;; ============================================================
;;; Error Handling Tests — jj--suggest-help
;;; ============================================================

(ert-deftest jj-test-suggest-help/no-revision ()
  "Suggest help for 'No such revision' error."
  (jj--suggest-help "test" "No such revision: abc123")
  ;; Should not error; just verifying it runs without throwing
  (should t))

(ert-deftest jj-test-suggest-help/stale-working-copy ()
  "Suggest help for stale working copy."
  (jj--suggest-help "test" "Working copy is stale")
  (should t))

(ert-deftest jj-test-suggest-help/merge-conflict ()
  "Suggest help for merge conflict."
  (jj--suggest-help "test" "Merge conflict in file.txt")
  (should t))

(ert-deftest jj-test-suggest-help/nothing-to-squash ()
  "Suggest help for empty squash."
  (jj--suggest-help "test" "nothing to squash")
  (should t))

(ert-deftest jj-test-suggest-help/loop-error ()
  "Suggest help for rebase loop."
  (jj--suggest-help "test" "would create a loop")
  (should t))

;;; ============================================================
;;; Template Tests
;;; ============================================================

(ert-deftest jj-test-format-log-template/produces-string ()
  "Log template is a non-empty string."
  (let ((jj--version '(0 28 2)))
    (let ((template (jj--format-log-template)))
      (should (stringp template))
      (should (> (length template) 0)))))

(ert-deftest jj-test-format-log-template/contains-core-fields ()
  "Template contains essential jj template fields."
  (let ((jj--version '(0 28 2)))
    (let ((template (jj--format-log-template)))
      (should (string-match-p "change_id" template))
      (should (string-match-p "commit_id" template))
      (should (string-match-p "description" template)))))

(ert-deftest jj-test-format-log-template/version-dependent-old ()
  "Template uses old API for versions < 0.37."
  (let ((jj--version '(0 28 2)))
    (let ((template (jj--format-log-template)))
      (should (string-match-p "format_short_change_id_with_hidden_and_divergent_info" template))
      (should (string-match-p "self\\.git_head()" template)))))

(ert-deftest jj-test-format-log-template/version-dependent-new ()
  "Template uses new API for versions >= 0.37."
  (let ((jj--version '(0 37 0)))
    (let ((template (jj--format-log-template)))
      (should (string-match-p "format_short_change_id_with_change_offset" template))
      (should (string-match-p "contained_in" template)))))

(ert-deftest jj-test-format-log-template/diff-stat-conditional ()
  "Template includes diff-stat field only when jj-log-show-diff-stat is set."
  (let ((jj--version '(0 28 2)))
    (let ((jj-log-show-diff-stat nil))
      (should-not (string-match-p "diff-stat.*stat(120)" (jj--format-log-template))))
    (let ((jj-log-show-diff-stat t))
      (should (string-match-p "stat(120)" (jj--format-log-template))))))

;;; ============================================================
;;; Root Detection Tests
;;; ============================================================

(ert-deftest jj-test-root/finds-repo ()
  "jj--root finds repo via locate-dominating-file."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_file _name) "/home/user/repo/")))
    (let (jj--repo-root)
      (should (string= (jj--root) "/home/user/repo/")))))

(ert-deftest jj-test-root/uses-cache ()
  "jj--root returns cached value when available."
  (let ((jj--repo-root "/cached/root/"))
    (should (string= (jj--root) "/cached/root/"))))

(ert-deftest jj-test-root/error-when-not-in-repo ()
  "jj--root signals user-error when not in a repo."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_file _name) nil)))
    (let (jj--repo-root)
      (should-error (jj--root) :type 'user-error))))

;;; ============================================================
;;; Interactive Command Tests (mock completing-read)
;;; ============================================================

(ert-deftest jj-test-bookmark-create/constructs-args ()
  "jj-bookmark-create calls bookmark create with name and revision."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-get-changeset-at-point) (lambda () "abc123"))
              ((symbol-function 'read-string) (lambda (&rest _) "my-bookmark"))
              ((symbol-function 'jj-log-refresh) #'ignore))
      (jj-bookmark-create)
      (let ((args (jj-test--get-last-command-args)))
        (should (member "bookmark" args))
        (should (member "create" args))
        (should (member "my-bookmark" args))
        (should (member "-r" args))
        (should (member "abc123" args))))))

(ert-deftest jj-test-bookmark-delete/constructs-args ()
  "jj-bookmark-delete calls bookmark delete with chosen name."
  (jj-test-with-mock-command-sequence
      (list jj-test--bookmark-names-output  ;; get-bookmark-names call
            "")                              ;; delete call
      0
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "set-up-tests"))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'jj-log-refresh) #'ignore)
              ((symbol-function 'jj--root) (lambda () "/tmp/repo/")))
      (jj-bookmark-delete)
      ;; The most recent call should be the delete
      (let ((args (jj-test--get-last-command-args)))
        (should (member "bookmark" args))
        (should (member "delete" args))
        (should (member "set-up-tests" args))))))

(ert-deftest jj-test-bookmark-create/empty-name-skips ()
  "jj-bookmark-create with empty name does nothing."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj-get-changeset-at-point) (lambda () "abc123"))
              ((symbol-function 'read-string) (lambda (&rest _) "")))
      (jj-bookmark-create)
      ;; No command should have been issued (only the mock capture list)
      (should (= (jj-test--command-count) 0)))))

;;; ============================================================
;;; Git Remote Parsing
;;; ============================================================

(ert-deftest jj-test-get-git-remotes/parses-names ()
  "jj--get-git-remotes extracts remote names from output."
  (jj-test-with-mock-commands jj-test--git-remotes-output 0
    (let ((remotes (jj--get-git-remotes)))
      (should (member "lazy" remotes))
      (should (member "origin" remotes)))))

(ert-deftest jj-test-get-git-remotes/empty-output ()
  "jj--get-git-remotes returns nil for empty output."
  (jj-test-with-mock-commands "" 0
    (cl-letf (((symbol-function 'jj--root) (lambda () "/tmp/repo/")))
      ;; With empty output from jj, falls back to git remote which is also mocked empty
      (let ((remotes (jj--get-git-remotes)))
        ;; Should handle gracefully, returning nil or empty list
        (should (or (null remotes) (= (length remotes) 0)))))))

;;; ============================================================
;;; Bookmark Name Parsing
;;; ============================================================

(ert-deftest jj-test-get-bookmark-names/local ()
  "jj--get-bookmark-names returns parsed bookmark list."
  (jj-test-with-mock-commands jj-test--bookmark-names-output 0
    (let ((names (jj--get-bookmark-names)))
      (should (member "bookmark-move-transient" names))
      (should (member "ik/pretty" names))
      (should (member "set-up-tests" names)))))

(ert-deftest jj-test-get-bookmark-names/all-remotes-flag ()
  "jj--get-bookmark-names with all-remotes includes --all."
  (jj-test-with-mock-commands jj-test--remote-bookmarks-output 0
    (jj--get-bookmark-names t)
    (let ((args (jj-test--get-last-command-args)))
      (should (member "--all" args)))))

;;; ============================================================
;;; Mock Sequence Infrastructure Test
;;; ============================================================

(ert-deftest jj-test-mock-sequence/returns-successive-values ()
  "Mock sequence returns different values for successive calls."
  (jj-test-with-mock-command-sequence '("first" "second" "third") 0
    (should (string= (jj--run-command "cmd1") "first"))
    (should (string= (jj--run-command "cmd2") "second"))
    (should (string= (jj--run-command "cmd3") "third"))))

(ert-deftest jj-test-mock-sequence/falls-back-to-empty ()
  "Mock sequence returns empty string when sequence is exhausted."
  (jj-test-with-mock-command-sequence '("only-one") 0
    (should (string= (jj--run-command "cmd1") "only-one"))
    (should (string= (jj--run-command "cmd2") ""))))

(provide 'jj-mode-test)
;;; jj-mode-test.el ends here
