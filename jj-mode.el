;;; jj-mode.el -*- lexical-binding: t; -*-

(require 'magit-section)
(require 'transient)
(require 'ansi-color)

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

;; (setq jj-mode-map nil)

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
    (define-key map (kbd "N") 'jj-new)
    (define-key map (kbd "s") 'jj-squash)
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
    map)
  "Keymap for `jj-mode'.")

(define-derived-mode jj-mode magit-section-mode "JJ"
  "Major mode for interacting with jj version control system."
  :group 'jj
  (setq-local revert-buffer-function 'jj-log-refresh)
  ;; Clear rebase selections when buffer is killed
  (add-hook 'kill-buffer-hook 'jj-rebase-clear-selections nil t))

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
  (jj--debug "Running command: %s %s" jj-executable (string-join args " "))
  (let ((start-time (current-time))
        result exit-code)
    (with-temp-buffer
      (setq exit-code (apply #'call-process jj-executable nil t nil args))
      (setq result (buffer-string))
      (jj--debug "Command completed in %.3f seconds, exit code: %d"
                 (float-time (time-subtract (current-time) start-time))
                 exit-code)
      (when (and jj-show-command-output (not (string-empty-p result)))
        (jj--debug "Command output: %s" (string-trim result)))
      result)))

(defun jj--run-command-color (&rest args)
  "Run jj command with ARGS and return colorized output."
  (jj--debug "Running color command: %s --color=always %s" jj-executable (string-join args " "))
  (let ((start-time (current-time))
        result exit-code)
    (with-temp-buffer
      (let ((process-environment (cons "FORCE_COLOR=1" (cons "CLICOLOR_FORCE=1" process-environment))))
        (setq exit-code (apply #'call-process jj-executable nil t nil "--color=always" args))
        (setq result (ansi-color-apply (buffer-string)))
        (jj--debug "Color command completed in %.3f seconds, exit code: %d"
                   (float-time (time-subtract (current-time) start-time))
                   exit-code)
        result))))

(defun jj--run-command-async (callback &rest args)
  "Run jj command with ARGS asynchronously and call CALLBACK with output."
  (jj--debug "Starting async command: %s %s" jj-executable (string-join args " "))
  (let ((buffer (generate-new-buffer " *jj-async*"))
        (start-time (current-time)))
    (set-process-sentinel
     (apply #'start-process "jj" buffer jj-executable args)
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
      (message "Nothing to push - all bookmarks are up to date")
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

(defun jj--analyze-status-for-hints (status-output)
  "Analyze jj status output and provide helpful hints."
  (when (and status-output (not (string-empty-p status-output)))
    (cond
     ;; No changes
     ((string-match-p "The working copy is clean" status-output)
      (message "Working copy is clean - no changes to commit"))

     ;; Conflicts present
     ((string-match-p "There are unresolved conflicts" status-output)
      (message "💡 Resolve conflicts with 'jj resolve' or use diffedit (E/M)"))

     ;; Untracked files
     ((string-match-p "Untracked paths:" status-output)
      (message "💡 Add files with 'jj file track' or create .gitignore"))

     ;; Working copy changes
     ((string-match-p "Working copy changes:" status-output)
      (message "💡 Commit changes with 'jj commit' or describe with 'jj describe'")))))

(defclass jj-commit-section (magit-section)
  ((commit-id :initarg :commit-id)
   (author :initarg :author)
   (date :initarg :date)
   (description :initarg :description)
   (bookmarks :initarg :bookmarks)))

(defclass jj-commits-section (magit-section) ())
(defclass jj-status-section (magit-section) ())
(defclass jj-diff-stat-section (magit-section) ())
(defclass jj-log-graph-section (magit-section) ())
(defclass jj-log-entry-section (magit-section)
  ((commit-id :initarg :commit-id)
   (description :initarg :description)
   (bookmarks :initarg :bookmarks)))
(defclass jj-diff-section (magit-section) ())
(defclass jj-file-section (magit-section)
  ((file :initarg :file)))
(defclass jj-hunk-section (magit-section)
  ((file :initarg :file)
   (start :initarg :hunk-start)
   (header :initarg :header)))

(defun jj--parse-log-line (line)
  "Parse a single jj log line."
  (when (string-match "^\\([a-z]+\\)\\s-+\\([^|]+\\)\\s-*|\\s-*\\(.*\\)$" line)
    (let* ((id (match-string 1 line))
           (info (match-string 2 line))
           (desc (match-string 3 line))
           (bookmarks (when (string-match "\\(([^)]+)\\)" info)
                        (match-string 1 info)))
           (author-date (replace-regexp-in-string "\\s-*([^)]+)\\s-*" "" info)))
      (list :id id
            :info info
            :author-date author-date
            :description desc
            :bookmarks bookmarks))))

(defun jj-log-insert-commits ()
  "Insert jj log commits into current buffer."
  (let* ((log-output (jj--run-command "log"
                                      "--no-graph"
                                      "--template" "change_id.shortest() ++ \" \" ++ if(bookmarks, bookmarks.join(\", \") ++ \" \", \"\") ++ author.name() ++ \" \" ++ author.timestamp().ago() ++ \" | \" ++ if(description, description.first_line(), \"(no description)\")"))
         (lines (split-string log-output "\n" t)))
    (when lines
      (magit-insert-section (jj-commits-section)
        (magit-insert-heading "Recent Commits")
        (dolist (line lines)
          (when-let ((commit-data (jj--parse-log-line line)))
            (magit-insert-section section (jj-commit-section)
                                  (oset section commit-id (plist-get commit-data :id))
                                  (oset section description (plist-get commit-data :description))
                                  (insert (propertize (format "%-8s" (plist-get commit-data :id))
                                                      'face 'magit-hash))
                                  (when (plist-get commit-data :bookmarks)
                                    (insert (propertize (plist-get commit-data :bookmarks)
                                                        'face 'magit-bookmark-local) " "))
                                  (insert (propertize (plist-get commit-data :author-date)
                                                      'face 'magit-log-author))
                                  (insert " ")
                                  (insert (propertize (plist-get commit-data :description)
                                                      'face 'magit-section-highlight))
                                  (insert "\n"))))))))

(defun jj--parse-log-graph-line (line)
  "Parse LINE from jj log output to extract changeset info."
  (when (string-match "\\([○◉×x◆●◯◍@]\\)\\s-*\\([a-z][a-z0-9]+\\)" line)
    (let* ((marker (match-string 1 line))
           (id (match-string 2 line))
           (rest (substring line (match-end 0)))
           bookmarks description)
      ;; Extract bookmarks and description from the rest of the line
      (when (string-match "\\s-+\\(.*\\)" rest)
        (setq description (match-string 1 rest)))
      ;; Check if there are bookmark names at the beginning
      (when (and description (string-match "^\\(\\S-+\\)\\s-+\\(.*\\)" description))
        (let ((first-word (match-string 1 description)))
          (when (not (string-match "^[0-9]" first-word))
            (setq bookmarks first-word
                  description (match-string 2 description)))))
      (when id
        (list :marker marker
              :id id
              :bookmarks bookmarks
              :description description
              :full-line line)))))

(defun jj-log-insert-logs ()
  "Insert jj log graph into current buffer."
  (let ((log-output (jj--run-command-color "log")))
    (when (and log-output (not (string-empty-p log-output)))
      (magit-insert-section (jj-log-graph-section)
        (magit-insert-heading "Log Graph")
        (let ((lines (split-string log-output "\n" t)))
          (dolist (line lines)
            (if-let ((changeset-data (jj--parse-log-graph-line line)))
                ;; This line represents a changeset
                (magit-insert-section section (jj-log-entry-section)
                                      (oset section commit-id (plist-get changeset-data :id))
                                      (oset section description (plist-get changeset-data :description))
                                      (oset section bookmarks (plist-get changeset-data :bookmarks))
                                      (insert line "\n"))
              ;; This is a graph line or other content
              (insert line "\n"))))
        (insert "\n")))))

(defun jj-log-insert-status ()
  "Insert jj status into current buffer."
  (let ((status-output (jj--run-command-color "status")))
    (when (and status-output (not (string-empty-p status-output)))
      (magit-insert-section (jj-status-section)
        (magit-insert-heading "Working Copy Status")
        (insert status-output)
        (insert "\n")
        ;; Analyze status and provide hints in the minibuffer
        (jj--analyze-status-for-hints status-output)))))

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
(defun jj-log ()
  "Display jj log in a magit-style buffer."
  (interactive)
  (let* ((repo-root (or (magit-toplevel) default-directory))
         (buffer-name (format "*jj-log:%s*" (file-name-nondirectory (directory-file-name repo-root))))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (default-directory repo-root))
        (erase-buffer)
        (jj-mode)
        (magit-insert-section (jjbuf)  ; Root section wrapper
          (jj-log-insert-logs)
          (jj-log-insert-status)
          (jj-log-insert-diff))
        (goto-char (point-min))))
    (switch-to-buffer buffer)))

(defun jj-log-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the jj log buffer."
  (interactive)
  (when (derived-mode-p 'jj-mode)
    (jj--with-progress "Refreshing log view"
                       (lambda ()
                         (let ((inhibit-read-only t)
                               (pos (point)))
                           (erase-buffer)
                           (magit-insert-section (jjbuf)  ; Root section wrapper
                             (jj-log-insert-logs)
                             (jj-log-insert-status)
                             (jj-log-insert-diff))
                           (goto-char pos)
                           (jj--debug "Log refresh completed"))))))

(defun jj-enter-dwim ()
  "Context-sensitive Enter key behavior."
  (interactive)
  (let ((section (magit-current-section)))
    (cond
     ;; On a changeset/commit - edit it with jj edit
     ((and section
           (memq (oref section type) '(jj-log-entry-section jj-commit-section))
           (slot-boundp section 'commit-id))
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
      (jj-visit-file))

     ;; Default - show commit details (old behavior)
     (t
      (jj-log-visit-commit)))))

(defun jj-edit-changeset-at-point ()
  "Edit the commit at point using jj edit."
  (interactive)
  (when-let ((commit-id (jj-get-changeset-at-point)))
    (let ((result (jj--run-command "edit" commit-id)))
      (if (jj--handle-command-result (list "edit" commit-id) result
                                     (format "Now editing commit %s" commit-id)
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
              (repo-root (magit-toplevel)))
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
              (repo-root (magit-toplevel)))
    (let ((full-file-path (expand-file-name file repo-root)))
      (find-file full-file-path))))

(defun jj-diffedit-emacs ()
  "Emacs-based diffedit using built-in ediff."
  (interactive)
  (let* ((section (magit-current-section))
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
  (let* ((repo-root (magit-toplevel))
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
  (let* ((repo-root (magit-toplevel))
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

(defun jj-log-visit-commit ()
  "Show details of commit at point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (commit-id (or (and (eq (oref section type) 'jj-commit-section)
                                  (oref section commit-id))
                             (and (eq (oref section type) 'jj-log-entry-section)
                                  (oref section commit-id)))))
    (let ((buffer (get-buffer-create (format "*jj-commit-%s*" commit-id))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (jj--run-command-color "show" "-r" commit-id "--git"))
          (diff-mode)
          (ansi-color-apply-on-region (point-min) (point-max))
          (goto-char (point-min))))
      (display-buffer buffer))))

(defun jj-edit-changeset ()
  "Edit commit at point."
  (interactive)
  (when-let ((commit-id (jj-get-changeset-at-point)))
    (let ((result (jj--run-command "edit" commit-id)))
      (if (jj--handle-command-result (list "edit" commit-id) result
                                     (format "Now editing changeset %s" commit-id)
                                     "Failed to edit commit")
          (jj-log-refresh)))))

(defun jj-squash ()
  "Squash commits."
  (interactive)
  (when-let ((commit-id (jj-get-changeset-at-point)))
    (let ((result (jj--run-command "squash" "-r" commit-id)))
      (if (jj--handle-command-result (list "squash" "-r" commit-id) result
                                     (format "Squashed commit %s" commit-id)
                                     "Failed to squash commit")
          (jj-log-refresh)))))

(defun jj-bookmark-create ()
  "Create a new bookmark."
  (interactive)
  (let* ((commit-id (or (jj-get-changeset-at-point) "@"))
         (name (read-string "Bookmark name: ")))
    (unless (string-empty-p name)
      (jj--run-command "bookmark" "create" name "-r" commit-id)
      (jj-log-refresh))))

(defun jj-bookmark-abandon ()
  "Abandon a bookmark."
  (interactive)
  (let* ((bookmarks-output (jj--run-command "bookmark" "list"))
         (bookmarks (seq-filter
                     (lambda (line) (not (string-empty-p line)))
                     (split-string bookmarks-output "\n")))
         (bookmark-names (mapcar
                          (lambda (line)
                            (when (string-match "^\\([^:]+\\)" line)
                              (match-string 1 line)))
                          bookmarks))
         (bookmark-names (seq-filter 'identity bookmark-names)))
    (if bookmark-names
        (let ((choice (completing-read "Abandon bookmark (deletes on remote): " bookmark-names)))
          (when choice
            (jj--run-command "bookmark" "delete" choice)
            (jj-log-refresh)
            (message "Abandoned bookmark '%s'" choice)))
      (message "No bookmarks found"))))

(defun jj-bookmark-forget ()
  "Forget a bookmark."
  (interactive)
  (let* ((bookmarks-output (jj--run-command "bookmark" "list"))
         (bookmarks (seq-filter
                     (lambda (line) (not (string-empty-p line)))
                     (split-string bookmarks-output "\n")))
         (bookmark-names (mapcar
                          (lambda (line)
                            (when (string-match "^\\([^:]+\\)" line)
                              (match-string 1 line)))
                          bookmarks))
         (bookmark-names (seq-filter 'identity bookmark-names)))
    (if bookmark-names
        (let ((choice (completing-read "Forget bookmark: " bookmark-names)))
          (when choice
            (jj--run-command "bookmark" "forget" choice)
            (jj-log-refresh)
            (message "Forgot bookmark '%s'" choice)))
      (message "No bookmarks found"))))

(defun jj-bookmark-track ()
  "Track a remote bookmark."
  (interactive)
  (let* ((remotes-output (jj--run-command "bookmark" "list" "--all"))
         (remote-lines (seq-filter
                        (lambda (line) (string-match "@" line))
                        (split-string remotes-output "\n")))
         (remote-bookmarks (mapcar
                            (lambda (line)
                              (when (string-match "^\\([^:]+\\)" line)
                                (match-string 1 line)))
                            remote-lines))
         (remote-bookmarks (seq-filter 'identity remote-bookmarks)))
    (if remote-bookmarks
        (let ((choice (completing-read "Track remote bookmark: " remote-bookmarks)))
          (when choice
            (jj--run-command "bookmark" "track" choice)
            (jj-log-refresh)
            (message "Tracking bookmark '%s'" choice)))
      (message "No remote bookmarks found"))))

(defun jj-tug ()
  "Run jj tug command."
  (interactive)
  (let ((result (jj--run-command "tug")))
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
  ["Bookmark Operations"
   [("t" "Tug" jj-tug
     :description "Run jj tug command")
    ("c" "Create bookmark" jj-bookmark-create
     :description "Create new bookmark")
    ("T" "Track remote" jj-bookmark-track
     :description "Track remote bookmark")]
   [("a" "Abandon bookmark" jj-bookmark-abandon
     :description "Delete local bookmark")
    ("f" "Forget bookmark" jj-bookmark-forget
     :description "Forget bookmark")]
   [("q" "Quit" transient-quit-one)]])

(defun jj-undo ()
  "Undo the last change."
  (interactive)
  (let ((commit-id (jj-get-changeset-at-point)))
    (jj--run-command "undo")
    (jj-log-refresh)
    (when commit-id
      (jj-goto-commit commit-id))))

(defun jj-abandon ()
  "Abandon a changeset."
  (interactive)
  (if-let ((commit-id (jj-get-changeset-at-point)))
      (progn
        (jj--run-command "abandon" "-r" commit-id)
        (jj-log-refresh))
    (message "Can only run new on a change")))

(defun jj-new ()
  "Create a new changeset."
  (interactive)
  (if-let ((commit-id (jj-get-changeset-at-point)))
      (progn
        (jj--run-command "new" "-r" commit-id)
        (jj-log-refresh)
        (jj-goto-commit commit-id))
    (message "Can only run new on a change")))

(defun jj-goto-current ()
  "Jump to the current changeset (@)."
  (interactive)
  (goto-char (point-min))
  (if (re-search-forward "^.*@.*$" nil t)
      (goto-char (line-beginning-position))
    (message "Current changeset (@) not found")))

(defun jj-goto-commit (commit-id)
  "Jump to a specific COMMIT-ID in the log."
  (interactive "sCommit ID: ")
  (let ((start-pos (point)))
    (goto-char (point-min))
    (if (re-search-forward (regexp-quote commit-id) nil t)
        (goto-char (line-beginning-position))
      (goto-char start-pos)
      (message "Commit %s not found" commit-id))))

(defun jj-git-push (args)
  "Push to git remote with ARGS."
  (interactive (list (transient-args 'jj-git-transient)))
  (let* ((allow-new (member "--allow-new" args))
         (bookmark-arg (seq-find (lambda (arg) (string-prefix-p "--bookmark=" arg)) args))
         (bookmark (when bookmark-arg (substring bookmark-arg 11)))
         (cmd-args (cond
                    ((and bookmark allow-new) (list "git" "push" "--allow-new" "--bookmark" bookmark))
                    (bookmark (list "git" "push" "--bookmark" bookmark))
                    (allow-new (list "git" "push" "--allow-new"))
                    (t (list "git" "push"))))
         (success-msg (if bookmark
                          (format "Successfully pushed bookmark %s" bookmark)
                        "Successfully pushed to remote")))
    (let ((result (apply #'jj--run-command cmd-args)))
      (if (jj--handle-push-result cmd-args result success-msg)
          (jj-log-refresh)))))

(defun jj-commit ()
  "Open commit message buffer."
  (interactive)
  (let ((current-desc (string-trim (jj--run-command "log" "-r" "@" "--no-graph" "-T" "description"))))
    (jj--open-message-buffer "COMMIT_MSG" "jj commit" 'jj--commit-finish nil current-desc)))

(defun jj-describe ()
  "Open describe message buffer."
  (interactive)
  (let ((commit-id (jj-get-changeset-at-point)))
    (if commit-id
        (let ((current-desc (string-trim (jj--run-command "log" "-r" commit-id "--no-graph" "-T" "description"))))
          (jj--open-message-buffer "DESCRIBE_MSG"
                                   (format "jj describe -r %s" commit-id)
                                   'jj--describe-finish commit-id current-desc))
      (message "No changeset at point"))))

(defun jj--open-message-buffer (buffer-name command finish-func &optional commit-id initial-desc)
  "Open a message editing buffer."
  (let* ((repo-root (or (magit-toplevel) default-directory))
         (log-buffer (current-buffer))
         (window-config (current-window-configuration))
         (buffer (get-buffer-create (format "*%s:%s*" buffer-name (file-name-nondirectory (directory-file-name repo-root))))))
    (with-current-buffer buffer
      (erase-buffer)
      (text-mode)
      (setq-local default-directory repo-root)
      (setq-local jj--message-command command)
      (setq-local jj--message-finish-func finish-func)
      (setq-local jj--message-commit-id commit-id)
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
         (commit-id jj--message-commit-id)
         (log-buffer jj--log-buffer)
         (window-config jj--window-config))
    (if (string-empty-p final-message)
        (message "Empty message, aborting")
      (kill-buffer)
      (set-window-configuration window-config)
      (funcall finish-func final-message commit-id))))

(defun jj--message-abort ()
  "Abort message editing."
  (interactive)
  (when (yes-or-no-p "Abort message editing? ")
    (let ((window-config jj--window-config))
      (kill-buffer)
      (set-window-configuration window-config)
      (message "Aborted"))))

(defun jj--commit-finish (message &optional _commit-id)
  "Finish commit with MESSAGE."
  (jj--message-with-log "Committing changes...")
  (let ((result (jj--run-command "commit" "-m" message)))
    (if (jj--handle-command-result (list "commit" "-m" message) result
                                   "Successfully committed changes"
                                   "Failed to commit")
        (jj-log-refresh))))

(defun jj--describe-finish (message &optional commit-id)
  "Finish describe with MESSAGE for COMMIT-ID."
  (if commit-id
      (progn
        (jj--message-with-log "Updating description for %s..." commit-id)
        (let ((result (jj--run-command "describe" "-r" commit-id "-m" message)))
          (if (jj--handle-command-result (list "describe" "-r" commit-id "-m" message) result
                                         (format "Description updated for %s" commit-id)
                                         "Failed to update description")
              (jj-log-refresh))))
    (jj--message-with-log "No commit ID available for description update")))

(defun jj-git-fetch ()
  "Fetch from git remote."
  (interactive)
  (jj--message-with-log "Fetching from remote...")
  (let ((result (jj--run-command "git" "fetch")))
    (if (jj--handle-command-result (list "git" "fetch") result
                                   "Fetched from remote" "Fetch failed")
        (jj-log-refresh))))

(defun jj-diff ()
  "Show diff for current change or commit at point."
  (interactive)
  (let* ((commit-id (jj-get-changeset-at-point))
         (buffer (get-buffer-create "*jj-diff*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if commit-id
            (insert (jj--run-command-color "show" "-r" commit-id "--git"))
          (insert (jj--run-command-color "diff" "--git")))
        (diff-mode)
        (ansi-color-apply-on-region (point-min) (point-max))
        (goto-char (point-min))))
    (display-buffer buffer)))

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
  (when-let ((section (magit-current-section)))
    (cond
     ((and (slot-boundp section 'commit-id)
           (memq (oref section type) '(jj-log-entry-section jj-commit-section)))
      (oref section commit-id))
     (t nil))))

;; Rebase state management
(defvar jj-rebase-source nil
  "Currently selected source commit for rebase.")

(defvar jj-rebase-destinations nil
  "List of currently selected destination commits for rebase.")

(defvar jj-rebase-source-overlay nil
  "Overlay for highlighting the selected source commit.")

(defvar jj-rebase-destination-overlays nil
  "List of overlays for highlighting selected destination commits.")

;;;###autoload
(defun jj-rebase-clear-selections ()
  "Clear all rebase selections and overlays."
  (interactive)
  (setq jj-rebase-source nil
        jj-rebase-destinations nil)
  (when jj-rebase-source-overlay
    (delete-overlay jj-rebase-source-overlay)
    (setq jj-rebase-source-overlay nil))
  (dolist (overlay jj-rebase-destination-overlays)
    (delete-overlay overlay))
  (setq jj-rebase-destination-overlays nil)
  (message "Cleared all rebase selections"))

;;;###autoload
(defun jj-rebase-set-source ()
  "Set the commit at point as rebase source."
  (interactive)
  (when-let ((commit-id (jj-get-changeset-at-point))
             (section (magit-current-section)))
    ;; Clear previous source overlay
    (when jj-rebase-source-overlay
      (delete-overlay jj-rebase-source-overlay))
    ;; Set new source
    (setq jj-rebase-source commit-id)
    ;; Create overlay for visual indication
    (setq jj-rebase-source-overlay
          (make-overlay (oref section start) (oref section end)))
    (overlay-put jj-rebase-source-overlay 'face '(:background "dark green" :foreground "white"))
    (overlay-put jj-rebase-source-overlay 'before-string "[SOURCE] ")
    (message "Set source: %s" commit-id)))

;;;###autoload
(defun jj-rebase-toggle-destination ()
  "Toggle the commit at point as a rebase destination."
  (interactive)
  (when-let ((commit-id (jj-get-changeset-at-point))
             (section (magit-current-section)))
    (if (member commit-id jj-rebase-destinations)
        ;; Remove from destinations
        (progn
          (setq jj-rebase-destinations (remove commit-id jj-rebase-destinations))
          ;; Remove overlay
          (dolist (overlay jj-rebase-destination-overlays)
            (when (and (>= (overlay-start overlay) (oref section start))
                       (<= (overlay-end overlay) (oref section end)))
              (delete-overlay overlay)
              (setq jj-rebase-destination-overlays (remove overlay jj-rebase-destination-overlays))))
          (message "Removed destination: %s" commit-id))
      ;; Add to destinations
      (push commit-id jj-rebase-destinations)
      ;; Create overlay for visual indication
      (let ((overlay (make-overlay (oref section start) (oref section end))))
        (overlay-put overlay 'face '(:background "dark blue" :foreground "white"))
        (overlay-put overlay 'before-string "[DEST] ")
        (push overlay jj-rebase-destination-overlays)
        (message "Added destination: %s" commit-id)))))

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
  :transient-non-suffix 'transient--do-warn
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
    ("n" "Next" jj-goto-next-changeset
     :transient t)
    ("p" "Prev" jj-goto-prev-changeset
     :transient t)
    ("q" "Quit" transient-quit-one)]])

(transient-define-prefix jj-git-transient ()
  "Transient for jj git operations."
  :transient-suffix 'transient--do-exit
  :transient-non-suffix 'transient--do-warn
  ["Arguments"
   ("-n" "Allow new bookmarks" "--allow-new")
   ("-b" "Bookmark" "--bookmark=" :reader transient-read-string)]
  [:description "JJ Git Operations"
   :class transient-columns
   ["Actions"
    ("p" "Push" jj-git-push
     :transient nil)
    ("f" "Fetch" jj-git-fetch
     :transient nil)]
   [("q" "Quit" transient-quit-one)]])

(provide 'jj-mode)
