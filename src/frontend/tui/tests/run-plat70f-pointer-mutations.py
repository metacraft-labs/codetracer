#!/usr/bin/env python3
"""The mutation harness for the pointer's shape (Pointer-Affordances.md), for a
click on a hop row, and for the origin chain of a variable the line does not
assign.

Each arm plants ONE defect in the shared function, the OSC 22 protocol, the
terminal's hit-test, driver or restore, `nim-termctl`'s crash path, the GPUI
window, the desktop's stamp and stylesheets, or the engine's origin chain;
REBUILDS the shipped `codetracer-tui` / `codetracer-gpui` / desktop /
`replay-server` when the defect is compiled into one; runs the suites that must
catch it; and requires RED, with the failure the first run recorded
(`plat70f-pointer-mutation-because.json`, derived with `--derive`).

The discipline is the earlier harnesses': committed control digests over
subjects and suites, a needle scan that gates re-recording, `because` derived
from a run, rc 124 is a hang, per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT70F_BUILD_TUI` / `$PLAT70F_BUILD_GPUI` /
`$PLAT70F_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`. The desktop arms run `$PLAT70F_DESKTOP_TEST` when set, else
`npx playwright test` in `src/tests/gui`. The engine's arms run
`cargo test --test origin_dap_test` in `src/db-backend`.

No mocks: the shipped ViewModel over real values, the shipped terminal binary
on a real pty against a real recording, the shipped GPUI binary's window plan,
the real Electron app, and the engine over its in-memory trace reader.

Usage:
    run-plat70f-pointer-mutations.py [--only P1,T1] [--derive]
    run-plat70f-pointer-mutations.py --needle-scan
    run-plat70f-pointer-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70f-pointer-mutation-control.sha256"
BECAUSE = HERE / "plat70f-pointer-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70f-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.

SHAPE = "src/common/pointer_shape.nim"
KEYS = "src/frontend/viewmodel/viewmodels/state_pane_keys.nim"
OSC = "src/frontend/tui/app/theme/pointer_protocol.nim"
CAPS = "src/frontend/tui/app/theme/capabilities.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
DRIVER = "src/frontend/tui/host/terminal_driver.nim"
PROBE = "src/frontend/tui/host/terminal_probe.nim"
MAIN = "src/frontend/tui/main.nim"
TERMCTL = "../nim-termctl/src/nim_termctl/posix_backend.nim"
GMAIN = "src/frontend/gpui/main.nim"
GPOINTER = "src/frontend/gpui/window_pointer.nim"
GCLICKS = "src/frontend/gpui/window_clicks.nim"
STAMP = "src/frontend/ui/pointer_stamp.nim"
BUTTONS = "src/frontend/styles/components/button.styl"
STATEVIEW = "src/frontend/viewmodel/views/isonim_state_view.nim"
PANEL = "src/frontend/ui/isonim_origin_chain.nim"
ENGINE = "src/db-backend/src/db.rs"

VMU = "src/frontend/viewmodel/tests/unit/test_plat70f_pointer_shapes.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70f_pointer_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70f_gpui_plan.nim"
SPEC = "src/tests/gui/tests/value-origin/plat70f-pointer.spec.ts"
ENGINE_TEST = "src/db-backend/tests/origin_dap_test.rs"

SUBJECTS = [SHAPE, KEYS, OSC, CAPS, RUNTIME, DRIVER, PROBE, MAIN, TERMCTL, GMAIN,
            GPOINTER, GCLICKS, STAMP, BUTTONS, STATEVIEW, PANEL, ENGINE]
SUITES = [VMU, PTY, PTY_E, PLAN, SPEC, ENGINE_TEST]

PTY_ONCE = "*::the query, one push, sets after it, each only on change"
PTY_1000 = "*::1000 motion reports over one element write at most one OSC 22"
PTY_DRAG = "*::a tab drag grabs, and keeps its offered drop off the layout"
PTY_LACKS = "*::a shape the terminal says it lacks is never written (PA-3)"
PTY_FOCUS = "*::focus-out pops, focus-in pushes the last shape again"
PTY_KITTY = "*::kitty: the pop is the last OSC 22, before the alternate screen is left"
PTY_QUIT = "*::set-only: the reset follows the last shape on quit"
PTY_TERM = "*::set-only: the reset follows the last shape on SIGTERM"
PTY_SEGV = "*::set-only: the reset follows the last shape on SIGSEGV"
PTY_X11 = "*::xterm's shapes are its own names"
PTY_STOP = "*::a stop gives the pointer back, and the continue takes it again"
PTY_VT = "*::a silent peer with TERM=vt220 is never sent OSC 22"
PTY_OFF = "*::--pointer-shapes=off asks nothing and writes nothing"
PTY_TMUX_OFF = "*::a silent wrapped query: nothing sent, and the remedy reported"
PTY_TMUX_ON = "*::an answered wrapped query: every sequence wrapped"
PTY_E = "src/frontend/tui/tests/real_terminal/test_plat70e_origin_keys_pty.nim"
PTY_HOP = "*::a press on a hop seeks to its tick, with the cursor on it"
PLAN_SHAPES = "*::the render plan carries each element's shape"
PLAN_HOLD = "*::during a tab drag the window's override is the gesture's"
PLAN_HOP = "*::seeks to the hop's tick, with the cursor on it"
VMU_REST = "*::clickable elements point, and a disabled one refuses"
VMU_CELL = "*::a truncated cell points; a cell that fits does not"
VMU_GESTURE = "*::the gesture's shape, whatever is under the pointer"
VMU_FALLBACK = "*::the fallback chain stops at what the terminal has (§5.2)"
VMU_CLICK = "*::seeks to the hop's tick and leaves the cursor on it"
VMU_GATE = "*::no stylesheet but the eight rules' says cursor"
VMU_NATIVE = "*::no native front-end module sets a cursor by name"
ENGINE_DUNDER = "test_origin_chain_of_a_dunder_never_assigned_has_no_hop"
ENGINE_LIST = "test_origin_chain_of_a_list_is_its_mutation_then_its_assignment"
ENGINE_OTHER = "test_origin_chain_of_a_change_on_another_variables_line_is_unknown"

ARMS = [
    # ---- the shared function ------------------------------------------------
    ("F1", [(SHAPE, "    return psNotAllowed",
             "    return psPointer")],
     [(VMU, VMU_REST), (PLAN, PLAN_SHAPES)],
     "§3.2: a disabled control still points"),
    ("F2", [(SHAPE, "  of hkCell: (if target.truncated: psPointer else: psDefault)",
             "  of hkCell: psPointer")],
     [(VMU, VMU_CELL)],
     "§3.2: an affordance on a cell that fits"),
    ("F3", [(SHAPE, "  of pgTabDrag: (if gesture.legalDrop: psGrabbing else: psNotAllowed)",
             "  of pgTabDrag: psGrabbing")],
     [(VMU, VMU_GESTURE)],
     "§3.3: a refused drop still grabs"),
    ("F4", [(SHAPE, "    psGrabbing: psGrab, psNotAllowed: psDefault]",
             "    psGrabbing: psPointer, psNotAllowed: psDefault]")],
     [(VMU, VMU_FALLBACK)],
     "§5.2: grabbing falls straight to pointer, skipping grab"),
    # ---- the hop's click ----------------------------------------------------
    ("H1", [(KEYS, "  stateKey(rows, at, \"list.activate\")",
             "  StateKeyEffect(kind: skeNone, cursor: at)")],
     [(VMU, VMU_CLICK), (PTY_E, PTY_HOP), (PLAN, PLAN_HOP)],
     "a click on a hop does nothing, on every front-end"),
    ("H2", [(RUNTIME, "      of vrkOrigin:\n        if event.button != mbLeft:",
             "      of vrkOrigin:\n        if true:")],
     [(PTY_E, PTY_HOP)],
     "the terminal's hop row takes no click"),
    ("H3", [(GCLICKS, "      elif getAttribute(el, StateOriginHopAttribute).len > 0:",
             "      elif getAttribute(el, StateOriginHopAttribute).len < 0:")],
     [(PLAN, PLAN_HOP)],
     "the window's hop row is not wired"),
    ("H4", [(STATEVIEW, "    tdiv(class = chainLineClass(line), onclick = seek):",
             "    tdiv(class = chainLineClass(line)):")],
     [(SPEC, None)],
     "the desktop's in-row hop takes no click"),
    # ---- OSC 22 (the milestone's F arms) ------------------------------------
    ("P1", [(OSC, "  if not ok or (e.hasShown and e.shown == s):",
             "  if not ok:")],
     [(PTY, PTY_1000)],
     "F: emitting on every motion report"),
    ("P2", [(OSC, "  let (ok, s) = supportedFallback(shape, e.caps.supported)",
             "  let (ok, s) = (true, shape)")],
     [(PTY, PTY_LACKS)],
     "F: a shape outside the supported set written"),
    ("P3", [(DRIVER, "  discard setExtraRestore(d.restoreUnion())",
             "  discard setExtraRestore(d.restoreUnion().replace(d.pointer.restoreBytes, \"\"))")],
     [(PTY, PTY_KITTY), (PTY, PTY_TERM)],
     "F: the restore omitted from the signal path"),
    ("P4", [(OSC, "  \"\\x1bPtmux;\" & sequence.replace(\"\\x1b\", \"\\x1b\\x1b\") & St",
             "  \"\\x1bPtmux;\" & sequence & St")],
     [(PTY, PTY_TMUX_OFF)],
     "F: the tmux wrap without doubling ESC"),
    ("P5", [(TERMCTL, "  ## fault or a `kill`.\n  restoreTerminalSafe()",
             "  ## fault or a `kill`.\n  gExtraRestoreLen = 0\n  restoreTerminalSafe()")],
     [(PTY, PTY_SEGV)],
     "F: the set-only reset missing from the crash handler only"),
    ("P6", [(OSC, "    of \"foot\", \"ghostty\": pdCss",
             "    of \"foot\", \"ghostty\": pdOff")],
     [(PTY, PTY_QUIT)],
     "F: set-only terminals switched off"),
    ("P7", [(BUTTONS, "BUTTON_BORDER_COLOR = colors-ui-border-primary",
             ".planted\n  cursor: pointer\n\nBUTTON_BORDER_COLOR = colors-ui-border-primary")],
     [(VMU, VMU_GATE)],
     "F: a front-end choosing a shape itself (a planted `cursor: pointer`)"),
    ("P8", [(GPOINTER, "      r.setStyle(el, \"cursor\", pointerShapeOf(target).cssName)",
             "      r.setStyle(el, \"cursor\", \"pointer\")")],
     [(VMU, VMU_NATIVE)],
     "PA-1: the window naming a shape instead of asking the function"),
    ("P9", [(OSC, "  if caps.dialect == pdX11: X11PointerNames[shape]",
             "  if false: X11PointerNames[shape]")],
     [(PTY, PTY_X11)],
     "§2: xterm spoken to in CSS"),
    ("P10", [(OSC, "    if e.caps.dialect == pdKitty and not e.pushed: e.caps.pushBytes(s)",
              "    if e.caps.dialect == pdKitty: e.caps.pushBytes(s)")],
     [(PTY, PTY_ONCE)],
     "§5.3: every shape a push, so one pop leaves shapes on the stack"),
    ("P11", [(OSC, "  if e.pushed:\n    result = e.caps.popBytes",
              "  if false:\n    result = e.caps.popBytes")],
     [(PTY, PTY_FOCUS)],
     "§5.3: focus-out leaves the shape on another pane's pointer"),
    ("P12", [(DRIVER, "  result.add d.pointer.resumeBytes",
              "  discard d.pointer.resumeBytes")],
     [(PTY, PTY_STOP)],
     "§5.4: the continue does not show the shape again"),
    ("P13", [(PROBE, "  if flags.pointerQueryWanted and not env.term.toLowerAscii.startsWith(\"vt\"):",
              "  if flags.pointerQueryWanted:")],
     [(PTY, PTY_VT)],
     "PA-5: a vt220 is asked"),
    ("P14", [(CAPS, "  not flags.noMouse and\n    (flags.choices.pointerShapes.isNone or",
              "  not flags.noMouse and\n    (true or")],
     [(PTY, PTY_OFF)],
     "§5.6: --pointer-shapes=off still asks"),
    ("P15", [(OSC, "    return PointerCaps(dialect: pdOff, source: \"tmux\", remedy: PointerRemedy)",
              "    return PointerCaps(dialect: pdOff, source: \"tmux\")")],
     [(PTY, PTY_TMUX_OFF)],
     "PA-7: no remedy line"),
    ("P16", [(OSC, "  elif shape == psColResize and caps.columnAlias: \"ew-resize\"",
              "  elif false: \"ew-resize\"")],
     [(PTY, PTY_ONCE)],
     "kitty is asked for a name it said it does not know"),
    ("P17", [(DRIVER, "      writeAll(d.outFd, d.pointer.restoreBytes)",
              "      discard d.pointer.restoreBytes")],
     [(PTY, "*:::set pointer-shapes off gives the pointer back; on takes it again")],
     "§5.6: turning the shapes off leaves the last one showing"),
    # ---- the terminal's hit-test --------------------------------------------
    ("T1", [(MAIN, "  if isMouse and not event.shift:\n    driver.setPointerShape(rt.pointerShapeAt(event))",
             "  if false:\n    driver.setPointerShape(rt.pointerShapeAt(event))")],
     [(PTY, PTY_ONCE)],
     "§5.3: a mouse report never reaches the shape"),
    ("T2", [(RUNTIME, "    of ikDraggingTab:\n      return PointerGesture(kind: pgTabDrag,",
             "    of ikRevealingDock:\n      return PointerGesture(kind: pgTabDrag,")],
     [(PTY, PTY_DRAG)],
     "§3.3: the terminal does not see a tab drag as a gesture"),
    # ---- the GPUI window ----------------------------------------------------
    ("G1", [(GMAIN, "    stampPointerShapes(r, gRoot)",
             "    discard")],
     [(PLAN, PLAN_SHAPES), (PLAN, PLAN_HOP)],
     "§4: the window's elements carry no shape"),
    ("G2", [(GMAIN, "  r.setWindowCursor(name)\n  if not gRoot.isNil:\n    r.setAttribute(gRoot, WindowCursorAttribute, name)",
             "  r.setWindowCursor(\"\")\n  if not gRoot.isNil:\n    r.setAttribute(gRoot, WindowCursorAttribute, \"\")")],
     [(PLAN, PLAN_HOLD)],
     "§4: no override during a gesture"),
    # ---- the desktop --------------------------------------------------------
    ("D1", [(STAMP, "  stampTree(documentRoot)",
             "  discard documentRoot")],
     [(SPEC, None)],
     "§4: what is on the page carries no data-pointer"),
    ("D2", [(STAMP, "    setGesture(dragGestureAt(e.evTarget)))",
             "    discard dragGestureAt(e.evTarget))")],
     [(SPEC, None)],
     "§4: the body carries no gesture while a divider is held"),
    # ---- the engine ---------------------------------------------------------
    ("O1", [(ENGINE, "        (ValueRecord::Sequence { elements: x, .. }, ValueRecord::Sequence { elements: y, .. }) => all_equal(x, y),",
             "        (ValueRecord::Sequence { .. }, ValueRecord::Sequence { .. }) => false,")],
     [(ENGINE_TEST, ENGINE_LIST)],
     "a list that kept its contents reads as changed"),
    ("O2", [(ENGINE, "                if first_sighting {\n                    terminator = Terminator::new(TerminatorKind::RecordingStart);",
             "                if false {\n                    terminator = Terminator::new(TerminatorKind::RecordingStart);")],
     [(ENGINE_TEST, ENGINE_DUNDER)],
     "a dunder's first sighting reads as a write"),
    ("O3", [(ENGINE, "                .is_some_and(|ast| !ast.targets_variable(&current_var_name))",
             "                .is_some_and(|_ast| false)")],
     [(ENGINE_TEST, ENGINE_DUNDER), (ENGINE_TEST, ENGINE_OTHER)],
     "another variable's assignment is taken as this one's origin"),
    ("O4", [(ENGINE, "        .is_some_and(|rest| rest.starts_with('.') || rest.starts_with('['))",
             "        .is_some_and(|_rest| false)")],
     [(ENGINE_TEST, ENGINE_LIST)],
     "an in-place mutation is not a write"),
    # ---- the declared survivor ----------------------------------------------
    ("N1", [(SHAPE, "  $shape",
             "  result = $shape")],
     [(VMU, None)],
     "behaviour-preserving: spelled differently, the same answer"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {SHAPE, KEYS, OSC, CAPS, RUNTIME, DRIVER, PROBE, MAIN, TERMCTL}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {SHAPE, KEYS, GMAIN, GPOINTER, GCLICKS}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {SHAPE, KEYS, STAMP, BUTTONS, STATEVIEW, PANEL}
  # Subjects compiled into the desktop's bundle.
PTY_SUITES = {PTY, PTY_E}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}
PYTHON_SUITES = set()
CARGO_SUITES = {ENGINE_TEST}

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
    if suite in PTY_SUITES:
        return lane_flags("tui-real-terminal")
    if suite == VMU:
        return lane_flags("vm-unit") + ["--path:src/frontend/viewmodel"]
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
        f.write("# Control digests for run-plat70f-pointer-mutations.py — the\n"
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
    return build_with("PLAT70F_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70F_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70F_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70F_DESKTOP_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["npx", "playwright", "test", suite.split("src/tests/gui/", 1)[1],
         "--reporter=line"]
    cwd = REPO if cmd else REPO / "src/tests/gui"
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [ln.strip() for ln in plain.splitlines()
             if ln.strip().startswith("Error:")][:1]
    return "RED", first


def run_python(suite, test_filter=None):
    """A Python unittest suite (or the one test `test_filter` names): GREEN
    on rc 0, else RED on its first `FAIL:` / `ERROR:` line."""
    try:
        p = subprocess.run([sys.executable, suite] +
                           ([test_filter] if test_filter else []), cwd=REPO,
                           capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if "\nOK" in out else ("RAN-NOTHING", [])
    first = [ln.strip() for ln in out.splitlines()
             if ln.startswith("FAIL:") or ln.startswith("ERROR:")][:1]
    return "RED", first


def run_cargo(suite, test_filter):
    """An engine test: GREEN on rc 0, else RED on its first panic line."""
    argv = ["cargo", "test", "--test", Path(suite).stem] + \
        ([test_filter] if test_filter else [])
    try:
        p = subprocess.run(argv, cwd=REPO / "src/db-backend", capture_output=True,
                           text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if "1 passed" in out or " passed;" in out else ("RAN-NOTHING", [])
    if "error: could not compile" in out:
        return "DID-NOT-COMPILE", []
    first = [ln.strip() for ln in out.splitlines() if "panicked at" in ln or
             ln.startswith("assertion")][:1]
    return "RED", first


def run_suite(suite, test_filter):
    if suite in CARGO_SUITES:
        return run_cargo(suite, test_filter)
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
    if suite in PYTHON_SUITES:
        return run_python(suite, test_filter)
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
        lines = out.splitlines()
        for i, ln in enumerate(lines):
            if "[FAILED]" in ln or "Unhandled exception" in ln:
                cause = portable_cause(ln.strip())
                # A raised wait names its condition, not its case: the case
                # the unittest runner then reports as [FAILED] is added, so
                # two arms red in different cases are told apart.
                if "Unhandled exception" in ln:
                    for nxt in lines[i + 1:]:
                        if "[FAILED]" in nxt:
                            cause += " in " + nxt.strip().split("[FAILED] ", 1)[1]
                            break
                failures = [cause]
                break
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
    graded = sorted({(s, flt) for arm in selected for s, flt in arm[2]},
                    key=lambda t: (t[0], t[1] or ""))
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
            backups[rel] = path.with_name(path.name + ".plat70fbak")
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
