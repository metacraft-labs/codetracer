## Event Log pane — what the desktop adds around its generic view.
##
## ---------------------------------------------------------------------------
## The pane is the generic view (``viewmodel/views/isonim_event_log_view.nim``)
## over the session's ``EventLogVM``, mounted by the panel host
## (``ui/panel_host``) into the container GoldenLayout creates. The host
## measures the rows the pane shows and the ViewModel asks the engine for
## them (``ct/event-load``), with the search, the order and the kind filter;
## the ViewModel follows the debugger, so a move marks the current event.
##
## This module is the desktop's half of the pane, installed as the panel
## host's decorator for ``Content.EventLog``:
##
## * the Filter drop-down (``#category-image``): the event kinds by tag, with
##   the "Trace events" and "Recorded events" presets — a selection the
##   ViewModel carries (``EventLogVM.selectedKinds``);
## * a right click on an event opens its text in an editor view;
## * a tracepoint run's results reach the log: the engine merges their
##   trace-log rows into it, and the pane asks for its window again.
##
## The ``EventLogComponent`` keeps its identity for the layout, the focus
## routing and the keyboard.
## ---------------------------------------------------------------------------

import
  ui_imports,
  ../[ types, communication ]

import std/options
from ../viewmodel/store/types as vmtypes import EventLogRow
from ../viewmodel/viewmodels/event_log_vm import EventLogVM,
  setSelectedKinds, selectRow, doubleClickRow, reload, resetLog, eventLogText
from ../viewmodel/session_vm import SessionViewModel
from isonim/core/signals import val
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_event_log_filter_dropdown_view import
  FilterTabRecord, FilterTagRow, FilterKindRecord, FilterDropdownCallbacks,
  FilterDropdownContainerId, mountFilterDropdownInto
import ./panel_host
from ./trace import onTraceResultsChanged

var sessionEventLogVM: EventLogVM
  ## The session's ``EventLogVM`` (``initEventLogVMFromSession``).

proc installEventLogSwitchProcessBridge*(onSwitch: proc(recordingId: string)) =
  ## §5.3 — give the Event Log a way to rotate the session's active
  ## recording when a boundary chip's counterpart lives in a sibling
  ## trace. Called by the renderer bootstrap right after
  ## `initEventLogVMFromSession`, mirroring how the State Pane's
  ## "Switch process" menu is wired.
  if sessionEventLogVM.isNil:
    return
  sessionEventLogVM.onSwitchProcessProc = onSwitch

proc initEventLogVMFromSession*(vm: EventLogVM) =
  ## The session's `EventLogVM` is installed: the one the panel host renders.
  sessionEventLogVM = vm

proc paneVM(): EventLogVM =
  ## The ViewModel the pane renders, or nil before the session exists.
  let session = panelSession()
  if session.isNil: nil else: session.eventLogVM

# ---------------------------------------------------------------------------
# The kind filter: event kinds by tag
# ---------------------------------------------------------------------------

const
  EVENT_LOG_KIND_NAMES: array[EventLogKind, string] = [
    "write",
    "write file",
    "write(other)",
    "read",
    "read file",
    "read(other)",
    "read dir",
    "open dir",
    "close dir",
    "socket",
    "open",
    "error",

    "trace log event",
    "messages",
    "write(stderr)",
    "exec",
    "read env",
    "write env",
    "stat",
    "create dir",
    "remove dir",
    "remove file",
    "rename",
    "change dir",
  ]
    ## The kinds' names in the Filter drop-down.

  EVENT_LOG_TAG_NAMES: array[EventTag, string] = [
    "std streams",
    "read events",
    "write events",
    "network",
    "trace",
    "file",
    "errors",
    "evm events",
    "process"
  ]

  EVENT_LOG_BUTTON_NAMES: array[EventDropDownBox, string] = [
    "Filter",
    "Trace events",
    "Recorded events",
    "_"
  ]

