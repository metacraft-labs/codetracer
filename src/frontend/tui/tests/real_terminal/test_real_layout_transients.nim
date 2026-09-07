## test_real_layout_transients.nim — PLAT-6, Tier 2.
##
## ## What only this file can say
##
## PLAT-6's unticked row: *"Cross-tier snapshot equivalence for each transient
## state. Not done."* This is it — the drag ghost, the highlighted drop target,
## the resize guide, the auto-hide strips and the reveal overlay, each
## composited in process through `TerminalTestHarness` AND in a spawned child
## that writes its bytes into a real pty, parsed by a real terminal state
## machine, written as six-format snapshot directories and compared CELL FOR
## CELL.
##
## Until this holds, every Tier-1 assertion about a decoration is
## self-referential: `app/tests/test_layout_binding.nim` reads `cellAt` off the
## same in-process compositor that produced the ANSI, so nothing in Tier 1 can
## notice that the compositor's idea of a `▒` and a terminal's idea of it have
## come apart. CTUI-2 found three defects in exactly that seam on its first run,
## and `binding.paintDecorations` is the one place in this front-end that writes
## one-cell glyphs OVER an already-painted grid — `healWideEdges` exists because
## of it.
##
## ## CROSS-TIER EQUALITY IS NECESSARY AND IT IS NOT SUFFICIENT
##
## **Read this before treating a green run here as evidence about the
## decorations.** A differential check is blind to any defect the two tiers
## SHARE. If `decorationsFor` produced the wrong rectangle, or `glyphFor`
## returned the wrong glyph, both tiers would paint the same wrong screen and
## every comparison below would pass. PLAT-6's own status note says exactly this
## about cross-tier equality, and it is the reason the hit-test's evidence is a
## cell-grid sweep rather than a snapshot.
##
## So each state carries a second assertion that does NOT go through the
## comparison: the decoration's own rectangle, taken from
## `binding.decorationsFor` — the MODEL's expectation — is probed on the REAL
## terminal and required to hold that kind's glyph. A shared defect in the glyph
## table or in the rectangle reddens that probe while leaving the equality
## green, which is the whole point of writing it.
##
## The probe is deliberately taken at each rectangle's LAST cell: `paintDecorations`
## writes the label along the FIRST row of a rectangle and later decorations
## paint over earlier ones, so a probe at the origin would be asserting about
## whichever of those won. Cells covered by a later decoration or by the label
## are skipped and COUNTED, so a state in which every probe was skipped cannot
## pass silently.
##
## ## THE BARRIER MOVES PER STATE, AND THAT IS NOT COSMETIC
##
## `dual_snap.waitForCompleteFrame` reads "the cursor rests at
## `(rows-1, cols-1)`", which is already true after the first frame — so it
## cannot tell a repaint caused by F10 from the frame before it, and a snapshot
## taken on that barrier would compare the PREVIOUS state's screen with this
## state's model. `apps/app_layout_transients.nim` therefore parks the cursor at
## `(0, step + 1)` after every frame and this file waits on `waitForCursorAt`,
## which is a position the cursor was not at a moment earlier — `step + 1`
## rather than `step` because a freshly spawned terminal's cursor is already at
## `(0, 0)`, so waiting for that would be satisfied before the child wrote a
## byte and would snapshot a blank screen.
##
## ## It does not skip
##
## A child that will not compile, a child that never parks its cursor, a tier
## that did not write one of the six files: every one FAILS by name.
## `compareSnapshotDirs` itself refuses two directories written by the same
## tier, which is the vacuous pass this construction exists to prevent.
##
## ## No mocks
##
## There is no mock here and no ViewModel at all: the subject is the renderer,
## the terminal and PLAT-6's decoration layer, and all three are real. The
## child's only input is F10, sent by the parent through the kernel.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13.

import std/[options, os, strutils, times, unicode, unittest]

import isonim_tui
import term_assert

import ../../app/views/shell
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../apps/app_layout_transients as transApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 57

