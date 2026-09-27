#!/usr/bin/env python3
"""PLAT-45 — the mutation harness for ONE default arrangement, shared by every
front-end: the shared tree, the fold, the capability, the generated desktop
default, and each product's own remembered layout.

    python3 src/frontend/tui/tests/run-plat45-layout-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --only=S1,F2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported (the fold, three-media and real-PTY suites open the real `calc`
recording). The GPUI suites load `libgpui_nim_shim`; the harness puts the shim
on `LD_LIBRARY_PATH` itself.

ONE ARM PER CLAIM OF THE VERIFICATION GATE, each naming the case that must die:

  | gate row | arms |
  |---|---|
  | one source: moving a pane in `sharedDefaultLayout()` moves ALL THREE
  |   front-ends' observed default | S1 (terminal), S1g (GPUI) |
  | one source: a hand edit of `default_layout.json` fails the staleness check | S2 |
  | one source: a hand-written terminal profile tree fails three-media | S3 |
  | one product reading another's layout file | R1 (GPUI), R2 (terminal) |
  | a product that skips the save | R3 (terminal write-through), R4 (GPUI) |
  | fold law: a pane dropped | F1 |
  | fold law: a depth skipped | F2 |
  | fold law: monotonicity violated | F3 |
  | the fold is exactly as deep as the cells require | F4 |
  | edit mode folds ITS OWN shared default | F5 |
  | the capability: an undrawable pane silently omitted | C1 (model), C2 (GPUI plan) |
  | the persisted format: the v3 -> v4 migration | V1 |
  | the one table where PaneKind meets Content | T1 |
  | the translation re-derives the desktop's percentages | D1 |
  | the terminal sizes minimums first, not in the desktop's proportions | E1 |
  | report-only regions fold before any region that draws data | E2 |
  | the source pane's minimum is "usable" (60), not "legible" | E3 |
  | a resize inside one depth re-shares the cells | E4 |

THE GPUI WINDOW'S OWN DRAWING (`gpui/main.paintWindowChrome` laying the
leaves out by the dock document) has no arm here: its evidence is a frame on a
compositor (`ci/test/plat45-arrangement-window.sh`), which no suite this
harness runs can take. The committed reading of that frame is asserted by the
three-media suite; re-taking it is the recorded-dark capture lane's job.

THREE VERDICTS (Verification-Harness-Traps §1): `killed` (the named case
reported [FAILED]), `SURVIVED` (result lines, the named case [OK]),
`HARNESS-FAILURE` (the needle was not unique, the suite did not compile, or it
printed no result lines). A run that prints nothing is never a kill.

THE BINARIES ARE PART OF THE SUBJECT (PLAT-44's addition). An arm whose defect
is compiled into `build/bin/codetracer-gpui` or `build/bin/codetracer-tui` is
graded against a binary REBUILT with the defect — otherwise a shipped-binary
case grades the unmutated binary and the arm survives for a reason that has
nothing to do with the assertion (§4a). Both binaries are rebuilt from the
restored tree at the end.

RESTORATION is from an in-memory snapshot, and every subject's SHA-256 is
compared with the pre-run baseline after each arm (§32). `--needle-scan`
refuses a lost or ambiguous needle; the full run refuses unless the scan is
clean AND every subject matches `plat45-layout-mutation-control.sha256`.

NO DECLARED SURVIVORS.
"""

from __future__ import annotations

import hashlib
import os
import re
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]            # .../codetracer

# -- subjects ---------------------------------------------------------------
MODEL = "src/frontend/headless_app/layout_model.nim"
DESK = "src/frontend/headless_app/desktop_panes.nim"
DEFAULT = "src/config/default_layout.json"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
PERSIST = "src/frontend/tui/app/layout/persistence.nim"
TUIMAIN = "src/frontend/tui/main.nim"
GMEM = "src/frontend/gpui/layout_memory.nim"
GMAIN = "src/frontend/gpui/main.nim"
GSHELL = "src/frontend/gpui/app/shell.nim"
CELLS = "src/frontend/tui/app/layout/cells.nim"
TSHELL = "src/frontend/tui/app/views/shell.nim"

