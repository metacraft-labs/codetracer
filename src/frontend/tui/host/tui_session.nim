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

import std/[json, os, strutils, tables]

import codetracer_embed
import headless_session
from backend/stdio_backend import sendDapRequestNoResponse, drainEvents,
  waitForEvent

# QUALIFIED, and the qualification is load-bearing: `EventLogRow` is declared
# TWICE in this module's scope — `viewmodel/store/types.EventLogRow` is the
# store's neutral row, and `tui/app/views/event_log.EventLogRow` is a rendered
# row of the PANE (a `kind` + an index + an `EventRow`). Naming it bare
# compiles in the files that import only one of the two and fails as
# "ambiguous identifier" in the ones that import both, which is the shape a
# reader meets as a compile error several modules away from either declaration.
import ../../viewmodel/store/types as store_types
import ../../viewmodel/viewmodels/inline_value_timeline

import viewmodels/filesystem_vm   # the replay file tree the Files pane lists
import viewmodels/calltrace_vm    # CALLTRACE_BUFFER, the desktop's pre-fetch
import viewmodels/scratchpad_vm   # PLAT-50: the scratchpad pane
import ../../viewmodel/host/terminal_output_source   # PLAT-52
import ../app/call_stack_binding
import ../app/runtime
import ../app/source_binding
import ../app/timeline_binding
import ../app/variables_binding
import ../app/syntax/highlighter   # lexerContexts: the window's entry state
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
    callTraceStack*: seq[string]
      ## PLAT-47. The call stack's frame names at the current stop, innermost
      ## first — what marks the current call in a section loaded later, when
      ## the reader scrolls (`pageCallTrace`).
    callTraceAsked*: bool
      ## PLAT-47. `learnExtent` asked the backend for the call trace. With no
      ## rows arrived, the calltrace pane then says the recording has none.
    files*: FileTreeModel
      ## PLAT-47. The recording's source tree, as the Files pane lists it —
      ## read ONCE, at open (`learnExtent`), off the session's `FilesystemVM`,
      ## which `loadRecordingPanes` filled with the same tree the desktop's
      ## Files pane renders. Until PLAT-47 only `--headless` filled the pane;
      ## the interactive terminal showed an empty FILES pane on every replay.
    lexerContexts*: LexerContextCache
      ## PLAT-47 B4. The highlighter's state at the start of every line of the
      ## files this session has fetched windows of, derived from the whole file
      ## the provider sliced (`SourceFetch.fileLines`) and handed to
      ## `SourceVM` with each window, so a window that opens inside a
      ## docstring is coloured as the desktop colours it.
    valueGate*: InlineValueGate
    tracepointsRun*: int
      ## PLAT-50: how many tracepoints `:tracepoint` swept (each its own id).
      ## PLAT-29. The inline values are drawn only when the locals they come
      ## from are about the stop the debugger is at — reconciled against the
      ## store's stop timeline (`viewmodels/inline_value_timeline`). Counts
      ## every draw; the store's `stops.report` counts every arrival.

proc openTuiSession*(traceFolder: string; viewportHeight: int;
                     bound: DapReadBound = DapReadBound(interruptFd: -1)
                    ): TuiSession =
  ## Spawn `replay-server` on `traceFolder`, complete the DAP handshake and
  ## build the ViewModel graph the panes read.
  ##
  ## `allowWorkingTree = false` on the provider, for CTUI-5's reason restated as
  ## a product decision rather than a test one: a source pane that silently read
  ## the file off disk when the recording's payload was unopenable would show a
  ## user the code they have NOW for a recording made against the code they had
  ## THEN. §3.3.2's provenance marker exists to make that difference visible, and
  ## it cannot if the provider papers over it.
  ## `bound` is CTUI-14's per-message clock and its escape hatch; see
  ## `host/native_host.openLocalTrace`. It is carried rather than built here
  ## because the fd it watches is the DRIVER's input fd, and this module owns
  ## no terminal.
  let sess = openLocalTrace(traceFolder, bound)
  let store = sess.session.store
  let src = createSourceVM(store, sess.session.editorVM)
  if not sess.session.editorVM.isNil:
    sess.session.editorVM.showFlowOverlay.val = FlowOverlayShownByDefault
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
    lexerContexts: newLexerContextCache(),
    valueTimeline: initValueTimeline(),
    entryFile: sess.getCurrentFile(),
    bounds: TimelineBounds(),
    callBoundaries: @[],
    mutations: @[],
    maxRRTicks: 0'u64,
    originNav: nav,
    valueGate: InlineValueGate())

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
    let contexts =
      if captured.fileLines.len > 0 and captured.lines.len > 0:
        s.lexerContexts.contextsFor(captured.revision.path, captured.fileLines,
                                    captured.firstLine,
                                    captured.firstLine + captured.lines.len - 1)
      else: @[]
    discard s.session.session.store.applySourceFetch(s.source, captured,
                                                      contexts)

proc stackBody(s: TuiSession): JsonNode =
  let response = s.session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": CalltraceLevels})
  discard s.session.drainEvents()
  response.getOrDefault("body")

