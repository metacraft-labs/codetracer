#!/usr/bin/env python3
"""run-plat37-window-mutations.py — PLAT-37's mutation harness: the window,
the frame, and the instrument that reads it.

## THE MACHINERY IS PLAT-20's, PLAT-22's AND PLAT-35's, REUSED RATHER THAN
## RE-DERIVED

The lock, the needle scan, the digest gate, the derived `because`, the
verdicts and the behaviour-preserving control per arm are
`run-plat35-visual-mutations.py`'s, unchanged in shape. A second harness
IMPLEMENTATION is Verification-Harness-Traps §14 one level up, and §14a is the
entry about what re-derivation costs.

**IT CARRIES `CONTROL_HASHES` AND `plat37-window-mutation-control.sha256` FROM
ITS FIRST COMMIT.** §39 is open because three harnesses never had one, and a
new harness joining them is a deliberate act. This one does not join them.

## WHAT THE ARMS ARE AIMED AT, AND THE ONE THING THEY ARE NOT

The gate this harness grades — `test_gpui_window_frame.nim` — reads a RECORD:
either `src/tests/visual/plat37-measurements.json` (a recorded capture, the
same arrangement PLAT-35 has for its Electron answers) or a live measurement
of `build/plat37/`. So the arms come in two kinds and the split is stated
rather than left to be noticed:

  **ARMS OVER THE RECORD** (`M1`..`M5`) corrupt the evidence in the exact
  shapes a broken window would produce — a frame identical to the blank
  control, a control that clears the threshold it is supposed to fail, a join
  with no denominator, a cross-scenario control with no population, and a
  featureless build that grew a frame. These are aimed at the GATE'S READERS,
  which is where §4 lives: a reader that invents a default for a missing row
  makes every case written over it true for free.

  **ARMS OVER THE CODE** (`M6`..`M10`) corrupt the thresholds, the palette,
  the vocabulary parser, the scan's subject and the corpus's cardinality.

  **AND ONE ARM OVER THE MEASURING CODE** (`M11`), graded with
  `PLAT37_CORPUS=live`, because nothing in the recorded path exercises
  `plat37_vision`'s GuiAssert calls at all. Saying so and covering it is the
  alternative to a harness that grades ten arms and quietly has no opinion
  about the module that produces every number the other ten corrupt. That arm
  needs `build/plat37/` and its frames; when they are absent it FAILS BY NAME
  rather than being skipped.

**EVERY ARM IS GRADED WITH `PLAT37_CORPUS` PINNED.** Without it the harness
would grade `M1`..`M10` against whichever corpus happened to be on the disk —
the live one on a workstation that has just captured, the recorded one in CI —
and an arm that corrupted the recorded file would SURVIVE on the workstation
for a reason that has nothing to do with the gate. That is §18's second
corollary (*pin the image, or the manifest measures whichever build ran last*)
arriving through an environment variable.

## §10.3 — NO MUTATION ARM MAY QUOTE A COUNT

Inherited from PLAT-35 unchanged. A count changes every time a case is added,
which is the most frequent edit any suite receives, so an arm whose needle
holds one is an arm that silently stops matching.

Usage:
    run-plat37-window-mutations.py                      # grade every arm
    run-plat37-window-mutations.py --only M1,M6
    run-plat37-window-mutations.py --needle-scan
    run-plat37-window-mutations.py --derive
    run-plat37-window-mutations.py --record-control-hashes
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HARNESS_DIR = Path(__file__).resolve().parent

# --- subjects ---------------------------------------------------------------
MEASUREMENTS = "src/tests/visual/plat37-measurements.json"
THRESHOLDS = "src/tests/visual/plat37-thresholds.json"
CHROME = "src/frontend/gpui/chrome.nim"
REPLAY_OPS = "src/frontend/gpui/replay_ops.nim"
SCENARIOS = "src/tests/visual/scenarios.json"
VISION = "src/frontend/gpui/tests/plat37_vision.nim"

# --- the suite the arms are graded against ----------------------------------
# §16c: this is NOT a mutation subject and it is in TOUCHED anyway, because a
# change that touches only the suite invalidates every arm graded against it
# while producing no overlap signal at all in a harness whose TOUCHED names
# subjects only.
SUITE = "src/frontend/gpui/tests/test_gpui_window_frame.nim"

TOUCHED = [MEASUREMENTS, THRESHOLDS, CHROME, REPLAY_OPS, SCENARIOS, VISION,
           SUITE]

CONTROL_HASHES = HARNESS_DIR / "plat37-window-mutation-control.sha256"
BECAUSE_FILE = HARNESS_DIR / "plat37-window-mutation-because.json"
LOCK_FILE = REPO / "build" / "plat37-window-mutations.lock"
NIMCACHE = REPO / "build" / "plat37mut"

# The `gpui-shell` lane's flags, from `ci/lib/test-lane-files.sh`. PLAT-37
# widened that lane by one path — `--path:../GuiAssert/src` — because this
# gate reads pixels.
SUITE_CMD = {SUITE: ["--path:src/frontend/viewmodel",
                     "--path:../GuiAssert/src"]}


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
    corpus: str = "recorded"
    because: str = ""
    extra_kills: list = field(default_factory=list)


# ONE control fragment per subject, appended to rather than invented per arm: a
# behaviour-preserving control is a second quotation of the same file, and one
# shared spelling per file is one thing to keep aimed instead of eleven. Each
# ends AT A LINE END, which the needle scan enforces.
CTL = {
    MEASUREMENTS: ('"milestone": "PLAT-37",',
                   '"milestone": "PLAT-37", "_ctl": 0,'),
    THRESHOLDS: ('"milestone": "PLAT-37",',
                 '"milestone": "PLAT-37", "_ctl": 0,'),
    CHROME: ("func chromeOf*(role: ChromeRole): string =",
             "func chromeOf*(role: ChromeRole): string =  ## ctl"),
    REPLAY_OPS: ("func isReplayOpKind*(kind: string): bool =",
                 "func isReplayOpKind*(kind: string): bool =  ## ctl"),
    SCENARIOS: ('"schemaVersion": 1,', '"schemaVersion": 1, "_ctl": 0,'),
    VISION: ("proc nonBlackFraction*(img: GrayImage): float =",
             "proc nonBlackFraction*(img: GrayImage): float =  ## ctl"),
}


ARMS = [
    # ------------------------------------------------------------------
    # THE RECORD — the shapes a broken window actually produces
    # ------------------------------------------------------------------
    Arm("M1", MEASUREMENTS,
        '"ssimVsBlank": ',
        '"ssimVsBlank": 1.0, "_mutated": ',
        SUITE,
        "'entry-shell': SSIM against the blank control is below the ceiling",
        CTL[MEASUREMENTS][0], CTL[MEASUREMENTS][1],
        "THE WINDOW OPENED AND PAINTED NOTHING. A frame identical to the "
        "blank control scores 1.0, which is the pass-shaped failure this "
        "whole tier exists to see — and it is the state fifteen pre-existing "
        "cases once reported [OK] against. The needle is the FIRST "
        "`ssimVsBlank` in the record, which is `entry-shell`'s, so the arm "
        "lands on one scenario rather than all six; an arm that broke every "
        "row would be killed by whichever case ran first and would say "
        "nothing about which."),

    Arm("M2", MEASUREMENTS,
        '"blankSelfSsim": ',
        '"blankSelfSsim": 0.0, "_mutated": ',
        SUITE,
        "all three predicates FAIL on the blank control, per scenario",
        CTL[MEASUREMENTS][0], CTL[MEASUREMENTS][1],
        "THE BLANK CONTROL CLEARS THE THRESHOLD IT EXISTS TO FAIL. §7b: an "
        "unfalsified negative control is a self-comparison wearing a "
        "negation. If the control scored 0.0 against itself, the ceiling "
        "would be a number no screen can fail and every SSIM case above it "
        "would be true for free."),

    Arm("M3", MEASUREMENTS,
        '"ocrK": ',
        '"ocrK": 0, "_mutated": ',
        SUITE,
        "'entry-shell': the OCR join holds, with a non-zero denominator",
        CTL[MEASUREMENTS][0], CTL[MEASUREMENTS][1],
        "THE JOIN'S DENOMINATOR GOES TO ZERO. A join whose K is zero is "
        "satisfied by ANY frame — §4 arriving through an empty numerator — "
        "and it is the failure mode of a needle extractor that stopped "
        "finding text rather than of a window that stopped drawing it."),

    Arm("M4", MEASUREMENTS,
        '"ocrFramesScoredAgainst": ',
        '"ocrFramesScoredAgainst": 0, "_mutated": ',
        SUITE,
        "the needles score STRICTLY LOWER on a DIFFERENT-CONTENT frame",
        CTL[MEASUREMENTS][0], CTL[MEASUREMENTS][1],
        "THE CROSS-SCENARIO CONTROL LOSES ITS POPULATION. §34 arriving "
        "through a denominator: a `best over the other frames` computed over "
        "ZERO other frames compares less than this scenario's own hits for "
        "free, so the control passes while measuring nothing. This is the arm "
        "that makes the control's own population a checked quantity."),

    Arm("M5", MEASUREMENTS,
        '"hasFrame": false,',
        '"hasFrame": true,',
        SUITE,
        "DIFF-6: the windowed build produced frames and the featureless none",
        CTL[MEASUREMENTS][0], CTL[MEASUREMENTS][1],
        "THE FEATURELESS ARM CLAIMS A FRAME IT DID NOT PRODUCE. `DIFF-6` is "
        "the only differential this milestone has and it is exactly this "
        "difference: a build that produced frames and one that produced none. "
        "The first `\"hasFrame\": false` in the record is the featureless "
        "arm's, because every windowed row above it is `true`.\n\n"
        "**RE-AIMED, AND THE FIRST AIM IS WORTH KEEPING IN THE RECORD** "
        "(§32a: a re-aimed arm must be RE-RUN, and it was). It flipped the "
        "featureless `outcome` from `timedout` to `captured` and named the "
        "partition case as its killer — and it SURVIVED, because that case "
        "reads the WINDOWED arm only and is right to. An arm that survives "
        "reads as `the mutation is harmless`, and the thing that caught this "
        "was `--derive` refusing to invent a `because` for a case that "
        "stayed green."),

    # ------------------------------------------------------------------
    # THE THRESHOLDS
    # ------------------------------------------------------------------
    Arm("M6", THRESHOLDS,
        '"minEdgeChangeRatioVsBlank": {\n    "value": ',
        '"minEdgeChangeRatioVsBlank": {\n    "value": -1.0, "_mutated": ',
        SUITE,
        "'entry-shell': the frame has STRUCTURE, not merely luminance",
        CTL[THRESHOLDS][0], CTL[THRESHOLDS][1],
        "THE FLOOR BECOMES A FREE PASS. A floor below zero is cleared by the "
        "BLANK CONTROL, which scores exactly 0.0 against itself by "
        "construction, so the predicate stops discriminating. The arm is "
        "aimed at the CONTROL half rather than at the frame half, which is "
        "the half a loosened threshold breaks first and the half nobody "
        "looks at.\n\n"
        "**RE-AIMED FROM THE SSIM CEILING, AND THE HARNESS IS WHAT FORCED "
        "IT** (§17a). Loosening `maxSsimVsBlank` to 1.01 kills a case, but it "
        "kills it through `not controlPassesSsim(entry)` — the same "
        "assertion `M2` breaks — so `--derive` reported *M6 and M2 derived "
        "the same `because`; an arm must not be attributable to a case it "
        "did not break* and refused the pair. Two arms testing one predicate "
        "through two different doors is a harness with a hole it cannot see; "
        "the guard saw it."),

    Arm("M7", THRESHOLDS,
        '      { "date": "2026-09-22", "value": 0.2, "change": "TIGHTENED to the tightest candidate the sweep admits" }\n    ]',
        '      { "date": "2026-09-22", "value": 0.2, "change": "TIGHTENED to the tightest candidate the sweep admits" },\n      { "date": "2026-09-23", "value": 0.05, "change": "loosened" },\n      { "date": "2026-09-24", "value": 0.01, "change": "loosened" }\n    ]',
        SUITE,
        "'minEdgeChangeRatioVsBlank' carries a direction, a reason and a history",
        CTL[THRESHOLDS][0], CTL[THRESHOLDS][1],
        "A THRESHOLD LOOSENED TWICE. The ratchet rule, inherited from "
        "PLAT-35's thresholds.json and from visual-design-iteration.md: a "
        "threshold loosened twice is a defect in the CAPTURE, not in the "
        "threshold. It is enforced rather than quoted, and the direction is "
        "read off the entry — this one is a FLOOR, so loosening it is a "
        "LOWER value, and a single spelling of 'raised' would have been "
        "wrong for it."),

    # ------------------------------------------------------------------
    # THE PALETTE, THE PARSER, THE SCAN AND THE POPULATION
    # ------------------------------------------------------------------
    Arm("M8", CHROME,
        '    "#e6edf3", # crWindowForeground',
        '    "#13171d", # crWindowForeground',
        SUITE,
        "every foreground/background pair clears the contrast floor",
        CTL[CHROME][0], CTL[CHROME][1],
        "THE WINDOW OPENS, PAINTS, AND PHOTOGRAPHS AS A BLANK SCREEN. A "
        "foreground one shade off the background is the exact failure this "
        "milestone exists to make impossible, arriving through the PALETTE "
        "instead of through the renderer — and no image metric in the gate "
        "would catch it on a corpus captured before the change, which is why "
        "contrast is COMPUTED from the WCAG definition rather than eyeballed."),

    Arm("M9", REPLAY_OPS,
        "  for k in ReplayOpKinds:\n    if k == kind: return true\n  false",
        "  for k in ReplayOpKinds:\n    if k == kind: return true\n  true",
        SUITE,
        "the parser refuses what it should refuse, and names what it saw",
        CTL[REPLAY_OPS][0], CTL[REPLAY_OPS][1],
        "THE VOCABULARY STOPS BEING CLOSED. A parser that accepts "
        "`steppIn=6` performs no operation and draws the ENTRY POINT, and a "
        "frame taken at the wrong state is worse than no frame: it is a "
        "picture nobody can tell from the right one. §4 — a parse that "
        "matched nothing satisfies everything written over it."),

    Arm("M10", CHROME,
        "func chromeOf*(role: ChromeRole): string =\n  WindowChrome[role]",
        "func chromeOf*(role: ChromeRole): string =\n  let destroy = 0\n  discard destroy\n  WindowChrome[role]",
        SUITE,
        "no source file CALLS the window registry, comments excluded",
        CTL[CHROME][0], CTL[CHROME][1],
        "A REGISTRY NAME REAPPEARS IN A FILE THAT IS NOT `main.nim`. **This "
        "is the arm aimed at the SCAN'S SUBJECT SET rather than at the "
        "subject** (§35a): the cheapest way past a one-file scan is to make "
        "the call from a file the scanned one imports, and this front-end "
        "grew two new modules in this very milestone. An identical arm "
        "placed in `main.nim` would be killed by a scan that covers only "
        "`main.nim`, and would therefore certify nothing about the set."),

    Arm("M12", SCENARIOS,
        '      "id": "entry-shell",\n      "view": "shell",\n      "recording": "calc",\n      "viewport": "wide",\n      "operations": [],',
        '      "id": "entry-shell",\n      "view": "shell",\n      "recording": "calc",\n      "viewport": "wide",\n      "operations": [{ "kind": "sneak", "times": 1 }],',
        SUITE,
        "every operation the scenario set USES is one the parser performs",
        CTL[SCENARIOS][0], CTL[SCENARIOS][1],
        "THE CORPUS GROWS AN OPERATION NO DRIVER PERFORMS. `scenarios.json` "
        "publishes the vocabulary AND uses it, and those are two claims: a "
        "member the set declares but nothing performs is a member it has for "
        "free, and a scenario that names one captures a state nobody asked "
        "for on one side and the entry point on the other. The vocabulary "
        "agreement case cannot see this — `sneak` is in neither list, so both "
        "set differences stay empty — which is why the USE is checked "
        "separately from the AGREEMENT."),

    # ------------------------------------------------------------------
    # THE MEASURING CODE — the one arm that needs frames
    # ------------------------------------------------------------------
    Arm("M11", VISION,
        "    if n.len > 0 and hay.contains(n):",
        "    if n.len > 0:",
        SUITE,
        "the needles score ZERO on the blank control captured beside the frame",
        CTL[VISION][0], CTL[VISION][1],
        "THE OCR JOIN MATCHES WITHOUT LOOKING. `ocrHits` stops consulting the "
        "haystack, so every needle is a hit on every frame — including the "
        "BLANK CONTROL, which is the case that sees it. **It is the only arm "
        "here graded against the LIVE corpus**, because nothing in the "
        "recorded path runs this module at all: the recorded numbers were "
        "produced by it on another machine, and a mutation cannot reach "
        "backwards into a file already written. A harness that graded ten "
        "arms and had no opinion about the module producing every number the "
        "other ten corrupt would be a harness with a hole in exactly the "
        "place it is hardest to see.",
        corpus="live"),
]

# §10.3's rejection list. A `find` or `control_find` holding any of these is
# REFUSED rather than warned about: an arm whose needle quotes a count is an
# arm that stops matching on the most frequent edit a suite receives.
COUNT_SPELLINGS = [
    "ExpectedAssertions",
    "CHECKS:",
    "expectedScenarios",
    "expectedViewports",
    "expectedCanaries",
    "expectedOperationKinds",
    "MinNeedleLength",
    "MaxNeedles",
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
    APPENDING a comment marker (or a JSON member) to a matched fragment, so a
    needle that is a PREFIX of a longer line comments out the rest of that
    line and the behaviour-preserving control stops being behaviour-preserving.
    """
    at = text.find(needle)
    if at < 0:
        return False, ""
    nl = text.find("\n", at + len(needle))
    end = at + len(needle)
    rest = text[end:nl if nl >= 0 else len(text)]
    return rest.strip() == "", rest


