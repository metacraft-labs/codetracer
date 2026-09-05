## app_call_stack.nim — CTUI-6 snapshot app: the call stack pane beside the
## source pane.
##
## One component tree, exported so the Tier-1 half of
## `tests/real_terminal/test_real_call_stack.nim` composites the SAME proc in
## process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime, the frame barrier, the input
## framing and the OSC 8 emission.
##
## ## THE SCREEN SHOWS BOTH PANES, AND THAT IS THE POINT
##
## CTUI-6's contract is a relationship BETWEEN two panes: selecting an outer
## frame moves the inspection cursor and the source view follows it, while the
## execution pointer stays where the debugger is. A screen with only the call
## stack on it could not settle that on a real terminal — a click would move a
## marker and nothing would corroborate that the source followed. So the call
## stack is painted on the left and the source pane on the right, and the
## Tier-2 case clicks a frame in one and reads the other.
##
## ## The stack is the SHAPE `wide_state` really produces
##
## 49 `descend` frames, then `main`, then `<module>` — which is exactly the
## 51-frame stack CTUI-1 measured and this milestone's recursion suite asserts
## against a real trace (`main.py:81`, `main.py:95`, `main.py:1`). One frame is
## ADDED that no fixture in the corpus produces: a library frame under
## `/nix/store/…/lib/python3.12/runpy.py`, so that both arms of §3.3.3's
## "library code vs. user application code" badge are on one real screen. That
## asymmetry is deliberate and is recorded in `app/views/frame_item.nim`'s
## header: no recorder in this workspace yet produces a trace whose stack enters
## a library, so the library arm has no fixture and would otherwise be rendered
## by nothing.
##
## ## THE TIER-1 HALF MUST NOT DRIVE INPUT
##
## `buildTree` reads `currentModel`, which the CHILD's input handler mutates.
## `runDualSnap`'s Tier-1 half runs in the test process and must therefore see
## the pristine `initialModel()` — which it does, because no suite calls
## `handleInput` in process. A test that did would compare a driven Tier-1
## screen against an undriven Tier-2 one, which is the "two different programs"
## failure `dual_snap.newestSourceTime`'s header is about, arriving by a
## different door.

import isonim_tui

import ../../app/input/call_stack_keys
import ../../app/views/call_stack
import ../../app/views/source_pane

const
  SamplePath* = "/opt/ctui6/sample/main.py"
  LibraryPath* = "/nix/store/9r2c1v/lib/python3.12/runpy.py"
  SampleRoot* = "/opt/ctui6/sample"
  SampleLineCount* = 110
  RecursionDepth* = 49
    ## The 49 `descend` frames CTUI-1 measured on `wide_state`, so the pane on a
    ## real terminal is showing the shape a real recursion produces.
  RecursionLine* = 81
  MainLine* = 95
  ModuleLine* = 1
  LibraryLine* = 198

  StackPaneWidth* = 46
    ## Wide enough for `* > #50 usr <module>()   main.py:1` plus the rule, and
    ## narrow enough to leave the source pane a readable column at 80.

proc buildSampleLines(): seq[string] =
  ## A deterministic 110-line Python-shaped file. Built rather than written out
  ## because the pane's assertions are about line NUMBERS — the frames point at
  ## 81, 95 and 1 — and a hand-written sample would have to be recounted every
  ## time a line moved.
  result = @[]
  for i in 1 .. SampleLineCount:
    if i == ModuleLine:
      result.add "# ctui6 sample program"
    elif i == RecursionLine - 1:
      result.add "def descend(depth):"
    elif i == RecursionLine:
      result.add "    return descend(depth - 1) if depth > 0 else 0"
    elif i == MainLine - 1:
      result.add "def main():"
    elif i == MainLine:
      result.add "    print(descend(49))"
    else:
      result.add "value_" & $i & " = " & $i

const SampleLines* = buildSampleLines()

proc sampleFrames*(): seq[StackFrame] =
  ## The 52-frame stack this app paints.
  result = @[]
  for i in 0 ..< RecursionDepth:
    result.add StackFrame(index: i, id: 100 - i, name: "descend",
                          path: SamplePath, line: RecursionLine)
  result.add StackFrame(index: RecursionDepth, id: 2, name: "main",
                        path: SamplePath, line: MainLine)
  result.add StackFrame(index: RecursionDepth + 1, id: 1, name: "<module>",
                        path: SamplePath, line: ModuleLine)
  result.add StackFrame(index: RecursionDepth + 2, id: 0, name: "_run_module",
                        path: LibraryPath, line: LibraryLine)