const
  Stem = "app_layout_transients"
  FrameTimeoutMs = 20000

  Geometries = [(cols: 80, rows: 24), (cols: 120, rows: 40)]
    ## CTUI-2's two, for its reason: 80x24 clips content that 120x40 does not,
    ## and it selects a different profile — so the arrangement each state's
    ## gesture is made against differs as well as the width it is drawn at.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc labelCellsOf(d: LayoutDecoration): int =
  ## How many cells `paintDecorations` overwrites with this decoration's label.
  ## Spelled the way the painter spells it — `fitCells` then a trailing strip —
  ## because a probe that guessed would skip the wrong cells.
  if d.label.len == 0: 0
  else: textCells(fitCells(d.label, d.area.width).strip(leading = false))

proc modelDecorations(state: transApp.TransientState;
                      cols, rows: int): seq[LayoutDecoration] =
  ## What the MODEL says will be drawn — `binding.decorationsFor` over the same
  ## model the app paints. Not read back off the screen, which is the whole
  ## point of it.
  let model = transApp.modelFor(state, cols, rows)
  let composed = initLayout(model.layout, model.docked)
  let geom = geometryOf(composed, bodyArea(cols, rows), model.interaction)
  decorationsFor(composed, geom, model.interaction)

proc paintedCellsOfModel(state: transApp.TransientState;
                         cols, rows: int): int =
  ## The number of non-blank cells the model says the screen has. The
  ## non-vacuity floor for the comparison: two tiers that agree the screen is
  ## blank satisfy a cell-for-cell equality for free (Verification-Harness-Traps
  ## §4b), and this number is knowable because the tree is a pure function of
  ## the geometry.
  for line in shellRows(transApp.modelFor(state, cols, rows), cols, rows):
    for r in runes(line):
      if $r != " ":
        inc result

# ---------------------------------------------------------------------------
# The probe registers. Filled by the sweep in the first case and asserted in
# the second, so a defect both tiers share reddens the ABSOLUTE case while the
# DIFFERENTIAL one stays green — which is the distinction the header is about.
# ---------------------------------------------------------------------------

var
  probeMismatches: seq[string] = @[]
  probeNotes: seq[string] = @[]
  emptyStates: seq[string] = @[]
  drawnStates: seq[string] = @[]
  probesMade = 0
  kindsProbed: set[LayoutDecorationKind] = {}
  statesSwept = 0

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template ckEquivalent(sess: var TuiTestSession;
                      state: transApp.TransientState;
                      atCols, atRows, atStep: int) =
  ## One state, two tiers, compared cell for cell — plus the floor that says
  ## the screen they agree about is the screen the model describes.
  ##
  ## THE PARAMETERS ARE NOT CALLED `cols` / `rows`: `std/unittest`'s templates
  ## are not hygienic here, so `canon.rows` with a parameter named `rows`
  ## substitutes the ARGUMENT into the field access — `canon.g.rows`, which does
  ## not compile and whose error names neither the template nor the call.
  ## `test_real_command_mode.nim` records the same trap for `pos.row`.
  block:
    let caseName = Stem & "-" & $state & "-" & $atCols & "x" & $atRows
    let base = dualSnapCaseDir(caseName)
    removeDir(base)
    let tier1 = base / "tier1"
    let tier2 = base / "tier2"

    let h = newTerminalTestHarness(atCols, atRows)
    try:
      h.mount(proc (r: TerminalRenderer): TerminalNode =
        transApp.buildTree(r, atCols, atRows, atStep))
      h.flush()
      writeTier1Snapshot(h, tier1)
    finally:
      h.dispose()
    writeTier2Snapshot(sess, tier2)

    let divergences = compareSnapshotDirs(tier1, tier2)
    if divergences.len > 0:
      checkpoint(caseName & ": " & $divergences.len & " divergence(s)")
      for d in divergences[0 .. min(4, divergences.high)]:
        checkpoint(describe(d))
    ck divergences.len == 0

    # THE FLOOR, as the EXACT count rather than "more than none".
    let canon = canonFromDir(tier1)
    let painted = countCellsWhere(canon, proc(c: CanonCell): bool =
      c.rune != " " and c.rune.len > 0)
    let wanted = paintedCellsOfModel(state, atCols, atRows)
    checkpoint(caseName & ": " & $painted & " painted cell(s) of " &
               $(canon.rows * canon.cols) & ", model says " & $wanted)
    ck painted == wanted
    ck painted > 0

