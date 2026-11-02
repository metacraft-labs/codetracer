#!/usr/bin/env python3
"""PLAT-55 — the mutation harness for the Problems pane on the terminal and in
the GPUI window (codetracer-pm `spec/Planned-Features/Build-Output-Pane.md`
§3.3, `Edit-Mode-Toolbar.md` §11): the words and the list every front-end
draws (moved into `errors_vm`), the one rule from a build's lines to its rows
(`build_diagnostics`), the native reader of a build (`tui/host/build_problems`),
the terminal's painter, runtime, host source, layout and loop, the GPUI leaf
and window, the shared Edit-mode footer, the vocabulary view, and the
desktop's Build component.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` / desktop when the defect is compiled into a binary an arm
is graded through; runs the suites that must catch it; and requires RED —
with the failure the first run recorded (`plat55-problems-mutation-
because.json`, derived with `--derive`).

The discipline is PLAT-53's harness's (`run-plat53-test-results-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT55_BUILD_TUI` / `$PLAT55_BUILD_GPUI` /
`$PLAT55_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`; the suites compile with `$PLAT55_NIM` when set, else
`nim`. The desktop arm is graded by the Electron capture spec, run by
`$PLAT55_DESKTOP_TEST` when set, else `npx playwright test` in `src/tests/gui`
(a DISPLAY is needed). Every suite builds the real PLAT-55 crate with the
real `nargo`, which must be on PATH, as the lanes require.

Usage:
    run-plat55-problems-mutations.py [--only V1,T1] [--derive]
    run-plat55-problems-mutations.py --needle-scan
    run-plat55-problems-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat55-problems-mutation-control.sha256"
BECAUSE = HERE / "plat55-problems-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat55-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/errors_vm.nim"
RULE = "src/frontend/viewmodel/viewmodels/build_diagnostics.nim"
READER = "src/frontend/tui/host/build_problems.nim"
SOURCE = "src/frontend/tui/host/problems_source.nim"
TUI_PANE = "src/frontend/tui/app/views/problems_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
LAYOUT = "src/frontend/headless_app/layout_model.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
GPUI_LEAF = "src/frontend/gpui/problems_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP_BUILD = "src/frontend/ui/build.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat55_problems.nim"
TBL = "src/frontend/tui/tests/test_plat55_problems.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat55_problems_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat55_gpui_plan.nim"
SPEC = "src/tests/gui/tests/problems-pane/plat55-problems-capture.spec.ts"

SUBJECTS = [VM, RULE, READER, SOURCE, TUI_PANE, RUNTIME, SHELL, PROFILE,
            LAYOUT, TUI_MAIN, GPUI_LEAF, GPUI_MAIN, VOCAB, DESKTOP_BUILD]
SUITES = [VMU, TBL, PTY, PLAN, SPEC]

TBL_BUILD = "*::a real failing build: rows, highlight, F8, a press, buttons, keys"
PLAN_ROWS = "*::a real failing build: the desktop's rows, counts and buttons"
PLAN_BUTTONS = "*::the Errors filter and Group by File, pressed where drawn"
PLAN_PRESS = "*::a press on a row opens its file at its line; next error; the keys"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the words and the list (the ViewModel) ---------------------------
    ("V1", [(VM, '  of blsWarning: "\\xe2\\x9a\\xa0"', '  of blsWarning: "\\xe2\\x97\\x8f"')],
     [(VMU, None)],
     "§3.3: a warning's icon is the error's"),
    ("V2", [(VM, "      order.add entry.problem.path", "      order.insert(entry.problem.path, 0)")],
     [(VMU, None), (TBL, TBL_BUILD)],
     "§3.3: Group by File lists the files out of the order they first appear"),
    ("V3", [(VM, '  if p.col >= 0: $p.line & ":" & $p.col', '  if p.col >= 0: $p.line')],
     [(VMU, None), (TBL, TBL_BUILD)],
     "§3.3: a row's location drops its column"),
    ("V4", [(VM, "              minUnits: ProblemMessageFloor, flex: 1)], viewport, gap)",
             "              minUnits: ProblemMessageFloor)], viewport, gap)")],
     [(VMU, None)],
     "§3.3: the message is not given the row's slack"),
    # ---- the rule from a build's lines to rows ----------------------------
    ("B1", [(RULE, '  "Hint" in raw', '  false')],
     [(VMU, None)],
     "§3.4: a Nim `Hint:` line becomes a Problems row"),
    ("B2", [(RULE, "      severity: severityOf(result.scanned.severity),",
             "      severity: blsError,")],
     [(VMU, None), (TBL, TBL_BUILD), (PLAN, PLAN_ROWS)],
     "§3.4: a warning (keyword on the line above) is listed as an error"),
    ("B3", [(RULE, "    f.vm.clearProblems()", "    discard")],
     [(VMU, None), (TBL, TBL_BUILD)],
     "EMT-D22.7: a new build does not clear the last build's rows"),
    ("B4", [(RULE, "    discard f.vm.highlightFirstError()", "    discard")],
     [(VMU, None), (TBL, TBL_BUILD), (PLAN, PLAN_ROWS)],
     "EMT-D21: a failed build highlights no error"),
    ("B5", [(RULE, "  if path.len == 0 or path.isAbsoluteBuildPath or workingDirectory.len == 0:",
             "  if true:")],
     [(VMU, None), (TBL, TBL_BUILD)],
     "EMT-A36: a relative path is not resolved against the build's directory"),
    # ---- the native reader -------------------------------------------------
    ("H1", [(READER, "    p.consumed = session.received", "    discard")],
     [(TBL, TBL_BUILD)],
     "a line the build wrote is read again on every tick (duplicate rows)"),
    ("H2", [(READER, "  if not fileExists(resolved):", "  if false:")],
     [(TBL, TBL_BUILD)],
     "EMT-D20: a row whose file is gone does not say why"),
    # ---- the terminal's host source and painter ---------------------------
    ("S1", [(SOURCE, "      vm.jumpToProblem(problems[index])", "      discard")],
     [(TBL, TBL_BUILD), (PTY, None)],
     "K35: a press on a row opens nothing"),
    ("S2", [(SOURCE, "  of blsWarning: ptWarning", "  of blsWarning: ptError")],
     [(TBL, TBL_BUILD), (PTY, None)],
     "§3.3: a warning's icon is drawn in the error colour"),
    ("T1", [(TUI_PANE, "        if i < model.filters.len:", "        if i <= model.filters.len:")],
     [(TBL, None)],
     "§3.3: a press on Group by File is read as a filter"),
    ("T2", [(TUI_PANE, "        g.fillSurface(y, area.col, width, 1, ProblemsSelectedSurface)",
             "        discard")],
     [(TBL, None)],
     "§3.3: the selected row is not drawn selected"),
    ("T3", [(TUI_PANE, "    location = max(location, cellWidthOf(r.location))",
             "    location = max(location, 1)")],
     [(TBL, None)],
     "§3.3: the location is cut"),
    # ---- the terminal's runtime, layout and loop ---------------------------
    ("R1", [(RUNTIME, "      rt.problemsCommand(pcmOpen, t.index, outcome)",
             "      rt.problemsCommand(pcmSelect, t.index, outcome)")],
     [(TBL, TBL_BUILD), (PTY, None)],
     "K35: a press on a row selects it and opens nothing"),
    ("R2", [(RUNTIME, "        discard b.beginRevealDock(paneProblems)", "        discard")],
     [(TBL, TBL_BUILD), (PTY, None)],
     "EMT-D22.4: next error does not reveal the docked pane"),
    ("R3", [(RUNTIME, "  if rt.hasDockKeys and rt.dockKeys == paneProblems and not rt.prompt.open and",
             "  if false and rt.hasDockKeys and rt.dockKeys == paneProblems and not rt.prompt.open and")],
     [(TBL, TBL_BUILD)],
     "§3.3: the docked pane, pressed, does not take the arrow keys"),
    ("R4", [(RUNTIME, "    buf.moveCaretTo(max(1, line) - 1, max(1, col) - 1)", "    discard")],
     [(TBL, TBL_BUILD)],
     "K35: the file opens with the caret not at the diagnostic"),
    ("L1", [(LAYOUT, "    if find(tree, d.pane).isNil:", "    if false:")],
     [(TBL, TBL_BUILD), (PTY, None), (PLAN, PLAN_ROWS)],
     "Edit mode docks no footer (the desktop's PROBLEMS is missing)"),
    ("L2", [(PROFILE, "     paneProblems},", "     },"),
            (SHELL, "  elif region.pane == paneProblems and model.problems.loaded:",
             "  elif false:")],
     [(PTY, None)],
     "§3.3: the terminal draws the report leaf, not the pane"),
    ("M1", [(TUI_MAIN, "  let problems = newProblemsSource(rt,\n    proc(path: string; line, col: int): string =\n      rt.openWorkingFileAt(path, line, col))",
             "  let problems = newProblemsSource(rt,\n    proc(path: string; line, col: int): string =\n      \"\")")],
     [(PTY, None)],
     "K35: the Edit loop says it opened the file and opens nothing"),
    # ---- the GPUI leaf and window -----------------------------------------
    ("G1", [(GPUI_LEAF, "  of blsError: ProblemsErrorColour", "  of blsError: ProblemsTextColour")],
     [(PLAN, PLAN_ROWS)],
     "§3.3: the GPUI error icon is not in the desktop's error colour"),
    ("G2", [(GPUI_LEAF, "        return GProblemsHit(kind: gpFilter, index: i)",
             "        return GProblemsHit(kind: gpFilter, index: 0)")],
     [(PLAN, PLAN_BUTTONS)],
     "§3.3: a press on the GPUI Errors button selects All"),
    ("G3", [(GPUI_MAIN, "    openArm.doc.moveCaretTo(max(1, line) - 1, max(1, col) - 1)",
             "    discard")],
     [(PLAN, PLAN_PRESS)],
     "K35: the GPUI editor opens the file with the caret not at the diagnostic"),
    ("G4", [(GPUI_MAIN, "  let changed = gProblems.follow(gBuild.session, nowMonoMs())",
             "  let changed = false")],
     [(PLAN, PLAN_ROWS)],
     "the GPUI window does not read its build into the pane"),
    ("P1", [(VOCAB, '    children.add viewTable("problems.rows", ProblemsColumns, cells)',
             '    discard cells')],
     [(TBL, TBL_BUILD)],
     "the vocabulary's Problems view lists no problem"),
    # ---- the desktop -------------------------------------------------------
    ("D1", [(DESKTOP_BUILD, "  if read.fed.problem:",
             "  if read.fed.problem and read.fed.row.severity != blsWarning:")],
     [(SPEC, None)],
     "§3.4: the desktop does not list the rows the shared rule reads"),
    # ---- the declared survivor ---------------------------------------------
    ("Z1", [(GPUI_MAIN, "  let deadline = epochTime() + 5.0", "  let deadline = epochTime() + 6.0")],
     [(PLAN, PLAN_ROWS)],
     "behaviour-preserving: the DECLARED SURVIVOR (the window's build-stop budget)"),
]

DECLARED_SURVIVORS = {"Z1"}

IN_BINARY = {VM, RULE, READER, SOURCE, TUI_PANE, RUNTIME, SHELL, PROFILE,
             LAYOUT, TUI_MAIN, VOCAB}
IN_GPUI = {VM, RULE, READER, LAYOUT, GPUI_LEAF, GPUI_MAIN, VOCAB}
IN_DESKTOP = {VM, RULE, DESKTOP_BUILD, LAYOUT}
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
        f.write("# Control digests for run-plat55-test-results-mutations.py —\n"
                "# the subjects AND the suites the arms are graded by (§16c).\n"
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
    return build_with("PLAT55_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT55_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT55_BUILD_DESKTOP", "build-once")


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


def run_spec(suite):
    """The Electron spec: GREEN on rc 0, else RED on its first expectation."""
    cmd = os.environ.get("PLAT55_DESKTOP_TEST")
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
    cmd = [os.environ.get("PLAT55_NIM", "nim"), "c", "-r", "--hints:off",
           "--warnings:off",
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
            backups[rel] = path.with_name(path.name + ".plat55bak")
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
