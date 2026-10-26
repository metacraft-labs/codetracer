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
## `variablesModelFor` and CTUI-8's `eventLogModelFor`.
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
  waitForEvent, isClosed

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
import ../../viewmodel/pane_viewport   # HSF-V2: the pane's cells as a Viewport
import viewmodels/scratchpad_vm   # PLAT-50: the scratchpad pane
import viewmodels/search_results_vm   # PLAT-57: Find in Files
from ../../viewmodel/host/find_in_files import FindInFilesScope, pump
from std/unicode import runeLen
import ../../viewmodel/host/terminal_output_source   # PLAT-52
import ../app/call_stack_binding
import ../app/frame_viewer_binding
import ../app/runtime
import ../app/views/search_results_pane   # PLAT-57
import ../app/views/agent_activity_pane   # PLAT-54
import ../../viewmodel/host/native_agent_host   # PLAT-54: Agent Activity's host
from ../app/edit_binding import EditBuffer, moveCaretTo, caretLine, caretColumn   # the read-only document a result opens in
import ../app/source_binding
import ../app/timeline_binding
import ../app/variables_binding
import ../app/syntax/highlighter   # lexerContexts: the window's entry state
import ./native_host
import ./session_driver

export native_host

const
  SourceOverscan* = 6
    ## How many lines beyond the viewport `SourceVM` holds. CTUI-5's own
    ## number, kept so the shipped front-end fetches the window its Tier-1
    ## suites measured.
  EndedSessionNote* =
    "the debugging session has ended; open a recording to debug again"
    ## M76: what an entry point answers once *Stop* ended the session.
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
    frames*: FrameViewerVM
      ## PLAT-51: the frame viewer's ViewModel, when a producer opened one
      ## (PLAT-59 wires the producer; nil until then). The pane's own
      ## scrubber asks it for frames (`pcFrameSeek`).
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
    followedStop*: tuple[tick: uint64; path: string; line: int]
      ## M73 (#840): the stop whose execution line the source window last
      ## FOLLOWED (`serveSourceWindow`). A refresh at the same stop — a
      ## breakpoint set, a search run, a resize settled — serves the window
      ## where the user scrolled it instead of snapping it back to the
      ## pointer: following the pointer is what a STOP does (Monaco reveals
      ## the line on `ct/complete-move`, not on every repaint).
    followOwed*: bool
      ## The pane's height changed (`setViewportHeight`): the next refresh
      ## follows the pointer even at the same stop, as every refresh did
      ## before M73, so a shrunken pane does not leave it below the last row.
    tracepointsRun*: int
      ## PLAT-50: how many tracepoints `:tracepoint` swept (each its own id).
      ## PLAT-29. The inline values are drawn only when the locals they come
      ## from are about the stop the debugger is at — reconciled against the
      ## store's stop timeline (`viewmodels/inline_value_timeline`). Counts
      ## every draw; the store's `stops.report` counts every arrival.
    stopped: bool
      ## M76: *Stop* ended this session (`stop`) — its `replay-server` is
      ## gone and nothing here may ask it anything. Every entry point the
      ## host loop calls answers without touching the engine once this is
      ## set; the tab it was shown in survives as an edit tab.
    closed: bool
      ## `close` has run; a second call is a no-op.
    agent*: NativeAgentHost
      ## PLAT-54: Agent Activity's host — the desktop's `AgentActivityVM`
      ## over this session's store (so a live agent's session is the one
      ## this session's tab reports), a recorded session it was handed, and
      ## the files and recordings its cards open.

proc ended*(s: TuiSession): bool =
  ## M76: whether the session's replay has ended — by this host's *Stop*
  ## (`stop`), or by any other caller of the session's `DebugControlsVM`
  ## Stop (`invokeToolbarAction("stop")`, which `native_host` installs), whose
  ## closed channel is read here so no entry point writes to it afterwards.
  not s.isNil and (s.stopped or s.session.isNil or s.session.backend.isNil or
                   s.session.backend.isClosed)

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
  ##
  ## Raises `EngineStalledAfterOpenError` (a `DapStalledError`) when the engine
  ## completes the handshake and then goes quiet on the session's first
  ## request; a stall in the handshake itself is a plain `DapStalledError`.
  let sess = openLocalTrace(traceFolder, bound)
  # A STALL FROM HERE ON IS A STALL AFTER THE OPEN. `openLocalTrace` reached
  # the first stop (and raises `EngineStalledAfterOpenError` itself for the
  # requests it sends after it), so the engine read the recording; an engine
  # that goes quiet on what this builds — the flow overlay switched on below
  # — is reported in the same after-open terms, with its child closed here.
  try:
    let store = sess.session.store
    let src = createSourceVM(store, sess.session.editorVM)
    if not sess.session.editorVM.isNil:
      sess.session.editorVM.showFlowOverlay.val = FlowOverlayShownByDefault
    src.setOverscan(SourceOverscan)
    src.setViewport(src.viewport.withRows(max(1, viewportHeight)))
    var nav = new(OriginNavigator)
    nav[] = initOriginNavigator()
    # THE PANES READ THE SESSION'S VIEWMODELS — the ones
    # `initializePanelViewModels` built when the session attached — not a
    # second set over the same store (Shared-DOM-Front-Ends D1). A second
    # `StateVM` was what the inline values were drawn from while the stop
    # loader wrote the origin summaries into the session's. The origin chain is
    # not a panel VM; the session holds the one the host attaches.
    let panels = sess.session
    if panels.originChainVM.isNil:
      panels.attachOriginChainVM(createOriginChainVM(store))
    result = TuiSession(
      session: sess,
      source: src,
      calltrace: panels.calltraceVM,
      state: panels.stateVM,
      timeline: panels.timelineVM,
      events: panels.eventLogVM,
      controls: panels.debugControlsVM,
      origin: panels.originChainVM,
      provider: newCtfsSourceProvider(traceFolder, allowWorkingTree = false),
      lexerContexts: newLexerContextCache(),
      valueTimeline: initValueTimeline(),
      entryFile: sess.getCurrentFile(),
      bounds: TimelineBounds(),
      callBoundaries: @[],
      mutations: @[],
      maxRRTicks: 0'u64,
      originNav: nav,
      valueGate: InlineValueGate(),
      agent: newNativeAgentHost(store))
  except DapStalledError as e:
    sess.close()
    raise newException(EngineStalledAfterOpenError, e.msg, e)

