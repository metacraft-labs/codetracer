## PLAT-41 — thirteen panes on both front-ends, from RUNS, and the eight newly
## expressed ones read back off the native window's screen.
##
## Run (the `tui` lane's flags):
##   nim c -r --path:src/frontend/viewmodel <tui lane flags> \
##     src/frontend/tui/tests/test_plat41_parity.nim
##
## `src/tests/visual/plat41-readings.json` is written by `plat41_record.nim`
## from two capture lanes at one stop of the `calc` recording:
##
##   * the NATIVE column — the shipped `codetracer-gpui`'s own `--plan-out` of
##     a window holding all thirteen panes: each leaf's `data-ct-state` and the
##     text it drew (tier: RUN);
##   * the eight panes PLAT-41 expressed, READ OFF THAT WINDOW'S PIXELS by
##     PLAT-39's reader, with the default layout and a blank compositor as the
##     controls (tier: CAPTURE);
##   * the DESKTOP column — the desktop's DOM at the same stop, pane by pane
##     (tier: RUN). PLAT-23 could take it only at SOURCE level.
##
## What is asserted:
##
##   1. THE PARITY TABLE: thirteen rows, both columns, every row's tier, and
##      PLAT-23's G3 — no pane where the desktop draws DATA and the native
##      window does not. Measured, the table had one such row when this suite
##      was written (`fileTree`, which PLAT-41 had parked as an accepted
##      exception); it is repaired, not filed.
##   2. PLAT-39's READER over each new pane: `srRead` where the run drew data,
##      `srEmpty` — warranted by the pane's OWN message — where the true answer
##      of an unexercised session is empty (search, scratchpad, shell, build),
##      and never `srUnreadable`; the blank control unreadable everywhere and
##      the default layout locating none of the seven it does not place.
##   3. DIFF-10: each pane both front-ends draw with data compares as one
##      domain value — the transport controls, the timeline's position and
##      extent, the recording's file tree — and the flow's rows and the four
##      earlier panes are pinned to the readings DIFF-8 and DIFF-9 take.
##   4. The report→data transition, per new pane, on a live session: a fresh
##      store answers a report, the shipped producers turn it to data, and the
##      data is the recording's (its files, its flow window, its extent).
##   5. The constants the reader carries because it imports no product module
##      (`TransportLabels`, `QuietMessages`) are the product's own.
##
## No mocks: a real recording and `replay-server`, the real session, views and
## binaries; the capture records are measurements of the shipped front-ends.

import std/[json, os, sequtils, sets, strutils, tables, unittest]

import codetracer_embed
import headless_session
import store/replay_data_store
import backend/stdio_backend   # `toBackendService` over the live transport
import viewmodels/[debug_controls_vm, filesystem_vm, flow_vm, timeline_vm,
                   search_vm, scratchpad_vm, shell_vm]
import headless_app/layout_model
import headless_app/headless_app
import ../../view_vocabulary/pane_views
import ../../../common/value_presentation
import ../host/native_host
import ../../../tests/visual/screen_oracle/pane_grammar
import ./fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let rec = parseJson(readFile(repo / "src/tests/visual/plat41-readings.json"))

const NewPanes = [paneDebugControls, paneFlow, paneTimeline, paneSearch,
                  paneScratchpad, paneShell, paneFileTree, paneBuildOutput]
  ## The eight PLAT-41 owed — every `PaneKind` outside the five PLAT-40 and
  ## the editor already drew — derived below from the sets rather than
  ## trusted.

proc gpuiState(pane: PaneKind): string =
  rec["gpuiCensus"]{$pane}{"state"}.getStr("<absent>")

proc gpuiText(pane: PaneKind): seq[string] =
  for t in rec["gpuiCensus"]{$pane}{"text"}.getElems: result.add t.getStr

proc electronRow(pane: PaneKind): JsonNode =
  for r in rec["electron"]["rows"]:
    if r["pane"].getStr == $pane: return r
  nil

