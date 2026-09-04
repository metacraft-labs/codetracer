## SDK-CONSUMER: BlockTracer.milestones.org M2b's first verification test.
## It is written as a consumer — every import below resolves to
## `codetracer_embed` or to something outside the SDK subtree — because the
## claim being made is about the five panes *as a consumer receives them*,
## and a test that reached into `viewmodel/store/` would be proving it about
## a different package than the one that ships.
##
## test_five_panes_drive_headlessly.nim
##
## M2b verification #1:
##
##   "Each pane's full state and derivations are exercised through
##    MockBackendService with no renderer, including every degraded state as
##    an enum value."
##
## The five panes are `EditorVM`, `CalltraceVM`, `StateVM`, `EventLogVM` and
## `DebugControlsVM` — the panes BlockTracer renders (M2b Goal). Every pane
## beyond those five is upstream's phase 5 and deliberately out of scope.
##
## Three properties are proved here.
##
## 1. **All five construct and drive with no renderer**, over one
##    `MockBackendService`: signals mutate, action procs run, memos
##    recompute. No Electron, no DOM, no display, no `replay-server`, no
##    network.
##
## 2. **Every degraded state is an enum value.** Page-Descriptions.md §14
##    ends: "Every row above is a value of an enum on a ViewModel, not a
##    branch in a view, which is what makes each of them testable without a
##    browser." The suite walks `PaneDegradation` exhaustively — `for d in
##    PaneDegradation` — so a value added to that enum and then rendered by
##    no pane fails here rather than in review.
##
## 3. **The degraded state arrives over the backend seam**, not only from a
##    host-side setter: a `CtReplayStatus` event pushed through
##    `MockBackendService.emitEvent` moves the panes, which is what makes
##    "exercised through MockBackendService" true of the §14 rows and not
##    just of the ordinary ones.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_five_panes_drive_headlessly.nim
##
## The `vm-unit` lane discovers this file by glob (ci/lib/test-lane-files.sh)
## and `CoreViewModelGateTests` (src/ct_test/release_gate.nim) asserts it still
## exists and is not skip-disabled — the glob runs it, the gate keeps it.
##
## `vm-unit`'s backend is C only (`test_lane_backend` in the same file answers
## `js` for `vm-js` and `frontend-js` alone), so the assertions below execute
## on the C backend. The subject still *compiles* under `nim js`, because
## `store/degraded_state.nim` reaches the JS target through
## `replay_data_store` on every file in the `vm-js` lane; what does not run
## there is this file's checks. Front-End-Architecture.md §6 wants Tier 1 on
## both backends, so that is a real gap in the lane, not a property of this
## suite — see BlockTracer.milestones.org's M2b entry.

import std/[json, options, sets, strutils, unittest]

import codetracer_embed

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

type
  Panes = object
    ## The five panes M2b scopes, over one store and one backend.
    ##
    ## Note what is NOT in this object: any reference from one pane to
    ## another. Each `create*VM` takes the store and nothing else, which is
    ## the structural half of the claim the companion suite
    ## (`test_cross_pane_composition_needs_no_bridge.nim`) makes the
    ## behavioural half of.
    store: ReplayDataStore
    mock: MockBackendService
    editor: EditorVM
    calltrace: CalltraceVM
    state: StateVM
    eventLog: EventLogVM
    controls: DebugControlsVM

proc openPanes(): Panes =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  Panes(
    store: store,
    mock: mock,
    editor: createEditorVM(store),
    calltrace: createCalltraceVM(store),
    state: createStateVM(store),
    eventLog: createEventLogVM(store),
    controls: createDebugControlsVM(store),
  )

proc closePanes(p: Panes) =
  p.editor.dispose()
  p.calltrace.dispose()
  p.state.dispose()
  p.eventLog.dispose()
  p.controls.dispose()
  p.store.dispose()

