#!/usr/bin/env python3
"""PLAT-26's mutation harness — proof that the selection suite can go red.

`test_editor_selection_laws.nim` claims that six laws, a twelve-operation
totality sweep, a generator and two source scans each detect something. This
script proves it one case at a time: it patches a single passage of a SUBJECT —
the selection model, the operation set, the generator, or the suites' own
non-vacuity machinery — and requires the **named** case to fail. A mutation
killed only by some other case is MISDIRECTED and is a failure of this harness,
not a pass.

**SIX OF THE ARMS ARE §3.2's OWN KILLER COLUMN, APPLIED.** Every `LAW-S*` row
in Editor-Model-Conformance-Suite.md §3.2 names the mutation that must kill it,
and *"an arm with no stated killer is not admitted"*. The `law` field below
carries the row's wording verbatim beside the patch that performs it, so a
reader can check the arm against the published table rather than against this
file's own description of it. `ci/test/editor-model-case-floor.sh PLAT-26`
checks the other half — that the table still publishes six rows and six
killers.

WHY THIS IS A THIRD HARNESS RATHER THAN AN ARGUMENT TO THE SECOND
-----------------------------------------------------------------
The FLOOR GATE was renamed rather than copied when PLAT-25 needed it, because
it is one parser over one grammar and a second copy would be a second place for
the grammar to drift. A mutation harness is the other shape: its content is
almost entirely the arms, which are per-milestone by construction, and its
machinery is forty lines of byte-level file IO. PLAT-24 and PLAT-25 each carry
their own for that reason and this follows the precedent. What IS shared, and
deliberately identical, is the four-verdict vocabulary, the §32f byte IO, the
signal-restoring handler and the §10.3 count rule — copied with their reasons
attached so a reader of this file does not have to find the other two.

WHY IT REACHES THE SUITE AND THE GENERATOR
------------------------------------------
FOURTEEN of the twenty-four arms mutate the HARNESS rather than the product,
and that is deliberate. This campaign's recurring defect is a gate that cannot
fail: a generator that produced nothing, a population assertion over an empty
set, a scanner whose sweep found nothing, a CONTROL that had become a second
call to the rule. Those are properties of the harness, so the only way to show
they are armed is to break the harness and require it to notice:

  G1  the shared position budget collapses to one point
  G2  the classifier stops discriminating, so the histogram is the generator
      agreeing with itself (§34's third rule)
  G3  every law cell draws nothing, and every law over it is vacuous
  G4  the totality sweep compares one class instead of eight
  G5  the fuzz stream stops after one step
  G6  the source scan matches nothing
  G7  the directory enumeration matches nothing (§35)
  G8  the totality control's arithmetic stops moving anything
  G9  a pinned measurement is edited to claim its own opposite
  G10 the shrinker returns its input
  G11 THE GENERATOR STOPS PRODUCING OVERLAPPING SETS — the selection analogue
      of §4.1's disjoint pairs, and the arm that decides whether the
      normalisation laws are evidence
  G12 the "an arm reading only the primary CAN kill" gate stops discriminating
  G13 the invariant predicate stops refusing a touching pair, which is the
      SECOND MECHANISM that would disarm `M1` (§32a)
  G14 THE CONTROL BECOMES A SECOND CALL TO THE RULE (§30). It is the one arm
      whose kill NOTHING about the product could have established: all
      forty-eight totality rows stay green under it, so an arm on
      `changeByRange` would survive rather than kill, and what notices is the
      source scan over this file's subject's own `totalityControl` body

FOUR VERDICTS, NOT TWO (Verification-Harness-Traps.md §1). An arm that never
ran is not a kill:

  killed           the named case reported [FAILED]
  SURVIVED         the run produced result lines and the named case was [OK]
  MISDIRECTED      something else went red and the named case did not
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all
  HUNG             no result inside the timeout — its own outcome, not a pass

RESTORATION IS FROM A VERIFIED SNAPSHOT, never from `git checkout --`: the
original bytes are read into memory before the mutation and written back after,
and the SHA-256 of every touched file is compared against the control digest
before the next arm starts. §32i is the reason the alternative is not
available at all here — `git checkout -- <path>` on a file that was only
`git add -N`'d restores the EMPTY index blob and truncates it, which is how a
recovery becomes a data loss. **Every read and every write is bytes** (§32f).

THE NEEDLE SCAN (§32). An arm whose `find` text a later repair moved is
silently unkillable: it reports HARNESS-FAILURE only when it is RUN, and
nothing runs it if the suite is green. `--needle-scan` checks every arm's
needle occurs exactly once WITHOUT compiling anything, in about a second, and
must be run BEFORE the control digests are re-recorded.

Usage (from the repository root):
  python3 src/frontend/viewmodel/tests/unit/run-plat26-selection-mutations.py
  python3 .../run-plat26-selection-mutations.py --needle-scan
  python3 .../run-plat26-selection-mutations.py --enumerate-touched
  python3 .../run-plat26-selection-mutations.py --record-control-hashes
  python3 .../run-plat26-selection-mutations.py --only=M1,G11
"""

