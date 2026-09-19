#!/usr/bin/env python3
"""PLAT-30's arming — the mutation harness for the named operation vocabulary,
its population, its spec-as-oracle and the retirement of `applyEditKey`.

    python3 src/frontend/viewmodel/tests/unit/run-plat30-vocabulary-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --enumerate-touched
    python3 ... --only=M1,U2

WHAT THIS IS, AND WHY EVERY PART OF IT IS HERE
==============================================
PLAT-30 publishes no `LAW-*` row, so there is no column of killers to perform.
What it publishes instead is a 140-row oracle, a 224-member vocabulary and two
two-sided equalities — and the question an arm has to answer is the same one:
**which named case goes red when I make this change?**

Verification-Harness-Traps, applied rather than cited:

  * §36  — *"a published killing mutation is a claim about the ASSERTION, not
           only about the code."* This milestone's named shape is an arm that
           SWAPS TWO OPERATIONS' IMPLEMENTATIONS: the vocabulary still has 224
           members, every name is still published, both set differences are
           still empty, and the oracle cannot see it. `M1` performs exactly
           that, and the case that dies is a WITNESS case — `char-left` moving
           forward — which is why the sweep's witnesses are declared per
           declaration rather than being "something changed".
  * §32  — a needle lost under a later repair is silently unkillable, so
           `--needle-scan` refuses to run when any arm's needle is absent or
           ambiguous, and the full run refuses unless the scan is clean.
  * §32f — every read and every write is BYTES.
  * §32h — `finally` is not a signal handler.
  * §10.3 — no arm's needle may quote a count. The scan reads every declared
           count constant out of the subjects and REJECTS an arm whose needle
           contains one of their names or one of their values.
  * §4   — the control-digest guard's verdict is ACTED ON.

EIGHT SUBJECTS, AND FOUR OF THEM ARE THE HARNESS'S OWN EVIDENCE
---------------------------------------------------------------
The product is four modules — the vocabulary, the state it is pure over, the
binding table that replaced `applyEditKey`'s `case`, and the dispatch that reads
it. The population is a generator. The suites are three. A suite that cannot fail is this campaign's
recurring defect, so the population and the suites are armed like anything
else: `G*` performs a defect the population actually had, and `U*` empties a
guard the suite rests on.

THE THIRD SUITE NEEDS THE `tui` LANE'S LINK FLAGS, AND THEY ARE READ RATHER
THAN COPIED. `test_edit_binding_vocabulary.nim` links `isonim_tui`, which needs
the tree-sitter archive and two `-L` flags this repository's dev shell puts on
neither the linker's path nor `LD_LIBRARY_PATH`. `ci/lib/test-lane-files.sh`
already answers that question for the lane; this sources it rather than
spelling the flags, so a second place for them to drift is not created. If the
sourcing fails the harness says so and refuses, because a third suite silently
dropped from the run would take `M14` — the only arm on the DISPATCH — with it.

COUNT THE ARMS BY THEIR `subject`, NOT BY THEIR NAME. `G2`'s subject is the
generator and `U1`'s is a suite; the letters say which, and the table in
PLAT-30's status records the split.

ALL SUITES RUN FOR EVERY ARM. They share the product modules, so an arm on
`operations.nim` can redden any of them; running only "the suite an arm belongs
to" would be the harness deciding in advance which case is allowed to notice,
which is the MISDIRECTED verdict made unavailable.
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
OPS = "src/frontend/viewmodel/editor/operations.nim"
STATE = "src/frontend/viewmodel/editor/editor_state.nim"
BINDINGS = "src/common/editing_key_bindings.nim"
DISPATCH = "src/frontend/tui/app/edit_binding.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/vocabulary_generator.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_vocabulary_laws.nim"
ORACLE = "src/frontend/viewmodel/tests/unit/test_editor_vocabulary_oracle.nim"
TUI = "src/frontend/tui/app/tests/test_edit_binding_vocabulary.nim"

TOUCHED = [OPS, STATE, BINDINGS, DISPATCH, GENERATOR, LAWS, ORACLE, TUI]

CONTROL_HASHES = HERE / "plat30-vocabulary-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P30_SUITE_TIMEOUT", "2400"))
VM_FLAGS = ["--hints:off", "--warnings:off", "--path:src/frontend/viewmodel"]

RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*(.*?)\s*(?:\x1b\[[0-9;]*m)*$")


def tui_lane_flags() -> list:
    """The `tui` lane's extra flags, READ from the lane library.

    Not copied: `ci/lib/test-lane-files.sh` resolves the tree-sitter runtime by
    four routes and records the answer, and a second spelling here would be a
    second thing to be wrong about a store path.
    """
    proc = subprocess.run(
        ["bash", "-c",
         "source ci/lib/test-lane-files.sh && test_lane_extra_flags tui"],
        cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        return []
    return proc.stdout.strip().split()


# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# Six families are COMPOSED at run time and the scan checks the TEMPLATE rather
# than searching for the whole string.
# ---------------------------------------------------------------------------

OP_CHAR_LEFT = "operation: move-char-left"
OP_EXTEND_CHAR_RIGHT = "operation: extend-char-right"
OP_DELETE_BACK = "operation: delete-char-backward"
OP_AROUND_PARENS = "operation: select-around-parens"
OP_DELETE_TO_LINE_START = "operation: delete-to-line-start"
OP_LINE_START_SMART = "operation: move-line-start-smart"
DISP_LINE_START = "display: move-line-start"
DISP_LINE_UP = "display: move-line-up"
DISP_ROW_START = "display: move-display-line-start"
FUZZ3 = "FUZZ-8 x corpus class 3"
MARKS_MOVE = ("A MARK AND THE JUMP LIST MOVE WITH THE DOCUMENT, through the "
              "same change set")
ORACLE_L3 = "§7.1 line 3 — names(T) - names(I) == {}"
ORACLE_L4 = "§7.1 line 4 — names(I) - names(T) == {}"
ORACLE_DD_L3 = "§7.1 line 3 — dependent(T) - dependent(I) == {}"
ORACLE_PARSE = "the published section was found and parsed, category by category"
REFUSAL_ARM = "the refusal arm exists and is reached, two-sidedly"
POPULATION = "the scenario table is one row per declaration, in the vocabulary's order"
CARDINALITY = "the vocabulary's own cardinalities, asserted before anything is swept"
BEHAVIOUR_DELETE = "behaviour: delete-cluster-before"
BINDING_TABLE = "the binding table answers the three questions a `case` could not"
WIDGET_LEFT = "behaviour through the widget: move-caret-left"
WIDGET_HOME = "behaviour through the widget: move-caret-line-start"
OP_ENTER_VISUAL = "operation: enter-visual"

NAMED_CASES = [
    OP_CHAR_LEFT, OP_EXTEND_CHAR_RIGHT, OP_DELETE_BACK, OP_AROUND_PARENS,
    OP_DELETE_TO_LINE_START, OP_LINE_START_SMART,
    DISP_LINE_START, DISP_LINE_UP, DISP_ROW_START, FUZZ3,
    MARKS_MOVE,
    ORACLE_L3, ORACLE_L4, ORACLE_DD_L3, ORACLE_PARSE, REFUSAL_ARM,
    POPULATION, CARDINALITY, BEHAVIOUR_DELETE, BINDING_TABLE, WIDGET_LEFT,
    WIDGET_HOME, OP_ENTER_VISUAL,
]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


ARMS = [
    # =======================================================================
    # THE PRODUCT
    # =======================================================================
    Arm(
        "M1", OPS,
        '    motionDecl("char-left", false, mCharLeft),\n'
        '    motionDecl("char-right", false, mCharRight),\n',
        '    motionDecl("char-left", false, mCharRight),\n'
        '    motionDecl("char-right", false, mCharLeft),\n',
        OP_CHAR_LEFT,
        "TWO OPERATIONS' IMPLEMENTATIONS ARE SWAPPED — this milestone's §36 "
        "shape, and the one a 224-member vocabulary makes most likely. Note "
        "what does NOT move: the vocabulary still holds 224 members, every "
        "published name still has an implementation, both set differences are "
        "still empty and the cardinality assertion still passes. The oracle is "
        "structurally incapable of seeing it. What sees it is the sweep's "
        "per-declaration WITNESS — `char-left` is declared `ckMovedBack` — "
        "which is the whole argument for declaring one per row instead of "
        "asserting that something changed",
    ),
    Arm(
        "M2", OPS,
        "proc mLineStart(env: OpEnv; st: EditorState; r: SelectionRange;\n"
        "                args: OpArgs): MotionLanding =\n"
        "  landing(env.lineStartOf(env.lineOf(r.head)))\n",
        "proc mLineStart(env: OpEnv; st: EditorState; r: SelectionRange;\n"
        "                args: OpArgs): MotionLanding =\n"
        "  landing(env.lineStartOf(env.lineOf(r.head)),\n"
        "          some(env.display.cache.toDisplay(env.ctx.store.posOf(r.head)).column))\n",
        DISP_LINE_START,
        "A DISPLAY-INDEPENDENT MOTION READS THE WRAP COLUMN. This is the arm "
        "that makes the display sweep's 200 NEGATIVE controls falsifiable, and "
        "it is the reason `operations.nim` gives every handler access to "
        "`env.settings` instead of separating the two by type: under the "
        "separated design this mutation would not compile, the 200 would be "
        "true by construction, and §7b's *'an unfalsified negative control is "
        "a self-comparison wearing a negation'* would apply to the largest "
        "single term in the campaign's floor.\n\n"
        "        **IT LANDS IN THE SAME PLACE AND CARRIES A DIFFERENT GOAL "
        "COLUMN, WHICH IS THE WHOLE POINT.** A first spelling made the motion "
        "go to the DISPLAY ROW's start, and that reddened the three `line-"
        "start` cases of the FIRST sweep too — which demonstrates that the "
        "mutation is wrong but not that the second sweep is independent of the "
        "first. In this form the head is still at the line's first offset at "
        "the swept column, so every witness the operation sweep asserts stays "
        "green and ONLY the display sweep notices. That is what §10.4's "
        "second rule asks for, performed rather than argued",
    ),
    Arm(
        "M3", OPS,
        "  let goal = if r.goalColumn.isSome: r.goalColumn.get else: here.column\n"
        "  let line = env.lineOf(r.head)\n",
        "  let goal = if r.goalColumn.isSome: r.goalColumn.get else: 0\n"
        "  let line = env.lineOf(r.head)\n",
        DISP_LINE_UP,
        "A DISPLAY-DEPENDENT MOTION STOPS READING THE WRAP COLUMN. The "
        "positive half of §2.3's equality, armed. `line-up` still steps one "
        "logical line — so its OPERATION case stays green and only the "
        "DISPLAY case dies, which is the two sweeps asking two questions "
        "rather than one question twice",
    ),
    Arm(
        "M4", OPS,
        "    for id, pos in st.marks:\n"
        "      if pos >= 0 and pos <= st.doc.len:\n"
        "        result.marks[id] = cs.mapPosOr(pos, sideAfter)\n"
        "    for i in 0 ..< result.jumps.len:\n"
        "      let pos = st.jumps[i]\n"
        "      if pos >= 0 and pos <= st.doc.len:\n"
        "        result.jumps[i] = cs.mapPosOr(pos, sideAfter)\n",
        "    discard\n",
        MARKS_MOVE,
        "A STORED OFFSET STOPS MOVING WITH THE DOCUMENT: the marks and the "
        "jump list are no longer mapped through the change set that moved the "
        "text under them. Nothing in either 224-case sweep can see it — both "
        "run ONE operation against a fresh state — and this needs an edit "
        "BETWEEN a mark being set and it being jumped to, which is what a "
        "random stream produces and a scenario does not.\n\n"
        "**THIS ARM'S SUBJECT MOVED ON 2026-09-19 AND THE NEEDLE MOVED WITH "
        "IT** (§32, caught by `--needle-scan` reporting LOST before any digest "
        "was re-recorded). It used to delete `commitChange`'s two "
        "`selUndo` / `selRedo` mapping loops — *the* defect this milestone "
        "actually shipped, `undo-selection` handing back `[96,182)` in a "
        "114-byte document. **Those loops no longer exist.** PLAT-32 replaced "
        "the four flat snapshot stacks with an event history in which every "
        "stored selection is anchored to its event, so a local edit cannot "
        "put one in the wrong coordinates and there is nothing to drag "
        "forward. The CLASS is still armed, twice, and in the milestone that "
        "owns it: `run-plat32-history-mutations.py`'s `M9` and `M11` perform "
        "exactly this defect on the one path that can still reach it — a "
        "REMOTE change, which moves the document without adding an event. "
        "What is re-aimed here is this arm, onto the offsets that are STILL "
        "dragged forward by this function: the marks and the jump list, which "
        "are PLAT-31's own §36a repair",
    ),
    Arm(
        "M5", OPS,
        "    of ofExtend: spanRange(r.anchor, got.offset, got.goal)\n",
        "    of ofExtend: caret(got.offset, assocBefore, none(BidiLevel), got.goal)\n",
        OP_EXTEND_CHAR_RIGHT,
        "THE `extend-` FORM COLLAPSES LIKE `move-`. Three forms generated from "
        "one declaration is a deliverable, and *'so the three cannot "
        "disagree'* is only a property if something notices when they do. The "
        "per-form structural assertion is what notices — and note that the "
        "LANDING is unchanged, so every witness about where the head went "
        "stays green",
    ),
    Arm(
        "M6", OPS,
        "    (ctx.prevBoundary(r.pos), r.pos)))\n",
        "    (max(r.pos - 1, 0), r.pos)))\n",
        OP_DELETE_BACK,
        "ONE BACKSPACE REMOVES ONE BYTE INSTEAD OF ONE GRAPHEME CLUSTER — the "
        "half-deleted emoji §5 of the conformance suite exists to stop, at the "
        "operation the spec names as most likely to regress silently. The "
        "witness is `ckClusterMinusOne`, measured with the segmenter rather "
        "than with the operation's own boundary table",
    ),
    Arm(
        "M7", OPS,
        '    commandDecl("toggle-fold", cToggleFold),\n',
        "",
        ORACLE_L3,
        "A PUBLISHED DECLARATION VANISHES FROM THE IMPLEMENTATION. The first "
        "direction of §7.1, armed: something in the table has no "
        "implementation. It is the direction a suite written from the "
        "implementation never checks",
    ),
    Arm(
        "M8", OPS,
        '    objectDecl("quote-back", oQuoteBack),\n',
        '    objectDecl("quote-backtick", oQuoteBack),\n',
        ORACLE_L4,
        "AN IMPLEMENTED NAME IS NOT PUBLISHED. The second direction, and the "
        "one a spec-first reader assumes cannot happen. Both are needed "
        "because either alone is satisfied by a rename that moved a name from "
        "one side to the other",
    ),
    Arm(
        "M9", OPS,
        '    motionDecl("page-up", true, mPageUp),\n',
        '    motionDecl("page-up", false, mPageUp),\n',
        ORACLE_DD_L3,
        "A DECLARED DISPLAY-DEPENDENCE FLAG IS FLIPPED. §2.3's property is "
        "DECLARED, so the declaration is a thing that can be wrong — and the "
        "oracle compares it against the published `Display-dependent` column "
        "in both directions, which is the second of §7.2's two tables for this "
        "milestone",
    ),
    Arm(
        "M10", OPS,
        "  let (a, b) = enclosingPair(env.ctx.doc, r.head, open, close)\n"
        "  if a < 0: return objRefused(r, rrNoEnclosingObject)\n"
        "  if around: objSpan(a, b + 1) else: objSpan(a + 1, b)\n",
        "  let (a, b) = enclosingPair(env.ctx.doc, r.head, open, close)\n"
        "  if a < 0: return objRefused(r, rrNoEnclosingObject)\n"
        "  objSpan(a + 1, b)\n",
        OP_AROUND_PARENS,
        "`select-around-X` RETURNS `select-inner-X`'s SPAN. Two forms from one "
        "declaration, and the arm that shows the two are two: `around` must "
        "STRICTLY contain `inner`, which is a relation between two operations "
        "and cannot be asserted of either alone",
    ),
    Arm(
        "M11", OPS,
        "func refused(st: EditorState; why: RefusalReason): OpResult =\n"
        "  OpResult(outcome: ooRefused, state: st, refusal: why, intents: @[])\n",
        "func refused(st: EditorState; why: RefusalReason): OpResult =\n"
        "  OpResult(outcome: ooRefused, state: st, refusal: rrNone, intents: @[])\n",
        REFUSAL_ARM,
        "A REFUSAL STOPS BEING TYPED. `FUZZ-8`'s invariant is *'no exception "
        "escapes, and a refusal is a typed value'*, and the second half is the "
        "one that is easy to write and never check: an `ooRefused` carrying no "
        "reason is indistinguishable from a no-op to anything that reads only "
        "the outcome",
    ),
    Arm(
        "M12", BINDINGS,
        '                   operation: "delete-char-backward", effect: eeChanged,\n',
        '                   operation: "delete-word-backward", effect: eeChanged,\n',
        BEHAVIOUR_DELETE,
        "A BINDING ROW NAMES AN OPERATION THE VOCABULARY DOES NOT HAVE — and "
        "`delete-word-backward` is deliberately a FUSED name, the shape §2.1 "
        "says the vocabulary must not contain at all. This is the arm on the "
        "join: without it the table's `operation` column is a comment",
    ),
    Arm(
        "M13", BINDINGS,
        '    EditBindingRow(key: "", behaviour: ebInsertText,\n',
        '    EditBindingRow(key: "Insert", behaviour: ebInsertText,\n',
        BINDING_TABLE,
        "THE DEFAULT ROW STOPS BEING THE DEFAULT. `applyEditKey`'s `else` arm "
        "is the fourteenth behaviour and it is expressed as the row whose key "
        "is empty; a row bound to a real key instead leaves typing itself "
        "unbound, which is the entire editing path",
    ),
    Arm(
        "M14", DISPATCH,
        "  of ebMoveCharLeft: w.moveLeft(); ekMoved\n",
        "  of ebMoveCharLeft: w.moveRight(); ekMoved\n",
        WIDGET_LEFT,
        "THE DISPATCH PERFORMS THE WRONG BEHAVIOUR. `applyEditKey` is now a "
        "lookup plus a `case` over `EditBehaviour`, and the `case` is still a "
        "place a wrong answer can live — it is simply a place that can be "
        "asked the three questions CTUI-9 names. This is the only arm the "
        "ViewModel suites cannot reach, which is why the third suite is in the "
        "run",
    ),

    Arm(
        "M15", STATE,
        "  a.doc == b.doc and a.selection == b.selection and a.mode == b.mode and\n",
        "  a.doc == b.doc and a.selection == b.selection and\n",
        OP_ENTER_VISUAL,
        "THE STATE COMPARISON STOPS READING THE MODE. `settle` decides `acted` "
        "from `noOp` by comparing the whole state, so a comparison that reads "
        "two of its twenty-six fields makes every operation whose only effect "
        "is elsewhere report a NO-OP. The nine modal operations are the "
        "cheapest demonstration, and the reason the comparison is written out "
        "field by field rather than left to a structural `==` the type does "
        "not have",
    ),

    # =======================================================================
    # THE POPULATION
    # =======================================================================
    Arm(
        "G1", GENERATOR,
        '    sp("delete-to-line-start", caLine1Mid, {ckDocShrank}),\n',
        '    sp("delete-to-line-start", caDocStart, {ckDocShrank}),\n',
        OP_DELETE_TO_LINE_START,
        "ONE SCENARIO'S CARET IS MOVED TO A PLACE THE OPERATION CANNOT ACT "
        "FROM — §34, performed. A caret already at the line's start leaves "
        "`delete-to-line-start` with nothing to delete, and the case then "
        "passes every 'the document is still valid' assertion anybody would "
        "write. What catches it is asserting the OUTCOME as an equality: the "
        "input made it act, or the case is about the input",
    ),
    Arm(
        "G2", GENERATOR,
        "    while tries < runLen and\n"
        "          source[bs[runStart + off]] in {' ', '\\t'}:\n",
        "    while false:\n",
        OP_LINE_START_SMART,
        "THE FRAME'S SEGMENTS MAY BEGIN WITH WHITESPACE AGAIN — a defect this "
        "population actually had, twice. A segment starting with a space "
        "lengthens the frame's indent, so the scenario's recorded "
        "`line1FirstNonBlank` stops being where the first non-blank is, and "
        "`line-start-smart`'s landmark case fails on a LANDMARK that is wrong "
        "rather than on a motion that is. The first repair tested "
        "`strip().len == 0`, which a cluster of *space + combining mark* "
        "passes, and a fifth document failed",
    ),
    Arm(
        "G3", GENERATOR,
        "  m.displayCaret = displayWitness(text, tbs)\n",
        "  m.displayCaret = m.line1Early\n",
        DISP_ROW_START,
        "THE SEARCHED DISPLAY LANDMARK BECOMES A CONSTANT — also a defect this "
        "population had. A caret whose row is its logical line's FIRST row at "
        "both wrap columns answers the same thing at both, so "
        "`display-line-start` stops differing and twelve display cases become "
        "green statements about nothing. §34 in the landmarks rather than in "
        "the documents",
    ),

    # =======================================================================
    # THE SUITES
    # =======================================================================
    Arm(
        "U1", LAWS,
        '    "move-page-up", "extend-page-up", "select-page-up",\n',
        '    "move-page-up", "extend-page-up",\n',
        CARDINALITY,
        "THE SECOND SWEEP'S POSITIVE CASES, ASSERTED BY NAME, LOSES ONE. The "
        "list exists because 200 of the 224 display cases are negative "
        "controls and the positive ones are few enough to write down; a list "
        "that silently shrank would leave the sweep's two-sided equality "
        "asserted against a smaller positive half. Both its length AND its "
        "membership against the declared property, in both directions, are "
        "what this arm lands on",
    ),
    Arm(
        "U2", ORACLE,
        "      declColumn = if category == 'D': 1 else: 0\n",
        "      declColumn = 0\n",
        ORACLE_PARSE,
        "THE PARSER READS CATEGORY D's GROUP-LABEL COLUMN. §2.4 publishes the "
        "column rule precisely because a parser that guesses gets D wrong, and "
        "the group labels carry no backticks at all — so the parse silently "
        "yields SEVENTY FEWER declarations and every set difference stays "
        "empty. The per-category count is what refuses it, which is why the "
        "parse is asserted category by category rather than only in total",
    ),
    Arm(
        "U3", GENERATOR,
        '    sp("select-all", caLine0Mid, {ckSelectionChanged}),\n',
        '    sp("select-all", caLine0Mid, {}),\n',
        POPULATION,
        "A SCENARIO ROW LOSES ITS WITNESS. An operation swept with an empty "
        "check set is asserted to have ACTED and nothing else, which is the "
        "difference between 224 cases and 224 cases that mean something. The "
        "guard is the 'no row is witnessless' assertion, and this is the arm "
        "that proves it is a guard",
    ),
    Arm(
        "U4", TUI,
        "  buf.widget.moveCursorTo(Caret(line: 1, column: 8))\n",
        "  buf.widget.moveCursorTo(Caret(line: 0, column: 0))\n",
        WIDGET_HOME,
        "THE DISPATCH SUITE'S CARET MOVES TO THE DOCUMENT'S FIRST POSITION — "
        "§34 on the third suite. From `(0, 0)` neither `Left` nor `Home` has "
        "anywhere to go, so both report `ekMoved` and move nothing, and the "
        "fourteen rows become fourteen green cases about a caret that could "
        "not have acted. It is the same defect `G1` performs on the ViewModel "
        "side, which is why both are here rather than one standing for the "
        "other",
    ),
]

DECLARED_SURVIVORS: list = []
"""No arm is declared a survivor. An arm that survives is a `problems += 1`."""


@dataclass
class RunResult:
    rc: int
    passed: list = None
    failed: list = None
    ran: bool = False
    hung: bool = False

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []
        self.ran = True
        self.hung = False

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


# EVERY READ AND EVERY WRITE IS BYTES, AND THAT IS NOT STYLE (§32f).
def read_source(path: str) -> str:
    return (ROOT / path).read_bytes().decode("utf-8", errors="surrogateescape")


def write_source(path: str, text: str) -> None:
    (ROOT / path).write_bytes(text.encode("utf-8", errors="surrogateescape"))


def suites() -> list:
    """(path, binary, flags) for each suite, with the TUI lane's flags read."""
    tui_flags = tui_lane_flags()
    if not tui_flags:
        print("REFUSING: could not read the `tui` lane's flags out of "
              "ci/lib/test-lane-files.sh. Without them the third suite does "
              "not link, and dropping it silently would take M14 — the only "
              "arm on the DISPATCH — with it.")
        return []
    return [
        (ORACLE, "/tmp/plat30-mutation-oracle", VM_FLAGS),
        (LAWS, "/tmp/plat30-mutation-laws", VM_FLAGS),
        (TUI, "/tmp/plat30-mutation-tui", ["--hints:off", "--warnings:off"] + tui_flags),
    ]