VM = "src/frontend/viewmodel/tests/unit/test_shared_default_layout.nim"
FOLD = "src/frontend/tui/tests/test_plat45_fold.nim"
THREE = "src/frontend/tui/tests/test_plat45_three_media.nim"
GPUI = "src/frontend/gpui/tests/test_plat45_gpui_layout.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_real_plat45_layout.nim"
REFLOW = "src/frontend/tui/app/tests/test_resize_reflow.nim"

SUBJECTS = [MODEL, DESK, DEFAULT, PROFILE, PERSIST, TUIMAIN, GMEM, GMAIN,
            GSHELL, CELLS, TSHELL]
SUITES = [VM, FOLD, THREE, GPUI, PTY, REFLOW]
TOUCHED = SUBJECTS + SUITES

# Which binary a subject is compiled into (a subject in neither is read by the
# suites' own compile).
IN_GPUI_BINARY = {MODEL, DESK, GMEM, GMAIN, GSHELL}
IN_TUI_BINARY = {MODEL, PROFILE, PERSIST, TUIMAIN, CELLS, TSHELL}

CONTROL_HASHES = HERE / "plat45-layout-mutation-control.sha256"
SUITE_TIMEOUT = int(os.environ.get("CT_P45_SUITE_TIMEOUT", "2400"))
SHIM = ROOT.parent / "isonim-gpui/rust/target/debug"

RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*(.*?)\s*(?:\x1b\[[0-9;]*m)*$")

# ---------------------------------------------------------------------------
# The case names, spelled ONCE.
# ---------------------------------------------------------------------------

C_TABLE = "the table is one-to-one onto Content ordinals, and inverts"
C_V3 = "every committed v3 document restores unchanged, migrated to v4"
C_REPORTS = "report leaves are exactly the placed panes a front-end cannot draw"
C_LAWS = "the four laws at every depth of the debug default"
C_STEPS = "every authored step of the debug order folds exactly one region"
C_FRESH = "the committed file is byte-for-byte the generator's output"
C_GRID = "a coarse grid from 80x24 to 300x100: minimums, minimality, reachability"
C_EDIT = "edit mode folds its own shared default by the same rule"
C_TERM = "the terminal at ultra-wide shows the shared default, read from its frame"
C_GPUI3 = "the GPUI binary's dock document is the shared default too"
C_EDITOR = "the source pane stays usable: editor width at 80x24, 120x40, 200x60"
C_REPORTFIRST = "report-only regions fold before any region that draws data"
C_RESHARE = "a resize inside one profile band keeps the active tab"
C_GREMEMBER = ("rearranged, remembered in its OWN file, restored; the others' "
               "files never read")
C_TREMEMBER = ("the terminal remembers ITS OWN layout, written through, and reset "
               "deletes only its file")

CASE_SUITE = {
    C_TABLE: VM, C_V3: VM, C_REPORTS: VM, C_LAWS: VM, C_STEPS: VM,
    C_FRESH: VM,
    C_GRID: FOLD, C_EDIT: FOLD, C_EDITOR: FOLD, C_REPORTFIRST: FOLD,
    C_RESHARE: REFLOW,
    C_TERM: THREE, C_GPUI3: THREE,
    C_GREMEMBER: GPUI,
    C_TREMEMBER: PTY,
}
NAMED_CASES = list(CASE_SUITE)


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str


ARMS = [
    # --- one source -----------------------------------------------------------
    Arm("S1", MODEL,
        "      stack([pane(paneTestResults)]),\n"
        "      stack([pane(paneConstraints)])],\n      weight = 18.75)])",
        "      stack([pane(paneConstraints)]),\n"
        "      stack([pane(paneTestResults)])],\n      weight = 18.75)])",
        C_TERM,
        "a pane moved in the ONE authored tree: the terminal's first screen "
        "moves with it, and the pinned decision notices"),
    Arm("S1g", MODEL,
        "    stack([pane(paneFileTree), pane(paneVcs)], weight = 15.0),",
        "    stack([pane(paneVcs), pane(paneFileTree)], weight = 15.0),",
        C_GPUI3,
        "the Files stack's tabs reordered in the shared tree: the GPUI "
        "window's dock document follows, and the pinned decision notices"),
    Arm("S2", DEFAULT,
        '                "size": "25%",\n',
        '                "size": "30%",\n',
        C_FRESH,
        "the desktop default edited by hand: the committed file is no longer "
        "what the shared tree generates"),
    Arm("S3", PROFILE,
        "  terminalDefaultAt(pmDebug, profile.width, profile.height,\n"
        "                    depthFor(pmDebug, profile))",
        "  column([row([pane(paneCalltrace, weight = 30.0),\n"
        "               pane(paneEditor, weight = 70.0)], weight = 3.0),\n"
        "          stack([pane(paneState), pane(paneTimeline),\n"
        "                 pane(paneEventLog)], weight = 1.0)])",
        C_TERM,
        "the terminal's hand-written compact profile reinstated: its screen "
        "is no longer a derivation of the shared default"),
    # --- each product's own file ---------------------------------------------
    Arm("R1", GMEM,
        '  GpuiLayoutFileName* = "gpui-layout.json"',
        '  GpuiLayoutFileName* = "tui-layout.json"',
        C_GREMEMBER,
        "the GPUI window reads (and writes) the terminal's file: a terminal "
        "arrangement changes the window's next start"),
    Arm("R2", PERSIST,
        '  LayoutDocumentFileName* = "tui-layout.json"',
        '  LayoutDocumentFileName* = "gpui-layout.json"',
        C_TREMEMBER,
        "the terminal reads (and writes) the GPUI window's file"),
    Arm("R3", TUIMAIN,
        "    let saved = persistLayoutForSession(rt)\n"
        "    if saved.outcome == lpoFailed:\n"
        "      rt.app.notification = saved.message",
        "    discard rt",
        C_TREMEMBER,
        "the write-through dropped: a committed gesture is not on disk until "
        "(and unless) the process exits cleanly"),
    Arm("R4", GMAIN,
        "      let failed = saveGpuiLayoutDocument(shell.saveWindowLayout(windowId))",
        "      let failed = \"\"",
        C_GREMEMBER,
        "the GPUI window skips the save: a rearrangement is gone at the next "
        "start"),
    # --- the fold -------------------------------------------------------------
    Arm("F1", MODEL,
        "  if t.kind == lnStack:\n    for m in moved:\n      t.children.add m",
        "  if t.kind == lnStack:\n    discard",
        C_LAWS,
        "a fold into an existing stack drops the folded panes on the floor"),
    Arm("F2", MODEL,
        "  for i in 0 ..< steps:\n    foldStep(result, s.folds[i])",
        "  for i in 0 ..< steps:\n    if i != 1: foldStep(result, s.folds[i])",
        C_STEPS,
        "a depth skipped: the second authored step never runs, so depth 2 "
        "shows what depth 1 did"),
    Arm("F3", MODEL,
        "    t.becomes(LayoutNode(kind: lnStack, weight: t.weight, activeIndex: 0,",
        "    t.becomes(LayoutNode(kind: lnRow, weight: t.weight, activeIndex: 0,",
        C_LAWS,
        "a fold that SPLITS its target instead of stacking into it: the region "
        "count grows, and monotonicity is broken"),
    Arm("F4", PROFILE,
        "    if fitsAt(terminalDefaultAt(product, width, height, d), width, height):\n"
        "      return d",
        "    if fitsAt(terminalDefaultAt(product, width, height, d), width, height):\n"
        "      return min(d + 1, deepest)",
        C_GRID,
        "the terminal folds one step further than its cells require"),
    Arm("F5", PROFILE,
        "  terminalDefaultAt(pmEdit, profile.width, profile.height,\n"
        "                    depthFor(pmEdit, profile))",
        "  terminalDefaultAt(pmDebug, profile.width, profile.height,\n"
        "                    depthFor(pmEdit, profile))",
        C_EDIT,
        "edit mode folds the DEBUG default rather than its own"),
    # --- the terminal gives the source pane a usable width ---------------------
    Arm("E1", PROFILE,
        "  sizeForCells(result, body.width, body.height)",
        "  discard body",
        C_EDITOR,
        "the folded tree keeps the desktop's proportions: the source pane gets "
        "a quarter of the width whatever the fold does"),
    Arm("E2", PROFILE,
        "      if not r.isNil and not drawsAny(tree, step.region, c):\n"
        "        pick = i\n        break",
        "      discard",
        C_REPORTFIRST,
        "the terminal takes the shared order as it is: a region with data can "
        "fold while a region of report leaves still takes space"),
    Arm("E3", CELLS,
        "  of paneEditor: 60\n",
        "  of paneEditor: 24\n",
        C_EDITOR,
        "the source pane's minimum back to 'legible' (24): the fold stops "
        "while the editor is a sliver"),
    Arm("E4", TSHELL,
        "  if before == after:\n    resizeShares(model.layout, model.product, selected)\n",
        "  if before == after:\n",
        C_RESHARE,
        "a resize inside one depth keeps the old size's cell counts: the "
        "source pane falls under its minimum"),
    # --- the capability --------------------------------------------------------
    Arm("C1", MODEL,
        "  for p in allPanes(tree):\n    if not c.canDraw(p):\n"
        "      result.add ReportLeaf(",
        "  for p in allPanes(tree):\n    if not c.canDraw(p) and p != paneVcs:\n"
        "      result.add ReportLeaf(",
        C_REPORTS,
        "the report list silently omits one undrawable pane"),
    Arm("C2", GSHELL,
        "  for slot in arrangement.slots:\n    var leaf = GpuiLeaf(",
        "  for slot in arrangement.slots:\n"
        "    if slot.pane == \"constraints\": continue\n"
        "    var leaf = GpuiLeaf(",
        C_GPUI3,
        "the GPUI window silently omits an undrawable pane from its plan "
        "instead of drawing its report"),
    # --- the format, the table, the translation --------------------------------
    Arm("V1", MODEL,
        "    of 3:\n      result = migrateV3toV4(result)\n",
        "",
        C_V3,
        "the v3 -> v4 step missing from the chain: every v3 document is refused"),
    Arm("T1", DESK,
        "    paneTestResults: DesktopPane(placement: dpLayout,\n"
        "                                 content: Content.TestResults,",
        "    paneTestResults: DesktopPane(placement: dpLayout,\n"
        "                                 content: Content.Constraints,",
        C_TABLE,
        "two panes mapped to one Content ordinal: the table stops being "
        "one-to-one and the inverse lookup lies"),
    Arm("D1", DESK,
        "    if emitted(c): kept.add c",
        "    kept.add c",
        C_FRESH,
        "the root row's percentages computed WITH the runtime-inserted editor: "
        "the desktop would render other shares than the tree's"),
]

DECLARED_SURVIVORS: list = []


@dataclass
class RunResult:
    rc: int
    passed: list = None
    failed: list = None
    ran: bool = True
    hung: bool = False

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def read_source(path: str) -> str:
    return (ROOT / path).read_bytes().decode("utf-8", errors="surrogateescape")


def write_source(path: str, text: str) -> None:
    (ROOT / path).write_bytes(text.encode("utf-8", errors="surrogateescape"))


def lane_flags(lane: str) -> list:
    """The lane's extra flags, read from `ci/lib/test-lane-files.sh` rather
    than spelled here (Verification-Harness-Traps §14)."""
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
         f"test_lane_extra_flags {lane}"],
        cwd=ROOT, capture_output=True, text=True).stdout.split()


