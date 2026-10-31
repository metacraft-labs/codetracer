#!/usr/bin/env python3
"""PLAT-70 Part D — the mutation harness for `:grep` and Find in Files' field
(Find-And-Incremental-Search.md §5), and for the input framer's `ESC ESC`
reading that the keymap selector's DIFF-12 pty case tripped over.

Each arm plants ONE defect in the shared ViewModels (`search_results_vm`'s
seed and field request, `omnibar_vm`'s selected seed), the shared runner, the
terminal's runtime, host, painter or input framer, the GPUI window, or the
desktop's panel and routing; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` / desktop when the defect is compiled into a binary an arm
is graded through; runs the suites that must catch it; and requires RED —
with the failure the first run recorded (`plat70d-grep-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-70 Part B's harness's, clause for clause: committed
control digests over subjects AND suites (§16c), a needle scan that gates
re-recording (§39a), `because` derived from a run, rc 124 is a hang (§1),
per-arm restore verification, one declared behaviour-preserving survivor,
and `ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT70D_BUILD_TUI` / `$PLAT70D_BUILD_GPUI` /
`$PLAT70D_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui`
/ `just build-once`. The desktop arms are graded by the Electron spec, run by
`$PLAT70D_DESKTOP_TEST` when set, else `npx playwright test` in
`src/tests/gui`.

No mocks: the suites graded here run the shipped ViewModels, runner and
framer over real values, a real pipe and a real filesystem, the shipped
terminal binary on a real pty against a real recording and `replay-server`,
the shipped GPUI binary's window plan, and the real Electron app.

Usage:
    run-plat70d-grep-mutations.py [--only V1,T1] [--derive]
    run-plat70d-grep-mutations.py --needle-scan
    run-plat70d-grep-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70d-grep-mutation-control.sha256"
BECAUSE = HERE / "plat70d-grep-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70d-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
SEARCH_VM = "src/frontend/viewmodel/viewmodels/search_results_vm.nim"
OMNIBAR = "src/frontend/viewmodel/viewmodels/omnibar_vm.nim"
RUNNER = "src/frontend/viewmodel/host/find_in_files.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
TOPBAR = "src/frontend/tui/app/views/top_bar.nim"
TSESSION = "src/frontend/tui/host/tui_session.nim"
DRIVER = "src/frontend/tui/host/terminal_driver.nim"
GMAIN = "src/frontend/gpui/main.nim"
DVIEW = "src/frontend/viewmodel/views/isonim_search_results_view.nim"
DPANEL = "src/frontend/ui/search_results.nim"
DSERVICE = "src/frontend/services/search_service.nim"
UIJS = "src/frontend/ui_js.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70d_grep_vm.nim"
FS8 = "src/frontend/viewmodel/tests/unit/test_plat57_find_in_files.nim"
ESC = "src/frontend/tui/tests/test_esc_delay.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70d_grep_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70d_gpui_plan.nim"
SPEC = "src/tests/gui/tests/search/plat70d-grep.spec.ts"

SUBJECTS = [SEARCH_VM, OMNIBAR, RUNNER, RUNTIME, TOPBAR, TSESSION, DRIVER,
            GMAIN, DVIEW, DPANEL, DSERVICE, UIJS]
SUITES = [VMU, FS8, ESC, PTY, PLAN, SPEC]

PTY_CUA = "*::CUA: Ctrl+Shift+F opens the field on the selection, selected; typing replaces it; F4"
PTY_VIM = "*::Vim: :grep at Vim's own : prompt; :grep alone opens the field on the query"
PTY_NORG = "*::no rg on PATH: the walker gives the oracle's rows"
PLAN_SEL = "*::F4 selects the match; Ctrl+Shift+F opens the field on it, selected; typing replaces it"
PLAN_ALONE = "*::`:grep` alone with nothing selected: the field on the pane's query, selected"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared ViewModels ------------------------------------------------
    ("V1", [(SEARCH_VM,
             "  if selection.len > 0 and '\\n' notin selection and '\\r' notin selection:",
             "  if selection.len > 0 and '\\r' notin selection:")],
     [(VMU, None)],
     "§5.2: a selection over several lines seeds the field"),
    ("V2", [(SEARCH_VM,
             "  if selection.len > 0 and '\\n' notin selection and '\\r' notin selection:",
             "  if false:")],
     [(VMU, None), (PTY, PTY_CUA)],
     "§5.2: the selection never seeds the field (the pane's query does)"),
    ("V3", [(SEARCH_VM,
             "                                     revision: vm.fieldRequest.val.revision + 1)",
             "                                     revision: vm.fieldRequest.val.revision)")],
     [(VMU, None), (SPEC, None)],
     "§5.2: a second request is the first one again: the desktop's field does not open"),
    ("O1", [(OMNIBAR, "  if vm.removeSelected():\n    let at = vm.cursor",
             "  if false:\n    let at = vm.cursor")],
     [(VMU, None), (PTY, PTY_CUA)],
     "§5.2: typing inserts before the selected seed instead of replacing it"),
    ("O2", [(OMNIBAR, "    vm.anchor = prefix.len", "    vm.anchor = -1")],
     [(VMU, None), (PTY, PTY_CUA), (PLAN, PLAN_SEL)],
     "§5.2: the seed is not selected"),
    ("O3", [(OMNIBAR, "    vm.cursor = if delta < 0: a else: b",
             "    vm.cursor = if delta < 0: b else: a")],
     [(VMU, None)],
     "Left on a selection goes to its end, Right to its start"),
    ("O4", [(OMNIBAR, "  ## Delete the character before the caret, or the selected text.\n  if vm.removeSelected():",
             "  ## Delete the character before the caret, or the selected text.\n  if false:")],
     [(VMU, None)],
     "Backspace on the selected seed deletes one character"),
    # ---- the runner (the milestone's Part D arms) -------------------------------
    ("W1", [(RUNNER,
             "  if scope.stripPrefix.len > 0 and path.startsWith(scope.stripPrefix) and",
             "  if false and path.startsWith(scope.stripPrefix) and")],
     [(PTY, PTY_NORG)],
     "FS-8: with no rg, the walker's rows name the materialised `files/` path"),
    ("W2", [(RUNNER, "                   rgText(data{\"lines\"}), first, stop))",
             "                   (path & \":\" & $data{\"line_number\"}.getInt & \":\" & "
             "rgText(data{\"lines\"})).split(':')[2], first, stop))")],
     [(FS8, None)],
     "FS-8: rg's output read by a colon split (the `x.nim:12:` line)"),
    # ---- the terminal ------------------------------------------------------------
    ("T1", [(RUNTIME, "  let selection = if buf.isNil: \"\" else: selectionText(buf.doc)",
             "  let selection = \"\"")],
     [(PTY, PTY_CUA)],
     "§5.2: the terminal's field ignores the editor's selection"),
    ("T2", [(RUNTIME, "  rt.app.omnibar.openSelected(\":grep \", seed)",
             "  rt.app.omnibar.open(\":grep \" & seed)")],
     [(PTY, PTY_CUA)],
     "§5.2: the terminal's field opens on the seed without selecting it"),
    ("T3", [(TOPBAR, "        if picked.width > 0:", "        if false:")],
     [(PTY, PTY_CUA)],
     "§5.2: the selected seed is not drawn on the selection ground"),
    ("T4", [(RUNTIME, "  if mode == omProgram:", "  if mode == omProgram and needle.len > 0:")],
     [(PTY, PTY_CUA)],
     "§5.1: `:grep` alone falls to the palette's accept (\"nothing matches\")"),
    ("T5", [(RUNTIME, "  if mode == omProgram:", "  if false:")],
     [(PTY, PTY_NORG)],
     "§5.1: the omnibox's `:grep <text>` falls to the palette's accept again"),
    ("T6", [(RUNTIME, "      if words.len == 1: rt.openFindInFiles(outcome)",
             "      if words.len == 1: rt.runFindInFiles(\"\", outcome)")],
     [(PTY, PTY_VIM)],
     "§5.1: `:grep` alone at Vim's prompt searches nothing instead of opening the field"),
    ("T7", [(TSESSION, "  if vm.isNil: rt.app.search.query else: vm.openField(selection)",
             "  if vm.isNil: rt.app.search.query else: selection")],
     [(PTY, PTY_VIM)],
     "§5.2: the host passes the selection through, never the pane's query"),
    # ---- the input framer (DIFF-12) ---------------------------------------------
    ("F1", [(DRIVER, "        f.paired = true\n        return (true, $Esc)",
             "        f.reset()\n        return (true, $Esc)")],
     [(ESC, None)],
     "`ESC ESC O P` loses F1's ESC: `O`, `P` are typed (the DIFF-12 flake)"),
    ("F2", [(DRIVER, "    if not paired:\n      return DriverEvent(kind: dekToken, token: $Esc)\n    if next >= 0:\n      return DriverEvent(kind: dekIdle)\n  var wait = timeoutMs",
             "    if true:\n      return DriverEvent(kind: dekToken, token: $Esc)\n    if next >= 0:\n      return DriverEvent(kind: dekIdle)\n  var wait = timeoutMs"),
            (DRIVER, "      let paired = d.framer.paired\n      d.framer.reset()\n      if not paired:\n        return DriverEvent(kind: dekToken, token: $Esc)\n    return DriverEvent(kind: dekIdle)",
             "      let paired = d.framer.paired\n      d.framer.reset()\n      return DriverEvent(kind: dekToken, token: $Esc)\n    return DriverEvent(kind: dekIdle)")],
     [(ESC, None)],
     "`ESC ESC` alone is two Escs"),
    ("F3", [(DRIVER, "      if f.paired:\n        # The pair's second `ESC`, continued by no escape sequence: the byte",
             "      if false:\n        # The pair's second `ESC`, continued by no escape sequence: the byte")],
     [(ESC, None)],
     "`ESC ESC j` is Esc and Alt+j: the pair's second ESC made a modifier"),
    # ---- GPUI ------------------------------------------------------------------------
    ("G1", [(GMAIN, "  let selection = if gDebugDocs.hasKey(path): selectionText(gDebugDocs[path])",
             "  let selection = if false: selectionText(gDebugDocs[path])")],
     [(PLAN, PLAN_SEL)],
     "§5.2: GPUI's field ignores the editor's selection"),
    ("G2", [(GMAIN, "  gOmnibar.openSelected(CommandPrefix & \"grep \", seed)",
             "  gOmnibar.open(CommandPrefix & \"grep \" & seed)")],
     [(PLAN, PLAN_ALONE)],
     "§5.2: GPUI's field opens on the seed without selecting it"),
    ("G3", [(GMAIN, "        if showsQuery and selA >= 0:", "        if false:")],
     [(PLAN, PLAN_SEL)],
     "§5.2: GPUI does not draw the selected seed"),
    # ---- the desktop ------------------------------------------------------------------
    ("D1", [(UIJS, "    search_results.openFindInFilesField(),", "    data.findInFiles(),")],
     [(SPEC, None)],
     "§5.2: Ctrl+Shift+F opens the palette on `:grep ` again, not the panel's field"),
    ("D2", [(DVIEW, "      {.importjs: \"((n) => setTimeout(() => { n.focus(); n.select(); }, 0))(#)\".}",
             "      {.importjs: \"((n) => setTimeout(() => { n.focus(); }, 0))(#)\".}")],
     [(SPEC, None)],
     "§5.2: the desktop's field is focused but its text is not selected"),
    ("D3", [(DSERVICE, "      openFindInFilesFieldHook()", "      discard")],
     [(SPEC, None)],
     "§5.1: the desktop's `:grep` alone does nothing"),
    ("D4", [(DPANEL, "    discard vm.openField(editorSelectionText())",
             "    discard vm.openField(\"\")")],
     [(SPEC, None)],
     "§5.2: the desktop's field ignores Monaco's selection"),
    # ---- the declared survivor ----------------------------------------------------------
    ("N1", [(OMNIBAR, "  if a < b: (a, b) else: (-1, -1)", "  if b > a: (a, b) else: (-1, -1)")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {SEARCH_VM, OMNIBAR, RUNNER, RUNTIME, TOPBAR, TSESSION, DRIVER}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {SEARCH_VM, OMNIBAR, RUNNER, GMAIN}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {SEARCH_VM, RUNNER, DVIEW, DPANEL, DSERVICE, UIJS}
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
        f.write("# Control digests for run-plat70d-grep-mutations.py — the\n"
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
    return build_with("PLAT70D_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70D_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70D_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70D_DESKTOP_TEST")
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
            backups[rel] = path.with_name(path.name + ".plat70dbak")
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