def run_one(path: str, binary: str, flags: list, res: RunResult) -> None:
    try:
        proc = subprocess.run(
            ["nim", "c", "-r", *flags, "-o:" + binary, path],
            cwd=ROOT, capture_output=True, text=True, timeout=SUITE_TIMEOUT,
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
        # PER SUITE, not per run. A mutation that stops ONE of the three
        # suites compiling while the others still print their cases would
        # otherwise read as a clean survival.
        res.ran = False
        print(f"      ---- {path}: no result lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)


# §32h: `finally` covers an exception and does NOT cover a signal.
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


def run_suite(suite_list: list) -> RunResult:
    res = RunResult(rc=0)
    for path, binary, flags in suite_list:
        run_one(path, binary, flags, res)
    return res


COUNT_CONSTANT = re.compile(
    r"^\s*const\s+(ExpectedAssertions|ExpectedCases|ExpectedOperations|"
    r"ExpectedDeclarations|ExpectedDisplayDependent|ExpectedDisplayIndependent|"
    r"ExpectedScenarioDocs|EditBehaviourCount|RunFloor)\s*=\s*(\d+)", re.M)
COUNT_NAMES = ("ExpectedAssertions", "ExpectedCases", "ExpectedOperations",
               "ExpectedDeclarations", "ExpectedDisplayDependent",
               "ExpectedDisplayIndependent", "ExpectedScenarioDocs",
               "EditBehaviourCount", "RunFloor", "CHECKS:")


def declared_counts() -> dict:
    """{value: "file:Name"} for every declared count constant in the subjects."""
    found = {}
    for path in TOUCHED:
        try:
            text = read_source(path)
        except OSError:
            continue
        for m in COUNT_CONSTANT.finditer(text):
            found[m.group(2)] = f"{path}:{m.group(1)}"
    return found


CASE_TEMPLATES = [
    ('test "operation: " & op.name:', LAWS, "THE OPERATION SWEEP'S CELL"),
    ('test "display: " & op.name:', LAWS, "THE DISPLAY SWEEP'S CELL"),
    ('test "FUZZ-8 x corpus class " & $cls:', LAWS, "THE FUZZ-8 CELL"),
    ('test "row: " & specDecl.name:', ORACLE, "THE ORACLE ROW CELL"),
    ('test "behaviour: " & $row.behaviour:', ORACLE, "THE BINDING-ROW CELL"),
    ('test "behaviour through the widget: " & $row.behaviour:', TUI,
     "THE DISPATCH CELL"),
]

COMPOSED_PREFIXES = ("operation: ", "display: ", "FUZZ-8 x corpus class ",
                     "row: ", "behaviour: ", "behaviour through the widget: ")


def check_killer_names(problems: int) -> int:
    """Every killer names a case the suites actually instantiate."""
    bodies = {p: read_source(p) for p in (LAWS, ORACLE, TUI)}
    everywhere = "\n".join(bodies.values())

    for needle, path, label in CASE_TEMPLATES:
        if needle not in bodies[path]:
            print(f"{label} IS NOT IN {path}")
            problems += 1

    for name in NAMED_CASES:
        if name.startswith(COMPOSED_PREFIXES):
            continue    # composed from a table; the templates are checked above
        if name not in everywhere:
            print(f"KILLER NAME NOT IN ANY SUITE: {name!r}")
            problems += 1

    for arm in ARMS:
        if arm.killer not in NAMED_CASES:
            print(f"{arm.id}: killer {arm.killer!r} is not a declared case name")
            problems += 1
    return problems


def needle_scan() -> int:
    """Every arm's needle occurs exactly once. No toolchain, about a second."""
    problems = 0

    # §10.3 FIRST, because an arm that quotes a count is unkillable in a way
    # the occurrence check cannot see: the needle is present today and gone on
    # the next commit that adds a test.
    counts = declared_counts()
    print(f"declared count constants in the subjects: "
          f"{', '.join(f'{v}={k}' for k, v in sorted(counts.items())) or 'none'}")
    if not counts:
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

    # EVERY SUBJECT CARRIES AT LEAST ONE ARM. Seven subjects and an arm table
    # that reached only three would be a harness whose coverage is a list of
    # files rather than a set of checks.
    armed = {arm.path for arm in ARMS}
    unarmed = [p for p in TOUCHED if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    else:
        print(f"all {len(TOUCHED)} subjects carry at least one arm")

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
    # **ITS VERDICT IS ACTED ON, NOT PRINTED.** PLAT-27's harness was found
    # discarding the bool this returns; PLAT-28 repaired it and this one
    # inherits the repair. It matters because `baseline` below is snapshotted
    # from the CURRENT tree — without this refusal a run started on an
    # already-mutated file restores TO the mutation and reports itself clean.
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved (§32). Re-run "
              "--needle-scan, review the tree, then --record-control-hashes.")
        return 1

    suite_list = suites()
    if not suite_list:
        return 1

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    print("\n== control ==")
    control = run_suite(suite_list)
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
    global _ACTIVE
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
        _ACTIVE = (arm.path, original)
        write_source(arm.path, original.replace(arm.find, arm.replace))
        try:
            res = run_suite(suite_list)
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
