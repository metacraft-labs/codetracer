#!/usr/bin/env python3
"""The mutation harness for shared input routing
(Input-Routing-And-Keymaps.md): operation tables, the pointer keymap, the
overlays' rows, the one route from a resolved name to its procedure, and the
source gate that keeps views thin.

Each arm plants ONE defect (an operation table entry pointing at the wrong
procedure, a scope precedence inverted, a decoder dropping a modifier, ...);
REBUILDS the shipped `codetracer-tui` / `codetracer-gpui` / desktop when the
defect is compiled into a binary an arm is graded through; runs the suites that
must catch it; and requires RED with the failure the first run recorded
(`plat64-input-routing-mutation-because.json`, derived with `--derive`).

The discipline is the other comparator harnesses': committed control digests
over subjects AND suites (§16c), a needle scan that gates re-recording (§39a),
`because` derived from a run, rc 124 is a hang (§1), per-arm restore
verification, and `ci/lib/harness_guard.py`'s argument rule before anything is
touched.

The builds run `$PLAT64_BUILD_TUI` / `$PLAT64_BUILD_GPUI` /
`$PLAT64_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`. The desktop arms are graded by the Electron specs, run by
`$PLAT64_DESKTOP_TEST` when set (with the spec in `$PLAT64_DESKTOP_SPEC`,
relative to `src/tests/gui`), else `npx playwright test` in `src/tests/gui`.

No mocks: the suites graded here run the shipped tables and router over real
values, the shipped terminal binary on a real pty against a real recording and
`replay-server`, the shipped GPUI binary's window plan, and the real Electron app.

Usage:
    run-plat64-input-routing-mutations.py [--only V1,T1] [--derive]
    run-plat64-input-routing-mutations.py --needle-scan
    run-plat64-input-routing-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat64-input-routing-mutation-control.sha256"
BECAUSE = HERE / "plat64-input-routing-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat64-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
TABLE = "src/frontend/viewmodel/input/operation_table.nim"
ROUTER = "src/frontend/viewmodel/keymap/keymap_router.nim"
KEYNAMES = "src/common/key_names.nim"
POINTER = "src/frontend/viewmodel/keymap/pointer_rows.nim"
OVERLAY = "src/frontend/viewmodel/keymap/overlay_rows.nim"
CLIENT = "src/frontend/viewmodel/keymap/client_actions.nim"
CLICKS = "src/frontend/headless_app/pane_clicks.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
MOUSE = "src/frontend/tui/app/input/mouse.nim"
GMAIN = "src/frontend/gpui/main.nim"
GKEYS = "src/frontend/gpui/app/gpui_keys.nim"
FIELD = "src/frontend/viewmodel/views/field_keys.nim"
KEYROUTER = "src/frontend/ui/key_router.nim"
GATE = "ci/test/input-routing-gate.sh"

# Suites.
MAP = "src/frontend/tui/tests/test_plat64_operation_mapping.nim"
TABLES = "src/frontend/tui/tests/test_plat64_operation_tables.nim"
CENSUS = "src/frontend/tui/tests/test_plat64_reachability.nim"
UNIT = "src/frontend/viewmodel/tests/unit/test_plat64_pointer_keymap.nim"
LAYERS = "src/frontend/viewmodel/tests/unit/test_plat68_layers.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat64_input_routing_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat64_gpui_plan.nim"
SPEC = "src/tests/gui/tests/keymaps/plat64-input-routing.spec.ts"
GATETEST = "ci/test/input-routing-gate-test.sh"
TOPBAR = "src/frontend/tui/tests/test_plat48_top_bar.nim"
VPSPEC = "src/tests/gui/tests/frame-viewer/video-player-keymap-rows.spec.ts"

SUBJECTS = [TABLE, ROUTER, KEYNAMES, POINTER, OVERLAY, CLIENT, CLICKS, RUNTIME,
            MOUSE, GMAIN, GKEYS, FIELD, KEYROUTER, GATE]
SUITES = [MAP, TABLES, CENSUS, UNIT, LAYERS, PTY, PLAN, SPEC, GATETEST, TOPBAR,
          VPSPEC]

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the one route ---------------------------------------------------------
    ("O1", [(TABLE, "  for table in hub.tables:\n    if not table.isActive or call.name notin table.entries:",
             "  for i in countdown(hub.tables.high, 0):\n    let table = hub.tables[i]\n    if not table.isActive or call.name notin table.entries:")],
     [(MAP, None)],
     "§3: the walk is outermost first: a scope precedence inverted"),
    ("O2", [(TABLE, "      if not answer.enabled:",
             "      if false:")],
     [(MAP, None), (TABLES, None)],
     "IR-6: a disabled operation runs"),
    ("O3", [(TABLE, "    if entry.action(call, ctx):\n      return InvokeResult(kind: oiRan, table: table.owner)",
             "    discard entry.action(call, ctx)\n    return InvokeResult(kind: oiRan, table: table.owner)")],
     [(MAP, None)],
     "§3: a procedure that declines ends the walk"),
    ("O4", [(TABLE, "    if not table.isActive or call.name notin table.entries:",
             "    if call.name notin table.entries:")],
     [(MAP, None), (TABLES, None)],
     "§3: an overlay's table holds while it is closed"),
    ("O5", [(TABLE, "  if not isKnownOperation(name):",
             "  if false:")],
     [(MAP, None)],
     "§3.1: a name no catalogue has binds"),
    # ---- the mapping table ----------------------------------------------------
    ("M1", [(CLIENT, '    ("video-player.cancel-picker", "videoPlayerCancelPicker"),', "")],
     [(MAP, None)],
     "§3.2: a ClientAction is mapped to nothing"),
    ("M2", [(CLICKS, '    caConstraintCopyName: "constraints.copy-name",',
             '    caConstraintCopyName: "constraints.go-to-source",')],
     [(MAP, None)],
     "§3.2: two ContextActions run one operation"),
    ("M3", [(CLICKS, '    ("K67", "constraints.go-to-source"), ("K68", "context-menu.open"),',
             '    ("K67", "constraints.no-such"), ("K68", "context-menu.open"),')],
     [(MAP, None)],
     "§5.1: an element declares an operation that does not exist"),
    # ---- the pointer keymap ---------------------------------------------------
    ("P1", [(ROUTER, "  for source in [lsUser, lsBase]:\n    let km = if source == lsUser: router.userByTable.getOrDefault(PointerTable)",
             "  for source in [lsBase, lsUser]:\n    let km = if source == lsUser: router.userByTable.getOrDefault(PointerTable)")],
     [(UNIT, None), (PLAN, None)],
     "§5.1: the base's pointer row beats the user's"),
    ("P2", [(POINTER, '    BaseRow(chords: "Click", operation: "calltrace.go-to-call",',
             '    BaseRow(chords: "Click", operation: "calltrace.toggle-call",')],
     [(UNIT, None)],
     "§5.1: a call row declares the wrong operation"),
    ("P3", [(ROUTER, "  let table = if r.chords.len > 0 and isPointerChord(r.chords[0]): PointerTable\n              else: tableOfOperation(r.operation)",
             "  let table = tableOfOperation(r.operation)")],
     [(UNIT, None)],
     "§4.3: a user's pointer row lands in a key table and never resolves"),
    ("P4", [(ROUTER, "    if not isPointerChord(c) and not legacyEncodable(c): return false",
             "    if not legacyEncodable(c): return false")],
     [(UNIT, None)],
     "a terminal with no extended keys refuses a gesture as undeliverable"),
    ("P5", [(KEYNAMES, '    "application": "Menu", "click": "Click", "doubleclick": "DoubleClick",',
             '    "application": "Menu", "click": "", "doubleclick": "DoubleClick",')],
     [(UNIT, None)],
     "a written gesture is not read"),
    # ---- the decoders ---------------------------------------------------------
    ("D1", [(RUNTIME, "  pointerGesture(event.buttonOf, event.ctrl, event.shift, event.alt)",
             "  pointerGesture(event.buttonOf, false, event.shift, event.alt)")],
     [(PTY, None)],
     "the terminal's gesture drops Ctrl: the rebound press never fires"),
    ("D2", [(GMAIN, "                  of gbLeft: prPrimary), c.ctrl, false, c.alt)",
             "                  of gbLeft: prPrimary), false, false, c.alt)")],
     [(PLAN, None)],
     "GPUI's gesture drops Ctrl: the rebound press never fires"),
    ("D5", [(KEYNAMES, "  if ctrl: mods.incl kmodCtrl\n  if shift: mods.incl kmodShift\n  if alt: mods.incl kmodAlt\n  if meta: mods.incl kmodMeta",
             "  if shift: mods.incl kmodShift\n  if alt: mods.incl kmodAlt\n  if meta: mods.incl kmodMeta")],
     [(UNIT, None)],
     "the one gesture spelling drops Ctrl on every front-end"),
    ("D3", [(MOUSE, "  event.ctrl = (code and 16) != 0", "  event.ctrl = false")],
     [(PTY, None)],
     "the SGR decoder drops Ctrl"),
    ("D4", [(GKEYS, 'if "alt" in modifiers: result.incl kmodAlt', 'discard')],
     [(PLAN, None)],
     "GPUI's key decoder drops Alt: the user's chord never arrives"),
    # ---- table entries pointing at the wrong procedure -------------------------
    ("T1", [(RUNTIME, 'programMenu.bindOp("menu.focus-next", act(rt.app.menu.moveHighlight(1)))',
             'programMenu.bindOp("menu.focus-next", act(rt.app.menu.moveHighlight(-1)))')],
     [(TABLES, None)],
     "the terminal's menu.focus-next runs the previous row's procedure"),
    ("T2", [(RUNTIME, 'onTarget("calltrace.go-to-call"):\n    outcome.jumpsToCall = true',
             'onTarget("calltrace.go-to-call"):\n    outcome.togglesCall = true')],
     [(PTY, None)],
     "the terminal's call-row entry toggles instead of going to the call"),
    ("T3", [(RUNTIME, "                   if rt.hasDebugSession: AlwaysEnabled",
             "                   if true: AlwaysEnabled")],
     [(TABLES, None)],
     "IR-6: Stop with no session loses its table's reason"),
    ("T4", [(GMAIN, 'programMenu.bindOp("menu.focus-next", act do:\n    gMenu.moveHighlight(1)',
             'programMenu.bindOp("menu.close", act do:\n    gMenu.moveHighlight(1)')],
     [(PLAN, None)],
     "GPUI's menu.focus-next is not bound"),
    ("T5", [(GMAIN, '  runElementGesture(r, gesture, paneCalltrace, (if onToggle: ekToggle else: ekRow),',
             '  runElementGesture(r, "Click", paneCalltrace, (if onToggle: ekToggle else: ekRow),')],
     [(PLAN, None)],
     "GPUI's call-row press loses its modifiers on the way to the router"),
    # ---- the overlays' rows ----------------------------------------------------
    ("R1", [(OVERLAY, '    BaseRow(chords: "Down", operation: "menu.focus-next", table: MenuTable),',
             '    BaseRow(chords: "Down", operation: "menu.focus-previous", table: MenuTable),')],
     [(UNIT, None)],
     "Down in the menu runs the wrong operation"),
    ("R2", [(RUNTIME, '  rt.want(MenuTable, "window", "", rt.app.menu.isOpen)', "")],
     [(TOPBAR, None)],
     "the terminal never pushes the menu's layer"),
    # ---- the Video Player's rows and presses ----------------------------------
    ("V1", [(OVERLAY, '    BaseRow(chords: "j", operation: "video-player.rewind", table: VideoPlayerTable),',
             '    BaseRow(chords: "j", operation: "video-player.fast-forward", table: VideoPlayerTable),')],
     [(UNIT, None)],
     "a Video Player row is bound to the wrong operation"),
    ("V2", [(OVERLAY, '    BaseRow(chords: "Enter", operation: "video-player.commit-pick", table: VideoMagnifierTable),',
             '    BaseRow(chords: "Enter", operation: "video-player.cancel-picker", table: VideoMagnifierTable),')],
     [(UNIT, None)],
     "Enter in the magnifier cancels the pick instead of making it"),
    ("V3", [(RUNTIME, "        discard rt.pressElement(event, paneVideoPlayer, ekButton,\n"
                      "                                VideoPlayerOperations[b.action],\n"
                      "                                ContextTarget(pane: paneVideoPlayer), outcome)",
             "        rt.playerAction(b.action, outcome)")],
     [(TABLES, None)],
     "a transport button's press bypasses the router: a user's row cannot take it"),
    ("V4", [(RUNTIME, '  rt.want(TerminalInfoTable, "window", "", rt.terminalInfo.open)\n  rt.syncVideoPlayerLayers()',
             '  rt.want(TerminalInfoTable, "window", "", rt.terminalInfo.open)')],
     [(TABLES, None)],
     "the terminal never pushes the picker's layers: the magnifier's keys step frames"),
    ("P6", [(POINTER, '    BaseRow(chords: "Click", operation: "point-list.select",',
             '    BaseRow(chords: "Click", operation: "vcs.toggle-commit",')],
     [(UNIT, None)],
     "§5.1: a Points row declares another pane's operation"),
    ("V5", [(KEYROUTER, "  syncVideoPickerLayer()\n  let path = desktopScopePath()",
             "  let path = desktopScopePath()")],
     [(VPSPEC, None)],
     "the desktop never pushes the picker's layer: Escape does not cancel it"),
    # ---- the top bar, a tab's pin and a docked label ----------------------------
    ("B1", [(RUNTIME, '  of thTab:\n    press(ekTab, "session-tabs.activate", hit.index)',
             '  of thTab:\n'
             '    let at = rt.app.shell.stripTabAt(rt.app.welcomeTabs, hit.index)\n'
             '    if at.isWelcome: rt.showWelcomeTab(at.welcomeIndex, outcome)\n'
             '    else: rt.showSessionTab(at.sessionIndex, outcome)')],
     [(TABLES, None)],
     "the terminal's session-tab press bypasses the router: a user's row cannot take it"),
    ("B2", [(RUNTIME, '    discard rt.pressElement(event, pane, ekButton, "layout.toggle-docked-pane",\n'
                      '                            ContextTarget(pane: pane), outcome)',
             '    rt.labelAction = binding.toggleDockOpen(pane)')],
     [(TABLES, None)],
     "the terminal's docked label press bypasses the router"),
    ("B3", [(GMAIN, '  of gtTab:\n    press(ekTab, "session-tabs.activate", hit.index)',
             '  of gtTab:\n'
             '    let at = mainShell().app.stripTabAt(gWelcomeTabs, hit.index)\n'
             '    if at.isWelcome: showWelcomeTab(r, at.welcomeIndex)\n'
             '    else: showSessionTab(r, at.sessionIndex)')],
     [(PLAN, None)],
     "GPUI's session-tab press bypasses the router: a user's row cannot take it"),
    ("B4", [(GMAIN, '  of gtTabAdd:\n    press(ekButton, "session-tabs.new")',
             '  of gtTabAdd:\n    gHoverTabAdd = false\n    openWelcomeTab(r)')],
     [(PLAN, None)],
     "GPUI's + press bypasses the router"),
    # ---- the desktop -----------------------------------------------------------
    ("W1", [(KEYROUTER, '  if res.kind == erOperation and res.layer.startsWith("user:"):\n    if runDesktopOperation(res) == nkHandled:',
             '  if false:\n    if runDesktopOperation(res) == nkHandled:')],
     [(SPEC, None)],
     "the desktop ignores a user's pointer row"),
    ("W2", [(KEYROUTER, '    pointerGesture(button, ev.ctrlKey.to(bool), ev.shiftKey.to(bool),',
             '    pointerGesture(button, false, ev.shiftKey.to(bool),')],
     [(SPEC, None)],
     "the desktop's gesture drops Ctrl"),
    ("W3", [(KEYROUTER, "      swallowNextClick = true\n", "")],
     [(SPEC, None)],
     "the desktop runs a user's pointer row and the element's own click too"),
    # ---- the source gate -------------------------------------------------------
    ("G1", [(GATE, 'if stack and KEYISH.search(stack[-1][1]):', 'if False:')],
     [(GATETEST, None)],
     "IR-1: a `case` over a key name passes the gate"),
    ("G2", [(GATE, '    if have > allowed:', '    if False:')],
     [(GATETEST, None)],
     "IR-1: the gate never reddens"),
    ("G3", [(GATE, '    elif have < allowed:', '    elif False:')],
     [(GATETEST, None)],
     "IR-1: a stale ledger entry passes"),
]

DECLARED_SURVIVORS = set()

IN_BINARY = {TABLE, ROUTER, KEYNAMES, POINTER, OVERLAY, CLIENT, CLICKS, RUNTIME, MOUSE}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {TABLE, ROUTER, KEYNAMES, POINTER, OVERLAY, CLIENT, CLICKS, GMAIN, GKEYS}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {ROUTER, KEYNAMES, POINTER, OVERLAY, CLIENT, FIELD, KEYROUTER}
  # Subjects compiled into the desktop's bundle.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC, VPSPEC}
SHELL_SUITES = {GATETEST}


def path_of(rel):
    return REPO / rel


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(path_of(rel))


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    if suite == PTY:
        return lane_flags("tui-real-terminal")
    if suite.startswith("src/frontend/tui/"):
        return lane_flags("tui")
    if suite.startswith("src/frontend/gpui/"):
        return lane_flags("gpui-shell") + ["--path:src/frontend/viewmodel"]
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    for arm_id, edits, *_ in ARMS:
        for rel, find, _ in edits:
            text = path_of(rel).read_text()
            n = text.count(find)
            if n != 1:
                print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
                ok = False
                continue
            end = text.index(find) + len(find)
            if end < len(text) and text[end] not in "\r\n":
                print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
                ok = False
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat64-input-routing-mutations.py — the\n"
                "# subjects AND the suites the arms are graded by (§16c).\n"
                "# Refreshed with --record-control-hashes, gated by the\n"
                "# needle scan (§39a).\n")
        for rel in SUBJECTS + SUITES:
            f.write(f"{sha(rel)}  {rel}\n")
    print(f"recorded {len(SUBJECTS) + len(SUITES)} control digests")
    return 0


def controls_match():
    if not CONTROL.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        digest, rel = line.split("  ", 1)
        if sha(rel) != digest:
            print(f"CONTROL DIGEST MOVED: {rel}")
            ok = False
    return ok


def build_with(env_var, recipe):
    cmd = os.environ.get(env_var)
    argv = ["bash", "-c", cmd] if cmd else ["just", recipe]
    p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                       timeout=TIMEOUT)
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-2000:])
    return p.returncode == 0


def build_binary():
    return build_with("PLAT64_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT64_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT64_BUILD_DESKTOP", "build-once")


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the screen;
    the recorded cause keeps the condition and drops the snapshot."""
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def run_spec(suite):
    """The Electron spec: GREEN on rc 0, else RED on its first expectation."""
    cmd = os.environ.get("PLAT64_DESKTOP_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["npx", "playwright", "test", suite.split("src/tests/gui/", 1)[1],
         "--reporter=line"]
    cwd = REPO if cmd else REPO / "src/tests/gui"
    # The spec a `$PLAT64_DESKTOP_TEST` command is to run, relative to
    # src/tests/gui (there is more than one desktop suite).
    env = dict(os.environ,
               PLAT64_DESKTOP_SPEC=suite.split("src/tests/gui/", 1)[1])
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [ln.strip() for ln in plain.splitlines()
             if ln.strip().startswith("Error:")][:1]
    return "RED", first