proc close*(s: TuiSession) =
  ## Tear the session down. The source window is this host's; the panel
  ## ViewModels are the session's, and `session.close` disposes them with it.
  ##
  ## Idempotent: *Stop* closes a session that the loop's teardown closes
  ## again on the way out.
  if s.isNil or s.closed:
    return
  s.closed = true
  s.agent.close()
  s.source.dispose()
  s.session.close()

proc stop*(s: TuiSession; rt: TuiRuntime): NativeStopOutcome =
  ## M76: THE TERMINAL'S STOP, the host half (Debugger-Controls.md § "Ending
  ## a session from inside it"). The runtime already put the workspace in
  ## Edit mode (requirement 1, `runtime.stopDebugging`); this ends the replay
  ## — the SDK session disposed, the `replay-server` child terminated
  ## (`native_host.stopThroughControls`: the session's `DebugControlsVM`
  ## Stop, shared with GPUI; requirement 2) —
  ## and makes the runtime forget the session, so the tab that showed it is
  ## an edit tab like one that never ran (requirement 3): no recording name,
  ## no engine behind the dispatcher, empty debugger panes. Opening a
  ## recording, or `Ctrl+F5` onto the empty debugger, is the ordinary route
  ## from there.
  if s.isNil:
    return NativeStopOutcome(pid: -1, message: "there is no debugging session")
  if s.stopped:
    return NativeStopOutcome(pid: s.session.replayPid(),
                             message: "the debugging session had already ended")
  s.stopped = true
  if not s.closed:
    s.closed = true
    s.source.dispose()
  result = s.session.stopThroughControls()
  rt.forgetSession()
  # Requirement 1 for every route here — the menu and the chord made the
  # switch already (`runtime.stopDebugging`); a caller of the ViewModel's
  # Stop did not.
  rt.enterProductMode(pmEdit)
  rt.app.notification = "stopped the debugging session" &
    " — the tab is in Edit mode; open a recording to debug again"

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
  if s.ended:
    return
  s.source.setOverscan(SourceOverscan)
  s.source.setViewport(s.source.viewport.withRows(max(1, height)))
  s.followOwed = true

proc pumpMove*(s: TuiSession) =
  ## Consume the `stopped` + `ct/complete-move` pair a navigation command
  ## produces, and push the new position into the store.
  ##
  ## TOTAL: never raises. `waitForEvent` raises `ValueError` when its message
  ## budget runs out, and a front-end that let that escape would drop the
  ## terminal it was restoring on a command the engine merely declined. The
  ## caller sees an unchanged position instead, which is what the screen would
  ## show anyway.
  if s.ended:
    return
  discard s.session.settleMove()

proc serveSourceRequests(s: TuiSession; requests: seq[SourceLineRequest]) =
  ## Serve `requests` — what `SourceVM` said its window lacks — through the
  ## real provider.
  for request in requests:
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

proc serveSourceWindow(s: TuiSession; tick: uint64) =
  ## At a NEW stop (or after the pane's height changed), follow the execution
  ## pointer (`followAndRequest`: not at all while it is visible, centred when
  ## it is not); at the stop the window already followed, keep the window
  ## where it is. Then serve every line it lacks.
  ##
  ## M73 (#840): until M73 every refresh followed, which was harmless while
  ## nothing else could move the window. Now the user can, and a refresh that
  ## is not a move (a breakpoint toggled on a line the user scrolled to)
  ## snapped the window back to the pointer.
  let stop = (tick: tick, path: s.source.path.val,
              line: s.source.executionLine.val)
  if s.followOwed or stop != s.followedStop:
    s.followedStop = stop
    s.followOwed = false
    s.serveSourceRequests(s.source.followAndRequest())
  else:
    s.serveSourceRequests(s.source.requestMissing())

proc scrollSource*(s: TuiSession; rt: TuiRuntime; scroll: SourceScroll) =
  ## M73 (#840): what the user asked the source pane's window to do
  ## (`runtime.SourceScroll`), done to `SourceVM` — `scrollBy` / `scrollTo`,
  ## `centreOnExecutionPointer`, and the caret written into `EditorVM` and
  ## followed by `followCursor` — then the lines the window lacks served the
  ## way a stop's are (`requestMissing`, as `followAndRequest` ends), and the
  ## pane's model given the new window (`withSourceWindow`). The execution
  ## pointer is never touched.
  ##
  ## A FILE SHOWN WHOLE (PLAT-50's `viewedFile`: one opened from the Files
  ## pane or a Find in Files result) is not `SourceVM`'s: its model holds every
  ## line, so the same rules move its `viewportTop` directly.
  if scroll.kind == sskNone:
    return
  let rows = max(1, s.source.viewportHeight.val)
  if rt.app.viewedFile.len > 0:
    let m = rt.app.source
    rt.app.source.viewportTop =
      case scroll.kind
      of sskNone: m.viewportTop
      of sskBy: clampTop(m.viewportTop + scroll.delta, rows, m.totalLineCount)
      of sskTo: clampTop(scroll.top, rows, m.totalLineCount)
      of sskCentreOnPointer:
        topCentring(m.viewportTop, m.executionLine, rows, m.totalLineCount)
      of sskFollowCaret:
        topFollowingCursor(m.viewportTop, scroll.line, rows, m.totalLineCount)
    return
  # M76: after *Stop* the session's `SourceVM` is disposed and no engine
  # serves the lines it would request.
  if s.ended:
    return
  case scroll.kind
  of sskNone: discard
  of sskBy: s.source.scrollBy(scroll.delta)
  of sskTo: s.source.scrollTo(scroll.top)
  of sskCentreOnPointer: s.source.centreOnExecutionPointer()
  of sskFollowCaret:
    let editor = s.session.session.editorVM
    if editor.isNil:
      return
    editor.setCursor(scroll.line, scroll.column)
    s.source.followCursor()
  s.serveSourceRequests(s.source.requestMissing())
  rt.app.source = rt.app.source.withSourceWindow(s.source)

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

