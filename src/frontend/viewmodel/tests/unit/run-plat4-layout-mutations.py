#!/usr/bin/env python3
"""PLAT-4's arming — the mutation harness for the layout command algebra,
auto-hide, the window set, and the session slot that holds a `Layout`.

    python3 src/frontend/viewmodel/tests/unit/run-plat4-layout-mutations.py
    python3 ... --needle-scan
    python3 ... --record-control-hashes
    python3 ... --enumerate-touched
    python3 ... --only=M1,W2

Run from the repository root, inside the dev shell, with `REPLAY_SERVER_BIN`
exported. The cross-renderer suite (the `tui` lane's flags) opens the real
`calc` recording over a real `replay-server` and loads `libgpui_nim_shim`, so
`LD_LIBRARY_PATH` must reach the shim exactly as it must for that lane.

WHY THIS FILE EXISTS
====================
PLAT-4 was verified by a sixteen-arm pass that was RUN and RECORDED in the
milestone's status block but never committed as a harness, so nothing could
re-grade it when a later milestone edited `layout_model.nim`. This is that
pass as a file, extended to the closing pass's own claims (2026-09-26): the
command × shape matrix, the docked split source, the non-defaulting `owned`,
the window set's problem kinds, and the session slot holding a whole `Layout`.

ONE ARM PER CLAIM, each naming the case that must die:

  | claim | arms |
  |---|---|
  | `apply` never mutates its argument | M1 |
  | `loNoOp` is distinct from `loApplied` | M2 |
  | refusals are asserted BY KIND | M3, M18 |
  | §2.4 rule 1 (single-child row/column collapses; stacks exempt) | M4, M5 |
  | §2.4 rule 3 (last pane refused — the single-tab-stack witness) | M6 |
  | §2.4 rule 4 (survivors renormalised) | M7 |
  | undo/redo is a command log of `loApplied` only | M8 |
  | §7: placed AND docked fails validate | M9 |
  | §7: owned but nowhere fails validate | M10 |
  | `owned` has no default — the vacuous call is unspellable | M11 |
  | `revealed` is not persisted | M12 |
  | the v1→v2 migration supplies `docked` | M13 |
  | the floating-panel non-goal: no coordinate on a persisted type | M14 |
  | a DOCKED pane is a legal split source, in one command | M15, M16 |
  | every command × every shape: outcomes AND pane conservation | M17, T1 |
  | the window set: capacity, atomic cross-window move | W1, W2 |
  | the window set reports a layout defect as one | W3, W4 |
  | the session slot's document carries docked panes | H1, H2, H6 |
  | a pre-`docked` app document still restores | H3 |
  | `openSession(Layout)` validates the WHOLE layout, and copies it | H4, H5 |
  | the GPUI shell syncs the whole `Layout` onto the session | G1 |
  | the terminal binding and screen model start from the whole `Layout` | U1, U2 |

THREE VERDICTS, NOT TWO (Verification-Harness-Traps §1): `killed` (the named
case reported [FAILED]), `SURVIVED` (result lines, the named case [OK]),
`HARNESS-FAILURE` (the needle was not unique, the suite did not compile, or it
printed no result lines). A run that prints nothing is never a kill.

EACH ARM RUNS THE SUITE ITS KILLER LIVES IN, and only that suite. The verdict
reads one named case, so a second suite could only add `(+n more)` to a
kill — and running four suites per arm quadruples a grade whose subjects are
compiled from scratch. `MISDIRECTED` still means "the suite went red but not
in the named case".

RESTORATION is from an in-memory snapshot of the subject's bytes, and the
SHA-256 of every subject is compared against the pre-run baseline after each
arm (§32). `--needle-scan` refuses a lost or ambiguous needle; the full run
refuses unless the scan is clean AND every subject's control digest matches
`plat4-layout-mutation-control.sha256`.

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
ROOT = HERE.parents[4]            # .../codetracer

# -- subjects ---------------------------------------------------------------
MODEL = "src/frontend/headless_app/layout_model.nim"
WSET = "src/frontend/headless_app/window_set.nim"
APPM = "src/frontend/headless_app/headless_app.nim"
SHELL = "src/frontend/gpui/app/shell.nim"
TUIAPP = "src/frontend/tui/app/tui_app.nim"

ALG = "src/frontend/viewmodel/tests/unit/test_layout_algebra.nim"
LMOD = "src/frontend/viewmodel/tests/unit/test_layout_model.nim"
APP = "src/frontend/viewmodel/tests/unit/test_headless_app_entrypoint.nim"
CROSS = "src/frontend/tui/tests/test_cross_renderer_panes.nim"

TOUCHED = [MODEL, WSET, APPM, SHELL, TUIAPP, ALG, LMOD, APP, CROSS]
SUITES = [ALG, LMOD, APP, CROSS]

CONTROL_HASHES = HERE / "plat4-layout-mutation-control.sha256"

SUITE_TIMEOUT = int(os.environ.get("CT_P4_SUITE_TIMEOUT", "1800"))
BASE_FLAGS = ["--hints:off", "--warnings:off", "--path:src/frontend/viewmodel"]

RESULT_LINE = re.compile(r"^\s*(?:\x1b\[[0-9;]*m)*\[(OK|FAILED)\]\s*"
                         r"(?:\x1b\[[0-9;]*m)*(.*?)\s*(?:\x1b\[[0-9;]*m)*$")

# ---------------------------------------------------------------------------
# The case names, spelled ONCE.
# ---------------------------------------------------------------------------

C_PURE = "every command leaves the input layout byte-identical"
C_NOOP = "activating a hidden tab applies; activating a visible one is a no-op"
C_NOT_STACK = "a destination that is not a stack is refused by kind"
C_RULE1 = "rule 1: a row left with one child is replaced by that child"
C_RULE1_STACK = "rule 1 does not apply to a stack — one tab is an arrangement"
C_RULE3_MODEL = "rule 3 holds for a CONTAINER root too, not just a collapsed pane one"
C_RULE4 = "rule 4: surviving siblings are renormalised to the same total"
C_UNDO_ONLY = "only loApplied commands enter the log"
C_BOTH = "a pane in the tree AND in docked fails validate"
C_OWNED = "a pane the shell owns that is nowhere fails validate"
C_NO_DEFAULT = ("validate(Layout) has no default owned set — the vacuous call "
                "is unspellable")
C_REVEALED = "revealed is NOT persisted — a restore reopens no overlay"
C_V1 = "a version-1 document migrates forward and restores"
C_NO_COORD = "no persisted layout type carries a position or a size"
C_DOCK_SPLIT = "a DOCKED pane can be split into the tree, in one command"
C_MATRIX = "every (shape, command) cell has the outcome written down for it"
C_WHOLE = "dragging a WHOLE REGION into a tab is refused by kind (§8 decision 1)"
C_SINGLE_WIN = "opening a second window is refused on a declared single-window set"
C_ATOMIC = "a refused insertion discards the removal — the move is atomic"
C_WIN_INVALID = ("a window's OWN invalid layout is reported as that, not as a "
                 "duplicate")
C_WIN_OWNED = "an owned pane that is in NO window is reported by the layout's kind"
C_APP_DOCKED = "a DOCKED pane survives saveLayouts -> restoreLayouts"
C_APP_EMPTY = "every session entry writes docked, even empty"
C_APP_LEGACY = ("a document written before sessions held docked panes still "
                "restores")
C_APP_OPEN = ("a session can be opened over a whole Layout, and a broken one is "
              "refused")
C_SHELL_SYNC = ("a pane DOCKED in a GPUI window reaches the session, its saved "
                "document, and a terminal binding")

NAMED_CASES = [
    C_PURE, C_NOOP, C_NOT_STACK, C_RULE1, C_RULE1_STACK, C_RULE3_MODEL,
    C_RULE4, C_UNDO_ONLY, C_BOTH, C_OWNED, C_NO_DEFAULT, C_REVEALED, C_V1,
    C_NO_COORD, C_DOCK_SPLIT, C_MATRIX, C_WHOLE, C_SINGLE_WIN, C_ATOMIC,
    C_WIN_INVALID, C_WIN_OWNED, C_APP_DOCKED, C_APP_EMPTY, C_APP_LEGACY,
    C_APP_OPEN, C_SHELL_SYNC,
]

# Which suite each case lives in — read by `check_killer_names`, which refuses
# a killer whose spelling is not in that file.
CASE_SUITE = {
    C_RULE3_MODEL: LMOD,
    C_APP_DOCKED: APP, C_APP_EMPTY: APP, C_APP_LEGACY: APP, C_APP_OPEN: APP,
    C_SHELL_SYNC: CROSS,
}


def suite_of(case: str) -> str:
    return CASE_SUITE.get(case, ALG)


@dataclass
class Arm:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str


ARMS = [
    # --- the algebra --------------------------------------------------------
    Arm("M1", MODEL,
        "  var next = layout.clone()\n  let tree = next.tree",
        "  var next = layout\n  let tree = next.tree",
        C_PURE,
        "apply works on the caller's tree instead of a copy: every command "
        "now writes through the argument, and undo-by-replay is unsound"),
    Arm("M2", MODEL,
        "    if tree.isVisible(cmd.activateTarget):\n      return noOp()",
        "    if tree.isVisible(cmd.activateTarget):\n      return appliedTo(next)",
        C_NOOP,
        "activating a visible tab reports loApplied, so a click on the tab "
        "already showing pushes an undo entry"),
    Arm("M3", MODEL,
        "    let destination = parentOf(tree, anchor)\n"
        "    if destination.isNil or destination.kind != lnStack:\n"
        "      return refusedFor(lpTargetNotAStack, cmd.moveBeside)",
        "    let destination = parentOf(tree, anchor)\n"
        "    if destination.isNil or destination.kind != lnStack:\n"
        "      return refusedFor(lpPaneNotPlaced, cmd.moveBeside)",
        C_NOT_STACK,
        "a move onto a non-stack is still refused, but for the WRONG reason "
        "— the refusal-by-kind claim, not the refusal itself"),
    Arm("M4", MODEL,
        "  if kept.len == 1:\n    # Rule 1.",
        "  if false:\n    # Rule 1.",
        C_RULE1,
        "rule 1 switched off: a row left with one child stays a single-child "
        "row, which validate calls a hole"),
    Arm("M5", MODEL,
        "  if node.kind == lnStack:\n"
        "    # A stack with one tab is an ordinary arrangement, not a hole: rule 1 does",
        "  if node.kind == lnStack and kept.len > 1:\n"
        "    # A stack with one tab is an ordinary arrangement, not a hole: rule 1 does",
        C_RULE1_STACK,
        "the stack exemption dropped: a one-tab stack collapses to its tab "
        "and the tab strip a drop was aimed at disappears"),
    Arm("M6", MODEL,
        "  if allPanes(node).len <= 1:\n    return false\n"
        "  discard detachPane(node, kind)",
        "  discard detachPane(node, kind)",
        C_RULE3_MODEL,
        "the rule-3 gate deleted from the legacy mutator — the audit's "
        "finding that only the single-tab STACK witness can see this"),
    Arm("M7", MODEL,
        "  let factor = targetSum / have\n  if abs(factor - 1.0) < 1e-12:\n"
        "    return",
        "  let factor = targetSum / have\n  if true:\n    return",
        C_RULE4,
        "rule 4 switched off: removing a neighbour changes the container's "
        "total, so saved weights stop meaning the same fraction"),
    Arm("M8", MODEL,
        "  result = apply(h.value, cmd)\n  if result.kind != loApplied:\n"
        "    return",
        "  result = apply(h.value, cmd)\n  if result.kind == loRefused:\n"
        "    return",
        C_UNDO_ONLY,
        "a no-op enters the undo log: the next undo shows the same screen"),
    Arm("M9", MODEL,
        "    if layout.tree.contains(d.pane):\n"
        "      result.add(LayoutProblem(kind: lpPaneBothPlacedAndDocked,",
        "    if false:\n"
        "      result.add(LayoutProblem(kind: lpPaneBothPlacedAndDocked,",
        C_BOTH,
        "validate no longer sees a pane in the tree and on a strip at once"),
    Arm("M10", MODEL,
        "  for p in owned:\n"
        "    if not layout.tree.contains(p) and layout.dockedIndex(p) < 0:",
        "  for p in owned:\n"
        "    if false:",
        C_OWNED,
        "the owned-but-nowhere check becomes vacuous for every owned set"),
    Arm("M11", MODEL,
        "proc validate*(layout: Layout; owned: set[PaneKind]): seq[LayoutProblem] =",
        "proc validate*(layout: Layout; owned: set[PaneKind] = {}): seq[LayoutProblem] =",
        C_NO_DEFAULT,
        "the audit's recorded residual, restored: owned defaults to the empty "
        "set and an unqualified call is vacuous without saying so"),
    Arm("M12", MODEL,
        "  result[\"order\"] = %d.order\n",
        "  result[\"order\"] = %d.order\n  result[\"revealed\"] = %d.revealed\n",
        C_REVEALED,
        "the transient overlay flag leaks into the persisted document"),
    Arm("M13", MODEL,
        "  result = copy(doc)\n  result[\"docked\"] = newJArray()\n",
        "  result = copy(doc)\n",
        C_V1,
        "the v1->v2 step forgets to supply docked, so every v1 document is "
        "refused as missing a field after migration"),
    Arm("M14", MODEL,
        "  DockedPane* = object\n",
        "  DockedPane* = object\n    x*: int\n",
        C_NO_COORD,
        "a coordinate on a persisted type: the first field a floating panel "
        "would need"),
    Arm("M15", MODEL,
        "      if dockedAt >= 0 and not moving.isNil:",
        "      if dockedAt >= 0:",
        C_DOCK_SPLIT,
        "the closing pass's decision reverted: a docked source is refused "
        "again and the strip-to-edge drag has no one-command spelling"),
    Arm("M16", MODEL,
        "          movedTitle = next.docked[dockedAt].title\n"
        "        next.docked.delete(dockedAt)",
        "          movedTitle = next.docked[dockedAt].title",
        C_DOCK_SPLIT,
        "the docked source is split into the tree AND left on its strip — "
        "placed and docked at once, §3.3's invariant broken by a command"),
    Arm("M17", MODEL,
        "                                   children: @[existing, moved]))",
        "                                   children: @[existing]))",
        C_MATRIX,
        "merging onto a bare pane drops the moved pane on the floor — a pane "
        "the matrix's conservation law must find missing"),
    Arm("M18", MODEL,
        "      return refusedFor(lpStackChildNotPane, cmd.mergedPane)",
        "      return refusedFor(lpDuplicatePane, cmd.mergedPane)",
        C_WHOLE,
        "the whole-region drag is still refused but under a kind that "
        "describes a different defect"),
    Arm("T1", ALG,
        'const MatrixShapes = ["bare pane", "two-pane row", "stacked", '
        '"two stacks",\n                      "deep tree", "with docked"]',
        'const MatrixShapes = ["bare pane", "two-pane row", "stacked", '
        '"two stacks",\n                      "deep tree", "deep tree"]',
        C_MATRIX,
        "THE INSTRUMENT: the matrix silently loses its docked shape while "
        "keeping its size; the per-row table must notice"),
    # --- the window set -----------------------------------------------------
    Arm("W1", WSET,
        "  if ws.capacity == wcSingleWindow:\n"
        "    return refuse(wpSingleWindowOnly, window = some(id))",
        "  if false:\n"
        "    return refuse(wpSingleWindowOnly, window = some(id))",
        C_SINGLE_WIN,
        "a declared single-window front-end accepts a second window"),
    Arm("W2", WSET,
        "  let insertion = apply(ws.windows[dstAt].layout,",
        "  discard ws.windows[srcAt].layout.tree.removePane(pane)\n"
        "  let insertion = apply(ws.windows[dstAt].layout,",
        C_ATOMIC,
        "the removal written through the SHARED tree ref before the insertion "
        "is known to succeed — the audit's in-place arm, not a shadowed clone"),
    Arm("W3", WSET,
        "      result.add(WindowSetProblem(kind: wpLayoutInvalid, window: some(w.id),",
        "      result.add(WindowSetProblem(kind: wpPaneInTwoWindows, window: some(w.id),",
        C_WIN_INVALID,
        "a window's own single-child row is reported as a cross-window "
        "duplicate again"),
    Arm("W4", WSET,
        "        kind: wpLayoutInvalid, window: none(WindowId), pane: some(p),",
        "        kind: wpUnknownWindow, window: none(WindowId), pane: some(p),",
        C_WIN_OWNED,
        "an owned pane found in no window is reported as an unknown window id"),
    # --- the session slot ---------------------------------------------------
    Arm("H1", APPM,
        "      for d in s.layout.docked:\n        docked.add(d.toJson())",
        "      for d in s.layout.docked:\n        discard d.toJson()",
        C_APP_DOCKED,
        "saveLayouts writes an empty docked list: the pane is in neither "
        "half of the document, exactly the pre-closing defect"),
    Arm("H2", APPM,
        "      if entry.hasKey(\"docked\"): entry[\"docked\"] else: newJArray()",
        "      newJArray()",
        C_APP_DOCKED,
        "restoreLayouts ignores the docked list it was handed"),
    Arm("H3", APPM,
        "      if entry.hasKey(\"docked\"): entry[\"docked\"] else: newJArray()",
        "      entry[\"docked\"]",
        C_APP_LEGACY,
        "a document from before the slot held a Layout is no longer readable"),
    Arm("H4", APPM,
        "  let problems = source.validate({})\n  if problems.len > 0:\n"
        "    raiseApp(\"openSession was given an invalid layout: \"",
        "  let problems = source.tree.validate()\n  if problems.len > 0:\n"
        "    raiseApp(\"openSession was given an invalid layout: \"",
        C_APP_OPEN,
        "openSession validates only the tree, so a layout whose pane is "
        "placed AND docked opens"),
    Arm("H5", APPM,
        "  openSessionWith(app, backend, title, layout.clone(), clock, adopt)",
        "  openSessionWith(app, backend, title, layout, clock, adopt)",
        C_APP_OPEN,
        "the Layout overload aliases the caller's tree into the slot"),
    Arm("H6", APPM,
        "      entry[\"docked\"] = docked\n",
        "",
        C_APP_EMPTY,
        "saveLayouts omits the docked key: each entry reverts to the old "
        "tree-only shape, so gaining a docked pane changes the document's shape"),
    # --- the GPUI shell -----------------------------------------------------
    Arm("G1", SHELL,
        "    session.layout = slot.layout.clone()",
        "    session.layout = initLayout(slot.layout.tree.clone())",
        C_SHELL_SYNC,
        "the sync copies only the tree, as it did while the slot held a "
        "LayoutNode — a window's docked pane vanishes from the session"),
    # --- the terminal -------------------------------------------------------
    Arm("U1", TUIAPP,
        "      initLayout(profileLayout(selected))\n    else: active.layout\n",
        "      initLayout(profileLayout(selected))\n"
        "    else: initLayout(active.layout.tree)\n",
        C_SHELL_SYNC,
        "the terminal binding is seeded from the session's TREE, as it was "
        "while the slot held a LayoutNode — its docked panes are dropped"),
    Arm("U2", TUIAPP,
        "             else: active.layout.docked),",
        "             else: @[]),",
        C_SHELL_SYNC,
        "the unbound screen model ignores the session's docked list, so a "
        "docked pane is on no strip and in no region"),
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
    if path == CROSS:
        # The `tui` lane's flags: the suite links the terminal projection AND
        # the GPUI shim, and opens the real `calc` recording.
        return ["--hints:off", "--warnings:off", *lane_flags("tui")]
    return list(BASE_FLAGS)


def binary_for(path: str) -> tuple:
    stem = Path(path).stem
    base = Path(tempfile.gettempdir()) / f"plat4-mutation-{os.getuid()}"
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
            encoding="utf-8", errors="replace",
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


def check_killer_names(problems: int) -> int:
    for name in NAMED_CASES:
        where = suite_of(name)
        # `liveTest` is `test_cross_renderer_panes.nim`'s wrapper around
        # `test` for cases that need the recording; it prints the same
        # `[OK]`/`[FAILED]` line under the same name.
        source = read_source(where)
        if f'test "{name}"' not in source and f'liveTest "{name}"' not in source:
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
    if not counts:
        print("REFUSING: no declared count constant was found in any subject, "
              "so §10.3's rule would pass vacuously")
        problems += 1
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
    # The suites are armed through their killers; the product subjects and
    # the matrix's own table must each carry an arm of their own.
    unarmed = [p for p in (MODEL, WSET, APPM, SHELL, ALG) if p not in armed]
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

    baseline = {p: digest(p) for p in TOUCHED}
    install_restore_on_signal()

    wanted = [a for a in ARMS if not only or a.id in only]
    print("\n== control ==")
    for path in SUITES:
        if not any(suite_of(a.killer) == path for a in wanted):
            continue
        control = run_one(path)
        if control.failed or not control.ran or control.rc != 0:
            print(f"CONTROL IS NOT GREEN: {path} rc={control.rc} "
                  f"failed={control.failed}")
            return 1
        missing = [c for c in NAMED_CASES
                   if suite_of(c) == path and c not in control.passed]
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
            res = run_one(suite_of(arm.killer))
        finally:
            write_source(arm.path, original)
            _ACTIVE = None
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{arm.id:<4} HARNESS-FAILURE      {p} did not "
                          "restore to its control bytes")
                    return 2
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