func eventRowOf(row: store_types.EventLogRow): EventRow =
  ## One store row as the pane's row.
  ##
  ## THE TERMINAL'S ONLY CONVERSION, and it converts from the STORE's row
  ## rather than from the wire. What it adds is the one thing the store cannot
  ## hold: `category`, which is `app/views/event_log.categoryFor`'s
  ## classification of `(kindId, stdout)` into the five colours §3.3.5 names.
  ## Everything else is carried across unchanged, so a pane row and a store row
  ## cannot disagree about where an event was or what it said.
  EventRow(
    index: row.eventIndex,
    tick: row.rrTicks,
    file: row.file,
    line: row.line,
    content: row.value,
    category: categoryFor(row.kindId, row.stdout),
    kindId: row.kindId)

proc loadedEventRows(s: TuiSession; offset, limit: int;
                     order = RecordedEventOrder): seq[EventRow] =
  ## Ask the backend for a window and read the answer OUT OF THE STORE.
  ##
  ## `requestAndLoadEventLog` decodes into `store.eventLog.rows` — see its
  ## header — so the request is issued for its effect and the rows are read
  ## from the one place they live. This used to convert the returned sequence
  ## itself, which made the terminal one of three independent decoders of the
  ## same payload.
  discard s.session.requestAndLoadEventLog(start = offset, count = limit,
                                           order = order)
  result = @[]
  for row in s.session.session.store.eventLog.rows.val:
    result.add eventRowOf(row)

proc fileTreeModelOf*(vm: FilesystemVM): FileTreeModel =
  ## The Files pane's rows for a replay: the `FilesystemVM`'s tree, root
  ## included, depth-first in the tree's own order — the rows the desktop's
  ## Files pane draws for the same VM content, with the same labels.
  ##
  ## PLAT-50: a folder's children are listed only while the VM has it
  ## EXPANDED (`FilesystemVM.isExpanded`), as the desktop's tree renders
  ## them — the VM's own smart expansion opens single-child chains and the
  ## active file's ancestors; a click toggles one (`toggleFolder`).
  var entries: seq[FileTreeEntry] = @[]
  proc walk(n: FilesystemEntryNode; depth: int) =
    if n.text.len == 0 and n.children.len == 0:
      return
    let open = not n.isFolder or vm.isExpanded(n.path)
    entries.add FileTreeEntry(text: n.text, depth: depth,
                              isFolder: n.isFolder, path: n.path,
                              expanded: n.isFolder and open)
    if open:
      for c in n.children:
        walk(c, depth + 1)
  if not vm.isNil:
    walk(vm.rootEntry.val, 0)
  initFileTreeModel(entries)

proc learnExtent*(s: TuiSession) =
  ## Read the recording's extent and its seek targets ONCE, at open.
  ##
  ## Separated from `refresh` because it is the expensive read and it does not
  ## change: `ct/event-load`'s `maxRRTicks` is a property of the recording, and
  ## re-asking for it after every step would put a whole-log request inside the
  ## step latency CTUI-14 measures.
  # THE SHARED PRODUCERS (`native_host.loadRecordingPanes`) — the event log's
  # first window and the call trace, asked by the same call the GPUI front-end
  # makes, so neither front-end can be fed while the other is starved. Both
  # decode into the store; everything below reads the store.
  #
  # The call trace is the one PLAT-40 found starved: until the terminal asked
  # for it here, every caller of `requestAndLoadCalltrace` was under `tests/`,
  # `getCalltraceLines()` was empty on every real run, and `callBoundaries` was
  # silently `@[]` — "empty because nothing asked" and "empty because the
  # request failed" produced the same value. `PaneLoad` now says which.
  let loaded = s.session.loadRecordingPanes()
  # PLAT-52: the recorded program's terminal output — the Terminal Output
  # pane's lines and screen model (`terminal_output_source`, which GPUI asks
  # through too). A refusal leaves the pane in its loading state.
  try:
    discard s.session.loadTerminalOutput()
  except CatchableError:
    discard
  s.files = fileTreeModelOf(s.session.session.fileTreeVM)
  s.callTraceAsked = true
  var rows: seq[EventRow] = @[]
  for row in s.session.session.store.eventLog.rows.val:
    rows.add eventRowOf(row)
  # The extent comes off the STORE's own aggregate rather than by scanning
  # the rows again. `applyEventLogRows` raises `maxRRTicks` to the largest any
  # applied row reported and never lowers it, so a later page cannot shrink
  # the recording.
  if loaded.events:
    s.maxRRTicks = s.session.session.store.eventLog.maxRRTicks.val
  s.bounds = resolveBounds(s.timeline, rows, s.maxRRTicks)
  s.mutations = mutationTicks(rows)
  s.callBoundaries =
    if loaded.calltrace: boundariesFromCalltrace(s.session.getCalltraceLines())
    else: @[]

proc toggleBreakpoint*(s: TuiSession; path: string; line: int): bool =
  ## `:break` / `F9`: toggle through `HeadlessDebugSession.toggleBreakpoint`,
  ## THE producer of breakpoint rows both native front-ends share (PLAT-40).
  ## Until 2026-09-23 the terminal kept its own list here, and `:break`
  ## before that answered "no breakpoint service is wired".
  s.session.toggleBreakpoint(path, line)

