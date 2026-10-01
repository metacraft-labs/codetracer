## test_real_layout_mouse.nim — PLAT-6, Tier 2: a MOUSE gesture through a real
## pty.
##
## ## What only this file can say
##
## PLAT-6's remaining row, and the reason it was `partial` a second time:
## *"`binding.onMouse`, `beginDrag`, `hoverAt` and `dropDrag` have no caller
## anywhere outside `app/layout/binding.nim` itself and
## `app/tests/test_layout_binding.nim`. `runtime.handleToken` routes the twelve
## `:` verbs and no mouse report at all."* So with `--layout-binding` on, a
## typed `:dock bottom` rearranged a real terminal and a mouse drag did nothing.
##
## `runtime.routeMouseReport` is the wiring. This file drives it the way a user
## does: `apps/app_layout_mouse.nim` hosts the SAME `TuiRuntime` `main.nim`
## builds — through `app_layout_gestures.newBoundRuntime`, so the two Tier-2
## apps cannot disagree about what "with the binding on" means — and this parent
## writes SGR-1006 press and release bytes into a real pty. Every step of the
## path is the product's:
##
##   * the bytes arrive on a real file descriptor and are framed into ONE token
##     by `host/terminal_driver.InputFramer` — the same framer the shipped
##     driver runs, and the reason `handleToken` sees `ESC [ < 0 ; 1 ; 2 M`
##     rather than `<`;
##   * `runtime.handleToken` asks `app/input/mouse.decodeMouse`, which is
##     CTUI-6's decoder unchanged;
##   * `binding.onMouse` turns press-then-release-somewhere-else into a drop;
##   * `layout_interaction.commit` and `layout_model.apply` decide, and the next
##     frame is painted from what they decided.
##
## `app/tests/test_layout_command_routing.nim` asserts the same route in process
## and owns the parts a terminal cannot answer: the resulting `Layout`, the
## screen a runtime with NO binding paints, and the cell-by-cell sweep of which
## dock edges a drop can reach.
##
## ## THE ASSERTION THAT WOULD CATCH BOTH TIERS BEING WRONG TOGETHER
##
## Comparing the terminal against the in-process model is a DIFFERENTIAL check
## and is blind to any defect the two share — a `paintDecorations` that used one
## glyph for every decoration kind paints the same wrong screen in both, and
## every cell-for-cell comparison stays green. So the probes are a SEPARATE
## CASE with its own verdict: each decoration's rectangle is taken from the
## MODEL's own `decorationsFor` and probed on the REAL terminal, and required to
## carry THAT KIND's glyph. The drag reaches two kinds with two different glyphs
## — `ldDragGhost` (`░`) while the pane is being carried and `ldDockStrip` (`·`)
## once it has landed — so a painter that had collapsed the glyph table reddens
## the probe case while the equality case stays green.
##
## `run-plat6-mutations.py`'s M35 is that demonstration rather than this
## paragraph: it plants exactly that defect, declares the differential case
## SPARED, and requires the probe case to die.
##
## ## THE BARRIER IS THE CURSOR, AND IT MOVES PER REPORT
##
## `dual_snap.waitForCompleteFrame` reads "the cursor rests at
## `(rows-1, cols-1)`", which is ALREADY TRUE after the first frame — a mouse
## report opens no prompt, so nothing moves the cursor off it. A parent waiting
## there after a press would be satisfied by the frame BEFORE the press. So the
## child parks the cursor at `(0, step + 1)` after every frame and this file
## waits on `waitForCursorAt`: a position the cursor was not at a moment
## earlier, the first one included, because `(0, 0)` is where a freshly spawned
## terminal's cursor already is.
##
## ## It does not skip
##
## A child that will not compile, a child that never parks its cursor, a `stty`
## that is not there: every one FAILS by name with what was actually observed.
## There is no `when false`, no early return on a missing prerequisite, and no
## `try/except` that turns a failure into a pass.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine, driven by real mouse bytes. The child's `Dispatcher` carries
## no ViewModels, which is not a stand-in for one: `app/commands/interpreter.nim`
## documents nil as "not wired" and answers `drUnavailable` by name, and a
## layout gesture needs no debugger at all.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc` sets a
## module-level global and the case still reports `[OK]` with its failed
## comparison printed directly above it. Every helper here that calls `check` is
## a `template`; the two that are `proc`s return values or record into the
## registers below and call `check` nowhere.