def needle_scan() -> list[str]:
    bad: list[str] = []
    # A MISSING SUBJECT FAILS BY NAME, not with a traceback. The recorded
    # measurement file is produced by `ci/test/plat37_measure.nim` from a real
    # capture; a tree without it cannot grade half these arms, and saying so is
    # the difference between a harness that refuses and one that crashes.
    for rel in sorted({a.path for a in ARMS} | {SUITE}):
        if not (REPO / rel).exists():
            bad.append(
                f"subject {rel} is not in the tree. If it is "
                f"{MEASUREMENTS}, take a capture and record it:\n"
                f"      bash ci/test/plat37-window-frame.sh\n"
                f"      just plat37-measure")
    if bad:
        return bad
    for arm in ARMS:
        text = (REPO / arm.path).read_text()
        # `find` is allowed to occur more than once ONLY where the arm says so
        # in its own note, and no arm says so: the record holds one
        # `ssimVsBlank` per run, so a needle that matched several would mutate
        # whichever `str.replace(..., 1)` reached first and the arm would be
        # about a row nobody chose.
        for label, needle in (("find", arm.find),
                              ("control_find", arm.control_find)):
            n = text.count(needle)
            expected = 1
            if label == "find" and arm.name in FIRST_MATCH_ARMS:
                # DECLARED, not tolerated. These arms target the FIRST
                # occurrence of a repeated key in a generated record, and the
                # count of occurrences is data — so the scan asserts the
                # needle matches AT LEAST once and the arm's `kills` names the
                # scenario the first occurrence belongs to.
                if n < 1:
                    bad.append(f"{arm.name}.{label}: occurs 0 times in "
                               f"{arm.path}")
                continue
            if n != expected:
                bad.append(f"{arm.name}.{label}: occurs {n} time(s) in "
                           f"{arm.path}, expected exactly {expected}")
                continue
            for spelling in COUNT_SPELLINGS:
                if spelling in needle:
                    bad.append(f"{arm.name}.{label}: quotes the count "
                               f"spelling '{spelling}' — §10.3 REJECTS this, "
                               f"it does not warn about it")
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