proc gpuiDrawsData(pane: PaneKind): bool =
  gpuiState(pane) == "live"

# ===========================================================================
suite "PLAT-41 1 — the parity table, both columns from runs":
# ===========================================================================

  test "the eight are exactly the panes outside PLAT-40's four and the editor":
    var derived = initHashSet[PaneKind]()
    for p in PaneKind:
      if p notin {paneEditor, paneCalltrace, paneState, paneEventLog,
                  panePointList}:
        derived.incl p
    ck derived == NewPanes.toHashSet
    ck derived.len == 8

  test "thirteen rows in each column, one per PaneKind, both directions":
    var native, desktop = initHashSet[string]()
    for k, _ in rec["gpuiCensus"]: native.incl k
    for r in rec["electron"]["rows"]: desktop.incl r["pane"].getStr
    var enumNames = initHashSet[string]()
    for p in PaneKind: enumNames.incl $p
    ck native == enumNames
    ck desktop == enumNames
    ck native.len == 13
    ck desktop.len == 13

  test "every native row's state is its category's: data, a named exception, or the editor":
    for p in PaneKind:
      let st = gpuiState(p)
      checkpoint($p & ": " & st & " " & $gpuiText(p))
      if p in PaneAcceptedExceptions:
        ck st == "pane-report"
        ck gpuiText(p).anyIt(it.contains("edit-mode view"))
      else:
        ck st in ["live", "pane-report"]

  test "G3 — no pane where the desktop draws data and the native window does not":
    var regressions: seq[string] = @[]
    for p in PaneKind:
      let e = electronRow(p)
      checkpoint($p & ": desktop " & e["state"].getStr & " (" &
                 e["detail"].getStr & "), native " & gpuiState(p))
      if e["state"].getStr == "data" and not gpuiDrawsData(p):
        regressions.add $p
    checkpoint("regressions: " & $regressions)
    ck regressions.len == 0

  test "the native window draws data in every pane the recording feeds at this stop":
    # The panes whose data a plain stop provides; the four quiet ones are
    # asserted as quiet below, by their own messages.
    for p in [paneEditor, paneCalltrace, paneState, paneEventLog,
              paneDebugControls, paneFlow, paneTimeline, paneFileTree]:
      checkpoint($p & ": " & gpuiState(p))
      ck gpuiDrawsData(p)

# ===========================================================================
suite "PLAT-41 2 — PLAT-39's reader over each new pane":
# ===========================================================================

  let px = rec["gpui"]["panes"]

  test "the four fed panes read, off the screen":
    for pane in ["debugControls", "flow", "timeline", "fileTree"]:
      checkpoint(pane & ": " & $px[pane])
      ck px[pane]["kind"].getStr == "read"
      ck px[pane]["value"].len > 0

  test "the four quiet panes read EMPTY, by their own message, never unreadable":
    for pane in ["search", "scratchpad", "shell", "buildOutput"]:
      checkpoint(pane & ": " & $px[pane])
      ck px[pane]["kind"].getStr == "empty"

  test "the reading and the run agree pane by pane: read where the run drew data":
    for p in NewPanes:
      let reading = px[$p]["kind"].getStr
      checkpoint($p & ": reading " & reading & ", run " & gpuiState(p))
      ck (reading == "read") == gpuiDrawsData(p)

  test "the controls say no":
    for pane, r in rec["gpui"]["blank"]:
      if pane in ["width", "height", "located"]: continue
      ck r["kind"].getStr == "unreadable"
    var located = initHashSet[string]()
    for p in rec["gpui"]["default"]["located"]: located.incl p.getStr
    for p in NewPanes:
      if p != paneDebugControls:
        ck $p notin located

