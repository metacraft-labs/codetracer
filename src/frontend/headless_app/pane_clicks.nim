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
# The Agent Activity prompt's "add context" items, through the SDK facade
# (`viewmodels/agent_prompt_context`, re-exported by `codetracer_embed`).
from codetracer_embed import AgentAddContextItem, label,
  AgentNoEditorSelectionReason
# The editor's Nim trace entries (`viewmodels/nim_tracing_vm`).
from codetracer_embed import NimTraceAction, nimTraceLabelOf,
  nimTraceOperationOf

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
    nsRetired = "retired"
      ## The desktop no longer has the target either: a later decision removed
      ## it from every front-end (the decision in `note`). The row keeps its id
      ## so the ids stay the milestone table's; nothing implements it.

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
    ## operation the context menus run, so a host's `case` over it is the
    ## exhaustive list of what it must route. Top is the native hosts'
    ## additional auto-hide edge; the remaining operations mirror desktop.
    caNone = "none"
    caPinLeft = "pin-left"
    caPinBottom = "pin-bottom"
    caPinRight = "pin-right"
    caPinTop = "pin-top"
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
    caToggleInlineBreakpoint = "toggle-inline-breakpoint"
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
    caFileCreate = "file-create"
      ## The Files pane's menu (Filesystem-Pane.md § "Context menu"): the
      ## four entries `FilesystemVM.fileTreeMenu` decides, in its order.
    caFileRename = "file-rename"
    caFileDelete = "file-delete"
    caFileEdit = "file-edit"
    caAgentAttachUpload = "agent-attach-upload"
      ## PLAT-54: the Agent Activity prompt's `+` menu
      ## (`agentAddContextMenu`), its four items in the desktop's order.
    caAgentAttachFilesFolders = "agent-attach-files-folders"
    caAgentAttachEditorSelection = "agent-attach-editor-selection"
    caAgentAttachRecording = "agent-attach-recording"
    caRequestGoToHandler = "request-go-to-handler"
      ## PLAT-58: the Requests row's menu (Request-Panel.md § N.5), the
      ## entries `RequestPanelVM.rowMenu` decides, in its order; the request
      ## is `ContextTarget.index` (its id).
    caRequestCopyUrl = "request-copy-url"
    caRequestFilterMethod = "request-filter-method"
      ## …and a Method picker's choice: the filter becomes
      ## `ContextTarget.text` ("" for every method).
    caRequestFilterStatus = "request-filter-status"
      ## …and a Status picker's choice (`text`: "2xx" … "5xx", or "").
    caRequestClearFilters = "request-clear-filters"
    caLowLevelGoToSourceLine = "low-level-go-to-source-line"
      ## PLAT-60: an instruction's menu in the Low Level Code pane, the
      ## entries `LowLevelCodeVM.rowMenu` decides, in its order; the
      ## instruction is `ContextTarget.index`, its offset `line`.
    caLowLevelShowSourceLine = "low-level-show-source-line"
    caLowLevelCopyInstruction = "low-level-copy-instruction"
    caLowLevelCopySourceLocation = "low-level-copy-source-location"
    caVerificationGoToSource = "verification-go-to-source"
      ## PLAT-63: a line's menu in the Verification pane, the entries
      ## `VerificationVM.rowMenu` decides, in its order; the line is
      ## `ContextTarget.text` (its key).
    caVerificationOpenCounterexample = "verification-open-counterexample"
    caVerificationCopyMessage = "verification-copy-message"
    caVerificationCopyLocation = "verification-copy-location"
    caVerificationCloseCounterexample = "verification-close-counterexample"
    caConstraintGoToSource = "constraint-go-to-source"
      ## PLAT-62: a Constraints row's menu, the entries
      ## `ConstraintsVM.rowMenu` decides, in its order; the row is
      ## `ContextTarget.index` (its index in the ViewModel's rows) and its
      ## name `ContextTarget.text`.
    caConstraintCopyName = "constraint-copy-name"
    caConstraintCopySourceLocation = "constraint-copy-source-location"
    caTraceMacro = "trace-macro"
      ## Nim's compile-time tracing (`viewmodels/nim_tracing_vm`): the
      ## editor's four entries, offered where the caret is on what they
      ## trace; each runs its `editor.trace-*` operation at the menu's line
      ## and column.
    caTraceStaticBlock = "trace-static-block"
    caTraceConstant = "trace-constant"
    caTraceEval = "trace-eval"

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
    cmkFileTreeNode = "file-tree-node"
      ## A row of the Files pane's tree (K19).
    cmkAgentAddContext = "agent-add-context"
      ## The Agent Activity prompt's `+` (the desktop's
      ## `.agent-add-context-dropdown`): opened by a press, not a right-click.
    cmkRequestRow = "request-row"
      ## PLAT-58: a row of the Requests pane (K59).
    cmkRequestPicker = "request-picker"
      ## PLAT-58: the Requests pane's Method or Status picker, opened as a
      ## dropdown (K60): one entry per option, the current one hinted.
    cmkLowLevelRow = "low-level-row"
      ## PLAT-60: an instruction of the Low Level Code pane (K62).
    cmkVerificationRow = "verification-row"
      ## PLAT-63: a finding, an offer or a step of the Verification pane
      ## (K65).
    cmkConstraintRow = "constraint-row"
      ## PLAT-62: a row of the Constraints pane (K68).

  ContextMenuEntry* = object
    label*: string
    hint*: string
      ## The desktop's hint column (a chord, a gesture).
    action*: ContextAction
    enabled*: bool
    reason*: string
      ## Why a disabled entry is disabled.
    carriesValue*: bool
      ## PLAT-58: the entry names its own value (a picker's option), which
      ## the chosen target carries in `text` (`choose`) — "" included.
    value*: string

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
    tick*: uint64
      ## An event's or a history entry's moment.
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

