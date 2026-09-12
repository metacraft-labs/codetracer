#!/usr/bin/env python3
"""Mutation harness for PLAT-12's per-type visualisers.

WHAT THIS COVERS. Project-Definitions.md §5: §5.2 (media-typed declarations and
what a surface that cannot draw them does instead), §5.3 (what a rule matches,
how it presents, what it hides), §5.4 (precedence across tiers, and the
requirement that a user be able to ask which visualiser rendered a value) and
§5.5 (existing behaviour unchanged where no rule applies). Seven subject files,
three suites.

WHY THE ARMS ARE AIMED WHERE THEY ARE. PLAT-12's substance is a RESOLUTION and
a RENDERING, both of which are ordinary code with ordinary failure modes, so —
unlike PLAT-11, whose rule is satisfied by there being no code to mutate —
there is no aiming problem here. The arms are grouped by the property they
falsify:

  * §5.3's matching is the ONE predicate both packages call (V1-V4);
  * §5.4's precedence picks the right rule AND reports what it beat, which is
    the half a silent winner would fail (V5-V9);
  * §5.3's hiding removes the field from the line, the children and the totals
    (V10-V12);
  * §5.2's media is classified by a closed enum, drawn only where the surface
    said it can, and degraded with a name and a remedy otherwise (V13-V20);
  * the rendering boundary re-checks what the parse boundary checked, because
    a `Visualiser` can reach `resolve` without having come through a file
    (V21-V26);
  * the two front-end surfaces actually pass the tier and actually report it
    (V27-V31);
  * the work bound's five charges, one arm each, plus the report and the rule
    it blames (V39-V50);
  * what the bound does AFTER it is reached (V51-V53) — added 2026-09-12 by the
    third verification, and the reason they are a group is that all three were
    ARGUMENTS IN A DOC COMMENT. The bound makes four post-exhaustion decisions,
    each justified in its own function's header, each naming the alternative
    and its cost; the 52-case suite was green over all four opposites, and one
    of the four was wrong by 77x. A comment that cannot be made false is where
    an unfalsifiable claim is most comfortable, because the prose around it is
    ABOUT correctness and reads as evidence (§4d one level up, §7a's family).
    The sweep that finds the next one is not "which comments lack arms" — it is
    which SITES lack comments: the decision nobody wrote down was the defect.

IT IS A SEPARATE FILE FROM THE PLAT-7 … PLAT-11 HARNESSES, for the reason
PLAT-8's header gives: each records control digests over its own campaign's
subjects, and merging them would mean one `--record-control-hashes` step
re-blessing several campaigns' files at once.

**AND IT MUST NOT RUN BESIDE THEM.** The locks are per harness and do not
serialise against each other. PLAT-12's subject set is disjoint from every
other harness's — but its SUITES are not disjoint from what other harnesses
COMPILE, and that is the direction residue 12 records: PLAT-11's suites compile
PLAT-8's mutation subject, and a PLAT-8 arm reddens PLAT-11's unmutated suite.
Run one harness at a time.

FIVE VERDICTS, NOT TWO (Verification-Harness-Traps §1a and §17):

  killed           the named case reported [FAILED] **and** the failure output
                   carries the arm's own `because`
  MIS-ATTRIBUTED   the named case went red, but not for the arm's reason — it
                   died upstream of the mutated line (§17). This sits beside
                   HARNESS-FAILURE rather than beside `killed`, because like it
                   the run told you nothing
  SURVIVED         the run produced result lines and the named case was green
  SUITE-DIED       the run produced result lines and the named case is in
                   NEITHER list — the binary died before reaching it
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all

Verdicts are parsed out of `[OK]` / `[FAILED]` RESULT LINES, never out of an
exit status: `nim c -r` returns the same non-zero code for a compile error, a
failed assertion and an OOM.

EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file,
applied on its own, which must leave the suite GREEN. A renamed local, a
hoisted binding, a swapped disjunction, a bound written as arithmetic.

EVERY ARM'S `because` IS CHECKED AGAINST THE CONTROL RUN, BEFORE ANY MUTATION.
A `because` that already occurs in a passing run is true for free.

A `because` IS A QUOTATION OF THE FAILURE TEXT, NOT OF THE SOURCE
(Verification-Harness-Traps §17a). `unittest.check` stringifies the AST it
receives and a template's body is substituted before it gets there, so
`ckEq p.mediaGaps.len, 1` prints as `p.mediaGaps.len == 1` — the CALL SITE's
argument, not the template's parameter name — and no `because` in this file
names a template-local `let`, whose gensym number is not stable across
compilations. Every one below was taken from a real failure transcript; the
`--explain` mode exists so the next person can take theirs the same way.

THE NEEDLE SCAN GATES `--record-control-hashes` (Verification-Harness-Traps
§16): re-recording is exactly the moment an arm's needle has just been moved by
the repair that made the re-record necessary. And §16a: after a repair that
TIGHTENS anything, re-run the arms — a second mechanism disarms an arm exactly
as a moved needle does, and no scan can see it.

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, enforced with an exclusive `flock`
taken BEFORE the control-hash check.

THE CONTROL HASHES ARE RECORDED ON DISK, NOT TAKEN AT START-UP. A baseline
taken at start-up reads a mutation a killed run left behind as the baseline.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat12-visualiser-mutations.py

`-u` matters when the output is redirected: python otherwise block-buffers
stdout and a log stays empty until the last arm.

Arms naming one case are run individually:
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat12-visualiser-mutations.py V1 V9

`--explain <ARM>` applies one arm, runs its suite and prints the failure lines
verbatim, so a `because` is DERIVED from a transcript rather than typed from
the source.
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

# --- the files an arm may touch -------------------------------------------
#
# THIS FILE ONCE CARRIED A SECOND, EARLIER COPY OF EVERYTHING FROM HERE TO
# `acquire_lock`, COPIED FROM THE PLAT-11 HARNESS AND LEFT IN PLACE. It was
# behaviourally inert — the PLAT-12 block below rebound every name, so the
# PLAT-12 lock and the PLAT-12 digests were the ones taken — and it is deleted
# anyway, because the file's whole contract is "never two harnesses at once"
# and a reader forty lines in was being shown `LOCK_PATH = .plat11-…lock` and
# `CONTROL_HASHES = plat11-…sha256` in the file that states it. A shadowed
# constant that names the WRONG LOCK reads, to the next person, as the answer
# to the question they came here with.

VOCAB = "src/common/value_presentation/vocabulary.nim"
PRESENT = "src/common/value_presentation/presenter.nim"
SURFACES = "src/common/value_presentation/surfaces.nim"
BRIDGE = "src/common/value_visualisers.nim"
DEGRADE = "src/frontend/viewmodel/store/value_media_degradation.nim"
TREE = "src/frontend/tui/app/views/tree_node.nim"
PANE = "src/frontend/tui/app/views/variables.nim"

TOUCHED = [VOCAB, PRESENT, SURFACES, BRIDGE, DEGRADE, TREE, PANE]

PURE_SUITE = "src/common/value_visualisers_test.nim"
VM_SUITE = ("src/frontend/viewmodel/tests/unit/"
            "test_visualiser_media_degrades_as_a_pane_row.nim")
TUI_SUITE = "src/frontend/tui/app/tests/test_value_provenance_affordance.nim"

CONTROL_HASHES = HERE / "plat12-visualiser-mutation-control.sha256"
LOCK_PATH = HERE / ".plat12-visualiser-mutation.lock"

NIM_RESULT = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*)$")


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def acquire_lock():
    """Take the exclusive run lock, or explain who holds it and refuse."""
    fh = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.seek(0)
        holder = fh.read().strip() or "(the holder recorded no details)"
        fh.close()
        print("ANOTHER MUTATION RUN HOLDS THE LOCK — nothing was mutated.")
        print(f"  lock: {LOCK_PATH}")
        print(f"  held by: {holder}")
        print("  Two instances in one worktree corrupt each other's restores.")
        return None
    fh.seek(0)
    fh.truncate()
    fh.write(f"pid {os.getpid()} on {os.uname().nodename}, cwd {ROOT}\n")
    fh.flush()
    return fh


# --- the case names, spelled once ------------------------------------------
#
# A typo here shows up as "the killer resolves to 0 green cases" in the
# pre-flight rather than as a silently unkillable arm.

# `src/common/value_visualisers_test.nim`
P_PREDICATE = "the grammar and the presenter ask the same question of a rule"
P_LANGUAGE = "a rule matching by language never claims another language's type"
P_SURFACES = "a summary template renders on EVERY surface, within each budget"
P_FIELDS = "the template substitutes the value's OWN fields, through the presenter"
P_NOFIELD = "a placeholder naming a field the value lacks is REPORTED, not blanked"
P_ONEPASS = "templating is one pass: a substituted value cannot make a placeholder"
P_BRACE = "a doubled brace is a literal brace, as the parser's validator says"
P_HIDES = "a hidden field leaves the line, the children AND the totals"
P_HIDECAP = "a hidden member does not spend the budget's member cap"
P_NOHIDE = "a rule hiding a field the value does not have changes nothing"
P_PRESENT = "a declared presentation replaces the node's kind"
P_NOPRESENT = "a rule that declares NO presentation leaves the value's own shape"
P_VALUEKIND = "a declaration cannot name a presentation a VALUE cannot inhabit"
P_BEATS = "a declaration beats a builtin, and the report names both"
P_UNOPPOSED = "with no declarations the builtin wins and says it was unopposed"
P_SPECIFIC = "the more specific rule wins, and the loser is still reported"
P_BYRANK = "the winner is chosen by RANK, not by position in the list"
P_BYTIER = "a TIER outranks a rank, which is the order §5.4 states"
P_USERRANK = "the user's origin outranks SPECIFICITY, not merely list order"
P_NEARERRANK = "a nearer package outranks a MORE SPECIFIC rule further away"
P_CREDULOUS = "an unclassifiable type is refused even by a surface that claims it"
P_NEARER = "a nearer package's rule outranks an ancestor's at equal specificity"
P_TIE = "a tie is decided by declaration order and BOTH sides are reported"
P_USER = "the user's own rule ranks ahead of the project's, and the id says so"
P_DRAWN = "the one medium every surface honours is rendered as media"
P_DEGRADES = "a media type this surface cannot draw degrades, and the value REMAINS"
P_NOFIELDMEDIA = "a rule pointing at a field the value lacks is its own answer"
P_UNKNOWNMEDIA = "a media type outside §5.2's list has a remedy of its own"
P_DEDUP = "gaps are deduplicated and bounded"
P_GAPBOUND = "the gap list is bounded, so a declaration cannot allocate without limit"
P_ONESET = "the closed media set is ONE set, in both packages"
P_EXACT = "a media type is classified by EXACT equality, never by name-lookup"
P_BOUNDS = "every bound PLAT-11 checks, `admit` checks again from the same number"
P_SEPARATOR = "a field name carrying a path SEPARATOR is refused"
P_CONTROLBYTE = "a field name carrying a CONTROL byte is refused"
P_GOODNAMES = "the legitimate field names a language really produces are admitted"
P_TIERBOUND = "the active tier is bounded by MaxVisualiserRules"
P_COMPAT = "with no visualisers the pipeline is byte-identical to PLAT-2's"
# Added 2026-09-12 by the landing pass. The first five are the cases the three
# UNDECLARED arms that survived the 44-case suite now die against, plus the
# work bound and the tier discriminator.
P_WORKBOUND = "a summary that re-enters its own type is bounded by WORK, not depth"
P_WORKWIDE = "the work bound is on the PRESENTATION, so a wide tree cannot buy depth"
P_EMPTYHIDE = "an EMPTY hide entry hides nothing, so no rule can erase a sequence"
P_BYSPECIFICITY = "SPECIFICITY decides on a list that reached `visualisersFor` unsorted"
P_TIERSILENT = "a Visualiser that never declared a TIER competes at the bottom"
P_MEDIAFIELDDRAWN = "a rule whose field is absent degrades even where the surface CAN draw"
# Added by the landing pass's SECOND verification, 2026-09-12. The first six
# arms below grade the five charges the work bound makes and the byte charge it
# always made; the seventh grades `exhaustedIn`'s first-writer-wins rule, which
# had been documented behaviour with no evidence because every case until now
# carried ONE rule, so "deepest" and "outermost" named the same id.
P_WORKCHARGE = "the bound counts the WORK a frame does, not the bytes it returned"
P_DEEPESTRULE = "the rule NAMED as exhausted is the deepest one, not the outermost"
# Added by the landing pass's THIRD verification, 2026-09-12. The bound makes
# three decisions about what happens AFTER it is reached — one function stops
# walking, two go on answering — and all three were arguments in a header with
# nothing in the suite that could tell them from their opposites. V51 grades
# the one that was wrong (the member walk, 77x the bound); V52 and V53 grade
# the two that were right and unevidenced.
P_SIBLINGWALK = "an exhausted rendering stops WALKING a sibling, not only charging it"
P_ELIDEDRULE = "an ELIDED node still reports the rule that claimed it"

# `test_visualiser_media_degrades_as_a_pane_row.nim`
V_AXIS = "an undrawable declaration sets the dependency axis to unsupported"
V_SATISFIED = "a declaration this surface CAN draw leaves the axis satisfied"
V_ROW = "the gap resolves to pdDependencyMissing on an otherwise healthy trace"
V_PRECEDENCE = "a trace that will not replay outranks an image that will not draw"
V_DETAIL = "the detail names the media type, the surface and a remedy"

# `test_value_provenance_affordance.nim`
T_RENDERS = "a declared visualiser renders the row and the title names it"
T_BUILTIN = "with no declaration the same pane reports the built-in, unopposed"
T_DEGRADED = "a media declaration this terminal cannot draw is REPORTED, not blank"
T_CLEAN = "a declaration this terminal CAN draw leaves nothing to report"


@dataclass
class Suite:
    path: str
    binary: str
    extra_path: bool = False
    tui_path: bool = False


NIM_PURE = Suite(PURE_SUITE, "/tmp/plat12-mut-pure")
NIM_VM = Suite(VM_SUITE, "/tmp/plat12-mut-vm", extra_path=True)
NIM_TUI = Suite(TUI_SUITE, "/tmp/plat12-mut-tui", extra_path=True, tui_path=True)


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    suite: Suite
    because: str
    why: str = ""
    control_name: str = ""
    control_find: str = ""
    control_replace: str = ""


DECLARED_SURVIVORS: list[Mutation] = []


MUTATIONS: list[Mutation] = [
    # -- §5.3's matching: the ONE predicate both packages call --------------
    Mutation(
        "V1", VOCAB,
        "  if ruleLanguage.len > 0 and ruleLanguage != valueLanguage: return false",
        "  if false: return false",
        P_LANGUAGE, NIM_PURE,
        'present(matrix(), StatePanelBudget, languageName = "python",',
        "a rule that named a language stops being restricted to it, so a "
        "project's Rust visualiser claims a Python value of the same type "
        "name — §5.3 lists the language as a match criterion precisely because "
        "one type name means different things in two languages",
        control_name="the language test is written as a named binding",
        control_find="  if ruleLanguage.len > 0 and ruleLanguage != valueLanguage: return false",
        control_replace="  let languageMismatch = ruleLanguage.len > 0 and\n"
                        "                         ruleLanguage != valueLanguage\n"
                        "  if languageMismatch: return false",
    ),
    Mutation(
        "V2", VOCAB,
        "  of mkTypeSuffix:\n    match.len <= typeName.len and\n"
        "      typeName[typeName.len - match.len .. ^1] == match",
        "  of mkTypeSuffix:\n    match.len <= typeName.len and\n"
        "      typeName[0 ..< match.len] == match",
        P_PREDICATE, NIM_PURE,
        'rule.matches(typeName, valueLang) == expected',
        "`typeSuffix` starts matching PREFIXES, so a rule written to catch "
        "`RingBuffer` catches `Buffers` instead and misses the type it named",
        control_name="the suffix slice is taken through a named start index",
        control_find="  of mkTypeSuffix:\n    match.len <= typeName.len and\n"
                     "      typeName[typeName.len - match.len .. ^1] == match",
        control_replace="  of mkTypeSuffix:\n    if match.len > typeName.len: false\n"
                        "    else:\n"
                        "      let start = typeName.len - match.len\n"
                        "      typeName[start .. ^1] == match",
    ),
    # -- §5.4's precedence, and the report that says what it beat -----------
    Mutation(
        # RE-AIMED 2026-09-12 (Verification-Harness-Traps §16). F3 put the two
        # tier reads behind `effectiveTier`, so this arm's quotation of
        # `a.tier < b.tier …` stopped occurring. The needle scan caught it
        # before the digests were re-recorded, which is the ordering §16 exists
        # to impose.
        "V3", PRESENT,
        "  ta < tb or (ta == tb and a.rank > b.rank)",
        "  ta < tb or (ta == tb and a.rank >= b.rank)",
        P_TIE, NIM_PURE,
        'p.root.text == "first"',
        "a TIE stops going to the rule declared first and goes to the last one "
        "instead — §5.4 says ties are broken by declaration order, and a tie "
        "resolved by which entry the loop happened to reach last is not an "
        "order anybody can predict from their own file",
        control_name="the rank comparison is written the other way round",
        control_find="  ta < tb or (ta == tb and a.rank > b.rank)",
        control_replace="  ta < tb or (ta == tb and b.rank < a.rank)",
    ),
    Mutation(
        "V4", PRESENT,
        "    if result < 0 or visualiserRanks(vis, presenters.visualisers[result]):",
        "    if result < 0:",
        P_BYRANK, NIM_PURE,
        'winningVisualiser(matrix(), wrongOrder, "") == 1',
        "specificity stops deciding and the FIRST rule in the list wins, so a "
        "one-character `typePrefix` beats an exact type name — §5.4's "
        "'within a tier the more specific match wins', gone",
        control_name="the rank test is hoisted into a named binding",
        control_find="    if result < 0 or visualiserRanks(vis, presenters.visualisers[result]):",
        control_replace="    let outranksIncumbent =\n"
                        "      result >= 0 and visualiserRanks(vis, presenters.visualisers[result])\n"
                        "    if result < 0 or outranksIncumbent:",
    ),
    Mutation(
        "V5", PRESENT,
        "  for id in resolveBuiltin(v, presenters).candidates:\n    candidates.add id",
        "  for id in resolveBuiltin(v, presenters).candidates:\n    discard id",
        P_BEATS, NIM_PURE,
        'described.contains("over=builtin.record")',
        "a visualiser wins SILENTLY: the attribution reports it as unopposed, "
        "so a user asking why their value looks different is told nothing was "
        "overridden. §5.4's whole reason for the field is that 'a formatting "
        "layer that cannot explain itself becomes untrustworthy the first time "
        "it is wrong'",
        control_name="the builtin candidates are appended through a named seq",
        control_find="  for id in resolveBuiltin(v, presenters).candidates:\n    candidates.add id",
        control_replace="  let builtinCandidates = resolveBuiltin(v, presenters).candidates\n"
                        "  for id in builtinCandidates:\n    candidates.add id",
    ),
    Mutation(
        "V6", PRESENT,
        "  let vis = winningVisualiser(v, presenters, language)\n  if vis < 0:\n"
        "    return resolveBuiltin(v, presenters)",
        "  let vis = winningVisualiser(v, presenters, language)\n  if true:\n"
        "    return resolveBuiltin(v, presenters)",
        P_BEATS, NIM_PURE,
        'described.contains("project:.codetracer/visualisers.toml#0")',
        "the whole visualiser TIER disappears from the attribution: values "
        "still render through it, and the report names the built-in that did "
        "not draw them — which is the worst of both, a layer that cannot "
        "explain itself AND explains itself wrongly",
        control_name="the tier test is written against a named index",
        control_find="  let vis = winningVisualiser(v, presenters, language)\n  if vis < 0:\n"
                     "    return resolveBuiltin(v, presenters)",
        control_replace="  let vis = winningVisualiser(v, presenters, language)\n"
                        "  let noVisualiserMatched = vis < 0\n"
                        "  if noVisualiserMatched:\n"
                        "    return resolveBuiltin(v, presenters)",
    ),
    Mutation(
        "V7", BRIDGE,
        "  let originWeight = if origin == doUser: 1 else: 0",
        "  let originWeight = 0",
        P_USERRANK, NIM_PURE,
        'present(matrix(), StatePanelBudget, presenters = presenters).root.text ==',
        "a user's own rule stops outranking the project's, so a local "
        "experiment on a checked-in type silently does nothing and the author "
        "has no way to tell it apart from a rule that failed to parse",
        control_name="the origin weight is computed with a case",
        control_find="  let originWeight = if origin == doUser: 1 else: 0",
        control_replace="  var originWeight = 0\n"
                        "  case origin\n"
                        "  of doUser: originWeight = 1\n"
                        "  of doProject: originWeight = 0",
    ),
    Mutation(
        "V8", BRIDGE,
        "  originWeight * 1_000_000 + scopeDepth(rule.scope) * 10_000 + specificity(rule)",
        "  originWeight * 1_000_000 + specificity(rule)",
        P_NEARERRANK, NIM_PURE,
        'present(matrix(), StatePanelBudget, presenters = presenters).root.text ==',
        "§6's 'a nearer .codetracer/ overrides an ancestor's' stops applying "
        "to visualisers: a monorepo package's own rule ties with the root's "
        "and the tie is then broken by declaration order, so which package's "
        "rule wins depends on the order the caller enumerated directories",
        control_name="the rank is accumulated rather than summed in one line",
        control_find="  originWeight * 1_000_000 + scopeDepth(rule.scope) * 10_000 + specificity(rule)",
        control_replace="  var acc = originWeight * 1_000_000\n"
                        "  acc += scopeDepth(rule.scope) * 10_000\n"
                        "  acc += specificity(rule)\n"
                        "  acc",
    ),
    # -- §5.3's hiding ------------------------------------------------------
    Mutation(
        "V9", PRESENT,
        "  for h in hide:\n    if h == label: return true\n  false",
        "  for h in hide:\n    if false: return true\n  false",
        P_HIDES, NIM_PURE,
        'not hidden.root.text.contains("scratch")',
        "§5.3's 'often the single most valuable thing a visualiser does' stops "
        "happening: a project that hides an internal scratch buffer from every "
        "surface gets it shown on every surface, with no error anywhere",
        control_name="the hide membership is tested through a named binding",
        control_find="  for h in hide:\n    if h == label: return true\n  false",
        control_replace="  for h in hide:\n    let isHiddenName = h == label\n"
                        "    if isHiddenName: return true\n  false",
    ),
    Mutation(
        # RE-AIMED 2026-09-12 (Verification-Harness-Traps §16), by the third
        # verification. The F2 repair put an `elif tally.exhausted` branch
        # between the two lines this arm quoted, so the quotation stopped
        # occurring. The needle scan caught it BEFORE the digests were
        # re-recorded, which is the ordering §16 exists to impose — re-record
        # first and the harness would have been perfectly consistent with a
        # tree in which this arm described nothing.
        "V10", PRESENT,
        "    elif tally.exhausted: v.members.len\n    else: visible.len",
        "    elif tally.exhausted: v.members.len\n    else: v.members.len",
        P_HIDES, NIM_PURE,
        "hidden.root.totalMembers == 3",
        "the TOTALS stop agreeing with the children: the line hides the field "
        "and the node still counts it, so a record whose every remaining field "
        "is hidden keeps its expansion caret and opens onto nothing",
        control_name="the shown-member count is written as a nested if",
        control_find="    elif tally.exhausted: v.members.len\n    else: visible.len",
        control_replace="    elif tally.exhausted: v.members.len\n"
                        "    else: (if visible.len >= 0: visible.len else: 0)",
    ),
    Mutation(
        "V11", PRESENT,
        "  var visible: seq[int] = @[]\n  for i in 0 ..< v.members.len:\n"
        "    if not isHidden(hide, v.members[i].label): visible.add i\n"
        "  let total = visible.len",
        "  var visible: seq[int] = @[]\n  for i in 0 ..< v.members.len:\n"
        "    visible.add i\n"
        "  let total = visible.len",
        P_HIDES, NIM_PURE,
        'not hidden.root.text.contains("scratch")',
        "hiding applies to the CHILDREN and not to the line, so the state "
        "panel's tree drops the field and the same panel's value cell shows "
        "it — two spellings of one value in one pane, which is the failure "
        "PLAT-2's own risk section names",
        control_name="the visible-member walk uses an explicit index variable",
        control_find="  var visible: seq[int] = @[]\n  for i in 0 ..< v.members.len:\n"
                     "    if not isHidden(hide, v.members[i].label): visible.add i\n"
                     "  let total = visible.len",
        control_replace="  var visible: seq[int] = @[]\n  var scan = 0\n"
                        "  while scan < v.members.len:\n"
                        "    if not isHidden(hide, v.members[scan].label): visible.add scan\n"
                        "    inc scan\n"
                        "  let total = visible.len",
    ),
    # -- §5.3's 'how it presents' -------------------------------------------
    Mutation(
        "V12", PRESENT,
        "    if vis.presentDeclared:",
        "    if true:",
        P_NOPRESENT, NIM_PURE,
        "present(point(), StatePanelBudget, presenters = presenters).root.kind == pkTree",
        "`pkText` being the enum's zero value is read as a declaration, so "
        "every rule that hides a field or declares media ALSO flattens the "
        "value to a leaf — the tree beside it disappears and nothing says so",
        control_name="the declared-presentation test is hoisted",
        control_find="    if vis.presentDeclared:",
        control_replace="    let declaredAPresentation = vis.presentDeclared\n"
                        "    if declaredAPresentation:",
    ),
    # -- §5.2's media, and its degradation ----------------------------------
    Mutation(
        "V13", VOCAB,
        "    if c != mcUnknown and mediaTypeSpelling(c) == mediaType:",
        "    if c != mcUnknown and mediaType.contains(mediaTypeSpelling(c)):",
        P_EXACT, NIM_PURE,
        "mediaClassOf(spelling) == mcUnknown",
        "the media type stops being classified by EXACT equality and starts "
        "being matched by CONTAINMENT — which is dispatch by name over a "
        "string a cloned repository wrote, the one thing this enum exists to "
        "prevent. `image/png; charset=x`, `../image/png` and "
        "`image/png/../../etc/passwd` all classify as PNG",
        control_name="the spelling comparison is taken through a named binding",
        control_find="    if c != mcUnknown and mediaTypeSpelling(c) == mediaType:",
        control_replace="    let spelling = mediaTypeSpelling(c)\n"
                        "    if c != mcUnknown and spelling == mediaType:",
    ),
    Mutation(
        "V14", PRESENT,
        "  if class notin ctx.budget.media: return false",
        "  if false: return false",
        P_DEGRADES, NIM_PURE,
        "p.mediaGaps.len == 1",
        "every surface claims to draw every medium, so a terminal with no "
        "image protocol renders `<image/png, 40 bytes>` in place of the value "
        "and reports nothing missing — a blank region with a caption, which is "
        "exactly what §8.2 forbids",
        control_name="the surface capability test is written as a membership",
        control_find="  if class notin ctx.budget.media: return false",
        control_replace="  let surfaceClaimsIt = class in ctx.budget.media\n"
                        "  if not surfaceClaimsIt: return false",
    ),
    Mutation(
        "V15", PRESENT,
        "  if class == mcUnknown: return false",
        "  if false: return false",
        P_CREDULOUS, NIM_PURE,
        "p.mediaGaps.len == 1",
        "a media type this build cannot classify is DRAWN anyway: the value "
        "is replaced by a label naming a type no surface understands, and the "
        "reader loses the value to get a string",
        control_name="the unknown-class test is written as a set membership",
        control_find="  if class == mcUnknown: return false",
        control_replace="  if class in {mcUnknown}: return false",
    ),
    Mutation(
        "V16", PRESENT,
        "    tally.noteGap(mediaGapFor(vis, ctx, field, tally))",
        "    discard mediaGapFor(vis, ctx, field, tally)",
        P_DEGRADES, NIM_PURE,
        "p.mediaGaps.len == 1",
        "the degradation becomes SILENT: the value still renders, and nothing "
        "anywhere says the project asked for an image and did not get one. "
        "That is the 'degraded, not broken' half of §8.2 without the "
        "'visibly' half, which is indistinguishable from the declaration "
        "having been ignored",
        control_name="the gap is built into a named binding first",
        control_find="    tally.noteGap(mediaGapFor(vis, ctx, field, tally))",
        control_replace="    let gap = mediaGapFor(vis, ctx, field, tally)\n"
                        "    tally.noteGap(gap)",
    ),
    Mutation(
        "V17", PRESENT,
        "  for existing in tally.gaps:\n    if existing == gap: return",
        "  for existing in tally.gaps:\n    if false: return",
        P_DEDUP, NIM_PURE,
        "p.mediaGaps.len == 1",
        "one declaration is reported once per RENDERING rather than once: a "
        "member is drawn twice in an ordinary presentation — inside its "
        "parent's line and as its own node — so the reader is told about two "
        "problems where there is one, and the `MaxMediaGaps` bound is then "
        "reached by a value with four",
        control_name="the duplicate test is written through a named binding",
        control_find="  for existing in tally.gaps:\n    if existing == gap: return",
        control_replace="  for existing in tally.gaps:\n"
                        "    let alreadyReported = existing == gap\n"
                        "    if alreadyReported: return",
    ),
    Mutation(
        "V18", PRESENT,
        "  if tally.gaps.len >= MaxMediaGaps: return",
        "  if false: return",
        P_GAPBOUND, NIM_PURE,
        "p.mediaGaps.len == MaxMediaGaps",
        "the gap list stops being bounded, so a cloned repository's "
        "declarations decide how many sentences this process allocates per "
        "rendered value — a rule matching by suffix over a thousand-member "
        "record is a thousand strings, per surface, per frame",
        control_name="the bound is written as arithmetic",
        control_find="  if tally.gaps.len >= MaxMediaGaps: return",
        control_replace="  if tally.gaps.len > MaxMediaGaps - 1: return",
    ),
    Mutation(
        "V19", VOCAB,
        "  if not g.fieldPresent:",
        "  if false:",
        P_NOFIELDMEDIA, NIM_PURE,
        'detail.contains("no such field")',
        "a rule pointing at a field the value does not have is reported as a "
        "surface that cannot draw, so the author is told to open the value "
        "somewhere else — the retry that cannot succeed, for a declaration "
        "that is simply wrong",
        control_name="the field-presence test is written as a negation",
        control_find="  if not g.fieldPresent:",
        control_replace="  if g.fieldPresent == false:",
    ),
    Mutation(
        "V20", SURFACES,
        "  MediaCapabilityNote* = {mcOctetStream}",
        "  MediaCapabilityNote*: set[MediaClass] = {}",
        P_DRAWN, NIM_PURE,
        'p.root.text == Label',
        "no surface draws anything at all, so §5.2's mechanism has no positive "
        "arm anywhere in the product and the degradation path below is the "
        "only reachable behaviour — a feature that is all fallback",
        control_name="the capability set is written as an explicit set literal",
        control_find="  MediaCapabilityNote* = {mcOctetStream}",
        control_replace="  MediaCapabilityNote*: set[MediaClass] = {mcOctetStream}",
    ),
    Mutation(
        "V21", VOCAB,
        "  if p.mediaGaps.len > 0:",
        "  if false:",
        P_DEGRADES, NIM_PURE,
        'describeAttribution(p).contains("media-degraded=image/png")',
        "the one-line answer to 'which visualiser rendered this' stops saying "
        "that the visualiser asked for something it did not get — true, and "
        "misleading at once, on every surface that has room for one line and "
        "not for a paragraph",
        control_name="the gap test is written as a non-empty check",
        control_find="  if p.mediaGaps.len > 0:",
        control_replace="  if p.mediaGaps.len != 0:",
    ),
    # -- templating ---------------------------------------------------------
    Mutation(
        "V22", PRESENT,
        '        acc.add "<no field \'" & name & "\'>"',
        '        acc.add ""',
        P_NOFIELD, NIM_PURE,
        r'''text == "10,<no field \'z\'>"''',
        "a placeholder naming a field the value does not have renders as "
        "NOTHING. `app/source_binding.annotationsFrom` drops a variable whose "
        "rendering is empty, and a step-to-step diff cannot see a change "
        "between two values that both render as \"\" — so a wrong rule is "
        "invisible to the person who wrote it",
        control_name="the missing-field marker is built in a named binding",
        control_find='        acc.add "<no field \'" & name & "\'>"',
        control_replace='        let marker = "<no field \'" & name & "\'>"\n'
                        '        acc.add marker',
    ),
    Mutation(
        "V23", PRESENT,
        "        acc.add '{'\n        i += 2",
        "        acc.add '{'\n        i += 1",
        P_BRACE, NIM_PURE,
        'present(point(), StatePanelBudget, presenters = presenters).root.text ==',
        "`{{` stops being an escape for one literal brace and becomes two, so "
        "a summary that wants to show a brace shows two and a template nobody "
        "can write correctly",
        control_name="the escape advance is written as two increments",
        control_find="        acc.add '{'\n        i += 2",
        control_replace="        acc.add '{'\n        inc i\n        inc i",
    ),
    # -- the admission boundary: what parsing excluded, not reopened --------
    Mutation(
        "V24", BRIDGE,
        "  if rule.match.len == 0 or rule.match.len > MaxTypeMatchBytes: return false",
        "  if false: return false",
        P_BOUNDS, NIM_PURE,
        'not admit(VisualiserRule(match: ""))',
        "an unbounded match string reaches `winningVisualiser`, which compares "
        "it against every rendered node's type name on every surface — and an "
        "EMPTY one matches every unnamed value, so one malformed rule claims "
        "the whole tier",
        control_name="the match bound is tested in two statements",
        control_find="  if rule.match.len == 0 or rule.match.len > MaxTypeMatchBytes: return false",
        control_replace="  if rule.match.len == 0: return false\n"
                        "  if rule.match.len > MaxTypeMatchBytes: return false",
    ),
    Mutation(
        "V25", BRIDGE,
        "    if ch == '/' or ch == '\\\\': return false",
        "    if false: return false",
        P_SEPARATOR, NIM_PURE,
        'not admit(VisualiserRule(match: "M", mediaType: "image/png", mediaFrom: bad))',
        "a field name may carry a path separator. Nothing opens it TODAY — "
        "there is no field on a `Visualiser` that names a file — and the "
        "refusal is what stops `../secrets` from becoming a path by somebody "
        "else's edit, which is PLAT-11's own reason for a closed path grammar "
        "applied to the one string that is not a path",
        control_name="the separator test is written as a set membership",
        control_find="    if ch == '/' or ch == '\\\\': return false",
        control_replace="    if ch in {'/', '\\\\'}: return false",
    ),
    Mutation(
        "V26", BRIDGE,
        "    if ch < ' ' or ch == '\\x7f': return false",
        "    if false: return false",
        P_CONTROLBYTE, NIM_PURE,
        'not admit(VisualiserRule(match: "M", hide: @[bad]))',
        "a NUL can sit in a field name. Every comparison above it runs on the "
        "whole string and every C API below it sees the string truncated at "
        "the NUL — the same split PLAT-11's `ppControlChar` closes for a path, "
        "arriving through a name that is compared to one",
        control_name="the control-character test is written as a set membership",
        control_find="    if ch < ' ' or ch == '\\x7f': return false",
        control_replace="    if ch in {'\\x00' .. '\\x1f', '\\x7f'}: return false",
    ),
    Mutation(
        "V27", BRIDGE,
        "    if mediaClassOf(rule.mediaType) == mcUnknown: return false",
        "    if false: return false",
        P_UNKNOWNMEDIA, NIM_PURE,
        'not admit(VisualiserRule(match: "Image", mediaType: "image/tiff",',
        "a media type outside §5.2's closed list becomes a `Visualiser`, so "
        "the grammar's closed list stops being closed at the boundary where "
        "the string is about to be rendered from",
        control_name="the classification is taken through a named binding",
        control_find="    if mediaClassOf(rule.mediaType) == mcUnknown: return false",
        control_replace="    let declaredClass = mediaClassOf(rule.mediaType)\n"
                        "    if declaredClass == mcUnknown: return false",
    ),
    Mutation(
        "V28", BRIDGE,
        "    if result.len >= MaxVisualiserRules: break",
        "    if false: break",
        P_TIERBOUND, NIM_PURE,
        "visualisersFor(synthesised).len == MaxVisualiserRules",
        "the active tier stops being bounded, and it is the list "
        "`winningVisualiser` walks ONCE PER RENDERED NODE on every surface — "
        "so its length is a number a cloned repository chooses and multiplies "
        "against the size of a recording",
        control_name="the tier bound is written as arithmetic",
        control_find="    if result.len >= MaxVisualiserRules: break",
        control_replace="    if result.len > MaxVisualiserRules - 1: break",
    ),
    Mutation(
        "V29", BRIDGE,
        "  if rule.present notin ValuePresentationKinds: return false",
        "  if false: return false",
        P_VALUEKIND, NIM_PURE,
        "admit(VisualiserRule(match: \"Point\", present: k)) == k in ValuePresentationKinds",
        "a declaration may name a presentation a VALUE cannot inhabit, so a "
        "recorded record becomes a `Button` or a `Modal` — PLAT-3's eleven "
        "interaction and chrome forms reachable from a `git clone`",
        control_name="the presentation range test is written as a membership",
        control_find="  if rule.present notin ValuePresentationKinds: return false",
        control_replace="  if not (rule.present in ValuePresentationKinds): return false",
    ),
    # -- the degraded state a pane renders ----------------------------------
    Mutation(
        "V30", DEGRADE,
        "  if p.mediaGaps.len == 0: pdsSatisfied else: pdsUnsupported",
        "  if p.mediaGaps.len >= 0: pdsSatisfied else: pdsUnsupported",
        V_AXIS, NIM_VM,
        "mediaDependencyState(degraded) == pdsUnsupported",
        "a media gap never reaches the degraded-state catalogue, so every pane "
        "that renders values reports `pdNone` while a declaration is going "
        "undrawn — the gap exists, is described, and no surface treatment "
        "follows from it",
        control_name="the axis is decided with a case on emptiness",
        control_find="  if p.mediaGaps.len == 0: pdsSatisfied else: pdsUnsupported",
        control_replace="  if p.mediaGaps.len > 0: pdsUnsupported else: pdsSatisfied",
    ),
    Mutation(
        "V31", DEGRADE,
        "  result.dependency = mediaDependencyState(p)",
        "  result.dependency = pdsSatisfied",
        V_ROW, NIM_VM,
        "valueSnapshot(initDegradedStateSnapshot(), degraded).dependency ==",
        "the snapshot carries the session's four axes and drops the fifth, so "
        "`resolveDegradation` decides on data that cannot express the thing "
        "that is wrong. The same shape as a `surfaceDegradation` that forgot "
        "to call `dependencyState`",
        control_name="the axis is assigned through a named binding",
        control_find="  result.dependency = mediaDependencyState(p)",
        control_replace="  let axis = mediaDependencyState(p)\n"
                        "  result.dependency = axis",
    ),
    Mutation(
        "V32", DEGRADE,
        "    pdEngineUnavailable,\n    pdDependencyMissing,\n  }",
        "    pdEngineUnavailable,\n  }",
        V_ROW, NIM_VM,
        "ValuePresentationDegradations ==",
        "the sensitivity set stops naming the one row this module exists to "
        "produce, so a gap resolves to `pdNone` — `degraded_state`'s own rule "
        "is that a pane not sensitive to a condition reports `pdNone`, and "
        "here the condition is the pane's own",
        control_name="the set is written with a trailing member reordered",
        control_find="    pdEngineUnavailable,\n    pdDependencyMissing,\n  }",
        control_replace="    pdDependencyMissing,\n    pdEngineUnavailable,\n  }",
    ),
    # -- the two front-end surfaces -----------------------------------------
    Mutation(
        "V33", TREE,
        "          presenters = withVisualisers(spec.visualisers))",
        "          presenters = BuiltinPresenters)",
        T_RENDERS, NIM_TUI,
        'spec.formattedValue(40) == "(10, 20)"',
        "the terminal's variables pane stops passing the tier, so a project's "
        "visualiser renders on the desktop and not in the terminal — which "
        "makes `--ui` a product choice, the exact risk PLAT-12's own risk "
        "section names and `CLI/ct/ui-selection.md` forbids",
        control_name="the presenter set is built into a named binding",
        control_find="          presenters = withVisualisers(spec.visualisers))",
        control_replace="          presenters = withVisualisers(spec.visualisers))\n"
                        "\nproc presenterSetOf*(spec: TreeRowSpec): PresenterSet =\n"
                        "  ## Named accessor for the row's presenter set.\n"
                        "  withVisualisers(spec.visualisers)",
    ),
    Mutation(
        "V34", PANE,
        "      memberCount: row.node.memberCount, presented: row.node.presented,\n"
        "      visualisers: model.visualisers,",
        "      memberCount: row.node.memberCount, presented: row.node.presented,\n"
        "      visualisers: @[],",
        T_RENDERS, NIM_TUI,
        'spec.formattedValue(40) == "(10, 20)"',
        "the pane holds the tier and never hands it to the row, so every row "
        "renders by the built-in table while the pane's TITLE — which builds "
        "its own spec — reports the visualiser. A pane that names a presenter "
        "it did not draw with is worse than one that names none",
        control_name="the row's visualisers are taken through a named binding",
        control_find="proc rowSpecFor*(model: VariablesModel; row: VariablesRow;\n"
                     "                 width: int): TreeRowSpec =",
        control_replace="proc rowVisualisers(model: VariablesModel): seq[Visualiser] =\n"
                        "  ## Named accessor, so the row and the title read one field.\n"
                        "  model.visualisers\n"
                        "\nproc rowSpecFor*(model: VariablesModel; row: VariablesRow;\n"
                        "                 width: int): TreeRowSpec =",
    ),
    # -- THE LANDING PASS, 2026-09-12 -------------------------------------
    #
    # V36-V38 are the three arms that a verification pass planted UNDECLARED
    # and that survived the whole 44-case suite. All three are §16a in its
    # exact shape — a guard whose every case is also satisfied by a second
    # mechanism beside it — and all three are answered the way §16a asks: not
    # by deleting a mechanism, but by giving each one evidence only it can
    # satisfy. V39-V41 are the work bound F1 added and its two halves; V42 is
    # the tier discriminator.
    Mutation(
        "V36", BRIDGE,
        "  originWeight * 1_000_000 + scopeDepth(rule.scope) * 10_000 + specificity(rule)",
        "  originWeight * 1_000_000 + scopeDepth(rule.scope) * 10_000",
        P_BYSPECIFICITY, NIM_PURE,
        'present(matrix(), StatePanelBudget, presenters = presenters).root.text ==',
        "§5.4's 'within a tier the more specific match wins' stops applying to "
        "a list that did not arrive pre-sorted. THIS IS V7's AND V8's DEFECT ON "
        "THE THIRD TERM OF THE SAME EXPRESSION, and it survived the 44-case "
        "suite: `load.rankVisualisers` hands `visualisersFor` a seq already in "
        "§5.4's order, so a rank with no specificity term agrees with the "
        "seq's order on every list a FILE produces — and the one case that "
        "separates rank from list order sets `rank:` by hand and never reaches "
        "`rankOf`",
        control_name="the rank is accumulated rather than summed in one line",
        control_find="  originWeight * 1_000_000 + scopeDepth(rule.scope) * 10_000 + specificity(rule)",
        control_replace="  var acc = originWeight * 1_000_000\n"
                        "  acc += scopeDepth(rule.scope) * 10_000\n"
                        "  acc += specificity(rule)\n"
                        "  acc",
    ),
    Mutation(
        "V37", PRESENT,
        "  not field.isNil\n\nfunc visualisedText(",
        "  true\n\nfunc visualisedText(",
        P_MEDIAFIELDDRAWN, NIM_PURE,
        'p.root.text.startsWith("Image(")',
        "the THIRD of `surfaceDrawsMedia`'s three conditions goes, and its own "
        "doc comment says all three are necessary. A rule declaring "
        "`application/octet-stream` — the one class EVERY budget claims — from "
        "a field the value does not have renders "
        "`<application/octet-stream, 0 bytes>` IN PLACE OF the value and "
        "reports NO gap: a blank region with a caption, which is what §8.2 "
        "forbids. It survived the 44-case suite because the only missing-field "
        "case declared `image/png`, which condition 2 already refuses",
        control_name="the field-presence test is written through a named binding",
        control_find="  not field.isNil\n\nfunc visualisedText(",
        control_replace="  let declaredField = field\n"
                        "  not declaredField.isNil\n\nfunc visualisedText(",
    ),
    Mutation(
        "V38", PRESENT,
        "  if label.len == 0: return false\n  for h in hide:",
        "  if false: return false\n  for h in hide:",
        P_EMPTYHIDE, NIM_PURE,
        'ruled.root.text == plain.root.text',
        "a rule hiding the empty string erases every POSITIONAL element of "
        "every sequence and tuple it matches — from the line, from the "
        "children and from the totals — because a positional member's label "
        "is \"\". `admit` refuses such a rule, so only a `Visualiser` built "
        "without it can carry one, which is exactly the argument "
        "`describeMediaGap`'s `mcUnknown` arm already makes with a hand-built "
        "case; it survived the 44-case suite because no case applied that "
        "standard here",
        control_name="the empty-label guard is written as a non-empty test",
        control_find="  if label.len == 0: return false\n  for h in hide:",
        control_replace="  if not (label.len > 0): return false\n  for h in hide:",
    ),
    Mutation(
        "V39", PRESENT,
        "  if tally.work >= MaxRenderWork:",
        "  if false:",
        P_WORKBOUND, NIM_PURE,
        "p.root.text.len <= MaxRenderWork",
        "§5.2's templating goes back to being unbounded. A summary is "
        "substituted by RENDERING the field it names, so a rule matching a "
        "type that contains itself re-enters its own template once per "
        "placeholder: 16 per level, levels bounded only by `Budget.depth`. "
        "Measured before the bound, at the state panel's own depth of 7: "
        "4,294,967,296 bytes and 125 seconds for ONE value, from a 200-byte "
        "declaration a `git clone` brings with it",
        control_name="the work bound is written as arithmetic",
        control_find="  if tally.work >= MaxRenderWork:",
        control_replace="  if tally.work > MaxRenderWork - 1:",
    ),
    Mutation(
        "V40", PRESENT,
        "    tally.exhausted = true\n    return Ellipsis",
        "    return Ellipsis",
        P_WORKBOUND, NIM_PURE,
        "p.expansion.reached",
        "the bound still holds and stops saying so. The value is cut off, the "
        "elision glyph is there, and NOTHING reports that this process refused "
        "to finish — no marker on the one-line attribution, no sentence, no "
        "remedy, and `expansion.reached` false. §8.2's 'degraded, not broken' "
        "without the 'visibly', which is indistinguishable from a rule that "
        "was simply written badly",
        control_name="the exhausted flag is set through a named binding",
        control_find="    tally.exhausted = true\n    return Ellipsis",
        control_replace="    let ranOut = true\n    tally.exhausted = ranOut\n"
                        "    return Ellipsis",
    ),
    Mutation(
        "V41", PRESENT,
        "  if tally.exhausted:\n    # PLAT-12. The bound is on the PRESENTATION",
        "  if false:\n    # PLAT-12. The bound is on the PRESENTATION",
        P_WORKWIDE, NIM_PURE,
        # RE-ATTRIBUTED 2026-09-12 (Verification-Harness-Traps §16a), by the
        # third verification, and it is that entry's own shape arriving in the
        # same pass that created it. This arm's `because` was
        # `p.root.children.len == 0` and its needle never moved — the needle
        # scan passed, the mutation applied, the case went red — but the F2
        # repair skips the hidden-member walk for an exhausted node, so
        # `visible` is EMPTY and the record arm's child loop adds nothing
        # whether or not this return exists. The old `because` had stopped
        # being evidence about the RETURN and become evidence about the WALK,
        # and the harness said so: MIS-ATTRIBUTED, the fourth verdict doing
        # exactly what §17 added it for.
        #
        # The remedy is §16a's — disjoint evidence, not a deleted arm. A MAP is
        # what only this return refuses: `renderNode`'s map arm iterates
        # `v.entries` and never consults `visible`, so the walk guard cannot
        # reach it. The `because` below is the map's, taken from a transcript.
        "m.root.keys.len == 0",
        "the node's own LINE stops at the bound and its CHILDREN do not: "
        "`renderNode` goes on descending, and every `inlineText` below an "
        "exhausted rendering returns the elision glyph for free — so a shared "
        "sub-value referenced six times per level builds 6^7 nodes whose text "
        "is all `…`. The bound is on the PRESENTATION, and a tree walk that "
        "ignores it puts the cost back in the allocator instead of the string",
        control_name="the exhausted descent test is hoisted into a binding",
        control_find="  if tally.exhausted:\n    # PLAT-12. The bound is on the PRESENTATION",
        control_replace="  let allowanceGone = tally.exhausted\n"
                        "  if allowanceGone:\n"
                        "    # PLAT-12. The bound is on the PRESENTATION",
    ),
    Mutation(
        "V42", PRESENT,
        "  if vis.tierDeclared: vis.tier else: ptBuiltin",
        "  vis.tier",
        P_TIERSILENT, NIM_PURE,
        "effectiveTier(silent) == ptBuiltin",
        "`ptInProgram` is the zero value of `PresenterTier` AND §5.4's "
        "highest-precedence tier, so a `Visualiser` built by anything that "
        "omitted `tier` wins against every declaration in the product — "
        "silently, with maximum privilege, on a rank of zero. `pkText`'s "
        "shape with a worse blast radius, and the producers §5.1 still expects "
        "(a plugin tier, PLAT-13's executable tier) are the ones that build a "
        "`Visualiser` by hand",
        control_name="the declared-tier test is written as a negation",
        control_find="  if vis.tierDeclared: vis.tier else: ptBuiltin",
        control_replace="  if not vis.tierDeclared: ptBuiltin else: vis.tier",
    ),
    # -- the work bound's FIVE charges, one arm each ------------------------
    #
    # V39 grades the TEST of the bound and V40 its report; these grade what the
    # bound is a bound ON. They exist because a verification pass removed the
    # per-frame charge and the 50-case suite stayed green (§16a in its exact
    # shape: the byte charge covered every case the frame charge had), and then
    # measured that neither charge covered the three O(n) walks a frame makes —
    # 19.5 seconds on one value, with `spent` reporting the same 1,048,582 it
    # reports for a field two hundred times smaller.
    Mutation(
        "V43", PRESENT,
        "  inc tally.work\n  let vi = chargedWinner(",
        "  let vi = chargedWinner(",
        P_WORKCHARGE, NIM_PURE,
        "plain.expansion.spent == 1801",
        "the bound stops counting FRAMES and counts only what they returned. "
        "It can never be worse than a factor of two — no rendering in this "
        "pipeline returns zero bytes, the shortest being a `{{` summary's one "
        "— which is exactly why nothing but an EQUALITY over `spent` can "
        "grade it, and why the arm survived the whole suite before this case "
        "existed. `spent` is a number a reader is invited to watch "
        "approaching, and an under-count is a false report",
        control_name="the frame charge is written as an addition",
        control_find="  inc tally.work\n  let vi = chargedWinner(",
        control_replace="  tally.work += 1\n  let vi = chargedWinner(",
    ),
    Mutation(
        "V44", PRESENT,
        "  tally.work += memberScanCost(v)\n"
        "  let attribution = resolveBuiltin(v, presenters)",
        "  let attribution = resolveBuiltin(v, presenters)",
        P_WORKCHARGE, NIM_PURE,
        "plain.expansion.spent == 1801",
        "the member walks go back to being free on the BUILT-IN path, which "
        "needs no `media` key and no declaration beyond a summary naming one "
        "byte field: `byteBufferOf` runs twice over a sequence and allocates a "
        "slot per member, and `formatByteBuffer` then prints at most "
        "`budget.members` of them, so the output the byte charge prices is "
        "capped while the walk is not. Measured at 200,000 bytes: 474 ms with "
        "`spent` at 105,513, a tenth of the bound — so the rendering was not "
        "even stopped",
        control_name="the builtin member charge is hoisted into a binding",
        control_find="  tally.work += memberScanCost(v)\n"
                     "  let attribution = resolveBuiltin(v, presenters)",
        control_replace="  let walked = memberScanCost(v)\n"
                        "  tally.work += walked\n"
                        "  let attribution = resolveBuiltin(v, presenters)",
    ),
    Mutation(
        "V45", PRESENT,
        "    tally.work += memberScanCost(v)\n    for i in 0 ..< v.members.len:",
        "    for i in 0 ..< v.members.len:",
        P_WORKCHARGE, NIM_PURE,
        "plain.expansion.spent == 1801",
        "the SECOND walk of the same members — `renderNode`'s own "
        "hidden-member scan, which runs once per node on a node count the "
        "bound is supposed to cap — stops being paid for. One charge on one of "
        "two spending sites is §14's defect with the roles reversed: the "
        "predicate is shared and the CALL SITE is missing, so the half that "
        "still charges goes on agreeing with itself",
        control_name="the node's member charge is hoisted into a binding",
        control_find="    tally.work += memberScanCost(v)\n"
                     "    for i in 0 ..< v.members.len:",
        control_replace="    let walked = memberScanCost(v)\n"
                        "    tally.work += walked\n"
                        "    for i in 0 ..< v.members.len:",
    ),
    Mutation(
        "V46", PRESENT,
        "    tally.work += visualiserScanCost(v, presenters)",
        "    discard visualiserScanCost(v, presenters)",
        P_WORKCHARGE, NIM_PURE,
        "oneByte.expansion.spent == 2210",
        "the visualiser scan goes back to being free, and BOTH of its bounds "
        "are the declaration's: `MaxVisualiserRules` x `MaxTypeMatchBytes` is "
        "51,200 byte comparisons per rendered node, from a file a `git clone` "
        "brought with it. Bounded per frame is not bounded per presentation — "
        "the frame count is the thing `MaxRenderWork` exists to bound, so the "
        "two multiply. Measured with one recursive rule plus 255 decoys "
        "sharing 199 of 200 bytes with the type name: 112 ms against 13 ms at "
        "one rule, with `spent` constant across all four",
        control_name="the scan charge is hoisted into a binding",
        control_find="    tally.work += visualiserScanCost(v, presenters)",
        control_replace="    let scanned = visualiserScanCost(v, presenters)\n"
                        "    tally.work += scanned",
    ),
    Mutation(
        "V47", PRESENT,
        "  tally.work += mediaScanCost(m)",
        "  discard mediaScanCost(m)",
        P_WORKCHARGE, NIM_PURE,
        "large.expansion.spent - small.expansion.spent == 2 * (400 - 40)",
        "the DOMINANT term of the finding this group was written for. "
        "`declaredMediaBytes` walks and allocates a `seq[int]` as long as the "
        "field `mediaFrom` names, twice per value — once for the gap, once for "
        "the node — and `noteGap` deduplicates a gap this walk has already "
        "BUILT, so the walk happens every frame whether or not the gap is new. "
        "Measured against a 200,000-byte field at the state panel's depth: "
        "19,511 ms for ONE value, linear in the field, with `spent` identical "
        "in every run",
        control_name="the media charge is hoisted into a binding",
        control_find="  tally.work += mediaScanCost(m)",
        control_replace="  let walked = mediaScanCost(m)\n  tally.work += walked",
    ),
    Mutation(
        "V48", PRESENT,
        "    tally.work += result.len",
        "    discard result.len",
        P_WORKCHARGE, NIM_PURE,
        "plain.expansion.spent == 1801",
        "the bound stops being a bound on the BYTES this process allocated on "
        "a repository's behalf. This is the half that always had evidence — "
        "the recursive-summary case asserts the byte count at every surface — "
        "and it is declared here so the five charges are graded by five arms "
        "rather than by four and an inference",
        control_name="the byte charge is written as an addition of a binding",
        control_find="    tally.work += result.len",
        control_replace="    let produced = result.len\n    tally.work += produced",
    ),
    Mutation(
        "V50", PRESENT,
        "    tally.work += memberScanCost(v)\n  memberNamed(v, label)",
        "    discard memberScanCost(v)\n  memberNamed(v, label)",
        P_WORKCHARGE, NIM_PURE,
        "far.expansion.spent - near.expansion.spent == 3 * (1000 - 400)",
        "resolving a DECLARED NAME goes back to being free. `memberNamed` is "
        "an equality scan over `v.members` — its own header has said so since "
        "it was written, where it reads as a reassurance — and a summary makes "
        "one per PLACEHOLDER, up to `MaxTemplatePlaceholders` per frame, over "
        "a member list the RECORDING sizes. `builtinInlineText` is never "
        "reached when a summary answers, so the member charge there does not "
        "cover it. Measured with sixteen placeholders over a 100,000-member "
        "record at the state panel's depth: 4,118 ms for ONE value, against "
        "6 ms with the charge and a counter that moved by one node's worth "
        "without it",
        control_name="the lookup charge is hoisted into a binding",
        control_find="    tally.work += memberScanCost(v)\n  memberNamed(v, label)",
        control_replace="    let walked = memberScanCost(v)\n"
                        "    tally.work += walked\n  memberNamed(v, label)",
    ),
    # -- what the bound does AFTER it is reached: three decisions, three arms -
    #
    # The bound's three post-exhaustion decisions are asymmetric on purpose and
    # each was argued in a function header. A verification pass ran all three
    # opposites against the 52-case suite: one of them was WRONG and the suite
    # could not see it, and the other two were right and the suite could not
    # see them either. An argument nobody can falsify is not evidence (§7a),
    # whichever way it points.
    Mutation(
        "V51", PRESENT,
        "  if not v.isNil and v.kind != pvkMap and not tally.exhausted:",
        "  if not v.isNil and v.kind != pvkMap:",
        P_SIBLINGWALK, NIM_PURE,
        "p.expansion.spent == MaxRenderWork + 10",
        "the hidden-member walk goes back above `renderNode`'s own exhaustion "
        "return — which stops the DESCENT and not the CALLER's loop. So every "
        "sibling after the one that exhausted the allowance pays a full "
        "frame's charge over a member list the RECORDING sizes, up to "
        "`Budget.depth * Budget.members` of them. Measured on a 200-wide DAG "
        "over a 400,000-member shared child at the state panel's budget: "
        "`spent` 80,803,474 against a bound of 1,048,576 — **77x** — and 532 "
        "ms against 23 ms, with the multiplier bought by a DECLARATION that "
        "makes the parent's line cheap enough for the child loop to start. A "
        "bound whose own report reads `80803474 of 1048576` is the sentence "
        "`inlineText`'s byte charge already refuses to produce",
        control_name="the still-spending test is hoisted into a named binding",
        control_find="  if not v.isNil and v.kind != pvkMap and not tally.exhausted:",
        control_replace="  let stillSpending =\n"
                        "    not v.isNil and v.kind != pvkMap and not tally.exhausted\n"
                        "  if stillSpending:",
    ),
    Mutation(
        "V52", PRESENT,
        "  if not tally.exhausted:\n"
        "    tally.work += memberScanCost(v)\n"
        "  memberNamed(v, label)",
        "  if tally.exhausted: return nil\n"
        "  tally.work += memberScanCost(v)\n"
        "  memberNamed(v, label)",
        P_WORKBOUND, NIM_PURE,
        'not p.root.text.contains("<no field")',
        "resolving a declared field name stops ANSWERING once the allowance is "
        "gone, not merely stops being charged. Its header states the "
        "consequence exactly — a `substituteSummary` loop that started getting "
        "`nil` back half way through emits `<no field 'x'>` for placeholders "
        "whose field is right there — and nothing asserted it: the whole suite "
        "is green over this mutation. Measured on the recursive-summary case's "
        "own value, whose every `Node` carries the `next` its summary names: "
        "**69 occurrences of `<no field`**. A rendering that ran out of "
        "ALLOWANCE reporting a wrong DECLARATION is the one message that sends "
        "a reader to edit a rule that is correct",
        control_name="the lookup's spending test is hoisted into a binding",
        control_find="  if not tally.exhausted:\n"
                     "    tally.work += memberScanCost(v)\n"
                     "  memberNamed(v, label)",
        control_replace="  let spending = not tally.exhausted\n"
                        "  if spending:\n"
                        "    tally.work += memberScanCost(v)\n"
                        "  memberNamed(v, label)",
    ),
    Mutation(
        "V53", PRESENT,
        "  if not tally.exhausted:\n"
        "    tally.work += visualiserScanCost(v, presenters)\n"
        "  winningVisualiser(v, presenters, language)",
        "  if tally.exhausted: return -1\n"
        "  tally.work += visualiserScanCost(v, presenters)\n"
        "  winningVisualiser(v, presenters, language)",
        P_ELIDEDRULE, NIM_PURE,
        "elided.kind == pkImage",
        "the visualiser scan stops answering once the allowance is gone, so an "
        "ELIDED node loses what the project said it is. Its header's "
        "justification — 'its answer decides what an elided node reports about "
        "itself' — had no evidence, and the first verification that went "
        "looking could not produce any: output byte-identical to unmutated. It "
        "needs a node that is BOTH elided AND claimed by a rule with something "
        "to declare, which exists because `renderNode`'s child loop does NOT "
        "stop when the allowance does — only the descent below each node "
        "does — so every sibling after the one that exhausted the budget is "
        "one. With this arm the declared `Image` presentation and the declared "
        "`image/png` both vanish and the node becomes indistinguishable from "
        "its unclaimed sibling",
        control_name="the scan's spending test is hoisted into a binding",
        control_find="  if not tally.exhausted:\n"
                     "    tally.work += visualiserScanCost(v, presenters)\n"
                     "  winningVisualiser(v, presenters, language)",
        control_replace="  let scanning = not tally.exhausted\n"
                        "  if scanning:\n"
                        "    tally.work += visualiserScanCost(v, presenters)\n"
                        "  winningVisualiser(v, presenters, language)",
    ),
    Mutation(
        "V49", PRESENT,
        "    if tally.exhausted and tally.exhaustedIn.len == 0:",
        "    if tally.exhausted:",
        P_DEEPESTRULE, NIM_PURE,
        'p.expansion.visualiser == "project:.codetracer/visualisers.toml#1"',
        "the rule the report blames becomes the OUTERMOST one rather than the "
        "deepest. `exhaustedIn` is documented first-writer-wins and the first "
        "writer is the deepest frame, because the stack unwinds from the point "
        "the bound was reached — that is the rule whose author has something "
        "to change. Without the guard every frame overwrites on the way out "
        "and a user is sent to edit a rule that names one field, once, and "
        "could not reach the bound if it tried",
        control_name="the first-writer test is written as a negation",
        control_find="    if tally.exhausted and tally.exhaustedIn.len == 0:",
        control_replace="    if tally.exhausted and not (tally.exhaustedIn.len > 0):",
    ),
    Mutation(
        "V35", PANE,
        "  describeDegradation(spec.presentation(ProvenanceBudgetCells))",
        "  \"\"",
        T_DEGRADED, NIM_TUI,
        'detail.contains("image/png")',
        "the terminal stops saying what is missing and how to get it: the row "
        "renders the value, the title says `media-degraded=`, and the sentence "
        "with the remedy in it is gone — §8.2's 'a name and an install action, "
        "not unavailable', reduced to a token",
        control_name="the degradation sentence is built into a named binding",
        control_find="  describeDegradation(spec.presentation(ProvenanceBudgetCells))",
        control_replace="  let rendered = spec.presentation(ProvenanceBudgetCells)\n"
                        "  describeDegradation(rendered)",
    ),
]


@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list[str] = None
    failed: list[str] = None
    output: str = ""

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def run_suite(suite: Suite, label: str) -> RunResult:
    """Compile and run one suite; parse its verdict out of its RESULT LINES."""
    res = RunResult()
    compile_cmd = ["nim", "c", "-f", "--hints:off", "--warnings:off"]
    if suite.extra_path:
        compile_cmd.append("--path:src/frontend/viewmodel")
    if suite.tui_path:
        # The TUI suites resolve `isonim_tui` and the app's own modules through
        # the same two paths `ci/lib/test-lane-files.sh` gives the `tui` lane.
        compile_cmd.append("--path:src/frontend/tui")
    compile_cmd += [f"--nimcache:/tmp/plat12-mut-cache-{Path(suite.path).stem}",
                    f"-o:{suite.binary}", suite.path]
    compile_proc = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True,
                                  text=True, errors="replace", timeout=3600)
    if compile_proc.returncode != 0:
        res.rc = compile_proc.returncode
        res.ran = False
        res.output = compile_proc.stdout + compile_proc.stderr
        print("      ---- did not compile; last 12 lines ----")
        for line in res.output.splitlines()[-12:]:
            print("      " + line)
        return res
    # `errors="replace"` IS LOAD-BEARING, not defensive tidiness. Arm C4's
    # suite prints a `checkpoint` containing the bytes `\xc0\xaf` — an overlong
    # UTF-8 encoding of `/`, which is the whole point of the case it belongs
    # to — and a strict decode raises out of the harness MID-ARM, with a
    # mutation applied and the traceback pointing at `subprocess`. Measured on
    # this harness's first full run: arms C1-C3 graded, C4 crashed the driver.
    proc = subprocess.run([suite.binary], cwd=ROOT, capture_output=True,
                          text=True, errors="replace", timeout=3600)
    out = proc.stdout + proc.stderr
    res.output = out
    res.rc = proc.returncode
    for line in out.splitlines():
        m = NIM_RESULT.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print("      ---- no result lines; last 12 lines of output ----")
        for line in out.splitlines()[-12:]:
            print("      " + line)
    return res


def apply_once(path: str, find: str, replace: str) -> tuple[str, str]:
    """Return (original, error). The needle must occur exactly once."""
    p = ROOT / path
    original = p.read_text()
    n = original.count(find)
    if n != 1:
        return original, f"pattern occurs {n} times in {path}, expected 1"
    p.write_text(original.replace(find, replace))
    return original, ""


def restore(path: str, original: str) -> None:
    (ROOT / path).write_text(original)


def read_control_hashes() -> dict[str, str]:
    if not CONTROL_HASHES.exists():
        return {}
    out: dict[str, str] = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        if h and p:
            out[p] = h
    return out


def needle_scan() -> list[str]:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    Verification-Harness-Traps §16. A mutation arm is a QUOTATION of the code,
    held somewhere the compiler does not look, and every repair to the quoted
    file is an opportunity for it to stop matching. When it does, the arm can
    never be applied, so it can never be killed, and what it leaves behind is a
    row in the table that LOOKS like coverage.

    It gates `--record-control-hashes` rather than sitting beside it: blessing
    new bytes as the baseline is exactly the moment an arm's needle has just
    been moved, and recording first would certify the drift.
    """
    problems: list[str] = []
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        body = (ROOT / mut.path).read_text()
        for label, needle in (("find", mut.find),
                              ("control_find", mut.control_find)):
            if not needle:
                continue
            n = body.count(needle)
            if n != 1:
                problems.append(
                    f"{mut.id}: {label} occurs {n} time(s) in {mut.path}, "
                    f"expected exactly 1")
    return problems


