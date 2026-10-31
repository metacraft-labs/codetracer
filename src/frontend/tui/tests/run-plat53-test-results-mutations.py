#!/usr/bin/env python3
"""PLAT-53 — the mutation harness for the Test Results pane on the terminal
and in the GPUI window (codetracer-pm `spec/GUI/Core-Panes/Test-Results-Pane.md`
§8, and §9 — which tab a test's recording opens in, on every front-end, the
`replay-open-in` setting, the Ctrl modifier, the hover tooltips, and a
maximized terminal pane's presses; the palette pair **Tests: Run** / **Tests:
Run in Current Tab**, `Ctrl+Enter` on a native row, and the desktop editor's
context-menu Run-test through the host): the words every front-end draws (moved into `test_results_vm`), the one
catalog rule (`test_catalog_answer`), the desktop's host over the native
producers (`viewmodel/host/native_test_host`), the terminal's painter,
runtime, host source and loop, the GPUI leaf and window, the vocabulary view,
and the desktop's catalog answer.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` / desktop when the defect is compiled into a binary an arm
is graded through; runs the suites that must catch it; and requires RED —
with the failure the first run recorded (`plat53-test-results-mutation-
because.json`, derived with `--derive`).

The discipline is PLAT-70 Part I's harness's (`ci/test/run-plat70i-fit-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT53_BUILD_TUI` / `$PLAT53_BUILD_GPUI` /
`$PLAT53_BUILD_DESKTOP` when set, else `just build-tui` / `just build-gpui` /
`just build-once`. The desktop arm is graded by the Electron capture spec, run
by `$PLAT53_DESKTOP_TEST` when set, else `npx playwright test` in
`src/tests/gui` (a DISPLAY is needed). Every suite runs the real `ct test
run` / `ct record-test` on a real Noir crate: `ct` (built beside its
`ct-test`) and `nargo` must be reachable, as the lanes require.

Usage:
    run-plat53-test-results-mutations.py [--only V1,T1] [--derive]
    run-plat53-test-results-mutations.py --needle-scan
    run-plat53-test-results-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat53-test-results-mutation-control.sha256"
BECAUSE = HERE / "plat53-test-results-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat53-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
VM = "src/frontend/viewmodel/viewmodels/test_results_vm.nim"
FIT = "src/frontend/viewmodel/viewmodels/table_fit.nim"
CATALOG = "src/frontend/viewmodel/viewmodels/test_catalog_answer.nim"
HOST = "src/frontend/viewmodel/host/native_test_host.nim"
TUI_PANE = "src/frontend/tui/app/views/test_results_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
SOURCE = "src/frontend/tui/host/test_results_source.nim"
TUI_MAIN = "src/frontend/tui/main.nim"
GPUI_LEAF = "src/frontend/gpui/test_results_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
NS9 = "src/frontend/index/ns9_panes.nim"
DESKTOP_HOST = "src/frontend/viewmodel/viewmodels/desktop_test_host.nim"
SETTING = "src/frontend/viewmodel/viewmodels/replay_open_setting.nim"
VIEW = "src/frontend/viewmodel/views/isonim_test_results_view.nim"
UI_JS = "src/frontend/ui_js.nim"
OMNI = "src/frontend/viewmodel/viewmodels/omnibar_sources.nim"
CUA = "src/frontend/viewmodel/keymap/cua_keymap.nim"
EDITOR = "src/frontend/ui/editor.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat53_test_results.nim"
TBL = "src/frontend/tui/tests/test_plat53_test_results.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat53_test_results_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat53_gpui_plan.nim"
SPEC = "src/tests/gui/tests/test-results-pane/plat53-test-results-capture.spec.ts"
VMT = "src/frontend/viewmodel/tests/unit/test_test_tab_placement.nim"
DSPEC = "src/tests/gui/tests/test-results-pane/desktop_suite_run_verdicts.spec.ts"
ORACLE = "src/frontend/viewmodel/tests/unit/test_plat68_cua_oracle.nim"

SUBJECTS = [VM, FIT, CATALOG, HOST, TUI_PANE, RUNTIME, SHELL, PROFILE, SOURCE,
            TUI_MAIN, GPUI_LEAF, GPUI_MAIN, VOCAB, NS9, DESKTOP_HOST, SETTING,
            VIEW, UI_JS, OMNI, CUA, EDITOR]
SUITES = [VMU, TBL, PTY, PLAN, SPEC, VMT, DSPEC, ORACLE]

TBL_HOST = "*::catalog, ▶, verdicts, selection, a recording opened, kill, refusal"
PLAN_OPEN = "*::the failing test's ⏵ opens its recording in a new tab; again, and with Shift"
PLAN_AFTER = "*::the ▶: the desktop's verdicts, message and colours"
PLAN_TAB = "*::§9: Ctrl opens in this tab; the hover label is the control's title"
TBL_CTRL = "*::Ctrl inverts the destination; Enter and the palette use the setting"
TBL_HOVER = "*::hovering a control puts its title on the status line; leaving restores"
TBL_MAX = "*::a maximized Test Results answers its presses where it is drawn"
PTY_TAB = "*::§9: a test's tab reused, Ctrl opens in this tab, hover, a maximized pane"
TBL_RUN = "*::Ctrl+Enter inverts; the palette's Run and Run in Current Tab record"
PLAN_RUN = "*::§9.3: Ctrl+Enter on the selected row; the palette's Tests: Run"
PLAN_SET = "*::§9.3: the omnibox's Tests: Open Recordings in the Current Tab"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the words every front-end draws (the ViewModel) -------------------
    ("V1", [(VM, '  of trsPassed: "✓"', '  of trsPassed: "·"')],
     [(VMU, None)],
     "§8.4: a passed test's mark is not the desktop's ✓"),
    ("V2", [(VM, '  if row.state == trsNotRun: ""', '  if true: ""')],
     [(VMU, None)],
     "§8.4: a test that ran shows no duration"),
    ("V3", [(VM, "  if vm.inFlight.val:\n    RunInProgressText\n  elif vm.runAbsence.val.len > 0:",
             "  if false:\n    RunInProgressText\n  elif vm.runAbsence.val.len > 0:")],
     [(VMU, None)],
     "§3: the ▶'s title does not say a run is already in progress"),
    ("V4", [(VM, "      for line in row.message.splitLines():",
             "      for line in newSeq[string]():")],
     [(VMU, None), (TBL, TBL_HOST)],
     "§8.4: a failed test's message is not listed under it"),
    ("V5", [(FIT, "    FitColumn(name: TestColumnNames[1], flex: TestNameFlex),",
             "    FitColumn(name: TestColumnNames[1], flex: TestWhereFlex),")],
     [(VMU, None)],
     "§8.4: the name does not outrank the location (the desktop's 1.8fr : 1fr)"),
    ("V6", [(FIT, "    FitColumn(name: TestColumnNames[3], preferredUnits: durationUnits,\n              neverCut: true),",
             "    FitColumn(name: TestColumnNames[3], preferredUnits: durationUnits,\n              neverCut: false),")],
     [(VMU, None)],
     "§8.4: the duration is cut when the pane is narrow"),
    # ---- the catalog rule ---------------------------------------------------
    ("C1", [(CATALOG, "    return TestCatalogAnswer(absence: NoTestProviderText)",
             "    discard")],
     [(VMU, None)],
     "§8.2: a folder that is not a Noir crate is parsed instead of stated"),
    ("C2", [(CATALOG, "    result = TestCatalogAnswer(absence: DiscoveryFailedStem &",
             "    result = TestCatalogAnswer(absence: \"\" &")],
     [(VMU, None)],
     "§8.2: a failed discovery says nothing about why"),
    # ---- the native producers (the desktop's host over them) -----------------
    ("N1", [(HOST, '  let ended = if signal > 0: suiteEndedBySignalText(signal) else: ""',
             '  let ended = ""')],
     [(TBL, TBL_HOST)],
     "§5: a run killed by a signal settles without saying so"),
    ("N2", [(HOST, "                                 options = {poDaemon})",
             "                                 options = {})")],
     [(TBL, TBL_HOST)],
     "§8.1: the run is not its own process group (a kill reaches only the shell)"),
    ("N3", [(DESKTOP_HOST, "  if run.openAfter and recordingId.len > 0:",
             "  if false:")],
     [(VMT, None), (TBL, TBL_HOST)],
     "§9.5: record-and-open records and never opens the recording"),
    ("N4", [(HOST, "  let why = h.openFolder(testId, recordingId, folder, policy)",
             "  let why = h.openFolder(testId, recordingId, recordingId, policy)")],
     [(TBL, TBL_HOST)],
     "§8.3: the window is handed the recording's id, not its folder"),
    ("N5", [(HOST, "  let events = readQuietly(job.eventsPath)",
             '  let events = ""')],
     [(TBL, TBL_HOST)],
     "§4.3: the runner's events file is not read (no verdicts)"),
    ("N6", [(HOST, "        path: relativePath(path, root).replace('\\\\', '/'),",
             "        path: path.replace('\\\\', '/'),")],
     [(TBL, TBL_HOST)],
     "§8.2: the sources are named by absolute path (the catalog finds no test)"),
    ("N7", [(HOST, "    job.killGroup(SIGTERM)", "    discard"),
            (HOST, "      job.killGroup(SIGKILL)", "      discard")],
     [(TBL, TBL_HOST)],
     "§5: the window's end leaves its `ct test run` running"),
    # ---- the terminal --------------------------------------------------------
    ("T1", [(TUI_PANE, "      let indent = TestsMarkCells + TestsGapCells\n      let t = truncateToCells(line.text, max(0, width - indent))",
             "      let indent = 0\n      let t = truncateToCells(line.text, max(0, width - indent))")],
     [(TBL, None)],
     "§8.4: a message is not indented under its row's name"),
    ("T2", [(TUI_PANE, "                           markStyle(r.tone))",
             "                           TestsNameStyle)")],
     [(TBL, None)],
     "§8.4: the passed and failed marks are not in the success / error colours"),
    ("T3", [(TUI_PANE, "      if col == a:", "      if col == a + 2:")],
     [(TBL, None)],
     "§8.4: a press on `⟳` is read as a press on `⏵`"),
    ("T4", [(RUNTIME, "  if control.enabled:", "  if true:")],
     [(TBL, TBL_HOST)],
     "§3: a disabled control runs anyway instead of saying why"),
    ("T5", [(RUNTIME, "    if at.found and at.region.pane == paneTestResults and rt.app.tests.loaded:",
             "    if false:")],
     [(TBL, TBL_HOST)],
     "§8.4: the wheel does not scroll the list"),
    ("T6", [(RUNTIME, "       rt.runTestsKeyOperation(res.operation, outcome):",
             "       false:")],
     [(TBL, TBL_HOST)],
     "§8.4: the keys do not move the selection; Enter is not `⏵`"),
    ("T7", [(SOURCE, "                      vm.openButtonTitle(row, shiftReachable = false),",
             "                      vm.openButtonTitle(row),")],
     [(TBL, TBL_HOST)],
     "§8.4: the terminal's `⏵` promises a Shift the terminal cannot hold"),
    ("T8", [(PROFILE, "     paneTestResults,", "     "),
            (SHELL, "  elif region.pane == paneTestResults and model.tests.loaded:",
             "  elif false:")],
     [(PTY, None)],
     "§8.4: the terminal draws the report leaf, not the pane"),
    ("T9", [(TUI_MAIN, "    of ttpNewTab:\n      let why = app.recordingOpener(folder)",
             '    of ttpNewTab:\n      let why = ""')],
     [(PTY, None)],
     "§8.3: the terminal says it opened the recording and opens no tab"),
    # ---- GPUI -----------------------------------------------------------------
    ("G1", [(GPUI_LEAF, "  of trsFailed, trsErrored: TestsErrorColour",
             "  of trsFailed, trsErrored: TestsTextColour")],
     [(PLAN, PLAN_AFTER)],
     "§8.4: the GPUI failed mark is not in the desktop's error colour"),
    ("G2", [(GPUI_LEAF, "    if x >= actions and x < actions + TestsActionPx:",
             "    if x >= actions + TestsActionPx and x < actions + 2 * TestsActionPx:")],
     [(PLAN, PLAN_OPEN)],
     "§8.4: a press on the GPUI `⏵` is read as `⟳` (stays, opens nothing)"),
    ("G3", [(GPUI_MAIN, "    vm.setShiftHeld(gPointerShift)",
             "    vm.setShiftHeld(false)")],
     [(PLAN, PLAN_OPEN)],
     "§4.4: Shift held does not arm the GPUI `⏵` (no re-record)"),
    ("G4", [(GPUI_MAIN, "    let before = gSessionsOpened.len\n    openRecordingInTab(rr, folder)",
             "    let before = gSessionsOpened.len\n    discard folder")],
     [(PLAN, PLAN_OPEN)],
     "§8.3: the GPUI window opens no tab for a test's recording"),
    # ---- §9: which tab a test's recording opens in -------------------------
    ("R1", [(VM, "      return TestTabPlacement(kind: ttpShowTab, tab: t.tab)",
             "      return TestTabPlacement(kind: ttpNewTab, tab: -1)")],
     [(VMT, None), (PLAN, PLAN_OPEN)],
     "§9.1 arm 1: the same recording again opens a second tab"),
    ("R2", [(VM, "    return TestTabPlacement(kind: ttpReplaceTab, tab: t.tab)",
             "    return TestTabPlacement(kind: ttpNewTab, tab: -1)")],
     [(VMT, None), (PTY, PTY_TAB)],
     "§9.1 rule 4: a re-run of the same test opens another tab"),
    ("R3", [(VM, "  if policy == topCurrentTab and vm.currentTabReplaceable.val and",
             "  if policy == topCurrentTab and")],
     [(VMT, None)],
     "§9.1 rule 3: an editing session is replaced by a replay"),
    ("R4", [(VM, "  if redirect: vm.openSetting.val.invert() else: vm.openSetting.val",
             "  vm.openSetting.val")],
     [(VMT, None), (TBL, TBL_CTRL)],
     "§9.3: Ctrl does not invert the destination"),
    ("R5", [(VM, '  action & " " & vm.openDestinationText(row)', "  action")],
     [(VMT, None), (PLAN, PLAN_TAB)],
     "§9.4: the ⏵ title does not say where it opens"),
    ("R6", [(DESKTOP_HOST, "    openPolicy: host.vm.effectiveOpenPolicy())",
             "    openPolicy: topNewTab)")],
     [(VMT, None)],
     "§9.5: record-and-open forgets the destination chosen at the press"),
    ("R7", [(SETTING, "    if e.workspace != key:", "    if true:")],
     [(VMT, None)],
     "§9.3: setting a workspace again adds a second line for it"),
    ("R8", [(HOST, "  h.vm.setOpenSetting(replayOpenFor(readReplayOpen(), root))",
             "  discard root")],
     [(TBL, TBL_CTRL)],
     "§9.3: the native host does not read the workspace's setting"),
    ("R9", [(VIEW, "    discard vm.testTabs.val", "    discard")],
     [(DSPEC, None)],
     "§9.4: the desktop's ⏵ title is not redrawn when the test gets a tab"),
    ("M1", [(RUNTIME, "  if not rt.maximize.active or not rt.layoutBindingEnabled():\n    return rt.layoutGeometry()",
             "  if true:\n    return rt.layoutGeometry()")],
     [(TBL, TBL_MAX), (PTY, PTY_TAB)],
     "CodeTracer-TUI §4.4: a maximized pane's presses go to the arrangement under it"),
    ("H1", [(RUNTIME, "        rt.testsHoverPointer(event, result)", "        discard")],
     [(TBL, TBL_HOVER), (PTY, PTY_TAB)],
     "§9.6: the terminal shows no title on hover"),
    ("H2", [(RUNTIME, "    model.status.notification = rt.app.testsHover",
             "    discard")],
     [(TBL, TBL_HOVER)],
     "§9.6: the hovered title never reaches the status line"),
    ("K1", [(RUNTIME, "                             behaviour: (if event.ctrl: TestsRedirectBehaviour",
             "                             behaviour: (if false: TestsRedirectBehaviour")],
     [(TBL, TBL_CTRL), (PTY, PTY_TAB)],
     "§9.3: the terminal drops Ctrl off a ⏵ press"),
    ("K2", [(SOURCE, "      s.vm.setRedirectHeld(true)", "      s.vm.setRedirectHeld(false)")],
     [(TBL, TBL_CTRL)],
     "§9.3: the terminal's Ctrl press is not held through the open"),
    ("K3", [(RUNTIME, "  let openIn = parseReplayOpenCommandTarget(action)\n  if openIn.ok:",
             "  let openIn = parseReplayOpenCommandTarget(action)\n  if false:")],
     [(TBL, TBL_CTRL)],
     "§9.3: the terminal's palette command does not set replay-open-in"),
    ("P2", [(TUI_MAIN, "      (replaceTab >= 0 and sessions.hasKey(replaceTab)) or",
             "      false or")],
     [(PTY, PTY_TAB)],
     "§9.5: the terminal opens a new tab where it should replace one"),
    ("P3", [(TUI_MAIN, "    tests.vm.noteTestTab(testId, int(shownId), recordingId)",
             "    discard")],
     [(PTY, PTY_TAB)],
     "§9.2: the terminal forgets which tab a test's recording is in"),
    ("G5", [(GPUI_MAIN, "    vm.setRedirectHeld(gPointerCtrl)", "    vm.setRedirectHeld(false)")],
     [(PLAN, PLAN_TAB)],
     "§9.3: Ctrl held does not redirect a GPUI ⏵"),
    ("G6", [(GPUI_MAIN, "      gHoverTests = over", "      discard over")],
     [(PLAN, PLAN_TAB)],
     "§9.6: the GPUI window shows no hover label on a Test Results control"),
    ("G7", [(GPUI_MAIN, "  gTestsVM.noteTestTab(testId, int(gShell.app.activeSessionId()),\n                       recordingId)",
             "  discard recordingId")],
     [(PLAN, PLAN_OPEN)],
     "§9.2: the GPUI window forgets which tab a test's recording is in"),
    ("D2", [(UI_JS, "    createNewSession(data)\n    data.ipc.send cstring\"CODETRACER::load-recent-trace\",\n      js{traceId: cstring(recordingId)}",
             "    data.openRecordingById(recordingId)")],
     [(DSPEC, None)],
     "§9.5: the desktop loads a test's recording into the edit session (the filed issue)"),
    ("D3", [(UI_JS, "    saveReplayOpenIn(data, topCurrentTab),", "    saveReplayOpenIn(data, topNewTab),")],
     [(DSPEC, None)],
     "§9.3: the desktop's palette command writes the wrong destination"),
    # ---- §9.3: the palette pair and Ctrl+Enter; §9.7: the context menu -----
    ("R10", [(VM, "  vm.hasCommandPolicy = true", "  vm.hasCommandPolicy = false")],
     [(VMT, None), (TBL, TBL_RUN)],
     "§9.3: the palette pair's destination is not held through its dispatch"),
    ("R11", [(VM, "  if vm.hasCommandPolicy:\n    return vm.commandPolicy",
              "  if false:\n    return vm.commandPolicy")],
     [(VMT, None), (TBL, TBL_RUN)],
     "§9.3: the host captures the setting, not the command's destination"),
    ("R12", [(VM, "  let action = vm.recordAndOpenRecording.val\n  if action.isNil:\n    return NoReplayHostText\n  let row = vm.rows.val[i]",
              "  let action = vm.openExistingRecording.val\n  if action.isNil:\n    return NoReplayHostText\n  let row = vm.rows.val[i]")],
     [(VMT, None), (TBL, TBL_RUN)],
     "§9.3: Run opens the existing recording instead of recording"),
    ("R13", [(OMNI, "                            target: runTestCommandTarget(policy))",
              "                            target: replayOpenCommandTarget(policy))")],
     [(PLAN, PLAN_RUN)],
     "§9.3: the omnibox's Tests: Run sets the setting instead of running"),
    ("K4", [(RUNTIME, '    let redirected = operation == "list.activate-redirected"',
             "    let redirected = false")],
     [(TBL, TBL_RUN), (PTY, PTY_TAB)],
     "§9.3: the terminal's Ctrl+Enter opens where Enter does"),
    ("K5", [(CUA, '    BaseRow(chords: "Ctrl+Enter", operation: "list.activate-redirected",',
             '    BaseRow(chords: "Ctrl+Enter", operation: "list.activate",')],
     [(ORACLE, None), (TBL, TBL_RUN)],
     "§9.3: CUA's Ctrl+Enter on a row is a plain open"),
    ("K6", [(RUNTIME, "  let runIn = parseRunTestCommandTarget(action)\n  if runIn.ok:",
             "  let runIn = parseRunTestCommandTarget(action)\n  if false:")],
     [(TBL, TBL_RUN)],
     "§9.3: the terminal's palette pair is not dispatched"),
    ("K7", [(SOURCE, "      s.vm.selectTest(c.path)", "      discard c.path")],
     [(TBL, TBL_RUN)],
     "§9.3: the terminal's palette pair ignores the selected row"),
    ("G8", [(GPUI_MAIN, '      gTestsVM.setRedirectHeld(operation == "list.activate-redirected")',
             "      gTestsVM.setRedirectHeld(false)")],
     [(PLAN, PLAN_RUN)],
     "§9.3: the GPUI window's Ctrl+Enter opens where Enter does"),
    ("G9", [(GPUI_MAIN, "  if gpuiTestsCommand(r, action):\n    return",
             "  if false:\n    return")],
     [(PLAN, PLAN_RUN)],
     "§9.3: the GPUI omnibox's test commands do nothing"),
    ("G10", [(GPUI_MAIN, "    gTestsVM.selectTest(if sel >= 0 and sel < rows.len: rows[sel].testId",
              "    gTestsVM.selectTest(if false: rows[sel].testId")],
     [(PLAN, PLAN_RUN)],
     "§9.3: the GPUI palette pair ignores the selected row"),
    ("G11", [(GPUI_MAIN, '    traceGesture("tests: " & gTestsHost.setReplayOpen(openIn.policy))',
              '    traceGesture("tests: ")')],
     [(PLAN, PLAN_SET)],
     "§9.3: the GPUI omnibox's Open Recordings in … writes no setting"),
    ("D4", [(UI_JS, "  let why = vm.runSelectedTestIn(policy)",
             '  let why = vm.runTestIn("", policy)')],
     [(DSPEC, None)],
     "§9.3: the desktop's palette pair ignores the selected row"),
    ("D5", [(VIEW, "         onclick = proc() = vm.selectTest(row.testId)):",
             "         onclick = proc() = discard row.testId):")],
     [(DSPEC, None)],
     "§9.3: a click on a desktop row selects nothing"),
    ("D6", [(EDITOR, "            self.startEditorTestAt(line)",
             "            self.runTest(self.getLineFunctionName(line + 1), self.name, line, 1)")],
     [(DSPEC, None)],
     "§9.7: the editor's context menu loads the recording into the edit session"),
    ("P1", [(VOCAB, '    children.add viewTable("tests.rows", TestResultsColumns, cells)',
             '    discard cells')],
     [(TBL, TBL_HOST)],
     "the vocabulary's Test Results view lists no test"),
    # ---- the desktop ------------------------------------------------------------
    ("D1", [(NS9, "  if answer.hasCatalog:", "  if false:")],
     [(SPEC, None)],
     "§8.2: the desktop's catalog answer (the shared rule) sends no catalog"),
    # ---- the declared survivor ---------------------------------------------------
    ("S1", [(HOST, "    sleep(20)", "    sleep(25)")],
     [(TBL, TBL_HOST)],
     "behaviour-preserving: the DECLARED SURVIVOR (the stop's poll interval)"),
]

DECLARED_SURVIVORS = {"S1"}

IN_BINARY = {VM, FIT, CATALOG, HOST, TUI_PANE, RUNTIME, SHELL, PROFILE, SOURCE,
             TUI_MAIN, VOCAB, DESKTOP_HOST, SETTING, OMNI, CUA}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {VM, FIT, CATALOG, HOST, GPUI_LEAF, GPUI_MAIN, VOCAB, DESKTOP_HOST,
           SETTING, OMNI, CUA}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = {VM, CATALOG, NS9, DESKTOP_HOST, SETTING, VIEW, UI_JS, OMNI, CUA,
              EDITOR}
  # Subjects compiled into the desktop's bundle.
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC, DSPEC}


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
        f.write("# Control digests for run-plat53-test-results-mutations.py —\n"
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
    return build_with("PLAT53_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT53_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT53_BUILD_DESKTOP", "build-once")


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
    cmd = os.environ.get("PLAT53_DESKTOP_TEST")
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
            backups[rel] = path.with_name(path.name + ".plat53bak")
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
