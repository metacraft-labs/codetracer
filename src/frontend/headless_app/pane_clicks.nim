## headless_app/pane_clicks.nim — WHAT A CLICK DOES, as data every front-end
## reads.
##
## The desktop states its click behaviour in DOM handlers, one view at a time
## (`viewmodel/views/isonim_*_view.nim`, `ui/editor.nim`, `ui/event_log.nim`,
## `ui/layout.nim`, `ui/flow.nim`, `ui/auto_hide.nim`). The terminal and GPUI
## hit-test cells and pixels instead, and until this module there was no
## shared answer to "a right-click on a call-trace row offers WHICH entries?"
## — each native front-end would have re-spelled the desktop's menus, and two
## spellings drift.
##
## So this module holds:
##
##   * `ClickInventory` — every click behaviour the desktop has, with the
##     shared operation it runs and the state of each native front-end. The
##     PLAT-50 milestone's table IS this array (`test_plat50_click_models`
##     reads the milestone's table and compares the two row by row).
##   * The CONTEXT MENUS the desktop shows, as `ContextMenuModel` values built
##     from the facts every front-end reads (a call's expanded state, a tab's
##     maximised state, the editor's line and the word under the pointer, a
##     docked pane's edge): labels and hints spelled as the desktop spells
##     them, an action each, enabled or disabled with a reason.
##   * `ContextMenuState` — an open menu: where it was opened, which entry the
##     keyboard is on, and what choosing one means. The terminal draws it as a
##     framed dropdown, GPUI as a popover; both route the chosen
##     `ContextAction` to the same operations.
##   * `callTokenAt` — the desktop editor's "word under the pointer"
##     (`ui/editor.getTokenFromPosition`), which the call jumps send.
##
## Nothing here talks to an engine: the actions are VALUES, and each host maps
## them onto its session (`HeadlessDebugSession`) and layout (`LayoutModel`).

import std/[strutils, unicode]

import ./layout_model

