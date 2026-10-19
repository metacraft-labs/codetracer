## operation_catalogue.nim — THE NAMES a binding may run outside the
## editing vocabulary.
##
## Owns: every operation a keymap row may name that is not one of the
## editing vocabulary's (Editing-Operations §2.2, `editor/operations.nim`) —
## the debugger's, the layout's, the session tabs', the lists', the single-
## line inputs', the overlays' and the editor PANE's (scrolling, read-only,
## breakpoints) — each with its argument kind, its label and the table a
## user row naming it is installed in (Input-Routing §3.1's operation table,
## reduced to what a keymap needs).
##
## Refuses to own: what an operation DOES. That is the ViewModel's action
## procedure, reached through each front-end's dispatch
## (`tui/app/input/operation_dispatch`, `client_actions` for GPUI and the
## desktop). This module only makes the names a CLOSED set, so a row naming
## an operation that does not exist is a load error rather than a binding
## that silently does nothing.
##
## ## THE TWO NAMESPACES, AND HOW THEY ARE TOLD APART
##
## A vocabulary operation is spelled bare in a binding (`move-char-left`) —
## PLAT-30's names, unchanged, because DIFF-4 compares sequences of them —
## and written `editor.move-char-left` in data and in `keybindings.json`.
## Everything here is written and stored with its namespace
## (`debugger.step-over`). A vocabulary name never contains a dot, so
## `isCatalogued` is the one test.
##
## Pure; compiles on C, JS and wasm32.

import std/strutils

import ./scope_path

type
  OperationArg* = enum
    oaNone = "none"
    oaNumber = "number"
      ## A positive integer: `layout.focus-pane-by-index(3)`.
    oaPane = "pane"
      ## A pane name: `layout.focus-pane(file-tree)`.
    oaMenuFolder = "menu folder"
      ## A top-level folder of the program menu: `menu.open-folder(debug)`.

  CataloguedOperation* = object
    name*: string
    arg*: OperationArg
    table*: string
      ## Where a USER row naming this operation is installed (§5.1: the
      ## user layer is consulted scope by scope, like the base). A user who
      ## wants it elsewhere scopes it with a `when`.
    label*: string

const
  PaneArguments* = ["editor", "call-trace", "variables", "event-log",
                    "file-tree", "problems", "build-output", "terminal",
                    "points", "search"]
    ## The pane names `layout.focus-pane(…)` takes, in the specification's
    ## spelling (CUA-Keymap.md §3.7, CodeTracer-TUI.md §4.2).

  MenuFolderArguments* = ["file", "edit", "view", "build", "reset", "debug",
                          "help"]
    ## The program menu's top-level folders `menu.open-folder(…)` takes — the
    ## shared tree's labels (`product_menu.productMenuTree`), lower-cased.

func op(name: string; table: string; label: string;
        arg = oaNone): CataloguedOperation =
  CataloguedOperation(name: name, arg: arg, table: table, label: label)

