## test_layout_profiles.nim — CTUI-3, Tier 1.
##
## ## What this asserts
##
## CodeTracer-TUI.milestones.org, CTUI-3: "at 80x24, 120x40 and 200x60, asserts
## the selected profile, the pane set, and each pane's cell region; records a
## Tier-1 golden per geometry."
##
## All three, plus the two properties the milestone calls out separately:
##
##   * profile selection is a PURE FUNCTION of (width, height) and is tested as
##     one, with no harness mounted and no tree projected — the whole first
##     case runs without a renderer existing;
##   * the Compact profile's bottom row is a `stack`, so `Alt+1/2/3` is
##     `LayoutNode.activate`. That is asserted as an identity, not as a
##     resemblance: the test calls `activate` on the very node type the desktop
##     persists, and then reads the tab strip off the composited screen.
##
## ## Every number here is EXACT
##
## Verification-Harness-Traps §4b: an existential control is satisfied by one
## member of a set whose size is knowable. Every pane region below is a
## four-integer rectangle, every pane set is compared as a whole sequence, and
## the golden files are counted rather than checked for non-emptiness.
##
## ## No mocks
##
## Nothing here needs a debugger. The subject is arithmetic over a layout tree
## and a compositor's output, and both are real.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope. Inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still reports `[OK]` while
## `programResult` goes to 1. CTUI-2 measured that happening. Every helper below
## that checks anything is therefore a template.

import std/[os, strutils, unicode, unittest]

import isonim_tui

import headless_app/layout_model
import codetracer_embed

import ../layout/profile
import ../layout/project
import ../views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 368

const
  Geometries = [(cols: 80, rows: 24), (cols: 120, rows: 40),
                (cols: 200, rows: 60)]
    ## The three the milestone names, one per profile.

var countedAssertions = 0

template ck(condition: untyped) =
  ## `check`, counted — Verification-Harness-Traps §4c.
  inc countedAssertions
  check condition

template ckRegion(proj: Projection; kind: PaneKind;
                  expCol, expRow, expWidth, expHeight: int) =
  ## One pane's rectangle, as four exact integers.
  ##
  ## A template because it calls `check`; see this file's header for the
  ## silent-self-pass mechanism that makes the distinction load-bearing.
  ##
  ## The parameters are `exp*` rather than `col` / `row` / `width` / `height`
  ## because a template parameter substitutes INSIDE a field access: named
  ## `col`, the body's `got.col` expands to `got.0` at the call site
  ## `ckRegion(proj, paneCalltrace, 0, ...)` and does not compile.
  block:
    let got = proj.regionFor(kind)
    checkpoint($kind & " -> " & $got & ", expected (" & $expCol & "," &
               $expRow & " " & $expWidth & "x" & $expHeight & ")")
    ck got.col == expCol
    ck got.row == expRow
    ck got.width == expWidth
    ck got.height == expHeight

proc goldenRoot(): string =
  ## Where the Tier-1 goldens land: under `test-logs/`, which `.gitignore`
  ## covers, so a run never dirties the tree. Same rule
  ## `testing/dual_snap.nim` records for itself.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir / "test-logs" / "tui-shell-geometry"
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

const GoldenFiles = ["plaintext.txt", "ansi.ansi", "cellmap.json", "svg.svg",
                     "annotated.svg", "treedump.txt"]
  ## The six formats `TerminalTestHarness` records, named here rather than
  ## imported from `testing/dual_snap.nim`: that module imports `term_assert`,
  ## whose `--path` only the Tier-2 lane carries, and a Tier-1 suite that could
  ## compile against TermAssert would be one edit away from spawning a pty in
  ## the fast lane (docs/tui-testing.md).

proc writeGolden(h: TerminalTestHarness; dir: string) =
  ## The six formats for one geometry.
  createDir(dir)
  let buf = h.driver.buffer
  writeFile(dir / GoldenFiles[0], encodePlaintext(buf))
  writeFile(dir / GoldenFiles[1], encodeAnsi(buf))
  writeFile(dir / GoldenFiles[2], encodeCellMap(buf))
  writeFile(dir / GoldenFiles[3], encodeSvg(buf))
  writeFile(dir / GoldenFiles[4],
            encodeAnnotatedSvg(buf, h.root, h.compositor, h.focusedId))
  writeFile(dir / GoldenFiles[5], encodeTreeDump(h.compositor, h.root))