import std/[options, strutils, times, unicode, unittest]

import term_assert

import headless_app/layout_model

import ../../app/runtime
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../../testing/strip_read
import ../apps/app_layout_gestures as gestureApp
import ../apps/app_layout_mouse as mouseApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 52  # PLAT-48: the strip read as labels on blanks (one check where three were)

const
  Stem = "app_layout_mouse"
  Cols = mouseApp.Cols
  Rows = mouseApp.Rows
  FrameTimeoutMs = 20000

  DraggedPane = paneEditor
    ## The shared default's one BARE region at 80x24 (the Source pane, no tab
    ## strip), which is what makes its own title row the cell a press picks it
    ## up by — and makes the drag ghost the pane's whole rectangle, wide enough
    ## for the decoration probe below to read a glyph cell past the ghost's
    ## label. A stacked pane's ghost is only its tab's cells, which its label
    ## covers entirely, so the probe would have nothing to read.
  DraggedPaneTitle = "Source"
  DraggedPaneTitleRow = "SOURCE"
  FocusedAtStart = paneFileTree
    ## Where `newPaneFocus` starts: the shared default's first region. Asserted
    ## so a change of the default that moved it is seen here; the drag itself
    ## does not depend on focus.

  DropRow = 0
  DropCol = 40
    ## THE HEADER ROW. A drop docks a pane when it lands on a cell OUTSIDE the
    ## tree area, and with nothing docked yet the only such cells a terminal has
    ## are the header and the status rows — which is the medium property
    ## `test_layout_command_routing.nim` re-measures over every cell of the
    ## screen. This one docks to `leTop`.

var
  countedAssertions = 0
  probeMismatches: seq[string] = @[]
  probeNotes: seq[string] = @[]
  probesMade = 0
  framesProbed = 0
  kindsProbed: set[LayoutDecorationKind] = {}

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# Values only. Nothing below calls `check`.
# ---------------------------------------------------------------------------

proc sgrReport(button, row, col: int; pressed: bool): string =
  ## One SGR-1006 report, in the exact bytes a terminal puts on the wire.
  ##
  ## Written out rather than taken from `TermAssert.sendMouseClick`, and the
  ## reason is structural rather than distrust: that helper writes a press AND a
  ## release AT ONE CELL, which is a CLICK. A drag is a press at one cell and a
  ## release at another, and no helper in the harness can express it. The case
  ## "the bytes this file writes are the bytes the harness writes" below pins
  ## this encoder against `sendMouseClick` on a real child's own stdin, so the
  ## hand-written form is measured rather than assumed
  ## (Verification-Harness-Traps §9).
  ##
  ## ONE-BASED ON THE WIRE (`app/input/mouse.nim`'s header), which is why every
  ## argument here is zero-based and every field is `+ 1`.
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc catV(s: string): string =
  ## `cat -v`'s rendering of a byte string: `ESC` as `^[`, every other control
  ## character as `^` plus the letter 64 above it. POSIX, and the reason the
  ## byte-level case can read the child's stdin off a SCREEN — the raw bytes
  ## would be parsed as escape sequences by the very terminal doing the reading.
  result = ""
  for ch in s:
    if ch.ord < 32: result.add "^" & $chr(ch.ord + 64)
    else: result.add ch

proc paneRow(sess: var TuiTestSession; row: int): string =
  ## One row of the terminal, with its right-hand padding removed.
  ##
  ## `strutils.strip` IS QUALIFIED, AND THAT IS NOT STYLE. This file imports
  ## `std/unicode` for `Rune`, and `unicode.strip` — which wins the overload on
  ## an unqualified call — returns an all-whitespace string UNCHANGED, so an
  ## assertion that a row is empty fails while every assertion about a row with
  ## content passes. Measured on nim 2.2.8; see `test_real_command_mode.nim`.
  strutils.strip(sess.regionText(row, 0, Cols, 1).split('\n')[0],
                 leading = false)