def report_needle_scan() -> int:
    problems = needle_scan()
    if not problems:
        print(f"  all {len(MUTATIONS) + len(DECLARED_SURVIVORS)} arm(s) resolve "
              f"to exactly one needle and one control needle")
        return 0
    print("ARM NEEDLES DO NOT RESOLVE — nothing was mutated and nothing recorded.")
    for line in problems:
        print(f"  {line}")
    print("  An arm whose needle no longer occurs can never be applied and can")
    print("  never be killed; it sits in the table looking like coverage.")
    print("  Re-aim it at the code as it is now, then re-run.")
    return 2


def write_control_hashes() -> None:
    body = ["# Control digests for run-plat12-visualiser-mutations.py.",
            "#",
            "# ABSOLUTE, and that is the point. A baseline taken at start-up",
            "# cannot tell a clean tree from one a killed run left a mutation",
            "# in: it reads the mutation as the baseline, every restore then",
            "# verifies against the mutated bytes, and the only symptom is",
            "# `CONTROL IS NOT GREEN` — which describes a red suite without",
            "# naming the cause.",
            "#",
            "# Rewrite with --record-control-hashes, deliberately, when one of",
            "# these files changes on purpose. The needle scan gates that step",
            "# (Verification-Harness-Traps §16).",
            ""]
    for p in TOUCHED:
        body.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(body) + "\n")


