#!/usr/bin/env python3
"""PLAT-63 — the mutation harness for the Verification pane on the terminal
and in the GPUI window (codetracer-pm `spec/Planned-Features/Verification-
Payload-Contract-v1.md` §5, §7, §9; `milestones/Verno-CodeTracer-Integration.
milestones.org` VN-M3, VN-M5): the pane every front-end draws (in
`verification_vm`: the findings by kind, the lines, the cursor, a press, the
row menu, where a finding's file is), the desktop's view of it, the native
host that runs the project's Verno action, the terminal's painter, runtime and
host, the GPUI leaf and window, the vocabulary view, the row menu's native
form, the layout schema and the desktop's pane table.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` when the defect is compiled into a binary an arm is graded
through; runs the suites that must catch it; and requires RED — with the
failure the first run recorded (`plat63-verification-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-60's harness's (`run-plat60-low-level-code-
mutations.py`), clause for clause: committed control digests over subjects AND
suites (§16c), a needle scan that gates re-recording (§39a), `because` derived
from a run, rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT63_BUILD_TUI` / `$PLAT63_BUILD_GPUI` when set, else
`just build-tui` / `just build-gpui`; the suites compile with `$PLAT63_NIM`
when set, else `nim`. The suites drive real recorded Verno runs through the
product's runner (`tui/tests/fixtures/plat63_verno_projects`).

Usage:
    run-plat63-verification-mutations.py [--only V1,T1] [--derive]
    run-plat63-verification-mutations.py --needle-scan
    run-plat63-verification-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat63-verification-mutation-control.sha256"
BECAUSE = HERE / "plat63-verification-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat63-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/verification_vm.nim"
VIEW = "src/frontend/viewmodel/views/isonim_verification_view.nim"
HOSTVM = "src/frontend/viewmodel/host/native_verification_host.nim"
LAYOUT = "src/frontend/headless_app/layout_model.nim"
DESKTOP_PANES = "src/frontend/headless_app/desktop_panes.nim"
CLICKS = "src/frontend/headless_app/pane_clicks.nim"
TUI_PANE = "src/frontend/tui/app/views/verification_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
SOURCE = "src/frontend/tui/host/verification_source.nim"
GPUI_LEAF = "src/frontend/gpui/verification_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP_HOST = "src/frontend/ui/verification.nim"
DESKTOP_RUNNER = "src/frontend/index/verification_runner.nim"
DESKTOP_IPC = "src/frontend/ui_js.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat63_verification_vm.nim"
TBL = "src/frontend/tui/tests/test_plat63_verification.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat63_verification_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat63_gpui_verification.nim"
SPEC = "src/tests/gui/tests/verification-pane/desktop_verno_run.spec.ts"

SUBJECTS = [VM, VIEW, HOSTVM, LAYOUT, DESKTOP_PANES, CLICKS, TUI_PANE,
            RUNTIME, SOURCE, GPUI_LEAF, GPUI_MAIN, VOCAB, DESKTOP_HOST,
            DESKTOP_RUNNER, DESKTOP_IPC]
SUITES = [VMU, TBL, PTY, PLAN, SPEC]

TBL_PAINT = "*::every width: the header, the lines, the tones and the hit-tests"
TBL_WORDS = "*::the words, as the shared model has them"
TBL_SHORT = "*::short: the scrollbar, scrolled, and a press on it"
TBL_RUN = "*::a real pipeline-error run: open, Run, findings, a press, the menu"
TBL_CX = "*::the counterexample: offers, the steps, a press on each"
TBL_NONE = "*::a project that declares no Verno action offers no run, and says why"
PLAN_RUN = "*::a real run: Run, the findings by kind, a press, the menu, the keys"
PLAN_CX = "*::the counterexample: the offer opens it; the violation opens its line"
PTY_RUN = "*::Run, the findings by kind, a right-click, a press"
PTY_CX = "*::the counterexample: the offer opens it in the pane"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the pane's model (the shared ViewModel) ---------------------------
    ("V1", [(VM, "  FindingGroupOrder* = [vfkFailedObligation, vfkPipelineError,",
             "  FindingGroupOrder* = [vfkPipelineError, vfkFailedObligation,")],
     [(VMU, None)],
     "the groups are not listed failures first"),
    ("V2", [(VM, '  kindLabel(kind) & " (" & $count & ")"', "  kindLabel(kind)")],
     [(VMU, None), (TBL, TBL_RUN)],
     "a kind's heading drops its count"),
    ("V3", [(VM, "            line.column = finding.location.range.startColumn",
             "            line.column = 1")],
     [(VMU, None)],
     "an offer's source column is guessed"),
    ("V4", [(VM, "        line.line = finding.range.startLine",
             "        line.line = 1")],
     [(VMU, None), (TBL, TBL_RUN), (PTY, PTY_RUN), (PLAN, PLAN_RUN)],
     "a finding leads to line 1, not its own"),
    ("V5", [(VM, "    if step.position.isKnown:", "    if true:")],
     [(VMU, None), (TBL, TBL_CX)],
     "a step with no recorded position leads to a line"),
    ("V6", [(VM, "    elif at < 0: (if delta < 0: keys.high else: 0)",
             "    elif at < 0: 0")],
     [(VMU, None)],
     "a move up from no cursor lands on the first line"),
    ("V7", [(VM, "    else: clamp(at + delta, 0, keys.high)",
             "    else: (at + delta + keys.len) mod keys.len")],
     [(VMU, None)],
     "the cursor wraps instead of stopping at the ends"),
    ("V8", [(VM, "    if vm.openCounterexample(session, line.findingId):",
             "    if false:")],
     [(VMU, None), (TBL, TBL_CX), (PTY, PTY_CX), (PLAN, PLAN_CX)],
     "a press on an offer opens no counterexample"),
    ("V9", [(VM, "  let noSource = if line.hasSource: \"\" else: line.noSourceReason",
             "  let noSource = \"\"")],
     [(VMU, None)],
     "Go to Source is enabled where there is no source"),
    ("V10", [(VM, "        return VerificationMenuOutcome(note: e.reason)",
              "        discard")],
     [(VMU, None)],
     "a disabled menu entry runs anyway"),
    ("V11", [(VM, "    result.copied = line.location", "    result.copied = line.message")],
     [(VMU, None), (TBL, TBL_RUN)],
     "Copy Location copies the message"),
    ("V12", [(VM, "    result.add root[0 ..< slash] & \"/\" & file", "    discard")],
     [(VMU, None), (TBL, TBL_RUN), (PTY, PTY_RUN), (PLAN, PLAN_RUN)],
     "a file the reporter spells from the package's parent is not found"),
    ("V13", [(VM, "  vm.selectedKey.val = \"\"\n  vm.phase.val = vpStarting",
              "  vm.phase.val = vpStarting")],
     [(VMU, None)],
     "a new run keeps the last run's cursor"),
    ("V14", [(VM, "    canRun: vm.runnableLabel.val.len > 0 and not vm.isRunning.val,",
              "    canRun: vm.runnableLabel.val.len > 0,")],
     [(VMU, None)],
     "the Run control is offered while a run is in flight"),
    ("V15", [(VM, "      session.goToStep(line.row)\n    if line.hasSource:",
              "      discard\n    if line.hasSource:")],
     [(VMU, None), (TBL, TBL_CX), (PLAN, PLAN_CX)],
     "a press on a step does not move the counterexample"),
    # ---- the desktop's view ------------------------------------------------
    ("D1", [(VIEW, "              text group.heading", "              text \"\"")],
     [(VMU, None), (TBL, TBL_RUN)],
     "the desktop draws no kind heading"),
    ("D2", [(VIEW, "                   `data-ct-verification-location` = row.location,",
             "                   `data-ct-verification-location` = \"\",")],
     [(VMU, None)],
     "the desktop's row carries no location"),
    ("D3", [(VIEW, "      if mdl.canRun:", "      if false:")],
     [(VMU, None)],
     "the desktop draws no Run control where a host offers one"),
    # ---- the native host ---------------------------------------------------
    ("H1", [(HOSTVM, "    h.vm.offerRun(actions[0].label)", "    discard")],
     [(TBL, TBL_RUN), (PTY, PTY_RUN), (PLAN, PLAN_RUN)],
     "the project's declared Verno action is never offered"),
    ("H2", [(HOSTVM, "    if fileExists(candidate):", "    if true:")],
     [(TBL, TBL_RUN)],
     "a finding's file is taken without looking for it"),
    ("H3", [(HOSTVM, "    h.running = false", "    discard")],
     [(TBL, TBL_RUN)],
     "a run never settles"),
    ("H4", [(HOSTVM, "  h.run = startAction(h.vm, h.action.get, h.projectRoot)",
             "  h.run = startAction(h.vm, h.action.get, getTempDir())")],
     [(TBL, TBL_RUN)],
     "the action runs outside the project, and its report is not found"),
    # ---- the persisted vocabulary and the shared menu ----------------------
    ("L1", [(LAYOUT, "    of 7:\n      result = migrateV7toV8(result)", "    of 7777:\n      result = migrateV7toV8(result)")],
     [(VMU, None)],
     "a version-7 layout is no longer read"),
    ("L2", [(DESKTOP_PANES, "                                  content: Content.Verification,",
             "                                  content: Content.LowLevelCode,")],
     [(VMU, None)],
     "the pane is not the desktop's Verification content"),
    ("C1", [(CLICKS, "  result = ContextMenuModel(kind: cmkVerificationRow,",
             "  result = ContextMenuModel(kind: cmkLowLevelRow,")],
     [(TBL, TBL_RUN), (PLAN, PLAN_RUN)],
     "the native row menu is not the Verification pane's"),
    # ---- the terminal's painter, runtime and host --------------------------
    ("T1", [(TUI_PANE, "      g.fillSurface(y, area.col, width, 1, VerificationSelectedSurface)",
             "      discard")],
     [(TBL, TBL_PAINT)],
     "the cursor's line is not drawn on the selection surface"),
    ("T2", [(TUI_PANE, "  else: VerificationOtherKindStyle", "  else: VerificationTextStyle")],
     [(TBL, TBL_WORDS)],
     "a pipeline error's kind is not drawn in its tone"),
    ("T3", [(TUI_PANE, "  let i = screen.top + (row - screen.listTop)",
             "  let i = screen.top + (row - screen.listTop) + 1")],
     [(TBL, TBL_PAINT), (PTY, PTY_RUN)],
     "a press lands on the line below"),
    ("T4", [(TUI_PANE, "    result.trackCol = area.col + area.width - ScrubberTrackCells",
             "    discard")],
     [(TBL, TBL_SHORT)],
     "an overflowing list draws no scrollbar"),
    ("T5", [(TUI_PANE, "      return VerificationTarget(kind: vtRun, line: -1)",
             "      return VerificationTarget(kind: vtHeader, line: -1)")],
     [(TBL, TBL_RUN), (PTY, PTY_RUN)],
     "a press on Run runs nothing"),
    ("R1", [(RUNTIME, '  of "aVerification": (true, paneVerification)',
             '  of "aVerificationX": (true, paneVerification)')],
     [(TBL, TBL_RUN), (PTY, PTY_RUN)],
     "View › Verification opens nothing"),
    ("R2", [(RUNTIME, "      let r = rt.actOnVerification(VerificationAct(kind: vrRowMenu,",
             "      let r = rt.actOnVerification(VerificationAct(kind: vrPress,")],
     [(TBL, TBL_RUN), (PTY, PTY_RUN)],
     "a right press opens no menu"),
    ("R3", [(RUNTIME, "                      ask(rt.runVerificationKeyOperation(c.name, outcome)))",
             "                      ask(false))")],
     [(TBL, TBL_RUN)],
     "the list keys do not move the cursor"),
    ("R4", [(RUNTIME, '    rt.copyToClipboard(result.copied, "the line")', "    discard")],
     [(TBL, TBL_RUN)],
     "Copy Location reaches no clipboard"),
    ("S1", [(SOURCE, "    s.goTo(vm.activateLine(session, a.key), result)",
             "    discard vm.activateLine(session, a.key)")],
     [(TBL, TBL_RUN), (PTY, PTY_RUN)],
     "a press on a finding opens no file"),
    ("S2", [(SOURCE, "    result.menu = verificationRowContextMenuOf(vm, session, a.key)",
             "    discard")],
     [(TBL, TBL_RUN), (PTY, PTY_RUN)],
     "the row menu the host builds is empty"),
    ("S3", [(SOURCE, "    result.note = s.host.runVerification()", "    discard")],
     [(TBL, TBL_RUN), (PTY, PTY_RUN)],
     "Run runs nothing"),
    # ---- the GPUI leaf and window ------------------------------------------
    ("G1", [(GPUI_LEAF, '    r.setAttribute(el, "data-ct-verification-line-kind", $line.kind)',
             "    discard")],
     [(PLAN, PLAN_RUN)],
     "GPUI's lines carry no kind"),
    ("G2", [(GPUI_LEAF, '      r.setAttribute(el, "data-ct-selected", "true")', "      discard")],
     [(PLAN, PLAN_RUN)],
     "GPUI draws no cursor"),
    ("G3", [(GPUI_LEAF, "          (y - lay.list.y) div VerificationRowPx",
             "          (y - lay.list.y) div VerificationRowPx + 1")],
     [(PLAN, PLAN_RUN)],
     "a GPUI press lands on the line below"),
    ("G4", [(GPUI_LEAF, "    result.run = PxRect(x: right, y: inner.y, w: w, h: VerificationHeaderPx)",
             "    result.run = PxRect(x: right, y: inner.y, w: 0, h: VerificationHeaderPx)")],
     [(PLAN, PLAN_RUN)],
     "GPUI's Run control cannot be pressed"),
    ("M1", [(GPUI_MAIN, '  of "aVerification": GpuiMenuRoute(kind: gmrPane, pane: paneVerification)',
             '  of "aVerificationX": GpuiMenuRoute(kind: gmrPane, pane: paneVerification)')],
     [(PLAN, PLAN_RUN)],
     "GPUI's View › Verification opens nothing"),
    ("M2", [(GPUI_MAIN, "      opened = verificationGoTo(r, vm.activateLine(session, hit.key))",
             "      discard vm.activateLine(session, hit.key)")],
     [(PLAN, PLAN_RUN)],
     "a GPUI press on a finding opens no file"),
    ("M3", [(GPUI_MAIN, "    of \"list.focus-last\": vm.moveSelection(session, 1, toEnd = true)",
             "    of \"list.focus-last\": vm.moveSelection(session, 1)")],
     [(PLAN, PLAN_RUN)],
     "GPUI's End moves one line"),
    ("M4", [(GPUI_MAIN, "      discard verificationGoTo(r, outcome.activation)",
             "      discard")],
     [(PLAN, PLAN_RUN)],
     "GPUI's Go to Source from the menu opens nothing"),
    # ---- the vocabulary ----------------------------------------------------
    ("P1", [(VOCAB, "      cells.add @[row.kindLabel, row.title, row.message, row.location]",
             "      discard row")],
     [(TBL, TBL_RUN)],
     "the vocabulary's Verification view lists no finding"),
    # ---- the desktop's host and runner (the Electron app, one spec) --------
    ("W1", [(DESKTOP_HOST, "    vm.offerRun(actions[0].label)", "    discard")],
     [(SPEC, None)],
     "the desktop never offers the project's Verno action"),
    ("W2", [(DESKTOP_HOST, "  let cwd = actionWorkingDirectory(action, desktopProjectRoot)",
             "  let cwd = \"/\"")],
     [(SPEC, None)],
     "the desktop runs the action outside the project, and its report is not found"),
    ("W3", [(DESKTOP_HOST, "      verificationVMInstance.noteOutput(line)", "      discard line")],
     [(SPEC, None)],
     "a live run shows none of the verifier's output"),
    ("W4", [(DESKTOP_HOST, "        cstring(directory)), cstring(PayloadFileName)))",
             "        cstring(directory)), cstring(\"absent.json\")))")],
     [(SPEC, None)],
     "the run's report is never read"),
    ("W5", [(DESKTOP_HOST, "              runStartedAtUnixMs = run.startedAtUnixMs)",
             "              runStartedAtUnixMs = 0)")],
     [(SPEC, None)],
     "the desktop gives the report no start time, so this run's report reads as stale"),
    ("W6", [(DESKTOP_HOST, "  data.ipc.send cstring\"CODETRACER::verification-cancel\", js{}",
             "  discard")],
     [(SPEC, None)],
     "Stop never reaches the process"),
    ("W7", [(DESKTOP_RUNNER, "        if (process.platform !== 'win32') process.kill(-child.pid, name);",
             "        if (process.platform !== 'win32') process.kill(child.pid, name);")],
     [(SPEC, None)],
     "Stop leaves what the verifier started running"),
    ("W8", [(DESKTOP_RUNNER, "           {code: (typeof code === 'number') ? code : null,",
             "           {code: null,")],
     [(SPEC, None)],
     "the run's exit code never reaches the classifier"),
    ("W9", [(DESKTOP_HOST, "    if nodeFileExists(cstring(path)):", "    if true:")],
     [(SPEC, None)],
     "a finding's file is taken without looking for it"),
    ("W10", [(VIEW, "        verificationRunRequest(),", "        discard,")],
     [(SPEC, None)],
     "the desktop's Run control runs nothing"),
    ("W11", [(DESKTOP_HOST, "    refreshDesktopVerification()", "    discard")],
     [(SPEC, None)],
     "the pane does not read the project's task files when it opens"),
    ("W12", [(DESKTOP_HOST, "    vm.offerRun(\"\", NoVernoActionReason)",
              "    vm.offerRun(\"Verify with Verno\")")],
     [(SPEC, None)],
     "a project that declares no Verno action is offered a run"),
    ("W13", [(DESKTOP_HOST, "      vm.noteElapsed(elapsedNow()), 1000)", "      discard, 1000)")],
     [(SPEC, None)],
     "a live run's clock stands still"),
    ("W14", [(DESKTOP_IPC, "    cancelled = not response[\"cancelled\"].isUndefined and",
              "    cancelled = true or not response[\"cancelled\"].isUndefined and")],
     [(SPEC, None)],
     "every run's exit reads as a Stop"),
    # ---- the declared survivor ---------------------------------------------
    ("Z1", [(GPUI_LEAF, "  VerificationGapPx = 12", "  VerificationGapPx = 13")],
     [(PLAN, PLAN_RUN)],
     "behaviour-preserving: the DECLARED SURVIVOR (the GPUI line's gap)"),
]

DECLARED_SURVIVORS = {"Z1"}

IN_BINARY = {VM, VIEW, HOSTVM, LAYOUT, DESKTOP_PANES, CLICKS, TUI_PANE,
             RUNTIME, SOURCE, VOCAB}
IN_GPUI = {VM, HOSTVM, LAYOUT, DESKTOP_PANES, CLICKS, GPUI_LEAF, GPUI_MAIN,
           VOCAB}
IN_DESKTOP = {VM, VIEW, DESKTOP_HOST, DESKTOP_RUNNER, DESKTOP_IPC}
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}
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
        f.write("# Control digests for run-plat63-verification-mutations.py —\n"
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
    return build_with("PLAT63_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT63_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT63_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT63_DESKTOP_TEST")
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
    cmd = os.environ.get("PLAT63_RUST_TEST")
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
    cmd = [os.environ.get("PLAT63_NIM", "nim"), "c", "-r", "--hints:off",
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
            backups[rel] = path.with_name(path.name + ".plat63bak")
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
