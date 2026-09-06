## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/call_stack.nim — CTUI-6. The left pane of CodeTracer-TUI.md
## §3.3.3, painted into whatever rectangle CTUI-3's projection gives the
## `calltrace` pane.
##
## ## A PURE FUNCTION OF A VALUE, for the same three reasons the source pane is
##
## `CallStackModel` in, `CallStackScreen` out. `app/call_stack_binding.nim` is
## the only module that knows a ViewModel or a DAP response exists. That is what
## lets the recursion-grouping suite assert against a 51-frame stack without a
## debugger, lets two frames be compared as values when the emission budget is
## measured, and keeps the pane's row count a property of a field a reader can
## see.
##
## ## THE FRAMES ARE AN INPUT, AND THAT IS A FINDING RATHER THAN A SHORTCUT
##
## CTUI-6's goal sentence says "bind `CalltraceVM` to a hierarchical frame
## tree". `CalltraceVM` is the ViewModel of the CALLTRACE — the recorded call
## TREE around the current position, `ct/load-calltrace-section`'s rows with
## their `depth` — and it is not the CALL STACK. Measured on
## `noir_space_ship` (2026-09-05): at a stop whose DAP `stackTrace` reports 4
## frames, `ct/load-calltrace-section` returns 81 rows, most of them siblings
## and children of calls that have already returned.
##
## **Nothing in `src/frontend/viewmodel/` issues DAP `stackTrace` or stores its
## answer.** `stackTrace` is in `backend/dap_commands.nim`'s allow-list and has
## exactly the call sites a grep over the ViewModel layer shows: two test files
## and no ViewModel. `store/types.nim` has no frame type — `CallLine` is a
## calltrace row and `DebuggerState` carries one `Location`.
##
## So this pane takes its frames as a VALUE, exactly as CTUI-5's source pane
## takes its breakpoints as a value for the same class of reason
## (`PointListVM.points` is never filled from a backend response), and
## `call_stack_binding.framesFromStackTrace` converts the engine's own answer.
## `CalltraceVM` still owns what it really owns: the SELECTION
## (`selectedEntry`) and the expand/collapse set (`expandedNodes`), which is
## where the binding puts the inspection cursor.
##
## ## Recursion is collapsed by CONSECUTIVE IDENTITY, not by name alone
##
## A run of frames collapses when it is at least `RecursionGroupMinimum` long
## and every member shares BOTH the function name and the path. Name alone
## would fuse two different `run` methods from two modules into one group and
## report a recursion depth that never happened.
##
## The group row reports its count, which is CTUI-6's contract for it, and the
## row is bounded: 49 recursive frames are one row until they are expanded.
## Expanding keeps the header — so the group can be collapsed again from the
## keyboard — and lists its members after it.

import isonim_tui

import ../layout/profile
import ./frame_item
import ./hyperlinks
import ./styled_row

export frame_item, hyperlinks, styled_row, profile

