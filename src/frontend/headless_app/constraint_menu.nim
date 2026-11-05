## headless_app/constraint_menu.nim — the Constraints pane's row menu (K68)
## for the native front-ends, read off the shared Constraints model.
##
## PLAT-62: a row's right press opens Go to Source, Copy Name and Copy Source
## Location, each disabled with its reason where it cannot act. The desktop's
## view hands `ConstraintsVM.rowMenu`'s entries to its context menu; the
## terminal and GPUI draw a `ContextMenuModel` (`pane_clicks`). This module is
## the one conversion between the two, so the three front-ends show the
## entries, the order and the reasons one function decided.
##
## Choosing an entry re-asks the model at that moment
## (`runConstraintMenuAction`): a `ContextMenuModel` carries no closures, and a
## new report may have landed while the menu was open, so the row is found
## again by its index AND its name — a row that is no longer the one the menu
## was opened on does nothing.

import codetracer_embed
import ./pane_clicks

export pane_clicks

func contextActionOf*(action: ConstraintMenuAction): ContextAction =
  case action
  of cmGoToSource: caConstraintGoToSource
  of cmCopyName: caConstraintCopyName
  of cmCopySourceLocation: caConstraintCopySourceLocation

func constraintMenuActionOf*(action: ContextAction):
    tuple[ok: bool, action: ConstraintMenuAction] =
  ## The Constraints model's entry a menu action names; `ok` false for any
  ## other action.
  case action
  of caConstraintGoToSource: (true, cmGoToSource)
  of caConstraintCopyName: (true, cmCopyName)
  of caConstraintCopySourceLocation: (true, cmCopySourceLocation)
  else: (false, cmGoToSource)

proc constraintRowContextMenuOf*(vm: ConstraintsVM;
                                 index: int): ContextMenuModel =
  ## A right press on row `index`: the model's menu for it, as a native menu
  ## (empty for no such row).
  var decided: seq[tuple[label: string; action: ContextAction;
                         enabled: bool; reason: string]] = @[]
  var name = ""
  if not vm.isNil:
    let rows = vm.rows.val
    if index >= 0 and index < rows.len:
      name = rows[index].name
    for e in vm.rowMenu(index):
      decided.add (e.label, contextActionOf(e.action), e.enabled, e.reason)
  constraintRowContextMenu(index, name, decided)

proc runConstraintMenuAction*(vm: ConstraintsVM; action: ContextAction;
                              target: ContextTarget): ConstraintMenuOutcome =
  ## Choose `action` from a Constraints row menu, as the model decides it NOW.
  ## `done` false when nothing ran (a disabled entry, a row that is no longer
  ## the one the menu named, another pane's action).
  let (isConstraint, wanted) = constraintMenuActionOf(action)
  if vm.isNil or not isConstraint:
    return
  let index = int(target.index)
  let rows = vm.rows.val
  if index < 0 or index >= rows.len or rows[index].name != target.text:
    return
  vm.runRowMenu(index, wanted)