const ContextActionOperations*: array[ContextAction, string] = [
    caNone: "",
    caPinLeft: "layout.pin-pane-left",
    caPinBottom: "layout.pin-pane-bottom",
    caPinRight: "layout.pin-pane-right",
    caPinTop: "layout.pin-pane-top",
    caUnpin: "layout.unpin-pane",
    caClosePane: "layout.close-pane",
    caMaximise: "layout.maximize-pane",
    caCopy: "editor.copy-at",
    caFind: "find.open",
    caJumpToLine: "debugger.smart-jump",
    caRunToCursor: "debugger.run-to-cursor",
    caJumpBackwardToLine: "debugger.jump-backward-to-line",
    caJumpToCall: "debugger.source-call-jump",
    caJumpForwardToCall: "debugger.jump-forward-to-call",
    caJumpBackwardToCall: "debugger.jump-backward-to-call",
    caAddBreakpoint: "editor.add-breakpoint",
    caToggleInlineBreakpoint: "editor.toggle-inline-breakpoint",
    caDeleteBreakpoint: "editor.delete-breakpoint",
    caEnableBreakpoint: "editor.enable-breakpoint",
    caDisableBreakpoint: "editor.disable-breakpoint",
    caDeleteBreakpointsInFile: "editor.delete-breakpoints-in-file",
    caDeleteAllBreakpoints: "editor.delete-all-breakpoints",
    caAddTracepoint: "editor.toggle-tracepoint",
    caToggleCallChildren: "calltrace.toggle-call",
    caToggleValueHistory: "variables.value-history",
    caShowValueOrigin: "variables.show-value-origin",
    caAddValueToScratchpad: "scratchpad.add-value",
    caAddAllValuesToScratchpad: "scratchpad.add-all-values",
    caJumpToValue: "variables.jump-to-value",
    caFileCreate: "file-tree.create",
    caFileRename: "file-tree.rename",
    caFileDelete: "file-tree.delete",
    caFileEdit: "file-tree.edit",
    caAgentAttachUpload: "agent-activity.attach-upload",
    caAgentAttachFilesFolders: "agent-activity.attach-files-folders",
    caAgentAttachEditorSelection: "agent-activity.attach-editor-selection",
    caAgentAttachRecording: "agent-activity.attach-recording",
    caRequestGoToHandler: "requests.go-to-handler",
    caRequestCopyUrl: "requests.copy-url",
    caRequestFilterMethod: "requests.filter-method",
    caRequestFilterStatus: "requests.filter-status",
    caRequestClearFilters: "requests.clear-filters",
    caLowLevelGoToSourceLine: "low-level.go-to-source-line",
    caLowLevelShowSourceLine: "low-level.show-source-line",
    caLowLevelCopyInstruction: "low-level.copy-instruction",
    caLowLevelCopySourceLocation: "low-level.copy-source-location",
    caVerificationGoToSource: "verification.go-to-source",
    caVerificationOpenCounterexample: "verification.open-counterexample",
    caVerificationCopyMessage: "verification.copy-message",
    caVerificationCopyLocation: "verification.copy-location",
    caVerificationCloseCounterexample: "verification.close-counterexample",
    caConstraintGoToSource: "constraints.go-to-source",
    caConstraintCopyName: "constraints.copy-name",
    caConstraintCopySourceLocation: "constraints.copy-source-location",
    caTraceMacro: "editor.trace-macro-at-cursor",
    caTraceStaticBlock: "editor.trace-static-block-at-cursor",
    caTraceConstant: "editor.trace-constant-at-cursor",
    caTraceEval: "editor.trace-eval"]
  ## The operation each context menu action runs (Input-Routing §3.2): the
  ## array's index type makes it total, and `test_plat64_operation_mapping`
  ## asserts every name is catalogued and none is listed twice.

