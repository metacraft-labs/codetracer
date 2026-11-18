## headless_app/low_level_menu.nim — the Low Level Code pane's row menu (K62)
## for the native front-ends, read off the shared listing model.
##
## codetracer-pm `spec/GUI/Debugging-Features/Generated-Code-Listing.md`
## §0.2 (PLAT-60): an instruction's right press opens Go to Source Line, Show
## Source Line, Copy Instruction and Copy Source Location, each disabled with
## its reason where it cannot act. The desktop's view hands
## `LowLevelCodeVM.rowMenu`'s entries to its context menu; the terminal and
## GPUI draw a `ContextMenuModel` (`pane_clicks`). This module is the one
## conversion between the two, so the three front-ends show the entries, the
## order and the reasons one function decided.
##
## Choosing an entry re-asks the model at that moment (`runLowLevelMenu`): a
## `ContextMenuModel` carries no closures, and the listing may have been
## replaced (the debugger moved) while the menu was open, so the instruction
## is found again by its index AND its offset — a listing that no longer has
## that offset at that index runs nothing.

import codetracer_embed
import ./pane_clicks

export pane_clicks

func contextActionOf*(action: LowLevelMenuAction): ContextAction =
  case action
  of llmGoToSourceLine: caLowLevelGoToSourceLine
  of llmShowSourceLine: caLowLevelShowSourceLine
  of llmCopyInstruction: caLowLevelCopyInstruction
  of llmCopySourceLocation: caLowLevelCopySourceLocation

func lowLevelMenuActionOf*(action: ContextAction):
    tuple[ok: bool, action: LowLevelMenuAction] =
  ## The listing model's entry a menu action names; `ok` false for any other
  ## action.
  case action
  of caLowLevelGoToSourceLine: (true, llmGoToSourceLine)
  of caLowLevelShowSourceLine: (true, llmShowSourceLine)
  of caLowLevelCopyInstruction: (true, llmCopyInstruction)
  of caLowLevelCopySourceLocation: (true, llmCopySourceLocation)
  else: (false, llmGoToSourceLine)

proc lowLevelRowContextMenuOf*(vm: LowLevelCodeVM;
                               index: int): ContextMenuModel =
  ## A right press on instruction `index`: the model's menu for it, as a
  ## native menu (no entries for no such instruction).
  var decided: seq[tuple[label: string; action: ContextAction;
                         enabled: bool; reason: string]] = @[]
  var offset = -1
  if not vm.isNil:
    let rows = vm.instructions.val
    if index >= 0 and index < rows.len:
      offset = rows[index].offset
      for e in vm.rowMenu(index):
        decided.add (e.label, contextActionOf(e.action), e.enabled, e.reason)
  lowLevelRowContextMenu(index, offset, decided)

proc runLowLevelMenu*(vm: LowLevelCodeVM; action: ContextAction;
                      target: ContextTarget): LowLevelMenuOutcome =
  ## Choose `action` from an instruction's menu, as the model decides it NOW.
  ## Nothing runs for another pane's action or an instruction no longer
  ## listed where the menu found it.
  let (isLowLevel, wanted) = lowLevelMenuActionOf(action)
  if vm.isNil or not isLowLevel:
    return
  let index = int(target.index)
  let rows = vm.instructions.val
  if index < 0 or index >= rows.len or rows[index].offset != target.line:
    return LowLevelMenuOutcome(note: "that instruction is no longer listed")
  vm.runRowMenu(index, wanted)
