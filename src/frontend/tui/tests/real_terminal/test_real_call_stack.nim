## test_real_call_stack.nim — CTUI-6, Tier 2.
##
## ## What only this file can say
##
## CTUI-6: "TermAssert: click a frame with `sendMouseClick(row, col)` and assert
## the source pane followed, which exercises §4.4's mouse model end to end and
## cannot be tested in process. Asserts frames render as OSC 8 hyperlinks via
## `hyperlinkAt`."
##
## Both, plus the §3.3.3 colours read back out of a real terminal's own cell
## model, plus the verification gate's ">50-frame stacks scroll without
## artifacts, verified by `regionText` over the scrolled region". Three of those
## are unobservable anywhere else (`docs/tui-testing.md`'s table): a real
## SGR-1006 byte sequence arriving on a real fd, OSC 8 hyperlinks — which are
## not represented in the `ScreenBuffer` at all — and the colours a terminal
## shows after its own state machine has parsed them.
##
## ## EVERY COLOUR HERE IS ASSERTED ABSOLUTELY, AND THAT IS A RULE
##
## `docs/tui-testing.md`, "What cross-tier equality cannot catch, and never
## will": a differential check compares two renderings of the SAME program, so
## it is blind by construction to any defect both tiers share. CTUI-5 measured
## that — a mutation that rendered provenance away kept `runDualSnap` at zero
## divergences and was caught only by `fg.idx == 3'u8`.
##
## CTUI-6's whole subject is a distinction between two cursors, so every glyph
## and colour this suite relies on for MEANING is asserted as a NUMBER:
## `bright_yellow` is 11 for the execution frame, `cyan` is 6 for the inspection
## cursor, `green` is 2 for the `usr` badge, `bright_black` is 8 for `lib`,
## `blue` is 4 for the execution line's background. The cross-tier case is the
## fourth in this file and asserts something else entirely: that the renderer is
## faithful.
##
## ## EVERY DRIVEN FRAME IS WAITED FOR BY NAME
##
## `waitForCompleteFrame` cannot be the barrier after an input: the cursor is
## already parked on the bottom-right cell from the PREVIOUS frame, so it
## returns immediately and the assertions would read the screen from before the
## click. The child therefore labels an input-driven repaint `<label>-stepN`
## (`testing/test_app_runtime.nim`, and CTUI-6 widened the step counter to any
## repaint the parent caused for exactly this reason), and every case here waits
## for the label of the frame it is about to read. No sleeps, no `waitForText`.
##
## ## The frames come from a constant, and the stack is `wide_state`'s shape
##
## `apps/app_call_stack.nim` paints 49 `descend` frames under `main` and
## `<module>` — the 51-frame stack CTUI-1 measured — plus ONE library frame no
## fixture in the corpus produces, so both arms of the user/library badge are on
## one real screen. See that app's header.
##
## ## It does not skip
##
## A missing grammar archive, a child that will not compile, a child that never
## finishes a frame, a label that never arrives: every one FAILS by name.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine.
##
## ## Templates, not procs, for anything that calls `check`

import std/[options, strutils, times, unicode, unittest]

import isonim_tui
import term_assert

import ../../app/input/call_stack_keys
import ../../app/views/call_stack
import ../../app/views/source_pane
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_call_stack as stackApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 137

const
  Cols = 90
  Rows = 46
    ## The Ultra-wide profile's `editor` rectangle at 200x60, from CTUI-3's
    ## measured table — tall enough to show the whole collapsed stack and short
    ## enough that the EXPANDED recursion cannot fit, which is the case the
    ## verification gate is about.
  Label = "call-stack"
  Stem = "app_call_stack"
  FrameTimeoutMs = 20000
  LabelTimeoutMs = 10000

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc describeCell(c: term_assert.Cell): string =
  var attrs: seq[string] = @[]
  for a in c.attrs:
    attrs.add $a
  "rune='" & (if c.rune.int32 == 0: " " else: $c.rune) & "' fg=" &
    (case c.fg.kind
     of ckDefault: "default"
     of ckIndexed: "indexed:" & $c.fg.idx
     of ckRgb: "rgb") &
    " bg=" &
    (case c.bg.kind
     of ckDefault: "default"
     of ckIndexed: "indexed:" & $c.bg.idx
     of ckRgb: "rgb") &
    " attrs={" & attrs.join(",") & "}"

