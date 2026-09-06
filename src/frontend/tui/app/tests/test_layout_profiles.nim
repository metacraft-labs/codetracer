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

import ../layout/profile
import ../layout/project
import ../views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 309

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
    ck selectProfile(80, 24) == lpCompact
    ck selectProfile(120, 40) == lpStandard
    ck selectProfile(200, 60) == lpUltraWide

    # THE BOUNDARIES, on both sides, because a breakpoint table is exactly
    # where an off-by-one lives and neither of the three sizes above is near
    # one.
    ck selectProfile(119, 40) == lpCompact
    ck selectProfile(120, 40) == lpStandard
    ck selectProfile(179, 40) == lpStandard
    ck selectProfile(180, 40) == lpUltraWide
    ck selectProfile(200, 34) == lpCompact     ## height decides first
    ck selectProfile(200, 35) == lpUltraWide
    ck selectProfile(120, 34) == lpCompact
    ck selectProfile(120, 35) == lpStandard

    # PURITY, asserted rather than asserted about: the same arguments give the
    # same answer after every other call in this case, and the answer does not
    # depend on the order the grid is walked.
    var forward: seq[LayoutProfile] = @[]
    var backward: seq[LayoutProfile] = @[]
    for w in countup(60, 220, 20):
      for h in countup(10, 70, 10):
        forward.add selectProfile(w, h)
    for w in countdown(220, 60, 20):
      for h in countdown(70, 10, 10):
        backward.add selectProfile(w, h)
    ck forward.len == 9 * 7
    ck backward.len == forward.len
    var matched = 0
    for i in 0 ..< forward.len:
      if forward[i] == backward[backward.len - 1 - i]:
        inc matched
    ck matched == forward.len
    # And the grid really did contain all three profiles — otherwise the
    # symmetry above holds for free over a constant function.
    ck lpCompact in forward
    ck lpStandard in forward
    ck lpUltraWide in forward

  test "each profile's minimum-size contract is satisfied at its geometry":
    # CTUI-3's risk mitigation asks for "an explicit minimum-size contract per
    # pane that the projection test enforces rather than discovers". The
    # contract is `profile.minPaneWidth` / `minPaneHeight`; this is where it is
    # checked against the sizes the milestone names.
    checkpoint("profile minimums: " & profileSummary())
    ck profileFits(lpCompact, 80, 24)
    ck profileFits(lpStandard, 120, 40)
    ck profileFits(lpUltraWide, 200, 60)
    # The negative twin, through the same function: a profile whose columns do
    # not fit must SAY so rather than be laid out into slivers.
    ck not profileFits(lpUltraWide, 60, 60)
    ck not profileFits(lpStandard, 40, 40)
    ck minimumWidth(lpUltraWide) > minimumWidth(lpStandard)
    ck minimumWidth(lpStandard) > minimumWidth(lpCompact)

  test "80x24 selects Compact and partitions the body exactly":
    let (w, h) = (80, 24)
    let body = bodyArea(w, h)
    let proj = projectLayout(profileLayout(selectProfile(w, h)), body)
    checkpoint(describe(proj))
    ck proj.status == prOk
    ck body == CellArea(col: 0, row: 1, width: 80, height: 22)
    # THE PANE SET AS A WHOLE SEQUENCE, in projection order. Comparing the set
    # member by member would pass over a fourth pane nobody expected.
    ck proj.visiblePaneKinds() == @[paneCalltrace, paneEditor, paneState]
    ckRegion(proj, paneCalltrace, 0, 1, 24, 17)
    ckRegion(proj, paneEditor, 24, 1, 56, 17)
    ckRegion(proj, paneState, 0, 18, 80, 5)
    ck coverageProblems(proj.regions, body).len == 0
    ck coveredCells(proj.regions, body) == body.cellCount()

  test "120x40 selects Standard, three columns and an eight-row strip":
    let (w, h) = (120, 40)
    let body = bodyArea(w, h)
    let proj = projectLayout(profileLayout(selectProfile(w, h)), body)
    checkpoint(describe(proj))
    ck proj.status == prOk
    ck proj.visiblePaneKinds() ==
       @[paneCalltrace, paneEditor, paneState, paneTimeline]
    ckRegion(proj, paneCalltrace, 0, 1, 30, 30)
    ckRegion(proj, paneEditor, 30, 1, 60, 30)
    ckRegion(proj, paneState, 90, 1, 30, 30)
    # §3.2: "Bottom row (height: 8 rows)". The 4:1 weight in
    # `profile.profileLayout` is chosen so this lands on eight AT THIS
    # GEOMETRY, and this is the assertion that keeps that true.
    ckRegion(proj, paneTimeline, 0, 31, 120, 8)
    ck coverageProblems(proj.regions, body).len == 0
    ck coveredCells(proj.regions, body) == body.cellCount()

  test "200x60 selects Ultra-wide and gives the fourth column its own pane":
    let (w, h) = (200, 60)
    let body = bodyArea(w, h)
    let proj = projectLayout(profileLayout(selectProfile(w, h)), body)
    checkpoint(describe(proj))
    ck proj.status == prOk
    ck proj.visiblePaneKinds() ==
       @[paneCalltrace, paneEditor, paneState, paneEventLog, paneTimeline]
    ckRegion(proj, paneCalltrace, 0, 1, 40, 46)
    ckRegion(proj, paneEditor, 40, 1, 90, 46)
    ckRegion(proj, paneState, 130, 1, 40, 46)
    ckRegion(proj, paneEventLog, 170, 1, 30, 46)
    ckRegion(proj, paneTimeline, 0, 47, 200, 12)
    ck coverageProblems(proj.regions, body).len == 0
    ck coveredCells(proj.regions, body) == body.cellCount()

  test "the Compact bottom row is a stack, and Alt+1/2/3 is LayoutNode.activate":
    # THE MILESTONE'S LOAD-BEARING CONTRACT. Not "the TUI has tabs" — that
    # the tab operation IS the desktop's operation, performed on the desktop's
    # own type.
    let node = profileLayout(lpCompact)
    var stacks = 0
    proc countStacks(n: LayoutNode) =
      if n.isNil: return
      if n.kind == lnStack: inc stacks
      for c in n.children: countStacks(c)
    countStacks(node)
    ck stacks == 1
    ck profileTabs(lpCompact) == @[paneState, paneTimeline, paneEventLog]
    # The wider profiles carry no stack at all, which is what makes the tab
    # keys Compact-only rather than universally bound to nothing.
    ck profileTabs(lpStandard).len == 0
    ck profileTabs(lpUltraWide).len == 0

    # `allPanes` sees all five; `visiblePanes` sees three. That difference IS
    # the stack, and it is the reason a shell need not load an invisible tab.
    ck allPanes(node).len == 5
    ck visiblePanes(node) == @[paneCalltrace, paneEditor, paneState]

    let body = bodyArea(80, 24)
    let before = projectLayout(node, body)
    ck before.regionFor(paneState).height == 5
    ck before.regionFor(paneTimeline).cellCount() == 0

    # Alt+2 — `activate(paneTimeline)`, the same call `session_switch.nim`
    # makes through GoldenLayout on the desktop.
    ck node.activate(paneTimeline)
    let after = projectLayout(node, body)
    ck after.visiblePaneKinds() == @[paneCalltrace, paneEditor, paneTimeline]
    # THE REGION IS THE SAME CELLS. A tab switch moves which pane owns the
    # slot; it must not move the slot.
    ck after.regionFor(paneTimeline) == before.regionFor(paneState)
    ck after.regionFor(paneState).cellCount() == 0
    ck coverageProblems(after.regions, body).len == 0

  test "the tab strip on the composited screen follows activate":
    # The model half above says the tree changed. This says the SCREEN did —
    # through the real compositor, in the real `ScreenBuffer`, which is the
    # only thing that makes the first half a statement about the product.
    var model = demoModel(80, 24)
    let h = newTerminalTestHarness(80, 24)
    h.mount(proc(r: TerminalRenderer): TerminalNode =
      renderShellTree(model, r, 80, 24))
    let stackRow = bodyArea(80, 24).row + 17
    let firstTabs = rowText(h, stackRow, 80)
    checkpoint("tab strip: '" & firstTabs.strip() & "'")
    ck firstTabs.startsWith("[Variables]")
    ck firstTabs.contains("Timeline")
    ck firstTabs.contains("Tracepoints")

    ck model.layout.activate(paneTimeline)
    h.mount(proc(r: TerminalRenderer): TerminalNode =
      renderShellTree(model, r, 80, 24))
    let secondTabs = rowText(h, stackRow, 80)
    checkpoint("tab strip after Alt+2: '" & secondTabs.strip() & "'")
    ck secondTabs.contains("[Timeline]")
    ck not secondTabs.contains("[Variables]")
    # The two strips differ ONLY in the brackets — a repaint that rebuilt the
    # layout from the profile would have reset the active tab and produced the
    # first string again, which is the failure `shell.reprofile` guards.
    ck firstTabs != secondTabs
    ck firstTabs.replace("[", " ").replace("]", " ") ==
       secondTabs.replace("[", " ").replace("]", " ")
    h.dispose()

  test "the status bar's hint strip is profile-dependent":
    # §3.3.6 asks for a "dynamic" strip. A constant would satisfy every other
    # assertion in this file, so the difference is asserted directly.
    ck keyHints(umNormal, lpCompact) != keyHints(umNormal, lpStandard)
    ck keyHints(umNormal, lpStandard) == keyHints(umNormal, lpUltraWide)
    ck keyHints(umNormal, lpCompact).contains("F10")
    ck keyHints(umNormal, lpStandard).contains("step-over")
    ck keyHints(umCommand, lpCompact) != keyHints(umNormal, lpCompact)
    # And it reaches the screen: the bottom row of an 80x24 shell is the
    # Compact strip, and of a 120x40 shell the wide one.
    let compact = demoModel(80, 24).shellRows(80, 24)
    let standard = demoModel(120, 40).shellRows(120, 40)
    ck compact[^1].contains(keyHints(umNormal, lpCompact))
    ck standard[^1].contains("step-over")
    ck compact[^1].startsWith("NORMAL |")

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
      for mode in UiMode:
        for note in ["", "n", "trace reloaded from disk"]:
          inc checkedWidths
          let bar = statusBarText(
            initStatusBarModel(mode = mode, profile = lpStandard,
                               notification = note), width)
          if textCells(bar) != width:
            wrongStatus.add $mode & " note='" & note & "' " & $width & " -> " &
              $textCells(bar)
    checkpoint("widths checked: " & $checkedWidths)
    if wrongHeader.len > 0:
      checkpoint("header: " & wrongHeader[0 .. min(4, wrongHeader.high)].join(", "))
    if wrongStatus.len > 0:
      checkpoint("status: " & wrongStatus[0 .. min(4, wrongStatus.high)].join(", "))
    # `6` is `UiMode`'s cardinality: CTUI-9 added `umInspect`, §4.1's fourth
    # mode, which CTUI-3 had no indicator for. The literal is deliberate — a
    # `len(UiMode)` here would be computed by the same enum the sweep walks and
    # would stop being able to notice that the sweep skipped a member.
    ck checkedWidths == 240 * (2 + 6 * 3)
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
    ck wide.contains("[demo.ct]")
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
