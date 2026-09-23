#!/usr/bin/env python3
"""PLAT-31's arming — the mutation harness for the keymap layer: the resolver,
the two models, the product default, the shared key-name predicate, the
`DIFF-4` population and the two suites over them.

    python3 src/frontend/viewmodel/tests/unit/run-plat31-keymap-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --enumerate-touched
    python3 ... --only=M1,U2

WHAT THIS IS, AND WHY THERE IS NO `LAW-*` COLUMN TO READ
=======================================================
`Editor-Model-Conformance-Suite.md` §3 publishes `LAW-A*` … `LAW-X*` and none
of them is PLAT-31's, exactly as none of them was PLAT-30's. So
`ci/test/editor-model-case-floor.sh` runs no law-table oracle for this
milestone, and the campaign's rule — *a published claim needs a published
killer, performed* — is discharged here: **one arm per claim the milestone
makes**, each naming the case that dies.

The claims, and the arms that kill them, in the milestone's own order:

  | claim | arm |
  |---|---|
  | the resolver's outcome is a closed set reached across the scope | `M7` |
  | modal state is the EDITOR's, not the keymap's | `M6`, `M8` |
  | the text-entry rule reuses `keyCharacter`, not `isPrintableKey` | `M2`, `M12` |
  | the Vim keymap composes through operator-pending | `M9` |
  | the Kakoune keymap is noun-then-verb, with no operator-pending | `M10` |
  | the configuration format reports every malformed line | `M1` |
  | conflict detection: no chord bound twice, none a proper prefix | `M4`, `M5` |
  | a pending prefix times out, at its bound | `M3` |
  | **a keymap-private operation is a red gate** | `M1` |
  | the default does not move | `M11` |
  | `DIFF-4`'s two paths are two paths | `G1`, `G4`, `U2` |
  | the task set can grow and cannot silently shrink | `G3` |

Verification-Harness-Traps, applied rather than cited:

  * §36  — the milestone NAMES its own killing mutation: *"A MUTATION ARM THAT
           ADDS A KEYMAP-PRIVATE OPERATION. The check above must redden.
           Without it the subset assertion is satisfied by a keymap that adds
           nothing yet, which is every keymap on the day it is written."*
           That is `M1`, and it is the first arm in the table because it is the
           one the milestone asked for by name.
  * §30a — `U2` empties the differential's SOURCE scan, which is the only
           instrument that can see the Vim arm resolving through the Kakoune
           keymap. An arm that made the scan vacuous and was not noticed would
           mean the scan is decoration.
  * §30b — `M12` mutates `src/common/key_names.nim`, the ONE function both
           keymaps call. The mutation goes on the function rather than on
           either caller, which is what makes the debugger keymap's arms and
           the editing keymap's arms evidence about each other.
  * §34  — `G1` makes one row's two key sequences identical and `G2` moves a
           task's caret to a landmark where its object is absent. Both are the
           population defect this milestone is most likely to ship, and both
           were REAL: the table shipped with a row whose two paths coincided
           and a row whose "identity" had never been executed.
  * §32  — `--needle-scan` refuses to run when any needle is absent or
           ambiguous, and the full run refuses unless the scan is clean AND
           the control digests have not moved.
  * §32f — every read and every write is BYTES.
  * §32h — `finally` is not a signal handler.
  * §10.3 — no arm's needle may quote a count. The scan reads every declared
           count constant out of the subjects and REJECTS an arm whose needle
           contains one of their names or one of their values.
  * §4   — the control-digest guard's verdict is ACTED ON.

EIGHT SUBJECTS, AND THREE OF THEM ARE THE HARNESS'S OWN EVIDENCE
---------------------------------------------------------------
The product is five modules — the resolver, the two models, the default, and
the shared key-name decoder. The population is a generator. The suites are two.
A suite that cannot fail is this campaign's recurring defect, so the population
and the suites are armed like anything else: `G*` performs a defect the
population ACTUALLY HAD, and `U*` empties a guard the suite rests on.

BOTH SUITES RUN FOR EVERY ARM. They share the product modules, so an arm on
`editing_keymap.nim` can redden either; running only "the suite an arm belongs
to" would be the harness deciding in advance which case is allowed to notice,
which is the MISDIRECTED verdict made unavailable.

THIS HARNESS NEEDS NO LANE FLAGS. Unlike PLAT-30's, whose third suite links
`isonim_tui`, both suites here are pure ViewModel and compile with
`--path:src/frontend/viewmodel` alone. Said rather than left to be noticed,
because the absence of the `tui_lane_flags` block is a difference from the
harness this one is modelled on.
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
RESOLVER = "src/frontend/viewmodel/keymap/editing_keymap.nim"
VIM = "src/frontend/viewmodel/keymap/vim_keymap.nim"
KAK = "src/frontend/viewmodel/keymap/kakoune_keymap.nim"
PRODUCT = "src/frontend/viewmodel/keymap/product_keymap.nim"
KEYNAMES = "src/common/key_names.nim"
TASKS = "src/frontend/viewmodel/tests/generators/keymap_task_set.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_keymap_laws.nim"
DIFF = "src/frontend/viewmodel/tests/unit/test_editor_keymap_differential.nim"

TOUCHED = [RESOLVER, VIM, KAK, PRODUCT, KEYNAMES, TASKS, LAWS, DIFF]

CONTROL_HASHES = HERE / "plat31-keymap-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P31_SUITE_TIMEOUT", "2400"))
VM_FLAGS = ["--hints:off", "--warnings:off", "--path:src/frontend/viewmodel"]

RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*(.*?)\s*(?:\x1b\[[0-9;]*m)*$")

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# Two families are COMPOSED at run time — the per-task `DIFF-4` cells and the
# per-scope conflict cells — and the scan checks the TEMPLATE rather than
# searching for the whole string.
# ---------------------------------------------------------------------------

PROBE_UNBOUND = "the `erNothing` probe key is bound by no model in any scope"
SCOPE_PRODUCT = "the scope is five dimensions and the sweep enumerates their whole product"
OUT_OP_PANE = "outcome `operation` x pane"
OUT_CHAR_MODEL = "outcome `character` x model"
SPACE_BY_NAME = "`Space` — `keyCharacter` and `isPrintableKey` disagree, by name"
SPACE_CHARACTER = "under text entry, `Space` resolves to the CHARACTER and not the name"
BOUND_EXACTLY = "AT the bound exactly: the prefix survives"
CONFLICTS_CLEAN = "the clean keymaps report NOTHING, in every one of the 168 scopes"
DUP_VIM_NORMAL = "a planted DUPLICATE is named, in vim/normal"
PRE_VIM_NORMAL = "a planted PREFIX is named, in vim/normal"
COVERED_PLUS_FILED = "every model: covered + filed == every operation, with the two sets DISJOINT"
COVERAGE_GAP = "every model: the coverage GAP is empty"
NO_PRIVATE_OP = "every model: no reachable operation is keymap-PRIVATE"
LAYER_REACHED = "the layer reaches two operations the binding tables do not always name"
APPLY_ONE_FIELD = "`applyResolution` assigns exactly ONE EditorState field, and it is `pending`"
ONE_PREDICATE = "the text-entry predicate is ONE function with two callers (§30a)"
DEFAULT_THIRTEEN = "the product default lifts thirteen rows and the fourteenth is the character arm"
COUNT_IS_STATE = "a count is editor state: a trie entry cannot hold one"
TASK_CARDINALITY = "the task set is its declared cardinality, and no id appears twice"
T34_KEYS = "§34 — every row's two KEY sequences are distinct, as an equality"
T34_OPS = "§34 — and the sharper half: the two OPERATION sequences also differ"
T30A_SOURCE = "§30a — this file's body names the two constructors, once each"
T30A_VALUE = "§30a, at the value level — each arm records what the other cannot reach"
FILED_BY_KAKOUNE = "everything Vim reaches and Kakoune does not is filed BY KAKOUNE"
SETS_DIFFER = "the two sets genuinely differ — the differential has a subject"
DIFF_DELETE_LINE = "DIFF-4 delete-line / vim"
COUNT_APPLIED = "a count is APPLIED to the motion, and the repeat is the `extend-` form"
DIFF_COUNT_3 = "DIFF-4 count-3-delete-word / vim"
DIFF_INNER_PARENS = "DIFF-4 inner-parens / vim"

NAMED_CASES = [
    PROBE_UNBOUND, SCOPE_PRODUCT, OUT_OP_PANE, OUT_CHAR_MODEL,
    SPACE_BY_NAME, SPACE_CHARACTER, BOUND_EXACTLY, CONFLICTS_CLEAN,
    DUP_VIM_NORMAL, PRE_VIM_NORMAL, COVERED_PLUS_FILED, COVERAGE_GAP,
    NO_PRIVATE_OP, LAYER_REACHED, APPLY_ONE_FIELD, ONE_PREDICATE,
    DEFAULT_THIRTEEN, COUNT_IS_STATE, TASK_CARDINALITY, T34_KEYS, T34_OPS,
    T30A_SOURCE, T30A_VALUE, FILED_BY_KAKOUNE, SETS_DIFFER,
    DIFF_DELETE_LINE, DIFF_COUNT_3, DIFF_INNER_PARENS, COUNT_APPLIED,
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
        "M1", VIM,
        '  r.add eb(@["u"], "undo", {emNormal})\n',
        '  r.add eb(@["u"], "undo", {emNormal})\n'
        '  r.add eb(@["Ctrl+j"], "undo-everything", {emNormal})\n',
        NO_PRIVATE_OP,
        "**A KEYMAP-PRIVATE OPERATION, WHICH IS THE ARM THE MILESTONE ASKS "
        "FOR BY NAME.** *'Without it the subset assertion is satisfied by a "
        "keymap that adds nothing yet, which is every keymap on the day it is "
        "written.'* Note what does NOT move: every existing binding still "
        "resolves, the trie reports no conflict, and `DIFF-4`'s forty-one "
        "tasks all still reach one document, because no task types `Ctrl+j`. "
        "What refuses it is `unpublishedOperations`, which checks every "
        "reachable name against `operationNamed` rather than against a second "
        "list — so the gate is the VOCABULARY and not a copy of it",
    ),
    Arm(
        "M2", RESOLVER,
        "  if scope.textEntry and pending.chords.len == 0 and isTextKey(key):\n"
        '    return EditingResolution(kind: erCharacter, operation: "", args: OpArgs(),\n'
        "                             character: keyCharacter(key), spelling: key,\n",
        "  if scope.textEntry and pending.chords.len == 0 and isPrintableKey(key):\n"
        '    return EditingResolution(kind: erCharacter, operation: "", args: OpArgs(),\n'
        "                             character: key, spelling: key,\n",
        SPACE_CHARACTER,
        "**THE TEXT-ENTRY SHADOW USES `isPrintableKey`, WHICH IS THE DEFECT "
        "THIS PRODUCT HAS ALREADY SHIPPED ONCE.** `keyName(\" \")` is the "
        "five-letter name `Space`, `isPrintableKey` answers false for it, and "
        "under that spelling a space typed at the `:` prompt resolved to "
        "nothing — `:goto 4500` could not be typed at all. Every other key in "
        "the alphabet behaves identically under both spellings, which is why "
        "the milestone asks for the rule to be asserted on `Space` "
        "SPECIFICALLY AND BY NAME: a suite that swept printable letters would "
        "be green",
    ),
    Arm(
        "M3", RESOLVER,
        "  if pending.chords.len > 0 and nowMs - pending.startedMs > EditingPendingTimeoutMs:\n",
        "  if pending.chords.len > 0 and nowMs - pending.startedMs >= EditingPendingTimeoutMs:\n",
        BOUND_EXACTLY,
        "THE TIMEOUT BOUNDARY MOVES BY ONE MILLISECOND. `>` becomes `>=`, so a "
        "prefix that arrives at EXACTLY the published bound is discarded "
        "instead of completed. Nothing at a plausible distance from the bound "
        "can see it — a case at half the timeout and a case at twice it are "
        "both still green — which is why the milestone asks for the timeout "
        "*'asserted at its bound'* and why the bound is a named constant "
        "rather than a number in a case",
    ),
    Arm(
        "M4", RESOLVER,
        "  if t.nodes[cur].binding >= 0:\n"
        '    let seqText = b.chords.join(" ")\n'
        "    if seqText notin t.duplicates: t.duplicates.add seqText\n"
        "  else:\n"
        "    t.nodes[cur].binding = index\n",
        "  t.nodes[cur].binding = index\n",
        DUP_VIM_NORMAL,
        "**THE DUPLICATE DETECTOR IS DELETED AND THE SECOND ROW SILENTLY "
        "WINS.** This is §2.4's `move-line-up` defect one layer up: two rows "
        "claim one chord, the table resolves to whichever was inserted last, "
        "and nothing says so. The clean keymaps have no duplicate, so the "
        "NEGATIVE sweep over all 168 scopes stays green — which is exactly why "
        "the detector has to be asserted on a PLANTED conflict, and why the "
        "planted case also checks that the FIRST row still wins",
    ),
    Arm(
        "M5", RESOLVER,
        "    if node.binding >= 0 and node.children.len > 0:\n",
        "    if node.binding >= 0 and node.children.len > t.nodes.len:\n",
        PRE_VIM_NORMAL,
        "THE PREFIX DETECTOR STOPS FINDING ANYTHING. A node that carries a "
        "binding AND has children is a sequence that can never be typed — the "
        "resolver is still waiting for the longer one — and after this arm the "
        "condition is unsatisfiable. It is the second of §4.2's two shapes, "
        "armed separately from the first because *a detector that finds "
        "nothing passes on an empty keymap* and one arm cannot prove two "
        "shapes",
    ),
    Arm(
        "M6", RESOLVER,
        '          run("cancel-operator", OpArgs())\n',
        "          state.count = 0\n"
        '          state.pendingOperator = ""\n',
        APPLY_ONE_FIELD,
        "**THE TRANSIENTS ARE CLEARED BY ASSIGNMENT INSTEAD OF THROUGH THE "
        "PUBLISHED OPERATION.** The documents are identical, every task still "
        "reaches the same end state, and every set equality still holds — "
        "because the STATE is the same. What changes is that the recorded "
        "operation sequence is no longer the whole of the layer's effect; it "
        "becomes a LOG BESIDE the effect, and `DIFF-4` compares that sequence. "
        "No assertion about an answer can see this, which is why the claim is "
        "checked against the SOURCE and why that check had to be armed",
    ),
    Arm(
        "M7", RESOLVER,
        "    (bs.panes == {} or scope.pane in bs.panes)\n",
        "    (bs.panes == {} or true)\n",
        OUT_OP_PANE,
        "THE PANE DIMENSION STOPS SCOPING ANYTHING. Every editing chord now "
        "fires while the call-stack pane owns the keyboard — §4.3's second "
        "dimension, gone. The document assertions cannot see it (no task "
        "changes pane) and neither can the conflict detector (the same rows "
        "are admitted everywhere, so no NEW duplicate appears). What sees it "
        "is the outcome profile, which is an EQUALITY over the dimension's "
        "values rather than a tick that the outcome was reached somewhere",
    ),
    Arm(
        "M8", RESOLVER,
        "                  else: max(1, state.count)\n",
        "                  else: 1\n",
        COUNT_APPLIED,
        "**THE COUNT IS READ AND THEN IGNORED.** `3dw` deletes one word. This "
        "is the milestone's own risk section performed — *'Vim mode ships as a "
        "list of bindings that covers the demo and fails at the first composed "
        "command'* — and it is why composed commands with counts are a stated "
        "requirement of the task set rather than a nicety. A task set of "
        "single keystrokes is green under this arm, and so is every scope, "
        "conflict and coverage assertion in the other suite.\n\n"
        "**THIS ARM WAS AIMED AT A `DIFF-4` COUNT TASK AND CAME BACK "
        "MISDIRECTED, WHICH IS THE MOST USEFUL THING THIS HARNESS DID.** The "
        "count is applied in `applyResolution`, which BOTH keymaps share, so "
        "the mutation degrades both arms identically: the two end documents "
        "still agree, both operation sequences are still subsets of their own "
        "reachable sets, and every per-task assertion passes. It died only in "
        "`assertion count` — a tally noticing that fewer operations ran, not a "
        "case noticing the product is wrong. A differential can only see what "
        "DIFFERS between its sides; a defect below the point where the two "
        "paths diverge is invisible to it by construction. The repair was to "
        "write the missing law, not to re-aim the arm at the tally",
    ),
    Arm(
        "M9", VIM,
        "  for key in LinewiseAroundOperatorKeys:\n"
        '    r.add eb(@[key], "select-around-line", {emOperatorPending})\n',
        "  for key in LinewiseAroundOperatorKeys:\n"
        '    r.add eb(@[key], "select-line", {emOperatorPending})\n',
        DIFF_DELETE_LINE,
        "**THE DEFECT `DIFF-4` ACTUALLY FOUND, PUT BACK.** `dd` resolves "
        "through `select-line`, whose span is the line's TEXT with the "
        "terminator excluded, so it leaves an empty line behind instead of "
        "removing the line. Everything internal to the Vim keymap stays green: "
        "the chord resolves, the operation is published, `covered + filed == "
        "224` still holds and the trie reports no conflict. It took the OTHER "
        "keymap — Kakoune's `Ctrl+x`, one published `delete-line` — "
        "disagreeing by one byte on all eighteen documents to see it, which is "
        "the differential earning its place in §8's table",
    ),
    Arm(
        "M10", KAK,
        '  r.add eb(@["d"], "delete-selection", KakouneLiveModes)\n',
        '  r.add eb(@["d"], "begin-operator", KakouneLiveModes,\n'
        '           OpArgs(operator: "delete-selection"))\n',
        T30A_VALUE,
        "**KAKOUNE GROWS AN OPERATOR-PENDING STATE, WHICH IS THE ONE THING IT "
        "IS DEFINED BY NOT HAVING.** §2.1: Kakoune is noun-then-verb. This arm "
        "makes it verb-then-noun, and the interesting part is what survives: "
        "the two keymaps are still two tables, the two key sequences are still "
        "distinct, and `begin-operator` is now reachable under BOTH models — "
        "so the §30a witness, which exists precisely to catch one arm "
        "resolving through the other's keymap, is what dies. The filed row "
        "calling this *'THE DEFINING ABSENCE'* becomes an overlap and the "
        "disjointness equality dies with it",
    ),
    Arm(
        "M11", PRODUCT,
        "    if row.key == DefaultEditKey: continue   # the `else` arm — see the header\n",
        "    if false: continue   # the `else` arm — see the header\n",
        DEFAULT_THIRTEEN,
        "THE FOURTEENTH ROW BECOMES A BINDING. `TuiEditBindings`'s last row has "
        "the EMPTY key and names `insert-text` — `applyEditKey`'s `else` arm, "
        "which fires only when the key stands for a character. In the resolver "
        "that is §4.1's CHARACTER outcome and not a row at all, so binding it "
        "means the empty string is now a chord in the trie. *'The default does "
        "not move'* is the claim, and a fourteenth binding is it moving",
    ),
    Arm(
        "M12", KEYNAMES,
        '  if name == "Space": " "\n',
        '  if false: " "\n',
        SPACE_BY_NAME,
        "**THE ARM GOES ON THE SHARED FUNCTION, WHICH IS THE WHOLE POINT OF "
        "THERE BEING ONE** (§30b). `keyCharacter` loses its `Space` arm and "
        "collapses into `isPrintableKey`. Because `tui/app/input/keymap.nim` "
        "and `viewmodel/keymap/editing_keymap.nim` call the SAME function, "
        "this single mutation is evidence about both keymaps at once — which "
        "is the property a second, re-derived spelling of these five lines "
        "would have destroyed, and the one §30a calls *'the worst instance … a "
        "whole re-derived module'*",
    ),

    # =======================================================================
    # THE POPULATION
    # =======================================================================
    Arm(
        "G1", TASKS,
        '              caret: tcCamelStart, vimKeys: @["d", "w"],\n'
        '              kakouneKeys: @["w", "d"],\n',
        '              caret: tcCamelStart, vimKeys: @["d", "w"],\n'
        '              kakouneKeys: @["d", "w"],\n',
        T34_KEYS,
        "**§34, IN THE PLACE THIS MILESTONE ACTUALLY MEETS IT.** A row whose "
        "two key sequences are the SAME compares a thing with itself: `d w` "
        "under Vim and `d w` under Kakoune would agree about the end document "
        "for a reason that has nothing to do with either keymap being right. "
        "The per-task cases would not notice — the documents genuinely agree — "
        "so the distinctness is asserted over the whole population as an "
        "EQUALITY (`41 of 41`) rather than spot-checked",
    ),
    Arm(
        "G2", TASKS,
        '  EditingTask(id: "inner-parens", family: tfObject, caret: tcParensInner,\n',
        '  EditingTask(id: "inner-parens", family: tfObject, caret: tcLine0Mid,\n',
        DIFF_INNER_PARENS,
        "§34 IN THE LANDMARK RATHER THAN IN THE KEYS. The caret moves off the "
        "parenthesised span, so `d i (` has no object to select and BOTH arms "
        "become no-ops — which means the end documents still agree, the "
        "operation sequences still differ, every name is still published, and "
        "every assertion about the pair is still true. The row measures "
        "nothing. What refuses it is the per-task requirement that the "
        "document actually MOVED on every document, with the one deliberate "
        "identity row named",
    ),
    Arm(
        "G3", TASKS,
        '  EditingTask(id: "delete-word-backward", family: tfOperatorMotion,\n'
        '              caret: tcCamelEnd, vimKeys: @["d", "b"],\n'
        '              kakouneKeys: @["b", "d"], note: ""),\n',
        "",
        TASK_CARDINALITY,
        "A TASK ROW IS DELETED. The milestone's words: *'the task set is a "
        "data file whose length is checked, so it can GROW but cannot SILENTLY "
        "SHRINK to the four tasks somebody demoed.'* Every remaining row still "
        "passes and every set equality still holds; the population is simply "
        "smaller, which is the one thing a suite of per-row cases cannot "
        "notice by itself. This arm is why the cardinality is a declared "
        "constant rather than a `len` nobody compares",
    ),
    Arm(
        "G4", TASKS,
        '    "delete-char-forward",\n'
        '    "delete-char-backward",\n'
        '    "join-then-delete-char",\n',
        '    "delete-char-forward",\n'
        '    "delete-char-backward",\n',
        T34_OPS,
        "THE NAMED EXCEPTION LIST LOSES A MEMBER. `CoincidentOperationTasks` "
        "records the three rows whose two DISTINCT key sequences drive ONE "
        "operation sequence — the class §34's second bullet exists to separate "
        "— and the list is compared BY NAME rather than only by count, because "
        "a count written as *'the whole set minus a few'* is satisfied by any "
        "few. This arm is the reason the comparison is a list equality; it "
        "also moves the divergence count, so both halves of that case fire",
    ),

    # =======================================================================
    # THE SUITES
    # =======================================================================
    Arm(
        "U1", LAWS,
        "          for textEntry in [false, true]:\n",
        "          for textEntry in [false]:\n",
        OUT_CHAR_MODEL,
        "**THE SCOPE SWEEP LOSES A DIMENSION'S SECOND VALUE.** §35's arm, on "
        "this milestone's own population: the enumeration still runs, still "
        "builds tries, still resolves keys and still reports every outcome it "
        "finds — over HALF the scopes. `erCharacter` is reachable only under "
        "text entry, so it becomes reachable nowhere, and the four profile "
        "cases about it are asserting over an empty set. It is caught because "
        "the profile is an equality against a DECLARED set rather than a "
        "non-emptiness check, and because the sweep's cardinality is asserted "
        "as a product of its five dimensions",
    ),
    Arm(
        "U2", DIFF,
        '      if text.startsWith("#"): continue\n',
        "      continue\n",
        T30A_SOURCE,
        "**THE §30a SOURCE SCAN IS MADE VACUOUS**, which is §4's shape applied "
        "to the one instrument that can see the substitution this file is "
        "about. The comment stripper starts discarding every line, `Body` "
        "becomes empty, and every `count(...) == 1` over it becomes "
        "`0 == 1` — so it is caught. Had the scan been written as *'the Vim "
        "constructor does not appear twice'* it would have become vacuously "
        "true instead, which is why every arm of it is an equality on a count "
        "rather than an absence",
    ),
    Arm(
        "U3", LAWS,
        "  let a = src.find(opening)\n"
        "  if a < 0: return \"\"\n",
        "  let a = -1\n"
        "  if a < 0: return \"\"\n",
        APPLY_ONE_FIELD,
        "THE SOURCE-SCAN HELPER MATCHES NOTHING. §4, verbatim: *'a parser that "
        "matched nothing satisfies every check written over what it read.'* "
        "All three source claims in that suite read their subject through this "
        "one function, so emptying it would turn three cases green for free — "
        "and it does not, because each of them asserts its body is non-empty "
        "before asserting anything about its contents. This arm is what makes "
        "that a guard rather than a habit",
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
        (LAWS, "/tmp/plat31-mutation-laws", VM_FLAGS),
        (DIFF, "/tmp/plat31-mutation-diff", VM_FLAGS),
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


# **BOTH SPELLINGS, AND THE SECOND ONE IS WHY THIS DIFFERS FROM PLAT-30's.**
# The older harnesses match `const <Name> = <n>` only. This milestone's two
# most load-bearing counts — `TaskSetCardinality` and
# `DivergentOperationTasks` — are MEMBERS of a `const` block, written
# `  TaskSetCardinality* = 41` with an indent and an export marker and no
# `const` on their own line, so a regex anchored on the keyword saw neither.
# Measured: the scan reported three count constants and both of these were
# missing, which would have let an arm quote `41` and be silently unkillable
# on the next commit that grows the task set — precisely §10.3's failure mode,
# inside the check for it.
COUNT_CONSTANT = re.compile(
    r"^[ \t]*(?:const[ \t]+)?(ExpectedAssertions|ExpectedCases|"
    r"ExpectedScenarioDocs|ExpectedErrorKinds|TaskSetCardinality|"
    r"DivergentOperationTasks|EditingKeymapErrorKindCount)\*?"
    r"[ \t]*=[ \t]*(\d+)", re.M)
COUNT_NAMES = ("ExpectedAssertions", "ExpectedCases", "ExpectedScenarioDocs",
               "ExpectedErrorKinds", "TaskSetCardinality",
               "DivergentOperationTasks", "EditingKeymapErrorKindCount",
               "CHECKS:")


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
    ('test "DIFF-4 " & t.id & " / vim":', DIFF, "THE DIFF-4 VIM CELL"),
    ('test "DIFF-4 " & t.id & " / kakoune":', DIFF, "THE DIFF-4 KAKOUNE CELL"),
    ('test "a planted DUPLICATE is named, in " & label:', LAWS,
     "THE PLANTED-DUPLICATE CELL"),
    ('test "a planted PREFIX is named, in " & label:', LAWS,
     "THE PLANTED-PREFIX CELL"),
]

COMPOSED_PREFIXES = ("DIFF-4 ", "a planted DUPLICATE is named, in ",
                     "a planted PREFIX is named, in ")


def check_killer_names(problems: int) -> int:
    """Every killer names a case the suites actually instantiate."""
    bodies = {p: read_source(p) for p in (LAWS, DIFF)}
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

    # EVERY SUBJECT CARRIES AT LEAST ONE ARM. Eight subjects and an arm table
    # that reached only four would be a harness whose coverage is a list of
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
