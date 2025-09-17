;;; jj-split.el --- Interactive diff editor for jj -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Brandon Olivier
;; Keywords: vc, tools
;; Package-Requires: ((emacs "28.1") (magit-section "3.0.0"))

;;; Commentary:

;; This package provides an interactive diff editor mode for jj operations
;; like diffedit, split, and interactive squash. It uses magit-style sections
;; with line-by-line selection capabilities.

;;; Code:

(require 'magit-section)
(require 'cl-lib)

;; Forward declare jj--run-command
(declare-function jj--run-command "jj-mode" (&rest args))

;;; Customization

(defgroup jj-split nil
  "Interactive split mode for jj."
  :group 'jj)

(defface jj-split-selected-face
  '((t :background "#2d4f2d" :extend t))
  "Face for selected lines."
  :group 'jj-split)

(defface jj-split-unselected-face
  '((t :inherit default))
  "Face for unselected lines."
  :group 'jj-split)

(defface jj-split-context-face
  '((t :foreground "#888888"))
  "Face for context lines."
  :group 'jj-split)

(defface jj-split-deletion-face
  '((t :foreground "#ff6b6b" :inherit default))
  "Face for deletion lines (lines starting with -)."
  :group 'jj-split)

(defface jj-split-deletion-selected-face
  '((t :foreground "#ff6b6b" :background "#4d2d2d" :extend t))
  "Face for selected deletion lines."
  :group 'jj-split)

;;; Data Structures

(cl-defstruct jj-split-line
  id          ; unique identifier "file:hunk:line"
  file        ; file path
  hunk-header ; @@ -10,5 +10,8 @@ style header  
  hunk-id     ; unique hunk identifier
  line-number ; line number within hunk
  content     ; line content
  type        ; 'context, 'addition, 'deletion
  selected    ; boolean - is this line selected
  section-ref ; reference to magit section
  )

;;; Section Types

(defclass jj-split-root-section (magit-section) ())
(defclass jj-split-file-section (magit-section)
  ((file-path :initarg :file-path :reader jj-split-file-section-file-path)))

(defclass jj-split-hunk-section (magit-section)
  ((hunk-header :initarg :hunk-header :reader jj-split-hunk-section-header)
   (hunk-id :initarg :hunk-id :reader jj-split-hunk-section-id)))

(defclass jj-split-line-section (magit-section)
  ((line-data :initarg :line-data :reader jj-split-line-section-data)))

;;; Buffer-local Variables

(defvar-local jj-split-lines nil
  "List of all diff lines with selection state.")

(defvar-local jj-split-revision nil
  "The revision being edited.")

(defvar-local jj-split-operation nil
  "The operation type: 'diffedit, 'split, or 'squash.")

;;; Mode Definition

;; (setq jj-split-mode-map nil)

(defvar jj-split-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    ;; Navigation  
    (define-key map (kbd "p") #'jj-split-previous-line)
    (define-key map (kbd "n") #'jj-split-next-line)
    (define-key map (kbd "j") #'jj-split-next-line)
    (define-key map (kbd "k") #'jj-split-previous-line)
    (define-key map (kbd "P") #'jj-split-previous-hunk)
    (define-key map (kbd "N") #'jj-split-next-hunk)
    (define-key map (kbd "M-p") #'jj-split-previous-file)
    (define-key map (kbd "M-n") #'jj-split-next-file)
    ;; Selection
    (define-key map (kbd "SPC") #'jj-split-toggle-line-selection)
    (define-key map (kbd "s") #'jj-split-select-hunk)
    (define-key map (kbd "u") #'jj-split-unselect-hunk)
    (define-key map (kbd "S") #'jj-split-select-file)
    (define-key map (kbd "U") #'jj-split-unselect-file)
    (define-key map (kbd "r") #'jj-split-reset-selections)
    ;; Actions
    (define-key map (kbd "RET") #'jj-split-accept-and-next)
    (define-key map (kbd "C-c C-c") #'jj-split-apply)
    (define-key map (kbd "C-c C-k") #'jj-split-abort)
    (define-key map (kbd "g") #'jj-split-refresh)
    (define-key map (kbd "?") #'jj-split-help)
    map)
  "Keymap for `jj-split-mode'.")

(define-derived-mode jj-split-mode magit-section-mode "JJ-Split"
  "Major mode for interactive jj split operations."
  (setq-local revert-buffer-function #'jj-split-refresh)
  (setq-local buffer-read-only t)
  (setq magit-section-preserve-visibility t))

;;; Diff Parsing

(defun jj-split--parse-diff (diff-output)
  "Parse DIFF-OUTPUT into jj-split-line structures."
  (let ((lines (split-string diff-output "\n"))
        (current-file nil)
        (current-hunk nil)
        (current-hunk-id 0)
        (line-number 0)
        (result '()))
    (dolist (line lines)
      (cond
       ;; File header: diff --git a/file b/file
       ((string-match "^diff --git a/\\(.+\\) b/\\(.+\\)$" line)
        (setq current-file (match-string 1 line))
        (setq current-hunk-id 0))
       ;; Hunk header: @@ -10,5 +10,8 @@
       ((string-match "^@@\\s-+\\(-[0-9]+,[0-9]+\\)\\s-+\\(\\+[0-9]+,[0-9]+\\)\\s-+@@\\(.*\\)?$" line)
        (setq current-hunk line)
        (setq current-hunk-id (1+ current-hunk-id))
        (setq line-number 0))
       ;; Skip other header lines
       ((or (string-match "^index " line)
            (string-match "^--- " line)
            (string-match "^\\+\\+\\+ " line)
            (string-match "^new file mode " line)
            (string-match "^deleted file mode " line))
        nil)
       ;; Diff content lines
       ((and current-file current-hunk
             (or (string-match "^\\([+-]\\)\\(.*\\)$" line)
                 (string-match "^\\( \\)\\(.*\\)$" line)))
        (let* ((prefix (match-string 1 line))
               (content (match-string 2 line))
               (type (cond ((string= prefix "+") 'addition)
                           ((string= prefix "-") 'deletion)
                           (t 'context)))
               (line-id (format "%s:%d:%d" current-file current-hunk-id line-number))
               (selectable (not (eq type 'context))))
          (setq line-number (1+ line-number))
          (push (make-jj-split-line
                 :id line-id
                 :file current-file
                 :hunk-header current-hunk
                 :hunk-id current-hunk-id
                 :line-number line-number
                 :content content
                 :type type
                 :selected nil
                 :section-ref nil)
                result)))))
    (nreverse result)))

;;; Buffer Generation

(defun jj-split--generate-buffer (lines)
  "Generate the split buffer content from LINES."
  (let ((inhibit-read-only t)
        (current-file nil)
        (current-hunk nil))
    (erase-buffer)
    (magit-insert-section (jj-split-root-section)
      (magit-insert-heading (format "JJ %s Buffer for revision %s\n"
                                    (capitalize (symbol-name jj-split-operation))
                                    jj-split-revision))
      (dolist (line lines)
        (let ((file (jj-split-line-file line))
              (hunk-header (jj-split-line-hunk-header line)))
          ;; Insert file section if new file
          (unless (equal file current-file)
            (setq current-file file)
            (setq current-hunk nil)
            (magit-insert-section (jj-split-file-section :file-path file)
              (magit-insert-heading (propertize (format "File: %s\n" file)
                                                'face 'magit-section-heading))))
          ;; Insert hunk section if new hunk
          (unless (equal hunk-header current-hunk)
            (setq current-hunk hunk-header)
            (magit-insert-section (jj-split-hunk-section 
                                   :hunk-header hunk-header
                                   :hunk-id (jj-split-line-hunk-id line))
              (magit-insert-heading (propertize (format "%s\n" hunk-header)
                                                'face 'magit-diff-hunk-heading))))
          ;; Insert line section
          (magit-insert-section (jj-split-line-section :line-data line)
            (let* ((indicator (if (eq (jj-split-line-type line) 'context)
                                  "   "
                                (if (jj-split-line-selected line) "[*]" "[ ]")))
                   (prefix (pcase (jj-split-line-type line)
                             ('addition "+")
                             ('deletion "-")
                             ('context " ")))
                   (face (pcase (jj-split-line-type line)
                           ('addition (if (jj-split-line-selected line)
                                          'jj-split-selected-face
                                        'jj-split-unselected-face))
                           ('deletion (if (jj-split-line-selected line)
                                          'jj-split-deletion-selected-face
                                        'jj-split-deletion-face))
                           ('context 'jj-split-context-face))))
              (insert (propertize (format "%s %s %s\n" 
                                          indicator
                                          prefix
                                          (jj-split-line-content line))
                                  'face face
                                  'jj-split-line-id (jj-split-line-id line)
                                  'jj-split-selectable (not (eq (jj-split-line-type line) 'context))))
              ;; Store reference to this line in the section
              (setf (jj-split-line-section-ref line) magit-insert-section--current))))))
    (insert "\n")
    (insert "Keybindings:\n")
    (insert "  SPC - Toggle line selection\n")
    (insert "  s/u - Select/unselect hunk\n")
    (insert "  S/U - Select/unselect file\n")
    (insert "  RET - Accept line and move to next\n")
    (insert "  C-c C-c - Apply changes\n")
    (insert "  C-c C-k - Abort\n")))

;;; Selection Functions

(defun jj-split--get-current-line-data ()
  "Get the line data for the line at point."
  ;; Try text property first
  (when-let ((line-id (get-text-property (point) 'jj-split-line-id)))
    (seq-find (lambda (line) (equal (jj-split-line-id line) line-id)) jj-split-lines)))

(defun jj-split--find-lines-by-predicate (predicate)
  "Find all lines matching PREDICATE."
  (seq-filter predicate jj-split-lines))

(defun jj-split--refresh-buffer ()
  "Refresh the entire buffer display."
  (let ((current-pos (point)))
    (jj-split--generate-buffer jj-split-lines)
    (goto-char (min current-pos (point-max)))))

(defun jj-split--refresh-line-display (line)
  "Refresh the display of a specific LINE."
  ;; For now, just refresh the whole buffer - this is simpler and more reliable
  (jj-split--refresh-buffer))

(defun jj-split-toggle-line-selection ()
  "Toggle selection of current line."
  (interactive)
  (if (get-text-property (point) 'jj-split-selectable)
      (if-let ((line-data (jj-split--get-current-line-data)))
          (progn
            (setf (jj-split-line-selected line-data) 
                  (not (jj-split-line-selected line-data)))
            (jj-split--refresh-line-display line-data)
            (message "Line %s" (if (jj-split-line-selected line-data) "selected" "unselected")))
        (message "Could not find line data"))
    (message "Line not selectable")))

(defun jj-split-accept-and-next ()
  "Accept (select) current line and move to next selectable line."
  (interactive)
  (if (get-text-property (point) 'jj-split-selectable)
      (if-let ((line-data (jj-split--get-current-line-data)))
          (progn
            ;; Select the current line
            (setf (jj-split-line-selected line-data) t)
            (jj-split--refresh-line-display line-data)
            (message "Line selected")
            ;; Move to next selectable line
            (jj-split--move-to-next-selectable-line))
        (message "Could not find line data"))
    (progn
      ;; Not selectable, just move to next selectable line
      (jj-split--move-to-next-selectable-line))))

(defun jj-split--move-to-next-selectable-line ()
  "Move to the next selectable line."
  (let ((start-pos (point))
        (found nil))
    (while (and (not found) (< (point) (point-max)))
      (forward-line 1)
      (when (get-text-property (point) 'jj-split-selectable)
        (setq found t)))
    (unless found
      ;; No more selectable lines, stay at current position or go back
      (goto-char start-pos)
      (message "No more selectable lines"))))

(defun jj-split-select-hunk ()
  "Select all lines in current hunk."
  (interactive)
  (when-let ((line-data (jj-split--get-current-line-data)))
    (let ((hunk-id (jj-split-line-hunk-id line-data))
          (file (jj-split-line-file line-data)))
      (dolist (line (jj-split--find-lines-by-predicate
                     (lambda (l) (and (equal (jj-split-line-file l) file)
                                      (equal (jj-split-line-hunk-id l) hunk-id)
                                      (not (eq (jj-split-line-type l) 'context))))))
        (setf (jj-split-line-selected line) t)
        (jj-split--refresh-line-display line)))))

(defun jj-split-unselect-hunk ()
  "Unselect all lines in current hunk."
  (interactive)
  (when-let ((line-data (jj-split--get-current-line-data)))
    (let ((hunk-id (jj-split-line-hunk-id line-data))
          (file (jj-split-line-file line-data)))
      (dolist (line (jj-split--find-lines-by-predicate
                     (lambda (l) (and (equal (jj-split-line-file l) file)
                                      (equal (jj-split-line-hunk-id l) hunk-id)
                                      (not (eq (jj-split-line-type l) 'context))))))
        (setf (jj-split-line-selected line) nil)
        (jj-split--refresh-line-display line)))))

(defun jj-split-select-file ()
  "Select all lines in current file."
  (interactive)
  (when-let ((line-data (jj-split--get-current-line-data)))
    (let ((file (jj-split-line-file line-data)))
      (dolist (line (jj-split--find-lines-by-predicate
                     (lambda (l) (and (equal (jj-split-line-file l) file)
                                      (not (eq (jj-split-line-type l) 'context))))))
        (setf (jj-split-line-selected line) t)
        (jj-split--refresh-line-display line)))))

(defun jj-split-unselect-file ()
  "Unselect all lines in current file."
  (interactive)
  (when-let ((line-data (jj-split--get-current-line-data)))
    (let ((file (jj-split-line-file line-data)))
      (dolist (line (jj-split--find-lines-by-predicate
                     (lambda (l) (and (equal (jj-split-line-file l) file)
                                      (not (eq (jj-split-line-type l) 'context))))))
        (setf (jj-split-line-selected line) nil)
        (jj-split--refresh-line-display line)))))

(defun jj-split-reset-selections ()
  "Reset all selections."
  (interactive)
  (dolist (line jj-split-lines)
    (when (not (eq (jj-split-line-type line) 'context))
      (setf (jj-split-line-selected line) nil)
      (jj-split--refresh-line-display line))))

;;; Navigation Functions

(defun jj-split-next-line ()
  "Move to next diff line."
  (interactive)
  (magit-section-forward))

(defun jj-split-previous-line ()
  "Move to previous diff line."
  (interactive)
  (magit-section-backward))

(defun jj-split-previous-hunk ()
  "Move to previous hunk."
  (interactive)
  (when-let ((section (magit-current-section)))
    (while (and section (not (eq (eieio-object-class section) 'jj-split-hunk-section)))
      (setq section (magit-section-parent section)))
    (when section
      (magit-section-backward-sibling))))

(defun jj-split-next-hunk ()
  "Move to next hunk."
  (interactive)
  (when-let ((section (magit-current-section)))
    (while (and section (not (eq (eieio-object-class section) 'jj-split-hunk-section)))
      (setq section (magit-section-parent section)))
    (when section
      (magit-section-forward-sibling))))

(defun jj-split-previous-file ()
  "Move to previous file."
  (interactive)
  (when-let ((section (magit-current-section)))
    (while (and section (not (eq (eieio-object-class section) 'jj-split-file-section)))
      (setq section (magit-section-parent section)))
    (when section
      (magit-section-backward-sibling))))

(defun jj-split-next-file ()
  "Move to next file."
  (interactive)
  (when-let ((section (magit-current-section)))
    (while (and section (not (eq (eieio-object-class section) 'jj-split-file-section)))
      (setq section (magit-section-parent section)))
    (when section
      (magit-section-forward-sibling))))

;;; Remaining Functions

(defun jj-split-apply ()
  "Apply the split with current selections."
  (interactive)
  (message "Apply functionality not yet implemented - this will create the actual diffedit command"))

(defun jj-split-abort ()
  "Abort the split operation."
  (interactive)
  (when (y-or-n-p "Abort split operation? ")
    (kill-buffer)))

(defun jj-split-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the split buffer."
  (interactive)
  (let ((current-pos (point)))
    (jj-split--load-diff-data)
    (goto-char (min current-pos (point-max)))))

(defun jj-split-help ()
  "Show help for split mode."
  (interactive)
  (with-help-window "*JJ Split Help*"
    (princ "JJ Split Mode Help\n")
    (princ "==================\n\n")
    (princ "Navigation:\n")
    (princ "  p/n     - Previous/next section\n")
    (princ "  j/k     - Previous/next line\n") 
    (princ "  P/N     - Previous/next hunk\n")
    (princ "  M-p/M-n - Previous/next file\n")
    (princ "  TAB     - Toggle section folding\n\n")
    (princ "Selection:\n")
    (princ "  SPC     - Toggle line selection\n")
    (princ "  s/u     - Select/unselect hunk\n")
    (princ "  S/U     - Select/unselect file\n")
    (princ "  r       - Reset all selections\n\n")
    (princ "Actions:\n")
    (princ "  RET     - Accept line and move to next\n")
    (princ "  C-c C-c - Apply changes\n")
    (princ "  C-c C-k - Abort\n")
    (princ "  g       - Refresh\n")
    (princ "  ?       - Show this help\n")))

;;; Entry Points

(defun jj-diffedit-interactive (&optional revision)
  "Start interactive diffedit for REVISION (default: @)."
  (interactive)
  (let* ((rev (or revision "@"))
         (buffer-name (format "*jj-diffedit:%s*" rev)))
    (with-current-buffer (get-buffer-create buffer-name)
      (jj-split-mode)
      (setq jj-split-revision rev)
      (setq jj-split-operation 'diffedit)
      (jj-split--load-diff-data)
      (goto-char (point-min)))
    (switch-to-buffer buffer-name)))

(defun jj-split--load-diff-data ()
  "Load diff data for current revision and generate buffer."
  (let ((diff-output (jj--run-command "diff" "--git" "-r" jj-split-revision)))
    (if (string-empty-p (string-trim diff-output))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "No changes to edit in revision %s\n" jj-split-revision)))
      (setq jj-split-lines (jj-split--parse-diff diff-output))
      (jj-split--generate-buffer jj-split-lines))))

(provide 'jj-split)
;;; jj-split.el ends here