from __future__ import annotations

import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]            # .../codetracer

# -- subjects ---------------------------------------------------------------
SELECTION = "src/frontend/viewmodel/editor/selection.nim"
OPS = "src/frontend/viewmodel/editor/selection_ops.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/selection_generator.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_selection_laws.nim"
EX = "src/frontend/viewmodel/tests/unit/test_editor_selection_examples.nim"

TOUCHED = [SELECTION, OPS, GENERATOR, LAWS, EX]

CONTROL_HASHES = HERE / "plat26-selection-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P26_SUITE_TIMEOUT", "900"))
LAWS_BIN = os.environ.get("CT_P26_LAWS_BIN", "/tmp/plat26-mutation-laws")
EX_BIN = os.environ.get("CT_P26_EX_BIN", "/tmp/plat26-mutation-examples")

# BOTH SUITES RUN FOR EVERY ARM, and that is deliberate rather than thorough.
# They share `selection.nim`, so an arm on `mapRange` can redden either;
# running only the suite an arm "belongs to" would be the harness deciding in
# advance which case is allowed to notice, which is the MISDIRECTED verdict's
# whole point made unavailable.
SUITES = [(LAWS, LAWS_BIN), (EX, EX_BIN)]

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# Five families of name are COMPOSED at run time and the scan checks the halves
# rather than searching for the whole string:
#   `<LAW-Sn> x K=<k>`                    from `LawName[law] & " x K=" & $k`
#   `totality: <op> x K=<k>`              from `"totality: " & $op & " x K=" & $k`
#   `normalisation: <cls> / primary <n>`  from the violation sweep
#   `range mapping: <mp> / <side> / ...`  from the boundary sweep
#   `FUZZ-3 x corpus class <n>`           from the fuzz sweep
# ---------------------------------------------------------------------------

L_S1_K7 = "LAW-S1 x K=7"
L_S2_K7 = "LAW-S2 x K=7"
L_S4_K7 = "LAW-S4 x K=7"
L_S5_K2 = "LAW-S5 x K=2"

T_INSERT_K7 = "totality: opInsertText x K=7"
T_DELETE_K7 = "totality: opDeleteRange x K=7"
T_SELLINE_K3 = "totality: opSelectLine x K=3"

N_TOUCH_0 = "normalisation: selTouching / primary 0"
F_CLASS1 = "FUZZ-3 x corpus class 1"
GOAL_CLASS1 = "goal column x corpus class 1"

C_HIST = "the seed, the K values and the realised histogram are printed and asserted"
C_REALISED = "every drawn set realises the class it was drawn for, at every K > 1"
C_CLUSTER = ("every motion lands on a cluster boundary, over all eighteen "
             "corpus documents")
C_DISCRIM = ("A MUTATION ARM THAT READS ONLY THE PRIMARY RANGE can kill, "
             "per operation")
C_SCAN1 = ("the primary index is read in exactly one place, and it is not "
           "an operation")
C_SCAN2 = "the scan's subject list is the directory, not a list somebody maintains"
C_CONTROL = ("the totality control is a SECOND DERIVATION, not a second call "
             "to the rule")
C_FALSIFY = ("the invariant predicate is FALSIFIABLE, and refuses each "
             "violation by name")
C_SHRINK = "a planted always-failing property shrinks to its known counterexample"

X_MORE = "mapping a selection never produces MORE ranges — the two-edit case"
X_ORACLE = "`columnAt` at a line's end agrees with the corpus manifest's own walk"
X_DUP = "duplicates collapse and the direction of the last one wins"
X_DIR = "DIRECTION IS A FIELD, because extend-style motions need it"
X_ROUND = ("the round trip is exact in COLUMN space and not in OFFSET space, "
           "measured")

NAMED_CASES = [
    L_S1_K7, L_S2_K7, L_S4_K7, L_S5_K2,
    T_INSERT_K7, T_DELETE_K7, T_SELLINE_K3,
    N_TOUCH_0, F_CLASS1, GOAL_CLASS1,
    C_HIST, C_REALISED, C_CLUSTER, C_DISCRIM, C_SCAN1, C_SCAN2, C_CONTROL,
    C_FALSIFY, C_SHRINK,
    X_MORE, X_ORACLE, X_DUP, X_DIR, X_ROUND,
]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    law: str = ""       # §3.2's own killer wording, where the arm performs one
    law_id: str = ""    # which LAW-S* it performs, stated rather than parsed