proc eventLogBodyRows(rt: TuiRuntime): int =
  ## HSF-V2: the rows the Event Log pane shows on the current screen (its
  ## layout rectangle, `paneBodyRows`), at least one.
  max(1, rt.paneBodyRows(paneEventLog))

proc eventLogPageRows(rt: TuiRuntime): int =
  ## HSF-V2: how many events one page of the pane holds — the window the
  ## shared policy asks for a pane of that height (`viewport.listWindow`:
  ## the rows shown and the lead below them), never a fixed number
  ## (UI-Data-Loading-Guidelines AP 6; it was 64).
  listWindow(Viewport(rows: rt.eventLogBodyRows)).count

proc loadedEventRows(s: TuiSession; offset, limit: int;
                     order = RecordedEventOrder): seq[EventRow] =
  ## The rows `[offset, offset + limit)` of the log in `order`, read OUT OF
  ## THE STORE after the pane's window is reported to the session's
  ## `EventLogVM` (`showEventLogWindow`, HSF-D6): the ViewModel asks for the
  ## window, naming the stop so the answer also says which row is "now", and
  ## the store holds the answer — the one place the rows live.
  s.session.showEventLogWindow(offset, limit, order)
  result = @[]
  let ev = s.session.session.store.eventLog
  let first = ev.loadedStart.val
  let held = ev.rows.val
  for i in offset ..< offset + limit:
    let at = i - first
    if at >= 0 and at < held.len:
      result.add eventRowOf(held[at])

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
  ##
  ## Raises `EngineStalledAfterOpenError` when the engine answers none of
  ## these requests for a whole budget: ONE budget, then the caller reports
  ## the stall in §8b's after-open terms. Until this raised, each request
  ## swallowed its own stall as a pane that did not load, so a silent engine
  ## cost one budget per request and was then reported, if at all, as a
  ## recording with empty panes.
  if s.ended:
    return
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
  let loaded =
    try:
      s.session.loadRecordingPanes(raiseOnStall = true)
    except DapStalledError as e:
      raise newException(EngineStalledAfterOpenError, e.msg, e)
  # PLAT-52: the recorded program's terminal output — the Terminal Output
  # pane's lines and screen model (`terminal_output_source`, which GPUI asks
  # through too). A refusal leaves the pane in its loading state.
  # Its lines are asked for when the pane first reports what it shows
  # (`refreshTerminalOutput`): the window, not every write (Q3).
  s.session.openTerminalOutput()
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
  result = initCallTraceModel(rows, s.session.getCurrentRRTicks(),
                              s.callTraceStack,
                              firstIndex = store.calltrace.startLineIndex.val,
                              total = int(store.calltrace.totalCallsCount.val),
                              scrollTop = rt.app.callTrace.scrollTop,
                              follow = not rt.app.callTraceScrolled,
                              # PLAT-51: where the debugger is in the WHOLE
                              # trace (the engine's): the scrubber's mark, and
                              # the check on a section's unprovable answer.
                              currentIndex =
                                int(store.calltrace.currentLineIndex.val))

proc pageCallTrace*(s: TuiSession; rt: TuiRuntime) =
  ## PLAT-47: **the call trace, a section at a time.** HSF-V2: the pane
  ## REPORTS what it shows — its body's rows, the row it is scrolled to, and
  ## the depth levels that fit across it (`pane_viewport.cellPaneViewport`) —
  ## and `CalltraceVM` asks for the window that viewport needs
  ## (`ct/load-calltrace-section`, the window policy every front-end shares),
  ## then the pane is built from the section the store holds.
  ##
  ## So there is no cap on the trace: the store holds one section, the title
  ## counts the whole trace (`totalCallsCount`), and scrolling past the
  ## section asks for the next. A row the store does not hold is drawn as
  ## loading, never as the end of the trace.
  if s.ended:
    return
  var model = s.callTraceModelOf(rt)
  rt.app.callTrace = model
  if s.calltrace.isNil:
    return
  if model.total == 0 and s.callTraceAsked:
    # The recording has no calls (`learnExtent` asked, the engine counted
    # none): the pane shows the call stack instead and has nothing to page
    # to, so it reports no window and the ViewModel asks for none.
    s.calltrace.setViewport(Viewport())
    return
  let body = rt.paneBodyRows(paneCalltrace)
  if body <= 0:
    return
  let top = model.visibleTop(body)
  let held = (model.firstIndex.int, model.rows.len)
  s.calltrace.setViewport(cellPaneViewport(
    body, rt.paneBodyCols(paneCalltrace), top,
    colsPerLevel = CallRowIndentCells))
  s.session.settle()
  let store = s.session.session.store
  if (store.calltrace.startLineIndex.val.int, store.calltrace.lines.val.len) ==
     held and model.total > 0:
    return
  inc rt.app.listScrubFetches
  rt.app.callTrace = s.callTraceModelOf(rt)
  if not rt.app.callTraceScrolled:
    return
  # The reader's position is kept exactly across the load — and a view the
  # scrubber put at the END stays at the end of the trace as re-counted.
  rt.app.callTrace.scrollTop =
    if rt.app.callTraceAtEnd: max(0, rt.app.callTrace.total - body)
    else: top

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
                                   scrubSent: prior.scrubSent,
                                   # PLAT-70: the horizontal view and the
                                   # widest line measured so far are the
                                   # pane's own, carried too.
                                   hview: prior.hview, widths: prior.widths,
                                   overflowMarkers: prior.overflowMarkers)
  if vm.isNil:
    return
  result.loading = vm.initialLoad.val
  result.lines = vm.lines.val
  result.windowed = vm.windowed
  result.linesStart = vm.linesStart.val
  result.total = vm.lineCount
  result.screen = vm.screen
  result.offered = vm.screenOffered.val
  result.view = vm.view.val
  result.currentTicks = ticks
  result.currentLine =
    if result.windowed: vm.currentLine() else: lineOfTick(result.lines, ticks)
  if not vm.screen.isNil:
    result.shownWrite = vm.screen.writeAtTick(ticks)
  # The output's identity is its ViewModel: another session's (a tab
  # switch) is another output, and is measured from nothing.
  result.measureContent(cast[int](vm))

