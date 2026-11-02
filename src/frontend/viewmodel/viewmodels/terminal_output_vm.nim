## viewmodels/terminal_output_vm.nim
##
## TerminalOutputVM — the ViewModel of the Terminal Output pane, read by all
## three front-ends (the desktop's IsoNim view, the terminal's pane, the GPUI
## window's pane).
##
## Spec: `codetracer-specs/spec/GUI/Core-Panes/Terminal-Output-Pane.md`.
##
## Holds reactive state for:
## - the recorded writes (``events``) and, derived from them by the shared
##   model (`terminal_output_model`), the LINE VIEW's lines — each a sequence
##   of fragments carrying their text and their decoded SGR attributes as data
##   (PLAT-52: until then the desktop's `ansi_up` HTML) — and the SCREEN
##   VIEW's emulator model, with its snapshots and marks;
## - whether the pane is still waiting for its first load;
## - the debugger's current ``rrTicks`` (fragments are past / active / future
##   against it, and the screen view shows the screen as of it);
## - which view is shown (lines or screen), remembered per recording;
## - the built-in scrubber, which is REAL-TIME (the user, 2026-10-06):
##   dragging it moves the recording position (`ct/event-jump`) to each write
##   it crosses, and the screen shows the write under the pointer while that
##   move is in flight.
##
## Derives:
## - ``isLoading`` / ``isEmpty`` — the two overlays;
## - ``screenOffered`` — the output contains screen control;
## - ``shownWrite`` — the write whose screen the screen view shows (the
##   write under a dragged scrubber, else the last write at or before the
##   current tick).
##
## Usage::
##
##   let vm = createTerminalOutputVM(store)
##   vm.setEvents(@[TerminalOutputEvent(content: "\e[31mred\e[0m\n",
##                                      rrTicks: 5)])
##   echo vm.lines.val[0].fragments[0].style.fg   # indexed 1
##
## THE LINE VIEW IS WINDOWED (Viewport-Driven-Loading V1, Decided Q3). A view
## reports what it shows (`setViewport`, in lines), and the ViewModel asks the
## engine for that window of LINES — `ct/load-terminal-lines`, the 20/10
## buffers every windowed list uses — with the total; `lines` then holds the
## window, from `linesStart`. Only the screen view loads every write
## (`ct/load-terminal`), because its scrubber spans all of them, and only once
## it is shown. A host that never reports a viewport may still hand the whole
## output to `setEvents` (the headless suites, a recording opened offline);
## then `lines` is every line.

import std/[json, options, tables]
import ./action_sink