def suite_flags(path: str) -> list:
    base = ["--hints:off", "--warnings:off"]
    if path == VM:
        return base + ["--path:src/frontend/viewmodel"]
    if path == GPUI:
        return base + lane_flags("gpui-shell")
    if path == PTY:
        return base + lane_flags("tui-real-terminal")
    return base + lane_flags("tui")


def suite_env() -> dict:
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(SHIM) + ":" + env.get("LD_LIBRARY_PATH", "")
    env["CODETRACER_REPO_ROOT"] = str(ROOT)
    return env


def binary_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat45-mutation-{os.getuid()}"
    base.mkdir(parents=True, exist_ok=True)
    return str(base / stem), str(base / f"nc-{stem}")


def run_one(path: str) -> RunResult:
    res = RunResult(rc=0)
    binary, nimcache = binary_for(path)
    try:
        proc = subprocess.run(
            ["nim", "c", "-r", *suite_flags(path), "--nimcache:" + nimcache,
             "-o:" + binary, path],
            cwd=ROOT, capture_output=True, text=True, timeout=SUITE_TIMEOUT,
            encoding="utf-8", errors="replace", env=suite_env(),
        )
    except subprocess.TimeoutExpired:
        res.hung = True
        res.ran = False
        print(f"      ---- {path}: NO RESULT AFTER {SUITE_TIMEOUT}s ----")
        return res
    out = proc.stdout + proc.stderr
    res.rc = proc.returncode
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print(f"      ---- {path}: no result lines; last 20 lines ----")
        for line in out.splitlines()[-20:]:
            print("      " + line)
    return res