proc terminalLinesRefetch(s: TuiSession):
    proc(m: TerminalOutputPaneModel; rows: int): TerminalOutputPaneModel =
  ## The pane's `refetch`: report the rows the line view shows from `m`'s
  ## position and adopt the window the engine answers. A following view's
  ## position depends on the current line, which the first answer names, so
  ## it is reported again until it holds still (twice at most in practice).
  let sess = s
  result = proc(m: TerminalOutputPaneModel; rows: int): TerminalOutputPaneModel =
    let vm = sess.session.session.terminalOutputVM
    result = m
    if vm.isNil or rows <= 0:
      return
    var reported = -1
    for _ in 0 ..< 3:
      let top = result.visibleTop(rows)
      if top == reported:
        break
      reported = top
      vm.showTerminalLines(Viewport(rows: rows, firstRow: top))
      result = terminalOutputModelOf(vm, sess.session.getCurrentRRTicks(),
                                     result)
      result.refetch = m.refetch
      result.writeOf = m.writeOf

proc refreshTerminalOutput*(s: TuiSession; rt: TuiRuntime) =
  if s.ended:
    return
  rt.app.terminalOutput = terminalOutputModelOf(
    s.session.session.terminalOutputVM, s.session.getCurrentRRTicks(),
    rt.app.terminalOutput)
  rt.app.terminalOutput.refetch = s.terminalLinesRefetch()
  let vm = s.session.session.terminalOutputVM
  if not vm.isNil:
    rt.app.terminalOutput.writeOf = proc(write: int): TerminalOutputEvent =
      vm.eventOf(write)
  # The line view holds the lines the pane shows at this position.
  rt.app.terminalOutput.ensureShown(rt.terminalOutputRows())

proc showViewedFile(s: TuiSession; rt: TuiRuntime; force = false)

# ---------------------------------------------------------------------------
# PLAT-57: Find in Files
# ---------------------------------------------------------------------------

proc searchModelOf*(vm: SearchResultsVM;
                    prior: SearchResultsPaneModel): SearchResultsPaneModel =
  ## The session's `SearchResultsVM` as the pane's value: the field, the
  ## toggles, where the search is, and the groups flattened into rows — every
  ## caption, count and highlight split the ViewModel's own. The reading
  ## position (`scrollTop`) is the pane's, kept while the query is.
  result = SearchResultsPaneModel(loaded: not vm.isNil, selected: -1)
  if vm.isNil:
    return
  result.query = vm.query.val
  let o = vm.options.val
  for which in SearchOption:
    result.options.add SearchPaneOption(
      operation: SearchOptionOperations[which],
      label: SearchOptionLabels[which], on: o.isOn(which))
  result.summary = vm.summaryText()
  result.empty = vm.emptyText(NativeSearchPrompt)
  result.selected = vm.selected.val
  for d in vm.displayRows():
    result.rows.add SearchPaneRow(
      kind: (if d.kind == sdFile: spFile else: spMatch), path: d.path,
      caption: d.caption, count: d.count, index: d.index, line: d.line,
      before: d.before, hit: d.hit, after: d.after)
  result.scrollTop = if prior.query == result.query: prior.scrollTop else: 0

proc refreshSearch*(s: TuiSession; rt: TuiRuntime) =
  rt.app.search = searchModelOf(s.session.session.searchResultsVM,
                                rt.app.search)

proc wireFindInFiles*(s: TuiSession) =
  ## The session's Find in Files searches go to the shared runner, over this
  ## recording's scope (`native_host.recordingSearchScope`).
  let folder = s.session.tracePath
  wireFindInFiles(s.session.session.searchResultsVM,
                  proc(): FindInFilesScope = recordingSearchScope(folder))

proc findInFiles*(s: TuiSession; rt: TuiRuntime; query: string): string =
  ## `:grep <query>`: the session's search (`SearchResultsVM.search`, which
  ## hands it to the runner). "" when it started, else why not.
  if s.ended:
    return EndedSessionNote
  let vm = s.session.session.searchResultsVM
  if vm.isNil:
    return "this session has no Find in Files"
  vm.search(query)
  s.refreshSearch(rt)
  ""

# ---------------------------------------------------------------------------
# PLAT-54: Agent Activity
# ---------------------------------------------------------------------------

proc agentModelOf*(host: NativeAgentHost;
                   prior: AgentPaneModel): AgentPaneModel =
  ## The session's `AgentActivityVM` as the pane's value: the shared feed's
  ## rows, the prompt (typed, or the desktop's placeholder), Send or Stop.
  ## The reading position (`scroll`) is the pane's own, kept.
  result = AgentPaneModel(loaded: not host.isNil, scroll: prior.scroll)
  if host.isNil:
    return
  result.rows = host.feedRows()
  let typed = host.vm.inputValue.val
  result.promptIsPlaceholder = typed.len == 0
  result.prompt = if typed.len > 0: typed else: promptPlaceholder(host.vm)
  result.working = host.vm.isLoading.val
  if not prior.loaded:
    result.scroll = initFeedScroll()

proc refreshAgent*(s: TuiSession; rt: TuiRuntime) =
  rt.app.agent = agentModelOf(s.agent, rt.app.agent)

proc pumpAgent*(s: TuiSession; rt: TuiRuntime): bool =
  ## Apply what a live agent sent since the last tick (the loop calls this
  ## on its idle tick); whether the pane's value changed.
  if s.isNil or s.agent.isNil:
    return false
  let polled = s.agent.poll()
  if not polled and not s.agent.changed:
    return false
  s.agent.changed = false
  let before = rt.app.agent
  s.refreshAgent(rt)
  if s.agent.message.len > 0:
    rt.app.notification = s.agent.message
    s.agent.message = ""
  rt.app.agent != before