const
  FindTable* = "find"
  PaletteTable* = "palette"
  CommandLineTable* = "command-line"
  ContextMenuTable* = "context-menu"

  Catalogue*: seq[CataloguedOperation] = @[
    # --- The debugger (CUA-Keymap.md §4, CodeTracer-TUI.md §4.2) ---------
    op("debugger.continue", GlobalTable, "Continue"),
    op("debugger.reverse-continue", GlobalTable, "Reverse Continue"),
    op("debugger.step-over", GlobalTable, "Step Over"),
    op("debugger.reverse-step-over", GlobalTable, "Reverse Step Over"),
    op("debugger.step-into", GlobalTable, "Step Into"),
    op("debugger.reverse-step-into", GlobalTable, "Reverse Step Into"),
    op("debugger.step-out", GlobalTable, "Step Out"),
    op("debugger.reverse-step-out", GlobalTable, "Reverse Step Out"),
    op("debugger.step-over-statement", GlobalTable, "Step Over Statement"),
    op("debugger.reverse-step-over-statement", GlobalTable,
       "Reverse Step Over Statement"),
    op("debugger.stop", GlobalTable, "Stop"),
    op("debugger.restart", GlobalTable, "Restart"),
    op("debugger.run-to-entry", GlobalTable, "Run to Entry"),
    op("debugger.reset-operation", GlobalTable, "Reset Operation"),
    op("debugger.smart-jump", GlobalTable, "Smart Jump"),
    op("debugger.run-to-cursor", GlobalTable, "Run to Cursor"),
    op("debugger.source-call-jump", GlobalTable, "Jump to Call"),
    op("debugger.previous-call", GlobalTable, "Jump to Previous Call"),
    op("debugger.next-call", GlobalTable, "Jump to Next Call"),
    op("debugger.previous-mutation", GlobalTable, "Jump to Previous Mutation"),
    op("debugger.next-mutation", GlobalTable, "Jump to Next Mutation"),
    op("debugger.jump-to-start", GlobalTable, "Jump to Start"),
    op("debugger.jump-to-end", GlobalTable, "Jump to End"),
    op("debugger.seek-to-tick", GlobalTable, "Seek to Tick"),
    op("debugger.reverse-origin", GlobalTable, "Reverse Origin"),

    # --- The editor PANE: acts on the pane, not on `EditorState` ----------
    op("editor.scroll-line-up", EditorTable, "Scroll Line Up"),
    op("editor.scroll-line-down", EditorTable, "Scroll Line Down"),
    op("editor.scroll-page-up", EditorTable, "Scroll Page Up"),
    op("editor.scroll-page-down", EditorTable, "Scroll Page Down"),
    op("editor.scroll-half-page-up", EditorTable, "Scroll Half Page Up"),
    op("editor.scroll-half-page-down", EditorTable, "Scroll Half Page Down"),
    op("editor.toggle-word-wrap", EditorTable, "Toggle Word Wrap"),
    op("editor.toggle-tab-moves-focus", EditorTable, "Toggle Tab Moves Focus"),
    op("editor.toggle-read-only", GlobalTable, "Toggle Read-Only"),
    op("editor.toggle-macro-expansion", EditorTable, "Toggle Macro Expansion"),
    op("editor.center-on-pointer", EditorTable, "Center on Execution Pointer"),
    op("editor.jump-to-value-origin", GlobalTable, "Jump to Value Origin"),
    op("editor.toggle-breakpoint", EditorTable, "Toggle Breakpoint"),
    op("editor.toggle-tracepoint", EditorTable, "Toggle Tracepoint"),

    # --- Find (CUA-Keymap.md §3.5) ----------------------------------------
    op("find.open", GlobalTable, "Find"),
    op("find.open-backward", GlobalTable, "Find Backward"),
    op("find.open-replace", GlobalTable, "Replace"),
    op("find.next", FindTable, "Find Next"),
    op("find.previous", FindTable, "Find Previous"),
    op("find.next-selection-match", EditorTable, "Find Next Selection"),
    op("find.previous-selection-match", EditorTable, "Find Previous Selection"),
    op("find.toggle-case", FindTable, "Toggle Match Case"),
    op("find.toggle-whole-word", FindTable, "Toggle Whole Word"),
    op("find.toggle-regex", FindTable, "Toggle Regular Expression"),
    op("find.toggle-in-selection", FindTable, "Toggle Find in Selection"),
    op("find.toggle-preserve-case", FindTable, "Toggle Preserve Case"),
    op("find.replace-one", FindTable, "Replace"),
    op("find.replace-all", FindTable, "Replace All"),
    op("find.select-all-matches", FindTable, "Select All Matches"),
    op("find.close", FindTable, "Close Find"),

    # --- Lists and trees (§3.6) -------------------------------------------
    op("list.focus-previous", ListTable, "Previous Row"),
    op("list.focus-next", ListTable, "Next Row"),
    op("list.focus-page-up", ListTable, "Page Up"),
    op("list.focus-page-down", ListTable, "Page Down"),
    op("list.focus-first", ListTable, "First Row"),
    op("list.focus-last", ListTable, "Last Row"),
    op("list.collapse", ListTable, "Collapse"),
    op("list.expand", ListTable, "Expand"),
    op("list.toggle-expand", ListTable, "Toggle Expand"),
    op("list.activate", ListTable, "Open"),
    op("list.clear-selection", ListTable, "Clear Selection"),
    op("list.filter", ListTable, "Filter"),
    op("list.copy", ListTable, "Copy"),

    # --- Single-line inputs (§3.6) ----------------------------------------
    op("input.move-left", InputTable, "Left"),
    op("input.move-right", InputTable, "Right"),
    op("input.move-word-left", InputTable, "Word Left"),
    op("input.move-word-right", InputTable, "Word Right"),
    op("input.move-start", InputTable, "Start"),
    op("input.move-end", InputTable, "End"),
    op("input.extend-left", InputTable, "Select Left"),
    op("input.extend-right", InputTable, "Select Right"),
    op("input.extend-word-left", InputTable, "Select Word Left"),
    op("input.extend-word-right", InputTable, "Select Word Right"),
    op("input.extend-start", InputTable, "Select to Start"),
    op("input.extend-end", InputTable, "Select to End"),
    op("input.delete-backward", InputTable, "Delete Backward"),
    op("input.delete-forward", InputTable, "Delete Forward"),
    op("input.delete-word-backward", InputTable, "Delete Word Backward"),
    op("input.delete-word-forward", InputTable, "Delete Word Forward"),
    op("input.select-all", InputTable, "Select All"),
    op("input.cut", InputTable, "Cut"),
    op("input.copy", InputTable, "Copy"),
    op("input.paste", InputTable, "Paste"),
    op("input.undo", InputTable, "Undo"),
    op("input.redo", InputTable, "Redo"),
    op("input.history-previous", InputTable, "Previous in History"),
    op("input.history-next", InputTable, "Next in History"),
    op("input.complete", InputTable, "Complete"),
    op("input.toggle-overwrite", InputTable, "Toggle Overwrite"),
    op("input.commit", InputTable, "Accept"),
    op("input.cancel", InputTable, "Cancel"),

    # --- The palette and the command line (§3.7, §3.8) ---------------------
    op("palette.quick-open-file", GlobalTable, "Go to File"),
    op("palette.open-commands", GlobalTable, "Show All Commands"),
    op("palette.go-to-symbol-in-file", GlobalTable, "Go to Symbol in File"),
    op("palette.go-to-symbol", GlobalTable, "Go to Symbol"),
    op("palette.go-to-line", GlobalTable, "Go to Line"),
    op("palette.focus-previous", PaletteTable, "Previous Item"),
    op("palette.focus-next", PaletteTable, "Next Item"),
    op("palette.focus-page-up", PaletteTable, "Page Up"),
    op("palette.focus-page-down", PaletteTable, "Page Down"),
    op("palette.accept", PaletteTable, "Accept"),
    op("palette.close", PaletteTable, "Close"),
    op("command-line.open", GlobalTable, "Open Command Line"),

    # --- The context menu (§3.8) -------------------------------------------
    op("context-menu.open", GlobalTable, "Show Context Menu"),
    op("context-menu.focus-previous", ContextMenuTable, "Previous Entry"),
    op("context-menu.focus-next", ContextMenuTable, "Next Entry"),
    op("context-menu.focus-first", ContextMenuTable, "First Entry"),
    op("context-menu.focus-last", ContextMenuTable, "Last Entry"),
    op("context-menu.enter-submenu", ContextMenuTable, "Open Submenu"),
    op("context-menu.leave-submenu", ContextMenuTable, "Close Submenu"),
    op("context-menu.accept", ContextMenuTable, "Choose"),
    op("context-menu.close", ContextMenuTable, "Close Menu"),

    # --- The workbench (§3.7) ----------------------------------------------
    op("search.find-in-files", GlobalTable, "Find in Files"),
    op("session-tabs.next-recent", GlobalTable, "Next Recently Used Tab"),
    op("session-tabs.previous-recent", GlobalTable,
       "Previous Recently Used Tab"),
    op("session-tabs.next", GlobalTable, "Next Tab"),
    op("session-tabs.previous", GlobalTable, "Previous Tab"),
    op("session-tabs.close", GlobalTable, "Close Tab"),
    op("session-tabs.close-all", GlobalTable, "Close All Tabs"),
    op("session-tabs.reopen-closed", GlobalTable, "Reopen Closed Tab"),
    op("session-tabs.new", GlobalTable, "New Tab"),
    op("session.open-file", GlobalTable, "Open File"),
    op("session.toggle-product-mode", GlobalTable, "Toggle Debug / Edit Mode"),
    op("session.re-record", GlobalTable, "Re-record"),
    op("navigation.back", GlobalTable, "Go Back"),
    op("navigation.forward", GlobalTable, "Go Forward"),
    op("layout.focus-next-pane", GlobalTable, "Focus Next Pane"),
    op("layout.focus-previous-pane", GlobalTable, "Focus Previous Pane"),
    op("layout.focus-left", GlobalTable, "Focus Pane Left"),
    op("layout.focus-right", GlobalTable, "Focus Pane Right"),
    op("layout.focus-up", GlobalTable, "Focus Pane Above"),
    op("layout.focus-down", GlobalTable, "Focus Pane Below"),
    op("layout.focus-pane-by-index", GlobalTable, "Focus Pane by Index",
       oaNumber),
    op("layout.focus-pane", GlobalTable, "Focus Pane", oaPane),
    op("layout.maximize-pane", GlobalTable, "Maximize / Restore Pane"),
    op("layout.toggle-side-panels", GlobalTable, "Toggle Side Panels"),
    op("layout.toggle-bottom-panel", GlobalTable, "Toggle Bottom Panel"),
    op("layout.toggle-shell-pane", GlobalTable, "Toggle Shell"),
    op("layout.cancel-drag", GlobalTable, "Cancel Drag"),
    op("layout.reveal-next-docked", GlobalTable, "Reveal Next Docked Pane"),
    op("menu.open", GlobalTable, "Open Menu"),
    op("menu.toggle", GlobalTable, "Toggle Menu"),
    op("menu.open-folder", GlobalTable, "Open Menu Folder", oaMenuFolder),
    op("window.zoom-in", GlobalTable, "Zoom In"),
    op("window.zoom-out", GlobalTable, "Zoom Out"),
    op("window.toggle-fullscreen", GlobalTable, "Toggle Full Screen"),
    op("window.new", GlobalTable, "New Window"),
    op("window.close", GlobalTable, "Close Window"),
    op("help.keyboard-shortcuts", GlobalTable, "Keyboard Shortcuts"),
    op("help.check-key-delivery", GlobalTable, "Check Key Delivery"),
    op("preferences.open", GlobalTable, "Open Settings"),
    op("app.quit", GlobalTable, "Quit"),
    op("app.suspend", GlobalTable, "Suspend"),
    op("router.cancel-pending", GlobalTable, "Cancel Pending Chord"),
    op("problems.next", GlobalTable, "Next Problem"),
    op("problems.previous", GlobalTable, "Previous Problem"),
    op("build.run", GlobalTable, "Build"),
    op("build.run-program", GlobalTable, "Build and Run"),
    op("project.export", GlobalTable, "Export Project"),
    op("view.low-level-code", GlobalTable, "Show Low Level Code"),
    op("tests.run", GlobalTable, "Run Tests"),
    op("flow.set-multiline", GlobalTable, "Flow: Multiline"),
    op("flow.set-parallel", GlobalTable, "Flow: Parallel"),
    op("flow.set-inline", GlobalTable, "Flow: Inline"),
    op("flow.loop-level-up", GlobalTable, "Flow: Loop Level Up"),
    op("flow.loop-level-down", GlobalTable, "Flow: Loop Level Down"),
    op("variables.toggle-hex-dec", PaneTablePrefix & "state",
       "Toggle Hex / Dec"),
    op("variables.view-memory-dump", PaneTablePrefix & "state",
       "View Memory Dump"),

    # --- The terminal's modal machine, under the Vim and Kakoune bases ----
    # (§5.5 / CodeTracer-TUI.md §4.1: its mode is state; these are the
    # operations its keys run.)
    op("inspect.open", GlobalTable, "Inspect"),
    op("modal.return-to-normal", GlobalTable, "Return to NORMAL"),
  ]

