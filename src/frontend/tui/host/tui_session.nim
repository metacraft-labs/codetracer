## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
## See `host/native_host.nim`'s header for the full rule, and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that keeps
## `app/` on the other side of it.
##
## host/tui_session.nim — CTUI-11. A live debugging session behind the panes.
##
## ## Why this exists at all, and why it is here
##
## Every pane in this front-end is a pure function of a MODEL, and every model
## has a binding under `app/` that builds it out of a ViewModel: CTUI-5's
## `sourcePaneModelFor`, CTUI-6's `callStackModelFor`, CTUI-7's
## `variablesModelFor`, CTUI-8's `timelineBarModelFor` and `eventLogModelFor`.
## Until this milestone every one of those was called only from a test, because
## `main.nim` had no loop to call them in. This module is the thing that calls
## them on a real stop, and it is in `host/` for one reason: it owns a
## `HeadlessDebugSession`, which spawns `replay-server` and which the Embed SDK
## facade deliberately withholds from `app/`.
##
## ## THE PUMP, AND THE DEFECT IT IS WRITTEN AGAINST
##
## `app/runtime.handleToken` SENDS a navigation command through CTUI-10's
## dispatcher and answers `awaitsMove`. It cannot wait for the result:
## `ct/complete-move` arrives as an EVENT, the blocking read for it is
## `DapStdioBackend.waitForEvent`, and that is on this side of the facade.
##
## CTUI-5 measured what happens when nothing pumps it, and recorded it as a
## property of the headless host rather than of its own suite: the step is sent,
## the engine really moves, and every pane goes on reporting the old position
## for the rest of the session. `pumpMove` is what closes that, and
## `refresh` is what re-reads every pane afterwards.
##
## ## Everything here is read at the stop, and nothing is retained
##
## `refresh` rebuilds all five models from scratch on every move. That is the
## bindings' own contract — "everything is read at call time and nothing is
## retained, so two stops are two values and the difference between them is
## exactly the difference on screen" — and it is what makes a repaint a function
## of the engine's state rather than of the order the user pressed keys in.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it spawns replay-server.".}

import std/[json, os, strutils]

import codetracer_embed
import headless_session

import ../app/call_stack_binding
import ../app/runtime
import ../app/source_binding
import ../app/timeline_binding
import ../app/variables_binding
import ./native_host

export native_host

const
  SourceOverscan* = 6
    ## How many lines beyond the viewport `SourceVM` holds. CTUI-5's own
    ## number, kept so the shipped front-end fetches the window its Tier-1
    ## suites measured.
  EventLogPageSize* = 64
  CalltraceLevels* = 400
    ## `stackTrace`'s `levels`. The same number CTUI-6's suites ask for, so a
    ## deep recursion is as visible here as it is there.
  MaxEventsForBounds* = 4096
    ## How much of the event log is read once, at open, to learn the
    ## recording's extent.
    ##
    ## CTUI-8 established that `TimelineVM.markers` is filled by nothing on a
    ## replay session and that the recording's extent comes from
    ## `ct/event-load`'s `maxRRTicks` instead. So the timeline's bounds are a
    ## property of that one answer, and this is the window it is read from.

type
  TuiSession* = ref object
    ## One open trace, its ViewModels and its source provider.
    session*: HeadlessDebugSession
    source*: SourceVM
    calltrace*: CalltraceVM
    state*: StateVM
    timeline*: TimelineVM
    events*: EventLogVM
    controls*: DebugControlsVM
    origin*: OriginChainVM
    provider*: SourceProvider
    valueTimeline*: ValueTimeline
      ## CTUI-7's step-to-step diff. Carried across stops, because a diff is by
      ## definition a fact about two of them.
    entryFile*: string
    bounds*: TimelineBounds
    callBoundaries*: seq[uint64]
    mutations*: seq[uint64]
    maxRRTicks*: uint64
    originNav*: ref OriginNavigator

