#!/usr/bin/env python3
"""run-plat35-visual-mutations.py — PLAT-35's mutation harness: cross-renderer
visual alignment.

## THE MACHINERY IS PLAT-20's AND PLAT-22's, REUSED RATHER THAN RE-DERIVED

The lock, the needle scan, the digest gate, the derived `because`, the verdicts
and the behaviour-preserving control per arm are `run-plat22-mutations.py`'s.
A second harness IMPLEMENTATION is Verification-Harness-Traps §14 one level up,
and §14a is the entry about what re-derivation costs.

Two rules are added here, both from this campaign's own written guidance rather
than from a defect measured on this milestone:

* **§10.3 — NO MUTATION ARM MAY QUOTE A COUNT.** A count changes every time a
  case is added, which is the most frequent edit any suite receives, so an arm
  whose needle holds one is an arm that silently stops matching. The needle scan
  REJECTS (never warns about) a `find` or `control_find` containing
  `ExpectedAssertions`, `CHECKS:`, `expectedScenarios`, `LayoutQuestionCount`,
  or any of their current values as a standalone number.
* **THE ARMS ARE AIMED AT THE QUESTIONS THAT AGREE.** The suite reads the gap
  register as a PREDICTION — a question with no filed gap must agree, a question
  with one must still differ — so a mutation aimed at a producer for a gapped
  question could not be killed by a rule that merely tolerates divergence. Every
  arm below names the case it kills, and `--derive` records the exact
  `Check failed:` line, so an arm that has drifted onto a gapped question is
  MIS-ATTRIBUTED rather than quietly SURVIVED.

## THE MILESTONE'S OWN REQUIREMENT, AND WHICH ARM IS IT

PLAT-35's gate: *"A MUTATION ARM ON ONE PANE. Break one pane in one front-end;
the comparison must redden AND the review brief must surface a missing element
finding. The methodology's own checklist item 7: if it does not, the
expected-elements block is too vague."*

That is **two** arms, and they are separated on purpose because they fail for
different reasons and one must not mask the other:

  * `M1` breaks the editor pane in the GPUI front-end — `renderEditor` stops
    appending rows — and the tier-3 comparison must redden.
  * `M8` blunts the review brief's expected-elements block for one view into a
    sentence about quality, and the suite's own check on that block must redden.
    A brief that survives M8 is a brief a reviewer could satisfy while looking
    at a blank pane, which is exactly the state checklist item 7 exists to
    detect.

    **IT IS `M8`, AND THIS SENTENCE SAID `M6` UNTIL 2026-09-21.** `M6` is the
    comparator arm below — the one that makes `compareAnswer` agree with
    everything. Naming the wrong arm in the paragraph that states the
    milestone's own requirement is how a reader checks the requirement against
    an arm that does not serve it and concludes the gate is met when a
    different arm met it.

Usage:
    run-plat35-visual-mutations.py                      # grade every arm
    run-plat35-visual-mutations.py --only M1,M8
    run-plat35-visual-mutations.py --needle-scan
    run-plat35-visual-mutations.py --derive
    run-plat35-visual-mutations.py --record-control-hashes
"""

import argparse
import fcntl
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HARNESS_DIR = Path(__file__).resolve().parent

# --- subjects ---------------------------------------------------------------
LEAVES = "src/frontend/gpui/app/leaves.nim"
ANSWERS = "src/frontend/view_vocabulary/gpui_layout_answers.nim"
VOCAB = "src/common/view_vocabulary/layout_questions.nim"
BRIEF = "tools/visual-review-brief.md"
SCENARIOS = "src/tests/visual/scenarios.json"

# --- the suite the arms are graded against ----------------------------------
# §16c: this is NOT a mutation subject and it is in TOUCHED anyway, because a
# change that touches only the suite invalidates every arm graded against it
# while producing no overlap signal at all in a harness whose TOUCHED names
# subjects only.
SUITE = "src/frontend/gpui/tests/test_cross_renderer_visual_alignment.nim"

TOUCHED = [LEAVES, ANSWERS, VOCAB, BRIEF, SCENARIOS, SUITE]

