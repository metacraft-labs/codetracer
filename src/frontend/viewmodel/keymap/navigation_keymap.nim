## navigation_keymap.nim — THE MODAL BASES' NAVIGATION TABLE, as data.
##
## Owns: `codetracer-specs/spec/Front-Ends/CodeTracer-TUI.md` §4.2 — the pane
## navigation, stepping, seeking, value-origin, source, variables-tree,
## search, palette and command keys of the NORMAL / COMMAND / SEARCH /
## INSPECT machine (§4.1) — as the Vim and Kakoune bases' navigation layer
## (Base-Keymaps-And-Layer-Stack.md §3.2: *"§4.2 is the modal navigation those
## two bases were built beside"*). Every row is in the global table and holds
## in the navigation modes it names: the machine's mode is STATE, and the
## layer for a mode is this table filtered by it (§5.5's derived layers).
##
## Refuses to own: the editor's rows (`vim_keymap`, `kakoune_keymap`), what an
## operation does, and the machine's transitions (`tui/app/input/
## modal_state`).
##
## **NOTHING HERE BUT DATA** (§8 item 3). It was `tui/app/input/keymap.nim`'s
## `defaultKeymap()` and its own resolver; the rows moved here unchanged and
## the resolver was deleted, so the terminal's debugger keys and the editor's
## go through the one resolver (§8 item 1).
##
## §4.2 spells its chords its own way (`rf`, `Ctrl+w h`, `t <tick> Enter`);
## `test_keymap_no_conflicts.nim` compares this table with §4.2 through
## `SpecSpellings` below, which records the three places the spellings
## differ: `rf` / `rc` are two keys, and `t <tick> Enter` is the one key `t`
## (the digits and `Enter` belong to the tick prompt).

import ./base_rows
import ./editing_keymap

