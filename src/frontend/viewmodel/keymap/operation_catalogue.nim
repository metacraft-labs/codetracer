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
    oaColumnResize = "column resize"
      ## A signed number of cells, after an optional column name:
      ## `table.resize-column(output,+4)`, or `table.resize-column(-2)` for
      ## the focused column (Horizontal-Overflow.md §5.2).
    oaTarget = "pane-target"
      ## The element the operation acts on: the row under the pointer, the
      ## row a context menu was opened on, or the focused row from a key
      ## (Input-Routing §3.1). A binding cannot supply it literally.

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
                    "points", "search", "flow", "scratchpad", "shell",
                    "agent-activity", "verification", "step-list",
                    "local-call-trace", "constraints"]
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
  MenuTable* = "menu"
  ContentViewTable* = "content-view"
  TerminalInfoTable* = "terminal-info"
  LayoutGestureTable* = "layout-gesture"
    ## Pushed while a layout gesture (a drag, a held divider, a revealed dock) is
    ## live: its `Escape` beats every base's, as the terminal's always did.
  VideoPlayerTable* = PaneTablePrefix & "videoPlayer"
    ## The Video Player's own keys while it has the focus.
  VideoPickerTable* = "video-picker"
    ## Pushed while the Video Player's pixel picker is on, owned by the pane:
    ## its `Escape` cancels the picker and is nobody else's then.
  VideoMagnifierTable* = "video-magnifier"
    ## Pushed while the terminal's magnifier is open over the frame (the
    ## picker's keyboard stage): the arrows move the picked pixel, `Enter`
    ## picks it.
  PointerTable* = "pointer"
    ## The rows whose key is a pointer gesture (`pointer_rows`). Never on a
    ## scope path: only `keymap_router.routePointer` consults it.

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
    op("editor.toggle-inline-breakpoint", EditorTable, "Toggle Inline Breakpoint"),
    op("editor.toggle-tracepoint", EditorTable, "Toggle Tracepoint"),
    # Nim's compile-time code, traced into a recording that opens in a new
    # session tab (`viewmodels/nim_tracing_vm`).
    # (macro and static block are catalogued with the editor's other
    # target operations below.)
    op("editor.trace-constant-at-cursor", EditorTable,
       "Trace Constant Initializer"),
    op("editor.trace-eval", EditorTable, "Trace NimScript Evaluation"),

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
    # PLAT-70 Part C (Find-And-Incremental-Search.md §3.5, §4.5): the
    # session's two exits by name — `find.close` is CUA's spelling of the
    # first — Emacs's `C-w`, and Emacs's `M-s .` launcher.
    op("find.accept", FindTable, "Find: Accept"),
    op("find.cancel", FindTable, "Find: Cancel and Return"),
    op("find.yank-word", FindTable, "Find: Pull Word into Query"),
    op("find.open-symbol-at-caret", GlobalTable, "Find Symbol at Caret"),

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
    op("list.activate-redirected", ListTable, "Open in the Other Tab"),
    op("list.clear-selection", ListTable, "Clear Selection"),
    op("list.filter", ListTable, "Filter"),
    op("list.copy", ListTable, "Copy"),
    # --- The table panes' overflow (Horizontal-Overflow.md §5) -------------
    op("list.show-detail", ListTable, "Show Detail"),
    op("table.resize-column", ListTable, "Resize Column", oaColumnResize),

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
    op("search.next-result", GlobalTable, "Next Search Result"),
    op("search.previous-result", GlobalTable, "Previous Search Result"),
    op("search.toggle-case", GlobalTable, "Toggle Match Case"),
    op("search.toggle-whole-word", GlobalTable, "Toggle Match Whole Word"),
    op("search.toggle-regex", GlobalTable, "Toggle Use Regular Expression"),
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
    # --- The text panes' horizontal view (Horizontal-Overflow.md §4.4) -------
    op("view.scroll-left", GlobalTable, "View: Scroll Left"),
    op("view.scroll-right", GlobalTable, "View: Scroll Right"),
    op("view.scroll-left-half", GlobalTable, "View: Scroll Left Half a View"),
    op("view.scroll-right-half", GlobalTable, "View: Scroll Right Half a View"),
    op("view.scroll-to-line-start", GlobalTable, "View: Scroll to Line Start"),
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
    op("variables.show-value-origin", PaneTablePrefix & "state",
       "Show Value Origin"),

    # --- The overlays every base shares (`overlay_rows`) ---------------------
    op("menu.focus-previous", MenuTable, "Previous Menu Item"),
    op("menu.focus-next", MenuTable, "Next Menu Item"),
    op("menu.enter-folder", MenuTable, "Open Submenu"),
    op("menu.leave-folder", MenuTable, "Close Submenu"),
    op("menu.accept", MenuTable, "Choose Menu Item"),
    op("menu.close", MenuTable, "Close Menu"),
    op("content-view.close", ContentViewTable, "Close"),
    op("content-view.scroll-up", ContentViewTable, "Scroll Up"),
    op("content-view.scroll-down", ContentViewTable, "Scroll Down"),
    op("content-view.page-up", ContentViewTable, "Page Up"),
    op("content-view.page-down", ContentViewTable, "Page Down"),
    op("terminal-info.close", TerminalInfoTable, "Close"),
    op("terminal-info.scroll-up", TerminalInfoTable, "Scroll Up"),
    op("terminal-info.scroll-down", TerminalInfoTable, "Scroll Down"),
    op("terminal-info.ask-again", TerminalInfoTable, "Ask the Terminal Again"),
    op("terminal-info.glyphs-look-right", TerminalInfoTable,
       "The Glyphs Look Right"),
    op("terminal-info.glyphs-look-wrong", TerminalInfoTable,
       "The Glyphs Look Wrong"),
    op("terminal-info.copy-test", TerminalInfoTable, "Copy a Test String"),
    op("terminal-output.toggle-view", PaneTablePrefix & "terminalOutput",
       "Toggle Lines / Screen"),

    # --- Everything else a user can reach (Input-Routing §3.2) --------------
    # The desktop's `ClientAction`s that name no Monaco command, and the
    # context menus' `ContextAction`s (`client_actions`,
    # `pane_clicks.ContextActionOperations`). No base binds a default chord to
    # these: they are reached from a menu or an element, and a user's row can
    # bind any of them.
    op("session.switch-to-edit", GlobalTable, "Switch to Edit Mode"),
    op("session.switch-to-debug", GlobalTable, "Switch to Debug Mode"),
    op("session.new-file", GlobalTable, "New File"),
    op("session.open-folder", GlobalTable, "Open Folder"),
    op("session.open-recent", GlobalTable, "Open Recent"),
    op("session.save", GlobalTable, "Save"),
    op("session.save-as", GlobalTable, "Save As"),
    op("session.save-all", GlobalTable, "Save All"),
    op("session.debug", GlobalTable, "Debug"),
    op("session.trace", GlobalTable, "Trace"),
    op("session.load-trace", GlobalTable, "Load Trace"),
    op("session.open-trace", GlobalTable, "Open Trace"),
    op("session.open-trace-in-new-tab", GlobalTable, "Open Trace in New Tab"),
    op("session.record-new-trace", GlobalTable, "Record New Trace"),
    op("session.record-from-launch", GlobalTable, "Record from Launch"),
    op("session.new-trace-tab", GlobalTable, "New Trace Tab"),
    op("session.re-record-project", GlobalTable, "Re-record Project"),
    op("session.restart-db-backend", GlobalTable, "Restart DB Backend"),
    op("session.restart-backend-manager", GlobalTable,
       "Restart Backend Manager"),
    op("session.collab-invite", GlobalTable, "Invite Collaborators"),
    op("session.apply-edit-and-reload", GlobalTable, "Apply Edit and Reload"),
    op("session.launch-under-hcr", GlobalTable, "Launch under Hot Code Reload"),
    op("layout.toggle-live-edit-panel", GlobalTable, "Toggle Live Edit Panel"),
    op("tests.open-in-new-tab", PaneTablePrefix & "testResults",
       "Open in a New Tab"),
    op("tests.open-in-current-tab", PaneTablePrefix & "testResults",
       "Open in the Current Tab"),
    op("tests.run-test", PaneTablePrefix & "testResults", "Run Test"),
    op("tests.run-test-in-current-tab", PaneTablePrefix & "testResults",
       "Run Test in the Current Tab"),
    op("build.run-program-in-current-tab", GlobalTable,
       "Build and Run in the Current Tab"),
    op("palette.fixed-search", GlobalTable, "Search in Project"),
    op("search.replace-in-files", GlobalTable, "Replace in Files"),
    op("build.compile", GlobalTable, "Compile"),
    op("build.run-static", GlobalTable, "Run Static"),
    op("layout.save", GlobalTable, "Save Layout"),
    op("layout.load", GlobalTable, "Load Layout"),
    op("layout.reset", GlobalTable, "Reset Layout"),
    op("layout.switch-debug-wide", GlobalTable, "Wide Debug Layout"),
    op("layout.switch-edit-normal", GlobalTable, "Normal Edit Layout"),
    op("layout.new-horizontal-group", GlobalTable, "New Horizontal Tab Group"),
    op("layout.new-vertical-group", GlobalTable, "New Vertical Tab Group"),
    op("layout.new-state", GlobalTable, "New State Pane"),
    op("layout.new-event-log", GlobalTable, "New Event Log"),
    op("layout.new-full-calltrace", GlobalTable, "New Call Trace"),
    op("layout.new-terminal", GlobalTable, "New Terminal"),
    op("layout.pin-pane-left", GlobalTable, "Pin Pane to Left", oaTarget),
    op("layout.pin-pane-bottom", GlobalTable, "Pin Pane to Bottom", oaTarget),
    op("layout.pin-pane-right", GlobalTable, "Pin Pane to Right", oaTarget),
    op("layout.pin-pane-top", GlobalTable, "Pin Pane to Top", oaTarget),
    op("layout.unpin-pane", GlobalTable, "Unpin Pane", oaTarget),
    op("layout.close-pane", GlobalTable, "Close Pane", oaTarget),
    op("view.notifications", GlobalTable, "Show Notifications"),
    op("view.start-window", GlobalTable, "Show Start Window"),
    op("view.theme-0", GlobalTable, "Mac Classic Theme"),
    op("view.theme-1", GlobalTable, "Default White Theme"),
    op("view.theme-2", GlobalTable, "Default Black Theme"),
    op("view.theme-3", GlobalTable, "Default Dark Theme"),
    op("view.editor-theme-0", GlobalTable, "Editor Theme"),
    op("view.preview-multiline", GlobalTable, "Preview: Multiline"),
    op("view.preview-single-line", GlobalTable, "Preview: Single Line"),
    op("view.preview-none", GlobalTable, "Preview: None"),
    op("view.source-code", GlobalTable, "Show Source Code"),
    op("view.disassembly", GlobalTable, "View Disassembly"),
    op("view.generated-c-source", GlobalTable, "View Generated C Source"),
    op("view.previous-point-in-time", GlobalTable, "Previous Point in Time"),
    op("view.next-point-in-time", GlobalTable, "Next Point in Time"),
    op("preferences.options", GlobalTable, "Options"),
    # The desktop's editor (the `sharedEditor` developer setting) and the
    # shared editor's base keymap, from the palette.
    op("preferences.toggle-shared-editor", GlobalTable, "Developer: Toggle Shared Editor"),
    op("preferences.keymap-cua", GlobalTable, "Keymap: CUA"),
    op("preferences.keymap-emacs", GlobalTable, "Keymap: Emacs"),
    op("preferences.keymap-vim", GlobalTable, "Keymap: Vim"),
    op("preferences.keymap-kakoune", GlobalTable, "Keymap: Kakoune"),
    op("help.user-manual", GlobalTable, "User Manual"),
    op("help.report-problem", GlobalTable, "Report a Problem"),
    op("help.suggest-feature", GlobalTable, "Suggest a Feature"),
    op("help.about", GlobalTable, "About"),
    op("flow.zoom-loop-in", GlobalTable, "Flow: Zoom Loop In"),
    op("flow.zoom-loop-out", GlobalTable, "Flow: Zoom Loop Out"),
    op("flow.loop-level-at-position", GlobalTable,
       "Flow: Loop Level at Position"),
    op("debugger.jump-backward-to-line", GlobalTable, "Jump Backward to Line",
       oaTarget),
    op("debugger.jump-forward-to-call", GlobalTable, "Jump Forward to Call",
       oaTarget),
    op("debugger.jump-backward-to-call", GlobalTable, "Jump Backward to Call",
       oaTarget),
    op("editor.add-breakpoint", EditorTable, "Add Breakpoint", oaTarget),
    op("editor.delete-breakpoint", EditorTable, "Delete Breakpoint", oaTarget),
    op("editor.delete-breakpoints-in-file", EditorTable,
       "Delete Breakpoints in File", oaTarget),
    op("editor.delete-all-breakpoints", EditorTable, "Delete All Breakpoints"),
    op("editor.enable-breakpoint", EditorTable, "Enable Breakpoint", oaTarget),
    op("editor.enable-all-breakpoints", EditorTable, "Enable All Breakpoints"),
    op("editor.disable-breakpoint", EditorTable, "Disable Breakpoint",
       oaTarget),
    op("editor.disable-all-breakpoints", EditorTable,
       "Disable All Breakpoints"),
    op("editor.delete-tracepoint", EditorTable, "Delete Tracepoint"),
    op("editor.enable-tracepoint", EditorTable, "Enable Tracepoint"),
    op("editor.enable-all-tracepoints", EditorTable, "Enable All Tracepoints"),
    op("editor.disable-tracepoint", EditorTable, "Disable Tracepoint"),
    op("editor.disable-all-tracepoints", EditorTable,
       "Disable All Tracepoints"),
    op("editor.collect-tracepoint-results", EditorTable,
       "Collect Enabled Tracepoint Results"),
    op("editor.copy-at", EditorTable, "Copy", oaTarget),
    op("editor.trace-macro-at-cursor", EditorTable,
       "Trace Macro Execution"),
    op("editor.trace-static-block-at-cursor", EditorTable,
       "Trace Static Block Execution"),

    # --- The panes' own (a row's hotspots and context menus) ----------------
    op("calltrace.go-to-call", PaneTablePrefix & "calltrace",
       "Go to this call", oaTarget),
    op("calltrace.toggle-call", PaneTablePrefix & "calltrace",
       "Expand or collapse this call", oaTarget),
    op("event-log.jump", PaneTablePrefix & "eventLog", "Go to this event",
       oaTarget),
    op("event-log.show-content", PaneTablePrefix & "eventLog",
       "Show the event's full content", oaTarget),
    op("event-log.sort", PaneTablePrefix & "eventLog",
       "Order the log by this column", oaTarget),
    op("layout.activate-tab", GlobalTable, "Activate Tab", oaTarget),
    op("session-tabs.activate", GlobalTable, "Activate Session Tab", oaTarget),
    op("editor.add-column-breakpoint", EditorTable, "Add Column Breakpoint",
       oaTarget),
    op("variables.hide-other-process-watches", PaneTablePrefix & "state",
       "Hide Watches from Other Processes"),
    op("video-player.seek-frame", GlobalTable, "Video: Seek to Frame", oaTarget),
    op("video-player.seek-draw", GlobalTable, "Video: Show Draw Call", oaTarget),
    op("video-player.select-pixel", GlobalTable, "Video: Select Pixel", oaTarget),
    op("pixel-history.activate", GlobalTable, "Pixel History: Go to Draw Call",
       oaTarget),
    op("shader-debug.step", GlobalTable, "Shader Debug: Step", oaTarget),
    op("point-list.select", PaneTablePrefix & "pointList", "Select this point",
       oaTarget),
    op("terminal-output.jump-to-write", PaneTablePrefix & "terminalOutput",
       "Go to this output", oaTarget),
    op("scratchpad.remove", PaneTablePrefix & "scratchpad", "Remove this value",
       oaTarget),
    op("vcs.open-file-diff", PaneTablePrefix & "vcs", "Open this file's diff",
       oaTarget),
    op("vcs.toggle-commit", PaneTablePrefix & "vcs",
       "Expand or collapse this commit", oaTarget),
    op("search.open-result", PaneTablePrefix & "search", "Open this result",
       oaTarget),
    op("status.copy-path", GlobalTable, "Copy the Current File's Path"),
    op("low-level.toggle-sync", PaneTablePrefix & "lowLevelCode",
       "Keep the Listing in Step with the Source"),
    op("verification.run", PaneTablePrefix & "verification",
       "Run the Project's Verifier"),
    op("verification.stop", PaneTablePrefix & "verification",
       "Stop the Verifier"),
    op("requests.select", PaneTablePrefix & "requests", "Select this request",
       oaTarget),
    op("variables.toggle-expand", PaneTablePrefix & "state",
       "Expand or collapse this value", oaTarget),
    op("variables.value-history", PaneTablePrefix & "state",
       "Show this value's history", oaTarget),
    op("variables.value-origin", PaneTablePrefix & "state",
       "Show this value's origin", oaTarget),
    op("variables.load-more", PaneTablePrefix & "state", "Load more members",
       oaTarget),
    op("variables.jump-to-value", PaneTablePrefix & "state", "Jump to value",
       oaTarget),
    op("history.seek-to-tick", PaneTablePrefix & "state", "Go to this moment",
       oaTarget),
    op("scratchpad.add-value", GlobalTable, "Add value to scratchpad",
       oaTarget),
    op("scratchpad.add-all-values", GlobalTable,
       "Add all values to scratchpad", oaTarget),
    op("file-tree.open", PaneTablePrefix & "fileTree", "Open this file",
       oaTarget),
    op("file-tree.toggle-folder", PaneTablePrefix & "fileTree",
       "Expand or collapse this folder", oaTarget),
    op("file-tree.activate", PaneTablePrefix & "fileTree",
       "Open this file, or expand or collapse this folder", oaTarget),
    op("file-tree.create", PaneTablePrefix & "fileTree", "Create", oaTarget),
    op("file-tree.rename", PaneTablePrefix & "fileTree", "Rename", oaTarget),
    op("file-tree.delete", PaneTablePrefix & "fileTree", "Delete", oaTarget),
    op("file-tree.edit", PaneTablePrefix & "fileTree", "Edit", oaTarget),
    op("agent-activity.attach-upload", PaneTablePrefix & "agentActivity",
       "Attach: Upload"),
    op("agent-activity.attach-files-folders", PaneTablePrefix & "agentActivity",
       "Attach: Files and Folders"),
    op("agent-activity.attach-editor-selection",
       PaneTablePrefix & "agentActivity", "Attach: Editor Selection"),
    op("agent-activity.attach-recording", PaneTablePrefix & "agentActivity",
       "Attach: Recording"),
    op("agent-activity.start-worktree-session", GlobalTable,
       "Start Agentic Worktree Session"),
    op("requests.go-to-handler", PaneTablePrefix & "requests", "Go to Handler",
       oaTarget),
    op("requests.copy-url", PaneTablePrefix & "requests", "Copy URL", oaTarget),
    op("requests.filter-method", PaneTablePrefix & "requests",
       "Filter by Method", oaTarget),
    op("requests.filter-status", PaneTablePrefix & "requests",
       "Filter by Status", oaTarget),
    op("requests.clear-filters", PaneTablePrefix & "requests", "Clear Filters"),
    op("low-level.go-to-source-line", PaneTablePrefix & "lowLevelCode",
       "Go to Source Line", oaTarget),
    op("low-level.show-source-line", PaneTablePrefix & "lowLevelCode",
       "Show Source Line", oaTarget),
    op("low-level.copy-instruction", PaneTablePrefix & "lowLevelCode",
       "Copy Instruction", oaTarget),
    op("low-level.copy-source-location", PaneTablePrefix & "lowLevelCode",
       "Copy Source Location", oaTarget),
    op("verification.go-to-source", PaneTablePrefix & "verification",
       "Go to Source", oaTarget),
    op("verification.open-counterexample", PaneTablePrefix & "verification",
       "Step Through the Counterexample", oaTarget),
    op("verification.copy-message", PaneTablePrefix & "verification",
       "Copy Message", oaTarget),
    op("verification.copy-location", PaneTablePrefix & "verification",
       "Copy Location", oaTarget),
    op("verification.close-counterexample", PaneTablePrefix & "verification",
       "Close the Counterexample"),
    op("constraints.go-to-source", PaneTablePrefix & "constraints",
       "Go to Source", oaTarget),
    op("constraints.copy-name", PaneTablePrefix & "constraints", "Copy Name",
       oaTarget),
    op("constraints.copy-source-location", PaneTablePrefix & "constraints",
       "Copy Source Location", oaTarget),
    op("frame-viewer.next-frame", GlobalTable, "Next frame", oaTarget),
    op("frame-viewer.previous-frame", GlobalTable, "Previous frame", oaTarget),
    op("frame-viewer.go-to-frame", GlobalTable, "Go to this frame", oaTarget),
    # The Video Player's own keys (Visual-Replay.md § Keyboard Shortcuts): its
    # pane's table while it has the focus, the picker's and the magnifier's
    # layers while they are open (`overlay_rows`).
    op("video-player.toggle-play", VideoPlayerTable, "Video: Play / Pause"),
    op("video-player.rewind", VideoPlayerTable, "Video: Rewind"),
    op("video-player.fast-forward", VideoPlayerTable, "Video: Fast Forward"),
    op("video-player.step-frame-back", VideoPlayerTable, "Video: Previous Frame"),
    op("video-player.step-frame-forward", VideoPlayerTable, "Video: Next Frame"),
    op("video-player.step-draw-back", VideoPlayerTable, "Video: Previous Draw"),
    op("video-player.step-draw-forward", VideoPlayerTable, "Video: Next Draw"),
    op("video-player.jump-start", VideoPlayerTable, "Video: Jump to Start"),
    op("video-player.jump-end", VideoPlayerTable, "Video: Jump to End"),
    op("video-player.toggle-picker", VideoPlayerTable, "Video: Toggle Picker"),
    op("video-player.cancel-picker", VideoPickerTable, "Video: Cancel Picker"),
    op("video-player.move-magnifier-left", VideoMagnifierTable,
       "Video: Move the Picked Pixel Left", oaNumber),
    op("video-player.move-magnifier-right", VideoMagnifierTable,
       "Video: Move the Picked Pixel Right", oaNumber),
    op("video-player.move-magnifier-up", VideoMagnifierTable,
       "Video: Move the Picked Pixel Up", oaNumber),
    op("video-player.move-magnifier-down", VideoMagnifierTable,
       "Video: Move the Picked Pixel Down", oaNumber),
    op("video-player.commit-pick", VideoMagnifierTable,
       "Video: Pick This Pixel"),

    # --- The terminal's modal machine, under the Vim and Kakoune bases ----
    # (§5.5 / CodeTracer-TUI.md §4.1: its mode is state; these are the
    # operations its keys run.)
    op("inspect.open", GlobalTable, "Inspect"),
    op("modal.return-to-normal", GlobalTable, "Return to NORMAL"),
  ]

func parseColumnResize*(arg: string):
    tuple[ok: bool; column: string; delta: int] =
  ## `table.resize-column`'s argument: `[column,]delta`, `delta` a non-zero
  ## signed number of cells; `column` "" for the focused one.
  let comma = arg.rfind(',')
  let column = if comma < 0: "" else: arg[0 ..< comma].strip
  let number = (if comma < 0: arg else: arg[comma + 1 .. ^1]).strip
  var delta = 0
  try:
    delta = parseInt(if number.startsWith("+"): number[1 .. ^1] else: number)
  except ValueError:
    return (false, "", 0)
  if delta == 0:
    return (false, "", 0)
  (true, column, delta)

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
  of oaColumnResize:
    let parsed = parseColumnResize(arg)
    if parsed.ok: ""
    else: "'" & name & "' takes [column,]cells, a signed number of cells"
  of oaTarget:
    if arg.len > 0: "'" & name & "' acts on an element, not on '" & arg & "'"
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
