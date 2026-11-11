## pointer_rows.nim — WHAT A POINTER GESTURE ON AN ELEMENT RUNS, as data every
## base shares and a user's `keybindings.json` overrides.
##
## Owns: Input-Routing-And-Keymaps.md §5.1's pointer keymap for the panes:
## `scope × modifiers × gesture × element kind → operation`, written as ordinary
## rows whose "key" is a gesture (`Ctrl+Click`) and whose `when` names the pane
## and the element kind. They resolve through the one resolver, so a user's
## `{"key": "ctrl+click", "command": "...", "when": "paneKind == calltrace"}` is
## a row like any other, listed and conflict-checked the same way.
##
## Refuses to own: hit-testing (a front-end's own geometry, §5.3), what an
## operation does (each front-end's operation tables), and the editor's press
## table (`input/editor_pointer`).

import ./base_rows

const
  PointerRows*: seq[BaseRow] = @[
    # --- The call trace (K20-K22) ------------------------------------------
    BaseRow(chords: "Click", operation: "calltrace.go-to-call",
            whenText: "paneKind == calltrace && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "DoubleClick", operation: "calltrace.go-to-call",
            whenText: "paneKind == calltrace && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "calltrace.toggle-call",
            whenText: "paneKind == calltrace && elementKind == toggle",
            table: PointerTable),

    # --- The event log (K24-K26) -------------------------------------------
    BaseRow(chords: "Click", operation: "event-log.jump",
            whenText: "paneKind == eventLog && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "RightClick", operation: "event-log.show-content",
            whenText: "paneKind == eventLog && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "event-log.sort",
            whenText: "paneKind == eventLog && elementKind == header",
            table: PointerTable),

    # --- The variables (K27, K28) ------------------------------------------
    BaseRow(chords: "Click", operation: "variables.toggle-expand",
            whenText: "paneKind == state && elementKind == row",
            table: PointerTable),

    # --- The Files pane (K17, K18) -----------------------------------------
    BaseRow(chords: "Click", operation: "file-tree.activate",
            whenText: "paneKind == fileTree && elementKind == row",
            table: PointerTable),

    # --- The other panes' rows (K31 - K35, K53, K58, K61, K63, K64, K67) ----
    BaseRow(chords: "Click", operation: "point-list.select",
            whenText: "paneKind == pointList && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "terminal-output.jump-to-write",
            whenText: "paneKind == terminalOutput && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "vcs.open-file-diff",
            whenText: "paneKind == vcs && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "vcs.toggle-commit",
            whenText: "paneKind == vcs && elementKind == toggle",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "search.open-result",
            whenText: "paneKind == search && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "requests.select",
            whenText: "paneKind == requests && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "low-level.go-to-source-line",
            whenText: "paneKind == lowLevelCode && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "low-level.toggle-sync",
            whenText: "paneKind == lowLevelCode && elementKind == toggle",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "verification.go-to-source",
            whenText: "paneKind == verification && elementKind == row",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "constraints.go-to-source",
            whenText: "paneKind == constraints && elementKind == row",
            table: PointerTable),

    # --- An inline value in the editor (K36): Ctrl+click pins it ---------------
    BaseRow(chords: "Ctrl+Click", operation: "scratchpad.add-value",
            whenText: "paneKind == editor && elementKind == value",
            table: PointerTable),

    # --- The Visual Replay panes (K72, K73): a press on the Video Player's
    # frame picks the pixel under it, on a Pixel History row goes to its draw
    # call. (A transport or Shader Debug button runs the operation it
    # carries; the scrubbers are gestures.)
    BaseRow(chords: "Click", operation: "video-player.select-pixel",
            whenText: "paneKind == videoPlayer && elementKind == value",
            table: PointerTable),
    BaseRow(chords: "Click", operation: "pixel-history.activate",
            whenText: "paneKind == pixelHistory && elementKind == row",
            table: PointerTable),

    # --- Every element with a menu (K7, K19, K22, K28, K59, K62, K65, K68) ---
    BaseRow(chords: "RightClick", operation: "context-menu.open",
            whenText: "elementKind != none && paneKind != eventLog",
            table: PointerTable),

    # --- A pane's tab (K5) -------------------------------------------------
    BaseRow(chords: "Click", operation: "layout.activate-tab",
            whenText: "elementKind == tab", table: PointerTable),
  ]
