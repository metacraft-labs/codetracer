## viewmodel/process_switcher_vm.nim — the process switcher of a
## multi-process recording (CTF-P2c step 5; codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## §2.6, D25, D76-D82).
##
## A multi-process recording groups several traces for browsing together
## (`GUI/Debugging-Features/Value-Origin-Tracking.md` §14.8: the session's
## `[[trace]]` rows, reported by the backend's `ct/listProcesses`). Its
## session tab selects the process with **the recording switcher**: the
## numbered buttons `1 2 3 …` an Agent Harbor initiative's tab draws for its
## recordings (`nim-agents-isonim-viewmodels`
## `agent_harbor/recording_switcher.nim`; Agent-Harbor-Front-End.md
## "Recording buttons", AHF-AREQ2: one control for both). This viewmodel
## turns the recording's processes into those buttons:
##
## - each button's tooltip names the process, its pid and its binary (D25);
##   a field the wire does not carry is left out rather than invented
##   (`processTooltipOf`);
## - a correlation marker that leads to another process
##   (`GUI/Debugging-Features/Correlation-Markers.md` §4, §5.3) rings that
##   process's button until the reader follows it -- selects that process by
##   a press, a key or the marker's own jump (`markCorrelation`, `select`);
## - `next` / `previous` step through the processes in order, wrapping, and
##   pass over a process whose trace is missing (nothing to show);
## - with fewer than two processes there is no switcher (`shown`).
##
## The process tree sidebar (`isonim_process_tree_view.nim`) stays the
## detail view; this viewmodel does not replace `SessionViewModel`'s
## process state. `fromProcessTree` converts the backend's rows and
## `onSwitch` is the hook a host binds to `SessionViewModel.onSwitchProcess`
## when the production session tab adopts the switcher (a later slice).
##
## The ring is the recording switcher's own: `processButtons` passes the
## ringed process to `recordingButtons` (`ringedId`), whose buttons carry
## `ringed` and whose `+N` carries `hiddenRinged`, and each host's switcher
## drawing draws it (D81; manager note 143).
##
## The rules (the tooltip, the ring's life, the stepping order) are plain
## procedures over values, tested without signals; the viewmodel holds the
## signals the views follow.

import std/strutils

import isonim/core/signals
import isonim/viewmodel
import nim_agents_isonim_viewmodels/agent_harbor/recording_switcher

export viewmodel, signals, recording_switcher

type
  ProcessEntry* = object
    ## One process of the recording.
    recordingId*: string
      ## The trace's stable handle (`ct/listProcesses` `recordingId`).
    role*: string
      ## The process's role in the session (`frontend`, `backend`).
    displayName*: string
      ## The trace file's name (`backend.ct`).
    pid*: int
      ## The recorded process id; 0 when unknown (the wire carries none yet).
    binary*: string
      ## The recorded executable; "" when unknown.
    state*: RecordingState
      ## Ready, loading, failed to load, or missing from the bundle.
    error*: string
      ## Why it failed to load, or where it went.

  CorrelationMark* = object
    ## A correlation marker that leads to another process: which, and the
    ## words that say so (`A correlation marker (envelope-flow, step 1 204)
    ## leads here`).
    toId*: string
    words*: string

  ProcessSwitcherVM* = ref object of ViewModel
    title*: string
      ## The recording's name, the session tab's title (`envelope-flow`).
    entries*: Signal[seq[ProcessEntry]]
    activeId*: Signal[string]
    correlation*: Signal[CorrelationMark]
      ## The marker whose counterpart is in another process; empty `toId`
      ## for none.
    onSwitch*: proc(recordingId: string)
      ## Hears every change of the active process; nil for none.

const
  MiddleDot = " \xC2\xB7 "

# ---------------------------------------------------------------------------
# The rules, over values
# ---------------------------------------------------------------------------

proc processLabel*(entry: ProcessEntry): string =
  ## The name a process goes by: its role, else its trace's name, else its
  ## id.
  if entry.role.len > 0: entry.role
  elif entry.displayName.len > 0: entry.displayName
  else: entry.recordingId

