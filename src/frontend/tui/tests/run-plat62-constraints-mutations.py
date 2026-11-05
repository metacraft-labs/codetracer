#!/usr/bin/env python3
"""PLAT-62 — the mutation harness for the Constraints pane on the terminal and
in the GPUI window (codetracer-pm `spec/Planned-Features/Noir-Studio.md`
§ "The Constraints pane on the terminal and the GPUI window (PLAT-62)"): the
shared ViewModel's rows, links to source, selection, activation and row menu
(`constraints_vm`), the declaration scan (`noir_test_syntax`), the measurement
rule (`constraints_answer`), the listing and each opcode's place
(`constraints_listing`, `raw_inflate`), the columns (`table_fit.constraintsFit`),
the native host and the terminal's source, painter, runtime and loop, the GPUI
leaf and window, the vocabulary view, the desktop's view, its host and its
recording tab.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` / desktop when the defect is compiled into a binary an arm
is graded through; runs the suites that must catch it; and requires RED — with
the failure the first run recorded (`plat62-constraints-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-58's harness's (`run-plat58-requests-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, and
`ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT62_BUILD_TUI` / `$PLAT62_BUILD_GPUI` /
`$PLAT62_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`. The desktop's arm is graded by the Electron capture
(`scripts/plat62-capture-electron.sh`, or `$PLAT62_DESKTOP_TEST`; a DISPLAY or
Xvfb is needed), whose answers file is restored after every run. The Nim
suites run the real `nargo` on the PLAT-62 crate (and, for the recording
cases, the real `ct`, `ct-test` and `REPLAY_SERVER_BIN`).

Usage:
    run-plat62-constraints-mutations.py [--only V1,T1] [--derive]
    run-plat62-constraints-mutations.py --needle-scan
    run-plat62-constraints-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat62-constraints-mutation-control.sha256"
BECAUSE = HERE / "plat62-constraints-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat62-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/constraints_vm.nim"
SYNTAX = "src/ct_test/frameworks/noir_test_syntax.nim"
ANSWER = "src/frontend/viewmodel/viewmodels/constraints_answer.nim"
FIT = "src/frontend/viewmodel/viewmodels/table_fit.nim"
HOST = "src/frontend/viewmodel/host/native_constraints_host.nim"
SOURCE = "src/frontend/tui/host/constraints_source.nim"
TUI_PANE = "src/frontend/tui/app/views/constraints_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
GPUI_LEAF = "src/frontend/gpui/constraints_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP_VIEW = "src/frontend/viewmodel/views/isonim_constraints_view.nim"
DESKTOP_HOST = "src/frontend/index/ns9_panes.nim"
LISTING = "src/frontend/viewmodel/viewmodels/constraints_listing.nim"
INFLATE = "src/common/raw_inflate.nim"
DESKTOP_TAB = "src/frontend/ui/constraints.nim"
MENU = "src/frontend/viewmodel/viewmodels/product_menu.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat62_constraints.nim"
TBL = "src/frontend/tui/tests/test_plat62_constraints.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat62_constraints_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat62_gpui_constraints.nim"
SPEC = "src/tests/gui/tests/constraints-pane/plat62-constraints-capture.spec.ts"
ANSWERS = "src/tests/visual/answers/plat62-constraints.electron.json"
FIXTURE = "src/frontend/tui/tests/fixtures/plat62_noir_circuit.nim"
RUST = "<no engine suite>"
DBL = "<no regression spec>"

SUBJECTS = [VM, SYNTAX, ANSWER, FIT, HOST, SOURCE, TUI_PANE, RUNTIME, SHELL,
            PROFILE, TUI_MAIN, GPUI_LEAF, GPUI_MAIN, VOCAB, DESKTOP_VIEW,
            DESKTOP_HOST, LISTING, INFLATE, DESKTOP_TAB, MENU]
SUITES = [VMU, TBL, PTY, PLAN, SPEC, ANSWERS, FIXTURE]

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared ViewModel ------------------------------------------------
    ("V1", [(VM, '  elif fn.name == "main":', '  elif false:')],
     [(VMU, None)],
     "a `main` declared twice is not the crate root's"),
    ("V2", [(VM, '    if fn.name.startsWith("directive_"):',
             '    if false:')],
     [(VMU, None), (TBL, None)],
     "a compiler directive is said to be a name nobody declares"),
    ("V3", [(VM, '    if d.name == fn.name and not d.isTest:',
             '    if d.name == fn.name:')],
     [(VMU, None)],
     "a `#[test]` is taken for the function a program names"),
    ("V4", [(VM, '    pick = 0', '    pick = -1')],
     [(VMU, None), (TBL, None), (PTY, None), (PLAN, None)],
     "a name declared once is placed nowhere"),
    ("V5", [(VM, '  vm.onOpenSource(link.path, link.line, link.column)',
             '  discard link.column')],
     [(VMU, None), (TBL, None)],
     "K67: activating a placed row opens nothing"),
    ("V6", [(VM, '  result.add ConstraintMenuEntry(label: GoToSourceLabel, action: cmGoToSource,\n'
                 '                                 enabled: link.linked, reason: link.reason)',
             '  result.add ConstraintMenuEntry(label: GoToSourceLabel, action: cmGoToSource,\n'
             '                                 enabled: true, reason: link.reason)')],
     [(VMU, None), (TBL, None)],
     "K68: Go to Source is offered on a row placed nowhere"),
    ("V7", [(VM, '  if not enabled:\n    return\n  let row = vm.rows.val[index]',
             '  if false:\n    return\n  let row = vm.rows.val[index]')],
     [(VMU, None)],
     "K68: a disabled menu entry runs"),
    ("V8", [(VM, '    result.copied = whereText(row.source)',
             '    result.copied = row.rowText')],
     [(VMU, None), (TBL, None)],
     "K68: Copy Source Location copies the name"),
    ("V9", [(VM, '  of "list.focus-page-up": next = (if cur < 0: 0 else: cur - max(1, page))',
             '  of "list.focus-page-up": next = (if cur < 0: 0 else: cur - 1)')],
     [(VMU, None)],
     "the list's Page Up moves one row"),
    ("V10", [(VM, '                               source: linkOpcode(op.place))',
              '                               source: links[f])')],
     [(VMU, None)],
     "an opcode row claims its function's line"),
    ("V11", [(VM, '      result.add unlinked(NoSourcesReason)',
              '      result.add unlinked("")')],
     [(VMU, None)],
     "rows read before the sources do not say why they are placed nowhere"),
    ("V12", [(VM, '  if link.linked: link.path & ":" & $link.line else: ""',
              '  if link.linked: link.path else: ""')],
     [(VMU, None), (TBL, None), (PLAN, None)],
     "a row's place drops its line"),
    ("Y1", [(SYNTAX, '      if attr.isTest:\n        pendingTest = true',
             '      if false:\n        pendingTest = true')],
     [(VMU, None)],
     "a `#[test]` is not marked as one"),
    ("Y2", [(SYNTAX, '    if not rel.endsWith(".nr") or not rel.startsWith("src/"):',
             '    if not rel.endsWith(".nr"):')],
     [(VMU, None)],
     "a source outside `src/`, which nargo does not compile, declares functions"),
    ("A1", [(ANSWER, '  if run.missing:\n    return NargoMissingText',
             '  if false:\n    return NargoMissingText')],
     [(VMU, None)],
     "a missing `nargo` is reported as a failed run"),
    ("A2", [(ANSWER, '  if not hasMarker:\n    return NotANoirCrateText',
             '  if false:\n    return NotANoirCrateText')],
     [(VMU, None), (TBL, None)],
     "a folder with no Nargo.toml is measured anyway"),
    ("A3", [(ANSWER, '           (if said.len > 0: said[0 ..< min(said.len, 400)]',
             '           (if false: said[0 ..< min(said.len, 400)]')],
     [(VMU, None)],
     "a failed run's error text is not said"),
    ("F1", [(FIT, '              minUnits: ConstraintNameFloorCells * unit, flex: 1),',
             '              minUnits: ConstraintNameFloorCells * unit, flex: 0),')],
     [(VMU, None)],
     "the name does not take the room the other columns leave"),
    # ---- the native host and the terminal ---------------------------------------
    ("H1", [(HOST, '    h.vm.setSources(sources)',
             '    discard root')],
     [(TBL, None), (PLAN, None)],
     "the native hosts place no row (the sources are never read)"),
    ("H2", [(HOST, '  if state == h.fingerprint:\n    return false',
             '  if true:\n    return false')],
     [(TBL, None)],
     "a save does not re-measure the circuit"),
    ("C1", [(SOURCE, '    if rt.paneAreaOf(paneConstraints).width <= 0:\n      return false',
             '    if false:\n      return false')],
     [(TBL, None)],
     "the circuit is measured for a window that never shows the pane"),
    ("C2", [(SOURCE, '      if buf.isDirty:', '      if false:')],
     [(TBL, None)],
     "an unsaved edit does not mark the counts stale"),
    ("C3", [(SOURCE, '      linked: row.source.linked, title: rowTitle(row))',
             '      linked: true, title: rowTitle(row))')],
     [(TBL, None)],
     "the terminal's pane draws every row as one a press takes somewhere"),
    ("T1", [(TUI_PANE, '      g.fillSurface(ry, area.col, width, 1, ConstraintsSelectedSurface)',
             '      discard ry')],
     [(TBL, None)],
     "the selected row is not drawn on the selection surface"),
    ("T2", [(TUI_PANE, '    let main = if model.stale or r.unconstrained or not r.linked:',
             '    let main = if model.stale:')],
     [(TBL, None)],
     "a row placed nowhere is drawn like a placed one"),
    ("T3", [(TUI_PANE, '  ConstraintsTarget(kind: cgRow, index: model.rows[i].index)',
             '  ConstraintsTarget(kind: cgRow, index: model.rows[0].index)')],
     [(TBL, None)],
     "K67: a press on any row is read as a press on the first"),
    ("T4", [(RUNTIME, '        let r = rt.actOnConstraints(ConstraintsAct(kind: cakRowMenu,',
             '        let r = rt.actOnConstraints(ConstraintsAct(kind: cakSelect,')],
     [(TBL, None)],
     "K68: a right press on a row opens no menu"),
    ("T5", [(RUNTIME, '       rt.runConstraintsKeyOperation(res.operation, outcome):',
             '       false:')],
     [(TBL, None)],
     "the focused pane's keys do not move the selection; Enter opens nothing"),
    ("T6", [(RUNTIME, '    if words.len == 1 and words[0] == "constraints":',
             '    if false:')],
     [(TBL, None), (PTY, None)],
     "`:constraints` does not open the pane"),
    ("T7", [(PROFILE, '     paneConstraints,\n'
                      '     # PLAT-61: the interactive shell (`views/shell_session_pane.nim`).',
             '     # PLAT-61: the interactive shell (`views/shell_session_pane.nim`).'),
            (SHELL, '  elif region.pane == paneConstraints and model.constraints.loaded:',
             '  elif false:')],
     [(PTY, None)],
     "the terminal draws the report leaf, not the pane"),
    ("T8", [(TUI_MAIN, '  # PLAT-62: the Constraints pane over this window\'s project; a row opens in\n'
                       '  # the editor.\n'
                       '  let constraints = newConstraintsSource(rt,\n'
                       '    proc(): string = app.projectRoot,\n'
                       '    proc(path: string; line, col: int): string =\n'
                       '      rt.openWorkingFileAt(path, line, col))',
             '  # PLAT-62: the Constraints pane over this window\'s project; a row opens in\n'
             '  # the editor.\n'
             '  let constraints = newConstraintsSource(rt,\n'
             '    proc(): string = app.projectRoot,\n'
             '    proc(path: string; line, col: int): string =\n'
             '      "refused")')],
     [(PTY, None)],
     "the shipped Edit window opens no row's line"),
    ("P1", [(VOCAB, '        cells.add @[row.name, row.kindLabel, row.count, whereText(row.source)]',
             '        cells.add @[row.name, row.kindLabel, row.count, ""]')],
     [(TBL, None)],
     "the vocabulary's Constraints view drops where each function is declared"),
    # ---- GPUI -------------------------------------------------------------------
    ("G1", [(GPUI_MAIN, '    if pressConstraints(r, x, y, right = true):',
             '    if false:')],
     [(PLAN, None)],
     "K68: a right press on a GPUI row opens no menu"),
    ("G2", [(GPUI_LEAF, '  result = GConstraintsHit(kind: gcRow, index: i)',
             '  result = GConstraintsHit(kind: gcRow, index: 0)')],
     [(PLAN, None)],
     "K67: a GPUI press on any row is read as a press on the first"),
    ("G3", [(GPUI_MAIN, '    if not gConstraintsStarted:', '    if false:')],
     [(PLAN, None)],
     "the GPUI window never measures the circuit"),
    ("G4", [(GPUI_MAIN, '    runConstraintsMenu(r, action, target)',
             '    discard target')],
     [(PLAN, None)],
     "K68: a GPUI row menu's entries do nothing"),
    # ---- the desktop ----------------------------------------------------------------
    ("D1", [(DESKTOP_VIEW, '  result = proc() = discard vm.activateRow(captured)',
             '  result = proc() = discard captured')],
     [(VMU, None)],
     "K67: a press on a desktop row opens nothing"),
    ("D2", [(DESKTOP_HOST, '    if measured.hasReport: sourcesJson(noirSourcesUnder(folder)) else: "[]"',
             '    if false: sourcesJson(noirSourcesUnder(folder)) else: "[]"')],
     [(SPEC, None)],
     "the desktop's host sends no sources, so no desktop row is placed"),
    ("D3", [(DESKTOP_TAB, '      askToMeasure(data.activeSession)',
             '      discard data.activeSession')],
     [(SPEC, None)],
     "a recording's tab on the desktop never measures the circuit"),
    ("D4", [(MENU, '      item("Constraints", "aConstraints"),\n      item("Start Agent Worktree Session", "aStartAgenticWorktreeSession"),',
             '      item("Start Agent Worktree Session", "aStartAgenticWorktreeSession"),')],
     [(SPEC, None)],
     "a desktop user cannot open the pane in Debug mode"),
    ("D5", [(DESKTOP_HOST, '    listing: cstring(measured.listing),',
             '    listing: cstring(""),')],
     [(SPEC, None)],
     "the desktop's host sends no opcodes, so it shows totals alone"),
    ("D6", [(DESKTOP_HOST, '    artefact: (if measured.hasReport:',
             '    artefact: (if false:')],
     [(SPEC, None)],
     "the desktop's host sends no debug symbols, so no opcode is placed"),
    # ---- the listing and where each opcode leads ------------------------------
    ("L1", [(LISTING, '      if nextAcir >= acir.len or acir[nextAcir].opcodes != fn.opcodes:',
             '      if nextAcir >= acir.len:')],
     [(VMU, None)],
     "a listing that does not add up to the totals is shown under them"),
    ("L2", [(LISTING, '  if listing.count(AcirListingHeader) > 1:', '  if false:')],
     [(VMU, None)],
     "a workspace's listings are read as one package's"),
    ("L3", [(LISTING, '  for i in countdown(frames.len - 1, 0):',
             '  for i in 0 ..< frames.len:')],
     [(VMU, None)],
     "an inlined opcode leads to its call, not its own line"),
    ("L4", [(LISTING, '         text == source.content:', '         true:')],
     [(VMU, None)],
     "an opcode is placed on a file that changed after the compile"),
    ("L5", [(LISTING, '            op.place = placeOfStack(treeOf(info), located[key].getInt, files)\n            break',
             '            break')],
     [(VMU, None)],
     "an unconstrained function's opcodes are never placed"),
    ("L6", [(LISTING, '    # folder holds, so a malformed one is an expected input.\n    unread = true',
             '    # folder holds, so a malformed one is an expected input.\n    discard')],
     [(VMU, None)],
     "an unreadable artefact reads as opcodes the compiler did not place"),
    ("L7", [(LISTING, '  if at == 0 and not output.startsWith("{"):\n    return ("", output)\n  (output[0 ..< at], output[at .. ^1])',
             '  ("", output)')],
     [(VMU, None)],
     "the printed opcodes are read as part of the JSON report"),
    ("I1", [(INFLATE, '      var from0 = output.len - distance',
             '      var from0 = output.len - distance + 1')],
     [(VMU, None)],
     "a deflate back-reference copies from the wrong place"),
    ("I2", [(INFLATE, '      if output.len + length > limit:\n        fault("the stream expands past the limit")\n      # Byte by byte: a distance shorter than the length repeats what this very',
             '      # Byte by byte: a distance shorter than the length repeats what this very')],
     [(VMU, None)],
     "a deflate stream can expand past its limit"),
    ("N1", [(ANSWER, '  NargoInfoArgs* = ["info", "--json", "--print-acir"]',
             '  NargoInfoArgs* = ["info", "--json"]')],
     [(TBL, None)],
     "the hosts do not ask for the opcodes"),
    ("N2", [(HOST, '      readQuietly(artefactPathUnder(root, answer.report.package)), sources))',
             '      "", sources))')],
     [(TBL, None)],
     "a native window reads no debug symbols, so no opcode is placed"),
    ("N3", [(RUNTIME, '  of "aConstraints": (true, paneConstraints)',
             '  of "aConstraintsX": (true, paneConstraints)')],
     [(TBL, None)],
     "View › Constraints does nothing on the terminal"),
    ("N4", [(GPUI_MAIN, '  of "aConstraints": GpuiMenuRoute(kind: gmrPane, pane: paneConstraints)',
             '  of "aConstraintsX": GpuiMenuRoute(kind: gmrPane, pane: paneConstraints)')],
     [(PLAN, None)],
     "View › Constraints does nothing in the GPUI window"),
    ("N5", [(TUI_PANE, '      if placeCells > 0:',
             '      if false:')],
     [(PTY, None)],
     "the terminal does not say where an opcode's row leads"),
]

DECLARED_SURVIVORS = set()

IN_BINARY = {VM, SYNTAX, ANSWER, FIT, HOST, SOURCE, TUI_PANE, RUNTIME, SHELL,
             PROFILE, TUI_MAIN, VOCAB, LISTING, INFLATE, MENU}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {VM, SYNTAX, ANSWER, FIT, HOST, GPUI_LEAF, GPUI_MAIN, VOCAB, LISTING,
           INFLATE, MENU}
  # Subjects compiled into `codetracer-gpui`.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
RUST_SUITES = set()
DESKTOP_SUITES = {SPEC}
IN_DESKTOP = {VM, SYNTAX, ANSWER, DESKTOP_VIEW, DESKTOP_HOST, LISTING, INFLATE,
              DESKTOP_TAB, MENU}
  # Subjects compiled into the desktop's bundle and its main process.


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
        cwd=REPO, capture_output=True, text=True, errors="replace",
        check=True).stdout.split()


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
        f.write("# Control digests for run-plat62-constraints-mutations.py — the\n"
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
    p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True, errors="replace",
                       timeout=TIMEOUT)
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-2000:])
    return p.returncode == 0


def build_binary():
    return build_with("PLAT62_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT62_BUILD_GPUI", "build-gpui")


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


def run_rust(suite):
    """The engine's suite: GREEN on rc 0, else RED on its first panic."""
    cmd = os.environ.get("PLAT62_CARGO_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["cargo", "test", "--test", Path(suite).stem]
    cwd = REPO if cmd else REPO / "src/db-backend"
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, errors="replace",
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    if "error[" in out and "test result" not in out:
        return "DID-NOT-COMPILE", []
    first = [ln.strip() for ln in out.splitlines()
             if "panicked at" in ln or ln.strip().startswith("ct/seek")][:1]
    first = [re.sub(r":\d+:\d+:", "", f) for f in first]
    return "RED", first


def run_spec(suite):
    """A desktop suite in the real Electron app: GREEN on rc 0, else RED on
    its first expectation. The capture (SPEC) rewrites the answers file the
    native suites read, so the file is put back whatever the run did; the
    double-click regression (DBL) writes its own container."""
    cmd = os.environ.get("PLAT62_DESKTOP_TEST") if suite == SPEC else None
    if cmd:
        argv = ["bash", "-c", cmd]
    elif suite == SPEC:
        argv = ["bash", "scripts/plat62-capture-electron.sh"]
    else:
        argv = ["just", "test-e2e", suite.split("src/tests/gui/", 1)[1]]
    saved = path_of(ANSWERS).read_bytes()
    try:
        p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True, errors="replace",
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    finally:
        path_of(ANSWERS).write_bytes(saved)
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [ln.strip() for ln in plain.splitlines()
             if ln.strip().startswith(("Error:", "Expected:", "Received:"))][:2]
    return "RED", [" / ".join(first)] if first else []


def build_desktop():
    return build_with("PLAT62_BUILD_DESKTOP", "build-once")


def run_suite(suite, test_filter):
    if suite in RUST_SUITES:
        return run_rust(suite)
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
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, errors="replace",
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
    needs_desktop = any(s in DESKTOP_SUITES for arm in selected
                        for s, _ in arm[2])
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
            backups[rel] = path.with_name(path.name + ".plat62bak")
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