def build(recipe: str) -> bool:
    p = subprocess.run(["just", recipe], cwd=ROOT, capture_output=True,
                       text=True, timeout=SUITE_TIMEOUT)
    if p.returncode != 0:
        print(f"      ---- just {recipe} failed; last 15 lines ----")
        for line in (p.stdout + p.stderr).splitlines()[-15:]:
            print("      " + line)
    return p.returncode == 0


def rebuild_for(path: str) -> bool:
    ok = True
    if path in IN_GPUI_BINARY:
        ok = build("build-gpui") and ok
    if path in IN_TUI_BINARY:
        ok = build("build-tui") and ok
    return ok


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
    r"^[ \t]*(?:const[ \t]+)?(ExpectedAssertions)\*?[ \t]*=[ \t]*(\d+)", re.M)


def declared_counts() -> dict:
    found = {}
    for path in TOUCHED:
        for m in COUNT_CONSTANT.finditer(read_source(path)):
            found[m.group(2)] = f"{path}:{m.group(1)}"
    return found


# The two fold-law cases are generated by a loop over the two shared defaults;
# their printed names are the debug arm of these templates, which must still
# be in the suite for the killer to exist.
LOOP_TEMPLATES = {
    C_LAWS: 'test "the four laws at every depth of the " & name & " default"',
    C_STEPS: ('test "every authored step of the " & name & " order folds '
              'exactly one region"'),
}


def check_killer_names(problems: int) -> int:
    for name in NAMED_CASES:
        where = CASE_SUITE[name]
        source = read_source(where)
        literal = f'test "{name}"' in source
        templated = name in LOOP_TEMPLATES and LOOP_TEMPLATES[name] in source
        if not (literal or templated):
            print(f"KILLER NAME NOT IN {where}: {name!r}")
            problems += 1
    for arm in ARMS:
        if arm.killer not in NAMED_CASES:
            print(f"{arm.id}: killer {arm.killer!r} is not a declared case name")
            problems += 1
    unused = [c for c in NAMED_CASES if c not in {a.killer for a in ARMS}]
    if unused:
        print(f"NAMED CASES NO ARM KILLS: {unused}")
        problems += 1
    return problems