proc paneRow(sess: var TuiTestSession; row, width: int): string =
  ## One row of the terminal, as text, from column 0.
  sess.regionText(row, 0, width, 1).split('\n')[0]

proc badgeColumn(indexWidth: int): int =
  ## The first cell of the badge field, from `frame_item`'s own layout: two
  ## marker columns, a space, the index field, a space.
  2 + 1 + indexWidth + 1

proc frameIndexToken(row: string): string =
  ## The `#N` token of a rendered frame row, or "".
  ##
  ## Found by SCANNING for the `#`, not by position: a selected row carries a
  ## cursor glyph before the index and an expanded group's members are
  ## indented, so a fixed column would read three different things on three
  ## rows of the same pane.
  for token in strutils.splitWhitespace(row):
    if token.startsWith("#"):
      return token
  ""

proc settledFrame(sess: var TuiTestSession; step: int): ScreenSnapshot =
  ## Wait for the frame the child declares final at `step`, by name.
  ##
  ## The cursor barrier first — it proves the pty has been consumed up to the
  ## end of SOME frame — then the capture handshake, which is what makes the
  ## answer the frame the child itself calls finished. See this module's header
  ## on why the barrier alone is not enough after an input.
  waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
  sess.send($TestAppCaptureByte)
  waitForSnapshotLabel(sess, stepLabel(Label, step), LabelTimeoutMs)

proc spawnChild(): TuiTestSession =
  compileChildApp(Stem)
  newTuiTest(appBinaryPath(Stem),
             @["--cols=" & $Cols, "--rows=" & $Rows,
               "--test-ipc", "--label=" & Label])
    .width(Cols).height(Rows)
    .spawn()

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkMarkerCells(sess: var TuiTestSession; row: int;
                          wantExecution, wantInspection: bool) =
  ## The two marker columns of one row, read out of the terminal.
  ##
  ## THE ASSERTION CTUI-6 IS ABOUT. Both cells are read on every call, so "the
  ## execution marker is here" and "the inspection cursor is NOT here" are
  ## asserted together — a pane that moved the execution marker along with the
  ## cursor would satisfy either one alone.
  let execCell = sess.cellAt(row, 0)
  let cursorCell = sess.cellAt(row, 1)
  checkpoint("row " & $row & " markers: exec " & describeCell(execCell) &
             ", cursor " & describeCell(cursorCell))
  if wantExecution:
    ck $execCell.rune == ExecutionFrameGlyph
    ck execCell.fg.kind == ckIndexed
    ck execCell.fg.idx == 11'u8        # `bright_yellow`
    ck caBold in execCell.attrs
  else:
    ck $execCell.rune != ExecutionFrameGlyph
    ck execCell.fg.kind == ckDefault
    ck caBold notin execCell.attrs
  if wantInspection:
    ck $cursorCell.rune == InspectedFrameGlyph
    ck cursorCell.fg.kind == ckIndexed
    ck cursorCell.fg.idx == 6'u8       # `cyan`
    ck caBold in cursorCell.attrs
  else:
    ck $cursorCell.rune != InspectedFrameGlyph
    ck cursorCell.fg.kind == ckDefault
    ck caBold notin cursorCell.attrs