# The arms whose `find` deliberately targets the FIRST occurrence of a key that
# the generated record repeats once per run. Declared here rather than handled
# by a lenient default, so an arm that started matching several times by
# ACCIDENT is still refused.
FIRST_MATCH_ARMS = {"M1", "M2", "M3", "M4", "M5"}


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN FAILED:")
        for b in bad:
            print("  " + b)
        return 2
    print(f"needle scan: {len(ARMS)} arm(s), every `find` and `control_find` "
          f"matches, ends at a line end, and quotes no count")
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
# Control digests for run-plat37-window-mutations.py.
#
# The bytes every arm restores to, and the bytes every arm's verdict was taken
# against. BOTH HALVES OF `TOUCHED` are here — the six mutation subjects AND
# the suite the arms are graded by — which is Verification-Harness-Traps §16c's
# gap paid rather than inherited: a change that touches only the suite
# invalidates every arm graded against it while producing no overlap signal at
# all in a harness whose TOUCHED names subjects only.
#
# THIS FILE EXISTS FROM THE HARNESS'S FIRST COMMIT. §39 is open because three
# harnesses never had one; a new harness joining them is a deliberate act, and
# this one does not join them.
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


def run_suite(suite: str, corpus: str) -> tuple[int, str]:
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    cmd = ["nim", "c", "-r", "--hints:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + SUITE_CMD[suite] + [suite]
    env = dict(os.environ)
    # **PINNED, NEVER INHERITED.** Without this the harness would grade an arm
    # against whichever corpus happened to be on the disk, and an arm that
    # corrupted the recorded record would SURVIVE on a workstation that had
    # just captured — for a reason with nothing to do with the gate.
    env["PLAT37_CORPUS"] = corpus
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       timeout=7200, env=env)
    return p.returncode, p.stdout + p.stderr


