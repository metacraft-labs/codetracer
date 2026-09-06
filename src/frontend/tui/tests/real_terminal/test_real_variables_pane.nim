## test_real_variables_pane.nim — CTUI-7, Tier 2.
##
## ## What only this file can say
##
## CTUI-7: "TermAssert: asserts the `[MOD]` row's real foreground/background via
## `cellAt`, which is the only way to prove the highlight is visible rather than
## merely set. Cross-tier `snap` equality."
##
## Both, plus the §3.3.4 type-formatter colours read back out of a real
## terminal's own cell model, and the pagination affordance on a screen a
## terminal really scrolled to.
##
## ## EVERY COLOUR HERE IS ASSERTED ABSOLUTELY, AND THAT IS A RULE
##
## `docs/tui-testing.md`, "What cross-tier equality cannot catch, and never
## will": a differential check compares two renderings of the SAME program, so
## it is blind by construction to any defect both tiers share. CTUI-5 measured
## it — a mutation that rendered provenance away kept `runDualSnap` at zero
## divergences and was caught only by `fg.idx == 3'u8`.
##
## CTUI-7's whole subject is a badge that has to be SEEN, so every colour this
## suite relies on for MEANING is asserted as a NUMBER: `black` is 0 and `green`
## is 2 for the `[MOD]` badge, `green` is 2 again for the changed row's name,
## `bright_black` is 8 for the cursor's row highlight, `bright_cyan` is 14 for
## the expander, and the five value classes are 6 / 10 / 5 / 8 / 12. The
## cross-tier case is the last in this file and asserts something else entirely:
## that the renderer is faithful.
##
## ## THE ONE ASSERTION THAT FOUND A DEFECT
##
## The row this file reads is BOTH selected and changed, which is the case a
## variables pane meets constantly and the one where two backgrounds compete.
## The first draft of `app/views/tree_node.treeRow` applied the cursor's
## `bright_black` over every span, badge included, so the one row that had
## something to say lost the badge that says it. Reading the cell out of a real
## terminal is what found that; a differential check could not, because both
## tiers painted the same wrong screen.
##
## ## EVERY DRIVEN FRAME IS WAITED FOR BY NAME
##
## `waitForCompleteFrame` cannot be the barrier after an input: the cursor is
## already parked on the bottom-right cell from the PREVIOUS frame. The child
## labels a stepped repaint `<label>-stepN` and every case here waits for the
## label of the frame it is about to read. No sleeps, no `waitForText`.
##
## ## It does not skip
##
## A missing grammar archive, a child that will not compile, a child that never
## finishes a frame, a label that never arrives: every one FAILS by name.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine. Its data is a constant — see `apps/app_variables.nim`'s header
## on why a snapshot app cannot open a `.ct` container, and where the fixture
## evidence lives instead.
##
## ## Templates, not procs, for anything that calls `check`

import std/[strutils, times, unicode, unittest]

import isonim_tui
import term_assert

import ../../app/views/variables
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_variables as varsApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 92

const
  Cols = 90
  Rows = 46
    ## The Ultra-wide profile's `editor` rectangle at 200x60, from CTUI-3's
    ## measured table — wide enough for the name, type and value fields to be
    ## distinct columns and tall enough for the whole collapsed tree.
  Label = "variables"
  Stem = "app_variables"
  FrameTimeoutMs = 20000
  LabelTimeoutMs = 10000

  Black = 0'u8
  Green = 2'u8
  Yellow = 3'u8
  Magenta = 5'u8
  Cyan = 6'u8
  White = 7'u8
  BrightBlack = 8'u8
  BrightGreen = 10'u8
  BrightBlue = 12'u8
  BrightCyan = 14'u8

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

proc paneRow(sess: var TuiTestSession; row: int): string =
  ## One row of the terminal, as text, from column 0.
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc valueColumn(screen: VariablesScreen): int =
  ## The first cell of the VALUE field, from the PANE'S OWN reported geometry
  ## plus `tree_node`'s field arithmetic — never written down. `nameColumn` is
  ## the pane's answer for where its name field starts, so a pane painted at a
  ## non-zero column would move this read with it.
  let widths = fieldWidths(Cols)
  screen.nameColumn + widths.name + 1 + widths.typ + 1

