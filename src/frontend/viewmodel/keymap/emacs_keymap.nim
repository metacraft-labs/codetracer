## emacs_keymap.nim — THE EMACS BASE KEYMAP's editor layer, as data.
##
## Owns: the rows of `codetracer-specs/spec/GUI/Emacs-Keymap.md` §3 — GNU
## Emacs's default editing keys over the editing vocabulary
## (Base-Keymaps-And-Layer-Stack.md §3.2).
##
## Refuses to own: what the rows mean (`editor/operations.nim`), how a row
## becomes a binding (`base_rows.nim`), and every scope but the editor —
## windows, buffers, the minibuffer and GUD's `C-x C-a` prefix arrive with
## PLAT-68's second phase.
##
## **NOTHING HERE BUT DATA** (Base-Keymaps §8 item 3), compared row by row with
## Emacs-Keymap.md by `test_plat68_cua_oracle.nim`.
##
## THE ACTIVE MARK IS `visual` MODE. `C-SPC` (`set-mark`) collapses the region
## to the point and enters `visual`; every motion is two rows, the `move-` form
## while the mark is inactive and the `extend-` form while it is active, told
## apart by `editorMode` — the editor's own state (Editing-Operations §3), not
## a flag of this table's.

import ./base_rows

const
  Writable = "editorTextFocus && !editorReadOnly"
  Inactive = "editorTextFocus && editorMode != visual"
  Active = "editorTextFocus && editorMode == visual"

  EmacsRows*: seq[BaseRow] = @[
    # --- §3.1 Motion, with the mark inactive and active --------------------
    BaseRow(chords: "Ctrl+F", operation: "editor.move-char-forward", whenText: Inactive),
    BaseRow(chords: "Ctrl+F", operation: "editor.extend-char-forward", whenText: Active),
    BaseRow(chords: "Ctrl+B", operation: "editor.move-char-backward", whenText: Inactive),
    BaseRow(chords: "Ctrl+B", operation: "editor.extend-char-backward", whenText: Active),
    BaseRow(chords: "Ctrl+N", operation: "editor.move-line-down", whenText: Inactive),
    BaseRow(chords: "Ctrl+N", operation: "editor.extend-line-down", whenText: Active),
    BaseRow(chords: "Ctrl+P", operation: "editor.move-line-up", whenText: Inactive),
    BaseRow(chords: "Ctrl+P", operation: "editor.extend-line-up", whenText: Active),
    BaseRow(chords: "Ctrl+A", operation: "editor.move-line-start", whenText: Inactive),
    BaseRow(chords: "Ctrl+A", operation: "editor.extend-line-start", whenText: Active),
    BaseRow(chords: "Ctrl+E", operation: "editor.move-line-end", whenText: Inactive),
    BaseRow(chords: "Ctrl+E", operation: "editor.extend-line-end", whenText: Active),
    BaseRow(chords: "Alt+F", operation: "editor.move-group-forward", whenText: Inactive),
    BaseRow(chords: "Alt+F", operation: "editor.extend-group-forward", whenText: Active),
    BaseRow(chords: "Alt+B", operation: "editor.move-group-backward", whenText: Inactive),
    BaseRow(chords: "Alt+B", operation: "editor.extend-group-backward", whenText: Active),
    BaseRow(chords: "Alt+<", operation: "editor.move-doc-start", whenText: Inactive),
    BaseRow(chords: "Alt+<", operation: "editor.extend-doc-start", whenText: Active),
    BaseRow(chords: "Alt+>", operation: "editor.move-doc-end", whenText: Inactive),
    BaseRow(chords: "Alt+>", operation: "editor.extend-doc-end", whenText: Active),
    BaseRow(chords: "Ctrl+V", operation: "editor.move-page-down", whenText: Inactive),
    BaseRow(chords: "Ctrl+V", operation: "editor.extend-page-down", whenText: Active),
    BaseRow(chords: "Alt+V", operation: "editor.move-page-up", whenText: Inactive),
    BaseRow(chords: "Alt+V", operation: "editor.extend-page-up", whenText: Active),
    BaseRow(chords: "Alt+}", operation: "editor.move-paragraph-forward", whenText: Inactive),
    BaseRow(chords: "Alt+}", operation: "editor.extend-paragraph-forward", whenText: Active),
    BaseRow(chords: "Alt+{", operation: "editor.move-paragraph-backward", whenText: Inactive),
    BaseRow(chords: "Alt+{", operation: "editor.extend-paragraph-backward", whenText: Active),
    BaseRow(chords: "Right", operation: "editor.move-char-right", whenText: Inactive),
    BaseRow(chords: "Right", operation: "editor.extend-char-right", whenText: Active),
    BaseRow(chords: "Left", operation: "editor.move-char-left", whenText: Inactive),
    BaseRow(chords: "Left", operation: "editor.extend-char-left", whenText: Active),
    BaseRow(chords: "Down", operation: "editor.move-line-down", whenText: Inactive),
    BaseRow(chords: "Down", operation: "editor.extend-line-down", whenText: Active),
    BaseRow(chords: "Up", operation: "editor.move-line-up", whenText: Inactive),
    BaseRow(chords: "Up", operation: "editor.extend-line-up", whenText: Active),
    BaseRow(chords: "Home", operation: "editor.move-line-start", whenText: Inactive),
    BaseRow(chords: "Home", operation: "editor.extend-line-start", whenText: Active),
    BaseRow(chords: "End", operation: "editor.move-line-end", whenText: Inactive),
    BaseRow(chords: "End", operation: "editor.extend-line-end", whenText: Active),
    BaseRow(chords: "Ctrl+Home", operation: "editor.move-doc-start", whenText: Inactive),
    BaseRow(chords: "Ctrl+Home", operation: "editor.extend-doc-start", whenText: Active),
    BaseRow(chords: "Ctrl+End", operation: "editor.move-doc-end", whenText: Inactive),
    BaseRow(chords: "Ctrl+End", operation: "editor.extend-doc-end", whenText: Active),
    BaseRow(chords: "PageDown", operation: "editor.move-page-down", whenText: Inactive),
    BaseRow(chords: "PageDown", operation: "editor.extend-page-down", whenText: Active),
    BaseRow(chords: "PageUp", operation: "editor.move-page-up", whenText: Inactive),
    BaseRow(chords: "PageUp", operation: "editor.extend-page-up", whenText: Active),
    # --- §3.2 Shift-selection (`shift-select-mode`, on by default) ---------
    BaseRow(chords: "Shift+Right", operation: "editor.extend-char-right", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Left", operation: "editor.extend-char-left", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Down", operation: "editor.extend-line-down", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Up", operation: "editor.extend-line-up", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Home", operation: "editor.extend-line-start", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+End", operation: "editor.extend-line-end", whenText: "editorTextFocus"),

    # --- §3.3 The mark and the kill ring -----------------------------------
    BaseRow(chords: "Ctrl+Space", operation: "editor.set-mark", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+G", operation: "editor.deactivate-mark", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+X Ctrl+X", operation: "editor.exchange-point-and-mark", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+X H", operation: "editor.select-all", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+K", operation: "editor.kill-line", whenText: Writable),
    BaseRow(chords: "Ctrl+W", operation: "editor.kill-region", whenText: Writable),
    BaseRow(chords: "Alt+W", operation: "editor.copy-region", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Y", operation: "editor.yank", whenText: Writable),
    BaseRow(chords: "Alt+Y", operation: "editor.yank-pop", whenText: Writable),

    # --- §3.4 Editing --------------------------------------------------------
    BaseRow(chords: "Ctrl+D", operation: "editor.delete-char-forward", whenText: Writable),
    BaseRow(chords: "Delete", operation: "editor.delete-char-forward", whenText: Writable),
    BaseRow(chords: "Backspace", operation: "editor.delete-char-backward", whenText: Writable),
    BaseRow(chords: "Alt+D", operation: "editor.delete-group-forward", whenText: Writable),
    BaseRow(chords: "Alt+Backspace", operation: "editor.delete-group-backward", whenText: Writable),
    BaseRow(chords: "Enter", operation: "editor.insert-newline-and-indent", whenText: Writable),
    BaseRow(chords: "Ctrl+O", operation: "editor.split-line", whenText: Writable),
    BaseRow(chords: "Ctrl+T", operation: "editor.transpose-chars", whenText: Writable),
    BaseRow(chords: "Tab", operation: "editor.insert-tab", whenText: Writable),
    BaseRow(chords: "Ctrl+X Tab", operation: "editor.indent-selection", whenText: Writable),
    BaseRow(chords: "Alt+;", operation: "editor.toggle-comment", whenText: Writable),
    BaseRow(chords: "Ctrl+X Ctrl+U", operation: "editor.upper-case", whenText: Writable),
    BaseRow(chords: "Ctrl+X Ctrl+L", operation: "editor.lower-case", whenText: Writable),
    BaseRow(chords: "Ctrl+/", operation: "editor.undo", whenText: Writable),
    BaseRow(chords: "Ctrl+X U", operation: "editor.undo", whenText: Writable),
    BaseRow(chords: "Ctrl+Shift+/", operation: "editor.redo", whenText: Writable),

    # --- §3.5 Files ------------------------------------------------------------
    BaseRow(chords: "Ctrl+X Ctrl+S", operation: "editor.save",
            whenText: "editorFocus && productMode == edit"),
    BaseRow(chords: "Ctrl+X Ctrl+W", operation: "editor.save-as",
            whenText: "editorFocus && productMode == edit"),
    BaseRow(chords: "Ctrl+X S", operation: "editor.save-all", whenText: "productMode == edit"),
  ]

  EmacsDeferred*: seq[DeferredRow] = @[
    DeferredRow(chords: "Ctrl+S", operation: "find.open",
                whenText: "editorFocus", reason: OverlayOperation),
    DeferredRow(chords: "Ctrl+R", operation: "find.open-backward",
                whenText: "editorFocus", reason: OverlayOperation),
    DeferredRow(chords: "Alt+%", operation: "find.open-replace",
                whenText: "editorFocus && !editorReadOnly", reason: OverlayOperation),
    DeferredRow(chords: "Alt+G G", operation: "palette.go-to-line",
                whenText: "editorFocus", reason: OverlayOperation),
    DeferredRow(chords: "Alt+X", operation: "palette.open-commands",
                whenText: "", reason: OverlayOperation),
    DeferredRow(chords: "Ctrl+L", operation: "editor.center-on-pointer",
                whenText: "editorTextFocus", reason: PaneOperation),
  ]
