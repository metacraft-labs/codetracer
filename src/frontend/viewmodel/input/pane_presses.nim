## pane_presses.nim — WHAT A PRESS ON AN ELEMENT OF ONE OF THE SESSION'S PANES
## DOES, IN A DOM FRONT-END: the procedure for each operation the pointer
## keymap names, over the element's identity.
##
## Input-Routing-And-Keymaps.md §5.1: the pointer keymap names the operation a
## press on an element runs (`viewmodel/keymap/pointer_rows`, a user's
## `keybindings.json`); each front-end performs it on the element pressed. The
## terminal's procedures are `tui/app/runtime`'s `elements` table, GPUI's are
## `gpui/main`'s; these are a DOM front-end's (the desktop and web renderer, a
## VS Code panel), for the panes whose ViewModels the session owns. Each reads
## the element's identity through `attr` — the `data-*` attributes the pane's
## view draws on the element and its row — and acts on the ViewModel: what the
## view's own click handler did before, moved here unchanged.
##
## No DOM here: `dom_pane_presses` reads the attributes off the element the
## DOM's hit test found (`dom_pointer`), and a suite rendering a view under
## `MockRenderer` reads them off its mock node, so both run the same procedure.

import std/[options, strutils]

import ../session_vm
import ../viewmodels/[calltrace_vm, event_log_vm, state_vm, filesystem_vm,
                      point_list_vm, terminal_output_vm, search_results_vm,
                      low_level_code_vm, request_panel_vm, constraints_vm,
                      pixel_history_vm]
from ../views/isonim_request_panel_view import pressAndActivateRow
import isonim/core/signals

type
  AttributeReader* = proc(name: string): string
    ## An attribute of the element pressed or of the nearest ancestor that
    ## carries it; empty when none does.

const
  SessionPressOperations* = [
    "calltrace.go-to-call", "calltrace.toggle-call", "event-log.jump",
    "event-log.sort", "variables.toggle-expand", "file-tree.activate",
    "point-list.select", "terminal-output.jump-to-write",
    "search.open-result", "requests.select", "low-level.go-to-source-line",
    "low-level.toggle-sync"]
    ## The operations this module performs, one per base pointer row of the
    ## session's panes (`pointer_rows`).

proc intOf(attr: AttributeReader; name: string): int =
  try: parseInt(attr(name)) except ValueError: -1

proc pressCalltrace*(vm: CalltraceVM; operation: string;
                     attr: AttributeReader): bool =
  ## K20, K21: the call's text goes to the call, its toggle expands it.
  let index = intOf(attr, "data-call-index")
  if vm.isNil or index < 0:
    return false
  case operation
  of "calltrace.go-to-call":
    # Select the row's CALL, so the mark stays on it when a collapse or a
    # filter change moves it to another row (#811). `ForMove`, because the
    # jump lands where several frames can share the step, and following the
    # debugger's call there would mark a deeper one.
    let callKey = attr("data-call-key")
    if callKey.len > 0:
      vm.selectCallForMove(callKey)
    else:
      vm.selectEntry(some(int64(index)))
    vm.doubleClickEntry(int64(index))
    true
  of "calltrace.toggle-call":
    vm.toggleExpandCallChildren(int64(index))
    true
  else: false

proc pressEventLog*(vm: EventLogVM; operation: string;
                    attr: AttributeReader): bool =
  ## K24: a row selects the event and moves the debugger to it; K26: a
  ## column's header orders the log by it.
  if vm.isNil:
    return false
  case operation
  of "event-log.jump":
    let position = intOf(attr, "data-position")
    if position < 0:
      return false
    let at = position - vm.store.eventLog.loadedStart.val
    vm.selectRow(some(at))
    vm.doubleClickRow(at)
    true
  of "event-log.sort":
    let column =
      try: parseEnum[EventLogColumn](attr("data-column"))
      except ValueError: return false
    vm.sortBy(vm.order().clickedHeader(column))
    true
  else: false

proc pressState*(vm: StateVM; operation: string; attr: AttributeReader): bool =
  ## K27: a compound value's expander shows or hides its parts.
  let path = attr("data-variable-path")
  if vm.isNil or path.len == 0 or operation != "variables.toggle-expand":
    return false
  vm.toggleExpand(path)
  true