CONTROL_HASHES = HARNESS_DIR / "plat35-visual-mutation-control.sha256"
BECAUSE_FILE = HARNESS_DIR / "plat35-visual-mutation-because.json"
LOCK_FILE = REPO / "build" / "plat35-visual-mutations.lock"
NIMCACHE = REPO / "build" / "plat35mut"

# The `gpui-shell` lane's flags, from `ci/lib/test-lane-files.sh`: no
# `isonim_tui` flags at all, which is that lane's whole point.
SUITE_CMD = {SUITE: ["--path:src/frontend/viewmodel"]}


@dataclass
class Arm:
    name: str
    path: str
    find: str
    replace: str
    suite: str
    kills: str
    control_find: str
    control_replace: str
    note: str
    because: str = ""
    extra_kills: list = field(default_factory=list)


# ONE control fragment per subject, appended to rather than invented per arm: a
# behaviour-preserving control is a second quotation of the same file, and one
# shared spelling per file is one thing to keep aimed instead of eight. Each
# ends AT A LINE END, which the needle scan enforces.
CTL = {
    LEAVES: ("proc slotPath(slot: DockPaneSlot): string =",
             "proc slotPath(slot: DockPaneSlot): string =  ## ctl"),
    ANSWERS: ("proc lineOf(node: GpuiElement): int =",
              "proc lineOf(node: GpuiElement): int =  ## ctl"),
    VOCAB: ("proc tokenIsPublished*(token: string): bool =",
            "proc tokenIsPublished*(token: string): bool =  ## ctl"),
    BRIEF: ("## Design Goals", "## Design Goals <!-- ctl -->"),
    SCENARIOS: ('"schemaVersion": 1,', '"schemaVersion": 1, "_ctl": 0,'),
}


