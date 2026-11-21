#!/usr/bin/env python3
"""NOT-A-CI-GATE: a mutation-grading instrument its owner runs in
Verification-Harness-Traps §39b's order (needle scan, record, grade), as every
`run-plat*-mutations.py` beside the suites is; it edits product sources in
place, so no lane may run it as a check. CI does start it — `ci/lint/nim.sh`'s
harness-argument-refusal step, by discovery, with a refused flag.

PLAT-70 — the mutation harness for the user's three find decisions of
2026-11-20 (Find-And-Incremental-Search.md §7):

* OQ-F5, regular expressions and Find in Selection in the editor core's one
  matcher (`editor/find_match.nim`), the find session (`viewmodels/find_vm.nim`),
  the vocabulary's seeds (`editor/operations.nim`), the terminal's runtime and
  GPUI's window; and nim-regex's admission into the core's import closure
  (`ci/test/editor-import-closure.sh`, `common/editor_core_admission.nim`);
* OQ-F6, the find tokens: the terminal's roles, GPUI's leaf colours and the
  Monaco theme documents' colours (`lib/monaco_appearance.nim`);
* OQ-F7, the folder window's keys through the shared router (`gpui/main.nim`,
  `gpui/app/edit_arm.nim`).

Each arm plants ONE defect, REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` when an arm is graded through a binary the defect is
compiled into, runs the suites that must catch it, and requires RED — with
the failure the first run recorded (`plat70-find-decisions-mutation-because.json`,
derived with `--derive`).

The discipline is Part C's harness's (`run-plat70c-find-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT70FD_BUILD_TUI` / `$PLAT70FD_BUILD_GPUI` when set, else
`just build-tui` / `just build-gpui`.

Usage:
    run-plat70-find-decisions-mutations.py [--only R1,R2] [--derive]
    run-plat70-find-decisions-mutations.py --needle-scan
    run-plat70-find-decisions-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70-find-decisions-mutation-control.sha256"
BECAUSE = HERE / "plat70-find-decisions-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70-find-decisions-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
MATCH = "src/frontend/viewmodel/editor/find_match.nim"
OPS = "src/frontend/viewmodel/editor/operations.nim"
FINDVM = "src/frontend/viewmodel/viewmodels/find_vm.nim"
ADMISSION = "src/common/editor_core_admission.nim"
GATE = "ci/test/editor-import-closure.sh"
RUNTIME = "src/frontend/tui/app/runtime.nim"
ROLES = "src/frontend/tui/app/theme/roles.nim"
MONACO = "src/frontend/lib/monaco_appearance.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
GPUI_LEAVES = "src/frontend/gpui/app/leaves.nim"
EDIT_ARM = "src/frontend/gpui/app/edit_arm.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70_find_regex.nim"
CLOSURE_GATE = "src/frontend/viewmodel/tests/unit/test_editor_async_closure.nim"
COLOURS = "src/frontend/tui/tests/test_plat70_find_colours.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70_find_regex_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70_find_decisions_gpui_plan.nim"

SUBJECTS = [MATCH, OPS, FINDVM, ADMISSION, GATE, RUNTIME, ROLES, MONACO,
            GPUI_MAIN, GPUI_LEAVES, EDIT_ARM]
SUITES = [VMU, CLOSURE_GATE, COLOURS, PTY, PLAN]

PTY_RX = "*::Alt+R reads the field as a regular expression, and back"
PTY_SCOPE = "*::Alt+L confines the search to the selected lines, and back"
PLAN_RX = "*::Alt+R reads the field as a regular expression"
PLAN_F7 = "*::Vim: / opens the widget, typing highlights, Enter keeps, n walks"
PLAN_F7_SCOPE = "*::folder window highlights follow the open session in selection"
PLAN_TOKENS = "*::the bands are painted with the find tokens"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- OQ-F5: the matcher ------------------------------------------------------
    ("R1", [(MATCH, "  if not options.caseSensitive: flags.incl regexCaseless",
             "  discard options.caseSensitive")],
     [(VMU, None)],
     "a regular expression ignores Match Case off (never caseless)"),
    ("R2", [(MATCH, "      if pattern[i] in {'n', 'r', 'W'}: return true",
             "      discard pattern[i]")],
     [(VMU, None)],
     "an expression that can match a line break is searched line by line"),
    ("R3", [(MATCH, "    if wholeWord and (wordBefore(s, a) or wordAt(s, b)): continue",
             "    discard wholeWord")],
     [(VMU, None)],
     "Match Whole Word is not applied to a regular expression's matches"),
    ("R4", [(MATCH, "  if lookaroundRepeats(pattern):",
             "  if false:")],
     [(VMU, None)],
     "the guard: a look-around around a repetition is searched (polynomial time)"),
    ("R5", [(MATCH, "  if expandedSize(pattern) > RegexSizeLimit:",
             "  if false:")],
     [(VMU, None)],
     "the guard: a counted repetition expanding past the limit is compiled"),
    ("R6", [(MATCH, "  if scope.len == 0: return @[MatchSpan(a: 0, b: doc.len)]",
             "  return @[MatchSpan(a: 0, b: doc.len)]")],
     [(VMU, None)],
     "Find in Selection's scope is ignored by the matcher"),
    ("R7", [(MATCH, "  if validateUtf8(text) >= 0: flags.incl regexArbitraryBytes",
             "  discard validateUtf8(text)")],
     [(VMU, None)],
     "a document that is not valid UTF-8 is searched as if it were (undefined)"),
    # ---- OQ-F5: the session and the vocabulary ------------------------------------
    ("S1", [(FINDVM, "  d.state.search.options.regex = not d.state.search.options.regex\n  f.recompute(d)",
             "  d.state.search.options.regex = not d.state.search.options.regex")],
     [(VMU, None)],
     "Alt+R flips the toggle and leaves the old highlights"),
    ("S2", [(FINDVM, "    if b > a and doc[b - 1] == '\\n':",
             "    if false:")],
     [(VMU, None)],
     "Find in Selection keeps a scope's trailing line break (VS Code ends it at the line's end)"),
    ("S3", [(FINDVM, "      if '\\n' notin t: return literalPattern(t, options)",
             "      if '\\n' notin t: return t")],
     [(VMU, None)],
     "a seed from the selection is not escaped while the toggle is on"),
    ("S4", [(OPS, "  after.search.pattern = literalPattern(t, st.search.options)\n  after.search.options.wholeWord = false",
             "  after.search.pattern = t\n  after.search.options.wholeWord = false")],
     [(VMU, None)],
     "search-selection (Vim's g*) is not escaped while the toggle is on"),
    ("S5", [(FINDVM, "    # The toggle outlives the session, as VS Code's `isRegex` does.\n    regex: regex)",
             "    regex: false)")],
     [(VMU, None)],
     "the regular-expression toggle does not outlive the session"),
    ("S6", [(FINDVM, "                      scope = f.scope)\n  f.wrapped = w.wrapped",
             "                      )\n  f.wrapped = w.wrapped")],
     [(VMU, None)],
     "the walk (Enter / F3) leaves the scope"),
    # ---- OQ-F5: nim-regex's admission into the core -----------------------------------
    ("A1", [(GATE, "		if [ \"${spec}\" = \"${lib}\" ] || [ \"${spec}\" = \"pkg/${lib}\" ]; then",
             "		if [ -n \"${lib}\" ]; then")],
     [(CLOSURE_GATE, None)],
     "the closure admits any library, not only the admitted one"),
    ("A2", [(GATE, "			case \"${resolved}\" in @lib:*) continue ;; esac",
             "			:")],
     [(CLOSURE_GATE, None)],
     "the closure walks into the admitted library (its debug-only std/os reddens the core)"),
    ("A3", [(ADMISSION, "  EditorCoreAdmittedLibraries*: array[1, tuple[primitive, replacement: string]] = [",
             "  EditorCoreAdmittedLibraries*: array[2, tuple[primitive, replacement: string]] = ["),
            (ADMISSION, "dotgraph`'s debug dump\"),",
             "dotgraph`'s debug dump\"),\n    (\"jsony\", \"planted\"),")],
     [(CLOSURE_GATE, None)],
     "a second library admitted without a reviewed checkout"),
    # ---- OQ-F5: the front-ends --------------------------------------------------------------
    ("T1", [(RUNTIME, "               of \"find.toggle-regex\": rt.app.find.toggleRegex(buf.doc)",
             "               of \"find.toggle-regex\": rt.app.find.toggleCase(buf.doc)")],
     [(PTY, PTY_RX)],
     "the terminal's Alt+R runs Match Case"),
    ("T2", [(RUNTIME, "                  \"find.toggle-regex\", \"find.toggle-in-selection\",",
             "                  \"find.toggle-regex\",")],
     [(PTY, PTY_SCOPE)],
     "the terminal's Alt+L is not bound to the session"),
    ("G1", [(GPUI_MAIN, "    if gFind.open: reveal = gFind.toggleRegex(d)",
             "    discard")],
     [(PLAN, PLAN_RX)],
     "GPUI's Alt+R does nothing"),
    # ---- OQ-F6: the tokens -----------------------------------------------------------------
    ("K1", [(ROLES, "    srSurfaceFindMatch: bgOnly(dgSurface, dtEditorThemeFindMatchHighlight,",
             "    srSurfaceFindMatch: bgOnly(dgSurface, dtColorsUiSurfaceAlertWarning,")],
     [(COLOURS, None)],
     "the terminal paints every match on the alert surface again"),
    ("K2", [(MONACO, "  doc[\"colors\"][\"editor.findMatchBackground\"] =\n    %DesignTokenHex[dtEditorThemeFindMatch][mode]",
             "  discard mode")],
     [(COLOURS, None)],
     "Monaco is not given the current match's token (it draws vs-dark's)"),
    ("K3", [(GPUI_LEAVES, "  FindMatchCurrentColour* = DesignTokenHex[dtEditorThemeFindMatch][dmDark]",
             "  FindMatchCurrentColour* = DesignTokenHex[dtEditorThemeSelection][dmDark]")],
     [(PLAN, PLAN_TOKENS)],
     "GPUI paints the current match on another token (the selection's)"),
    # ---- OQ-F7: the folder window ------------------------------------------------------------
    ("F1", [(GPUI_MAIN, "     res.operation.startsWith(\"find.\") or",
             "     false or")],
     [(PLAN, PLAN_F7)],
     "the folder window's `/` reaches the document, not the router (OQ-F7's defect)"),
    ("F2", [(GPUI_MAIN, "  if gFind.open and gFind.owner == \"editor:\" & openArm.path:\n    routeWindowKey(r, key, mods)\n    return true",
             "  if false:\n    routeWindowKey(r, key, mods)\n    return true")],
     [(PLAN, PLAN_F7)],
     "the folder window's open find field does not take the keys typed into it"),
    ("F3", [(EDIT_ARM, "  for m in find.marksInWindow(arm.doc, arm.viewportTop, viewportHeight):",
             "  var closed: FindVM\n  for m in closed.marksInWindow(arm.doc, arm.viewportTop, viewportHeight):")],
     [(PLAN, PLAN_F7_SCOPE)],
     "the folder window draws no highlights while its session is open"),
    # ---- the declared survivor -------------------------------------------------------------
    ("N1", [(MATCH, "  if b > a: result.add MatchSpan(a: a, b: b)\n  for i in 1 ..< result.len:",
             "  if a < b: result.add MatchSpan(a: a, b: b)\n  for i in 1 ..< result.len:")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR (the same comparison, mirrored)"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {MATCH, OPS, FINDVM, RUNTIME, ROLES}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {MATCH, OPS, FINDVM, GPUI_MAIN, GPUI_LEAVES, EDIT_ARM}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = set()
  # No arm here is graded through the desktop's bundle: its one subject
  # (`lib/monaco_appearance`) is held by the token suite in process.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = set()


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
        f.write("# Control digests for run-plat70-find-decisions-mutations.py — the\n"
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
    return build_with("PLAT70FD_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70FD_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70FD_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70FD_DESKTOP_TEST")
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
            backups[rel] = path.with_name(path.name + ".plat70fdbak")
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