let kindTags: array[EventLogKind, seq[EventTag]] = [
  @[EventWrites, EventStd],   #Write
  @[EventWrites, EventFiles], #WriteFile
  @[EventWrites],             #WriteOther
  @[EventReads, EventStd],    #Read
  @[EventReads, EventFiles],  #ReadFile
  @[EventReads],              #ReadOther
  @[],                        #ReadDir
  @[],                        #OpenDir
  @[],                        #CloseDir
  @[EventNetwork],            #Socket
  @[EventFiles],              #Open
  @[EventErrorEvents],        #Error

  @[EventTrace],              #TraceLogEvent
  @[EventEvm],                #EvmEvent
  @[EventWrites, EventStd],   #WriteStderr
  @[EventProcess],            #Exec
  @[EventReads, EventProcess],  #ReadEnv
  @[EventWrites, EventProcess], #WriteEnv
  @[EventReads, EventFiles],  #Stat
  @[EventWrites, EventFiles], #CreateDir
  @[EventWrites, EventFiles], #RemoveDir
  @[EventWrites, EventFiles], #RemoveFile
  @[EventWrites, EventFiles], #Rename
  @[EventProcess],            #ChangeDir
]

var tagKinds: array[EventTag, seq[EventLogKind]]

for kind, tags in kindTags:
  for tag in tags:
    tagKinds[tag].add(kind)

type KindSelection = array[EventLogKind, bool]
  ## One flag per kind, by ordinal — `EventLogVM.selectedKinds`, whose empty
  ## selection is every kind.

proc selectionOf(vm: EventLogVM): KindSelection =
  let kinds = vm.selectedKinds.val
  for kind in EventLogKind:
    result[kind] = kinds.len == 0 or (ord(kind) < kinds.len and kinds[ord(kind)])

proc select(vm: EventLogVM; selection: KindSelection) =
  var kinds = newSeq[bool](selection.len)
  for kind, selected in selection:
    kinds[ord(kind)] = selected
  vm.setSelectedKinds(kinds)

proc allTagged(selection: var KindSelection; value: bool) =
  for tag in EventTag:
    for kind in tagKinds[tag]:
      selection[kind] = value

proc isTagSelected(selection: KindSelection; tag: EventTag): bool =
  result = true
  for kind in tagKinds[tag]:
    result = selection[kind]
    if result:
      break

proc tagState(selection: KindSelection; tag: EventTag): string =
  ## A tag's check: all of its kinds, some, or none.
  var count = 0
  for kind in tagKinds[tag]:
    if selection[kind]:
      count += 1
  if count > 0 and count == tagKinds[tag].len: "checked"
  elif count != 0: "indeterminate"
  else: "unchecked"

proc anyDeselected(selection: KindSelection): bool =
  for tag in EventTag:
    for kind in tagKinds[tag]:
      if not selection[kind]:
        return true

proc isOnlyTrace(selection: KindSelection): bool =
  for tag in EventTag:
    for kind in tagKinds[tag]:
      if selection[kind] != (tag == EventTrace):
        return false
  true

const
  RecordedEventTags = [EventReads, EventFiles, EventNetwork, EventWrites,
                       EventErrorEvents, EventProcess]
    ## The "Recorded events" preset: the kinds a recording makes.
  NonRecordedEventTags = [EventTrace, EventEvm]

proc isOnlyRecorded(selection: KindSelection): bool =
  for tag in RecordedEventTags:
    for kind in tagKinds[tag]:
      if not selection[kind]:
        return false
  for tag in NonRecordedEventTags:
    for kind in tagKinds[tag]:
      if selection[kind]:
        return false
  true

proc onlyTrace(): KindSelection =
  result.allTagged(false)
  for kind in tagKinds[EventTrace]:
    result[kind] = true

proc onlyRecorded(): KindSelection =
  result.allTagged(false)
  for tag in RecordedEventTags:
    for kind in tagKinds[tag]:
      result[kind] = true

const FilterDropdownTriggerGap = 6.0
  ## Pixels between the filter button and the menu it opens.  Mirrors
  ## `DROPDOWN_TRIGGER_GAP` in styles/components/shared_widgets.styl, which
  ## every menu positioned by CSS uses; this menu is positioned from JavaScript,
  ## so it cannot read that value.

