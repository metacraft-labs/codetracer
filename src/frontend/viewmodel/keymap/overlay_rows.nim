## overlay_rows.nim — the keys of the overlays every base shares: the program
## menu, a shown text (an event's content), the terminal's information dialog,
## and the Terminal Output pane's own keys.
##
## Owns: those rows as data (Input-Routing §4.3: no binding is installed by
## code; each of these was a `case` over key names in each front-end's view).
##
## Refuses to own: what the operations do (each front-end's operation tables
## onto `MenuVM` and the rest), the base-specific rows (`cua_keymap`,
## `emacs_keymap`, `navigation_keymap`), and resolution.
##
## These overlays read the same keys under every base, on purpose: an open menu
## in Vim is still a menu, as VS Code's is under a Vim extension. A user's row
## rebinds any of them like any other.

import ./base_rows

const
  OverlayRows*: seq[BaseRow] = @[
    # --- The program menu, while it is open (CUA-Keymap.md §3.8) -----------
    BaseRow(chords: "Up", operation: "menu.focus-previous", table: MenuTable),
    BaseRow(chords: "Down", operation: "menu.focus-next", table: MenuTable),
    BaseRow(chords: "Right", operation: "menu.enter-folder", table: MenuTable),
    BaseRow(chords: "Left", operation: "menu.leave-folder", table: MenuTable),
    BaseRow(chords: "Enter", operation: "menu.accept", table: MenuTable),
    BaseRow(chords: "Escape", operation: "menu.close", table: MenuTable),

    # --- A text shown over the window: an event's content, a tracepoint's hits
    BaseRow(chords: "Escape", operation: "content-view.close", table: ContentViewTable),
    BaseRow(chords: "Enter", operation: "content-view.close", table: ContentViewTable),
    BaseRow(chords: "q", operation: "content-view.close", table: ContentViewTable),
    BaseRow(chords: "Up", operation: "content-view.scroll-up", table: ContentViewTable),
    BaseRow(chords: "k", operation: "content-view.scroll-up", table: ContentViewTable),
    BaseRow(chords: "Down", operation: "content-view.scroll-down", table: ContentViewTable),
    BaseRow(chords: "j", operation: "content-view.scroll-down", table: ContentViewTable),
    BaseRow(chords: "PageUp", operation: "content-view.page-up", table: ContentViewTable),
    BaseRow(chords: "PageDown", operation: "content-view.page-down", table: ContentViewTable),
    BaseRow(chords: "Space", operation: "content-view.page-down", table: ContentViewTable),

    # --- The terminal's information dialog (CodeTracer-TUI-Terminal-Adaptation) -
    BaseRow(chords: "Escape", operation: "terminal-info.close", table: TerminalInfoTable),
    BaseRow(chords: "q", operation: "terminal-info.close", table: TerminalInfoTable),
    BaseRow(chords: "Up", operation: "terminal-info.scroll-up", table: TerminalInfoTable),
    BaseRow(chords: "Down", operation: "terminal-info.scroll-down", table: TerminalInfoTable),
    BaseRow(chords: "r", operation: "terminal-info.ask-again", table: TerminalInfoTable),
    BaseRow(chords: "y", operation: "terminal-info.glyphs-look-right", table: TerminalInfoTable),
    BaseRow(chords: "n", operation: "terminal-info.glyphs-look-wrong", table: TerminalInfoTable),
    BaseRow(chords: "c", operation: "terminal-info.copy-test", table: TerminalInfoTable),

    # --- A layout gesture in flight: `Escape` cancels it under every base -----
    BaseRow(chords: "Escape", operation: "layout.cancel-drag", table: LayoutGestureTable),

    # --- The Terminal Output pane (Terminal-Output-Pane.md §3): `v` toggles the
    # lines and screen views. `Left` / `Right` are the view's, under every base,
    # and in the screen view that operation steps a write.
    BaseRow(chords: "Left", operation: "view.scroll-left",
            table: PaneTablePrefix & "terminalOutput"),
    BaseRow(chords: "Right", operation: "view.scroll-right",
            table: PaneTablePrefix & "terminalOutput"),
    BaseRow(chords: "v", operation: "terminal-output.toggle-view",
            whenText: "paneKind == terminalOutput && !textInputFocus",
            table: PaneTablePrefix & "terminalOutput"),
  ]
