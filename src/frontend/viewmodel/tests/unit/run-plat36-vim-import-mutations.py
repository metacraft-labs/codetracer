#!/usr/bin/env python3
"""PLAT-36's arming — the mutation harness for the Vim-configuration importer,
its pinned corpus, and the two suites over them.

    python3 src/frontend/viewmodel/tests/unit/run-plat36-vim-import-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --enumerate-touched
    python3 ... --only=M1,G2

WHAT THIS IS, AND WHY THERE IS NO `LAW-*` COLUMN TO READ
=======================================================
`Editor-Model-Conformance-Suite.md` §3 publishes `LAW-A*` … `LAW-X*` and none
of them is PLAT-36's, exactly as none was PLAT-30's, PLAT-31's, PLAT-34's or
PLAT-35's. So `ci/test/editor-model-case-floor.sh` runs no law-table oracle for
this milestone and the campaign's rule — *a published claim needs a published
killer, performed* — is discharged here: **one arm per claim the milestone
makes**, each naming the case that dies.

The claims, and the arms that kill them, in the milestone's own order:

  | claim | arm |
  |---|---|
  | translated + reported == total, per file, as an equality | `M1`, `M2`, `M4` |
  | the reason set is closed and every member is reachable | `M3`, `G5` |
  | "binds nothing" and "could not be read" are different outcomes | `M5`, `M10` |
  | each of the five map arguments has a RECORDED decision | `M6`, `M7` |
  | a translated mapping that differs is REPORTED, not shipped | `M8`, `M11` |
  | the import is not a Vimscript interpreter, and `<leader>` is lexical | `M12`, `M13` |
  | a plugin reference and a Vimscript reference are different reasons | `M14` |
  | the chords are keys a terminal can actually produce | `M9` |
  | the corpus is eighteen pinned documents and cannot shrink | `G2` |
  | the partition law's denominator is NOT the importer's own sum | `G3` |
  | `DIFF-5`'s two sides are two keymaps | `G1` |
  | the key-name round trip has a population | `G4` |

Verification-Harness-Traps, applied rather than cited:

  * §22  — the partition law's denominator must not be the importer's own
           sum, and `M4` is what proves the second pass is load-bearing: it
           mutates `countMappingLines` ALONE, so the outcome-derived halves
           are untouched and only the raw-text count disagrees.

           **AND THE FIRST SPELLING OF THAT ARM COULD NOT KILL, WHICH IS §36
           INSIDE THIS HARNESS.** `G3` was first written as *make
           `manifest.tsv`'s `mapLines` read `translated + reported`*, on the
           reasoning that this performs §22's collapse. It ran and SURVIVED.
           The reason is the population, measured rather than argued: on a
           CORRECT corpus `mapLines == translated + reported` holds on all
           eighteen rows, so the substitution replaces a value with an equal
           value and changes nothing. *A mutation whose two expressions are
           equal in the population is a mutation no assertion can observe* —
           §36's fourth rule, and the verdict read `SURVIVED / no case
           noticed`, which is the reading that costs nothing ("the check is
           dead, drop the arm"). The arm was REPLACED rather than deleted, and
           the §22 claim now rests on `M4`, which does kill.
  * §30a — `G1` makes the differential's two arms share one keymap, which is
           the substitution no assertion about the ANSWER can see. It must die
           in the SOURCE-scan case; that it also dies in the rows is a bonus
           and not the point.
  * §34  — `G2` points one corpus id at another document. The population loses
           a member while staying the same SIZE, which is §34b's shape exactly,
           and `G4` empties a sweep's alphabet.
  * §36  — every killer below was read against the implementation before being
           trusted, and TWO of them moved the product rather than the arm:
           `M9` and `M10` restore defects this suite FOUND on its first run
           (the control-byte collision and the mode-set equality in `unmap`),
           so they are arms for repairs rather than arms for hypotheses.
  * §36a — the suites build their corpus at MODULE SCOPE, so a mutation that
           made the importer raise would kill the harness rather than a case.
           Both suites count those raises and assert the count is zero in a
           case of their own, which is what keeps such an arm's verdict a kill.
  * §32  — `--needle-scan` refuses to run when any needle is absent or
           ambiguous, and the full run refuses unless the scan is clean AND
           every subject's control digest matches. §10.3's rule is checked
           first: no needle may quote a declared count's name or value.
  * §10.3 — no arm quotes `ExpectedAssertions`, `CHECKS:`, a corpus size or any
           of their values.

NO DECLARED SURVIVORS. Every arm below is expected to die, and none is
recorded as an accepted survival — which is a claim this file makes rather than
an omission, and the run prints the count either way.
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
IMPORTER = "src/frontend/viewmodel/keymap/vim_import.nim"
CORPUS = "src/frontend/viewmodel/tests/corpus/vimrc_corpus.nim"
LAWS = "src/frontend/viewmodel/tests/unit/test_editor_vim_import.nim"
DIFF = "src/frontend/viewmodel/tests/unit/test_editor_vim_import_differential.nim"

TOUCHED = [IMPORTER, CORPUS, LAWS, DIFF]

CONTROL_HASHES = HERE / "plat36-vim-import-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P36_SUITE_TIMEOUT", "2400"))
VM_FLAGS = ["--hints:off", "--warnings:off", "--path:src/frontend/viewmodel"]

RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*(.*?)\s*(?:\x1b\[[0-9;]*m)*$")

# ---------------------------------------------------------------------------
# The case names, spelled ONCE. A typo here surfaces as "the control did not
# run this case" rather than as a silently unkillable arm.
#
# One family is COMPOSED at run time — the per-corpus-file partition and
# resolution cells — and the scan checks the TEMPLATE rather than searching for
# the whole string.
# ---------------------------------------------------------------------------

PARTITION = "PARTITION LAW: translated + reported == total mapping lines — "
RESOLVED = "RESOLVED AGAINST: every imported binding of "

P_MSWIN = PARTITION + "v01-vim-mswin"
P_DEFAULTS = PARTITION + "v03-vim-defaults"
P_LESS = PARTITION + "v06-vim-less"
P_DVORAK = PARTITION + "v07-vim-dvorak-enable"
P_SWAPMOUSE = PARTITION + "v09-vim-swapmouse"
P_MATCHIT = PARTITION + "v11-vim-matchit"
P_SPF13 = PARTITION + "v18-spf13-vimrc"

CLASSES = "THE FOUR FILE CLASSES ARE NON-EMPTY, AS EQUALITIES (§34)"
COVERAGE = "THE COVERAGE FIGURE IS MEASURED, AND IT IS N OF M"
TYPED = "BINDING NOTHING AND FAILING TO READ ARE DIFFERENT CONSTRUCTORS"
UNIQUE = "<unique>: ENFORCED — an already-claimed chord leaves it uninstalled"
SILENT = "<silent>: honoured trivially, and it is the one with NO divergence"
KEYNAMES = "THE KEY NAMES THE IMPORTER PRODUCES ARE key_names' OWN (§30a)"
MACRO = ("A MULTI-OPERATION RIGHT-HAND SIDE BECOMES A MACRO, AND ITS LIMIT "
         "IS NAMED")
LEADER = "mapleader IS READ LEXICALLY, AND ONLY WHEN IT IS UNCONDITIONAL"
REASON_SYNTAX = ("PLANTED REASON: the syntax was not understood is reachable "
                 "and moves the totals")
REASON_NOOP = ("PLANTED REASON: the right-hand side uses an operation this "
               "editor does not have is reachable and moves the totals")
NEGATIVE = ("A FILE OF ONLY UNTRANSLATABLE LINES PRODUCES ZERO BINDINGS AND "
            "M ENTRIES")
CORPUS_PINNED = ("THE CORPUS IS EIGHTEEN PINNED DOCUMENTS WITH A SOURCE AND "
                 "A REVISION")
OUTCOME_KINDS = ("THE CORPUS REACHES ALL FIVE OUTCOME KINDS OR NAMES THE ONES "
                 "IT DOES NOT")
T30A = "THE TWO ARMS DO NOT SHARE A KEYMAP (§30a)"
R_DVORAK = RESOLVED + "v07-vim-dvorak-enable resolves to its own operation"
DIFF5_OTHER = ("A DIVERGENCE WITH NO REPORT ENTRY WOULD BE A FAILURE — the "
               "other arm")

NAMED_CASES = [
    CLASSES, COVERAGE, TYPED, UNIQUE, SILENT, KEYNAMES, MACRO, LEADER,
    REASON_SYNTAX, REASON_NOOP, NEGATIVE, CORPUS_PINNED, OUTCOME_KINDS,
    T30A, DIFF5_OTHER,
    P_MSWIN, P_DEFAULTS, P_LESS, P_DVORAK, P_SWAPMOUSE, P_MATCHIT, P_SPF13,
    R_DVORAK,
]

COMPOSED_PREFIXES = (PARTITION, RESOLVED, "DIFF-5: ", "MAP FAMILY: ",
                     "SET OPTION: ", "PLANTED REASON: ")

CASE_TEMPLATES = [
    ('test "PARTITION LAW: translated + reported == total mapping lines — " '
     "& docId:", LAWS, "THE PARTITION CELL"),
    ('test "RESOLVED AGAINST: every imported binding of " & docId &', DIFF,
     "THE RESOLUTION CELL"),
    ('test "MAP FAMILY: " & $fam &', LAWS, "THE MAP-FAMILY CELL"),
    ('test "SET OPTION: " & $opt &', LAWS, "THE SET-OPTION CELL"),
    ('test "PLANTED REASON: " & $reason &', LAWS, "THE PLANTED-REASON CELL"),
    ("test \"DIFF-5: the imported chord and the Vim sequence '\" & rhs &",
     DIFF, "THE DIFF-5 CELL"),
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
    # THE PRODUCT — the importer
    # =======================================================================
    Arm(
        "M1", IMPORTER,
        "    result.outcomes.add LineOutcome(line: ln, text: txt, kind: lkMapping,\n"
        "                                    outcome: okReported, reason: rs,\n"
        "                                    detail: dt)\n"
        "    result.report.add ImportReportEntry(line: ln, text: txt, reason: rs,\n",
        "    result.report.add ImportReportEntry(line: ln, text: txt, reason: rs,\n",
        P_SWAPMOUSE,
        "**THE PARTITION LAW'S OWN KILLER.** A reported line stops getting an "
        "OUTCOME while still getting a report row, so `translated + reported` "
        "no longer accounts for every mapping line — a lost line, which is "
        "*'indistinguishable from a line the user never wrote'*. Note what "
        "does NOT move: the report is still complete, the coverage figure's "
        "numerator is unchanged, and an importer graded on its report alone "
        "would be green",
    ),
    Arm(
        "M2", IMPORTER,
        "      report(lineNo, body, irNoOperation,\n"
        "             \"the right-hand side token '\" & badRhs &\n"
        "               \"' names nothing this editor can do\")\n"
        "      continue\n",
        "      continue\n",
        P_SWAPMOUSE,
        "**A SILENT DROP**, which is the defect §6.3 calls worse than no "
        "import at all: a right-hand side this editor cannot express produces "
        "neither a binding nor a report row, and the user finds out when "
        "muscle memory fails. `swapmouse.vim`'s twenty mouse remaps are "
        "exactly this shape and are the file the arm is aimed at",
    ),
    Arm(
        "M3", IMPORTER,
        "      report(lineNo, body, irSyntax,\n"
        "             \"the left-hand side token '\" & badLhs &\n"
        "               \"' is not a key this editor can spell\")\n"
        "      continue\n"
        "    if not rhsOk:\n",
        "      report(lineNo, body, irNoOperation,\n"
        "             \"the left-hand side token '\" & badLhs &\n"
        "               \"' is not a key this editor can spell\")\n"
        "      continue\n\n"
        "    if not rhsOk:\n",
        P_LESS,
        "**TWO MEMBERS OF THE CLOSED SET COLLAPSE INTO ONE.** An unreadable "
        "LEFT-hand side is reported as a right-hand-side problem. The set "
        "still has five members and every one is still declared; what changes "
        "is that one of them stops being EMITTED, which is the state a closed "
        "set with an unreachable member cannot be told from",
    ),
    Arm(
        "M4", IMPORTER,
        "    if matchFamily(fields[0]).isMapping:\n"
        "      inc result\n",
        "    if matchFamily(fields[0]).isMapping and\n"
        '       fields[0] notin ["unmap", "mapclear"]:\n'
        "      inc result\n",
        P_LESS,
        "**THE SECOND PRODUCER OF THE DENOMINATOR STOPS COUNTING A FAMILY.** "
        "`countMappingLines` is the pass that keeps the partition law from "
        "being `|A| + |B| == |A ∪ B|`, and here it disagrees with both other "
        "producers on `macros/less.vim`: the second pass reports 67 where the "
        "outcome list and the manifest both say 124. The delta is the 57 "
        "lines whose head word is spelled EXACTLY `unmap` or `mapclear`. "
        "`matchit`'s thirteen are NOT among them and that is worth stating "
        "rather than rounding — they are spelled `nunmap`/`xunmap`/`ounmap`, "
        "so the literal `notin` list does not catch them and matchit's count "
        "does not move. One file is enough: the manifest's independent column "
        "is what makes the disagreement a red run rather than a quieter law",
    ),
    Arm(
        "M5", IMPORTER,
        "      let removed = removeBindings(result.keymap, modes, chords, false)\n"
        "      result.outcomes.add LineOutcome(line: lineNo, text: body,\n"
        "                                      kind: lkMapping, outcome: okUnbind,\n"
        "                                      unbindFamily: family, cleared: removed)\n"
        "      continue\n\n"
        "    if rhsText.len == 0:\n",
        "      discard removeBindings(result.keymap, modes, chords, false)\n"
        "      report(lineNo, body, irSyntax, \"nothing was bound\")\n"
        "      continue\n\n"
        "    if rhsText.len == 0:\n",
        TYPED,
        "**\"BINDS NOTHING\" COLLAPSES INTO \"COULD NOT BE READ\"**, which is "
        "this campaign's most repeated defect in the one place it is most "
        "tempting: an `unmap` that cleared nothing produces an empty binding "
        "list, and so does a line naming a mouse button. Only the CONSTRUCTOR "
        "tells them apart, and after this arm it does not",
    ),
    Arm(
        "M6", IMPORTER,
        "      if claimed.len > 0:\n"
        "        result.outcomes.add LineOutcome(line: lineNo, text: body,\n",
        "      if false:\n"
        "        result.outcomes.add LineOutcome(line: lineNo, text: body,\n",
        UNIQUE,
        "`<unique>` STOPS BEING ENFORCED. Vim refuses to install a `<unique>` "
        "mapping over an existing one; here the second mapping silently wins, "
        "which is a decision the milestone asks to be RECORDED rather than "
        "taken by accident. Nothing about the count of translated lines moves "
        "— the line is still translated — so only a case that reads the "
        "OUTCOME KIND can see it",
    ),
    Arm(
        "M7", IMPORTER,
        "    if vmaBuffer in mapArgs:\n"
        "      diverge(lineNo, body,\n"
        '              "<buffer> asks for a mapping local to one buffer; §4.3 has no " &\n',
        "    if vmaSilent in mapArgs or vmaBuffer in mapArgs:\n"
        "      diverge(lineNo, body,\n"
        '              "<buffer> asks for a mapping local to one buffer; §4.3 has no " &\n',
        SILENT,
        "`<silent>` GROWS A DIVERGENCE IT MUST NOT HAVE. It is the one of the "
        "five arguments whose decision is *nothing here echoes, so the flag "
        "distinguishes nothing*, and that is a claim rather than an omission: "
        "a divergence for it would tell the user their mapping behaves "
        "differently when it does not. The arm is aimed at the case that "
        "asserts the ZERO",
    ),
    Arm(
        "M8", IMPORTER,
        "    if isTextEntryMode(startMode) and chords.len > 0 and\n"
        "       chords[0].len == 1 and chords[0][0] >= ' ' and chords[0][0] <= '~':\n",
        "    if false and isTextEntryMode(startMode) and chords.len > 0 and\n"
        "       chords[0].len == 1 and chords[0][0] >= ' ' and chords[0][0] <= '~':\n",
        P_DVORAK,
        "**§4.3's TEXT-ENTRY SHADOW STOPS BEING REPORTED**, which is a "
        "TRANSLATED mapping that silently does nothing — §6.4's *'a defect to "
        "be reported in the same report rather than a feature'*. "
        "`dvorak/enable.vim` is seventy such lines and is the only file in "
        "the corpus every one of whose mappings translates; after this arm it "
        "translates all seventy and says nothing about any of them",
    ),
    Arm(
        "M9", IMPORTER,
        "  if ControlAliases.hasKey(lower):\n",
        "  if false and ControlAliases.hasKey(lower):\n",
        KEYNAMES,
        "**A REPAIR IS REVERTED, AND THE DEFECT IT REPAIRED WAS FOUND BY THE "
        "CASE THIS ARM KILLS.** `<C-H>` is byte 0x08 and `key_names.keyName` "
        "answers `Backspace` for it, so a chord spelled `Ctrl+h` is one no "
        "terminal reader can ever produce and the binding would resolve for "
        "nobody. The importer's first spelling produced exactly that; the "
        "round-trip case went red on its first run and the product changed",
    ),
    Arm(
        "M10", IMPORTER,
        "    if (anyChords or b.chords == chords) and (b.scope.modes * modes).len > 0:\n",
        "    if (anyChords or b.chords == chords) and b.scope.modes == modes:\n",
        TYPED,
        "**THE SECOND REVERTED REPAIR.** `:unmap gQ` covers Normal, Visual, "
        "Select and Operator-pending; `:nnoremap gQ 0` installs into Normal "
        "alone. Comparing the two mode SETS for equality cleared nothing, so "
        "a teardown block silently removed no mapping — and `macros/less.vim` "
        "is fifty-four such lines. The arm restores the equality",
    ),
    Arm(
        "M11", IMPORTER,
        "      let carries = argumentBearing(resolved)\n"
        "      if carries.len > 0:\n",
        "      let carries = argumentBearing(resolved)\n"
        "      if false:\n",
        MACRO,
        "**A MACRO THAT DROPS ITS ARGUMENTS IS SHIPPED INSTEAD OF REPORTED.** "
        "`EditorState.macros` is a table of operation NAMES and `replay-macro` "
        "replays each step with a fresh empty `OpArgs`, so `nnoremap gQ y$` "
        "would bind, resolve, act, and do nothing — the exact failure the "
        "report exists to prevent. The refusal is the product; this arm makes "
        "it a feature",
    ),
    Arm(
        "M12", IMPORTER,
        "    if raw.len == 0 or raw[0] in {' ', '\\t'}: continue\n",
        "    if raw.len == 0: continue\n",
        LEADER,
        "`mapleader` IS READ FROM A CONDITIONAL ASSIGNMENT. The lexical rule "
        "is *column zero, unconditional, a string literal* — anything else "
        "and `<leader>` is unresolved and its mappings are reported as "
        "Vimscript. `spf13-vim` assigns `g:spf13_leader` inside an `if` at "
        "indent eight, and after this arm the importer believes an assignment "
        "it cannot know ran",
    ),
    Arm(
        "M13", IMPORTER,
        "  if s.len > 1 and s[0] == ':' and not isTextEntryMode(startMode): return true\n",
        "  if s[0] == ':': return true\n",
        P_DVORAK,
        "**THE THIRD REVERTED REPAIR.** In Insert mode a mapping's right-hand "
        "side is TYPED, so `inoremap z :` inserts a colon. Reading the colon "
        "unconditionally made one of `dvorak/enable.vim`'s seventy pure "
        "key-to-key remaps report *invokes Vimscript*, which is how the rule "
        "was found — a file that is 70 of 70 translatable became 69",
    ),
    Arm(
        "M14", IMPORTER,
        '  PluginMarkers = ["<plug>"]\n',
        '  PluginMarkers = ["<plug>", "<sid>", "<snr>"]\n',
        P_LESS,
        "**THE FOURTH REVERTED REPAIR.** `<SID>` and `<SNR>` are script-local "
        "FUNCTION references, which §6.2 lists under Vimscript; as plugin "
        "markers they made `macros/less.vim` — a file that loads no plugin at "
        "all — report twenty-nine plugin references. The totals do not move "
        "one line: only the REASON does, which is why the per-file reason "
        "counts are in the manifest and not only the coverage figure",
    ),

    # =======================================================================
    # THE CORPUS AND THE SUITES
    # =======================================================================
    Arm(
        "G1", DIFF,
        "  driveKeys(st, imp.keymap, vimScope(emNormal), keys, wrap)\n",
        "  driveKeys(st, vimKeymap().keymap, vimScope(emNormal), keys, wrap)\n",
        T30A,
        "**§30a: THE DIFFERENTIAL'S TWO ARMS SHARE ONE KEYMAP.** This is the "
        "substitution no assertion about the ANSWER can see in general, and "
        "the SOURCE scan is the only instrument aimed at it. That the rows "
        "also redden here is a property of this particular substitution — "
        "`gQ` is bound by no Vim row — and not something to rely on: a "
        "substitution that happened to agree would leave the scan as the only "
        "red",
    ),
    Arm(
        "G2", CORPUS,
        '    VimrcDoc(id: "v09-vim-swapmouse",\n'
        '             text: staticRead("vimrc/v09-vim-swapmouse.vim")),\n',
        '    VimrcDoc(id: "v09-vim-swapmouse",\n'
        '             text: staticRead("vimrc/v01-vim-mswin.vim")),\n',
        P_SWAPMOUSE,
        "**§34b: THE POPULATION LOSES A MEMBER WITHOUT LOSING SIZE.** One "
        "corpus id points at another document, so the set is still eighteen, "
        "every class is still reached and every sweep still has its "
        "multiplier. What moves is the one thing a per-class count cannot "
        "see: the file's own row. The manifest is what notices",
    ),
    Arm(
        "G3", CORPUS,
        '    if f[0] == "id": continue\n',
        '    if f[0] == "id" or f[1] == "reported": continue\n',
        CORPUS_PINNED,
        "**A MANIFEST PARSER THAT SILENTLY DROPS ROWS**, which is §4 one "
        "level up: a parser that read less than the whole table satisfies "
        "every check written over what it DID read, and the seven "
        "fully-reported files are the ones whose rows carry the corpus's "
        "hardest claims. The cardinality assertion is what fails; every "
        "surviving row still agrees with the importer",
    ),
    Arm(
        "G4", LAWS,
        "    for c in 'a' .. 'z':\n",
        "    for c in 'a' .. 'a':\n",
        KEYNAMES,
        "**A SWEEP'S ALPHABET IS EMPTIED TO ONE LETTER.** Four of the "
        "twenty-six control spellings are the ones that matter (`<C-H>`, "
        "`<C-I>`, `<C-J>`, `<C-M>`) and none of them is `a`, so every "
        "assertion inside the loop still passes. The case's own POPULATION "
        "FLOOR is what fails — §4's rule that a scan finding nothing "
        "satisfies everything written over it, applied to a sweep",
    ),
    Arm(
        "G5", LAWS,
        '    irSyntax: "nnoremap <LeftMouse> 0\\n",\n',
        '    irSyntax: "nnoremap gQ 0\\n",\n',
        REASON_SYNTAX,
        "**A PLANTED LINE STOPS PRODUCING ITS REASON.** The plant becomes a "
        "perfectly translatable mapping, so the reason it was written for is "
        "emitted by nothing — which is the state *'a reason no planted line "
        "can produce'* names. The case must fail on the reason's count AND on "
        "the totals moving the wrong way, which is why it asserts both",
    ),
]

DECLARED_SURVIVORS: list = []


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
        (LAWS, "/tmp/plat36-mutation-laws", VM_FLAGS),
        (DIFF, "/tmp/plat36-mutation-diff", VM_FLAGS),
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


COUNT_CONSTANT = re.compile(
    r"^[ \t]*(?:const[ \t]+)?(ExpectedAssertions|ExpectedFamilies|"
    r"ExpectedReasons|ExpectedArguments|ExpectedOptions|ExpectedEmptyFiles|"
    r"ExpectedTranslatedFiles|ExpectedReportedFiles|ExpectedMixedFiles|"
    r"ExpectedDiffRows|ExpectedMacroRows|ExpectedDocChangingRows|"
    r"VimrcCorpusSize|MapFamilyCount|ImportReasonCount|VimMapArgumentCount|"
    r"VimOptionCount)\*?[ \t]*=[ \t]*(\d+)", re.M)
COUNT_NAMES = ("ExpectedAssertions", "ExpectedFamilies", "ExpectedReasons",
               "ExpectedArguments", "ExpectedOptions", "ExpectedEmptyFiles",
               "ExpectedTranslatedFiles", "ExpectedReportedFiles",
               "ExpectedMixedFiles", "ExpectedDiffRows", "ExpectedMacroRows",
               "ExpectedDocChangingRows", "VimrcCorpusSize", "MapFamilyCount",
               "ImportReasonCount", "VimMapArgumentCount", "VimOptionCount",
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
        # ONLY MULTI-DIGIT VALUES, and the narrowing is MEASURED rather than
        # convenient. With every declared value compared, the rule rejects
        # **three of the nineteen arms on four digit matches** — `M8` twice,
        # `M13` and `G3` once each — and every one of the four is the single
        # digit `1`, matching `ExpectedTranslatedFiles = 1`, inside a length
        # comparison (`chords[0].len == 1`, `s.len > 1`) or a table index. Not
        # one is a count. (The figure was seven matches before `G3` was
        # replaced; it is re-taken here rather than carried, which is §36b's
        # whole point.)
        #
        # A rule no arm in this subject set can satisfy is a rule that gets
        # switched off rather than obeyed. The NAME check above is unnarrowed
        # and applies to every constant including the single-digit ones, so an
        # arm quoting `ExpectedTranslatedFiles` still fails; what is given up
        # is catching a bare `1` that happens to mean it, and a bare single
        # digit was never evidence of a quoted count.
        #
        # **THIS MILESTONE IS THE FIRST WHOSE ARMS COLLIDE WITH A SINGLE-DIGIT
        # COUNT, WHICH IS NOT THE SAME AS THE FIRST TO DECLARE ONE** — and the
        # difference was measured rather than assumed, because the first
        # spelling of this paragraph claimed the latter and it is false.
        # `PLAT-31` declares `ExpectedErrorKinds = 5` (and
        # `EditingKeymapErrorKindCount = 5`); `PLAT-32` declares
        # `ForbiddenInOracleCount = 9`, `StreamSteps = 8`,
        # `GroupingKeystrokes = 5` and `Keystrokes = 5`. All six sit inside
        # those harnesses' own `COUNT_CONSTANT` lists and all six are gated by
        # the UNNARROWED value rule to this day. What is new here is not the
        # single digit but the COLLISION: run their arm tables against their
        # own declared values and each yields ZERO digit matches, so neither
        # harness ever had to answer this question. §36b — re-take the figure,
        # do not carry it.
        for digits in re.findall(r"\d\d+", arm.find + arm.replace):
            if digits in counts:
                print(f"{arm.id}: NEEDLE QUOTES THE VALUE OF "
                      f"{counts[digits]} ({digits}) — §10.3")
                problems += 1

    # EVERY SUBJECT CARRIES AT LEAST ONE ARM. Four subjects and an arm table
    # that reached only the product would be a harness that arms the code and
    # not the instrument — the milestone asks for both.
    armed = {arm.path for arm in ARMS}
    unarmed = [p for p in TOUCHED if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    else:
        print(f"all {len(TOUCHED)} subjects carry at least one arm")

    # NO TWO ARMS SHARE A `because`. §33a's second trap: a duplicated
    # justification is one of the two arms grading nothing anybody has read.
    whys = {}
    for arm in ARMS + DECLARED_SURVIVORS:
        key = arm.why[:60]
        if key in whys:
            print(f"{arm.id}: DUPLICATE justification, shared with {whys[key]}")
            problems += 1
        whys[key] = arm.id

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
        # A PATH THAT IS NOT IN THE FILE AT ALL IS A REFUSAL, NOT A SKIP.
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

    print(f"\ndeclared survivors: {len(DECLARED_SURVIVORS)}")
    print(f"{problems} problems")
    return 0 if problems == 0 else 1


def run_suite(suite_list: list) -> RunResult:
    res = RunResult(rc=0)
    for path, binary, flags in suite_list:
        run_one(path, binary, flags, res)
    return res


if __name__ == "__main__":
    sys.exit(main())
