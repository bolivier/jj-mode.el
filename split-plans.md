# JJ Interactive Split Mode Implementation Plan

## Overview

Create an interactive diff editor mode for jj operations (split, diffedit, interactive squash) that provides line-by-line selection across multiple files, using a simplified two-section layout with efficient state management.

## Architecture

### Core Components

1. **jj-split-mode**: A major mode derived from `magit-section-mode` for interactive diff editing
2. **Section Types**: File and line sections for granular diff content organization  
3. **State Management**: Single unified state model with line-level granularity
4. **Action System**: Handle user actions (accept, reject, undo, apply) on lines and hunks
5. **Integration Layer**: Connect with existing jj-mode functions and commands

### Buffer Structure

```
JJ Split Buffer for commit abc123def

[FILE SECTION: src/main.rs]
  [HUNK SECTION: @@ -10,5 +10,8 @@]
        old line
    [ ] + new line 1                  
    [*] + new line 2                  
[FILE SECTION: tests/test.rs]  
  [HUNK SECTION: @@ -1,3 +1,6 @@]
    [ ] + added test                  
    [ ] + test helper                 
[FILE SECTION: src/config.rs]
  [HUNK SECTION: @@ -5,2 +5,4 @@]
    [*] + config option              
    [*] + default value              
```

## Implementation Plan

### Phase 1: Core Infrastructure

#### 1.1 Define Section Classes
- `jj-split-file-section`: File-level diff sections
- `jj-split-hunk-section`: Individual hunk sections
- `jj-split-line-section`: Individual line sections within hunks

#### 1.2 Create jj-split-mode
```elisp
(define-derived-mode jj-split-mode magit-section-mode "JJ-Split"
  "Major mode for interactive jj split operations."
  (setq-local revert-buffer-function 'jj-split-refresh)
  (setq-local buffer-read-only t))  ; Keep read-only, use overlays for interaction
```

#### 1.3 Basic Navigation Keybindings
- `p`/`n`: Navigate between sections (reuse magit-section navigation)
- `P`/`N`: Navigate between hunks specifically  
- `M-p`/`M-n`: Navigate between files
- `j`/`k`: Navigate between lines within hunks
- `TAB`: Toggle section folding

### Phase 2: Simplified State Management

#### 2.1 Unified Data Structure
```elisp
(cl-defstruct jj-split-line
  id          ; unique identifier "file:hunk:line"
  file        ; file path
  hunk-header ; @@ -10,5 +10,8 @@ style header  
  line-number ; line number within hunk
  content     ; line content
  type        ; 'context, 'addition, 'deletion
  selected    ; boolean - is this line selected
  section-ref ; reference to magit section
)

(defvar-local jj-split-lines nil
  "List of all diff lines with selection state")
```

#### 2.2 Core Actions
- `SPC`: Toggle selection of current line/hunk
- `s`: Select current hunk (all lines in hunk)
- `u`: Unselect current hunk (all lines in hunk)
- `S`: Select all lines in current file
- `U`: Unselect all lines in current file
- `r`: Reset all selections
- `RET`: Apply split with current selections

#### 2.3 Visual State Management
- Use text properties and overlays for selection state:
  - `jj-split-selected-face`: Highlight for selected lines
  - `jj-split-unselected-face`: Default for unselected lines
  - `jj-split-context-face`: Dimmed for context lines
- Display selection indicators: `[*]` selected, `[ ]` unselected, `   ` context

### Phase 3: Line-Level Management

#### 3.1 Selection Functions
- `jj-split-toggle-line-selection`: Toggle current line
- `jj-split-select-hunk`: Select all selectable lines in current hunk
- `jj-split-unselect-hunk`: Unselect all lines in current hunk  
- `jj-split-refresh-display`: Update visual state without rebuilding buffer

#### 3.2 Efficient Buffer Updates
- Use overlays for selection indicators to avoid buffer rebuilds
- Update only affected lines when selection changes
- Lazy rendering for large files (show first N hunks, expand on demand)

#### 3.3 Section Generation
- `jj-split-insert-file-section`: Show file with all lines and current selection state
- Single unified display with inline selection indicators
- No separate sections - all changes visible with `[*]`/`[ ]` indicators

### Phase 4: Integration with jj Commands

#### 4.1 Entry Points
- `jj-split-interactive`: Launch split mode for current/specified commit
- `jj-diffedit-interactive`: Launch diffedit mode 
- `jj-squash-interactive`: Launch interactive squash mode

#### 4.2 Command Integration
```elisp
(defun jj-split-interactive (&optional revision)
  "Start interactive split for REVISION (default: @)."
  (let* ((rev (or revision "@"))
         (buffer-name (format "*jj-split:%s*" rev))
         (diff-output (jj--run-command "diff" "-r" rev "--git")))
    (jj-split-create-buffer buffer-name diff-output rev)))
```

#### 4.3 Apply Changes
- `jj-split-apply`: Generate final command based on accepted/rejected hunks
- Create temporary files for partial commits
- Execute appropriate jj command with selected changes

### Phase 4: Advanced Features

#### 4.1 Undo System
- Implement simple action history for selections
- Track selection state changes for undo
- `C-/`: Standard Emacs undo for selections

#### 4.2 Search and Navigation
- `/`: Search for text within diff
- `?`: Search backwards  
- `g`: Refresh from jj (re-read diff)

#### 4.3 Multi-file Operations
- `m`: Mark/unmark files for bulk operations
- `M-s`: Select all hunks in marked files
- `M-u`: Unselect all hunks in marked files

### Phase 5: User Experience & Polish

#### 5.1 Help and Documentation  
- `?`: Show help transient with available commands
- Context-sensitive help based on current section type
- Integration with existing jj-mode help system

#### 5.2 Error Handling & Edge Cases
- Validate line selections before applying
- Handle binary files gracefully
- Support for very large diffs with lazy loading
- Empty commits and merge commits

#### 5.3 Performance Optimization
- Efficient overlay management
- Minimal buffer rebuilds
- Memory-conscious design for large files

## Simplified File Organization

```
jj-split.el              ; Single file implementation to start
```

## Key Benefits

1. **Native Emacs Experience**: Full integration with Emacs editing environment
2. **Magit-Style Navigation**: Familiar keybindings and section-based interface
3. **Line-Level Granularity**: Select individual lines across multiple files
4. **Simplified State Model**: Single unified view with inline selection indicators
5. **Performance-Conscious**: Efficient updates using overlays, minimal rebuilds
6. **Consistency**: Matches existing jj-mode patterns and conventions

## Success Criteria

- [ ] Can split a commit interactively with `p`/`n` navigation
- [ ] Can select/unselect individual lines with `SPC`
- [ ] Can select/unselect entire hunks with `s`/`u`
- [ ] Visual indicators show selection state clearly
- [ ] Can navigate between files and see all changes
- [ ] Final split operation works correctly with jj
- [ ] Mode integrates seamlessly with existing jj-mode
- [ ] Performance remains good with large diffs

This simplified architecture focuses on the core functionality while maintaining the flexibility for line-level selection across multiple files, with a much more achievable implementation scope.