const
  DesktopTabMenuLabels* = ["Pin to Left", "Pin to Bottom", "Pin to Right",
                           "Close"]
    ## `ui/layout.addPanelTransferContextMenu`'s first four entries; the fifth
    ## names the stack's state (`MaximiseLabel` / `MinimiseLabel`).
  TopPinLabel* = "Pin to Top"
    ## Native front-ends support the fourth auto-hide edge too. Keep the
    ## measured desktop labels above intact: the desktop has no Top entry.
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
  ## pin to an edge, close, and maximise / minimise its container, with Top
  ## added for the native hosts' fourth auto-hide edge.
  ContextMenuModel(
    kind: cmkTab, target: ContextTarget(pane: pane),
    entries: @[
      entry(DesktopTabMenuLabels[0], caPinLeft),
      entry(DesktopTabMenuLabels[1], caPinBottom),
      entry(DesktopTabMenuLabels[2], caPinRight),
      entry(TopPinLabel, caPinTop),
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
  if edge != leTop:
    result.entries.add entry(TopPinLabel, caPinTop)
  result.entries.add entry(UnpinLabel, caUnpin)
  result.entries.add entry(DesktopTabMenuLabels[3], caClosePane)

type
  NimTraceEntry* = tuple[label: string; action: ContextAction; hint: string]
    ## One of the editor's Nim trace entries, as the caller decided it from
    ## the document and the caret (`nim_tracing_vm.availableNimTraceActions`)
    ## and the active base's chord.

func nimTraceContextAction*(action: NimTraceAction): ContextAction =
  case action
  of ntaMacro: caTraceMacro
  of ntaStaticBlock: caTraceStaticBlock
  of ntaConstant: caTraceConstant
  of ntaEval: caTraceEval

func nimTraceActionOf*(action: ContextAction): tuple[found: bool;
                                                    action: NimTraceAction] =
  case action
  of caTraceMacro: (true, ntaMacro)
  of caTraceStaticBlock: (true, ntaStaticBlock)
  of caTraceConstant: (true, ntaConstant)
  of caTraceEval: (true, ntaEval)
  else: (false, ntaMacro)

proc nimTraceEntriesOf*(actions: set[NimTraceAction];
                        chordOf: proc(operation: string): string):
    seq[NimTraceEntry] =
  ## The entries for the actions the caret offers, in the actions' order,
  ## each hinted with its chord in the active base (`chordOf`, "" for none).
  for a in NimTraceAction:
    if a in actions:
      let op = nimTraceOperationOf(a)
      result.add (nimTraceLabelOf(a), nimTraceContextAction(a),
                  (if chordOf.isNil: "" else: chordOf(op)))

func addNimTraceEntries(menu: var ContextMenuModel;
                        entries: openArray[NimTraceEntry]) =
  for e in entries:
    menu.entries.add entry(e.label, e.action, hint = e.hint)

type
  LineBreakpoint* = enum
    ## The breakpoint on the line a menu is opened on.
    lbNone, lbEnabled, lbDisabled

func editorTextContextMenu*(path: string; line: int; lineText = "";
                            column = 0; token = ""; tokenError = "";
                            breakpoint = lbNone; fileHasBreakpoints = false;
                            anyBreakpoints = false;
                            inlineBreakpoint = false;
                            inlineChord = "Shift+F9";
                            nimTrace: openArray[NimTraceEntry] = []):
    ContextMenuModel =
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
                             hint = "<click left of the line number>")
  of lbEnabled:
    result.entries.add entry("Disable breakpoint", caDisableBreakpoint)
    result.entries.add entry("Delete breakpoint", caDeleteBreakpoint,
                             hint = "<click on the red dot>")
  of lbDisabled:
    result.entries.add entry("Enable breakpoint", caEnableBreakpoint)
    result.entries.add entry("Delete breakpoint", caDeleteBreakpoint,
                             hint = "<click on the red dot>")
  # Editor-Pane.md § Inline breakpoints: directly after the line breakpoint's
  # entries, at the press (a right press places the caret first). Its hint is
  # the active base's chord, read from the keymap by the caller.
  result.entries.add entry(
    (if inlineBreakpoint: "Remove Inline Breakpoint"
     else: "Add Inline Breakpoint"),
    caToggleInlineBreakpoint, hint = inlineChord)
  if fileHasBreakpoints:
    result.entries.add entry("Delete breakpoints in file",
                             caDeleteBreakpointsInFile)
  if anyBreakpoints:
    result.entries.add entry("Delete ALL breakpoints", caDeleteAllBreakpoints)
  result.entries.add entry("Add tracepoint", caAddTracepoint,
                           hint = "Enter<on line>")
  # The Nim trace entries close the menu, as on the desktop.
  result.addNimTraceEntries(nimTrace)

func editorEditContextMenu*(path: string; line: int; lineText = "";
                            column = 0;
                            nimTrace: openArray[NimTraceEntry] = []):
    ContextMenuModel =
  ## The editor's right-click menu in EDIT mode on the native front-ends:
  ## the entries that MAKE a recording rather than navigate one — the Nim
  ## trace entries — which the desktop offers in both its menus
  ## (`ui/editor.createContextMenuItems`, Mode-Transitions.md §8.3). Empty
  ## where the caret offers none; a front-end opens no menu then.
  result = ContextMenuModel(
    kind: cmkEditorText,
    target: ContextTarget(pane: paneEditor, path: path, line: line,
                          column: column, text: lineText))
  result.addNimTraceEntries(nimTrace)

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

const FileTreeMenuLabels* = ["Create", "Rename", "Delete", "Edit"]
  ## The Files pane's menu, always all four and in this order
  ## (Filesystem-Pane.md § "Context menu"; `FilesystemVM.FileTreeAction`).

func fileTreeNodeContextMenu*(path: string;
                              decided: openArray[tuple[label: string;
                                                       enabled: bool;
                                                       reason: string]]):
    ContextMenuModel =
  ## A Files row's right-click menu, from the entries the shared Files model
  ## decided (`headless_app/file_tree_menu.fileTreeContextMenuOf` reads them
  ## off `FilesystemVM.fileTreeMenu`). A disabled entry keeps its reason, and
  ## the reason is also its HINT — the column a native menu draws beside the
  ## label — because the spec shows it as the entry's sublabel.
  result = ContextMenuModel(kind: cmkFileTreeNode,
                            target: ContextTarget(pane: paneFileTree,
                                                  path: path))
  for d in decided:
    let action =
      if d.label == FileTreeMenuLabels[0]: caFileCreate
      elif d.label == FileTreeMenuLabels[1]: caFileRename
      elif d.label == FileTreeMenuLabels[2]: caFileDelete
      elif d.label == FileTreeMenuLabels[3]: caFileEdit
      else: caNone
    result.entries.add entry(d.label, action,
                             hint = (if d.enabled: "" else: d.reason),
                             enabled = d.enabled, reason = d.reason)

const RequestPickerCurrentHint* = "current"
  ## The hint column of a picker's current option (the desktop's
  ## `ct-menu-item--active`).

func requestRowContextMenu*(id: int64;
                            decided: openArray[tuple[label: string;
                                                     action: ContextAction;
                                                     enabled: bool;
                                                     reason: string]]):
    ContextMenuModel =
  ## PLAT-58 (K59): a Requests row's menu, from the entries the shared model
  ## decided (`headless_app/request_menu.requestRowContextMenuOf` reads them
  ## off `RequestPanelVM.rowMenu`). A disabled entry's reason is its hint too,
  ## as the Files menu's is.
  result = ContextMenuModel(kind: cmkRequestRow,
                            target: ContextTarget(pane: paneRequests,
                                                  index: id))
  for d in decided:
    result.entries.add entry(d.label, d.action,
                             hint = (if d.enabled: "" else: d.reason),
                             enabled = d.enabled, reason = d.reason)

func requestPickerContextMenu*(statusPicker: bool;
                               options: openArray[(string, string)];
                               current: string): ContextMenuModel =
  ## PLAT-58 (K60): the Method (or Status) picker as a dropdown — the
  ## desktop's options in its order, each choosing its value
  ## (`ContextTarget.text`, "" for All); the current one hinted.
  result = ContextMenuModel(kind: cmkRequestPicker,
                            target: ContextTarget(pane: paneRequests,
                                                  text: current,
                                                  expression:
                                                    (if statusPicker: "status"
                                                     else: "method")))
  let action = if statusPicker: caRequestFilterStatus
               else: caRequestFilterMethod
  for (value, label) in options:
    var e = entry(label, action,
                  hint = (if value == current: RequestPickerCurrentHint
                          else: ""))
    e.carriesValue = true
    e.value = value
    result.entries.add e

func lowLevelRowContextMenu*(index, offset: int;
                             decided: openArray[tuple[label: string;
                                                      action: ContextAction;
                                                      enabled: bool;
                                                      reason: string]]):
    ContextMenuModel =
  ## PLAT-60: an instruction's menu in the Low Level Code pane, from the
  ## entries the shared model decided (`headless_app/low_level_menu.
  ## lowLevelRowContextMenuOf` reads them off `LowLevelCodeVM.rowMenu`). A
  ## disabled entry's reason is its hint too, as the Files menu's is. The
  ## target carries the instruction's index and offset, so a choice made
  ## after the listing changed finds no row rather than another one.
  result = ContextMenuModel(kind: cmkLowLevelRow,
                            target: ContextTarget(pane: paneLowLevelCode,
                                                  index: int64(index),
                                                  line: offset))
  for d in decided:
    result.entries.add entry(d.label, d.action,
                             hint = (if d.enabled: "" else: d.reason),
                             enabled = d.enabled, reason = d.reason)

func verificationRowContextMenu*(key: string;
                                 decided: openArray[tuple[label: string;
                                                          action: ContextAction;
                                                          enabled: bool;
                                                          reason: string]]):
    ContextMenuModel =
  ## PLAT-63: a line's menu in the Verification pane, from the entries the
  ## shared model decided (`headless_app/verification_menu.
  ## verificationRowContextMenuOf` reads them off `VerificationVM.rowMenu`).
  ## The target carries the line's key, so a choice made after a new run
  ## replaced the list finds no line rather than another one.
  result = ContextMenuModel(kind: cmkVerificationRow,
                            target: ContextTarget(pane: paneVerification,
                                                  text: key, index: -1))
  for d in decided:
    result.entries.add entry(d.label, d.action,
                             hint = (if d.enabled: "" else: d.reason),
                             enabled = d.enabled, reason = d.reason)

func constraintRowContextMenu*(index: int; name: string;
                               decided: openArray[tuple[label: string;
                                                        action: ContextAction;
                                                        enabled: bool;
                                                        reason: string]]):
    ContextMenuModel =
  ## PLAT-62 (K68): a Constraints row's menu, from the entries the shared
  ## model decided (`headless_app/constraint_menu.constraintRowContextMenuOf`
  ## reads them off `ConstraintsVM.rowMenu`). A disabled entry's reason is its
  ## hint too, as the Requests row's is.
  result = ContextMenuModel(kind: cmkConstraintRow,
                            target: ContextTarget(pane: paneConstraints,
                                                  index: int64(index),
                                                  text: name))
  for d in decided:
    result.entries.add entry(d.label, d.action,
                             hint = (if d.enabled: "" else: d.reason),
                             enabled = d.enabled, reason = d.reason)

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

func agentAddContextMenu*(editorSelection: string): ContextMenuModel =
  ## The Agent Activity prompt's `+` menu — the desktop's four items, in its
  ## order and words (`agent_prompt_context.AgentAddContextItem`). A native
  ## front-end has no system file dialog, so the two file items and the
  ## recording item open the omnibox on a path (DeepReview-GUI.md §2.2.7);
  ## *Editor selection* attaches `editorSelection` (the editor's file and the
  ## lines its selection covers, `editorSelectionContext`), disabled with the
  ## reason when no file is shown.
  ContextMenuModel(
    kind: cmkAgentAddContext,
    target: ContextTarget(pane: paneAgentActivity, path: editorSelection),
    entries: @[
      entry(aciUpload.label, caAgentAttachUpload),
      entry(aciFilesFolders.label, caAgentAttachFilesFolders),
      entry(aciEditorSelection.label, caAgentAttachEditorSelection,
            hint = (if editorSelection.len > 0: ""
                    else: AgentNoEditorSelectionReason),
            enabled = editorSelection.len > 0,
            reason = (if editorSelection.len > 0: ""
                      else: AgentNoEditorSelectionReason)),
      entry(aciRecording.label, caAgentAttachRecording)])

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

proc moveToEnd*(s: var ContextMenuState; last: bool) =
  ## Home / End: to the first (or, with `last`, the final) ENABLED entry.
  ## Not `move(±n)`: a step of more than the entry count wraps to an
  ## arbitrary row, and Nim's `mod` keeps the sign of a negative operand.
  let n = s.menu.entries.len
  if not s.open or n == 0:
    return
  s.selected = -1
  move(s, if last: -1 else: 1)

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
  var target = s.menu.target
  if e.carriesValue:
    target.text = e.value
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

const ClickInventory*: array[75, ClickBehaviour] = [
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
  k("K10", "Editor gutter: glyph column", {cgClick}, "toggle a breakpoint on the line",
    "toggleBreakpoint", nsDone, nsDone),
  k("K11", "Editor gutter: glyph column", {cgRightClick},
    "enable / disable the line's breakpoint", "setBreakpointEnabled",
    nsDone, nsDone,
    "the desktop's own handler did nothing on a marker; fixed by PLAT-50"),
  k("K12", "Editor text", {cgCtrlClick, cgMiddleClick}, "Jump to line",
    "sourceLineJump(smart)", nsDone, nsDone),
  k("K13", "Editor text", {cgRightClick},
    "menu: Copy, Find, the line and call jumps, the breakpoint entries, " &
      "Add / Remove Inline Breakpoint, Add tracepoint",
    "editorTextContextMenu", nsDone, nsDone),
  k("K14", "Editor text", {cgAltClick}, "add a cursor",
    "add-cursor-at-point", nsDone, nsDone,
    "was a column-anchored breakpoint; column breakpoints are set at the caret"),
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
    "the Files pane's menu: Create, Rename, Delete, Edit " &
      "(Filesystem-Pane.md)",
    "FilesystemVM.fileTreeMenu", nsDone, nsDone),
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
  k("K29", "Variables: hide watches from other processes", {cgClick},
    "hide or show the watches added in another process",
    "StateVM.setHideOtherProcessWatches", nsDone, nsDone,
    "the pane is one list of variables and watches; the terminal's toggle is `:watches hide|show`"),
  k("K30", "Timeline: track", {cgClick}, "seek to the tick",
    "-", nsRetired, nsRetired,
    "the Timeline panel was removed from every front-end (Layout-System.md, " &
      "\"The Timeline panel is removed\")"),
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
  k("K35", "Search results: row", {cgClick},
    "open the file at the line, the match selected; the recording position " &
      "stays", "SearchResultsVM.openResult", nsDone, nsDone,
    "PLAT-57: Find in Files is drawn natively on both"),
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
    "toggle the value's history", "loadValueHistory", nsExisting,
    nsExisting,
    "PLAT-51 drew the row's history control on both native front-ends " &
      "(the terminal's history glyph, `vcHistory`; GPUI's `history:` " &
      "button): it opens the history under the row. Corrected by " &
      "PLAT-70 Part E, which measured it; it read \"the native rows draw " &
      "no history button\""),
  k("K41", "Variables: origin badge", {cgClick},
    "show the origin chain in the row", "loadValueOrigin", nsExisting,
    nsExisting,
    "PLAT-51 drew the row's origin control on both native front-ends " &
      "(the terminal's `⇠`, `vcOrigin` → `pcValueOrigin`; GPUI's " &
      "`origin:` button → `showValueOrigin`): the chain opens under the " &
      "row. PLAT-70 Part E measured it (the entry read \"the native rows " &
      "draw no origin badge\") and added the keyboard: " &
      "`variables.show-value-origin` and the hops as rows"),
  k("K42", "Auto-hide label", {cgRightClick},
    "menu: Pin to the other edges, Unpin, Close", "dockLabelContextMenu",
    nsDone, nsDone),
  k("K43", "Pane tab: pin button", {cgClick}, "pin the pane to the left",
    "cmdDock", nsNotApplicable, nsExisting,
    "the terminal strip draws no pin glyph (its tab menu pins, K7); " &
      "GPUI's button is PLAT-49 part B's"),
  k("K44", "Timeline: zoom buttons", {cgClick}, "zoom the track",
    "-", nsRetired, nsRetired,
    "the Timeline panel was removed from every front-end (Layout-System.md, " &
      "\"The Timeline panel is removed\")"),
  k("K45", "Timeline: track", {cgDrag},
    "seek where the drag is released", "-", nsRetired, nsRetired,
    "the Timeline panel was removed from every front-end (Layout-System.md, " &
      "\"The Timeline panel is removed\")"),
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
    "drawn only for a test recording with a certificate"),
  k("K57", "Problems / Build line", {cgClick},
    "jump to file:line", "source jump", nsNotApplicable, nsNotApplicable,
    "the panes are report leaves natively in a replay (K35 was this row " &
      "with Find in Files' until PLAT-57 drew that pane)"),
  k("K58", "Requests: row", {cgClick, cgDoubleClick},
    "select it / go to the request handler's entry (the Call Trace " &
      "follows the move)", "RequestPanelVM.pressRow / activate", nsDone,
    nsDone, "PLAT-58: the ViewModel counts the double press, which neither " &
      "native platform reports"),
  k("K59", "Requests: row", {cgRightClick},
    "menu: Go to Handler, Copy URL, Filter by Method, Filter by Status, " &
      "Clear Filters", "RequestPanelVM.rowMenu", nsDone, nsDone,
    "PLAT-58 added the menu on all three front-ends"),
  k("K60", "Requests: Method / Status picker, URL field", {cgClick},
    "open the picker's options / focus the URL search",
    "RequestPanelVM.setFilterMethod / setFilterStatus / setSearchText",
    nsDone, nsDone,
    "PLAT-58: the pickers open as dropdowns; the field is the omnibox's " &
      "(the terminal's command line's) `:requests <text>`"),
  k("K61", "Low Level Code: instruction", {cgClick},
    "go to the source line it came from (`ct/source-line-jump`)",
    "LowLevelCodeVM.jumpToInstruction", nsDone, nsDone,
    "PLAT-60: the pane is drawn natively; the keys move the listing's " &
      "cursor, whose source line the editor cross-references"),
  k("K62", "Low Level Code: instruction", {cgRightClick},
    "menu: Go to Source Line, Show Source Line, Copy Instruction, Copy " &
      "Source Location", "LowLevelCodeVM.rowMenu", nsDone, nsDone,
    "PLAT-60 added the menu on all three front-ends"),
  k("K63", "Low Level Code: sync toggle", {cgClick},
    "keep the listing in step with the source, or stop",
    "LowLevelCodeVM.setSyncEnabled", nsDone, nsDone,
    "PLAT-60: the header's `sync on` / `sync off`"),
  k("K64", "Verification: finding, counterexample offer, step", {cgClick},
    "go to the finding's source location; open the counterexample; move " &
      "the counterexample to the step (and its source, when recorded)",
    "VerificationVM.activateLine", nsDone, nsDone,
    "PLAT-63: the pane is drawn natively; the keys move the cursor and " &
      "Enter is the press"),
  k("K65", "Verification: finding, counterexample offer, step",
    {cgRightClick},
    "menu: Go to Source, Step Through the Counterexample, Copy Message, " &
      "Copy Location, Close the Counterexample", "VerificationVM.rowMenu",
    nsDone, nsDone, "PLAT-63 added the menu on all three front-ends"),
  k("K66", "Verification: Run / Stop", {cgClick},
    "run the project's declared Verno action / stop the run",
    "verification_source.runVerification / stopVerification", nsDone,
    nsDone, "PLAT-63: drawn where the host runs the project's verifier; " &
      "the desktop's pane has no runner and draws neither"),
  k("K67", "Constraints: row", {cgClick},
    "select it / open the line that declares its function",
    "ConstraintsVM.activateRow", nsDone, nsDone,
    "PLAT-62: a row no source declares opens nothing and says why"),
  k("K68", "Constraints: row", {cgRightClick},
    "menu: Go to Source, Copy Name, Copy Source Location",
    "ConstraintsVM.rowMenu", nsDone, nsDone,
    "PLAT-62 added the menu on all three front-ends"),
  k("K69", "Video Player: transport control", {cgClick},
    "Jump to Start, Rewind, Play / Pause, Fast Forward, Jump to End, the " &
      "draw-call and frame steps, the Pixel Picker",
    "VideoPlayerVM.dispatchVideoPlayerAction", nsDone, nsDone,
    "PLAT-59: the transport row; the terminal's controls are `[|<]` …"),
  k("K70", "Video Player: frame scrubber", {cgClick, cgDrag},
    "seek to the frame under the pointer; a drag coalesces its requests " &
      "and settles on the release",
    "VideoPlayerVM.beginScrub / dragScrub / releaseScrub", nsDone, nsDone,
    "PLAT-59: the desktop's Scrub Slider, the pane's bottom track natively"),
  k("K71", "Video Player: draw-call scrubber", {cgClick, cgDrag},
    "show the framebuffer after that draw call of the frame (the desktop " &
      "steps draw calls with its buttons)",
    "VideoPlayerVM.beginScrub(scrubDraw)", nsDone, nsDone,
    "PLAT-59: the nested track under the frame scrubber, native only"),
  k("K72", "Video Player: frame", {cgClick},
    "the picker's commit: the pixel's history and shader (without the " &
      "picker, the pixel is selected)",
    "FrameViewerVM.selectPixel", nsDone, nsDone,
    "PLAT-59: the terminal's press opens §5's magnifier first; a press " &
      "on a magnified pixel commits it"),
  k("K73", "Pixel History: row", {cgClick},
    "go to the draw call's event; the Video Player shows that draw call; " &
      "the Shader Debug pane loads its fragment",
    "VisualReplayPanesVM.activateHistoryEntry", nsDone, nsDone,
    "PLAT-59: the desktop's click shows the draw call too now"),
  k("K74", "Shader Debug: step button", {cgClick},
    "First / Back / Step / Last",
    "ShaderDebugVM.stepFirst / stepBackward / stepForward / stepLast",
    nsDone, nsDone, "PLAT-59"),
  k("K75", "Editor gutter: line numbers",
    {cgClick, cgDrag, cgRightClick, cgAltClick},
    "select the line; drag selects lines, Shift+click extends by lines where " &
      "the medium delivers it; Alt+click adds a whole-line cursor; right click " &
      "opens the editor menu",
    "select-line-at, extend-by-unit-to", nsDone, nsDone)]