proc agentPress*(s: TuiSession; rt: TuiRuntime; row, button: int): string =
  ## A press on Agent Activity row `row` (`button` -1 for the row itself).
  if s.isNil or s.agent.isNil:
    return "this session has no Agent Activity"
  let rows = rt.app.agent.rows
  if row < 0 or row >= rows.len:
    return ""
  let r = rows[row]
  let action = if button < 0: r.press
               elif button < r.buttons.len: r.buttons[button]
               else: AgentFeedAction()
  if action.kind == faNone:
    return ""
  discard s.agent.runFeed(r, action)
  s.agent.changed = false
  s.refreshAgent(rt)
  result = s.agent.message
  s.agent.message = ""

proc agentPrompt*(s: TuiSession; rt: TuiRuntime; text: string): string =
  if s.isNil or s.agent.isNil:
    return "this session has no Agent Activity"
  result = s.agent.sendPrompt(text)
  s.refreshAgent(rt)

proc agentStop*(s: TuiSession; rt: TuiRuntime): string =
  if s.isNil or s.agent.isNil:
    return ""
  s.agent.stopAgent()
  "the agent stops after its current turn"

proc pumpFindInFiles*(s: TuiSession; rt: TuiRuntime): bool =
  ## Advance the search in flight (the loop calls this on its idle tick);
  ## whether the pane's value changed.
  if s.ended:
    return false
  discard nativeFindInFiles.pump()
  let before = rt.app.search
  s.refreshSearch(rt)
  rt.app.search != before

proc showSearchResult*(s: TuiSession; rt: TuiRuntime; index: int): string =
  ## PLAT-57 (K35, `search.next-result`): result `index` selected and its file
  ## shown in the editor at its line, the match selected and the caret on it
  ## — read from the recording, as a file opened from the Files pane is; the
  ## recording position does not move (Editor-Pane.md: a Find-in-Files row
  ## click deliberately does not). "" when it opened, else why not.
  if s.ended:
    return EndedSessionNote
  let vm = s.session.session.searchResultsVM
  if vm.isNil:
    return "there are no search results"
  let rows = vm.results.val
  if index < 0 or index >= rows.len:
    return "there is no such search result"
  vm.selectResult(index)
  let row = rows[index]
  rt.app.viewedFile = row.path
  s.showViewedFile(rt, force = true)
  if rt.app.viewedFile.len == 0:
    s.refreshSearch(rt)
    return rt.app.notification
  let paneRows = max(1, rt.sourcePaneRows())
  rt.app.source.viewportTop = max(1, row.line - paneRows div 3)
  let column = if row.matchStart > 0 and row.matchStart <= row.text.len:
                 row.text[0 ..< row.matchStart].runeLen
               else: 0
  let buf = rt.debugBuffer()
  if not buf.isNil and buf.path == row.path:
    buf.moveCaretTo(row.line - 1, column)
    if row.matchLength > 0:
      let width = row.text[row.matchStart ..<
                           min(row.text.len,
                               row.matchStart + row.matchLength)].runeLen
      buf.doc.extendSelectionTo(row.line - 1, column + width)
    rt.app.caret = (buf.path, buf.caretLine, buf.caretColumn + 1)
  else:
    rt.app.caret = (row.path, row.line, column + 1)
  s.refreshSearch(rt)
  # The list keeps the selected row in view.
  let at = rt.app.search.rowOfResult(index)
  if at >= 0:
    let under = rt.paneBodyRows(paneSearch)
    rt.app.search.scrollTop = rt.app.search.revealRow(at, max(1, under - 3))
  rt.app.notification = "opened " & row.path & ":" & $row.line
  ""

proc showFileAt*(s: TuiSession; rt: TuiRuntime; path: string;
                 line, col: int): string =
  ## PLAT-55 (K35) in a replay's Debug mode: a Problems row's file shown in
  ## the editor at its line, the caret there — read from the recording, as a
  ## Find in Files result is (`showSearchResult`); the recording position
  ## does not move. "" when it opened, else why not.
  if s.ended:
    return EndedSessionNote
  rt.app.viewedFile = path
  s.showViewedFile(rt, force = true)
  if rt.app.viewedFile.len == 0:
    return if rt.app.notification.len > 0: rt.app.notification
           else: path & " is not in this recording"
  let paneRows = max(1, rt.sourcePaneRows())
  rt.app.source.viewportTop = max(1, line - paneRows div 3)
  let column = max(1, col) - 1
  let buf = rt.debugBuffer()
  if not buf.isNil and buf.path == path:
    buf.moveCaretTo(line - 1, column)
    rt.app.caret = (buf.path, buf.caretLine, buf.caretColumn + 1)
  else:
    rt.app.caret = (path, line, column + 1)
  ""

proc toggleSearchOption*(s: TuiSession; rt: TuiRuntime;
                         operation: string): string =
  ## One of Find in Files' toggles flipped by its operation
  ## (`search.toggle-case`, `-whole-word`, `-regex`) — a press on it, or its
  ## key in the field — and a search that ran runs again with it (the
  ## ViewModel's rule). The words the status line shows.
  if s.ended:
    return EndedSessionNote
  let vm = s.session.session.searchResultsVM
  if vm.isNil:
    return "this session has no Find in Files"
  let (known, which) = searchOptionOf(operation)
  if not known:
    return "`" & operation & "` is no Find in Files option"
  vm.toggleOption(which)
  s.refreshSearch(rt)
  SearchOptionTitles[which] & (if vm.options.val.isOn(which): " on" else: " off")

proc stepSearchResult*(s: TuiSession; rt: TuiRuntime; delta: int): string =
  ## `search.next-result` / `search.previous-result`: the next / previous
  ## result, wrapping (`SearchResultsVM.stepResult`), shown.
  if s.ended:
    return EndedSessionNote
  let vm = s.session.session.searchResultsVM
  if vm.isNil or vm.results.val.len == 0:
    return "there are no search results"
  s.showSearchResult(rt, vm.stepResult(delta))