proc points*(s: TuiSession): seq[SourcePoint] =
  ## The breakpoints and tracepoints the store holds, as the source pane's
  ## points — read from `store.pointList.rows`, which the shared producer
  ## writes, so the gutter shows what every other surface shows.
  sourcePointsOf(s.session.session.store.pointList.rows.val)

const
  CallTraceBuffer* = CALLTRACE_BUFFER
    ## Rows loaded above and below the ones the pane shows: the desktop's
    ## `CalltraceVM` pre-fetch (`calltrace_vm.CALLTRACE_BUFFER`), so a step of
    ## a line or a half page usually needs no request at all.

proc callTraceModelOf(s: TuiSession; rt: TuiRuntime): CallTraceModel =
  ## The pane's model over the section the store holds, at the current stop,
  ## keeping the reader's scroll position and whether the pane follows the
  ## current call.
  let store = s.session.session.store
  var rows: seq[CallTraceRow] = @[]
  # PLAT-49 part B: each row carries the ViewModel's `CallRow` — its
  # arguments and return value from the store's `calltrace.args`, which the
  # shared decoder fills (`replay_data_store.applyCalltraceResponse`).
  let args = store.calltrace.args.val
  for line in store.calltrace.lines.val:
    let a = if line.callKey.len > 0 and line.callKey in args:
              args[line.callKey]
            else: @[]
    rows.add CallTraceRow(
      index: line.index,
      name: (if line.displayName.len > 0: line.displayName else: line.name),
      depth: line.depth, rrTicks: line.rrTicks,
      call: callRowOf(line, a))
  initCallTraceModel(rows, s.session.getCurrentRRTicks(), s.callTraceStack,
                     firstIndex = store.calltrace.startLineIndex.val,
                     total = int(store.calltrace.totalCallsCount.val),
                     scrollTop = rt.app.callTrace.scrollTop,
                     follow = not rt.app.callTraceScrolled)

proc pageCallTrace*(s: TuiSession; rt: TuiRuntime) =
  ## PLAT-47: **the call trace, a section at a time.** Build the pane's model
  ## from the section the store holds and, when the rows the pane shows are
  ## not all in it, load the section around them — the rows on screen plus
  ## `CallTraceBuffer` either side, through `ct/load-calltrace-section`, the
  ## request the desktop's `CalltraceVM` pages with — and build it again.
  ##
  ## So there is no cap on the trace: the store holds one section, the title
  ## counts the whole trace (`totalCallsCount`), and scrolling past the
  ## section loads the next. A row the store does not hold is drawn as
  ## loading, never as the end of the trace.
  var model = s.callTraceModelOf(rt)
  rt.app.callTrace = model
  if model.total == 0 or s.calltrace.isNil:
    return
  let body = rt.paneBodyRows(paneCalltrace)
  if body <= 0:
    return
  let top = model.visibleTop(body)
  let first = model.firstIndex.int
  let last = top + min(body, model.total - top)
  if top >= first and last <= first + model.rows.len:
    return
  let start = max(0, top - CallTraceBuffer)
  try:
    s.session.requestAndLoadCalltrace(
      startIndex = start.int64, height = body + 2 * CallTraceBuffer,
      depth = RecordingCalltraceDepth)
  except CatchableError:
    # The rows stay drawn as loading; the next scroll asks again.
    return
  rt.app.callTrace = s.callTraceModelOf(rt)
  if not rt.app.callTraceScrolled:
    return
  # The reader's position is kept exactly across the load.
  rt.app.callTrace.scrollTop = top

proc scratchpadModelOf*(vm: ScratchpadVM): ScratchpadPaneModel =
  ## PLAT-50: the Scratchpad ViewModel's rows as the pane's value.
  result = ScratchpadPaneModel(loaded: not vm.isNil)
  if vm.isNil:
    return
  for e in vm.entries.val:
    result.rows.add ScratchpadPaneRow(expression: e.expression,
                                      value: e.valueText)

proc refreshScratchpad(s: TuiSession; rt: TuiRuntime) =
  rt.app.scratchpad = scratchpadModelOf(s.session.session.scratchpadVM)

proc terminalOutputModelOf*(vm: TerminalOutputVM; ticks: uint64;
                            prior: TerminalOutputPaneModel):
                            TerminalOutputPaneModel =
  ## PLAT-52: the Terminal Output ViewModel at the stop `ticks`, as the pane's
  ## value — the line view's lines and the screen model, both the shared
  ## model's (`terminal_output_model`). The reading position (`scrollTop`,
  ## `follow`) and a held screen scrubber are the pane's own and are carried
  ## across stops (a drag moves the debugger, so it crosses many).
  result = TerminalOutputPaneModel(loaded: not vm.isNil, follow: prior.follow,
                                   scrollTop: prior.scrollTop,
                                   shownWrite: -1, currentLine: -1,
                                   # A drag of the screen's scrubber moves
                                   # the debugger live: it is still held
                                   # across the refresh each move makes.
                                   previewing: prior.previewing,
                                   scrubSent: prior.scrubSent)
  if vm.isNil:
    return
  result.loading = vm.initialLoad.val
  result.lines = vm.lines.val
  result.screen = vm.screen
  result.offered = vm.screenOffered.val
  result.view = vm.view.val
  result.currentTicks = ticks
  result.currentLine = lineOfTick(result.lines, ticks)
  if not vm.screen.isNil:
    result.shownWrite = vm.screen.writeAtTick(ticks)