type
  CallStackRowKind* = enum
    cskFrame
    cskGroup

  CallStackRow* = object
    ## One row of the pane, before it is painted.
    kind*: CallStackRowKind
    firstFrame*: int
      ## Index into `CallStackModel.frames`. For a group, its INNERMOST member —
      ## the one with the smallest DAP index, which is the one a reader means
      ## by "the recursion".
    count*: int
      ## 1 for `cskFrame`; the group's size for `cskGroup`.
    expanded*: bool
    depthInGroup*: bool
      ## This frame row is a member of an expanded group, so it is indented.

  CallStackModel* = object
    ## Everything the pane shows, as a value.
    frames*: seq[StackFrame]
      ## Innermost first, exactly as DAP `stackTrace` orders them.
    userRoots*: seq[string]
      ## Directories whose files are the recorded program's own. See
      ## `frame_item.classifyFrame`.
    executionFrame*: int
      ## The frame the debugger is stopped in. Always 0 in a DAP stack, and a
      ## FIELD rather than a constant because that is the fact the pane renders
      ## and a pane that assumed it would silently draw the wrong marker the day
      ## a host presents a stack starting elsewhere.
    selected*: int
      ## THE INSPECTION CURSOR: which frame the source view is showing. Index
      ## into `frames`. Moving it must never move the debugger, which is
      ## CTUI-6's contract and what `test_call_stack_navigation.nim` asserts
      ## against `DebugControlsVM`.
    expandedGroups*: seq[int]
      ## `firstFrame` of each expanded group.
    scrollTop*: int
      ## First visible ROW (not frame): a collapsed group is one row.
    threadName*: string
      ## What DAP `threads` calls the thread this stack belongs to.
    threadCount*: int
      ## How many threads the backend reported. §3.3.3: "In single-threaded
      ## traces, automatically collapses to show the call tree directly" — so
      ## the pane names the thread in its title and shows no selector.
      ##
      ## THERE IS NO THREAD SELECTOR IN THIS CAMPAIGN, and it is cut rather than
      ## unimplemented: no recorder in this workspace produces a recording whose
      ## DAP `threads` reports more than one entry (CTUI-1's "Verification
      ## 2026-09-05", re-measured for CTUI-6 and reproduced in
      ## `tests/test_multi_thread_selection.nim`, which fails the day the count
      ## exceeds one). A selector shipped now would be a control nothing could
      ## drive and no test could exercise.

  CallStackScreen* = object
    ## One painted pane, plus the counts and coordinates a test asserts on.
    rows*: seq[StyledRow]
    area*: CellArea
    visible*: seq[CallStackRow]
      ## The rows actually painted, in order, one per body row that has one.
    bodyHeight*: int
    indexWidth*: int
    links*: seq[PaneHyperlink]
      ## OSC 8 targets over each visible frame's location field, in SCREEN
      ## coordinates. See `app/views/hyperlinks.nim`.
    frameRows*: int
    groupRows*: int
    totalRows*: int
      ## Rows the model has, visible or not. What `scrollTop` is bounded by.

const
  CallStackTitle* = "CALL STACK"
    ## Contains the string CTUI-3's own pane title produced
    ## (`shell.paneTitle(paneCalltrace)` uppercased), so every CTUI-3 and CTUI-5
    ## assertion that reads `CALL STACK` off a shell row still reads it once
    ## this pane fills that rectangle.
  PaneRule* = "─"
  RecursionGroupMinimum* = 3
    ## The shortest run that collapses. Two identical frames are an ordinary
    ## call of a helper by itself and reading `2 x f` costs a reader more than
    ## reading two rows; three is where a stack starts to be about the
    ## recursion rather than about the calls.
  GroupMemberIndent* = 1
    ## Cells an expanded group's members have their NAME indented by, so the
    ## header and its members are distinguishable in a plaintext read. The
    ## marker columns are never indented — see `frame_item.FrameRowSpec.indent`.

  TitleStyle* = CellStyle(fg: "white", bold: true)
  ThreadStyle* = CellStyle(fg: "bright_black")
  RuleStyle* = CellStyle(fg: "bright_black")
  EmptyStackText* = "no frames reported"
  EmptyStackStyle* = CellStyle(fg: "bright_black", italic: true)

proc initCallStackModel*(frames: seq[StackFrame] = @[];
                         userRoots: seq[string] = @[];
                         executionFrame = 0; selected = 0;
                         expandedGroups: seq[int] = @[];
                         scrollTop = 0;
                         threadName = ""; threadCount = 0): CallStackModel =
  CallStackModel(
    frames: frames, userRoots: userRoots, executionFrame: executionFrame,
    selected: selected, expandedGroups: expandedGroups, scrollTop: scrollTop,
    threadName: threadName, threadCount: threadCount)

proc isEmpty*(model: CallStackModel): bool =
  ## Whether the pane has a stack at all. A model with no frames is a session
  ## that has not stopped anywhere yet, and the shell leaves the rectangle to
  ## CTUI-3's plain title row for it.
  model.frames.len == 0

