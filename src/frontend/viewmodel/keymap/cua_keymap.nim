## cua_keymap.nim — THE CUA BASE KEYMAP's editor layer, as data.
##
## Owns: the rows of `codetracer-specs/spec/GUI/CUA-Keymap.md` §3.1–§3.4 (the
## editor: caret and selection, multiple cursors, editing, folding) and §3.10
## (the legacy-terminal fallbacks of those rows) — VS Code 1.105.0's bindings,
## the default base (Base-Keymaps-And-Layer-Stack.md §3.1).
##
## Refuses to own: what the rows MEAN (the editing vocabulary,
## `editor/operations.nim`), how a row becomes a binding (`base_rows.nim`), and
## every other scope — panes, the find widget, lists, overlays, the debugger
## layer (CUA-Keymap.md §3.5–§3.9, §4) — which PLAT-68's second phase lays
## over PLAT-64's router.
##
## **NOTHING HERE BUT DATA.** No procedure, no closure, no `case` over keys
## (Base-Keymaps §8 item 3). Each row is spelled as CUA-Keymap.md spells it,
## `writable` expanded, so `test_plat68_cua_oracle.nim` compares the two row by
## row in both directions; an edit here that is not an edit there is red.
##
## `CuaDeferred` holds the §3.1–§3.4 / §3.10 rows whose operation is an
## editor-PANE operation (scrolling, word wrap, Tab-moves-focus): they act on
## the pane's viewport or settings, not on `EditorState`, so they belong to the
## pane table PLAT-64's router dispatches, and binding them here would need a
## second dispatch. The oracle counts them by name.

import ./base_rows
import ./when_expr

