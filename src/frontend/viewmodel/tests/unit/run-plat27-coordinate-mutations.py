#!/usr/bin/env python3
"""PLAT-27's mutation harness — proof that the coordinate suite can go red.

`test_editor_wrap_laws.nim` claims that six laws, a 90-cell bijection sweep, a
twelve-operation display-motion sweep, a differential against a real terminal, a
cache-coherence stream and six source scans each detect something. This script
proves it one case at a time: it patches a single passage of a SUBJECT — the
projection, the population generator, or the suites' own non-vacuity machinery —
and requires the **named** case to fail. A mutation killed only by some other
case is MISDIRECTED and is a failure of this harness, not a pass.

**SIX OF THE ARMS ARE §3.3's OWN KILLER COLUMN, APPLIED.** Every `LAW-C*` row in
Editor-Model-Conformance-Suite.md §3.3 names the mutation that must kill it, and
*"an arm with no stated killer is not admitted"*. The `law` field below carries
the row's wording verbatim beside the patch that performs it, so a reader can
check the arm against the published table rather than against this file's own
description of it. `ci/test/editor-model-case-floor.sh PLAT-27` checks the other
half — that §3.3 still publishes seven rows and seven killers, that `LAW-C7` is
declared deferred, and that the remaining six match the suite in both
directions.

WHY THIS IS A FOURTH HARNESS RATHER THAN AN ARGUMENT TO THE FLOOR GATE
---------------------------------------------------------------------
The FLOOR GATE was renamed rather than copied when PLAT-25 needed it, because it
is one parser over one grammar and a second copy would be a second place for the
grammar to drift. A mutation harness is the other shape: its content is almost
entirely the arms, which are per-milestone by construction, and its machinery is
forty lines of byte-level file IO. PLAT-24, PLAT-25 and PLAT-26 each carry their
own for that reason and this follows the precedent. What IS shared, and
deliberately identical, is the four-verdict vocabulary, the §32f byte IO, the
signal-restoring handler and the §10.3 count rule — copied with their reasons
attached so a reader of this file does not have to find the other three.

WHY IT REACHES THE SUITE AND THE GENERATOR
------------------------------------------
TEN of the twenty-two arms mutate the HARNESS rather than the product, and that
is deliberate. This campaign's recurring defect is a gate that cannot fail, and
this milestone's own population arrived carrying it: **of the 72 cells §6
declares, 35 have no wrapped line and six documents never wrap at any declared
column**, so a third of the corpus satisfied every coordinate law by not
exercising the subject at all. That is a property of the POPULATION, so the only
way to show it is now armed is to break the population and require it to notice:

  G1  the witness column goes back to being wider than every line, so nothing
      wraps — §34's exact trap, performed
  G2  the classifier stops discriminating, so the histogram is the generator
      agreeing with itself (§34's third rule)
  G3  the fifth column is dropped and the population is the declared matrix
      again
  G4  the directory enumeration matches nothing (§35)
  G5  the law's OWN canonicalisation derivation stops skipping zero-width
      clusters, so the oracle and the subject part company
  G6  THE DIFFERENTIAL BECOMES A SELF-COMPARISON (§30). `DIFF-2`'s other side
      returns the model's own rows. It was AIMED at the negative half — the
      case asserting the two producers DISAGREE about tabs — and it SURVIVED
      there: all thirty-six cells stay green and so does the negative half,
      because the replacement is a correct re-derivation of the widget's
      algorithm. What notices is a claim about the PRODUCER, not the answer: a
      source scan over `terminalRowSpans`'s own body. Traps §30a
  G7  the forward sweep iterates nothing, and every law over it is vacuous
  G8  the reverse sweep calls every display column a cluster boundary — the
      model §6 names explicitly as one that would pass the round trip and be
      wrong about the thing the round trip exists to check
  G9  the fuzz stream stops after one step
  G10 the renderer-import scan's spelling list is emptied, so the risk PLAT-27
      names has a gate that cannot fire

FOUR VERDICTS, NOT TWO (Verification-Harness-Traps.md §1). An arm that never ran
is not a kill:

  killed           the named case reported [FAILED]
  SURVIVED         the run produced result lines and the named case was [OK]
  MISDIRECTED      something else went red and the named case did not
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all
  HUNG             no result inside the timeout — its own outcome, not a pass

RESTORATION IS FROM A VERIFIED SNAPSHOT, never from `git checkout --`: the
original bytes are read into memory before the mutation and written back after,
and the SHA-256 of every touched file is compared against the control digest
before the next arm starts. §32i is the reason the alternative is not available
at all here — `git checkout -- <path>` on a file that was only `git add -N`'d
restores the EMPTY index blob and truncates it, which is how a recovery becomes
a data loss. **Every read and every write is bytes** (§32f).

THE NEEDLE SCAN (§32). An arm whose `find` text a later repair moved is silently
unkillable: it reports HARNESS-FAILURE only when it is RUN, and nothing runs it
if the suite is green. `--needle-scan` checks every arm's needle occurs exactly
once WITHOUT compiling anything, in about a second, and must be run BEFORE the
control digests are re-recorded.

Usage (from the repository root):
  python3 src/frontend/viewmodel/tests/unit/run-plat27-coordinate-mutations.py
  python3 .../run-plat27-coordinate-mutations.py --needle-scan
  python3 .../run-plat27-coordinate-mutations.py --enumerate-touched
  python3 .../run-plat27-coordinate-mutations.py --record-control-hashes
  python3 .../run-plat27-coordinate-mutations.py --only=M1,G1
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
WRAP = "src/frontend/viewmodel/editor/wrap.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/wrap_generator.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_wrap_laws.nim"
EX = "src/frontend/viewmodel/tests/unit/test_editor_wrap_examples.nim"

TOUCHED = [WRAP, GENERATOR, LAWS, EX]

CONTROL_HASHES = HERE / "plat27-coordinate-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P27_SUITE_TIMEOUT", "1200"))
LAWS_BIN = os.environ.get("CT_P27_LAWS_BIN", "/tmp/plat27-mutation-laws")
EX_BIN = os.environ.get("CT_P27_EX_BIN", "/tmp/plat27-mutation-examples")

# BOTH SUITES RUN FOR EVERY ARM, and that is deliberate rather than thorough.
# They share `wrap.nim`, so an arm on `toLogical` can redden either; running
# only the suite an arm "belongs to" would be the harness deciding in advance
# which case is allowed to notice, which is the MISDIRECTED verdict's whole
# point made unavailable.
SUITES = [(LAWS, LAWS_BIN), (EX, EX_BIN)]

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not run
# this case" rather than as a silently unkillable arm.
#
# Three families of name are COMPOSED at run time and the scan checks the halves
# rather than searching for the whole string:
#   `bijection: <docId> x w=<col>`     from the population loop
#   `LAW-C5 x <doc> / <policy>`        from the width-policy sweep
#   `display motion: <op> x w=<col>`   from the motion sweep
# ---------------------------------------------------------------------------

L_C1 = "LAW-C1"
L_C2 = "LAW-C2"
L_C3 = "LAW-C3"
L_C4 = "LAW-C4"
L_C5 = "LAW-C5"
L_C6 = "LAW-C6"

BIJ_CJK = "bijection: c5-cjk-long x w=20"
BIJ_TABS = "bijection: c8-tabs-short x w=20"
C5_AMB = "LAW-C5 x c4-ambiguous-long / awWide"
C6_TABS = "LAW-C6 x c8-tabs-long"
DIFF_CJK = "DIFF-2 x c5-cjk-long x w=20"
TAB_MATRIX = "tab matrix: c8-tabs-short x tab=2 x w=20"
MOTION_END = "display motion: dispRowEnd/formMove x w=8"
MOTION_DOWN = "display motion: dispRowDown/formMove x w=8"

C_POP = ("the declared cross product, its realised classes, and the six "
         "documents it left unwrapped")
C_WITNESS = ("every corpus document witnesses the wrapped, boundary and "
             "multi-row classes")
C_DERIVED = ("the witness column is DERIVED from the document and is not one "
             "of the declared four")
C_DIFFNEG = ("DIFF-2 runs at tabSize 0 because the two producers DISAGREE "
             "about tabs — the negative half")
C_SCAN_DIR = ("the scan's subject list is the directory, not a list somebody "
              "maintains")
C_SCAN_RENDER = ("NO MODULE OF THE CORE REACHES A RENDERER — the dependency "
                 "does not invert")
C_CLAMP = "NO CLAMP REPAIRS A COORDINATE — the out-of-range paths RAISE"
C_CANON = "`columnCanonical` and the law's own derivation agree, over the corpus"
C_PRODUCER = "DIFF-2's OTHER SIDE IS THE WIDGET, not a second call to the model"
C_FUZZMOVED = "the fuzz stream really moved rows, and the cache was really spliced"
C_LADDER = ("THE GOAL COLUMN IS A COLUMN AND NOT A CLUSTER INDEX, over a "
            "wrapped ladder")
C_PROJ = ("TWO PROJECTIONS OF ONE DOCUMENT AT TWO WIDTHS COEXIST — the "
          "§5-vs-§9 decision, executable")

X_BOUNDARY = "A POSITION AT A WRAP BOUNDARY IS THE START OF THE FOLLOWING ROW"
X_WIDE = ("A CLUSTER WIDER THAN THE WRAP COLUMN OCCUPIES A ROW ALONE AND "
          "OVERFLOWS IT")
X_STALE = ("THE COST, PINNED: a cache handed another document RAISES rather "
           "than repairing")
X_DOLLAR = ("SCREEN-LINE `$` LANDS ON THE LAST CHARACTER OF A CONTINUING ROW, "
            "NOT PAST IT")
X_TABGRID = ("THE TAB STOP GRID IS THE LOGICAL LINE'S, AND WRAPPING PARTITIONS "
             "THE CELLS")
X_ZEROWIDTH = ("A ZERO-WIDTH CLUSTER SHARES ITS COLUMN, WHICH IS WHY `LAW-C1` "
               "IS NOT AN IDENTITY")

NAMED_CASES = [
    L_C1, L_C2, L_C3, L_C4, L_C5, L_C6,
    BIJ_CJK, BIJ_TABS, C5_AMB, C6_TABS, DIFF_CJK, TAB_MATRIX,
    MOTION_END, MOTION_DOWN,
    C_POP, C_WITNESS, C_DERIVED, C_DIFFNEG, C_SCAN_DIR, C_SCAN_RENDER,
    C_CLAMP, C_CANON, C_PRODUCER, C_FUZZMOVED, C_LADDER, C_PROJ,
    X_BOUNDARY, X_WIDE, X_STALE, X_DOLLAR, X_TABGRID, X_ZEROWIDTH,
]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    law: str = ""       # §3.3's own killer wording, where the arm performs one
    law_id: str = ""    # which LAW-C* it performs, stated rather than parsed


ARMS = [
    # =======================================================================
    # THE SIX LAW KILLERS, §3.3's column applied
    # =======================================================================
    Arm(
        "M1", WRAP,
        "  if i < 0: m.width else: m.clusters[i].column\n",
        "  if i < 0: m.width\n"
        "  else: m.clusters[i].column + (byteInLine - m.clusters[i].startByte)\n",
        L_C1,
        "THE DISPLAY COLUMN IS ROUNDED TO A CELL INSTEAD OF A CLUSTER — one "
        "cell per BYTE inside the cluster instead of the cluster's own column. "
        "A three-byte CJK ideograph occupies two cells, so its third byte "
        "reports a column the cluster does not cover, the return leg resolves "
        "that column to the FOLLOWING cluster, and the round trip lands one "
        "cluster on. **It is invisible at cluster boundaries**, which is why "
        "`LAW-C1` is quantified over EVERY BYTE and not over boundaries: a law "
        "that swept boundaries only would be green under it, and so are "
        "`LAW-C2`, `LAW-C3` and `LAW-C4`, which never ask about an interior "
        "byte.\n\n"
        "        A FIRST SPELLING OF THIS ARM SURVIVED, and it is worth the "
        "sentence: rounding to the cluster's SECOND cell moves the column into "
        "a cell the same cluster still covers, so the return leg comes back to "
        "the same cluster and the round trip is unchanged. An arm on a "
        "coordinate has to move the value OUT of the cluster's own span to be "
        "observable at all",
        law="round the display column to a cell instead of a cluster",
        law_id="LAW-C1",
    ),
    Arm(
        "M2", WRAP,
        "      return textPos(r.line, cl.startByte)\n",
        "      return textPos(r.line, cl.stopByte)\n",
        L_C2,
        "A DISPLAY COLUMN RESOLVES TO THE END OF THE CLUSTER CONTAINING IT "
        "RATHER THAN ITS START, so the return leg reports the FOLLOWING "
        "cluster's column. Note what stays true under it: the map is still "
        "total, still monotone, still lands on a cluster boundary, and the "
        "rows are untouched — only the round trip moves, which is why `LAW-C2` "
        "is a law of its own rather than a clause of `LAW-C1`",
        law="resolve a display column to the end of the cluster containing it "
            "rather than its start, so the return leg reports the following "
            "cluster's column",
        law_id="LAW-C2",
    ),
    Arm(
        "M3", WRAP,
        "  result.add DisplayRow(line: line, startByte: startByte, endByte: m.byteLen,\n"
        "                        startColumn: startColumn, width: cells)\n",
        "  result.add DisplayRow(line: line, startByte: startByte, endByte: m.byteLen,\n"
        "                        startColumn: startColumn, width: cells)\n"
        "  if result.len > 1:\n"
        "    var rev: seq[DisplayRow] = @[]\n"
        "    for k in countdown(result.len - 1, 0): rev.add result[k]\n"
        "    result = rev\n",
        L_C3,
        "A LINE'S ROWS COME BACK IN THE WRONG ORDER. The SET of rows is "
        "unchanged — every byte of the line is still covered exactly once — so "
        "a law that only asked whether the rows partition the document would "
        "be satisfied. What moves is the correspondence between logical order "
        "and display order, which is the only thing `LAW-C3` is about",
        law="wrap a line's rows in the wrong order",
        law_id="LAW-C3",
    ),
    Arm(
        "M4", WRAP,
        "    cells = m.width\n"
        "  # The tail row",
        "    cells = m.width\n"
        "  if wrapColumn > 0 and result.len > 0: return\n"
        "  # The tail row",
        L_C4,
        "THE LAST ROW OF A WRAPPED LINE IS DROPPED. An unwrapped line keeps "
        "its only row, so the row count falls by exactly the number of wrapped "
        "lines and every structural check that counts rows against lines still "
        "passes. What notices is the concatenation: the document comes back "
        "short",
        law="drop the last row of a wrapped line",
        law_id="LAW-C4",
    ),
    Arm(
        "M5", WRAP,
        "    clusterDisplayWidth(cluster, policy.ambiguous)\n",
        "    clusterDisplayWidth(cluster, awNarrow)\n",
        C5_AMB,
        "THE WIDTH PARAMETER IS IGNORED. §3.3 says of this killer that it "
        "*'kills only the first half — which is why the second half exists'*, "
        "and that is exactly what happens: every class-9 cell stays green "
        "because an ASCII control document answers the same at both policies, "
        "and the class-4 cells go red because an ambiguous-width document must "
        "not. The named case is an `awWide` cell of `c4-ambiguous-long`",
        law="ignore the parameter",
        law_id="LAW-C5",
    ),
    Arm(
        "M6", WRAP,
        "  let firstLine = lineOfOffset(oldDoc, loA)\n",
        "  let firstLine = lineOfOffset(oldDoc, loA) + 1\n",
        C6_TABS,
        "INVALIDATION SKIPS THE REGION ABOVE THE EDIT. The recomputed span now "
        "starts at the edit's LAST line rather than its first, so an edit "
        "inside a line leaves that line's earlier rows stale — and 'the region "
        "above the edit' is precisely the part of the edit's own line that "
        "precedes it. Every edit that happens to start a line survives it, "
        "which is why the arm needs a stream rather than an example",
        law="skip invalidation for a region above the edit",
        law_id="LAW-C6",
    ),

    # =======================================================================
    # SIX MORE ON THE PRODUCT — properties no LAW-C* row names
    # =======================================================================
    Arm(
        "M7", WRAP,
        "    ((atColumn div policy.tabSize) + 1) * policy.tabSize - atColumn\n",
        "    policy.tabSize\n",
        TAB_MATRIX,
        "A TAB ADVANCES BY THE TAB SIZE INSTEAD OF TO THE NEXT TAB STOP. The "
        "two agree whenever the column is already a multiple of the tab size, "
        "which is why the killer is the CORPUS-WIDE oracle against PLAT-26's "
        "independently-derived `columnAt` and not a hand-written example.\n\n"
        "        THE CELL IS `tab=2` AND THAT IS NOT ARBITRARY: at `tab=8` the "
        "long document's tabs sit at columns that are already multiples of 8 "
        "often enough for the cell to stay green, so naming it would have made "
        "the arm a coin flip on the corpus's indentation. Measured — the first "
        "spelling named `c8-tabs-long x tab=8` and reported MISDIRECTED",
    ),
    Arm(
        "M8", WRAP,
        "  if c.isLastRowOfLine(row): return r.width\n",
        "  return r.width\n",
        MOTION_END,
        "SCREEN-LINE `$` RETURNS THE ROW'S WIDTH ON EVERY ROW. On a CONTINUING "
        "row that position is the same point as column 0 of the NEXT row, so "
        "`g$` reports the following row. **This is the defect the milestone "
        "actually shipped and then found by running the sweep**, which is why "
        "it is an arm: the first implementation returned the width "
        "unconditionally and nine of the twelve motion cells went red",
    ),
    Arm(
        "M9", WRAP,
        "    (ctx.offsetOfDisplay(DisplayPos(row: target, column: col)), some(goal))\n",
        "    (ctx.offsetOfDisplay(DisplayPos(row: target, column: col)), some(col))\n",
        C_LADDER,
        "THE GOAL IS RECOMPUTED FROM THE LANDED COLUMN — `LAW-S5`'s published "
        "killer, re-performed in display space, because a goal column that is "
        "a DISPLAY column is this milestone's deliverable rather than "
        "PLAT-26's. On a ladder of alternating wide and narrow rows the column "
        "collapses on the first step and never comes back",
    ),
    Arm(
        "M10", WRAP,
        "  if doc.len != c.docLen:\n",
        "  if false and doc.len != c.docLen:\n",
        X_STALE,
        "THE STALE-CACHE GUARD STOPS RAISING. §36a: a guard that repairs "
        "silently cannot be told from one that never fires, and here the "
        "'repair' is answering about the wrong document. The cost of the "
        "decision at the top of `wrap.nim` — a projection per renderer means "
        "an invalidation per renderer — is priced on this guard existing",
    ),
    Arm(
        "M11", WRAP,
        "    if col < rs[k].startColumn + rs[k].width:\n",
        "    if col <= rs[k].startColumn + rs[k].width:\n",
        X_BOUNDARY,
        "A POSITION AT A WRAP BOUNDARY RESOLVES TO THE END OF THE PRECEDING "
        "ROW instead of the start of the following one. Both answers name the "
        "same point, so nothing about the document changes; what changes is "
        "which of the two the caret is painted at, and the end-of-row position "
        "of a continuing row is the one the coordinate model declares "
        "non-canonical",
    ),
    Arm(
        "M12", WRAP,
        "      if cells > 0 and cells + c.cells > wrapColumn:\n",
        "      if cells + c.cells > wrapColumn:\n",
        X_WIDE,
        "A CLUSTER WIDER THAN THE WRAP COLUMN IS PUSHED ONTO AN EMPTY ROW AND "
        "THEN ONTO ANOTHER ONE, forever — the loop emits a zero-width row "
        "before every over-wide cluster. It is the failure mode the `cells > "
        "0` guard exists for, and it is the closest a greedy wrapper gets to "
        "'split the cluster' without doing it",
    ),

    # =======================================================================
    # THE POPULATION AND THE SUITES' OWN MACHINERY — §34, §35, §30, §4
    # =======================================================================
    Arm(
        "G1", GENERATOR,
        "  max(2, c.widestLine div WitnessDivisor)\n",
        "  max(2, c.widestLine * 4)\n",
        C_WITNESS,
        "**§34's TRAP, PERFORMED.** The witness column becomes wider than every "
        "line, so no document wraps at it and the population is the declared "
        "matrix again — under which six of the eighteen corpus documents never "
        "wrap at any column and every coordinate law is trivially true for "
        "them. EVERY LAW STAYS GREEN. What notices is the per-document class "
        "assertion, which is the whole reason it is written as one",
    ),
    Arm(
        "G2", GENERATOR,
        "      result.incl wcWrapped\n",
        "      result.incl wcWrapped\n"
        "    result.incl {wcWrapped, wcExactBoundary, wcMultiRow}\n",
        C_POP,
        "THE CLASSIFIER STOPS DISCRIMINATING and reports every class for every "
        "cell. §34's third rule: a histogram built from a classifier that "
        "agrees with everything is the generator agreeing with itself, and the "
        "only thing that can see it is the per-class EQUALITY — non-emptiness "
        "passes under this arm",
    ),
    Arm(
        "G3", GENERATOR,
        "    for col in columnsFor(base):\n",
        "    for col in WrapMatrix:\n",
        C_POP,
        "THE FIFTH COLUMN IS DROPPED and the population is §6's declared cross "
        "product exactly. This is the state the milestone STARTED in, and it "
        "is kept as an arm rather than as a paragraph: 72 cells, 35 of them "
        "with nothing wrapped, and a bijection asserted over documents whose "
        "display rows are their logical lines",
    ),
    Arm(
        "G4", LAWS,
        '    if kind == pcFile and path.endsWith(".nim"):\n',
        '    if kind == pcFile and path.endsWith(".nimx"):\n',
        C_SCAN_DIR,
        "THE DIRECTORY ENUMERATION MATCHES NOTHING — §35's own arm, which is "
        "one character in the extension it filters on. A lister that matches "
        "nothing satisfies 'the set is exactly these eight' by leaving nothing "
        "to disagree with it",
    ),
    Arm(
        "G5", LAWS,
        "    result[i] = if m.clusters[i].cells > 0: m.clusters[i].startByte\n"
        "                else: result[i + 1]\n",
        "    result[i] = m.clusters[i].startByte\n",
        C_CANON,
        "THE LAW'S OWN CANONICALISATION STOPS SKIPPING ZERO-WIDTH CLUSTERS, so "
        "the suite's oracle and the module's `columnCanonical` part company on "
        "the 33,465 positions the milestone's §3.3a note is about. The case "
        "that compares the two derivations is what notices — and the reason "
        "there ARE two derivations is §32a: one predicate feeding both would "
        "let a single edit disarm the law and the check on it together",
    ),
    Arm(
        "G6", GENERATOR,
        "  let t = tui.TextAreaWidget(lines: ls, width: wrapColumn, softWrap: true,\n"
        "                             tabSize: 4)\n"
        "  for r in tui.allDisplayRows(t):\n"
        "    result.add (r.lineIndex, r.startCluster, r.endCluster)\n",
        "  let c = initWrapCache(doc, wrapSettings(wrapColumn, TabsAsClusters, awNarrow))\n"
        "  for i in 0 ..< c.rowCount:\n"
        "    let r = c.rowAt(i)\n"
        "    let m = c.metricsOf(r.line)\n"
        "    result.add (r.line, clusterIndexOfByte(m, r.startByte),\n"
        "                clusterIndexOfByte(m, r.endByte))\n",
        C_PRODUCER,
        "**THE DIFFERENTIAL BECOMES A SELF-COMPARISON** (§30). `DIFF-2`'s "
        "other side stops being `isonim-tui` and becomes the model at the "
        "widget's own tab policy.\n\n"
        "        IT WAS FIRST AIMED AT THE NEGATIVE HALF AND IT SURVIVED, "
        "which is the finding worth keeping. All thirty-six `DIFF-2` cells "
        "stay green — they pass HARDER — and so does the case asserting the "
        "two producers DISAGREE about tabs, because a model at `tabSize = 0` "
        "disagrees with a model at `tabSize = 4` about tabs exactly as the "
        "widget does. The replacement is a CORRECT re-derivation of the "
        "widget's algorithm (§30a's 'a whole re-derived module'), and no "
        "assertion about the ANSWER can distinguish a correct re-derivation "
        "from the original.\n\n"
        "        What notices is a claim about the PRODUCER: a source scan "
        "over `terminalRowSpans`'s own body, requiring it to reach "
        "`tui.allDisplayRows` and to reach nothing of this milestone's "
        "projection. It is the one arm whose kill nothing about the product "
        "could have established, which is PLAT-26's `G14` in a second shape",
    ),
    Arm(
        "G7", LAWS,
        "    var ci = 0\n"
        "    for b in 0 .. m.byteLen:\n",
        "    var ci = 0\n"
        "    for b in 0 ..< 0:\n",
        L_C1,
        "THE FORWARD SWEEP ITERATES NOTHING. Every law quantified over it is "
        "then quantified over the empty set and holds. §4, and the reason the "
        "position count is ASSERTED rather than merely printed: without that "
        "assertion this arm is a clean survival",
    ),
    Arm(
        "G8", LAWS,
        "        let isBoundary = columnOfByte(m, p.column) == r.startColumn + col\n",
        "        let isBoundary = true\n",
        L_C2,
        "EVERY DISPLAY COLUMN IS CALLED A CLUSTER BOUNDARY — the model §6 names "
        "by hand as one that *'would pass the round trip and be wrong about the "
        "thing it exists to check'*. The round trips that then run include the "
        "interior cells of wide clusters, so this one DOES also redden them; "
        "what makes it an arm rather than a coincidence is that the "
        "cluster-boundary COUNT is asserted as an equality against an "
        "arithmetic derivation, and that equality fails first",
    ),
    Arm(
        "G9", LAWS,
        "      for step in 0 ..< 20:\n"
        "        let cs = genSimple(doc, r, 2)\n"
        "        if cs.isIdentity: continue\n"
        "        let newDoc = cs.apply(doc)\n"
        "        let before = (c.rowCount, c.lineCount)\n",
        "      for step in 0 ..< 1:\n"
        "        let cs = genSimple(doc, r, 2)\n"
        "        if cs.isIdentity: continue\n"
        "        let newDoc = cs.apply(doc)\n"
        "        let before = (c.rowCount, c.lineCount)\n",
        C_FUZZMOVED,
        "THE FUZZ STREAM STOPS AFTER ONE STEP, so the cache is never asked to "
        "splice on top of a splice. `FUZZ-6`'s whole subject is accumulated "
        "staleness and a one-step stream cannot accumulate any",
    ),
    Arm(
        "G10", LAWS,
        '                           "isonim_gpui", "karax", "std/dom"]\n',
        '                           ]\n',
        C_SCAN_RENDER,
        "THE RENDERER-IMPORT SCAN'S SPELLING LIST IS TRUNCATED, from seven "
        "spellings to four — the three it drops are `isonim_gpui`, `karax` and "
        "`std/dom`, which are every non-terminal renderer the list names. "
        "PLAT-27's named risk is *'the model answers display questions by "
        "asking the renderer, and the dependency inverts without anyone "
        "noticing'*; its stated mitigation is PLAT-29's import-closure check, "
        "which has not landed, so this scan is the only gate the risk has. A "
        "scan over a SHORTENED subject list still runs and still passes, which "
        "is why the non-vacuity assertion is an EQUALITY on the length "
        "(`RendererSpellings.len == 7`) rather than `> 0`: `> 0` would have "
        "survived this (§4)",
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
# `path.write_text(original)` then writes a DIFFERENT file back — in the RESTORE
# path, where nothing looks, and the digest check afterwards passes because the
# baseline came through the same lossy door. PLAT-24's harness was found doing
# exactly this when a Unicode corpus joined its subject set, and THIS
# milestone's suites embed `\r` in their own source (`"ab\r\ncd"` and the CRLF
# example), so the door is open here too.
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
            # mutated projection can print them, and a UnicodeDecodeError in the
            # READER would abort the harness mid-arm with a file still mutated
            # on disk.
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

    Editor-Model-Conformance-Suite.md §10.3 applies Verification-Harness-Traps
    §32 to the one class of needle that is GUARANTEED to move: a count changes
    every time a test is added, which is the most frequent edit a suite
    receives.
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
    silent way a moved needle does. Three of this suite's name families are
    COMPOSED at run time, so a literal search would report every one of them
    missing — a scan that is wrong in the noisy direction. Each half is checked
    instead.
    """
    laws = read_source(LAWS)
    ex = read_source(EX)
    gen = read_source(GENERATOR)
    both = laws + "\n" + ex

    templates = [
        ('test "bijection: " & cell.docId & " x w=" & $cell.column:', laws,
         "THE BIJECTION CELL TEMPLATE"),
        ('test "LAW-C5 x " & id & " / " & $policy:', laws,
         "THE WIDTH-POLICY CELL TEMPLATE"),
        ('test "LAW-C6 x " & id:', laws, "THE CACHE CELL TEMPLATE"),
        ('test "DIFF-2 x " & id & " x w=" & $w:', laws,
         "THE DIFFERENTIAL CELL TEMPLATE"),
        ('test "display motion: " & $op & " x w=" & $w:', laws,
         "THE MOTION CELL TEMPLATE"),
        ('test "tab matrix: " & id & " x tab=" & $tab & " x w=" & $w:', laws,
         "THE TAB-MATRIX CELL TEMPLATE"),
    ]
    for needle, text, label in templates:
        if needle not in text:
            print(f"{label} IS NOT IN THE SUITE")
            problems += 1

    for name in NAMED_CASES:
        if name.startswith("bijection: "):
            doc = name[len("bijection: "):].split(" x w=")[0]
            if f'"{doc}"' not in gen and doc not in read_source(
                    "src/frontend/viewmodel/tests/corpus/unicode_corpus.nim"):
                print(f"KILLER CORPUS DOCUMENT NOT DECLARED: {doc!r}")
                problems += 1
        elif name.startswith(("LAW-C5 x ", "LAW-C6 x ", "DIFF-2 x ",
                              "display motion: ", "tab matrix: ")):
            pass    # composed from an enum or the corpus; the halves are above
        elif name.startswith("LAW-C"):
            if f'"{name}"' not in laws:
                print(f"KILLER LAW ID NOT DECLARED: {name!r}")
                problems += 1
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

    # ALL SIX OF §3.3's NON-DEFERRED KILLERS ARE PERFORMED, two-sidedly.
    #
    # `an arm with no stated killer is not admitted` is the rule about the
    # TABLE; this is the rule about the HARNESS. `LAW-C7` is published and
    # belongs to PLAT-28, and the floor gate is where that deferral is checked
    # against the spec; here it is simply not expected.
    performed = set()
    for arm in ARMS:
        if not arm.law:
            continue
        if not arm.law_id.startswith("LAW-C"):
            print(f"{arm.id}: quotes a §3.3 killer but declares law_id "
                  f"{arm.law_id!r}")
            problems += 1
            continue
        performed.add(arm.law_id)
    expected = {f"LAW-C{i}" for i in range(1, 7)}
    if performed != expected:
        print(f"§3.3 KILLERS NOT PERFORMED BY ANY ARM: "
              f"{sorted(expected - performed)}")
        print(f"ARMS CLAIMING A LAW THAT IS NOT PUBLISHED HERE: "
              f"{sorted(performed - expected)}")
        problems += 1
    else:
        print(f"all {len(expected)} of §3.3's non-deferred killers are "
              f"performed by an arm")

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
    # **ITS VERDICT IS ACTED ON, NOT PRINTED.** This call used to discard the
    # bool it returns, which made the one check standing between "the tree is
    # the reviewed tree" and "the tree is whatever a previous run left behind"
    # a gate that could not fail — §4's own shape, inside the harness that
    # exists to find it. It matters because `baseline` below is snapshotted
    # from the CURRENT tree: without this refusal a run started on an
    # already-mutated file restores to the mutation and reports itself clean.
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