proc refreshTerminalOutput*(s: TuiSession; rt: TuiRuntime) =
  rt.app.terminalOutput = terminalOutputModelOf(
    s.session.session.terminalOutputVM, s.session.getCurrentRRTicks(),
    rt.app.terminalOutput)

proc showViewedFile(s: TuiSession; rt: TuiRuntime)

proc refresh*(s: TuiSession; rt: TuiRuntime)

proc runTracepointSweep(s: TuiSession; rt: TuiRuntime;
                        request: TracepointRequest): int =
  ## PLAT-50: one tracepoint swept over the recording; its hits shown, the
  ## panes refreshed (the point list and the gutter carry it). Answers how
  ## many hits.
  inc s.tracepointsRun
  let hits = s.session.runTracepoints(@[TracepointSweepSpec(
    tracepointId: s.tracepointsRun - 1, path: request.path,
    line: request.line, expression: request.expression)])
  var text = ""
  for h in hits:
    var parts: seq[string] = @[]
    for (name, value) in h.values:
      parts.add name & " = " & value
    text.add "tick " & $h.rrTicks & "  " &
             (if h.errorMessage.len > 0: h.errorMessage
              else: parts.join(", ")) & "\n"
  rt.app.content = ContentOverlay(
    open: true,
    title: "tracepoint `" & request.expression & "` at " &
           request.path.extractFilename & ":" & $request.line & " — " &
           $hits.len & " hit(s)",
    text: (if text.len > 0: text else: "the line never ran"))
  s.refresh(rt)
  hits.len

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
  # The flow overlay reads the SAME facts GPUI's `editorSurfaceFor` reads —
  # `FlowVM.styledLines`, through `notTakenLinesOf` — and honours the same
  # `EditorVM.showFlowOverlay` toggle.
  let frames = framesFromStackTrace(s.stackBody())
  rt.app.callStack = callStackModelFor(frames, s.entryFile)
  # PLAT-47: THE CALL TRACE — the section of it the store holds, which the
  # pane pages through as the reader scrolls (`pageCallTrace`).
  s.callTraceStack = @[]
  for f in frames:
    s.callTraceStack.add f.name
  s.pageCallTrace(rt)
  rt.app.callTraceLoaded = s.callTraceAsked
  # PLAT-47: the replay's Files pane. Only when the pane holds nothing else —
  # Edit mode fills it with the project walk (`runtime.enterEdit…`), and a
  # stop must not replace that with the recording's tree.
  if rt.app.fileTree.isEmpty:
    rt.app.fileTree = s.files

  # THE LOCALS ARE LOADED BEFORE THE SOURCE MODEL IS BUILT, because the source
  # pane's inline values are read from them. Until 2026-09-23 the model was
  # built first and passed no values at all, so the shipped terminal drew no
  # inline value on any line (PLAT22-PG3's re-measurement found it).
  discard s.session.loadStopPanes()

  # The flow overlay reads the SAME facts GPUI's `editorSurfaceFor` reads —
  # `FlowVM.styledLines`, through `notTakenLinesOf` — and honours the same
  # `EditorVM.showFlowOverlay` toggle. The inline values come from the SAME
  # producer GPUI's editor uses — `editor_surface.inlineValuesOf` over
  # `StateVM`, presented at this medium's row budget — so the two native
  # editors cannot show two different sets of values for one stop.
  let editorVM = s.session.session.editorVM
  let flowVM = s.session.session.flowVM
  # PLAT-29: the locals were requested at a stop, and are drawn beside the
  # source only while the debugger is still at it — reconciled against the
  # store's stop timeline on the way to the pane. `loadStopPanes` above is
  # synchronous, so on this host the answer is always current by now; the
  # withheld arm is observed by `test_plat29_inline_values.nim`.
  let values = s.valueGate.installable(
    s.session.session.store,
    inlineValuesOf(s.state, tuiRowBudget(max(1, rt.width), false)))
  let notTaken =
    if editorVM.isNil or flowVM.isNil or not editorVM.showFlowOverlay.val: @[]
    else: notTakenLinesOf(flowVM.styledLines.val)
  rt.app.source = sourcePaneModelFor(
    s.source, s.session.session.store.degraded.sourceAvailability.val,
    points = s.points,
    notTakenLines = notTaken,
    inlineValues = values)
  # PLAT-50: A FILE OPENED FROM THE FILES PANE stays in the editor until the
  # debugger moves (`applyOutcome` clears `viewedFile` on every move).
  if rt.app.viewedFile.len > 0:
    s.showViewedFile(rt)

  # PLAT-40. The Points pane reads the same points the gutter just drew.
  rt.app.points = pointListPaneModelFor(s.points)

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
  let sess = s
  # PLAT-49 part B: THE COLUMNS ARE THE USER'S, not the stop's — the model is
  # rebuilt at every stop, and the columns shown, hidden and reordered
  # (`:column-*`, the omnibar's column commands) are carried across.
  let keptColumns = rt.app.eventLog.columns
  # PLAT-50: and so is the ORDER a header click chose — the pages are asked
  # for in it (read when a page is fetched, so a reorder applies at once).
  let keptOrder = rt.app.eventLog.order
  let runtime = rt
  rt.app.eventLog = eventLogModelFor(
    proc(offset, limit: int): EventPage =
      var rows: seq[EventRow] = @[]
      try:
        rows = sess.loadedEventRows(offset, limit, runtime.app.eventLog.order)
      except CatchableError:
        discard
      EventPage(rows: rows, atEnd: rows.len < limit),
    currentTick = tick, pageSize = EventLogPageSize)
  if keptColumns.order.len > 0:
    rt.app.eventLog.columns = keptColumns
  rt.app.eventLog.order = keptOrder
  s.refreshScratchpad(rt)
  s.refreshTerminalOutput(rt)
  rt.app.location = s.session.getCurrentFile() & ":" &
                    $s.session.getCurrentLine()
  # THE PANE DOES NOT FETCH WHILE IT PAINTS — `app/views/event_log.nim`'s
  # header states that as the rule that keeps painting a pure function of what
  # is held — so a caller that wants rows asks for them. A caller that forgets
  # gets `elrPending` rows, which is exactly what the first run of this loop
  # showed: five `…` lines under a `TRACEPOINTS loading` title.
  rt.app.eventLog.ensureWindow(0, EventLogPageSize)

  # PLAT-48: the top bar reads the transport ViewModel for which controls
  # are available, and the omnibar searches the session's files and the
  # call trace section the store now holds.
  rt.app.controls = s.controls
  rt.app.filesVM = s.session.session.fileTreeVM
  rt.app.store = s.session.session.store
  rt.app.refreshOmnibarIndex()

  rt.dispatcher = Dispatcher(
    controls: s.controls,
    timeline: s.timeline,
    calltrace: s.calltrace,
    state: s.state,
    origin: s.origin,
    originNav: s.originNav,
    services: CommandServices(
      setBreakpoint: proc(path: string; line: int): bool =
        sess.toggleBreakpoint(path, line),
      # PLAT-50: `:tracepoint <expr>` RUNS — the sweep over the whole
      # recording (`ct/run-tracepoints`), its hits shown over the body as the
      # desktop's tracepoint editor lists them under the line, the point on
      # the point list and in the gutter. Until now the shipped terminal
      # composed the request and said no sweep service was wired.
      runTracepoint: proc(request: TracepointRequest): int =
        sess.runTracepointSweep(runtime, request),
      setTheme: rt.themeService))
  rt.context = CommandContext(
    file: s.session.getCurrentFile(),
    line: s.session.getCurrentLine(),
    tick: tick,
    frameCount: frames.len,
    targets: targetsFor(s.bounds, s.callBoundaries, s.mutations),
    # A move rebuilds the Variables model with nothing selected; a click on
    # a row sets this (`runtime.routePaneClick`).
    selectedVariable: "",
    functions: @[])

