## test_cross_tier_snapshot_equivalence.nim — CTUI-2, the keystone.
##
## ## The claim
##
## For each snapshot app, at 80x24 and at 120x40: composite the tree in process
## through `TerminalTestHarness`, composite THE SAME PROC in a spawned child
## that writes its bytes into a real pty, parse those bytes with a real
## terminal state machine, write both as six-format snapshot directories, and
## assert they are equal cell for cell.
##
## Until this holds, every Tier-1 golden in the campaign is self-referential:
## all six formats are derived from the same in-process model that produced the
## ANSI, so nothing in Tier 1 can notice that the compositor's idea of the
## screen and a terminal's idea of it have come apart.
##
## ## It found three defects on its first run
##
## They are recorded in `src/frontend/tui/testing/dual_snap.nim`'s header with
## the measurements that established them: a compositor that never wrote a
## ghost cell (one column of drift per wide glyph), a libvterm binding that
## raised `RangeDefect` on the trailing half of every wide glyph, and two
## snapshot encoders that disagreed about that half and about underline. All
## three are in sibling libraries, all three were invisible to either tier
## alone, and all three sat inside green runs.
##
## ## No mocks, and nothing is faked
##
## There is no `MockBackendService` here and no ViewModel at all: the subject is
## the renderer and the terminal, and both are real. The `Pilot`-class
## permitted fake is not used either — the child's only input is one byte on a
## real pty, sent by the parent through the kernel.
##
## ## It does not skip
##
## A missing grammar archive, a child that will not compile, a child that never
## finishes a frame: every one of them FAILS, by name, with the recipe or the
## measurement that explains it. There is no `when false`, no early return on a
## missing prerequisite, and no `try/except` that converts a failure into a
## pass. The one `except DualSnapError` block in this file is the same-tier
## refusal arm, which captures the message in order to ASSERT ON IT; an
## exception that never arrived leaves the message empty and reddens the
## `raised.contains(...)` checks below it.

import std/[os, strutils, unittest]

import isonim_tui

import ../../testing/dual_snap

import ../apps/app_borders as borderApp
import ../apps/app_color_depth as colorApp
import ../apps/app_command_palette as paletteApp
import ../apps/app_overlay as overlayApp
import ../apps/app_scroll_viewport as scrollApp
import ../apps/app_wide_glyphs as wideApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 79

const
  Geometries = [(cols: 80, rows: 24), (cols: 120, rows: 40)]
    ## Both, for every app. The milestone asks for it and the reason is
    ## concrete: 80x24 clips content every app deliberately overflows, 120x40
    ## does not, and a width bug that only bites at a clip boundary is exactly
    ## the one a single geometry misses.

var countedAssertions = 0

template ck(condition: untyped) =
  ## `check`, counted — see codetracer-specs/Testing/
  ## Verification-Harness-Traps.md §4c. A case that returned early or a loop
  ## that skipped a member reddens the file on the spot.
  inc countedAssertions
  check condition

# TEMPLATES, NOT PROCS, AND THE REASON IS A HARNESS DEFECT THIS SUITE HAD.
#
# `std/unittest`'s `check` reports a failure by assigning `testStatusIMPL`, a
# variable the `test` template injects into its own scope. Inside a `proc` that
# symbol is not visible, so `check` takes its `else` branch — it sets
# `programResult = 1` and prints the failure, and THE TEST STILL REPORTS [OK].
# Measured, in the first run of this file: two `Check failed:` lines for
# `app_wide_glyphs` appeared in the log under a case marked `[OK]`, and the
# suite's own `[FAILED]` count did not move.
#
# That is codetracer-specs/Testing/Verification-Harness-Traps.md's common
# thread exactly — a harness reporting a state it did not reach — and it is the
# more dangerous half of it, because the per-case verdict is what
# `ci/lib/run-nim-test-lane.sh` tallies. As templates these expand INSIDE the
# test block, where `testStatusIMPL` is in scope and a failure is a failure.
template equivalent(stem: string; build: untyped;
                    cols, rows: int): DualSnapResult =
  ## Run one case and assert equality, printing the full divergence report and
  ## the exclusion register when it fails.
  block:
    let res = runDualSnap(stem, build, cols, rows)
    if res.divergences.len > 0:
      checkpoint(report(res))
    ck res.divergences.len == 0
    res

