#!/usr/bin/env python3
"""PLAT-25's mutation harness — proof that the edit-algebra suite can go red.

`test_editor_change_algebra.nim` claims that ten laws, a generator and a
source scan each detect something. This script proves it one case at a time:
it patches a single passage of a SUBJECT — the algebra, the transaction, the
generator, or the suites' own non-vacuity machinery — and requires the
**named** case to fail. A mutation killed only by some other case is
MISDIRECTED and is a failure of this harness, not a pass.

**TEN OF THE ARMS ARE §3.1's OWN KILLER COLUMN, APPLIED.** Every `LAW-A*` row
in Editor-Model-Conformance-Suite.md §3.1 names the mutation that must kill
it, and *"an arm with no stated killer is not admitted"*. The `law` field
below carries the row's wording verbatim beside the patch that performs it, so
a reader can check the arm against the published table rather than against
this file's own description of it. `ci/test/editor-model-case-floor.sh` checks
the other half — that the table still publishes ten rows and ten killers.

WHY IT REACHES THE SUITE AND THE GENERATOR
------------------------------------------
TWELVE of the twenty-six arms mutate the HARNESS rather than the product —
`M7`, `G1` … `G7` and `G9` … `G12` — and that is deliberate. This campaign's
recurring defect is a gate that cannot fail: a generator that produced
nothing, a population assertion over an empty set, a scanner whose sweep found
nothing, an oracle that had become a second call to the thing under test.
Those are properties of the HARNESS, so the only way to show they are armed is
to break the harness and require it to notice:

  M7  the functoriality check applies the second mapping to the pre-first
      offset — §3.1's own killer for `LAW-A6`, which has nowhere else to live
      because `compose` + `mapPos` IS the implementation
  G1  the shared position budget collapses to one point
  G2  THE PAIR GENERATOR BECOMES TWO INDEPENDENT DRAWS — §4.1's named defect,
      performed. `LAW-A1` is trivially true on disjoint pairs, so this is the
      one arm that decides whether ten thousand pairs are evidence
  G3  the class witness stops discriminating, so a `c7-illformed` window with
      no ill-formed byte in it passes for class 7
  G4  a law cell draws nothing, and every law over it is vacuously satisfied
  G5  the gate draws a tenth of the pairs it says it does
  G6  the fuzz stream stops after one step
  G7  the source scan matches nothing
  G9  the shrinker returns its input
  G10 `LAW-A10`'s oracle stops being independent of `mapPos`
  G11 the typed-mapping sweep examines a document of no positions
  G12 a pinned finding is edited to claim its own opposite

`G8` is the thirteenth and belongs with them in spirit while mutating the
product: it adds A SIXTH MODULE HAND-WRITING THE DOUBLE MAPPING — this
milestone's own stated risk, performed — and what must notice it is the source
scan rather than any law.

FOUR VERDICTS, NOT TWO (Verification-Harness-Traps.md §1). An arm that never
ran is not a kill:

  killed           the named case reported [FAILED]
  SURVIVED         the run produced result lines and the named case was [OK]
  MISDIRECTED      something else went red and the named case did not
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all

RESTORATION IS FROM A VERIFIED SNAPSHOT, never from `git checkout --`: the
original bytes are read into memory before the mutation and written back
after, and the SHA-256 of every touched file is compared against the control
digest before the next arm starts. **Every read and every write is bytes**
(§32f): `Path.read_text()` applies universal-newline translation, and a
harness that restores through it rewrites its own subjects in the one code
path nobody reviews.

THE NEEDLE SCAN (§32). An arm whose `find` text a later repair moved is
silently unkillable: it reports HARNESS-FAILURE only when it is RUN, and
nothing runs it if the suite is green. `--needle-scan` checks every arm's
needle occurs exactly once WITHOUT compiling anything, in about a second, and
must be run BEFORE the control digests are re-recorded.

Usage (from the repository root):
  python3 src/frontend/viewmodel/tests/unit/run-plat25-change-algebra-mutations.py
  python3 .../run-plat25-change-algebra-mutations.py --needle-scan
  python3 .../run-plat25-change-algebra-mutations.py --enumerate-touched
  python3 .../run-plat25-change-algebra-mutations.py --record-control-hashes
  python3 .../run-plat25-change-algebra-mutations.py --only=M1,G2
"""

from __future__ import annotations