proc snapshotFor(degradation: PaneDegradation): DegradedStateSnapshot =
  ## One snapshot that exhibits `degradation` and nothing more severe.
  ##
  ## Written as a total `case` over the enum rather than a table so that
  ## adding a value to `PaneDegradation` without deciding how it is reached
  ## is a compile error here, not a silently unexercised row.
  result = initDegradedStateSnapshot()
  case degradation
  of pdNone: discard
  of pdPermanentlyUnreplayable:
    result.availability = raUnreplayable
  of pdReplayWindowExpired:
    result.availability = raWindowExpired
  of pdEngineUnavailable:
    result.capability = rcWorkerUnsupported
  of pdDivergenceDetected:
    result.integrity = tiDivergent
  of pdTraceTruncated:
    result.integrity = tiTruncated
  of pdNoVerifiedSource:
    result.sourceAvailability = savUnverified

proc apply(store: ReplayDataStore; snapshot: DegradedStateSnapshot) =
  store.setReplayAvailability(snapshot.availability)
  store.setTraceIntegrity(snapshot.integrity)
  store.setReplayCapability(snapshot.capability)
  store.setSourceAvailability(snapshot.sourceAvailability)

proc paneDegradations(p: Panes): seq[PaneDegradation] =
  @[
    p.editor.degradedState.val,
    p.calltrace.degradedState.val,
    p.state.degradedState.val,
    p.eventLog.degradedState.val,
    p.controls.degradedState.val,
  ]

proc storageWriteRow(index: int; file: string; line: int;
                     rrTicks: uint64): EventLogRow =
  ## A write event, which is the row M2b's second verification clicks.
  ##
  ## `kind` is a free-text label the recorder supplies; the SDK has no
  ## opinion about it and must not — CodeTracer-Embed-SDK.md §3.2's last
  ## row keeps every chain concept one layer up, so "a storage write" is
  ## the consumer's reading of an ordinary event row, not a type here.
  EventLogRow(
    eventId: rrTicks,
    eventIndex: index,
    kindId: 1,
    kind: "Write",
    file: file,
    line: line,
    value: "slot=7 value=1",
    rrTicks: rrTicks,
    maxRRTicks: 4096'u64,
  )

# ---------------------------------------------------------------------------
# 1. All five panes construct and drive headlessly
# ---------------------------------------------------------------------------