def run_shell_suite(suite):
    """A shell contract suite: GREEN on rc 0, else RED on its first FAIL line."""
    try:
        p = subprocess.run(["bash", suite], cwd=REPO, capture_output=True,
                           text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    if p.returncode == 0:
        return "GREEN", []
    first = [ln.strip() for ln in p.stdout.splitlines() if "FAIL" in ln][:1]
    return "RED", first


def run_suite(suite, test_filter):
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
    if suite in SHELL_SUITES:
        return run_shell_suite(suite)
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + suite_flags(suite) + [suite]
    if test_filter:
        cmd.append(test_filter)
    try:
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [portable_cause(ln.strip().split("Check failed: ", 1)[1])
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        ran = out.count("[OK]")
        return ("GREEN", failures) if ran > 0 else ("RAN-NOTHING", [])
    # A base that does not hold together does not LOAD: the suite dies before
    # its first case, on the loader's own diagnostic — a kill by the
    # product's check, graded as one, on that line.
    refused = [ln.strip() for ln in out.splitlines()
               if "BaseRowError" in ln and "unhandled exception" in ln.lower()]
    if refused:
        return "RED", refused[:1]
    if not failures and "Error:" in out and "[FAILED]" not in out:
        return "DID-NOT-COMPILE", failures
    if not failures:
        failures = [portable_cause(ln.strip()) for ln in out.splitlines()
                    if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
    return "RED", failures


def grade(suites):
    first, verdict = "", "GREEN"
    for s, flt in suites:
        v, f = run_suite(s, flt)
        if v in ("HUNG", "DID-NOT-COMPILE", "RAN-NOTHING"):
            return v, ""
        if v == "RED":
            verdict = "RED"
            if not first and f:
                first = f[0]
    return verdict, first


sys.path.insert(0, str(REPO / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main():
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    a = ap.parse_args()
    os.chdir(REPO)
    if a.needle_scan:
        return 0 if needle_scan() else 1
    if a.record_control_hashes:
        return record_controls()
    if not needle_scan() or not controls_match():
        print("the tree is not at the control bytes; nothing was mutated.")
        return 3
    only = set(filter(None, a.only.split(",")))
    selected = [arm for arm in ARMS if not only or arm[0] in only]
    needs_binary = any(s in PTY_SUITES for arm in selected for s, _ in arm[2])
    needs_gpui = any(s in GPUI_SUITES for arm in selected for s, _ in arm[2])
    needs_desktop = any(s in DESKTOP_SUITES for arm in selected
                        for s, _ in arm[2])
    binary_digest = gpui_digest = None
    if needs_binary:
        if not build_binary():
            print("ABORT: the unmutated binary does not build.")
            return 1
        binary_digest = sha_path(BIN)
    if needs_gpui:
        if not build_gpui():
            print("ABORT: the unmutated GPUI binary does not build.")
            return 1
        gpui_digest = sha_path(GPUI_BIN)
    if needs_desktop and not build_desktop():
        print("ABORT: the unmutated desktop does not build.")
        return 1
    graded = sorted({(s, flt) for arm in selected for s, flt in arm[2]})
    for s, flt in graded:
        v, f = run_suite(s, flt)
        if v != "GREEN":
            print(f"ABORT: the baseline of {s} is {v}: {f[:1]}")
            return 1
    print(f"baseline GREEN ({len(graded)} suite run(s))")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, edits, suites, what in selected:
        files = sorted({rel for rel, _, _ in edits})
        backups = {}
        for rel in files:
            path = path_of(rel)
            backups[rel] = path.with_name(path.name + ".plat64bak")
            shutil.copy2(path, backups[rel])
        try:
            for rel, find, replace in edits:
                path = path_of(rel)
                path.write_text(path.read_text().replace(find, replace, 1))
            built = True
            if any(s in PTY_SUITES for s, _ in suites) and \
                    any(r in IN_BINARY for r in files):
                built = build_binary()
            if built and any(s in GPUI_SUITES for s, _ in suites) and \
                    any(r in IN_GPUI for r in files):
                built = build_gpui()
            if built and any(s in DESKTOP_SUITES for s, _ in suites) and \
                    any(r in IN_DESKTOP for r in files):
                built = build_desktop()
            verdict, first = grade(suites) if built else ("DID-NOT-COMPILE", "")
        finally:
            for rel in files:
                shutil.move(backups[rel], path_of(rel))
                if sha(rel) != digests[rel]:
                    print(f"ABORT: restore of {rel} failed after {arm_id}.")
                    return 1
        derived[arm_id] = first
        if arm_id in DECLARED_SURVIVORS:
            ok = verdict == "GREEN"
            mark = "SURVIVED (declared)" if ok else f"MISDIRECTED ({verdict})"
        elif verdict == "RED":
            want = because.get(arm_id)
            ok = a.derive or want is None or want == first
            mark = "KILLED" if ok else f"KILLED BY THE WRONG CHECK: {first!r}"
        else:
            ok = False
            mark = verdict if verdict != "GREEN" else "SURVIVED — NOT ENFORCED"
        print(f"  {arm_id:<4} {mark:<30} {what}", flush=True)
        if a.derive or not ok:
            print(f"       because: {first!r}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s)")
    if binary_digest is not None:
        if not build_binary() or sha_path(BIN) != binary_digest:
            print("FAIL: the binary rebuilt from the restored tree differs "
                  "from the one the run started with.")
            return 1
    if gpui_digest is not None:
        if not build_gpui() or sha_path(GPUI_BIN) != gpui_digest:
            print("FAIL: the GPUI binary rebuilt from the restored tree "
                  "differs from the one the run started with.")
            return 1
    if needs_desktop and not build_desktop():
        print("FAIL: the desktop does not rebuild from the restored tree.")
        return 1
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