import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]            # .../codetracer

# -- subjects ---------------------------------------------------------------
CHANGESET = "src/frontend/viewmodel/editor/change_set.nim"
TRANSACTION = "src/frontend/viewmodel/editor/transaction.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/change_generator.nim"
ALG = "src/frontend/viewmodel/tests/unit/test_editor_change_algebra.nim"
EX = "src/frontend/viewmodel/tests/unit/test_editor_change_examples.nim"

# PLAT-33: the scan in ALG sweeps EVERY production module under
# `viewmodel/`, so a cross-directory call site is a subject of this
# harness. `collab/text_ops.nim` is the module that sat outside the old
# `editor/`-only subject set, which is why G15 plants its call there.
TEXTOPS = "src/frontend/viewmodel/collab/text_ops.nim"

TOUCHED = [CHANGESET, TRANSACTION, GENERATOR, ALG, EX, TEXTOPS]

CONTROL_HASHES = HERE / "plat25-change-algebra-mutation-control.sha256"

# A SUITE THAT NEVER FINISHES IS ITS OWN VERDICT, NOT A LONG PASS
# ---------------------------------------------------------------
# Verification-Harness-Traps §1: *a hang arm is one whose rc is 124 and nothing
# else*. This is that rule applied on the way IN rather than on the way out,
# and it is here because an arm on this subject did hang: stepping `compose`
# by a section's OLD extent where its NEW one belongs makes the iterator stop
# advancing on a pure insertion, and the suite spins. With the default
# one-hour timeout the harness sat on it for eleven minutes before it was
# killed by hand, and the kill — which is a SIGTERM to this process, not to
# the child — skipped the `finally` that restores the subject and left a
# mutated `change_set.nim` on disk. The control digest file is what found it.
#
# Two changes came out of that and both are below: a timeout short enough that
# a hang is a minute's news rather than an hour's, and a signal handler so
# that a SIGTERM restores the subject on its way out. SIGKILL still cannot,
# which is the other reason the digests are recorded.
SUITE_TIMEOUT = int(os.environ.get("CT_P25_SUITE_TIMEOUT", "900"))
ALG_BIN = os.environ.get("CT_P25_ALG_BIN", "/tmp/plat25-mutation-algebra")
EX_BIN = os.environ.get("CT_P25_EX_BIN", "/tmp/plat25-mutation-examples")

# BOTH SUITES RUN FOR EVERY ARM, and that is deliberate rather than thorough.
# They share `change_set.nim`, so an arm on `compose` can redden either;
# running only the suite an arm "belongs to" would be the harness deciding in
# advance which case is allowed to notice, which is the MISDIRECTED verdict's
# whole point made unavailable.
SUITES = [(ALG, ALG_BIN), (EX, EX_BIN)]

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# Three families of name are COMPOSED at run time and the scan checks both
# halves of each rather than searching for the whole string:
#   `<LAW-An> x <clsFoo>`      from `LawName[law] & " x " & $cls`
#   `FUZZ-1 x <clsFoo>`        from `"FUZZ-1 x " & $cls`
#   `typed mapping: <...>`     from `$shape & " / " & $side & " / " & $arm`
# ---------------------------------------------------------------------------

L_A1_TOUCH = "LAW-A1 x clsTouchingPoint"
L_A1_OVER = "LAW-A1 x clsOverlapping"
L_A2_TOUCH = "LAW-A2 x clsTouchingPoint"
L_A3_REPLACE = "LAW-A3 x clsReplace"
L_A4_REPLACE = "LAW-A4 x clsReplace"
L_A5_OVER = "LAW-A5 x clsOverlapping"
L_A6_OVER = "LAW-A6 x clsOverlapping"
L_A7_REPLACE = "LAW-A7 x clsReplace"
L_A8_REPLACE = "LAW-A8 x clsReplace"
L_A9_REPLACE = "LAW-A9 x clsReplace"
L_A10_DELETE = "LAW-A10 x clsPureDelete"

F_OVER = "FUZZ-1 x clsOverlapping"