proc frameAt*(model: CallStackModel; index: int): StackFrame =
  ## The frame at `index`, or a zero frame outside the stack. Every caller here
  ## computes its index from the model's own geometry; the clamp exists so a
  ## test that reads past the end gets an answer rather than a crash.
  if index >= 0 and index < model.frames.len: model.frames[index]
  else: StackFrame(index: -1, line: 0)

proc originOf*(model: CallStackModel; index: int): FrameOrigin =
  classifyFrame(model.frameAt(index).path, model.userRoots)

proc isExpanded*(model: CallStackModel; firstFrame: int): bool =
  firstFrame in model.expandedGroups

# ---------------------------------------------------------------------------
# Runs and rows
# ---------------------------------------------------------------------------

proc recursionRuns*(frames: openArray[StackFrame]): seq[(int, int)] =
  ## Every maximal run of `RecursionGroupMinimum` or more CONSECUTIVE frames
  ## sharing a name and a path, as `(firstIndex, count)`.
  ##
  ## Exposed so a test can assert the runs the grouping is derived from
  ## separately from the rows it produces — a pane that grouped correctly for
  ## the wrong reason and a pane that grouped wrongly are otherwise the same
  ## screen.
  result = @[]
  var i = 0
  while i < frames.len:
    var j = i + 1
    while j < frames.len and frames[j].name == frames[i].name and
          frames[j].path == frames[i].path:
      inc j
    if j - i >= RecursionGroupMinimum:
      result.add (i, j - i)
    i = j

proc paneRows*(model: CallStackModel): seq[CallStackRow] =
  ## Every row the pane would show if it were tall enough, in order.
  ##
  ## A collapsed group is ONE row. An expanded group is its header row followed
  ## by one row per member, which is what "expanding the group yields the
  ## individual frames" means and what keeps a group collapsible again once
  ## opened.
  result = @[]
  let runs = recursionRuns(model.frames)
  var runAt = 0
  var i = 0
  while i < model.frames.len:
    if runAt < runs.len and runs[runAt][0] == i:
      let (first, count) = runs[runAt]
      let open = model.isExpanded(first)
      result.add CallStackRow(kind: cskGroup, firstFrame: first, count: count,
                              expanded: open)
      if open:
        for k in 0 ..< count:
          result.add CallStackRow(kind: cskFrame, firstFrame: first + k,
                                  count: 1, expanded: false,
                                  depthInGroup: true)
      inc runAt
      i = first + count
    else:
      result.add CallStackRow(kind: cskFrame, firstFrame: i, count: 1)
      inc i

proc rowOfFrame*(rows: openArray[CallStackRow]; frame: int): int =
  ## The row that REPRESENTS `frame` — itself, or the collapsed group holding
  ## it. -1 when the frame is not in the stack.
  result = -1
  for i, row in rows:
    case row.kind
    of cskFrame:
      if row.firstFrame == frame:
        return i
    of cskGroup:
      # An EXPANDED group's header represents no frame: every member has its own
      # row further down, and returning the header here would make `j` from the
      # header jump over the member it just opened.
      if not row.expanded and frame >= row.firstFrame and
         frame < row.firstFrame + row.count:
        return i

proc frameOfRow*(rows: openArray[CallStackRow]; row: int): int =
  ## The frame a row stands for: itself, or a group's innermost member. -1 when
  ## the row does not exist.
  if row < 0 or row >= rows.len:
    return -1
  rows[row].firstFrame

