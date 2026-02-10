;;; test-setup.el --- Test setup for jj-mode -*- lexical-binding: t; -*-

;;; Commentary:
;; This file sets up the test environment by ensuring dependencies are available.
;; Run this before running tests if you get "Cannot open load file" errors.

;;; Code:

(require 'package)

;; Add MELPA if not already present
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

;; Refresh package list if needed
(unless package-archive-contents
  (package-refresh-contents))

;; Install dependencies if missing
(dolist (pkg '(magit transient))
  (unless (package-installed-p pkg)
    (message "Installing %s..." pkg)
    (package-install pkg)))

(message "Test dependencies installed successfully!")

(provide 'test-setup)
;;; test-setup.el ends here