proc settledFrame(sess: var TuiTestSession; step: int): ScreenSnapshot =
  ## Wait for the frame the child declares final at `step`, by name.
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

template checkValueColour(sess: var TuiTestSession; screen: VariablesScreen;
                          row: int; wantRune: string; wantFg: uint8) =
  ## One value cell, read out of a real terminal: the rune the formatter chose
  ## and the colour its CLASS carries.
  let cell = sess.cellAt(row, valueColumn(screen))
  checkpoint("value cell at row " & $row & ": " & describeCell(cell))
  ck $cell.rune == wantRune
  ck cell.fg.kind == ckIndexed
  ck cell.fg.idx == wantFg

template checkPaneMatchesModel(sess: var TuiTestSession;
                               expected: seq[string]; label: string) =
  ## Every row of the pane, on the terminal, is the row the model says.
  var matched = 0
  var firstDiff = ""
  for i in 0 ..< Rows:
    let got = paneRow(sess, i)
    if got == expected[i]:
      inc matched
    elif firstDiff.len == 0:
      firstDiff = "row " & $i & ":\n  term:  '" & got & "'\n  model: '" &
        expected[i] & "'"
  if firstDiff.len > 0:
    checkpoint(label & " " & firstDiff)
  ck matched == Rows

# ---------------------------------------------------------------------------