proc openTuiSession*(traceFolder: string; viewportHeight: int): TuiSession =
  ## Spawn `replay-server` on `traceFolder`, complete the DAP handshake and
  ## build the ViewModel graph the panes read.
  ##
  ## `allowWorkingTree = false` on the provider, for CTUI-5's reason restated as
  ## a product decision rather than a test one: a source pane that silently read
  ## the file off disk when the recording's payload was unopenable would show a
  ## user the code they have NOW for a recording made against the code they had
  ## THEN. §3.3.2's provenance marker exists to make that difference visible, and
  ## it cannot if the provider papers over it.
  let sess = openLocalTrace(traceFolder)
  let store = sess.session.store
  let src = createSourceVM(store, sess.session.editorVM)
  src.setViewport(height = max(1, viewportHeight), overscan = SourceOverscan)
  var nav = new(OriginNavigator)
  nav[] = initOriginNavigator()
  TuiSession(
    session: sess,
    source: src,
    calltrace: createCalltraceVM(store),
    state: createStateVM(store),
    timeline: createTimelineVM(store),
    events: createEventLogVM(store),
    controls: createDebugControlsVM(store),
    origin: createOriginChainVM(store),
    provider: newCtfsSourceProvider(traceFolder, allowWorkingTree = false),
    valueTimeline: initValueTimeline(),
    entryFile: sess.getCurrentFile(),
    bounds: TimelineBounds(),
    callBoundaries: @[],
    mutations: @[],
    maxRRTicks: 0'u64,
    originNav: nav)

proc close*(s: TuiSession) =
  ## Tear the session down. Ordered VM-first because each `dispose` drops a
  ## reactive root that still reads the store.
  if s.isNil:
    return
  s.origin.dispose()
  s.controls.dispose()
  s.events.dispose()
  s.timeline.dispose()
  s.state.dispose()
  s.calltrace.dispose()
  s.source.dispose()
  s.session.close()

proc setViewportHeight*(s: TuiSession; height: int) =
  ## Tell `SourceVM` how many lines the source PANE actually has.
  ##
  ## Not a detail. `SourceVM.followExecutionPointer` scrolls the window it was
  ## told about, so a viewport taller than the pane's rectangle scrolls the
  ## execution line to a row the pane never draws — measured on `calc` at
  ## 120x40 with the viewport set from the terminal's height: the pointer was on
  ## line 55 and the pane was showing 23-51. The height therefore comes from the
  ## PROJECTION, once the shell has been laid out, and is re-set on every
  ## resize.
  s.source.setViewport(height = max(1, height), overscan = SourceOverscan)

proc pumpMove*(s: TuiSession) =
  ## Consume the `stopped` + `ct/complete-move` pair a navigation command
  ## produces, and push the new position into the store.
  ##
  ## TOTAL: never raises. `waitForEvent` raises `ValueError` when its message
  ## budget runs out, and a front-end that let that escape would drop the
  ## terminal it was restoring on a command the engine merely declined. The
  ## caller sees an unchanged position instead, which is what the screen would
  ## show anyway.
  try:
    s.session.consumeNextCompleteMove()
  except CatchableError:
    discard

proc serveSourceWindow(s: TuiSession) =
  ## Follow the execution pointer and serve every line the window then lacks,
  ## through the real provider.
  for request in s.source.followAndRequest():
    var captured = SourceFetch(status: sfsProviderUnavailable,
                               detail: "the provider callback never ran")
    # SEEDED WITH A STATUS THAT CANNOT BE MISTAKEN FOR SUCCESS, and drained:
    # `async_compat.onComplete` defers a callback even on an already-complete
    # native future, and `SourceFetchStatus`'s zero value is `sfsAvailable`, so
    # a callback that never ran would read as an empty file rather than as a
    # failure. That is CTUI-4's trap, and it is repeated here because this is a
    # second call site rather than because it is likely.
    s.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
    drainSourceCallbacks()
    discard s.session.session.store.applySourceFetch(s.source, captured)

proc stackBody(s: TuiSession): JsonNode =
  let response = s.session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": CalltraceLevels})
  discard s.session.drainEvents()
  response.getOrDefault("body")

proc eventRows(s: TuiSession; offset, limit: int): seq[EventRow] =
  result = @[]
  for entry in s.session.requestAndLoadEventLog(start = offset, count = limit):
    result.add EventRow(
      index: entry.eventIndex,
      tick: entry.rrTicks,
      file: entry.file,
      line: entry.line,
      content: entry.content,
      category: categoryFor(entry.kind, entry.stdout),
      kindId: entry.kind)

