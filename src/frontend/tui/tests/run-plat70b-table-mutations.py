#!/usr/bin/env python3
"""PLAT-70 Part B — the mutation harness for the table panes (truncation,
the full value, resizable columns).

Each arm plants ONE defect in the shared ViewModel (`table_overflow.nim`,
`event_log_vm.nim`'s widths, the value budget), a keymap row, the terminal's
painters or runtime, the GPUI window, or the desktop's DOM pass; REBUILDS the
shipped `codetracer-tui` / `codetracer-gpui` / desktop when the defect is
compiled into a binary an arm is graded through; runs the suites that must
catch it; and requires RED — with the failure the first run recorded
(`plat70b-table-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-70 Part A's harness's, clause for clause: committed
control digests over subjects AND suites (§16c), a needle scan that gates
re-recording (§39a), `because` derived from a run, rc 124 is a hang (§1),
per-arm restore verification, one declared behaviour-preserving survivor,
and `ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT70B_BUILD_TUI` / `$PLAT70B_BUILD_GPUI` /
`$PLAT70B_BUILD_DESKTOP` when set (a worktree whose submodules the `just`
recipes refuse, or a desktop built in a scratch workspace), else `just
build-tui` / `just build-gpui` / `just build-once`. The desktop arms are
graded by the Electron spec, run by `$PLAT70B_DESKTOP_TEST` when set, else
`npx playwright test` in `src/tests/gui`.

Usage:
    run-plat70b-table-mutations.py [--only M1,T1] [--derive]
    run-plat70b-table-mutations.py --needle-scan
    run-plat70b-table-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70b-table-mutation-control.sha256"
BECAUSE = HERE / "plat70b-table-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70b-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
MODEL = "src/frontend/viewmodel/viewmodels/table_overflow.nim"
EVENT_VM = "src/frontend/viewmodel/viewmodels/event_log_vm.nim"
SURFACES = "src/common/value_presentation/surfaces.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
EMACS = "src/frontend/viewmodel/keymap/emacs_keymap.nim"
NAVIGATION = "src/frontend/viewmodel/keymap/navigation_keymap.nim"
BORDERS = "src/frontend/tui/app/views/borders.nim"
TUI_EVENTS = "src/frontend/tui/app/views/event_log.nim"
TUI_CALLS = "src/frontend/tui/app/views/call_trace.nim"
TUI_SHELL = "src/frontend/tui/app/views/shell.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
GPUI_LEAVES = "src/frontend/gpui/app/leaves.nim"
DOM = "src/frontend/viewmodel/views/table_overflow_dom.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70b_table_overflow.nim"
TBL = "src/frontend/tui/tests/test_plat70b_tables.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70b_tables_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70b_gpui_plan.nim"
SPEC = "src/tests/gui/tests/layout/plat70b-table-overflow.spec.ts"

SUBJECTS = [MODEL, EVENT_VM, SURFACES, CUA, EMACS, NAVIGATION, BORDERS,
            TUI_EVENTS, TUI_CALLS, TUI_SHELL, RUNTIME, GPUI_MAIN, GPUI_LEAVES,
            DOM]
SUITES = [VMU, TBL, PTY, PLAN, SPEC]

PTY_MAIN = "*::HO-8, hover, the `…` press and the detail, list.copy"
PTY_WIDTHS = "*::the Event Log's separators, the minimum, :column-width, the document"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared model ---------------------------------------------------
    ("M1", [(MODEL, "  result.truncated = clipped", "  result.truncated = true")],
     [(VMU, None)],
     "HO-8: a `…` on a cell that fits"),
    ("M2", [(MODEL, "  max(1, min(DetailLineCap, bodyRows div 2))",
             "  max(1, bodyRows)")],
     [(VMU, None)],
     "§5.3: the detail is not capped at min(10, half the body)"),
    ("M3", [(MODEL, "  if nowMs - h.sinceMs >= HoverDelayMs:",
             "  if nowMs - h.sinceMs > HoverDelayMs:")],
     [(VMU, None)],
     "§5.3: the tooltip waits longer than 500 ms"),
    ("M4", [(MODEL, "  if pane.len > 0 and truncated:", "  if pane.len > 0:")],
     [(VMU, None)],
     "§5.3: resting on a cell that fits starts the tooltip's clock"),
    ("M5", [(MODEL, "  max(MinColumnCells, cells)", "  max(1, cells)")],
     [(VMU, None)],
     "§5.2: a column narrower than 3 cells"),
    ("M6", [(MODEL, "  if d.isOpen(pane, key) and (column.len == 0 or d.column == column):",
             "  if false:")],
     [(VMU, None)],
     "§5.3: pressing an open row's `…` again does not close its detail"),
    ("M7", [(MODEL, "  max(1, min(TooltipMaxColumns, windowCols))",
             "  max(1, windowCols)")],
     [(VMU, None)],
     "§5.3: the tooltip is not wrapped at 80 columns"),
    ("M8", [(MODEL, "    if cells < MinColumnCells:", "    if cells < 0:")],
     [(VMU, None)],
     "§5.2: a remembered width under the minimum is accepted"),
    ("M9", [(MODEL, "        line = line[lastSpace + 1 .. ^1]", "        line = \"\"")],
     [(VMU, None)],
     "§5.3: wrapping drops the word that moved down"),
    ("M10", [(MODEL, "  let kept = max(0, cap - 1)", "  let kept = cap")],
     [(VMU, None)],
     "§5.3: the hint is an eleventh line"),
    ("B1", [(SURFACES, "  Budget(name: \"table-full\", lines: 1, cells: 0,",
             "  Budget(name: \"table-full\", lines: 1, cells: 80,")],
     [(VMU, None)],
     "§5.3: the full value is itself cut (at 80 cells)"),
    # ---- the widths, in the model --------------------------------------------
    ("W1", [(EVENT_VM, "      result.widths[col] = clampColumnCells(e.cells)",
             "      discard")],
     [(VMU, None)],
     "HO-9: the remembered widths are not applied"),
    ("W2", [(EVENT_VM, "  c.setColumnWidth(col, c.columnWidthOr(col, current) + delta)",
             "  c.setColumnWidth(col, current)")],
     [(VMU, None)],
     "§5.2: table.resize-column does not resize"),
    # ---- keymaps ---------------------------------------------------------------
    ("K1", [(CUA, "    BaseRow(chords: \"Ctrl+K Ctrl+I\", operation: \"list.show-detail\", whenText: \"listFocus\",",
             "    BaseRow(chords: \"Ctrl+K Ctrl+Y\", operation: \"list.show-detail\", whenText: \"listFocus\",")],
     [(VMU, None)],
     "CUA §3.11: Ctrl+K Ctrl+I does not show the detail"),
    ("K2", [(EMACS, "    BaseRow(chords: \"Ctrl+H .\", operation: \"list.show-detail\", whenText: \"listFocus\",",
             "    BaseRow(chords: \"Ctrl+H ,\", operation: \"list.show-detail\", whenText: \"listFocus\",")],
     [(VMU, None)],
     "Emacs §3.13: Ctrl+H . does not show the detail"),
    ("K3", [(NAVIGATION, "    BaseRow(chords: \"Shift+K\", operation: \"list.show-detail\", table: G, navModes: N,\n            whenText: \"listFocus\"),",
             "    BaseRow(chords: \"Shift+K\", operation: \"list.show-detail\", table: G, navModes: N,\n            whenText: \"\"),")],
     [(VMU, None)],
     "Vim: Shift+K shows a detail in the editor too"),
    # ---- the terminal ------------------------------------------------------------
    ("T1", [(BORDERS, "  (\"█\", \"#\"), (\"…\", \"~\"), (\"·\", \".\"),",
             "  (\"█\", \"#\"), (\"…\", \"…\"), (\"·\", \".\"),")],
     [(TBL, None)],
     "the ASCII tier draws `…`, not `~`"),
    ("T2", [(TUI_EVENTS, "    if col == at:\n      return (true, c)",
             "    if col == at + 1:\n      return (true, c)")],
     [(TBL, None)],
     "§5.2: the Event Log's separators hit-tested off their drawn column"),
    ("T3", [(TUI_EVENTS, "    let w = model.columns.columnWidthOr(\n      col, columnCells(col, k == shown.high, startCol + width - at))",
             "    let w = columnCells(col, k == shown.high, startCol + width - at)")],
     [(TBL, None)],
     "HO-9: the terminal draws its defaults, not the model's widths"),
    ("T4", [(TUI_CALLS, "    let fitted = fitCell(full, stop - textAt, terminalMeasure)",
             "    let fitted = fitCell(full, stop - textAt + 2, terminalMeasure)")],
     [(TBL, None)],
     "HO-8: the Call Trace's row is fitted at a width other than its own"),
    ("T5", [(TUI_SHELL, "  let row = if below + h <= height - 1: below else: max(0, t.row - h)",
             "  let row = below")],
     [(TBL, None)],
     "§5.3: the tooltip runs off the screen's foot"),
    ("T6", [(RUNTIME, "  discard rt.openDetail(hit.pane, hit.cut.key, hit.cut.column)\n  outcome.repaint = true\n  true",
             "  outcome.repaint = true\n  true")],
     [(PTY, PTY_MAIN)],
     "§5.3: a press on the `…` (real SGR bytes) opens no detail"),
    ("T7", [(RUNTIME, "  if not rt.app.cellHover.tick(nowMs):\n    return false",
             "  if true:\n    return false")],
     [(PTY, PTY_MAIN)],
     "§5.3: the resting pointer's tooltip never shows (a real pty)"),
    # ---- GPUI --------------------------------------------------------------------
    ("G1", [(GPUI_MAIN, "  if c.button == gbLeft and tableGestureAt(c.x, c.y):",
             "  if false:")],
     [(PLAN, None)],
     "§5.3: the row under a `…` press jumps the debugger (and a separator's header orders the log)"),
    ("G2", [(GPUI_MAIN, "  vm.columns.val = vm.columns.val.withColumnWidths(stored.entries)",
             "  discard stored")],
     [(PLAN, None)],
     "HO-9: the window opens at its defaults, not the remembered widths"),
    ("G3", [(GPUI_MAIN, "    rememberEventLogWidths(vm)\n    wireClicks(r)",
             "    wireClicks(r)")],
     [(PLAN, None)],
     "HO-9: a drag's width is kept in the window only, never written"),
    ("G4", [(GPUI_MAIN, "  if x != gColumnDrag.startX:", "  if true:")],
     [(PLAN, None)],
     "§5.2: a press and release in place on a separator resizes the column"),
    ("G5", [(GPUI_MAIN, "          return (fullValueText(row.presented, row.whole),",
             "          return (row.whole,")],
     [(PLAN, None)],
     "§5.3: list.copy copies the drawn value, not the whole one"),
    ("G6", [(GPUI_LEAVES, "        if fitted.truncated:\n          r.setAttribute(c, TableCutAttribute, $col)",
             "        if true:\n          r.setAttribute(c, TableCutAttribute, $col)")],
     [(PLAN, None)],
     "HO-8: the window marks every Event Log cell cut"),
    # ---- the desktop -----------------------------------------------------------------
    ("D1", [(DOM, "      let fitted = fitCell(drawn, cell.cellsOf)",
             "      var fitted = fitCell(drawn, cell.cellsOf)\n      fitted.truncated = true")],
     [(SPEC, None)],
     "HO-8: the desktop marks a cell that fits cut"),
    ("D2", [(DOM, "      t.swallowClick = true", "      t.swallowClick = false")],
     [(SPEC, None)],
     "§5.3: the click ending a `…` press reaches the row and jumps"),
    ("D3", [(DOM, "          let whole = t.fullValueOf(cell.parts.key)",
             "          let whole = \"\"")],
     [(SPEC, None)],
     "§5.3: the desktop's cut value reveals only the text it already draws"),
    # ---- the declared survivor ---------------------------------------------------
    ("N1", [(MODEL, "  max(MinColumnCells, cells)", "  max(cells, MinColumnCells)")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {MODEL, EVENT_VM, SURFACES, CUA, EMACS, NAVIGATION, BORDERS,
             TUI_EVENTS, TUI_CALLS, TUI_SHELL, RUNTIME}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {MODEL, EVENT_VM, SURFACES, CUA, EMACS, NAVIGATION, GPUI_MAIN,
           GPUI_LEAVES}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {MODEL, EVENT_VM, SURFACES, CUA, EMACS, NAVIGATION, DOM}
  # Subjects compiled into the desktop's bundle.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}


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
        f.write("# Control digests for run-plat70b-table-mutations.py — the\n"
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
    return build_with("PLAT70B_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70B_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70B_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70B_DESKTOP_TEST")
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


def run_suite(suite, test_filter):
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
            backups[rel] = path.with_name(path.name + ".plat70bbak")
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
