#!/usr/bin/env python3
"""The mutation harness for editor multi-click selection, the gutter's two zones,
Alt+click and Shift+F9 (Editor-Pane.md § Multi-click selection, MC.1 - MC.7,
§ Inline breakpoints).

Each arm plants ONE defect in the shared pointer model, the word classifier, the
operations, the breakpoint plans, the terminal, the GPUI window or the desktop;
REBUILDS the shipped binary when the defect is compiled into one an arm is graded
through; runs the suites that must catch it; and requires RED with the failure
the first run recorded (`plat70g-multiclick-mutation-because.json`, derived with
`--derive`).

The discipline is the earlier parts' harnesses': committed control digests over
subjects AND suites, a needle scan that gates re-recording, `because` derived from
a run, rc 124 is a hang, per-arm restore verification, and
`ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT70G_BUILD_TUI` / `$PLAT70G_BUILD_GPUI` /
`$PLAT70G_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`. The desktop arms are graded by the Electron spec, run by
`$PLAT70G_DESKTOP_TEST` when set, else `npx playwright test` in `src/tests/gui`.

No mocks: the suites graded here run the shipped ViewModel over real values, the
shipped terminal binary on a real pty against a real recording and
`replay-server`, the shipped GPUI binary's window plan, and the real Electron app.

Usage:
    run-plat70g-multiclick-mutations.py [--only C1,T1] [--derive]
    run-plat70g-multiclick-mutations.py --needle-scan
    run-plat70g-multiclick-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70g-multiclick-mutation-control.sha256"
BECAUSE = HERE / "plat70g-multiclick-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70e-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

COUNTER = "src/frontend/viewmodel/input/click_counter.nim"
POINTER = "src/frontend/viewmodel/input/editor_pointer.nim"
WORDS = "src/frontend/viewmodel/editor/word_classifier.nim"
OPS = "src/frontend/viewmodel/editor/operations.nim"
LANES = "src/frontend/viewmodel/viewmodels/editor_gutter_lanes.nim"
PLANS = "src/frontend/viewmodel/sdk/breakpoints.nim"
CLICKS = "src/frontend/headless_app/pane_clicks.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
ROLES = "src/frontend/tui/app/theme/roles.nim"
MOUSE = "src/frontend/tui/app/input/mouse.nim"
WCLICKS = "src/frontend/gpui/window_clicks.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
EDITOR = "src/frontend/ui/editor.nim"
TRACE = "src/frontend/ui/trace.nim"
APPEARANCE = "src/frontend/lib/monaco_appearance.nim"

VMU = "src/frontend/viewmodel/tests/unit/test_plat70g_pointer_vm.nim"
DIFF = "src/frontend/tui/tests/test_plat70g_differential.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70g_multiclick_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70g_gpui_plan.nim"
SPEC = "src/tests/gui/tests/editor/plat70g-multiclick.spec.ts"

SUBJECTS = [COUNTER, POINTER, WORDS, OPS, LANES, PLANS, CLICKS, RUNTIME, ROLES,
            MOUSE, WCLICKS, LEAVES, EDITOR, TRACE, APPEARANCE]
SUITES = [VMU, DIFF, PTY, PLAN, SPEC]

PTY_SHIFT = "*::a Shift press is the terminal's: nothing happens"
PTY_HINT = "*::the hint is `gutter.breakpoint.hint`'s colour, a number"
PTY_REBIND = "*::the menu's chord is the user's when they rebind it"
PTY_REPLAY = "*::the selection moves nothing in the replay"
PTY_ALT = "*::Alt adds a cursor and no breakpoint; Shift+F9 sets one the replay honours"
PTY_MENU = "*::the menu's inline entry, and its Remove"
PLAN_COUNT = "*::the platform's count reaches the counter, and the stricter one wins"
SPEC_ALT = "Alt+click adds a cursor in the read-only editor and no breakpoint"
SPEC_GLYPH = "the glyph column toggles on the press; the numbers select the line"

ARMS = [
    # ---- the counter ----------------------------------------------------------
    ("C1", [(COUNTER, "  c.previous = p\n  c.hasPrevious = true",
             "  if c.run == 1: c.previous = p\n  c.hasPrevious = true")],
     [(VMU, None)], "the interval measured from the first press, not the previous"),
    ("C2", [(COUNTER, "  c.count = min(fromPlatform, c.run)",
             "  c.count = min(3, min(fromPlatform, c.run))")],
     [(VMU, None)], "the count capped at 3: no select-all"),
    ("C3", [(COUNTER, "  c.run = if samePlace: c.run + 1 else: 1",
             "  c.run = if sameTarget: c.run + 1 else: 1")],
     [(VMU, None)], "the same-position rule dropped"),
    ("C4", [(COUNTER, "  if c.down and samePlace:", "  if false:")],
     [(VMU, None)], "the duplicate-press rule dropped"),
    # ---- the word and the operations ------------------------------------------
    ("W1", [(WORDS, "  elif r in c.runes:", "  elif r in c.runes or not r.isAlpha:")],
     [(VMU, None)], "CharCat's classes instead of wordSeparators': a separator is not `€`"),
    ("O1", [(OPS, "  let (a, b) = lineSpanOf(env, env.lineOf(args.number))\n  var after = env.withPointerRange(st, spanRange(a, b), args.pointer.keepOthers,",
             "  let (a, b) = (env.lineStartOf(env.lineOf(args.number)), env.lineEndOf(env.lineOf(args.number)))\n  var after = env.withPointerRange(st, spanRange(a, b), args.pointer.keepOthers,")],
     [(VMU, None)], "the triple click without its line break"),
    ("O2", [(OPS, "  if contains(offset):\n    anchor.last", "  if contains(offset):\n    offset")],
     [(VMU, None)], "the word drag shrinks below the anchor"),
    ("O3", [(OPS, "    let next = env.displayRowOf(offset) + 1",
             "    let next = env.display.cache.firstRowOf(line) + env.display.cache.rowsInLine(line)")],
     [(VMU, None)], "the line drag in logical lines below the anchor"),
    ("O4", [(OPS, "    env.rowStartOffset(env.displayRowOf(offset))", "    env.lineStartOf(line)")],
     [(VMU, None)], "the line drag in logical lines above the anchor"),
    # ---- the rows --------------------------------------------------------------
    ("P1", [(POINTER, "  let count = if p.hit.element == peGutterGlyph: 1 else: observed.count",
             "  let count = observed.count"),
            (POINTER, "    PointerRow(element: peGutterGlyph, mods: pmNone, button: pbLeft,\n               minCount: 1, maxCount: AnyCount, operation: poToggleBreakpoint),",
             "    PointerRow(element: peGutterGlyph, mods: pmNone, button: pbLeft,\n               minCount: 1, maxCount: 1, operation: poToggleBreakpoint),")],
     [(VMU, None)], "a gutter press counted: one toggle on a double press"),
    ("P2", [(POINTER, "  of poLineJump: result.effect = pfLineJump",
             "  of poLineJump:\n    d.runPointerOp(\"select-word-at\", args, p.timeMs)\n    result.effect = pfLineJump")],
     [(VMU, None)], "Ctrl+double-click also selecting"),
    ("P3", [(POINTER, "    d.runPointerOp(\"select-word-at\", args, p.timeMs)\n    g.held = true\n    result.effect = pfSelected",
             "    d.runPointerOp(\"select-word-at\", args, p.timeMs)\n    g.held = true\n    result.effect = pfLineJump")],
     [(PTY, PTY_REPLAY)], "a multi-click that seeks: the tick moved"),
    ("P4", [(POINTER, "                  nowMs: int64) =\n  discard d.applyNamed(name, args, nowMs)",
             "                  nowMs: int64) =\n  if d.isReadOnly: return\n  discard d.applyNamed(name, args, nowMs)")],
     [(VMU, None)], "the selection refused in the read-only editor"),
    ("M1", [(POINTER, "    elif unit in {puLine, puDocument}:\n      emVisualLine",
             "    elif unit in {puLine, puDocument}:\n      emVisual")],
     [(VMU, None)], "Vim's triple click entering characterwise VISUAL"),
    ("A1", [(POINTER, "    d.runPointerOp(\"add-cursor-at-point\", args, p.timeMs)\n    g.held = true\n    result.effect = pfSelected\n  of poAddLineCursor:",
             "    result.effect = pfToggleBreakpoint\n  of poAddLineCursor:")],
     [(VMU, None), (PTY, PTY_ALT)], "the Alt+click breakpoint restored on the terminal"),
    ("A2", [(POINTER, "  of poAddCursor:", "  of poAddCursor:\n    if d.isReadOnly: return")],
     [(VMU, None)], "Alt+click adds no cursor in the read-only Debug editor"),
    ("Z1", [(POINTER, "    PointerRow(element: peGutterLineNumber, mods: pmNone, button: pbLeft,\n               minCount: 1, maxCount: AnyCount, operation: poSelectLine),",
             "    PointerRow(element: peGutterLineNumber, mods: pmNone, button: pbLeft,\n               minCount: 1, maxCount: AnyCount, operation: poToggleBreakpoint),")],
     [(VMU, None)], "a line-number press toggling a breakpoint (the old K10)"),
    ("Z2", [(POINTER, "    PointerRow(element: peGutterGlyph, mods: pmNone, button: pbLeft,\n               minCount: 1, maxCount: AnyCount, operation: poToggleBreakpoint),",
             "    PointerRow(element: peGutterGlyph, mods: pmNone, button: pbLeft,\n               minCount: 1, maxCount: AnyCount, operation: poSelectLine),")],
     [(VMU, None)], "a glyph press selecting the line: the zones swapped"),
    ("Z3", [(LANES, "    of gbGlyph: result.glyphRight = b.rightPx", "    of gbGlyph: result.glyphRight = b.rightPx + 10")],
     [(VMU, None)], "the zone boundary off by one lane: the pointer lane classed as glyph"),
    ("R1", [(POINTER, "  of poSetEnabled: result.effect = pfSetBreakpointEnabled",
             "  of poSetEnabled: result.effect = pfToggleBreakpoint")],
     [(VMU, None)], "a glyph right press deleting instead of disabling"),
    ("H1", [(POINTER, "  let next = if element == peGutterGlyph and not lineHasMark and line > 0: line",
             "  let next = if element == peGutterGlyph and line > 0: line")],
     [(VMU, None)], "the hover hint drawn on a marked line"),
    ("H2", [(ROLES, "    srGutterBreakpointHint: fgOnly(dgGutter, dtColorsUiSurfaceAlertError,",
             "    srGutterBreakpointHint: fgOnly(dgGutter, dtColorsUiTextPrimaryDisabled,")],
     [(PTY, PTY_HINT)], "the hover hint in the disabled breakpoint's colour"),
    # ---- the breakpoint plans -----------------------------------------------------
    ("K1", [(PLANS, "  if col < 2 or not columnsSupported:", "  if true or not columnsSupported:")],
     [(VMU, None)], "Shift+F9 setting a line breakpoint at column 2 or later"),
    ("K2", [(PLANS, "  if col < 2 or not columnsSupported:", "  if col < 1 or not columnsSupported:")],
     [(VMU, None)], "Shift+F9 setting a column breakpoint at column 1"),
    ("K3", [(PLANS, "    if sp.line == line and sp.column == column:\n      for other in held:",
             "    if false:\n      for other in held:")],
     [(VMU, None)], "Shift+F9 not toggling: a second press puts it back"),
    # ---- the menu ---------------------------------------------------------------------
    ("N1", [(RUNTIME, "  rt.chordOfOperation(\"editor.toggle-inline-breakpoint\")", "  \"Shift+F9\"")],
     [(PTY, PTY_REBIND)], "the inline entry's hint a literal, not the active base's chord"),
    ("N2", [(CLICKS, "hint = \"<click left of the line number>\")", "hint = \"<click line number gutter>\")")],
     [(PTY, PTY_MENU)], "the old hint restored"),
    # ---- the front-ends ---------------------------------------------------------------
    ("T1", [(RUNTIME, "    if isMouse and event.shift:", "    if false and isMouse and event.shift:")],
     [(PTY, PTY_SHIFT)], "the Shift stand-down removed on the terminal"),
    ("T2", [(MOUSE, "proc mouseMetrics*(): MouseMetrics = gMouseMetrics", "from std/times import epochTime\nlet pressTimeGate* = epochTime() - 0.4 > 0.0\nproc mouseMetrics*(): MouseMetrics = gMouseMetrics")],
     [(DIFF, None)], "a front-end comparing press times itself"),
    ("G1", [(WCLICKS, "      click.clickCount = p.clickCount", "      discard")],
     [(PLAN, PLAN_COUNT)], "GPUI ignoring click_count: a platform count of 1 on a fast second press"),
    ("G2", [(LEAVES, "  EditorGutterPx* = 110", "  EditorGutterPx* = 110\n  GutterBreakpointX* = 62")],
     [(PLAN, "*::the source gate: GPUI's lanes are the shared map's")], "GPUI's gutter reading its own pixel constants"),
    ("D1", [(EDITOR, "        else:\n          toggleBreakpoint(editorPointStore(), $self.name, line)\n    elif targetType in [MouseTargetGutterLineNumbers,",
             "        else:\n          discard setTimeout(proc() = toggleBreakpoint(editorPointStore(), $self.name, line), 15000)\n    elif targetType in [")],
     [(SPEC, SPEC_GLYPH)], "the desktop's glyph toggle moved off the press"),
    ("D2", [(APPEARANCE, "    let lineHtml = cstring\"<div class='gutter-line'>\" & lineText & cstring\"</div>\"",
             "    let lineHtml = cstring\"<div class='gutter-line' onmousedown='event.stopPropagation()'>\" & lineText & cstring\"</div>\"")],
     [(SPEC, SPEC_GLYPH)], "the desktop's stopPropagation guard left on the number"),
    ("D3", [(EDITOR, "    elif cast[bool](e.event.ctrlKey) and cast[bool](e.event.altKey):\n      try:\n        let targetToken = self.getTokenFromPosition(e.target.position)",
             "    elif cast[bool](e.event.altKey) and not cast[bool](e.event.ctrlKey):\n      toggleBreakpoint(editorPointStore(), $self.name, cast[int](e.target.position.lineNumber))\n    elif cast[bool](e.event.ctrlKey) and cast[bool](e.event.altKey):\n      try:\n        let targetToken = self.getTokenFromPosition(e.target.position)")],
     [(SPEC, SPEC_ALT)], "the Alt+click breakpoint restored on the desktop"),
]

DECLARED_SURVIVORS = set()

IN_BINARY = {COUNTER, POINTER, WORDS, OPS, LANES, PLANS, CLICKS, RUNTIME, ROLES, MOUSE}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {COUNTER, POINTER, WORDS, OPS, LANES, PLANS, CLICKS, WCLICKS, LEAVES}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {EDITOR, TRACE, APPEARANCE}
  # Subjects compiled into the desktop's bundle.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}
PYTHON_SUITES = set()

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
        f.write("# Control digests for run-plat70g-multiclick-mutations.py — the\n"
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
    return build_with("PLAT70G_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70G_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70G_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70G_DESKTOP_TEST")
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
            backups[rel] = path.with_name(path.name + ".plat70gbak")
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