proc showViewedFile(s: TuiSession; rt: TuiRuntime) =
  ## PLAT-50 (K17): the editor shows `rt.app.viewedFile` — a file the user
  ## clicked in the Files pane — read whole from the recording through the
  ## same source provider the stop's file comes from (generation 0, the
  ## recorded one), with its breakpoints in the gutter. The execution
  ## pointer is drawn only when the debugger is IN that file. The desktop
  ## opens such a file in a tab of its own (`FilesystemVM.openFile` →
  ## `openTab`); this editor has one tab, so the file takes it until the
  ## debugger next moves, as the desktop's editor then switches back to the
  ## location's file.
  let path = rt.app.viewedFile
  if path == s.source.path.val:
    rt.app.viewedFile = ""
    return
  var fetched = SourceFetch(status: sfsProviderUnavailable,
                            detail: "the provider callback never ran")
  s.provider.fetch(SourceLineRequest(path: path, sourceGeneration: 0,
                                     sourceDigest: "", firstLine: 1,
                                     lastLine: high(int32)),
                   proc(f: SourceFetch) = fetched = f)
  drainSourceCallbacks()
  if fetched.fileLines.len == 0 and fetched.lines.len == 0:
    rt.app.notification = "could not open " & path & ": " & fetched.detail
    rt.app.viewedFile = ""
    return
  let lines = if fetched.fileLines.len > 0: fetched.fileLines
              else: fetched.lines
  let top = if rt.app.source.path == path: max(1, rt.app.source.viewportTop)
            else: 1
  rt.app.source = initSourcePaneModel(
    path = path,
    revisionLabel = "@0",
    provenance = provenanceFor(savVerified),
    firstHeldLine = 1,
    heldLines = lines,
    totalLineCount = lines.len,
    viewportTop = top,
    executionLine = 0,
    marks = marksForFile(s.points, path),
    columnMarks = columnMarksForFile(s.points, path))
  rt.app.fileTree.openPath = path