proc processTooltipOf*(entry: ProcessEntry): string =
  ## `backend · pid 4182 · /srv/envelope/bin/backend`, and the state when
  ## it is not ready (the recording switcher's own state words,
  ## `recording_switcher.tooltipOf`). A pid or binary the wire did not carry
  ## is left out, never shown as `pid 0`.
  var parts = @[entry.processLabel]
  if entry.pid > 0: parts.add "pid " & $entry.pid
  if entry.binary.len > 0: parts.add entry.binary
  result = parts.join(MiddleDot)
  case entry.state
  of rsReady: discard
  of rsLoading: result.add " (loading)"
  of rsFailed:
    result.add " (failed to load" & (if entry.error.len > 0: ": " & entry.error else: "") & ")"
  of rsMissing:
    result.add " (missing" & (if entry.error.len > 0: ": " & entry.error else: "") & ")"

proc toRecordingEntry*(entry: ProcessEntry): RecordingEntry =
  ## The process as the recording switcher's entry (its state and id; the
  ## tooltip is the process's own, `processButtons`).
  RecordingEntry(id: entry.recordingId, name: entry.processLabel,
                 state: entry.state, error: entry.error)

proc fromProcessTree*[T](row: T): ProcessEntry =
  ## A `ct/listProcesses` row (`session_vm.ProcessTreeEntry`, or any value
  ## with its `recordingId`, `role` and `displayName`) as a process: the wire carries no pid, binary
  ## or load state yet (codetracer-pm `issues/2026-11-21-ct-list-processes-
  ## carries-no-pid-binary-or-load-state.md`), so they are unknown and ready.
  ProcessEntry(recordingId: row.recordingId, role: row.role,
               displayName: row.displayName, state: rsReady)

proc switcherShown*(entries: openArray[ProcessEntry]): bool =
  ## A switcher is drawn for two or more processes; a single-process
  ## recording has nothing to switch between.
  entries.len >= 2

proc indexOf(entries: openArray[ProcessEntry]; id: string): int =
  result = -1
  for i, e in entries:
    if e.recordingId == id: return i

proc steppedId*(entries: openArray[ProcessEntry]; activeId: string; delta: int): string =
  ## The process `delta` (+1 or -1) away from the active one, wrapping, and
  ## passing over a missing process; "" when there is none other to go to.
  if entries.len < 2 or delta == 0: return ""
  let start = max(0, entries.indexOf(activeId))
  var i = start
  for _ in 1 ..< entries.len:
    i = (i + delta + entries.len) mod entries.len
    if i == start: break
    if entries[i].state != rsMissing: return entries[i].recordingId
  ""

proc ringedIdOf*(entries: openArray[ProcessEntry]; activeId: string;
                 mark: CorrelationMark): string =
  ## The process the marker rings: its counterpart's, unless that is the
  ## active process (nothing to follow) or not in the recording.
  if mark.toId.len == 0 or mark.toId == activeId: return ""
  if entries.indexOf(mark.toId) < 0: return ""
  mark.toId

proc processButtons*(entries: openArray[ProcessEntry]; activeId: string;
                     mark: CorrelationMark; maxShown = high(int)): RecordingButtons =
  ## The recording switcher's buttons for the processes
  ## (`recording_switcher.recordingButtons`: the first `maxShown - 1` and the
  ## active one, the rest behind `+N`), each tooltip the process's own, and
  ## the ringed process's tooltip also saying the marker leads there.
  var recs: seq[RecordingEntry]
  for e in entries: recs.add e.toRecordingEntry
  let ringed = ringedIdOf(entries, activeId, mark)
  result = recordingButtons(recs, activeId, maxShown, ringed)
  for b in result.buttons.mitems:
    let at = entries.indexOf(b.id)
    if at < 0: continue
    b.tooltip = processTooltipOf(entries[at])
    if b.id == ringed and mark.words.len > 0:
      b.tooltip.add " \xE2\x80\x94 " & mark.words

# ---------------------------------------------------------------------------
# The viewmodel
# ---------------------------------------------------------------------------

proc newProcessSwitcherVM*(title: string; entries: seq[ProcessEntry]; activeId = "";
                           onSwitch: proc(recordingId: string) = nil): ProcessSwitcherVM =
  ## The switcher over `entries`; the active process is `activeId`, or the
  ## first that is not missing.
  var active = activeId
  if entries.indexOf(active) < 0:
    active = ""
    for e in entries:
      if e.state != rsMissing:
        active = e.recordingId
        break
  withViewModel proc(dispose: proc()): ProcessSwitcherVM =
    ProcessSwitcherVM(title: title, entries: createSignal(entries),
                      activeId: createSignal(active),
                      correlation: createSignal(CorrelationMark()),
                      onSwitch: onSwitch)