const
  GestureMachine* = "gesture"
    ## A row whose drag goes to a gesture machine (`layout_interaction`), not an
    ## operation (Input-Routing §5.2).

  ClickOperations*: seq[tuple[id, operation: string]] = @[
    ## Each behaviour as the OPERATION its element declares (Input-Routing
    ## §5.1). The rows `pointer_rows` holds resolve through the pointer keymap;
    ## `test_plat64_operation_mapping` asserts every row a front-end implements
    ## is here and names an operation that exists.
    ("K1", "menu.toggle"), ("K2", "debugger.step-over"),
    ("K3", "palette.open-commands"), ("K4", "session-tabs.activate"),
    ("K4", "session-tabs.close-tab"), ("K4", "session-tabs.new"),
    ("K5", "layout.activate-tab"), ("K6", GestureMachine),
    ("K7", "context-menu.open"), ("K8", "layout.reveal-next-docked"),
    ("K8", "layout.toggle-docked-pane"),
    ("K9", GestureMachine), ("K10", "editor.toggle-breakpoint"),
    ("K11", "editor.enable-breakpoint"), ("K12", "debugger.smart-jump"),
    ("K13", "context-menu.open"), ("K14", "editor.add-column-breakpoint"),
    ("K15", "debugger.source-call-jump"), ("K17", "file-tree.activate"),
    ("K18", "file-tree.activate"), ("K19", "context-menu.open"),
    ("K20", "calltrace.go-to-call"), ("K21", "calltrace.toggle-call"),
    ("K22", "context-menu.open"), ("K23", "context-menu.open"),
    ("K24", "event-log.jump"), ("K25", "event-log.show-content"),
    ("K26", "event-log.sort"), ("K27", "variables.toggle-expand"),
    ("K28", "context-menu.open"),
    ("K29", "variables.hide-other-process-watches"),
    ("K31", "point-list.select"), ("K32", "terminal-output.jump-to-write"),
    ("K33", "scratchpad.remove"), ("K34", "vcs.open-file-diff"),
    ("K35", "search.open-result"), ("K36", "scratchpad.add-value"),
    ("K37", "status.copy-path"), ("K38", "calltrace.go-to-call"),
    ("K40", "variables.value-history"), ("K41", "variables.value-origin"),
    ("K42", "context-menu.open"), ("K43", "layout.pin-pane-left"),
    ("K43", "layout.pin-pane-bottom"),
    ("K53", "vcs.toggle-commit"), ("K58", "requests.select"),
    ("K59", "context-menu.open"), ("K60", "requests.filter-method"),
    ("K61", "low-level.go-to-source-line"), ("K62", "context-menu.open"),
    ("K63", "low-level.toggle-sync"), ("K64", "verification.go-to-source"),
    ("K65", "context-menu.open"), ("K66", "verification.run"),
    ("K66", "verification.stop"),
    ("K67", "constraints.go-to-source"), ("K68", "context-menu.open"),
    ("K69", "video-player.toggle-play"), ("K70", "video-player.seek-frame"),
    ("K71", "video-player.seek-draw"), ("K72", "video-player.select-pixel"),
    ("K73", "pixel-history.activate"), ("K74", "shader-debug.step"),
    ("K75", "editor.select-line-at")]

func clickOperationOf*(id: string): string =
  ## The operation inventory row `id` declares, or "".
  for (k, op) in ClickOperations:
    if k == id: return op
  ""

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