proc setFlowOverlay*(s: TuiSession; shown: bool) =
  ## Show or hide the flow overlay for this session — `EditorVM`'s own toggle,
  ## the one the GPUI front-end's `--no-flow-overlay` sets too.
  if not s.session.session.editorVM.isNil:
    s.session.session.editorVM.showFlowOverlay.val = shown

proc toggleCallChildren*(s: TuiSession; rt: TuiRuntime; index: int64) =
  ## PLAT-49 part B: expand or collapse the children of the call at trace
  ## `index` — the desktop's toggle (`CalltraceVM.toggleExpandCallChildren`:
  ## `ct/expand-calls` or `ct/collapse-calls` for the call's key, then the
  ## section again) — and redraw the pane from the reloaded section.
  let store = s.session.session.store
  let at = index - store.calltrace.startLineIndex.val
  let lines = store.calltrace.lines.val
  if at < 0 or at >= lines.len.int64:
    return
  let line = lines[at.int]
  if not line.hasChildren:
    return
  let command = if line.isExpanded: "ct/collapse-calls" else: "ct/expand-calls"
  try:
    # FIRE AND FORGET, as the desktop's `backend.send` is: the engine sends
    # no response to `ct/expand-calls` / `ct/collapse-calls` (measured — a
    # blocking `sendDapRequest` never returned), only the changed section
    # the next load reads.
    s.session.backend.sendDapRequestNoResponse(command, %*{
      "callKey": line.callKey, "nonExpandedKind": 1, "count": 0})
    discard s.session.backend.drainEvents()
    let body = rt.paneBodyRows(paneCalltrace)
    let start = max(0, rt.app.callTrace.visibleTop(max(1, body)) -
                       CallTraceBuffer)
    s.session.requestAndLoadCalltrace(
      startIndex = start.int64, height = max(1, body) + 2 * CallTraceBuffer,
      depth = RecordingCalltraceDepth)
  except CatchableError as e:
    rt.app.notification = "could not " &
      (if line.isExpanded: "collapse" else: "expand") & " the call: " & e.msg
    return
  rt.app.callTrace = s.callTraceModelOf(rt)

proc describe*(s: TuiSession): string

proc noteWhere(s: TuiSession; rt: TuiRuntime) =
  ## PLAT-50: after a click moved the debugger, the status line says where it
  ## landed — as a step names what it did — instead of keeping the note of
  ## whatever happened before (it kept the startup's `main.py:1 tick 0`).
  rt.app.notification = s.describe()

proc moved(s: TuiSession; rt: TuiRuntime) =
  ## A click moved the debugger: the panes follow it, and the status line
  ## says where it landed.
  rt.app.viewedFile = ""
  s.refresh(rt)
  s.noteWhere(rt)