proc setupFilterDropdown(host: Element; vm: EventLogVM) =
  ## Wire the pane's filter button (`#category-image`) to the event-kind
  ## drop-down. The drop-down's container is appended once to the document
  ## (hidden) and placed under the button each time it opens; its content is
  ## remounted from the ViewModel's selection on every change.
  let filterBtn = host.querySelector(cstring"#category-image")
  if filterBtn.isNil:
    cwarn "event_log: the filter button is not in the pane"
    return
  var open = false
  var focused = false

  proc showDropdown()

  proc apply(selection: KindSelection) =
    vm.select(selection)
    showDropdown()

  proc callbacks(): FilterDropdownCallbacks =
    FilterDropdownCallbacks(
      onTabClick: proc(tabIndex: int) =
        case tabIndex
        of 0: apply(onlyTrace())
        of 1: apply(onlyRecorded())
        else: discard,
      onTagToggle: proc(tagIndex: int) =
        var selection = vm.selectionOf
        let tag = EventTag(tagIndex)
        let checked = not selection.isTagSelected(tag)
        for kind in tagKinds[tag]:
          selection[kind] = checked
        apply(selection),
      onKindToggle: proc(tagIndex, kindIndex: int) =
        var selection = vm.selectionOf
        let kind = tagKinds[EventTag(tagIndex)][kindIndex]
        selection[kind] = not selection[kind]
        apply(selection),
      onToggleEnabled: proc() =
        ## Every kind on when any is off; every kind off otherwise.
        var selection = vm.selectionOf
        selection.allTagged(selection.anyDeselected)
        apply(selection))

  proc showDropdown() =
    let selection = vm.selectionOf
    var container = document.getElementById(cstring FilterDropdownContainerId)
    if container.isNil:
      # Created once; a mousedown inside it does not blur the filter button,
      # which keeps the menu open while a box is checked.
      container = document.createElement(cstring"div")
      container.setAttribute(cstring"id", cstring FilterDropdownContainerId)
      container.setAttribute(cstring"class", cstring"dropdown-container")
      container.addEventListener(cstring"mousedown", proc(e: Event) =
        e.preventDefault())
      document.body.appendChild(container)
    var rows: seq[FilterTagRow] = @[]
    for tag in EventTag:
      var kinds: seq[FilterKindRecord] = @[]
      for kind in tagKinds[tag]:
        kinds.add FilterKindRecord(
          label: EVENT_LOG_KIND_NAMES[kind],
          checkState: if selection[kind]: "checked" else: "unchecked")
      rows.add FilterTagRow(label: EVENT_LOG_TAG_NAMES[tag],
                            checkState: selection.tagState(tag),
                            kinds: kinds)
    mountFilterDropdownInto(
      cast[dom_api.Element](container),
      @[FilterTabRecord(label: EVENT_LOG_BUTTON_NAMES[OnlyTrace],
                        isSelected: selection.isOnlyTrace),
        FilterTabRecord(label: EVENT_LOG_BUTTON_NAMES[OnlyRecordedEvent],
                        isSelected: selection.isOnlyRecorded)],
      rows,
      not selection.anyDeselected,
      callbacks())
    let rect = filterBtn.getBoundingClientRect()
    container.style.position = "absolute"
    container.style.top = &"{rect.bottom + FilterDropdownTriggerGap}px"
    container.style.left = &"{rect.left}px"
    container.style.zIndex = "1000".cstring
    container.style.display = "block"
    filterBtn.classList.add(cstring"open")
    filterBtn.focus()

  proc hideDropdown() =
    let container = document.getElementById(cstring FilterDropdownContainerId)
    if not container.isNil:
      container.style.display = "none"
    filterBtn.classList.remove(cstring"open")

  filterBtn.addEventListener(cstring"focus", proc(e: Event) =
    focused = true
    showDropdown())
  filterBtn.addEventListener(cstring"blur", proc(e: Event) =
    if open or focused:
      focused = false
      open = false
      hideDropdown())
  filterBtn.addEventListener(cstring"click", proc(e: Event) =
    open = not open
    if not open and focused:
      cast[Element](e.target).blur())
  filterBtn.addEventListener(cstring"keydown", proc(e: Event) =
    ## Escape closes the menu, as it does every other drop-down; the button
    ## holds the focus the whole time the menu is open.
    if cast[KeyboardEvent](e).keyCode == ESC_KEY_CODE:
      e.preventDefault()
      e.stopPropagation()
      focused = false
      open = false
      hideDropdown()
      filterBtn.blur())