type
  ClickGesture* = enum
    cgClick = "click"
    cgDoubleClick = "double-click"
    cgRightClick = "right-click"
    cgCtrlClick = "ctrl-click"
    cgMiddleClick = "middle-click"
    cgAltClick = "alt-click"
    cgCtrlAltClick = "ctrl-alt-click"
    cgDrag = "drag"
    cgHover = "hover"

  NativeState* = enum
    ## Where a native front-end stands on one behaviour.
    nsDone = "done"
      ## Implemented by PLAT-50, with a real-stack test.
    nsExisting = "existing"
      ## Implemented by an earlier milestone (named in `ClickBehaviour.note`).
    nsNotApplicable = "n/a"
      ## The TARGET is not drawn by this front-end (the reason in `note`): a
      ## click needs something to land on. Never used for a target that is
      ## drawn.

  ClickBehaviour* = object
    id*: string
      ## `K1` … — the milestone table's row.
    target*: string
      ## The pane and the part of it clicked.
    gestures*: set[ClickGesture]
    desktop*: string
      ## What the desktop does, and where it says so.
    sharedOp*: string
      ## The operation every front-end calls.
    terminal*, gpui*: NativeState
    note*: string

  ContextAction* = enum
    ## What choosing a context-menu entry does. One value per DISTINCT
    ## operation the desktop's menus run, so a host's `case` over it is the
    ## exhaustive list of what it must route.
    caNone = "none"
    caPinLeft = "pin-left"
    caPinBottom = "pin-bottom"
    caPinRight = "pin-right"
    caUnpin = "unpin"
    caClosePane = "close-pane"
    caMaximise = "maximise"
    caCopy = "copy"
    caFind = "find"
    caJumpToLine = "jump-to-line"
    caRunToCursor = "run-to-cursor"
    caJumpBackwardToLine = "jump-backward-to-line"
    caJumpToCall = "jump-to-call"
    caJumpForwardToCall = "jump-forward-to-call"
    caJumpBackwardToCall = "jump-backward-to-call"
    caAddBreakpoint = "add-breakpoint"
    caDeleteBreakpoint = "delete-breakpoint"
    caEnableBreakpoint = "enable-breakpoint"
    caDisableBreakpoint = "disable-breakpoint"
    caDeleteBreakpointsInFile = "delete-breakpoints-in-file"
    caDeleteAllBreakpoints = "delete-all-breakpoints"
    caAddTracepoint = "add-tracepoint"
    caToggleCallChildren = "toggle-call-children"
    caToggleValueHistory = "toggle-value-history"
    caShowValueOrigin = "show-value-origin"
    caAddValueToScratchpad = "add-value-to-scratchpad"
    caAddAllValuesToScratchpad = "add-all-values-to-scratchpad"
    caJumpToValue = "jump-to-value"

  ContextMenuKind* = enum
    cmkTab = "tab"
    cmkEditorText = "editor-text"
    cmkCallTraceRow = "call-trace-row"
    cmkCallArgument = "call-argument"
    cmkVariablesRow = "variables-row"
    cmkFlowValue = "flow-value"
    cmkValueHistoryEntry = "value-history-entry"
      ## PLAT-51: a row of a variable's value history (the desktop's history
      ## popover row, `ui/value.createHistoryContextMenu`).
    cmkDockLabel = "dock-label"

  ContextMenuEntry* = object
    label*: string
    hint*: string
      ## The desktop's hint column (a chord, a gesture).
    action*: ContextAction
    enabled*: bool
    reason*: string
      ## Why a disabled entry is disabled.

  NamedValue* = tuple[name, value: string]

  ContextTarget* = object
    ## What the menu was opened ON — the facts its actions need.
    pane*: PaneKind
    path*: string
      ## A file (editor) or a variable path (Variables).
    line*: int
      ## An editor line, 1-based.
    column*: int
      ## The editor column pressed, 1-based (0: none).
    index*: int64
      ## A call-trace row's call index.
    token*: string
      ## The word under the pointer in the editor — what the call jumps send
      ## (`callTokenAt`); empty when the press was not on a word.
    tokenError*: string
      ## Why there is no usable word (the desktop's "Multiple calls of 'x' on
      ## line N." for an ambiguous Rust path); the call jumps report it.
    text*: string
      ## The editor line's text (Copy) or a value's text (scratchpad).
    expression*: string
      ## A value's name (scratchpad, Jump to value).
    values*: seq[NamedValue]
      ## Every value shown on the editor line ("Add all values to scratchpad").
    edge*: LayoutEdge
      ## A docked pane's edge (`cmkDockLabel`).

  ContextMenuModel* = object
    kind*: ContextMenuKind
    target*: ContextTarget
    entries*: seq[ContextMenuEntry]

  ContextMenuState* = object
    ## An open (or closed) context menu.
    open*: bool
    menu*: ContextMenuModel
    selected*: int
      ## The entry the keyboard is on (-1 none); a pointer hovering an entry
      ## moves it there.
    anchorRow*, anchorCol*: int
      ## Where it was opened: a cell (terminal) or, scaled, a pixel (GPUI).

const
  DesktopTabMenuLabels* = ["Pin to Left", "Pin to Bottom", "Pin to Right",
                           "Close"]
    ## `ui/layout.addPanelTransferContextMenu`'s first four entries; the fifth
    ## names the stack's state (`MaximiseLabel` / `MinimiseLabel`).
  MaximiseLabel* = "Maximise container"
  MinimiseLabel* = "Minimise container"
  ExpandCallChildrenLabel* = "Expand Call Children"
  CollapseCallChildrenLabel* = "Collapse Call Children"
  AddToScratchpadLabel* = "Add to scratchpad"
    ## PLAT-51: the desktop's history-row entry (`ui/value.nim`'s spelling).
  AddValueToScratchpadLabel* = "Add value to scratchpad"
  AddAllValuesToScratchpadLabel* = "Add all values to scratchpad"
  JumpToValueLabel* = "Jump to value"
  UnpinLabel* = "Unpin"
  NoWordSelected* = "No word selected."
    ## The desktop's answer to a call jump with no word under the pointer
    ## (`ui/editor.createContextMenuItems`'s fallback handler).

