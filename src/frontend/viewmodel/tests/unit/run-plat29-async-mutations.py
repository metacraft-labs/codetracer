#!/usr/bin/env python3
"""PLAT-29's arming — the mutation harness for the asynchronous boundary, the
document version and the import-closure check.

    python3 src/frontend/viewmodel/tests/unit/run-plat29-async-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=M1,A4

WHAT THIS IS, AND WHY EVERY PART OF IT IS HERE
==============================================
Editor-Model-Conformance-Suite.md §3 admits a law only when it names the
mutation that must kill it. §3.5 names five. This harness PERFORMS each of
them and requires a NAMED case to go red — not "the suite failed", which is
satisfied by a mutation that breaks the build.

Verification-Harness-Traps, applied rather than cited:

  * §32   — a needle lost under a later repair is silently unkillable, so
            `--needle-scan` refuses to run when any arm's needle is absent or
            ambiguous, and the full run refuses unless the scan is clean.
  * §32f  — every read and every write is BYTES, not text: a universal-newline
            translation on the way in and out would rewrite bytes an arm did
            not ask to change.
  * §32h  — `finally` is not a signal handler, so SIGTERM/SIGINT/SIGHUP
            restore the subject before exiting.
  * §10.3 — no arm's needle may quote a count. The scan reads every declared
            count constant out of the subjects and REJECTS an arm whose needle
            contains one of their names or one of their values, and refuses to
            run at all when no subject declares a count (a scan that found
            nothing satisfies every "must not contain" written over it).
  * §4    — THE CONTROL-DIGEST GUARD'S VERDICT IS ACTED ON. PLAT-27's harness
            was found returning a bool nobody read; PLAT-28 repaired it and
            this one inherits the repair rather than the defect. `baseline` is
            snapshotted from the CURRENT tree, so without the refusal a run
            started on an already-mutated file restores TO the mutation and
            reports itself clean.
  * §36   — a published killing mutation is a claim about the ASSERTION and
            not only about the code. `M5` is this milestone's finding: the
            published killer for `LAW-V5` — *map both ends of the evidence
            region with the same side* — was UNOBSERVABLE against the law as
            first written, because the sentinel oracle's region is the bytes
            between two markers and an insert at either edge lands inside it
            BY DEFINITION. The oracle and the model legitimately disagree
            there. The repair is to the ASSERTION and never to the killer:
            `LAW-V5 SIDES` measures the two sides directly, against the length
            of the text the case itself inserted.

FIVE SUBJECTS AND THREE OF THEM ARE THE HARNESS'S OWN EVIDENCE. The product is
two modules; the population is a generator; the suites are two; and the GATE is
a shell script. A gate that cannot fail is this campaign's recurring defect, so
the gate is armed like any other subject — five arms on it, and one on the
allow-list table it reads.

COUNT THE ARMS BY THEIR `subject`, NOT BY THEIR NAME, which is PLAT-28's own
correction. `U4`'s subject is the EXAMPLES SUITE even though the defect it
performs is a population defect; `A1`'s subject is the ADMISSION TABLE even
though it reddens the gate.

ALL THREE SUITES RUN FOR EVERY ARM. They share the product modules, so an arm
on `reconcile.nim` can redden any of them; running only "the suite an arm
belongs to" would be the harness deciding in advance which case is allowed to
notice, which is the MISDIRECTED verdict made unavailable.
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
VERSION = "src/frontend/viewmodel/editor/document_version.nim"
RECONCILE = "src/frontend/viewmodel/editor/reconcile.nim"
GENERATOR = "src/frontend/viewmodel/tests/generators/async_generator.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_async_laws.nim"
EX = "src/frontend/viewmodel/tests/unit/test_editor_async_examples.nim"
CLOSURE = "src/frontend/viewmodel/tests/unit/test_editor_async_closure.nim"
GATE = "ci/test/editor-import-closure.sh"
ADMISSION = "src/common/editor_core_admission.nim"

TOUCHED = [VERSION, RECONCILE, GENERATOR, LAWS, EX, CLOSURE, GATE, ADMISSION]

CONTROL_HASHES = HERE / "plat29-async-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P29_SUITE_TIMEOUT", "2400"))
LAWS_BIN = os.environ.get("CT_P29_LAWS_BIN", "/tmp/plat29-mutation-laws")
EX_BIN = os.environ.get("CT_P29_EX_BIN", "/tmp/plat29-mutation-examples")
CLOSURE_BIN = os.environ.get("CT_P29_CLOSURE_BIN", "/tmp/plat29-mutation-closure")

NIM_FLAGS = ["--hints:off", "--warnings:off", "--path:src/frontend/viewmodel"]

SUITES = [(LAWS, LAWS_BIN), (EX, EX_BIN), (CLOSURE, CLOSURE_BIN)]

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# Two families are COMPOSED at run time and the scan checks the TEMPLATE rather
# than searching for the whole string:
#   `LAW-V1 and FUZZ-5 x class <n>`
#   `LAW-V2 <producer> x <outcome>`
# ---------------------------------------------------------------------------

V1_CLASS1 = "LAW-V1 and FUZZ-5 x class 1"
V2_INLINE_DROP = "LAW-V2 pkInlineValues x roDropped"
V2_TREE_MAP = "LAW-V2 pkTreeSitter x roMapped"
V3 = "LAW-V3: a result whose evidence the delta edited is never applied"
V4 = "LAW-V4: drop-or-rebase is the producer's declared rule, two-sidedly"
V5_SIDES = ("LAW-V5 SIDES: text inserted at either edge is not swallowed into "
            "the region")
V5_ORACLE = "LAW-V5: a mapped result's positions are where the ORACLE finds them"

N_CLAMP = "NO CLAMP REPAIRS A VERSION — every unreachable path RAISES"
N_FORGOTTEN = "A FORGOTTEN VERSION IS A COUNTED OUTCOME, NOT AN EXCEPTION"
N_LAWSET = "the law set's cardinality is asserted and every law names its killer"
N_ORACLE = "THE ORACLE IS NOT THE RECONCILER — §30a, on the BODY"
N_RECON = "THE RECONCILER OWNS NO MAPPING OF ITS OWN — §30a, from the other side"
N_DIR = "the scan's subject list is the directory, not a list somebody maintains"
N_NOTINT = "THE VERSION IS NOT AN INT — arithmetic on it does not compile"

P_SEED = ("the seed, the realised shapes and the schedule size are printed and "
          "asserted")
P_SHAPES = "the four edit shapes are EQUALITIES against the schedule, each witnessed"
P_CLASSIFIERS = ("the two classifiers agree about every drawn edit, and neither "
                 "is the constructor")
P_HIST = "the reconciliation histogram realises all twelve cells, as EQUALITIES"

E_STORM = "THE DROP COUNT IS NON-ZERO UNDER AN EDIT STORM"
E_ZERO = "AND IT IS EXACTLY ZERO WHEN THE DOCUMENT DOES NOT MOVE"
E_FORGOTTEN = "drVersionForgotten is realised, by name"
E_CARRIED = "drCarriedDeleted is realised, by name"
E_REFUSED = "a drop reason that disagrees with its outcome is refused, not reconciled"
E_LATENCY = "EDIT LATENCY AT LOAD 0, TAKE 1"

C_REAL = "THE EDITOR MODEL'S CLOSURE IS CLEAN, AND IT IS NOT A CLOSURE OF ONE"
C_R1 = "ROUTE 1 — a NEWLINE-CONTINUED import is seen"
C_R2 = ("ROUTE 2 — an import sharing its line with a BLOCK COMMENT is REFUSED, "
        "not missed")
C_R3 = ("ROUTE 3 — one hop of INDIRECTION, which a per-file scan cannot see at "
        "all")
C_R4 = "ROUTE 4 — a FOREIGN-FUNCTION PRAGMA, which needs no import"
C_R5 = ("ROUTE 5 — THE CALL SITE rather than the rendering: a refusal is a "
        "finding")
C_R6 = "ROUTE 6 — `export … except` narrows one path and not the other"
C_R7 = "ROUTE 7 — THE PLANTED IMPORT MUST REDDEN IT"
C_CONTROL = "THE CONTROL — the same tree with nothing planted is GREEN"

NAMED_CASES = [
    V1_CLASS1, V2_INLINE_DROP, V2_TREE_MAP, V3, V4, V5_SIDES, V5_ORACLE,
    N_CLAMP, N_FORGOTTEN, N_LAWSET, N_ORACLE, N_RECON, N_DIR, N_NOTINT,
    P_SEED, P_SHAPES, P_CLASSIFIERS, P_HIST,
    E_STORM, E_ZERO, E_FORGOTTEN, E_CARRIED, E_REFUSED, E_LATENCY,
    C_REAL, C_R1, C_R2, C_R3, C_R4, C_R5, C_R6, C_R7, C_CONTROL,
]


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""
    law: str = ""       # §3.5's own killer wording, where an arm performs one
    law_id: str = ""    # which law it performs, stated rather than parsed


ARMS = [
    # =======================================================================
    # THE FIVE PUBLISHED KILLERS — §3.5's own column
    # =======================================================================
    Arm(
        "M1", VERSION,
        "  vd.cur = DocumentVersion(int(vd.cur) + 1)\n",
        "  vd.cur = DocumentVersion(int(vd.cur))\n",
        V1_CLASS1,
        "THE VERSION IS PUBLISHED WITHOUT BEING ADVANCED — §3.5's own wording "
        "for `LAW-V1`. Note how little else moves: the document is still "
        "correct, the change set is still in the log, every position still "
        "maps, and the ONLY observable is that `version` stopped being a "
        "function of how many transactions have been applied. Every stale "
        "result then reads as fresh, which is the single failure this whole "
        "boundary exists to prevent",
        law="publish the version without advancing it, so every result looks fresh",
        law_id="LAW-V1",
    ),
    Arm(
        "M2", RECONCILE,
        "    rep.record(r.producer, roDropped, drEvidenceDeleted)\n"
        "    return Reconciled(producer: r.producer, outcome: roDropped,\n"
        "                      reason: drEvidenceDeleted)\n",
        "    rep.record(r.producer, roMapped, drNotDropped)\n"
        "    return Reconciled(producer: r.producer, outcome: roMapped,\n"
        "                      value: r)\n",
        V2_INLINE_DROP,
        "A MOVED RESULT WHOSE PLACE IS GONE IS CLASSIFIED AS MAPPED — §3.5's "
        "own wording for `LAW-V2`, on the arm only an anchored producer "
        "reaches. A text-derived producer never gets here, because the "
        "region-touched test refuses first; that asymmetry is why the killer "
        "names `pkInlineValues` and not `pkTreeSitter`, and it is what §32a "
        "means by giving two mechanisms disjoint evidence",
        law="classify every moved result as mapped, so the drop arm is never reached",
        law_id="LAW-V2",
    ),
    Arm(
        "M3", RECONCILE,
        "    if r.fromA < toPos and r.toA > fromPos:\n",
        "    if r.fromA < fromPos and r.toA > toPos:\n",
        V3,
        "THE REGION-TOUCHED TEST HAS ITS BOUNDS SWAPPED — §3.5's own wording "
        "for `LAW-V3`. It is the sharpest arm in the harness because NOTHING "
        "about the answer looks wrong: the markers are intact, every position "
        "is in range, every coordinate maps exactly, and the payload is "
        "untouched. A law quantified over POSITIONS alone stays entirely "
        "green. What moves is the OUTCOME, and a stale highlight is then "
        "applied over text the parser never saw",
        law="swap the bounds of the region-touched test, so an edit inside the "
            "evidence region reads as an edit outside it",
        law_id="LAW-V3",
    ),
    Arm(
        "M4", RECONCILE,
        "  ProducerRules[p].rule\n",
        "  srAnchorLive\n",
        V4,
        "ONE STALE RULE FOR EVERY PRODUCER — §3.5's own wording for `LAW-V4`. "
        "The table is still there, still correct and still printed; it has "
        "simply stopped being consulted. Three of the four producers behave "
        "exactly as before, which is why the case asserts the rule's "
        "PARTITION of the producer set rather than any one producer's answer",
        law="answer one stale rule for every producer, so drop-or-rebase stops "
            "being a property of the producer",
        law_id="LAW-V4",
    ),
    Arm(
        "M5", RECONCILE,
        "  let movedTo = delta.mapPos(r.evidenceTo, sideBefore)\n",
        "  let movedTo = delta.mapPos(r.evidenceTo, sideAfter)\n",
        V5_SIDES,
        "BOTH ENDS OF THE REGION ARE MAPPED WITH THE SAME SIDE — §3.5's own "
        "wording for `LAW-V5`.\n\n"
        "        **THIS ARM IS THE MILESTONE'S §36 FINDING AND IT IS WORTH "
        "THE PARAGRAPH.** Against `LAW-V5` as first written — the model's "
        "region compared with the SENTINEL ORACLE's — the published killer is "
        "UNOBSERVABLE, and not because the law is weak. The oracle's region is "
        "*the bytes between two markers*, so an insert at either edge lands "
        "inside it by definition; the oracle and the model legitimately "
        "disagree about an edge insert, which is exactly why the generator's "
        "edit rule excludes one. Every sentinel comparison the suite makes is "
        "green under this mutation.\n\n"
        "        The repair is to the ASSERTION and never to the killer "
        "(§36's first rule). `LAW-V5 SIDES` measures the two sides directly, "
        "over an insert at each edge, against THE LENGTH OF THE TEXT THE CASE "
        "ITSELF INSERTED — a number from the input rather than from anything "
        "the model computed (§22). `LAW-S4`'s biasing rule, applied to a "
        "region: a span never grows to cover text the producer never saw, and "
        "a highlight that swallowed the character you just typed is what the "
        "other choice looks like on screen",
        law="map both ends of the evidence region with the same side, so text "
            "inserted at an edge is swallowed into the region",
        law_id="LAW-V5",
    ),

    # =======================================================================
    # FOUR MORE ON THE PRODUCT — properties no published killer names
    # =======================================================================
    Arm(
        "M6", VERSION,
        "  if since > vd.cur:\n"
        "    raise newException(VersionError,\n"
        '      "delta: " & $since & " is ahead of this document\'s " & $vd.cur &\n',
        "  if since > vd.cur:\n"
        "    return identityChangeSet(vd.docText.len)\n"
        "  if false:\n"
        "    raise newException(VersionError,\n"
        '      "delta: " & $since & " is ahead of this document\'s " & $vd.cur &\n',
        N_CLAMP,
        "**A VERSION FROM THE FUTURE IS CLAMPED TO THE PRESENT.** §36a's "
        "headline for this milestone, in its worst possible direction: *'a "
        "clamp is a silent repair, and it hides the defect it clamps for "
        "exactly as long as the value stays out of range'*. The identity "
        "change set is what a document that has not moved returns, so every "
        "result naming an impossible version is reported as FRESH and applied. "
        "Nothing raises, nothing counts and nothing looks wrong",
    ),
    Arm(
        "M7", RECONCILE,
        "  if r.computedAgainst > vd.version:\n"
        "    raise newException(VersionError,\n",
        "  if r.computedAgainst > vd.version:\n"
        "    return Reconciled(producer: r.producer, outcome: roApplied,\n"
        "                      value: r)\n"
        "  if false:\n"
        "    raise newException(VersionError,\n",
        N_CLAMP,
        "THE SAME CLAMP, ONE LAYER UP AND BY A DIFFERENT MECHANISM. §32a: two "
        "mechanisms guarding one property silently halve the older one's "
        "mutation coverage unless each gets evidence only it can satisfy. "
        "`delta` refuses a future version and so does `reconcile`, so the "
        "clamp case asserts BOTH refusals separately — remove either alone and "
        "it goes red, which is the arrangement that makes each of them "
        "evidence",
    ),
    Arm(
        "M8", RECONCILE,
        "  if (outcome == roDropped) != (reason != drNotDropped):\n",
        "  if false:\n",
        E_REFUSED,
        "THE REPORT ACCEPTS A DROP WITH NO REASON AND A REASON WITH NO DROP. "
        "The counter then reports a drop total and a reason total that do not "
        "add up, and nothing downstream can tell which of the two is wrong — "
        "which is the state a counted staleness report exists to make "
        "impossible",
    ),
    Arm(
        "M9", RECONCILE,
        "      change: rebased.bOverA,\n",
        "      change: rebased.aOverB,\n",
        V2_TREE_MAP,
        "THE WRONG ARM OF THE REBASE. Both arms of `rebase` are real change "
        "sets, both are well-formed, and both apply cleanly to SOME document — "
        "just not to this one. `aOverB` is the intervening delta re-expressed "
        "after the producer's change, so it is over the OLD length, and a "
        "caller that installed it would replace the wrong bytes. Only the "
        "length equality sees it; nothing about the positions does",
    ),

    # =======================================================================
    # THE POPULATION DEFECTS — a population is a subject like any other
    # =======================================================================
    Arm(
        "G1", GENERATOR,
        "        result.add ScheduleStep(producer: p, shape: s, site: k mod SitesPerDoc)\n",
        "        result.add ScheduleStep(producer: p, shape: esOutside, site: k mod SitesPerDoc)\n",
        P_SHAPES,
        "**THE SCHEDULE STOPS PRODUCING STALE RESULTS, WHICH IS THE DEFECT "
        "THIS MILESTONE WAS WARNED ABOUT BY NAME.** §34 in the form the brief "
        "gave it: *a generator that never produces a stale result, so "
        "reconciliation is never exercised*. Every law about dropping is then "
        "quantified over the empty set and every one of them stays green. The "
        "per-shape counts are asserted as EQUALITIES against the declared "
        "cross product, so three of the four rows go red at once; a histogram "
        "checked only for non-emptiness would show one full row and three "
        "empty ones and satisfy nothing that could notice",
    ),
    Arm(
        "G2", GENERATOR,
        "  if not a.present: return esDestroy\n",
        "  if true: return esOutside\n",
        P_CLASSIFIERS,
        "THE ORACLE'S CLASSIFIER STOPS READING ITS INPUT. §34's third rule is "
        "that the classifier must not be the constructor; this is the "
        "degenerate form — a classifier that answers without looking. It is "
        "caught by the SECOND classifier, which reads the built change set's "
        "changed ranges rather than the two documents, and the two are "
        "compared cell by cell",
    ),
    Arm(
        "G3", GENERATOR,
        "    if rule == srTextDerived: roDropped else: roMapped\n",
        "    roMapped\n",
        P_HIST,
        "THE SCHEDULE'S INTENT STOPS DEPENDING ON THE RULE. The expectation "
        "the twelve cells are compared against is derived from the DECLARED "
        "table; flattening it makes the expectation disagree with a "
        "reconciler that is behaving perfectly. It is the arm that proves the "
        "histogram is an equality against something independent rather than "
        "against the model's own output",
    ),

    # =======================================================================
    # THE SUITES — a gate that cannot fail is this campaign's defect
    # =======================================================================
    Arm(
        "U1", LAWS,
        'const OracleForbidden = ["mapPos", "ChangeSet", "changeSet", "sections",\n'
        '                         "compose(", "rebase(", "mapPosOr", "delta("]\n',
        "const OracleForbidden: array[0, string] = []\n",
        N_ORACLE,
        "§30a's OWN ARM, and it is the one that cannot be replaced by an "
        "assertion about an answer. An empty forbidden list makes the "
        "oracle-independence scan iterate nothing and satisfy every *'must not "
        "contain'* written over it (§4). The case asserts the list's "
        "cardinality for exactly this reason",
    ),
    Arm(
        "U2", LAWS,
        'const ReconcileForbidden = ["skKeep", "skReplace", "posB", "s.insert.len",\n'
        '                            "for s in cs.sections", "oldLen", "newLen"]\n',
        "const ReconcileForbidden: array[0, string] = []\n",
        N_RECON,
        "THE SAME ARM FROM THE OTHER SIDE. `OracleForbidden` says the control "
        "does not re-derive the model; this says the MODEL does not re-derive "
        "PLAT-25. Two scans, two lists, two cardinalities — and each needs "
        "evidence only it can satisfy (§32a), which is why they are two arms "
        "rather than one",
    ),
    Arm(
        "U3", LAWS,
        '    if kind == pcFile and path.endsWith(".nim"):\n',
        '    if kind == pcFile and path.endsWith(".nimx"):\n',
        N_DIR,
        "§35's ARM: the directory enumeration matches nothing, so *'the set is "
        "exactly these fifteen'* is satisfied by leaving nothing to disagree "
        "with it. The arm is one character in the extension it filters on, "
        "which is the trap's own stated remedy applied to itself. It is not "
        "hypothetical here: this list grew from thirteen to fifteen on the "
        "day PLAT-29 added two modules, and PLAT-28's copy of the same case "
        "went red until it did",
    ),
    Arm(
        "U4", EX,
        "        let shape = if k mod 8 == 7: esDestroy\n",
        "        let shape = if false: esDestroy\n",
        E_STORM,
        "THE EDIT STORM STOPS DESTROYING ANYTHING. Every site survives, so the "
        "two anchored producers are MAPPED rather than dropped and their drop "
        "counts fall to zero — while the two text-derived ones go on dropping, "
        "which is what makes this an arm about the POPULATION rather than "
        "about the reconciler. *'A suite where the drop count is zero is a "
        "suite that never reached the code it grades'*, and the per-producer "
        "assertion is what says so for each of the four rather than for the "
        "total",
    ),

    # =======================================================================
    # THE GATE, AND THE TABLE IT READS — five arms, because a verification
    # gate that cannot fail is this campaign's own recurring defect
    # =======================================================================
    Arm(
        "A1", ADMISSION,
        '    ("std/unicode", "rune-level string handling',
        '    ("std/unicodeX", "rune-level string handling',
        C_REAL,
        "THE ALLOW-LIST LOSES THE ONE ROW THE REAL CLOSURE NEEDS. `std/unicode` "
        "is what the grapheme segmenter the whole coordinate model rests on is "
        "built from, so the real tree goes red — which is the arm that proves "
        "the gate's verdict on the REAL tree is a measurement rather than a "
        "constant. The array's declared length is unchanged, so this also "
        "passes the parser's own `parsed == declared` check and reaches the "
        "rule",
    ),
    Arm(
        "A2", GATE,
        '\t"isonim-tui|isonim_tui/text/width.nim|ISONIM_TUI_SRC|../isonim-tui/src"\n',
        '\t"isonim-tui|isonim_tui/text/widthX.nim|ISONIM_TUI_SRC|../isonim-tui/src"\n',
        C_REAL,
        "**THE WALK STOPS AT THIS REPOSITORY'S BOUNDARY.** The probe no longer "
        "resolves, so `isonim-tui` is not a search root and the five modules "
        "the editor model reaches there become unresolvable — reported by "
        "check 1 rather than skipped, which is the whole reason an "
        "unresolvable spec is a finding. Without this arm *'the closure "
        "contains no async'* would mean *'contains none IN CODETRACER'*, and "
        "IsoNim is on somebody else's cadence",
    ),
    Arm(
        "A3", GATE,
        '\t\t\t\tqueue+=("${resolved}")\n',
        "\t\t\t\t:\n",
        C_R3,
        "**THE CLOSURE BECOMES A SCAN.** The BFS resolves every edge and "
        "enqueues none of them, so the walk visits exactly the root set — "
        "which is precisely the instrument this milestone replaced. Route 3's "
        "case is the one that notices, because its root module is INNOCENT and "
        "the finding it asserts on names the helper. Every other check stays "
        "green, which is what the old instrument looked like from outside",
    ),
    Arm(
        "A4", GATE,
        '\t\t\t[ "${a}" = "${spec}" ] && ok=1 && break\n',
        "\t\t\tok=1\n",
        C_R7,
        "THE ALLOW-LIST ADMITS EVERYTHING. The planted arm is what must redden "
        "first (§32's rule that the needle scan runs BEFORE the digests are "
        "re-recorded), and it is deliberately the simplest possible input — a "
        "bare `import std/asyncdispatch` — so that a gate which had stopped "
        "working entirely is caught by something no cleverness is needed to "
        "read",
    ),
    Arm(
        "A5", GATE,
        "\tsed -e 's/#\\[.*\\]#//g' -e 's/[[:space:]]*##\\?.*$//' \"$1\" 2>/dev/null\n",
        '\tcat "$1" 2>/dev/null\n',
        C_CONTROL,
        "THE COMMENT STRIPPER STOPS STRIPPING. Every module that DOCUMENTS the "
        "rule becomes a finding — `reconcile.nim`'s header names sixteen of "
        "the eighteen denied identifiers on purpose — and so does the "
        "synthetic control tree, whose header names two. The CONTROL is the "
        "case that notices, which is the right one: a gate that reddens on its "
        "own evidence is a gate nobody can use, and §4d names the usual "
        "repair (rewording a comment to appease a regex) as the smell",
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
        # PER SUITE, not per run. A mutation that stops ONE of the three suites
        # compiling while the others still print their cases would otherwise
        # read as a clean survival.
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
    closure = read_source(CLOSURE)
    everywhere = laws + "\n" + ex + "\n" + closure

    templates = [
        ('test "LAW-V1 and FUZZ-5 x class " & $(ci + 1):', laws,
         "THE LAW-V1 CELL TEMPLATE"),
        ('test "LAW-V2 " & $p & " x " & $o:', laws, "THE LAW-V2 CELL TEMPLATE"),
        ('test "EDIT LATENCY AT LOAD " & $LoadLevels[loadIdx] & ", TAKE " & $take:',
         ex, "THE LATENCY CELL TEMPLATE"),
    ]
    for needle, text, label in templates:
        if needle not in text:
            print(f"{label} IS NOT IN THE SUITE")
            problems += 1

    composed = ("LAW-V1 and FUZZ-5 x ", "LAW-V2 pk", "EDIT LATENCY AT LOAD ")
    for name in NAMED_CASES:
        if name.startswith(composed):
            continue    # composed from an enum; the halves are checked above
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

    # ALL FIVE PUBLISHED KILLERS ARE PERFORMED, two-sidedly.
    performed = set()
    for arm in ARMS:
        if not arm.law:
            continue
        if not arm.law_id.startswith("LAW-V"):
            print(f"{arm.id}: quotes a published killer but declares law_id "
                  f"{arm.law_id!r}")
            problems += 1
            continue
        performed.add(arm.law_id)
    expected = {f"LAW-V{i}" for i in range(1, 6)}
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
    # discarding the bool this returns. It matters because `baseline` below is
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