ARMS = [
    # ------------------------------------------------------------------
    # THE PANE MUTATION — the milestone's own gate, half one
    # ------------------------------------------------------------------
    Arm("M1", LEAVES,
        "  for row in surface.rows:\n    r.appendChild(parent, renderEditorRow(r, row, widest))",
        "  for row in surface.rows:\n    discard row",
        SUITE,
        "stepped-editor / editor-row-count",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "BREAK ONE PANE IN ONE FRONT-END. The GPUI editor keeps its container, "
        "its medium attribute, its provenance and its heading, and draws no "
        "rows — which is exactly the failure a screenshot review is worst at "
        "and a layout assertion is best at. A comparison that stays green here "
        "is a comparison that would pass a blank editor."),

    # RE-AIMED 2026-09-21, and re-run (§32a). Its old needle BLANKED the
    # attribute and its expected case was `at least one scenario still
    # diverges on inline-value-runs-by-line`. The re-aim was decided while
    # `PLAT35-VG7` stood retired, on the reasoning that blanking an attribute
    # already empty on every row is a mutation that changes nothing and an arm
    # that can only survive.
    #
    # **THE PREMISE OF THAT RE-AIM WAS FALSE AND THE RE-AIM SURVIVED IT.**
    # VG7 was retired against the one run in six in which the GPUI arm's
    # locals never arrived (`PLAT35-PD3`), the gap is filed again as
    # `PLAT35-VG9`, and no tier-3 cell reaches the `gaps.len == 0` alignment
    # branch on this tree. So this arm is NOT aimed at that branch — nothing
    # is, and no arm can be while eight gaps are filed. It is aimed at
    # `PLAT35-VG9`'s RESIDUAL, and it is a sharper arm than the one it
    # replaced either way: publishing a value nobody drew is visible to the
    # residual's one-line rule, whereas blanking an attribute is visible to
    # nothing on a run where the attribute is already blank.
    #
    # Its `because` line is DERIVED (`--derive --only M2`), never typed, which
    # is what caught the drift: when the residual replaced the alignment
    # branch the arm came back MIS-ATTRIBUTED — killed by `Check failed:
    # holds` against a recorded `Check failed: agreed` — instead of quietly
    # passing for a new reason.
    Arm("M2", LEAVES,
        "  r.setAttribute(el, EditorValuesAttribute, structuredValues(row.values))",
        "  r.setAttribute(el, EditorValuesAttribute, \"phantom=1\")",
        SUITE,
        "advanced-state / inline-value-runs-by-line",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "THE GPUI EDITOR PUBLISHES AN INLINE VALUE NOBODY DREW. The "
        "annotation span is untouched, so `textContent` is unchanged and a "
        "text-based check cannot see it; only the structured answer can. §3's "
        "row asks for *count, order and the text of each*, and this invents "
        "all three on every row while the screen looks identical. It is also "
        "the arm aimed at `PLAT35-VG9`'s residual, which is what asks that "
        "every inline run the GPUI arm draws names a line, a count and a "
        "named value.\n\n"
        "THIS NOTE SAID SOMETHING ELSE FOR A DAY AND IT WAS WRONG. It said "
        "this was `the one arm aimed at the gaps.len == 0 branch`, which was "
        "true only while `PLAT35-VG7` stood retired — and VG7 was retired by "
        "mistake, against a run in which the GPUI arm\u2019s locals had not "
        "arrived, so every question about an empty pane agreed. The gap is "
        "filed again as `PLAT35-VG9`, the alignment branch is unreachable on "
        "this tree once more, and no arm reaches it."),

    Arm("M3", LEAVES,
        "  r.setAttribute(gutter, TokenAttribute, gpuiTokenFor(trGutterLineNumber, row))",
        "  r.setAttribute(gutter, TokenAttribute, \"#8b949e\")",
        SUITE,
        "stepped-editor / token-colour-per-role",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "COLOUR ANSWERED AS A HEX VALUE RATHER THAN AS A TOKEN ID. §3.1 is "
        "explicit that a token comparison is exact and survives rasterisation "
        "while a hex comparison does not; this is that rule with something to "
        "break. It is the arm that makes `DesignTokenAlphabet` a check rather "
        "than a list."),

    Arm("M4", LEAVES,
        "    r.setAttribute(node, FocusIndexAttribute, $result.drawn)",
        "    r.setAttribute(node, FocusIndexAttribute, \"0\")",
        SUITE,
        "entry-shell / focus-order",
        CTL[LEAVES][0], CTL[LEAVES][1],
        "EVERY LEAF CLAIMS FOCUS POSITION ZERO. The focus order collapses to "
        "one name, which is the shape a front-end with no focus chain would "
        "produce if nobody had noticed — and `PLAT35-VG4` files precisely that "
        "this order is declared rather than enforced, so the arm is aimed at "
        "the half that IS checkable."),

    # ------------------------------------------------------------------
    # THE PRODUCER'S OWN HONESTY
    # ------------------------------------------------------------------
    # RE-AIMED 2026-09-21, and re-run (§32a). It used to silence the INLINE
    # VALUE producer, and after `PLAT35-VG7` was retired that made it land on
    # the same assertion as the re-aimed `M2` — `ck agreed` in the tier-3 cell
    # for `inline-value-runs-by-line`. **The harness refused the pair before a
    # human noticed**: `--derive` compares the `because` lines and reported
    # *M5 and M2 derived the same `because`; an arm must not be attributable
    # to a case it did not break*. That guard is the reason this was a
    # five-minute repair rather than two arms quietly testing one thing.
    #
    # Aimed now at the PANE-RECTANGLE producer, which keeps this arm's own
    # meaning — silence where an answer exists — and lands on a different
    # gap's residual (`PLAT35-VG3`) so the two `because` lines are distinct.
    # It is deliberately NOT aimed at `which-panes-are-present` or
    # `gutter-marks-by-line`: both are PINNED by `corpus-pins.json` now, so a
    # mutation there would redden a pin case first and be attributed to it.
    Arm("M5", ANSWERS,
        "  if rects.len == 0: return Unanswered",
        "  if true: return Unanswered",
        SUITE,
        "entry-shell / pane-rectangles",
        CTL[ANSWERS][0], CTL[ANSWERS][1],
        "THE PRODUCER GOES SILENT ON A QUESTION IT CAN ANSWER. §3: *a question "
        "one front-end answers and the other omits is a FAILURE, never a "
        "skipped row*. This is the arm that makes `Unanswered` a value with "
        "consequences rather than an escape hatch — and it is aimed at a "
        "GAPPED question on purpose, because the residual's first clause is "
        "*one side is silent; a gap does not license silence*, which is the "
        "exact sentence a gap would otherwise be read as permitting."),

    # ------------------------------------------------------------------
    # THE COMPARATOR — §4a, the arming of all forty-eight tier-3 cases
    # ------------------------------------------------------------------
    Arm("M6", VOCAB,
        "  elif left == right:\n    result.verdict = cvEqual",
        "  elif true:\n    result.verdict = cvEqual",
        SUITE,
        "the comparator reports a DIFFERENCE over two real answers",
        CTL[VOCAB][0], CTL[VOCAB][1],
        "THE COMPARATOR AGREES WITH EVERYTHING. Without an arm here, a "
        "comparator that returned `cvEqual` unconditionally would make every "
        "tier-3 case in the suite true for free — the §4a shape, and the "
        "single most valuable arm in this harness because it is aimed at the "
        "instrument rather than at the subject."),

    Arm("M7", VOCAB,
        "    if abs(ra[i].w - rb[i].w) > PaneRectangleTolerancePp: return false",
        "    if false: return false",
        SUITE,
        "the pane-rectangle tolerance is applied and is not a free pass",
        CTL[VOCAB][0], CTL[VOCAB][1],
        "THE ONE TOLERANCE IN THE VOCABULARY BECOMES A FREE PASS. Pane "
        "rectangles are the only question compared inexactly; a tolerance that "
        "swallows any width at all turns question one into a row that cannot "
        "fail. The needle carries NO NUMBER, per §10.3: quoting "
        "`PaneRectangleTolerancePp`'s value would make this arm stop matching "
        "the day the tolerance moves, which is the one day somebody needs it."),

    # ------------------------------------------------------------------
    # THE REVIEW BRIEF — the milestone's own gate, half two
    # ------------------------------------------------------------------
    Arm("M8", BRIEF,
        "- Everything in `shell`, plus:\n- An **execution-pointer mark** on exactly one gutter row, and the\n  corresponding source row visually distinguished (a highlighted line\n  background, not only a gutter glyph).\n- The **state pane now lists variables** \u2014 name, type and value per row. It is\n  not empty. An empty state pane here is a first-order finding.\n- The **call-trace pane lists frames**, with one marked as current.\n- Line numbers are **contiguous ascending integers**; no gaps, no repeats, no\n  `0`.",
        "- The editor should look clean, polished and professional.",
        SUITE,
        "the brief has a block for the 'editor' view",
        CTL[BRIEF][0], CTL[BRIEF][1],
        "THE EXPECTED-ELEMENTS BLOCK IS BLUNTED INTO A SENTENCE ABOUT QUALITY. "
        "The methodology's checklist item 7: *deliberately break a view and "
        "confirm the review surfaces a missing-element finding; if it does "
        "not, your brief's expected-elements block is too vague*. A block "
        "reading 'the editor should look clean' is satisfiable by a blank "
        "pane, and this is the arm that says so."),

    # ------------------------------------------------------------------
    # THE POPULATION — §34
    # ------------------------------------------------------------------
    # RE-AIMED 2026-09-21 (§32a: a re-aimed arm has to be RE-RUN, and it was).
    # `returned-calltrace`'s operation sequence changed — it is now
    # `stepIn x21, stepOut x1`, because stepping out one frame shallower lands
    # on the same line and tick as `continueForward` and the two scenarios
    # genuinely collided once the capture began asserting effect rather than
    # action. The needle quotes the sequence, so it had to follow.
    Arm("M9", SCENARIOS,
        '      "viewport": "laptop",\n      "operations": [\n        { "kind": "stepIn", "times": 21 },\n        { "kind": "stepOut", "times": 1 }\n      ],',
        '      "viewport": "wide",\n      "operations": [\n        { "kind": "stepIn", "times": 6 }\n      ],',
        SUITE,
        "THE POPULATION: the six scenarios are pairwise distinct on screen",
        CTL[SCENARIOS][0], CTL[SCENARIOS][1],
        "TWO SCENARIOS REACH ONE STATE. Verification-Harness-Traps §34: a "
        "population whose members are structurally identical makes every "
        "multiplier over it decorative — eight questions times six copies of "
        "one screen is eight cases wearing a six. This arm makes "
        "`returned-calltrace` a second `stepped-editor`, and the pairwise "
        "distinctness case is the only thing in the suite that can see it."),
]

