#!/usr/bin/env python3
"""PLAT-32's arming — the mutation harness for undo in a buffer with more than
one writer: the history module, the stream generator and the two suites over
them.

    python3 src/frontend/viewmodel/tests/unit/run-plat32-history-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --enumerate-touched
    python3 ... --only=M1,U2

WHAT THIS IS
============
`Editor-Model-Conformance-Suite.md` §3.6 publishes six `LAW-H*` rows, each with
a killing mutation in its own column, and Verification-Harness-Traps §36 says
what that column is worth without this file: *"a published killing mutation is a
claim about the ASSERTION, not only about the code — and the assertion can be
too weak to observe it."* Four instances so far in this campaign, each because
the mutation produced a DIFFERENT VALID STRUCTURE rather than an invalid one.
Undo has several of those shapes — a history that coalesces differently, an
inverse computed by a different route — so every one of the six is performed
here and the case it kills is named.

THE SIX PUBLISHED KILLERS, AND THE ARM THAT PERFORMS EACH
---------------------------------------------------------

  | law      | published killer                                   | arm  |
  |----------|----------------------------------------------------|------|
  | `LAW-H1` | coalesce two events without composing inversions   | `M1` |
  | `LAW-H2` | store the redo event instead of inverting the undo | `M2` |
  | `LAW-H3` | push it into the done branch only                  | `M3` |
  | `LAW-H4` | drop the event and discard the mapping             | `M4` |
  | `LAW-H5` | never group … and always group                     | `M5`, `M6` |
  | `LAW-H6` | map the undone event through the remote change     | `M7` |
  |          | with the wrong bias                                |      |

`LAW-H5` takes two arms because its published killer names two mutations and
says why: *"always group (passes the first half); never group (passes the
second)"*. One arm would leave whichever half it does not land on untested,
which is the shape a one-sided count assertion has.

Verification-Harness-Traps, applied rather than cited:

  * §36  — every published killer is PERFORMED, and the verdict per law is
           recorded in the milestone. An arm that survives is a `problems += 1`
           and the repair is to the ASSERTION, never to the killer.
  * §36a — `M10` puts a CLAMP back where `history.pop` raises. A clamp cannot
           be told from a guard that never fires, and it makes a broken inverse
           look total for exactly as long as the wrong value lands in range.
  * §30a — `U1` empties the oracle's forbidden-spelling list and `U2` makes its
           reader match nothing. The `LAW-H1` oracle is string surgery ON
           PURPOSE: a correct re-derivation of the model would agree with the
           model for the reason the model agrees with itself, and no assertion
           about either side's ANSWER could tell the difference.
  * §30b — `M5` and `M6` both land on `mayGroup`, the ONE predicate the product
           and the suite's controls share. The mutation goes on the function.
  * §34  — `G1` restores the stream generator's first `ssRemoteHeavy` period,
           which realised 0 of 9 with every law green, and `G2` moves the drop
           generator's kill range so no event is ever dropped.
  * §32  — `--needle-scan` refuses to run when any needle is absent or
           ambiguous, and the full run refuses unless the scan is clean AND the
           control digests have not moved.
  * §32f — every read and every write is BYTES.
  * §32h — `finally` is not a signal handler.
  * §10.3 — no arm's needle may quote a count. The scan reads every declared
           count constant out of the subjects and REJECTS an arm whose needle
           contains one of their names or one of their values.

BOTH SUITES RUN FOR EVERY ARM. They share `history.nim` and the generator, so
an arm on either can redden either; running only "the suite an arm belongs to"
would be the harness deciding in advance which case is allowed to notice, which
is the MISDIRECTED verdict made unavailable.

THIS HARNESS NEEDS NO LANE FLAGS: both suites are pure ViewModel and compile
with `--path:src/frontend/viewmodel` alone.
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
HISTORY = "src/frontend/viewmodel/editor/history.nim"
STATE = "src/frontend/viewmodel/editor/editor_state.nim"
OPS = "src/frontend/viewmodel/editor/operations.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/history_generator.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_history_laws.nim"
EX = "src/frontend/viewmodel/tests/unit/test_editor_history_examples.nim"

TOUCHED = [HISTORY, STATE, OPS, GENERATOR, LAWS, EX]

CONTROL_HASHES = HERE / "plat32-history-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P32_SUITE_TIMEOUT", "2400"))
VM_FLAGS = ["--hints:off", "--warnings:off", "--path:src/frontend/viewmodel"]

RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*(.*?)\s*(?:\x1b\[[0-9;]*m)*$")

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# Three families are COMPOSED at run time — the per-shape law cells, the
# delivery matrix and the grouping sweep — and the scan checks the TEMPLATE
# rather than searching for the whole string.
# ---------------------------------------------------------------------------

H1_LOCAL = "LAW-H1 x ssLocalOnly"
H1_INTERLEAVED = "LAW-H1 x ssInterleaved"
H2_LOCAL = "LAW-H2 x ssLocalOnly"
H2_INTERLEAVED = "LAW-H2 x ssInterleaved"
H3_INTERLEAVED = "LAW-H3 x ssInterleaved"
H4_LOCAL = "LAW-H4 x ssLocalOnly"
H5_LOCAL = "LAW-H5 x ssLocalOnly"
H6_LOCAL = "LAW-H6 x ssLocalOnly"

DROP_REALISED = ("the drop generator drops, on EVERY corpus class — "
                 "a realised count")
DROP_BELOW = "the event beneath a dropped one STILL UNDOES CORRECTLY"
DROP_NEGATIVE = ("the NEGATIVE CONTROL: a remote change that does not map the "
                 "event away drops nothing")
POP_RAISES = ("§36a — pop RAISES when a remote change reached the document "
              "and not the history")
SHAPE_REALISED = "§34 — every drawn stream REALISED the shape it was drawn for"
POPULATION_BUILT = "the module-scope population was built WITHOUT RAISING"
INTERLEAVED_EQ = "§34 — THE INTERLEAVED CLASS IS NON-EMPTY, AS AN EQUALITY"
ORACLE_SCAN = "§30a — THE ORACLE IS NOT A SECOND CALL TO THE MODEL"
ONE_REBASE = "§30a — the ONE rebase primitive is called once, by name, with no flag"
DIR_SCAN = "§35 — the scan's subject list is the DIRECTORY, not a list somebody keeps"

GROUP_INPUT_INSIDE = "grouping x ueInput x INSIDE the window is one event"
GROUP_INPUT_SPAN = "grouping x ueInput x SPANNING the window is one event each"
GROUP_MOVE_INSIDE = "grouping x ueMove x INSIDE the window is still N events"
WINDOW_BOUND = ("AT the window exactly: a new event; one millisecond inside "
                "it: the same one")
ISOLATION = "THE ISOLATION ANNOTATION, two-sidedly"
ISOLATED_SEL = ("AN ISOLATED SELECTION-ONLY TRANSACTION IS NOT DEDUPED "
                "AGAINST ITS PREDECESSOR")
SEL_REBASED = ("A SELECTION RECORDED PAST SOMEBODY ELSE'S EDIT COMES BACK IN "
               "THE RIGHT COORDINATES")
CLASSIFIER_SCAN = "§30a — THE CLASSIFIER READS WHAT THE PRODUCT READS"
BRANCH_BOUND = "the branch is BOUNDED, and the bound is the published one"
UNDO_ISOLATES = ("an UNDO isolates: the next edit does not coalesce into a "
                 "generated event")
GATE_MINE = "THE GATE: remote edits survive an undo of the local one"
GATE_CONTROL = "THE NEGATIVE CONTROL: the same case with NO remote edit"
TWO_EVENTS = ("typing, pausing past the window, typing again, and undoing: "
              "TWO events")
SEL_UNDO = "undo-selection restores the selection and leaves the document alone"
REDO_BEFORE = "rebased redo x rsAtEdge x remote BEFORE the undo"
REDO_AFTER = "rebased redo x rsAtEdge x remote AFTER the undo"

VOCAB_UNDO = "VOCAB undo and redo walk the event history"
VOCAB_REFUSE = "VOCAB undo REFUSES on an empty history, by name"
VOCAB_SEL = "VOCAB undo-selection is a SELECTION walk and moves no text"
VOCAB_REDO_SEL = ("VOCAB redo-selection walks it forward, and the document "
                  "never moves")
VOCAB_GROUP = "VOCAB an edit through the vocabulary GROUPS by the published rule"
VOCAB_GONE = "VOCAB the snapshot stack is GONE, not kept beside the history"

NAMED_CASES = [
    H1_LOCAL, H1_INTERLEAVED, H2_LOCAL, H2_INTERLEAVED, H3_INTERLEAVED,
    H4_LOCAL, H5_LOCAL, H6_LOCAL,
    DROP_REALISED, DROP_BELOW, DROP_NEGATIVE, POP_RAISES,
    SHAPE_REALISED, INTERLEAVED_EQ, ORACLE_SCAN, ONE_REBASE, DIR_SCAN,
    POPULATION_BUILT,
    GROUP_INPUT_INSIDE, GROUP_INPUT_SPAN, GROUP_MOVE_INSIDE, WINDOW_BOUND,
    ISOLATION, BRANCH_BOUND, UNDO_ISOLATES,
    GATE_MINE, GATE_CONTROL, TWO_EVENTS, SEL_UNDO, REDO_BEFORE, REDO_AFTER,
    VOCAB_UNDO, VOCAB_REFUSE, VOCAB_SEL, VOCAB_REDO_SEL, VOCAB_GROUP,
    VOCAB_GONE, ISOLATED_SEL, SEL_REBASED, CLASSIFIER_SCAN,
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
    # THE SIX PUBLISHED KILLERS — §3.6's own column, performed
    # =======================================================================
    Arm(
        "M1", HISTORY,
        "      changes: compose(ev.changes, last.changes),\n",
        "      changes: last.changes,\n",
        H1_LOCAL,
        "**`LAW-H1`'s PUBLISHED KILLER: COALESCE TWO EVENTS WITHOUT COMPOSING "
        "THEIR INVERSIONS.** The merged event keeps only the OLDER inversion, "
        "so undoing a group of five keystrokes undoes one of them and leaves "
        "the document in a state the stream never held. Note what does NOT "
        "move: the branch depth is still 1, the group is still one undo, the "
        "redo still round-trips through the same wrong pair, and every "
        "structural assertion about the history passes. The `ssLocalOnly` arm "
        "is what dies, which is the point of that arm existing",
    ),
    Arm(
        "M2", HISTORY,
        "  let ev = eventFromTransaction(step.tr, docBefore, step.selectionBefore,\n"
        "                                startOverride = some(step.revisedSelection))\n",
        "  let ev = some HistEvent(kind: hekChange, mapped: none(ChangeSet),\n"
        "                          changes: step.tr.changes,\n"
        "                          effects: step.tr.effects,\n"
        "                          startSelection: step.revisedSelection,\n"
        "                          endSelection: step.selectionBefore,\n"
        "                          selectionsAfter: @[],\n"
        "                          userEvent: ueUndo, isolated: false)\n",
        H2_LOCAL,
        "**`LAW-H2`'s PUBLISHED KILLER: STORE THE REDO EVENT INSTEAD OF "
        "INVERTING THE UNDO.** The opposite branch receives the undo "
        "transaction's own change set rather than its inversion, which is "
        "exactly what a history that KEEPS a redo event does — and it is a "
        "perfectly well-formed event, of the right kind, with the right "
        "lengths, on the right branch. §36's *'a different valid structure'*: "
        "the branch depths are identical, `redoDepth` is right, and nothing "
        "about the SHAPE of the history says anything is wrong. What dies is "
        "the document after the redo",
    ),
    Arm(
        "M3", HISTORY,
        "                        undone: addMappingToBranch(h.undone, t.changes),\n",
        "                        undone: h.undone,\n",
        H3_INTERLEAVED,
        "**`LAW-H3`'s PUBLISHED KILLER: PUSH IT INTO THE DONE BRANCH ONLY.** "
        "The remote change reaches the events that can still be undone and "
        "not the ones that can be redone, so the undone branch is expressed "
        "over a document that moved under it. Everything about UNDO stays "
        "green — the done branch is mapped correctly and 'undo mine, not "
        "theirs' still holds — which is why the case that dies is the one "
        "that undoes everything, takes a remote change and then REDOES",
    ),
    Arm(
        "M4", HISTORY,
        "    carried =\n"
        "      if ev.mapped.isSome: ev.mapped.get\n"
        "      else: identityChangeSet(carried.newLength)\n",
        "    carried = identityChangeSet(carried.newLength)\n",
        DROP_BELOW,
        "**`LAW-H4`'s PUBLISHED KILLER: DROP THE EVENT AND DISCARD THE "
        "MAPPING** — the clause `Editor-ViewModel.md` §13.2 calls *'easy to "
        "omit and impossible to notice'*. The arm keeps the drop and replaces "
        "the inherited mapping with an identity OF THE RIGHT LENGTH, which is "
        "the plausible-looking form of discarding it. What survives: the "
        "event IS dropped, the depth falls by exactly one, the document is "
        "right, and the negative control still passes. Nothing is wrong until "
        "somebody undoes the event beneath — which is the case named here, "
        "and which exists only because that clause was read",
    ),
    Arm(
        "M5", HISTORY,
        "  if done.len > 0 and mayGroup(h, done[^1], ev, nowMs):\n",
        "  if false and mayGroup(h, done[^1], ev, nowMs):\n",
        GROUP_INPUT_INSIDE,
        "**`LAW-H5`'s PUBLISHED KILLER, FIRST HALF: NEVER GROUP.** Five "
        "keystrokes become five events. The SPANNING half of every grouping "
        "case stays green under this — which is the whole reason the law is "
        "two-sided and why one arm could not have graded it",
    ),
    Arm(
        "M6", HISTORY,
        "  if nowMs - h.prevTime >= NewGroupDelayMs: return false\n",
        "  if false: return false\n",
        GROUP_INPUT_SPAN,
        "**`LAW-H5`'s PUBLISHED KILLER, SECOND HALF: ALWAYS GROUP.** The "
        "elapsed-time test is removed from `mayGroup` — the ONE predicate "
        "(§30b), so the product and every control over it move together — and "
        "keystrokes an hour apart coalesce into one event. The INSIDE half "
        "stays green, exactly as the published killer says",
    ),
    Arm(
        "M7", HISTORY,
        "      startSelection: mapSelection(ev.startSelection, r.aOverB),\n",
        "      startSelection: mapSelection(ev.startSelection, mapping),\n",
        H6_LOCAL,
        "**`LAW-H6`'s PUBLISHED KILLER: MAP THE UNDONE EVENT THROUGH THE "
        "REMOTE CHANGE WITH THE WRONG BIAS.** The stored selection is mapped "
        "through the remote change as it stands in the document ABOVE the "
        "event instead of through the rebased form that belongs below it, so "
        "the caret lands on the wrong side of somebody else's insertion. "
        "**The document returns IDENTICAL** — it is decided by the other arm "
        "of the same `rebase` call, which this arm does not touch — which is "
        "why §3.6 says of this law that a document comparison is satisfied by "
        "both of them, and why the case asserts a caret OFFSET",
    ),

    # =======================================================================
    # THE PRODUCT, BEYOND THE PUBLISHED SIX
    # =======================================================================
    Arm(
        "M8", HISTORY,
        "  if isolatedOf(t): st = st.isolate()\n",
        "  if false: st = st.isolate()\n",
        ISOLATED_SEL,
        "**`HistoryState.isolate` STOPS BEING CALLED, AND THE FIRST AIM OF "
        "THIS ARM WAS WRONG.** It was pointed at the three-event isolation "
        "case and came back SURVIVED, because that case is decided by the "
        "EVENT's own `isolated` flag — which `mayGroup` reads and this arm "
        "does not touch. The one behaviour `isolate` decides alone is the "
        "SELECTION path: `recordSelectionChange` drops a same-shape selection "
        "change inside the window, and resetting `prevTime` is what makes an "
        "isolated one survive that. §36's first rule, performed: *'the "
        "question is not is this mutation wrong, but WHICH ASSERTION goes red "
        "when I make it'* — and when the answer was none, the repair was the "
        "missing assertion rather than a deleted line",
    ),
    Arm(
        "M9", HISTORY,
        "      endSelection: mapSelection(ev.endSelection, mapping),\n",
        "      endSelection: ev.endSelection,\n",
        H2_INTERLEAVED,
        "**THE RELOCATED PLAT-30 `M4`: A STORED SELECTION STOPS MOVING WITH "
        "THE DOCUMENT.** That arm performed a defect PLAT-30 actually had — "
        "`undo-selection` handing back `[96,182)` in a 114-byte document — by "
        "deleting `commitChange`'s two `selUndo`/`selRedo` mapping loops. "
        "Those loops no longer exist: PLAT-32 replaced the flat stacks with "
        "events, and a selection anchored to an event does not need dragging "
        "forward on every local edit. The one thing that CAN still move a "
        "document without adding an event is a remote change, and this is "
        "that case. The class is armed; the subject moved",
    ),
    Arm(
        "M10", HISTORY,
        "  if ev.changes.length != doc.len:\n"
        "    raise newException(HistoryError,\n"
        '      "pop: the top event inverts a document of " & $ev.changes.length &\n'
        '      " bytes and the document is " & $doc.len &\n'
        '      " — a remote change reached the document and not the history")\n'
        "\n"
        "  # ======================================================================\n",
        "  if ev.changes.length != doc.len:\n"
        "    return none(HistoryStep)\n"
        "\n"
        "  # ======================================================================\n",
        POP_RAISES,
        "**§36a: THE RAISE BECOMES A SILENT REPAIR.** *'A guard that repairs a "
        "value silently cannot be distinguished, from the outside, from a "
        "guard that never fires.'* Answering `none` instead of raising turns "
        "'a remote change reached the document and not the history' into "
        "'there is nothing to undo' — a defined, plausible, TOTAL-looking "
        "outcome that hides a missing mapping for as long as the branch "
        "happens to be reachable. Every law stays green: the mutation only "
        "fires on a state the product never produces, which is precisely why "
        "it has to be driven deliberately",
    ),
    Arm(
        "M11", HISTORY,
        "  for s in selectionsAfterOf(ev):\n"
        "    sels.add mapSelection(s, mapping)\n",
        "  for s in selectionsAfterOf(ev):\n"
        "    sels.add s\n",
        SEL_REBASED,
        "THE SELECTION HISTORY HANGING OFF AN EVENT STOPS BEING MAPPED PAST A "
        "REMOTE CHANGE. The second half of `M9`'s class, on the other field: "
        "`undo-selection` after somebody else has edited restores a range in "
        "the wrong coordinates. It is armed separately because `endSelection` "
        "and `selectionsAfter` are two fields with two call sites, and one "
        "arm cannot prove two",
    ),
    Arm(
        "M12", HISTORY,
        "  if result.len > MaxHistoryDepth:\n"
        "    result.delete(0)\n",
        "  if false:\n"
        "    result.delete(0)\n",
        BRANCH_BOUND,
        "THE BRANCH GROWS WITHOUT BOUND. PLAT-30's `HistoryLimit` was a "
        "MEMORY bound on a snapshot stack; here the same number is a POLICY — "
        "how far back undo reaches — and a policy that no case asserts is a "
        "policy that can be deleted by an editor who reads it as a leftover",
    ),
    Arm(
        "M13", HISTORY,
        "  HistoryState(done: done, undone: @[], prevTime: nowMs,\n",
        "  HistoryState(done: done, undone: h.undone, prevTime: nowMs,\n",
        UNDO_ISOLATES,
        "A NEW EDIT NO LONGER CLEARS THE REDO BRANCH. The redo branch then "
        "holds events expressed against a document that diverged, and the "
        "next redo either raises or applies an edit from a history the user "
        "abandoned. Every undo assertion stays green — the done branch is "
        "untouched — so the case that dies is the one that asserts "
        "`redoDepth` is zero after an edit following an undo",
    ),
    Arm(
        "M14", OPS,
        "  let step = popUndoSelection(st.history, st.doc, st.selection)\n",
        "  let step = popUndo(st.history, st.doc, st.selection)\n",
        VOCAB_SEL,
        "THE VOCABULARY'S `undo-selection` BECOMES `undo`. PLAT-30 kept "
        "`selUndo` as a SECOND STACK on the stated grounds that *'folding "
        "them into one stack would make two of the four operations "
        "unreachable'*; PLAT-32 folded them into one BRANCH, and this arm is "
        "what makes 'the four are still four' a checked claim rather than the "
        "assertion that was true of the old shape",
    ),

    Arm(
        "M15", STATE,
        "  st.history = recordSelectionChange(st.history, st.selection, nowMs)\n",
        "  discard nowMs\n",
        VOCAB_REDO_SEL,
        "A SELECTION CHANGE STOPS BEING RECORDED AT ALL. The other half of "
        "`M14`: that arm makes `undo-selection` do the WRONG thing, this one "
        "makes it have nothing to do. Two of the four published history "
        "operations become unreachable — which is exactly what PLAT-30 said "
        "would happen if the two stacks were folded into one, and the reason "
        "these cases exist is to say that folding them into one BRANCH did "
        "not do it",
    ),

    # =======================================================================
    # THE POPULATION
    # =======================================================================
    Arm(
        "G1", GENERATOR,
        "      result.add(if i mod 4 == 0: stLocal else: stRemote)\n",
        "      result.add(if i mod 3 == 0: stLocal else: stRemote)\n",
        SHAPE_REALISED,
        "**§34, AND IT WAS REAL: THE GENERATOR'S FIRST `ssRemoteHeavy` PERIOD "
        "PUT BACK.** At a period of three the shape realised **0 of 9** and "
        "every law was green — the streams were classified `ssLocalPlusRemote` "
        "and the remote-heavy cells were running a shape nobody had asked "
        "for. No property could see it and no non-emptiness check would have "
        "either, because the population was large, varied and non-empty in "
        "every dimension. What found it is the per-class EQUALITY between the "
        "shape drawn and the shape realised",
    ),
    Arm(
        "G2", GENERATOR,
        "  let kill = remoteTransaction(doc, upper - 1, upper + MarkerB.len, \"\")\n",
        "  let kill = remoteTransaction(doc, upper - 1, upper + MarkerB.len - 1, \"\")\n",
        DROP_REALISED,
        "**THE DROP GENERATOR STOPS DROPPING**, by one byte. (This arm's own "
        "needle MOVED when the generator was repaired to reach one byte "
        "beneath the marker — §32's exact shape, caught by the scan before the "
        "control digests were re-recorded, which is the order that rule "
        "exists for.) The remote "
        "change deletes all but the last byte of the marker, so the event "
        "survives mapping and nothing is ever dropped — and every `LAW-H4` "
        "assertion about a branch that DID drop is simply never exercised. "
        "The milestone's own words: *'a generator that never produces it "
        "makes easy to omit and impossible to notice literally true'*. The "
        "realised drop count is asserted as an equality against the number "
        "drawn, which is what refuses this",
    ),
    Arm(
        "G3", GENERATOR,
        "  for (a, b) in markerSpans(doc):\n"
        "    if result > a and result < b: return b\n",
        "  for (a, b) in markerSpans(doc):\n"
        "    if false: return b\n",
        H1_INTERLEAVED,
        "GENERATED POSITIONS ARE ALLOWED BACK INSIDE A MARKER. A remote "
        "insertion lands in the middle of `<A>3` and the marker is no longer "
        "a unique substring, so the ORACLE — *'the final document minus the "
        "markers of the undone events'* — stops being exact. This is the arm "
        "that says the oracle's precondition is a property of the generator "
        "and not a hope: it dies in the law cells with remote steps in them "
        "and leaves `ssLocalOnly` green",
    ),
    Arm(
        "G4", GENERATOR,
        "  if isRemote(s.tr): stRemote\n",
        "  if s.tr.annotations.len == 1: stRemote\n",
        CLASSIFIER_SCAN,
        "**THE CLASSIFIER STOPS READING WHAT THE PRODUCT READS** (§34's third "
        "rule). `isRemote` is `history.nim`'s own function — the one `record` "
        "branches on — and this replaces it with a shape test on the "
        "annotation list that happens to agree on today's constructors. It is "
        "the re-derivation §30a is about, in a classifier: correct today, and "
        "invisible to every assertion about what the streams ANSWER",
    ),

    # =======================================================================
    # THE SUITES' OWN GUARDS
    # =======================================================================
    Arm(
        "U1", LAWS,
        'const ForbiddenInOracle = ["rebase", "mapPos", "mapSelection", "invert",\n'
        '                           "compose", "changedRanges", "ChangeSet",\n'
        '                           "sections", "HistoryState"]\n',
        "const ForbiddenInOracle: seq[string] = @[]\n",
        ORACLE_SCAN,
        "**THE §30a INSTRUMENT IS EMPTIED.** §4, verbatim: *'a scanner that "
        "finds nothing passes every must-not-contain check you write.'* With "
        "an empty list the oracle could call `rebase` and the scan would "
        "still be green — which would make the one check that can tell an "
        "independent oracle from a second call to the model into decoration. "
        "The cardinality assertion is what refuses it",
    ),
    Arm(
        "U2", LAWS,
        "  let a = src.find(opening)\n"
        "  if a < 0: return \"\"\n",
        "  let a = -1\n"
        "  if a < 0: return \"\"\n",
        ORACLE_SCAN,
        "THE SOURCE-SCAN READER MATCHES NOTHING. The second half of `U1`: an "
        "instrument can be disarmed by emptying its subject as well as by "
        "emptying its list, and the two are different edits. Every case that "
        "reads a body through `bodyOf` asserts the body is non-empty BEFORE "
        "asserting anything about its contents, which is what makes that a "
        "guard rather than a habit",
    ),
    Arm(
        "U3", LAWS,
        '    if path.endsWith(".nim"):\n',
        '    if path.endsWith(".nimx"):\n',
        DIR_SCAN,
        "§35's OWN ARM: the directory lister matches nothing, so *'the set is "
        "exactly these eighteen'* is satisfied by leaving nothing to disagree "
        "with it. This is one character in the extension it filters on, which "
        "is the arm that trap names",
    ),
    Arm(
        "U4", EX,
        "const Ruler = \"0123456789abcdef\"\n",
        "const Ruler = \"0123456789abcdee\"\n",
        REDO_BEFORE,
        "THE RULER LOSES ITS DISTINCTNESS. Every landmark in the pinned cases "
        "is found by `find`, which answers the FIRST occurrence; a repeated "
        "byte makes a landmark ambiguous and the cases then measure offsets "
        "that are not the ones they name. The suite's own precondition, armed "
        "— a pinned case over a ruler somebody edited is a pinned case about a "
        "different document",
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
    """(path, binary, flags) for each suite. Both are pure ViewModel."""
    return [
        (LAWS, "/tmp/plat32-mutation-laws", VM_FLAGS),
        (EX, "/tmp/plat32-mutation-examples", VM_FLAGS),
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


def run_suite(suite_list: list) -> RunResult:
    res = RunResult(rc=0)
    for path, binary, flags in suite_list:
        run_one(path, binary, flags, res)
    return res


# BOTH SPELLINGS — a count constant written on its own `const` line and one
# written as a MEMBER of a `const` block. PLAT-31 found the second spelling
# invisible to a regex anchored on the keyword, which is §10.3's own failure
# mode inside the check for it.
COUNT_CONSTANT = re.compile(
    r"^[ \t]*(?:const[ \t]+)?(ExpectedAssertions|ExpectedCases|"
    r"ForbiddenInOracleCount|StreamShapeCount|RemoteSiteCount|StreamSteps|"
    r"GroupingKeystrokes|GroupingKinds|Keystrokes|FuzzRounds|"
    r"MaxHistoryDepth|MaxSelectionsPerEvent|NewGroupDelayMs|LawCount)\*?"
    r"[ \t]*=[ \t]*(\d+)", re.M)
# THE NAME LIST AND THE VALUE LIST ARE NOT THE SAME LIST, AND THE SPLIT IS
# DELIBERATE — it was taken after this scan refused three arms on its first run.
#
# §10.3's rule is about a count that "changes every time a test is added, which
# is the most frequent edit any suite receives": an arm quoting one is present
# today and unkillable on the next commit. `ExpectedAssertions`, a sweep's
# cardinality and `CHECKS:` are all of that kind, and no arm may name them.
#
# `NewGroupDelayMs`, `MaxHistoryDepth`, `MaxSelectionsPerEvent` and
# `StreamSteps` are NOT: they are published product and generator policy, and
# two of the six killers §3.6 publishes are about the lines that read them —
# `M6` is *"always group"* and there is no spelling of that mutation which does
# not mention the window. Forbidding the NAME there would be §35's collision
# ("a needle that has earned its place is worth more than a name") resolved the
# wrong way, and a needle that loses its constant to a rename is caught by the
# occurrence scan below anyway.
#
# **Their VALUES stay forbidden**, because an incidental digit in a needle that
# happens to equal a declared constant is the collision §10.3 is really about
# and is invisible to every other check here. `GroupingKinds` moved from a
# literal to a derivation for exactly that reason.
COUNT_NAMES = ("ExpectedAssertions", "ExpectedCases", "ForbiddenInOracleCount",
               "GroupingKeystrokes", "GroupingKinds", "Keystrokes",
               "FuzzRounds", "LawCount", "CHECKS:")


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
    ('test "LAW-H1 x " & $shape:', LAWS, "THE LAW-H1 CELL"),
    ('test "LAW-H6 x " & $shape:', LAWS, "THE LAW-H6 CELL"),
    ('test "FUZZ-4 x corpus class " & $(classIndex + 1):', LAWS,
     "THE FUZZ-4 CELL"),
    ('test "delivery " & order.id & " x " & $site:', EX,
     "THE DELIVERY-MATRIX CELL"),
    ('test "rebased redo x " & $site &', EX, "THE REBASED-REDO CELL"),
]

COMPOSED_PREFIXES = ("LAW-H", "FUZZ-4 x corpus class ", "delivery ",
                     "rebased redo x ", "grouping x ")


def check_killer_names(problems: int) -> int:
    """Every killer names a case the suites actually instantiate."""
    bodies = {p: read_source(p) for p in (LAWS, EX)}
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

    # EVERY SUBJECT CARRIES AT LEAST ONE ARM. A subject list longer than the
    # set of things anybody mutated is a harness whose coverage is a list of
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
    # **ITS VERDICT IS ACTED ON, NOT PRINTED.** `baseline` below is snapshotted
    # from the CURRENT tree — without this refusal a run started on an
    # already-mutated file restores TO the mutation and reports itself clean.
    if not check_control_hashes():
        print("REFUSING TO RUN: a control digest moved (§32). Re-run "
              "--needle-scan, review the tree, then --record-control-hashes.")
        return 1

    suite_list = suites()

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