C_HIST = "the seed, the case count and the realised histogram are printed and asserted"
C_REALISED = "every drawn pair realises the class it was drawn for"
C_WINDOWS = "every corpus window offers the boundaries a shared budget needs"
C_UNICODE = "the population is real Unicode, not ASCII wearing a corpus's name"
C_GATE = "THE IDENTITY, over 10,000 generated pairs from a stated distribution"
C_SCAN1 = "the flag-taking routine is private, declared once, and called twice"
C_SCAN2 = "no module anywhere in the ViewModel tree can spell the double mapping"
C_SHRINK = "a planted always-failing property shrinks to its known counterexample"
C_A2PIN = "LAW-A2: associativity holds as a mapping and NOT as a value"
C_A6POP = "the refinement excludes a real population, not an empty one"

X_ORDERED = "change sets are built from unordered, colliding edit lists"
X_MERGE = "mergeTransactions(concurrent) goes through the ONE primitive"
X_REVEAL = "a revealed range shrinks away from an insert at either edge"
X_TYPED = "typed mapping: esDelete / sideBefore / mapCollapsed"

NAMED_CASES = [
    L_A1_TOUCH, L_A1_OVER, L_A2_TOUCH, L_A3_REPLACE, L_A4_REPLACE, L_A5_OVER,
    L_A6_OVER, L_A7_REPLACE, L_A8_REPLACE, L_A9_REPLACE, L_A10_DELETE,
    F_OVER,
    C_HIST, C_REALISED, C_WINDOWS, C_UNICODE, C_GATE, C_SCAN1, C_SCAN2,
    C_SHRINK, C_A2PIN, C_A6POP,
    X_ORDERED, X_MERGE, X_REVEAL, X_TYPED,
]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    law: str = ""     # §3.1's own killer wording, where the arm performs one