# §10.3's rejection list. A `find` or `control_find` holding any of these is
# REFUSED rather than warned about: an arm whose needle quotes a count is an arm
# that stops matching on the most frequent edit a suite receives.
COUNT_SPELLINGS = [
    "ExpectedAssertions",
    "CHECKS:",
    "expectedScenarios",
    "expectedViewports",
    "expectedCanaries",
    "expectedOperationKinds",
    "LayoutQuestionCount",
]


# ---------------------------------------------------------------------------
# machinery
# ---------------------------------------------------------------------------

def take_lock():
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("ANOTHER RUN HOLDS THE LOCK. Two harnesses mutating one tree "
              "produce verdicts about a tree neither of them wrote (§16).")
        sys.exit(4)
    return fh


def digest(rel: str) -> str:
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def _ends_at_line_end(text: str, needle: str) -> tuple[bool, str]:
    """Does `needle` end where its line ends in `text`?

    PLAT-21's second needle check, adopted. Every control here works by
    APPENDING a comment marker to a matched fragment, so a needle that is a
    PREFIX of a longer line comments out the rest of that line and the
    behaviour-preserving control stops being behaviour-preserving.
    """
    at = text.find(needle)
    if at < 0:
        return False, ""
    end = at + len(needle)
    rest = text[end:text.find("\n", end) if text.find("\n", end) >= 0 else len(text)]
    return rest.strip() == "", rest