# ---------------------------------------------------------------------------
# The word under the pointer
# ---------------------------------------------------------------------------

func isWordRune(r: Rune): bool =
  ## Monaco's default word definition, for source text: a run of anything
  ## that is not white space or one of its separators
  ## (`` `~!@#$%^&*()-=+[{]}\|;:'",.<>/? ``,
  ## https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/core/wordHelper.ts
  ## `USUAL_WORD_SEPARATORS`).
  if r.isWhiteSpace:
    return false
  if r.int32 < 128:
    return char(r.int32) notin "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?"
  true

func callTokenAt*(lineText: string; column: int;
                  rust = false): tuple[token, error: string] =
  ## The word at `column` (1-based, a code point) of `lineText`, as the
  ## desktop's `getTokenFromPosition` reads it from Monaco: the word the
  ## column is in, or the one it ends (Monaco's `getWordAtPosition` takes the
  ## word ending AT the position too). For Rust the word is widened over
  ## `::`-joined path segments, and a path that occurs more than once on the
  ## line is AMBIGUOUS — the desktop refuses it with "Multiple calls of 'x'
  ## on line N." (`error`, the line left to the caller to name).
  let runes = lineText.toRunes
  if column < 1 or runes.len == 0:
    return ("", "")
  var at = min(column - 1, runes.len)
  # The press is on the word, or just past its end.
  if at >= runes.len or not runes[at].isWordRune:
    if at > 0 and runes[at - 1].isWordRune:
      dec at
    else:
      return ("", "")
  var first = at
  var last = at
  while first > 0 and runes[first - 1].isWordRune:
    dec first
  while last + 1 < runes.len and runes[last + 1].isWordRune:
    inc last
  if rust:
    proc rustPart(r: Rune): bool =
      r == Rune(':') or (r.int32 < 128 and
                         (char(r.int32).isAlphaNumeric or char(r.int32) == '_'))
    while first > 0 and rustPart(runes[first - 1]):
      dec first
    while last + 1 < runes.len and rustPart(runes[last + 1]):
      inc last
  result.token = $runes[first .. last]
  if rust and lineText.count(result.token) != 1:
    result.error = "Multiple calls of '" & result.token & "'"
    result.token = ""

# ---------------------------------------------------------------------------
# The context menus
# ---------------------------------------------------------------------------

func entry(label: string; action: ContextAction; hint = "";
           enabled = true; reason = ""): ContextMenuEntry =
  ContextMenuEntry(label: label, hint: hint, action: action,
                   enabled: enabled, reason: reason)

func tabContextMenu*(pane: PaneKind; maximised: bool): ContextMenuModel =
  ## A pane tab's right-click menu — `ui/layout.addPanelTransferContextMenu`:
  ## pin to an edge, close, and maximise / minimise its container.
  ContextMenuModel(
    kind: cmkTab, target: ContextTarget(pane: pane),
    entries: @[
      entry(DesktopTabMenuLabels[0], caPinLeft),
      entry(DesktopTabMenuLabels[1], caPinBottom),
      entry(DesktopTabMenuLabels[2], caPinRight),
      entry(DesktopTabMenuLabels[3], caClosePane),
      entry((if maximised: MinimiseLabel else: MaximiseLabel), caMaximise)])

func dockLabelContextMenu*(pane: PaneKind; edge: LayoutEdge): ContextMenuModel =
  ## A docked pane's label's right-click menu — the desktop's auto-hide strip
  ## (`ui/auto_hide.nim`'s `onContextMenu`): pin it to each OTHER edge, unpin
  ## it back into the layout, close it.
  result = ContextMenuModel(kind: cmkDockLabel,
                            target: ContextTarget(pane: pane, edge: edge))
  if edge != leLeft:
    result.entries.add entry(DesktopTabMenuLabels[0], caPinLeft)
  if edge != leBottom:
    result.entries.add entry(DesktopTabMenuLabels[1], caPinBottom)
  if edge != leRight:
    result.entries.add entry(DesktopTabMenuLabels[2], caPinRight)
  result.entries.add entry(UnpinLabel, caUnpin)
  result.entries.add entry(DesktopTabMenuLabels[3], caClosePane)

