## test_value_origin_jump.nim — CTUI-10, Tier 1, ON A REAL TRACE.
##
## ## THE ASSERTION THIS MILESTONE EXISTS FOR
##
## CTUI-10: *"on `noir_space_ship`: selects a variable with a known non-trivial
## provenance, presses `o`, and asserts the debugger lands on the tick
## `OriginChainVM` reports as the origin, with source, stack and variables all
## consistent at the destination. Asserts `O` returns. This is the campaign's
## headline feature and it gets an assertion on the DESTINATION STATE, not
## merely on the tick changing."*
##
## ## FIRST: THE ORIGIN DATA IS REAL. HERE IS HOW THAT WAS ESTABLISHED
##
## Four ViewModel fields in this layer have turned out to be filled by nothing —
## `PointListVM.points` (CTUI-5), `store.locals.globals` (CTUI-7),
## `TimelineVM.markers` and `EventLogVM.eventRows` (CTUI-8). So the first thing
## this suite does is prove `OriginChainVM` is not a fifth, and it proves it
## three ways rather than by finding one non-empty field:
##
##   1. **The wire answers.** `ct/originChain` is dispatched by
##      `dap_server.rs` into `Handler::origin_chain`, and the response is
##      accompanied by a `ct/updated-origin-chain` event carrying the whole
##      chain. `applyOriginEvents` counts the events it applied and the count is
##      asserted to be EXACTLY ONE per query — so "the answer arrived" is a
##      number, not an absence of an error.
##   2. **The chain has an interior.** Every local at the chosen stop is
##      queried and its chain echoed. The suite asserts that at least one has a
##      hop the classifier NAMED (`kind != okUnknown`) at a tick strictly
##      earlier than the question, and it asserts the count of such variables —
##      so a corpus that stopped answering would redden rather than silently
##      select nothing.
##   3. **The destination is the engine's own.** Seeking to the hop's
##      `location.rrTicks` puts the engine at exactly `location.path` and
##      `location.line`, and `stackTrace` at the destination agrees. Three
##      independent surfaces on one coordinate.
##
## ## ONE MEASURED DISAGREEMENT INSIDE THE ENGINE'S ANSWER
##
## An `OriginHop` carries BOTH `sourceText` (the statement the classifier
## matched) and `location.line` (the line of the recorded step it stopped on),
## and on this recording they are two different lines: `sourceText` is
## `remaining_shield += regeneration;` (line 12 of `shield.nr`) while
## `location.line` is 14 (`status_report(…)`).
##
## The cause is in `db.rs` and it is an ENGINE DEFECT rather than a tie: the
## origin walk's second pass finds the producing line by stepping back one
## recorded step (for recorders that snapshot variables at line entry, which
## Noir's is), assigns only `line_text`, and discards the step it found as
## `_prev_step`. So `location` keeps naming the LATER step and `o` lands one
## recorded step after the write. See `app/origin_binding.nim`'s header.
##
## Asserted here as an inequality, with both read back off disk, so the day
## `db.rs` keeps `_prev_step` this suite says so instead of quietly navigating
## somewhere new. This front-end navigates by `location` because it is the only
## one of the two that names a tick.
##
## ## THE PENDING STATE IS ASSERTED, WHICH IS CTUI-10's NAMED RISK MITIGATION
##
## *"the query is asynchronous with a visible pending state, and the test
## asserts the pending state appears — an optimization that hides a hang behind
## a frozen screen is worse than the wait."* So the first `o` is asserted to
## leave `originQueryState == oqPending`, `OriginChainVM.loading == true` and
## the notification reading `OriginPendingText`, BEFORE the event is pumped —
## and
## the same three are asserted to have flipped after.
##
## ## AND IT IS THE PRODUCT'S OWN DISPATCH
##
## Every action here goes through `app/commands/interpreter.dispatchAction` —
## the same proc a keybinding reaches — and every `:` line through `runCommand`.
## Nothing in this file calls a `DebugControlsVM` action proc, or
## `TimelineVM.seek`; `app/tests/test_gdb_command_surface.nim`'s structural
## walk is what keeps that true for the whole tree.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under
## `src/frontend/tui/app/` and fails on an import resolving to
## `headless_session`. This suite's subject is a real `HeadlessDebugSession`
## over a real `replay-server`. The `tui` lane globs `tests/test_*.nim` and
## `app/tests/test_*.nim` identically, so nothing about the coverage changes.
## CTUI-10's deliverable list spells it `app/tests/test_value_origin_jump.nim`;
## that placement is not available for a suite that opens a trace, and CTUI-8's
## `tests/test_event_log_jump.nim` set the precedent.
##
## ## No mocks
##
## A real `.ct` trace recorded by a real recorder, opened by a real
## `replay-server`, with source read through the production `SourceProvider`
## constructed with `allowWorkingTree = false`.
##
## ## Templates, not procs, for anything that calls `check`