proc shown*(vm: ProcessSwitcherVM): bool =
  ## Tracked: the switcher is drawn.
  vm.entries.val.switcherShown

proc ringedId*(vm: ProcessSwitcherVM): string =
  ## Tracked: the process the marker rings ("" for none).
  ringedIdOf(vm.entries.val, vm.activeId.val, vm.correlation.val)

proc buttons*(vm: ProcessSwitcherVM; maxShown = high(int)): RecordingButtons =
  ## Tracked: the buttons a host draws, `maxShown` the number that fit.
  if not vm.shown: return
  processButtons(vm.entries.val, vm.activeId.val, vm.correlation.val, maxShown)

proc ringedNumber*(vm: ProcessSwitcherVM): int =
  ## Tracked: the ringed process's 1-based number (0 for none).
  let id = vm.ringedId
  if id.len == 0: return 0
  vm.entries.val.indexOf(id) + 1

proc ringedHidden*(vm: ProcessSwitcherVM; maxShown = high(int)): bool =
  ## Tracked: the ringed process sits behind `+N` at `maxShown` buttons, so
  ## the chip carries the ring (D80).
  vm.buttons(maxShown).hiddenRinged

proc activeNumber*(vm: ProcessSwitcherVM): int =
  ## Tracked: the active process's 1-based number (0 for none).
  vm.entries.val.indexOf(vm.activeId.val) + 1

proc select*(vm: ProcessSwitcherVM; recordingId: string): bool =
  ## Makes `recordingId` the active process; selecting the ringed process
  ## follows the marker, and the ring goes. False when nothing changed (the
  ## process is active already, missing, or not in the recording).
  let entries = vm.entries.val
  let at = entries.indexOf(recordingId)
  if at < 0 or entries[at].state == rsMissing: return false
  if vm.activeId.val == recordingId: return false
  if vm.correlation.val.toId == recordingId:
    vm.correlation.val = CorrelationMark()
  vm.activeId.val = recordingId
  if vm.onSwitch != nil: vm.onSwitch(recordingId)
  true

proc selectNumber*(vm: ProcessSwitcherVM; number: int): bool =
  ## `select` by the 1-based number a button shows (the number keys).
  let entries = vm.entries.val
  if number < 1 or number > entries.len: return false
  vm.select(entries[number - 1].recordingId)

proc next*(vm: ProcessSwitcherVM): bool =
  ## The next process, wrapping, passing over a missing one.
  let id = steppedId(vm.entries.val, vm.activeId.val, 1)
  id.len > 0 and vm.select(id)

proc previous*(vm: ProcessSwitcherVM): bool =
  ## The previous process, wrapping, passing over a missing one.
  let id = steppedId(vm.entries.val, vm.activeId.val, -1)
  id.len > 0 and vm.select(id)

proc markCorrelation*(vm: ProcessSwitcherVM; toId, words: string): bool =
  ## A correlation marker at the reader's position leads to `toId`: its
  ## button is ringed until the reader follows it. A marker toward the
  ## active process, or one outside the recording, rings nothing (false).
  let mark = CorrelationMark(toId: toId, words: words)
  if ringedIdOf(vm.entries.val, vm.activeId.val, mark).len == 0: return false
  vm.correlation.val = mark
  true

proc followCorrelation*(vm: ProcessSwitcherVM): bool =
  ## Follows the ringed marker: selects its process.
  let id = vm.ringedId
  id.len > 0 and vm.select(id)

proc applyProcess*(vm: ProcessSwitcherVM; entry: ProcessEntry): bool =
  ## One process appeared or changed state (a trace loading turned ready or
  ## failed): replaced in place, so the buttons keep their numbers, or added
  ## at the end. False when nothing changed.
  if entry.recordingId.len == 0: return false
  var entries = vm.entries.val
  let at = entries.indexOf(entry.recordingId)
  if at >= 0:
    if entries[at] == entry: return false
    entries[at] = entry
  else:
    entries.add entry
  vm.entries.val = entries
  true
