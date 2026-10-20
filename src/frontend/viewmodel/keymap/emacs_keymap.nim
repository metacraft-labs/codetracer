## emacs_keymap.nim — THE EMACS BASE KEYMAP, as data.
##
## Owns: the rows of `codetracer-specs/spec/GUI/Emacs-Keymap.md` §3 — GNU
## Emacs's default keys for every scope this product has
## (Base-Keymaps-And-Layer-Stack.md §3.2): the editor, isearch (the find
## widget's layer), the minibuffer (single-line inputs), the completion list
## (the palette's layer), list buffers, windows and buffers (panes and session
## tabs), GUD's `C-x C-a` prefix and the desktop's F-key set for stepping.
##
## Refuses to own: what the rows mean (`editor/operations.nim`,
## `operation_catalogue.nim`) and how a row becomes a binding
## (`base_rows.nim`).
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
import ./when_expr

const
  Writable = "editorTextFocus && !editorReadOnly"
  Inactive = "editorTextFocus && editorMode != visual"
  Active = "editorTextFocus && editorMode == visual"
  InputWhen = "textInputFocus && !editorTextFocus"
  Debug = "productMode == debug"
  G = GlobalTable

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

    # --- §3.6 Search, the palette and the editor pane --------------------------
    BaseRow(chords: "Ctrl+S", operation: "find.open", whenText: "editorFocus"),
    BaseRow(chords: "Ctrl+R", operation: "find.open-backward", whenText: "editorFocus"),
    BaseRow(chords: "Alt+%", operation: "find.open-replace",
            whenText: "editorFocus && !editorReadOnly"),
    BaseRow(chords: "Alt+G G", operation: "palette.go-to-line", whenText: "editorFocus"),
    # `next-error` / `previous-error`: in Emacs they walk `grep` output.
    BaseRow(chords: "Alt+G N", operation: "search.next-result", table: G),
    BaseRow(chords: "Alt+G P", operation: "search.previous-result", table: G),
    # Find in Files' field: isearch's `M-c` / `M-r`, and `M-w` for the word
    # toggle (isearch's `M-s w` is a prefix the field does not have).
    BaseRow(chords: "Alt+C", operation: "search.toggle-case",
            whenText: "searchInputFocus", table: G),
    BaseRow(chords: "Alt+W", operation: "search.toggle-whole-word",
            whenText: "searchInputFocus", table: G),
    BaseRow(chords: "Alt+R", operation: "search.toggle-regex",
            whenText: "searchInputFocus", table: G),
    BaseRow(chords: "Ctrl+L", operation: "editor.center-on-pointer", whenText: "editorTextFocus"),
    BaseRow(chords: "Alt+X", operation: "palette.open-commands", table: G),

    # --- §3.7 Windows, buffers and the session ---------------------------------
    BaseRow(chords: "Alt+`", operation: "menu.open", table: G),
    BaseRow(chords: "Ctrl+X O", operation: "layout.focus-next-pane", table: G),
    BaseRow(chords: "Ctrl+X 1", operation: "layout.maximize-pane", table: G),
    BaseRow(chords: "Ctrl+X B", operation: "session-tabs.next-recent", table: G),
    BaseRow(chords: "Ctrl+X Right", operation: "session-tabs.next", table: G),
    BaseRow(chords: "Ctrl+X Left", operation: "session-tabs.previous", table: G),
    BaseRow(chords: "Ctrl+X K", operation: "session-tabs.close", table: G),
    BaseRow(chords: "Ctrl+X Ctrl+F", operation: "session.open-file", table: G),
    BaseRow(chords: "Ctrl+X Ctrl+Q", operation: "editor.toggle-read-only", table: G),
    BaseRow(chords: "Ctrl+X Ctrl+C", operation: "app.quit", table: G),
    # PLAT-70 (Horizontal-Overflow.md §4.4): GNU `scroll-left` (`C-x <`) moves
    # the TEXT left, so the view right; `scroll-right` the other way.
    BaseRow(chords: "Ctrl+X <", operation: "view.scroll-right-half",
            whenText: OutputPanesWhen, table: G),
    BaseRow(chords: "Ctrl+X >", operation: "view.scroll-left-half",
            whenText: OutputPanesWhen, table: G),
    BaseRow(chords: "Ctrl+G", operation: "layout.cancel-drag", whenText: "dragActive", table: G),

    # --- §3.8 Debugging: GUD's prefix and the desktop's F-keys ------------------
    BaseRow(chords: "Ctrl+X Ctrl+A Ctrl+N", operation: "debugger.step-over", whenText: Debug,
            table: G),
    BaseRow(chords: "Ctrl+X Ctrl+A Ctrl+S", operation: "debugger.step-into", whenText: Debug,
            table: G),
    BaseRow(chords: "Ctrl+X Ctrl+A Ctrl+F", operation: "debugger.step-out", whenText: Debug,
            table: G),
    BaseRow(chords: "Ctrl+X Ctrl+A Ctrl+R", operation: "debugger.continue", whenText: Debug,
            table: G),
    BaseRow(chords: "Ctrl+X Ctrl+A Ctrl+B", operation: "editor.toggle-breakpoint",
            whenText: "editorFocus", table: G),
    BaseRow(chords: "Enter", operation: "editor.toggle-tracepoint",
            whenText: "editorTextFocus && editorReadOnly && " & Debug),
    BaseRow(chords: "F8", operation: "debugger.continue", whenText: Debug, table: G),
    BaseRow(chords: "F2", operation: "debugger.continue", whenText: Debug, table: G),
    BaseRow(chords: "Shift+F8", operation: "debugger.reverse-continue", whenText: Debug, table: G),
    BaseRow(chords: "F10", operation: "debugger.step-over", whenText: Debug, table: G),
    BaseRow(chords: "Shift+F10", operation: "debugger.reverse-step-over", whenText: Debug,
            table: G),
    BaseRow(chords: "F11", operation: "debugger.step-into", whenText: Debug, table: G),
    BaseRow(chords: "Shift+F11", operation: "debugger.reverse-step-into", whenText: Debug,
            table: G),
    BaseRow(chords: "F12", operation: "debugger.step-out", whenText: Debug, table: G),
    BaseRow(chords: "Shift+F12", operation: "debugger.reverse-step-out", whenText: Debug,
            table: G),
    BaseRow(chords: "Alt+F10", operation: "debugger.step-over-statement", whenText: Debug,
            table: G),
    BaseRow(chords: "Alt+Shift+F10", operation: "debugger.reverse-step-over-statement",
            whenText: Debug, table: G),
    BaseRow(chords: "Shift+F5", operation: "debugger.stop", whenText: Debug, table: G),
    BaseRow(chords: "F5", operation: "debugger.continue", whenText: Debug, table: G),
    BaseRow(chords: "Ctrl+Shift+F5", operation: "debugger.restart", whenText: Debug, table: G),
    BaseRow(chords: "Ctrl+F5", operation: "session.toggle-product-mode", table: G),

    # --- §3.9 isearch: the find widget's layer ----------------------------------
    BaseRow(chords: "Ctrl+S", operation: "find.next", whenText: "findWidgetVisible",
            table: FindTable),
    BaseRow(chords: "Ctrl+R", operation: "find.previous", whenText: "findWidgetVisible",
            table: FindTable),
    BaseRow(chords: "Alt+C", operation: "find.toggle-case", whenText: "findWidgetVisible",
            table: FindTable),
    BaseRow(chords: "Alt+R", operation: "find.toggle-regex", whenText: "findWidgetVisible",
            table: FindTable),
    BaseRow(chords: "Enter", operation: "find.close", whenText: "findInputFocus",
            table: FindTable),
    BaseRow(chords: "Ctrl+G", operation: "find.close", whenText: "findWidgetVisible",
            table: FindTable),

    # --- §3.10 The minibuffer: single-line inputs --------------------------------
    BaseRow(chords: "Ctrl+F", operation: "input.move-right", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Right", operation: "input.move-right", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Ctrl+B", operation: "input.move-left", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Left", operation: "input.move-left", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Alt+F", operation: "input.move-word-right", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Alt+B", operation: "input.move-word-left", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Ctrl+A", operation: "input.move-start", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Home", operation: "input.move-start", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Ctrl+E", operation: "input.move-end", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "End", operation: "input.move-end", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Backspace", operation: "input.delete-backward", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Ctrl+D", operation: "input.delete-forward", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Delete", operation: "input.delete-forward", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Alt+Backspace", operation: "input.delete-word-backward", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Alt+D", operation: "input.delete-word-forward", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Ctrl+Y", operation: "input.paste", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Ctrl+/", operation: "input.undo", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Alt+P", operation: "input.history-previous", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Up", operation: "input.history-previous", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Alt+N", operation: "input.history-next", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Down", operation: "input.history-next", whenText: InputWhen,
            table: InputTable),
    BaseRow(chords: "Tab", operation: "input.complete", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Enter", operation: "input.commit", whenText: InputWhen, table: InputTable),
    BaseRow(chords: "Ctrl+G", operation: "input.cancel", whenText: InputWhen, table: InputTable),

    # --- §3.11 Completions: the palette's layer ----------------------------------
    BaseRow(chords: "Ctrl+N", operation: "palette.focus-next", table: PaletteTable),
    BaseRow(chords: "Down", operation: "palette.focus-next", table: PaletteTable),
    BaseRow(chords: "Ctrl+P", operation: "palette.focus-previous", table: PaletteTable),
    BaseRow(chords: "Up", operation: "palette.focus-previous", table: PaletteTable),
    BaseRow(chords: "Ctrl+V", operation: "palette.focus-page-down", table: PaletteTable),
    BaseRow(chords: "Alt+V", operation: "palette.focus-page-up", table: PaletteTable),
    BaseRow(chords: "Enter", operation: "palette.accept", table: PaletteTable),
    BaseRow(chords: "Ctrl+G", operation: "palette.close", table: PaletteTable),

    # --- §3.12 List buffers and menus ---------------------------------------------
    BaseRow(chords: "Up", operation: "list.focus-previous", whenText: "listFocus", table: ListTable),
    BaseRow(chords: "Ctrl+P", operation: "list.focus-previous", whenText: "listFocus",
            table: ListTable),
    BaseRow(chords: "Down", operation: "list.focus-next", whenText: "listFocus", table: ListTable),
    BaseRow(chords: "Ctrl+N", operation: "list.focus-next", whenText: "listFocus",
            table: ListTable),
    BaseRow(chords: "PageUp", operation: "list.focus-page-up", whenText: "listFocus",
            table: ListTable),
    BaseRow(chords: "PageDown", operation: "list.focus-page-down", whenText: "listFocus",
            table: ListTable),
    BaseRow(chords: "Home", operation: "list.focus-first", whenText: "listFocus", table: ListTable),
    BaseRow(chords: "End", operation: "list.focus-last", whenText: "listFocus", table: ListTable),
    BaseRow(chords: "Left", operation: "list.collapse", whenText: "treeFocus", table: ListTable),
    BaseRow(chords: "Right", operation: "list.expand", whenText: "treeFocus", table: ListTable),
    BaseRow(chords: "Space", operation: "list.toggle-expand", whenText: "treeFocus",
            table: ListTable),
    BaseRow(chords: "Enter", operation: "list.activate", whenText: "listFocus", table: ListTable),
    BaseRow(chords: "Ctrl+G", operation: "list.clear-selection",
            whenText: "listFocus && !dragActive",
            table: ListTable),
    BaseRow(chords: "Ctrl+S", operation: "list.filter", whenText: "listFocus", table: ListTable),
    BaseRow(chords: "Up", operation: "context-menu.focus-previous", table: ContextMenuTable),
    BaseRow(chords: "Ctrl+P", operation: "context-menu.focus-previous", table: ContextMenuTable),
    BaseRow(chords: "Down", operation: "context-menu.focus-next", table: ContextMenuTable),
    BaseRow(chords: "Ctrl+N", operation: "context-menu.focus-next", table: ContextMenuTable),
    BaseRow(chords: "Right", operation: "context-menu.enter-submenu", table: ContextMenuTable),
    BaseRow(chords: "Left", operation: "context-menu.leave-submenu", table: ContextMenuTable),
    BaseRow(chords: "Enter", operation: "context-menu.accept", table: ContextMenuTable),
    BaseRow(chords: "Ctrl+G", operation: "context-menu.close", table: ContextMenuTable),
  ]