def require_live_corpus(selected) -> int:
    """A live-corpus arm needs the frames. Absent, it FAILS BY NAME."""
    if not any(a.corpus == "live" for a in selected):
        return 0
    if (REPO / "build/plat37/manifest.json").exists():
        return 0
    print("REFUSED: an arm in this selection is graded against the LIVE "
          "corpus and build/plat37/manifest.json is not here.")
    print("  Take a capture first:  bash ci/test/plat37-window-frame.sh")
    print("  This is NOT skipped. An arm that cannot be graded and is "
          "counted as passed is the defect the whole campaign is about; "
          "--only can exclude it deliberately, which is a different act.")
    return 3


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
    assert text.count(find) >= 1, f"needle not found in {rel}"
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
            rc, out = run_suite(arm.suite, arm.corpus)
        finally:
            restore(arm.path, original)
        lines = failure_lines_for(out, arm.kills)
        checks = [ln[ln.index("Check failed:"):] for ln in lines
                  if "Check failed:" in ln]
        if not checks:
            # **NOT EVERY FAILURE `std/unittest` REPORTS IS A `Check failed:`
            # LINE**, and an arm aimed at one that is not would otherwise be
            # refused as underivable rather than graded. `expect` prints its
            # own form — this repository's parser suite is full of them — so
            # the fallback is the first non-empty line of the failing case's
            # block, which is that message. The fallback is deliberately
            # SECOND: a `Check failed:` line is a more specific attribution
            # and is preferred wherever there is one.
            checks = [ln for ln in lines if ln.strip()]
        if not checks:
            print(f"{arm.name}: NO `Check failed:` line for '{arm.kills}' — "
                  f"cannot derive a `because`.")
            print("   verdict was:", verdict_for(out, arm.kills))
            continue
        text = re.sub(r"\s+", " ", checks[0]).strip()
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
            rc, out = run_suite(arm.suite, arm.corpus)
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
            crc, cout = run_suite(arm.suite, arm.corpus)
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
    print("| arm | subject | corpus | verdict | note |")
    print("|-----|---------|--------|---------|------|")
    for arm, verdict, note in results:
        print(f"| {arm.name} | {Path(arm.path).name} | {arm.corpus} | "
              f"**{verdict}** | {note} |")
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

    rc = require_live_corpus(selected)
    if rc:
        return rc

    if args.derive:
        return derive(selected)
    return grade(selected)


if __name__ == "__main__":
    sys.exit(main())
