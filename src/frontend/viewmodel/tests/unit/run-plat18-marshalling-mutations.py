#!/usr/bin/env python3
"""PLAT-18's mutation harness — what the marshalling instrument and the
vertical slice would say if the thing they name had not happened.

PLAT-18 decides, by measurement, whether the WASM core should replace `nim js`
in Electron and the browser. Every number in that decision comes from three
instruments:

  * `src/frontend/viewmodel/tests/manual/plat18_marshalling_probe.nim`
        bytes, encode time, decode time and crossings for the variables pane
        over the 600-member fixture, on any of the three backends
  * `ci/test/plat18-electron-slice.sh`
        the same pane in a real Electron renderer, three arms interleaved
  * `ci/test/plat18-fake-timer-builds.sh`
        §5's rejection criterion, in DEBUG and RELEASE

**A milestone whose deliverable is a measurement has to show the measurement
can be wrong.** These arms are that: each removes one property the instrument
depends on and requires the instrument to say so, by name and for the right
reason.

THE CROSS-CHECK IS WHAT MOST ARMS GRADE, and it is worth stating why it can
carry them. There are two implementations of one wire format — `boundary_meter`
COUNTS what an operation would cost, `plat18_frame_renderer` WRITES the bytes a
host applies — because one is an instrument on the current build and the other
is the slice's actual boundary. Verification-Harness-Traps.md §14's remedy for
the case where there genuinely have to be two is a mechanical equality between
them, so the probe renders the SAME panel over the SAME state through BOTH and
requires the same total (7,572 bytes for MOUNT, 823,324 for EXPAND). An arm
that changes what either side charges for breaks the equality; an arm that
changes what BOTH charge for would not, which is why the arms below also reach
the probe's own floors.

SIX VERDICTS, NOT TWO (§1, §1a, §16a, §17), and the count is SIX because that
is how many this harness can actually emit — see the note below:

  killed                 the graded run went red AND its output carried the
                         arm's own `because`
  killed (UNATTRIBUTED)  it went red and the arm has no `because` recorded
  MIS-ATTRIBUTED         it went red for something else's reason — §17's fourth
                         verdict, which says *the run told you nothing*
  SUITE-DIED             the target built and printed no result line at all
  HARNESS-FAILURE        the target did not build, or a file did not restore
  SURVIVED               the instrument did not notice

TWO OF PLAT-17's VERDICTS ARE ABSENT, AND DELIBERATELY SO RATHER THAN BY
OVERSIGHT. `MISDIRECTED` ("something else went red and the named case did
not") and `NO-VERDICT-FOR-KILLER` ("the run printed result lines and the named
case reported neither [OK] nor [FAILED]") are both statements about a NAMED
CASE within a suite. PLAT-17's graders were `std/unittest` suites, whose
`[OK]`/`[FAILED]` lines are per case, so both verdicts were decidable there.
Every grader here is a WHOLE SCRIPT or a whole probe run — `plat18-electron-slice.sh`,
`plat18-fake-timer-builds.sh`, `plat18-dev-loop.sh`, and the probe's single
terminal `PLAT18-MARSHAL-VERDICT` — and none of them has a per-case verdict to
be silent about or to fire in the wrong place. Carrying the two labels here
would be two rows of a table that can never be reached: coverage on paper
(§16). What they protected against is covered instead by MIS-ATTRIBUTED, which
compares the arm's `because` against the transcript, so a red run for the wrong
reason is still separated from a kill.

`TOUCHED` NAMES THE GRADED SCRIPTS AND SUITES, NOT ONLY THE MUTATION SUBJECTS
(§16c). Nine of the sixteen harnesses before PLAT-17 declare subjects only,
because `TOUCHED` doubles as the restore set, the digest set and the §16b
enumeration set and "minimal" came to mean "subjects only". The cost is a
change touching ONLY a grader producing no overlap signal while invalidating
every arm graded against it — with §16's needle scan passing too, because the
subjects were never touched.

IT REACHES INTO A SECOND REPOSITORY. `isonim/src/isonim/core/boundary_meter.nim`
and `isonim/src/isonim/testing/mock_dom.nim` are in the sibling checkout
`isonim`, which `config.nims` puts on the Nim path. `TOUCHED`, the digest file
and `--enumerate-touched` all cross that boundary, and the enumeration runs
`git status --porcelain -uall` in EACH repo a `TOUCHED` entry lives in.

RESTORATION IS CHECKED PER ARM, NOT ONCE AT THE END, and one of the subjects is
in a sibling repo, so an arm that leaves a file dirty must be named where it
happened.

Usage:
    run-plat18-marshalling-mutations.py
    run-plat18-marshalling-mutations.py --needle-scan
    run-plat18-marshalling-mutations.py --enumerate-touched
    run-plat18-marshalling-mutations.py --collect-because
    run-plat18-marshalling-mutations.py --record-control-hashes
    run-plat18-marshalling-mutations.py --only=M1,S3
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]            # .../codetracer
WORKSPACE = ROOT.parent           # .../codetracer-gui

# ---------------------------------------------------------------------------
# Paths — ROOT-relative strings, so `--enumerate-touched` and any external
# auditor can resolve `TOUCHED` with `ast.parse` WITHOUT importing this module.
# Importing a harness is one keystroke from running it (§16c).
# ---------------------------------------------------------------------------

# -- mutation subjects ------------------------------------------------------
METER = "../isonim/src/isonim/core/boundary_meter.nim"          # sibling repo
FRAME = "src/frontend/viewmodel/tests/manual/plat18_frame_renderer.nim"
PROBE = "src/frontend/viewmodel/tests/manual/plat18_marshalling_probe.nim"
SLICE = "src/frontend/viewmodel/tests/manual/plat18_slice.nim"
APPLIER = "src/frontend/viewmodel/tests/manual/plat18_slice_host/applier.js"
VIEW = "src/frontend/viewmodel/views/isonim_state_view.nim"
FT_SH = "ci/test/plat18-fake-timer-builds.sh"
DEV_SH = "ci/test/plat18-dev-loop.sh"

# -- graded, never mutated (§16c) -------------------------------------------
SLICE_SH = "ci/test/plat18-electron-slice.sh"
MOCK_DOM = "../isonim/src/isonim/testing/mock_dom.nim"          # sibling repo
DRIVER = "src/frontend/viewmodel/tests/manual/plat18_slice_host/driver.js"
FT_PROBE = "src/frontend/viewmodel/tests/manual/wasm_fake_timer_probe.nim"

TOUCHED = [
    # Mutated by at least one arm:
    METER,     # M1 M2 M3 M4        (sibling repo isonim)
    FRAME,     # M6 M7
    PROBE,     # M5 M8              — and the grader for M1-M9
    SLICE,     # S1 S3
    APPLIER,   # S2
    VIEW,      # M9
    FT_SH,     # F1 F2 F3           — and the grader for itself
    DEV_SH,    # D1                 — and the grader for itself
    #
    # Graded against, never mutated. A change to any of these invalidates the
    # arms above exactly as a change to a subject would:
    SLICE_SH,  # grades S1 S2 S3
    MOCK_DOM,  # every meter byte the probe counts comes through these hooks
    DRIVER,    # the slice's row floor, which S1 and S2 are killed by
    FT_PROBE,  # the chain F1-F3's contracts are taken over
]

CONTROL_HASHES = HERE / "plat18-marshalling-mutation-control.sha256"
LOCK = HERE / ".plat18-marshalling-mutation.lock"

CACHE_ROOT = Path(os.environ.get("CT_NIM_CACHE_ROOT", "/tmp/ct-nim-cache")) / "plat18-mutations"
SCRATCH = Path(os.environ.get("CT_P18_HARNESS_OUT",
                              "/tmp/ct-plat18-harness"))


# ---------------------------------------------------------------------------
# Arms
# ---------------------------------------------------------------------------

@dataclass
class Grader:
    kind: str                 # "probe" | "script"
    target: str
    env: dict = field(default_factory=dict)

    @property
    def label(self) -> str:
        stem = Path(self.target).stem
        return f"{stem}@native" if self.kind == "probe" else stem


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    grader: Grader
    killer: str
    why: str
    control_name: str
    control_find: str
    control_replace: str
    expect: str = "verdict-fails"   # "verdict-fails" | "script-fails"


# THE PROBE IS COMPILED WITH `-d:ctPlat18Slice`, which is what brings the
# wire/meter cross-check into it. Without the define the probe measures the
# meter alone and six of the nine arms below have nothing to break.
G_PROBE = Grader("probe", PROBE)

# THE SLICE IS RUN AT ONE SAMPLE. Its published figures are medians of 9 or 15;
# an arm does not need a distribution, it needs the run to refuse, and the
# refusals here are row-count equalities that hold or do not at n=1. The
# artifact sizes and the interleaving are unaffected.
G_SLICE = Grader("script", SLICE_SH,
                 env={"CT_P18_SAMPLES": "1",
                      "CT_P18_OUT": str(SCRATCH / "slice")})

# THE FAKE-TIMER SCRIPT AT A REDUCED ITERATION COUNT, with the wall-time floor
# lowered to match. 100,000 rather than the default 300,000 costs about a third
# of the run; the floor has to come down with it or contract 0 would fire for a
# reason about this harness rather than about the arm. F3 inverts contract 0's
# COMPARISON rather than moving its constant, so it kills under either value —
# an arm that a harness's own env could disarm is §16a wearing an environment
# variable.
# ONE REPETITION, because an arm needs the contract to fire and not a
# distribution; the published figures are medians of three.
G_DEV = Grader("script", DEV_SH,
               env={"CT_P18_DEV_REPS": "1",
                    "CT_P18_DEV_OUT": str(SCRATCH / "devloop")})

G_FT = Grader("script", FT_SH,
              env={"CT_FAKE_TIMER_ITERATIONS": "100000",
                   "CT_P18_MIN_WALL_MS": "5",
                   "CT_P18_FT_OUT": str(SCRATCH / "faketimer")})


ARMS = [
    # -------------------------------------------------------------------
    # The meter — what a crossing COSTS
    # -------------------------------------------------------------------
    Arm(
        id="M1",
        path=METER,
        find="  meter.payloadBytes += int64(strBytes)\n",
        replace="  meter.payloadBytes += 0\n",
        grader=G_PROBE,
        killer="(the wire/meter cross-check)",
        expect="verdict-fails",
        why="THE STRING BYTES STOP BEING CHARGED. Crossings, handles and "
            "opcodes are all still counted, so the instrument goes on "
            "producing a plausible total — and the whole of §3's argument is "
            "that the text is the cost. The cross-check against the wire is "
            "what notices",
        control_name="the payload is accumulated through a named local",
        control_find="  meter.payloadBytes += int64(strBytes)\n",
        control_replace="  let charged = int64(strBytes)\n  meter.payloadBytes += charged\n",
    ),
    Arm(
        id="M2",
        path=METER,
        find="  1 + handles * HandleWidth + strCount * LengthWidth + strBytesTotal\n",
        replace="  1 + handles * HandleWidth + strCount * LengthWidth\n",
        grader=G_PROBE,
        killer="(the frame-size guard)",
        expect="verdict-fails",
        why="THE SIZE PREDICATE AND THE ENCODER PART. `frameBytesFor` says "
            "how big a frame is and the encoder writes it; §14 says one "
            "predicate, and where there must be two, a mechanical equality. "
            "This is that equality: the encoder's advance stops matching the "
            "size, and `sizeMismatch` is what the probe refuses over",
        control_name="the size is summed in two steps",
        control_find="  1 + handles * HandleWidth + strCount * LengthWidth + strBytesTotal\n",
        control_replace="  let framing = 1 + handles * HandleWidth + strCount * LengthWidth\n  framing + strBytesTotal\n",
    ),
    Arm(
        id="M3",
        path=METER,
        find="  proc utf8ByteLen*(s: string): int {.inline.} =\n    ## A Nim `string` on the C and WASM backends already IS its UTF-8 bytes.\n    s.len\n",
        replace="  proc utf8ByteLen*(s: string): int {.inline.} =\n    ## A Nim `string` on the C and WASM backends already IS its UTF-8 bytes.\n    0\n",
        grader=G_PROBE,
        killer="(the wire/meter cross-check)",
        expect="verdict-fails",
        why="THE UTF-8 LENGTH GOES TO ZERO on the C and WASM arms. This is "
            "the function that makes the byte count the SAME INTEGER on all "
            "three backends — the property that lets a figure taken under "
            "`nim js` be compared with one taken under wasm32 at all",
        control_name="the length is returned through an explicit result",
        control_find="  proc utf8ByteLen*(s: string): int {.inline.} =\n    ## A Nim `string` on the C and WASM backends already IS its UTF-8 bytes.\n    s.len\n",
        control_replace="  proc utf8ByteLen*(s: string): int {.inline.} =\n    ## A Nim `string` on the C and WASM backends already IS its UTF-8 bytes.\n    result = s.len\n",
    ),
    Arm(
        id="M4",
        path=METER,
        find="    decoded.add bmDecode(at, n)\n",
        replace="    decoded.add \"\"\n",
        grader=G_PROBE,
        killer="(the decode non-vacuity floor)",
        expect="verdict-fails",
        why="A DECODE THAT RETURNS NOTHING. The timing is still taken and is "
            "now very fast, which is the direction an instrument fails in "
            "silently: `decode_ns` would be published over a loop that "
            "reconstructed no strings. `decodedBytes == payloadBytes` is the "
            "floor under it",
        control_name="the decoded string is bound before it is appended",
        control_find="    decoded.add bmDecode(at, n)\n",
        control_replace="    let piece = bmDecode(at, n)\n    decoded.add piece\n",
    ),

    # -------------------------------------------------------------------
    # The probe's own floors
    # -------------------------------------------------------------------
    Arm(
        id="M5",
        path=PROBE,
        find="  let pv = PValue(kind: pvkInt, text: align($tick, 6, '0'), typeName: \"Int\",\n                  sourceKind: \"Int\")\n",
        replace="  let pv = PValue(kind: pvkInt, text: $tick, typeName: \"Int\",\n                  sourceKind: \"Int\")\n",
        grader=G_PROBE,
        killer="(the structural-stability check)",
        expect="verdict-fails",
        why="THE STEP PHASE'S BYTE COUNT STARTS MOVING between samples, "
            "because the counter grows a digit. The figures the probe "
            "publishes for a phase are a property of the view and the "
            "fixture, not of the host, so a spread there means two different "
            "renderings were averaged — and the median would have hidden it",
        control_name="the width is written with a named constant",
        control_find="  let pv = PValue(kind: pvkInt, text: align($tick, 6, '0'), typeName: \"Int\",\n                  sourceKind: \"Int\")\n",
        control_replace="  const StepWidth = 6\n  let pv = PValue(kind: pvkInt, text: align($tick, StepWidth, '0'),\n                  typeName: \"Int\", sourceKind: \"Int\")\n",
    ),
    Arm(
        id="M8",
        path=PROBE,
        find="  if node.kind == mnkElement and node.attributes.hasKey(\"data-variable-name\") and\n     node.attributes.getOrDefault(\"class\", \"\").contains(\"value-expanded-name\"):\n",
        replace="  if node.kind == mnkElement and node.attributes.hasKey(\"data-variable-name\"):\n",
        grader=G_PROBE,
        killer="(the row-count floor)",
        expect="verdict-fails",
        why="THE ROW COUNTER COUNTS TWO ELEMENTS PER ROW. "
            "`renderVariableRowImpl` puts `data-variable-name` on the row "
            "container AND on the origin badge, so without the class filter "
            "every figure here is published against a screen the probe "
            "believes has twice as many rows as it has. The same defect was "
            "found in the slice's DOM selector and fixed there",
        control_name="the two conditions are hoisted into locals",
        control_find="  if node.kind == mnkElement and node.attributes.hasKey(\"data-variable-name\") and\n     node.attributes.getOrDefault(\"class\", \"\").contains(\"value-expanded-name\"):\n",
        control_replace="  let named = node.kind == mnkElement and node.attributes.hasKey(\"data-variable-name\")\n  let isRow = node.attributes.getOrDefault(\"class\", \"\").contains(\"value-expanded-name\")\n  if named and isRow:\n",
    ),

    # -------------------------------------------------------------------
    # The frame renderer — what a crossing WRITES
    # -------------------------------------------------------------------
    Arm(
        id="M6",
        path=FRAME,
        find="  op(boCreateElement):\n    wirePutU32(int(result))\n    wirePutStr(tag)\n",
        replace="  op(boCreateElement):\n    wirePutStr(tag)\n",
        grader=G_PROBE,
        killer="(the wire/meter cross-check)",
        expect="verdict-fails",
        why="THE HANDLE STOPS CROSSING on element creation. §3's whole point "
            "about DOM nodes is that a WASM core holds an INDEX rather than a "
            "node, so the index is part of what every create costs — 4 bytes "
            "× 9,000 creates on the expand alone",
        control_name="the handle is written through a local",
        control_find="  op(boCreateElement):\n    wirePutU32(int(result))\n    wirePutStr(tag)\n",
        control_replace="  let handle = int(result)\n  op(boCreateElement):\n    wirePutU32(handle)\n    wirePutStr(tag)\n",
    ),
    Arm(
        id="M7",
        path=FRAME,
        find="proc appendChild*(r: FrameRenderer; parent, child: FrameNode) =\n  op(boAppendChild):\n    wirePutU32(int(parent))\n    wirePutU32(int(child))\n",
        replace="proc appendChild*(r: FrameRenderer; parent, child: FrameNode) =\n  op(boAppendChild):\n    wirePutU32(int(parent))\n",
        grader=G_PROBE,
        killer="(the wire/meter cross-check)",
        expect="verdict-fails",
        why="A TREE OPERATION LOSES ONE OF ITS TWO HANDLES. `AppendChild` is "
            "the single commonest operation the pane issues — 12,000 of the "
            "42,017 on the expand — so undercharging it by four bytes moves "
            "the headline figure by 48 KB while the stream still applies",
        control_name="the two handles are written from a tuple",
        control_find="proc appendChild*(r: FrameRenderer; parent, child: FrameNode) =\n  op(boAppendChild):\n    wirePutU32(int(parent))\n    wirePutU32(int(child))\n",
        control_replace="proc appendChild*(r: FrameRenderer; parent, child: FrameNode) =\n  let pair = (int(parent), int(child))\n  op(boAppendChild):\n    wirePutU32(pair[0])\n    wirePutU32(pair[1])\n",
    ),

    # -------------------------------------------------------------------
    # The view — the extraction that gave the slice the SAME markup
    # -------------------------------------------------------------------
    Arm(
        id="M9",
        path=VIEW,
        find="  indexEach[VariableViewState, RendererT, NodeT](r, rowContainer,\n",
        replace="  if false: indexEach[VariableViewState, RendererT, NodeT](r, rowContainer,\n",
        grader=G_PROBE,
        killer="(the row-count floor)",
        expect="verdict-fails",
        why="THE ROWS STOP BEING WIRED to the panel. `renderStatePanelImpl` "
            "is the extraction PLAT-18 made so the slice draws the SAME "
            "markup as the product instead of a copy of it; if the "
            "instantiation stops producing rows, every byte count in this "
            "milestone is a measurement of an empty pane",
        control_name="the container is bound before the list is attached",
        control_find="  indexEach[VariableViewState, RendererT, NodeT](r, rowContainer,\n",
        control_replace="  let rows = rowContainer\n  indexEach[VariableViewState, RendererT, NodeT](r, rows,\n",
    ),

    # -------------------------------------------------------------------
    # The slice — the pane in a real Electron renderer
    # -------------------------------------------------------------------
    Arm(
        id="S1",
        path=SLICE,
        find="    appendChild(theRenderer, NoFrameNode, thePanelRoot)\n",
        replace="    discard thePanelRoot\n",
        grader=G_SLICE,
        killer="(the slice's row floor)",
        expect="script-fails",
        why="THE PANEL NEVER REACHES THE DOCUMENT. The core still builds it, "
            "`p18Rows` still answers 602, and every timing is still taken — "
            "over a document that stayed empty. The floor is that the CORE's "
            "count and the DOCUMENT's must agree, which is exactly the "
            "difference between those two claims",
        control_name="the root handle is bound before it is attached",
        control_find="    appendChild(theRenderer, NoFrameNode, thePanelRoot)\n",
        control_replace="    let container = NoFrameNode\n    appendChild(theRenderer, container, thePanelRoot)\n",
    ),
    Arm(
        id="S2",
        path=APPLIER,
        find="  SetAttribute: (c) => { const h = c.u32(); const n = c.str(), v = c.str(); c.nodes[h].setAttribute(n, v); },\n",
        replace="  SetAttribute: (c) => { c.u32(); c.str(); c.str(); },\n",
        grader=G_SLICE,
        killer="(the slice's row floor)",
        expect="script-fails",
        why="THE HOST READS AN OPERATION AND DOES NOT PERFORM IT. The frame "
            "still parses, the op count still matches, and the document is "
            "missing every attribute — which is the failure mode a host-side "
            "applier has that a direct renderer does not, and the one a "
            "count-only check could never see",
        control_name="the attribute name and value are read into separate statements",
        control_find="  SetAttribute: (c) => { const h = c.u32(); const n = c.str(), v = c.str(); c.nodes[h].setAttribute(n, v); },\n",
        control_replace="  SetAttribute: (c) => { const h = c.u32(); const n = c.str(); const v = c.str(); c.nodes[h].setAttribute(n, v); },\n",
    ),
    Arm(
        id="S3",
        path=SLICE,
        find="    emscriptenExitWithLiveRuntime()\n",
        replace="    discard\n",
        grader=G_SLICE,
        killer="(the slice's row floor)",
        expect="script-fails",
        why="MAIN RETURNS, AND ORC DESTROYS THE MODULE'S GLOBALS. This is the "
            "defect PLAT-18 found the moment PLAT-17's core was wired into a "
            "front-end, restored: `NimMainModule` ends with `=destroy` calls "
            "on every global of the main module, so a host calling in "
            "afterwards operates on freed memory. It does not crash — a "
            "`HashSet[string]` goes on reporting `card == 81` while lookups "
            "return false — which is why the arm is graded by an EFFECT on "
            "the document rather than by a status",
        control_name="the live-runtime call is made through a local alias",
        control_find="    emscriptenExitWithLiveRuntime()\n",
        control_replace="    let keepAlive = emscriptenExitWithLiveRuntime\n    keepAlive()\n",
    ),

    # -------------------------------------------------------------------
    # The fake-timer re-measurement — §5's rejection criterion
    # -------------------------------------------------------------------
    Arm(
        id="F1",
        path=FT_SH,
        find='MIN_RATIO="${CT_P18_MIN_RATIO:-1000}"\n',
        replace='MIN_RATIO="${CT_P18_MIN_RATIO:-100000000}"\n',
        grader=G_FT,
        killer="(contract 2 — the mechanism threshold)",
        expect="script-fails",
        why="THE MECHANISM THRESHOLD RAISED ABOVE THE MEASUREMENT. 1,000 sits "
            "between the ~1 a chain deferring to a host loop scores and the "
            "tens of thousands this one does; above the measurement the "
            "script reports FAILED over a chain entirely inside its runtime, "
            "which is the arm that says the threshold separates two "
            "MECHANISMS rather than tuning a speed",
        control_name="the threshold default is written with an underscore",
        control_find='MIN_RATIO="${CT_P18_MIN_RATIO:-1000}"\n',
        control_replace='MIN_RATIO="${CT_P18_MIN_RATIO:-1_000}"\n',
    ),
    Arm(
        id="F2",
        path=FT_SH,
        find='MAX_SLOWDOWN="${CT_P18_MAX_SLOWDOWN:-3.0}"\n',
        replace='MAX_SLOWDOWN="${CT_P18_MAX_SLOWDOWN:-0.1}"\n',
        grader=G_FT,
        killer="(contract 3 — §5's rejection criterion)",
        expect="script-fails",
        why="§5's REJECTION CRITERION LOWERED UNDER THE MEASUREMENT. This is "
            "the contract the whole milestone can turn on — a fake-timer "
            "suite materially slower under WASM outweighs artifact "
            "uniformity — so a run in which it cannot fire is a run in which "
            "the criterion was not applied",
        control_name="the limit default is written with a trailing zero",
        control_find='MAX_SLOWDOWN="${CT_P18_MAX_SLOWDOWN:-3.0}"\n',
        control_replace='MAX_SLOWDOWN="${CT_P18_MAX_SLOWDOWN:-3.00}"\n',
    ),
    Arm(
        id="F3",
        path=FT_SH,
        find="\t\tif ! awk -v w=\"${w}\" -v m=\"${MIN_WALL_MS}\" 'BEGIN{exit !(w+0 >= m+0)}'; then\n",
        replace="\t\tif ! awk -v w=\"${w}\" -v m=\"${MIN_WALL_MS}\" 'BEGIN{exit !(w+0 <= m+0)}'; then\n",
        grader=G_FT,
        killer="(contract 0 — the clock can resolve it)",
        expect="script-fails",
        why="CONTRACT 0's COMPARISON INVERTED. The contract exists because "
            "PLAT-17's 20,000-iteration release timing read `22.000` against "
            "a 1 ms quantum and produced 2.98x against a 3.0 limit — a "
            "correct build failing about half the time (§12a through a "
            "clock's resolution). The arm inverts the COMPARISON rather than "
            "moving the constant, so this harness's own "
            "`CT_P18_MIN_WALL_MS` cannot disarm it — an arm an environment "
            "variable can turn off is §16a wearing a `-e`",
        control_name="the floor comparison is written with the operands swapped",
        control_find="\t\tif ! awk -v w=\"${w}\" -v m=\"${MIN_WALL_MS}\" 'BEGIN{exit !(w+0 >= m+0)}'; then\n",
        control_replace="\t\tif ! awk -v w=\"${w}\" -v m=\"${MIN_WALL_MS}\" 'BEGIN{exit !(m+0 <= w+0)}'; then\n",
    ),

    # -------------------------------------------------------------------
    # The developer loop — §5's fifth criterion
    # -------------------------------------------------------------------
    Arm(
        id="D1",
        path=DEV_SH,
        find='\tlimit="${CT_P18_DEV_MAX:-5.0}"\n',
        replace='\tlimit="${CT_P18_DEV_MAX:-0.1}"\n',
        grader=G_DEV,
        killer="(contract 2 — the developer-loop regression gate)",
        expect="script-fails",
        why="THE REGRESSION GATE LOWERED UNDER THE MEASUREMENT. This is the "
            "only contract in the dev-loop script that can fail a run — §5's "
            "criterion beside it is REPORTED — so a gate that cannot fire "
            "leaves the script unable to say anything at all, and its "
            "`plat18-dev-loop: all contracts hold` would be true of a loop "
            "that had become ten times slower",
        control_name="the regression limit is written with a trailing zero",
        control_find='\tlimit="${CT_P18_DEV_MAX:-5.0}"\n',
        control_replace='\tlimit="${CT_P18_DEV_MAX:-5.00}"\n',
    ),
]


# ---------------------------------------------------------------------------
# `because` — DERIVED FROM TRANSCRIPTS, NEVER TYPED (§17a, §17b)
# ---------------------------------------------------------------------------
#
# Regenerate with `--collect-because`. A string typed from a source file is a
# second copy of the code held where the compiler does not read it (§14), and
# it goes stale exactly as §16's needle does with NO SCAN ABLE TO SEE IT
# (§17b) — the only instrument is running the arm.
BECAUSE: dict = {
    # --- the probe's refusals: COUNTS, quoted verbatim ----------------------
    # Several arms are told apart by WHICH refusals fired together and by the
    # SIZE of the disagreement, so the clauses are ` && `-joined and the
    # numbers are kept. See `derived_because` for why that is the opposite of
    # §17a's usual rule here and why it is right.
    'M1': 'decode returned 237 byte(s) of 0 && decode returned 3802 byte(s) of 0 && decode returned 382719 byte(s) of 0 && decode returned 5391 byte(s) of 0 && wire/meter disagree on EXPAND: meter 440605 byte(s), wire 823324 && wire/meter disagree on MOUNT: meter 2181 byte(s), wire 7572',
    'M2': 'frame size disagreed with frameBytesFor 133 time(s) && frame size disagreed with frameBytesFor 15 time(s) && frame size disagreed with frameBytesFor 16 time(s) && frame size disagreed with frameBytesFor 27016 time(s)',
    # M3 is M2's set PLUS the cross-check's, and that is what separates them:
    # M2 breaks the size predicate alone, M3 stops measuring the bytes at all.
    'M3': 'frame size disagreed with frameBytesFor 133 time(s) && frame size disagreed with frameBytesFor 15 time(s) && frame size disagreed with frameBytesFor 16 time(s) && frame size disagreed with frameBytesFor 27016 time(s) && wire/meter disagree on EXPAND: meter 440605 byte(s), wire 823324 && wire/meter disagree on MOUNT: meter 2181 byte(s), wire 7572',
    'M4': 'decode returned 0 byte(s) of 237 && decode returned 0 byte(s) of 3802 && decode returned 0 byte(s) of 382719 && decode returned 0 byte(s) of 5391',
    'M5': 'structural figures not stable across samples (16/424 vs 16/425)',
    # M6 and M7 print the same SENTENCE and different totals: 36,000 bytes is
    # 9,000 element creations undercharged by four, 48,000 is 12,000 appends.
    'M6': 'wire/meter disagree on EXPAND: meter 823324 byte(s), wire 787324 && wire/meter disagree on MOUNT: meter 7572 byte(s), wire 7392',
    'M7': 'wire/meter disagree on EXPAND: meter 823324 byte(s), wire 775324 && wire/meter disagree on MOUNT: meter 7572 byte(s), wire 7332',
    # M8 counts two elements per row; M9 wires no rows at all.
    'M8': 'COLLAPSE drew 4 row(s), expected 2 && EXPAND drew 1204 row(s), expected 602 && MOUNT drew 4 row(s), expected 2 && STEP drew 1204 row(s), expected 602',
    'M9': 'COLLAPSE drew 0 row(s), expected 2 && EXPAND drew 0 row(s), expected 602 && MOUNT drew 0 row(s), expected 2 && STEP drew 0 row(s), expected 602',

    # --- the slice's refusals ------------------------------------------------
    # S1 and S2 produced the SAME string until the driver grew a second check.
    # "the panel reached the document" and "the rows are identifiable in it"
    # are different properties, and one row count answered 0 for both — §16a,
    # and the repair is in driver.js's `checkAttached`.
    'S1': 'js-crossing/MOUNT: the panel never reached the document — the container holds 0 child element(s)',
    'S2': 'js-crossing/MOUNT: core says 2 row(s), the document holds 0, expected 2',
    # S3 is the ORC-destroys-globals defect restored. It reaches only the wasm
    # arm, which is what tells it from S1: the two JS arms pass and the
    # transcript names the one that did not.
    'S3': 'wasm-crossing/MOUNT: the panel never reached the document — the container holds 0 child element(s)',

    # --- the fake-timer contracts: RATIOS, so these ARE normalised ----------
    'F1': 'FAIL: debug/native scores N.N, below N — the chain is deferring to a host loop',
    'F2': "FAIL: debug: wasm is N.Nx native's wall time, above N.Nx — §N's rejection criterion",
    'F3': 'FAIL: debug/native wall time is N.N ms, under the N ms floor — raise CT_FAKE_TIMER_ITERATIONS; a N ms clock quantum is worth N.N% of this number',

    # --- the developer loop: also a ratio, so also normalised --------------
    'D1': 'FAIL: one edit-compile-run is N.Nx the nim js loop under wasm, above the N.Nx regression limit',
}


# ---------------------------------------------------------------------------
# Transcript parsing
# ---------------------------------------------------------------------------
#
# ANSI IS STRIPPED BEFORE ANYTHING READS A TRANSCRIPT. `std/unittest` colours
# its result lines unless told otherwise, and an anchored `^\s*\[(OK|FAILED)\]`
# matches none of the coloured bytes — a scanner that finds nothing, passing
# every "must not contain" and failing every "must" (trap 4).
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(s: str) -> str:
    return ANSI.sub("", s)


# The probe's own vocabulary. `PLAT18-MARSHAL-PROBLEM <text>` is one refusal;
# `PLAT18-MARSHAL-VERDICT ok` is the terminal green line.
PROBE_PROBLEM = re.compile(r"^PLAT18-MARSHAL-PROBLEM\s+(.*?)\s*$", re.M)
PROBE_VERDICT_OK = re.compile(r"^PLAT18-MARSHAL-VERDICT ok\s*$", re.M)
PROBE_VERDICT_FAIL = re.compile(r"^PLAT18-MARSHAL-VERDICT FAIL\b", re.M)
PROBE_CROSSCHECK = re.compile(r"^PLAT18-MARSHAL cross-check .*AGREE\s*$", re.M)

# The two scripts. `plat18-electron-slice.sh` reports through the renderer's
# `PLAT18-SLICE-VERDICT` line and its own `PLAT-18 slice:` summary;
# `plat18-fake-timer-builds.sh` uses `  ok: ` / `  FAIL: `.
SH_OK_LINE = re.compile(r"^\s*ok:\s+(.*?)\s*$")
SH_FAIL_LINE = re.compile(r"^\s*FAIL:\s+(.*?)\s*$")
SLICE_VERDICT_OK = re.compile(r"^PLAT18-SLICE-VERDICT ok\s*$", re.M)
SLICE_VERDICT_FAIL = re.compile(r"^PLAT18-SLICE-VERDICT FAIL\s+(.*?)\s*$", re.M)
SLICE_ARMS = re.compile(r"^PLAT18-SLICE-ARMS\s+(.*?)\s*$", re.M)
FT_TERMINAL = re.compile(r"^plat18-fake-timer-builds:", re.M)


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True
    built: bool = True
    transcript: str = ""

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def parse_probe(out: str, rc: int, built: bool) -> RunResult:
    out = strip_ansi(out)
    res = RunResult(rc=rc, built=built, transcript=out)
    if not built:
        res.ran = False
        return res
    # A PROBE THAT RAN IS ONE THAT REACHED ITS TERMINAL VERDICT. Reading `ran`
    # off the problem lines alone would score a probe that died halfway — the
    # case where the run told you nothing — as a probe with nothing to say.
    green = bool(PROBE_VERDICT_OK.search(out))
    problems = PROBE_PROBLEM.findall(out)
    res.failed = problems
    if green:
        # The cross-check's AGREE lines and the four phase lines are what a
        # green run has to show for itself; naming them individually is what
        # lets the pre-flight assert the instrument was not merely quiet.
        res.passed = PROBE_CROSSCHECK.findall(out) or ["(probe verdict ok)"]
    res.ran = green or bool(problems) or bool(PROBE_VERDICT_FAIL.search(out))
    return res


def parse_script(out: str, rc: int) -> RunResult:
    out = strip_ansi(out)
    res = RunResult(rc=rc, transcript=out)
    for line in out.splitlines():
        m = SH_OK_LINE.match(line)
        if m:
            res.passed.append(m.group(1))
            continue
        m = SH_FAIL_LINE.match(line)
        if m:
            res.failed.append(m.group(1))
    # The slice prints no `ok:` markers at all — its green path is the
    # renderer's `PLAT18-SLICE-VERDICT ok` plus the three-arm list. Both are
    # required: a verdict over two arms is a verdict about a different
    # experiment.
    if SLICE_VERDICT_OK.search(out):
        arms = SLICE_ARMS.search(out)
        res.passed.append("slice verdict ok: " + (arms.group(1) if arms else "?"))
    for m in SLICE_VERDICT_FAIL.finditer(out):
        res.failed.append(m.group(1))
    res.ran = bool(res.passed or res.failed or FT_TERMINAL.search(out))
    return res


def because_matches(b: str, transcript: str) -> bool:
    """Does this transcript carry every clause of the arm's `because`?

    Clauses are ` && `-separated and EVERY one must occur. A single clause
    would attribute two arms to one refusal — the probe reports per phase and
    per check, and what distinguishes several of these arms is WHICH refusals
    fired together rather than which fired first (see `derived_because`).

    Matched against the raw transcript AND against a number-normalised copy of
    it, so a clause derived from a probe refusal (counts, kept verbatim) and a
    clause derived from a script contract (a ratio, normalised) are both
    findable without the caller having to know which kind it holds.
    """
    if not b:
        return False
    raw = strip_ansi(transcript)
    norm = normalise_numbers(raw)
    return all(clause in raw or clause in norm for clause in b.split(" && "))


def normalise_numbers(s: str) -> str:
    """Every run of digits replaced by `N`.

    Byte counts, row counts and wall times all appear in the lines below and
    all of them move. What does not move is the sentence around them, and that
    is what a `because` has to be a quotation of.
    """
    return re.sub(r"\d+", "N", s).strip()


def derived_because(text: str) -> str:
    """The most specific stable evidence a failing transcript carries.

    The order is the content of this function, and each rung is here because
    an arm would otherwise have been mis-attributed:

      1. the PROBE's own `PLAT18-MARSHAL-PROBLEM` line — its statement of the
         EFFECT (§17a's closing rule), with any MEASUREMENT stripped, because
         a `because` carrying a number that moves is wrong INTERMITTENTLY;
      2. the SLICE's `PLAT18-SLICE-VERDICT FAIL <text>`, likewise the effect —
         "core says N row(s), the document holds M";
      3. a script's whole `FAIL:` line. The contract NAME alone occurs in a
         GREEN run too, as `ok: <name>`, so it is satisfied for free (§17).
    """
    text = strip_ansi(text)
    problems = PROBE_PROBLEM.findall(text)
    if problems:
        # THE SET OF REFUSALS, NOT THE FIRST ONE — and this is the shape of
        # §16a rather than a convenience.
        #
        # The probe refuses per PHASE, so its first line names MOUNT whatever
        # the defect was. Derived from the first line alone, four of these arms
        # collapse into two pairs: M1 and M4 both report `decode returned …`
        # and M2 and M3 both report `frame size disagreed …`. Derived from the
        # LAST line they collapse differently — M1 and M3 both end at
        # `wire/meter disagree`. Neither single line separates them, because
        # neither is what distinguishes them: M1 stops CHARGING for the string
        # bytes and M3 stops MEASURING them, so M3 additionally breaks the
        # frame-size equality and M1 does not. The evidence is which refusals
        # fired TOGETHER.
        #
        # So: strip the phase prefix (a defect in the meter fires in every
        # phase and the phase names carry no information about it), normalise
        # the measurements, dedupe, sort, and join. The clauses are matched
        # individually against a normalised transcript — see `because_matches`.
        # THE NUMBERS ARE KEPT, and that is the opposite of what §17a asks for
        # everywhere else on this page — so it needs its reason stated. §17a's
        # rule is that a `because` carrying a MEASUREMENT is wrong
        # intermittently. Every number in a probe refusal is a COUNT: bytes on
        # a wire, rows on a screen, refusals in a loop. All three are
        # deterministic functions of the fixture and the view, and NO wall time
        # ever reaches one of these lines — the timings live in the
        # `PLAT18-MARSHAL phase=` rows, which no arm quotes.
        #
        # Keeping them is also what separates two pairs of arms that nothing
        # else does: M6 undercharges 9,045 element creations by four bytes and
        # M7 undercharges 12,060 appends by four, so the two produce the same
        # SENTENCE and different totals; M8 makes the row counter count two
        # elements per row and M9 stops the rows being wired at all, so one
        # reports 1,204 where 602 was expected and the other 0. Normalised,
        # each pair collapsed into one string and the harness refused the run
        # — which is the duplicate guard working, and this is its repair.
        #
        # The script arms are the exception and they DO normalise: a
        # fake-timer contract quotes a ratio and a wall time, and both move on
        # every run.
        shapes = []
        for line in problems:
            body = re.sub(r"^(MOUNT|EXPAND|STEP|COLLAPSE): ", "", line)
            if body not in shapes:
                shapes.append(body)
        return " && ".join(sorted(shapes))
    for m in SLICE_VERDICT_FAIL.finditer(text):
        # `js-direct/MOUNT: core says 2 row(s), the document holds 4, …` —
        # counts again, and the arm to arm difference is in them.
        return m.group(1)[:200]
    for line in text.splitlines():
        m = SH_FAIL_LINE.match(line)
        if m:
            # NORMALISED, unlike the two branches above: a fake-timer contract
            # quotes a ratio and a wall time and both move on every run.
            return "FAIL: " + normalise_numbers(m.group(1))
    for line in text.splitlines():
        s = line.strip()
        if s and not s.startswith("/") and not s.startswith("wasm://"):
            return s[:160]
    return ""


# ---------------------------------------------------------------------------
# Graders
# ---------------------------------------------------------------------------

def _env(extra: dict) -> dict:
    e = dict(os.environ)
    e.update(extra)
    return e


def run_grader(g: Grader) -> RunResult:
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    SCRATCH.mkdir(parents=True, exist_ok=True)
    if g.kind == "script":
        proc = subprocess.run(["bash", g.target], cwd=ROOT,
                              capture_output=True, text=True,
                              errors="replace", env=_env(g.env), timeout=7200)
        return parse_script(proc.stdout + proc.stderr, proc.returncode)

    cache = CACHE_ROOT / "probe"
    artifact = CACHE_ROOT / "probe.bin"
    # `-d:ctPlat18Slice` is what brings the wire/meter cross-check in, and
    # `--mm:orc` is named rather than defaulted (§12b: a measurement names its
    # memory manager, and so does the run that grades one).
    cmd = ["nim", "c", "--hints:off", "--warnings:off", "--mm:orc",
           "-d:ctPlat18Slice", "--path:src/frontend/viewmodel",
           f"--nimcache:{cache}", f"-o:{artifact}", g.target]
    build = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           errors="replace", env=_env(g.env), timeout=7200)
    if build.returncode != 0:
        return parse_probe(build.stdout + build.stderr, build.returncode, built=False)
    proc = subprocess.run([str(artifact)], cwd=ROOT, capture_output=True,
                          text=True, errors="replace", env=_env(g.env),
                          timeout=7200)
    return parse_probe(proc.stdout + proc.stderr, proc.returncode, built=True)


# ---------------------------------------------------------------------------
# Digests, the lock, the needle scan, the §16b enumeration
# ---------------------------------------------------------------------------

def digest(rel: str) -> str:
    return hashlib.sha256((ROOT / rel).read_bytes()).hexdigest()


def repo_of(rel: str) -> Path:
    """The git repo a `TOUCHED` entry lives in.

    Two entries are in the sibling checkout `isonim`, so neither the digest
    sweep nor the §16b enumeration may assume one repository.
    """
    p = (ROOT / rel).resolve()
    d = p.parent
    while d != d.parent:
        if (d / ".git").exists():
            return d
        d = d.parent
    return ROOT


def read_control_hashes() -> dict:
    if not CONTROL_HASHES.exists():
        return {}
    out = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        out[p] = h
    return out


def write_control_hashes() -> None:
    lines = [
        "# Control digests for run-plat18-marshalling-mutations.py.",
        "#",
        "# The bytes every arm restores to, and the bytes every arm's verdict",
        "# was taken against. Both halves of TOUCHED are here — the seven",
        "# mutation subjects AND the four graders no arm mutates — which is",
        "# §16c's gap paid rather than inherited.",
        "#",
        "# TWO ENTRIES ARE OUTSIDE THIS REPOSITORY:",
        "# ../isonim/src/isonim/core/boundary_meter.nim and",
        "# ../isonim/src/isonim/testing/mock_dom.nim, in the sibling checkout",
        "# config.nims puts on the Nim path. PLAT-18's instrument is in the",
        "# library whose renderers it measures.",
        "#",
        "# Refreshed with --record-control-hashes, which the needle scan GATES",
        "# (§16): re-recording from a tree whose arms have stopped matching",
        "# certifies the arms along with the bytes.",
    ]
    for p in TOUCHED:
        lines.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")


def needle_scan() -> list[str]:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    Exactly once, not at least once: an arm whose needle occurs twice has two
    targets and hits neither (§16).
    """
    bad = []
    for a in ARMS:
        text = (ROOT / a.path).read_text()
        n = text.count(a.find)
        if n != 1:
            bad.append(f"{a.id:<4} find occurs {n}x in {a.path}")
        n = text.count(a.control_find)
        if n != 1:
            bad.append(f"{a.id:<4} control_find occurs {n}x in {a.path}")
    return bad


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN: an arm has stopped quoting code that exists.")
        print("  A quotation that no longer matches is a row in the table that")
        print("  looks like coverage and can never be killed (§16).")
        for b in bad:
            print("   ", b)
        return 2
    print(f"needle scan: all {len(ARMS)} arms' find and control_find resolve "
          "to exactly one site")
    return 0


def enumerate_touched() -> int:
    """§16b: intersect `TOUCHED` with the diff BEING COMMITTED, per repo.

    The subject set is the COMMIT's, not the session's — and `-uall`, because
    untracked files are in the diff being committed and a porcelain call
    without it reports a DIRECTORY for a new tree and misses every file under
    it.
    """
    repos: dict = {}
    for p in TOUCHED:
        repos.setdefault(repo_of(p), []).append(p)
    total = 0
    for repo, paths in sorted(repos.items()):
        proc = subprocess.run(["git", "status", "--porcelain", "-uall"],
                              cwd=repo, capture_output=True, text=True)
        diff = {line[3:] for line in proc.stdout.splitlines() if line[3:]}
        print(f"{repo.name}: {len(diff)} path(s) in the diff being committed")
        for p in sorted(paths):
            rel = os.path.relpath((ROOT / p).resolve(), repo)
            mark = "OVERLAPS" if rel in diff else "clean   "
            if rel in diff:
                total += 1
            print(f"  {mark}  {rel}")
    print(f"\n{total} of {len(TOUCHED)} TOUCHED entries are in the diff.")
    print("An overlapping harness has two dispositions — re-run, or")
    print("deliberately deferred with a reason — and neither is absence "
          "from a list.")
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list) -> int:
    only = None
    for a in argv:
        if a.startswith("--only="):
            only = {s.strip() for s in a[len("--only="):].split(",")}
    arms = [a for a in ARMS if only is None or a.id in only]

    if "--needle-scan" in argv:
        return report_needle_scan()
    if "--enumerate-touched" in argv:
        return enumerate_touched()

    # THE LOCK IS TAKEN BEFORE THE BASELINE DIGESTS ARE READ. A second run
    # starting between the read and the first mutation would record a mutated
    # file as the control bytes. `flock`, never `pgrep -f`: a `pgrep` pattern
    # matches the auditor reading this file.
    lock_fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"another run holds {LOCK}. Never two harnesses at once.")
        return 2

    try:
        collecting = "--collect-because" in argv

        rc = report_needle_scan()
        if rc:
            return rc

        if "--record-control-hashes" in argv:
            # GATED BY THE SCAN ABOVE (§16). The natural next step after a
            # repair is to re-bless the baseline; doing that first leaves the
            # harness perfectly consistent with a tree in which some of its
            # arms describe nothing.
            write_control_hashes()
            print(f"recorded {len(TOUCHED)} control digest(s) to "
                  f"{CONTROL_HASHES.name}")
            return 0

        recorded = read_control_hashes()
        if not recorded:
            print(f"no {CONTROL_HASHES.name}; run --record-control-hashes "
                  "first (the needle scan gates it).")
            return 2
        drift = [(p, recorded.get(p), digest(p))
                 for p in TOUCHED if recorded.get(p) != digest(p)]
        if drift:
            print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
            for p, want, got in drift:
                print(f"  {p}\n      recorded {want}   on disk {got}")
            return 2
        baseline = {p: recorded[p] for p in TOUCHED}

        # PRE-FLIGHT over the UNMUTATED tree: every grader green, and every
        # `because` ABSENT from the green transcript. A `because` that already
        # occurs in a passing run is true for free (§17).
        graders = []
        for a in arms:
            if a.grader not in graders:
                graders.append(a.grader)
        control_runs = {}
        print("\n--- control pre-flight (the unmutated tree) ---", flush=True)
        for g in graders:
            res = run_grader(g)
            control_runs[id(g)] = res
            if not res.ran:
                print(f"CONTROL IS NOT GREEN: {g.label} produced no result "
                      "lines at all. Nothing below would mean anything.")
                print(res.transcript[-3000:])
                return 2
            if res.failed:
                print(f"CONTROL IS NOT GREEN: {g.label} -> {res.failed[:3]}")
                return 2
            print(f"  {g.label:<44} {res.total} result line(s), 0 failed",
                  flush=True)

        for a in arms:
            b = BECAUSE.get(a.id, "")
            ctl = control_runs[id(a.grader)]
            if b and because_matches(b, ctl.transcript):
                print(f"{a.id}: its `because` already occurs in the GREEN run "
                      "— it would be satisfied for free (§17).")
                return 2

        print(f"\n--- {len(arms)} arm(s) ---", flush=True)
        problems = 0
        collected = {}
        for a in arms:
            path = ROOT / a.path
            original = path.read_text()
            if original.count(a.find) != 1:
                print(f"{a.id:<5} HARNESS-FAILURE  the needle stopped "
                      f"resolving mid-run in {a.path}")
                return 2
            path.write_text(original.replace(a.find, a.replace))
            try:
                res = run_grader(a.grader)
            finally:
                path.write_text(original)
                # PER ARM, not once at the end. An arm that left a file dirty
                # must be named where it happened, because every verdict after
                # it is otherwise suspect — and two of these files are in a
                # sibling repository.
                for p in TOUCHED:
                    if digest(p) != baseline[p]:
                        print(f"{a.id:<5} HARNESS-FAILURE  {p} did not restore "
                              "to its control bytes")
                        return 2

            note = ""
            if not res.built:
                verdict, note = "HARNESS-FAILURE", "the target did not build"
                problems += 1
            elif not res.ran:
                verdict, note = "SUITE-DIED", ("the target built and reached no "
                                               "verdict line at all")
                problems += 1
            elif not res.failed:
                verdict, note = "SURVIVED", "the instrument reported nothing"
                problems += 1
            elif collecting:
                verdict = "collected"
                note = derived_because(res.transcript) or "(nothing)"
                if note != "(nothing)":
                    collected[a.id] = note
            elif not BECAUSE.get(a.id, ""):
                verdict = "killed (UNATTRIBUTED)"
                note = "no `because`; run --collect-because"
                problems += 1
            elif not because_matches(BECAUSE[a.id], res.transcript):
                verdict = "MIS-ATTRIBUTED"
                note = (f"{BECAUSE[a.id]!r} not in the transcript; it said: "
                        + derived_because(res.transcript))
                problems += 1
            else:
                verdict = "killed"
                note = BECAUSE[a.id].splitlines()[0][:76]

            print(f"{a.id:<5} {a.grader.label[:32]:<32} {verdict:<22} {note}",
                  flush=True)

        if collecting:
            # TWO ARMS MAY NOT SHARE ONE `because`. A string two mutations both
            # produce cannot attribute either, and the harness would report
            # `killed` for an arm whose grader failed for the other's reason —
            # §17's mis-attribution with the detector disarmed, and §5a one
            # layer down: two events with different remedies behind one value.
            dupes: dict = {}
            for k, v in collected.items():
                dupes.setdefault(v, []).append(k)
            shared = {v: ks for v, ks in dupes.items() if len(ks) > 1}
            print("\n# paste into BECAUSE:")
            for k, v in collected.items():
                print(f"    {k!r}: {v!r},")
            if shared:
                print("\nREFUSING: these arms derived the SAME `because`, so "
                      "neither can be attributed:")
                for v, ks in shared.items():
                    print(f"  {ks} -> {v!r}")
                print("  Aim `derived_because` at evidence only one of them "
                      "produces; do not type one in.")
                return 2
            return 0

        # THE CONTROLS. Each is behaviour-preserving and must leave its grader
        # green. Without them an arm cannot tell "the mutation broke the
        # property" from "any edit to this file breaks the build".
        print(f"\n--- {len(arms)} behaviour-preserving control(s) ---", flush=True)
        for a in arms:
            path = ROOT / a.path
            original = path.read_text()
            if original.count(a.control_find) != 1:
                print(f"{'':<5} CONTROL-HARNESS-FAILURE  {a.id}'s control "
                      f"needle stopped resolving in {a.path}")
                problems += 1
                continue
            path.write_text(original.replace(a.control_find, a.control_replace))
            try:
                res = run_grader(a.grader)
            finally:
                path.write_text(original)
                for p in TOUCHED:
                    if digest(p) != baseline[p]:
                        print(f"{a.id:<5} CONTROL-HARNESS-FAILURE  {p} did not "
                              "restore to its control bytes")
                        return 2
            if not res.ran:
                print(f"{a.id:<5} CONTROL-DID-NOT-RUN      {a.control_name}")
                problems += 1
            elif res.failed:
                print(f"{a.id:<5} CONTROL-RED              {a.control_name} "
                      f"-> {res.failed[:2]}")
                problems += 1
            else:
                print(f"{a.id:<5} control green            {a.control_name}",
                      flush=True)

        print(f"\n{len(arms)} arms, {problems} problems")
        return 1 if problems else 0
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