const
  N = {nmNormal}
  C = {nmCommand}
  S = {nmSearch}
  I = {nmInspect}
  G = GlobalTable

  NavigationRows*: seq[BaseRow] = @[
    # ---- NORMAL -------------------------------------------------------------
    # Pane Navigation
    BaseRow(chords: "Tab", operation: "layout.focus-next-pane", table: G, navModes: N),
    BaseRow(chords: "Shift+Tab", operation: "layout.focus-previous-pane", table: G, navModes: N),
    BaseRow(chords: "F6", operation: "layout.focus-next-pane", table: G, navModes: N),
    BaseRow(chords: "Shift+F6", operation: "layout.focus-previous-pane", table: G, navModes: N),
    BaseRow(chords: "Ctrl+W H", operation: "layout.focus-left", table: G, navModes: N),
    BaseRow(chords: "Ctrl+W J", operation: "layout.focus-down", table: G, navModes: N),
    BaseRow(chords: "Ctrl+W K", operation: "layout.focus-up", table: G, navModes: N),
    BaseRow(chords: "Ctrl+W L", operation: "layout.focus-right", table: G, navModes: N),
    BaseRow(chords: "1", operation: "layout.focus-pane(call-trace)", table: G, navModes: N),
    BaseRow(chords: "2", operation: "layout.focus-pane(editor)", table: G, navModes: N),
    BaseRow(chords: "3", operation: "layout.focus-pane(variables)", table: G, navModes: N),
    BaseRow(chords: "4", operation: "layout.focus-pane(event-log)", table: G, navModes: N),
    BaseRow(chords: "z", operation: "layout.maximize-pane", table: G, navModes: N,
            whenText: "!(" & OutputPanesWhen & ")"),
    # Omniscient Stepping
    BaseRow(chords: "n", operation: "debugger.step-over", table: G, navModes: N),
    BaseRow(chords: "F10", operation: "debugger.step-over", table: G, navModes: N),
    BaseRow(chords: "p", operation: "debugger.reverse-step-over", table: G, navModes: N),
    BaseRow(chords: "Shift+F10", operation: "debugger.reverse-step-over", table: G, navModes: N),
    BaseRow(chords: "s", operation: "debugger.step-into", table: G, navModes: N),
    BaseRow(chords: "F11", operation: "debugger.step-into", table: G, navModes: N),
    BaseRow(chords: "b", operation: "debugger.reverse-step-into", table: G, navModes: N),
    BaseRow(chords: "Shift+F11", operation: "debugger.reverse-step-into", table: G, navModes: N),
    BaseRow(chords: "f", operation: "debugger.step-out", table: G, navModes: N),
    BaseRow(chords: "Shift+F5", operation: "debugger.step-out", table: G, navModes: N),
    BaseRow(chords: "r f", operation: "debugger.reverse-step-out", table: G, navModes: N),
    BaseRow(chords: "c", operation: "debugger.continue", table: G, navModes: N),
    BaseRow(chords: "F5", operation: "debugger.continue", table: G, navModes: N),
    BaseRow(chords: "r c", operation: "debugger.reverse-continue", table: G, navModes: N),
    BaseRow(chords: "Alt+F5", operation: "debugger.reverse-continue", table: G, navModes: N),
    # Time-Travel Seeking
    BaseRow(chords: "[", operation: "debugger.previous-call", table: G, navModes: N),
    BaseRow(chords: "]", operation: "debugger.next-call", table: G, navModes: N),
    BaseRow(chords: "{", operation: "debugger.previous-mutation", table: G, navModes: N),
    BaseRow(chords: "}", operation: "debugger.next-mutation", table: G, navModes: N),
    BaseRow(chords: "g g", operation: "debugger.jump-to-start", table: G, navModes: N),
    BaseRow(chords: "Shift+G", operation: "debugger.jump-to-end", table: G, navModes: N),
    BaseRow(chords: "t", operation: "debugger.seek-to-tick", table: G, navModes: N),
    # History: the positions the debugger has stopped at, as the desktop's
    # back / forward buttons walk them (the browser's chords).
    BaseRow(chords: "Alt+Left", operation: "navigation.back", table: G, navModes: N),
    BaseRow(chords: "Alt+Right", operation: "navigation.forward", table: G, navModes: N),
    # Value Origin Tracking
    BaseRow(chords: "o", operation: "editor.jump-to-value-origin", table: G, navModes: N),
    BaseRow(chords: "Shift+O", operation: "debugger.reverse-origin", table: G, navModes: N),
    # Source Navigation
    BaseRow(chords: "j", operation: "editor.scroll-line-down", table: G, navModes: N),
    BaseRow(chords: "Down", operation: "editor.scroll-line-down", table: G, navModes: N),
    BaseRow(chords: "k", operation: "editor.scroll-line-up", table: G, navModes: N),
    BaseRow(chords: "Up", operation: "editor.scroll-line-up", table: G, navModes: N),
    BaseRow(chords: "Ctrl+U", operation: "editor.scroll-half-page-up", table: G, navModes: N),
    BaseRow(chords: "Ctrl+D", operation: "editor.scroll-half-page-down", table: G, navModes: N),
    BaseRow(chords: ".", operation: "editor.center-on-pointer", table: G, navModes: N),
    BaseRow(chords: "F9", operation: "editor.toggle-breakpoint", table: G, navModes: N),
    BaseRow(chords: "Space", operation: "editor.toggle-breakpoint", table: G, navModes: N),
    # PLAT-70 (Horizontal-Overflow.md §4.4): the output panes' view — Vim's
    # `zh` / `zl`, `zH` / `zL` and `0`. Over these two panes `z` is their
    # prefix, so `z` maximizes every OTHER pane (its `when` above).
    BaseRow(chords: "z h", operation: "view.scroll-left", table: G, navModes: N,
            whenText: OutputPanesWhen),
    BaseRow(chords: "z l", operation: "view.scroll-right", table: G, navModes: N,
            whenText: OutputPanesWhen),
    BaseRow(chords: "z Shift+H", operation: "view.scroll-left-half", table: G,
            navModes: N, whenText: OutputPanesWhen),
    BaseRow(chords: "z Shift+L", operation: "view.scroll-right-half", table: G,
            navModes: N, whenText: OutputPanesWhen),
    BaseRow(chords: "0", operation: "view.scroll-to-line-start", table: G,
            navModes: N, whenText: OutputPanesWhen),
    # Variables Tree
    BaseRow(chords: "Enter", operation: "list.expand", table: G, navModes: N,
            whenText: "!editorTextFocus"),
    BaseRow(chords: "l", operation: "list.expand", table: G, navModes: N),
    BaseRow(chords: "h", operation: "list.collapse", table: G, navModes: N),
    BaseRow(chords: "Backspace", operation: "list.collapse", table: G, navModes: N),
    BaseRow(chords: "x", operation: "variables.toggle-hex-dec", table: G, navModes: N),
    BaseRow(chords: "m", operation: "variables.view-memory-dump", table: G, navModes: N),
    # Search and Palette
    BaseRow(chords: "Ctrl+P", operation: "palette.open-commands", table: G, navModes: N),
    BaseRow(chords: "F1", operation: "palette.open-commands", table: G, navModes: N),
    BaseRow(chords: "Ctrl+Shift+P", operation: "palette.open-commands", table: G, navModes: N),
    BaseRow(chords: "/", operation: "find.open", table: G, navModes: N),
    BaseRow(chords: "?", operation: "find.open-backward", table: G, navModes: N),
    # Command Mode
    BaseRow(chords: ":", operation: "command-line.open", table: G, navModes: N),
    BaseRow(chords: "Escape", operation: "modal.return-to-normal", table: G, navModes: N),
    BaseRow(chords: "q", operation: "app.quit", table: G, navModes: N),
    BaseRow(chords: "Ctrl+C", operation: "app.quit", table: G, navModes: N),
    # §4.1's INSPECT entry
    BaseRow(chords: "i", operation: "inspect.open", table: G, navModes: N),
    # Mode-Transitions.md §1: the mode toggle
    BaseRow(chords: "Ctrl+F5", operation: "session.toggle-product-mode", table: G, navModes: N),
    # §3.3.1: the session tabs
    BaseRow(chords: "g t", operation: "session-tabs.next", table: G, navModes: N),
    BaseRow(chords: "g Shift+T", operation: "session-tabs.previous", table: G, navModes: N),
    BaseRow(chords: "Ctrl+Tab", operation: "session-tabs.next", table: G, navModes: N),
    BaseRow(chords: "Ctrl+Shift+Tab", operation: "session-tabs.previous", table: G, navModes: N),

    # ---- COMMAND: a text field; the three keys that are not text -------------
    BaseRow(chords: "Escape", operation: "modal.return-to-normal", table: G, navModes: C),
    BaseRow(chords: "Enter", operation: "input.commit", table: G, navModes: C),
    BaseRow(chords: "Backspace", operation: "input.delete-backward", table: G, navModes: C),

    # ---- SEARCH: `n` / `N` walk the matches once the query is committed ------
    BaseRow(chords: "Escape", operation: "modal.return-to-normal", table: G, navModes: S),
    BaseRow(chords: "Enter", operation: "input.commit", table: G, navModes: S),
    BaseRow(chords: "Backspace", operation: "input.delete-backward", table: G, navModes: S),
    BaseRow(chords: "n", operation: "find.next", table: G, navModes: S),
    BaseRow(chords: "Shift+N", operation: "find.previous", table: G, navModes: S),

    # ---- INSPECT --------------------------------------------------------------
    BaseRow(chords: "Enter", operation: "list.expand", table: G, navModes: I),
    BaseRow(chords: "l", operation: "list.expand", table: G, navModes: I),
    BaseRow(chords: "h", operation: "list.collapse", table: G, navModes: I),
    BaseRow(chords: "Backspace", operation: "list.collapse", table: G, navModes: I),
    BaseRow(chords: "x", operation: "variables.toggle-hex-dec", table: G, navModes: I),
    BaseRow(chords: "m", operation: "variables.view-memory-dump", table: G, navModes: I),
    BaseRow(chords: "o", operation: "editor.jump-to-value-origin", table: G, navModes: I),
    BaseRow(chords: "Shift+O", operation: "debugger.reverse-origin", table: G, navModes: I),
    BaseRow(chords: "j", operation: "editor.scroll-line-down", table: G, navModes: I),
    BaseRow(chords: "Down", operation: "editor.scroll-line-down", table: G, navModes: I),
    BaseRow(chords: "k", operation: "editor.scroll-line-up", table: G, navModes: I),
    BaseRow(chords: "Up", operation: "editor.scroll-line-up", table: G, navModes: I),
    BaseRow(chords: "Ctrl+U", operation: "editor.scroll-half-page-up", table: G, navModes: I),
    BaseRow(chords: "Ctrl+D", operation: "editor.scroll-half-page-down", table: G, navModes: I),
    BaseRow(chords: ":", operation: "command-line.open", table: G, navModes: I),
    BaseRow(chords: "/", operation: "find.open", table: G, navModes: I),
    BaseRow(chords: "?", operation: "find.open-backward", table: G, navModes: I),
    BaseRow(chords: "Escape", operation: "modal.return-to-normal", table: G, navModes: I),
  ]

  ModalSurfaceRows*: seq[BaseRow] = @[
    ## The modal bases' rows for the surfaces §4.2 does not tabulate, from
    ## their own sources:
    ##
    ##   * the command line and the find field are single-line inputs, and
    ##     Vim's own command-line editing keys are these (`:help
    ##     cmdline-editing`: the arrows, `<Home>` / `<End>`, `<Up>` / `<Down>`
    ##     history, `<Tab>` completion, `<Del>`, `CTRL-W`), and so are
    ##     `<CR>`, which executes the line (`:help c_<CR>`), and `<BS>`, which
    ##     deletes the character before the cursor (`:help c_<BS>`). Those two
    ##     are also the COMMAND and SEARCH rows below, which the terminal's
    ##     prompt reaches; they are here so that EVERY field takes them in
    ##     NORMAL too — a desktop text field (Base-Keymaps-And-Layer-Stack.md
    ##     §6.2), which has no prompt mode, would otherwise answer `Enter` with
    ##     §4.2's `list.expand` and `Backspace` with `list.collapse`;
    ##   * the palette and a context menu are lists of choices, walked as
    ##     Vim's own popup menu is (`:help popupmenu-keys`: the arrows,
    ##     `<PageUp>` / `<PageDown>`, `<CR>`, `<Esc>`);
    ##   * the terminal's chrome keys of PLAT-48 — `F12` opens the program
    ##     menu, `Ctrl+O` reveals the next docked pane — which the modal
    ##     machine had beside §4.2 and keeps in NORMAL.
    ##   * `Enter` in the read-only Debug editor opens the tracepoint editor,
    ##     as under every base (Base-Keymaps-And-Layer-Stack.md §3.2). A
    ##     modal base's read-only editor has no editor layer (§5.5), so the row
    ##     is global, beside §4.2's `Enter`, which expands a TREE node and
    ##     says so (`!editorTextFocus`).
    BaseRow(chords: "Left", operation: "input.move-left", table: InputTable),
    BaseRow(chords: "Right", operation: "input.move-right", table: InputTable),
    BaseRow(chords: "Shift+Left", operation: "input.move-word-left", table: InputTable),
    BaseRow(chords: "Shift+Right", operation: "input.move-word-right", table: InputTable),
    BaseRow(chords: "Home", operation: "input.move-start", table: InputTable),
    BaseRow(chords: "End", operation: "input.move-end", table: InputTable),
    BaseRow(chords: "Up", operation: "input.history-previous", table: InputTable),
    BaseRow(chords: "Down", operation: "input.history-next", table: InputTable),
    BaseRow(chords: "Tab", operation: "input.complete", table: InputTable),
    BaseRow(chords: "Delete", operation: "input.delete-forward", table: InputTable),
    BaseRow(chords: "Ctrl+W", operation: "input.delete-word-backward", table: InputTable),
    BaseRow(chords: "Enter", operation: "input.commit", table: InputTable),
    BaseRow(chords: "Backspace", operation: "input.delete-backward", table: InputTable),
    BaseRow(chords: "Up", operation: "palette.focus-previous", table: PaletteTable),
    BaseRow(chords: "Down", operation: "palette.focus-next", table: PaletteTable),
    BaseRow(chords: "PageUp", operation: "palette.focus-page-up", table: PaletteTable),
    BaseRow(chords: "PageDown", operation: "palette.focus-page-down", table: PaletteTable),
    BaseRow(chords: "Enter", operation: "palette.accept", table: PaletteTable),
    BaseRow(chords: "Escape", operation: "palette.close", table: PaletteTable),
    BaseRow(chords: "Up", operation: "context-menu.focus-previous", table: ContextMenuTable),
    BaseRow(chords: "Down", operation: "context-menu.focus-next", table: ContextMenuTable),
    BaseRow(chords: "Enter", operation: "context-menu.accept", table: ContextMenuTable),
    BaseRow(chords: "Escape", operation: "context-menu.close", table: ContextMenuTable),
    BaseRow(chords: "Enter", operation: "editor.toggle-tracepoint", table: G,
            navModes: N,
            whenText: "editorTextFocus && editorReadOnly && productMode == debug"),
    BaseRow(chords: "F12", operation: "menu.open", table: G, navModes: N),
    BaseRow(chords: "Ctrl+O", operation: "layout.reveal-next-docked", table: G,
            navModes: N),
  ]