ARMS = [
    # =======================================================================
    # THE SIX LAW KILLERS, §3.2's column applied
    # =======================================================================
    Arm(
        "M1", SELECTION,
        "    if merged.len > 0 and r.rangeFrom <= merged[^1].rangeTo:\n",
        "    if merged.len > 0 and r.rangeFrom < merged[^1].rangeTo:\n",
        L_S1_K7,
        "THE MERGE STEP FOR TOUCHING RANGES, DROPPED — and the arm the whole "
        "touching-merge decision was taken for. Under CodeMirror's rule this "
        "mutation is NOT OBSERVABLE, because `[0,3)` and `[3,6)` do not "
        "overlap and an invariant forbidding only overlap is satisfied by the "
        "mutated output. Strict separation is the weakest invariant under "
        "which it lands",
        law="drop the merge step for *touching* ranges",
        law_id="LAW-S1",
    ),
    Arm(
        "M2", SELECTION,
        "  EditorSelection(ranges: merged, primary: mainIndex)\n",
        "  EditorSelection(ranges: merged, primary: 0)\n",
        L_S2_K7,
        "the primary index is reset to 0 rather than carried onto the range "
        "that absorbed it. Every OTHER property of the selection is "
        "unchanged — the ranges, their order, their extents — which is why "
        "LAW-S2 is a separate law rather than a clause of LAW-S1",
        law="reset the primary index to 0",
        law_id="LAW-S2",
    ),
    Arm(
        "M3", OPS,
        "    raise newException(SelectionError, \"changeByRange: an empty selection\")\n"
        "  let first = f(sel[0])\n",
        "    raise newException(SelectionError, \"changeByRange: an empty selection\")\n"
        "  if sel.rangeCount > 0:\n"
        "    let only = f(sel[sel.primaryIndex])\n"
        "    return transaction(changeSet(doc.len, only.edits),\n"
        "                       some(editorSelection([only.range], 0)), only.effects)\n"
        "  let first = f(sel[0])\n",
        T_INSERT_K7,
        "**THE MILESTONE'S ONLY INTERESTING FAILURE MODE, PERFORMED.** The "
        "operation reads `s.ranges[s.primary]` and nothing else, which is "
        "precisely what a type that permits many ranges while every operation "
        "reads the first one would do. Every K = 1 row still passes — which "
        "is what makes the K > 1 rows evidence rather than decoration",
        law="make one operation read `s.ranges[s.primary]`",
        law_id="LAW-S3",
    ),
    Arm(
        "M4", SELECTION,
        "    let hi = cs.mapPosOr(r.hi, sideBefore)\n",
        "    let hi = cs.mapPosOr(r.hi, sideAfter)\n",
        L_S4_K7,
        "both ends of a range are mapped with the same bias, so an insert "
        "exactly at the range's end is swallowed into the selection. The "
        "same mutation on `efRevealRange` is PLAT-25's `T2`, which is the "
        "point: one rule, and this milestone is where it acquires a law",
        law="map both ends with the same bias",
        law_id="LAW-S4",
    ),
    Arm(
        "M5", OPS,
        "               range: caret(landed, assocBefore, none(BidiLevel), some(goal)))\n",
        "               range: caret(landed, assocBefore, none(BidiLevel),\n"
        "                            some(columnAt(text, landed - ctx.lineStart(target),\n"
        "                                          ctx.policy))))\n",
        L_S5_K2,
        "THE GOAL IS RECOMPUTED FROM THE LANDED COLUMN. On a ladder of "
        "alternating long and short lines the column collapses to the short "
        "line's width on the first step down and never comes back — which is "
        "the exact behaviour the field exists to prevent, and which nothing "
        "but a multi-step vertical motion can see",
        law="recompute the goal from the landed column",
        law_id="LAW-S5",
    ),
    Arm(
        "M6", SELECTION,
        "  for r in s.ranges: xs.add mapRange(r, cs)\n",
        "  for r in s.ranges:\n"
        "    var pieces = 0\n"
        "    for ch in cs.changedRanges(individual = true):\n"
        "      if ch.fromA >= r.rangeFrom and ch.toA <= r.rangeTo: inc pieces\n"
        "    if pieces >= 2:\n"
        "      for ch in cs.changedRanges(individual = true):\n"
        "        if ch.fromA >= r.rangeFrom and ch.toA <= r.rangeTo:\n"
        "          xs.add mapRange(spanRange(ch.fromA, ch.toA), cs)\n"
        "    else:\n"
        "      xs.add mapRange(r, cs)\n",
        X_MORE,
        "ONE MAPPED RANGE PER TOUCHED CHANGE SECTION, so a range spanning two "
        "edits comes back as two. The mapped set is still ordered and still "
        "separated — it is only the COUNT that rose, which is why LAW-S6 is "
        "stated as count-or-merge rather than as 'the result is normalised'",
        law="emit one mapped range per *touched change section*, so a range "
            "spanning two edits comes back as two",
        law_id="LAW-S6",
    ),

    # =======================================================================
    # FOUR MORE ON THE PRODUCT — properties no LAW-S* row names
    # =======================================================================
    Arm(
        "M7", SELECTION,
        "      col = ((col div policy.tabSize) + 1) * policy.tabSize\n",
        "      col = col + policy.tabSize\n",
        X_ORACLE,
        "A TAB ADVANCES BY THE TAB SIZE INSTEAD OF TO THE NEXT TAB STOP. The "
        "two agree whenever the column is already a multiple of the tab size, "
        "which is why the killer is the CORPUS-WIDE oracle against PLAT-24's "
        "independent `expandTabs` walk and not a hand-written example",
    ),
    Arm(
        "M8", SELECTION,
        "  elif next.anchor > next.head:\n",
        "  elif prev.anchor > prev.head:\n",
        X_DUP,
        "a merge takes its direction from the range already in the result "
        "rather than from the incoming one. The reference's rule is the "
        "incoming one — the range a user just extended is the one whose "
        "direction should survive — and the merged extents are identical "
        "either way, so only a case that reads `inverted` can see it",
    ),
    Arm(
        "M9", SELECTION,
        "    SelectionRange(kind: srNonEmpty, lo: head, hi: anchor, inverted: true,\n",
        "    SelectionRange(kind: srNonEmpty, lo: head, hi: anchor, inverted: false,\n",
        X_DIR,
        "DIRECTION STOPS BEING RECORDED. A leftward selection becomes "
        "indistinguishable from a rightward one, so `extend-left` grows both "
        "or shrinks both — the defect the `inverted` field exists to prevent, "
        "and the reason it is a field rather than a convention",
    ),
    Arm(
        "M10", OPS,
        "  ctx.boundaryAtOrBefore(ctx.store.offsetOf(textPos(line, ctx.store.lineLen(line))))\n",
        "  ctx.store.offsetOf(textPos(line, ctx.store.lineLen(line)))\n",
        C_CLUSTER,
        "THE CRLF CLAMP, REMOVED — the defect this milestone's corpus sweep "
        "actually found. `TextStore` is `\\n`-delimited and UAX #29 keeps CR "
        "LF together, so the unclamped line end is the offset INSIDE the "
        "cluster. It reddens only on the corpus's line-terminator class, "
        "which is why the sweep runs over all eighteen documents rather than "
        "over a hand-written one",
    ),

    # =======================================================================
    # THIRTEEN ON THE HARNESS — the gates that must be able to fail
    # =======================================================================
    Arm(
        "G1", GENERATOR,
        "  for i in 0 ..< want: result.add bs[at + i]\n",
        "  for i in 0 ..< want: result.add bs[at]\n",
        C_HIST,
        "THE SHARED POSITION BUDGET COLLAPSES TO ONE POINT. Every class "
        "constructor then builds degenerate ranges out of one offset, and the "
        "histogram is the only thing that can see it — every law still passes, "
        "and passes harder",
    ),
    Arm(
        "G2", GENERATOR,
        "proc classifySelection*(rs: seq[SelectionRange]): SelClass =\n",
        "proc classifySelection*(rs: seq[SelectionRange]): SelClass =\n"
        "  if true: return selDisjoint\n",
        C_REALISED,
        "THE CLASSIFIER STOPS DISCRIMINATING. §34's third rule: if the "
        "histogram is built from the label the generator applied to its own "
        "output, the whole check is the generator agreeing with itself and "
        "the two-independent-draws defect is invisible in principle",
    ),
    Arm(
        "G3", LAWS,
        "  for iter in 0 ..< DrawsPerCell:\n",
        "  for iter in 0 ..< DrawsPerCell - DrawsPerCell:\n",
        L_S1_K7,
        "EVERY LAW CELL DRAWS NOTHING. All twenty-four of them are then "
        "vacuously satisfied (§4). The `o.draws == DrawsPerCell` floor under "
        "each cell is the only thing that can notice",
    ),
    Arm(
        "G4", LAWS,
        "        for cls in SelClass:\n"
        "          let d = docs[r.rand(docs.len - 1)]\n"
        "          let draw = genSelDraw(d, r, cls, k)\n"
        "          let sel = editorSelection(draw.ranges, draw.primary)\n"
        "          let ctx = initOpCtx(draw.doc)\n",
        "        for cls in [selDisjoint]:\n"
        "          let d = docs[r.rand(docs.len - 1)]\n"
        "          let draw = genSelDraw(d, r, cls, k)\n"
        "          let sel = editorSelection(draw.ranges, draw.primary)\n"
        "          let ctx = initOpCtx(draw.doc)\n",
        T_SELLINE_K3,
        "THE TOTALITY SWEEP COMPARES ONE CLASS INSTEAD OF EIGHT, and the one "
        "it keeps is the class with nothing to merge. The `compared == "
        "SelClassCount` floor under each cell is what notices; without it a "
        "sweep that had quietly become a sweep over the easy shape would read "
        "as forty-eight green rows",
    ),
    Arm(
        "G5", LAWS,
        "    for step in 1 .. stepsPerRound:\n",
        "    for step in 1 .. stepsPerRound - stepsPerRound + 1:\n",
        F_CLASS1,
        "THE FUZZ STREAM STOPS AFTER ONE STEP. `FUZZ-3`'s whole claim is that "
        "the selection is normalised after EVERY step of a stream; a one-step "
        "stream satisfies it and demonstrates nothing about a selection that "
        "has been mapped through its own edits a dozen times",
    ),
    Arm(
        "G6", LAWS,
        "    if t.startsWith(\"#\"): continue\n",
        "    if t.startsWith(\"\"): continue\n",
        C_SCAN1,
        "THE SOURCE SCAN MATCHES NOTHING. §4's canonical shape: a scanner "
        "that finds nothing satisfies every 'must be exactly this' written "
        "over it, including 'the primary index is read in exactly one place'",
    ),
    Arm(
        "G7", LAWS,
        "      if kind == pcFile and path.endsWith(\".nim\"):\n",
        "      if kind == pcFile and path.endsWith(\".nimrod\"):\n",
        C_SCAN2,
        "THE DIRECTORY ENUMERATION MATCHES NOTHING — §35's own stated arm, "
        "*'the arm is one character in the extension it filters on'*. A "
        "lister that matches nothing satisfies 'these two files are in the "
        "directory' by leaving nothing to disagree with it",
    ),
    Arm(
        "G8", LAWS,
        "    for e in outs[i].edits: delta += e.insert.len - (e.toPos - e.fromPos)\n",
        "    for e in outs[i].edits: delta += 0\n",
        T_DELETE_K7,
        "THE TOTALITY CONTROL'S ARITHMETIC STOPS MOVING ANYTHING. The control "
        "is the half of LAW-S3 that is not the implementation, and a control "
        "that computes a constant is a control that agrees with nothing. It "
        "reddens only for the two operations that EDIT, which is why both of "
        "them have their own named cell",
    ),
    Arm(
        "G9", EX,
        "    counted offsetRoundTripped + zeroWidthShifts + illFormedTails == boundaries\n",
        "    counted offsetRoundTripped == boundaries\n",
        X_ROUND,
        "A PINNED MEASUREMENT IS EDITED TO CLAIM ITS OWN OPPOSITE: that the "
        "offset-space round trip is exact. It is not — 6,669 of 165,244 "
        "corpus boundaries are displaced — and a recorded finding that no "
        "case can contradict is a paragraph rather than a measurement",
    ),
    Arm(
        "G10", GENERATOR,
        "  result = d\n  var progress = true\n",
        "  result = d\n  var progress = false\n",
        C_SHRINK,
        "THE SHRINKER RETURNS ITS INPUT. §4.5 requires shrinking and says its "
        "absence is a REPORTED DEFECT; a shrinker nobody has watched shrink "
        "is the same thing with a green tick beside it",
    ),
    Arm(
        "G11", GENERATOR,
        "    for i in 0 ..< k: rs.add spanRange(p[i], p[i + 2])\n",
        "    for i in 0 ..< k: rs.add spanRange(p[2 * i], p[2 * i + 1])\n",
        C_HIST,
        "**THE GENERATOR STOPS PRODUCING OVERLAPPING SETS** and produces "
        "disjoint ones instead — the selection analogue of §4.1's *'two "
        "independent draws are overwhelmingly disjoint and the law is "
        "trivially true on disjoint pairs'*. A selection generator that never "
        "overlaps makes normalisation trivially true, and the per-class "
        "EQUALITY is the only thing that can see it: every law stays green",
    ),
    Arm(
        "G12", LAWS,
        "  applyOp(ctx, op, editorSelection([sel.mainRange], 0))\n",
        "  applyOp(ctx, op, sel)\n",
        C_DISCRIM,
        "THE 'AN ARM READING ONLY THE PRIMARY CAN KILL' GATE STOPS "
        "DISCRIMINATING. That case is what makes `M3` a kill rather than a "
        "hope: it asserts, per operation, that the population CONTAINS a "
        "selection on which primary-only and all-ranges disagree. With the "
        "two made equal it finds none, and says so",
    ),
    Arm(
        "G13", SELECTION,
        "    if i > 0 and r.rangeFrom <= rs[i - 1].rangeTo:\n",
        "    if i > 0 and r.rangeFrom < rs[i - 1].rangeTo:\n",
        C_FALSIFY,
        "§32a: A SECOND MECHANISM DISARMS AN ARM EXACTLY AS A MOVED NEEDLE "
        "DOES. `M1` drops the touching merge; what NOTICES is the invariant "
        "predicate refusing a touching pair. Weaken the predicate the same "
        "way and `M1` survives — so the predicate has its own arm, and the "
        "falsifiability case is what it lands on",
    ),
    Arm(
        "G14", LAWS,
        "  var outs: seq[RangeOutcome] = @[]\n"
        "  for r in sel: outs.add applyRangeOp(ctx, op, r)\n",
        "  if true: return applyOp(ctx, op, sel)\n"
        "  var outs: seq[RangeOutcome] = @[]\n"
        "  for r in sel: outs.add applyRangeOp(ctx, op, r)\n",
        C_CONTROL,
        "**THE CONTROL BECOMES A SECOND CALL TO THE RULE** — §30, performed. "
        "All forty-eight totality rows stay GREEN, which is the whole point: "
        "the defect is invisible to every law written over it, and an arm on "
        "`changeByRange` would then SURVIVE rather than kill. What notices is "
        "the source scan over this file's own `totalityControl` body, which is "
        "the one claim in the suite that no mutation of the product could "
        "establish",
    ),
]

