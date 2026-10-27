#!/usr/bin/env python3
"""PLAT-70 Part I — the mutation harness for fit-or-scroll (the table panes'
column widths from their minimum and preferred widths, and the horizontal
bar only when the minimums do not fit; Horizontal-Overflow.md §5.5).

Each arm plants ONE defect in the shared solver (`table_fit.nim`, the Event
Log's declaration in `event_log_vm.nim`), the terminal's painters or runtime,
the GPUI window, or the desktop's DOM pass, view or key router (the residuals
closed after Part I: the bar that appears is woken, GPUI's bars answer a
press and a grab, the palette's `view.*` reaches the table panes on every
front-end); REBUILDS the shipped
`codetracer-tui` / `codetracer-gpui` / desktop when the defect is compiled
into a binary an arm is graded through; runs the suites that must catch it;
and requires RED — with the failure the first run recorded
(`plat70i-fit-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-70 Part B's harness's (`src/frontend/tui/tests/
run-plat70b-table-mutations.py`), clause for clause: committed control
digests over subjects AND suites (§16c), a needle scan that gates
re-recording (§39a), `because` derived from a run, rc 124 is a hang (§1),
per-arm restore verification, one declared behaviour-preserving survivor,
and `ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT70I_BUILD_TUI` / `$PLAT70I_BUILD_GPUI` /
`$PLAT70I_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui`
/ `just build-once`. The desktop arms are graded by the Electron spec, run by
`$PLAT70I_DESKTOP_TEST` when set, else `npx playwright test` in
`src/tests/gui`.

Usage:
    run-plat70i-fit-mutations.py [--only F1,T1] [--derive]
    run-plat70i-fit-mutations.py --needle-scan
    run-plat70i-fit-mutations.py --record-control-hashes
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

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat70i-fit-mutation-control.sha256"
BECAUSE = HERE / "plat70i-fit-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70i-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
FIT = "src/frontend/viewmodel/viewmodels/table_fit.nim"
EVENT_VM = "src/frontend/viewmodel/viewmodels/event_log_vm.nim"
TUI_EVENTS = "src/frontend/tui/app/views/event_log.nim"
TUI_CALLS = "src/frontend/tui/app/views/call_trace.nim"
TUI_VARS = "src/frontend/tui/app/views/variables.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
GPUI_LEAVES = "src/frontend/gpui/app/leaves.nim"
DOM = "src/frontend/viewmodel/views/table_fit_dom.nim"
DESKTOP_EVENTS = "src/frontend/viewmodel/views/isonim_event_log_view.nim"
KEY_ROUTER = "src/frontend/ui/key_router.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70i_table_fit.nim"
TBL = "src/frontend/tui/tests/test_plat70i_fit_layout.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70i_fit_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70i_gpui_plan.nim"
SPEC = "src/tests/gui/tests/layout/plat70i-fit-or-scroll.spec.ts"
HSB = "src/frontend/tui/tests/test_plat70h_scrollbars.nim"

SUBJECTS = [FIT, EVENT_VM, TUI_EVENTS, TUI_CALLS, TUI_VARS, RUNTIME,
            GPUI_MAIN, GPUI_LEAVES, DOM, DESKTOP_EVENTS, KEY_ROUTER]
SUITES = [VMU, TBL, PTY, PLAN, SPEC, HSB]

PTY_EVENTS = "*::the Event Log: no bar while the columns fit; a wide column scrolls"
PTY_CALLS = "*::HO-15: a deep call scrolls the Call Trace to its whole name"
HSB_APPEARS = "*::a table pane's sideways bar that APPEARS fades in (§7.5, HO-11)"
HSB_PALETTE = "*::the palette's View: Scroll Right / Left reach a table pane (§4.4, §5.5)"
PLAN_BAR = "*::the Event Log's bar answers a press on its track and a thumb grab, offset kept"
PLAN_CALL_BAR = "*::the Call Trace's bar answers a press on its track"
PLAN_PALETTE = "*::the palette's View: Scroll Right reaches the focused table pane"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared solver --------------------------------------------------
    ("F1", [(FIT, "      result.widths[i] = prefs[i] + extra[i]",
             "      result.widths[i] = prefs[i]")],
     [(VMU, None)],
     "§5.5.2 FIT: the slack is not given to the flex columns"),
    ("F2", [(FIT, "      result.widths[i] = floors[i] + given[i]",
             "      result.widths[i] = max(0, floors[i] + given[i] - 1)")],
     [(VMU, None)],
     "HO-12: SHRINK draws a column below its floor"),
    ("F3", [(FIT, "  ## HO-11: the bar exists iff the floors do not fit.\n  f.mode == fmScroll",
             "  ## HO-11: the bar exists iff the floors do not fit.\n  f.mode != fmFit")],
     [(VMU, None)],
     "HO-11: the bar is shown in SHRINK"),
    ("F4", [(FIT, "    result.mode = fmScroll",
             "    result.mode = fmShrink")],
     [(VMU, None)],
     "HO-11: the bar is never shown — floors wider than the pane are not scrolled"),
    ("F5", [(FIT, "  if c.userUnits > 0: c.userUnits\n  elif c.neverCut or c.fixed: max(0, c.preferredUnits)",
             "  if false: c.userUnits\n  elif c.neverCut or c.fixed: max(0, c.preferredUnits)")],
     [(VMU, None)],
     "HO-14: a column the user resized shrinks below the user's width"),
    ("F6", [(FIT, "  elif c.neverCut or c.fixed: max(0, c.preferredUnits)",
             "  elif c.fixed: max(0, c.preferredUnits)")],
     [(VMU, None)],
     "§5.5.1: a never-cut column (a number) is cut"),
    ("F7", [(FIT, "  CompositeRow(floorUnits: max(0, indentUnits) + head + more,",
             "  CompositeRow(floorUnits: head + more,")],
     [(VMU, None), (TBL, None)],
     "§5.5.3: a composite row's floor leaves out its indent (a deep call is never scrolled to)"),
    ("F8", [(FIT, "  v.setViewport(f.viewportUnits)",
             "  discard")],
     [(VMU, None)],
     "§4.1: the view is not settled over the pane's width"),
    ("E1", [(EVENT_VM, "      f.flex = 1",
             "      f.flex = 0")],
     [(VMU, None)],
     "§5.5.3: the Event Log's output column takes no slack"),
    ("E2", [(EVENT_VM, "      f.userUnits = c.widths[col] * userUnit",
             "      discard")],
     [(VMU, None), (TBL, None)],
     "HO-14: the Event Log's remembered widths are not the solver's"),
    # ---- the terminal ---------------------------------------------------------
    ("T1", [(TUI_EVENTS, "    g.copySlice(area.row + 1, area.col, table, 1, left, width)",
             "    g.copySlice(area.row + 1, area.col, table, 1, 0, width)")],
     [(TBL, None)],
     "the Event Log's header is drawn from column 0 while the rows scroll"),
    ("T2", [(TUI_EVENTS, "           width, GapCells)",
             "           10_000, GapCells)")],
     [(TBL, None)],
     "the terminal's Event Log keeps fixed widths (it never shrinks or scrolls)"),
    ("T3", [(TUI_CALLS, "    rows.add callFitRow(r.rowStartCol, cellWidthOf(call.callee),",
             "    rows.add callFitRow(0, cellWidthOf(call.callee),")],
     [(TBL, None)],
     "HO-15: the terminal's Call Trace measures its floor without the indent"),
    ("T4", [(TUI_EVENTS, "    paintHorizontalBar(g, geo.barRow, area.col, width, geo.view.barModel)",
             "    discard geo.view")],
     [(PTY, PTY_EVENTS)],
     "HO-11: the Event Log in SCROLL draws no bar (a real pty)"),
    ("T5", [(RUNTIME, "  of paneEventLog, paneCalltrace, paneState: rt.tableViewOf(pane).view.overflows",
             "  of paneEventLog, paneCalltrace, paneState: false")],
     [(PTY, PTY_EVENTS)],
     "§4.3: the horizontal wheel (SGR 67) does not scroll a table pane"),
    ("T6", [(TUI_VARS, "  fitTable([name, value], max(0, fields), gap = 1)",
             "  fitTable([name, value], 10_000, gap = 1)")],
     [(TBL, None)],
     "the terminal's Variables pane never scrolls"),
    # ---- GPUI -------------------------------------------------------------------
    ("G1", [(GPUI_LEAVES, "      r.setStyle(el, \"margin-left\", $(-hLeft) & \"px\")",
             "      discard el")],
     [(PLAN, None)],
     "the GPUI Event Log's header and rows do not move with its view"),
    ("G2", [(GPUI_LEAVES, "    r.setStyle(list, \"margin-left\", $(-hLeft) & \"px\")",
             "    discard list")],
     [(PLAN, None)],
     "HO-15: the GPUI Call Trace's rows do not move with its view"),
    ("G3", [(GPUI_MAIN, "    if dx != 0.0 and onPane in [$paneCalltrace, $paneEventLog]:",
             "    if false:")],
     [(PLAN, None)],
     "§4.3: the GPUI window's horizontal wheel does not scroll a table pane"),
    ("G4", [(GPUI_LEAVES, "           max(0, paneW - TableScrollbarPx), gap = 0)",
             "           10_000, gap = 0)")],
     [(PLAN, None)],
     "the GPUI Event Log keeps its widths inside any pane (never scrolls)"),
    # ---- the desktop --------------------------------------------------------------
    ("D1", [(DESKTOP_EVENTS, "  vm.tableMetrics.val.cells > 0 and vm.desktopFit.overflows",
             "  false")],
     [(SPEC, None)],
     "HO-14: the desktop Event Log never scrolls"),
    ("D2", [(DOM, "    if fit.overflows:\n      scroller.setStyle(\"overflow-x\", \"auto\")",
             "    if true:\n      scroller.setStyle(\"overflow-x\", \"auto\")")],
     [(SPEC, None)],
     "OQ-H5: the desktop Call Trace scrolls sideways while its floors fit"),
    ("D3", [(DOM, "        if left > 0.0:",
             "        if false:")],
     [(SPEC, None)],
     "the desktop Event Log's header does not follow the body's sideways scroll"),
    # ---- the residuals closed after Part H / Part I --------------------------------
    ("W1", [(RUNTIME, "       b.pane in TableViewPanes and not rt.scrollbars.present[b.pane][b.axis]:",
             "       false:")],
     [(HSB, HSB_APPEARS)],
     "§7.5: a table pane's sideways bar that appears (its columns grew past the pane) is not woken"),
    ("T7", [(RUNTIME, "      discard rt.runViewOperation(name, outcome)",
             "      discard name")],
     [(HSB, HSB_PALETTE)],
     "§4.4: the palette's View: Scroll Right does not reach a table pane in the terminal"),
    ("G5", [(GPUI_MAIN, "    if pressTableHBar(r, x, y):",
             "    if false and pressTableHBar(r, x, y):")],
     [(PLAN, PLAN_BAR), (PLAN, PLAN_CALL_BAR)],
     "§5.5.4: the GPUI table panes' bars answer no press (wheel only)"),
    ("G6", [(GPUI_MAIN, "              else: v.dragThumb(v.barModel.heldThumbStart(f))",
             "              else: v.dragThumb(f - v.barModel.thumbLength / 2.0)")],
     [(PLAN, PLAN_BAR)],
     "Scrollbar-Scrubbers §3.3: a GPUI table bar's grabbed thumb jumps to centre on the pointer (the grab offset dropped)"),
    ("G7", [(GPUI_MAIN, "      runGpuiViewOperation(r, name)",
             "      discard name")],
     [(PLAN, PLAN_PALETTE)],
     "§4.4: the palette's View: Scroll Right does not reach a GPUI table pane"),
    ("D4", [(KEY_ROUTER, "    var scroller = if id.len > 0: tableScrollerOf(cstring(id)) else: nil",
             "    var scroller: JsObject = nil")],
     [(SPEC, None)],
     "§4.4: the palette's View: Scroll Right does not reach a desktop table pane"),
    # ---- the declared survivor ---------------------------------------------------
    ("N1", [(FIT, "  v.setContent(if f.overflows: f.contentUnits else: 0)",
             "  v.setContent(f.contentUnits)")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR (outside SCROLL the table is never wider than the pane)"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {FIT, EVENT_VM, TUI_EVENTS, TUI_CALLS, TUI_VARS, RUNTIME}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {FIT, EVENT_VM, GPUI_MAIN, GPUI_LEAVES}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {FIT, EVENT_VM, DOM, DESKTOP_EVENTS, KEY_ROUTER}
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
        f.write("# Control digests for run-plat70i-fit-mutations.py — the\n"
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
    return build_with("PLAT70I_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70I_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70I_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70I_DESKTOP_TEST")
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
    graded = sorted({(s, flt) for arm in selected for s, flt in arm[2]},
                    key=lambda p: (p[0], p[1] or ""))
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
            backups[rel] = path.with_name(path.name + ".plat70ibak")
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