proc applyPaneClick(s: TuiSession; rt: TuiRuntime; c: PaneClickRequest) =
  ## PLAT-50: a click in a pane that needs the session — the shared
  ## operations of `headless_app/pane_clicks.ClickInventory`.
  let session = s.session
  case c.kind
  of pcNone: discard
  of pcVcsDiff, pcVcsCommit:
    discard   # the VCS source's (`vcs_source.applyClick`)
  of pcTerminalView:
    # PLAT-52: the Terminal Output's view toggle — the ViewModel's choice,
    # remembered for this recording (`native_host.loadRecordingPanes` wires
    # the memory).
    let vm = session.session.terminalOutputVM
    if not vm.isNil:
      vm.setView(if c.text == $tvScreen: tvScreen else: tvLines)
      if vm.view.val == tvLines and c.text == $tvScreen:
        rt.app.notification = "this recording's output drives no screen"
    s.refreshTerminalOutput(rt)
  of pcColumnBreakpoint:
    # K14: the desktop's Alt+click (`lineActionClickAt` →
    # `addColumnBreakpoint`).
    if session.setColumnBreakpoint(c.path, c.line, c.column):
      rt.app.notification = "a breakpoint at line " & $c.line & ", column " &
                            $c.column
    else:
      rt.app.notification = "the engine refused a breakpoint at " & c.path &
                            ":" & $c.line & ":" & $c.column
    s.refresh(rt)
  of pcCallJump:
    # K15 / the editor menu's call jumps (`ct/source-call-jump`).
    try:
      session.sourceCallJump(c.path, c.line, c.text, c.behaviour)
    except CatchableError as e:
      # The engine may have reached the line before finding no call there:
      # the panes follow wherever it is, then say why.
      rt.app.viewedFile = ""
      s.refresh(rt)
      rt.app.notification = "could not go to the call of " & c.text & ": " &
                            e.msg
      return
    s.moved(rt)
  of pcEventOrder:
    # K26: the engine orders the log (`ct/event-load`'s `sortKey`); the pane
    # pages through it in that order from the top.
    rt.app.eventLog.reorder(c.order)
    rt.app.eventLog.ensureWindow(0, EventLogPageSize)
    rt.app.notification =
      if c.order == RecordedEventOrder: "event log in recorded order"
      else: "event log ordered by " & eventLogColumnTitle(c.order.column) &
            (if c.order.ascending: ", ascending" else: ", descending")
  of pcScratchpadAdd:
    # K23 / K36: "Add value to scratchpad" / Ctrl+click / "Add all values".
    for (name, value) in c.values:
      session.addToScratchpad(name, value)
    s.refreshScratchpad(rt)
    rt.app.notification =
      if c.values.len == 1: "added " & c.values[0].name & " to the scratchpad"
      else: "added " & $c.values.len & " values to the scratchpad"
  of pcScratchpadRemove:
    # K33: the scratchpad's close button.
    let vm = session.session.scratchpadVM
    if not vm.isNil:
      vm.removeValue(int(c.index))
    s.refreshScratchpad(rt)
  of pcValueHistory:
    # K28: "Toggle value history" — the value's recorded history.
    let name = variablePathOf(c.path)
    try:
      let rows = session.loadValueHistory(name)
      var text = ""
      for r in rows:
        text.add $r.locationTicks & "  " & r.valueText & "\n"
      rt.app.content = ContentOverlay(
        open: true, title: "history of " & name & " (" & $rows.len &
                           " value" & (if rows.len == 1: "" else: "s") & ")",
        text: (if rows.len > 0: text else: "no recorded values"))
    except CatchableError as e:
      rt.app.notification = "no history for " & name & ": " & e.msg
  of pcValueOrigin:
    # K28: "Show value origin" — the chain the desktop's origin panel lists.
    let name = variablePathOf(c.path)
    try:
      let lines = session.loadValueOrigin(name).originHopLines
      rt.app.content = ContentOverlay(
        open: true, title: "origin of " & name,
        text: (if lines.len > 0: lines.join("\n")
               else: "no recorded origin for " & name))
    except CatchableError as e:
      rt.app.notification = "no origin for " & name & ": " & e.msg
  of pcOpenFile:
    # K17: the desktop's `FilesystemVM.openFile`.
    rt.app.viewedFile = c.path
    s.showViewedFile(rt)
    if rt.app.viewedFile.len > 0:
      rt.app.notification = "opened " & c.path
  of pcToggleFolder:
    # K18: the desktop's `FilesystemVM.toggleExpanded`.
    let vm = session.session.fileTreeVM
    if not vm.isNil:
      vm.toggleExpanded(c.path)
      let open = rt.app.fileTree.openPath
      s.files = fileTreeModelOf(vm)
      rt.app.fileTree = s.files
      rt.app.fileTree.openPath = open
  of pcToggleBreakpoint:
    # K10: the desktop's gutter click (`lineActionClick` → `toggleBreakpoint`).
    if not s.toggleBreakpoint(c.path, c.line):
      rt.app.notification = "the engine refused a breakpoint at " & c.path &
                            ":" & $c.line
    s.refresh(rt)
  of pcSetBreakpointEnabled:
    # K11: the desktop's gutter right-click (`enable` / `disable`).
    if session.setBreakpointEnabled(c.path, c.line, c.enabled):
      rt.app.notification = (if c.enabled: "enabled" else: "disabled") &
                            " the breakpoint at line " & $c.line
    s.refresh(rt)
  of pcLineJump:
    # K12 / K13: "Jump to line" / "Run to Cursor" / "Jump backward to line".
    try:
      session.sourceLineJump(c.path, c.line, c.behaviour)
    except CatchableError as e:
      rt.app.notification = "could not go to line " & $c.line & ": " & e.msg
      return
    s.moved(rt)
  of pcEventJump:
    # K24: the desktop's event-log row click (`ct/event-jump`).
    try:
      session.eventJump(EventLogEntry(content: c.text, rrTicks: c.tick,
                                      line: c.line, file: c.path,
                                      eventIndex: int(c.index)))
    except CatchableError as e:
      rt.app.notification = "could not go to the event: " & e.msg
      return
    rt.app.viewedFile = ""
    s.refresh(rt)
    s.noteWhere(rt)
  of pcDeleteBreakpoints:
    # K13's "Delete breakpoints in file" / "Delete ALL breakpoints".
    var paths: seq[string] = @[]
    for r in session.session.store.pointList.rows.val:
      if r.kind == PointKindBreakpoint and r.path notin paths and
         (c.path.len == 0 or r.path == c.path):
        paths.add r.path
    for p in paths:
      discard session.clearBreakpoints(p)
    rt.app.notification = "deleted the breakpoints " &
      (if c.path.len == 0: "in every file" else: "in " & c.path)
    s.refresh(rt)
  of pcSeek:
    # K30: the timeline's click (`TimelineVM.seek` → `ct/timeline-seek`,
    # the handler `ct/goto-ticks` reaches).
    try:
      session.gotoTick(c.tick)
    except CatchableError as e:
      rt.app.notification = "could not go to tick " & $c.tick & ": " & e.msg
      return
    rt.app.viewedFile = ""
    s.refresh(rt)
    s.noteWhere(rt)