template bothGeometries(stem: string; build: untyped;
                        painted80, painted120: int) =
  ## Both geometries, plus the non-vacuity floor for each.
  ##
  ## The floor is the EXACT painted-cell count, not "more than none" — trap 4b:
  ## an existential control is satisfied by one member of a set whose size is
  ## knowable, and this one is knowable, because every app's tree is a pure
  ## function of nothing. A screen the two tiers agree is BLANK would satisfy
  ## the equality above for free, and so would one that had quietly lost half
  ## its rows.
  for g in Geometries:
    let res = equivalent(stem, build, g.cols, g.rows)
    let canon = canonFromDir(res.tier1Dir)
    let painted = countCellsWhere(canon, proc(c: CanonCell): bool =
      c.rune != " " and c.rune.len > 0)
    let expected = if g.cols == 80: painted80 else: painted120
    checkpoint(stem & " at " & $g.cols & "x" & $g.rows & ": " & $painted &
               " painted cell(s) of " & $(canon.rows * canon.cols) &
               ", expected " & $expected)
    ck painted == expected

suite "CTUI-2: cross-tier snapshot equivalence":

  test "the exclusion register is what review approved":
    # An exclusion added without this number moving is an exclusion nobody
    # reviewed. The register itself is printed so a reader of a GREEN run can
    # see what the comparison stopped checking, which is the half of an
    # exclusion policy that usually goes missing.
    #
    # `echo`, NOT `checkpoint`, and the difference is the whole point of the
    # sentence above: `std/unittest` accumulates checkpoints and flushes them
    # only from `fail()`, so a `checkpoint` here would print on a RED run and
    # nowhere else — exactly the case where the register is least needed.
    # (`report()` still checkpoints it beside a divergence, which is where a
    # reader of a failure wants it.) The lane captures a green file's stdout,
    # so this is read by running the suite binary directly.
    echo renderExclusions()
    ck CrossTierExclusions.len == CrossTierExclusionCount
    ck CrossTierCanonicalisations.len == 2
    # Every entry carries the two fields that make it reviewable. An
    # exclusion with an empty `evidence` is the "unexplained exclusion" the
    # milestone says fails review, and it fails here instead.
    var withoutEvidence: seq[string] = @[]
    var withoutJustification: seq[string] = @[]
    for e in CrossTierExclusions:
      if e.evidence.strip().len == 0: withoutEvidence.add e.name
      if e.justification.strip().len == 0: withoutJustification.add e.name
    ck withoutEvidence.len == 0
    ck withoutJustification.len == 0
    # `canDim` is excluded and it is the ONLY attribute that is.
    ck canDim notin ComparedAttrs
    ck ComparedAttrs == {canBold, canItalic, canReverse, canBlink, canConceal,
                         canStrike}

  test "borders: box drawing survives the round trip":
    bothGeometries("app_borders", borderApp.buildTree, 1841, 3026)

  test "wide glyphs: CJK beside a combining mark next to a border":
    bothGeometries("app_wide_glyphs", wideApp.buildTree, 159, 174)

  test "colour depth: default, 16-colour, truecolor and every attribute":
    bothGeometries("app_color_depth", colorApp.buildTree, 294, 460)

  test "scroll viewport: a window into a longer document":
    bothGeometries("app_scroll_viewport", scrollApp.buildTree, 560, 819)

  test "overlays: layer ordering and opaque fills":
    bothGeometries("app_overlay", overlayApp.buildTree, 1279, 1279)

  test "the command palette: reverse-video selection and accented match runs":
    # CTUI-10's one new pane. `docs/tui-testing.md`: "A new pane needs exactly
    # one cross-tier equivalence test. Not zero, and not one per assertion."
    bothGeometries("app_command_palette", paletteApp.buildTree, 557, 637)

  test "the dim exclusion is exercised, not hypothetical":
    # The `dim-has-no-tier-2-representation` exclusion stops the comparison
    # looking at one attribute. An exclusion no case produces is an exclusion
    # nobody can check, so this asserts the Tier-1 side really does carry dim
    # cells — and that Tier 2 really does not see them, which is the fact the
    # exclusion claims.
    let dir = dualSnapCaseDir("app_color_depth-80x24")
    ck dirExists(dir / "tier1")
    let tier1 = canonFromDir(dir / "tier1")
    let tier2 = canonFromDir(dir / "tier2")
    let dim1 = countCellsWhere(tier1, proc(c: CanonCell): bool =
      canDim in c.attrs)
    let dim2 = countCellsWhere(tier2, proc(c: CanonCell): bool =
      canDim in c.attrs)
    checkpoint("dim cells: tier 1 " & $dim1 & ", tier 2 " & $dim2)
    ck dim1 >= len(colorApp.DimRowText)
    ck dim2 == 0
    # And the same cells agree about everything the comparison DOES look at,
    # which is why excluding one bit is not the same as excluding the row.
    let pos = firstCellWhere(dir / "tier1", proc(c: CanonCell): bool =
      canDim in c.attrs)
    ck pos.row >= 0
    if pos.row >= 0:
      let a = cellAtCanon(dir / "tier1", pos.row, pos.col)
      let b = cellAtCanon(dir / "tier2", pos.row, pos.col)
      checkpoint("dim cell (" & $pos.row & "," & $pos.col & "): tier1 " &
                 describeStyle(a) & " | tier2 " & describeStyle(b))
      ck a.rune == b.rune
      ck a.fg == b.fg

  test "the combining mark is dropped before the bytes are emitted":
    # WHAT THE HOSTILE CASE ACTUALLY PROVES. isonim-tui's `rawCellsForEntry`
    # skips every rune of display width 0, so U+0301 never reaches the pty and
    # both tiers agree about a screen it is absent from. Asserting the current
    # behaviour rather than letting a green equivalence run imply the stronger
    # claim: the day the compositor attaches combining marks to their base
    # cluster, this case goes red and somebody reads the sentence above.
    let dir = dualSnapCaseDir("app_wide_glyphs-120x40")
    let tier1 = readFile(dir / "tier1" / "plaintext.txt")
    let tier2 = readFile(dir / "tier2" / "plaintext.txt")
    # Positive twin first, through the same strings: a plaintext that failed to
    # be written would satisfy both "does not contain" assertions for free.
    ck tier1.contains("世界")
    ck tier2.contains("世界")
    ck not tier1.contains(wideApp.CombiningAcute)
    ck not tier2.contains(wideApp.CombiningAcute)

  test "wide glyphs occupy two columns on both sides of the comparison":
    # The defect this milestone found, asserted directly rather than only
    # through the equality: a compositor that stopped writing ghost cells would
    # still be self-consistent at Tier 1.
    let dir = dualSnapCaseDir("app_wide_glyphs-120x40")
    let tier1 = canonFromDir(dir / "tier1")
    let tier2 = canonFromDir(dir / "tier2")
    let wide1 = countCellsWhere(tier1, proc(c: CanonCell): bool = c.width == 2)
    let ghost1 = countCellsWhere(tier1, proc(c: CanonCell): bool = c.width == 0)
    let wide2 = countCellsWhere(tier2, proc(c: CanonCell): bool = c.width == 2)
    let ghost2 = countCellsWhere(tier2, proc(c: CanonCell): bool = c.width == 0)
    checkpoint("wide/ghost cells: tier 1 " & $wide1 & "/" & $ghost1 &
               ", tier 2 " & $wide2 & "/" & $ghost2)
    ck wide1 > 40
    ck wide1 == ghost1
    ck wide2 == wide1
    ck ghost2 == ghost1

  test "all six formats are written by both tiers":
    # The four formats the comparison does NOT read still have to exist. A
    # tier that stopped writing one would otherwise pass this suite silently,
    # and "the two directories are interchangeable" is the property every
    # golden recorded after this milestone rests on.
    var checkedFiles = 0
    var missing: seq[string] = @[]
    for g in Geometries:
      let dir = dualSnapCaseDir("app_borders-" & $g.cols & "x" & $g.rows)
      for tier in ["tier1", "tier2"]:
        for name in SnapAllFiles:
          inc checkedFiles
          if not fileExists(dir / tier / name):
            missing.add tier & "/" & name & " (" & $g.cols & "x" & $g.rows & ")"
    checkpoint("snapshot files checked: " & $checkedFiles)
    ck checkedFiles == 2 * 2 * SnapAllFiles.len
    if missing.len > 0:
      checkpoint("missing: " & missing.join(", "))
    ck missing.len == 0

  test "MUTATION ARM: one changed rune fails the comparison and names the cell":
    # A DELIVERABLE, NOT A DEMONSTRATION. A comparison that cannot be made to
    # fail is indistinguishable from one that is not reading the files, and
    # everything above it is a chain of green.
    #
    # The control is the same pair of directories in the same run: they have
    # just compared EQUAL in the borders case above, so a red result here can
    # only be the mutation.
    let dir = dualSnapCaseDir("app_borders-80x24")
    let tier1 = dir / "tier1"
    let tier2 = dir / "tier2"
    let control = compareSnapshotDirs(tier1, tier2)
    if control.len > 0:
      checkpoint("CONTROL FAILED — the arm below would be meaningless:\n" &
                 describe(control[0]))
    ck control.len == 0

    # Pick a painted cell rather than (0,0): a hard-coded coordinate keeps
    # passing after a layout change moved the content, which is the arm
    # quietly mutating a blank cell it would have caught anyway.
    let target = firstCellWhere(tier1, proc(c: CanonCell): bool =
      c.rune == "─")
    checkpoint("mutating cell (" & $target.row & "," & $target.col & ")")
    ck target.row >= 0
    let before = cellAtCanon(tier1, target.row, target.col)
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
      # BOTH RUNES, in the report, with their codepoints.
      ck d.tier1.contains("'X'")
      ck d.tier1.contains("U+0058")
      ck d.tier2.contains(before.rune)
      # AND BOTH STYLE SETS, so a divergence in colour is as legible as one in
      # text.
      ck d.tier1.contains("fg=")
      ck d.tier2.contains("attrs=")
      ck d.summary == "the runes differ"
    # Restored, so the directory is the pristine artifact a reader inspects
    # after the run — and so the next arm's control is honest.
    let restored = runDualSnap("app_borders", borderApp.buildTree, 80, 24)
    ck restored.divergences.len == 0

  test "MUTATION ARM: one changed style fails the comparison and names it":
    # The rune arm alone would leave a comparison that reads only text passing
    # every style question in the suite. This one changes NOTHING a plaintext
    # diff could see.
    let dir = dualSnapCaseDir("app_color_depth-120x40")
    let tier1 = dir / "tier1"
    let tier2 = dir / "tier2"
    let control = compareSnapshotDirs(tier1, tier2)
    if control.len > 0:
      checkpoint("CONTROL FAILED:\n" & describe(control[0]))
    ck control.len == 0

    let target = firstCellWhere(tier1, proc(c: CanonCell): bool =
      c.rune != " " and c.attrs == {})
    checkpoint("adding attrBold at (" & $target.row & "," & $target.col & ")")
    ck target.row >= 0
    mutateCellmapAttr(tier1, target.row, target.col, "attrBold")
    let after = compareSnapshotDirs(tier1, tier2)
    ck after.len == 1
    if after.len == 1:
      let d = after[0]
      checkpoint(describe(d))
      ck d.kind == dkCell
      ck d.row == target.row
      ck d.col == target.col
      ck d.summary == "the attribute sets differ"
      ck d.tier1.contains("canBold")
      ck not d.tier2.contains("canBold")
      # The plaintext half stayed identical, which is the point: without the
      # cellmap comparison this mutation is invisible.
      ck comparePlaintext(readFile(tier1 / "plaintext.txt"),
                          readFile(tier2 / "plaintext.txt")).len == 0
    let restored = runDualSnap("app_color_depth", colorApp.buildTree, 120, 40)
    ck restored.divergences.len == 0

  test "MUTATION ARM: an excluded attribute does NOT fail the comparison":
    # The other direction, and it is the one that makes the exclusion list
    # honest: planting `attrDim` — the one attribute the comparison excludes —
    # must leave the run green, so the exclusion is a measured property of this
    # code rather than a sentence in a comment. Verification-Harness-Traps §4a:
    # a claim about what a check ignores needs an arm as much as a claim about
    # what it catches.
    let dir = dualSnapCaseDir("app_borders-120x40")
    let tier1 = dir / "tier1"
    let tier2 = dir / "tier2"
    ck compareSnapshotDirs(tier1, tier2).len == 0
    let target = firstCellWhere(tier1, proc(c: CanonCell): bool = c.rune == "│")
    ck target.row >= 0
    mutateCellmapAttr(tier1, target.row, target.col, "attrDim")
    checkpoint("planted attrDim at (" & $target.row & "," & $target.col & ")")
    ck compareSnapshotDirs(tier1, tier2).len == 0
    # And the SAME cell with a non-excluded attribute is caught, through the
    # same code path — otherwise "green" above would be evidence that the
    # mutation helper does nothing.
    mutateCellmapAttr(tier1, target.row, target.col, "attrStrike")
    let caught = compareSnapshotDirs(tier1, tier2)
    ck caught.len == 1
    if caught.len == 1:
      ck caught[0].row == target.row
      ck caught[0].col == target.col
    let restored = runDualSnap("app_borders", borderApp.buildTree, 120, 40)
    ck restored.divergences.len == 0

  test "MUTATION ARM: comparing a directory with itself is refused":
    # The vacuous pass this whole file is written against: two directories that
    # compare equal because they were both written by the same tier. It cannot
    # be reported as success, so it is raised rather than returned.
    let dir = dualSnapCaseDir("app_borders-80x24")
    var raised = ""
    try:
      discard compareSnapshotDirs(dir / "tier1", dir / "tier1")
    except DualSnapError as e:
      raised = e.msg
    checkpoint("refusal: " & raised)
    ck raised.contains("same tier")
    ck raised.contains("tier1-isonim-tui")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
