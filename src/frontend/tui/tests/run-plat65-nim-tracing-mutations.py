#!/usr/bin/env python3
"""The mutation harness for Nim's compile-time tracing on the terminal and in
the GPUI window (codetracer-pm `spec/Planned-Features/Nim-Compile-Time-
Tracing-Milestones.md` M6, M9–M11): the shared ViewModel (`nim_tracing_vm`:
the offer at the caret, the line the compiler matches, the request's line
base, nimsuggest's command, where the recording opens), the native route
(`host/native_nim_tracer`: nimsuggest's protocol, the bundled sources), the
terminal's runtime and host loop, the GPUI window, the editor menu's model,
the CUA base's chords and the palette.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` when the defect is compiled into a binary an arm is graded
through; runs the suites that must catch it; and requires RED — with the
failure the first run recorded (`plat65-nim-tracing-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-63's harness's (`run-plat63-verification-
mutations.py`): committed control digests over subjects AND suites, a needle
scan that gates re-recording, `because` derived from a run, rc 124 is a hang,
per-arm restore verification, one declared behaviour-preserving survivor,
and `ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT65_BUILD_TUI` / `$PLAT65_BUILD_GPUI` when set, else
`just build-tui` / `just build-gpui`; the suites compile with `$PLAT65_NIM`
when set, else `nim`. The real-stack suites need the trace-enabled
nimsuggest and compiler (`CODETRACER_NIMSUGGEST`, `CODETRACER_NIM`) and a
built `replay-server`, found as the product finds it (`$REPLAY_SERVER_BIN`,
else the build's output tree; `tui/tests/fixtures/plat65_nim_project`).

Usage:
    run-plat65-nim-tracing-mutations.py [--only V1,T1] [--derive]
    run-plat65-nim-tracing-mutations.py --needle-scan
    run-plat65-nim-tracing-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat65-nim-tracing-mutation-control.sha256"
BECAUSE = HERE / "plat65-nim-tracing-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat65-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/nim_tracing_vm.nim"
HOST = "src/frontend/viewmodel/host/native_nim_tracer.nim"
CLICKS = "src/frontend/headless_app/pane_clicks.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
OMNIBAR = "src/frontend/viewmodel/viewmodels/omnibar_sources.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat65_nim_tracing_vm.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat65_nim_tracing_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat65_gpui_nim_tracing.nim"

SUBJECTS = [VM, HOST, CLICKS, RUNTIME, TUI_MAIN, GPUI_MAIN, CUA, OMNIBAR]
SUITES = [VMU, PTY, PLAN]

PTY_MAIN = "*::eval, static block, constant and macro — each a new session tab"
PTY_PROC = "*::on an ordinary proc line the static action is refused, and says why"
PLAN_EVAL = "*::eval: Ctrl+K T E in build.nims opens a new session tab in the script"
PLAN_MENU = "*::constant from the editor's menu, macro by its chord, each a new tab"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared ViewModel ---------------------------------------------
    ("V1", [(VM, "    # A routine's signature is not an evaluation, whatever encloses it.\n"
                 "    return TracedConstruct()",
             "    # A routine's signature is not an evaluation, whatever encloses it.\n"
             "    return TracedConstruct(context: ccStatic, line: line)")],
     [(VMU, None), (PTY, PTY_PROC)],
     "the static action is offered on a proc line"),
    ("V2", [(VM, "  (line: max(0, request.line - 1), character: max(0, request.column - 1))",
             "  (line: max(0, request.line), character: max(0, request.column - 1))")],
     [(VMU, None), (PTY, PTY_MAIN)],
     "the request is sent with a 1-based line"),
    ("V3", [(VM, "  ## same trace, so replacing it would only lose it.\n  topNewTab",
             "  ## same trace, so replacing it would only lose it.\n  topCurrentTab")],
     [(VMU, None), (PTY, PTY_MAIN), (PLAN, PLAN_EVAL)],
     "the new recording is opened in the current tab"),
    ("V4", [(VM, "      return TracedConstruct(context: ccStatic,\n"
                 "                             line: firstCodeLineAfter(lines, at))",
             "      return TracedConstruct(context: ccStatic,\n"
             "                             line: at)")],
     [(VMU, None)],
     "a static block is requested at its keyword, which the compiler never matches"),
    ("V5", [(VM, '  verb & " " & request.path & ":" & $(at.line + 1) & ":" & $at.character',
             '  verb & " " & request.path & ":" & $at.line & ":" & $at.character')],
     [(VMU, None)],
     "nimsuggest is asked about the line above the caret"),
    # ---- the native route -------------------------------------------------
    ("H1", [(HOST, '        args = @["--v3", "--stdin", "--nimcache:" & t.cache, request.path],',
             '        args = @["--stdin", "--nimcache:" & t.cache, request.path],')],
     [(PTY, PTY_MAIN)],
     "nimsuggest runs without protocol 3, and answers no trace query"),
    ("H2", [(HOST, "      bundleNimTraceSources(t.folder, request.path)", "      discard")],
     [(PTY, PTY_MAIN)],
     "the recording carries no source, and the new tab shows no code"),
    # ---- the terminal -----------------------------------------------------
    ("T1", [(RUNTIME, "    rt.runNimTrace(nimTraceActionOfOperation(c.name).action)",
             "    discard c")],
     [(PTY, PTY_PROC)],
     "the terminal's chords run no trace"),
    ("T2", [(TUI_MAIN, "      let recorded = pollRecording() or advanceNimTrace(rt, edit, openNimTrace)",
             "      let recorded = pollRecording()")],
     [(PTY, PTY_MAIN)],
     "the terminal never polls a trace, and nothing opens"),
    ("C1", [(CLICKS, "  # The Nim trace entries close the menu, as on the desktop.\n"
                     "  result.addNimTraceEntries(nimTrace)",
             "  # The Nim trace entries close the menu, as on the desktop.\n"
             "  discard nimTrace")],
     [(PTY, PTY_MAIN)],
     "the editor menu offers no trace entry"),
    # ---- the GPUI window --------------------------------------------------
    ("G1", [(GPUI_MAIN, "    runGpuiNimTrace(r, nimTraceActionOfOperation(c.name).action))",
             "    discard c)")],
     [(PLAN, PLAN_EVAL)],
     "the window's chords run no trace"),
    ("G2", [(GPUI_MAIN, "                        nimTrace = nimTraceEntriesAt(path, line, column))",
             "                        nimTrace = newSeq[NimTraceEntry]())")],
     [(PLAN, PLAN_MENU)],
     "the window's editor menu offers no trace entry"),
    # ---- the names ---------------------------------------------------------
    ("K1", [(CUA, '    BaseRow(chords: "Ctrl+K T S", operation: "editor.trace-static-block-at-cursor",',
             '    BaseRow(chords: "Ctrl+K T X", operation: "editor.trace-static-block-at-cursor",')],
     [(VMU, None)],
     "the static block's chord is not Ctrl+K T S"),
    ("P1", [(OMNIBAR, "  result.add nimTraceCommands()", "  discard")],
     [(VMU, None)],
     "the palette does not list the four"),
    # ---- the declared survivor ---------------------------------------------
    ("Z1", [(VM, "  StaticScanLines = 200", "  StaticScanLines = 201")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR (the offer's scan window)"),
]

DECLARED_SURVIVORS = {"Z1"}

IN_BINARY = {VM, HOST, CLICKS, RUNTIME, TUI_MAIN, CUA, OMNIBAR}
IN_GPUI = {VM, HOST, CLICKS, GPUI_MAIN, CUA, OMNIBAR}
IN_DESKTOP = set()
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = set()
RUST_SUITES = set()


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
        f.write("# Control digests for run-plat65-nim-tracing-mutations.py —\n"
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
    return build_with("PLAT65_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT65_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT65_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT65_DESKTOP_TEST")
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
    cmd = os.environ.get("PLAT65_RUST_TEST")
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
    cmd = [os.environ.get("PLAT65_NIM", "nim"), "c", "-r", "--hints:off",
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
            backups[rel] = path.with_name(path.name + ".plat65bak")
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