def check_control_hashes() -> int:
    recorded = read_control_hashes()
    if not recorded:
        print(f"NO CONTROL HASHES: {CONTROL_HASHES.relative_to(ROOT)} is missing.")
        print("  Every restore below would verify against digests taken from")
        print("  THIS tree, so a mutation a killed run left behind would be")
        print("  adopted as the baseline. Record them from a tree you have")
        print("  checked, with --record-control-hashes.")
        return 2
    missing = [p for p in TOUCHED if p not in recorded]
    if missing:
        print(f"CONTROL HASHES INCOMPLETE: no entry for {missing}")
        print("  Re-record with --record-control-hashes.")
        return 2
    drifted = [p for p in TOUCHED if recorded.get(p) != digest(p)]
    if drifted:
        print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
        for p in drifted:
            print(f"  {p}")
            print(f"      recorded {recorded[p]}")
            print(f"      on disk  {digest(p)}")
        print("  Either a previous run was killed before it restored, or one")
        print("  of these files changed on purpose. Check the diff, then")
        print("  re-record with --record-control-hashes.")
        return 2
    return 0


def install_signal_restore() -> None:
    """Turn SIGTERM/SIGHUP into an exception so `finally: restore(...)` runs."""

    def raise_on(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, raise_on)
        except (ValueError, OSError):
            pass