def needle_scan() -> list[str]:
    bad: list[str] = []
    for arm in ARMS:
        text = (REPO / arm.path).read_text()
        for label, needle in (("find", arm.find),
                              ("control_find", arm.control_find)):
            n = text.count(needle)
            if n != 1:
                bad.append(f"{arm.name}.{label}: occurs {n} time(s) in "
                           f"{arm.path}, expected exactly 1")
                continue
            for spelling in COUNT_SPELLINGS:
                if spelling in needle:
                    bad.append(f"{arm.name}.{label}: quotes the count spelling "
                               f"'{spelling}' — §10.3 REJECTS this, it does not "
                               f"warn about it")
            if label == "control_find":
                ok, rest = _ends_at_line_end(text, needle)
                if not ok:
                    bad.append(f"{arm.name}.control_find: does not end at a "
                               f"line end in {arm.path}; the rest of the line "
                               f"is {rest!r} and the control would comment it "
                               f"out")
    names = [a.name for a in ARMS]
    if len(set(names)) != len(names):
        bad.append("two arms share a name")
    kills = [a.kills for a in ARMS]
    if len(set(kills)) != len(kills):
        bad.append("two arms name the same killer case; an arm must be "
                   "attributable to the case it broke (§17a)")
    return bad


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN FAILED:")
        for b in bad:
            print("  " + b)
        return 2
    print(f"needle scan: {len(ARMS)} arm(s), every `find` and `control_find` "
          f"occurs exactly once, ends at a line end, and quotes no count")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        want, rel = line.split(None, 1)
        recorded[rel.strip()] = want
    subjects = set(TOUCHED)
    ok = True
    for rel in sorted(set(recorded) | subjects):
        if rel not in recorded:
            print(f"CONTROL DIGEST ABSENT: {rel} is compared by this harness "
                  f"but has no recorded digest — run --needle-scan, review, "
                  f"then --record-control-hashes (§16)")
            ok = False
            continue
        if rel not in subjects:
            print(f"CONTROL DIGEST STALE: {rel} is recorded but not compared "
                  f"by this harness — re-run --record-control-hashes (§16)")
            ok = False
            continue
        have = digest(rel)
        if have != recorded[rel]:
            print("CONTROL DIGEST MOVED — the tree is not at the control "
                  "bytes; nothing was mutated.")
            print(f"  {rel}\n      recorded {recorded[rel][:8]}…   "
                  f"on disk {have[:8]}…")
            ok = False
    return ok


