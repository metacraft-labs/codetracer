#!/usr/bin/env python3
"""PLAT-58 — the mutation harness for the Requests pane on the terminal and in
the GPUI window (codetracer-pm `spec/GUI/Core-Panes/Request-Panel.md`
§ "The terminal and the GPUI window (PLAT-58)"): the shared ViewModel's words,
tones, double press, menu, tail and reveal (`request_panel_vm`), the columns
(`table_fit.requestsFit`), the store's tail on a native transport, the engine's
seek on a materialized trace, the terminal's painter, runtime, focus ring,
host and loop, the GPUI leaf and window, and the vocabulary view.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` when the defect is compiled into a binary an arm is graded
through; runs the suites that must catch it; and requires RED — with the
failure the first run recorded (`plat58-requests-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-53's harness's (`run-plat53-test-results-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT58_BUILD_TUI` / `$PLAT58_BUILD_GPUI` /
`$PLAT58_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`. The desktop's arms are graded by the Electron capture
(`scripts/plat58-capture-electron.sh`, or `$PLAT58_DESKTOP_TEST`; a DISPLAY or
Xvfb is needed), whose answers file is restored after every run. The engine's arm is graded by its Rust
suite, run by `$PLAT58_CARGO_TEST` when set, else `cargo test --test
seek_to_geid_materialized_test` in `src/db-backend`. The Nim suites run a real
`replay-server` (`REPLAY_SERVER_BIN`) on the RS-M4 demo container.

Usage:
    run-plat58-requests-mutations.py [--only V1,T1] [--derive]
    run-plat58-requests-mutations.py --needle-scan
    run-plat58-requests-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat58-requests-mutation-control.sha256"
BECAUSE = HERE / "plat58-requests-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat58-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/request_panel_vm.nim"
FIT = "src/frontend/viewmodel/viewmodels/table_fit.nim"
STORE = "src/frontend/viewmodel/store/replay_data_store.nim"
ENGINE = "src/db-backend/src/dap_handler.rs"
TUI_PANE = "src/frontend/tui/app/views/requests_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
MOTIONS = "src/frontend/tui/app/input/motions.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
SESSION = "src/frontend/tui/host/tui_session.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
GPUI_LEAF = "src/frontend/gpui/requests_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP_VIEW = "src/frontend/viewmodel/views/isonim_request_panel_view.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat58_requests.nim"
TBL = "src/frontend/tui/tests/test_plat58_requests.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat58_requests_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat58_gpui_requests.nim"
RUST = "src/db-backend/tests/seek_to_geid_materialized_test.rs"
SPEC = "src/tests/gui/tests/request-panel/plat58-requests-capture.spec.ts"
ANSWERS = "src/tests/visual/answers/plat58-requests.electron.json"

SUBJECTS = [VM, FIT, STORE, ENGINE, TUI_PANE, RUNTIME, MOTIONS, SHELL,
            PROFILE, SESSION, TUI_MAIN, GPUI_LEAF, GPUI_MAIN, VOCAB,
            DESKTOP_VIEW]
SUITES = [VMU, TBL, PTY, PLAN, RUST, SPEC, ANSWERS]

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared ViewModel ------------------------------------------------
    ("V1", [(VM, '  of "redirect": rtRedirect', '  of "redirect": rtSuccess')],
     [(VMU, None)],
     "N.1: a 3xx status is coloured as a success"),
    ("V2", [(VM, '  of "DELETE": mtError', '  of "DELETE": mtLabel')],
     [(VMU, None)],
     "N.1: DELETE's badge is not the desktop's error colour"),
    ("V3", [(VM, "               nowMs - vm.lastPressMs <= RequestDoubleClickMs",
             "               nowMs - vm.lastPressMs < 0")],
     [(VMU, None), (TBL, None)],
     "N.4: a second press in time is not a double press (no handler)"),
    ("V4", [(VM, "  let double = vm.lastPressId == id and nowMs >= vm.lastPressMs and",
             "  let double = true and nowMs >= vm.lastPressMs and")],
     [(VMU, None)],
     "N.4: a press on another row counts as the second of a double press"),
    ("V5", [(VM, "  if req.seekUnavailableReason.len > 0:\n"
                 "    vm.jumpToHandler(index)   # sets the navigation message, sends nothing",
             "  if false:\n"
             "    vm.jumpToHandler(index)   # sets the navigation message, sends nothing")],
     [(VMU, None)],
     "Interactions: a row with no handler step is sent to the engine anyway"),
    ("V6", [(VM, "    action: rmFilterStatus, enabled: cls.len > 0 and not statusOn,",
             "    action: rmFilterStatus, enabled: not statusOn,")],
     [(VMU, None)],
     "N.5: an in-flight row offers Filter by Status"),
    ("V7", [(VM, '    enabled: any, reason: (if any: "" else: "no filter is on"))',
             '    enabled: true, reason: (if any: "" else: "no filter is on"))')],
     [(VMU, None), (TBL, None)],
     "N.5: Clear Filters is offered with no filter on"),
    ("V8", [(VM, "  if not enabled:\n    return\n  let req = rows[index]",
             "  if false:\n    return\n  let req = rows[index]")],
     [(VMU, None)],
     "N.5: a disabled menu entry runs"),
    ("V9", [(VM, "     nowMs - vm.lastPollMs < RequestSpanPollIntervalMs:",
             "     nowMs - vm.lastPollMs < 0:")],
     [(VMU, None)],
     "N.2: the tail is polled on every tick, not every 500 ms"),
    ("V10", [(VM, "    vm.revealed = true", "    discard")],
     [(VMU, None), (TBL, None)],
     "N.2: the pane reveals itself again and again, not once"),
    ("V11", [(VM, '    return (true, true, "")', '    return (true, false, "")')],
     [(VMU, None), (TBL, None)],
     "N.4: `:requests` alone searches for nothing instead of opening the field"),
    ("V12", [(VM, "      size: formatSize(req.responseSize), statusTone: statusTone(req),",
              "      size: $req.responseSize, statusTone: statusTone(req),")],
     [(VMU, None), (TBL, None)],
     "N.1: the Size column is raw bytes, not the desktop's B / KB"),
    ("V13", [(VM, '    of "list.focus-page-down": (if sel < 0: 0 else: sel + max(1, page))',
              '    of "list.focus-page-down": (if sel < 0: 0 else: sel + 1)')],
     [(VMU, None)],
     "N.4: Page Down moves one row"),
    ("F1", [(FIT, "              minUnits: RequestUrlFloorCells * unit, flex: 1),",
             "              minUnits: RequestUrlFloorCells * unit, flex: 0),")],
     [(VMU, None)],
     "N.1: the URL does not take the room the other columns leave"),
    ("F2", [(FIT, "    FitColumn(name: RequestsColumnNames[4], preferredUnits: durationUnits,\n"
                  "              neverCut: true),",
             "    FitColumn(name: RequestsColumnNames[4], preferredUnits: durationUnits,\n"
             "              neverCut: false),")],
     [(VMU, None)],
     "N.1: the duration is cut when the pane is narrow"),
    # ---- the store and the engine -------------------------------------------
    ("S1", [(STORE, "      s.applyRequestSpanDelta(responseBody(response))",
             "      s.applyRequestSpanDelta(response)")],
     [(TBL, None)],
     "N.2: a native transport's tail answer is dropped (no live row arrives)"),
    ("E1", [(ENGINE, "        let restored = if self.trace_kind == TraceKind::Materialized "
                     "&& !self.replay.serves_geid_positions() {",
             "        let restored = if false {")],
     [(RUST, None)],
     "Interactions: going to a handler is refused on a completed recording"),
    # ---- the terminal ---------------------------------------------------------
    ("T1", [(TUI_PANE, "const RightAligned = [true, false, false, true, true, true]",
             "const RightAligned = [true, false, false, false, true, true]")],
     [(TBL, None)],
     "N.1: the status is not right-aligned (the desktop's flex-end)"),
    ("T2", [(TUI_PANE, "  of rtClientError: CellStyle(role: srChromeNotification)",
             "  of rtClientError: CellStyle(role: srChromeError)")],
     [(TBL, None)],
     "N.1: a 4xx status is in the error colour, not the warning colour"),
    ("T3", [(TUI_PANE, "  of mtInformation: CellStyle(role: srChromeInfo)",
             "  of mtInformation: RequestsMutedStyle")],
     [(TBL, None)],
     "N.1: GET is not in its badge's information colour"),
    ("T4", [(TUI_PANE, "      return RequestsTarget(kind: rqMethod, position: -1)",
             "      return RequestsTarget(kind: rqStatus, position: -1)")],
     [(TBL, None)],
     "N.4: a press on the Method picker opens the Status options"),
    ("T5", [(RUNTIME, "        rt.openContextMenu(r.menu, event.row, event.col, outcome)",
             "        discard r.menu")],
     [(TBL, None)],
     "N.5: a right press on a row opens no menu"),
    ("T6", [(RUNTIME, "          position: t.position, nowMs: rt.scrollbars.clockMs), outcome)",
             "          position: t.position, nowMs: 0), outcome)")],
     [(TBL, None)],
     "N.4: every press is judged at time 0 (a late press goes to the handler)"),
    ("T7", [(RUNTIME, "       rt.runRequestsKeyOperation(res.operation, outcome):",
             "       false:")],
     [(TBL, None)],
     "N.4: the keys do not move the selection; Enter is not the handler"),
    ("T8", [(RUNTIME, "  if at >= 0 and b.layout.docked[at].open:",
             "  if false:")],
     [(TBL, None)],
     "N.4: `:requests` reveals the open docked pane over itself (Esc is taken)"),
    ("T9", [(RUNTIME, "      if requests.openField and rt.app.requests.search.len == 0:",
             "      if requests.openField:")],
     [(TBL, None), (PTY, None)],
     "N.4: the bare `:requests` with a search on does not clear it"),
    ("T10", [(MOTIONS, "  for region in projection.regions & docked:",
              "  for region in projection.regions:")],
     [(TBL, None)],
     "N.4: a press on the docked-open pane does not give it the keys"),
    ("T11", [(SESSION, "  drainPlatformCallbacks()\n  let vm = s.session.requestsVM",
              "  discard\n  let vm = s.session.requestsVM")],
     [(TBL, None)],
     "N.2: a filter's window answer is read before it is applied (stale rows)"),
    ("T12", [(SESSION, "    revealed = rt.revealRequestsPane()",
              "    revealed = false")],
     [(TBL, None), (PTY, None)],
     "N.2: a recording that serves requests does not bring the pane up"),
    ("T13", [(TUI_MAIN, "      let requestsChanged = session.pumpRequests(rt, nowMs())",
              "      let requestsChanged = false")],
     [(PTY, None)],
     "N.2: the shipped terminal never polls (no reveal, no tail)"),
    ("T14", [(PROFILE, "     paneRequests},", "     },"),
             (SHELL, "  elif region.pane == paneRequests and model.requests.loaded:",
              "  elif false:")],
     [(PTY, None)],
     "N.3: the terminal draws the report leaf, not the pane"),
    ("P1", [(VOCAB, '  children.add viewTable("requests.rows", @RequestsColumnTitles, cells)',
             '  discard cells')],
     [(TBL, None)],
     "the vocabulary's Requests view lists no request"),
    # ---- GPUI -------------------------------------------------------------------
    ("G1", [(GPUI_LEAF, "  of rtServerError: DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]",
             "  of rtServerError: RequestsLabelColour")],
     [(PLAN, None)],
     "N.1: the GPUI 5xx status is not in the desktop's error colour"),
    ("G2", [(GPUI_LEAF, "    return GRequestsHit(kind: grqMethod, position: -1, index: -1)",
             "    return GRequestsHit(kind: grqStatus, position: -1, index: -1)")],
     [(PLAN, None)],
     "N.4: a press on the GPUI Method picker opens the Status options"),
    ("G3", [(GPUI_MAIN, "    if pressRequests(r, x, y, right = true):",
             "    if false:")],
     [(PLAN, None)],
     "N.5: a right press on a GPUI row opens no menu"),
    ("G4", [(GPUI_MAIN, "      # REQUESTS pane opened when the recording serves any (RS-M4: once).\n"
                        "      discard pumpRequestsWindow(r)",
             "      # REQUESTS pane opened when the recording serves any (RS-M4: once).\n"
             "      discard")],
     [(PLAN, None)],
     "N.2: the GPUI window does not bring the pane up at open"),
    ("G5", [(GPUI_MAIN, "  if requests.isRequests:", "  if false:")],
     [(PLAN, None)],
     "N.4: `:requests <text>` in the GPUI omnibox does not search"),
    ("G6", [(GPUI_MAIN, "      requestsSay(r, gSession.goToHandler(i))\n  of \"list.filter\":",
             "      discard i\n  of \"list.filter\":")],
     [(PLAN, None)],
     "N.4: Enter on the GPUI pane does not go to the handler"),
    ("G7", [(GPUI_MAIN, "  drainPlatformCallbacks()\n  let body = requestsBody()",
             "  discard\n  let body = requestsBody()")],
     [(PLAN, None)],
     "N.2: a GPUI filter's window answer is drawn before it is applied"),
    # ---- the desktop ----------------------------------------------------------------
    ("D1", [(DESKTOP_VIEW, "        handler: rowMenuHandler(vm, index, e.action))",
             "        handler: rowMenuHandler(vm, index, rmClearFilters))")],
     [(SPEC, None)],
     "N.5: every entry of the desktop's row menu runs Clear Filters"),
    ("D2", [(DESKTOP_VIEW, "    if vm.pressRow(captured, int64(epochTime() * 1000)) == rpActivate:",
             "    if false:")],
     [(SPEC, None)],
     "N.4: two presses on a desktop row do not go to its handler"),
    # ---- the declared survivor ----------------------------------------------------
    ("S9", [(TUI_PANE, "  IdFloorCells = 2", "  IdFloorCells = 1")],
     [(TBL, None)],
     "behaviour-preserving: the DECLARED SURVIVOR (the id column's floor; "
     "every id is two cells)"),
]

DECLARED_SURVIVORS = {"S9"}

IN_BINARY = {VM, FIT, STORE, TUI_PANE, RUNTIME, MOTIONS, SHELL, PROFILE,
             SESSION, TUI_MAIN, VOCAB}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {VM, FIT, STORE, GPUI_LEAF, GPUI_MAIN, VOCAB}
  # Subjects compiled into `codetracer-gpui`.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
RUST_SUITES = {RUST}
DESKTOP_SUITES = {SPEC}
IN_DESKTOP = {VM, STORE, DESKTOP_VIEW}
  # Subjects compiled into the desktop's bundle.


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
        f.write("# Control digests for run-plat58-requests-mutations.py — the\n"
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
    return build_with("PLAT58_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT58_BUILD_GPUI", "build-gpui")


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the screen;
    the recorded cause keeps the condition and drops the snapshot."""
    head, sep, _rest = line.partition("; screen:")
    if sep:
        return head
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def run_rust(suite):
    """The engine's suite: GREEN on rc 0, else RED on its first panic."""
    cmd = os.environ.get("PLAT58_CARGO_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["cargo", "test", "--test", Path(suite).stem]
    cwd = REPO if cmd else REPO / "src/db-backend"
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    if "error[" in out and "test result" not in out:
        return "DID-NOT-COMPILE", []
    first = [ln.strip() for ln in out.splitlines()
             if "panicked at" in ln or ln.strip().startswith("ct/seek")][:1]
    first = [re.sub(r":\d+:\d+:", "", f) for f in first]
    return "RED", first


def run_spec(suite):
    """The Electron capture: GREEN on rc 0, else RED on its first expectation.
    It rewrites the answers file the native suites read, so the file is put
    back whatever the run did."""
    cmd = os.environ.get("PLAT58_DESKTOP_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["bash", "scripts/plat58-capture-electron.sh"]
    saved = path_of(ANSWERS).read_bytes()
    try:
        p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    finally:
        path_of(ANSWERS).write_bytes(saved)
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [ln.strip() for ln in plain.splitlines()
             if ln.strip().startswith(("Error:", "Expected:", "Received:"))][:2]
    return "RED", [" / ".join(first)] if first else []


def build_desktop():
    return build_with("PLAT58_BUILD_DESKTOP", "build-once")


def run_suite(suite, test_filter):
    if suite in RUST_SUITES:
        return run_rust(suite)
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
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
    needs_desktop = any(s in DESKTOP_SUITES for arm in selected
                        for s, _ in arm[2])
    if needs_desktop and not build_desktop():
        print("ABORT: the unmutated desktop does not build.")
        return 1
    graded = sorted({(s, flt or "") for arm in selected for s, flt in arm[2]})
    for s, flt in graded:
        v, f = run_suite(s, flt or None)
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
            backups[rel] = path.with_name(path.name + ".plat58bak")
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