DECLARED_SURVIVORS: list[Arm] = []

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


class RunResult:
    def __init__(self, rc: int = 0) -> None:
        self.rc = rc
        self.passed: list = []
        self.failed: list = []
        self.ran = True
        self.hung = False

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


# EVERY READ AND EVERY WRITE IS BYTES, AND THAT IS NOT STYLE (§32f).
#
# `Path.read_text()` opens in TEXT mode, which applies universal-newline
# translation: a `\r\n` in the file becomes a `\n` in the string, and
# `path.write_text(original)` then writes a DIFFERENT file back — in the
# RESTORE path, where nothing looks, and the digest check afterwards passes
# because the baseline came through the same lossy door. PLAT-24's harness was
# found doing exactly this when a Unicode corpus joined its subject set.
def read_source(path: str) -> str:
    return (ROOT / path).read_bytes().decode("utf-8", errors="surrogateescape")


def write_source(path: str, text: str) -> None:
    (ROOT / path).write_bytes(text.encode("utf-8", errors="surrogateescape"))


def run_one(path: str, binary: str, res: RunResult) -> None:
    try:
        proc = subprocess.run(
            ["nim", "c", "-r", "--hints:off", "-o:" + binary, path],
            cwd=ROOT, capture_output=True, text=True, timeout=SUITE_TIMEOUT,
            # `errors="replace"`: the corpus carries ill-formed bytes and a
            # mutated selection model can print them, and a UnicodeDecodeError
            # in the READER would abort the harness mid-arm with a file still
            # mutated on disk.
            encoding="utf-8", errors="replace",
        )
    except subprocess.TimeoutExpired:
        res.hung = True
        res.ran = False
        print(f"      ---- {path}: NO RESULT AFTER {SUITE_TIMEOUT}s ----")
        return
    out = proc.stdout + proc.stderr
    if proc.returncode != 0:
        res.rc = proc.returncode
    before = res.total
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == before:
        # PER SUITE, not per run. A mutation that stops ONE of the two suites
        # compiling while the other still prints its cases would otherwise
        # read as a clean survival.
        res.ran = False
        print(f"      ---- {path}: no result lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)


# THE SUBJECT UNDER MUTATION, AND THE WAY BACK FROM A SIGNAL (§32h).
# `write_source(arm.path, original)` sits in a `finally`, which covers an
# exception and does NOT cover a signal: the default SIGTERM handler terminates
# the interpreter without unwinding, so a harness killed between the mutate and
# the restore leaves its subject mutated.
_ACTIVE: tuple | None = None


def install_restore_on_signal() -> None:
    def handler(signum, _frame):
        if _ACTIVE is not None:
            path, original = _ACTIVE
            write_source(path, original)
            print(f"\nsignal {signum}: restored {path} before exiting")
        sys.exit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


def run_suite() -> RunResult:
    res = RunResult(rc=0)
    for path, binary in SUITES:
        run_one(path, binary, res)
    return res


COUNT_CONSTANT = re.compile(
    r"^\s*const\s+(ExpectedAssertions|ExpectedCases|ExpectedSpecRows|"
    r"ExpectedOperations|ExpectedNames)\s*=\s*(\d+)", re.M)
COUNT_NAMES = ("ExpectedAssertions", "ExpectedCases", "ExpectedSpecRows",
               "ExpectedOperations", "ExpectedNames", "CHECKS:")


def declared_counts() -> dict:
    """{value: "file:Name"} for every declared count constant in the subjects.

    Editor-Model-Conformance-Suite.md §10.3 applies
    Verification-Harness-Traps.md §32 to the one class of needle that is
    GUARANTEED to move: a count changes every time a test is added, which is
    the most frequent edit a suite receives.
    """
    found = {}
    for path in TOUCHED:
        try:
            text = read_source(path)
        except OSError:
            continue
        for m in COUNT_CONSTANT.finditer(text):
            found[m.group(2)] = f"{path}:{m.group(1)}"
    return found


def check_killer_names(problems: int) -> int:
    """Every killer names a case the suites actually instantiate.

    A case renamed in a suite makes its arm unkillable in exactly the same
    silent way a moved needle does. Five of this suite's name families are
    COMPOSED at run time, so a literal search would report every one of them
    missing — a scan that is wrong in the noisy direction. Each half is checked
    instead.
    """
    laws = read_source(LAWS)
    ex = read_source(EX)
    gen = read_source(GENERATOR)
    ops = read_source(OPS)
    both = laws + "\n" + ex

    templates = [
        ('test LawName[law] & " x K=" & $k:', laws, "THE LAW CELL TEMPLATE"),
        ('test "totality: " & $op & " x K=" & $k:', laws,
         "THE TOTALITY CELL TEMPLATE"),
        ('test "normalisation: " & $cls & " / primary " & $primary:', laws,
         "THE NORMALISATION CELL TEMPLATE"),
        ('test "FUZZ-3 x corpus class " & $clsIdx:', laws,
         "THE FUZZ CELL TEMPLATE"),
        ('test "goal column x corpus class " & $clsIdx:', laws,
         "THE GOAL-COLUMN CELL TEMPLATE"),
    ]
    for needle, text, label in templates:
        if needle not in text:
            print(f"{label} IS NOT IN THE SUITE")
            problems += 1

    for name in NAMED_CASES:
        if name.startswith("LAW-S") and " x K=" in name:
            law, _, k = name.partition(" x K=")
            if f'"{law}"' not in laws:
                print(f"KILLER LAW ID NOT DECLARED: {law!r}")
                problems += 1
            if f"KValues* = [" not in gen or k not in gen:
                print(f"KILLER K VALUE NOT DECLARED: {k!r}")
                problems += 1
        elif name.startswith("totality: "):
            op = name[len("totality: "):].split(" x K=")[0]
            if f"    {op}" not in ops:
                print(f"KILLER OPERATION NOT DECLARED: {op!r}")
                problems += 1
        elif name.startswith("normalisation: "):
            cls = name[len("normalisation: "):].split(" / ")[0]
            if f"    {cls}" not in gen:
                print(f"KILLER SELECTION CLASS NOT DECLARED: {cls!r}")
                problems += 1
        elif name.startswith(("FUZZ-3 x corpus class ", "goal column x corpus class ")):
            pass    # the class index is a literal range `1 .. 9` in the suite
        elif name not in both:
            print(f"KILLER NAME NOT IN EITHER SUITE: {name!r}")
            problems += 1

    for arm in ARMS:
        if arm.killer not in NAMED_CASES:
            print(f"{arm.id}: killer {arm.killer!r} is not a declared case name")
            problems += 1
    return problems


def needle_scan() -> int:
    """Every arm's needle occurs exactly once. No toolchain, about a second."""
    problems = 0

    # §10.3, FIRST, because an arm that quotes a count is unkillable in a way
    # the occurrence check cannot see: the needle is present today and gone on
    # the next commit that adds a test.
    counts = declared_counts()
    print(f"declared count constants in the subjects: "
          f"{', '.join(f'{v}={k}' for k, v in sorted(counts.items())) or 'none'}")
    if not counts:
        # A scan that found nothing satisfies every 'must not contain' written
        # over it (§4).
        print("REFUSING: no declared count constant was found in any subject, "
              "so §10.3's rule would pass vacuously")
        problems += 1
    for arm in ARMS + DECLARED_SURVIVORS:
        for name in COUNT_NAMES:
            if name in arm.find or name in arm.replace:
                print(f"{arm.id}: NEEDLE QUOTES A COUNT NAME ({name}) — §10.3")
                problems += 1
        for digits in re.findall(r"\d+", arm.find + arm.replace):
            if digits in counts:
                print(f"{arm.id}: NEEDLE QUOTES THE VALUE OF "
                      f"{counts[digits]} ({digits}) — §10.3")
                problems += 1

    # ALL SIX §3.2 KILLERS ARE PERFORMED, and the check is two-sided.
    #
    # `an arm with no stated killer is not admitted` is the rule about the
    # TABLE; this is the rule about the HARNESS. An arm carrying a `law` string
    # claims to perform one of §3.2's six killers, and the six it covers must
    # be all six — otherwise a law is executable, green, and has never been
    # watched fail.
    #
    # The law id is a FIELD rather than a slice of the killer case's name,
    # which is the one place this differs from PLAT-25's harness. `LAW-S6`'s
    # killer case is a pinned example rather than a law cell, because a
    # generated change set is not guaranteed to put two edits inside one range
    # and an arm whose kill depends on a draw is an arm that is sometimes a
    # SURVIVOR. Deriving the id from the case name would have forced the arm
    # onto a cell that cannot promise to notice.
    performed = set()
    for arm in ARMS:
        if not arm.law:
            continue
        if not arm.law_id.startswith("LAW-S"):
            print(f"{arm.id}: quotes a §3.2 killer but declares law_id "
                  f"{arm.law_id!r}")
            problems += 1
            continue
        performed.add(arm.law_id)
    expected = {f"LAW-S{i}" for i in range(1, 7)}
    if performed != expected:
        print(f"§3.2 KILLERS NOT PERFORMED BY ANY ARM: "
              f"{sorted(expected - performed)}")
        print(f"ARMS CLAIMING A LAW THAT IS NOT PUBLISHED: "
              f"{sorted(performed - expected)}")
        problems += 1
    else:
        print(f"all {len(expected)} of §3.2's killers are performed by an arm")

    for arm in ARMS + DECLARED_SURVIVORS:
        text = read_source(arm.path)
        n = text.count(arm.find)
        status = "ok" if n == 1 else "LOST" if n == 0 else "AMBIGUOUS"
        if n != 1:
            problems += 1
        print(f"{arm.id:<4} {status:<10} {n} occurrence(s) in {arm.path}")

    problems = check_killer_names(problems)
    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


def record_control_hashes() -> int:
    lines = [f"{digest(p)}  {p}" for p in TOUCHED]
    CONTROL_HASHES.write_text("\n".join(lines) + "\n")
    print(f"recorded {len(lines)} digests in {CONTROL_HASHES}")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print(f"NOTE: {CONTROL_HASHES.name} is absent — run "
              f"--record-control-hashes after reviewing the tree")
        return True
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip():
            continue
        h, p = line.split(None, 1)
        recorded[p.strip()] = h
    ok = True
    for p in TOUCHED:
        if p in recorded and recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  f"--record-control-hashes (§32)")
            ok = False
    return ok