func operationIndex*(name: string): int =
  for i, o in Catalogue:
    if o.name == name: return i
  -1

func isCatalogued*(name: string): bool =
  ## A namespaced name (it contains a dot) that this catalogue lists. A
  ## vocabulary operation never contains a dot.
  '.' in name and operationIndex(name) >= 0

func splitOperation*(text: string): tuple[name, arg: string] =
  ## `layout.focus-pane(file-tree)` → (`layout.focus-pane`, `file-tree`).
  let open = text.find('(')
  if open < 0 or not text.endsWith(")"):
    return (text, "")
  (text[0 ..< open], text[open + 1 ..< text.len - 1])

func argumentProblem*(name, arg: string): string =
  ## Why `arg` is not an argument of catalogued operation `name`, or "".
  let i = operationIndex(name)
  if i < 0:
    return "'" & name & "' is not an operation"
  case Catalogue[i].arg
  of oaNone:
    if arg.len > 0: "'" & name & "' takes no argument" else: ""
  of oaNumber:
    var n = 0
    try: n = parseInt(arg)
    except ValueError: return "'" & name & "' takes a number, not '" & arg & "'"
    if n < 1: "'" & name & "' takes a positive number" else: ""
  of oaPane:
    if arg notin PaneArguments:
      "'" & name & "' takes a pane (" & PaneArguments.join(", ") & ")"
    else: ""
  of oaMenuFolder:
    if arg notin MenuFolderArguments:
      "'" & name & "' takes a menu folder (" & MenuFolderArguments.join(", ") &
        ")"
    else: ""

func tableOfOperation*(name: string): string =
  ## Where a user row naming `name` is installed: the catalogue's table for
  ## a namespaced operation, the editor table for a vocabulary one.
  let i = operationIndex(name)
  if i >= 0: Catalogue[i].table else: EditorTable

func operationLabelOf*(name: string): string =
  ## The catalogue's human label for `name` (the name itself when it has
  ## none) — what an inert operation's note and the shortcut reference say.
  let i = operationIndex(name)
  if i >= 0: Catalogue[i].label else: name
