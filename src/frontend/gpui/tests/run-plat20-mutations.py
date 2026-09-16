#!/usr/bin/env python3
"""PLAT-20 mutation harness — the GPUI shell, the dock projection and `--ui=gpui`.

WHAT THIS IS
------------
Each arm applies ONE textual mutation to ONE source file, runs the suite(s)
that grade it, and requires a NAMED case to go red for the arm's OWN reason.
Every arm is reverted and the revert is verified by digest.

THE DISCIPLINE, AND WHERE EACH RULE COMES FROM
----------------------------------------------
`codetracer-specs/Testing/Verification-Harness-Traps.md`:

* **Five verdicts, not two** (§1a). `KILLED`, `SURVIVED`, `DID-NOT-COMPILE`,
  `MIS-ATTRIBUTED` and `NO-VERDICT-FOR-KILLER`. The last is §1a's mirror: a
  mutant that CRASHES the case prints no verdict line for it, and a line parser
  folds that into `SURVIVED`.
* **`because` is DERIVED, never typed** (§17, §17a, §17b). `--derive` reverts
  nothing, applies each arm, runs its grader and records the `Check failed:`
  line the killer case actually printed. A `because` typed from the source is a
  second copy of the code held in a file the compiler does not read, and for an
  assertion inside a `template` it is a string that can never occur.
* **Two arms may not derive the same `because`** (§17a's closing rule). If they
  do, the run REFUSES: a shared string lets an arm be attributed to a case it
  did not break.
* **The needle scan GATES the re-record** (§16). Every `find` and every
  `control_find` must occur EXACTLY ONCE. `--record-control-hashes` runs the
  scan first and refuses to record while any arm is unaimed, because recording
  from the subject under suspicion is §7 arriving inside the verification step.
* **`flock` before any digest** (§14d's corollary). A second run in the same
  worktree would otherwise grade a mutated file.
* **A named behaviour-preserving CONTROL per arm** (§4a, §14). One edit to the
  same region that must NOT change any verdict. An arm whose control goes red
  is scored `CONTROL-HARNESS-FAILURE`, which is a statement about the harness.
* **`TOUCHED` names every file an arm's verdict depends on** (§16b, §16c) —
  the ten subjects AND the four suites the arms are graded against, not only
  the files the arms restore. §16c's audit found nine of sixteen harnesses
  declaring subjects only; this one does not join them.

USAGE
-----
    run-plat20-mutations.py --needle-scan
    run-plat20-mutations.py --record-control-hashes   # refuses if the scan fails
    run-plat20-mutations.py --derive                  # re-derive every `because`
    run-plat20-mutations.py                           # the graded run
    run-plat20-mutations.py --only G5,G7
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HARNESS_DIR = Path(__file__).resolve().parent

# --- subjects ---------------------------------------------------------------
DOCK = "src/frontend/gpui/app/dock_projection.nim"
SHELL = "src/frontend/gpui/app/shell.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
EXTENT = "src/frontend/headless_app/extent_distribution.nim"
UISEL = "src/ct/ui_selection.nim"
UIDISP = "src/ct/launch/ui_dispatch.nim"

# --- the suites the arms are graded against ---------------------------------
# §16c: these are NOT mutation subjects, and they are in TOUCHED anyway. A
# change that touches only a suite invalidates every arm graded against it
# while producing no overlap signal at all if TOUCHED names subjects only.
SUITE_DOCK = "src/frontend/gpui/tests/test_gpui_dock_projection.nim"
SUITE_SPLIT = "src/frontend/gpui/tests/test_gpui_shell_split.nim"
SUITE_CROSS = "src/frontend/tui/tests/test_cross_frontend_layout.nim"
SUITE_UISEL = "src/ct/ui_selection_test.nim"

TOUCHED = [DOCK, SHELL, LEAVES, EXTENT, UISEL, UIDISP,
           SUITE_DOCK, SUITE_SPLIT, SUITE_CROSS, SUITE_UISEL]

CONTROL_HASHES = HARNESS_DIR / "plat20-mutation-control.sha256"
BECAUSE_FILE = HARNESS_DIR / "plat20-mutation-because.json"
LOCK_FILE = REPO / "build" / "plat20-mutations.lock"
# UNDER `build/`, NOT beside the harness. A lock file next to the source is an
# untracked artefact in the tree the harness itself digests, and it would turn
# up in every `git status --porcelain -uall` sweep §16b asks for — noise in the
# one instrument whose value is that its list is exact.

NIMCACHE = REPO / "build" / "plat20mut"

# How each suite is compiled and run. The flags are the LANE's, not invented
# here: `gpui-shell` and `ct-cli-units` are in `ci/lib/test-lane-files.sh` and
# the cross-front-end suite runs in the `tui` lane.
def _tui_link_flags() -> list[str]:
    """The `--passL:` flags the `tui` LANE gives a suite that links isonim-tui.

    READ FROM THE FILE THE LANE READS, never copied. `ci/lib/test-lane-files.sh`
    builds the `tui` lane's flags from `build/grammars/tui-link-flags.txt`,
    which `scripts/build-tui-grammars.sh` writes after resolving tree-sitter by
    four routes with no hard-coded store path. A second copy of that answer here
    would be Verification-Harness-Traps §14 exactly: two spellings of one fact,
    and the one nobody runs is the one that goes stale when the store path
    changes.

    **THIS EXISTS BECAUSE ITS ABSENCE COST TWO ARMS, measured on 2026-09-16.**
    `SUITE_CROSS` links `isonim_tui` (through `tui/app/layout/project`), and
    `isonim_tui/syntax/treesitter_ffi.nim` ends its `{.passl.}` with
    `-ltree-sitter`. Without `-L`, the link fails with
    `ld: cannot find -ltree-sitter` — so arms G5 and G12 both scored
    `DID-NOT-COMPILE` outside the nix dev shell, which is the verdict that
    means the run told you nothing. G5 is the LOAD-BEARING arm of this harness:
    it is the state PLAT-20's own risk note names.

    Absent, the flags are simply omitted rather than raising: inside the dev
    shell the linker finds the library on its own, and a harness that refused
    to start there would be worse than one that works in both places.
    """
    path = REPO / "build" / "grammars" / "tui-link-flags.txt"
    if not path.exists():
        return []
    return [f"--passL:{flag}" for flag in path.read_text().split()]


SUITE_CMD = {
    SUITE_DOCK: ["--path:src/frontend/viewmodel"],
    SUITE_SPLIT: ["--path:src/frontend/viewmodel"],
    SUITE_CROSS: ["--path:src/frontend/viewmodel"] + _tui_link_flags(),
    SUITE_UISEL: ["--mm:refc"],
}


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


ARMS = [
    Arm("G1", DOCK,
        "  of leTop: (false, dpCenter)",
        "  of leTop: (true, dpBottom)",
        SUITE_DOCK,
        "a pane docked to the TOP edge is REFUSED, not relocated",
        "func placementFor*(edge: LayoutEdge): (bool, DockPlacement) =",
        "func placementFor*(edge: LayoutEdge): (bool, DockPlacement) = ## ctl",
        "gpui-kit has no `top` placement. Silently rounding it to `bottom` is "
        "the 'I lost a pane' failure Layout-ViewModel §3A.2 is written "
        "against, and it is the cheapest mistake to make here."),

    Arm("G2", DOCK,
        '  result["open"] = %false',
        '  result["open"] = %true',
        SUITE_DOCK,
        "a docked pane becomes a DockState at its edge, and `open` is false",
        "  result[\"placement\"] = %($placement)",
        "  result[\"placement\"] = %($placement)  # ctl",
        "`revealed` is transient and is not in the committed layout (§3.2). "
        "An `open` a projection invented would reopen an overlay on restore."),

    Arm("G3", DOCK,
        "    let axis = if horizontal: 0 else: 1",
        "    let axis = if horizontal: 1 else: 0",
        SUITE_DOCK,
        "a row is axis 0 and a column is axis 1, which is gpui-kit's encoding",
        "    let horizontal = n.kind == lnRow",
        "    let horizontal = (n.kind == lnRow)",
        "gpui-kit's `PanelInfo::stack` writes 0 for Horizontal and 1 for "
        "Vertical. Swapping them produces a document that deserialises "
        "perfectly and lays out at right angles to the model."),

    Arm("G4", DOCK,
        "      if paneId.len == 0:",
        "      if paneId.len == 0:\n        paneId = c[\"panel_name\"].getStr\n      if paneId.len == 0:",
        SUITE_DOCK,
        "our reader DESCENDS upstream's documents, and reports no pane in them",
        "        elif panel.hasKey(PaneInfoKey):",
        "        elif panel.hasKey(PaneInfoKey):  # ctl",
        "Verification-Harness-Traps §4d: guessing a pane id out of "
        "`panel_name` is matching VOCABULARY rather than syntax. gpui-kit's "
        "own leaves are `Alpha`, `Beta`, `StoryContainer`; a reader that "
        "guessed would report them as ours."),

    Arm("G5", SHELL,
        "  saveLayout(shell.windows.windows[idx].layout)",
        "  projectDock(shell.windows.windows[idx].layout, shell.viewport).state",
        SUITE_CROSS,
        "the GPUI front-end persists the MODEL, not a DockAreaState",
        "  if idx < 0:\n    raiseShell(\"saveWindowLayout: no window \" & $id)",
        "  if idx < 0:\n    raiseShell(\"saveWindowLayout: no window \"  & $id)",
        "THE LOAD-BEARING ARM. PLAT-20's risk note: '`DockState` becomes the "
        "source of truth because it is the thing the library wants to own, "
        "and the model degrades into a serialisation format.' This arm IS "
        "that state."),

    Arm("G6", LEAVES,
        "    if not leaf.live:",
        "    if false:",
        SUITE_SPLIT,
        "the render plan verifies, and carries one line per leaf",
        "    r.setAttribute(node, StateAttribute, \"unloaded-extension\")",
        "    r.setAttribute(node, StateAttribute, \"unloaded-extension\") # ctl",
        "A leaf with no ViewModel must SAY so. Reporting it as live is the "
        "blank-region failure PLAT-9 forbids.\n\n"
        "RE-AIMED AFTER IT SURVIVED. The first version changed the leaf's "
        "`data-ct-state` ATTRIBUTE from `not-launched` to `live` and the case "
        "stayed green — correctly, because the render plan carries no "
        "attribute map (see the note on `planLeafTexts`) and the case reads "
        "the TEXT. Verification-Harness-Traps §16a's shape without a repair: "
        "the arm pointed at live code, applied, compiled and ran, and its "
        "evidence was never about the thing. The re-aimed arm removes the "
        "branch that chooses the text."),

    Arm("G7", SHELL,
        "      leaf.kind = if classified.kind == prContributed: glkContributed\n"
        "                  else: glkUnloadedExtension",
        "      leaf.kind = glkContributed",
        SUITE_SPLIT,
        "a contributed pane from an unloaded extension keeps its slot",
        "      let classified = classify(PaneRef(kind: prContributed, id: slot.pane),",
        "      let classified = classify(PaneRef(kind: prContributed, id: slot.pane),  # ctl",
        "This is the mistake the first draft of `leavesFor` actually made: "
        "being IN THE LAYOUT and being provided by a LOADED EXTENSION are "
        "different questions, and only `classify` asks the second."),

    Arm("G8", UISEL,
        '  AcceptedUiValues*: array[5, string] = ["electron", "gui", "gpui", "tui",\n                                         "webui"]',
        '  AcceptedUiValues*: array[4, string] = ["electron", "gui", "tui",\n                                         "webui"]',
        SUITE_UISEL,
        "`gpui` is ACCEPTED, and reaches its own component — PLAT-20",
        "  UiEnvVar* = \"CODETRACER_UI\"",
        "  UiEnvVar* = \"CODETRACER_UI\"  # ctl",
        "The deliverable itself: `--ui=gpui` reaching the front-end through "
        "PLAT-1's resolution."),

    Arm("G9", DOCK,
        "    tabPanelAround(kids, active)",
        "    tabPanelAround(kids, 0)",
        SUITE_DOCK,
        "a stack becomes ONE TabPanel carrying every tab and the active index",
        "    var active = n.activeIndex",
        "    var active = n.activeIndex  # ctl",
        "STACK MEMBERSHIP is half of what PLAT-20's cross-front-end test "
        "compares on. A tab group that always reports tab 0 active loses it."),

    Arm("G10", DOCK,
        "  let modelProblems = layout.validate()",
        "  let modelProblems: seq[LayoutProblem] = @[]",
        SUITE_DOCK,
        "an INVALID layout is refused rather than projected",
        "    return DockProjection(status: dpsRefused, problems: ps)",
        "    return DockProjection(status: dpsRefused, problems: ps)  # ctl",
        "A projection of an invalid tree is how a pane goes missing quietly. "
        "The dock projection refuses rather than degrading, because the "
        "window has not opened yet."),

    # ------------------------------------------------------------------
    # UNDECLARED ARMS — planted by the implementing pass against its own
    # evidence, not derived from the deliverable list. G11 is the one that
    # found something.
    # ------------------------------------------------------------------
    Arm("G11", EXTENT,
        "  if sum <= 0.0:\n    for i in 0 ..< n:\n      ideal[i] = float(total) / float(n)\n  else:\n    for i in 0 ..< n:\n      ideal[i] = float(total) * max(0.0, shares[i]) / sum",
        "  for i in 0 ..< n:\n    ideal[i] = float(total) / float(n)",
        SUITE_DOCK,
        "sizes sum to the extent exactly and follow the weights",
        "  var sum = 0.0",
        "  var sum = 0.0  # ctl",
        "WEIGHTS IGNORED — every sibling gets an equal share. Planted to ask "
        "what the CROSS-PROJECTION agreement test can see: both projections "
        "divide through this one function (§14's remedy), so a change here "
        "moves BOTH sides identically and the agreement holds. The answer is "
        "recorded in PLAT-20's status block; the coverage for the "
        "distribution is the dock suite's explicit ratio case and "
        "`test_layout_node_projection.nim`'s three properties, NOT the "
        "agreement."),

    Arm("G12", SHELL,
        "  let restored = restoreLayoutDocument(doc)",
        "  let restored = initLayout(defaultReplayLayout())",
        SUITE_CROSS,
        "terminal -> GPUI, through the model's own document",
        "  let idx = shell.windows.indexOf(id)\n  if idx < 0:\n    raiseShell(\"restoreWindowLayout: no window \" & $id)",
        "  let idx = shell.windows.indexOf(id)\n  if idx < 0:\n    raiseShell(\"restoreWindowLayout: no window \"  & $id)",
        "UNDECLARED. A restore that silently returns the DEFAULT layout is "
        "the 'silent fallback' `adoptLayoutDocument` exists to prevent, one "
        "front-end over — and it is the shape a round-trip test that "
        "compared only 'did it not raise' would pass over."),

    Arm("G13", DOCK,
        "  if centre[\"panel_name\"].getStr == \"TabPanel\":",
        "  if false:",
        SUITE_DOCK,
        "two of upstream's own subtrees are SHAPE-IDENTICAL to our projections",
        "  var doc = newJObject()\n  doc[\"version\"] = %DockSchemaVersion",
        "  var doc = newJObject()\n  doc[\"version\"] = %DockSchemaVersion  # ctl",
        "UNDECLARED. gpui-kit's own comment requires `DockAreaState.center` to "
        "be a `StackPanel` even when empty (`RootKind::Split`). Emitting a "
        "bare `TabPanel` root deserialises fine and is wrong, which is "
        "exactly the kind of thing a fixture-shaped conformance case is for."),

    # ------------------------------------------------------------------
    # ADDED BY THE SECOND VERIFICATION, 2026-09-15. It SURVIVED when it was
    # first planted, and the repair is in the SUITE.
    # ------------------------------------------------------------------
    Arm("G14", DOCK,
        '  const dockKeys = [("left_dock", dpLeft), ("right_dock", dpRight),\n                    ("bottom_dock", dpBottom)]',
        '  const dockKeys = [("left_dock", dpLeft), ("right_dock", dpRight)]',
        SUITE_DOCK,
        "a pane docked to EACH of the three edges round-trips through the "
        "reader",
        "  if state.hasKey(\"center\"):",
        "  if state.hasKey(\"center\"):  # ctl",
        "THE READER LOSES A DOCK KEY. Planted by the verifying pass and it "
        "SURVIVED: only `left_dock` was graded, so `right_dock` and "
        "`bottom_dock` could each be dropped — measured one at a time — with "
        "every suite in this repository green.\n\n"
        "It is not cosmetic. `shell.leavesFor` derives its leaves from this "
        "reader, so a key it does not descend is a pane the projection writes "
        "into the document and the front-end then draws NOTHING for — the 'I "
        "lost a pane' failure Layout-ViewModel §3A.2 is written against, "
        "arriving through the reader instead of through a coordinate.\n\n"
        "Why nothing caught it: the nine-command sweep asks "
        "`layout.visiblePanes()`, and `visiblePanes` deliberately EXCLUDES a "
        "docked pane. The one loop that looked like it covered every "
        "reachable pane covered exactly the panes that are not docked — "
        "Verification-Harness-Traps §4a's emptied subject, one level in.\n\n"
        "The repair is a CASE, not an arm. This arm drops `bottom_dock`; the "
        "`right_dock` and `left_dock` drops are symmetric and were each "
        "measured to die against the same new case. They are not three arms "
        "because all three print the identical substituted failure text "
        "(`Check failed: found`), and §17a REFUSES a shared `because`."),
]


# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

def digest(rel: str) -> str:
    return hashlib.sha256((REPO / rel).read_bytes()).hexdigest()


def take_lock():
    """`flock` BEFORE any digest (§14d's corollary).

    A second run in the same worktree legitimately takes the lock; while it
    holds it the tree on disk carries one arm's mutation, and any digest taken
    in that window blesses a mutated file. `rm -f` of the lock file is not
    cleanup — `flock` is on the inode — so the handle is held for the whole
    run and never unlinked.
    """
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.touch(exist_ok=True)
    fh = open(LOCK_FILE, "r+")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("REFUSED: another run holds the lock. Nothing was mutated.")
        sys.exit(3)
    return fh


def needle_scan() -> list[str]:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    Exactly once, not at least once: an arm whose needle occurs twice has two
    targets and hits neither (§16).
    """
    bad = []
    for arm in ARMS:
        text = (REPO / arm.path).read_text()
        n = text.count(arm.find)
        if n != 1:
            bad.append(f"{arm.name}: `find` occurs {n} times in {arm.path}, "
                       f"expected exactly 1")
        m = text.count(arm.control_find)
        if m != 1:
            bad.append(f"{arm.name}: `control_find` occurs {m} times in "
                       f"{arm.path}, expected exactly 1")
    return bad


def report_needle_scan() -> int:
    bad = needle_scan()
    if bad:
        print("NEEDLE SCAN FAILED — these arms are unaimed and cannot be "
              "killed:")
        for b in bad:
            print("  " + b)
        return 1
    print(f"needle scan: {len(ARMS)} arm(s), every `find` and `control_find` "
          f"occurs exactly once")
    return 0


def check_control_hashes() -> bool:
    if not CONTROL_HASHES.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL_HASHES.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        want, rel = line.split(None, 1)
        rel = rel.strip()
        have = digest(rel)
        if have != want:
            print(f"TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
            print(f"  {rel}\n      recorded {want[:8]}…   on disk {have[:8]}…")
            ok = False
    return ok


CONTROL_HEADER = """\
# Control digests for run-plat20-mutations.py.
#
# The bytes every arm restores to, and the bytes every arm's verdict was taken
# against. BOTH HALVES OF `TOUCHED` are here — the six mutation subjects AND
# the four suites the arms are graded by — which is Verification-Harness-Traps
# §16c's gap paid rather than inherited: a change that touches only a suite
# invalidates every arm graded against it while producing no overlap signal at
# all in a harness whose TOUCHED names subjects only.
#
# Recorded AFTER running the pre-commit hooks over every file (§16e). `shfmt`,
# `shellcheck`, `end-of-file-fixer`, `trim-trailing-whitespace`,
# `markdownlint-fix` and `cspell` all report Passed with the bytes unchanged,
# so the digests below are the digests the commit carries. Reading the files
# proves nothing here; running the hooks does.
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
                       timeout=2400)
    return p.returncode, p.stdout + p.stderr


def failure_lines_for(out: str, case: str) -> list[str]:
    """The `Check failed:` lines printed for `case`, in order.

    `unittest` prints the failure lines BEFORE the `[FAILED] <name>` line, so
    the block for a case is everything since the previous verdict line.
    """
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


# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------

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
        # `unittest` prefixes the line with the FILE AND POSITION, so the
        # marker is not at the start. Taking the substring from the marker is
        # also what makes the derived string position-independent: a line added
        # above the assertion would otherwise change every `because` in the
        # file (§17b's staleness, self-inflicted).
        checks = [l[l.index("Check failed:"):] for l in lines
                  if "Check failed:" in l]
        if not checks:
            print(f"{arm.name}: NO `Check failed:` line for '{arm.kills}' — "
                  f"cannot derive a `because`.")
            print("   verdict was:", verdict_for(out, arm.kills))
            continue
        # The FIRST one: the assertion the mutation reached first.
        text = re.sub(r"\s+", " ", checks[0]).strip()
        derived[arm.name] = text
        print(f"{arm.name}: because = {text}")
    # §17a's closing rule: two arms may not share a `because`.
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

        # 1. the arm
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
            # §1a's mirror: a mutant that crashed the case prints no verdict
            # line for it, and a line parser folds that into SURVIVED.
            results.append((arm, "NO-VERDICT-FOR-KILLER",
                            "the run told you nothing"))
            continue
        if v == "OK":
            results.append((arm, "SURVIVED", ""))
            continue

        raw = failure_lines_for(out, arm.kills)
        lines = " ".join(l[l.index("Check failed:"):] if "Check failed:" in l
                         else l for l in raw)
        lines = re.sub(r"\s+", " ", lines)
        if because[arm.name] not in lines:
            results.append((arm, "MIS-ATTRIBUTED",
                            f"expected: {because[arm.name]}"))
            continue

        # 2. the behaviour-preserving control
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
