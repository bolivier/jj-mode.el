;;; jj-mode.el --- A jujutsu vcs mode inspired by magit -*- lexical-binding: t; -*-

;; Author: Brandon Olivier
;; Keywords: jj, vcs, jujutsu, mode
;; Package-Requires: ((emacs "28.1"))
;; Version: 0.0.1
;; Homepage: https://github.com/bolivier/jj-mode.el

;;; Commentary:
;; A package to provide a Magit like experience when using Jujutsu (jj).

;; This file is NOT part of GNU Emacs.

;;; Code:

(require 'magit)
(require 'magit-section)
(require 'transient)
(require 'ansi-color)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup jj nil
  "Interface to jj version control system."
  :group 'tools)

(defcustom jj-executable "jj"
  "Path to jj executable."
  :type 'string
  :group 'jj)

(defcustom jj-debug nil
  "Enable debug logging for jj operations."
  :type 'boolean
  :group 'jj)

(defcustom jj-show-command-output t
  "Show jj command output in messages."
  :type 'boolean
  :group 'jj)

(defvar jj--version nil
  "Cached jj version string.")

(defun jj--get-version ()
  "Get the jj version as a list of numbers (major minor patch)."
  (unless jj--version
    (let* ((version-string (jj--run-command "--version"))
           (version-match (string-match "jj \\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)" version-string)))
      (when version-match
        (setq jj--version (list (string-to-number (match-string 1 version-string))
                                (string-to-number (match-string 2 version-string))
                                (string-to-number (match-string 3 version-string)))))))
  jj--version)

(defun jj--version>= (major minor patch)
  "Check if jj version is >= MAJOR.MINOR.PATCH."
  (let ((version (jj--get-version)))
    (when version
      (or (> (nth 0 version) major)
          (and (= (nth 0 version) major)
               (or (> (nth 1 version) minor)
                   (and (= (nth 1 version) minor)
                        (>= (nth 2 version) patch))))))))

(defcustom jj-log-sections-hook '(jj-log-insert-logs
                                  jj-log-insert-status
                                  jj-log-insert-diff)
  "Hook run to insert sections in the log buffer."
  :type 'hook
  :group 'jj)

(defcustom jj-log-show-diff-stat nil
  "Show diff stat in log graph. (makes log graph slower)"
  :type 'boolean
  :group 'jj)

(defcustom jj-log-display-function #'pop-to-buffer
  "Function called to display the jj log buffer.
The function must accept one argument: the buffer to display."
  :type '(choice
          (function-item switch-to-buffer)
          (function-item pop-to-buffer)
          (function-item display-buffer)
          (function :tag "Custom function"))
  :group 'jj)

(defcustom jj-log-entry-template 'multiline
  "Template to use to show log entry lines"
  :type '(choice
          (symbol :tag "Multiline" multiline)
          (symbol :tag "Oneline" oneline)
          (sexp :tag "Custom field list"))
  :group 'jj)

(defvar jj--render-log-entry-function nil
  "Cached function for rendering log entry template")

(defface jj-log-graph-face
  '((t))
  "Face to render log graph")
(defface jj-log-graph-fixed-pitch-face
  '((t :inherit (fixed-pitch jj-log-graph-face)))
  "Face to use for rendering log graph"
  :group 'jj)
;; diff-added/diff-removed faces (default and magit) often set background which spoils jj graph view
;; Instead define our own faces
(defface jj-diff-stat-added
  '((t :foreground "#227722"))
  "Face for showing added line count"
  :group 'jj)
(defface jj-diff-stat-removed
  '((t :foreground "#AF0000"))
  "Face for showing removed line count"
  :group 'jj)
(defface jj-working-copy-heading
  '((t :inherit region :extend t))
  "Face for showing current working copy in the log graph"
  :group 'jj)
(defface jj-trunk-heading
  '((t :inherit diff-added :extend t))
  "Face for showing current working copy in the log graph"
  :group 'jj)

(defvar jj-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Navigation
    (define-key map (kbd "n") 'magit-section-forward)
    (define-key map (kbd "p") 'magit-section-backward)
    (define-key map (kbd "M-n") 'magit-section-forward-sibling)
    (define-key map (kbd "M-p") 'magit-section-backward-sibling)
    (define-key map (kbd ".") 'jj-goto-current)
    (define-key map (kbd "TAB") 'magit-section-toggle)
    (define-key map (kbd "q") 'quit-window)

    ;; Basic operations
    (define-key map (kbd "g") 'jj-log-refresh)
    (define-key map (kbd "c") 'jj-commit)
    (define-key map (kbd "e") 'jj-edit-changeset)
    (define-key map (kbd "u") 'jj-undo)
    (define-key map (kbd "N") 'jj-new-transient)
    (define-key map (kbd "s") 'jj-squash-transient)
    (define-key map (kbd "S") 'jj-squash-into-parent)
    (define-key map (kbd "c") 'jj-commit)
    (define-key map (kbd "d") 'jj-describe)
    (define-key map (kbd "a") 'jj-abandon)

    ;; Advanced Operations
    (define-key map (kbd "RET") 'jj-enter-dwim)
    (define-key map (kbd "b") 'jj-bookmark-transient)
    (define-key map (kbd "r") 'jj-rebase-transient)
    (define-key map (kbd "G") 'jj-git-transient)

    ;; Experimental
    (define-key map (kbd "D") 'jj-diff)
    (define-key map (kbd "E") 'jj-diffedit-emacs)
    (define-key map (kbd "M") 'jj-diffedit-smerge)
    (define-key map (kbd "?") 'jj-mode-transient)
    map)
  "Keymap for `jj-mode'.")

;;;###autoload
(transient-define-prefix jj-mode-transient ()
  "JJ commands transient menu."
  [:description "JJ Commands" :class transient-columns
                ["Arguments"
                 ("-c" "Use commit id" "--use-commit-id")]
                ["Basic Operations"
                 ("g" "Refresh log" jj-log-refresh)
                 ("c" "Commit" jj-commit)
                 ("e" "Edit changeset" jj-edit-changeset)
                 ("u" "Undo last change" jj-undo)
                 ("N" "New changeset" jj-new)
                 ("a" "Abandon changeset" jj-abandon)
                 ("d" "Describe changeset" jj-describe)
                 ("s" "Squash changeset" jj-squash-transient)
                 ("S" "Squash into parent" jj-squash-into-parent)]
                ["Advanced Operations"
                 ("r" "Rebase changeset" jj-rebase-transient)
                 ("b" "Bookmark operations" jj-bookmark-transient)
                 ("G" "Git operations" jj-git-transient)]
                ["Experimental"
                 ("D" "Show diff" jj-diff)
                 ("E" "DiffEdit (ediff)" jj-diffedit-emacs)
                 ("M" "DiffEdit (smerge)" jj-diffedit-smerge)]
                ["Exit"
                 ("?" "Show cool help" transient-help)
                 ("q" "Quit transient" transient-quit-one)]])

(define-derived-mode jj-mode magit-section-mode "JJ"
  "Major mode for interacting with jj version control system."
  :group 'jj
  (setq-local line-number-mode nil)
  (setq-local revert-buffer-function 'jj-log-refresh)
  ;; Clear rebase selections when buffer is killed
  (add-hook 'kill-buffer-hook 'jj-rebase-clear-selections nil t)
  ;; Clear squash selections when buffer is killed
  (add-hook 'kill-buffer-hook 'jj-squash-clear-selections nil t))

(defvar-local jj--repo-root nil
  "Cached repository root for the current buffer.")
(defvar-local jj--log-revset nil
  "Revset displayed by current jj-mode buffer. If nil, default revset (revsets.log) is used")
(defvar-local jj--expand-log-entries nil
  "Controls whether log entry sections in graph should be expanded by default")

(defun jj--format-log-template ()
  "Dynamically constructs template for formatting log entries"
  (concat
   "'\x1e' ++
if(self.root(),
  format_root_commit(self),
  label(
    separate(' ',
      if(self.current_working_copy(), 'working_copy'),
      if(self.immutable(), 'immutable', 'mutable'),
      if(self.conflict(), 'conflicted'),
    ),
    separate('\x1e',
      "
   ;; see https://github.com/jj-vcs/jj/blob/f4be9a21e91620a39eb1ac4c0568e7c31ea04852/CHANGELOG.md?plain=1#L86
   (if (jj--version>= 0 37 0)
       "format_short_change_id_with_change_offset(self),"
     "format_short_change_id_with_hidden_and_divergent_info(self),")
   "
      format_short_signature_oneline(self.author()),
      concat(' ', separate(' ', self.bookmarks(), self.tags(), self.working_copies())),
      "
   ;; see https://github.com/jj-vcs/jj/blob/f4be9a21e91620a39eb1ac4c0568e7c31ea04852/CHANGELOG.md?plain=1#105
   (if (jj--version>= 0 37 0)
       "if(self.contained_in('first_parent(@)'), label('git_head', 'git_head()'), ' '),"
     "if(self.git_head(), label('git_head', 'git_head()'), ' '),")
   "
      if(self.conflict(), label('conflict', 'conflict'), ' '),
      if(config('ui.show-cryptographic-signatures').as_boolean(),
        format_short_cryptographic_signature(self.signature()),
        ' '),
      if(self.empty(), label('empty', '(empty)'), ' '),
      if(self.description(),
        self.description().first_line(),
        label(if(self.empty(), 'empty'), description_placeholder),
      ),
      format_short_commit_id(self.commit_id()),
      format_timestamp(commit_timestamp(self)),
      '{' ++ separate(', ',
        '\"long-desc\":' ++ self.description().escape_json(),
        '\"current-working-copy\":' ++ json(self.current_working_copy()),
        '\"trunk\":' ++ json(self.contained_in('trunk()')),"
   (when jj-log-show-diff-stat "'\"diff-stat\":' ++ stringify(self.diff().stat(120)).escape_json(),")
   "   ) ++ '}',
    ),
  )
)
"))

(defun jj--root ()
  "Find root of the current repository."
  (let ((root (or (and (boundp 'jj--repo-root) jj--repo-root)
                  (locate-dominating-file default-directory ".jj"))))
    (unless root
      (user-error "Cannot find root -- not in a JJ repo"))
    root))

(defun jj--debug (format-string &rest args)
  "Log debug message if jj-debug is enabled."
  (when jj-debug
    (message "[jj-mode] %s" (apply #'format format-string args))))

(defun jj--message-with-log (format-string &rest args)
  "Display message and log if debug enabled."
  (let ((msg (apply #'format format-string args)))
    (jj--debug "User message: %s" msg)
    (message "%s" msg)))

(defun jj--run-command (&rest args)
  "Run jj command with ARGS and return output."
  (let ((start-time (current-time))
        (safe-args (seq-remove #'null (append args '("--quiet"))))
        result exit-code)
    (jj--debug "Running command: %s %s" jj-executable (string-join safe-args " "))
    (with-temp-buffer
      (setq exit-code (apply #'process-file jj-executable nil t nil "--color=never" "--no-pager" safe-args))
      (setq result (buffer-string))
      (jj--debug "Command completed in %.3f seconds, exit code: %d"
                 (float-time (time-subtract (current-time) start-time))
                 exit-code)
      (when (and jj-show-command-output (not (string-empty-p result)))
        (jj--debug "Command output: %s" (string-trim result)))
      result)))

(defun jj--run-command-color (&rest args)
  "Run jj command with ARGS and return colorized output."
  (let ((start-time (current-time))
        (safe-args (seq-remove #'null (append args '("--quiet"))))
        result exit-code)
    (jj--debug "Running color command: %s --color=always %s" jj-executable (string-join safe-args " "))
    (with-temp-buffer
      (let ((process-environment (cons "FORCE_COLOR=1" (cons "CLICOLOR_FORCE=1" process-environment))))
        (setq exit-code (apply #'process-file jj-executable nil t nil "--color=always" safe-args))
        (setq result (ansi-color-apply (buffer-string)))
        (jj--debug "Color command completed in %.3f seconds, exit code: %d"
                   (float-time (time-subtract (current-time) start-time))
                   exit-code)
        (when (and jj-show-command-output (not (string-empty-p result)))
          (jj--debug "Command output: %s" (string-trim result)))
        result))))

(defun jj--run-command-async (callback &rest args)
  "Run jj command with ARGS asynchronously and call CALLBACK with output."
  (jj--debug "Starting async command: %s %s" jj-executable (string-join args " "))
  (let ((buffer (generate-new-buffer " *jj-async*"))
        (start-time (current-time)))
    (set-process-sentinel
     (apply #'start-file-process "jj" buffer jj-executable args)
     (lambda (process _event)
       (let ((exit-code (process-exit-status process)))
         (jj--debug "Async command completed in %.3f seconds, exit code: %d"
                    (float-time (time-subtract (current-time) start-time))
                    exit-code)
         (when (eq (process-status process) 'exit)
           (with-current-buffer (process-buffer process)
             (funcall callback (buffer-string)))
           (kill-buffer (process-buffer process))))))))

(defun jj--suggest-help (command-name error-msg)
  "Provide helpful suggestions when COMMAND-NAME fails with ERROR-MSG."
  (let ((suggestions
         (cond
          ((string-match-p "No such revision" error-msg)
           "Try refreshing the log (g) or check if the commit still exists.")
          ((string-match-p "Working copy is stale" error-msg)
           "Run 'jj workspace update-stale' to fix stale working copy.")
          ((string-match-p "Merge conflict" error-msg)
           "Resolve conflicts manually or use jj diffedit (E or M).")
          ((string-match-p "nothing to squash" error-msg)
           "Select a different commit that has changes to squash.")
          ((string-match-p "would create a loop" error-msg)
           "Check your rebase selections - source and destinations create a cycle.")
          ((string-match-p "No changes" error-msg)
           "No changes to commit. Make some changes first.")
          ((and (string= command-name "git")
                (or (string-match-p "Refusing to push" error-msg)
                    (string-match-p "would create new heads" error-msg)
                    (string-match-p "new bookmark" error-msg)))
           "Use --allow-new flag to push new bookmarks.")
          ((and (string= command-name "git") (string-match-p "authentication" error-msg))
           "Check your git credentials and remote repository access.")
          (t "Check 'jj help' or enable debug mode (M-x customize-variable jj-debug) for more info."))))
    (when suggestions
      (jj--message-with-log "💡 %s" suggestions))))

(defun jj--handle-command-result (command-args result &optional success-msg error-msg)
  "Handle command result with proper error checking and messaging."
  (let ((trimmed-result (string-trim result))
        (command-name (car command-args)))
    (jj--debug "Command result for '%s': %s"
               (string-join command-args " ")
               trimmed-result)

    ;; Always show command output if it exists (like CLI)
    (unless (string-empty-p trimmed-result)
      (message "%s" trimmed-result))

    (cond
     ;; Check for various error indicators
     ((or (string-match-p "^Error:\\|^error:" trimmed-result)
          (string-match-p "^Warning:\\|^warning:" trimmed-result)
          (string-match-p "^fatal:" trimmed-result))

      ;; Provide jj-specific contextual suggestions
      (cond
       ;; Working copy issues
       ((string-match-p "working copy is stale\\|concurrent modification" trimmed-result)
        (message "💡 Run 'jj workspace update-stale' to fix the working copy"))

       ;; Conflict resolution needed
       ((string-match-p "merge conflict\\|conflict in" trimmed-result)
        (message "💡 Resolve conflicts manually, then run 'jj resolve' or use diffedit (E/M)"))

       ;; Revision not found
       ((string-match-p "No such revision\\|revision.*not found" trimmed-result)
        (message "💡 Check the revision ID or refresh the log (g)"))

       ;; Empty commit issues
       ((string-match-p "nothing to squash\\|would be empty" trimmed-result)
        (message "💡 Select a different commit with actual changes"))

       ;; Rebase loop detection
       ((string-match-p "would create a loop\\|circular dependency" trimmed-result)
        (message "💡 Check your rebase source and destinations for cycles"))

       ;; Authentication/permission issues
       ((string-match-p "authentication\\|permission denied" trimmed-result)
        (message "💡 Check your git credentials and repository access"))

       ;; Generic suggestion for other errors
       (t
        (message "💡 Check 'jj help %s' for more information" command-name)))
      nil)

     ;; Success case
     (t
      (when (and success-msg (string-empty-p trimmed-result))
        (message "%s" success-msg))
      t))))

(defun jj--with-progress (message command-func)
  "Execute COMMAND-FUNC with minimal progress indication."
  (let ((start-time (current-time))
        result)
    (jj--debug "Starting operation: %s" message)
    (setq result (funcall command-func))
    (jj--debug "Operation completed in %.3f seconds"
               (float-time (time-subtract (current-time) start-time)))
    result))

(defun jj--extract-bookmark-names (text)
  "Extract bookmark names from jj command output TEXT."
  (let ((names '())
        (start 0))
    (while (string-match "bookmark[: ]+\\([^ \n,]+\\)" text start)
      (push (match-string 1 text) names)
      (setq start (match-end 0)))
    (nreverse names)))


(defun jj--get-bookmark-names (&optional all-remotes)
  "Return bookmark names.
When ALL-REMOTES is non-nil, include remote bookmarks formatted as NAME@REMOTE."
  (let* ((template (if all-remotes
                       "if(remote, name ++ '@' ++ remote ++ '\n', '')"
                     "name ++ '\n'"))
         (args (append '("bookmark" "list")
                       (and all-remotes '("--all"))
                       (list "-T" template))))
    (delete-dups (split-string (apply #'jj--run-command args) "\n" t))))

(defun jj--handle-push-result (cmd-args result success-msg)
  "Enhanced push result handler with bookmark analysis."
  (let ((trimmed-result (string-trim result)))
    (jj--debug "Push result: %s" trimmed-result)

    ;; Always show the raw command output first (like CLI)
    (unless (string-empty-p trimmed-result)
      (message "%s" trimmed-result))

    (cond
     ;; Check for bookmark push restrictions
     ((or (string-match-p "Refusing to push" trimmed-result)
          (string-match-p "Refusing to create new remote bookmark" trimmed-result)
          (string-match-p "would create new heads" trimmed-result))
      ;; Extract bookmark names that couldn't be pushed
      (let ((bookmark-names (jj--extract-bookmark-names trimmed-result)))
        (if bookmark-names
            (message "💡 Use 'jj git push --allow-new' to push new bookmarks: %s"
                     (string-join bookmark-names ", "))
          (message "💡 Use 'jj git push --allow-new' to push new bookmarks")))
      nil)

     ;; Check for authentication issues
     ((string-match-p "Permission denied\\|authentication failed\\|403" trimmed-result)
      (message "💡 Check your git credentials and repository permissions")
      nil)

     ;; Check for network issues
     ((string-match-p "Could not resolve hostname\\|Connection refused\\|timeout" trimmed-result)
      (message "💡 Check your network connection and remote URL")
      nil)

     ;; Check for non-fast-forward issues
     ((string-match-p "non-fast-forward\\|rejected.*fetch first" trimmed-result)
      (message "💡 Run 'jj git fetch' first to update remote tracking")
      nil)

     ;; Analyze jj-specific push patterns and provide contextual help
     ((string-match-p "Nothing changed" trimmed-result)
      (message "💡 Nothing to push - all bookmarks are up to date")
      t)

     ;; General error check
     ((or (string-match-p "^error:" trimmed-result)
          (string-match-p "^fatal:" trimmed-result))
      nil)                              ; Error already shown above

     ;; Success case
     (t
      (when (string-empty-p trimmed-result)
        (message "%s" success-msg))
      t))))

(defclass jj-commit-section (magit-section)
  ((change-id :initarg :change-id)
   (commit-id :initarg :commit-id)
   (author :initarg :author)
   (date :initarg :date)
   (description :initarg :description)
   (bookmarks :initarg :bookmarks)
   ))

(defclass jj-commits-section (magit-section) ())
(defclass jj-status-section (magit-section) ())
(defclass jj-diff-stat-section (magit-section) ())
(defclass jj-log-graph-section (magit-section) ())
(defclass jj-log-entry-section (magit-section)
  ((change-id :initarg :change-id)
   (commit-id :initarg :commit-id)
   (description :initarg :description)
   (bookmarks :initarg :bookmarks)
   (prefix :initarg :prefix)))
(defclass jj-diff-section (magit-section) ())
(defclass jj-file-section (magit-section)
  ((file :initarg :file)))
(defclass jj-hunk-section (magit-section)
  ((file :initarg :file)
   (start :initarg :hunk-start)
   (header :initarg :header)))


(defun jj--format-short-diff-stat (diff-stat)
  "Parses +added-deleted stat from full diff stat to improve short stat generation.

Using self.diff().stat().total_added() and self.diff().stat().total_removed() directly
in addition to full self.diff().stat() would slow down template about 3 times,
because templating language does not support caching (yet) and diff will be
calculated 3 times."
  (when (and diff-stat
             (string-match "\\([0-9]+\\) insertions?(\\+), \\([0-9]+\\) deletions?(-)$" diff-stat))
    (let ((added (match-string 1 diff-stat))
          (removed (match-string 2 diff-stat)))
      (concat (propertize (format "+%s" added) 'font-lock-face 'jj-diff-stat-added)
              (propertize (format "-%s" removed) 'font-lock-face 'jj-diff-stat-removed)))))

(defun jj--optional-string-trim (str)
  "Wrapper around `'string-trim` that passes-through nil values without error"
  (and str (string-trim str)))

(defun jj--add-face (str face)
  "Like (propertize str 'font-lock-face face) but composes with existing faces on string."
  (font-lock-append-text-property 0 (length str) 'font-lock-face face str)
  str)

(defun jj-parse-log-entries (&optional buf)
  "Get log line pairs from BUF (defaults to `current-buffer').

This somewhat naively runs log, splits on newlines, and partitions the
lines into pairs.

Each pair SHOULD be (line-with-changeset-id-and-email description-line).

The results of this fn are fed into `jj--parse-log-entries'."
  (with-current-buffer (or buf (current-buffer))
    (let* ((args (append (list "log" "-T" (jj--format-log-template))
                         (when jj--log-revset (list "-r" jj--log-revset))))
           (log-output (apply #'jj--run-command-color args)))
      (when (and log-output (not (string-empty-p log-output)))
        (let ((lines (split-string log-output "\n" t)))
          (cl-loop for line in lines
                   for elems = (mapcar
                                (lambda (s) (unless (string-blank-p s) (string-trim s)))
                                (split-string line "\x1e" ))
                   when (> (length elems) 1) collect
                   (condition-case err
                       (let* ((metadata-json (car (last elems)))
                              (metadata (json-parse-string metadata-json :object-type 'plist))
                              (optional-diff-stat (plist-get metadata :diff-stat))
                              (short-diff-stat (jj--format-short-diff-stat optional-diff-stat)))
                         (seq-let (prefix change-id author bookmarks git-head conflict signature empty short-desc commit-id timestamp metadata-json) elems
                           (let ((body-prefix (jj--make-body-prefix prefix "")))
                             (list :id change-id
                                   :prefix prefix
                                   :heading (apply (cdr jj--render-log-entry-function) short-diff-stat body-prefix elems)
                                   :author author
                                   :commit-id commit-id
                                   :long-desc (jj--optional-string-trim (plist-get metadata :long-desc))
                                   :diff-stat (jj--optional-string-trim optional-diff-stat)
                                   :current-working-copy (plist-get metadata :current-working-copy)
                                   :trunk (plist-get metadata :trunk)
                                   :bookmarks bookmarks))))
                     (json-parse-error
                      ;; Skip lines with invalid JSON, specifically, zz root()
                      nil))
                   else collect
                   (list :heading line)))))))

(defun jj--expand-log-entry-template (template)
  (cond
   ((eq template 'multiline)
    '(change-id author timestamp bookmarks git-head commit-id conflict signature empty newline short-desc diff-stat))
   ((eq template 'oneline)
    '(change-id author bookmarks git-head conflict signature empty short-desc commit-id timestamp))
   ((listp template)
    template)
   (t (cons "Invalid jj-log-entry-template" (jj--expand-log-entry-template 'multiline)))))

(defun jj--create-render-log-entry-function (template)
  (let ((args '(diff-stat body-prefix prefix change-id author bookmarks git-head conflict signature empty short-desc commit-id timestamp metadata-json))
        (accum '((jj--add-face prefix 'jj-log-graph-fixed-pitch-face))))
    (dolist (field template)
      (cond
       ((eq field 'newline)
        (push "\n" accum)
        (push 'body-prefix accum))
       ((member field args)
        (push `(when ,field " ") accum)
        (push field accum))
       ;; Just render invalid stuff somehow
       (t (push (format " [%s]" field) accum))))
    (byte-compile
     `(lambda (,@args)
        (propertize (concat ,@(reverse accum)) 'wrap-prefix body-prefix)))))

(defun jj--cache-render-log-entry-function ()
  "Recreates jj--render-log-entry-function if template has changed"
  (unless (equal jj-log-entry-template (car jj--render-log-entry-function))
    (setq jj--render-log-entry-function
          (cons jj-log-entry-template
                (jj--create-render-log-entry-function
                 (jj--expand-log-entry-template jj-log-entry-template))))))


(defun jj--make-body-prefix (prefix suffix)
  "Computes line prefix for lines following first line of the log section.
It does it by replacing all non-space characters with vertical bar.
This procedure produces valid graph rendering"
  (let ((patched-prefix (concat (replace-regexp-in-string "\\S-" "│" prefix) suffix)))
    (propertize patched-prefix 'font-lock-face 'jj-log-graph-fixed-pitch-face)))


;; We need to advice `magit-section-show' and `magit-section-hide' with
;; adding/removing prefix on show/hid opertions, because otherwise
;; line-prefix will be applied to lines even when body is invisible
(defun jj--magit-section-show (section &optional end)
  (when (eq (oref section type) 'jj-log-entry-section)
    (let* ((prefix (oref section prefix))
           (body-prefix (jj--make-body-prefix prefix "   "))
           (start (oref section content))
           (end (or end (oref section end)))
           (inhibit-read-only t))
      (put-text-property start end 'line-prefix body-prefix)
      (put-text-property start end 'wrap-prefix body-prefix))))
(defun jj--magit-section-hide (section)
  (when (eq (oref section type) 'jj-log-entry-section)
    (let ((start (oref section content))
          (end (oref section end))
          (inhibit-read-only t))
      (remove-text-properties start end '(line-prefix wrap-prefix)))))
(advice-add 'magit-section-show :after 'jj--magit-section-show)
(advice-add 'magit-section-hide :after 'jj--magit-section-hide)


(defun jj--log-insert-entry (entry)
  (let* ((hide (not jj--expand-log-entries))
         (section-start (point))
         (id (plist-get entry :id))
         (prefix (plist-get entry :prefix))
         (heading (plist-get entry :heading)))
    (magit-insert-section section (jj-log-entry-section entry hide)
      (oset section change-id (plist-get entry :id))
      (oset section bookmarks (plist-get entry :bookmarks))
      (oset section commit-id (plist-get entry :commit-id))
      (oset section prefix prefix)
      (magit-insert-heading heading)
      (font-lock-append-text-property section-start (point) 'font-lock-face 'jj-log-graph-face)
      (cond
       ((eq (plist-get entry :current-working-copy) t)
        (font-lock-append-text-property section-start (point) 'font-lock-face 'jj-working-copy-heading))
       ((eq (plist-get entry :trunk) t)
        (font-lock-append-text-property section-start (point) 'font-lock-face 'jj-trunk-heading)))
      (magit-insert-section-body
        (let ((body-start (point))
              (long-desc (plist-get entry :long-desc))
              (diff-stat (plist-get entry :diff-stat)))
          (when (not (string-empty-p long-desc))
            (insert (jj--add-face (concat long-desc "\n") 'jj-log-graph-face)))
          (when (and diff-stat (not (string-empty-p diff-stat)))
            (insert (jj--add-face (concat "\n" diff-stat "\n") 'jj-log-graph-fixed-pitch-face)))
          (jj--magit-section-show section (point)))))))

(cl-defmethod magit-section-highlight ((section jj-log-graph-section))
  "No-op highlight method to disable highlighting for Log Graph section.")

(defun jj-log-insert-logs ()
  "Insert jj log graph into current buffer."
  (jj--cache-render-log-entry-function)
  (magit-insert-section section (jj-log-graph-section)
    (magit-insert-heading (concat "Log Graph"
                                  (when jj--log-revset (format ": %s" jj--log-revset))))
    (let ((graph-start (point)))
      (dolist (entry (jj-parse-log-entries))
        (if (plist-get entry :id)
            (jj--log-insert-entry entry)
          (insert (jj--add-face (concat (plist-get entry :heading) "\n") 'jj-log-graph-fixed-pitch-face)))))))

(defun jj-log-insert-status ()
  "Insert jj status into current buffer."
  (let ((status-output (jj--run-command-color "status")))
    (when (and status-output (not (string-empty-p status-output)))
      (magit-insert-section (jj-status-section)
        (magit-insert-heading "Working Copy Status")
        (insert status-output)
        (insert "\n")))))

(defun jj-log-insert-diff ()
  "Insert jj diff with hunks into current buffer."
  (let ((diff-output (jj--run-command-color "diff" "--git")))
    (when (and diff-output (not (string-empty-p diff-output)))
      (magit-insert-section (jj-diff-section)
        (magit-insert-heading "Working Copy Changes")
        (jj--insert-diff-hunks diff-output)
        (insert "\n")))))

(defun jj--insert-diff-hunks (diff-output)
  "Parse and insert diff output as navigable hunk sections."
  (let ((lines (split-string diff-output "\n"))
        current-file
        file-section-content
        in-file-section)
    (dolist (line lines)
      (let ((clean-line (substring-no-properties line)))
        (cond
         ;; File header
         ((and (string-match "^diff --git a/\\(.*\\) b/\\(.*\\)$" clean-line)
               (let ((file-a (match-string 1 clean-line))
                     (file-b (match-string 2 clean-line)))
                 ;; Process any pending file section
                 (when (and in-file-section current-file)
                   (jj--insert-file-section current-file file-section-content))
                 ;; Start new file section
                 (setq current-file (or file-b file-a)
                       file-section-content (list line)
                       in-file-section t)
                 t)) ;; Return t to satisfy the condition
          ;; This is just a placeholder - the real work is done in the condition above
          nil)
         ;; Accumulate lines for current file section
         (in-file-section
          (push line file-section-content))
         ;; Outside of any file section
         (t nil))))
    ;; Process final file section if any
    (when (and in-file-section current-file)
      (jj--insert-file-section current-file file-section-content))))

(defun jj--insert-file-section (file lines)
  "Insert a file section with its hunks."
  (magit-insert-section file-section (jj-file-section)
    (oset file-section file file)
    (insert (propertize (concat "modified   " file "\n")
                        'face 'magit-filename))
    ;; Process the lines to find and insert hunks
    (let ((remaining-lines (nreverse lines))
          hunk-lines
          in-hunk)
      (dolist (line remaining-lines)
        (cond
         ;; Start of a hunk
         ((string-match "^@@.*@@" line)
          ;; Insert previous hunk if any
          (when in-hunk
            (jj--insert-hunk-lines file (nreverse hunk-lines)))
          ;; Start new hunk
          (setq hunk-lines (list line)
                in-hunk t))
         ;; Skip header lines
         ((string-match "^\\(diff --git\\|index\\|---\\|\\+\\+\\+\\|new file\\|deleted file\\)" line)
          nil)
         ;; Accumulate hunk lines
         (in-hunk
          (push line hunk-lines))))
      ;; Insert final hunk if any
      (when in-hunk
        (jj--insert-hunk-lines file (nreverse hunk-lines))))))

(defun jj--insert-hunk-lines (file lines)
  "Insert a hunk section from LINES."
  (when lines
    (let ((header-line (car lines)))
      (when (string-match "^\\(@@.*@@\\)\\(.*\\)$" header-line)
        (let ((header (match-string 1 header-line))
              (context (match-string 2 header-line)))
          (magit-insert-section hunk-section (jj-hunk-section)
            (oset hunk-section file file)
            (oset hunk-section header header)
            ;; Insert the hunk header
            (insert (propertize header 'face 'magit-diff-hunk-heading))
            (when (and context (not (string-empty-p context)))
              (insert (propertize context 'face 'magit-diff-hunk-heading)))
            (insert "\n")
            ;; Insert the hunk content
            (dolist (line (cdr lines))
              (cond
               ((string-prefix-p "+" line)
                (insert (propertize line 'face 'magit-diff-added) "\n"))
               ((string-prefix-p "-" line)
                (insert (propertize line 'face 'magit-diff-removed) "\n"))
               (t
                (insert (propertize line 'face 'magit-diff-context) "\n"))))))))))

;;;###autoload
(cl-defun jj-log (&key revset expand-entries)
  "Display jj log in a magit-style buffer."
  (interactive)
  (let* ((repo-root (jj--root))
         (buffer-name (format "*jj-log:%s*" (file-name-nondirectory (directory-file-name repo-root))))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (default-directory repo-root)
            (inhibit-modification-hooks t))
        (erase-buffer)
        (jj-mode)
        (funcall jj-log-display-function buffer)
        (setq-local jj--log-revset revset)
        (setq-local jj--expand-log-entries expand-entries)
        (setq-local jj--repo-root repo-root)
        (magit-insert-section (jjbuf)  ; Root section wrapper
          (magit-insert-section-body
            (magit-run-section-hook 'jj-log-sections-hook))
          (insert "\n"))
        (jj-goto-current)))))

(defun jj-log-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the jj log buffer."
  (interactive)
  (when (derived-mode-p 'jj-mode)
    (jj--with-progress "Refreshing log view"
                       (lambda ()
                         (let ((inhibit-read-only t)
                               (pos (point))
                               (default-directory (jj--root))
                               (selected-changeset (jj-get-changeset-at-point)))
                           (erase-buffer)
                           (magit-insert-section (jjbuf)  ; Root section wrapper
                             (magit-run-section-hook 'jj-log-sections-hook))
                           (or (and selected-changeset (jj-goto-commit selected-changeset t))
                               (goto-char pos))
                           (jj--debug "Log refresh completed"))))))

(defun jj-enter-dwim ()
  "Context-sensitive Enter key behavior."
  (interactive)
  (let ((section (magit-current-section)))
    (cond
     ;; On a changeset/commit - edit it with jj edit
     ((and section
           (memq (oref section type) '(jj-log-entry-section jj-commit-section))
           (slot-boundp section 'change-id))
      (jj-edit-changeset-at-point))

     ;; On a diff hunk line - jump to that line in the file
     ((and section
           (eq (oref section type) 'jj-hunk-section)
           (slot-boundp section 'file))
      (jj-goto-diff-line))

     ;; On a file section - visit the file
     ((and section
           (eq (oref section type) 'jj-file-section)
           (slot-boundp section 'file))
      (jj-visit-file)))))

(defun jj-edit-changeset-at-point ()
  "Edit the commit at point using jj edit."
  (interactive)
  (when-let ((change-id (jj-get-changeset-at-point)))
    (let ((result (jj--run-command "edit" change-id)))
      (if (jj--handle-command-result (list "edit" change-id) result
                                     (format "Now editing commit %s" change-id)
                                     "Failed to edit commit")
          (progn
            (jj-log-refresh)
            (back-to-indentation))))))

(defun jj-goto-diff-line ()
  "Jump to the line in the file corresponding to the diff line at point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (_ (eq (oref section type) 'jj-hunk-section))
              (file (oref section file))
              (header (oref section header))
              (repo-root (jj--root)))
    ;; Parse the hunk header to get line numbers
    (when (string-match "^@@.*\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?.*@@" header)
      (let* ((start-line (string-to-number (match-string 1 header)))
             ;; Calculate which line within the hunk we're on
             (hunk-start (oref section start))
             (current-pos (point))
             (line-offset 0)
             (full-file-path (expand-file-name file repo-root)))
        ;; Count lines from hunk start to current position
        (save-excursion
          (goto-char hunk-start)
          (forward-line 1) ; Skip hunk header
          (while (< (point) current-pos)
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              ;; Only count context and added lines for line numbering
              (unless (string-prefix-p "-" line)
                (setq line-offset (1+ line-offset))))
            (forward-line 1)))
        ;; Open file and jump to calculated line
        (let ((target-line (+ start-line line-offset -1))) ; -1 because we start counting from the header
          (find-file full-file-path)
          (goto-char (point-min))
          (forward-line (max 0 target-line))
          (message "Jumped to line %d in %s" (1+ target-line) file))))))

(defun jj-visit-file ()
  "Visit the file at point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (file (oref section file))
              (repo-root (jj--root)))
    (let ((full-file-path (expand-file-name file repo-root)))
      (find-file full-file-path))))

(defun jj-diffedit-emacs ()
  "Emacs-based diffedit using built-in ediff."
  (interactive)
  (let* ((default-directory (jj--root))
         (section (magit-current-section))
         (file (cond
                ((and section (eq (oref section type) 'jj-file-section))
                 (oref section file))
                ((and section (eq (oref section type) 'jj-hunk-section))
                 (oref section file))
                (t nil))))
    (if file
        (jj-diffedit-with-ediff file)
      (jj-diffedit-all))))

(defun jj-diffedit-with-ediff (file)
  "Open ediff session for a specific file against parent."
  (let* ((repo-root (jj--root))
         (full-file-path (expand-file-name file repo-root))
         (file-ext (file-name-extension file))
         (parent-temp-file (make-temp-file (format "jj-parent-%s" (file-name-nondirectory file))
                                           nil (when file-ext (concat "." file-ext))))
         (parent-content (let ((default-directory repo-root))
                           (jj--run-command "file" "show" "-r" "@-" file))))

    ;; Write parent content to temp file
    (with-temp-file parent-temp-file
      (insert parent-content)
      ;; Enable proper major mode for syntax highlighting
      (when file-ext
        (let ((mode (assoc-default (concat "." file-ext) auto-mode-alist 'string-match)))
          (when mode
            (funcall mode)))))

    ;; Set up cleanup
    (add-hook 'ediff-quit-hook
              `(lambda ()
                 (when (file-exists-p ,parent-temp-file)
                   (delete-file ,parent-temp-file))
                 (jj-log-refresh))
              nil t)

    ;; Start ediff session
    (ediff-files parent-temp-file full-file-path)
    (message "Ediff: Left=Parent (@-), Right=Current (@). Edit right side, then 'q' to quit and save.")))

(defun jj-diffedit-smerge ()
  "Emacs-based diffedit using smerge-mode (merge conflict style)."
  (interactive)
  (let* ((section (magit-current-section))
         (file (cond
                ((and section (eq (oref section type) 'jj-file-section))
                 (oref section file))
                ((and section (eq (oref section type) 'jj-hunk-section))
                 (oref section file))
                (t nil))))
    (if file
        (jj-diffedit-with-smerge file)
      (jj-diffedit-all))))

(defun jj-diffedit-with-smerge (file)
  "Open smerge-mode session for a specific file."
  (let* ((repo-root (jj--root))
         (full-file-path (expand-file-name file repo-root))
         (parent-content (let ((default-directory repo-root))
                           (jj--run-command "file" "show" "-r" "@-" file)))
         (current-content (if (file-exists-p full-file-path)
                              (with-temp-buffer
                                (insert-file-contents full-file-path)
                                (buffer-string))
                            ""))
         (merge-buffer (get-buffer-create (format "*jj-smerge-%s*" (file-name-nondirectory file)))))

    (with-current-buffer merge-buffer
      (erase-buffer)

      ;; Create merge-conflict format
      (insert "<<<<<<< Parent (@-)\n")
      (insert parent-content)
      (unless (string-suffix-p "\n" parent-content)
        (insert "\n"))
      (insert "=======\n")
      (insert current-content)
      (unless (string-suffix-p "\n" current-content)
        (insert "\n"))
      (insert ">>>>>>> Current (@)\n")

      ;; Enable smerge-mode
      (smerge-mode 1)
      (setq-local jj-smerge-file file)
      (setq-local jj-smerge-repo-root repo-root)

      ;; Add save hook
      (add-hook 'after-save-hook 'jj-smerge-apply-changes nil t)

      (goto-char (point-min)))

    (switch-to-buffer-other-window merge-buffer)
    (message "SMerge mode: Use C-c ^ commands to navigate/resolve conflicts, then save to apply.")))

(defun jj-smerge-apply-changes ()
  "Apply smerge changes to the original file."
  (when (and (boundp 'jj-smerge-file) jj-smerge-file)
    (let* ((file jj-smerge-file)
           (repo-root jj-smerge-repo-root)
           (full-file-path (expand-file-name file repo-root))
           (content (buffer-string)))

      ;; Only apply if no conflict markers remain
      (unless (or (string-match "^<<<<<<<" content)
                  (string-match "^=======" content)
                  (string-match "^>>>>>>>" content))
        (with-temp-file full-file-path
          (insert content))
        (jj-log-refresh)
        (message "Changes applied to %s" file)))))

(defun jj-diffedit-all ()
  "Open diffedit interface for all changes."
  (let* ((changed-files (jj--get-changed-files))
         (choice (if (= (length changed-files) 1)
                     (car changed-files)
                   (completing-read "Edit file: " changed-files))))
    (when choice
      (jj-diffedit-with-ediff choice))))

(defun jj--get-changed-files ()
  "Get list of files with changes in working copy."
  (let ((diff-output (jj--run-command "diff" "--name-only")))
    (split-string diff-output "\n" t)))

(defun jj-edit-changeset ()
  "Edit commit at point."
  (interactive)
  (when-let ((change-id (jj-get-changeset-at-point)))
    (let ((result (jj--run-command "edit" change-id)))
      (if (jj--handle-command-result (list "edit" change-id) result
                                     (format "Now editing changeset %s" change-id)
                                     "Failed to edit commit")
          (jj-log-refresh)))))

;; Squash state management
(defvar-local jj-squash-from nil
  "Currently selected 'from' commit for squash.")

(defvar-local jj-squash-into nil
  "Currently selected 'into' commit for squash.")

(defvar-local jj-squash-from-overlay nil
  "Overlay for highlighting the selected 'from' commit.")

(defvar-local jj-squash-into-overlay nil
  "Overlay for highlighting the selected 'into' commit.")

(defun jj--make-commit-overlay (section text face)
  (let* ((section-start (oref section start))
         (prefix (oref section prefix))
         (child-pos (+ section-start (length prefix)))
         (child (make-overlay child-pos child-pos))
         (heading-end (or (oref section content) (oref section end)))
         (overlay (make-overlay section-start heading-end)))
    (overlay-put overlay 'jj--child child)
    (overlay-put overlay 'face face)
    (overlay-put child 'before-string (propertize text 'face `(:weight bold ,@face)))
    overlay))

(defun jj--delete-overlay (overlay)
  (when-let ((child-overlay (overlay-get overlay 'jj--child)))
    (delete-overlay child-overlay))
  (delete-overlay overlay))

;;;###autoload
(defun jj-squash-clear-selections ()
  "Clear all squash selections and overlays."
  (interactive)
  (setq jj-squash-from nil
        jj-squash-into nil)
  (when jj-squash-from-overlay
    (jj--delete-overlay jj-squash-from-overlay)
    (setq jj-squash-from-overlay nil))
  (when jj-squash-into-overlay
    (jj--delete-overlay jj-squash-into-overlay)
    (setq jj-squash-into-overlay nil))
  (message "Cleared all squash selections"))

;;;###autoload
(defun jj-squash-set-from ()
  "Set the commit at point as squash `from' source."
  (interactive)
  (when-let ((change-id (jj-get-changeset-at-point))
             (section (magit-current-section)))
    ;; Clear previous from overlay
    (when jj-squash-from-overlay
      (jj--delete-overlay jj-squash-from-overlay))
    ;; Set new from
    (setq jj-squash-from change-id)
    ;; Create overlay for visual indication
    (setq jj-squash-from-overlay
          (jj--make-commit-overlay
           section " [FROM] "
           '(:background "dark orange" :foreground "white" :extend t)))
    (message "Set from: %s" change-id)))

;;;###autoload
(defun jj-squash-set-into ()
  "Set the commit at point as squash 'into' destination."
  (interactive)
  (when-let ((change-id (jj-get-changeset-at-point))
             (section (magit-current-section)))
    ;; Clear previous into overlay
    (when jj-squash-into-overlay
      (jj--delete-overlay jj-squash-into-overlay))
    ;; Set new into
    (setq jj-squash-into change-id)
    ;; Create overlay for visual indication
    (setq jj-squash-into-overlay
          (jj--make-commit-overlay
           section " [INTO]"
           '(:background "dark cyan" :foreground "white" :extend t)))
    (message "Set into: %s" change-id)))

;;;###autoload
(defun jj-squash-execute (&optional args)
  "Execute squash with selected from and into commits."
  (interactive (list (transient-args 'jj-squash-transient--internal)))
  (let ((keep-commit (member "--keep" args)))
    (cond
     ;; Both from and into selected
     ((and jj-squash-from jj-squash-into)
      (let* ((into-desc (string-trim (jj--run-command "log" "-r" jj-squash-into "--no-graph" "-T" "description")))
             (from-desc (string-trim (jj--run-command "log" "-r" jj-squash-from "--no-graph" "-T" "description")))
             (combined-desc (if (string-empty-p into-desc)
                                from-desc
                              into-desc))) ; Keep into message by default
        (jj--open-message-buffer "SQUASH_MSG"
                                 (format "jj squash --from %s --into %s" jj-squash-from jj-squash-into)
                                 'jj--squash-finish
                                 (list :from jj-squash-from :into jj-squash-into :keep keep-commit)
                                 combined-desc)))
     ;; Only from selected - use default behavior (squash into parent)
     (jj-squash-from
      (let* ((parent-desc (string-trim (jj--run-command "log" "-r" (format "%s-" jj-squash-from) "--no-graph" "-T" "description")))
             (from-desc (string-trim (jj--run-command "log" "-r" jj-squash-from "--no-graph" "-T" "description")))
             (combined-desc (if (string-empty-p parent-desc)
                                from-desc
                              parent-desc))) ; Keep parent message by default
        (jj--open-message-buffer "SQUASH_MSG"
                                 (format "jj squash -r %s" jj-squash-from)
                                 'jj--squash-finish
                                 (list :from jj-squash-from :into nil :keep keep-commit)
                                 combined-desc)))
     ;; No selection - use commit at point
     (t
      (if-let ((change-id (jj-get-changeset-at-point)))
          (let* ((parent-desc (string-trim (jj--run-command "log" "-r" (format "%s-" change-id) "--no-graph" "-T" "description")))
                 (commit-desc (string-trim (jj--run-command "log" "-r" change-id "--no-graph" "-T" "description")))
                 (combined-desc (if (string-empty-p parent-desc)
                                    commit-desc
                                  parent-desc))) ; Keep parent message by default
            (jj--open-message-buffer "SQUASH_MSG"
                                     (format "jj squash -r %s" change-id)
                                     'jj--squash-finish
                                     (list :from change-id :into nil :keep keep-commit)
                                     combined-desc))
        (jj--message-with-log "No commit selected for squash"))))))

(defun jj--do-squash (from into keep-commit message)
  "Perform the actual squash operation."
  (let* ((cmd-args (cond
                    ;; Both from and into specified
                    ((and from into)
                     (append (list "squash" "--from" from "--into" into)
                             (when keep-commit (list "--keep-emptied"))
                             (when message (list "-m" message))))
                    ;; Only from specified (squash into parent)
                    (from
                     (append (list "squash" "-r" from)
                             (when keep-commit (list "--keep-emptied"))
                             (when message (list "-m" message))))
                    (t nil)))
         (progress-msg (if into
                           (format "Squashing %s into %s" from into)
                         (format "Squashing %s into its parent" from)))
         (success-msg (if into
                          (format "Squashed %s into %s" from into)
                        (format "Squashed %s into its parent" from))))
    (when cmd-args
      (jj--message-with-log "%s..." progress-msg)
      (let ((result (apply #'jj--run-command cmd-args)))
        (if (jj--handle-command-result cmd-args result success-msg "Squash failed")
            (progn
              (jj-squash-clear-selections)
              (jj-log-refresh)))))))

(defun jj--squash-finish (message &optional squash-params)
  "Finish squash with MESSAGE and SQUASH-PARAMS."
  (when squash-params
    (let ((from (plist-get squash-params :from))
          (into (plist-get squash-params :into))
          (keep (plist-get squash-params :keep)))
      (jj--do-squash from into keep message))))

(defun jj-squash-cleanup-on-exit ()
  "Clean up squash selections when transient exits."
  (unless (eq this-command 'jj-mode-bury-squash)
    (jj-squash-clear-selections)
    (remove-hook 'transient-exit-hook 'jj-squash-cleanup-on-exit t)))

;; Squash transient menu
;;;###autoload
(defun jj-squash-transient ()
  "Transient for jj squash operations."
  (interactive)
  ;; Add cleanup hook for when transient exits
  (add-hook 'transient-exit-hook 'jj-squash-cleanup-on-exit nil t)
  (jj-squash-transient--internal))

(transient-define-prefix jj-squash-transient--internal ()
  "Internal transient for jj squash operations."
  :transient-suffix 'transient--do-exit
  :transient-non-suffix t
  [:description
   (lambda ()
     (concat "JJ Squash"
             (when jj-squash-from
               (format " | From: %s" jj-squash-from))
             (when jj-squash-into
               (format " | Into: %s" jj-squash-into))))
   ["Selection"
    ("f" "Set from" jj-squash-set-from
     :description (lambda ()
                    (if jj-squash-from
                        (format "Set from (current: %s)" jj-squash-from)
                      "Set from"))
     :transient t)
    ("t" "Set into" jj-squash-set-into
     :description (lambda ()
                    (if jj-squash-into
                        (format "Set into (current: %s)" jj-squash-into)
                      "Set into"))
     :transient t)
    ("c" "Clear selections" jj-squash-clear-selections
     :transient t)]
   ["Options"
    ("-k" "Keep emptied commit" "--keep")]
   ["Actions"
    ("s" "Execute squash" jj-squash-execute
     :description (lambda ()
                    (cond
                     ((and jj-squash-from jj-squash-into)
                      (format "Squash %s into %s" jj-squash-from jj-squash-into))
                     (jj-squash-from
                      (format "Squash %s into parent" jj-squash-from))
                     (t "Execute squash (select commits first)")))
     :transient nil)
    ("q" "Quit" transient-quit-one)
    ("b" "Bury" jj-mode-bury-squash)]])

(defun jj-mode-bury-squash ()
  (interactive)
  (transient-quit-one))

(defun jj-squash-into-parent ()
  "Squash changeset at point into parent"
  (interactive)
  ;; Add cleanup hook for when transient exits
  (when-let ((change-id (jj-get-changeset-at-point)))
    (let* ((args (list "squash" "--from" change-id "--into" (format "%s-" change-id)))
           (result (apply #'jj--run-command args)))
      (if (jj--handle-command-result args result
                                     (format "Squashed %s" change-id)
                                     "Failed to squash commit")
          (progn
            (jj-log-refresh)
            (back-to-indentation))))))

(defun jj-bookmark-create ()
  "Create a new bookmark."
  (interactive)
  (let* ((change-id (or (jj-get-changeset-at-point) "@"))
         (name (read-string "Bookmark name: ")))
    (unless (string-empty-p name)
      (jj--run-command "bookmark" "create" name "-r" change-id)
      (jj-log-refresh))))

(defun jj-bookmark-delete ()
  "Delete a bookmark (propagates on push)."
  (interactive)
  (let* ((names (jj--get-bookmark-names))
         (choice (and names (completing-read "Delete bookmark (propagates on push): " names nil t))))
    (if (not choice)
        (message "No bookmarks found")
      (when (yes-or-no-p (format "Delete bookmark '%s' (propagates on push)? " choice))
        (let ((default-directory (jj--root)))
          (let ((result (jj--run-command "bookmark" "delete" choice)))
            (when (jj--handle-command-result (list "bookmark" "delete" choice) result
                                             (format "Deleted bookmark '%s'" choice)
                                             "Failed to delete bookmark")
              (jj-log-refresh))))))))

(defun jj-bookmark-forget ()
  "Forget a bookmark (no propagation)."
  (interactive)
  (let* ((names (jj--get-bookmark-names))
         (choice (and names (completing-read "Forget bookmark: " names nil t))))
    (if (not choice)
        (message "No bookmarks found")
      (when (yes-or-no-p (format "Forget bookmark '%s' locally)? " choice))
        (let ((default-directory (jj--root)))
          (let ((result (jj--run-command "bookmark" "forget" choice)))
            (when (jj--handle-command-result (list "bookmark" "forget" choice) result
                                             (format "Forgot bookmark '%s'" choice)
                                             "Failed to forget bookmark")
              (jj-log-refresh))))))))

(defun jj-bookmark-track ()
  "Track remote bookmark(s)."
  (interactive)
  (let* ((remote-bookmarks (jj--get-bookmark-names t))
         (choice (and remote-bookmarks (completing-read "Track remote bookmark: " remote-bookmarks nil t))))
    (if (not choice)
        (message "No remote bookmarks found")
      (let ((default-directory (jj--root)))
        (let ((result (jj--run-command "bookmark" "track" choice)))
          (when (jj--handle-command-result (list "bookmark" "track" choice) result
                                           (format "Tracking bookmark '%s'" choice)
                                           "Failed to track bookmark")
            (jj-log-refresh)))))))

;;;###autoload
(defun jj-bookmark-list (&optional all)
  "List bookmarks in a temporary buffer.
With prefix ALL, include remote bookmarks."
  (interactive "P")
  (let* ((args (append '("bookmark" "list") (and all '("--all"))))
         (output (apply #'jj--run-command-color args))
         (buf (get-buffer-create "*JJ Bookmarks*")))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert output)
      (goto-char (point-min))
      (view-mode 1))
    (funcall jj-log-display-function buf)))

;;;###autoload
(defun jj-bookmark-move (commit names)
  "Move existing bookmark(s) NAMES to COMMIT."
  (interactive
   (let* ((existing (jj--get-bookmark-names))
          (crm-separator (or (bound-and-true-p crm-separator) ", *"))
          (names (completing-read-multiple "Move bookmark(s): " existing nil t))
          (at (or (jj-get-changeset-at-point) "@"))
          (rev (read-string (format "Target revision (default %s): " at) nil nil at)))
     (list rev names)))
  (when names
    (apply #'jj--run-command (append '("bookmark" "move" "-t" ) (list commit) names))
    (jj-log-refresh)
    (message "Moved bookmark(s) to %s: %s" commit (string-join names ", "))))

;;;###autoload
(defun jj-bookmark-rename (old new)
  "Rename bookmark OLD to NEW."
  (interactive
   (let* ((existing (jj--get-bookmark-names))
          (_ (when (null existing) (user-error "No bookmarks found")))
          (old (completing-read "Rename bookmark: " existing nil t))
          (new (read-string (format "New name for %s: " old))))
     (list old new)))
  (when (and (not (string-empty-p old)) (not (string-empty-p new)))
    (let ((default-directory (jj--root)))
      (let ((result (jj--run-command "bookmark" "rename" old new)))
        (when (jj--handle-command-result (list "bookmark" "rename" old new) result
                                         (format "Renamed bookmark '%s' -> '%s'" old new)
                                         "Failed to rename bookmark")
          (jj-log-refresh))))))

;;;###autoload
(defun jj-bookmark-set (name commit &optional args)
  "Create or update bookmark NAME to point to COMMIT.
ARGS can be transient related infix, for example
 --allow-backwards."
  (interactive
   (let* ((existing (jj--get-bookmark-names))
          (name (completing-read "Set bookmark: " existing nil nil))
          (at (or (jj-get-changeset-at-point) "@"))
          (rev (read-string (format "Target revision (default %s): " at) nil nil at)))
     (append (list name rev) (list (transient-args 'jj-bookmark-transient--internal)))))
  (let* ((default-directory (jj--root))
         (allow-backwards (when (transient-arg-value "--allow-backwards" args) "--allow-backwards"))
         (cmd-args (list "bookmark" "set" name "-r" commit allow-backwards)))
    (let ((result (apply #'jj--run-command cmd-args)))
      (when (jj--handle-command-result cmd-args result
                                       (format "Set bookmark '%s' to %s" name commit)
                                       "Failed to set bookmark")
        (jj-log-refresh)))))

;;;###autoload
(defun jj-bookmark-untrack (names)
  "Stop tracking remote bookmark(s) NAMES (e.g., name@remote)."
  (interactive
   (let* ((remote-names (jj--get-bookmark-names t))
          (crm-separator (or (bound-and-true-p crm-separator) ", *"))
          (names (completing-read-multiple "Untrack remote bookmark(s): " remote-names nil t)))
     (list names)))
  (when names
    (let ((default-directory (jj--root)))
      (let* ((cmd (append '("bookmark" "untrack") names))
             (result (apply #'jj--run-command cmd)))
        (when (jj--handle-command-result cmd result
                                         (format "Untracked: %s" (string-join names ", "))
                                         "Failed to untrack")
          (jj-log-refresh))))))


(defun jj-tug ()
  "Run jj tug command."
  (interactive)
  (let* ((rev (or (jj-get-changeset-at-point) "@"))
         (result (jj--run-command "bookmark" "move" "--from" (format "heads(::%s & bookmarks())" rev) "--to" rev)))
    (jj-log-refresh)
    (message "Tug completed: %s" (string-trim result))))

;; Bookmark transient menu
;;;###autoload
(defun jj-bookmark-transient ()
  "Transient for jj bookmark operations."
  (interactive)
  (jj-bookmark-transient--internal))

(transient-define-prefix jj-bookmark-transient--internal ()
  "Internal transient for jj bookmark operations."
  :transient-suffix 'transient--do-exit
  :transient-non-suffix t
  ["Arguments"
   ("-B" "Allow backwards" "--allow-backwards")]
  ["Bookmark Operations"
   [
    ("l" "List bookmarks" jj-bookmark-list
     :description "Show bookmark list" :transient nil)
    ("c" "Create bookmark" jj-bookmark-create
     :description "Create new bookmark" :transient nil)
    ("T" "Tug bookmark" jj-tug
     :description "Tug bookmark to recent commit"
     :transient nil)]
   [
    ("s" "Set bookmark" jj-bookmark-set
     :description "Create/update to commit" :transient nil)
    ("m" "Move bookmark(s)" jj-bookmark-move
     :description "Move existing to commit" :transient nil)
    ("r" "Rename bookmark" jj-bookmark-rename
     :description "Rename existing bookmark" :transient nil)]
   [
    ("t" "Track remote" jj-bookmark-track
     :description "Track remote bookmark" :transient nil)
    ("u" "Untrack remote" jj-bookmark-untrack
     :description "Stop tracking remote" :transient nil)]
   [
    ("d" "Delete bookmark" jj-bookmark-delete
     :description "Delete (propagate)" :transient nil)
    ("f" "Forget bookmark" jj-bookmark-forget
     :description "Forget (local)" :transient nil)]
   [("q" "Quit" transient-quit-one)]])

(defun jj-undo ()
  "Undo the last change."
  (interactive)
  (let ((result (jj--run-command "undo")))
    (when (jj--handle-command-result
           (list "undo") result
           "Undid last change"
           "Undo failed")
      (jj-log-refresh))))

(defun jj-abandon ()
  "Abandon a changeset."
  (interactive)
  (if-let ((change-id (jj-get-changeset-at-point)))
      (progn
        (jj--run-command "abandon" "-r" change-id)
        (jj-log-refresh))
    (message "Can only run abandon on a change")))

(defun jj-new (arg)
  "Create a new changeset.
With prefix ARG, open the transient menu for advanced options."
  (interactive "P")
  (if arg
      (jj-new-transient)
    (let* ((base (jj-get-changeset-at-point)))
      (if (not base)
          (user-error "Can only run new on a change")
        (let ((result (jj--run-command "new" "-r" base)))
          (when (jj--handle-command-result
                 (list "new" "-r" base)
                 result
                 "Created new changeset"
                 "Failed to create new changeset")
            (jj-log-refresh)
            (jj-goto-current)))))))

;; New transient menu
;;;###autoload
(defun jj-new-transient ()
  "Transient for jj new operations."
  (interactive)
  (jj-new-transient--internal))

(transient-define-prefix jj-new-transient--internal ()
  "Internal transient for jj new operations."
  :transient-suffix 'transient--do-exit
  :transient-non-suffix t
  [:description "JJ New"
   :class transient-columns
   ["Arguments"
    ("-r" "Parent revision(s)" "--parent=")
    ("-b" "Bookmark (or change id)" "--bookmark="
     :choices (lambda ()
                (jj--get-bookmark-names t)))
    ("-m" "Message" "--message=")
    ("-n" "No edit" "--no-edit")]
   ["Actions"
    ("n" "Create new changeset" jj-new-execute
     :transient nil)
    ("a" "Create after changeset" jj-new-after
     :transient nil)
    ("b" "Create before changeset" jj-new-before
     :transient nil)
    ("q" "Quit" transient-quit-one)]])

;;;###autoload
(defun jj-new-execute (&optional args)
  "Execute jj new with ARGS from transient."
  (interactive (list (transient-args 'jj-new-transient--internal)))
  (let* ((no-edit? (member "--no-edit" args))

         ;; Extract option arguments
         (parent-args (seq-filter (lambda (arg) (string-prefix-p "--parent=" arg)) args))
         (after-args (seq-filter (lambda (arg) (string-prefix-p "--insert-after=" arg)) args))
         (before-args (seq-filter (lambda (arg) (string-prefix-p "--insert-before=" arg)) args))
         (message-arg (seq-find (lambda (arg) (string-prefix-p "--message=" arg)) args))
         (bookmark-arg (transient-arg-value "--bookmark=" args))

         ;; Build command arguments
         (cmd-args (append '("new")
                           (when no-edit? '("--no-edit"))
                           (when message-arg
                             (list "-m" (substring message-arg (length "--message="))))
                           ;; Add --insert-after arguments
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--insert-after" (substring s (length "--insert-after="))))
                                                   after-args))
                           ;; Add --insert-before arguments
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--insert-before" (substring s (length "--insert-before="))))
                                                   before-args))
                           ;; Add parent revisions as positional arguments
                           (apply #'append (mapcar (lambda (s)
                                                     (list (substring s (length "--parent="))))
                                                   parent-args))))

         ;; Default to current changeset if no parents/after/before specified
         (final-cmd-args (if (and (null parent-args) (null after-args) (null before-args))
                             (let ((change-id (or bookmark-arg
                                                  (jj-get-changeset-at-point))))
                               (if change-id
                                   (append cmd-args (list change-id))
                                 cmd-args))
                           cmd-args)))

    (let ((result (apply #'jj--run-command final-cmd-args)))
      (when (jj--handle-command-result
             final-cmd-args
             result
             "Created new changeset"
             "Failed to create new changeset")
        (jj-log-refresh)
        (jj-goto-current)))))

;;;###autoload
(defun jj-new-after (&optional args)
  "Create a new changeset after an existing one.

Optionally takes a list like (\"--bookmark=bookmark-or-changeid-to-use\")
indicating where to create the new changeset.

Designed to receive ARGS from transient."
  (interactive (list (transient-args 'jj-new-transient--internal)))
  (let ((revset (or (transient-arg-value "--bookmark=" args)
                    (jj-get-changeset-at-point)
                    (completing-read "Change id: " (jj--get-bookmark-names t)))))
    (jj-new-execute (cons (format "--insert-after=%s" revset) args))))

;;;###autoload
(defun jj-new-before (&optional args)
  "Create a new changeset before an existing one.

Optionally takes a list like (\"--bookmark=bookmark-or-changeid-to-use\")
indicating where to create the new changeset.

Designed to receive ARGS from transient."
  (interactive (list (transient-args 'jj-new-transient--internal)))
  (let ((revset (or (transient-arg-value "--bookmark=" args)
                    (jj-get-changeset-at-point)
                    (completing-read "Change id: " (jj--get-bookmark-names t)))))
    (jj-new-execute (cons (format "--insert-before=%s" revset) args))))

(defun jj-goto-current ()
  "Jump to the current changeset (@)."
  (interactive)
  (goto-char (point-min))
  (if (re-search-forward "^.*@.*$" nil t)
      (goto-char (line-beginning-position))
    (message "Current changeset (@) not found")))

(defun jj-goto-commit (change-id &optional silent)
  "Jump to a specific CHANGE-ID in the log. Returns truthy value on success."
  (interactive "sChange ID: ")
  (let ((start-pos (point)))
    (goto-char (point-min))
    (if (re-search-forward (regexp-quote change-id) nil t)
        (goto-char (line-beginning-position))
      (goto-char start-pos)
      (unless silent
        (message "Change %s not found" change-id))
      nil)))

(defun jj--get-git-remotes ()
  "Return a list of Git remote names for the current repository.
Tries `jj git remote list' first, then falls back to `git remote'."
  (let* ((out (condition-case _
                  (jj--run-command "git" "remote" "list")
                (error "")))
         (names (if (and out (not (string-empty-p out)))
                    (let* ((lines (split-string out "\n" t))
                           (names (mapcar (lambda (l)
                                            (car (split-string l "[ :\t]" t)))
                                          lines)))
                      (delete-dups (copy-sequence names)))
                  ;; Fallback to plain `git remote`
                  (with-temp-buffer
                    (let* ((default-directory (jj--root))
                           (exit (process-file "git" nil t nil "remote")))
                      (when (eq exit 0)
                        (split-string (buffer-string) "\n" t)))))))
    names))

(defun jj-git-push (args)
  "Push to git remote with ARGS."
  (interactive (list (transient-args 'jj-git-push-transient)))
  (let* ((allow-new? (member "--allow-new" args))
         (all? (member "--all" args))
         (tracked? (member "--tracked" args))
         (deleted? (member "--deleted" args))
         (allow-empty? (member "--allow-empty-description" args))
         (allow-private? (member "--allow-private" args))
         (dry-run? (member "--dry-run" args))

         (remote-arg (seq-find (lambda (arg) (string-prefix-p "--remote=" arg)) args))
         (remote (when remote-arg (substring remote-arg (length "--remote="))))

         ;; Collect potential multi-value options supplied via --opt=value
         (bookmark-args (seq-filter (lambda (arg) (string-prefix-p "--bookmark=" arg)) args))
         (revision-args (seq-filter (lambda (arg) (string-prefix-p "--revisions=" arg)) args))
         (change-args   (seq-filter (lambda (arg) (string-prefix-p "--change=" arg)) args))
         (named-args    (seq-filter (lambda (arg) (string-prefix-p "--named=" arg)) args))

         (cmd-args (append '("git" "push")
                           (when remote (list "--remote" remote))
                           (when allow-new? '("--allow-new"))
                           (when all? '("--all"))
                           (when tracked? '("--tracked"))
                           (when deleted? '("--deleted"))
                           (when allow-empty? '("--allow-empty-description"))
                           (when allow-private? '("--allow-private"))
                           (when dry-run? '("--dry-run"))

                           ;; Expand = style into separate args as jj accepts space-separated
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--bookmark" (substring s (length "--bookmark="))))
                                                   bookmark-args))
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--revisions" (substring s (length "--revisions="))))
                                                   revision-args))
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--change" (substring s (length "--change="))))
                                                   change-args))
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--named" (substring s (length "--named="))))
                                                   named-args))))

         (success-msg (cond
                       ((and bookmark-args (= (length bookmark-args) 1))
                        (format "Successfully pushed bookmark %s"
                                (substring (car bookmark-args) (length "--bookmark="))))
                       (bookmark-args "Successfully pushed selected bookmarks")
                       (t "Successfully pushed to remote"))))
    (let ((result (apply #'jj--run-command cmd-args)))
      (when (jj--handle-push-result cmd-args result success-msg)
        (jj-log-refresh)))))

(defun jj-commit ()
  "Open commit message buffer."
  (interactive)
  (let ((current-desc (string-trim (jj--run-command "log" "-r" "@" "--no-graph" "-T" "description"))))
    (jj--open-message-buffer "COMMIT_MSG" "jj commit" 'jj--commit-finish nil current-desc)))

(defun jj-describe ()
  "Open describe message buffer."
  (interactive)
  (let ((change-id (jj-get-changeset-at-point)))
    (if change-id
        (let ((current-desc (string-trim (jj--run-command "log" "-r" change-id "--no-graph" "-T" "description"))))
          (jj--open-message-buffer "DESCRIBE_MSG"
                                   (format "jj describe -r %s" change-id)
                                   'jj--describe-finish change-id current-desc))
      (message "No changeset at point"))))

(defun jj--open-message-buffer (buffer-name command finish-func &optional change-id initial-desc)
  "Open a message editing buffer."
  (let* ((repo-root (jj--root))
         (log-buffer (current-buffer))
         (window-config (current-window-configuration))
         (buffer (get-buffer-create (format "*%s:%s*" buffer-name (file-name-nondirectory (directory-file-name repo-root))))))
    (with-current-buffer buffer
      (erase-buffer)
      (text-mode)
      (setq-local default-directory repo-root)
      (setq-local jj--message-command command)
      (setq-local jj--message-finish-func finish-func)
      (setq-local jj--message-change-id change-id)
      (setq-local jj--log-buffer log-buffer)
      (setq-local jj--window-config window-config)
      (local-set-key (kbd "C-c C-c") 'jj--message-finish)
      (local-set-key (kbd "C-c C-k") 'jj--message-abort)
      (when initial-desc
        (insert initial-desc))
      (insert "\n\n# Enter your message. C-c C-c to finish, C-c C-k to cancel\n"))
    (pop-to-buffer buffer)
    (goto-char (point-min))))

(defun jj--message-finish ()
  "Finish editing the message and execute the command."
  (interactive)
  (let* ((message (buffer-substring-no-properties (point-min) (point-max)))
         (lines (split-string message "\n"))
         (filtered-lines (seq-remove (lambda (line) (string-prefix-p "#" line)) lines))
         (final-message (string-trim (string-join filtered-lines "\n")))
         (command jj--message-command)
         (finish-func jj--message-finish-func)
         (change-id jj--message-change-id)
         (log-buffer jj--log-buffer)
         (window-config jj--window-config))
    (if (string-empty-p final-message)
        (message "Empty message, aborting")
      (kill-buffer)
      (set-window-configuration window-config)
      (funcall finish-func final-message change-id))))

(defun jj--message-abort ()
  "Abort message editing."
  (interactive)
  (when (yes-or-no-p "Abort message editing? ")
    (let ((window-config jj--window-config))
      (kill-buffer)
      (set-window-configuration window-config)
      (message "Aborted"))))

(defun jj--commit-finish (message &optional _change-id)
  "Finish commit with MESSAGE."
  (jj--message-with-log "Committing changes...")
  (let ((result (jj--run-command "commit" "-m" message)))
    (if (jj--handle-command-result (list "commit" "-m" message) result
                                   "Successfully committed changes"
                                   "Failed to commit")
        (jj-log-refresh))))

(defun jj--describe-finish (message &optional change-id)
  "Finish describe with MESSAGE for CHANGE-ID."
  (if change-id
      (progn
        (jj--message-with-log "Updating description for %s..." change-id)
        (let ((result (jj--run-command "describe" "-r" change-id "-m" message)))
          (if (jj--handle-command-result (list "describe" "-r" change-id "-m" message) result
                                         (format "Description updated for %s" change-id)
                                         "Failed to update description")
              (jj-log-refresh))))
    (jj--message-with-log "No change ID available for description update")))

(defun jj-git-fetch (args)
  "Fetch from git remote with ARGS from transient."
  (interactive (list (transient-args 'jj-git-fetch-transient)))
  (jj--message-with-log "Fetching from remote...")
  (let* ((tracked? (member "--tracked" args))
         (all-remotes? (member "--all-remotes" args))

         (branch-args (seq-filter (lambda (arg) (string-prefix-p "--branch=" arg)) args))
         (remote-args (seq-filter (lambda (arg) (string-prefix-p "--remote=" arg)) args))

         (cmd-args (append '("git" "fetch")
                           (when tracked? '("--tracked"))
                           (when all-remotes? '("--all-remotes"))
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--branch" (substring s (length "--branch="))))
                                                   branch-args))
                           (apply #'append (mapcar (lambda (s)
                                                     (list "--remote" (substring s (length "--remote="))))
                                                   remote-args))))
         (result (apply #'jj--run-command cmd-args)))
    (if (jj--handle-command-result cmd-args result
                                   "Fetched from remote" "Fetch failed")
        (jj-log-refresh))))

(defun jj-diff ()
  "Show diff for current change or commit at point."
  (interactive)
  (let* ((change-id (jj-get-changeset-at-point))
         (repo-root jj--repo-root)
         (buffer (get-buffer-create "*jj-diff*"))
         (prev-buffer (current-buffer)))
    (if (not change-id)
        (message "No diff to view at point.  Try again on a changeset.")
      (with-current-buffer buffer
        (setq default-directory repo-root)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (if change-id
              (insert (jj--run-command-color "show" "-r" change-id))
            (insert (jj--run-command-color "show")))
          (diff-mode)
          (ansi-color-apply-on-region (point-min) (point-max))
          (goto-char (point-min))
          ;; Make buffer read-only
          (setq buffer-read-only t)
          ;; Set up local keymap
          (use-local-map (copy-keymap diff-mode-map))
          (local-set-key (kbd "q")
                         (lambda ()
                           (interactive)
                           (kill-buffer)
                           (when (buffer-live-p prev-buffer)
                             (switch-to-buffer prev-buffer)))))))
    (switch-to-buffer buffer)))

;;;###autoload
(defun jj-goto-next-changeset ()
  "Navigate to the next changeset in the log."
  (interactive)
  (let ((pos (point))
        found)
    (while (and (not found)
                (< (point) (point-max)))
      (magit-section-forward)
      (when-let ((section (magit-current-section)))
        (when (and (memq (oref section type) '(jj-log-entry-section jj-commit-section))
                   (> (point) pos))
          (setq found t))))
    (unless found
      (goto-char pos)
      (message "No more changesets"))))

;;;###autoload
(defun jj-goto-prev-changeset ()
  "Navigate to the previous changeset in the log."
  (interactive)
  (let ((pos (point))
        found)
    (while (and (not found)
                (> (point) (point-min)))
      (magit-section-backward)
      (when-let ((section (magit-current-section)))
        (when (and (memq (oref section type) '(jj-log-entry-section jj-commit-section))
                   (< (point) pos))
          (setq found t))))
    (unless found
      (goto-char pos)
      (message "No more changesets"))))

(defun jj-get-changeset-at-point ()
  "Get the changeset ID at point."  
  (let ((id-type (if (transient-arg-value "--use-commit-id" (transient-args 'jj-mode-transient)) 'commit-id 'change-id)))   
    (when-let ((section (magit-current-section)))
      (cond
       ((and (slot-exists-p section id-type)
             (slot-boundp section id-type)
             (memq (oref section type) '(jj-log-entry-section jj-commit-section)))
        (slot-value section id-type))
       (t nil)))))

;; Rebase state management
(defvar-local jj-rebase-source nil
  "Currently selected source commit for rebase.")

(defvar-local jj-rebase-destinations nil
  "List of currently selected destination commits for rebase.")

(defvar-local jj-rebase-source-overlay nil
  "Overlay for highlighting the selected source commit.")

(defvar-local jj-rebase-destination-overlays nil
  "List of overlays for highlighting selected destination commits.")

;;;###autoload
(defun jj-rebase-clear-selections ()
  "Clear all rebase selections and overlays."
  (interactive)
  (setq jj-rebase-source nil
        jj-rebase-destinations nil)
  (when jj-rebase-source-overlay
    (jj--delete-overlay jj-rebase-source-overlay)
    (setq jj-rebase-source-overlay nil))
  (dolist (overlay jj-rebase-destination-overlays)
    (jj--delete-overlay overlay))
  (setq jj-rebase-destination-overlays nil)
  (message "Cleared all rebase selections"))

;;;###autoload
(defun jj-rebase-set-source ()
  "Set the commit at point as rebase source."
  (interactive)
  (when-let ((change-id (jj-get-changeset-at-point))
             (section (magit-current-section)))
    ;; Clear previous source overlay
    (when jj-rebase-source-overlay
      (jj--delete-overlay jj-rebase-source-overlay))
    ;; Set new source
    (setq jj-rebase-source change-id)
    ;; Create overlay for visual indication
    (setq jj-rebase-source-overlay
          (jj--make-commit-overlay
           section " [SOURCE]"
           '(:background "dark green" :foreground "white" :extend t)))
    (message "Set source: %s" change-id)))

;;;###autoload
(defun jj-rebase-toggle-destination ()
  "Toggle the commit at point as a rebase destination."
  (interactive)
  (when-let ((change-id (jj-get-changeset-at-point))
             (section (magit-current-section)))
    (if (member change-id jj-rebase-destinations)
        ;; Remove from destinations
        (progn
          (setq jj-rebase-destinations (remove change-id jj-rebase-destinations))
          ;; Remove overlay
          (dolist (overlay jj-rebase-destination-overlays)
            (when (and (>= (overlay-start overlay) (oref section start))
                       (<= (overlay-end overlay) (oref section end)))
              (jj--delete-overlay overlay)
              (setq jj-rebase-destination-overlays (remove overlay jj-rebase-destination-overlays))))
          (message "Removed destination: %s" change-id))
      ;; Add to destinations
      (push change-id jj-rebase-destinations)
      ;; Create overlay for visual indication
      (let ((overlay (jj--make-commit-overlay
                      section " [DEST]"
                      '(:background "dark blue" :foreground "white" :extend t))))
        (push overlay jj-rebase-destination-overlays)
        (message "Added destination: %s" change-id)))))

;;;###autoload
(defun jj-rebase-execute ()
  "Execute rebase with selected source and destinations."
  (interactive)
  (if (and jj-rebase-source jj-rebase-destinations)
      (when (yes-or-no-p (format "Rebase %s -> %s? "
                                 jj-rebase-source
                                 (string-join jj-rebase-destinations ", ")))
        (let* ((dest-args (apply 'append (mapcar (lambda (dest) (list "-d" dest)) jj-rebase-destinations)))
               (all-args (append (list "rebase" "-s" jj-rebase-source) dest-args))
               (progress-msg (format "Rebasing %s onto %s"
                                     jj-rebase-source
                                     (string-join jj-rebase-destinations ", ")))
               (success-msg (format "Rebase completed: %s -> %s"
                                    jj-rebase-source
                                    (string-join jj-rebase-destinations ", "))))
          (jj--message-with-log "%s..." progress-msg)
          (let ((result (apply #'jj--run-command all-args)))
            (if (jj--handle-command-result all-args result success-msg "Rebase failed")
                (progn
                  (jj-rebase-clear-selections)
                  (jj-log-refresh))))))
    (jj--message-with-log "Please select source (s) and at least one destination (d) first")))

;; Transient rebase menu
;;;###autoload
(defun jj-rebase-transient ()
  "Transient for jj rebase operations."
  (interactive)
  ;; Add cleanup hook for when transient exits
  (add-hook 'transient-exit-hook 'jj-rebase-cleanup-on-exit nil t)
  (jj-rebase-transient--internal))

(defun jj-rebase-cleanup-on-exit ()
  "Clean up rebase selections when transient exits."
  (jj-rebase-clear-selections)
  (remove-hook 'transient-exit-hook 'jj-rebase-cleanup-on-exit t))

(transient-define-prefix jj-rebase-transient--internal ()
  "Internal transient for jj rebase operations."
  :transient-suffix 'transient--do-exit
  :transient-non-suffix t
  [:description
   (lambda ()
     (concat "JJ Rebase"
             (when jj-rebase-source
               (format " | Source: %s" jj-rebase-source))
             (when jj-rebase-destinations
               (format " | Destinations: %s"
                       (string-join jj-rebase-destinations ", ")))))
   :class transient-columns
   ["Selection"
    ("s" "Set source" jj-rebase-set-source
     :description (lambda ()
                    (if jj-rebase-source
                        (format "Set source (current: %s)" jj-rebase-source)
                      "Set source"))
     :transient t)
    ("d" "Toggle destination" jj-rebase-toggle-destination
     :description (lambda ()
                    (format "Toggle destination (%d selected)"
                            (length jj-rebase-destinations)))
     :transient t)
    ("c" "Clear selections" jj-rebase-clear-selections
     :transient t)]
   ["Actions"
    ("r" "Execute rebase" jj-rebase-execute
     :description (lambda ()
                    (if (and jj-rebase-source jj-rebase-destinations)
                        (format "Rebase %s -> %s"
                                jj-rebase-source
                                (string-join jj-rebase-destinations ", "))
                      "Execute rebase (select source & destinations first)"))
     :transient nil)

    ("q" "Quit" transient-quit-one)]])

;; Git transients
(transient-define-prefix jj-git-transient ()
  "Top-level transient for jj git operations."
  :transient-suffix 'transient--do-exit
  :transient-non-suffix t
  [:description "JJ Git"
   :class transient-columns
   ["Sync"
    ("p" "Push" jj-git-push-transient)
    ("f" "Fetch" jj-git-fetch-transient)]
   [("q" "Quit" transient-quit-one)]])

;; Push transient and command
(transient-define-prefix jj-git-push-transient ()
  "Transient for jj git push."
  [:class transient-columns
          ["Arguments"
           ("-R" "Remote" "--remote=" :choices jj--get-git-remotes)
           ("-b" "Bookmark" "--bookmark=" :choices jj--get-bookmark-names)
           ("-a" "All bookmarks" "--all")
           ("-t" "Tracked only" "--tracked")
           ("-D" "Deleted" "--deleted")
           ("-n" "Allow new" "--allow-new")
           ("-E" "Allow empty desc" "--allow-empty-description")
           ("-P" "Allow private" "--allow-private")
           ("-r" "Revisions" "--revisions=")
           ("-c" "Change" "--change=")
           ("-N" "Named X=REV" "--named=")
           ("-y" "Dry run" "--dry-run")]
          [("p" "Push" jj-git-push :transient nil)
           ("q" "Quit" transient-quit-one)]])

;; Fetch transient and command
(transient-define-prefix jj-git-fetch-transient ()
  "Transient for jj git fetch."
  [:class transient-columns
          ["Arguments"
           ("-R" "Remote" "--remote=" :choices jj--get-git-remotes)
           ("-B" "Branch" "--branch=")
           ("-t" "Tracked only" "--tracked")
           ("-A" "All remotes" "--all-remotes")]
          [("f" "Fetch" jj-git-fetch :transient nil)
           ("q" "Quit" transient-quit-one)]])

(provide 'jj-mode)
;;; jj-mode.el ends here