type
  LineBreakpoint* = enum
    ## The breakpoint on the line a menu is opened on.
    lbNone, lbEnabled, lbDisabled

func editorTextContextMenu*(path: string; line: int; lineText = "";
                            column = 0; token = ""; tokenError = "";
                            breakpoint = lbNone; fileHasBreakpoints = false;
                            anyBreakpoints = false): ContextMenuModel =
  ## The editor's right-click menu in a replay — `ui/editor.
  ## createContextMenuItems`' Debug branch, measured on the real desktop
  ## (`plat50-desktop-capture.spec.ts`, `menus.editorText` and
  ## `menus.editorTextOnBreakpoint`): Copy (Monaco copies the caret's whole
  ## line when nothing is selected, and the right-click put the caret on
  ## `line`) and Find; "Jump to line" (`SmartJump`), "Run to Cursor"
  ## (`ForwardJump`) and "Jump backward to line" (`BackwardJump`); the three
  ## call jumps on the word under the pointer (`token`); the line's breakpoint
  ## entries ("Add breakpoint", or "Disable / Enable breakpoint" and "Delete
  ## breakpoint"), the file's and every breakpoint's deletion while there are
  ## some; "Add tracepoint". Labels and hints are the desktop's; every entry
  ## is enabled there, and here.
  result = ContextMenuModel(
    kind: cmkEditorText,
    target: ContextTarget(pane: paneEditor, path: path, line: line,
                          column: column, token: token,
                          tokenError: tokenError, text: lineText))
  result.entries = @[
    entry("Copy", caCopy),
    entry("Find", caFind),
    entry("Jump to line", caJumpToLine,
          hint = "<Middle click on line>, CTRL+<click on line>"),
    entry("Run to Cursor", caRunToCursor, hint = "CTRL+F10"),
    entry("Jump backward to line", caJumpBackwardToLine),
    entry("Jump to call", caJumpToCall,
          hint = "CTRL+ALT+<click function name>"),
    entry("Jump forward to call", caJumpForwardToCall),
    entry("Jump backward to call", caJumpBackwardToCall)]
  case breakpoint
  of lbNone:
    result.entries.add entry("Add breakpoint", caAddBreakpoint,
                             hint = "<click line number gutter>")
  of lbEnabled:
    result.entries.add entry("Disable breakpoint", caDisableBreakpoint)
    result.entries.add entry("Delete breakpoint", caDeleteBreakpoint,
                             hint = "<click on the red dot>")
  of lbDisabled:
    result.entries.add entry("Enable breakpoint", caEnableBreakpoint)
    result.entries.add entry("Delete breakpoint", caDeleteBreakpoint,
                             hint = "<click on the red dot>")
  if fileHasBreakpoints:
    result.entries.add entry("Delete breakpoints in file",
                             caDeleteBreakpointsInFile)
  if anyBreakpoints:
    result.entries.add entry("Delete ALL breakpoints", caDeleteAllBreakpoints)
  result.entries.add entry("Add tracepoint", caAddTracepoint,
                           hint = "Enter<on line>")

func callTraceContextMenu*(index: int64; hasChildren,
                           expanded: bool): ContextMenuModel =
  ## A call-trace row's right-click menu — `isonim_calltrace_view.
  ## calltraceRowContextItems`: expand or collapse the call's children.
  ## (The desktop's "Expand Full Callstack" was removed: it unfolds the
  ## engine's auto-collapsed calls, `ct/expand-calls` with
  ## `CallstackInternal`, and no front-end asks the engine to auto-collapse,
  ## so it changed nothing — measured on the real desktop.)
  ContextMenuModel(
    kind: cmkCallTraceRow,
    target: ContextTarget(pane: paneCalltrace, index: index),
    entries: @[
      entry((if hasChildren and expanded: CollapseCallChildrenLabel
             else: ExpandCallChildrenLabel), caToggleCallChildren,
            enabled = hasChildren,
            reason = (if hasChildren: "" else: "the call made no calls"))])