proc labelCellsOf(d: LayoutDecoration): int =
  ## How many cells `paintDecorations` overwrites with this decoration's label.
  ## Spelled the way the painter spells it — `fitCells` then a trailing strip —
  ## because a probe that guessed would skip the wrong cells.
  if d.label.len == 0: 0
  else: textCells(fitCells(d.label, d.area.width).strip(leading = false))

proc spawnChild(): TuiTestSession =
  compileChildApp(Stem)
  newTuiTest(appBinaryPath(Stem),
             @["--cols=" & $Cols, "--rows=" & $Rows])
    .width(Cols).height(Rows)
    .spawn()

proc probeDecorationsOnTheTerminal(sess: var TuiTestSession;
                                   model: TuiRuntime; label: string) =
  ## **THE HALF THAT SURVIVES BOTH TIERS BEING WRONG TOGETHER.**
  ##
  ## A `proc` THAT RECORDS RATHER THAN A TEMPLATE THAT ASSERTS, and that is not
  ## a violation of trap 13 — it calls `check` nowhere. The findings go into the
  ## module-level registers and are asserted in their OWN case, so the
  ## differential half and the absolute half are two verdicts instead of one.
  ## That separation is the deliverable: a defect both tiers share has to be
  ## able to redden the probe case while the equality case stays green, and it
  ## cannot demonstrate that from inside the same case.
  ##
  ## The probe is taken at each rectangle's LAST cell, because
  ## `paintDecorations` writes the label along the FIRST row of a rectangle and
  ## later decorations paint over earlier ones. Cells covered by either are
  ## skipped and COUNTED, so a frame in which every probe was skipped cannot
  ## pass silently.
  inc framesProbed
  let decorations = model.shellScreenOf().decorations
  var skipped = 0
  for i, d in decorations:
    kindsProbed.incl d.kind
    if d.area.isEmptyArea:
      continue
    var probeRow = d.area.row + d.area.height - 1
    var probeCol = d.area.col + d.area.width - 1
    # PLAT-47: the drag ghost is a LABEL over the frame that follows the
    # pointer, its text the dragged pane's name — probed at its last
    # character, which must be that character.
    let ghostText = if d.kind == ldDragGhost: d.label.strip(leading = false)
                    else: ""
    if d.kind == ldDragGhost:
      probeCol = d.area.col + ghostText.runeLen - 1
    var covered = false
    for j in i + 1 ..< decorations.len:
      if decorations[j].area.contains(probeRow, probeCol):
        covered = true
    if d.kind != ldDragGhost and probeRow == d.area.row and
       probeCol < d.area.col + labelCellsOf(d):
      covered = true
    if covered or probeRow >= Rows or probeCol >= Cols:
      inc skipped
      continue
    inc probesMade
    let rune = $sess.cellAt(probeRow, probeCol).rune
    let want = if d.kind == ldDragGhost: ghostText.runeAt(
                 ghostText.runeOffset(ghostText.runeLen - 1)).`$`
               else: glyphFor(d.kind)
    if rune != want:
      probeMismatches.add label & ": " & $d.kind & " at (" & $probeRow & "," &
        $probeCol & ") reads '" & rune & "' rather than '" & want & "'"
  probeNotes.add label & ": " & $decorations.len & " decoration(s), " &
    $skipped & " skipped"
  if decorations.len == 0:
    probeMismatches.add label & " drew no decoration at all"

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template ckScreenMatches(sess: var TuiTestSession; want: seq[string];
                         label: string) =
  ## Every row of the terminal against every row the in-process runtime
  ## painted. A DIFFERENTIAL check — see this file's header on what it cannot
  ## see and what is asserted beside it.
  block:
    var compared = 0
    var stale: seq[string] = @[]
    for row in 0 ..< Rows:
      inc compared
      let got = paneRow(sess, row)
      let expected = strutils.strip(want[row], leading = false)
      if got != expected:
        stale.add "row " & $row & ":\n  model:    '" & expected &
          "'\n  terminal: '" & got & "'"
    if stale.len > 0:
      checkpoint(label & ":\n" & stale[0 .. min(4, stale.high)].join("\n"))
    ck compared == Rows
    ck stale.len == 0

