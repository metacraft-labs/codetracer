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

import std/[json, tables]

import isonim/core/[signals, computation, owner, batch]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
import ./terminal_output_model

export terminal_output_model

type
  TerminalOutputVM* = ref object of ViewModel
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

    # -- Derived state --
    isLoading*: Memo[bool]
    isEmpty*: Memo[bool]
    screenOffered*: Memo[bool]
    shownWrite*: Memo[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setLines*(vm: TerminalOutputVM; lines: seq[TerminalLine]) =
  ## Replace the rendered lines wholesale (a caller that built them itself).
  vm.initialLoad.val = false
  vm.lines.val = lines

proc setEvents*(vm: TerminalOutputVM; events: seq[TerminalOutputEvent];
                cols = DefaultScreenCols; rows = DefaultScreenRows) =
  ## The recorded writes arrived: build the line view and the screen model
  ## from them, and pick the view — the one the user chose for this recording
  ## if they did, else the screen view when the output drives a screen.
  vm.screen = newTerminalScreenModel(events, cols, rows)
  vm.events.val = events
  vm.initialLoad.val = false
  vm.lines.val = buildTerminalLines(events)
  vm.scrubPreview.val = -1
  vm.scrubSent = -1
  vm.scrubHeld = false
  vm.scrubInFlight = false
  vm.scrubPending = -1
  if vm.recordingKey.len > 0 and vm.recordingKey in vm.viewMemory:
    vm.viewChosen = true
    vm.view.val = (if vm.screen.offered: vm.viewMemory[vm.recordingKey]
                   else: tvLines)
  else:
    vm.viewChosen = false
    vm.view.val = defaultViewFor(vm.screen.offered)
  vm.screenVersion.val = vm.screenVersion.val + 1

proc clearLines*(vm: TerminalOutputVM) =
  ## Reset to the pre-load state (a new trace).
  vm.initialLoad.val = true
  vm.screen = nil
  vm.events.val = @[]
  vm.lines.val = @[]
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
  let v = if view == tvScreen and not vm.screenOffered.val: tvLines else: view
  vm.view.val = v
  vm.viewChosen = true
  if vm.recordingKey.len > 0:
    vm.viewMemory[vm.recordingKey] = v
    if not vm.onViewChosen.isNil:
      vm.onViewChosen(vm.viewMemory)

proc toggleView*(vm: TerminalOutputVM) =
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
  lineOfTick(vm.lines.val, vm.currentRRTicks.val)

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

    let isLoading = createMemo[bool] proc(): bool =
      initialLoad.val and lines.val.len == 0

    let isEmpty = createMemo[bool] proc(): bool =
      (not initialLoad.val) and lines.val.len == 0

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
      isLoading: isLoading,
      isEmpty: isEmpty,
      disposeProc: dispose,
    )

    vm.screenOffered = createMemo[bool] proc(): bool =
      discard screenVersion.val
      not vm.screen.isNil and vm.screen.offered

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

    vm
