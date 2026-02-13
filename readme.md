# Jujutsu mode for Emacs

jj-mode provides a magit-inspired interface for
[Jujutsu](https://github.com/martinvonz/jj), offering an efficient way to
interact with JJ repositories from within Emacs.

## Features

- **Magit-style log viewer** with collapsible sections and syntax highlighting
- **Interactive rebase** with visual source/onto selection via transients
- **Bookmark management** with create, abandon, forget, track, and tug operations
- **Commit and describe** with dedicated message buffers and window management
- **Diff viewing** with file and hunk-level navigation
- **Context-sensitive actions** via DWIM (Do What I Mean) Enter key behavior
- **Git integration** with push/fetch operations and configurable options
- **Built-in conflict resolution** using Emacs ediff and smerge-mode

## Requirements

- Emacs 28.1 or later
- [Jujutsu (jj)](https://github.com/jj-vcs/jj) 0.37.0 or later installed and in PATH
- [magit](https://magit.vc/) (for section management and UI components)
- [transient](https://github.com/magit/transient) (usually bundled with magit)

## Installation

### Doom Emacs
```lisp
(package! jj-mode :recipe (:host github :repo "bolivier/jj-mode.el"))
```

### use-package with straight.el
```lisp
(use-package jj-mode
  :straight (:host github :repo "bolivier/jj-mode.el"))
```

### use-package with built-in package-vc integration
```lisp
(use-package jj-mode
  :vc (:url "https://github.com/bolivier/jj-mode.el"))
```

### Manual
Clone this repository and add it to your load path:
```lisp
(add-to-list 'load-path "/path/to/jj-mode")
(require 'jj-mode)
```

## Evil Mode

jj-mode doesn't ship with support for evil mode by default. To make it work you
need to put this snippet in your init config

```emacs-lisp
(evil-make-overriding-map jj-mode-map 'normal)
 
```

Or, in Doom Emacs

```emacs-lisp
(after! jj-mode
  (evil-make-overriding-map jj-mode-map 'normal))
```

## Usage

Start with `M-x jj-log` to open the main interface. Each project gets its own
buffer (`*jj-log:project-name*`).

### Key Bindings

#### Navigation
- `n`/`p` - Navigate between sections
- `RET` - Context-sensitive action (edit changeset, jump to file/line in diffs)
- `.` - Jump to current changeset (@)
- `TAB` - Toggle section folding

#### Basic Operations
- `g` - Refresh log
- `c` - Commit (opens message buffer)
- `d` - Describe changeset at point (opens message buffer)
- `D` - View diff for changeset
- `e` - Edit changeset (jj edit)
- `u` - Undo last operation
- `s` - Squash
- `N` - New changeset here
  - `n` create new changeset with options
  - `a` create new changeset after bookmark with options
  - `b` create new changeset before bookmark with options

#### Advanced Operations
- `r` - Rebase transient menu
  - `s` - Set rebase source
  - `o` - Toggle rebase onto target
  - `r` - Execute rebase
  - `c` - Clear selections
- `b` - Bookmark transient menu
  - `c` - Create bookmark
  - `a` - Abandon bookmark
  - `f` - Forget bookmark
  - `t` - Track remote bookmark
  - `T` - Tug (pull closest bookmark to current changeset)
- `G` - Git operations transient
  - `-b` - Set bookmark to push
  - `p` - Push
  - `f` - Fetch

#### Conflict Resolution
- `E` - Edit conflicts with ediff
- `M` - Edit conflicts with smerge-mode

#### Message Buffers
When editing commit/describe messages:
- `C-c C-c` - Finish and execute
- `C-c C-k` - Cancel

## Configuration

```lisp
;; Customize jj executable path if needed
(setq jj-executable "/path/to/jj")
```

## Upstream Breaking Changes

Since JJ is such a young project, there are sometimes breaking changes. Since
the project is so young, we will try to incorporate changes quickly. If you're
unable to update your version of jj to handle breaking changes upstream, it's
recommended that you pin jj-mode to a known good SHA. 

In addition to breaking changes, jj may introduce new mechanisms to manage a
repo. jj-mode will likewise migrate to those quickly.

## Contributing

Issues and pull requests welcome! This project aims to provide a solid JJ
interface while maintaining magit-like usability patterns.