# ---------------------------------------------------------------------------
# A right click opens an event's text
# ---------------------------------------------------------------------------

proc closestRow(target: Element): Element {.importjs:
  "((e) => (e && e.closest && e.closest('tr[data-position]')) || null)(#)".}

proc rowAtPosition(vm: EventLogVM; position: int): Option[EventLogRow] =
  let at = position - vm.store.eventLog.loadedStart.val
  let rows = vm.eventRows.val
  if at >= 0 and at < rows.len: some(rows[at]) else: none(EventLogRow)

proc setupOpenInEditor(host: Element; vm: EventLogVM) =
  ## A right click on a recorded event opens its text in an editor view.
  host.addEventListener(cstring"contextmenu", proc(e: Event) =
    let tr = closestRow(cast[Element](e.target))
    if tr.isNil:
      return
    e.preventDefault()
    let position =
      try: parseInt($tr.getAttribute(cstring"data-position"))
      except ValueError: -1
    let row = vm.rowAtPosition(position)
    if row.isNone or row.get.kindId == ord(TraceLogEvent):
      return
    data.makeEditorView(
      cstring(&"event: {row.get.kind} #{row.get.eventIndex}"),
      cstring(eventLogText(row.get)),
      ViewEventContent,
      LangUnknown))

# ---------------------------------------------------------------------------
# The panel host's decorator
# ---------------------------------------------------------------------------

proc decorateEventLog(host: dom_api.Element; session: SessionViewModel) =
  let vm = session.eventLogVM
  if vm.isNil:
    return
  let element = cast[Element](host)
  setupFilterDropdown(element, vm)
  setupOpenInEditor(element, vm)

setPanelDecorator(Content.EventLog, decorateEventLog)

var reloadQueued = false
  ## A reload is already scheduled for this turn: a tracepoint run reports
  ## once per tracepoint, and the log is asked for once.

onTraceResultsChanged(proc() =
  if reloadQueued:
    return
  reloadQueued = true
  discard setTimeout(proc() =
    reloadQueued = false
    let vm = paneVM()
    if not vm.isNil:
      vm.reload(), 0))

# ---------------------------------------------------------------------------
# The component: identity, focus and keys
# ---------------------------------------------------------------------------

proc moveSelection(delta: int; absolute = false) =
  ## Move the selected event within the rows the pane holds.
  let vm = paneVM()
  if vm.isNil or vm.eventRows.val.len == 0:
    return
  let last = vm.eventRows.val.len - 1
  let current = vm.selectedRow.val.get(0)
  let next = if absolute: delta else: current + delta
  vm.selectRow(some(clamp(next, 0, last)))

method onUp*(self: EventLogComponent) {.async.} =
  moveSelection(-1)

method onDown*(self: EventLogComponent) {.async.} =
  moveSelection(1)

method onGotoStart*(self: EventLogComponent) {.async.} =
  moveSelection(0, absolute = true)

method onGotoEnd*(self: EventLogComponent) {.async.} =
  moveSelection(high(int), absolute = true)

method onEnter*(self: EventLogComponent) {.async.} =
  let vm = paneVM()
  if not vm.isNil and vm.selectedRow.val.isSome:
    vm.doubleClickRow(vm.selectedRow.val.get)

method onFindOrFilter*(self: EventLogComponent) {.async.} =
  let field = document.querySelector(cstring".eventLog .eventLog-search-field")
  if not field.isNil:
    field.focus()

method restart*(self: EventLogComponent) =
  ## A new recording: its log replaces the previous one's.
  let vm = paneVM()
  if not vm.isNil:
    vm.resetLog()

method register*(self: EventLogComponent, api: MediatorWithSubscribers) =
  ## The pane subscribes to nothing: its rows are the session's
  ## `EventLogVM`'s, which asks the engine for them.
  self.api = api

proc registerEventLogComponent*(component: EventLogComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