# ===========================================================================
suite "PLAT-41 3 — DIFF-10: the panes both front-ends draw, as one domain value":
# ===========================================================================

  let px = rec["gpui"]["panes"]
  let desk = rec["electron"]

  test "the transport controls — the same nine actions":
    var native, desktop: seq[string]
    for a in px["debugControls"]["value"]: native.add a.getStr
    for a in desk["transport"]["actions"]: desktop.add a.getStr
    checkpoint("native " & $native & " | desktop " & $desktop)
    ck native.toHashSet == desktop.toHashSet
    ck native.len == TransportActions.len

  test "the timeline — the same position and the same extent":
    let n = px["timeline"]["value"]
    let d = desk["timeline"]
    checkpoint("native " & $n & " | desktop " & $d)
    ck n["currentTick"].getInt == d["currentTick"].getInt
    ck n["lastTick"].getInt == d["lastTick"].getInt
    ck n["lastTick"].getInt > 0

  test "the file tree — the recording's own sources, entry for entry":
    var native, desktop: seq[string]
    for e in px["fileTree"]["value"]: native.add e.getStr
    for e in desk["fileTree"]["entries"]: desktop.add e.getStr
    checkpoint("native " & $native & " | desktop " & $desktop)
    # The desktop names its root folder group too, as the native tree does.
    ck native.len > 0
    for entry in desktop:
      ck entry in native

  test "the flow — the window's steps, and the expressions the desktop shows inline":
    # The native pane's rows read off the screen are its LOCATIONS (the pane
    # clips the expression column at its width); the names are compared at
    # the run tier, off the shipped binary's plan, against the desktop's
    # inline value chips.
    ck px["flow"]["value"].len >= 10
    let nativeNames = gpuiText(paneFlow).toHashSet
    var desktopNames = initHashSet[string]()
    for n in desk["flowNames"]: desktopNames.incl n.getStr.strip(chars = {':', ' '})
    checkpoint("desktop names " & $desktopNames)
    ck desktopNames.len > 0
    for n in desktopNames:
      ck n in nativeNames

  test "the four earlier panes are compared where DIFF-8 and DIFF-9 compare them":
    let p39 = parseJson(readFile(repo / "src/tests/visual/plat39-readings.json"))
    let p40 = parseJson(readFile(repo / "src/tests/visual/plat40-readings.json"))
    for s in ["stepped-editor", "advanced-state"]:
      ck p39["gpui"][s]["programState"]["kind"].getStr == "read"
      ck p39["gpui"][s]["eventLog"]["kind"].getStr == "read"
      ck p39["gpui"][s]["editor"]["highlightedLine"].getInt ==
         p39["electron"][s]["editor"]["highlightedLine"].getInt
    ck p40["gpui"]["panes"]["calltrace"]["kind"].getStr == "read"
    ck p40["electron"]["panes"]["calltrace"]["kind"].getStr == "read"

  test "the quiet panes are quiet on BOTH front-ends at this stop":
    for p in [paneSearch, paneScratchpad, paneShell, paneBuildOutput]:
      checkpoint($p & ": desktop " & electronRow(p)["state"].getStr)
      ck electronRow(p)["state"].getStr != "data"
      ck not gpuiDrawsData(p)