proc pressFileTree*(vm: FilesystemVM; operation: string;
                    attr: AttributeReader): bool =
  ## K17, K18: a folder toggles, a file opens.
  let path = attr("data-ct-path")
  if vm.isNil or path.len == 0 or operation != "file-tree.activate":
    return false
  if attr("data-ct-folder") == "true":
    vm.toggleExpanded(path)
  else:
    vm.openFile(path)
  true

proc pressPointList*(vm: PointListVM; operation: string;
                     attr: AttributeReader): bool =
  ## K31: a point is selected.
  let index = intOf(attr, "data-point-index")
  if vm.isNil or index < 0 or operation != "point-list.select":
    return false
  vm.selectPoint(some(index))
  true

proc pressTerminalOutput*(vm: TerminalOutputVM; operation: string;
                          attr: AttributeReader): bool =
  ## K32: a fragment goes to its write; a line pressed past its text, to the
  ## write that completed it (its last fragment's).
  var write = intOf(attr, "data-event-index")
  if write < 0:
    write = intOf(attr, "data-last-event-index")
  if vm.isNil or write < 0 or operation != "terminal-output.jump-to-write":
    return false
  vm.jumpToEvent(write)
  true

proc pressSearchResults*(vm: SearchResultsVM; operation: string;
                         attr: AttributeReader): bool =
  ## K35: a match opens its file at its line.
  let index = intOf(attr, "data-search-result-index")
  if vm.isNil or index < 0 or operation != "search.open-result":
    return false
  discard vm.openResult(index)
  true

proc pressRequests*(vm: RequestPanelVM; operation: string;
                    attr: AttributeReader): bool =
  ## K58: a press is counted (`RequestPanelVM.pressRow`): the second press on
  ## the same row in time goes to its handler.
  let index = intOf(attr, "data-request-index")
  if vm.isNil or index < 0 or operation != "requests.select":
    return false
  discard pressAndActivateRow(vm, index)
  true

proc pressLowLevel*(vm: LowLevelCodeVM; operation: string;
                    attr: AttributeReader): bool =
  ## K61: an instruction goes to the source line it was generated from; K63:
  ## the sync toggle.
  if vm.isNil:
    return false
  case operation
  of "low-level.go-to-source-line":
    let index = intOf(attr, "data-low-level-row")
    let rows = vm.instructions.val
    if index < 0:
      return false
    if index < rows.len:
      vm.jumpToInstruction(rows[index])
    true
  of "low-level.toggle-sync":
    vm.setSyncEnabled(not vm.syncSettings.val.enabled)
    true
  else: false

proc pressConstraints*(vm: ConstraintsVM; operation: string;
                       attr: AttributeReader): bool =
  ## K67: a row is selected and its source opened. (The desktop holds a
  ## Constraints ViewModel per tab, outside the session: `ui/constraints`.)
  let index = intOf(attr, "data-constraint-index")
  if vm.isNil or index < 0 or operation != "constraints.go-to-source":
    return false
  discard vm.activateRow(index)
  true

proc pressPixelHistory*(vm: PixelHistoryVM; operation: string;
                        attr: AttributeReader): bool =
  ## K73: an entry is selected and its draw call's source opened.
  let index = intOf(attr, "data-pixel-history-index")
  if vm.isNil or index < 0 or operation != "pixel-history.activate":
    return false
  vm.selectEntry(index)
  true

proc performSessionPress*(session: SessionViewModel; operation: string;
                          attr: AttributeReader): bool =
  ## Performs `operation` on the element `attr` describes, over `session`'s
  ## ViewModels; false when it is not one of `SessionPressOperations` or the
  ## element is not one it acts on.
  if session.isNil:
    return false
  let pane = operation.split('.')[0]
  case pane
  of "calltrace": pressCalltrace(session.calltraceVM, operation, attr)
  of "event-log": pressEventLog(session.eventLogVM, operation, attr)
  of "variables": pressState(session.stateVM, operation, attr)
  of "file-tree": pressFileTree(session.fileTreeVM, operation, attr)
  of "point-list": pressPointList(session.pointListVM, operation, attr)
  of "terminal-output":
    pressTerminalOutput(session.terminalOutputVM, operation, attr)
  of "search": pressSearchResults(session.searchResultsVM, operation, attr)
  of "requests": pressRequests(session.requestPanelVM, operation, attr)
  of "low-level": pressLowLevel(session.lowLevelCodeVM, operation, attr)
  else: false