proc refreshOrigins(s: TuiSession; rt: TuiRuntime) =
  ## PLAT-51: the origin chains open in the Variables pane, read at THIS stop
  ## (an origin is the current value's), one line per hop.
  var origins = initTable[string, seq[string]]()
  for path in rt.app.openOrigins:
    let name = variablePathOf(path)
    try:
      origins[path] = s.session.loadValueOrigin(name).originHopLines
    except CatchableError:
      origins[path] = @[]
  rt.app.variables.origins = origins

proc refresh*(s: TuiSession; rt: TuiRuntime)

proc showTracepointHits(s: TuiSession; rt: TuiRuntime;
                        hits: seq[TracepointSweepHit]; title: string) =
  ## A sweep's hits over the body, as the desktop's tracepoint editor lists
  ## them under the line — one `:tracepoint`'s, or the program menu's "Run
  ## All Tracepoints" (M76). The values of the hits the overlay shows are read
  ## as it scrolls (Q4).
  let sess = s.session
  var held = hits
  let text = sess.tracepointHitsText(held, 0)
  rt.app.content = ContentOverlay(
    refill: proc(top: int): string = sess.tracepointHitsText(held, top),
    open: true,
    title: title,
    text: (if text.len > 0: text else: "the line never ran"))
  if hits.len == 0:
    rt.app.content.refill = nil

proc runTracepointSweep(s: TuiSession; rt: TuiRuntime;
                        request: TracepointRequest): int =
  ## PLAT-50: one tracepoint swept over the recording; its hits shown, the
  ## panes refreshed (the point list and the gutter carry it). Answers how
  ## many hits.
  inc s.tracepointsRun
  var hits = s.session.runTracepoints(@[TracepointSweepSpec(
    tracepointId: s.tracepointsRun - 1, path: request.path,
    line: request.line, expression: request.expression)])
  s.showTracepointHits(rt, hits,
    "tracepoint `" & request.expression & "` at " &
    request.path.extractFilename & ":" & $request.line & " — " &
    $hits.len & " hit(s)")
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
  if s.ended:
    return
  let tick = s.session.getCurrentRRTicks()

  serveSourceWindow(s, tick)
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
  # THE FLOW'S VALUES ON EVERY LINE IT REACHED — the one rule GPUI's editor
  # draws too (`editor_surface.flowValuesByLine`), with the overlay.
  let flowValues = flowValuesByLine(
    flowVM, s.source.path.val, int(tick),
    not editorVM.isNil and editorVM.showFlowOverlay.val)
  rt.app.source = sourcePaneModelFor(
    s.source, s.session.session.store.degraded.sourceAvailability.val,
    points = s.points,
    notTakenLines = notTaken,
    inlineValues = values,
    lineValues = flowValues)
  # PLAT-50: A FILE OPENED FROM THE FILES PANE stays in the editor until the
  # debugger moves (`applyOutcome` clears `viewedFile` on every move).
  if rt.app.viewedFile.len > 0:
    s.showViewedFile(rt)

  # PLAT-40. The Points pane reads the same points the gutter just drew.
  rt.app.points = pointListPaneModelFor(s.points)
  # PLAT-57: Find in Files, this session's.
  s.refreshSearch(rt)

  let locals = s.session.getLocals()
  s.valueTimeline.observeStop(tick, locals)
  # M71 (#838): the pane's reading position is the reader's too — a click on
  # a history entry moves the debugger, and the reader stays where they were
  # in the history (the painter clamps it to the new stop's rows).
  # HSF-V2: the Variables pane REPORTS what it shows (its layout rectangle's
  # rows and columns, scrolled to the reader's row); the stop loader sizes the
  # locals it asks for at the next stop from it.
  if not s.state.isNil:
    s.state.setViewport(cellPaneViewport(
      rt.paneBodyRows(paneState), rt.paneBodyCols(paneState),
      rt.app.variables.scrollTop))
  rt.app.variables = variablesModelFor(s.state, s.valueTimeline, tick,
                                       tickLabel = "tick " & $tick,
                                       scrollTop = rt.app.variables.scrollTop)
  # PLAT-51: the pane's open histories and origins, its watches and the
  # name column's width — the user's, carried across stops.
  rt.app.variables.histories = rt.app.openHistories
  rt.app.variables.watches =
    if s.state.isNil: @[] else: s.state.watchExpressions.val
  rt.app.variables.nameCells = rt.app.variablesNameCells
  s.refreshOrigins(rt)

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
  # PLAT-51: and so is WHERE THE READER IS in the log — the scrubber moves the
  # view, a row click moves the debugger, and the view must not jump back to
  # the top because the debugger moved.
  let keptScroll = rt.app.eventLog.scrollTop
  let keptSelected = rt.app.eventLog.selected
  let runtime = rt
  rt.app.eventLog = eventLogModelFor(
    proc(offset, limit: int): EventPage =
      var rows: seq[EventRow] = @[]
      try:
        # PLAT-51: naming the stop's tick, so the answer also says which row
        # of the whole log is "now" — the scrubber's mark.
        rows = sess.loadedEventRows(offset, limit, runtime.app.eventLog.order)
      except CatchableError:
        discard
      let ev = sess.session.session.store.eventLog
      EventPage(rows: rows, atEnd: rows.len < limit,
                total: (if ev.totalReported.val: ev.recordsTotal.val
                        else: -1)),
    currentTick = tick, pageSize = rt.eventLogPageRows)
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
  rt.app.eventLog.ensureWindow(0, rt.eventLogBodyRows)
  rt.app.eventLog.current = s.session.session.store.eventLog.currentIndex.val
  if keptScroll > 0:
    rt.app.eventLog.scrollTop = event_log.clampScrollTop(
      keptScroll, rt.app.eventLog.knownTotal, rt.eventLogBodyRows)
    rt.app.eventLog.ensureWindow(rt.app.eventLog.scrollTop, rt.eventLogBodyRows)
  rt.app.eventLog.selected = keptSelected

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