proc groupContaining*(model: CallStackModel; frame: int): int =
  ## The `firstFrame` of the group holding `frame`, or -1.
  result = -1
  for (first, count) in recursionRuns(model.frames):
    if frame >= first and frame < first + count:
      return first

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc titleRowSpans*(model: CallStackModel; width: int): StyledRow =
  ## `CALL STACK 51 frame(s) <thread 1> ────`.
  ##
  ## The frame COUNT is in the title because it is the number CTUI-6's
  ## navigation test asserts the backend reported, and a reader comparing the
  ## pane against a `stackTrace` response should not have to count rows —
  ## especially when a recursion is collapsed and the rows are fewer than the
  ## frames.
  result = @[]
  if width <= 0:
    return
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: CallStackTitle, style: TitleStyle)
  parts.add StyledSpan(text: " " & $model.frames.len & " frame(s)",
                       style: ThreadStyle)
  if model.threadName.len > 0:
    parts.add StyledSpan(text: " " & model.threadName, style: ThreadStyle)
  var used = 0
  for part in parts:
    if used >= width:
      break
    let fitted = truncateToCells(part.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: part.style)
    used += cellWidthOf(fitted)
  if used < width:
    result.add StyledSpan(text: " ", style: DefaultCellStyle)
    inc used
  if used < width:
    result.add StyledSpan(text: repeatGlyph(PaneRule, width - used),
                          style: RuleStyle)

proc titleRowText*(model: CallStackModel; width: int): string =
  rowText(titleRowSpans(model, width))

proc rowSpecFor*(model: CallStackModel; row: CallStackRow;
                 indexWidth, width: int): FrameRowSpec =
  ## The `frame_item` spec for one row of this model.
  ##
  ## The one place that decides which markers a row carries, so "the execution
  ## marker is on the execution frame" and "the cursor is on the selected
  ## frame" are one rule rather than two copies of it.
  let frame = model.frameAt(row.firstFrame)
  case row.kind
  of cskFrame:
    FrameRowSpec(
      kind: frkFrame, index: frame.index, name: frame.name,
      path: frame.path, line: frame.line,
      origin: classifyFrame(frame.path, model.userRoots),
      isExecution: row.firstFrame == model.executionFrame,
      isInspected: row.firstFrame == model.selected,
      indent: (if row.depthInGroup: GroupMemberIndent else: 0),
      groupCount: 0, expanded: false,
      indexWidth: indexWidth, width: width)
  of cskGroup:
    FrameRowSpec(
      kind: frkGroup, index: frame.index, name: frame.name,
      path: frame.path, line: frame.line,
      origin: classifyFrame(frame.path, model.userRoots),
      # A COLLAPSED group carries the markers of every member it hides: the
      # execution frame is inside it, or the selection is. An EXPANDED group's
      # header carries neither, because the member row that owns them is on
      # screen and two markers for one fact is how a reader loses track of
      # which row the debugger is on.
      isExecution: not row.expanded and
                   model.executionFrame >= row.firstFrame and
                   model.executionFrame < row.firstFrame + row.count,
      isInspected: not row.expanded and
                   model.selected >= row.firstFrame and
                   model.selected < row.firstFrame + row.count,
      indent: 0,
      groupCount: row.count, expanded: row.expanded,
      indexWidth: indexWidth, width: width)

proc clampScrollTop*(scrollTop, totalRows, bodyHeight: int): int =
  ## The first visible row, clamped so the body never runs off either end.
  if scrollTop < 0: 0
  elif bodyHeight <= 0: 0
  elif totalRows <= bodyHeight: 0
  elif scrollTop > totalRows - bodyHeight: totalRows - bodyHeight
  else: scrollTop

proc scrollToSelection*(model: var CallStackModel; bodyHeight: int) =
  ## The smallest scroll that brings the selected row into the body.
  ##
  ## "Smallest" for the reason `source_vm.topFollowingCursor` gives: a pane that
  ## re-centred on every move would make one keystroke look like a jump.
  let rows = model.paneRows()
  let row = rowOfFrame(rows, model.selected)
  if row < 0 or bodyHeight <= 0:
    return
  if row < model.scrollTop:
    model.scrollTop = row
  elif row > model.scrollTop + bodyHeight - 1:
    model.scrollTop = row - bodyHeight + 1
  model.scrollTop = clampScrollTop(model.scrollTop, rows.len, bodyHeight)