def main() -> int:
    only = None
    for arg in sys.argv[1:]:
        if arg == "--needle-scan":
            return needle_scan()
        if arg == "--enumerate-touched":
            for p in TOUCHED:
                print(p)
            return 0
        if arg == "--record-control-hashes":
            return record_control_hashes()
        if arg.startswith("--only="):
            only = set(arg[len("--only="):].split(","))
        else:
            print(f"unknown argument: {arg}")
            return 2

    if needle_scan() != 0:
        print("REFUSING TO RUN: a needle is lost or ambiguous (§32)")
        return 1
    check_control_hashes()

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    print("\n== control ==")
    control = run_suite()
    if control.failed or not control.ran:
        print(f"CONTROL IS NOT GREEN: rc={control.rc} failed={control.failed}")
        return 1
    missing = [c for c in NAMED_CASES if c not in control.passed]
    if missing:
        print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES: {missing}")
        return 1
    print(f"control: {control.total} cases, all {len(NAMED_CASES)} named ones "
          f"ran, 0 failures\n")

    problems = 0
    for arm in ARMS + DECLARED_SURVIVORS:
        if only and arm.id not in only:
            continue
        original = read_source(arm.path)
        occurrences = original.count(arm.find)
        if occurrences != 1:
            print(f"{arm.id:<5} HARNESS-FAILURE      needle occurs "
                  f"{occurrences} times in {arm.path}, expected 1")
            problems += 1
            continue
        global _ACTIVE
        _ACTIVE = (arm.path, original)
        write_source(arm.path, original.replace(arm.find, arm.replace))
        try:
            res = run_suite()
        finally:
            write_source(arm.path, original)
            _ACTIVE = None
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<5} HARNESS-FAILURE      {p} did not "
                          f"restore to its control bytes")
                    return 2
        declared = arm in DECLARED_SURVIVORS
        if res.hung:
            verdict = "HUNG"
            note = f"no result in {SUITE_TIMEOUT}s — repair the arm, not the timeout"
            problems += 1
        elif not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {res.failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", arm.why[:70] + "..."
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif arm.killer in res.failed:
            others = [f for f in res.failed if f != arm.killer]
            verdict = "killed"
            note = arm.killer + (f"  (+{len(others)} more)" if others else "")
        else:
            verdict = "MISDIRECTED"
            note = f"died in {res.failed[:3]}, not {arm.killer!r}"
            problems += 1
        print(f"{arm.id:<5} {verdict:<20} {note}")

    print(f"\n{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