def explain(arm_id: str) -> int:
    """Apply ONE arm, run its suite, and print the failure lines verbatim.

    Verification-Harness-Traps §17a: "derive it rather than type it". A
    `because` typed from the source is a second copy of the code held in a file
    the compiler does not read, and this is the one place where the copy and
    the original are not even written in the same language — `unittest`
    stringifies the AST AFTER a template's parameters have been substituted, so
    what is printed is the CALL SITE's expression and not the helper's.
    """
    match = [m for m in MUTATIONS + DECLARED_SURVIVORS if m.id == arm_id]
    if not match:
        print(f"no such arm: {arm_id}")
        return 2
    mut = match[0]
    lock = acquire_lock()
    if lock is None:
        return 2
    rc = check_control_hashes()
    if rc:
        return rc
    original, err = apply_once(mut.path, mut.find, mut.replace)
    if err:
        print(err)
        return 2
    try:
        res = run_suite(mut.suite, f"{mut.id}-explain")
    finally:
        restore(mut.path, original)
    print(f"== {mut.id} applied to {mut.path}; {mut.suite.path} said ==")
    for line in res.output.splitlines():
        if "Check failed" in line or line.strip().startswith("[FAILED]") or \
           line.strip().startswith("[OK]") and line.strip()[5:].strip() == mut.killer:
            print("  " + line)
    print(f"== the arm's `because` is {mut.because!r} ==")
    lock.close()
    return 0


