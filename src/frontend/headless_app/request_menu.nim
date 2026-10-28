## headless_app/request_menu.nim — the Requests pane's menus (K59, K60) for
## the native front-ends, read off the shared Requests model.
##
## codetracer-pm `spec/GUI/Core-Panes/Request-Panel.md` § N.4 – N.5: a row's
## right press opens Go to Handler, Copy URL, Filter by Method, Filter by
## Status and Clear Filters, each disabled with its reason where it cannot
## act; the Method and Status pickers open as dropdowns of the desktop's
## options. The desktop's view hands `RequestPanelVM.rowMenu`'s entries to
## its context menu; the terminal and GPUI draw a `ContextMenuModel`
## (`pane_clicks`). This module is the one conversion between the two, so the
## three front-ends show the entries, the order and the reasons one function
## decided.
##
## Choosing an entry re-asks the model at that moment (`runRequestMenuAction`):
## a `ContextMenuModel` carries no closures, and the row may have moved (a
## live tail, a window the engine answered) while the menu was open, so the
## row is found again by its request id.

import codetracer_embed
import ./pane_clicks

export pane_clicks

func contextActionOf*(action: RequestMenuAction): ContextAction =
  case action
  of rmGoToHandler: caRequestGoToHandler
  of rmCopyUrl: caRequestCopyUrl
  of rmFilterMethod: caRequestFilterMethod
  of rmFilterStatus: caRequestFilterStatus
  of rmClearFilters: caRequestClearFilters

func requestMenuActionOf*(action: ContextAction):
    tuple[ok: bool, action: RequestMenuAction] =
  ## The Requests model's entry a menu action names; `ok` false for any other
  ## action.
  case action
  of caRequestGoToHandler: (true, rmGoToHandler)
  of caRequestCopyUrl: (true, rmCopyUrl)
  of caRequestFilterMethod: (true, rmFilterMethod)
  of caRequestFilterStatus: (true, rmFilterStatus)
  of caRequestClearFilters: (true, rmClearFilters)
  else: (false, rmGoToHandler)

proc heldIndexOfId*(vm: RequestPanelVM; id: int64): int =
  ## The held row of request `id`, -1 when it is not held.
  if vm.isNil:
    return -1
  for i, r in vm.filteredRequests.val:
    if int64(r.id) == id:
      return i
  -1

proc requestRowContextMenuOf*(vm: RequestPanelVM;
                              index: int): ContextMenuModel =
  ## A right press on held row `index`: the model's menu for it, as a native
  ## menu (empty for no such row).
  var decided: seq[tuple[label: string; action: ContextAction;
                         enabled: bool; reason: string]] = @[]
  var id = 0'i64
  if not vm.isNil:
    let rows = vm.filteredRequests.val
    if index >= 0 and index < rows.len:
      id = int64(rows[index].id)
    for e in vm.rowMenu(index):
      decided.add (e.label, contextActionOf(e.action), e.enabled, e.reason)
  requestRowContextMenu(id, decided)

proc requestPickerMenuOf*(vm: RequestPanelVM;
                          statusPicker: bool): ContextMenuModel =
  ## A press on the Method (or Status) picker: its options as a dropdown.
  if statusPicker:
    requestPickerContextMenu(true, StatusPickerOptions,
                             if vm.isNil: "" else: vm.filterStatus.val)
  else:
    requestPickerContextMenu(false, MethodPickerOptions,
                             if vm.isNil: "" else: vm.filterMethod.val)

proc runRequestMenuAction*(vm: RequestPanelVM; action: ContextAction;
                           target: ContextTarget): RequestMenuOutcome =
  ## Choose `action` from a Requests menu, as the model decides it NOW: a
  ## picker's option sets its filter to `target.text`; a row's entry is the
  ## row's (`runRowMenu`), found again by its id. `done` false when nothing
  ## ran (a disabled entry, a row no longer held, another pane's action).
  let (isRequests, wanted) = requestMenuActionOf(action)
  if vm.isNil or not isRequests:
    return
  if target.expression in ["method", "status"]:
    # A picker's option.
    if target.expression == "method":
      vm.setFilterMethod(target.text)
    else:
      vm.setFilterStatus(target.text)
    result.done = true
    return
  let index = vm.heldIndexOfId(target.index)
  if index < 0:
    return
  vm.runRowMenu(index, wanted)