template ckBothSaw(sess: var TuiTestSession; model: TuiRuntime;
                   token: string; step: int; label: string) =
  ## One mouse report, delivered to the CHILD and to the in-process twin, with
  ## an EXACT barrier for the frame it produces.
  block:
    sess.send(token)
    waitForCursorAt(sess, 0, mouseApp.cursorParkColumn(step, Cols),
                    FrameTimeoutMs)
    let outcome = model.handleToken(token, 0'i64)
    checkpoint(label & " -> " & outcome.detail)
    # The child advanced its step counter because `handleInput` answered TRUE,
    # and the twin says the same thing. A report the runtime declined to repaint
    # for would leave the barrier unreachable, so this is the in-process half of
    # a fact the `waitForCursorAt` above has already established on the child.
    ck outcome.repaint

# ---------------------------------------------------------------------------

suite "PLAT-6 Tier 2: a mouse gesture through a real pty":

  test "a mouse DRAG typed as real bytes docks a pane on a real terminal":
    var sess = spawnChild()
    try:
      # STEP 0's BARRIER, which is not `(rows-1, cols-1)`. See the header.
      waitForCursorAt(sess, 0, mouseApp.cursorParkColumn(0, Cols),
                      FrameTimeoutMs)
      # THE POSITIVE CONTROL on every comparison below: a screen that parsed to
      # nothing satisfies a `strip()`-wise equality for free.
      ck sess.screenContents().strip().len > 0

      # THE IN-PROCESS TWIN, built through the app's OWN constructor so the two
      # runtimes are the same two calls rather than two readings of them.
      let model = gestureApp.newBoundRuntime(Cols, Rows)
      ck model.layoutBindingEnabled()
      let (hadFocus, focused) = model.focus.focusedPane()
      ck hadFocus
      checkpoint("the focused pane is " & $focused)
      ck focused == FocusedAtStart

      # ---- THE UNGESTURED SCREEN -------------------------------------------
      ckScreenMatches(sess, model.shellScreenOf().visibleRows, "before the gesture")
      let before = sess.screenContents()
      # No TOP strip yet: the body starts right under the top bar (PLAT-48's
      # bottom strip, the footer's, is there from the start).
      ck model.layoutGeometry().body.row == 1
      ck before.contains(DraggedPaneTitleRow)
      ck before.contains(" Variables ")     ## the shared default's Variables stack
      ck model.app.layoutBinding.interaction.kind == ikNone

      let source = model.layoutGeometry().regionOfPane(DraggedPane)
      checkpoint("the dragged pane is at " & $source)
      ck not source.isEmptyArea

      # ---- THE PRESS: the pane is picked up --------------------------------
      ckBothSaw(sess, model, sgrReport(0, source.row, source.col, true), 1,
                "press on the pane's title row")
      ck model.app.layoutBinding.interaction.kind == ikDraggingTab
      ck model.app.layoutBinding.interaction.source == DraggedPane
      ckScreenMatches(sess, model.shellScreenOf().visibleRows, "while dragging")
      probeDecorationsOnTheTerminal(sess, model, "while dragging")

      # ---- THE RELEASE, ON A CELL OUTSIDE THE TREE AREA --------------------
      ckBothSaw(sess, model, sgrReport(0, DropRow, DropCol, false), 2,
                "release on the header row")
      # THE MODEL. Only the layout can be asked whether the pane left the tree.
      ck model.app.layoutBinding.layout.dockedIndex(DraggedPane) >= 0
      ck not model.app.layoutBinding.layout.tree.contains(DraggedPane)
      ck model.app.layoutBinding.userModified
      ck model.app.layoutBinding.interaction.kind == ikNone
      ck model.app.layoutBinding.layout.dockedAt(leTop).len == 1

      # THE TERMINAL, differentially…
      ckScreenMatches(sess, model.shellScreenOf().visibleRows, "after the drop")
      probeDecorationsOnTheTerminal(sess, model, "after the drop")

      # …AND ABSOLUTELY. The strip's cells are asserted against the pane's own
      # name, padded, on a blank strip (PLAT-48's strip), neither of which is
      # read off the model's rendering. This pair is M35-IMMUNE by
      # construction, which is exactly why the probe case beside it exists.
      var stripRow = -1
      for s in model.layoutGeometry().strips:
        if s.edge == leTop:
          stripRow = s.area.row
      checkpoint("the top dock strip is on row " & $stripRow)
      ck stripRow == 1                    ## the body's first row, below the header
      let stripText = sess.regionText(stripRow, 0, Cols, 1).split('\n')[0]
      checkpoint("strip row: '" & stripText & "'")
      # EXACT (Verification-Harness-Traps §4b): the label, and nothing but
      # blanks besides.
      let wrongCells = stripLabelProblems(stripText, [DraggedPaneTitle])
      if wrongCells.len > 0:
        checkpoint(wrongCells[0 .. min(4, wrongCells.high)].join(", "))
      ck wrongCells.len == 0
      # AND THE PANE IS GONE FROM THE BODY. A strip drawn beside a pane that was
      # never removed would satisfy every assertion above.
      ck not sess.screenContents().contains(DraggedPaneTitleRow)

      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "the decorations a mouse gesture draws are what the MODEL says":
    # **THE ABSOLUTE HALF, AND IT IS A SEPARATE VERDICT ON PURPOSE.** The case
    # above compares the terminal against the in-process model and is blind to
    # any defect the two share. This reads each decoration's rectangle out of
    # `binding.decorationsFor` — the model's own expectation of WHERE and of
    # WHICH KIND — and requires the REAL terminal to carry that kind's glyph
    # there. A `paintDecorations` that used one glyph for every kind reddens
    # here and leaves the case above green, which is what `run-plat6-mutations
    # .py`'s M35 demonstrates.
    for note in probeNotes:
      checkpoint(note)
    if probeMismatches.len > 0:
      for m in probeMismatches[0 .. min(7, probeMismatches.high)]:
        checkpoint(m)
    ck probeMismatches.len == 0
    # THE POSITIVE CONTROLS. Every one is a count or a set membership, because
    # `probeMismatches.len == 0` is satisfied by a sweep that probed nothing.
    checkpoint("frames probed: " & $framesProbed & ", terminal probes: " &
               $probesMade & ", kinds reached: " & $kindsProbed)
    ck framesProbed == 2
    # Two per frame since PLAT-48: the drag's own decoration and the bottom
    # strip the shared default's footer panels sit on.
    ck probesMade == 4
    # TWO KINDS WITH TWO DIFFERENT GLYPHS, which is the property that makes the
    # probe able to see a collapsed glyph table at all. One kind, or two kinds
    # sharing a glyph, and this case would be as blind as the differential one.
    ck kindsProbed == {ldDragGhost, ldDockStrip}
    # Since PLAT-47 the ghost is a label (the pane's name) and the strip a
    # glyph: the two probes still read two different things.
    ck ghostLabelFor(paneCalltrace).strip != glyphFor(ldDockStrip)

  test "the bytes this file writes are the bytes the harness writes":
    # THE POSITIVE CONTROL ON THE INPUT HELPER (Verification-Harness-Traps §9):
    # `TermAssert.sendKey` silently strips `shift+` and `ctrl+`, so an input
    # helper in this harness is not something to take on trust. The mouse path
    # needs no modifier, and this file spells its own reports because
    # `sendMouseClick` cannot express a drag — so what is measured here is that
    # the encoder above and the harness's own agree, on a REAL child's stdin.
    #
    # `stty raw -echo` first, then `cat -v`: without raw mode the line
    # discipline buffers until a newline and echoes control characters itself,
    # and without `-v` the escape bytes would be parsed as escape sequences by
    # the very terminal being read.
    var sess = newTuiTest(
        "/bin/sh",
        @["-c", "stty raw -echo; printf READY; exec cat -v"])
      .width(Cols).height(Rows).spawn()
    try:
      # THE CHILD HAS TO HAVE RUN `stty` BEFORE ANYTHING IS SENT, or the line
      # discipline buffers the bytes and echoes them itself — measured, and it
      # is a race rather than a certainty: a readiness byte sent and echoed by
      # BOTH the kernel and `cat` reads back doubled. So the child announces
      # itself instead and nothing is written to its stdin until it has: the
      # barrier is `READY` on the screen, which cannot appear before `stty` has
      # returned.
      let probeRow = 3
      let probeCol = 5
      let ready = "READY"
      var seen = ""
      let readyDeadline = getTime() + initDuration(seconds = 15)
      while getTime() < readyDeadline:
        discard sess.drainOutput(50)
        seen = strutils.strip(sess.screenContents().split('\n')[0],
                              leading = false)
        if seen == ready:
          break
      checkpoint("the child announced: '" & seen & "'")
      ck seen == ready

      let mine = sgrReport(0, probeRow, probeCol, true) &
                 sgrReport(0, probeRow, probeCol, false)
      let wanted = ready & catV(mine)
      sess.sendMouseClick(probeRow, probeCol)
      let deadline = getTime() + initDuration(seconds = 15)
      while getTime() < deadline:
        discard sess.drainOutput(50)
        seen = strutils.strip(sess.screenContents().split('\n')[0],
                              leading = false)
        if seen.len >= wanted.len:
          break
      checkpoint("harness wrote: '" & seen & "'")
      checkpoint("this file wrote: '" & wanted & "'")
      # A NON-VACUITY FLOOR FIRST: an empty screen would satisfy an equality
      # against an empty expectation, and a short one would satisfy nothing at
      # all without saying why.
      ck seen.len == wanted.len
      ck seen == wanted
      # …and the encoding really is 1-based on the wire, asserted against the
      # ZERO-based arguments both sides were given rather than against each
      # other.
      ck wanted.contains(";" & $(probeCol + 1) & ";" & $(probeRow + 1) & "M")
      sess.terminate()
    finally:
      sess.close()

  test "a mouse drag on a DIVIDER moves it on a real terminal":
    # PLAT-5's divider drag, through the product's own input loop: a press on
    # the last column of a region whose neighbour across it is its sibling,
    # then a release further left, as real SGR-1006 bytes on a real pty.
    var sess = spawnChild()
    try:
      waitForCursorAt(sess, 0, mouseApp.cursorParkColumn(0, Cols),
                      FrameTimeoutMs)
      ck sess.screenContents().strip().len > 0
      let model = gestureApp.newBoundRuntime(Cols, Rows)
      let geom = model.layoutGeometry()
      # FIND a divider cell with a scratch runtime, so the child and the twin
      # below both see exactly one press and one release. A region's middle
      # row, never its title row, so the press is not a pane pick-up.
      var pressRow = -1
      var pressCol = -1
      for r in geom.projection.regions:
        if pressRow >= 0:
          break
        let row = r.area.row + r.area.height div 2
        let col = r.area.col + r.area.width - 1
        if col + 1 >= Cols or r.area.width < 12:
          continue
        let scratch = gestureApp.newBoundRuntime(Cols, Rows)
        discard scratch.handleToken(sgrReport(0, row, col, true), 0'i64)
        if scratch.app.layoutBinding.interaction.kind == ikResizingSplit:
          pressRow = row
          pressCol = col
      checkpoint("divider cell: (" & $pressRow & "," & $pressCol & ")")
      ck pressRow >= 0
      if pressRow >= 0:
        let before = sess.screenContents()
        let leftPane = geom.projection.regions[
          geom.regionIndexAt(pressRow, pressCol)].pane
        let was = geom.regionOfPane(leftPane)
        ckBothSaw(sess, model, sgrReport(0, pressRow, pressCol, true), 1,
                  "press on the divider")
        ck model.app.layoutBinding.interaction.kind == ikResizingSplit
        ckBothSaw(sess, model, sgrReport(0, pressRow, pressCol - 6, false), 2,
                  "release six columns to the left")
        ck model.app.layoutBinding.interaction.kind == ikNone
        ck model.app.layoutBinding.userModified
        ck model.app.layoutBinding.history.log.len == 1
        let now = model.layoutGeometry().regionOfPane(leftPane)
        checkpoint($leftPane & ": " & $was & " -> " & $now)
        # Cell rounding may land the edge one cell either side of the release.
        ck abs((now.col + now.width - 1) - (pressCol - 6)) <= 1
        # The terminal, differentially against the twin, and absolutely: the
        # screen is not the one before the drag.
        ckScreenMatches(sess, model.shellScreenOf().visibleRows, "after the drag")
        ck sess.screenContents() != before
      sess.send($TestAppQuitByte)
      let status = sess.waitExit(initDuration(seconds = 10))
      ck status.isSome
      ck status.get() == TestAppExitOk
    finally:
      sess.terminate()
      sess.close()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