const
  Writable = "editorTextFocus && !editorReadOnly"
    ## CUA-Keymap.md §2's `writable`, spelled out as the data must.

  CuaRows*: seq[BaseRow] = @[
    # --- §3.1 Editor — caret and selection ---------------------------------
    BaseRow(chords: "Left", operation: "editor.move-char-left", whenText: "editorTextFocus"),
    BaseRow(chords: "Right", operation: "editor.move-char-right", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Left", operation: "editor.extend-char-left", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Right", operation: "editor.extend-char-right", whenText: "editorTextFocus"),
    BaseRow(chords: "Up", operation: "editor.move-line-up", whenText: "editorTextFocus"),
    BaseRow(chords: "Down", operation: "editor.move-line-down", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Up", operation: "editor.extend-line-up", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Down", operation: "editor.extend-line-down", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Left", operation: "editor.move-group-left", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Right", operation: "editor.move-group-right", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Shift+Left", operation: "editor.extend-group-left", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Shift+Right", operation: "editor.extend-group-right", whenText: "editorTextFocus"),
    BaseRow(chords: "Home", operation: "editor.move-line-start-smart", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Home", operation: "editor.extend-line-start-smart", whenText: "editorTextFocus"),
    BaseRow(chords: "End", operation: "editor.move-line-end", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+End", operation: "editor.extend-line-end", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Home", operation: "editor.move-doc-start", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+End", operation: "editor.move-doc-end", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Shift+Home", operation: "editor.extend-doc-start", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Shift+End", operation: "editor.extend-doc-end", whenText: "editorTextFocus"),
    BaseRow(chords: "PageUp", operation: "editor.move-page-up", whenText: "editorTextFocus"),
    BaseRow(chords: "PageDown", operation: "editor.move-page-down", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+PageUp", operation: "editor.extend-page-up", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+PageDown", operation: "editor.extend-page-down", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+A", operation: "editor.select-all", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+L", operation: "editor.expand-line-selection", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Alt+Right", operation: "editor.select-parent-syntax", whenText: "editorTextFocus"),
    BaseRow(chords: "Shift+Alt+Left", operation: "editor.select-child-syntax", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Shift+\\", operation: "editor.move-matching-bracket", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+U", operation: "editor.undo-selection", whenText: "editorTextFocus"),
    BaseRow(chords: "Escape", operation: "editor.keep-primary-selection",
            whenText: "editorTextFocus && editorHasMultipleSelections"),
    BaseRow(chords: "Shift+Escape", operation: "editor.keep-primary-selection",
            whenText: "editorTextFocus && editorHasMultipleSelections"),
    BaseRow(chords: "Escape", operation: "editor.simplify-selection",
            whenText: "editorTextFocus && editorHasSelection && !editorHasMultipleSelections"),
    BaseRow(chords: "Shift+Escape", operation: "editor.simplify-selection",
            whenText: "editorTextFocus && editorHasSelection && !editorHasMultipleSelections"),

    # --- §3.2 Editor — multiple cursors ------------------------------------
    BaseRow(chords: "Ctrl+Alt+Up", operation: "editor.add-cursor-above",
            whenText: "editorTextFocus", platforms: {pkWindows, pkMac}),
    BaseRow(chords: "Ctrl+Alt+Down", operation: "editor.add-cursor-below",
            whenText: "editorTextFocus", platforms: {pkWindows, pkMac}),
    BaseRow(chords: "Shift+Alt+Up", operation: "editor.add-cursor-above",
            whenText: "editorTextFocus", platforms: {pkLinux}),
    BaseRow(chords: "Shift+Alt+Down", operation: "editor.add-cursor-below",
            whenText: "editorTextFocus", platforms: {pkLinux}),
    BaseRow(chords: "Ctrl+Shift+Up", operation: "editor.add-cursor-above",
            whenText: "editorTextFocus", platforms: {pkLinux}),
    BaseRow(chords: "Ctrl+Shift+Down", operation: "editor.add-cursor-below",
            whenText: "editorTextFocus", platforms: {pkLinux}),
    BaseRow(chords: "Shift+Alt+I", operation: "editor.add-cursor-at-each-line-of-selection",
            whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+D", operation: "editor.add-cursor-at-next-match", whenText: "editorFocus"),
    BaseRow(chords: "Ctrl+K Ctrl+D", operation: "editor.move-last-cursor-to-next-match",
            whenText: "editorFocus"),
    BaseRow(chords: "Ctrl+Shift+L", operation: "editor.select-all-matches", whenText: "editorFocus"),
    BaseRow(chords: "Ctrl+F2", operation: "editor.select-all-matches", whenText: "editorTextFocus"),

    # --- §3.3 Editor — editing ---------------------------------------------
    BaseRow(chords: "Backspace", operation: "editor.delete-char-backward", whenText: Writable),
    BaseRow(chords: "Shift+Backspace", operation: "editor.delete-char-backward", whenText: Writable),
    BaseRow(chords: "Delete", operation: "editor.delete-char-forward", whenText: Writable),
    BaseRow(chords: "Ctrl+Backspace", operation: "editor.delete-group-backward", whenText: Writable),
    BaseRow(chords: "Ctrl+Delete", operation: "editor.delete-group-forward", whenText: Writable),
    BaseRow(chords: "Enter", operation: "editor.insert-newline-and-indent", whenText: Writable),
    BaseRow(chords: "Tab", operation: "editor.insert-tab",
            whenText: Writable & " && !editorHasMultiLineSelection && !tabMovesFocus"),
    BaseRow(chords: "Tab", operation: "editor.indent-selection",
            whenText: Writable & " && editorHasMultiLineSelection && !tabMovesFocus"),
    BaseRow(chords: "Shift+Tab", operation: "editor.dedent-selection",
            whenText: Writable & " && !tabMovesFocus"),
    BaseRow(chords: "Ctrl+]", operation: "editor.indent-selection", whenText: Writable),
    BaseRow(chords: "Ctrl+[", operation: "editor.dedent-selection", whenText: Writable),
    BaseRow(chords: "Ctrl+Enter", operation: "editor.open-line-below", whenText: Writable),
    BaseRow(chords: "Ctrl+Shift+Enter", operation: "editor.open-line-above", whenText: Writable),
    BaseRow(chords: "Alt+Up", operation: "editor.swap-line-up", whenText: Writable),
    BaseRow(chords: "Alt+Down", operation: "editor.swap-line-down", whenText: Writable),
    BaseRow(chords: "Shift+Alt+Up", operation: "editor.copy-line-up",
            whenText: Writable, platforms: {pkWindows, pkMac}),
    BaseRow(chords: "Shift+Alt+Down", operation: "editor.copy-line-down",
            whenText: Writable, platforms: {pkWindows, pkMac}),
    BaseRow(chords: "Ctrl+Shift+Alt+Up", operation: "editor.copy-line-up",
            whenText: Writable, platforms: {pkLinux}),
    BaseRow(chords: "Ctrl+Shift+Alt+Down", operation: "editor.copy-line-down",
            whenText: Writable, platforms: {pkLinux}),
    BaseRow(chords: "Ctrl+Shift+K", operation: "editor.delete-line", whenText: Writable),
    BaseRow(chords: "Ctrl+/", operation: "editor.toggle-comment", whenText: Writable),
    BaseRow(chords: "Ctrl+K Ctrl+C", operation: "editor.line-comment", whenText: Writable),
    BaseRow(chords: "Ctrl+K Ctrl+U", operation: "editor.line-uncomment", whenText: Writable),
    BaseRow(chords: "Shift+Alt+A", operation: "editor.toggle-block-comment",
            whenText: Writable, platforms: {pkWindows, pkMac}),
    BaseRow(chords: "Ctrl+Shift+A", operation: "editor.toggle-block-comment",
            whenText: Writable, platforms: {pkLinux}),
    BaseRow(chords: "Ctrl+K Ctrl+X", operation: "editor.delete-trailing-whitespace", whenText: Writable),
    BaseRow(chords: "Ctrl+Z", operation: "editor.undo", whenText: Writable),
    BaseRow(chords: "Ctrl+Y", operation: "editor.redo", whenText: Writable),
    BaseRow(chords: "Ctrl+Shift+Z", operation: "editor.redo", whenText: Writable),
    BaseRow(chords: "Ctrl+X", operation: "editor.clipboard-cut", whenText: Writable),
    BaseRow(chords: "Shift+Delete", operation: "editor.clipboard-cut",
            whenText: Writable, platforms: {pkWindows}),
    BaseRow(chords: "Ctrl+C", operation: "editor.clipboard-copy", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Insert", operation: "editor.clipboard-copy",
            whenText: "editorTextFocus", platforms: {pkWindows}),
    BaseRow(chords: "Ctrl+V", operation: "editor.clipboard-paste", whenText: Writable),
    BaseRow(chords: "Shift+Insert", operation: "editor.clipboard-paste",
            whenText: Writable, platforms: {pkLinux, pkWindows}),
    BaseRow(chords: "Ctrl+S", operation: "editor.save",
            whenText: "editorFocus && productMode == edit"),
    BaseRow(chords: "Ctrl+Shift+S", operation: "editor.save-as",
            whenText: "editorFocus && productMode == edit"),
    BaseRow(chords: "Ctrl+K S", operation: "editor.save",
            whenText: "editorFocus && productMode == edit", platforms: {pkLinux, pkMac}),
    BaseRow(chords: "Ctrl+K Ctrl+Shift+S", operation: "editor.save",
            whenText: "editorFocus && productMode == edit", platforms: {pkWindows}),
    BaseRow(chords: "Ctrl+K S", operation: "editor.save-all",
            whenText: "productMode == edit", platforms: {pkWindows}),

    # --- §3.4 Editor — folding ---------------------------------------------
    BaseRow(chords: "Ctrl+Shift+[", operation: "editor.fold", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+Shift+]", operation: "editor.unfold", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+K Ctrl+[", operation: "editor.fold-recursively", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+K Ctrl+]", operation: "editor.unfold-recursively", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+K Ctrl+L", operation: "editor.toggle-fold", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+K Ctrl+0", operation: "editor.fold-all", whenText: "editorTextFocus"),
    BaseRow(chords: "Ctrl+K Ctrl+J", operation: "editor.unfold-all", whenText: "editorTextFocus"),

    # --- §3.10 Legacy-terminal fallbacks of the editor rows ----------------
    BaseRow(chords: "Ctrl+K Ctrl+K", operation: "editor.delete-line",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Ctrl+K /", operation: "editor.toggle-comment",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Ctrl+K O", operation: "editor.open-line-below",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Ctrl+K Shift+O", operation: "editor.open-line-above",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Ctrl+K [", operation: "editor.fold",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Ctrl+K ]", operation: "editor.unfold",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Ctrl+K 0", operation: "editor.fold-all",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Ctrl+K J", operation: "editor.unfold-all",
            whenText: "keyProtocol == legacy"),
    BaseRow(chords: "Shift+Alt+A", operation: "editor.toggle-block-comment",
            whenText: "keyProtocol == legacy", platforms: {pkLinux}),
  ]

  CuaDeferred*: seq[DeferredRow] = @[
    DeferredRow(chords: "Ctrl+Up", operation: "editor.scroll-line-up",
                whenText: "editorTextFocus", reason: PaneOperation),
    DeferredRow(chords: "Ctrl+Down", operation: "editor.scroll-line-down",
                whenText: "editorTextFocus", reason: PaneOperation),
    DeferredRow(chords: "Alt+PageUp", operation: "editor.scroll-page-up",
                whenText: "editorTextFocus", reason: PaneOperation),
    DeferredRow(chords: "Alt+PageDown", operation: "editor.scroll-page-down",
                whenText: "editorTextFocus", reason: PaneOperation),
    DeferredRow(chords: "Alt+Z", operation: "editor.toggle-word-wrap",
                whenText: "editorFocus", reason: PaneOperation),
    DeferredRow(chords: "Ctrl+M", operation: "editor.toggle-tab-moves-focus",
                whenText: "", reason: PaneOperation),
    DeferredRow(chords: "Ctrl+K M", operation: "editor.toggle-tab-moves-focus",
                whenText: "keyProtocol == legacy", reason: PaneOperation),
  ]