suite "M2b — the five panes drive headlessly (MockBackendService, no renderer)":

  test "all five construct over one store and one mock backend":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      check p.store.storeId > 0
      check not p.editor.isNil
      check not p.calltrace.isNil
      check not p.state.isNil
      check not p.eventLog.isNil
      check not p.controls.isNil
      # One store behind all five. That is the composition model: the
      # panes share data by sharing signals, not by holding each other.
      check p.editor.store.storeId == p.store.storeId
      check p.calltrace.store.storeId == p.store.storeId
      check p.state.store.storeId == p.store.storeId
      check p.eventLog.store.storeId == p.store.storeId
      check p.controls.store.storeId == p.store.storeId
      # Whatever reached the backend seam was a pane's own auto-load
      # effect, and every command went to the replay engine. Nothing
      # reached a renderer, because there is not one in this process.
      for received in p.mock.receivedCommands:
        check received.command.len > 0
      p.closePanes()
      dispose()

  test "EditorVM: signals mutate, action procs run, memos follow the store":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      # Signals + actions.
      p.editor.switchTab(3)
      check p.editor.activeTabIndex.val == 3
      p.editor.switchTab(-5)
      check p.editor.activeTabIndex.val == 0
      p.editor.setCursor(42, 7)
      check p.editor.cursorLine.val == 42
      check p.editor.cursorColumn.val == 7
      p.editor.setCursor(0, 0)
      check p.editor.cursorLine.val == 1
      check p.editor.cursorColumn.val == 1
      let overlayBefore = p.editor.showFlowOverlay.val
      p.editor.toggleFlowOverlay()
      check p.editor.showFlowOverlay.val != overlayBefore
      let gutterBefore = p.editor.showBreakpointGutter.val
      p.editor.toggleBreakpointGutter()
      check p.editor.showBreakpointGutter.val != gutterBefore
      # Memos.
      check p.editor.activeFileName.val == ""
      p.store.updateDebuggerPosition(11'u64, file = "contract.nr", line = 3,
                                     sourceGeneration = 2, sourceDigest = "d1")
      check p.editor.activeFileName.val == "contract.nr"
      check p.editor.activeSourceGeneration.val == 2
      check p.editor.activeSourceDigest.val == "d1"
      check p.editor.executionCursorKind.val == "replay"
      p.store.setSessionMode(liveMcr)
      check p.editor.executionCursorKind.val == "live-mcr"
      p.closePanes()
      dispose()

  test "CalltraceVM: viewport signals drive the visibleLines memo":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.calltrace.setViewportHeight(3)
      p.calltrace.scroll(-4)
      check p.calltrace.scrollPosition.val == 0'i64
      check p.calltrace.visibleLines.val.len == 0
      p.store.updateCalltraceSection(@[
        makeCallLine("main", 0, 0'u64),
        makeCallLine("read", 1, 1'u64),
        makeCallLine("write", 1, 2'u64),
        makeCallLine("commit", 1, 3'u64),
      ], startIndex = 0'i64, totalCount = 4'u64)
      check p.calltrace.visibleLines.val.len == 3
      check p.calltrace.visibleLines.val[0].name == "main"
      check p.calltrace.hasMoreAbove.val == false
      check p.calltrace.hasMoreBelow.val == true
      p.calltrace.scroll(1)
      check p.calltrace.hasMoreAbove.val == true
      p.calltrace.setSearchQuery("wri")
      check p.calltrace.highlightedMatches.val == @[2'i64]
      p.closePanes()
      dispose()

  test "StateVM: tabs, watches and expansion drive currentVariables":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      check p.state.activeTab.val == stLocals
      p.store.updateLocals(@[makeVariable("x", "1", "int")])
      p.store.locals.globals.val = @[makeVariable("g", "9", "int")]
      check p.state.currentVariables.val.len == 1
      check p.state.currentVariables.val[0].name == "x"
      p.state.selectTab(stGlobals)
      check p.state.currentVariables.val[0].name == "g"
      p.state.selectTab(stWatches)
      check p.state.currentVariables.val.len == 0
      # THE WATCHES TAB SHOWS THE WATCH ANSWERS.
      #
      # This arm of `currentVariables` used to be a literal
      # `newSeq[store_types.Variable]()`, so it could show nothing
      # whatever the backend answered — and the check above, on its own,
      # passed against that stub for exactly the same reason it passes
      # now. An assertion that only ever observes an EMPTY tab cannot
      # tell a working tab from a hard-coded one, so the tab is also
      # asserted with something in it.
      p.store.updateWatches(@[
        makeVariable("asteroid_masses[1]", "2000", "Field"),
        makeVariable("x + 1", "cannot evaluate `x + 1`: `+` would have to be computed", "watch error"),
      ])
      # `require`, not `check`: against the pre-fix stub this arm answers
      # an EMPTY seq, and the row reads below would then die with an
      # `IndexDefect` whose message says only "the container is empty" —
      # naming the symptom and not the defect. Aborting here makes the
      # failure report the sentence that is actually false.
      require p.state.currentVariables.val.len == 2 # the Watches tab shows the watch answers
      check p.state.currentVariables.val[0].name == "asteroid_masses[1]"
      check p.state.currentVariables.val[0].value == "2000"
      # A REFUSED watch is a row carrying its reason, not an absence.
      check p.state.currentVariables.val[1].name == "x + 1"
      check p.state.currentVariables.val[1].value.contains("cannot evaluate")
      # And the watches must not have leaked into the Locals tab.
      p.state.selectTab(stLocals)
      check p.state.currentVariables.val.len == 1
      check p.state.currentVariables.val[0].name == "x"
      p.state.selectTab(stWatches)
      p.state.addWatch("x + 1")
      p.state.addWatch("x + 1")
      check p.state.watchExpressions.val == @["x + 1"]
      p.state.removeWatch("x + 1")
      check p.state.watchExpressions.val.len == 0
      p.state.toggleExpand("x.field")
      check "x.field" in p.state.expandedPaths.val
      p.state.selectPath("x.field")
      check p.state.selectedPath.val == "x.field"
      # The "no source for this position" decision is a memo, not a class
      # name computed in a view — see `hasCodeState`'s docstring.
      check p.state.hasCodeState.val == false
      p.store.updateCodeStateLine(3, "let x = 1")
      check p.state.hasCodeState.val == true
      p.closePanes()
      dispose()

  test "EventLogVM: paging, sorting and filtering are pure derivations":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.eventLog.setPageSize(2)
      p.eventLog.appendLiveDebuggerStop(storageWriteRow(0, "a.nr", 1, 10'u64))
      p.eventLog.appendLiveDebuggerStop(storageWriteRow(1, "a.nr", 2, 11'u64))
      p.eventLog.appendLiveDebuggerStop(storageWriteRow(2, "b.nr", 3, 12'u64))
      check p.eventLog.totalEventCount.val == 3
      check p.eventLog.totalPages.val == 2
      p.eventLog.nextPage()
      check p.eventLog.currentPage.val == 1
      p.eventLog.nextPage()
      check p.eventLog.currentPage.val == 1
      p.eventLog.prevPage()
      check p.eventLog.currentPage.val == 0
      p.eventLog.sort(2)
      check p.eventLog.sortColumn.val == 2
      check p.eventLog.sortAscending.val == true
      p.eventLog.sort(2)
      check p.eventLog.sortAscending.val == false
      p.eventLog.selectRow(some(1))
      check p.eventLog.selectedRow.val == some(1)
      check p.eventLog.isLoading.val == false
      p.closePanes()
      dispose()

  test "DebugControlsVM: derived affordances and the step actions":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      check p.controls.statusText.val == "Idle"
      check p.controls.canStepForward.val == true
      check p.controls.canContinue.val == true
      check p.controls.isRunning.val == false
      # A completed replay is time-travellable regardless of whether the
      # DAP initialize capability arrived.
      p.store.setSessionMode(completedReplay)
      check p.controls.canStepBackward.val == true
      check p.controls.canReverseContinue.val == true
      p.mock.clearReceivedCommands()
      p.controls.stepForward()
      check p.mock.findCommand("next").isSome
      # `requestStep` leaves the debugger `dsStepping` until a real backend
      # reports a completed move, so the derivations follow it there.
      check p.controls.isRunning.val == true
      check p.controls.statusText.val == "Stepping..."
      check p.controls.canStepForward.val == false
      # Return to rest the way a completed move would, and step the other
      # way. (The store's own `debugger` signal is the seam a real backend
      # writes through; there is no renderer in this process to do it.)
      p.store.debugger.val = DebuggerState(status: dsIdle)
      p.mock.clearReceivedCommands()
      p.controls.stepBackward()
      check p.mock.findCommand("stepBack").isSome
      p.closePanes()
      dispose()

# ---------------------------------------------------------------------------
# 2. Every degraded state is an enum value (Page-Descriptions.md §14)
# ---------------------------------------------------------------------------

suite "M2b — every degraded state is an enum value (§14)":

  test "every PaneDegradation value is reachable on at least one pane":
    # The exhaustive half. `for d in PaneDegradation` means a seventh row
    # added to the catalogue and wired to nobody fails here.
    createRoot proc(dispose: proc()) =
      for degradation in PaneDegradation:
        let p = openPanes()
        p.store.apply(snapshotFor(degradation))
        check degradation in p.paneDegradations()
        p.closePanes()
      dispose()

  test "the per-pane sensitivity sets cover the whole catalogue exactly once over":
    var union: set[PaneDegradation] = {}
    for s in AllPaneDegradations:
      union = union + s
    for degradation in PaneDegradation:
      if degradation == pdNone:
        check degradation notin union
      else:
        check degradation in union

  test "a pane not sensitive to a row reports pdNone rather than a weaker value":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      # §14's truncation banner belongs to the debugger's chrome and to the
      # three data panes. The editor is showing a source line from *inside*
      # the recording, which truncation does not make wrong — so it must
      # not raise a banner it has nothing to say about.
      p.store.setTraceIntegrity(tiTruncated)
      check p.editor.degradedState.val == pdNone
      check p.calltrace.degradedState.val == pdTraceTruncated
      check p.eventLog.degradedState.val == pdTraceTruncated
      check p.state.degradedState.val == pdTraceTruncated
      check p.controls.degradedState.val == pdTraceTruncated
      # And the mirror: an unverified source is the editor's row alone.
      p.store.setTraceIntegrity(tiComplete)
      p.store.setSourceAvailability(savUnverified)
      check p.editor.degradedState.val == pdNoVerifiedSource
      check p.calltrace.degradedState.val == pdNone
      check p.eventLog.degradedState.val == pdNone
      check p.state.degradedState.val == pdNone
      check p.controls.degradedState.val == pdNone
      p.closePanes()
      dispose()

  test "'not now' and 'not ever' are different values (§14.1a)":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.store.setReplayAvailability(raWindowExpired)
      check p.controls.degradedState.val == pdReplayWindowExpired
      p.store.setReplayAvailability(raUnreplayable)
      check p.controls.degradedState.val == pdPermanentlyUnreplayable
      # §14.1a: "Presenting either as the other is the failure this table
      # exists to prevent."
      check pdReplayWindowExpired != pdPermanentlyUnreplayable
      # Both are still availability values distinct from the two live ones.
      p.store.setReplayAvailability(raWindowedLive)
      check p.controls.degradedState.val == pdNone
      p.closePanes()
      dispose()

  test "precedence is fixed, and the more severe row wins":
    let snapshot = DegradedStateSnapshot(
      availability: raUnreplayable,
      integrity: tiDivergent,
      capability: rcInsufficientMemory,
      sourceAvailability: savAbsent,
    )
    check resolveDegradation(snapshot, DebugControlsPaneDegradations) ==
      pdPermanentlyUnreplayable
    check resolveDegradation(snapshot, EditorPaneDegradations) ==
      pdPermanentlyUnreplayable
    # The declared order is the order applied.
    check DegradationPrecedence[0] == pdPermanentlyUnreplayable
    check DegradationPrecedence[^1] == pdNoVerifiedSource
    for i in 0 ..< DegradationPrecedence.len:
      var only = initDegradedStateSnapshot()
      only = snapshotFor(DegradationPrecedence[i])
      check resolveDegradation(only, {DegradationPrecedence[i]}) ==
        DegradationPrecedence[i]

  test "a subordinate row stays readable under a row that outranks it":
    # §14's divergence banner is non-dismissible and its truncation banner
    # offers a deeper profile; a debugger that is both must be able to say
    # both, which is why DebugControlsVM exposes them beside the resolved
    # value rather than only through it.
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.store.setTraceIntegrity(tiDivergent)
      p.store.setReplayCapability(rcWasmCompilationFailed)
      check p.controls.degradedState.val == pdEngineUnavailable
      check p.controls.divergenceDetected.val == true
      check p.controls.traceTruncated.val == false
      p.closePanes()
      dispose()

  test "the §14.2 capability ladder is a value, not a chain of ifs":
    # One rung per failure, and each failure keeps its own cause: §14.2
    # says "none should surface as a generic error".
    check capabilityRung(rcCapable) == crFullDebugger
    check capabilityRung(rcRangeRequestsUnsupported) == crTraceDownload
    check capabilityRung(rcWasmCompilationFailed) == crOpenInDesktop
    check capabilityRung(rcWorkerUnsupported) == crOpenInDesktop
    check capabilityRung(rcInsufficientMemory) == crStaticSummary
    var rungs: HashSet[CapabilityRung]
    for capability in ReplayCapability:
      rungs.incl(capabilityRung(capability))
    # Every rung of the ladder is reachable — a rung nothing falls to is a
    # fallback that was written and never offered.
    check rungs.len == 4

  test "an unusable replay disables every step affordance":
    # §14: a terminal state is "never a retry that cannot succeed", which
    # is a statement about buttons.
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.store.setSessionMode(completedReplay)
      check p.controls.replayUsable.val == true
      check p.controls.canStepForward.val == true
      check p.controls.canStepBackward.val == true
      check p.controls.canContinue.val == true
      check p.controls.canReverseContinue.val == true
      for availability in [raWindowExpired, raNeverGenerated, raUnreplayable]:
        p.store.setReplayAvailability(availability)
        check p.controls.replayUsable.val == false
        check p.controls.canStepForward.val == false
        check p.controls.canStepBackward.val == false
        check p.controls.canContinue.val == false
        check p.controls.canReverseContinue.val == false
      p.store.setReplayAvailability(raRetained)
      for capability in [rcWasmCompilationFailed, rcInsufficientMemory,
                         rcRangeRequestsUnsupported, rcWorkerUnsupported]:
        p.store.setReplayCapability(capability)
        check p.controls.replayUsable.val == false
        check p.controls.canStepForward.val == false
      p.store.setReplayCapability(rcCapable)
      check p.controls.canStepForward.val == true
      p.closePanes()
      dispose()

  test "a disabled step affordance issues no backend command":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.store.setReplayAvailability(raUnreplayable)
      p.mock.clearReceivedCommands()
      p.controls.stepForward()
      p.controls.stepBackward()
      p.controls.stepIn()
      p.controls.stepOut()
      p.controls.continueExecution()
      p.controls.reverseContinue()
      check p.mock.receivedCommands.len == 0
      p.closePanes()
      dispose()

  test "the editor's instruction-level fallback follows source availability":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      check p.editor.sourceAvailability.val == savVerified
      check p.editor.instructionLevelStepping.val == false
      p.store.setSourceAvailability(savUnverified)
      check p.editor.degradedState.val == pdNoVerifiedSource
      check p.editor.instructionLevelStepping.val == true
      # `savAbsent` is a distinct value because there is nothing for a
      # supply-sources action to attach to — the row's canonical treatment
      # differs even though both fall to instruction-level stepping.
      p.store.setSourceAvailability(savAbsent)
      check p.editor.sourceAvailability.val == savAbsent
      check p.editor.instructionLevelStepping.val == true
      check p.editor.degradedState.val == pdNoVerifiedSource
      p.closePanes()
      dispose()

# ---------------------------------------------------------------------------
# 3. The degraded state arrives over the backend seam
# ---------------------------------------------------------------------------

suite "M2b — degraded state through MockBackendService":

  test "a CtReplayStatus event moves every pane":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.mock.emitEvent(%*{
        "kind": "CtReplayStatus",
        "availability": "window-expired",
        "integrity": "truncated",
        "capability": "insufficient-memory",
        "sourceAvailability": "unverified",
      })
      check p.controls.degradedState.val == pdReplayWindowExpired
      check p.editor.degradedState.val == pdReplayWindowExpired
      check p.calltrace.degradedState.val == pdReplayWindowExpired
      check p.state.degradedState.val == pdReplayWindowExpired
      check p.eventLog.degradedState.val == pdReplayWindowExpired
      check p.controls.capabilityRung.val == crStaticSummary
      check p.controls.traceTruncated.val == true
      check p.editor.instructionLevelStepping.val == true
      p.closePanes()
      dispose()

  test "the RealBackendService envelope shape is accepted too":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.mock.emitEvent(%*{
        "kind": "CtReplayStatus",
        "data": {"integrity": "divergent"},
      })
      check p.controls.divergenceDetected.val == true
      check p.controls.degradedState.val == pdDivergenceDetected
      p.closePanes()
      dispose()

  test "a partial event leaves the axes it does not mention alone":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.store.setTraceIntegrity(tiTruncated)
      p.mock.emitEvent(%*{
        "kind": "CtReplayStatus",
        "sourceAvailability": "unverified",
      })
      check p.controls.traceTruncated.val == true
      check p.editor.instructionLevelStepping.val == true
      p.closePanes()
      dispose()

  test "an unrecognised spelling does not report a healthy replay":
    # The failure this guards against: a host that starts speaking a
    # spelling this build does not know must not be read as "retained,
    # complete, capable, verified".
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.store.setReplayAvailability(raUnreplayable)
      p.mock.emitEvent(%*{
        "kind": "CtReplayStatus",
        "availability": "quantum-superposition",
      })
      check p.controls.degradedState.val == pdPermanentlyUnreplayable
      p.closePanes()
      dispose()

  test "an unrelated event kind changes nothing":
    createRoot proc(dispose: proc()) =
      let p = openPanes()
      p.mock.emitEvent(%*{"kind": "CtSomethingElse", "availability": "unreplayable"})
      check p.controls.degradedState.val == pdNone
      p.closePanes()
      dispose()