ARMS = [
    # ================================================================== the
    # TEN LAW KILLERS, §3.1's column applied
    # =======================================================================
    Arm(
        "M1", CHANGESET,
        "  Rebased(aOverB: mapOver(a, b, before = true),\n",
        "  Rebased(aOverB: mapOver(a, b, before = false),\n",
        L_A1_TOUCH,
        "THE ARM THE MILESTONE EXISTS FOR. The flag is what is wrong when a "
        "hand-written copy is wrong, and it decides the answer only where the "
        "two change sets touch at a point — which is why the killer is the "
        "touching class and why the generator asserts that class non-empty",
        law="flip `before` in **one** of the primitive's two arms",
    ),
    Arm(
        "M2", CHANGESET,
        "          bOverA: mapOver(b, a, before = false))\n",
        "          bOverA: mapOver(b, a, before = true))\n",
        L_A1_TOUCH,
        "the OTHER arm of the same primitive. §3.1 says 'one of the "
        "primitive's two arms', and an arm that only ever flips the first one "
        "has tested one of them",
        law="flip `before` in **one** of the primitive's two arms",
    ),
    Arm(
        "M3", CHANGESET,
        "      open = (ia.ins > n or (ib.ins >= 0 and ib.len > n)) and\n"
        "             (open or builder.secs.len > before)\n",
        "      open = (ia.ins > n or (ib.ins >= 0 and ib.len > n))\n",
        L_A2_TOUCH,
        "the section merge in `compose` is reordered: a change is treated as "
        "still open across a section the builder did not actually push, so "
        "runs join that should have stayed apart. THE KILLER IS THE TOUCHING "
        "CLASS rather than the multi-section one, and the first run is how "
        "that was established: a reordered merge shows where two changed runs "
        "MEET, and multi-section pairs are separated by keeps by construction. "
        "Per-class running is what made the discriminating class visible",
        law="reorder the section merge in `compose`",
    ),
    Arm(
        "M4", CHANGESET,
        "  if n <= 0: return\n"
        "  if b.secs.len > 0 and b.secs[^1].kind == skKeep:\n",
        "  if n <= 0: return\n"
        "  if false and b.secs.len > 0 and b.secs[^1].kind == skKeep:\n",
        L_A3_REPLACE,
        "THE EMPTY-RUN COALESCING, DROPPED. Adjacent keeps stop merging, so "
        "`A . id` comes back with a section structure `A` never had. Every "
        "document it produces is still correct, which is the whole reason "
        "LAW-A3 is stated over VALUES",
        law="drop the empty-run coalescing so `A ∘ id` gains a zero-length section",
    ),
    Arm(
        "M5", CHANGESET,
        "      b.addReplace(s.insert.len, doc[pos ..< pos + s.delete])\n",
        "      b.addReplace(s.delete, doc[pos ..< pos + s.delete])\n",
        L_A4_REPLACE,
        "the inverse records the DELETED length where the INSERTED one "
        "belongs, so an inversion undoes the wrong number of bytes",
        law="record the inserted text's length instead of the deleted text",
    ),
    Arm(
        "M6", CHANGESET,
        "          builder.addReplace(n, (if ib.off > 0: \"\" else: ib.text), open)\n",
        "          builder.addReplace(n + 1, (if ib.off > 0: \"\" else: ib.text), open)\n",
        L_A5_OVER,
        "the composed section deletes one byte more than the two it is made "
        "of did — §3.1's 'any off-by-one in the composed section lengths', in "
        "the branch where an untouched run of `a` meets a change in `b`. "
        "THE OBVIOUS off-by-one here is NOT this one and is deliberately not "
        "used: stepping `compose` by `ia.len` where `ia.newExtent` belongs "
        "makes the iterator stop advancing on a pure insertion and the suite "
        "HANGS rather than reddens. An arm whose signal is 'the run never "
        "finished' has told you nothing about which case noticed "
        "(Verification-Harness-Traps §1), so the arm was moved to an "
        "off-by-one that produces a wrong ANSWER. The hang is still reachable "
        "by a future repair, which is why this harness now times a suite out "
        "and reports HUNG rather than waiting an hour",
        law="any off-by-one in the composed section lengths",
    ),
    Arm(
        "M7", ALG,
        "          let m2 = y.mapPos(m1.pos, side)\n",
        "          let m2 = y.mapPos(p, side)\n",
        L_A6_OVER,
        "§3.1's killer for LAW-A6 is 'apply B to the pre-A offset', and the "
        "only place this tree composes two mappings is the law's own check — "
        "`compose` then `mapPos` IS the implementation. So the arm is planted "
        "in the check, and what it shows is that the check compares two paths "
        "rather than one path with itself",
        law="apply `B` to the pre-`A` offset",
    ),
    Arm(
        "M8", CHANGESET,
        "        return Mapped(kind: mapSurvived, pos: posB + (pos - posA))\n",
        "        return Mapped(kind: mapSurvived, pos: posB + (endA - pos))\n",
        L_A7_REPLACE,
        "the offset inside an untouched run is measured from the wrong end, "
        "so positions come back in reverse order within every keep. Every "
        "individual answer is in range and the document is untouched; only "
        "the order relation can see it",
        law="a side comparison that reads the wrong end of a replacement",
    ),
    Arm(
        "M9", CHANGESET,
        "      result.oldLen += s.delete\n",
        "      result.oldLen += s.insert.len\n",
        L_A8_REPLACE,
        "A SECTION'S TWO LENGTHS DISAGREE. This is the invariant CodeMirror "
        "carries by convention in a flat `number[]`; here it is a field of a "
        "cached total, and the arm makes the total describe a document the "
        "change set does not apply to",
        law="let a section's two lengths disagree",
    ),
    Arm(
        "M10", CHANGESET,
        "      result.add $s.delete\n",
        "      result.add \"0\"\n",
        L_A9_REPLACE,
        "the encoder drops the deleted length — a field, gone, exactly as "
        "§3.1 asks. PLAT-33 puts change sets on a wire, so an encoder that "
        "round-trips only by accident is a convergence defect waiting",
        law="drop a field from the encoder",
    ),
    Arm(
        "M11", CHANGESET,
        "      if posA < pos and pos < endA:\n",
        "      if posA < pos and pos < endA and s.delete > 1_000_000:\n",
        L_A10_DELETE,
        "SURVIVED IS RETURNED FOR A POSITION INSIDE DELETED TEXT — the "
        "nullable-return defect §6.2 replaces, reintroduced. The position it "
        "reports is a plausible neighbour, which is what makes the typed arm "
        "the only thing that can tell",
        law="return *survived* for a position inside deleted text",
    ),

    # =======================================================================
    # THE TRANSACTION, AND THE ORDER-SENSITIVE CONSTRUCTOR
    # =======================================================================
    Arm(
        "T1", TRANSACTION,
        "    mapForA = r.bOverA\n    mapForB = r.aOverB\n",
        "    mapForA = r.aOverB\n    mapForB = r.bOverA\n",
        X_MERGE,
        "the two arms of `rebase` are read the wrong way round at the one "
        "call site that exists. The primitive is still correct and still "
        "called once; what is wrong is which answer goes where — which is "
        "precisely the failure mode a returned PAIR is supposed to make "
        "harder than a boolean parameter did",
    ),
    Arm(
        "T2", TRANSACTION,
        "           rangeTo: cs.mapPosOr(e.rangeTo, sideBefore))\n",
        "           rangeTo: cs.mapPosOr(e.rangeTo, sideAfter))\n",
        X_REVEAL,
        "both ends of a revealed range are mapped with the same bias, so an "
        "insert at the range's end is swallowed into it. `LAW-S4`'s rule, "
        "broken one milestone before the law that names it exists",
    ),
    Arm(
        "E1", CHANGESET,
        "      total = compose(total, rebase(total, part).bOverA)\n",
        "      total = compose(total, rebase(total, part).aOverB)\n",
        X_ORDERED,
        "the order-sensitive constructor takes the wrong arm out of the "
        "primitive, so a later edit is placed as though it came first. The "
        "reference's own colliding-edit example is what notices",
    ),

    # =======================================================================
    # THE SUITE'S AND THE GENERATOR'S OWN FLOORS
    # =======================================================================
    Arm(
        "G1", GENERATOR,
        "    result.add bs[at]\n    at += 1 + r.rand(1)\n",
        "    result.add bs[at]\n    at += 0\n",
        C_REALISED,
        "THE SHARED POSITION BUDGET COLLAPSES TO ONE POINT. Every class's "
        "constructor then places both of its edits at the same offset, so "
        "nine of the ten classes stop being the class they are labelled. The "
        "classifier is what refuses it, which is what says the classifier is "
        "not the constructor",
    ),
    Arm(
        "G2", GENERATOR,
        "proc genPair*(d: GenDoc; r: var Rng; cls: ShapeClass): ChangePair =\n"
        "  build(genDraw(d, r, cls))\n",
        "proc genPair*(d: GenDoc; r: var Rng; cls: ShapeClass): ChangePair =\n"
        "  var one = genDraw(d, r, cls)\n"
        "  one.bEdits = genDraw(d, r, cls).bEdits\n"
        "  build(one)\n",
        C_HIST,
        "**THE PAIR GENERATOR BECOMES TWO INDEPENDENT DRAWS.** §4.1's named "
        "defect, performed: two draws, one half taken from each, so the two "
        "change sets are placed against two different budgets and are "
        "overwhelmingly disjoint. `LAW-A1` stays green — it is trivially true "
        "on disjoint pairs — and every one of the hundred law cells stays "
        "green too. Only the histogram's per-class floors can see it, and "
        "this arm is the proof that they do",
    ),
    Arm(
        "G3", GENERATOR,
        "  if id.len < 2: return false\n",
        "  if id.len < 2: return false\n  if true: return true\n",
        C_UNICODE,
        "THE CLASS WITNESS STOPS DISCRIMINATING. Every window then 'witnesses' "
        "its class, including a `c7-illformed` window with no ill-formed byte "
        "in it — which is the state the generator was ACTUALLY in on the "
        "first seed tried, and which made FUZZ-1's refusal arm fire zero "
        "times. The falsifiability half of the witness case is what refuses "
        "it (§7b)",
    ),
    Arm(
        "G4", ALG,
        "  for k in 0 ..< DrawsPerCell:\n",
        "  for k in 0 ..< DrawsPerCell - DrawsPerCell:\n",
        L_A1_OVER,
        "EVERY LAW CELL DRAWS NOTHING. All hundred of them are then vacuously "
        "satisfied (§4). The `o.draws == DrawsPerCell` floor under each cell "
        "is the only thing that can notice, and this arm is what has seen it "
        "hold",
    ),
    Arm(
        "G5", ALG,
        "    let perClass = GatePairs div ShapeClassCount\n"
        "    for cls in ShapeClass:\n"
        "      for k in 0 ..< perClass:\n"
        "        let d = docs[r.rand(docs.len - 1)]\n"
        "        let pair = genPair(d, r, cls)\n"
        "        inc pairs\n",
        "    let perClass = GatePairs div ShapeClassCount div ShapeClassCount\n"
        "    for cls in ShapeClass:\n"
        "      for k in 0 ..< perClass:\n"
        "        let d = docs[r.rand(docs.len - 1)]\n"
        "        let pair = genPair(d, r, cls)\n"
        "        inc pairs\n",
        C_GATE,
        "THE GATE DRAWS A TENTH OF THE PAIRS IT SAYS IT DOES. Every "
        "comparison it makes still passes; the milestone's '10,000 generated "
        "pairs' becomes a thousand. The asserted COUNT is the only thing "
        "underneath, which is the whole reason §4 asks for it",
    ),
    Arm(
        "G6", ALG,
        "    for step in 1 .. stepsPerRound:\n",
        "    for step in 1 .. stepsPerRound - stepsPerRound + 1:\n",
        F_OVER,
        "THE FUZZ STREAM STOPS AFTER ONE STEP. `FUZZ-1`'s whole claim is that "
        "the invariants hold after EVERY step of a stream; a one-step stream "
        "satisfies it and demonstrates nothing about a document that has been "
        "edited under a mapping",
    ),
    Arm(
        "G7", ALG,
        "    if t.startsWith(\"#\"): continue\n",
        "    if t.startsWith(\"\"): continue\n",
        C_SCAN1,
        "THE SOURCE SCAN MATCHES NOTHING. §4's canonical shape: a scanner "
        "that finds nothing satisfies every 'must be exactly these' written "
        "over it, including 'no other module spells the double mapping'. The "
        "non-vacuity checks on the scan are what refuse it",
    ),
    Arm(
        "G8", TRANSACTION,
        "proc mapEffects*(effects: seq[Effect]; cs: ChangeSet): seq[Effect] =\n",
        "proc mapBoth(x, y: ChangeSet; before: bool): ChangeSet =\n"
        "  ## An inlined sixth copy of the double mapping.\n"
        "  if before: x else: y\n\n"
        "proc mapEffects*(effects: seq[Effect]; cs: ChangeSet): seq[Effect] =\n",
        C_SCAN2,
        "**A SIXTH MODULE HAND-WRITES THE DOUBLE MAPPING** — PLAT-25's own "
        "stated risk, performed. The milestone says the mitigation is that "
        "the mutation arm on the primitive SURVIVES when a copy exists, which "
        "is a signal a reader has to interpret. The scan makes it a red gate "
        "instead, and this is the arm that shows the gate is armed",
    ),
    Arm(
        "G9", GENERATOR,
        "  result = draw\n  var progress = true\n",
        "  result = draw\n  var progress = false\n",
        C_SHRINK,
        "THE SHRINKER RETURNS ITS INPUT. §4.5: a failing property that "
        "reports a 400-transaction counterexample has found a defect nobody "
        "will fix. The planted property still fails, the harness still "
        "reports a counterexample, and the counterexample is useless",
    ),
    Arm(
        "G10", ALG,
        "  for r in cs.changedRanges(individual = true):\n"
        "    if r.fromA < p and p < r.toA:\n",
        "  for r in cs.changedRanges(individual = true):\n"
        "    if r.fromA < p and p < r.toA and r.toA > 1_000_000:\n",
        L_A10_DELETE,
        "`LAW-A10`'s ORACLE STOPS BEING INDEPENDENT. It answers `survived` "
        "for everything, which is what `mapPos` answers for almost "
        "everything — two copies of one predicate letting the control agree "
        "with itself (§30) is what the oracle exists to avoid, and this arm "
        "is what says it does",
    ),
    Arm(
        "G11", EX,
        "const ShapeDocLen = 8\n",
        "const ShapeDocLen = 0\n",
        X_TYPED,
        "THE TYPED-MAPPING SWEEP EXAMINES A DOCUMENT OF NO POSITIONS. All "
        "twenty-four cells still run; the 'must produce this arm' half of "
        "each becomes a claim about the empty set. The witness floor under "
        "each cell is the only thing underneath",
    ),
    Arm(
        "G12", ALG,
        "    counted left != right                        # VALUES do not\n",
        "    counted left == right                        # VALUES do not\n",
        C_A2PIN,
        "the pinned counterexample for LAW-A2's value-level divergence is "
        "edited to claim the opposite. A recorded finding that no case can "
        "contradict is a paragraph; this arm is what makes it a measurement",
    ),
    Arm(
        "G13", ALG,
        "        if kind == pcFile and path.endsWith(\".nim\"):\n",
        "        if kind == pcFile and path.endsWith(\".nimrod\"):\n",
        C_SCAN2,
        "THE TREE ENUMERATION MATCHES NOTHING. The sweep derives its whole "
        "subject set by walking `viewmodel/`; break the file filter and it "
        "walks 252 modules and admits none of them, at which point every "
        "'no module anywhere spells this' assertion is a claim about the "
        "empty set. §4 applies to the lister exactly as it applies to the "
        "scan it feeds. The non-vacuity floors — the module count, the "
        "named directories, and every `RebaseSites` row having to be a "
        "visited path — are what refuse it",
    ),
    Arm(
        "G14", ALG,
        "            let stepwiseDiffers = xy.mapPos(p, side) != stepped\n",
        "            let stepwiseDiffers = false\n",
        C_A6POP,
        "**THE FALSIFICATION STOPS BEING MEASURED.** §3.1a's claim is not "
        "that `LAW-A6` holds with a precondition — it is that the law is "
        "FALSE without one, by this many. Drop the comparison and the refined "
        "law is still green everywhere, the precondition still fires, and the "
        "only thing that changes is the number nobody was checking. A "
        "restatement whose unrefined form has never been watched fail is a "
        "law weakened to fit an implementation",
    ),
    Arm(
        "G15", TEXTOPS,
        "proc authorityOf*(doc: SharedTextDocument): TextAuthority =",
        "proc rebaseCopyOutsideEditor*(a, b: ChangeSet): ChangeSet =\n"
        "  ## A call site ONE DIRECTORY OVER from `editor/`.\n"
        "  rebase(a, b).bOverA\n\n"
        "proc authorityOf*(doc: SharedTextDocument): TextAuthority =",
        C_SCAN2,
        "**THE DOUBLE MAPPING IS CALLED FROM OUTSIDE `editor/`** — §35's "
        "third and worst subject-list failure, performed. Until PLAT-33 the "
        "scan's `walkDir` was hard-coded to `editor/`, so this exact routine "
        "planted in `collab/` left the suite GREEN while the identical one in "
        "`editor/` reddened — measured, not supposed, and `collab/` is where "
        "the milestone had just added code. The subject set is derived from "
        "the tree now, and this arm is what says the widening is armed rather "
        "than merely written.\n\n"
        "**IT EDITS AN EXISTING MODULE RATHER THAN ADDING ONE, AND THAT IS "
        "MEASURED RATHER THAN ASSUMED.** A new file is not a `staticRead` "
        "dependency of anything, so the compile-time `walkDir` never re-runs "
        "and the planted file is invisible — unless something forces the "
        "frontend to re-run. The lever is NOT a cold nimcache (that forces a "
        "rebuild, but so do other things, and naming it made an earlier "
        "revision of this rationale misleading). Measured 2026-09-20, one "
        "variable at a time with the cache warm: an `-o:` naming a path that "
        "does not yet exist rebuilds and reddens; an `-o:` naming the "
        "existing up-to-date binary is skipped and stays green; an mtime "
        "`touch` on a tracked module is NOT enough, because Nim keys on "
        "content; a CONTENT edit to a tracked module rebuilds and reddens. "
        "This harness compiles to FIXED `-o:` paths, so it is the content "
        "edit that carries every arm — which every arm here makes, this one "
        "included. A file-ADDING arm would be silently unkillable here. "
        "See `Verification-Harness-Traps.md` §35a, which records both the "
        "measurement and the attempt to withdraw it",
    ),
]