func callArgumentContextMenu*(index: int64; name,
                              value: string): ContextMenuModel =
  ## A call-trace ARGUMENT's right-click menu — `isonim_calltrace_view.
  ## callArgContextItems`: "Add value to scratchpad".
  ContextMenuModel(
    kind: cmkCallArgument,
    target: ContextTarget(pane: paneCalltrace, index: index,
                          expression: name, text: value),
    entries: @[entry(AddValueToScratchpadLabel, caAddValueToScratchpad)])

func variablesContextMenu*(path: string): ContextMenuModel =
  ## A Variables row's right-click menu — the State pane's
  ## `buildVariableRowContextMenu`: value history and value origin.
  ContextMenuModel(
    kind: cmkVariablesRow, target: ContextTarget(pane: paneState, path: path),
    entries: @[
      entry("Toggle value history", caToggleValueHistory),
      entry("Show value origin", caShowValueOrigin, hint = "Ctrl+Shift+O")])

func flowValueContextMenu*(path: string; line: int; name, value: string;
                           lineValues: seq[NamedValue]): ContextMenuModel =
  ## An inline value's right-click menu — `ui/flow.createContextMenuItems`:
  ## "Jump to value" (the step the line ran at), "Add value to scratchpad"
  ## and "Add all values to scratchpad" (every value the line shows).
  ContextMenuModel(
    kind: cmkFlowValue,
    target: ContextTarget(pane: paneEditor, path: path, line: line,
                          expression: name, text: value, values: lineValues),
    entries: @[
      entry(JumpToValueLabel, caJumpToValue, hint = "<click on value>"),
      entry(AddValueToScratchpadLabel, caAddValueToScratchpad,
            hint = "CTRL+<click on value>"),
      entry(AddAllValuesToScratchpadLabel, caAddAllValuesToScratchpad)])

func valueHistoryEntryContextMenu*(expression, value: string;
                                   ticks: uint64;
                                   path = ""): ContextMenuModel =
  ## PLAT-51: a value-history ENTRY's right-click menu — the desktop's
  ## `ui/value.createHistoryContextMenu`: "Add to scratchpad" (the entry's
  ## value, under the variable's name) and "Show value origin".
  ContextMenuModel(
    kind: cmkValueHistoryEntry,
    target: ContextTarget(pane: paneState,
                          path: (if path.len > 0: path else: expression),
                          expression: expression, text: value,
                          index: int64(ticks)),
    entries: @[
      entry(AddToScratchpadLabel, caAddValueToScratchpad),
      entry("Show value origin", caShowValueOrigin)])

func labels*(m: ContextMenuModel): seq[string] =
  for e in m.entries:
    result.add e.label

# ---------------------------------------------------------------------------
# An open menu
# ---------------------------------------------------------------------------

func firstEnabled(m: ContextMenuModel): int =
  for i, e in m.entries:
    if e.enabled:
      return i
  -1

proc openAt*(s: var ContextMenuState; menu: ContextMenuModel; row, col: int) =
  ## Open `menu` at a cell (or a pixel): the keyboard starts on its first
  ## enabled entry, as the desktop's menu starts with none hovered but takes
  ## Down onto the first.
  s = ContextMenuState(open: true, menu: menu, selected: firstEnabled(menu),
                       anchorRow: row, anchorCol: col)

proc close*(s: var ContextMenuState) =
  s.open = false
  s.selected = -1

proc move*(s: var ContextMenuState; delta: int) =
  ## Up / Down: to the next ENABLED entry that way, wrapping.
  let n = s.menu.entries.len
  if not s.open or n == 0:
    return
  var i = if s.selected < 0: (if delta > 0: -1 else: n) else: s.selected
  for _ in 0 ..< n:
    i = (i + delta + n) mod n
    if s.menu.entries[i].enabled:
      s.selected = i
      return

proc hover*(s: var ContextMenuState; index: int) =
  ## The pointer is on entry `index` (any entry: a disabled one is still
  ## where the pointer is, but it is never chosen).
  if s.open and index >= 0 and index < s.menu.entries.len:
    s.selected = index