proc probeDecorationsOnTheTerminal(sess: var TuiTestSession;
                                   state: transApp.TransientState;
                                   atCols, atRows: int) =
  ## **THE HALF THAT SURVIVES BOTH TIERS BEING WRONG TOGETHER.** Every
  ## decoration the MODEL says is on this frame is probed on the REAL terminal
  ## and required to carry that kind's glyph.
  ##
  ## A `proc` THAT RECORDS RATHER THAN A TEMPLATE THAT ASSERTS, and that is not
  ## a violation of trap 13 — it calls `check` nowhere. The findings go into the
  ## module-level registers below and are asserted in their OWN test case, so
  ## the differential half and the absolute half are two verdicts instead of
  ## one. That separation is the deliverable: a defect both tiers share must be
  ## able to redden the probe case while the equality case stays green, and it
  ## cannot demonstrate that from inside the same case.
  block:
    let decorations = modelDecorations(state, atCols, atRows)
    var skipped = 0
    var wrong: seq[string] = @[]
    for i, d in decorations:
      kindsProbed.incl d.kind
      if d.area.isEmptyArea:
        continue
      let probeRow = d.area.row + d.area.height - 1
      let probeCol = d.area.col + d.area.width - 1
      # A later decoration paints over this one, so the cell would be asserted
      # against the wrong kind.
      var covered = false
      for j in i + 1 ..< decorations.len:
        if decorations[j].area.contains(probeRow, probeCol):
          covered = true
      # …and so does this decoration's own label, which is written along the
      # first row of its rectangle after the fill.
      if probeRow == d.area.row and
         probeCol < d.area.col + labelCellsOf(d):
        covered = true
      if covered or probeRow >= atRows or probeCol >= atCols:
        inc skipped
        continue
      inc probesMade
      let rune = $sess.cellAt(probeRow, probeCol).rune
      if rune != glyphFor(d.kind):
        wrong.add $d.kind & " at (" & $probeRow & "," & $probeCol &
          ") reads '" & rune & "' rather than '" & glyphFor(d.kind) & "'"
    for w in wrong:
      probeMismatches.add $state & " at " & $atCols & "x" & $atRows & ": " & w
    probeNotes.add $state & " at " & $atCols & "x" & $atRows & ": " &
      $decorations.len & " decoration(s), " & $skipped & " skipped"
    # `tsNone` is the one state with nothing to draw, and recording that is
    # what stops "no wrong cells" from being a statement about an empty list
    # everywhere else.
    if state == transApp.tsNone:
      emptyStates.add $state & " at " & $atCols & "x" & $atRows &
        " had " & $decorations.len
      if decorations.len != 0:
        probeMismatches.add $state & " should draw nothing and drew " &
          $decorations.len
    elif decorations.len == 0:
      probeMismatches.add $state & " at " & $atCols & "x" & $atRows &
        " drew no decoration at all"
    else:
      drawnStates.add $state & " at " & $atCols & "x" & $atRows

# ---------------------------------------------------------------------------