def needle_scan() -> int:
    problems = 0
    counts = declared_counts()
    print("declared count constants in the subjects: "
          f"{', '.join(f'{v}={k}' for k, v in sorted(counts.items())) or 'none'}")
    for arm in ARMS + DECLARED_SURVIVORS:
        if "ExpectedAssertions" in arm.find + arm.replace or \
           "CHECKS:" in arm.find + arm.replace:
            print(f"{arm.id}: NEEDLE QUOTES A COUNT NAME — §10.3")
            problems += 1
        for digits in re.findall(r"\d\d+", arm.find + arm.replace):
            if digits in counts:
                print(f"{arm.id}: NEEDLE QUOTES THE VALUE OF "
                      f"{counts[digits]} ({digits}) — §10.3")
                problems += 1
    armed = {arm.path for arm in ARMS}
    unarmed = [p for p in SUBJECTS if p not in armed]
    if unarmed:
        print(f"SUBJECTS WITH NO ARM: {unarmed}")
        problems += 1
    whys = {}
    for arm in ARMS + DECLARED_SURVIVORS:
        key = arm.why[:60]
        if key in whys:
            print(f"{arm.id}: DUPLICATE justification, shared with {whys[key]}")
            problems += 1
        whys[key] = arm.id
    ids = [a.id for a in ARMS]
    if len(set(ids)) != len(ids):
        print("DUPLICATE ARM ID")
        problems += 1
    for arm in ARMS + DECLARED_SURVIVORS:
        n = read_source(arm.path).count(arm.find)
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
        print(f"CONTROL DIGESTS ABSENT: {CONTROL_HASHES.name} — run "
              "--needle-scan, review the tree, then --record-control-hashes")
        return False
    recorded = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        if line.strip():
            h, p = line.split(None, 1)
            recorded[p.strip()] = h
    ok = True
    for p in TOUCHED:
        if p not in recorded:
            print(f"CONTROL DIGEST ABSENT: {p}")
            ok = False
        elif recorded[p] != digest(p):
            print(f"CONTROL DIGEST MOVED: {p} — re-run --needle-scan BEFORE "
                  "--record-control-hashes (§32)")
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
        print("REFUSING TO RUN: a control digest moved or is absent (§32)")
        return 1
    if not os.environ.get("REPLAY_SERVER_BIN"):
        print("REFUSING TO RUN: REPLAY_SERVER_BIN is not exported")
        return 1

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    wanted = [a for a in ARMS if not only or a.id in only]
    print("\n== control ==")
    if not (build("build-gpui") and build("build-tui")):
        print("CONTROL: the unmutated binaries do not build")
        return 1
    for path in SUITES:
        if not any(CASE_SUITE[a.killer] == path for a in wanted):
            continue
        control = run_one(path)
        if control.failed or not control.ran or control.rc != 0:
            print(f"CONTROL IS NOT GREEN: {path} rc={control.rc} "
                  f"failed={control.failed}")
            return 1
        missing = [c for c in NAMED_CASES
                   if CASE_SUITE[c] == path and c not in control.passed]
        if missing:
            print(f"CONTROL DID NOT RUN {len(missing)} NAMED CASES in {path}: "
                  f"{missing}")
            return 1
        print(f"control {path}: {control.total} cases, 0 failures")

    problems = 0
    killed = 0
    global _ACTIVE
    for arm in wanted:
        original = read_source(arm.path)
        if original.count(arm.find) != 1:
            print(f"{arm.id:<4} HARNESS-FAILURE      needle is not unique")
            problems += 1
            continue
        _ACTIVE = (arm.path, original)
        write_source(arm.path, original.replace(arm.find, arm.replace))
        try:
            suite = CASE_SUITE[arm.killer]
            needs_binary = suite in (GPUI, PTY, THREE)
            if needs_binary and not rebuild_for(arm.path):
                res = RunResult(rc=1, ran=False)
                print("      the mutated binary did not build")
            else:
                res = run_one(suite)
        finally:
            write_source(arm.path, original)
            _ACTIVE = None
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<4} HARNESS-FAILURE      {p} did not "
                          "restore to its control bytes")
                    return 2
            if arm.path in IN_GPUI_BINARY | IN_TUI_BINARY and \
               CASE_SUITE[arm.killer] in (GPUI, PTY, THREE):
                rebuild_for(arm.path)
        if res.hung:
            verdict, note = "HUNG", f"no result in {SUITE_TIMEOUT}s"
            problems += 1
        elif not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif not res.failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif arm.killer in res.failed:
            others = [f for f in res.failed if f != arm.killer]
            verdict = "killed"
            note = arm.killer + (f"  (+{len(others)} more)" if others else "")
            killed += 1
        else:
            verdict = "MISDIRECTED"
            note = f"died in {res.failed[:3]}, not {arm.killer!r}"
            problems += 1
        print(f"{arm.id:<4} {verdict:<20} {note}", flush=True)

    print(f"\n{killed}/{len(wanted)} killed; declared survivors: "
          f"{len(DECLARED_SURVIVORS)}")
    print(f"{problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