suite "CTUI-7 Tier 2: the variables pane on a real terminal":

  test "the [MOD] badge, the cursor and the type colours a terminal parsed":
    var sess = spawnChild()
    try:
      let model = varsApp.modelFor(0)
      let screen = varsApp.screenFor(model, Cols, Rows)
      let modifiedRow = bodyRowForPath(screen, "@Locals." & varsApp.ModifiedName)
      let plainRow = bodyRowForPath(screen, "@Locals." & varsApp.UnmodifiedName)

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

      # The pane says what the model says, on a terminal.
      checkPaneMatchesModel(sess, variablesText(model, Cols, Rows), "initial")
      checkpoint("first four pane rows:\n" & paneRow(sess, 0) & "\n" &
                 paneRow(sess, 1) & "\n" & paneRow(sess, 2) & "\n" &
                 paneRow(sess, 3))
      ck paneRow(sess, 0).contains(VariablesTitle)
      ck screen.modifiedRows == 1
      ck modifiedRow > 0
      ck plainRow > 0
      ck modifiedRow != plainRow

      # ---- THE `[MOD]` BADGE, ABSOLUTELY -----------------------------------
      # CTUI-7's Tier-2 sentence, as numbers. Both ends of the five-cell field
      # are read, because a badge whose extent was one cell off would be right
      # where it starts and wrong where it ends.
      let badgeStart = sess.cellAt(modifiedRow, screen.diffColumn)
      let badgeEnd = sess.cellAt(modifiedRow,
                                 screen.diffColumn + ModifiedTagCells - 1)
      checkpoint("badge start " & describeCell(badgeStart) & ", end " &
                 describeCell(badgeEnd))
      ck $badgeStart.rune == "["
      ck badgeStart.fg.kind == ckIndexed
      ck badgeStart.fg.idx == Black
      ck badgeStart.bg.kind == ckIndexed
      ck badgeStart.bg.idx == Green
      ck caBold in badgeStart.attrs
      ck $badgeEnd.rune == "]"
      ck badgeEnd.fg.idx == Black
      ck badgeEnd.bg.idx == Green
      ck sess.regionText(modifiedRow, screen.diffColumn, ModifiedTagCells, 1)
             .split('\n')[0] == ModifiedTag

      # …and §3.3.4's second signal, the accent on the row's NAME.
      let modifiedName = sess.cellAt(modifiedRow, screen.nameColumn)
      checkpoint("changed name cell " & describeCell(modifiedName))
      ck $modifiedName.rune == $varsApp.ModifiedName[0]
      ck modifiedName.fg.kind == ckIndexed
      ck modifiedName.fg.idx == Green
      ck caBold in modifiedName.attrs

      # ---- THE CURSOR'S HIGHLIGHT DOES NOT EAT THE BADGE -------------------
      # This row is BOTH selected and changed. The cell between the badge and
      # the name carries the cursor's own background; the badge keeps its own.
      # The first draft of `tree_node.treeRow` failed exactly here.
      let gap = sess.cellAt(modifiedRow, screen.nameColumn - 1)
      checkpoint("gap cell between badge and name " & describeCell(gap))
      ck gap.bg.kind == ckIndexed
      ck gap.bg.idx == BrightBlack
      ck badgeStart.bg.idx != gap.bg.idx

      # ---- THE NEGATIVE TWIN, through the same reader ----------------------
      # An unmodified, unselected row: the badge field is blank, uncoloured and
      # unbolded, and its name carries no accent. "The badge is on the changed
      # row" is only a statement if it is absent from the others.
      let plainBadge = sess.cellAt(plainRow, screen.diffColumn)
      let plainName = sess.cellAt(plainRow, screen.nameColumn)
      checkpoint("plain badge " & describeCell(plainBadge) & ", plain name " &
                 describeCell(plainName))
      ck $plainBadge.rune == " "
      ck plainBadge.fg.kind == ckDefault
      ck plainBadge.bg.kind == ckDefault
      ck caBold notin plainBadge.attrs
      ck $plainName.rune == $varsApp.UnmodifiedName[0]
      ck plainName.fg.idx == White
      ck caBold notin plainName.attrs
      ck plainName.fg.idx != modifiedName.fg.idx

      # ---- THE EXPANDER, IN ITS OWN COLUMN AND ITS OWN COLOUR --------------
      let collapsedNode = bodyRowForPath(screen, "@Locals.point")
      let leafNode = plainRow
      let expander = sess.cellAt(collapsedNode, 0)
      let leaf = sess.cellAt(leafNode, 0)
      checkpoint("expander " & describeCell(expander) & ", leaf " &
                 describeCell(leaf))
      ck $expander.rune == CollapsedGlyph
      ck expander.fg.kind == ckIndexed
      ck expander.fg.idx == BrightCyan
      ck caBold in expander.attrs
      ck $leaf.rune == " "
      ck leaf.fg.kind == ckDefault

      # ---- §3.3.4'S TYPE FORMATTERS, IN A TERMINAL'S OWN COLOURS -----------
      # Five classes, five numbers, read at the value column the LAYOUT
      # computes. Four of them have no fixture in CTUI-1's corpus.
      checkValueColour(sess, screen, plainRow, "4", Cyan)
      checkValueColour(sess, screen, bodyRowForPath(screen, "@Locals.label"),
                       "\"", BrightGreen)
      checkValueColour(sess, screen, bodyRowForPath(screen, "@Locals.flag"),
                       "t", Magenta)
      checkValueColour(sess, screen, bodyRowForPath(screen, "@Locals.missing"),
                       "n", BrightBlack)
      checkValueColour(sess, screen, bodyRowForPath(screen, "@Locals.handle"),
                       "0", BrightBlue)
      checkValueColour(sess, screen, collapsedNode, "P", Yellow)
      # …and the numeric row really carries BOTH bases, which is §3.3.4's
      # "decimal and hexadecimal simultaneously upon focus" on a real screen.
      ck paneRow(sess, modifiedRow).contains("(0x")
      # THE POINT, as one assertion: the classes do not look the same.
      var distinctColours: seq[uint8] = @[]
      for row in [plainRow, bodyRowForPath(screen, "@Locals.label"),
                  bodyRowForPath(screen, "@Locals.flag"),
                  bodyRowForPath(screen, "@Locals.missing"),
                  bodyRowForPath(screen, "@Locals.handle")]:
        let idx = sess.cellAt(row, valueColumn(screen)).fg.idx
        if idx notin distinctColours:
          distinctColours.add idx
      checkpoint("distinct value colours: " & $distinctColours)
      ck distinctColours.len == 5

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "expanding and paging are visible on a real terminal":
    var sess = spawnChild()
    try:
      discard settledFrame(sess, 0)
      let collapsed = varsApp.modelFor(0)
      let collapsedScreen = varsApp.screenFor(collapsed, Cols, Rows)
      ck $sess.cellAt(bodyRowForPath(collapsedScreen, "@Locals.point"),
                      0).rune == CollapsedGlyph

      # EXPAND, twice, with a real key. Every frame is waited for by NAME.
      sess.sendKey("f10")
      discard settledFrame(sess, 1)
      let opened = varsApp.modelFor(1)
      let openedScreen = varsApp.screenFor(opened, Cols, Rows)
      checkPaneMatchesModel(sess, variablesText(opened, Cols, Rows), "opened")
      let openedRow = bodyRowForPath(openedScreen, "@Locals.point")
      ck $sess.cellAt(openedRow, 0).rune == ExpandedGlyph
      ck sess.cellAt(openedRow, 0).fg.idx == BrightCyan
      # …and the struct's two fields are on the screen, under it, indented.
      ck paneRow(sess, openedRow + 1).contains("x")
      ck paneRow(sess, openedRow + 2).contains("y")
      ck openedScreen.totalRows == collapsedScreen.totalRows + 2

      sess.sendKey("f10")
      discard settledFrame(sess, 2)
      let paged = varsApp.modelFor(2)
      checkPaneMatchesModel(sess, variablesText(paged, Cols, Rows), "paged")
      # THE PAGE IS BOUNDED: a 600-member node put its FIRST PAGE on screen and
      # the pane's row count is the page, not the member count.
      let pagedScreen = varsApp.screenFor(paged, Cols, Rows)
      checkpoint("rows at step 2: " & $pagedScreen.totalRows & " for a " &
                 $varsApp.WideMemberCount & "-member node")
      ck pagedScreen.totalRows < varsApp.WideMemberCount
      ck pagedScreen.totalRows > openedScreen.totalRows

      # ---- THE `… N MORE` AFFORDANCE, ON A REAL TERMINAL -------------------
      # It is a hundred rows below the fold, so the third step scrolls the pane
      # to its end and the row is read back by `regionText`.
      sess.sendKey("f10")
      discard settledFrame(sess, 3)
      let scrolled = varsApp.modelFor(3)
      checkPaneMatchesModel(sess, variablesText(scrolled, Cols, Rows),
                            "scrolled")
      let scrolledScreen = varsApp.screenFor(scrolled, Cols, Rows)
      ck scrolledScreen.moreRows == 1
      var moreRow = -1
      for i, row in scrolledScreen.visible:
        if row.kind == vrkMore:
          moreRow = scrolledScreen.area.row + 1 + i
      checkpoint("more row at " & $moreRow & ": '" &
                 (if moreRow >= 0: paneRow(sess, moreRow) else: "<none>") & "'")
      ck moreRow > 0
      # THE EXACT REMAINDER, derived from the app's own member count and the
      # pane's page size rather than read back from the row that is under test.
      let remaining = varsApp.WideMemberCount - DefaultPageSize
      ck paneRow(sess, moreRow).contains($remaining)
      ck paneRow(sess, moreRow).contains("more")
      # …and the members on either side of it are the LAST page's, so the
      # scroll landed where the affordance says it did.
      ck paneRow(sess, moreRow - 1).contains("[" & $(DefaultPageSize - 1) & "]")

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "cross-tier snapshot equality grounds the pane's Tier-1 goldens":
    # docs/tui-testing.md: "a new pane needs exactly one cross-tier equivalence
    # test. Not zero, and not one per assertion." This is the variables pane's,
    # at CTUI-2's two geometries, through the SAME `buildTree` both tiers run.
    var checkedCases = 0
    for g in [(cols: 80, rows: 24), (cols: Cols, rows: Rows)]:
      let res = runDualSnap(Stem, varsApp.buildTree, g.cols, g.rows)
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
      for line in variablesText(varsApp.modelFor(0), g.cols, g.rows):
        for r in line.runes:
          if $r != " ":
            inc modelPainted
      checkpoint("app_variables at " & $g.cols & "x" & $g.rows & ": " &
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

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
