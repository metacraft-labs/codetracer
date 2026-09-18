#!/usr/bin/env python3
"""Mutation harness for PLAT-15's terminal visual debugging.

WHAT THIS COVERS. CodeTracer-TUI-Graphics.md §5 (the magnifier — the two-stage
pixel pick, the aspect-corrected zoom, the exactness of the reported
coordinate), §4 (the frame viewer's title and its tier), §2.6 (a pane that
cannot draw says so and keeps drawing) and §6.1 (pixel history). Six subject
files, two suites.

WHY THE ARMS ARE AIMED WHERE THEY ARE. This milestone's substance is a
COORDINATE and a DEGRADATION, and the two have different failure modes:

  * **the coordinate fails SILENTLY and CONSISTENTLY.** A magnifier that is off
    by one in either axis draws a plausible picture, reports a plausible
    number, and hands `pixel_history_vm` the wrong pixel — and every assertion
    written against the renderer's own output agrees with it. So the arms on
    `magnifier.nim` (V1-V7) each move the coordinate by a defined amount and
    ask whether the gate — which compares against the FIXTURE'S OWN FORMULA,
    evaluated in the test file — notices.
  * **the SHARED ARITHMETIC fails by drifting apart** (V8).
    `magnifier.coarsePixelRect` and `cell_render.sampleCell` must answer one
    question, and PLAT-15 made them share one function
    (`cell_render.sourceRectOfSubCell`) for Verification-Harness-Traps §14's
    reason. V8 makes the RENDERER sample somewhere other than where the model
    says it does, which is the defect a second copy would have made
    permanent — and it is killable only because the gate reads the renderer's
    real output rather than the model's own claim.
  * **the degradation fails by BLANKING** (V9-V16). §2.6's rule is that a lower
    tier shows the same content at lower fidelity and "never silently omits an
    overlay, a selection marker or a magnifier cursor", and the specific way a
    pane breaks it is to stop drawing the rest of itself. V12 is that arm by
    name.
  * **the PREDICATE fails by being asked of the wrong SET** (V23, V24), which is
    PLAT-15's landing-pass finding and the reason `tiers.nim` is a subject here.
    `DrawableTiers` contains `itProtocol` and `cell_render.renderCells` refuses
    it, so a pane that asked "is this drawable?" before painting was told yes
    for a Kitty terminal and the `CellRenderError` left `shellScreen`'s whole
    paint. V24 collapses the two sets back together and restores that exception
    verbatim; V23 keeps the guard and loses only the REASON, so the tier-0
    report and the octant report each have evidence the other cannot satisfy
    (§32a).

FOUR ARMS WERE ADDED BY THAT LANDING PASS — V21 (the magnifier's opening cursor,
which `(0, 0)` survived the whole nineteen-case suite), V22 (§5's hand-off, whose
NEGATIVE twin V14 already had and whose positive half did not), V23 and V24.

IT IS A SEPARATE FILE FROM THE PLAT-7 … PLAT-14 HARNESSES, for the reason
PLAT-8's header gives: each records control digests over its own campaign's
subjects, and merging them would mean one `--record-control-hashes` step
re-blessing several campaigns' files at once.

**AND IT MUST NOT RUN BESIDE THEM.** The locks are per harness and do not
serialise against each other. Three of this harness's subjects are ALSO
PLAT-14's — `cell_render.nim` (whose `sourceRectOfSubCell` this milestone
exported), `tiers.nim` (whose `CellRenderableTiers` PLAT-15's landing pass
extracted) and, through `test_frame_viewer_pane.nim`'s compile,
`image_capability.nim` — so a
PLAT-14 arm reddens this harness's unmutated control and vice versa. Run one
harness at a time. §32a applies in both directions: when either file changes,
BOTH harnesses' digests are re-recorded and BOTH harnesses' arms aimed at it
re-run.

FIVE VERDICTS, NOT TWO (Verification-Harness-Traps §1a and §17):

  killed           the named case reported [FAILED] **and** the failure output
                   carries the arm's own `because`
  MIS-ATTRIBUTED   the named case went red, but not for the arm's reason — it
                   died upstream of the mutated line (§17)
  SUITE-DIED       the binary produced result lines and the killer case was in
                   neither list, so it never ran
  SURVIVED         nothing noticed
  HARNESS-FAILURE  the arm could not be applied, or a restore did not restore

THE VERDICT IS PARSED FROM `[OK]`/`[FAILED]` LINES AND NEVER FROM AN EXIT
CODE. `std/unittest` exits non-zero for a compile-time abort, for a raised
exception and for a failed check alike, and three causes behind one number is
not a result.

THE `because` NEEDLES ARE DERIVED FROM TRANSCRIPTS, NOT TYPED FROM THE SOURCE
(§17a). Every string below was read out of a run in which the arm was applied;
`nim`'s `check` prints the failing expression AND each operand's value, and it
is the operand VALUE that says the mutation is what moved.

THE NEEDLE SCAN GATES `--record-control-hashes` (§16). Blessing new bytes as
the baseline is exactly the moment an arm's needle has just been moved, and
recording first would certify the drift.

THE LANE FLAGS ARE READ FROM `ci/lib/test-lane-files.sh` AND NOT COPIED HERE.
`test_frame_viewer_pane.nim` links `isonim_tui`, which needs a tree-sitter
runtime path and a grammar archive this repository builds; a second copy of
those flags would be a second thing to keep in step with the lane (§14).

Usage:
    direnv exec . python3 -u src/common/terminal_graphics/run-plat15-visual-mutations.py
    …                                      --needle-scan
    …                                      --record-control-hashes
    …                                      V1 V9        # individual arms
    …                                      --explain V1 # one arm, verbatim
"""

import fcntl
import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

# --- the files an arm may touch -------------------------------------------

MAG = "src/common/terminal_graphics/magnifier.nim"
TIERS = "src/common/terminal_graphics/tiers.nim"
RASTER = "src/common/terminal_graphics/raster.nim"
RENDER = "src/common/terminal_graphics/cell_render.nim"
PANE = "src/frontend/tui/app/views/frame_viewer.nim"
BIND = "src/frontend/tui/app/frame_viewer_binding.nim"