proc recordedSourceText*(s: TuiSession; path: string):
    tuple[ok: bool, text, message: string] =
  ## PLAT-68: a file of the RECORDING, whole — the source provider's
  ## generation 0, what the Debug-mode editor shows — for the read-only
  ## document its keys act on (`runtime.debugBuffer`). The same fetch
  ## `showViewedFile` makes for a clicked file.
  var fetched = SourceFetch(status: sfsProviderUnavailable,
                            detail: "the provider callback never ran")
  s.provider.fetch(SourceLineRequest(path: path, sourceGeneration: 0,
                                     sourceDigest: "", firstLine: 1,
                                     lastLine: high(int32)),
                   proc(f: SourceFetch) = fetched = f)
  drainSourceCallbacks()
  let lines = if fetched.fileLines.len > 0: fetched.fileLines
              else: fetched.lines
  if lines.len == 0:
    return (false, "", "could not read " & path & ": " & fetched.detail)
  (true, lines.join("\n") & "\n", "")

proc showViewedFile(s: TuiSession; rt: TuiRuntime; force = false) =
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
  # The stop's own file is the editor's already — unless a caller FORCES the
  # whole file (a Find in Files result, PLAT-57, shown at a line the stop's
  # window may not hold), with the execution pointer where it is.
  let stopFile = path == s.source.path.val
  if stopFile and not force:
    rt.app.viewedFile = ""
    return
  let executionLine = if stopFile: s.source.executionLine.val else: 0
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
    executionLine = executionLine,
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
  ## `index` (`session_driver.toggleCallChildren`, the desktop's toggle) and
  ## redraw the pane from the section the pane shows, read again.
  if s.ended:
    return
  let why = s.session.toggleCallChildren(index)
  if why.len > 0:
    rt.app.notification = why
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
  of pcTestsRun, pcTestsRefresh, pcTestsOpen, pcTestsOpenIn:
    discard   # the Test Results source's (`test_results_source.applyClick`)
  of pcFrameSeek:
    # PLAT-51: the frame viewer's own scrubber (CodeTracer-TUI-Graphics.md
    # §4, Visual-Replay.md's Scrub Slider): the frame under the pointer,
    # requested while held (the ViewModel's request serial drops a stale
    # answer) and settled where it is released.
    applyFrameSeek(s.frames, rt.app.frameViewer, int(c.index))
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
    rt.app.eventLog.ensureWindow(0, rt.eventLogBodyRows)
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
    # K28 / K40 (PLAT-51): "Toggle value history" and the row's history
    # button — the history OPENS IN THE PANE, under the row, as the
    # desktop's does (`div.ct-history-inline-container`); a second toggle
    # closes it. Its entries are navigation rows (a click goes to the tick).
    if rt.app.openHistories.hasKey(c.path):
      rt.app.openHistories.del(c.path)
    else:
      let name = variablePathOf(c.path)
      try:
        var entries: seq[HistoryEntry] = @[]
        for r in session.loadValueHistory(name):
          entries.add HistoryEntry(ticks: uint64(max(0'i64, r.locationTicks)),
                                   value: r.valueText)
        rt.app.openHistories[c.path] = entries
      except CatchableError as e:
        rt.app.notification = "no history for " & name & ": " & e.msg
    rt.app.variables.histories = rt.app.openHistories
  of pcValueOrigin:
    # K28 / K41 (PLAT-51): "Show value origin" and the row's origin badge —
    # the chain OPENS IN THE PANE under the row (the desktop's
    # `div.ct-origin-inline-chain`), re-read at every stop.
    let at = rt.app.openOrigins.find(c.path)
    if at >= 0:
      rt.app.openOrigins.delete(at)
    else:
      rt.app.openOrigins.add c.path
    s.refreshOrigins(rt)
  of pcWatch:
    # PLAT-51: a watch added, removed or edited (the desktop's watch field
    # and row controls), on the session's StateVM: the Variables pane reads
    # it, and the stop loader sends its list with `ct/load-locals`, so the
    # engine evaluates the watch in the next locals load and the pane
    # re-reads the stop.
    let vm = s.state
    if not vm.isNil:
      case c.behaviour
      of "remove": vm.removeWatch(c.path)
      of "edit": vm.editWatch(c.path, c.text)
      else: vm.addWatch(c.text)
    s.refresh(rt)
  of pcSearchResult:
    # PLAT-57 (K35): the result opens at its line; the debugger stays.
    let why = s.showSearchResult(rt, int(c.index))
    if why.len > 0:
      rt.app.notification = why
  of pcSearchOption:
    # PLAT-57: a toggle flips (and a search that ran runs again with it —
    # the ViewModel's rule).
    rt.app.notification = s.toggleSearchOption(rt, c.text)
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
      let top = rt.app.fileTree.scrollTop
      s.files = fileTreeModelOf(vm)
      rt.app.fileTree = s.files
      rt.app.fileTree.openPath = open
      # M71 (#838): a folder opened or closed keeps the reader's place.
      rt.app.fileTree.scrollTop = top
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
    discard session.clearAllBreakpoints(c.path)
    rt.app.notification = "deleted the breakpoints " &
      (if c.path.len == 0: "in every file" else: "in " & c.path)
    s.refresh(rt)
  of pcPointMenu:
    # M76 (codetracer#843): the program menu's breakpoint and tracepoint
    # items, at the editor caret's line — the performer GPUI's menu calls
    # too (`session_driver.performPointMenuOp`).
    let op = pointMenuOpOf(c.text)
    var nextId = s.tracepointsRun
    let done = session.performPointMenuOp(op, c.path, c.line, nextId)
    s.tracepointsRun = nextId
    if op == pmoRunAllTracepoints and done.performed:
      s.showTracepointHits(rt, done.swept,
        "tracepoints: " & $done.sweptSpecs & " run — " & $done.swept.len &
        " hit(s)")
    s.refresh(rt)
    rt.app.notification = done.message
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

proc applyOutcome*(s: TuiSession; rt: TuiRuntime; outcome: RuntimeOutcome) =
  ## What the host does with one token's outcome. The session-level half —
  ## settling a move, going to a call, toggling its children, waiting for an
  ## origin chain — is `session_driver`'s, shared with GPUI and the pane
  ## server; this proc adds the terminal's half: the notification line, the
  ## viewed file and the panes rebuilt from the session. A change to what the
  ## session holds without a move (a breakpoint) is refreshed and NOT pumped —
  ## a pump there would wait on a `stopped` event no engine sends.
  ##
  ## M76: *Stop* (`outcome.stopsSession`) ends the session here (`stop`).
  ## Once it has, nothing below may reach the engine: a request that would
  ## need it is answered on the status line instead.
  if outcome.stopsSession:
    discard s.stop(rt)
    return
  # M73 (#840): the user moved the source window (the wheel over the editor,
  # its scroll keys, its vertical bar, or a caret that left the screen).
  # Never a move, so nothing else here is owed for it.
  if outcome.sourceScroll.kind != sskNone:
    s.scrollSource(rt, outcome.sourceScroll)
  if s.ended:
    if outcome.paneClick.kind != pcNone or outcome.jumpsToCall or
       outcome.togglesCall or outcome.awaitsOrigin or outcome.awaitsMove or
       outcome.refreshesSession:
      rt.app.notification = EndedSessionNote
    return
  if outcome.paneClick.kind != pcNone:
    s.applyPaneClick(rt, outcome.paneClick)
  elif outcome.jumpsToCall:
    # PLAT-49 part B: a click on a call-trace row goes to that call, as the
    # desktop's click does.
    let why = s.session.jumpToCall(outcome.callIndex)
    if why.len > 0:
      rt.app.notification = why
    rt.app.viewedFile = ""
    s.refresh(rt)
    s.noteWhere(rt)
  elif outcome.togglesCall:
    s.toggleCallChildren(rt, outcome.callIndex)
  elif outcome.awaitsOrigin:
    # PLAT-50: the chain `o` / `:origin` asked for — its event taken into
    # the Origin ViewModel, then the action run again to walk it. Bounded:
    # an engine that never answers leaves the note saying it is querying.
    let event = s.session.awaitOriginEvent()
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
  # THE LINE VIEW HOLDS WHAT THE PANE SHOWS after whatever this token did to
  # the layout — a tab switch that reveals it, a resize, a maximise. A no-op
  # while the window it shows is held (Viewport-Driven-Loading Q3).
  rt.app.terminalOutput.ensureShown(rt.terminalOutputRows())

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
  ## and the user keeps a terminal that answers `q`. It stays on ORDINARY
  ## requests: the operations that are silent by design until they finish (a
  ## tracepoint sweep, a step or `continue`) are a slow engine, not a stopped
  ## one, and `allowSlowOperations` exempts them.
  if s.isNil or s.session.isNil or s.session.backend.isNil:
    return
  s.session.backend.bound.interruptFd = -1
  s.session.backend.bound.onInterrupt = nil

proc allowSlowOperations*(s: TuiSession) =
  ## Let the engine operations that are silent BY DESIGN take as long as they
  ## take, now that somebody is watching this session.
  ##
  ## The clock stays on every ordinary request (`disarmHandshakeInterrupt`
  ## says why), so a mid-session stall on one still fails by name and the
  ## terminal still answers `q`. But some operations send nothing until they
  ## are finished: a tracepoint sweep sends nothing until the whole recording
  ## is swept, and a step or `continue` is answered only once the move lands.
  ## Over a large recording either can be silent for longer than any budget,
  ## and that engine is SLOW, not stopped. Under the clock such a sweep was
  ## reported as a failure, and its answer — which still arrived — was then
  ## read as the answer to the next sweep. So those reads are untimed here
  ## (`DapReadBound.untimedOperations`); an engine that exits still ends them.
  ##
  ## Called on the INTERACTIVE paths only — the tty session, each session a
  ## "+" opens, the editor's pane server — and not by `--headless`, which
  ## nobody watches: there a silent operation stays a stall, and the channel
  ## is then declared dead so its late answer is never misread
  ## (codetracer-pm `spec/CLI/ct/ui-selection.md` §8b).
  if s.isNil or s.session.isNil or s.session.backend.isNil:
    return
  s.session.backend.bound.untimedOperations = true

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
  if s.ended:
    return EndedSessionNote
  let outcome = dispatchAction(rt.dispatcher, rt.context, kaSeekToTick, $tick)
  if outcome.status == drDone:
    s.pumpMove()
    s.refresh(rt)
  outcome.detail

proc header*(s: TuiSession; rt: TuiRuntime) =
  ## Point the runtime at this session — the one shown: the trace's NAME
  ## where §3.1's header row reads it, and (PLAT-68) the reader the Debug-mode
  ## editor opens its read-only documents with, from THIS recording. Separate
  ## from `refresh` because neither changes and `refresh` runs on every step.
  if s.ended:
    return
  let name = extractFilename(s.session.tracePath.strip(chars = {'/'}))
  rt.app.title = name
  rt.app.traceName = name
  rt.editServices.readSource = proc(path: string): EditReadResult =
    let read = s.recordedSourceText(path)
    EditReadResult(ok: read.ok, text: read.text, message: read.message)
  # M76: the session's `DebugControlsVM` Stop (installed by `native_host`)
  # does this terminal's half too — Edit mode, the runtime forgetting the
  # session — whichever caller reaches it, so a Stop from anywhere leaves
  # no part of the front end pointing at the ended engine. `stop` is
  # re-entrant-safe: it marks the session stopped before it ends the replay.
  let sess = s
  s.session.installNativeStop(proc() = discard sess.stop(rt))

proc describe*(s: TuiSession): string =
  ## For a diagnostic: where the engine is and what the recording's extent is.
  if s.ended:
    return EndedSessionNote
  s.session.getCurrentFile() & ":" & $s.session.getCurrentLine() &
    "  tick " & $s.session.getCurrentRRTicks() &
    "  extent " & (if s.bounds.known: $s.bounds.minTick & ".." & $s.bounds.maxTick
                   else: "unknown")