def main() -> int:
    if "--needle-scan" in sys.argv[1:]:
        return report_needle_scan()

    if "--explain" in sys.argv[1:]:
        idx = sys.argv.index("--explain")
        if idx + 1 >= len(sys.argv):
            print("--explain needs an arm id")
            return 2
        return explain(sys.argv[idx + 1])

    if "--record-control-hashes" in sys.argv[1:]:
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        print(f"recorded {len(TOUCHED)} control digest(s) in "
              f"{CONTROL_HASHES.relative_to(ROOT)}")
        return 0

    install_signal_restore()

    # THE LOCK IS TAKEN BEFORE THE HASH CHECK, and is held in a local for the
    # whole run: a garbage-collected file object closes its descriptor, and a
    # closed descriptor releases the flock.
    lock = acquire_lock()
    if lock is None:
        return 2

    rc = check_control_hashes()
    if rc:
        return rc

    # BEFORE ANY MUTATION. An arm that cannot be applied is not a thing to
    # discover forty minutes in, next to nineteen results you now have to
    # decide whether to trust.
    rc = report_needle_scan()
    if rc:
        return rc

    wanted = [a for a in sys.argv[1:] if not a.startswith("-")]
    selected = MUTATIONS + DECLARED_SURVIVORS
    if wanted:
        selected = [m for m in selected if m.id in wanted]
        missing = set(wanted) - {m.id for m in selected}
        if missing:
            print(f"no such arm(s): {sorted(missing)}")
            return 2
    survivors = [m for m in selected if m in DECLARED_SURVIVORS]

    baseline = {p: digest(p) for p in TOUCHED}

    # THE SUITE SET IS DERIVED FROM THE ARMS, not written out beside them —
    # a second registry of the same fact is where the two drift apart
    # (Verification-Harness-Traps §14).
    suites = []
    seen_suite_paths = set()
    for m in selected:
        if m.suite.path not in seen_suite_paths:
            seen_suite_paths.add(m.suite.path)
            suites.append(m.suite)
    controls: dict[str, RunResult] = {}

    print("== control ==")
    for s in suites:
        r = run_suite(s, "control-" + Path(s.path).stem)
        if not r.ran or r.failed:
            print(f"CONTROL IS NOT GREEN for {s.path}: rc={r.rc} failed={r.failed}")
            return 1
        controls[s.path] = r
        print(f"  {s.path}: {r.total} cases, 0 failures")

    problems = 0

    # EVERY KILLER MUST RESOLVE TO EXACTLY ONE GREEN CASE IN ITS OWN SUITE,
    # checked BEFORE any mutation. An arm whose killer does not is an arm that
    # can never legitimately be killed, and it would sit in the table looking
    # like coverage.
    for mut in selected:
        matches = [c for c in controls[mut.suite.path].passed if c == mut.killer]
        if len(matches) != 1:
            print(f"{mut.id}: killer {mut.killer!r} resolves to {len(matches)} "
                  f"green case(s) in {mut.suite.path}, expected exactly 1")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} killers resolve to exactly one green case")

    # EVERY `because` MUST BE ABSENT FROM THE GREEN OUTPUT (§17's fix, and §5's
    # sentinel rule applied to it). A `because` that already occurs in a
    # passing run is true for free, so an arm carrying one could be scored
    # `killed` for a case that died three hundred lines upstream.
    for mut in selected:
        if not mut.because:
            print(f"{mut.id}: no `because`; a kill could not be attributed")
            problems += 1
            continue
        if mut.because in controls[mut.suite.path].output:
            print(f"{mut.id}: because {mut.because!r} already occurs in the "
                  f"GREEN output of {mut.suite.path}; it cannot be evidence "
                  f"that this arm is what reddened the case")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} `because` needles are absent from the green "
          f"output\n")

    killed = 0
    for mut in selected:
        original, err = apply_once(mut.path, mut.find, mut.replace)
        if err:
            print(f"{mut.id:<5} HARNESS-FAILURE      {err}")
            problems += 1
            continue
        try:
            res = run_suite(mut.suite, f"{mut.id}-kill")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"to its control bytes")
                    return 2

        declared = mut in survivors
        newly_failed = [f for f in res.failed
                        if f not in controls[mut.suite.path].failed]
        attributed = mut.because in res.output
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and newly_failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {newly_failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif (mut.killer not in res.passed) and (mut.killer not in res.failed):
            # See the header's fifth verdict. The binary produced result lines
            # and the killer case is in neither list, so it never ran.
            verdict = "SUITE-DIED"
            note = (f"the suite produced {res.total} result line(s) and "
                    f"{mut.killer!r} was not among them")
            problems += 1
        elif not newly_failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer not in newly_failed:
            verdict, note = "MISDIRECTED", f"died in {newly_failed}, not {mut.killer!r}"
            problems += 1
        elif not attributed:
            # Verification-Harness-Traps §17: the case went red, and not for
            # this arm's reason. `the run told you nothing` — so this belongs
            # beside HARNESS-FAILURE, not beside `killed`.
            verdict = "MIS-ATTRIBUTED"
            note = f"the case died without {mut.because!r} in the failure output"
            problems += 1
            # Verification-Harness-Traps §17a asks that a `because` be DERIVED
            # from a transcript rather than typed from the source, and the
            # cheapest place to hand somebody a transcript is the moment the
            # harness has just decided theirs does not occur. Printed here
            # rather than left to a second run with `--explain`, because a
            # second run is a second forty minutes.
            print("      ---- the failure lines this arm actually produced ----")
            for line in res.output.splitlines():
                if "Check failed" in line or line.strip().startswith("[FAILED]"):
                    print("      " + line)
        else:
            others = [f for f in newly_failed if f != mut.killer]
            killed += 1
            verdict = "killed"
            note = mut.killer + (f"  (+{len(others)} more)" if others else "")
        print(f"{mut.id:<5} {verdict:<20} {note}")

        # --- the named behaviour-preserving control ------------------------
        if not mut.control_find:
            print(f"{'':<5} NO-CONTROL           this arm has no behaviour-preserving control")
            problems += 1
            continue
        original, err = apply_once(mut.path, mut.control_find,
                                   mut.control_replace)
        if err:
            print(f"{'':<5} CONTROL-HARNESS-FAILURE  {err}")
            problems += 1
            continue
        try:
            cres = run_suite(mut.suite, f"{mut.id}-control")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"after the control")
                    return 2
        c_newly_failed = [f for f in cres.failed
                          if f not in controls[mut.suite.path].failed]
        if not cres.ran:
            print(f"{'':<5} CONTROL-DID-NOT-RUN  {mut.control_name}")
            problems += 1
        elif c_newly_failed:
            print(f"{'':<5} CONTROL-RED          {mut.control_name} -> {c_newly_failed}")
            problems += 1
        else:
            print(f"{'':<5} control green        {mut.control_name}")

    print(f"\n{killed} killed, {len(survivors)} declared survivor(s), "
          f"{problems} problems")
    # THE LOCK IS NAMED HERE ON PURPOSE. It is held by an open descriptor and
    # nothing else reads the variable, so a tidying pass would delete the
    # binding and silently re-open the concurrency hole it exists to close.
    print(f"run lock held for the whole run: {LOCK_PATH.name} (fd {lock.fileno()})")
    lock.close()
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