proc initialModel*(): CallStackModel =
  ## The pane as the app opens: the recursion collapsed, the inspection cursor
  ## on the execution frame.
  initCallStackModel(
    frames = sampleFrames(),
    userRoots = @[SampleRoot],
    executionFrame = 0,
    selected = 0,
    threadName = "<thread 1>",
    threadCount = 1)

proc sourceModelFor*(model: CallStackModel; viewportHeight: int):
    SourcePaneModel =
  ## The source pane beside the stack, for whichever frame is inspected.
  ##
  ## THE EXECUTION POINTER IS DRAWN ONLY IN THE FILE THE DEBUGGER IS IN, which
  ## is `app/call_stack_binding.sourcePaneModelForFrame`'s rule reproduced here
  ## against a constant model — the app must not depend on a ViewModel, and the
  ## rule is the thing the Tier-2 case is reading.
  let frame = model.frameAt(model.selected)
  let executionFrame = model.frameAt(model.executionFrame)
  let showsExecution = frame.path == executionFrame.path
  let hasText = frame.path == SamplePath
  let total = if hasText: SampleLineCount else: 0
  var top = 1
  if total > 0:
    top = max(1, frame.line - viewportHeight div 2)
    if top > total - viewportHeight + 1:
      top = max(1, total - viewportHeight + 1)
  initSourcePaneModel(
    path = frame.path,
    provenance = (if hasText: gpVerified else: gpAbsent),
    firstHeldLine = 1,
    heldLines = (if hasText: SampleLines else: @[]),
    totalLineCount = total,
    viewportTop = top,
    executionLine = (if showsExecution and hasText: executionFrame.line else: 0),
    inspectionLine = frame.line)

var currentModel = initialModel()
var lastCols = 80
var lastRows = 24

proc stackPaneWidth*(cols: int): int =
  min(StackPaneWidth, max(10, cols div 2))

proc paint(g: var StyledGrid; model: CallStackModel;
           cols, rows: int): CallStackScreen =
  let stackWidth = stackPaneWidth(cols)
  result = paintCallStack(
    g, CellArea(col: 0, row: 0, width: stackWidth, height: rows), model)
  discard paintSourcePane(
    g, CellArea(col: stackWidth, row: 0, width: cols - stackWidth,
                height: rows),
    sourceModelFor(model, max(1, rows - 1)))

proc screenFor*(model: CallStackModel; cols, rows: int): CallStackScreen =
  ## The call stack pane's screen at this geometry — what a click resolves
  ## through, and where the OSC 8 links are.
  var g = newStyledGrid(cols, rows)
  paint(g, model, cols, rows)

proc treeFor*(r: TerminalRenderer; model: CallStackModel;
              cols, rows: int): TerminalNode =
  var g = newStyledGrid(cols, rows)
  discard paint(g, model, cols, rows)
  var rowsOut: seq[StyledRow] = @[]
  for row in 0 ..< rows:
    rowsOut.add g.rowSpans(row)
  styledRowsTree(r, rowsOut)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## The whole screen. `step` is ignored: this app is driven by real keys and
  ## real mouse reports, not by F10, and a builder that ignores its step
  ## paints the same tree however often F10 arrives (see
  ## `testing/test_app_runtime.nim`'s `SteppedTreeBuilder`).
  lastCols = cols
  lastRows = rows
  treeFor(r, currentModel, cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  ## The un-stepped shape, for `runDualSnap`'s sized overload.
  buildTree(r, cols, rows, 0)

proc handleInput*(token: string): bool =
  ## One input token from the runtime. Returns whether to repaint.
  ##
  ## CHILD-SIDE ONLY: see this module's header on why no Tier-1 half may call
  ## this.
  let screen = screenFor(currentModel, lastCols, lastRows)
  currentModel.applyKey(token, screen) != csaNone

proc frameLinks*(cols, rows: int): seq[PaneHyperlink] =
  ## Where the OSC 8 links go on the frame about to be painted.
  screenFor(currentModel, cols, rows).links

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an unused
  # runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams(),
    input = handleInput,
    links = frameLinks))
