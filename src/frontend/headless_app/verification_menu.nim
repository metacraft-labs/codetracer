## headless_app/verification_menu.nim — the Verification pane's row menu
## (K65) for the native front-ends, read off the shared ViewModel.
##
## PLAT-63: a right press on a finding, a counterexample offer or a step
## opens Go to Source, Step Through the Counterexample, Copy Message, Copy
## Location and Close the Counterexample — each where it applies, disabled
## with its reason where it cannot act. The desktop's view hands
## `VerificationVM.rowMenu`'s entries to its context menu; the terminal and
## GPUI draw a `ContextMenuModel` (`pane_clicks`). This module is the one
## conversion between the two, so the three front-ends show the entries, the
## order and the reasons one function decided.
##
## Choosing an entry re-asks the model at that moment (`runVerificationMenu`):
## a `ContextMenuModel` carries no closures, and a run may have replaced the
## list while the menu was open, so the line is found again by its key — a
## key no longer listed runs nothing.

import codetracer_embed
import ./pane_clicks

export pane_clicks

func contextActionOf*(action: VerificationMenuAction): ContextAction =
  case action
  of vmaGoToSource: caVerificationGoToSource
  of vmaOpenCounterexample: caVerificationOpenCounterexample
  of vmaCopyMessage: caVerificationCopyMessage
  of vmaCopyLocation: caVerificationCopyLocation
  of vmaCloseCounterexample: caVerificationCloseCounterexample

func verificationMenuActionOf*(action: ContextAction):
    tuple[ok: bool, action: VerificationMenuAction] =
  ## The ViewModel's entry a menu action names; `ok` false for any other
  ## action.
  case action
  of caVerificationGoToSource: (true, vmaGoToSource)
  of caVerificationOpenCounterexample: (true, vmaOpenCounterexample)
  of caVerificationCopyMessage: (true, vmaCopyMessage)
  of caVerificationCopyLocation: (true, vmaCopyLocation)
  of caVerificationCloseCounterexample: (true, vmaCloseCounterexample)
  else: (false, vmaGoToSource)

proc verificationRowContextMenuOf*(vm: VerificationVM;
                                   session: CounterexampleSessionVM;
                                   key: string): ContextMenuModel =
  ## A right press on the line `key` names: the model's menu for it, as a
  ## native menu (no entries for a line that is not listed).
  var decided: seq[tuple[label: string; action: ContextAction;
                         enabled: bool; reason: string]] = @[]
  if not vm.isNil:
    for e in vm.rowMenu(session, key):
      decided.add (e.label, contextActionOf(e.action), e.enabled, e.reason)
  verificationRowContextMenu(key, decided)

proc runVerificationMenu*(vm: VerificationVM; session: CounterexampleSessionVM;
                          action: ContextAction;
                          target: ContextTarget): VerificationMenuOutcome =
  ## Choose `action` from a line's menu, as the model decides it NOW.
  ## Nothing runs for another pane's action or a line no longer listed.
  let (isOurs, wanted) = verificationMenuActionOf(action)
  if vm.isNil or not isOurs:
    return
  vm.runRowMenu(session, target.text, wanted)