proc learnExtent*(s: TuiSession) =
  ## Read the recording's extent and its seek targets ONCE, at open.
  ##
  ## Separated from `refresh` because it is the expensive read and it does not
  ## change: `ct/event-load`'s `maxRRTicks` is a property of the recording, and
  ## re-asking for it after every step would put a whole-log request inside the
  ## step latency CTUI-14 measures.
  var rows: seq[EventRow] = @[]
  try:
    let entries = s.session.requestAndLoadEventLog(start = 0,
                                                   count = MaxEventsForBounds)
    for entry in entries:
      rows.add EventRow(
        index: entry.eventIndex, tick: entry.rrTicks, file: entry.file,
        line: entry.line, content: entry.content,
        category: categoryFor(entry.kind, entry.stdout), kindId: entry.kind)
      if entry.maxRRTicks > s.maxRRTicks:
        s.maxRRTicks = entry.maxRRTicks
  except CatchableError:
    discard
  s.bounds = resolveBounds(s.timeline, rows, s.maxRRTicks)
  s.mutations = mutationTicks(rows)
  try:
    s.callBoundaries = boundariesFromCalltrace(s.session.getCalltraceLines())
  except CatchableError:
    s.callBoundaries = @[]

proc refresh*(s: TuiSession; rt: TuiRuntime) =
  ## Rebuild every pane's model from the CURRENT stop, and re-point the
  ## dispatcher and the command context at it.
  ##
  ## One function rather than five, called from exactly two places (after the
  ## open and after each pumped move), which is what makes "the panes agree with
  ## each other" a property of the code rather than of the caller remembering
  ## the order.
  let tick = s.session.getCurrentRRTicks()

  serveSourceWindow(s)
  rt.app.source = sourcePaneModelFor(
    s.source, s.session.session.store.degraded.sourceAvailability.val)

  let frames = framesFromStackTrace(s.stackBody())
  rt.app.callStack = callStackModelFor(frames, s.entryFile)

  try:
    s.session.requestAndLoadLocals()
  except CatchableError:
    discard
  let locals = s.session.getLocals()
  s.valueTimeline.observeStop(tick, locals)
  rt.app.variables = variablesModelFor(s.state, s.valueTimeline, tick,
                                       tickLabel = "tick " & $tick)

  rt.app.timeline = timelineBarModelFor(s.timeline, s.bounds, @[], @[],
                                        currentTick = tick)
  # §3.1's header counters. `int` rather than `uint64` because `HeaderModel`
  # carries them as `int` for the width arithmetic that formats them; a
  # recording long enough to overflow that would have overflowed the scrubber's
  # column mapping first.
  rt.app.tick = int(tick)
  rt.app.totalTicks = int(s.bounds.maxTick)
  let sess = s.session
  rt.app.eventLog = eventLogModelFor(
    proc(offset, limit: int): EventPage =
      var rows: seq[EventRow] = @[]
      try:
        for entry in sess.requestAndLoadEventLog(start = offset, count = limit):
          rows.add EventRow(
            index: entry.eventIndex, tick: entry.rrTicks, file: entry.file,
            line: entry.line, content: entry.content,
            category: categoryFor(entry.kind, entry.stdout), kindId: entry.kind)
      except CatchableError:
        discard
      EventPage(rows: rows, atEnd: rows.len < limit),
    currentTick = tick, pageSize = EventLogPageSize)
  # THE PANE DOES NOT FETCH WHILE IT PAINTS — `app/views/event_log.nim`'s
  # header states that as the rule that keeps painting a pure function of what
  # is held — so a caller that wants rows asks for them. A caller that forgets
  # gets `elrPending` rows, which is exactly what the first run of this loop
  # showed: five `…` lines under a `TRACEPOINTS loading` title.
  rt.app.eventLog.ensureWindow(0, EventLogPageSize)

  rt.dispatcher = Dispatcher(
    controls: s.controls,
    timeline: s.timeline,
    calltrace: s.calltrace,
    state: s.state,
    origin: s.origin,
    originNav: s.originNav,
    services: CommandServices())
  rt.context = CommandContext(
    file: s.session.getCurrentFile(),
    line: s.session.getCurrentLine(),
    tick: tick,
    frameCount: frames.len,
    targets: targetsFor(s.bounds, s.callBoundaries, s.mutations),
    selectedVariable: "",
    functions: @[])

proc header*(s: TuiSession; rt: TuiRuntime) =
  ## Put the trace's NAME where §3.1's header row reads it. Separate from
  ## `refresh` because it never changes and `refresh` runs on every step.
  let name = extractFilename(s.session.tracePath.strip(chars = {'/'}))
  rt.app.title = name
  rt.app.traceName = name

proc describe*(s: TuiSession): string =
  ## For a diagnostic: where the engine is and what the recording's extent is.
  s.session.getCurrentFile() & ":" & $s.session.getCurrentLine() &
    "  tick " & $s.session.getCurrentRRTicks() &
    "  extent " & (if s.bounds.known: $s.bounds.minTick & ".." & $s.bounds.maxTick
                   else: "unknown")
