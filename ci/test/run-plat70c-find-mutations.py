#!/usr/bin/env python3
"""NOT-A-CI-GATE: a mutation-grading instrument its owner runs in
Verification-Harness-Traps §39b's order (needle scan, record, grade), as every
`run-plat*-mutations.py` beside the suites is; it edits product sources in
place, so no lane may run it as a check. CI does start it — `ci/lint/nim.sh`'s
harness-argument-refusal step, by discovery, with a refused flag.

PLAT-70 Part C — the mutation harness for incremental search (the find
session every base drives, the one matcher, the one pattern store, the
word-under-the-caret launchers; Find-And-Incremental-Search.md §2 – §4).

Each arm plants ONE defect in the shared matcher (`editor/find_match.nim`),
the editing vocabulary (`editor/operations.nim`), the find session
(`viewmodels/find_vm.nim`), a base's rows (`keymap/*.nim`), the terminal's
painters or runtime, the GPUI window, or the desktop's Monaco wiring;
REBUILDS the shipped `codetracer-tui` / `codetracer-gpui` / desktop when the
defect is compiled into a binary an arm is graded through; runs the suites
that must catch it; and requires RED — with the failure the first run
recorded (`plat70c-find-mutation-because.json`, derived with `--derive`).

The discipline is PLAT-70 Part I's harness's (`run-plat70i-fit-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The milestone's arms (PLAT-70 "Mutation-harness expectations", C) are C1 –
C9; the rest hold the other parts of the delivery to their tests.

The builds run `$PLAT70C_BUILD_TUI` / `$PLAT70C_BUILD_GPUI` /
`$PLAT70C_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui`
/ `just build-once`. The desktop arms are graded by the Electron spec, run by
`$PLAT70C_DESKTOP_TEST` when set, else `npx playwright test` in
`src/tests/gui`.

Usage:
    run-plat70c-find-mutations.py [--only C1,C2] [--derive]
    run-plat70c-find-mutations.py --needle-scan
    run-plat70c-find-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat70c-find-mutation-control.sha256"
BECAUSE = HERE / "plat70c-find-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat70c-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
MATCH = "src/frontend/viewmodel/editor/find_match.nim"
OPS = "src/frontend/viewmodel/editor/operations.nim"
FINDVM = "src/frontend/viewmodel/viewmodels/find_vm.nim"
VIM = "src/frontend/viewmodel/keymap/vim_keymap.nim"
KAK = "src/frontend/viewmodel/keymap/kakoune_keymap.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
EMACS = "src/frontend/viewmodel/keymap/emacs_keymap.nim"
SEARCH = "src/frontend/tui/app/views/search.nim"
SOURCE_PANE = "src/frontend/tui/app/views/source_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
GPUI_LEAVES = "src/frontend/gpui/app/leaves.nim"
DESKTOP_EDITOR = "src/frontend/ui/editor.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat70c_find_vm.nim"
TBL = "src/frontend/tui/tests/test_plat70c_find.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat70c_find_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat70c_gpui_plan.nim"
SPEC = "src/tests/gui/tests/editor/plat70c-incremental-find.spec.ts"

SUBJECTS = [MATCH, OPS, FINDVM, VIM, KAK, CUA, EMACS, SEARCH, SOURCE_PANE,
            RUNTIME, GPUI_MAIN, GPUI_LEAVES, DESKTOP_EDITOR]
SUITES = [VMU, TBL, PTY, PLAN, SPEC]

PTY_CUA = "*::Ctrl+F seeds; typing highlights matchesOf's spans after every key (FS-3)"
PTY_VIM = "*::Vim: * moves whole-word, n continues, # goes back, g* matches inside"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the milestone's arms (PLAT-70, "Mutation-harness expectations", C) --
    ("C1", [(FINDVM, "  result = (f.origin.top, f.origin.leftCol)",
             "  result = (f.origin.top, -1)")],
     [(VMU, None)],
     "FS-4: find.cancel restores the selection but not the horizontal scroll"),
    ("C2", [(FINDVM, "  ## Popped: nothing of the session survives but the pattern in the store.\n  f = FindVM()",
             "  ## Popped: nothing of the session survives but the pattern in the store.\n  f = FindVM(field: f.field)")],
     [(VMU, None)],
     "FS-2: the session keeps its own copy of the pattern after close"),
    ("C3", [(FINDVM, "  f.current = noSpan()\n  if st.pattern.len > 0:",
             "  if st.pattern.len > 0:"),
            (FINDVM, "                        f.origin.searchFrom,\n                        forward = f.direction == sdForward)",
             "                        (if f.hasCurrent: f.current.a + 1 else: f.origin.searchFrom),\n                        forward = f.direction == sdForward)")],
     [(VMU, None)],
     "§3.3 step 2: the first match taken after the previous current match, not after the origin"),
    ("C4", [(VIM, "    BaseMacro(id: VimStarMacro, steps: @[\"select-inner-word\",\n      \"search-selection-whole-word\", \"search-forward\", \"flip-selections\",",
             "    BaseMacro(id: VimStarMacro, steps: @[\"select-inner-word\",\n      \"search-selection\", \"search-forward\", \"flip-selections\",")],
     [(VMU, None), (PTY, PTY_VIM)],
     "§4.3: Vim's `*` without whole-word"),
    ("C5", [(VIM, "      \"search-selection-whole-word\", \"search-backward\", \"flip-selections\",",
             "      \"search-selection-whole-word\", \"search-forward\", \"flip-selections\",")],
     [(VMU, None)],
     "§4.3: Vim's `#` searches forward"),
    ("C6", [(KAK, "  r.add eb(@[\"*\"], \"search-selection-whole-word\", KakouneLiveModes)",
             "  r.add eb(@[\"*\"], \"search-selection-whole-word\", KakouneLiveModes)\n  r.add eb(@[\"s\"], \"search-selection\", KakouneLiveModes)")],
     [(VMU, None)],
     "§4.4: Kakoune's `s` still bound to search-selection"),
    ("C7", [(FINDVM, "  let start = if f.hasCurrent: f.current.b",
             "  let start = if false: f.current.b")],
     [(VMU, None)],
     "§4.5: Emacs's C-w pulls from the caret instead of the match's end"),
    ("C8", [(CUA, "    BaseRow(chords: \"Escape\", operation: \"find.close\", whenText: \"findWidgetVisible\",",
             "    BaseRow(chords: \"Escape\", operation: \"find.cancel\", whenText: \"findWidgetVisible\",")],
     [(VMU, None), (PTY, PTY_CUA)],
     "FS-5 / OQ-F1: CUA's Escape bound to find.cancel (the kept match lost)"),
    ("C9", [(SEARCH, "  for m in matchesOf(line, query, MatchOptions(caseSensitive: caseSensitive)):",
             "  discard line.find(query, 0)\n  for m in matchesOf(line, query, MatchOptions(caseSensitive: caseSensitive)):")],
     [(TBL, None)],
     "FS-1: a second matcher left in tui/app/views/search.nim (the source gate)"),
    # ---- the matcher ------------------------------------------------------------
    ("M1", [(MATCH, "  if options.wholeWord and (wordBefore(doc, pos) or wordAt(doc, stop)):",
             "  if options.wholeWord and wordBefore(doc, pos):")],
     [(VMU, None)],
     "whole word ignores the character after the match"),
    ("M2", [(MATCH, "      if pr != dr and pr.toLower != dr.toLower: return -1",
             "      if pr != dr: return -1")],
     [(VMU, None)],
     "a non-ASCII pattern is not case-folded"),
    ("M3", [(MATCH, "        i += n\n        continue",
             "        i += 1\n        continue")],
     [(VMU, None)],
     "the match set overlaps (`aa` in `aaaa` is three)"),
    ("M4", [(OPS, "  let i = findFrom(env.ctx.doc, st.search.pattern, start, forward,\n                   st.search.options)",
             "  let i = findFrom(env.ctx.doc, st.search.pattern, start, forward)")],
     [(VMU, None)],
     "FS-1: search-next ignores the store's options (a second rule)"),
    # ---- the session ------------------------------------------------------------
    ("S1", [(FINDVM, "  of bkCua: fcrInsensitive",
             "  of bkCua: fcrSensitive")],
     [(VMU, None)],
     "§3.1: CUA's find is case-sensitive"),
    ("S2", [(FINDVM, "    d.state.search.options.caseSensitive = hasUpper(d.state.search.pattern)",
             "    discard")],
     [(VMU, None)],
     "§3.1: Emacs's case folding is not smart"),
    ("S3", [(FINDVM, "                              current: s.a == current.a and current.a >= 0)",
             "                              current: false)")],
     [(VMU, None), (TBL, None)],
     "§3.3 step 4: the current match is not told apart"),
    ("S4", [(FINDVM, "    sel = mapSelection(sel, d.timeline.delta(f.origin.version))",
             "    discard")],
     [(VMU, None)],
     "§3.5: cancel does not map the origin through an edit"),
    ("S5", [(FINDVM, "    discard d.applyNamed(\"search-selection-whole-word\", OpArgs(), nowMs)",
             "    discard d.applyNamed(\"search-selection\", OpArgs(), nowMs)")],
     [(VMU, None)],
     "§4.2: CUA's Ctrl+F3 on a word is not whole-word"),
    ("S6", [(FINDVM, "  f.fieldSelected = text.len > 0",
             "  f.fieldSelected = false")],
     [(VMU, None)],
     "§3.2: the seed is not selected, so typing appends to it"),
    # ---- Emacs's rows -------------------------------------------------------------
    ("R1", [(EMACS, "    BaseRow(chords: \"Ctrl+G\", operation: \"find.cancel\", whenText: \"findWidgetVisible\",",
             "    BaseRow(chords: \"Ctrl+G\", operation: \"find.close\", whenText: \"findWidgetVisible\",")],
     [(VMU, None)],
     "§4.5: Emacs's C-g keeps instead of restoring"),
    # ---- the terminal -------------------------------------------------------------
    ("T1", [(SOURCE_PANE, "        paintCellBand(g, row, codeCol, codeW, left, m.fromColumn, m.toColumn,",
             "        paintCellBand(g, row, codeCol, codeW, 0, m.fromColumn, m.toColumn,")],
     [(TBL, None)],
     "the source pane draws a mark ignoring the view's left column"),
    ("T2", [(RUNTIME, "  let reveal = rt.app.find.setQuery(buf.doc, rt.prompt.buffer,\n                                    rt.prompt.cursor)",
             "  let reveal = FindReveal()")],
     [(PTY, PTY_CUA)],
     "§3.3: the terminal's field does not search as it is typed into"),
    # ---- GPUI ---------------------------------------------------------------------
    ("G1", [(GPUI_MAIN, "    runFindOperation(r, res.operation, nowMs)\n    return",
             "    openOmnibar(r, CommandPrefix & \"grep \")\n    return")],
     [(PLAN, None)],
     "GPUI's find is the omnibar's `:grep` again"),
    ("G2", [(GPUI_LEAVES, "    r.setAttribute(band, FindMatchAttribute,",
             "    r.setAttribute(band, \"data-ct-find-match-x\",")],
     [(PLAN, None)],
     "GPUI draws no find highlights"),
    # ---- the desktop ----------------------------------------------------------------
    ("D1", [(DESKTOP_EDITOR, "  discard ed.setSelections(o.selections)",
             "  discard o.selections")],
     [(SPEC, None)],
     "FS-4 on the desktop: Find: Cancel and Return leaves the match selected"),
    # ---- the declared survivor ---------------------------------------------------------
    ("N1", [(FINDVM, "  f.capped = f.matches.len >= MatchesLimit",
             "  f.capped = f.matches.len > MatchesLimit - 1")],
     [(VMU, None)],
     "behaviour-preserving: the DECLARED SURVIVOR (the same comparison over integers)"),
]

DECLARED_SURVIVORS = {"N1"}

IN_BINARY = {MATCH, OPS, FINDVM, VIM, KAK, CUA, EMACS, SEARCH, SOURCE_PANE,
             RUNTIME}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {MATCH, OPS, FINDVM, VIM, KAK, CUA, EMACS, GPUI_MAIN, GPUI_LEAVES}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {DESKTOP_EDITOR, CUA}
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
        f.write("# Control digests for run-plat70c-find-mutations.py — the\n"
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
    return build_with("PLAT70C_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT70C_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT70C_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT70C_DESKTOP_TEST")
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
            backups[rel] = path.with_name(path.name + ".plat70cbak")
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