proc choose*(s: var ContextMenuState; index: int):
    tuple[chosen: bool, action: ContextAction, target: ContextTarget] =
  ## Choose entry `index` (or the selected one for -1): an enabled entry
  ## closes the menu and answers its action; a disabled one answers nothing
  ## and leaves the menu open, as a disabled desktop item does.
  let i = if index < 0: s.selected else: index
  if not s.open or i < 0 or i >= s.menu.entries.len:
    return (false, caNone, ContextTarget())
  let e = s.menu.entries[i]
  if not e.enabled:
    return (false, caNone, s.menu.target)
  let target = s.menu.target
  s.close()
  (true, e.action, target)

func scratchpadSamplesOf*(target: ContextTarget;
                          action: ContextAction): seq[NamedValue] =
  ## The (expression, value) pairs a scratchpad action pins: the one value,
  ## or every value of the line.
  case action
  of caAddValueToScratchpad: @[(target.expression, target.text)]
  of caAddAllValuesToScratchpad: target.values
  else: @[]

# ---------------------------------------------------------------------------
# The inventory — the PLAT-50 milestone's table, row for row
# ---------------------------------------------------------------------------

func k(id, target: string; gestures: set[ClickGesture];
       desktop, sharedOp: string; terminal, gpui: NativeState;
       note = ""): ClickBehaviour =
  ClickBehaviour(id: id, target: target, gestures: gestures,
                 desktop: desktop, sharedOp: sharedOp, terminal: terminal,
                 gpui: gpui, note: note)

