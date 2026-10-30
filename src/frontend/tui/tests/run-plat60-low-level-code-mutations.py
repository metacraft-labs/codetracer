#!/usr/bin/env python3
"""PLAT-60 — the mutation harness for the Low Level Code pane on the terminal
and in the GPUI window (codetracer-pm `spec/GUI/Debugging-Features/
Generated-Code-Listing.md` §0, §0.2): the listing every front-end draws (moved
into `low_level_code_vm`: the rows, the execution pointer, the cross-reference
both ways, the header's words, the row menu, stepping by instruction where it
is offered), the engine's line range for a function's listing
(`dap_handler.rs::load_steps_for_call`), the store's capabilities, the
terminal's painter, runtime, host, editor and keys, the GPUI leaf, window and
editor, the vocabulary view and the desktop's view.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` when the defect is compiled into a binary an arm is graded
through; runs the suites that must catch it; and requires RED — with the
failure the first run recorded (`plat60-low-level-code-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-55's harness's (`run-plat55-problems-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT60_BUILD_TUI` / `$PLAT60_BUILD_GPUI` when set, else
`just build-tui` / `just build-gpui`; the suites compile with `$PLAT60_NIM`
when set, else `nim`. The engine's arms are graded by its Rust unit test, run
by `$PLAT60_RUST_TEST` when set, else `cargo test --lib test_asm_listing` in
`src/db-backend`. Every Nim suite but the ViewModel's opens the real
`noir_space_ship` recording with the real `replay-server`, as the lanes do.

Usage:
    run-plat60-low-level-code-mutations.py [--only V1,T1] [--derive]
    run-plat60-low-level-code-mutations.py --needle-scan
    run-plat60-low-level-code-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat60-low-level-code-mutation-control.sha256"
BECAUSE = HERE / "plat60-low-level-code-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat60-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/low_level_code_vm.nim"
VIEW = "src/frontend/viewmodel/views/isonim_low_level_code_view.nim"
STORE = "src/frontend/viewmodel/store/replay_data_store.nim"
ENGINE = "src/db-backend/src/dap_handler.rs"
TUI_PANE = "src/frontend/tui/app/views/low_level_code_pane.nim"
SOURCE_PANE = "src/frontend/tui/app/views/source_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
HOST = "src/frontend/tui/host/tui_session.nim"
KEYMAP = "src/frontend/viewmodel/keymap/cua_keymap.nim"
SCOPES = "src/frontend/viewmodel/keymap/scope_path.nim"
GPUI_LEAF = "src/frontend/gpui/low_level_code_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP_EDITOR = "src/frontend/ui/editor.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat60_low_level_code.nim"
TBL = "src/frontend/tui/tests/test_plat60_low_level_code.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat60_low_level_code_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat60_gpui_low_level_code.nim"
RUST = "src/db-backend/src/dap_handler.rs#test_asm_listing"
SPEC = "src/tests/gui/tests/low-level-code/plat60-low-level-code-capture.spec.ts"

SUBJECTS = [VM, VIEW, STORE, ENGINE, TUI_PANE, SOURCE_PANE, RUNTIME, HOST,
            KEYMAP, SCOPES, GPUI_LEAF, GPUI_MAIN, VOCAB, DESKTOP_EDITOR]
SUITES = [VMU, TBL, PTY, PLAN, SPEC]

TBL_OPEN = "*::Alt+1 opens it beside the source, with the engine's listing"
TBL_XREF = "*::the cross-reference both ways, a press, the menu, sync, a step"
TBL_BAR = "*::a short pane draws the listing's scrollbar"
PLAN_OPEN = "*::view.low-level-code opens it beside the source with the engine's listing"
PLAN_XREF = "*::the cross-reference both ways, the menu, a press, sync off"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the listing (the ViewModel) ---------------------------------------
    ("V1", [(VM, "    long[long.len - short.len - 1] == '/'", "    true")],
     [(VMU, None)],
     "a file whose name merely ends like another's is taken for it"),
    ("V2", [(VM, "      if instr.offset >= 0 and uint64(instr.offset) == ticks:",
             "      if false:")],
     [(VMU, None)],
     "the execution pointer ignores the step the debugger is at"),
    ("V3", [(VM, "    if sameSourceLine(instr.highLevelPath, instr.highLevelLine, at):",
             "    if false:")],
     [(VMU, None), (TBL, TBL_XREF)],
     "SOURCE -> INSTRUCTIONS: the editor's line marks nothing"),
    ("V4", [(VM, "  vm.sourceLineOf(vm.selected.val)", "  SourceLineRef()")],
     [(VMU, None), (TBL, TBL_XREF)],
     "INSTRUCTION -> SOURCE: the selected instruction names no line"),
    ("V5", [(VM, "      of llmGoToSourceLine: instr.hasSourceLine",
             "      of llmGoToSourceLine: true")],
     [(VMU, None)],
     "the menu offers Go to Source Line for an instruction with no line"),
    ("V6", [(VM, '    args: %*{"threadId": 1, "granularity": "instruction"})',
             '    args: %*{"threadId": 1})')],
     [(VMU, None)],
     "a step by instruction is asked for by line"),
    ("V7", [(VM, "       vm.generatedAtStop.val.len > 0:", "       true:")],
     [(VMU, None)],
     "the recording's own listing says it is not kept in step"),
    ("V8", [(VM, "    from0 = max(0, vm.executionIndex)", "    from0 = 0")],
     [(VMU, None)],
     "the listing's cursor starts at the top, not at the pointer"),
    ("V9", [(VM, "      executing: i == executing,", "      executing: false,")],
     [(VMU, None), (TBL, TBL_OPEN), (PTY, None), (PLAN, PLAN_OPEN)],
     "no instruction carries the execution pointer"),
    ("V10", [(VM, "      result.jumpTo = vm.jumpTargetOf(index)", "      discard")],
     [(VMU, None), (PLAN, PLAN_XREF)],
     "Go to Source Line, chosen on a native front-end, goes nowhere"),
    ("V11", [(VM, "        (activePath.len == 0 or sameSourcePath(instr.highLevelPath,",
              "        (activePath.len == 0 or (instr.highLevelPath ==")],
     [(VMU, None), (TBL, TBL_OPEN)],
     "a Noir listing's rows are compared to the move's full path verbatim"),
    ("D1", [(VIEW, '  if row.executing: result.add " execution-pointer"', "  discard")],
     [(VMU, None)],
     "the desktop draws no execution pointer"),
    ("C1", [(STORE, '    capabilities{"supportsSteppingGranularity"}.getBool(false))',
             "    false)")],
     [(VMU, None)],
     "an engine's instruction stepping is never seen"),
    # ---- the engine --------------------------------------------------------
    ("K1", [(ENGINE, "        for line in first_line..=last_line {",
             "        for line in first_line..last_line {")],
     [(RUST, None)],
     "a function's listing loses its last line"),
    ("K2", [(ENGINE, "            (enriched.function_first, enriched.function_last)",
             "            (0, 0)")],
     [(RUST, None)],
     "a function no grammar reads (every Noir one) lists nothing"),
    # ---- the terminal's painter, runtime, host, editor, keys ----------------
    ("T1", [(TUI_PANE, "        g.paintGlyph(ry, col, grExecPointer, LowLevelPointerStyle)",
             "        discard")],
     [(TBL, TBL_OPEN)],
     "the pointer's glyph is not drawn"),
    ("T2", [(TUI_PANE, "  elif r.linked: (true, LowLevelLinkedSurface)",
             "  elif false: (true, LowLevelLinkedSurface)")],
     [(TBL, TBL_XREF)],
     "a cross-referenced instruction is not drawn so"),
    ("T3", [(TUI_PANE, "    of lpInstruction: LowLevelTarget(kind: ltInstruction, index: r.index,",
             "    of lpInstruction: LowLevelTarget(kind: ltInstruction, index: -1,")],
     [(TBL, TBL_XREF), (PTY, None)],
     "a press on an instruction moves nothing"),
    ("T4", [(TUI_PANE, "    result.trackCol = area.col + area.width - ScrubberTrackCells",
             "    discard")],
     [(TBL, TBL_BAR)],
     "an overflowing listing draws no scrollbar"),
    ("S1", [(SOURCE_PANE, "    if line == model.crossRefLine and line > 0:",
             "    if false:")],
     [(TBL, TBL_XREF)],
     "the editor draws no cross-reference"),
    ("R1", [(RUNTIME, "    let acted = b.dispatch(cmdSplit(paneEditor, paneLowLevelCode, saRow,",
             "    let acted = b.dispatch(cmdSplit(paneEditor, paneLowLevelCode, saColumn,")],
     [(TBL, TBL_OPEN)],
     "the pane opens below the source, not beside it"),
    ("R2", [(RUNTIME, "  rt.lowLevelCursor = at", "  return")],
     [(TBL, TBL_XREF)],
     "the editor's caret is never told to the listing"),
    ("R3", [(RUNTIME, "    rt.openLowLevelCode(outcome)", "    discard")],
     [(TBL, TBL_OPEN), (PTY, None)],
     "Alt+1 opens nothing"),
    ("R4", [(RUNTIME, "       rt.runLowLevelKeyOperation(res.operation, outcome):",
             "       false:")],
     [(TBL, TBL_XREF)],
     "the list keys do not move the listing's cursor"),
    ("R5", [(RUNTIME, "    model.source.crossRefLine = ll.crossRefLine", "    discard")],
     [(TBL, TBL_XREF)],
     "the selected instruction's line never reaches the editor"),
    ("H1", [(HOST, "    vm.setShown(shown)", "    discard")],
     [(TBL, TBL_OPEN)],
     "the pane opened is never loaded at that stop"),
    ("H2", [(HOST, "    jump = vm.jumpTargetOf(act.index)", "    discard")],
     [(TBL, TBL_XREF), (PTY, None)],
     "a press on an instruction asks the engine for no move"),
    ("H3", [(HOST, "  result.crossRefLine = source.line", "  result.crossRefLine = 0")],
     [(TBL, TBL_XREF)],
     "the pane's value drops the cross-reference"),
    ("KM1", [(KEYMAP, '    BaseRow(chords: "Alt+1", operation: "view.low-level-code", table: G),',
              '    BaseRow(chords: "Alt+1", operation: "view.low-level-code", whenText: "frontEnd == desktop", table: G),')],
     [(TBL, TBL_OPEN), (PTY, None)],
     "Alt+1 is the desktop's alone again"),
    ("KM2", [(SCOPES, '                    "lowLevelCode"]', "                    ]")],
     [(TBL, TBL_XREF)],
     "the focused listing is not a list pane: the list keys are not its"),
    # ---- the GPUI leaf, window and editor ----------------------------------
    ("G1", [(GPUI_MAIN, "    applyGestureCommand(r, cmdSplit(paneEditor, paneLowLevelCode, saRow,",
             "    applyGestureCommand(r, cmdSplit(paneEditor, paneLowLevelCode, saColumn,")],
     [(PLAN, PLAN_OPEN)],
     "GPUI opens the pane below the source"),
    ("G2", [(GPUI_LEAF, '      if l.executing: r.setAttribute(el, "data-ct-executing", "true")',
             "      discard")],
     [(PLAN, PLAN_OPEN)],
     "GPUI marks no execution pointer"),
    ("G3", [(GPUI_MAIN, "      result.crossRefLine = x.line", "      discard")],
     [(PLAN, PLAN_XREF)],
     "the GPUI editor draws no cross-reference"),
    ("G4", [(GPUI_MAIN, "                       gDebugDocs[gEditorSurface.path].caretLine)",
             "                       0)")],
     [(PLAN, PLAN_XREF)],
     "the GPUI editor's caret is never told to the listing"),
    ("G5", [(GPUI_LEAF, "    of lrkInstruction: GLowLevelHit(kind: glInstruction, index: l.index)",
             "    of lrkInstruction: GLowLevelHit(kind: glInstruction, index: -1)")],
     [(PLAN, PLAN_XREF)],
     "a GPUI press on an instruction moves nothing"),
    ("P1", [(VOCAB, '    children.add viewTable("lowLevelCode.rows", LowLevelCodeColumns, cells)',
             "    discard cells")],
     [(TBL, TBL_OPEN)],
     "the vocabulary's Low Level Code view lists no instruction"),
    # ---- the desktop -------------------------------------------------------
    ("D2", [(DESKTOP_EDITOR, "    stopStore.applyStopLocation(parseJson($stringifyMove(response.toJs)))",
             "    discard")],
     [(SPEC, None)],
     "the desktop's Low Level Code view asks for nothing at any stop"),
    # ---- the declared survivor ---------------------------------------------
    ("Z1", [(GPUI_LEAF, "  LowLevelGapPx = 8", "  LowLevelGapPx = 9")],
     [(PLAN, PLAN_XREF)],
     "behaviour-preserving: the DECLARED SURVIVOR (the GPUI row's gap)"),
]

DECLARED_SURVIVORS = {"Z1"}

IN_BINARY = {VM, VIEW, STORE, TUI_PANE, SOURCE_PANE, RUNTIME, HOST, KEYMAP,
             SCOPES, VOCAB}
IN_GPUI = {VM, STORE, GPUI_LEAF, GPUI_MAIN, KEYMAP, SCOPES, VOCAB}
IN_DESKTOP = set()
  # The desktop's spec is run by `$PLAT60_DESKTOP_TEST` (the capture recipe),
  # which compiles the renderer from the checkout as it stands: an arm's
  # defect needs no separate build.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}
RUST_SUITES = {RUST}


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
        f.write("# Control digests for run-plat60-low-level-code-mutations.py —\n"
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
    return build_with("PLAT60_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT60_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT60_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT60_DESKTOP_TEST")
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


def run_rust(suite):
    """The engine's unit test: GREEN on rc 0, else RED on its first panic."""
    cmd = os.environ.get("PLAT60_RUST_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["cargo", "test", "--lib", suite.split("#", 1)[1]]
    cwd = REPO if cmd else REPO / "src/db-backend"
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    first = [ln.strip() for ln in out.splitlines()
             if ln.strip().startswith(("left:", "assertion"))][:1]
    if not first and "error[" in out:
        return "DID-NOT-COMPILE", []
    return "RED", first


def run_suite(suite, test_filter):
    if suite in RUST_SUITES:
        return run_rust(suite)
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    cmd = [os.environ.get("PLAT60_NIM", "nim"), "c", "-r", "--hints:off",
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
            backups[rel] = path.with_name(path.name + ".plat60bak")
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