proc paintCallStack*(g: var StyledGrid; area: CellArea;
                     model: CallStackModel): CallStackScreen =
  ## Paint the pane into `area` of `g`, and report what it painted.
  result = CallStackScreen(rows: @[], area: area, visible: @[],
                           bodyHeight: 0, indexWidth: 0, links: @[],
                           frameRows: 0, groupRows: 0, totalRows: 0)
  if area.width <= 0 or area.height <= 0:
    return

  let indexWidth = frameIndexWidth(model.frames.len)
  result.indexWidth = indexWidth

  var spanAt = area.col
  for span in titleRowSpans(model, area.width):
    g.paint(area.row, spanAt, span.text, span.style)
    spanAt += cellWidthOf(span.text)

  if area.height <= 1:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let bodyHeight = area.height - 1
  result.bodyHeight = bodyHeight
  let rows = model.paneRows()
  result.totalRows = rows.len

  if rows.len == 0:
    g.paint(area.row + 1, area.col,
            truncateToCells(EmptyStackText, area.width), EmptyStackStyle)
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let top = clampScrollTop(model.scrollTop, rows.len, bodyHeight)
  for i in 0 ..< bodyHeight:
    let rowIndex = top + i
    if rowIndex >= rows.len:
      break
    let screenRow = area.row + 1 + i
    let modelRow = rows[rowIndex]
    let item = frameItemRow(rowSpecFor(model, modelRow, indexWidth, area.width))
    var at = area.col
    for span in item.row:
      g.paint(screenRow, at, span.text, span.style)
      at += cellWidthOf(span.text)
    result.visible.add modelRow
    case modelRow.kind
    of cskFrame: inc result.frameRows
    of cskGroup: inc result.groupRows
    if item.locationCol >= 0 and item.locationWidth > 0:
      let frame = model.frameAt(modelRow.firstFrame)
      if frame.path.len > 0:
        result.links.add paneHyperlinkFor(
          frame.path, frame.line, screenRow,
          area.col + item.locationCol, item.locationWidth)

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc callStackScreen*(model: CallStackModel;
                      width, height: int): CallStackScreen =
  ## The pane on a screen of its own — the shape a Tier-1 test and the
  ## `app_call_stack` snapshot app both use.
  var g = newStyledGrid(width, height)
  let area = CellArea(col: 0, row: 0, width: width, height: height)
  result = paintCallStack(g, area, model)

proc callStackRows*(model: CallStackModel; width, height: int): seq[StyledRow] =
  callStackScreen(model, width, height).rows

proc callStackText*(model: CallStackModel; width, height: int): seq[string] =
  ## The pane as plain text, one string per row. What a Tier-2 `regionText`
  ## read is compared against.
  result = @[]
  for row in callStackRows(model, width, height):
    result.add rowText(row)

proc bodyRowForFrame*(screen: CallStackScreen; frame: int): int =
  ## The SCREEN row showing `frame`, or -1 when it is scrolled out.
  ##
  ## Derived from what was actually painted rather than recomputed from the
  ## model, so a test that clicks a row and a pane that painted it cannot
  ## disagree about which row that was.
  result = -1
  for i, row in screen.visible:
    let holds =
      case row.kind
      of cskFrame: row.firstFrame == frame
      of cskGroup: not row.expanded and frame >= row.firstFrame and
                   frame < row.firstFrame + row.count
    if holds:
      return screen.area.row + 1 + i

proc rowAtScreenRow*(screen: CallStackScreen; screenRow: int): int =
  ## Index into `screen.visible` for a screen row, or -1 outside the body.
  ##
  ## This is the mouse model of §4.4 ("clicking a call frame navigates the
  ## source view to that frame's call site") expressed as arithmetic a Tier-1
  ## test can check, so the Tier-2 case asserts the CLICK arrives rather than
  ## re-deriving where it should land.
  let i = screenRow - screen.area.row - 1
  if i < 0 or i >= screen.visible.len: -1 else: i

proc renderCallStackTree*(model: CallStackModel; r: TerminalRenderer;
                          width, height: int): TerminalNode =
  ## The pane as a component tree: one `div` per row, styled spans inside.
  styledRowsTree(r, callStackRows(model, width, height))