const ClickInventory*: array[56, ClickBehaviour] = [
  k("K1", "Top bar: menu button / item", {cgClick},
    "open the menu; run the item / enter the folder", "MenuVM",
    nsExisting, nsExisting, "PLAT-48/49"),
  k("K2", "Top bar: transport control", {cgClick},
    "the step / action", "DebugControlsVM", nsExisting, nsExisting, "PLAT-48"),
  k("K3", "Top bar: omnibox / result", {cgClick},
    "focus the field; accept the result", "OmnibarVM", nsExisting,
    nsExisting, "PLAT-48"),
  k("K4", "Top bar: session tab / close / add", {cgClick},
    "activate / close / new tab", "HeadlessApp", nsExisting, nsExisting,
    "PLAT-49 part B"),
  k("K5", "Pane tab", {cgClick}, "activate the tab", "lcActivateTab",
    nsExisting, nsExisting, "PLAT-47"),
  k("K6", "Pane tab", {cgDrag}, "move / split / dock", "layout_interaction",
    nsExisting, nsExisting, "PLAT-47/49"),
  k("K7", "Pane tab", {cgRightClick},
    "menu: Pin to Left / Bottom / Right, Close, Maximise container",
    "tabContextMenu", nsDone, nsDone),
  k("K8", "Auto-hide label", {cgHover, cgClick}, "preview / dock",
    "auto_hide_hover", nsExisting, nsExisting, "PLAT-49 part B"),
  k("K9", "Divider", {cgDrag}, "resize", "lcSetWeight", nsExisting,
    nsExisting, "PLAT-6/47"),
  k("K10", "Editor gutter", {cgClick}, "toggle a breakpoint on the line",
    "toggleBreakpoint", nsDone, nsDone),
  k("K11", "Editor gutter", {cgRightClick},
    "enable / disable the line's breakpoint", "setBreakpointEnabled",
    nsDone, nsDone,
    "the desktop's own handler did nothing on a marker; fixed by PLAT-50"),
  k("K12", "Editor text", {cgCtrlClick, cgMiddleClick}, "Jump to line",
    "sourceLineJump(smart)", nsDone, nsDone),
  k("K13", "Editor text", {cgRightClick},
    "menu: Copy, Find, the line and call jumps, the breakpoint entries, " &
      "Add tracepoint",
    "editorTextContextMenu", nsDone, nsDone),
  k("K14", "Editor text", {cgAltClick}, "a column-anchored breakpoint",
    "setColumnBreakpoint", nsDone, nsDone),
  k("K15", "Editor text: a call", {cgCtrlAltClick}, "Jump to call",
    "sourceCallJump", nsDone, nsDone),
  k("K16", "Editor gutter: run-test control", {cgClick},
    "re-record and run the test", "edit-mode test runner", nsNotApplicable,
    nsNotApplicable, "drawn in Edit mode only, where PLAT-43 runs it"),
  k("K17", "Files: file", {cgClick}, "open it in the editor",
    "FilesystemVM.openFile", nsDone, nsDone),
  k("K18", "Files: folder", {cgClick}, "expand / collapse",
    "FilesystemVM.toggleExpanded", nsDone, nsDone),
  k("K19", "Files: node", {cgRightClick},
    "no menu: the four no-op entries the desktop showed were removed",
    "-", nsDone, nsDone, "no front-end opens a Files menu"),
  k("K20", "Call trace: row", {cgClick, cgDoubleClick}, "go to that call",
    "calltraceJumpByLine", nsExisting, nsExisting, "PLAT-49 part B"),
  k("K21", "Call trace: toggle", {cgClick}, "expand / collapse children",
    "ct/expand-calls", nsExisting, nsExisting, "PLAT-49 part B"),
  k("K22", "Call trace: row", {cgRightClick},
    "menu: Expand / Collapse Call Children",
    "callTraceContextMenu", nsDone, nsDone,
    "the desktop's \"Expand Full Callstack\" could change nothing and was " &
      "removed by PLAT-50"),
  k("K23", "Call trace: argument", {cgRightClick},
    "menu: Add value to scratchpad", "addToScratchpad", nsDone, nsDone),
  k("K24", "Event log: row", {cgClick}, "go to that event", "eventJump",
    nsDone, nsDone),
  k("K25", "Event log: row", {cgRightClick},
    "open the event's full content", "event content overlay", nsDone,
    nsDone),
  k("K26", "Event log: column header", {cgClick},
    "sort by the column, again to reverse", "EventLogOrder", nsDone, nsDone,
    "the desktop's header strip took no click and the engine ignored the " &
      "order; both fixed by PLAT-50"),
  k("K27", "Variables: expander", {cgClick}, "expand / collapse the value",
    "variables expand", nsDone, nsDone),
  k("K28", "Variables: row", {cgRightClick},
    "menu: Toggle value history / Show value origin",
    "variablesContextMenu", nsDone, nsDone),
  k("K29", "Variables: Locals / Globals / Watches", {cgClick},
    "switch the tab", "StateVM.selectTab", nsNotApplicable, nsDone,
    "the terminal lists every group in one tree (PLAT-49 finding 12)"),
  k("K30", "Timeline: track", {cgClick}, "seek to the tick",
    "gotoTick", nsDone, nsDone),
  k("K31", "Point list: row", {cgClick}, "select the point",
    "PointListVM.selectPoint", nsDone, nsDone),
  k("K32", "Terminal output: line", {cgClick}, "go to that output",
    "ct/event-jump", nsDone, nsDone,
    "PLAT-52: the pane is drawn natively; a fragment (or the line past its " &
      "text) goes to its write"),
  k("K33", "Scratchpad: close", {cgClick},
    "remove the entry", "ScratchpadVM.removeValue", nsDone, nsDone),
  k("K34", "VCS: changed file", {cgClick}, "open the file's diff",
    "vcsFileDiff", nsDone, nsDone),
  k("K35", "Search results / Problems / Build line", {cgClick},
    "jump to file:line", "source jump", nsNotApplicable, nsNotApplicable,
    "the panes are report leaves natively in a replay"),
  k("K36", "Inline value", {cgClick, cgCtrlClick, cgRightClick},
    "go to the step the line ran at / add it to the scratchpad / menu: " &
      "Jump to value, Add value to scratchpad, Add all values to scratchpad",
    "addToScratchpad", nsDone, nsDone,
    "a native inline value is the current step's, so its click stays here"),
  k("K37", "Status bar: location", {cgClick},
    "copy the current file's path to the clipboard", "clipboard", nsDone,
    nsDone),
  k("K38", "Call trace: argument", {cgClick},
    "nothing: no tooltip, no move (only the call's name takes the press)",
    "-", nsExisting, nsExisting,
    "measured on the desktop; natively the whole row is the press target " &
    "(K20, PLAT-49 part B) — a terminal row has no separate name target"),
  k("K39", "Event log: filter button and kinds", {cgClick},
    "filter the log by event kind", "-", nsNotApplicable, nsNotApplicable,
    "the native event logs draw no filter control"),
  k("K40", "Variables: history button", {cgClick},
    "toggle the value's history", "loadValueHistory", nsNotApplicable,
    nsNotApplicable,
    "the native rows draw no history button; the row's menu has it (K28)"),
  k("K41", "Variables: origin badge", {cgClick},
    "show the origin chain in the row", "-", nsNotApplicable,
    nsNotApplicable, "the native rows draw no origin badge"),
  k("K42", "Auto-hide label", {cgRightClick},
    "menu: Pin to the other edges, Unpin, Close", "dockLabelContextMenu",
    nsDone, nsDone),
  k("K43", "Pane tab: pin button", {cgClick}, "pin the pane to the left",
    "cmdDock", nsNotApplicable, nsExisting,
    "the terminal strip draws no pin glyph (its tab menu pins, K7); " &
      "GPUI's button is PLAT-49 part B's"),
  k("K44", "Timeline: zoom buttons", {cgClick}, "zoom the track",
    "-", nsNotApplicable, nsNotApplicable,
    "the native timelines draw no zoom control"),
  k("K45", "Timeline: track", {cgDrag},
    "seek where the drag is released", "gotoTick", nsDone, nsDone),
  k("K46", "Flow: loop iteration controls", {cgClick, cgDoubleClick},
    "previous / next iteration; open a folded iteration", "-",
    nsNotApplicable, nsNotApplicable,
    "the native flow overlay draws no loop controls"),
  k("K47", "Editor text", {cgClick}, "place the caret", "-",
    nsNotApplicable, nsNotApplicable,
    "a replay's native editor has no caret"),
  k("K48", "Status bar: notification", {cgClick},
    "dismiss it / run its action", "-", nsNotApplicable, nsNotApplicable,
    "native notes are one status line with no buttons"),
  k("K49", "Files: a recording's diff list", {cgClick},
    "open the changed file", "-", nsNotApplicable, nsNotApplicable,
    "the native Files panes list no diff"),
  k("K50", "Tracepoint editor: run, menu, results, chart kind", {cgClick},
    "run / disable / hide / delete; go to a result", "-", nsNotApplicable,
    nsNotApplicable, "native tracepoints are set by command, not a widget"),
  k("K51", "Event log: a marker's boundary chip", {cgClick},
    "go to its counterpart", "-", nsNotApplicable, nsNotApplicable,
    "drawn only in a multi-recording session, which no native front-end opens"),
  k("K52", "Call trace: search result", {cgClick}, "go to that call", "-",
    nsNotApplicable, nsNotApplicable,
    "the native call traces draw no search box"),
  k("K53", "VCS: commit", {cgClick}, "expand / collapse its files",
    "VCSVM.setCommitFiles", nsDone, nsDone),
  k("K54", "VCS: branch, refresh", {cgClick},
    "list the branches; re-read the repository", "-", nsNotApplicable,
    nsNotApplicable,
    "the native VCS panes draw the branch as text and no refresh control"),
  k("K55", "Scratchpad: expander", {cgClick}, "expand a composite value",
    "-", nsNotApplicable, nsNotApplicable,
    "the native scratchpads hold one-line values"),
  k("K56", "Status bar: certificate", {cgClick}, "show the certificate",
    "-", nsNotApplicable, nsNotApplicable,
    "drawn only for a test recording with a certificate")]

func behaviour*(id: string): ClickBehaviour =
  ## The inventory row named `id` (`K1` …); an empty value for an unknown id.
  for b in ClickInventory:
    if b.id == id:
      return b

func describe*(b: ClickBehaviour): string =
  ## One line, for a report.
  var gestures: seq[string] = @[]
  for g in b.gestures:
    gestures.add $g
  b.id & " " & b.target & " [" & gestures.join(",") & "] " &
    b.desktop & " -> " & $b.terminal & "/" & $b.gpui