proc demoModel(width, height: int): ShellModel =
  ## One header for every geometry, so a difference between two screens is a
  ## difference in LAYOUT rather than in content.
  newShellModel(width, height, initHeaderModel(
    traceName = "demo.ct", targetArch = "x86_64", recordingKind = "native",
    status = esPaused, tick = 1420, totalTicks = 8950))

proc rowText(h: TerminalTestHarness; row, width: int): string =
  result = ""
  for col in 0 ..< width:
    result.add $h.cellAt(row, col).rune

suite "CTUI-3: breakpoint profiles and pane geometry":

  test "profile selection is a pure function of (width, height)":
    # NO HARNESS, NO TREE, NO PROJECTION. The milestone asks for this to be
    # testable independently of rendering, and the only way to demonstrate that
    # is a case that does not render.
    #
    # PLAT-45: a profile is now the SIZE the default is derived for. The
    # arrangement is the shared default folded for the size (`depthFor`),
    # asserted by the cases below and swept by `tests/test_plat45_fold.nim`.
    # (PLAT-49 removed the status line's key-hint strip, the last thing the
    # old breakpoint table decided.)
    ck selectProfile(80, 24) == lpCompact
    ck selectProfile(120, 40) == lpStandard
    ck selectProfile(200, 50) == lpUltraWide
    ck selectProfile(200, 60) == LayoutProfile(width: 200, height: 60)

    # PURITY, asserted rather than asserted about: the same arguments give the
    # same answer after every other call in this case, and the answer does not
    # depend on the order the grid is walked.
    var forward: seq[int] = @[]
    var backward: seq[int] = @[]
    for w in countup(60, 220, 20):
      for h in countup(10, 70, 10):
        forward.add depthFor(pmDebug, selectProfile(w, h))
    for w in countdown(220, 60, 20):
      for h in countdown(70, 10, 10):
        backward.add depthFor(pmDebug, selectProfile(w, h))
    ck forward.len == 9 * 7
    ck backward.len == forward.len
    var matched = 0
    for i in 0 ..< forward.len:
      if forward[i] == backward[backward.len - 1 - i]:
        inc matched
    ck matched == forward.len
    # And the grid really did contain an unfolded and a folded answer —
    # otherwise the symmetry above holds for free over a constant function.
    ck 0 in forward
    ck maxFoldDepth(sharedDefaultLayout()) in forward

  test "each size's fold satisfies the minimum-size contract":
    # CTUI-3's risk mitigation asks for "an explicit minimum-size contract per
    # pane that the projection test enforces rather than discovers". PLAT-45
    # makes that contract the thing that DECIDES the arrangement: the fold is
    # exactly as deep as it requires.
    checkpoint("fold depths: " & profileSummary())
    ck fitsAt(profileLayout(lpCompact), 80, 24)
    ck fitsAt(profileLayout(lpStandard), 120, 40)
    ck fitsAt(profileLayout(selectProfile(200, 60)), 200, 60)
    # The negative twin, through the same function: the UNFOLDED default at
    # 80x24 starves the editor, and says so rather than being laid out into a
    # sliver.
    ck not fitsAt(sharedDefaultLayout().tree, 80, 24)
    ck fitProblems(sharedDefaultLayout().tree, 80, 24).len > 0
    # PLAT-47: the shared default is the desktop's Debug layout (TESTS a tab
    # of FILES, no CONSTRAINTS), so it has two fold steps fewer and 80x24 is
    # reached at depth 2 — the same three regions the depth-4 fold gave.
    ck depthFor(pmDebug, lpCompact) == 2
    ck depthFor(pmDebug, lpStandard) == 0
    ck depthFor(pmDebug, lpUltraWide) == 0
    # The per-pane lower bound grows with every region the fold gives back.
    let s = sharedDefaultLayout()
    ck minimumWidth(foldLayout(s, 0)) > minimumWidth(foldLayout(s, 3))

  test "80x24 folds twice and partitions the body exactly":
    let (w, h) = (80, 24)
    let body = bodyArea(w, h)
    let proj = projectLayout(profileLayout(selectProfile(w, h)), body)
    checkpoint(describe(proj))
    ck proj.status == prOk
    ck body == CellArea(col: 0, row: 1, width: 80, height: 22)
    # THE PANE SET AS A WHOLE SEQUENCE, in projection order. Comparing the set
    # member by member would pass over a fourth pane nobody expected.
    # The source pane first, at its 60-cell minimum; the rest of the shared
    # default in one side column of two stacks.
    ck proj.visiblePaneKinds() == @[paneEditor, paneState, paneEventLog]
    ckRegion(proj, paneEditor, 0, 1, 60, 22)
    ckRegion(proj, paneState, 60, 1, 20, 11)
    ckRegion(proj, paneEventLog, 60, 12, 20, 11)
    ck coverageProblems(proj.regions, body).len == 0
    ck coveredCells(proj.regions, body) == body.cellCount()

  test "120x40 is the shared default unfolded, five regions":
    let (w, h) = (120, 40)
    let body = bodyArea(w, h)
    let proj = projectLayout(profileLayout(selectProfile(w, h)), body)
    checkpoint(describe(proj))
    ck proj.status == prOk
    ck proj.visiblePaneKinds() ==
       @[paneFileTree, paneEditor, paneState, paneCalltrace, paneEventLog]
    # Every region its minimum first, then the desktop's Debug-mode shares of
    # the rest (FILES 20 / editor 25 / the replay column 55).
    ckRegion(proj, paneFileTree, 0, 1, 12, 38)
    ckRegion(proj, paneEditor, 12, 1, 65, 38)
    ckRegion(proj, paneState, 77, 1, 21, 19)
    ckRegion(proj, paneCalltrace, 98, 1, 22, 19)
    ckRegion(proj, paneEventLog, 77, 20, 43, 19)
    ck coverageProblems(proj.regions, body).len == 0
    ck coveredCells(proj.regions, body) == body.cellCount()

  test "200x60 is the shared default unfolded, minimums first":
    let (w, h) = (200, 60)
    let body = bodyArea(w, h)
    let proj = projectLayout(profileLayout(selectProfile(w, h)), body)
    checkpoint(describe(proj))
    ck proj.status == prOk
    ck proj.visiblePaneKinds() ==
       @[paneFileTree, paneEditor, paneState, paneCalltrace, paneEventLog]
    # Every region gets its minimum (a region's minimum is its widest tab's,
    # and never less than that tab's label), and the columns left over are
    # shared 20 / 25 / 55 — the desktop's rendered Debug-mode shares. The
    # ARRANGEMENT is the desktop's; the cells are the terminal's.
    ckRegion(proj, paneFileTree, 0, 1, 28, 58)
    ckRegion(proj, paneEditor, 28, 1, 85, 58)
    ckRegion(proj, paneState, 113, 1, 43, 29)
    ckRegion(proj, paneCalltrace, 156, 1, 44, 29)
    ckRegion(proj, paneEventLog, 113, 30, 87, 29)
    ck coverageProblems(proj.regions, body).len == 0
    ck coveredCells(proj.regions, body) == body.cellCount()

  test "the shared default's stacks are stacks, and a tab switch is LayoutNode.activate":
    # THE MILESTONE'S LOAD-BEARING CONTRACT. Not "the TUI has tabs" — that
    # the tab operation IS the desktop's operation, performed on the desktop's
    # own type.
    let node = profileLayout(lpCompact)
    ck stackTabs(node) == @[
      @[paneState, paneScratchpad, paneCalltrace, paneAgentActivity,
        paneFileTree, paneVcs, paneTestResults],
      @[paneEventLog, paneTimeline, paneTerminalOutput]]

    # `allPanes` sees all eleven; `visiblePanes` sees three. That difference
    # IS the stacks, and it is the reason a shell need not load an invisible
    # tab.
    ck allPanes(node).len == 11
    ck visiblePanes(node) == @[paneEditor, paneState, paneEventLog]

    let body = bodyArea(80, 24)
    let before = projectLayout(node, body)
    ck before.regionFor(paneEventLog).height == 11
    ck before.regionFor(paneTimeline).cellCount() == 0

    # A tab click — `activate(paneTimeline)`, the same call
    # `session_switch.nim` makes through GoldenLayout on the desktop.
    ck node.activate(paneTimeline)
    let after = projectLayout(node, body)
    ck after.visiblePaneKinds() == @[paneEditor, paneState, paneTimeline]
    # THE REGION IS THE SAME CELLS. A tab switch moves which pane owns the
    # slot; it must not move the slot.
    ck after.regionFor(paneTimeline) == before.regionFor(paneEventLog)
    ck after.regionFor(paneEventLog).cellCount() == 0
    ck coverageProblems(after.regions, body).len == 0

  test "the tab strip on the composited screen follows activate":
    # The model half above says the tree changed. This says the SCREEN did —
    # through the real compositor, in the real `ScreenBuffer`, which is the
    # only thing that makes the first half a statement about the product.
    var model = demoModel(80, 24)
    let h = newTerminalTestHarness(80, 24)
    h.mount(proc(r: TerminalRenderer): TerminalNode =
      renderShellTree(model, r, 80, 24))
    # The event stack's strip: row 12, from column 60 (the 80x24 case above).
    let stackRow = bodyArea(80, 24).row + 11
    proc strip(h: TerminalTestHarness): string =
      rowText(h, stackRow, 80).runeSubStr(60)
    proc boldAt(h: TerminalTestHarness; col: int): bool =
      attrBold in h.cellAt(stackRow, col).attrs
    let firstTabs = strip(h)
    checkpoint("tab strip: '" & firstTabs.strip() & "'")
    # PLAT-47: a tab is its padded label; the active one is BOLD (its role's
    # weight), not bracketed.
    ck firstTabs.startsWith(" Event Log ")
    ck boldAt(h, 61) and not boldAt(h, 73)
    # The strip is 20 cells wide at 80x24 and cuts at the region's edge — the
    # second label to `Timelin`, the rest entirely; the stack still holds
    # them, in the shared default's order.
    ck firstTabs.startsWith(" Event Log   Timelin")
    ck stackTabs(model.layout)[^1][2] == paneTerminalOutput

    ck model.layout.activate(paneTimeline)
    h.mount(proc(r: TerminalRenderer): TerminalNode =
      renderShellTree(model, r, 80, 24))
    let secondTabs = strip(h)
    checkpoint("tab strip after the click: '" & secondTabs.strip() & "'")
    ck secondTabs.startsWith(" Event Log   Timelin")
    # The two strips differ ONLY in which tab is bold — a repaint that rebuilt
    # the layout from the profile would have reset the active tab and left
    # `Event Log` bold, which is the failure `shell.reprofile` guards.
    ck firstTabs == secondTabs
    ck not boldAt(h, 61) and boldAt(h, 73)
    h.dispose()

  test "the status bar carries no key-hint strip, at any profile or mode":
    # PLAT-49 (the user, 2026-10-01): the status line's key hints
    # (`'n':step-over …`, `F10:Next …`) are gone — no other front-end has
    # them. Asserted on the composed screen at both profiles and on the row
    # function in every input mode, so a strip that came back in one mode or
    # one width is caught.
    let compact = demoModel(80, 24).shellRows(80, 24)
    let standard = demoModel(120, 40).shellRows(120, 40)
    for hint in ["step-over", "rev-step", "F10:Next", "F5:Cont", ":help",
                 "Enter:run", "Esc:cancel", "expand", "Ctrl+F5"]:
      ck not compact[^1].contains(hint)
      ck not standard[^1].contains(hint)
    for mode in UiMode:
      for product in ProductMode:
        let row = statusBarText(initStatusBarModel(mode = mode,
                                                   profile = lpStandard,
                                                   product = product), 120)
        ck not row.contains("step-over")
        ck not row.contains(":run")
        ck not row.contains("Esc:")
        ck not row.contains("hjkl")
    # PLAT-16: TWO INDICATORS, IN TWO POSITIONS, AND THE INPUT ONE IS STILL
    # FIRST. `NORMAL` is the input mode and `[DEBUG]` is the product mode; the
    # brackets are what keep them from reading as one two-word mode name.
    # PLAT-45: an 80x24 terminal FOLDED the shared default, and the status
    # line says so right after the two indicators; 120x40 did not, and says
    # nothing.
    ck compact[^1].startsWith("NORMAL [DEBUG] [folded 2] ")
    ck standard[^1].startsWith("NORMAL [DEBUG] ")
    ck not standard[^1].startsWith("NORMAL [DEBUG] [folded")

  test "the header and the status bar are exactly `width` cells at every width":
    # A SWEEP, not three sizes. Both rows are built by fitting several fields
    # into a budget, and that arithmetic is off by one at ONE width in a
    # hundred rather than at all of them — a defect three geometries cannot
    # find. (It found one: at a width where the notification's room came to a
    # single cell, `statusBarText` returned `width + 1` cells.)
    let hdr = initHeaderModel(
      traceName = "a-rather-long-trace-name.ct", targetArch = "aarch64",
      recordingKind = "native", status = esReversing, tick = 987654,
      totalTicks = 1234567)
    var withTabs = hdr
    withTabs.sessions = @[SessionTab(title: "demo.ct", active: true),
                          SessionTab(title: "calc.ct", active: false)]
    var checkedWidths = 0
    var wrongHeader: seq[string] = @[]
    var wrongStatus: seq[string] = @[]
    for width in 1 .. 240:
      for model in [hdr, withTabs]:
        inc checkedWidths
        let line = headerText(model, width)
        if textCells(line) != width:
          wrongHeader.add $width & " -> " & $textCells(line)
      # PLAT-16: THE SWEEP GAINED A SECOND DIMENSION AND DID NOT GAIN MEMBERS.
      #
      # CodeTracer-TUI-Edit-Mode.md §1.2's risk is that Edit and Debug get
      # folded into `UiMode`, producing "a state machine with fifteen states
      # that should have two dimensions". This nested loop is that sentence as
      # a test: the product below is 6 x 2, and a collapse would make it 12 x 1
      # or 8 x 1 — a DIFFERENT ARITHMETIC, not a bigger number, so the literal
      # cannot be repaired by bumping it.
      for mode in UiMode:
        for product in ProductMode:
          for note in ["", "n", "trace reloaded from disk"]:
            inc checkedWidths
            let bar = statusBarText(
              initStatusBarModel(mode = mode, profile = lpStandard,
                                 notification = note, product = product),
              width)
            if textCells(bar) != width:
              wrongStatus.add $mode & "/" & $product & " note='" & note &
                "' " & $width & " -> " & $textCells(bar)
    checkpoint("widths checked: " & $checkedWidths)
    if wrongHeader.len > 0:
      checkpoint("header: " & wrongHeader[0 .. min(4, wrongHeader.high)].join(", "))
    if wrongStatus.len > 0:
      checkpoint("status: " & wrongStatus[0 .. min(4, wrongStatus.high)].join(", "))
    # `6` is `UiMode`'s cardinality: CTUI-9 added `umInspect`, §4.1's fourth
    # mode, which CTUI-3 had no indicator for. The literal is deliberate — a
    # `len(UiMode)` here would be computed by the same enum the sweep walks and
    # would stop being able to notice that the sweep skipped a member.
    #
    # `2` is `ProductMode`'s, on the same rule and for the sharper reason
    # PLAT-16's risk mitigation gives: the two cardinalities are written as a
    # PRODUCT of two literals rather than as one number, so the arithmetic
    # itself records that these are two dimensions. `6 * 2` and `12` are the
    # same integer and not the same claim.
    ck checkedWidths == 240 * (2 + 6 * 2 * 3)
    ck wrongHeader.len == 0
    ck wrongStatus.len == 0
    # The positive twin: at a width that fits everything, the fields are all
    # present. Without it, a `headerText` that returned `width` spaces would
    # satisfy every assertion above.
    let wide = headerText(withTabs, 200)
    ck wide.contains("[ct]")
    ck wide.contains("a-rather-long-trace-name.ct")
    ck wide.contains("aarch64")
    ck wide.contains("987,654 / 1,234,567")
    # PLAT-47: the session tabs are padded labels, the active one told apart
    # by its role on the painted row (`shell` restyles `sessionTabSpans`).
    ck wide.contains(" demo.ct  calc.ct ")
    ck not wide.contains("[demo.ct]")
    let spans = sessionTabSpans(withTabs, 200)
    ck spans.len == 2 and spans[0].active and not spans[1].active
    ck wide.runeSubStr(spans[0].col, spans[0].width) == " demo.ct "
    ck wide.contains("[REVERSING]")
    # And the badge is the LAST thing dropped: at a width that fits nothing
    # else, the state is still readable.
    ck headerText(withTabs, 12).contains("[REVERSING]")

  test "a degraded projection is drawn as degraded, not as a single pane":
    # CTUI-3: "never a silently misdrawn screen". The release policy's fallback
    # has to be visibly a fallback, or it is indistinguishable from a layout
    # somebody chose.
    var model = newShellModel(80, 24)
    model.layout = column([
      stack([row([pane(paneEditor), pane(paneState)])], activeIndex = 0)])
    let screen = model.shellScreen(80, 24, ppDegrade)
    checkpoint("body row: '" & screen.rows[1].strip() & "'")
    checkpoint("status row: '" & screen.rows[^1].strip() & "'")
    ck screen.projection.status == prInvalidLayout
    ck screen.rows.len == 24
    ck screen.rows[1].contains("LAYOUT DEGRADED")
    ck screen.rows[1].contains("invalid-layout")
    ck screen.rows[^1].contains("invalid-layout")
    for line in screen.rows:
      ck textCells(line) == 80
    # The healthy screen says none of that, through the same code path — a
    # banner that were always drawn would satisfy the assertions above for free.
    let healthy = demoModel(80, 24).shellScreen(80, 24)
    ck healthy.projection.status == prOk
    ck not healthy.rows[1].contains("LAYOUT DEGRADED")
    ck not healthy.rows[^1].contains("invalid-layout")

  test "every geometry paints a full screen and records a Tier-1 golden":
    var written = 0
    var checkedRows = 0
    for g in Geometries:
      var model = demoModel(g.cols, g.rows)
      let screen = model.shellScreen(g.cols, g.rows)
      ck screen.rows.len == g.rows
      for line in screen.rows:
        inc checkedRows
        if textCells(line) != g.cols:
          checkpoint("row is " & $textCells(line) & " cells, expected " &
                     $g.cols & ": '" & line & "'")
        ck textCells(line) == g.cols

      let h = newTerminalTestHarness(g.cols, g.rows)
      h.mount(proc(r: TerminalRenderer): TerminalNode =
        renderShellTree(model, r, g.cols, g.rows))
      # THE COMPOSITED SCREEN AND THE MODEL AGREE, ROW BY ROW. This is what
      # makes the golden below evidence rather than a picture: the strings the
      # test asserts on are the strings the compositor painted.
      var identical = 0
      for row in 0 ..< g.rows:
        if rowText(h, row, g.cols) == screen.rows[row]:
          inc identical
      ck identical == g.rows

      let dir = goldenRoot() / ($g.cols & "x" & $g.rows)
      removeDir(dir)
      writeGolden(h, dir)
      for name in GoldenFiles:
        inc written
        ck fileExists(dir / name)
      # The plaintext golden is the screen, so an encoder that wrote an empty
      # file cannot pass — trap 4b again, with a knowable size.
      ck readFile(dir / GoldenFiles[0]).splitLines().len >= g.rows
      h.dispose()
    checkpoint("golden files written: " & $written &
               ", screen rows checked: " & $checkedRows)
    ck written == Geometries.len * GoldenFiles.len
    ck checkedRows == 24 + 40 + 60

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
