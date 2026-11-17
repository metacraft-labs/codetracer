#!/usr/bin/env python3
"""PLAT-70 Part E — the mutation harness for the value origin from the
keyboard (Variable-State-Pane.md § Value origin from the keyboard;
Value-Origin-Tracking.md §13.0), and for the lane runner's specification
checkout.

Each arm plants ONE defect in the shared ViewModel (`state_pane_keys`'s cursor
rule and hop rows), the shipped keymap data and key decoders, the terminal's
runtime, painter or host, the GPUI window, the desktop's key router, or the
lane runner's resolver (`ci/lib/spec-checkout.sh`); REBUILDS the shipped
`codetracer-tui` / `codetracer-gpui` / desktop when the defect is compiled
into a binary an arm is graded through; runs the suites that must catch it;
and requires RED — with the failure the first run recorded
(`plat70e-origin-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-70 Part D's harness's, clause for clause: committed
control digests over subjects AND suites (§16c), a needle scan that gates
re-recording (§39a), `because` derived from a run, rc 124 is a hang (§1),
per-arm restore verification, one declared behaviour-preserving survivor,
and `ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT70E_BUILD_TUI` / `$PLAT70E_BUILD_GPUI` /
`$PLAT70E_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui`
/ `just build-once`. The desktop arms are graded by the Electron spec, run by
`$PLAT70E_DESKTOP_TEST` when set, else `npx playwright test` in
`src/tests/gui`. A Python suite (the lane runner's resolver) runs under
`python3`, RED on its first `FAIL:` / `ERROR:` line.

No mocks: the suites graded here run the shipped ViewModel and keymap data
over real values, the shipped terminal binary on a real pty against a real
recording and `replay-server`, the shipped GPUI binary's window plan, the
real Electron app, and the unmodified lane scripts in scratch workspaces.

Usage:
    run-plat70e-origin-mutations.py [--only V1,T1] [--derive]
    run-plat70e-origin-mutations.py --needle-scan
    run-plat70e-origin-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70e-origin-mutation-control.sha256"
BECAUSE = HERE / "plat70e-origin-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70e-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
KEYS = "src/frontend/viewmodel/viewmodels/state_pane_keys.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
EMACS = "src/frontend/viewmodel/keymap/emacs_keymap.nim"
NAV = "src/frontend/viewmodel/keymap/navigation_keymap.nim"
KEYNAMES = "src/common/key_names.nim"
DOMKEYS = "src/common/key_event_names.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
VARS = "src/frontend/tui/app/views/variables.nim"
TSESSION = "src/frontend/tui/host/tui_session.nim"
GMAIN = "src/frontend/gpui/main.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
ROUTER = "src/frontend/ui/key_router.nim"
SPECDIR = "ci/lib/spec-checkout.sh"
LANE = "ci/lib/run-nim-test-lane.sh"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70e_origin_keys_vm.nim"
ORACLE = "src/frontend/viewmodel/tests/unit/test_plat68_cua_oracle.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70e_origin_keys_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70e_gpui_plan.nim"
SPEC = "src/tests/gui/tests/value-origin/plat70e-origin-keys.spec.ts"
PATHS = "ci/test/spec-checkout-paths-test.py"

SUBJECTS = [KEYS, CUA, EMACS, NAV, KEYNAMES, DOMKEYS, RUNTIME, VARS, TSESSION,
            GMAIN, LEAVES, ROUTER, SPECDIR, LANE]
SUITES = [VMU, ORACLE, PTY, PLAN, SPEC, PATHS]

PTY_CUA = "*::CUA: Ctrl+Shift+O, Down onto a hop, Escape, Enter seeks, Menu"
PTY_LEGACY = "*::legacy keys: Ctrl+K Shift+F10 opens the row menu; Shift+F10 still steps back"
PTY_VIM = "*::Vim: g o in the pane; Esc on a hop closes it; o walks and Shift+O walks back"
PLAN_KEYS = "*::Ctrl+Shift+O, Down onto a hop, Escape, Enter seeks"
PLAN_MENU = "*::the Menu key opens the row menu; Show value origin toggles the chain"
PLAN_WALK = "*::o walks to the origin and Shift+O walks back"


# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared ViewModel: the cursor rule and the hop rows ---------------
    ("V1", [(KEYS, "    if r.kind in {srkVariable, srkHop}: result.add i",
             "    if r.kind in {srkVariable}: result.add i")],
     [(VMU, None), (PTY, PTY_CUA), (PLAN, PLAN_KEYS)],
     "§13.0: the hops are not focusable — Down skips them"),
    ("V2", [(KEYS, "      StateKeyEffect(kind: skeSeek, cursor: cursor, path: row.path,",
             "      StateKeyEffect(kind: skeNone, cursor: cursor, path: row.path,")],
     [(VMU, None), (PTY, PTY_CUA), (PLAN, PLAN_KEYS)],
     "§13.0: Enter on a hop does not seek"),
    ("V3", [(KEYS, "    StateKeyEffect(kind: skeCloseChain, cursor: variableCursor(row.path),",
             "    StateKeyEffect(kind: skeCloseChain, cursor: cursor,")],
     [(VMU, None), (PTY, PTY_CUA)],
     "§13.0: Escape closes the chain but leaves the cursor on a hop that is gone"),
    ("V4", [(KEYS, "      if operation == \"list.collapse\" and not row.operandsOpen:",
             "      if operation == \"list.collapse\":")],
     [(VMU, None)],
     "§13.0: Left on a hop whose operands are shown leaves it instead of collapsing them"),
    ("V5", [(KEYS, "      tick: hop.location.rrTicks, path: hop.location.path,",
             "      tick: 0, path: hop.location.path,")],
     [(VMU, None), (PTY, PTY_CUA)],
     "a hop row's seek target is not its hop's tick"),
    ("V6", [(KEYS, "    StateKeyEffect(kind: skeToggleChain, cursor: variableCursor(row.path),",
             "    StateKeyEffect(kind: skeToggleChain, cursor: cursor,")],
     [(VMU, None)],
     "Show Value Origin from a hop closes the chain and leaves the cursor on it"),
    # ---- the keymap data and the decoders (the milestone's E arms) ------------
    ("K1", [(CUA, "    BaseRow(chords: \"Ctrl+Shift+O\", operation: \"variables.show-value-origin\",",
             "    BaseRow(chords: \"Ctrl+Alt+Shift+O\", operation: \"variables.show-value-origin\",")],
     [(VMU, None), (ORACLE, None), (PTY, PTY_CUA)],
     "E: Ctrl+Shift+O left at editorFocus only — the Variables pane has no chord"),
    ("K2", [(KEYNAMES, "              of 29: \"Menu\"     # xterm's application (context-menu) key",
             "              of 29: \"\"     # xterm's application (context-menu) key")],
     [(VMU, None), (PTY, PTY_CUA)],
     "E: Menu decoded as nothing (xterm's CSI 29 ~)"),
    ("K3", [(KEYNAMES, "  of 57363: \"Menu\"          # the Kitty protocol's application key",
             "  of 57363: \"\"          # the Kitty protocol's application key")],
     [(VMU, None)],
     "Menu decoded as nothing under the Kitty protocol"),
    ("K4", [(CUA, "    BaseRow(chords: \"Ctrl+K Shift+F10\", operation: \"context-menu.open\", whenText: Debug,",
             "    BaseRow(chords: \"Ctrl+K Shift+F11\", operation: \"context-menu.open\", whenText: Debug,")],
     [(VMU, None), (ORACLE, None), (PTY, PTY_LEGACY)],
     "§3.8: no Debug-mode chord for the row menu on a legacy terminal"),
    ("K5", [(NAV, "            whenText: \"listFocus && paneKind == state\"),\n    BaseRow(chords: \"Menu\", operation: \"context-menu.open\", table: G, navModes: N),",
             "            whenText: \"listFocus\"),\n    BaseRow(chords: \"Menu\", operation: \"context-menu.open\", table: G, navModes: N),")],
     [(VMU, None)],
     "Vim / Kakoune: `g o` shows the value origin in every list, not only the Variables pane"),
    ("K6", [(DOMKEYS, "    \"ContextMenu\": \"Menu\"}.toTable",
             "    \"ContextMenuKey\": \"Menu\"}.toTable")],
     [(VMU, None), (SPEC, None)],
     "the desktop decodes the application key as nothing"),
    ("K7", [(EMACS, "    BaseRow(chords: \"Menu\", operation: \"palette.open-commands\", table: G),",
             "    BaseRow(chords: \"Menu\", operation: \"context-menu.open\", table: G),")],
     [(VMU, None), (ORACLE, None)],
     "Emacs: the application key is the context menu, not M-x"),
    # ---- the terminal ----------------------------------------------------------
    ("T1", [(RUNTIME, "    proc(): bool = focusedOn(paneState) and not rt.app.variables.isEmpty)",
             "    proc(): bool = false and focusedOn(paneState) and not rt.app.variables.isEmpty)")],
     [(PTY, PTY_CUA)],
     "the terminal's Variables pane takes no list keys"),
    ("T2", [(VARS, "                selected: model.selected == row.node.path and\n                          model.selectedHop == row.entry)",
             "                selected: false)")],
     [(PTY, PTY_CUA)],
     "the terminal does not draw the cursor on a hop"),
    ("T3", [(RUNTIME, "  if op == \"context-menu.open\":\n    let path = model.selected",
             "  if false:\n    let path = model.selected")],
     [(PTY, PTY_CUA)],
     "the terminal's Menu opens no row menu in the Variables pane"),
    ("T4", [(RUNTIME, "    outcome.requestClick(PaneClickRequest(kind: pcSeek, tick: effect.tick))",
             "    outcome.requestClick(PaneClickRequest(kind: pcSeek, tick: 0))")],
     [(PTY, PTY_CUA)],
     "the terminal's Enter on a hop seeks somewhere else"),
    ("T5", [(TSESSION, "    s.state.selectedHop.val = rt.app.variables.selectedHop",
             "    s.state.selectedHop.val = -1")],
     [(PTY, PTY_CUA)],
     "the terminal drops the hop cursor at the next stop"),
    ("T6", [(RUNTIME, "    # pane takes them.\n    of \"editor.scroll-line-down\": \"list.focus-next\"",
             "    # pane takes them.\n    of \"editor.scroll-line-down-x\": \"list.focus-next\"")],
     [(PTY, PTY_VIM)],
     "Vim's j / k do not move the Variables cursor"),
    # ---- GPUI ------------------------------------------------------------------
    ("G1", [(GMAIN, "    proc(): bool = gFocusPane == $paneState and not gCtxMenu.open and",
             "    proc(): bool = false and not gCtxMenu.open and")],
     [(PLAN, PLAN_KEYS)],
     "E: GPUI's Variables pane takes no list keys"),
    ("G2", [(GMAIN, "    walkValueOrigin(r, reverse = c.name == \"debugger.reverse-origin\"))",
             "    traceGesture(\"not available\"))")],
     [(PLAN, PLAN_WALK)],
     "E: GPUI does not dispatch o / Shift+O"),
    ("G3", [(LEAVES, "        let onHop = row.selected and vm.selectedHop.val == i",
             "        let onHop = false")],
     [(PLAN, PLAN_KEYS)],
     "GPUI does not draw the cursor on a hop"),
    ("G4", [(GMAIN, "  if operation == \"context-menu.open\":\n    openStateRowMenu(r)",
             "  if false:\n    openStateRowMenu(r)")],
     [(PLAN, PLAN_MENU)],
     "E: GPUI's Menu opens no row menu"),
    ("G5", [(GMAIN, "    vm.selectedHop.val = min(vm.selectedHop.val,",
             "    vm.selectedHop.val = -1 + 0 * min(vm.selectedHop.val,")],
     [(PLAN, PLAN_KEYS)],
     "GPUI drops the hop cursor at the stop a seek from the hop makes"),
    # ---- the desktop -----------------------------------------------------------
    ("D1", [(ROUTER, "  if res.operation == \"variables.show-value-origin\":",
             "  if false:")],
     [(SPEC, None)],
     "the desktop's Ctrl+Shift+O on a variable does nothing"),
    ("D2", [(ROUTER, "  if res.operation == \"context-menu.open\" and openContextMenuOfFocus():",
             "  if false and openContextMenuOfFocus():")],
     [(SPEC, None)],
     "the desktop's Menu opens no menu"),
    # ---- the lane runner's specification checkout --------------------------------
    ("L1", [(SPECDIR, "\t\t_rel=\"$(_ct_specs_manifest_field \"${_ws}\" path)\"",
             "\t\t_rel=\"\"")],
     [(PATHS, "LaneSpecCheckoutResolution.test_manifest_path_is_followed")],
     "the workspace manifest's path for the specification repo is ignored"),
    ("L2", [(LANE, "elif [ -n \"${_ct_spec_readers}\" ]; then", "elif false; then")],
     [(PATHS, None)],
     "a lane with spec-reading suites and no checkout compiles them anyway"),
    ("L3", [(SPECDIR, "\t\t\tif _snap=\"$(_ct_specs_snapshot \"${_cand}\" \"${_branch}\")\"; then",
             "\t\t\tif false; then")],
     [(PATHS, None)],
     "a shared checkout on an old-layout branch is not read at the manifest's branch"),
    # ---- the declared survivor ----------------------------------------------------------
    ("N1", [(KEYS, "    if stops.len == 0:", "    if stops.len < 1:")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {KEYS, CUA, EMACS, NAV, KEYNAMES, RUNTIME, VARS, TSESSION}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {KEYS, CUA, EMACS, NAV, KEYNAMES, GMAIN, LEAVES}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {KEYS, CUA, EMACS, NAV, KEYNAMES, DOMKEYS, ROUTER}
  # Subjects compiled into the desktop's bundle.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}
PYTHON_SUITES = {PATHS}

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
    if suite == VMU or suite == ORACLE:
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
        f.write("# Control digests for run-plat70e-origin-mutations.py — the\n"
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
    return build_with("PLAT70E_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70E_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70E_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70E_DESKTOP_TEST")
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


def run_suite(suite, test_filter):
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
            backups[rel] = path.with_name(path.name + ".plat70ebak")
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