CONTROL_HEADER = """\
# Control digests for run-plat35-visual-mutations.py.
#
# The bytes every arm restores to, and the bytes every arm's verdict was taken
# against. BOTH HALVES OF `TOUCHED` are here — the five mutation subjects AND
# the suite the arms are graded by — which is Verification-Harness-Traps §16c's
# gap paid rather than inherited: a change that touches only the suite
# invalidates every arm graded against it while producing no overlap signal at
# all in a harness whose TOUCHED names subjects only.
#
# Refreshed with --record-control-hashes, which the needle scan GATES (§16):
# re-recording from a tree whose arms have stopped matching certifies the arms
# along with the bytes.
"""


def write_control_hashes():
    lines = [f"{digest(rel)}  {rel}" for rel in TOUCHED]
    CONTROL_HASHES.write_text(CONTROL_HEADER + "\n".join(lines) + "\n")
    print(f"recorded {len(lines)} control digest(s) to "
          f"{CONTROL_HASHES.relative_to(REPO)}")


def run_suite(suite: str) -> tuple[int, str]:
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + SUITE_CMD[suite] + [suite]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       timeout=3600)
    return p.returncode, p.stdout + p.stderr


def failure_lines_for(out: str, case: str) -> list[str]:
    block: list[str] = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK]") or s.startswith("[FAILED]"):
            name = s.split("] ", 1)[-1]
            if name == case:
                return block
            block = []
            continue
        block.append(s)
    return []


def verdict_for(out: str, case: str) -> str | None:
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[OK] ") and s[5:] == case:
            return "OK"
        if s.startswith("[FAILED] ") and s[9:] == case:
            return "FAILED"
    return None


def apply_patch(rel: str, find: str, replace: str):
    path = REPO / rel
    text = path.read_text()
    assert text.count(find) == 1, f"needle not unique in {rel}"
    path.write_text(text.replace(find, replace, 1))


def restore(rel: str, original: str):
    (REPO / rel).write_text(original)


def load_because() -> dict:
    if BECAUSE_FILE.exists():
        return json.loads(BECAUSE_FILE.read_text())
    return {}


def derive(selected: list[Arm]) -> int:
    derived = {}
    for arm in selected:
        original = (REPO / arm.path).read_text()
        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        lines = failure_lines_for(out, arm.kills)
        # **PREFER THE `RESIDUAL` CHECKPOINT OVER THE `Check failed:` LINE**,
        # and the reason is §17a's closing rule rather than taste: four of
        # these arms redden the same assertion — `ck holds` — on four
        # different questions, so a `because` taken from the check text alone
        # would be the string "Check failed: holds" for all four and the
        # harness would refuse them as mutually unattributable. The residual
        # line names the gap and says what broke, and it is stable across
        # re-captures in a way the provenance checkpoint beside it is not.
        residual = [ln for ln in lines if ln.startswith("RESIDUAL")]
        checks = residual if residual else [ln[ln.index("Check failed:"):]
                                            for ln in lines
                                            if "Check failed:" in ln]
        if not checks:
            print(f"{arm.name}: NO `Check failed:` line for '{arm.kills}' — "
                  f"cannot derive a `because`.")
            print("   verdict was:", verdict_for(out, arm.kills))
            continue
        text = re.sub(r"\s+", " ", checks[0]).strip()
        # §10.3 again, on the DERIVED side: a `because` holding a count is a
        # needle holding a count one step removed.
        for spelling in COUNT_SPELLINGS:
            if spelling in text:
                print(f"{arm.name}: the derived `because` quotes "
                      f"'{spelling}'; aim the arm at a case that does not "
                      f"assert a count.")
                return 2
        derived[arm.name] = text
        print(f"{arm.name}: because = {text}")
    seen: dict[str, str] = {}
    clash = False
    for name, text in derived.items():
        if text in seen:
            print(f"REFUSED: {name} and {seen[text]} derived the same "
                  f"`because`; an arm must not be attributable to a case it "
                  f"did not break.")
            clash = True
        seen[text] = name
    if clash:
        return 2
    existing = load_because()
    existing.update(derived)
    BECAUSE_FILE.write_text(json.dumps(existing, indent=2, sort_keys=True)
                            + "\n")
    print(f"wrote {len(derived)} derived `because` string(s) to "
          f"{BECAUSE_FILE.relative_to(REPO)}")
    return 0