import std/[json, options, os, strutils, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/[replay_data_store, types]
import viewmodels/[calltrace_vm, debug_controls_vm,
                   origin_chain_types, origin_chain_vm, source_vm, state_vm,
                   timeline_vm]
import sdk/source_provider

import ../app/call_stack_binding
import ../app/commands/interpreter
import ../app/source_binding
import ../app/variables_binding
import ../app/views/command_palette
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 162

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "noir_space_ship"
  ProbeFunction = "calculate_damage"
    ## The call this suite steps out of to reach a stop inside
    ## `iterate_asteroids` where the loop's carried values are live. Chosen
    ## from the RECORDING's own calltrace, so no tick is written down here.
  ProbeCallIndex = 3
    ## The fourth recorded call to it — far enough into the loop that
    ## `remaining_shield` has been written by a PREVIOUS iteration, which is
    ## what makes the provenance non-trivial rather than the parameter it
    ## started as.

  SourceViewport = 16
  StackWidth = 46
  StackHeight = 17
  VariablesWidth = 60
  VariablesHeight = 20

  ExpectedThreads = 1
    ## CTUI-6 established that every recorder in this workspace answers DAP
    ## `threads` with exactly one entry — `replay-server` maps `threads` onto
    ## `list_processes`, whose CTFS implementation returns one synthetic
    ## process unconditionally. `:info threads` is asserted against that, as an
    ## equality, so the day a recorder grows per-thread state this suite says
    ## so.

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

# ---------------------------------------------------------------------------
# The harness
# ---------------------------------------------------------------------------

type OriginHarness = object
  session: HeadlessDebugSession
  timeline: TimelineVM
  calltrace: CalltraceVM
  source: SourceVM
  state: StateVM
  controls: DebugControlsVM
  origin: OriginChainVM
  provider: SourceProvider
  nav: ref OriginNavigator

proc openHarness(tracePath: string): OriginHarness =
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  let store = session.session.store
  let source = createSourceVM(store, session.session.editorVM)
  source.setViewport(height = SourceViewport, overscan = 4)
  var nav = new(OriginNavigator)
  nav[] = initOriginNavigator()
  OriginHarness(
    session: session,
    timeline: createTimelineVM(store),
    calltrace: createCalltraceVM(store),
    source: source,
    # THE SESSION'S OWN `StateVM`, not a fresh one — and that is load-bearing
    # rather than tidy. `:print <expr>` is `StateVM.addWatch`, and the watch
    # list that reaches the wire is the one `headless_session.
    # requestAndLoadLocals` reads off `session.stateVM`. A second `StateVM`
    # would take the watch and never be asked about it, and `:print` would
    # look wired while answering nothing. Not disposed here: the session owns
    # it.
    state: session.session.stateVM,
    controls: createDebugControlsVM(store),
    origin: createOriginChainVM(store),
    # `allowWorkingTree = false` DELIBERATELY, for CTUI-5's reason:
    # `noir_space_ship` is recorded from a program still in this checkout, so a
    # permissive provider would answer every request off the working tree and
    # the suite would pass without the trace payload ever being opened.
    provider: newCtfsSourceProvider(tracePath, allowWorkingTree = false),
    nav: nav)

proc closeHarness(h: OriginHarness) =
  h.origin.dispose()
  h.controls.dispose()
  h.source.dispose()
  h.calltrace.dispose()
  h.timeline.dispose()
  h.session.close()

proc dispatcherFor(h: OriginHarness): Dispatcher =
  ## THE PRODUCT'S OWN DISPATCH, wired to the ViewModels a real session built.
  ##
  ## The three service closures are the HOST — the thing `main.nim` will be —
  ## and each performs a real wire call through the session rather than
  ## returning a canned answer. They are not mocks: `CommandServices` exists
  ## precisely because no ViewModel owns a DAP `threads` round trip.
  let s = h.session
  Dispatcher(
    controls: h.controls,
    timeline: h.timeline,
    calltrace: h.calltrace,
    state: h.state,
    origin: h.origin,
    originNav: h.nav,
    services: CommandServices(
      threads: proc(): JsonNode =
        let response = s.sendRawDapRequest("threads", %*{})
        discard s.drainEvents()
        response.getOrDefault("body"),
      setBreakpoint: proc(path: string; line: int): bool =
        let response = s.lastSetBreakpointsResponse(path, line)
        discard s.drainEvents()
        response.getOrDefault("success").getBool(false)))

proc contextFor(h: OriginHarness; targets: TimelineTargets;
                selected = ""; functions: seq[FunctionSite] = @[];
                frameCount = 0): CommandContext =
  CommandContext(
    file: h.session.getCurrentFile(),
    line: h.session.getCurrentLine(),
    tick: h.session.getCurrentRRTicks(),
    frameCount: frameCount,
    targets: targets,
    selectedVariable: selected,
    functions: functions)

proc serveOne(h: OriginHarness; request: SourceLineRequest): SourceFetch =
  ## One request through the real provider, delivered. Seeded with a status
  ## that cannot be mistaken for success — `SourceFetchStatus`'s zero value is
  ## `sfsAvailable`, so a callback that never ran would read as an empty file.
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc fillSourceWindow(h: OriginHarness) =
  for request in h.source.followAndRequest():
    let fetch = h.serveOne(request)
    discard h.session.session.store.applySourceFetch(h.source, fetch)

proc recordedProgramLine(path: string; line: int): string =
  ## The `line`-th line of the file at `path`, read straight off disk — the
  ## INDEPENDENT ground truth for "the pane is showing the right line".
  if not fileExists(path):
    return ""
  let lines = splitSourceLines(readFile(path))
  if line >= 1 and line <= lines.len: lines[line - 1] else: ""

proc stackBody(h: OriginHarness): JsonNode =
  let response = h.session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 400,
  })
  discard h.session.drainEvents()
  response.getOrDefault("body")

