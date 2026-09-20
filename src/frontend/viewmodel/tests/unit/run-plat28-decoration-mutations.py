#!/usr/bin/env python3
"""PLAT-28's arming — the mutation harness for anchors, decorations and the
inlay that reflows.

    python3 src/frontend/viewmodel/tests/unit/run-plat28-decoration-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=M1,M6

WHAT THIS IS, AND WHY EVERY PART OF IT IS HERE
==============================================
Editor-Model-Conformance-Suite.md §3 admits a law only when it names the
mutation that must kill it. §3.4 names five; §3.3 names a sixth that belongs to
this milestone (`LAW-C7`). This harness PERFORMS each of them and requires a
NAMED case to go red — not "the suite failed", which is satisfied by a
mutation that breaks the build.

Verification-Harness-Traps, applied rather than cited:

  * §32   — a needle lost under a later repair is silently unkillable, so
            `--needle-scan` refuses to run when any arm's needle is absent or
            ambiguous, and the full run refuses unless the scan is clean.
  * §32f  — every read and every write is BYTES. `Path.read_text()` applies
            universal-newline translation, and this milestone's suites embed
            `"\\r\\n"` in their own source (`PLAT28-DG3`'s CRLF measurement),
            so a text-mode restore would rewrite the very bytes that case
            exists to pin.
  * §32h  — `finally` is not a signal handler, so SIGTERM/SIGINT/SIGHUP
            restore the subject before exiting.
  * §10.3 — no arm's needle may quote a count. The scan reads every declared
            count constant out of the subjects and REJECTS an arm whose needle
            contains one of their names or one of their values, and refuses to
            run at all when no subject declares a count (a scan that found
            nothing satisfies every "must not contain" written over it).
  * §4    — THE CONTROL-DIGEST GUARD'S VERDICT IS ACTED ON. PLAT-27's harness
            was found returning a bool nobody read: it printed
            `CONTROL DIGEST MOVED` and ran all 22 arms anyway. `baseline` is
            snapshotted from the CURRENT tree, so without the refusal a run
            started on an already-mutated file restores TO the mutation and
            reports itself clean.

TWO ARMS MUTATE THE GENERATOR AND FIVE MUTATE THE SUITE, because this
campaign's recurring defect is a gate that cannot fail. The population is a
subject like any other and is armed like one.

COUNT THE ARMS BY THEIR `subject`, NOT BY THEIR NAME. `G2` carries a `G`
because the DEFECT it performs is a population defect — the fuzz stream
stopping deleting around its anchors — but the lines it edits live in
`test_editor_decoration_laws.nim`, so its subject is the SUITE. Counting by
prefix gives three and four, and that is what this docstring, PLAT-28's status
and the conformance suite's arm table all said until it was measured.

BOTH SUITES RUN FOR EVERY ARM. They share the five product modules, so an arm
on `decoration.nim` can redden either; running only "the suite an arm belongs
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
ANCHOR = "src/frontend/viewmodel/editor/anchor.nim"
RANGESET = "src/frontend/viewmodel/editor/range_set.nim"
DECORATION = "src/frontend/viewmodel/editor/decoration.nim"
INLAY = "src/frontend/viewmodel/editor/inlay.nim"
PROJECTION = "src/frontend/viewmodel/editor/row_projection.nim"
WRAP = "src/frontend/viewmodel/editor/wrap.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/decoration_generator.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_decoration_laws.nim"
EX = "src/frontend/viewmodel/tests/unit/test_editor_decoration_examples.nim"

TOUCHED = [ANCHOR, RANGESET, DECORATION, INLAY, PROJECTION, WRAP, GENERATOR,
           LAWS, EX]

CONTROL_HASHES = HERE / "plat28-decoration-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P28_SUITE_TIMEOUT", "1800"))
LAWS_BIN = os.environ.get("CT_P28_LAWS_BIN", "/tmp/plat28-mutation-laws")
EX_BIN = os.environ.get("CT_P28_EX_BIN", "/tmp/plat28-mutation-examples")

# `--path:src/frontend/viewmodel` is what every `vm-*` lane supplies and what
# `test_editor_decoration_examples.nim.cfg` carries for itself; passing it here
# too makes the two suites compile the same way from one command.
NIM_FLAGS = ["--hints:off", "--path:src/frontend/viewmodel"]

SUITES = [(LAWS, LAWS_BIN), (EX, EX_BIN)]

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# Four families are COMPOSED at run time and the scan checks the halves rather
# than searching for the whole string:
#   `LAW-D1 anchor: <side> x <fate> x <editKind>`
#   `LAW-D2 fate: <surface> x <fate>`
#   `LAW-D5 <axiom> x <decorationKind>`
#   `EditorRow.<field> x <scenario>`
# ---------------------------------------------------------------------------

D1_INSERT = "LAW-D1 anchor: sideAfter x survived x clsPureInsert"
D1_COLLAPSE = "LAW-D1 anchor: sideBefore x collapsed x clsPureDelete"
D2_COLLAPSED = "LAW-D2 fate: asBreakpoint x collapsed"
D2_DELETED = "LAW-D2 fate: asBreakpoint x deleted"
D2_REFUSAL = "LAW-D2's refusal is EXECUTED: `position` raises on a non-survived fate"
D3_DELETE = "LAW-D3 x clsPureDelete"
D4_DELETE = "LAW-D4 x clsPureDelete"
D5_TOTAL = "LAW-D5 oaTotal x dkMark"
D5_STABLE = "LAW-D5 oaStable x dkInlineWidget"

C7_WITH = "LAW-C7 x class 1 x with the widget"
C7_WITHOUT = "LAW-C7 x class 1 x without the widget"
C7_WRAP = "LAW-C7 wrap arm x class 1"

FUZZ2 = "FUZZ-2 x class 2"
# CLASS 2 AND NOT CLASS 1, and the reason is `G2`'s own verdict: with the
# deliberate deletion removed, class 1's `genSimple` stream happens to delete
# around an anchor anyway and that class stays green. An arm whose kill depends
# on a draw is an arm that is sometimes a survivor (§36's fourth rule), so the
# killer names a class that does NOT depend on one.
FUZZ7 = "FUZZ-7 x class 1"

P_KINDS = ("the seed, the realised edit kinds and the anchor count are "
           "printed and asserted")
P_CLASSES = ("the deleted-text, boundary-side and wrapped-line classes are "
             "EQUALITIES, each witnessed")
P_REACH = "the reachability table is two-sided and its cardinality is asserted"
P_DECOPOP = "the DECORATION population realises all four arms, as EQUALITIES"

N_LAWSET = "the law set's cardinality is asserted and every law names its killer"
N_ORACLE = "THE ORACLE IS NOT THE MAPPING FUNCTION — §30a, on the BODY"
N_DIR = "the scan's subject list is the directory, not a list somebody maintains"
N_CLAMP = "NO CLAMP REPAIRS AN ANCHOR — every unreachable path RAISES"
N_SPLICE = "A DECORATED CACHE REFUSES THE SPLICE rather than dropping its widgets"
N_ONEPATH = "THE TWO ARMS OF THE REFLOW ARE ONE CODE PATH — §30a on the control"
N_LINES = ("`projectionLines` and `wrap.documentLines` agree over every "
           "corpus document")
N_SHRINK = "THE SHRINKER EXISTS AND IS TESTED BY A PLANTED ALWAYS-FAILING PROPERTY"

G_ARM1 = "GATE ARM 1 — with a width-10 widget at column 8, the text after it is at column 18"
G_ARM2 = "GATE ARM 2 — with the widget removed and NOTHING ELSE CHANGED, it is at column 8"
G_ARM3 = "GATE ARM 3 — THE WRAP ARM: the line wraps with the widget and not without it"
G_TAB = ("A TAB AFTER THE WIDGET RE-GRIDS — the shift is NOT uniform, and that "
         "is why the columns are recomputed")
G_WIDE = "A WIDE CLUSTER AFTER THE WIDGET IS POSITIONED IN CELLS, NOT IN CLUSTERS"
G_CLAMPREF = "THE OFFSET BOUND RAISES WHERE THE REFERENCE CLAMPS"
G_SIDE = "AN INSERT EXACTLY AT AN ANCHOR IS THE ONLY PLACE THE SIDE CHANGES THE ANSWER"
G_BP = ("A BREAKPOINT ON A DELETED LINE IS NOT A BREAKPOINT ON THE LINE THAT "
        "TOOK ITS PLACE")
G_REMOTE = "A REMOTE EDIT GOES THROUGH THE ONE REBASE PRIMITIVE"
G_FIELDS = "the seven fields and the four scenarios are asserted cardinalities"
# RENAMED BY PLAT-34 ON 2026-09-20, BECAUSE ITS SUBJECT CLOSED. The case
# measured `PLAT28-DG3` — `editorSurfaceForProject` splitting with
# `strutils.splitLines` while the model splits on `'\n'` only — and PLAT-34
# took the decision that gap's own remedy asked for and moved the SURFACE. The
# case now measures the AGREEMENT, with the old numbers kept in its comment.
# The name is updated here rather than the case being dropped from
# `NAMED_CASES`: a killer that names a case nobody wrote is a row that can
# never be a kill (§32), and this harness refuses on exactly that.
G_DG3 = ("PLAT28-DG3 — THE TWO PRODUCERS AGREED ABOUT A LINE TERMINATOR AFTER "
         "PLAT-34, measured")

NAMED_CASES = [
    D1_INSERT, D1_COLLAPSE, D2_COLLAPSED, D2_DELETED, D2_REFUSAL,
    D3_DELETE, D4_DELETE, D5_TOTAL, D5_STABLE,
    C7_WITH, C7_WITHOUT, C7_WRAP, FUZZ2, FUZZ7,
    P_KINDS, P_CLASSES, P_REACH, P_DECOPOP,
    N_LAWSET, N_ORACLE, N_DIR, N_CLAMP, N_SPLICE, N_ONEPATH, N_LINES, N_SHRINK,
    G_ARM1, G_ARM2, G_ARM3, G_TAB, G_WIDE, G_CLAMPREF, G_SIDE, G_BP, G_REMOTE,
    G_FIELDS, G_DG3,
]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    law: str = ""       # §3.3/§3.4's own killer wording, where an arm performs one
    law_id: str = ""    # which law it performs, stated rather than parsed


ARMS = [
    # =======================================================================
    # THE SIX PUBLISHED KILLERS — §3.4's five and §3.3's LAW-C7
    # =======================================================================
    Arm(
        "M1", ANCHOR,
        "               outcome: cs.mapPos(a.pos, a.side))\n",
        "               outcome: cs.mapPos(a.pos,\n"
        "                 (if a.side == sideBefore: sideAfter else: sideBefore)))\n",
        D1_INSERT,
        "ANCHORS ARE MAPPED WITH THE WRONG SIDE. Note how little moves: the "
        "fate is unchanged for every anchor, every position is still in "
        "range, and the ONLY observable is an insert exactly AT an anchor — "
        "which is why the population asserts the boundary-side class as an "
        "equality before any law reads it. A generator that never inserted at "
        "an anchor would leave this arm a survivor",
        law="map anchors with the wrong side",
        law_id="LAW-D1",
    ),
    Arm(
        "M2", ANCHOR,
        "  MappedAnchor(id: a.id, side: a.side, surface: a.surface,\n"
        "               outcome: cs.mapPos(a.pos, a.side))\n",
        "  var o = cs.mapPos(a.pos, a.side)\n"
        "  if o.kind == mapCollapsed: o = Mapped(kind: mapSurvived, pos: o.at)\n"
        "  MappedAnchor(id: a.id, side: a.side, surface: a.surface,\n"
        "               outcome: o)\n",
        D2_COLLAPSED,
        "THE COLLAPSE POINT IS RETURNED AS *SURVIVED*, which is §3.4's own "
        "wording. The position it reports is the RIGHT one — the point the "
        "range collapsed to — so nothing about the number is wrong and a law "
        "quantified over positions alone stays green. What moves is the FATE, "
        "and the oracle is what sees it: the sentinel is gone from the new "
        "document and the model says the anchor survived",
        law="return the collapse point as survived",
        law_id="LAW-D2",
    ),
    Arm(
        "M3", RANGESET,
        "    if not touchesChunk(touched, c.minPos, c.maxPos):\n",
        "    let nxt = rs.chunks[min(ci + 1, rs.chunks.len - 1)]\n"
        "    if not touchesChunk(touched, nxt.minPos, nxt.maxPos):\n",
        D3_DELETE,
        "THE SKIP PREDICATE IS WIDENED BY ONE CHUNK — §3.4's own wording, "
        "literally: the chunk is tested against its NEIGHBOUR's bounds, so a "
        "chunk the change actually touches is skipped and keeps a stale "
        "position the unoptimised path moves. The answer stays plausible "
        "(every position is in range, the set is still ordered) and only the "
        "differential sees it",
        law="widen the skip predicate by one chunk, so a chunk the change "
            "actually touches is skipped and keeps a stale position the "
            "unoptimised path moves",
        law_id="LAW-D3",
    ),
    Arm(
        "M4", RANGESET,
        "  if lo > hi: none((int, int)) else: some((lo, hi))\n",
        "  if lo > hi or true: none((int, int)) else: some((lo, hi))\n",
        D4_DELETE,
        "THE COMPARISON ALWAYS RETURNS AN EMPTY SPAN. §4's widen-vs-narrow in "
        "one line: an empty span trivially satisfies *'the reported span "
        "contains every actual difference'*, because there is nothing in it "
        "to be outside. The half that kills is the other one — `none` exactly "
        "when there is no difference — and it is the half a soundness-only law "
        "would not have",
        law="widen-vs-narrow: a comparison that returns an empty span always "
            "agrees",
        law_id="LAW-D4",
    ),
    Arm(
        "M5", DECORATION,
        "  if a.cls != b.cls: return ord(a.cls) < ord(b.cls)\n"
        "  a.offset < b.offset\n",
        "  if a.offset != b.offset: return a.offset < b.offset\n"
        "  ord(a.cls) < ord(b.cls)\n",
        D5_TOTAL,
        "THE OFFSET IS COMPARED BEFORE THE ENUM — §3.4's own wording.\n\n"
        "        **THIS ARM IS THE MILESTONE'S §36 FINDING AND IT IS WORTH "
        "THE PARAGRAPH.** `(offset, class)` compared lexicographically is "
        "ALSO A TOTAL ORDER: trichotomous, antisymmetric, transitive, and a "
        "stable sort under it is still stable. So the three axioms `LAW-D5` "
        "publishes — *'antisymmetric, transitive, and stable'* — are ALL "
        "GREEN under the published killer, and so is trichotomy. The killer "
        "cannot kill the law as stated.\n\n"
        "        The repair is to the ASSERTION and never to the killer "
        "(§36's first rule): every `LAW-D5` cell now also asserts that the "
        "CLASS DOMINATES — for any two order classes A < B and any legal "
        "offsets, `(A, x) < (B, y)` — over a population whose offsets "
        "deliberately run the other way. That is the claim the reference "
        "encodes by spacing its bands 10^8 apart, and it is the one thing the "
        "swap destroys",
        law="compare the offset before the enum",
        law_id="LAW-D5",
    ),
    Arm(
        "M6", INLAY,
        "      col += widgets[wi].cells\n"
        "      inc wi\n",
        "      col += 0\n"
        "      inc wi\n",
        C7_WITH,
        "THE WIDGET IS DRAWN AS AN OVERLAY — §3.3's own wording for `LAW-C7`. "
        "The widget cluster is still in the metrics and still reports its "
        "width; what it no longer does is ADVANCE THE COLUMN, which is "
        "exactly what an overlay cannot do. The text after it goes back to C. "
        "**This is the arm the whole milestone exists for**: it is the "
        "difference between a model that owns the layout and a renderer that "
        "paints over one",
        law="draw the widget as an overlay — it cannot move a column",
        law_id="LAW-C7",
    ),
    Arm(
        "M7", INLAY,
        "                                    cells: widgets[wi].cells, column: col)\n"
        "    col += widgets[wi].cells\n",
        "                                    cells: 0, column: col)\n"
        "    col += 0\n",
        C7_WRAP,
        "THE SAME OVERLAY, FOR A WIDGET AT THE END OF A LINE — the trailing "
        "loop rather than the in-line one. It is a SECOND arm and not a "
        "duplicate because the wrap arm is taken with the widget at the line's "
        "end: an overlay there cannot push the line past the wrap column, so "
        "the line stops wrapping and `LAW-C7`'s wrap arm — the claim a "
        "host-drawn overlay cannot make — is the case that notices.\n\n"
        "        **A FIRST SPELLING OF THIS ARM SURVIVED AND THE REASON IS A "
        "FINDING.** Zeroing only the COLUMN ADVANCE (`col += 0`) leaves the "
        "line wrapping exactly as before, because the WRAP DECISION in "
        "`wrap.wrapLine` accumulates each cluster's `cells` and never consults "
        "its `column` — so a widget that occupies no column still occupies "
        "width. (`wrapLine` DOES read `column`, at `wrap.nim:354`, but only to "
        "label a new row's `startColumn` after the break has been decided, so "
        "a zeroed advance moves where rows say they start and not whether they "
        "exist.) An overlay occupies "
        "NEITHER, and the arm has to zero both to be the mutation it names "
        "(§36: the question is not *is this mutation wrong* but *which "
        "assertion goes red when I make it*)",
        law="draw the widget as an overlay — it cannot move a column",
        law_id="LAW-C7",
    ),

    # =======================================================================
    # SIX MORE ON THE PRODUCT — properties no published killer names
    # =======================================================================
    Arm(
        "M8", INLAY,
        "    let w = cellsOf(text, col, policy)\n",
        "    let w = cl.cells\n",
        G_TAB,
        "THE COLUMNS ARE SHIFTED RATHER THAN RE-DERIVED — the cheap "
        "implementation of *'insert W cells at column C'*. It is right on "
        "every line with no tab after the widget, which is almost every line "
        "in almost every corpus, and wrong on exactly the class the corpus "
        "carries for it: a tab advances to the next multiple of `tabSize` "
        "counted from the start of the LOGICAL line, so a widget of 3 cells "
        "moves the tab's END by between 0 and `tabSize`, never by 3",
    ),
    Arm(
        "M9", DECORATION,
        "  if offset < -DecoOffsetBound or offset > DecoOffsetBound:\n"
        "    raise newException(DecorationError,\n",
        "  if offset < -DecoOffsetBound or offset > DecoOffsetBound:\n"
        "    return DecoOrder(cls: cls,\n"
        "      offset: max(-DecoOffsetBound, min(DecoOffsetBound, offset)))\n"
        "  if false:\n"
        "    raise newException(DecorationError,\n",
        G_CLAMPREF,
        "**THE REFERENCE'S OWN BEHAVIOUR, RESTORED.** CodeMirror clamps a user "
        "offset to +-10,000; this clamps instead of raising, and §36a is what "
        "the arm demonstrates: the clamp makes two distinguishable orders "
        "compare EQUAL and there is no way to tell it from a guard that never "
        "fires. Every order axiom stays true under it — a clamp preserves a "
        "total order — so only the case that asserts the REFUSAL can see it",
    ),
    Arm(
        "M10", ANCHOR,
        "  if pos < 0:\n"
        "    raise newException(AnchorError,\n",
        "  if pos < 0:\n"
        "    return Anchor(pos: 0, side: side, surface: surface, id: id)\n"
        "  if false:\n"
        "    raise newException(AnchorError,\n",
        N_CLAMP,
        "AN ANCHOR IS CLAMPED INTO RANGE — §36a's headline for this milestone: "
        "*'a clamp is a silent repair, and it hides the defect it clamps for "
        "exactly as long as the value stays out of range'*. Every fate then "
        "looks total, because there is no input for which the constructor "
        "refuses",
    ),
    Arm(
        "M11", WRAP,
        "  if c.hasWidgets:\n",
        "  if false:\n",
        N_SPLICE,
        "A DECORATED CACHE IS SPLICED RATHER THAN REFUSED. The splice "
        "recomputes a touched line's metrics FROM ITS TEXT, and a widget is "
        "not in the text — so the lines being edited quietly lose their inline "
        "values while every other line keeps them. It is the worst shape for a "
        "defect this milestone could have: a missing inline value looks exactly "
        "like *'there is nothing in scope on this line'*",
    ),
    Arm(
        "M12", PROJECTION,
        "  elif cls == MarkClassTracepoint: emTracepoint\n"
        "  else:\n"
        "    raise newException(RowProjectionError,\n",
        "  elif cls == MarkClassTracepoint: emTracepoint\n"
        "  elif true: emNone\n"
        "  else:\n"
        "    raise newException(RowProjectionError,\n",
        N_CLAMP,
        "AN UNKNOWN MARK CLASS ANSWERS `emNone` INSTEAD OF REFUSING. The "
        "repair is the worst available one: `emNone` is what a line with no "
        "breakpoint looks like, so a typo in a class name presents as a gutter "
        "that simply never shows anything — and a gutter that shows nothing is "
        "the state `PLAT22-PG1` already describes for a different reason",
    ),
    Arm(
        "M13", DECORATION,
        "    while i > 0 and d.order < result[i - 1].order:\n",
        "    while i > 0 and not (result[i - 1].order < d.order):\n",
        D5_STABLE,
        "THE ORDER SORT LOSES ITS STABILITY. Two decorations with EQUAL order "
        "now swap, so the paint order of two equally-ordered widgets depends "
        "on the insertion algorithm rather than on the declaration order. "
        "Every order axiom still holds — stability is not an axiom of the "
        "ORDER, it is a property of the SORT — which is why `LAW-D5` runs four "
        "axioms rather than three",
    ),

    # =======================================================================
    # THE POPULATION DEFECTS — a population is a subject like any other.
    # TWO of these three are GENERATOR arms (`G1`, `G3`); `G2`'s subject is the
    # LAWS SUITE, because the fuzz stream it edits lives there. See the module
    # docstring: count by `subject`, not by the prefix.
    # =======================================================================
    Arm(
        "G1", GENERATOR,
        "  let rot = r.rand(ad.sites.len - 1)\n",
        "  let rot = 0\n",
        D2_DELETED,
        "**THE ROLE ROTATION IS REMOVED, AND THIS ARM PERFORMS A DEFECT THIS "
        "MILESTONE ACTUALLY HAD.** With the pure delete pinned to site 0 and "
        "the replacement to site 1, a site's SURFACE (which cycles through "
        "`AnchorSurface`'s four members) and its FATE become perfectly "
        "correlated: `asBreakpoint` is only ever `collapsed` and "
        "`asDecorationRange` only ever `deleted`. Four of `LAW-D2`'s twelve "
        "cells come back EMPTY — and every law that DID run stayed green, "
        "which is §34 exactly: the populations, not the properties",
    ),
    Arm(
        "G2", LAWS,
        "        if step mod 4 == 3 and live.len > 0:\n",
        "        if false and live.len > 0:\n",
        FUZZ2,
        "THE FUZZ STREAM STOPS DELETING AROUND ITS ANCHORS. `FUZZ-2` is "
        "*'every anchor resolves inside [0, len] OR reports a typed deleted "
        "fate'*, and with nothing ever deleted the second half of that "
        "disjunction fires zero times and the invariant is a statement about "
        "arithmetic. **This was the first run's real behaviour**: six of nine "
        "classes realised zero typed fates, which is why the deliberate "
        "deletion is in the stream and why its count is asserted non-zero per "
        "class",
    ),
    Arm(
        "G3", GENERATOR,
        "  let shapes = sectionShapes(cs)\n"
        "  if shapes.len == 0: return clsEmpty\n",
        "  let shapes = sectionShapes(cs)\n"
        "  if true: return clsReplace\n"
        "  if shapes.len == 0: return clsEmpty\n",
        P_KINDS,
        "THE CLASSIFIER STOPS READING ITS INPUT. §34's third rule is that the "
        "classifier must not be the constructor; this is the degenerate form "
        "of the same failure — a classifier that answers without looking. The "
        "per-class realised counts are asserted as EQUALITIES against the "
        "per-class draw counts, so four of the five rows go red at once; a "
        "histogram checked only for non-emptiness would show one full row and "
        "four empty ones and satisfy nothing that could notice",
    ),

    # =======================================================================
    # THE REMAINING FOUR ON THE SUITE — a gate that cannot fail is this
    # campaign's defect. With `G2` above, five arms have the suite as subject.
    # =======================================================================
    Arm(
        "U1", LAWS,
        "  [true, false, false],   # clsPureInsert — nothing is removed\n",
        "  [true, true, true],   # clsPureInsert — nothing is removed\n",
        P_REACH,
        "THE REACHABILITY TABLE CLAIMS AN UNREACHABLE CELL IS REACHABLE. The "
        "matrix is two-sided precisely so this fails: a `true` cell that the "
        "population never realises is as red as a `false` cell that it does. "
        "Without the second direction, `Reachable` could be all-`true` and "
        "thirty `LAW-D1` cells would assert nothing but `seen > 0`",
    ),
    Arm(
        "U2", LAWS,
        'const OracleForbidden = ["mapPos", "mapAnchor", "changeSet", "ChangeSet",\n'
        '                         "sections", "compose(", "rebase(", "mapPosOr"]\n',
        'const OracleForbidden: array[0, string] = []\n',
        N_ORACLE,
        "§30a's OWN ARM, and it is the one that cannot be replaced by an "
        "assertion about an answer. An empty forbidden list makes the "
        "oracle-independence scan iterate nothing and satisfy every *'must not "
        "contain'* written over it (§4). The case asserts the list's "
        "cardinality for exactly this reason: a correct re-derivation on one "
        "side of a differential is invisible to every check except a scan of "
        "the control's own body",
    ),
    Arm(
        "U3", LAWS,
        '    if kind == pcFile and path.endsWith(".nim"):\n',
        '    if kind == pcFile and path.endsWith(".nimx"):\n',
        N_DIR,
        "§35's ARM: the directory enumeration matches nothing, so *'the set is "
        "exactly these thirteen'* is satisfied by leaving nothing to disagree "
        "with it. The arm is one character in the extension it filters on, "
        "which is the trap's own stated remedy applied to itself",
    ),
    Arm(
        "U4", EX,
        "  [true,  true,  false, false, false, false, false],   # scPlain\n",
        "  [true,  true,  true,  true,  true,  true,  true],   # scPlain\n",
        G_FIELDS,
        "THE VARIETY TABLE CLAIMS A CONSTANT FIELD VARIES. Twenty-eight "
        "`EditorRow` cells compare a field against today's producer, and three "
        "of the four scenarios have `pointer`, `values` and `flow` constant on "
        "BOTH sides — cases that cannot fail unless something says so. The "
        "declared table is what says so, and it is two-sided: a cell marked "
        "varying and found constant is as red as the reverse",
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


def run_one(path: str, binary: str, res: RunResult) -> None:
    try:
        proc = subprocess.run(
            ["nim", "c", "-r", *NIM_FLAGS, "-o:" + binary, path],
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
        # PER SUITE, not per run. A mutation that stops ONE of the two suites
        # compiling while the other still prints its cases would otherwise read
        # as a clean survival.
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


def check_killer_names(problems: int) -> int:
    """Every killer names a case the suites actually instantiate."""
    laws = read_source(LAWS)
    ex = read_source(EX)
    both = laws + "\n" + ex

    templates = [
        ('test cellName:', laws, "THE LAW-D1 CELL TEMPLATE"),
        ('test "LAW-D2 fate: " & $surface & " x " & fateName(fate):', laws,
         "THE LAW-D2 CELL TEMPLATE"),
        ('test "LAW-D3 x " & $cls:', laws, "THE LAW-D3 CELL TEMPLATE"),
        ('test "LAW-D4 x " & $cls:', laws, "THE LAW-D4 CELL TEMPLATE"),
        ('test "LAW-D5 " & $axiom & " x " & $kind:', laws,
         "THE LAW-D5 CELL TEMPLATE"),
        ('test "LAW-C7 x class " & $(c + 1) & " x with the widget":', laws,
         "THE LAW-C7 WITH-ARM TEMPLATE"),
        ('test "LAW-C7 x class " & $(c + 1) & " x without the widget":', laws,
         "THE LAW-C7 WITHOUT-ARM TEMPLATE"),
        ('test "LAW-C7 wrap arm x class " & $(c + 1):', laws,
         "THE LAW-C7 WRAP-ARM TEMPLATE"),
        ('test "FUZZ-2 x class " & $(c + 1):', laws, "THE FUZZ-2 TEMPLATE"),
        ('test "FUZZ-7 x class " & $(c + 1):', laws, "THE FUZZ-7 TEMPLATE"),
        ('test "EditorRow." & $f & " x " & $sc:', ex,
         "THE EditorRow CELL TEMPLATE"),
    ]
    for needle, text, label in templates:
        if needle not in text:
            print(f"{label} IS NOT IN THE SUITE")
            problems += 1

    composed = ("LAW-D1 anchor: ", "LAW-D2 fate: ", "LAW-D3 x ", "LAW-D4 x ",
                "LAW-D5 ", "LAW-C7 ", "FUZZ-2 x ", "FUZZ-7 x ", "EditorRow.")
    for name in NAMED_CASES:
        if name.startswith(composed):
            continue    # composed from an enum; the halves are checked above
        if name not in both:
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

    # §10.3 FIRST, because an arm that quotes a count is unkillable in a way the
    # occurrence check cannot see: the needle is present today and gone on the
    # next commit that adds a test.
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

    # ALL SIX PUBLISHED KILLERS ARE PERFORMED, two-sidedly. §3.4 publishes five
    # `LAW-D*`; §3.3's `LAW-C7` is this milestone's too, and PLAT-27's deferral
    # of it is expired in `ci/test/editor-model-case-floor.sh`.
    performed = set()
    for arm in ARMS:
        if not arm.law:
            continue
        if not (arm.law_id.startswith("LAW-D") or arm.law_id == "LAW-C7"):
            print(f"{arm.id}: quotes a published killer but declares law_id "
                  f"{arm.law_id!r}")
            problems += 1
            continue
        performed.add(arm.law_id)
    expected = {f"LAW-D{i}" for i in range(1, 6)} | {"LAW-C7"}
    if performed != expected:
        print(f"PUBLISHED KILLERS NOT PERFORMED BY ANY ARM: "
              f"{sorted(expected - performed)}")
        print(f"ARMS CLAIMING A LAW THAT IS NOT PUBLISHED HERE: "
              f"{sorted(performed - expected)}")
        problems += 1
    else:
        print(f"all {len(expected)} published killers are performed by an arm")

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
    # `TOUCHED` is the whole subject set of this harness; `record_control_hashes`
    # writes a digest for exactly these paths, so the comparator must read
    # exactly these paths. The two iterating the same set is the property that
    # makes "absent" mean something rather than being an accident of ordering.
    for p in TOUCHED:
        # **A PATH THAT IS NOT IN THE FILE AT ALL IS A REFUSAL, NOT A SKIP.**
        # The old one-sided test — a membership guard ANDed onto the digest
        # comparison — made absence and agreement indistinguishable:
        # a newly added subject passed the gate silently until somebody happened
        # to re-record. That is the one-sided-check shape §32 exists to forbid,
        # sitting inside the mechanism built to catch drift.
        if p not in recorded:
            print(f"CONTROL DIGEST ABSENT: {p} is compared by this harness "
                  f"but has no recorded digest — run --needle-scan, review, "
                  f"then --record-control-hashes (§32)")
            ok = False
        elif recorded[p] != digest(p):
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
    # discarding the bool this returns: it printed `CONTROL DIGEST MOVED` and
    # ran all 22 arms anyway. It matters because `baseline` below is
    # snapshotted from the CURRENT tree — without this refusal a run started on
    # an already-mutated file restores TO the mutation and reports itself clean.
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved (§32). Re-run "
              "--needle-scan, review the tree, then --record-control-hashes.")
        return 1

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