# ===========================================================================
suite "PLAT-41 4 — report to data, per new pane, on a live session":
# ===========================================================================

  let calc = resolveFixture("calc")
  doAssert calc.outcome != foMissingPrereq,
    missingPrereqMessage(calc.spec, calc.detail)
  let s = openLocalTrace(calc.tracePath)
  let fresh = createReplayDataStore(s.backend.toBackendService())

  test "the file tree: a report until the producer runs, then the recording's files":
    ck paneView(paneFileTree, ViewModel(createFilesystemVM(fresh)),
                GpuiPanelBudget, "tui").report.len > 0
    ck paneView(paneFileTree, ViewModel(s.session.fileTreeVM),
                GpuiPanelBudget, "tui").report.len > 0
    let loaded = s.loadRecordingPanes()
    ck loaded.files
    let pv = paneView(paneFileTree, ViewModel(s.session.fileTreeVM),
                      GpuiPanelBudget, "tui")
    ck pv.report.len == 0
    ck s.session.fileTreeVM.rootEntry.val.children.len == 1

  test "a replay slot hands the file tree to a front-end, and still no build":
    # The door every native front-end asks through (`paneViewModel`), which
    # answered nil for the file tree until PLAT-41's correction.
    let app = newHeadlessApp()
    let slot = app.openSession(s.backend.toBackendService(), title = "calc",
                               adopt = s.sdk)
    ck slot.paneViewModel(paneFileTree) == ViewModel(s.session.fileTreeVM)
    ck slot.paneIsLive(paneFileTree)
    ck slot.paneViewModel(paneBuildOutput).isNil
    ck not slot.paneIsLive(paneBuildOutput)

  test "the timeline: no extent on a fresh store, the recording's once the log is read":
    ck createTimelineVM(fresh).markers.val.len == 0
    let marks = s.session.timelineVM.markers.val
    checkpoint($marks)
    ck marks.len == 2
    ck marks[1] == s.session.store.eventLog.maxRRTicks.val
    ck marks[1] > 0'u64

  test "the flow: no steps on a fresh store, the window's steps once it loads":
    ck paneView(paneFlow, ViewModel(createFlowVM(fresh)), GpuiPanelBudget,
                "tui").report.len > 0
    # The flow window is requested by `FlowVM`'s own effect when the debugger
    # STOPS somewhere; the scenario's stop is three steps in, as both capture
    # lanes drive it.
    for _ in 0 ..< rec["scenario"]["nextSteps"].getInt:
      s.stepForward()
      discard s.drainEvents()
    let steps = s.session.flowVM.steps.val
    checkpoint($steps.len & " step row(s)")
    ck steps.len > 0
    ck steps.allIt(it.location.startsWith("main.py:"))
    ck paneView(paneFlow, ViewModel(s.session.flowVM), GpuiPanelBudget,
                "tui").report.len == 0

  test "the debug controls: nine actions, their availability the ViewModel's":
    let pv = paneView(paneDebugControls, ViewModel(s.session.debugControlsVM),
                      GpuiPanelBudget, "tui")
    var labels: seq[string] = @[]
    for c in pv.root.children:
      if c.kind == pkButton: labels.add c.label
    ck labels == TransportActions.mapIt(it[1])
    ck pv.root.expanded

  test "each quiet message is the pane's own report, word for word":
    # The reader carries these because it imports no product module; each is
    # compared with what the pane REALLY says over an unexercised ViewModel.
    let drawn = @[
      paneView(paneSearch, ViewModel(createSearchVM(fresh)), GpuiPanelBudget,
               "tui").report,
      paneView(paneScratchpad, ViewModel(createScratchpadVM(fresh)),
               GpuiPanelBudget, "tui").report,
      paneView(paneShell, ViewModel(createShellVM(fresh)), GpuiPanelBudget,
               "tui").report,
      paneView(paneBuildOutput, nil, GpuiPanelBudget, "tui").root.text]
    checkpoint($drawn)
    ck drawn == @QuietMessages

  s.close()

# ===========================================================================
suite "PLAT-41 5 — the reader's constants are the product's own":
# ===========================================================================

  test "TransportLabels is TransportActions' labels, in order":
    ck @TransportLabels == TransportActions.mapIt(it[1])

  test "the desktop toolbar has a button for every transport action":
    let view = readFile(repo / "src/frontend/viewmodel/views/isonim_debug_controls_view.nim")
    for (id, _) in TransportActions:
      checkpoint(id)
      ck ("id = \"" & id & "-image\"") in view

  test "the desktop census spec carries the same table":
    let spec = readFile(repo / "src/tests/gui/tests/visual/plat41-parity-capture.spec.ts")
    for (id, label) in TransportActions:
      ck ("[\"" & id & "\", \"" & label & "\"]") in spec

suite "PLAT-41 parity — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