proc bufferedStops(h: OriginHarness): int =
  ## How many `stopped` events are still queued. THE COUNT THAT MAKES "one
  ## atomic goto" a measurement.
  for event in h.session.drainEvents():
    if event.getOrDefault("event").getStr("") == "stopped":
      inc result

proc localNames(h: OriginHarness): seq[string] =
  h.session.requestAndLoadLocals()
  discard h.session.drainEvents()
  result = @[]
  for v in h.session.getLocals():
    result.add v.name

proc queryChain(h: OriginHarness; variable: string;
                tick: uint64): (int, OriginChain) =
  ## One `ct/originChain` through the ViewModel's own action proc, with the
  ## answer taken off the `ct/updated-origin-chain` event. Returns
  ## `(eventsApplied, chain)`.
  beginOriginQuery(h.origin, variable,
                   Location(file: h.session.getCurrentFile(),
                            line: h.session.getCurrentLine()), -1)
  let applied = applyOriginEvents(h.origin, h.session.drainEvents())
  discard tick
  let held = h.origin.activeChain.val
  (applied, (if held.isSome: held.get() else: OriginChain()))

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkDestinationState(h: OriginHarness; wantTick: uint64;
                               wantPath: string; wantLine: int;
                               label: string) =
  ## THE DESTINATION STATE — source, stack and variables, all read from their
  ## own ViewModel after the move, all asserted against the coordinate
  ## `OriginChainVM` reported.
  ##
  ## Asserting only the tick would pass a seek that moved the store and left
  ## every pane behind, which is the exact defect CTUI-8's event-jump suite was
  ## written against.
  let engineTick = h.session.getCurrentRRTicks()
  let engineFile = h.session.getCurrentFile()
  let engineLine = h.session.getCurrentLine()
  checkpoint(label & ": engine at tick " & $engineTick & " " & engineFile &
             ":" & $engineLine & " — chain said tick " & $wantTick & " " &
             wantPath & ":" & $wantLine)
  # ---- THE ENGINE AGREES WITH THE CHAIN, on all three coordinates ---------
  ck engineTick == wantTick
  ck engineFile == wantPath
  ck engineLine == wantLine

  # ---- THE TIMELINE ViewModel's own memo ----------------------------------
  ck h.timeline.currentPosition.val == wantTick
  ck h.controls.store.debugger.val.rrTicks == wantTick
  ck h.controls.store.debugger.val.location.line == wantLine

  # ---- THE SOURCE PANE, through the real provider -------------------------
  fillSourceWindow(h)
  let sourceModel = sourcePaneModelFor(
    h.source, h.session.session.store.degraded.sourceAvailability.val)
  ck sourceModel.executionLine == wantLine
  ck sourceModel.path == wantPath
  ck sourceModel.holdsLine(wantLine)
  let paneText = sourceModel.heldTextAt(wantLine)
  let onDisk = recordedProgramLine(wantPath, wantLine)
  checkpoint(label & " source line " & $wantLine & ": pane '" & paneText &
             "' disk '" & onDisk & "'")
  ck onDisk.len > 0
  ck paneText.strip() == onDisk.strip()

  # ---- THE CALL STACK PANE, from the engine's own stackTrace --------------
  let body = stackBody(h)
  let frames = framesFromStackTrace(body)
  ck frames.len > 0
  ck frames[0].line == wantLine
  ck frames[0].path == wantPath
  let stackModel = initCallStackModel(frames = frames, userRoots = @[],
                                      executionFrame = 0, selected = 0)
  let stackScreen = callStackScreen(stackModel, StackWidth, StackHeight)
  ck stackScreen.frameRows + stackScreen.groupRows > 0
  checkpoint(label & " innermost frame: " & frames[0].name)
  ck frames[0].name.len > 0

  # ---- THE VARIABLES PANE, from a fresh ct/load-locals --------------------
  h.session.requestAndLoadLocals()
  discard h.session.drainEvents()
  var timelineOfValues = initValueTimeline()
  observeStop(timelineOfValues, wantTick, h.state.currentVariables.val)
  let varsModel = variablesModelFor(h.state, timelineOfValues, wantTick,
                                    tickLabel = "tick " & $wantTick)
  let varsScreen = variablesScreen(varsModel, VariablesWidth, VariablesHeight)
  ck varsModel.tickLabel == "tick " & $wantTick
  ck varsScreen.totalRows > 0
  ck rowText(varsScreen.rows[0]).contains("tick " & $wantTick)
  ck h.state.currentVariables.val.len > 0