TOUCHED = [MAG, TIERS, RASTER, RENDER, PANE, BIND]

# `RENDER` AND `TIERS` ARE ALSO PLAT-14'S SUBJECTS. See this module's docstring.
# `tiers.nim` joined this list in PLAT-15's landing pass, when
# `CellRenderableTiers` — the predicate `renderCells` gates on AND the predicate
# the pane asks before it paints — was extracted into it. A shared predicate is
# graded from BOTH consumers (Verification-Harness-Traps §14b); PLAT-14's arms
# grade the renderer's side and V24 below grades the pane's.

MAG_SUITE = "src/common/terminal_graphics/magnifier_test.nim"
PANE_SUITE = "src/frontend/tui/app/tests/test_frame_viewer_pane.nim"

CONTROL_HASHES = HERE / "plat15-visual-mutation-control.sha256"
LOCK_PATH = HERE / ".plat15-visual-mutation.lock"

NIM_RESULT = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*)$")

UNDERIVED = "PLACEHOLDER-DERIVE-THIS-FROM-A-TRANSCRIPT"
    # The sentinel a new arm carries until its `because` has been READ OUT OF A
    # RUN (§17a). A CONSTANT rather than a literal at the one site that tests
    # it, so the guard and the table cannot come to spell it differently (§14);
    # and it is refused in the pre-flight, BEFORE anything is mutated, rather
    # than scoring MIS-ATTRIBUTED sixteen arms later.


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def acquire_lock():
    """Take the exclusive run lock, or explain who holds it and refuse."""
    fh = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.seek(0)
        holder = fh.read().strip() or "(the holder recorded no details)"
        fh.close()
        print("ANOTHER MUTATION RUN HOLDS THE LOCK — nothing was mutated.")
        print(f"  lock: {LOCK_PATH}")
        print(f"  held by: {holder}")
        print("  Two instances in one worktree corrupt each other's restores.")
        return None
    fh.seek(0)
    fh.truncate()
    fh.write(f"pid {os.getpid()} on {os.uname().nodename}, cwd {ROOT}\n")
    fh.flush()
    return fh