DECLARED_SURVIVORS: list[Arm] = []

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    ran: bool = True
    hung: bool = False

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
# found doing exactly this when a Unicode corpus joined its subject set. None
# of THIS harness's subjects is a corpus document today; the door is lossless
# anyway, because the day one of them is, nobody will be reading this comment.
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
            # mutated algebra can emit them, and a UnicodeDecodeError in the
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
        # compiling while the other still prints its cases would otherwise
        # read as a clean survival.
        res.ran = False
        print(f"      ---- {path}: no result lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)


# THE SUBJECT UNDER MUTATION, AND THE WAY BACK FROM A SIGNAL
# ----------------------------------------------------------
# `write_source(arm.path, original)` sits in a `finally`, which covers an
# exception and does NOT cover a signal: the default SIGTERM handler
# terminates the interpreter without unwinding, so a harness killed between
# the mutate and the restore leaves its subject mutated. That happened on
# 2026-09-18 — `pkill` on a run that had hung — and the file sat wrong until
# `sha256sum -c` against the control digests said so.
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
    the most frequent edit a suite receives. An arm whose needle quotes one is
    an arm that looks like coverage in the table and can never be applied.
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
    alg = read_source(ALG)
    ex = read_source(EX)
    gen = read_source(GENERATOR)
    both = alg + "\n" + ex

    if 'test LawName[law] & " x " & $cls:' not in alg:
        print("THE LAW CELL TEMPLATE IS NOT IN THE SUITE")
        problems += 1
    if 'test "FUZZ-1 x " & $cls:' not in alg:
        print("THE FUZZ CELL TEMPLATE IS NOT IN THE SUITE")
        problems += 1
    if 'test "typed mapping: " & $shape & " / " & $side & " / " & $arm:' not in ex:
        print("THE TYPED-MAPPING CELL TEMPLATE IS NOT IN THE EXAMPLES SUITE")
        problems += 1

    for name in NAMED_CASES:
        if name.startswith("LAW-A") and " x " in name:
            law, _, cls = name.partition(" x ")
            if f'"{law}"' not in alg:
                print(f"KILLER LAW ID NOT DECLARED: {law!r}")
                problems += 1
            if f"\n    {cls}\n" not in gen and f"    {cls}\n" not in gen:
                print(f"KILLER SHAPE CLASS NOT DECLARED: {cls!r}")
                problems += 1
        elif name.startswith("FUZZ-1 x "):
            cls = name[len("FUZZ-1 x "):]
            if f"    {cls}\n" not in gen:
                print(f"KILLER SHAPE CLASS NOT DECLARED: {cls!r}")
                problems += 1
        elif name.startswith("typed mapping: "):
            for part in name[len("typed mapping: "):].split(" / "):
                if part not in ex:
                    print(f"KILLER TYPED-MAPPING PART NOT IN SUITE: {part!r}")
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
        # over it (§4). If no subject declares a count, this rule is asleep and
        # says so rather than reporting a clean pass.
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

    # ALL TEN §3.1 KILLERS ARE PERFORMED, and the check is two-sided.
    #
    # `an arm with no stated killer is not admitted` is the rule about the
    # TABLE; this is the rule about the HARNESS. An arm that carries a `law`
    # string claims to perform one of §3.1's ten killers, and the ten laws it
    # covers must be all ten — otherwise a law is executable, green, and has
    # never been watched fail, which is the state §3's opening paragraph is
    # about. Arms whose killer happens to be a `LAW-A` case for another reason
    # (a harness floor, an oracle, a pinned finding) carry no `law` and are not
    # counted here, because counting them would let a floor arm stand in for a
    # law arm.
    performed = set()
    for arm in ARMS:
        if not arm.law:
            continue
        law_id = arm.killer.split(" x ")[0]
        if not law_id.startswith("LAW-A"):
            print(f"{arm.id}: quotes a §3.1 killer but its killer case "
                  f"{arm.killer!r} is not a law cell")
            problems += 1
            continue
        performed.add(law_id)
    expected = {f"LAW-A{i}" for i in range(1, 11)}
    if performed != expected:
        print(f"§3.1 KILLERS NOT PERFORMED BY ANY ARM: "
              f"{sorted(expected - performed)}")
        print(f"ARMS CLAIMING A LAW THAT IS NOT PUBLISHED: "
              f"{sorted(performed - expected)}")
        problems += 1
    else:
        print(f"all {len(expected)} of §3.1's killers are performed by an arm")

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
    # **ITS VERDICT IS ACTED ON, NOT PRINTED.** This call used to discard the
    # bool it returns, which made the one check standing between "the tree is
    # the reviewed tree" and "the tree is whatever a previous run left behind"
    # a gate that could not fail — §4's own shape, inside the harness that
    # exists to find it. It matters because `baseline` below is snapshotted
    # from the CURRENT tree: without this refusal a run started on an
    # already-mutated file restores to the mutation and reports itself clean.
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved or is absent (§32). "
              "Re-run --needle-scan, review the tree, then "
              "--record-control-hashes.")
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
            # §1: a hang is its own recorded outcome. An arm whose only signal
            # is "the run never finished" has told you nothing about WHICH case
            # noticed, so it is a problem to be repaired rather than a kill to
            # be counted.
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