import isonim/core/[signals, computation, owner, batch, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
import ../viewport
import ./terminal_output_model

export viewport

export terminal_output_model

type
  TerminalOutputVM* = ref object of ViewModel
    actionSink*: ActionSink
      ## Set in a mirror session: user actions go to the primary
      ## (`action_sink`); nil on a primary.
    store*: ReplayDataStore

    # -- Mutable state --
    events*: Signal[seq[TerminalOutputEvent]]
      ## The recorded writes, in order.
    lines*: Signal[seq[TerminalLine]]
      ## The line view (derived from ``events`` by ``setEvents``; set directly
      ## by ``setLines``).
    initialLoad*: Signal[bool]
      ## True until the first load lands.
    currentRRTicks*: Signal[uint64]
      ## The debugger's current position.
    view*: Signal[TerminalView]
      ## The view shown.
    scrubPreview*: Signal[int]
      ## The write a dragged scrubber is on, -1 when none is dragged.
    scrubSent*: int
      ## The write the drag last moved the recording position to, so a drag
      ## sends one jump per write it crosses, not one per pointer event.
    scrubHeld*: bool
      ## The scrubber is held (a plain field: the move's landing reads it
      ## inside the store's effect, which must not subscribe to it).
    scrubInFlight*: bool
      ## A drag's move was sent and the recording position has not moved
      ## since: the next write the pointer reaches waits in ``scrubPending``.
    scrubPending*: int
      ## The newest write the pointer reached while a move was in flight, -1
      ## for none. It supersedes every older one: a fast drag across many
      ## writes queues ONE move behind the one the engine is making.
    lastTicks*: uint64
      ## The recording position as last seen (a plain field, read where a
      ## signal read would subscribe).
    screenVersion*: Signal[int]
      ## Bumped whenever ``screen`` is rebuilt, so readers of it re-run.
    screen*: TerminalScreenModel
      ## The screen view's model over ``events`` (nil before a load).
    recordingKey*: string
      ## What the view choice is remembered under (the recording's path).
    viewMemory*: Table[string, TerminalView]
      ## The choices remembered so far, by recording. A host loads it at start
      ## and persists it from ``onViewChosen``.
    viewChosen*: bool
      ## The user chose the view for this recording.
    onViewChosen*: proc(memory: Table[string, TerminalView]) {.closure.}
      ## Called after the user chose a view, with the updated memory.

    # -- The line window (Viewport-Driven-Loading Q3) --
    viewport*: Signal[Viewport]
      ## What the view shows, in lines (`setViewport`).
    viewportGate: ViewportGate
    linesStart*: Signal[int]
      ## The output line `lines.val[0]` is.
    linesTotal*: Signal[int]
      ## How many lines the whole output has; -1 until the engine answered a
      ## window (`lines` is then the whole output, from `setEvents`).
    windowCurrentLine*: Signal[int]
      ## The engine's line of the current position (windowed only).
    offeredByEngine*: Signal[bool]
      ## The engine's answer to "does the output drive a screen", known
      ## before the writes are loaded.
    writesTotal*: Signal[int]
      ## How many writes the output has (the engine's count).
    namedWrites: Table[int, TerminalOutputEvent]
      ## The writes the held lines name, by write index, without their text.
    writesAsked: bool
      ## The screen view's `ct/load-terminal` was sent.
    lineTicks: uint64
      ## The tick the current line was last asked for (a window's answer
      ## names it too).

    # -- Derived state --
    isLoading*: Memo[bool]
    isEmpty*: Memo[bool]
    screenOffered*: Memo[bool]
    shownWrite*: Memo[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc windowed*(vm: TerminalOutputVM): bool =
  ## The engine serves the line view by window.
  vm.linesTotal.val >= 0

proc lineCount*(vm: TerminalOutputVM): int =
  ## How many lines the output has — the line view's scroll range.
  if vm.windowed: vm.linesTotal.val else: vm.lines.val.len

proc heldLine*(vm: TerminalOutputVM; index: int): Option[TerminalLine] =
  ## Output line `index`, when it is held.
  let at = index - (if vm.windowed: vm.linesStart.val else: 0)
  let held = vm.lines.val
  if at >= 0 and at < held.len: some(held[at]) else: none(TerminalLine)

proc setViewport*(vm: TerminalOutputVM; v: Viewport) =
  ## The lines the view shows — the ONE way a view tells this ViewModel what
  ## it shows (Viewport-Driven-Loading V1). Debounced on the store's
  ## `viewportScheduler`; the window is then asked for.
  # A mirror reports its measured size to the primary and keeps it too.
  discard vm.actionSink.forwards("viewport", "set", %*{
    "pane": "terminalOutput", "rows": v.rows, "depth": v.cols,
    "firstRow": v.firstRow})
  vm.viewportGate.submit(v)

proc setLines*(vm: TerminalOutputVM; lines: seq[TerminalLine]) =
  ## Replace the rendered lines wholesale (a caller that built them itself).
  vm.initialLoad.val = false
  vm.lines.val = lines

proc pickView(vm: TerminalOutputVM; offered: bool) =
  ## The view a newly loaded output opens in: the one the user chose for this
  ## recording if they did, else the screen view when the output drives a
  ## screen.
  if vm.recordingKey.len > 0 and vm.recordingKey in vm.viewMemory:
    vm.viewChosen = true
    vm.view.val = (if offered: vm.viewMemory[vm.recordingKey] else: tvLines)
  else:
    vm.viewChosen = false
    vm.view.val = defaultViewFor(offered)

proc applyLinesWindow*(vm: TerminalOutputVM; w: TerminalLinesWindow;
                       askedAtTicks: uint64) =
  ## Apply one `ct/load-terminal-lines` answer: the window, the totals, and
  ## the current line when the answer is for the position the debugger is
  ## still at. The first answer picks the view.
  if not w.ok:
    return
  let first = not vm.windowed
  batch(proc() =
    for named in w.namedWrites:
      vm.namedWrites[named.eventIndex] = named
    vm.linesStart.val = w.start
    vm.linesTotal.val = w.total
    vm.writesTotal.val = w.writes
    vm.offeredByEngine.val = w.screenOffered
    vm.lines.val = w.lines
    if askedAtTicks == vm.currentRRTicks.val:
      vm.windowCurrentLine.val = w.currentLine
      vm.lineTicks = askedAtTicks
    vm.initialLoad.val = false
    if first:
      vm.pickView(w.screenOffered))

proc setEvents*(vm: TerminalOutputVM; events: seq[TerminalOutputEvent];
                cols = DefaultScreenCols; rows = DefaultScreenRows) =
  ## The recorded writes arrived: build the line view and the screen model
  ## from them, and pick the view — the one the user chose for this recording
  ## if they did, else the screen view when the output drives a screen.
  vm.screen = newTerminalScreenModel(events, cols, rows)
  vm.events.val = events
  vm.scrubPreview.val = -1
  vm.scrubSent = -1
  vm.scrubHeld = false
  vm.scrubInFlight = false
  vm.scrubPending = -1
  if vm.windowed:
    # The screen view's writes: the line window and the view stay.
    vm.screenVersion.val = vm.screenVersion.val + 1
    return
  vm.initialLoad.val = false
  vm.lines.val = buildTerminalLines(events)
  vm.pickView(vm.screen.offered)
  vm.screenVersion.val = vm.screenVersion.val + 1

proc clearLines*(vm: TerminalOutputVM) =
  ## Reset to the pre-load state (a new trace).
  vm.initialLoad.val = true
  vm.screen = nil
  vm.events.val = @[]
  vm.lines.val = @[]
  vm.linesStart.val = 0
  vm.linesTotal.val = -1
  vm.windowCurrentLine.val = -1
  vm.offeredByEngine.val = false
  vm.writesTotal.val = 0
  vm.namedWrites.clear()
  vm.writesAsked = false
  vm.scrubPreview.val = -1
  vm.scrubSent = -1
  vm.scrubHeld = false
  vm.scrubInFlight = false
  vm.scrubPending = -1
  vm.screenVersion.val = vm.screenVersion.val + 1

proc landScrub(vm: TerminalOutputVM; rrTicks: uint64)

proc setCurrentRRTicks*(vm: TerminalOutputVM; rrTicks: uint64) =
  ## Update the debugger position so fragment tenses and the screen refresh.
  vm.currentRRTicks.val = rrTicks
  vm.landScrub(rrTicks)

proc setRecordingKey*(vm: TerminalOutputVM; key: string;
                      memory: Table[string, TerminalView]) =
  ## Which recording this is, and what was remembered so far.
  vm.recordingKey = key
  vm.viewMemory = memory

proc setView*(vm: TerminalOutputVM; view: TerminalView) =
  ## The user chose a view. The screen view is offered only for output with
  ## screen control; asking for it otherwise keeps the line view.
  if vm.actionSink.forwards("terminalOutput", "setView",
      %*{"view": sinkArg(view)}):
    return
  let v = if view == tvScreen and not vm.screenOffered.val: tvLines else: view
  vm.view.val = v
  vm.viewChosen = true
  if vm.recordingKey.len > 0:
    vm.viewMemory[vm.recordingKey] = v
    if not vm.onViewChosen.isNil:
      vm.onViewChosen(vm.viewMemory)

proc toggleView*(vm: TerminalOutputVM) =
  if vm.actionSink.forwards("terminalOutput", "toggleView", %*{}):
    return
  vm.setView(if vm.view.val == tvLines: tvScreen else: tvLines)

proc eventOf*(vm: TerminalOutputVM; eventIndex: int): TerminalOutputEvent =
  ## The write with this index (an empty one when there is none).
  let evs = vm.events.val
  if eventIndex >= 0 and eventIndex < evs.len and
     evs[eventIndex].eventIndex == eventIndex:
    return evs[eventIndex]
  for e in evs:
    if e.eventIndex == eventIndex:
      return e
  if eventIndex in vm.namedWrites:
    return vm.namedWrites[eventIndex]
  TerminalOutputEvent(eventIndex: -1)

proc eventJumpArgs*(ev: TerminalOutputEvent): JsonNode =
  ## The `ct/event-jump` request for one write (a `ProgramEvent` of kind
  ## `Write`). `kind` is `EventLogKind`'s integer (Write = 0); the engine
  ## reads `kind` and `directLocationRRTicks`, and requires the other keys.
  %*{
    "kind": 0,
    "content": "",
    "highLevelPath": ev.path,
    "highLevelLine": ev.line,
    "metadata": "",
    "maxRRTicks": 0,
    "directLocationRRTicks": ev.rrTicks,
    "eventIndex": ev.logIndex,
  }

proc jumpToEvent*(vm: TerminalOutputVM; eventIndex: int) =
  ## Go to the moment write `eventIndex` was produced (K32): the fragment's
  ## write, through `ct/event-jump`. A no-op for an unknown index.
  if vm.actionSink.forwards("terminalOutput", "jumpToEvent",
      %*{"eventIndex": eventIndex}):
    return
  var ev = vm.eventOf(eventIndex)
  if ev.eventIndex < 0:
    # Lines set directly (no events): the fragment knows its tick.
    for line in vm.lines.val:
      for fragment in line.fragments:
        if fragment.eventIndex == eventIndex:
          ev = TerminalOutputEvent(eventIndex: eventIndex,
                                   logIndex: eventIndex,
                                   rrTicks: fragment.rrTicks)
    if ev.eventIndex < 0:
      return
  vm.store.requestHistoricalNavigation("ct/event-jump", eventJumpArgs(ev))

proc jumpToWrite*(vm: TerminalOutputVM; write: int) =
  ## Move the recording position to write `write` (the scrubber's release,
  ## the step keys).
  if vm.actionSink.forwards("terminalOutput", "jumpToWrite",
      %*{"write": write}):
    return
  let evs = vm.events.val
  if write < 0 or write >= evs.len:
    return
  vm.jumpToEvent(evs[write].eventIndex)

proc sendScrub(vm: TerminalOutputVM; write: int) =
  ## Move the recording position to write `write` for the scrubber. Reads no
  ## signal (it runs inside the store's effect when a move lands). A move to
  ## the tick the debugger is already at changes nothing a landing could be
  ## seen by, so it is not left in flight.
  vm.scrubSent = write
  if vm.screen.isNil or write < 0 or write >= vm.screen.writes.len:
    return
  let ev = vm.screen.writes[write]
  vm.scrubInFlight = ev.rrTicks != vm.lastTicks
  vm.store.requestHistoricalNavigation("ct/event-jump", eventJumpArgs(ev))

proc landScrub(vm: TerminalOutputVM; rrTicks: uint64) =
  ## The recording position moved to `rrTicks`: the move in flight landed,
  ## so the newest write the pointer reached meanwhile is sent now.
  let moved = rrTicks != vm.lastTicks
  vm.lastTicks = rrTicks
  if not moved or not vm.scrubInFlight:
    return
  vm.scrubInFlight = false
  let pending = vm.scrubPending
  vm.scrubPending = -1
  if pending >= 0 and pending != vm.scrubSent:
    vm.sendScrub(pending)
  if not vm.scrubHeld and not vm.scrubInFlight:
    vm.scrubSent = -1

proc scrubTo*(vm: TerminalOutputVM; write: int) =
  ## The screen's scrubber is dragged onto write `write`. The scrubber is
  ## REAL-TIME (the user, 2026-10-06; Terminal-Output-Pane.md §3): the drag
  ## moves the recording position live, so every other pane follows as the
  ## thumb moves. Coalesced: a jump is sent only when the write under the
  ## pointer changes, at most one is in flight, and a write reached while one
  ## is in flight waits — superseded by any newer one — until it lands.
  ## `scrubPreview` shows the write under the pointer meanwhile.
  if vm.actionSink.forwards("terminalOutput", "scrubTo",
      %*{"write": write}):
    return
  let n = vm.events.val.len
  if n == 0:
    return
  let w = max(0, min(n - 1, write))
  vm.scrubPreview.val = w
  vm.scrubHeld = true
  if w == vm.scrubSent:
    vm.scrubPending = -1
  elif vm.scrubInFlight:
    vm.scrubPending = w
  else:
    vm.sendScrub(w)

proc releaseScrub*(vm: TerminalOutputVM): int =
  ## The scrubber is released: the drag already moved the recording position
  ## (`scrubTo`); a release on a write the drag has not sent yet sends it —
  ## after the move in flight, if there is one. Answers the write, -1 when no
  ## scrub was in progress.
  result = vm.scrubPreview.val
  vm.scrubPreview.val = -1
  vm.scrubHeld = false
  if result >= 0 and result != vm.scrubSent:
    if vm.scrubInFlight:
      vm.scrubPending = result
    else:
      vm.sendScrub(result)
  if not vm.scrubInFlight:
    vm.scrubSent = -1

proc cancelScrub*(vm: TerminalOutputVM) =
  if vm.actionSink.forwards("terminalOutput", "cancelScrub", %*{}):
    return
  vm.scrubPreview.val = -1
  vm.scrubSent = -1
  vm.scrubHeld = false
  vm.scrubInFlight = false
  vm.scrubPending = -1

proc stepTarget*(vm: TerminalOutputVM; delta: int): int =
  ## The write a step of `delta` writes from the shown one lands on, -1 when
  ## there is none that way.
  let n = vm.events.val.len
  if n == 0:
    return -1
  let at = vm.shownWrite.val
  let target = if at < 0 and delta > 0: delta - 1 else: at + delta
  if target < 0 or target >= n or target == at:
    return -1
  target

proc stepWrite*(vm: TerminalOutputVM; delta: int): int =
  ## The pane's previous / next write keys: move the recording position to
  ## the write before / after the one shown. Answers the write, or -1.
  result = vm.stepTarget(delta)
  if result >= 0:
    vm.jumpToWrite(result)

proc shownScreen*(vm: TerminalOutputVM): TermScreen =
  ## The screen the screen view shows now.
  discard vm.screenVersion.val
  if vm.screen.isNil:
    return newTermScreen()
  vm.screen.screenAfter(vm.shownWrite.val)

proc currentLine*(vm: TerminalOutputVM): int =
  ## The line of the current recording position (the line view scrubber's
  ## mark), -1 before the first write.
  if vm.windowed: vm.windowCurrentLine.val
  else: lineOfTick(vm.lines.val, vm.currentRRTicks.val)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createTerminalOutputVM*(store: ReplayDataStore): TerminalOutputVM =
  ## Create a TerminalOutputVM inside a reactive root owned by
  ## ``withViewModel``; disposed via ``vm.dispose()``. ``currentRRTicks``
  ## mirrors the store's debugger position.
  withViewModel proc(dispose: proc()): TerminalOutputVM =
    let events = createSignal(newSeq[TerminalOutputEvent]())
    let lines = createSignal(newSeq[TerminalLine]())
    let initialLoad = createSignal(true)
    let currentRRTicks = createSignal(0'u64)
    let view = createSignal(tvLines)
    let scrubPreview = createSignal(-1)
    let screenVersion = createSignal(0)
    let viewport = createSignal(Viewport())
    let linesStart = createSignal(0)
    let linesTotal = createSignal(-1)
    let windowCurrentLine = createSignal(-1)
    let offeredByEngine = createSignal(false)
    let writesTotal = createSignal(0)
    let viewportGate = newViewportGate(
      proc(): ViewportScheduler =
        if store.isNil: nil else: store.viewportScheduler,
      proc(v: Viewport) = viewport.val = v)

    let isLoading = createMemo[bool] proc(): bool =
      initialLoad.val and lines.val.len == 0

    let isEmpty = createMemo[bool] proc(): bool =
      (not initialLoad.val) and
        (if linesTotal.val >= 0: linesTotal.val == 0 else: lines.val.len == 0)

    let vm = TerminalOutputVM(
      store: store,
      events: events,
      lines: lines,
      initialLoad: initialLoad,
      currentRRTicks: currentRRTicks,
      view: view,
      scrubPreview: scrubPreview,
      scrubSent: -1,
      scrubPending: -1,
      screenVersion: screenVersion,
      viewport: viewport,
      viewportGate: viewportGate,
      linesStart: linesStart,
      linesTotal: linesTotal,
      windowCurrentLine: windowCurrentLine,
      offeredByEngine: offeredByEngine,
      writesTotal: writesTotal,
      isLoading: isLoading,
      isEmpty: isEmpty,
      disposeProc: dispose,
    )

    vm.screenOffered = createMemo[bool] proc(): bool =
      discard screenVersion.val
      offeredByEngine.val or (not vm.screen.isNil and vm.screen.offered)

    vm.shownWrite = createMemo[int] proc(): int =
      discard screenVersion.val
      let preview = scrubPreview.val
      if preview >= 0: preview
      elif vm.screen.isNil: -1
      else: vm.screen.writeAtTick(currentRRTicks.val)

    if not store.isNil:
      createEffect proc() =
        let ticks = store.debugger.val.rrTicks
        currentRRTicks.val = ticks
        # A landed scrub move sends the next one; what that reads (the
        # store's session) is not this effect's dependency.
        untrack(proc() = vm.landScrub(ticks))

    if not store.isNil and not store.backend.isNil:
      # THE LINE WINDOW (Viewport-Driven-Loading V2, Q3): the lines the view
      # shows plus the 20/10 buffers, asked once per distinct window. An
      # unmeasured view asks nothing. The answer names the current line for
      # the position it was asked at.
      var lastWindow = RowWindow(start: -1, count: 0)
      createEffect proc() =
        let w = listWindow(viewport.val)
        if w.count <= 0 or w == lastWindow:
          return
        lastWindow = w
        let ticks = untrack(proc(): uint64 = currentRRTicks.val)
        let fut = store.backend.send("ct/load-terminal-lines", %*{
          "start": w.start, "count": w.count, "atRRTicks": ticks})
        onComplete(fut,
          proc(response: JsonNode) =
            if responseSucceeded(response):
              vm.applyLinesWindow(
                terminalLinesWindowFromJson(responseBody(response)), ticks),
          proc(message: string) = discard)

      # THE CURRENT LINE follows the position: one count-0 request per tick,
      # once the engine serves the line view.
      vm.lineTicks = high(uint64)
      createEffect proc() =
        let ticks = currentRRTicks.val
        if linesTotal.val < 0 or ticks == vm.lineTicks:
          return
        vm.lineTicks = ticks
        let fut = store.backend.send("ct/load-terminal-lines", %*{
          "start": 0, "count": 0, "atRRTicks": ticks})
        onComplete(fut,
          proc(response: JsonNode) =
            if not responseSucceeded(response):
              return
            let w = terminalLinesWindowFromJson(responseBody(response))
            if w.ok and ticks == vm.currentRRTicks.val:
              vm.windowCurrentLine.val = w.currentLine,
          proc(message: string) = discard)

      # THE SCREEN VIEW loads every write, once it is shown: its scrubber
      # spans all of them.
      createEffect proc() =
        if view.val != tvScreen or not offeredByEngine.val or
           linesTotal.val < 0 or vm.writesAsked:
          return
        vm.writesAsked = true
        let fut = store.backend.send("ct/load-terminal", newJObject())
        onComplete(fut,
          proc(response: JsonNode) =
            # The answer is a JSON ARRAY of writes, which `responseBody`
            # (an object or nothing) does not pass through.
            if responseSucceeded(response):
              let body = if isResponseEnvelope(response):
                           response.getOrDefault("body")
                         else: response
              vm.setEvents(terminalEventsFromJson(body)),
          proc(message: string) =
            vm.writesAsked = false)

    vm