def grade(selected: list[Arm]) -> int:
    because = load_because()
    missing = [a.name for a in selected if a.name not in because]
    if missing:
        print(f"REFUSED: no derived `because` for {', '.join(missing)}. "
              f"Run --derive first; a typed one is a second copy of the code "
              f"(§17a).")
        return 2

    results = []
    for arm in selected:
        original = (REPO / arm.path).read_text()
        before = hashlib.sha256(original.encode()).hexdigest()

        try:
            apply_patch(arm.path, arm.find, arm.replace)
            rc, out = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        after = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if after != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the revert did not restore the bytes"))
            continue

        if "Error: " in out and "[OK]" not in out and "[FAILED]" not in out:
            results.append((arm, "DID-NOT-COMPILE", ""))
            continue

        v = verdict_for(out, arm.kills)
        if v is None:
            results.append((arm, "NO-VERDICT-FOR-KILLER",
                            "the run told you nothing"))
            continue
        if v == "OK":
            results.append((arm, "SURVIVED", ""))
            continue

        raw = failure_lines_for(out, arm.kills)
        lines = " ".join(ln[ln.index("Check failed:"):] if "Check failed:" in ln
                         else ln for ln in raw)
        lines = re.sub(r"\s+", " ", lines)
        if because[arm.name] not in lines:
            results.append((arm, "MIS-ATTRIBUTED",
                            f"expected: {because[arm.name]}"))
            continue

        try:
            apply_patch(arm.path, arm.control_find, arm.control_replace)
            crc, cout = run_suite(arm.suite)
        finally:
            restore(arm.path, original)
        cafter = hashlib.sha256((REPO / arm.path).read_bytes()).hexdigest()
        if cafter != before:
            results.append((arm, "HARNESS-FAILURE",
                            "the control revert did not restore the bytes"))
            continue
        if verdict_for(cout, arm.kills) != "OK":
            results.append((arm, "CONTROL-HARNESS-FAILURE",
                            "the behaviour-preserving control reddened the "
                            "killer case"))
            continue

        results.append((arm, "KILLED", ""))

    print()
    print("| arm | subject | verdict | note |")
    print("|-----|---------|---------|------|")
    for arm, verdict, note in results:
        print(f"| {arm.name} | {Path(arm.path).name} | **{verdict}** | "
              f"{note} |")
    killed = sum(1 for _, v, _ in results if v == "KILLED")
    print()
    print(f"{killed} of {len(results)} KILLED")
    return 0 if killed == len(results) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    fh = take_lock()  # BEFORE any digest.
    assert fh is not None

    if args.needle_scan:
        return report_needle_scan()

    if args.record_control_hashes:
        # §16: the scan GATES the recording. Recording first would certify a
        # tree in which an arm describes nothing.
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        return 0

    rc = report_needle_scan()
    if rc:
        return rc
    if not check_control_hashes():
        return 3

    selected = ARMS
    if args.only:
        want = {s.strip() for s in args.only.split(",")}
        selected = [a for a in ARMS if a.name in want]
        if not selected:
            print(f"no arm matches {args.only}")
            return 2

    if args.derive:
        return derive(selected)
    return grade(selected)


if __name__ == "__main__":
    sys.exit(main())