const OriginWaitMs = 20_000
  ## How long `o` waits for the engine's origin chain.

proc applyOutcome*(s: TuiSession; rt: TuiRuntime; outcome: RuntimeOutcome) =
  ## What the host does with one token's outcome, in ONE place so the shipped
  ## loop (`main.nim`) and the suites that drive the host run the same rule: a
  ## navigation is pumped and then refreshed; a change to what the session
  ## holds without a move (a breakpoint) is refreshed and NOT pumped — a pump
  ## there would wait on a `stopped` event no engine sends.
  if outcome.paneClick.kind != pcNone:
    s.applyPaneClick(rt, outcome.paneClick)
  elif outcome.jumpsToCall:
    # PLAT-49 part B: a click on a call-trace row goes to that call, as the
    # desktop's click does (`CalltraceVM.doubleClickEntry`'s
    # `ct/calltrace-jump`); `calltraceJump` waits for the move itself.
    let store = s.session.session.store
    let at = outcome.callIndex - store.calltrace.startLineIndex.val
    let lines = store.calltrace.lines.val
    if at >= 0 and at < lines.len.int64:
      try:
        s.session.calltraceJumpByLine(lines[at.int])
      except CatchableError as e:
        rt.app.notification = "could not go to the call: " & e.msg
      rt.app.viewedFile = ""
      s.refresh(rt)
      s.noteWhere(rt)
  elif outcome.togglesCall:
    s.toggleCallChildren(rt, outcome.callIndex)
  elif outcome.awaitsOrigin:
    # PLAT-50: the chain `o` / `:origin` asked for — its event taken into
    # the Origin ViewModel, then the action run again to walk it. Bounded:
    # an engine that never answers leaves the note saying it is querying.
    var event: JsonNode = nil
    let saved = s.session.backend.bound
    if saved.timeoutMs == 0 or saved.timeoutMs > OriginWaitMs:
      s.session.backend.bound.timeoutMs = OriginWaitMs
    try:
      event = s.session.backend.waitForEvent(OriginEventName)
    except CatchableError:
      discard
    s.session.backend.bound = saved
    if event.isNil or applyOriginEvents(s.origin, @[event]) == 0:
      rt.app.notification = "no origin arrived for the query"
      return
    let again = rt.retryOrigin(outcome.originRetry)
    if not again.awaitsOrigin:
      s.applyOutcome(rt, again)
  elif outcome.awaitsMove:
    s.pumpMove()
    rt.app.viewedFile = ""
    s.refresh(rt)
  elif outcome.refreshesSession:
    s.refresh(rt)
  elif outcome.pagesCallTrace:
    s.pageCallTrace(rt)

proc disarmHandshakeInterrupt*(s: TuiSession) =
  ## Take the ESCAPE HATCH off the DAP channel now that the session is open,
  ## and leave the CLOCK on.
  ##
  ## The two halves of `DapReadBound` have different lifetimes and this is the
  ## line between them. Abandoning a read leaves the stream part way through a
  ## framed message, which `stdio_backend.DapStdioBackend.broken` turns into a
  ## declared death — correct during the handshake, where the next thing that
  ## happens is that the whole session is thrown away, and WRONG afterwards,
  ## where a keystroke would kill a working channel. Measured rather than
  ## reasoned about: with the hatch left armed, typing `nnq` at a live session
  ## consumed the `n` and the `q` inside `pumpMove`'s read, aborted it
  ## mid-message and left the front-end unable to answer anything.
  ##
  ## The clock stays because a mid-session stall would otherwise hang the loop
  ## with no input running at all — the very shape CTUI-14 exists to remove.
  ## When it fires the channel is declared dead, every later read fails fast,
  ## and the user keeps a terminal that answers `q`.
  if s.isNil or s.session.isNil or s.session.backend.isNil:
    return
  s.session.backend.bound.interruptFd = -1
  s.session.backend.bound.onInterrupt = nil

proc seekToStartupTick*(s: TuiSession; rt: TuiRuntime; tick: int64): string =
  ## §6.2's `--goto=<tick>`, applied ONCE before the first debugger frame.
  ##
  ## CTUI-14 owns the flag and CTUI-8 owns the seek, and this is the whole of
  ## the difference: it dispatches `kaSeekToTick` — the SAME action `:goto`
  ## resolves to and the same one `t <tick> Enter` reaches — through the same
  ## `dispatchAction`, so the flag cannot seek differently from the command.
  ## `interpreter.seekWithin` remains the only call site of
  ## `timeline_binding.seekTo`, which is what keeps "exactly one goto per
  ## action" a property a test can count.
  ##
  ## Returns the dispatcher's own detail line, which `main.nim` puts on the
  ## status bar: a clamp against the recording's bounds is reported there
  ## ("goto to tick 900 (clamped from 99999)") rather than silently obeyed.
  let outcome = dispatchAction(rt.dispatcher, rt.context, kaSeekToTick, $tick)
  if outcome.status == drDone:
    s.pumpMove()
    s.refresh(rt)
  outcome.detail

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