template checkPaneMatchesModel(sess: var TuiTestSession;
                               expected: seq[string]; width: int;
                               label: string) =
  ## Every row of the pane, on the terminal, is the row the model says.
  var matched = 0
  var firstDiff = ""
  for i in 0 ..< Rows:
    let got = paneRow(sess, i, width)
    if got == expected[i]:
      inc matched
    elif firstDiff.len == 0:
      firstDiff = "row " & $i & ":\n  term:  '" & got & "'\n  model: '" &
        expected[i] & "'"
  if firstDiff.len > 0:
    checkpoint(label & " " & firstDiff)
  ck matched == Rows

suite "CTUI-6 Tier 2: the call stack pane on a real terminal":

  test "markers, badges and OSC 8 hyperlinks a terminal really parsed":
    var sess = spawnChild()
    try:
      let model = stackApp.initialModel()
      let screen = stackApp.screenFor(model, Cols, Rows)
      let stackWidth = stackApp.stackPaneWidth(Cols)
      ck screen.area.width == stackWidth
      # The collapsed stack: the recursion, `main`, `<module>`, the library
      # frame. Fifty-two frames in four rows, which is what the group is for.
      ck screen.totalRows == 4
      ck screen.links.len == screen.visible.len
      ck stackApp.sampleFrames().len == stackApp.RecursionDepth + 3

      # Nothing recorded yet: the child has painted and is waiting to be asked.
      # The positive control that every label below is an ANSWER rather than a
      # race the parent won.
      waitForCompleteFrame(sess, Cols, Rows, FrameTimeoutMs)
      ck sess.snapshots().len == 0
      sess.send($TestAppCaptureByte)
      let frame0 = waitForSnapshotLabel(sess, stepLabel(Label, 0),
                                        LabelTimeoutMs)
      ck frame0.label == Label
      ck frame0.rows == Rows
      ck frame0.cols == Cols

      # ---- the pane says what the model says, on a terminal ----------------
      checkPaneMatchesModel(sess, callStackText(model, stackWidth, Rows),
                            stackWidth, "initial")
      checkpoint("first four pane rows:\n" &
                 paneRow(sess, 0, stackWidth) & "\n" &
                 paneRow(sess, 1, stackWidth) & "\n" &
                 paneRow(sess, 2, stackWidth) & "\n" &
                 paneRow(sess, 3, stackWidth))
      ck paneRow(sess, 0, stackWidth).contains(CallStackTitle)
      ck paneRow(sess, 0, stackWidth).contains("<thread 1>")

      # ---- THE TWO CURSORS, ABSOLUTELY ------------------------------------
      # Row 1 is the collapsed recursion, which holds BOTH the execution frame
      # and the selection; row 2 is `main`, which holds neither.
      checkMarkerCells(sess, 1, wantExecution = true, wantInspection = true)
      checkMarkerCells(sess, 2, wantExecution = false, wantInspection = false)

      # ---- §3.3.3's user/library badge, in a terminal's own colours --------
      let badgeCol = badgeColumn(screen.indexWidth)
      let userBadge = sess.cellAt(2, badgeCol)
      let libraryBadge = sess.cellAt(4, badgeCol)
      checkpoint("usr badge " & describeCell(userBadge) & ", lib badge " &
                 describeCell(libraryBadge))
      ck $userBadge.rune == "u"
      ck userBadge.fg.kind == ckIndexed
      ck userBadge.fg.idx == 2'u8        # `green`
      ck $libraryBadge.rune == "l"
      ck libraryBadge.fg.kind == ckIndexed
      ck libraryBadge.fg.idx == 8'u8     # `bright_black`
      # THE WHOLE POINT, as one assertion: the two badges do not look the same.
      ck userBadge.fg.idx != libraryBadge.fg.idx
      ck paneRow(sess, 4, stackWidth).contains(LibraryBadge)
      ck paneRow(sess, 2, stackWidth).contains(UserBadge)

      # ---- the collapsed group reports its count ---------------------------
      let groupRow = paneRow(sess, 1, stackWidth)
      # The COUNT and the NAME, not `groupLabel(...)`: an expectation built by
      # the function under test moves with it, which a mutation arm on the
      # Tier-1 side proved by staying green.
      ck groupRow.contains($stackApp.RecursionDepth)
      ck groupRow.contains("descend")
      ck frameIndexToken(groupRow) == "#0"
      # THE EXPANDER IS ITS OWN COLUMN, so a collapsed group can carry it AND
      # the execution marker. Asserted absolutely, because the two would be
      # indistinguishable in a differential check that painted `+` in both
      # tiers at column 0.
      let expander = sess.cellAt(1, 2)
      checkpoint("expander cell " & describeCell(expander))
      ck $expander.rune == GroupCollapsedGlyph
      ck expander.fg.kind == ckIndexed
      ck expander.fg.idx == 5'u8         # `magenta`
      ck $sess.cellAt(2, 2).rune == NoMarkerGlyph

      # ---- OSC 8 HYPERLINKS, WHICH THE ScreenBuffer CANNOT REPRESENT -------
      # The link covers the location field of every visible frame row. Asserted
      # at BOTH ENDS of the field and one cell before it, because a link whose
      # extent was one cell off would answer correctly at its start and be wrong
      # at the end a user actually clicks.
      let link = screen.links[0]
      ck link.width > 0
      let atStart = sess.hyperlinkAt(link.row, link.col)
      let atEnd = sess.hyperlinkAt(link.row, link.col + link.width - 1)
      let before = sess.hyperlinkAt(link.row, link.col - 1)
      checkpoint("link at row " & $link.row & " cols " & $link.col & ".." &
                 $(link.col + link.width - 1) & " -> " &
                 (if atStart.isSome: atStart.get.uri else: "<none>"))
      ck atStart.isSome
      ck atStart.get.uri == "file://" & stackApp.SamplePath & "#L" &
                            $stackApp.RecursionLine
      ck atEnd.isSome
      ck atEnd.get.uri == atStart.get.uri
      # THE NEGATIVE TWIN, through the same reader: the cell before the field
      # carries no link, so "every cell has a link" cannot pass for "the
      # location field has a link".
      ck before.isNone
      # …and every visible frame row is linked, to ITS OWN line.
      var linkedRows = 0
      var wrongLinks: seq[string] = @[]
      for l in screen.links:
        let got = sess.hyperlinkAt(l.row, l.col)
        if got.isSome and got.get.uri == l.url:
          inc linkedRows
        else:
          wrongLinks.add "row " & $l.row & " expected " & l.url & " got " &
            (if got.isSome: got.get.uri else: "<none>")
      if wrongLinks.len > 0:
        checkpoint(wrongLinks.join("\n"))
      ck linkedRows == screen.links.len
      ck linkedRows == 4
      # More than one DISTINCT url — the recursion's line and `main`'s — so the
      # links are per-frame rather than one link repeated across the pane.
      var distinctUrls: seq[string] = @[]
      for l in screen.links:
        if l.url notin distinctUrls:
          distinctUrls.add l.url
      ck distinctUrls.len == 4
      ck sess.hyperlinks().len == distinctUrls.len

      # ---- the source pane beside it, with the execution pointer -----------
      let sourceModel = stackApp.sourceModelFor(model, Rows - 1)
      let sourceText = sourcePaneText(sourceModel, Cols - stackWidth, Rows)
      let sourceRow = 1 + sourceModel.executionLine - sourceModel.viewportTop
      ck sourceModel.executionLine == stackApp.RecursionLine
      ck sess.regionText(sourceRow, stackWidth, Cols - stackWidth, 1)
             .split('\n')[0] == sourceText[sourceRow]
      ck sourceText[sourceRow].contains(ExecutionPointerGlyph)

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "a real mouse click moves the inspection cursor and the source follows":
    var sess = spawnChild()
    try:
      var model = stackApp.initialModel()
      let screen = stackApp.screenFor(model, Cols, Rows)
      let stackWidth = stackApp.stackPaneWidth(Cols)
      discard settledFrame(sess, 0)

      # `main` is the row after the collapsed group. Its screen row comes from
      # the pane's own paint, not from a constant.
      let mainFrame = stackApp.RecursionDepth
      let targetRow = bodyRowForFrame(screen, mainFrame)
      ck targetRow == 2
      ck stackApp.sampleFrames()[mainFrame].name == "main"
      checkMarkerCells(sess, targetRow, wantExecution = false,
                       wantInspection = false)

      # THE CLICK. Real SGR-1006 bytes on a real fd, which is the whole reason
      # this case cannot be a Tier-1 one. Column 6 is inside the pane and inside
      # no field a click means anything else in.
      sess.sendMouseClick(targetRow, 6)
      discard settledFrame(sess, 1)

      # THE INSPECTION CURSOR MOVED TO THE CLICKED ROW…
      checkMarkerCells(sess, targetRow, wantExecution = false,
                       wantInspection = true)
      # …AND THE EXECUTION MARKER DID NOT. CTUI-6's contract on a real terminal:
      # the debugger is still in the recursion and the group row still says so.
      checkMarkerCells(sess, 1, wantExecution = true, wantInspection = false)

      # THE SOURCE PANE FOLLOWED. The model a click produces, computed here by
      # the same pure function the child ran — `applyKey` over the same bytes
      # `sendMouseClick` wrote, which is what makes the comparison a statement
      # about the app rather than about two hand-written screens.
      let clickBytes = "\x1b[<0;7;" & $(targetRow + 1) & "M"
      ck model.applyKey(clickBytes, screen) == csaSelectionMoved
      ck model.selected == mainFrame
      let followed = stackApp.sourceModelFor(model, Rows - 1)
      ck followed.inspectionLine == stackApp.MainLine
      ck followed.executionLine == stackApp.RecursionLine
      let sourceText = sourcePaneText(followed, Cols - stackWidth, Rows)
      var sourceMatched = 0
      var firstDiff = ""
      for i in 0 ..< Rows:
        let got = sess.regionText(i, stackWidth, Cols - stackWidth, 1)
                      .split('\n')[0]
        if got == sourceText[i]:
          inc sourceMatched
        elif firstDiff.len == 0:
          firstDiff = "source row " & $i & ":\n  term:  '" & got &
            "'\n  model: '" & sourceText[i] & "'"
      if firstDiff.len > 0:
        checkpoint(firstDiff)
      ck sourceMatched == Rows

      # BOTH CURSORS, ON ONE REAL SCREEN, IN TWO GLYPHS AND TWO COLOURS.
      let inspectionRow = 1 + followed.inspectionLine - followed.viewportTop
      let executionRow = 1 + followed.executionLine - followed.viewportTop
      ck inspectionRow != executionRow
      let gutter = sourcePaneScreen(followed, Cols - stackWidth, Rows)
      let pointerCol = stackWidth + gutter.gutterWidth -
                       GutterPointerCells - GutterGapCells
      let inspectionCell = sess.cellAt(inspectionRow, pointerCol + 1)
      let executionCell = sess.cellAt(executionRow, pointerCol)
      checkpoint("inspection pointer " & describeCell(inspectionCell) &
                 ", execution pointer " & describeCell(executionCell))
      ck $inspectionCell.rune == ">"
      ck inspectionCell.fg.kind == ckIndexed
      ck inspectionCell.fg.idx == 6'u8      # `cyan`
      ck caBold in inspectionCell.attrs
      ck $executionCell.rune == "-"
      ck executionCell.fg.kind == ckIndexed
      ck executionCell.fg.idx == 11'u8      # `bright_yellow`
      # …and the execution line still carries its background highlight, which
      # the inspection line does not. TWO DIFFERENT NUMBERS is what "rendered
      # distinctly" means to a reader looking at a screen rather than at a
      # style struct.
      ck executionCell.bg.kind == ckIndexed
      ck executionCell.bg.idx == 4'u8       # `blue`
      ck not (inspectionCell.bg.kind == ckIndexed and
              inspectionCell.bg.idx == 4'u8)
      ck inspectionCell.fg.idx != executionCell.fg.idx

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "a >50-frame stack expands and scrolls without artifacts":
    ## CTUI-6's verification gate: ">50-frame stacks scroll without artifacts,
    ## verified at Tier 2 by `regionText` over the scrolled region."
    var sess = spawnChild()
    try:
      let stackWidth = stackApp.stackPaneWidth(Cols)
      var model = stackApp.initialModel()
      discard settledFrame(sess, 0)

      # EXPAND, with a real key.
      sess.send(KeyToggleGroup)
      discard settledFrame(sess, 1)
      ck model.applyKey(KeyToggleGroup,
                        stackApp.screenFor(model, Cols, Rows)) == csaGroupToggled
      ck model.isExpanded(0)
      ck model.paneRows().len == stackApp.RecursionDepth + 4
      # The expanded stack does NOT fit the body, which is what makes the scroll
      # below a scroll rather than a repaint.
      ck model.paneRows().len > Rows - 1
      checkPaneMatchesModel(sess, callStackText(model, stackWidth, Rows),
                            stackWidth, "expanded")
      # The expander flipped, in its own column, on a real terminal.
      let openExpander = sess.cellAt(1, 2)
      checkpoint("expanded expander cell " & describeCell(openExpander))
      ck $openExpander.rune == GroupExpandedGlyph
      ck openExpander.fg.idx == 5'u8

      # SCROLL, with a real wheel event, and read the SCROLLED REGION back.
      sess.sendMouseScroll(10, 4, sdDown)
      discard settledFrame(sess, 2)
      ck model.applyKey("\x1b[<65;5;11M",
                        stackApp.screenFor(model, Cols, Rows)) == csaScrolled
      ck model.scrollTop == WheelScrollRows
      checkPaneMatchesModel(sess, callStackText(model, stackWidth, Rows),
                            stackWidth, "scrolled")

      # THE SCROLLED REGION SAYS WHICH FRAMES IT IS SHOWING, as the exact `#N`
      # sequence: a scroll that skipped a row, repeated one, or left a stale row
      # behind fails here and nowhere else.
      var indices: seq[string] = @[]
      for i in 1 .. 5:
        indices.add frameIndexToken(paneRow(sess, i, stackWidth))
      checkpoint("scrolled region frame indices: " & $indices)
      ck indices == @["#2", "#3", "#4", "#5", "#6"]
      # …and the body is painted to its end with no blank row in the middle: an
      # artifact on a terminal repainted from a stale model looks exactly like a
      # gap.
      var painted = 0
      for i in 1 ..< Rows:
        if paneRow(sess, i, stackWidth).strip().len > 0:
          inc painted
      let visibleRows = min(Rows - 1, model.paneRows().len - model.scrollTop)
      checkpoint("painted body rows " & $painted & " of " & $visibleRows)
      ck painted == visibleRows
      ck visibleRows == Rows - 1

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
    finally:
      sess.terminate()
      sess.close()

  test "cross-tier snapshot equality grounds the pane's Tier-1 goldens":
    # docs/tui-testing.md: "a new pane needs exactly one cross-tier equivalence
    # test. Not zero, and not one per assertion." This is the call stack pane's,
    # at CTUI-2's two geometries, through the SAME `buildTree` both tiers run.
    var checkedCases = 0
    for g in [(cols: 80, rows: 24), (cols: Cols, rows: Rows)]:
      let res = runDualSnap(Stem, stackApp.buildTree, g.cols, g.rows)
      inc checkedCases
      if res.divergences.len > 0:
        checkpoint(report(res))
      ck res.divergences.len == 0
      # THE NON-VACUITY FLOOR, as the EXACT painted-cell count rather than "more
      # than none": a screen the two tiers agree is blank would satisfy the
      # equality above for free. The number is knowable because the tree is a
      # pure function of the geometry.
      let canon = canonFromDir(res.tier1Dir)
      let painted = countCellsWhere(canon, proc(c: CanonCell): bool =
        c.rune != " " and c.rune.len > 0)
      var modelPainted = 0
      let stackWidth = stackApp.stackPaneWidth(g.cols)
      let model = stackApp.initialModel()
      for line in callStackText(model, stackWidth, g.rows):
        for r in line.runes:
          if $r != " ":
            inc modelPainted
      for line in sourcePaneText(stackApp.sourceModelFor(model, g.rows - 1),
                                 g.cols - stackWidth, g.rows):
        for r in line.runes:
          if $r != " ":
            inc modelPainted
      checkpoint("app_call_stack at " & $g.cols & "x" & $g.rows & ": " &
                 $painted & " painted cell(s) of " &
                 $(canon.rows * canon.cols) & ", model says " & $modelPainted)
      ck painted == modelPainted
      ck painted > 0
      # And the two tiers really are two tiers — `compareSnapshotDirs` refuses a
      # directory compared with itself, which is the vacuous pass this whole
      # construction exists to prevent.
      ck canon.dialect == "tier1-isonim-tui"
      ck canonFromDir(res.tier2Dir).dialect == "tier2-libvterm"
    ck checkedCases == 2

  test "the hyperlink emitter is the production encoder, byte for byte":
    ## `app/views/hyperlinks.frameBytesWithHyperlinks` walks the composited
    ## buffer the same way `isonim_tui`'s `encodeAnsi` does and re-glues rows the
    ## same way `testing/test_app_runtime.frameBytes` does. A second encoder that
    ## DRIFTED from the first would make every cross-tier comparison a comparison
    ## of two different programs — so the identity is asserted rather than
    ## described.
    ##
    ## This case needs no terminal and would belong in the Tier-1 lane, except
    ## that `frameBytes` lives in `testing/`, which imports `term_assert_client`,
    ## whose `--path` only this lane carries (`docs/tui-testing.md`, "Running
    ## it"). It is here for that reason and no other.
    let h = newTerminalTestHarness(Cols, Rows)
    var plain = ""
    var linked = ""
    let links = stackApp.frameLinks(Cols, Rows)
    try:
      h.mount(proc(r: TerminalRenderer): TerminalNode =
        stackApp.buildTree(r, Cols, Rows, 0))
      h.flush()
      plain = frameBytes(h.driver.buffer)
      linked = frameBytesWithHyperlinks(h.driver.buffer, links)
      ck frameBytesWithHyperlinks(h.driver.buffer, @[]) == plain
    finally:
      h.dispose()

    ck links.len == 4
    ck linked.len > plain.len
    # Stripping every OSC 8 sequence out of the linked stream yields the plain
    # one EXACTLY: the links add escapes and change no cell, no colour and no
    # position.
    var stripped = ""
    var i = 0
    var opens = 0
    var closes = 0
    while i < linked.len:
      if linked.continuesWith(Osc8Start, i):
        let stop = linked.find(Osc8Terminator, i)
        ck stop > 0
        if linked.continuesWith(Osc8Start & Osc8Terminator, i): inc closes
        else: inc opens
        i = stop + Osc8Terminator.len
      else:
        stripped.add linked[i]
        inc i
    checkpoint("opens " & $opens & ", closes " & $closes & ", stripped " &
               $stripped.len & " of " & $linked.len & " bytes against " &
               $plain.len)
    ck stripped == plain
    ck opens == links.len
    ck closes == opens
    # …and the URL a terminal will see is the one the pane computed.
    ck linked.contains(osc8Open(links[0].url))

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
