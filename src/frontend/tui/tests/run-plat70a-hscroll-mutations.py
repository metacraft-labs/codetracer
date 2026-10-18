#!/usr/bin/env python3
"""PLAT-70 Part A — the mutation harness for horizontal scrolling.

Each arm plants ONE defect in the shared model (`horizontal_scroll.nim`,
`editing_core.nim`'s per-line widths), a keymap, the terminal's decoder,
runtime or Terminal Output geometry, the remembered setting, or the GPUI
window; REBUILDS the shipped `codetracer-tui` / `codetracer-gpui` when the
defect is compiled into a binary an arm is graded through; runs the suites
that must catch it; and requires RED — with the failure the first run
recorded (`plat70a-hscroll-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-68's harness's, clause for clause: committed control
digests over subjects AND suites (§16c), a needle scan that gates
re-recording (§39a), `because` derived from a run, rc 124 is a hang (§1),
per-arm restore verification, one declared behaviour-preserving survivor,
and `ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT70A_BUILD_TUI` / `$PLAT70A_BUILD_GPUI` when set (a
worktree whose submodules `just build-tui` refuses), else the `just`
recipes.

Usage:
    run-plat70a-hscroll-mutations.py [--only V1,D1] [--derive]
    run-plat70a-hscroll-mutations.py --needle-scan
    run-plat70a-hscroll-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70a-hscroll-mutation-control.sha256"
BECAUSE = HERE / "plat70a-hscroll-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70a-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
MODEL = "src/frontend/viewmodel/viewmodels/horizontal_scroll.nim"
CORE = "src/frontend/viewmodel/editing_core.nim"
PREFS = "src/frontend/viewmodel/host/layout_preferences.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
NAVIGATION = "src/frontend/viewmodel/keymap/navigation_keymap.nim"
MOUSE = "src/frontend/tui/app/input/mouse.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TERMINAL = "src/frontend/tui/app/views/terminal_output_pane.nim"
SOURCE = "src/frontend/tui/app/views/source_pane.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
GPUI_TERMINAL = "src/frontend/gpui/terminal_output_leaf.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70a_horizontal_scroll.nim"
HSC = "src/frontend/tui/tests/test_plat70a_hscroll.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70a_hscroll_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70a_gpui_plan.nim"

SUBJECTS = [MODEL, CORE, PREFS, CUA, NAVIGATION, MOUSE, RUNTIME, TERMINAL,
            SOURCE, GPUI_MAIN, GPUI_TERMINAL]
SUITES = [VMU, HSC, PTY, PLAN]

WHEEL_PTY = "*::the bar, the SGR wheel bytes, track click and drag*"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared model ---------------------------------------------------
    ("V1", [(MODEL, "  v.viewportCols > 0 and v.contentCols > v.viewportCols",
             "  v.viewportCols > 0 and v.contentCols >= v.viewportCols")],
     [(VMU, None)],
     "HO-1: a bar drawn when the content exactly fits"),
    ("V2", [(MODEL, "  CaretFollowMargin* = 4", "  CaretFollowMargin* = 0")],
     [(VMU, None)],
     "§4.5: caret-follow's 4-column margin dropped"),
    ("V3", [(MODEL, "  let rightMargin = max(0, min(margin, lineEndCol - caretCol))",
             "  let rightMargin = margin")],
     [(VMU, None)],
     "§4.5: the margin applied past the line's end: End hides the end"),
    ("V4", [(MODEL, "  w.widest = max(w.widest, cols)", "  w.widest = cols")],
     [(VMU, None)],
     "§4.1: an output pane's width shrinks to the latest line measured"),
    ("V5", [(MODEL, "  v.scrollTo(v.barModel.clickAt(fraction))",
             "  v.scrollTo(int(fraction * float(v.contentCols)))")],
     [(VMU, None)],
     "HO-3: a track press puts its column at the left edge, not centred"),
    ("V6", [(CORE, "      d.remeasure(before, d.timeline.text, cs)",
             "      discard")],
     [(VMU, None)],
     "§4.1: an edit does not re-measure its lines: the width goes stale"),
    ("V7", [(MODEL, "  if f.armed and f.line == line and f.column == caretCol:",
             "  if false:")],
     [(VMU, None)],
     "§4.5: the view follows the caret on every draw, not on a caret move"),
    ("W1", [(MODEL, "  WheelColumns* = 6", "  WheelColumns* = 3")],
     [(VMU, None)],
     "§4.3: a notch is 3 columns, not Vim's 6"),
    # ---- keymaps --------------------------------------------------------------
    ("K1", [(CUA, "    BaseRow(chords: \"Left\", operation: \"view.scroll-left\", whenText: OutputPanesWhen,",
             "    BaseRow(chords: \"Left\", operation: \"view.scroll-left\", whenText: \"\",")],
     [(VMU, None)],
     "§4.4: CUA's Left scrolls the view everywhere, not in the output panes"),
    ("K2", [(NAVIGATION, "            whenText: \"!(\" & OutputPanesWhen & \")\"),",
             "            whenText: \"\"),")],
     [(VMU, None)],
     "§4.4: Vim's `z` maximize shadows `z h` / `z l` in the output panes"),
    # ---- the terminal ---------------------------------------------------------
    ("D1", [(MOUSE, "      of 2: mbWheelLeft", "      of 2: mbWheelUp")],
     [(PTY, WHEEL_PTY)],
     "HO-6: SGR 66 decoded as the vertical wheel again (the real pty's rows)"),
    ("C1", [(RUNTIME, "    if not bar.shown or event.row != bar.row:",
             "    if true:"),
            (SOURCE, "  if bar.shown and row == bar.row:",
             "  if false:")],
     [(PTY, WHEEL_PTY)],
     "HO-4: a press on the editor's bar is a click on the text: the caret moves"),
    ("D2", [(RUNTIME, "      if event.kind == mekPress and event.button in {mbWheelUp, mbWheelDown}:",
             "      if false:")],
     [(PTY, WHEEL_PTY)],
     "§4.3: a delivered Shift + wheel stands down instead of scrolling sideways"),
    ("T1", [(TERMINAL, "      result.contentRows -= 1", "      discard")],
     [(HSC, None)],
     "HO-7: Terminal Output's vertical track runs down into the bar's row"),
    ("M1", [(PREFS, "  defaultLayoutSettings(overflowMarkers = product == lpTerminal)",
             "  defaultLayoutSettings(overflowMarkers = false)")],
     [(HSC, None)],
     "§4.6: the terminal's overflow markers default off"),
    ("S1", [(GPUI_TERMINAL, "    let f = trackFractionAt(local, lay.hbar.w)",
             "    let f = float(local) / float(lay.hbar.w)")],
     [(HSC, None)],
     "HO-2: a front-end divides by the bar's extent itself"),
    # ---- GPUI -------------------------------------------------------------------
    ("G1", [(GPUI_MAIN, "  if shift and dx == 0.0: (0.0, dy) else: (dy, dx)",
             "  (dy, dx)")],
     [(PLAN, None)],
     "§4.3: GPUI's Shift + wheel scrolls rows, not columns"),
    ("G2", [(GPUI_TERMINAL, "                           w: result.content.w, h: TerminalTrackPx)",
             "                           w: inner.w, h: TerminalTrackPx)")],
     [(PLAN, None)],
     "HO-7: GPUI's Terminal Output bar runs under the vertical track's corner"),
    # ---- the declared survivor ---------------------------------------------------
    ("N1", [(MODEL, "  v.viewportCols > 0 and v.contentCols > v.viewportCols",
             "  v.contentCols > v.viewportCols and v.viewportCols > 0")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {MODEL, CORE, PREFS, CUA, NAVIGATION, MOUSE, RUNTIME, TERMINAL,
             SOURCE}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {MODEL, CORE, PREFS, CUA, NAVIGATION, GPUI_MAIN, GPUI_TERMINAL}
  # Subjects compiled into `codetracer-gpui`.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}


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
        f.write("# Control digests for run-plat70a-hscroll-mutations.py — the\n"
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
    return build_with("PLAT70A_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70A_BUILD_GPUI", "build-gpui")


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the screen;
    the recorded cause keeps the condition and drops the snapshot."""
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def run_suite(suite, test_filter):
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
            backups[rel] = path.with_name(path.name + ".plat70abak")
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
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