# ---------------------------------------------------------------------------

suite "CTUI-10: `o` lands on the origin OriginChainVM reports":

  test "noir_space_ship: the origin data is real, and `o` / `O` walk it":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let h = openHarness(resolution.tracePath)
      defer: closeHarness(h)

      # ---- THE STOP IS CHOSEN FROM THE RECORDING, not written down here ---
      h.session.requestAndLoadCalltrace()
      discard h.session.drainEvents()
      let callLines = h.session.getCalltraceLines()
      ck callLines.len > 0
      var probeTicks: seq[uint64] = @[]
      var names: seq[string] = @[]
      for line in callLines:
        if line.name notin names:
          names.add line.name
        if line.name.contains(ProbeFunction):
          probeTicks.add line.rrTicks
      echo "CTUI-10 CALLTRACE: ", callLines.len, " row(s), ", names.len,
           " distinct function(s); ", ProbeFunction, " called ",
           probeTicks.len, " time(s) at ", probeTicks
      ck probeTicks.len > ProbeCallIndex
      ck ProbeFunction in names

      h.session.gotoTick(probeTicks[ProbeCallIndex])
      discard h.session.drainEvents()
      ck h.session.getCurrentRRTicks() == probeTicks[ProbeCallIndex]
      h.session.stepOut()
      discard h.session.drainEvents()
      let queryTick = h.session.getCurrentRRTicks()
      let queryFile = h.session.getCurrentFile()
      let queryLine = h.session.getCurrentLine()
      echo "CTUI-10 QUERY STOP: tick ", queryTick, " ", queryFile, ":",
           queryLine, " — '", recordedProgramLine(queryFile, queryLine).strip(),
           "'"
      ck queryTick > probeTicks[ProbeCallIndex]
      ck queryFile.len > 0
      ck queryLine > 0

      let locals = localNames(h)
      echo "CTUI-10 LOCALS AT THE QUERY STOP: ", locals
      ck locals.len > 0

      # ---- IS THE ORIGIN DATA POPULATED? Every local, asked ---------------
      # This is the check the campaign's four unfilled ViewModel fields make
      # mandatory. The answer is echoed in full so a reader of a green run can
      # see the chains rather than take the assertion's word.
      var classified: seq[string] = @[]
      var bestVariable = ""
      var bestDistance = 0'u64
      var queriesIssued = 0
      var eventsApplied = 0
      for name in locals:
        inc queriesIssued
        let (applied, chain) = queryChain(h, name, queryTick)
        eventsApplied += applied
        # EXACTLY ONE EVENT PER QUERY. `ct/updated-origin-chain` is emitted
        # beside the response by `Handler::respond_origin_chain`; a path that
        # answered twice, or not at all, is red here.
        ck applied == 1
        let steps = stepsOf(chain)
        var summary = name & ": " & $steps.len & " hop(s) term=" &
          $chain.terminator.kind & " conf=" & $chain.confidence
        for step in steps:
          summary.add "\n      " & $step.kind & " " & step.targetExpr &
            " <- " & step.sourceExpr.strip() & " @ " &
            step.path.extractFilename & ":" & $step.line & " tick=" & $step.tick
        echo "CTUI-10 ORIGIN ", summary
        if steps.len == 0:
          continue
        let head = steps[0]
        if head.kind != okUnknown and head.tick < queryTick:
          classified.add name
          let distance = queryTick - head.tick
          if distance > bestDistance or
             (distance == bestDistance and name < bestVariable):
            bestDistance = distance
            bestVariable = name
      ck queriesIssued == locals.len
      ck eventsApplied == locals.len
      echo "CTUI-10 CLASSIFIED PROVENANCE: ", classified,
           " — deepest is `", bestVariable, "` at ", bestDistance,
           " tick(s) back"
      # THE ORIGIN CHAINS ARE POPULATED. Asserted as a count against the
      # locals, so an engine that stopped classifying reddens rather than
      # silently selecting nothing.
      ck classified.len > 0
      ck classified.len < locals.len       # not everything is classified
      ck bestVariable.len > 0
      ck bestDistance > 0
      # …and on THIS recording the deepest is `remaining_shield`, whose value
      # at this stop was written by the PREVIOUS iteration of the loop. An
      # equality rather than a property, so a re-recording that changed the
      # answer is visible rather than absorbed.
      ck bestVariable == "remaining_shield"

      # ---- PRESS `o` — THROUGH THE PRODUCT'S DISPATCH ---------------------
      # The navigator is reset first: the sweep above left the ViewModel
      # holding the LAST local's chain, and `o` must be seen to issue its own
      # query rather than to adopt a leftover.
      h.origin.onCancelLoad()
      h.origin.activeChain.val = none(OriginChain)
      h.nav[] = initOriginNavigator()
      # THE RECORDING'S EXTENT, from the surface CTUI-8 established is the one
      # that answers: `ct/event-load`'s `maxRRTicks`. `TimelineVM.markers` is
      # filled by nothing on a replay session, and a `TimelineTargets` whose
      # `maxTick` is 0 makes `timeline_keys.clampToBounds` clamp EVERY seek to
      # `minTick` — which is how a jump to the origin silently becomes a jump
      # to tick 0. Measured here rather than reasoned about: without this the
      # destination assertion below reports tick 0 at `main.nr:1`.
      let extentRows = h.session.requestAndLoadEventLog(start = 0, count = 1)
      discard h.session.drainEvents()
      ck extentRows.len > 0
      ck extentRows[0].maxRRTicks > 0'u64
      let targets = targetsFor(
        TimelineBounds(minTick: 0'u64, maxTick: extentRows[0].maxRRTicks,
                       known: true, source: "ct/event-load.maxRRTicks"),
        boundariesFromCalltrace(callLines), @[])
      ck targets.maxTick == extentRows[0].maxRRTicks
      ck targets.maxTick > queryTick
      let d = dispatcherFor(h)
      var ctx = h.contextFor(targets, selected = bestVariable)
      ck ctx.tick == queryTick
      ck ctx.selectedVariable == bestVariable

      ck originQueryState(h.origin) == oqIdle
      let firstPress = dispatchAction(d, ctx, kaValueOrigin)
      checkpoint("first `o`: " & $firstPress.status & " " & firstPress.detail)
      # ---- THE VISIBLE PENDING STATE — CTUI-10's named risk mitigation ----
      ck firstPress.status == drDone
      ck firstPress.action == kaValueOrigin
      ck firstPress.detail.startsWith(OriginPendingText)
      ck firstPress.detail.contains(bestVariable)
      ck h.origin.loading.val
      ck originQueryState(h.origin) == oqPending
      ck originNotification(h.nav[], oqPending) == OriginPendingText
      # …and the debugger has NOT moved while the query is in flight, which is
      # what makes the pending state a state rather than a label on a jump.
      ck h.session.getCurrentRRTicks() == queryTick
      # …and the breadcrumb the ViewModel pushed names the question.
      ck h.origin.breadcrumbStack.val.len > 0
      ck h.origin.breadcrumbStack.val[^1].variableName == bestVariable

      # ---- THE ANSWER LANDS ------------------------------------------------
      let applied = applyOriginEvents(h.origin, h.session.drainEvents())
      ck applied == 1
      ck not h.origin.loading.val
      ck originQueryState(h.origin) == oqReady
      ck h.origin.activeChain.val.isSome
      let chain = h.origin.activeChain.val.get()
      ck chain.queryVariable == bestVariable
      let steps = stepsOf(chain)
      ck steps.len > 0
      let originStep = steps[0]
      echo "CTUI-10 ORIGIN OF `", bestVariable, "`: ", $originStep.kind,
           " <- ", originStep.sourceExpr.strip(), " @ ",
           originStep.path, ":", originStep.line, " tick ", originStep.tick,
           " (question was tick ", queryTick, ")"
      ck originStep.tick < queryTick
      ck originStep.tick > 0'u64
      ck originStep.path.len > 0
      ck originStep.line > 0
      ck originStep.kind != okUnknown
      ck originStep.confidence > 0.0

      # THE ENGINE'S TWO ACCOUNTS OF ONE HOP DISAGREE, and both are its own.
      # `sourceText` is the statement the classifier matched; `location.line`
      # is the line of the recorded step. Measured 2026-09-06 — asserted as an
      # inequality with both read off disk, so a reconciliation reddens here.
      let lineAtLocation = recordedProgramLine(originStep.path, originStep.line)
      echo "CTUI-10 HOP SOURCE TEXT: classifier '",
           originStep.sourceText.strip(), "' vs the file at line ",
           originStep.line, ": '", lineAtLocation.strip(), "'"
      ck originStep.sourceText.len > 0
      ck lineAtLocation.len > 0
      ck originStep.sourceText.strip() != lineAtLocation.strip()

      # ---- PRESS `o` AGAIN: the same dispatch completes the jump -----------
      discard h.session.drainEvents()
      let secondPress = dispatchAction(d, ctx, kaValueOrigin)
      h.session.settleAfterSeek()
      checkpoint("second `o`: " & $secondPress.status & " " &
                 secondPress.detail)
      ck secondPress.status == drDone
      ck secondPress.action == kaValueOrigin
      ck secondPress.detail.contains(bestVariable)
      ck secondPress.detail.contains($originStep.tick)
      # ONE ATOMIC GOTO: no second `stopped` is left behind.
      ck bufferedStops(h) == 0
      ck h.nav[].depth == 1

      # ---- THE DESTINATION STATE ------------------------------------------
      checkDestinationState(h, originStep.tick, originStep.path,
                            originStep.line, "origin")

      # ---- `O` RETURNS -----------------------------------------------------
      discard h.session.drainEvents()
      ctx = h.contextFor(targets, selected = bestVariable)
      ck ctx.tick == originStep.tick
      let back = dispatchAction(d, ctx, kaReverseOrigin)
      h.session.settleAfterSeek()
      checkpoint("`O`: " & $back.status & " " & back.detail)
      ck back.status == drDone
      ck back.action == kaReverseOrigin
      ck bufferedStops(h) == 0
      ck h.nav[].depth == 0
      checkDestinationState(h, queryTick, queryFile, queryLine, "returned")

      # `O` AGAIN AT THE QUESTION IS REPORTED, not silent — there is nothing
      # left on the return stack.
      let overshoot = dispatchAction(d, ctx, kaReverseOrigin)
      checkpoint("`O` at the question: " & $overshoot.status & " " &
                 overshoot.detail)
      ck overshoot.status == drUnavailable
      ck overshoot.detail == OriginAtQueryText
      ck h.session.getCurrentRRTicks() == queryTick

      # ---- AND THE COMMAND SPELLING REACHES THE SAME PLACE ------------------
      # `:origin <var>` is `o` with the variable named. Same navigator, same
      # dispatch, same destination — which is CTUI-10's first contract measured
      # on a real debugger rather than on a value comparison.
      h.nav[] = initOriginNavigator()
      h.origin.activeChain.val = none(OriginChain)
      ctx = h.contextFor(targets, selected = "")
      let ask = runCommand(d, ctx, ":origin " & bestVariable)
      ck ask.invocation.status == csOk
      ck ask.invocation.kind == cmdOrigin
      ck ask.dispatch.action == kaValueOrigin
      ck ask.message.startsWith(OriginPendingText)
      ck applyOriginEvents(h.origin, h.session.drainEvents()) == 1
      discard h.session.drainEvents()
      let jump = runCommand(d, ctx, ":o " & bestVariable)
      h.session.settleAfterSeek()
      ck jump.dispatch.status == drDone
      ck bufferedStops(h) == 0
      ck h.session.getCurrentRRTicks() == originStep.tick
      ck h.session.getCurrentLine() == originStep.line
      ck h.session.getCurrentFile() == originStep.path

  test "the interpreter's dispatch moves a real debugger":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let h = openHarness(resolution.tracePath)
      defer: closeHarness(h)

      h.session.requestAndLoadCalltrace()
      discard h.session.drainEvents()
      let callLines = h.session.getCalltraceLines()
      let boundaries = boundariesFromCalltrace(callLines)
      ck boundaries.len > 2
      let events = h.session.requestAndLoadEventLog(start = 0, count = 1)
      discard h.session.drainEvents()
      ck events.len > 0
      let maxTick = events[0].maxRRTicks
      ck maxTick > 0'u64
      let targets = targetsFor(
        TimelineBounds(minTick: 0'u64, maxTick: maxTick, known: true,
                       source: "ct/event-load.maxRRTicks"),
        boundaries, @[])
      let d = dispatcherFor(h)

      # ---- `:goto <tick>` — §4.3's own spelling of §4.2's `t <tick> Enter` --
      let destination = boundaries[boundaries.len div 2]
      discard h.session.drainEvents()
      var ctx = h.contextFor(targets)
      let goto = runCommand(d, ctx, ":goto " & $destination)
      h.session.settleAfterSeek()
      checkpoint(":goto " & $destination & " -> " & goto.message)
      ck goto.dispatch.status == drDone
      ck goto.dispatch.action == kaSeekToTick
      ck bufferedStops(h) == 0
      ck h.session.getCurrentRRTicks() == destination

      # ---- `:next` IS `n` IS `dispatchAction(kaStepOver)` -------------------
      let beforeStep = h.session.getCurrentRRTicks()
      ctx = h.contextFor(targets)
      let next = runCommand(d, ctx, ":next")
      h.session.settleAfterSeek()
      ck next.dispatch.status == drDone
      ck next.dispatch.action == kaStepOver
      ck bufferedStops(h) == 0
      let afterCommand = h.session.getCurrentRRTicks()
      checkpoint(":next moved " & $beforeStep & " -> " & $afterCommand)
      ck afterCommand > beforeStep

      # The KEY form, from the same position, moves the same way. Run from the
      # SAME starting tick so the two are comparable.
      discard h.session.drainEvents()
      h.session.gotoTick(beforeStep)
      discard h.session.drainEvents()
      ck h.session.getCurrentRRTicks() == beforeStep
      ctx = h.contextFor(targets)
      let key = dispatchAction(d, ctx, kaStepOver)
      h.session.settleAfterSeek()
      ck key.status == drDone
      ck bufferedStops(h) == 0
      checkpoint("`n` from " & $beforeStep & " landed at " &
                 $h.session.getCurrentRRTicks())
      # IDENTICAL STATE from the two spellings, on a real debugger.
      ck h.session.getCurrentRRTicks() == afterCommand
      ck key == next.dispatch

      # ---- `:print <expr>` — the engine really evaluates a watch -----------
      # THE POSITION IS CHOSEN FROM THE RECORDING, the same way the origin case
      # chooses it: step out of a recorded `calculate_damage` call and the
      # loop's carried values are live.
      var probeTicks: seq[uint64] = @[]
      for line in callLines:
        if line.name.contains(ProbeFunction):
          probeTicks.add line.rrTicks
      ck probeTicks.len > ProbeCallIndex
      h.session.gotoTick(probeTicks[ProbeCallIndex])
      discard h.session.drainEvents()
      h.session.stepOut()
      discard h.session.drainEvents()

      let watched = "remaining_shield"
      ck h.state.watchExpressions.val.len == 0
      ctx = h.contextFor(targets)
      let printed = runCommand(d, ctx, ":print " & watched)
      checkpoint(":print -> " & printed.message)
      ck printed.dispatch.status == drDone
      ck h.state.watchExpressions.val.len == 1
      ck h.state.watchExpressions.val[0] == watched
      # …and the ENGINE ANSWERS IT on the next `ct/load-locals`, which is the
      # whole of the claim that `StateVM.addWatch` is a real evaluator and not
      # a list nobody reads. The answer arrives marked `isWatch` and
      # `applyLocalsResponse` splits it into `store.locals.watches`.
      h.session.requestAndLoadLocals()
      discard h.session.drainEvents()
      let watchRows = h.session.session.store.locals.watches.val
      var watchedValue = ""
      for v in watchRows:
        if v.name == watched:
          watchedValue = v.value
      echo "CTUI-10 PRINT: `", watched, "` = ", watchedValue, " (",
           watchRows.len, " watch row(s))"
      ck watchRows.len == 1
      ck watchRows[0].isWatch
      ck watchedValue.len > 0
      # THE POSITIVE TWIN THROUGH THE SAME CALL: the same expression is also a
      # plain local here, and the two answers agree — which is what makes the
      # watch an EVALUATION rather than an echo of the name.
      var localValue = ""
      for v in h.session.session.store.locals.locals.val:
        if v.name == watched:
          localValue = v.value
      ck localValue.len > 0
      ck localValue == watchedValue

      # ---- `:info threads` — CTUI-6's one thread, through a real request ---
      ctx = h.contextFor(targets)
      let threads = runCommand(d, ctx, ":info threads")
      checkpoint(":info threads -> " & threads.message & " / " &
                 threads.lines.join(" | "))
      ck threads.dispatch.status == drDone
      ck threads.lines.len == ExpectedThreads
      ck threads.message.contains($ExpectedThreads)

      # ---- `:break <line>` — the engine VERIFIES it ------------------------
      let programPath = h.session.getCurrentFile()
      let programLine = h.session.getCurrentLine()
      ctx = h.contextFor(targets)
      let brk = runCommand(d, ctx, ":break " & $programLine)
      checkpoint(":break -> " & brk.message)
      ck brk.dispatch.status == drDone
      ck brk.message.contains(programPath)
      ck brk.message.contains($programLine)

      # ---- THE PALETTE'S OWN LINE NAVIGATES --------------------------------
      # `command_palette` answers a §4.3 line and nothing else; here that line
      # is run through the same `runCommand` and the debugger is asserted to
      # have moved to the function's recorded tick.
      var entries: seq[PaletteEntry] = @[]
      var seenNames: seq[string] = @[]
      for line in callLines:
        if line.name in seenNames:
          continue
        seenNames.add line.name
        entries.add functionEntry(line.name, programPath, 1, line.rrTicks)
      ck entries.len > 1
      var palette = initPaletteModel(entries)
      discard palette.open()
      let hits = palette.setQuery("iterast")
      checkpoint("palette `iterast` -> " & $hits & " hit(s)")
      ck hits > 0
      let (hasTop, top) = palette.topHit()
      ck hasTop
      ck top.entry.text.contains("iterate_asteroids")
      let (hasCommand, paletteLine) = palette.selectedCommand()
      ck hasCommand
      checkpoint("palette runs: " & paletteLine)
      discard h.session.drainEvents()
      ctx = h.contextFor(targets)
      let ran = runCommand(d, ctx, paletteLine)
      h.session.settleAfterSeek()
      ck ran.dispatch.status == drDone
      ck ran.dispatch.action == kaSeekToTick
      ck bufferedStops(h) == 0
      # THE DESTINATION IS THE CALLTRACE'S OWN TICK for the function the query
      # named — read back out of the recording rather than out of the string
      # the palette produced, so this is not the palette checked against
      # itself.
      var wantTick = 0'u64
      for line in callLines:
        if line.name == top.entry.text:
          wantTick = line.rrTicks
          break
      checkpoint("palette landed on " & $h.session.getCurrentRRTicks() &
                 "; the calltrace says " & top.entry.text & " starts at " &
                 $wantTick)
      ck wantTick > 0'u64
      ck h.session.getCurrentRRTicks() == wantTick

  test "assertion count":
    echo "CTUI-10 ORIGIN JUMP: examined ", examinedFixtures,
         " fixture case(s), ", verifiedFixtures, " verified, ",
         skippedFixtures, " skipped"
    ck examinedFixtures == 2
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures > 0
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