def tui_lane_flags() -> list:
    """The `tui` lane's own compiler flags, read from the lane library.

    Verification-Harness-Traps §14: one source of truth. The lane script already
    answers "what does a suite that links isonim_tui need?", and a copy here
    would drift the day the grammar archive moves.
    """
    proc = subprocess.run(
        ["bash", "-c",
         ". ci/lib/test-lane-files.sh >/dev/null 2>&1; test_lane_extra_flags tui"],
        cwd=ROOT, capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise SystemExit("could not read the tui lane's flags: " + proc.stderr)
    return proc.stdout.split()


# --- the case names, spelled once ------------------------------------------
#
# A typo here shows up as "the killer resolves to 0 green cases" in the
# pre-flight rather than as a silently unkillable arm.

# `magnifier_test.nim`
M_COARSE = "one frame cell covers MORE THAN ONE source pixel, at every tier"
M_ONE = "a 1:1 fit DOES address a pixel — §5's own sentence, falsified"
M_FOOT = "the cell's FOOTPRINT is the fit's, and is the same at every tier"
M_SHARED = "the coarse rectangle is the RENDERER's own sampling, not a copy"
M_ZOOM = "the zoom is at least one cell per pixel, in both axes, always"
M_SQUARE = "a square cell needs no correction and a 1:2 cell needs a 2x one"
M_GATE = "every magnifier cell shows the pixel it names, through the renderer"
M_ROUND = "the cursor's cell and the cursor's pixel are the same fact"
M_REACH = "the cursor reaches every pixel and never leaves the image"
M_OCTANT = "octants refuse a magnifier, and a sextant magnifier is the twin"
M_TIER0 = "tier 0 magnifies at tier 1, and says so"
M_BLOWUP = "every magnified pixel is a colour the source has"
M_OPEN = "the magnifier OPENS inside the cell it was opened at, at every tier"

# `test_frame_viewer_pane.nim`
P_TITLE = "the title names the frame, its pixel extent and the resolved tier"
P_MAGTITLE = "a magnified pane names the OVERLAY's tier when it differs"
P_HANDOFF = "the picked pixel reaches the client as the pixel the magnifier named"
P_NOMAG = "without the magnification step there is no request at all"
P_OCTANT = "an octant pin degrades through pdDependencyMissing, picture only"
P_DRAWS = "the POSITIVE TWIN: a drawable tier draws, same model, same pane"
P_DECODER = "an ENCODED frame on a cell terminal is PLAT-14's bound 3, reported"
P_ABSENT = "no player at all is pdsABSENT, which is a different remedy"
P_PRECEDENCE = "the session's own rows still OUTRANK this pane's, one precedence"
P_EMIT = "a pane that cannot draw refuses to emit rather than emitting nothing"
P_TIER0 = "an UNMAGNIFIED tier-0 pane reports, keeps drawing, and does not raise"


@dataclass
class Suite:
    path: str
    binary: str
    tui: bool = False


NIM_MAG = Suite(MAG_SUITE, "/tmp/plat15-mut-mag")
NIM_PANE = Suite(PANE_SUITE, "/tmp/plat15-mut-pane", tui=True)


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    suite: Suite
    because: str
    why: str = ""
    control_name: str = ""
    control_find: str = ""
    control_replace: str = ""


DECLARED_SURVIVORS: list = []


MUTATIONS: list = [
    # -- §5's coordinate: each arm moves it by a defined amount -------------
    Mutation(
        "V1", MAG,
        "  (mag.window.x + col div mag.zoomCols, mag.window.y + row div mag.zoomRows)",
        "  (mag.window.x + col, mag.window.y + row)",
        M_GATE, NIM_MAG,
        'cell.fg was (r: 32, g: 119, b: 125)',
        why="THE ZOOM DROPPED FROM THE INVERSE. `zoomCols` is CELLS per source "
            "pixel, so a cell index is a pixel index only when the zoom is 1 — "
            "and at the default 1:2 cell it never is horizontally. The picture "
            "is unchanged and every coordinate to the right of the window's "
            "left edge is wrong.",
        control_name="sourcePixelOfCell, with the two components' order preserved "
                     "and the divisions written through intermediates",
        control_find="  (mag.window.x + col div mag.zoomCols, mag.window.y + row div mag.zoomRows)",
        control_replace="  (mag.window.x + (col div mag.zoomCols),\n"
                        "   mag.window.y + (row div mag.zoomRows))"),
    Mutation(
        "V2", MAG,
        "  let c = max(1, (r * max(1, aspect.heightPx) + max(1, aspect.widthPx) div 2) div\n"
        "                 max(1, aspect.widthPx))",
        "  let c = max(1, r)",
        M_SQUARE, NIM_MAG,
        'cellsPerSourcePixel(1, DefaultCellAspect) was (1, 1)',
        why="§2.4'S CORRECTION REMOVED FROM THE MAGNIFIER. Every source pixel "
            "is drawn half as wide as it is tall, which is the same stretch the "
            "frame's own fit exists to remove — arriving through the "
            "interaction instead of through the picture.",
        control_name="the zoom's width, written as a named intermediate",
        control_find="  let c = max(1, (r * max(1, aspect.heightPx) + max(1, aspect.widthPx) div 2) div\n"
                     "                 max(1, aspect.widthPx))",
        control_replace="  let w = max(1, aspect.widthPx)\n"
                        "  let c = max(1, (r * max(1, aspect.heightPx) + w div 2) div w)"),
    Mutation(
        "V3", MAG,
        "  if tier == itProtocol: itHalfBlock else: tier",
        "  tier",
        M_TIER0, NIM_MAG,
        'magnifierTier(itProtocol) was itProtocol',
        why="A TIER-0 MAGNIFIER. `renderCells` raises for `itProtocol` — a "
            "graphics-protocol emission is not a cell rendering — so the "
            "overlay stops being a picture and becomes an exception, on the "
            "terminals that draw the frame best.",
        control_name="the tier substitution, written as a case",
        control_find="  if tier == itProtocol: itHalfBlock else: tier",
        control_replace="  (case tier\n   of itProtocol: itHalfBlock\n   else: tier)"),
    Mutation(
        "V4", MAG,
        "  if effective notin CellRenderableTiers:",
        "  if false:",
        M_OCTANT, NIM_MAG,
        'is not implemented in this build',
        why="PLAT-14 RESIDUE 3, RESTORED. Without the guard an octant "
            "magnifier reaches `cell_render.glyphFor`, which raises a "
            "`CellRenderError` naming a remedy the PANE cannot report — the "
            "exception at draw time PLAT-14 recorded as PLAT-15's to decide.",
        control_name="the renderable test, written as a double negative",
        control_find="  if effective notin CellRenderableTiers:",
        control_replace="  if not (effective in CellRenderableTiers):"),
    Mutation(
        "V5", MAG,
        "  if mag.cursorX < mag.window.x:\n    mag.window.x = mag.cursorX",
        "  if false:\n    mag.window.x = mag.cursorX",
        M_REACH, NIM_MAG,
        'mag.window.x was 2',
        why="THE WINDOW STOPS FOLLOWING THE CURSOR LEFTWARD. The reported "
            "coordinate stays correct and the user cannot SEE the pixel it "
            "names, which is the half of §5 that a coordinate-only assertion "
            "cannot catch.",
        control_name="the leftward scroll, with the comparison reversed",
        control_find="  if mag.cursorX < mag.window.x:\n    mag.window.x = mag.cursorX",
        control_replace="  if mag.window.x > mag.cursorX:\n    mag.window.x = mag.cursorX"),
    Mutation(
        "V6", MAG,
        "  let effective = if tier == itProtocol: itAscii else: tier",
        "  let effective = tier",
        M_FOOT, NIM_MAG,
        'reference.x was 120',
        why="TIER 0'S 0x0 SUB-CELL GEOMETRY READ AS A DIVISOR. "
            "`subCell(itProtocol)` is `0x0` because a protocol emission is not "
            "a cell rendering, so the sub-cell grid collapses to 1x1 and every "
            "cell of a tier-0 frame reports the WHOLE image as its footprint — "
            "which would make the magnifier open over the entire frame from "
            "any cell the user pointed at.",
        control_name="the tier-0 substitution, written as a case",
        control_find="  let effective = if tier == itProtocol: itAscii else: tier",
        control_replace="  let effective = (case tier\n"
                        "                   of itProtocol: itAscii\n"
                        "                   else: tier)"),
    Mutation(
        "V7", MAG,
        "  result.cursorX = max(0, min(mag.cursorX + dx, mag.imageWidth - 1))",
        "  result.cursorX = max(mag.window.x,\n"
        "                       min(mag.cursorX + dx,\n"
        "                           mag.window.x + mag.window.width - 1))",
        M_ROUND, NIM_MAG,
        'mag.pickedPixel() was (5, 0)',
        why="THE CURSOR CLAMPED TO THE WINDOW INSTEAD OF TO THE IMAGE. Every "
            "pixel outside the first window becomes unpickable, which is "
            "precisely the precision §5 says the magnifier exists to provide — "
            "and the failure is invisible in a small fixture whose window "
            "covers the whole frame.",
        control_name="the horizontal clamp, with the bounds written through "
                     "intermediates",
        control_find="  result.cursorX = max(0, min(mag.cursorX + dx, mag.imageWidth - 1))",
        control_replace="  let wantX = mag.cursorX + dx\n"
                        "  result.cursorX = max(0, min(wantX, mag.imageWidth - 1))"),

    # -- §14: the renderer and the model must answer ONE question -----------
    Mutation(
        "V8", RENDER,
        "      let r = sourceRectOfSubCell(img.width, img.height, fit, tier, gx, gy)",
        "      let r = sourceRectOfSubCell(img.width, img.height, fit, tier, gy, gx)",
        M_GATE, NIM_MAG,
        'cell.fg was (r: 32, g: 130, b: 40)',
        why="THE RENDERER SAMPLES SOMEWHERE ELSE. `coarsePixelRect` and "
            "`sampleCell` share one function so the model's 'which source "
            "pixels does this cell show?' IS the renderer's — this arm is what "
            "proves the gate reads the renderer's real output rather than the "
            "model's own claim. A second copy of the arithmetic would have made "
            "this mutation invisible to the gate, which is §14 in one line.",
        control_name="the sub-cell lookup, with the arguments passed by name",
        control_find="      let r = sourceRectOfSubCell(img.width, img.height, fit, tier, gx, gy)",
        control_replace="      let r = sourceRectOfSubCell(sourceWidth = img.width,\n"
                        "                                  sourceHeight = img.height,\n"
                        "                                  fit = fit, tier = tier,\n"
                        "                                  gx = gx, gy = gy)"),

    # -- the cases whose arms were added so no case is graded only by
    #    collateral damage from another arm ---------------------------------
    Mutation(
        "V17", MAG,
        "            width: max(1, last.x + last.width - first.x),\n"
        "            height: max(1, last.y + last.height - first.y))",
        "            width: max(1, last.x + last.width - first.x),\n"
        "            height: max(1, first.height))",
        M_SHARED, NIM_MAG,
        'coarse.height was 2',
        why="THE UNION COLLAPSED TO ITS FIRST SUB-CELL. A cell's footprint is "
            "the union of the sub-cells the RENDERER samples, and a footprint "
            "that reported only the top sub-cell's rows would open the "
            "magnifier over half the neighbourhood the user pointed at — and "
            "would make §5's own argument about tiers 1-5 unfalsifiable, "
            "because the extra sub-cell rows are the whole of what those tiers "
            "add.",
        control_name="the union's height, written through an intermediate",
        control_find="            height: max(1, last.y + last.height - first.y))",
        control_replace="            height: max(1, (last.y + last.height) - first.y))"),
    Mutation(
        "V18", MAG,
        "  if viewCols <= 0 or viewRows <= 0:",
        "  if false:",
        "a magnifier over an empty raster is refused rather than sized to zero",
        NIM_MAG,
        'refused was 1',
        why="A MAGNIFIER WITH NO RECTANGLE. Without the refusal the window is "
            "sized from `viewCols div zoomCols == 0`, floored to 1 by "
            "`clampWindow`, and the caller gets an overlay it never asked for "
            "in a rectangle that cannot hold it — a blank region with a "
            "coordinate attached, which is what PLAT-12 spent a verification "
            "pass removing.",
        control_name="the rectangle test, written as a negated conjunction",
        control_find="  if viewCols <= 0 or viewRows <= 0:",
        control_replace="  if not (viewCols > 0 and viewRows > 0):"),
    Mutation(
        "V19", MAG,
        "  if col < 0 or row < 0 or col >= fit.cols or row >= fit.rows:",
        "  if false:",
        "a cell outside the frame is refused, not clamped to an edge pixel",
        NIM_MAG,
        'refused was 0',
        why="A CELL OUTSIDE THE FRAME, ANSWERED. `sourceRectOfSubCell` clamps "
            "in `raster.pixelAt`, so an out-of-range cell produces an EDGE "
            "pixel's rectangle rather than an error — and the magnifier then "
            "reports a coordinate for a pixel the user did not point at. That "
            "is §5's guess wearing a defensive coding style.",
        control_name="the bounds test, with the disjunction's operands reordered",
        control_find="  if col < 0 or row < 0 or col >= fit.cols or row >= fit.rows:",
        control_replace="  if col >= fit.cols or row >= fit.rows or col < 0 or row < 0:"),
    Mutation(
        "V20", MAG,
        "      let sx = mag.window.x + mx div (mag.zoomCols * max(1, geom.cols))",
        "      let sx = mag.window.x + mx div max(1, geom.cols)",
        "every magnified pixel is a colour the source has",
        NIM_MAG,
        'blown.pixelAt(mx, my) was (r: 44, g: 130, b: 68)',
        why="THE BLOW-UP IGNORED THE ZOOM HORIZONTALLY. Each magnified pixel "
            "then comes from a source pixel `zoomCols` times too far right, so "
            "the picture is a correct-looking crop of the wrong region — the "
            "shape a magnifier fails in silently, and the one a sweep over "
            "cell colours alone would not name.",
        control_name="the blow-up's source column, written through an intermediate",
        control_find="      let sx = mag.window.x + mx div (mag.zoomCols * max(1, geom.cols))",
        control_replace="      let cellsPerPixelX = mag.zoomCols * max(1, geom.cols)\n"
                        "      let sx = mag.window.x + mx div cellsPerPixelX"),

    # -- §2.6: a pane that cannot draw says so AND KEEPS DRAWING -------------
    Mutation(
        "V9", PANE,
        "  if tier notin CellRenderableTiers:",
        "  if false:",
        P_OCTANT, NIM_PANE,
        'Check failed: model.degradedMessage.contains("octant")',
        why="PLAT-14 RESIDUE 3 AT THE PANE, AND TIER 0 BESIDE IT. This one "
            "guard is what stops BOTH non-members of `CellRenderableTiers` "
            "reaching `renderCells`, where each is a `CellRenderError` the pane "
            "can only propagate — out of `shellScreen`'s whole paint, in the "
            "tier-0 case. Removing it restores exactly the defect PLAT-15's "
            "landing pass found, in both of its shapes.",
        control_name="the renderable test, written as a double negative",
        control_find="  if tier notin CellRenderableTiers:",
        control_replace="  if not (tier in CellRenderableTiers):"),
    Mutation(
        "V10", BIND,
        "  of fdgPlayerAbsent: pdsAbsent",
        "  of fdgPlayerAbsent: pdsUnsupported",
        P_ABSENT, NIM_PANE,
        'frameDependencyState(fdgPlayerAbsent) was pdsUnsupported',
        why="THE TWO REMEDIES COLLAPSED. `PluginDependencyState`'s own doc "
            "states what this costs: a user whose player is simply not running "
            "is told the host could not run it either way, which is the "
            "opposite of the actionable answer — §14's 'a terminal state with "
            "a reason, never a retry that cannot succeed' inverted.",
        control_name="the absent arm, written through a named constant",
        control_find="  of fdgPlayerAbsent: pdsAbsent",
        control_replace="  of fdgPlayerAbsent: (let s = pdsAbsent; s)"),
    Mutation(
        "V11", BIND,
        "  result = core\n  result.dependency = frameDependencyState(gap)",
        "  result = initDegradedStateSnapshot()\n"
        "  result.dependency = frameDependencyState(gap)",
        P_PRECEDENCE, NIM_PANE,
        'frameViewerDegradation(snapshot, fdgNoDecoder) was pdDependencyMissing',
        why="THE SESSION'S FOUR AXES DROPPED. A pane that resolved its own gap "
            "against a FRESH snapshot would report 'this frame will not draw' "
            "on a trace that will not replay at all — a second precedence, "
            "which is exactly what §14's one-enum-one-resolver rule exists to "
            "prevent.",
        control_name="the snapshot copy, written field by field",
        control_find="  result = core\n  result.dependency = frameDependencyState(gap)",
        control_replace="  result = core\n"
                        "  result.availability = core.availability\n"
                        "  result.dependency = frameDependencyState(gap)"),
    Mutation(
        "V12", PANE,
        "  if historyHeight >= 1 and atRow < area.row + area.height:",
        "  if gap == fdgNone and historyHeight >= 1 and atRow < area.row + area.height:",
        P_OCTANT, NIM_PANE,
        'screen.historyRows was 0',
        why="§2.6 BROKEN IN ITS OWN SHAPE: the pane stops drawing the REST of "
            "itself because one region cannot be drawn. 'Degradation never "
            "removes information' is the rule, and a pixel-history list that "
            "vanishes when the picture cannot be rendered removes exactly the "
            "information §6.2 says a terminal is best at.",
        control_name="the history guard, with the conjunction's operands swapped",
        control_find="  if historyHeight >= 1 and atRow < area.row + area.height:",
        control_replace="  if atRow < area.row + area.height and historyHeight >= 1:"),
    Mutation(
        "V13", PANE,
        "  if not model.hasRaster:\n    # PLAT-14 bound 3.",
        "  if false:\n    # PLAT-14 bound 3.",
        P_DECODER, NIM_PANE,
        'Check failed: model.degradedMessage.contains("no PNG or JPEG decoder")',
        why="PLAT-14 BOUND 3 UNREPORTED. An encoded frame on a cell terminal "
            "reaches `renderCells` with a zero raster instead of degrading, so "
            "'this build has no PNG decoder' becomes a blank region — which is "
            "the outcome PLAT-12 spent a whole verification pass removing.",
        control_name="the decoder test, written as an equality against false",
        control_find="  if not model.hasRaster:\n    # PLAT-14 bound 3.",
        control_replace="  if model.hasRaster == false:\n    # PLAT-14 bound 3."),
    Mutation(
        "V14", BIND,
        "  if history.isNil or not model.magnified:",
        "  if history.isNil:",
        P_NOMAG, NIM_PANE,
        'requestPixelHistory(history, model) was true',
        why="§5'S ENFORCEMENT REMOVED. Without the guard a caller that never "
            "opened a magnifier requests a history for `Magnifier()`'s zero "
            "coordinate — pixel (0, 0) of every frame — which is the "
            "coordinate inferred from nothing at all, reported as though a "
            "user had picked it.",
        control_name="the magnifier guard, written as a negated conjunction",
        control_find="  if history.isNil or not model.magnified:",
        control_replace="  if not ((not history.isNil) and model.magnified):"),
    Mutation(
        "V15", PANE,
        "    if drawn != model.capability.tier:\n      result.add \"  magnifier=\" & tierName(drawn)",
        "    if false:\n      result.add \"  magnifier=\" & tierName(drawn)",
        P_MAGTITLE, NIM_PANE,
        'Check failed: magnified.titleText().contains("magnifier=half-block")',
        why="§4'S TITLE MADE FALSE ON THE ONE PATH IT MATTERS MOST. A user "
            "magnifying on a Kitty terminal reads `image-tier=protocol` over a "
            "half-block picture — 'a faithful frame or a 2x3 approximation' "
            "reported as the former while it is the latter.",
        control_name="the overlay-tier test, written as a negated equality",
        control_find="    if drawn != model.capability.tier:",
        control_replace="    if not (drawn == model.capability.tier):"),
    Mutation(
        "V16", PANE,
        "  if gap != fdgNone:\n    raise newException(EmitError,",
        "  if false:\n    raise newException(EmitError,",
        P_EMIT, NIM_PANE,
        'is not implemented in this build',
        why="AN EMITTER THAT ANSWERS FOR A MODEL THAT CANNOT DRAW. "
            "`cell_render.glyphFor`'s rule, inverted: a caller that skipped "
            "`resolveGap` gets an exception from two layers down, or bytes for "
            "a picture the pane has already reported it cannot draw.",
        control_name="the gap refusal, written as a negated equality",
        control_find="  if gap != fdgNone:\n    raise newException(EmitError,",
        control_replace="  if not (gap == fdgNone):\n    raise newException(EmitError,"),
    Mutation(
        "V21", MAG,
        "    cursorX: min(coarse.x + coarse.width div 2, imageWidth - 1),\n"
        "    cursorY: min(coarse.y + coarse.height div 2, imageHeight - 1),",
        "    cursorX: 0,\n"
        "    cursorY: 0,",
        M_OPEN, NIM_MAG,
        'Check failed: coarse.containsPixel(mag.cursorX, mag.cursorY)',
        why="THE MAGNIFIER OPENS SOMEWHERE ELSE. §5's two stages are 'move a "
            "cell cursor over the frame' and 'open a magnifier over the "
            "neighbourhood that cell shows', and nothing in this suite joined "
            "them: with the cursor pinned to the image's top-left corner the "
            "window still follows it, the round trip still closes, and every "
            "colour the gate compares is still that pixel's — it is simply a "
            "pixel the user did not point at, which is §5's guess arriving "
            "through the OPENING instead of through an inference. This arm was "
            "added by PLAT-15's landing pass, where the whole 19-case suite "
            "survived the mutation.",
        control_name="the opening cursor, with the halvings parenthesised",
        control_find="    cursorX: min(coarse.x + coarse.width div 2, imageWidth - 1),\n"
                     "    cursorY: min(coarse.y + coarse.height div 2, imageHeight - 1),",
        control_replace="    cursorX: min(coarse.x + (coarse.width div 2), imageWidth - 1),\n"
                        "    cursorY: min(coarse.y + (coarse.height div 2), imageHeight - 1),"),
    Mutation(
        "V22", BIND,
        "  let (x, y) = model.magnifier.pickedPixel()",
        "  let (x, y) = (model.historyPixelX, model.historyPixelY)",
        P_HANDOFF, NIM_PANE,
        'Check failed: rec.pixelRequests[0] == (wantX, wantY, 3)',
        why="§5'S HAND-OFF TAKEN FROM SOMEWHERE ELSE. *'The magnifier reports "
            "the exact pixel coordinate, and THAT is what `pixel_history_vm` "
            "receives'* — this arm sends the coordinate the list on screen is "
            "already ABOUT, which is a plausible-looking pair of fields on the "
            "same model and is exactly the stale-for-live substitution "
            "`FrameViewerModel`'s own comment warns about. V14 arms the "
            "NEGATIVE half of this hand-off (no magnifier, no request); until "
            "PLAT-15's landing pass the positive half — the headline of §5 — "
            "had no arm of its own.",
        control_name="the picked pixel, unpacked through a named intermediate",
        control_find="  let (x, y) = model.magnifier.pickedPixel()",
        control_replace="  let picked = model.magnifier.pickedPixel()\n"
                        "  let (x, y) = picked"),
    Mutation(
        "V23", PANE,
        "    return\n"
        "      if tier == itProtocol: fdgProtocolNotPainted\n"
        "      else: fdgTierNotDrawable",
        "    return fdgTierNotDrawable",
        P_TIER0, NIM_PANE,
        'Check failed: model.gap == fdgProtocolNotPainted',
        why="THE TWO REASONS COLLAPSED INTO THE OLDER ONE. V9 removes the "
            "guard; this arm keeps it and loses the DISTINCTION, so a Kitty "
            "terminal is told its pinned tier has no glyph table and is "
            "offered sextants — a remedy for a problem it does not have, on "
            "the terminal that draws the frame best. §32a: two branches of one "
            "guard need evidence each, or the newer one is graded only as "
            "collateral of an arm aimed at the older.",
        control_name="the two reasons, written as a negated equality",
        control_find="    return\n"
                     "      if tier == itProtocol: fdgProtocolNotPainted\n"
                     "      else: fdgTierNotDrawable",
        control_replace="    return\n"
                        "      if tier != itProtocol: fdgTierNotDrawable\n"
                        "      else: fdgProtocolNotPainted"),
    Mutation(
        "V24", TIERS,
        "  CellRenderableTiers* = DrawableTiers - {itProtocol}",
        "  CellRenderableTiers* = DrawableTiers",
        P_TIER0, NIM_PANE,
        "Unhandled exception: image tier 'protocol' is a graphics-protocol "
        "emission, not a cell rendering",
        why="THE PREDICATE ITSELF, AND IT RESTORES THE ORIGINAL DEFECT EXACTLY. "
            "`DrawableTiers` means 'this tier produces bytes for a terminal' "
            "and CONTAINS `itProtocol`; `CellRenderableTiers` means 'this tier "
            "produces CELLS' and does not. Collapse the two and `resolveGap` "
            "answers `fdgNone` for a Kitty terminal again, `renderCells` "
            "refuses tier 0 from inside `paintFrameViewer`, and the "
            "`CellRenderError` leaves the WHOLE shell paint rather than one "
            "pane — which is what PLAT-15's landing pass measured through "
            "`shellScreen` and is why the two sets are two sets.",
        control_name="the renderable set, written as the members it has",
        control_find="  CellRenderableTiers* = DrawableTiers - {itProtocol}",
        control_replace="  CellRenderableTiers* = {itHalfBlock, itQuadrant, itSextant,\n"
                        "                          itBraille, itAscii}"),
]


@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list = None
    failed: list = None
    output: str = ""

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


TUI_FLAGS = None


def run_suite(suite: Suite, label: str) -> RunResult:
    """Compile and run one suite; parse its verdict out of its RESULT LINES."""
    global TUI_FLAGS
    res = RunResult()
    compile_cmd = ["nim", "c", "-f", "--hints:off", "--warnings:off"]
    if suite.tui:
        if TUI_FLAGS is None:
            TUI_FLAGS = tui_lane_flags()
        compile_cmd += TUI_FLAGS
    compile_cmd += [f"--nimcache:/tmp/plat15-mut-cache-{Path(suite.path).stem}",
                    f"-o:{suite.binary}", suite.path]
    compile_proc = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True,
                                  text=True, errors="replace", timeout=3600)
    if compile_proc.returncode != 0:
        res.rc = compile_proc.returncode
        res.ran = False
        res.output = compile_proc.stdout + compile_proc.stderr
        print("      ---- did not compile; last 12 lines ----")
        for line in res.output.splitlines()[-12:]:
            print("      " + line)
        return res
    proc = subprocess.run([suite.binary], cwd=ROOT, capture_output=True,
                          text=True, errors="replace", timeout=3600)
    out = proc.stdout + proc.stderr
    res.output = out
    res.rc = proc.returncode
    for line in out.splitlines():
        m = NIM_RESULT.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print("      ---- no result lines; last 12 lines of output ----")
        for line in out.splitlines()[-12:]:
            print("      " + line)
    return res