suite "PLAT-6 Tier 2: the transient states, harness against a real terminal":

  test "every transient state is the same screen in both tiers, cell for cell":
    var casesCompared = 0
    for g in Geometries:
      compileChildApp(Stem)
      var sess = newTuiTest(appBinaryPath(Stem),
                            @["--cols=" & $g.cols, "--rows=" & $g.rows])
        .width(g.cols).height(g.rows)
        .spawn()
      try:
        for step in 0 ..< transApp.TransientStateCount:
          if step > 0:
            # F10 — the runtime's own step key, sent as the exact bytes
            # `TermAssert.sendKey("f10")` writes.
            sess.send(TestAppStepKey)
          # THE BARRIER FOR THIS STEP, not for some frame. See the header.
          waitForCursorAt(sess, 0, transApp.cursorParkColumn(step, g.cols),
                          FrameTimeoutMs)
          let state = transApp.stateFor(step)
          inc casesCompared
          inc statesSwept
          ckEquivalent(sess, state, g.cols, g.rows, step)
          # RECORDED HERE, ASSERTED IN THE NEXT CASE. See the registers above.
          probeDecorationsOnTheTerminal(sess, state, g.cols, g.rows)
        sess.send($TestAppQuitByte)
        let status = sess.waitExit(initDuration(seconds = 10))
        ck status.isSome
        ck status.get() == TestAppExitOk
      finally:
        sess.terminate()
        sess.close()

    # THE POSITIVE CONTROL for the DIFFERENTIAL half, as a count rather than
    # "more than none" (Verification-Harness-Traps §4b): the membership is
    # known, so a sweep that skipped a state reddens here.
    checkpoint("states compared: " & $casesCompared)
    ck casesCompared == Geometries.len * transApp.TransientStateCount

  test "the decorations are what the MODEL says, on the real terminal":
    # **THE ABSOLUTE HALF, AND IT IS A SEPARATE VERDICT ON PURPOSE.** The case
    # above is a differential check and is blind to any defect the two tiers
    # share: a `paintDecorations` that drew one glyph for every kind would paint
    # the same wrong screen in both, and every comparison there would stay
    # green. This reads each decoration's rectangle out of
    # `binding.decorationsFor` — the model's own expectation — and requires the
    # REAL terminal to carry that kind's glyph there.
    #
    # `run-plat6-mutations.py` carries the arm that demonstrates the split: it
    # makes the painter use one glyph for every decoration, and the case above
    # survives while this one dies.
    for note in probeNotes:
      checkpoint(note)
    if probeMismatches.len > 0:
      for m in probeMismatches[0 .. min(7, probeMismatches.high)]:
        checkpoint(m)
    ck probeMismatches.len == 0
    # THE POSITIVE CONTROLS. Every one is a count or a set membership, because
    # `probeMismatches.len == 0` is satisfied by a sweep that probed nothing.
    checkpoint("states swept: " & $statesSwept & ", terminal probes: " &
               $probesMade & ", kinds reached: " & $kindsProbed)
    ck statesSwept == Geometries.len * transApp.TransientStateCount
    ck probesMade > 0
    # THE TWO SIDES OF THE POPULATION, so neither is free: exactly the
    # ungestured state draws nothing, and every other one draws something.
    ck emptyStates.len == Geometries.len
    ck drawnStates.len == Geometries.len * (transApp.TransientStateCount - 1)
    # EVERY DECORATION KIND WAS REACHED. A state list that had stopped
    # producing, say, a resize guide would leave every assertion above true.
    for kind in LayoutDecorationKind:
      ck kind in kindsProbed

  test "MUTATION ARM: a changed cell fails the comparison and names it":
    # A DELIVERABLE, NOT A DEMONSTRATION — CTUI-2's rule. A comparison that
    # cannot be made to fail is indistinguishable from one that is not reading
    # the files, and everything above it is a chain of green.
    #
    # The control is the same pair of directories the run above left behind:
    # they have just compared EQUAL, so a red result here can only be the
    # mutation.
    let dir = dualSnapCaseDir(Stem & "-" & $transApp.tsDragging & "-120x40")
    let tier1 = dir / "tier1"
    let tier2 = dir / "tier2"
    ck dirExists(tier1)
    ck dirExists(tier2)
    let control = compareSnapshotDirs(tier1, tier2)
    if control.len > 0:
      checkpoint("CONTROL FAILED — the arm below would be meaningless:\n" &
                 describe(control[0]))
    ck control.len == 0

    # A CELL THAT CARRIES A DECORATION, not (0,0): mutating a blank cell would
    # be an arm about the comparison rather than about the decorations, and a
    # hard-coded coordinate keeps passing after the layout moves the content.
    let target = firstCellWhere(tier1, proc(c: CanonCell): bool =
      c.rune == glyphFor(ldDropTarget))
    checkpoint("mutating the drop-target cell (" & $target.row & "," &
               $target.col & ")")
    ck target.row >= 0
    let before = cellAtCanon(tier1, target.row, target.col)
    ck before.rune == glyphFor(ldDropTarget)
    mutateCellmapRune(tier1, target.row, target.col, "X")
    let after = compareSnapshotDirs(tier1, tier2)
    ck after.len == 1
    if after.len == 1:
      let d = after[0]
      checkpoint(describe(d))
      # THE CELL, BY COORDINATE. "screens differ" is not a diagnosis.
      ck d.kind == dkCell
      ck d.row == target.row
      ck d.col == target.col
      ck d.tier1.contains("'X'")
      ck d.tier2.contains(before.rune)
      ck d.summary == "the runes differ"

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