def apply_once(path: str, find: str, replace: str):
    """Return (original, error). The needle must occur exactly once."""
    p = ROOT / path
    original = p.read_text()
    n = original.count(find)
    if n != 1:
        return original, f"pattern occurs {n} times in {path}, expected 1"
    p.write_text(original.replace(find, replace))
    return original, ""


def restore(path: str, original: str) -> None:
    (ROOT / path).write_text(original)


def read_control_hashes() -> dict:
    if not CONTROL_HASHES.exists():
        return {}
    out = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        if h and p:
            out[p] = h
    return out


def needle_scan() -> list:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    Verification-Harness-Traps §16. A mutation arm is a QUOTATION of the code,
    held somewhere the compiler does not look, and every repair to the quoted
    file is an opportunity for it to stop matching. When it does, the arm can
    never be applied, so it can never be killed, and what it leaves behind is a
    row in the table that LOOKS like coverage.

    It gates `--record-control-hashes` rather than sitting beside it: blessing
    new bytes as the baseline is exactly the moment an arm's needle has just
    been moved, and recording first would certify the drift.
    """
    problems = []
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        body = (ROOT / mut.path).read_text()
        for label, needle in (("find", mut.find),
                              ("control_find", mut.control_find)):
            if not needle:
                continue
            n = body.count(needle)
            if n != 1:
                problems.append(
                    f"{mut.id}: {label} occurs {n} time(s) in {mut.path}, "
                    f"expected exactly 1")
    return problems


def report_needle_scan() -> int:
    problems = needle_scan()
    if not problems:
        print(f"  all {len(MUTATIONS) + len(DECLARED_SURVIVORS)} arm(s) resolve "
              f"to exactly one needle and one control needle")
        return 0
    print("ARM NEEDLES DO NOT RESOLVE — nothing was mutated and nothing recorded.")
    for line in problems:
        print(f"  {line}")
    print("  An arm whose needle no longer occurs can never be applied and can")
    print("  never be killed; it sits in the table looking like coverage.")
    print("  Re-aim it at the code as it is now, then re-run.")
    return 2


def write_control_hashes() -> None:
    body = ["# Control digests for run-plat15-visual-mutations.py.",
            "#",
            "# ABSOLUTE, and that is the point. A baseline taken at start-up",
            "# cannot tell a clean tree from one a killed run left a mutation",
            "# in: it reads the mutation as the baseline, every restore then",
            "# verifies against the mutated bytes, and the only symptom is",
            "# `CONTROL IS NOT GREEN` — which describes a red suite without",
            "# naming the cause.",
            "#",
            "# Rewrite with --record-control-hashes, deliberately, when one of",
            "# these files changes on purpose. The needle scan gates that step",
            "# (Verification-Harness-Traps §16).",
            "#",
            "# `cell_render.nim` and `tiers.nim` are ALSO PLAT-14 subjects.",
            "# When either changes, both harnesses' digests have to be",
            "# re-recorded and both harnesses' arms aimed at it re-run —",
            "# §32a: a repair that tightens can disarm an arm whose needle",
            "# still resolves.",
            ""]
    for p in TOUCHED:
        body.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(body) + "\n")


def check_control_hashes() -> int:
    recorded = read_control_hashes()
    if not recorded:
        print(f"NO CONTROL HASHES: {CONTROL_HASHES.relative_to(ROOT)} is missing.")
        print("  Every restore below would verify against digests taken from")
        print("  THIS tree, so a mutation a killed run left behind would be")
        print("  adopted as the baseline. Record them from a tree you have")
        print("  checked, with --record-control-hashes.")
        return 2
    missing = [p for p in TOUCHED if p not in recorded]
    if missing:
        print(f"CONTROL HASHES INCOMPLETE: no entry for {missing}")
        print("  Re-record with --record-control-hashes.")
        return 2
    drifted = [p for p in TOUCHED if recorded.get(p) != digest(p)]
    if drifted:
        print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
        for p in drifted:
            print(f"  {p}")
            print(f"      recorded {recorded[p]}")
            print(f"      on disk  {digest(p)}")
        print("  Either a previous run was killed before it restored, or one")
        print("  of these files changed on purpose. Check the diff, then")
        print("  re-record with --record-control-hashes.")
        return 2
    return 0


def install_signal_restore() -> None:
    """Turn SIGTERM/SIGHUP into an exception so `finally: restore(...)` runs."""

    def raise_on(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, raise_on)
        except (ValueError, OSError):
            pass


def explain(arm_id: str) -> int:
    """Apply ONE arm, run its suite, and print the failure lines verbatim.

    Verification-Harness-Traps §17a: "derive it rather than type it". A
    `because` typed from the source is a second copy of the code held in a file
    the compiler does not read, so this is how the strings above were obtained.
    """
    chosen = [m for m in MUTATIONS + DECLARED_SURVIVORS if m.id == arm_id]
    if not chosen:
        print(f"no such arm: {arm_id}")
        return 2
    mut = chosen[0]
    lock = acquire_lock()
    if lock is None:
        return 2
    install_signal_restore()
    original, err = apply_once(mut.path, mut.find, mut.replace)
    if err:
        print(f"{mut.id}: {err}")
        return 2
    try:
        res = run_suite(mut.suite, f"{mut.id}-explain")
    finally:
        restore(mut.path, original)
    print(f"---- {mut.id}: failure lines with the arm applied ----")
    for line in res.output.splitlines():
        if ("Check failed" in line or " was " in line
                or line.strip().startswith("[FAILED]")
                or "Unhandled exception" in line):
            print("  " + line)
    lock.close()
    return 0


def main() -> int:
    if "--needle-scan" in sys.argv[1:]:
        return report_needle_scan()

    if "--explain" in sys.argv[1:]:
        idx = sys.argv.index("--explain")
        if idx + 1 >= len(sys.argv):
            print("--explain needs an arm id")
            return 2
        return explain(sys.argv[idx + 1])

    if "--record-control-hashes" in sys.argv[1:]:
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        print(f"recorded {len(TOUCHED)} control digest(s) in "
              f"{CONTROL_HASHES.relative_to(ROOT)}")
        return 0

    install_signal_restore()

    # THE LOCK IS TAKEN BEFORE THE HASH CHECK, and is held in a local for the
    # whole run: a garbage-collected file object closes its descriptor, and a
    # closed descriptor releases the flock.
    lock = acquire_lock()
    if lock is None:
        return 2

    rc = check_control_hashes()
    if rc:
        return rc

    # BEFORE ANY MUTATION. An arm that cannot be applied is not a thing to
    # discover forty minutes in, next to fifteen results you now have to decide
    # whether to trust.
    rc = report_needle_scan()
    if rc:
        return rc

    wanted = [a for a in sys.argv[1:] if not a.startswith("-")]
    selected = MUTATIONS + DECLARED_SURVIVORS
    if wanted:
        selected = [m for m in selected if m.id in wanted]
        missing = set(wanted) - {m.id for m in selected}
        if missing:
            print(f"no such arm(s): {sorted(missing)}")
            return 2
    survivors = [m for m in selected if m in DECLARED_SURVIVORS]

    baseline = {p: digest(p) for p in TOUCHED}

    # THE SUITE SET IS DERIVED FROM THE ARMS, not written out beside them —
    # a second registry of the same fact is where the two drift apart
    # (Verification-Harness-Traps §14).
    suites = []
    seen_suite_paths = set()
    for m in selected:
        if m.suite.path not in seen_suite_paths:
            seen_suite_paths.add(m.suite.path)
            suites.append(m.suite)
    controls = {}

    print("== control ==")
    for s in suites:
        r = run_suite(s, "control-" + Path(s.path).stem)
        if not r.ran or r.failed:
            print(f"CONTROL IS NOT GREEN for {s.path}: rc={r.rc} failed={r.failed}")
            return 1
        controls[s.path] = r
        print(f"  {s.path}: {r.total} cases, 0 failures")

    problems = 0

    # EVERY KILLER MUST RESOLVE TO EXACTLY ONE GREEN CASE IN ITS OWN SUITE,
    # checked BEFORE any mutation.
    for mut in selected:
        matches = [c for c in controls[mut.suite.path].passed if c == mut.killer]
        if len(matches) != 1:
            print(f"{mut.id}: killer {mut.killer!r} resolves to {len(matches)} "
                  f"green case(s) in {mut.suite.path}, expected exactly 1")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} killers resolve to exactly one green case")

    # EVERY `because` MUST BE ABSENT FROM THE GREEN OUTPUT (§17's fix, and §5's
    # sentinel rule applied to it).
    for mut in selected:
        if not mut.because or mut.because == UNDERIVED:
            print(f"{mut.id}: no `because`; a kill could not be attributed")
            problems += 1
            continue
        if mut.because in controls[mut.suite.path].output:
            print(f"{mut.id}: because {mut.because!r} already occurs in the "
                  f"GREEN output of {mut.suite.path}; it cannot be evidence "
                  f"that this arm is what reddened the case")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} `because` needles are absent from the green "
          f"output\n")

    killed = 0
    for mut in selected:
        original, err = apply_once(mut.path, mut.find, mut.replace)
        if err:
            print(f"{mut.id:<5} HARNESS-FAILURE      {err}")
            problems += 1
            continue
        try:
            res = run_suite(mut.suite, f"{mut.id}-kill")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"to its control bytes")
                    return 2

        declared = mut in survivors
        newly_failed = [f for f in res.failed
                        if f not in controls[mut.suite.path].failed]
        attributed = mut.because in res.output
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and newly_failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {newly_failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif (mut.killer not in res.passed) and (mut.killer not in res.failed):
            verdict = "SUITE-DIED"
            note = (f"the suite produced {res.total} result line(s) and "
                    f"{mut.killer!r} was not among them")
            problems += 1
        elif not newly_failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer not in newly_failed:
            verdict, note = "MISDIRECTED", f"died in {newly_failed}, not {mut.killer!r}"
            problems += 1
        elif not attributed:
            verdict = "MIS-ATTRIBUTED"
            note = f"the case died without {mut.because!r} in the failure output"
            problems += 1
            print("      ---- the failure lines this arm actually produced ----")
            for line in res.output.splitlines():
                if ("Check failed" in line or " was " in line
                        or line.strip().startswith("[FAILED]")):
                    print("      " + line)
        else:
            others = [f for f in newly_failed if f != mut.killer]
            killed += 1
            verdict = "killed"
            note = mut.killer + (f"  (+{len(others)} more)" if others else "")
        print(f"{mut.id:<5} {verdict:<20} {note}")

        # --- the named behaviour-preserving control ------------------------
        if not mut.control_find:
            print(f"{'':<5} NO-CONTROL           this arm has no behaviour-preserving control")
            problems += 1
            continue
        original, err = apply_once(mut.path, mut.control_find,
                                   mut.control_replace)
        if err:
            print(f"{'':<5} CONTROL-HARNESS-FAILURE  {err}")
            problems += 1
            continue
        try:
            cres = run_suite(mut.suite, f"{mut.id}-control")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"after the control")
                    return 2
        c_newly_failed = [f for f in cres.failed
                          if f not in controls[mut.suite.path].failed]
        if not cres.ran:
            print(f"{'':<5} CONTROL-DID-NOT-RUN  {mut.control_name}")
            problems += 1
        elif c_newly_failed:
            print(f"{'':<5} CONTROL-RED          {mut.control_name} -> {c_newly_failed}")
            problems += 1
        else:
            print(f"{'':<5} control green        {mut.control_name}")

    print(f"\n{killed} killed, {len(survivors)} declared survivor(s), "
          f"{problems} problems")
    # THE LOCK IS NAMED HERE ON PURPOSE. It is held by an open descriptor and
    # nothing else reads the variable, so a tidying pass would delete the
    # binding and silently re-open the concurrency hole it exists to close.
    print(f"run lock held for the whole run: {LOCK_PATH.name} (fd {lock.fileno()})")
    lock.close()
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
