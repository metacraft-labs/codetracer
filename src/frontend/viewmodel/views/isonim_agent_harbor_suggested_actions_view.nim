## IsoNim view of the suggested-actions block at the end of a session's
## timeline, over `SuggestedActionsVM` (nim-agents-isonim-viewmodels). The
## session activity view (`isonim_agent_harbor_session_activity_view`) draws
## it beneath its list while the suggestion waits, and the suggestion's
## record lines after its own lines once it is decided; GPUI
## (`gpui/agent_harbor/ah_suggested_actions.nim`) and the terminal
## (`tui/agent_harbor/ah_tui_suggested_actions.nim`) draw the same block.
## What the three decide alike is in `agent_harbor_suggested_actions_words`.
##
## Layout, top to bottom, on the raised ground the timeline's `Running:`
## strip uses (`agent_harbor_suggested_actions.styl`):
##
## - the label `SUGGESTED UI ACTIONS`;
## - the agent's reason, in the body role, wrapped;
## - one row per action: a check box and what the action does, wrapped; an
##   action CodeTracer cannot perform drawn unchecked and disabled, with its
##   reason under it; an action the operator unchecked in the caption-subtle
##   role;
## - `Approve` (CodeTracer's primary button; `Approve 2 of 3` when only some
##   are checked) and `Dismiss`, and, when `Approve` cannot be pressed, why.
##
## Presses are routed (Input-Routing-And-Keymaps.md §5.1): each row and
## button carries its operation (`data-ct-operation`) and its target
## (`data-ah-target`, the action's id); the page's one pointer listener
## resolves the press and the host runs it (`runSuggestedActionsPress`). The
## view holds no handler of its own. Every element carries its facts
## (`blockFacts`, `rowFacts`), so the host tests read the same facts in
## every host.

import isonim/dsl/ui
from ../input/element_press import OperationAttribute

import ./agent_harbor_suggested_actions_words
from ./agent_harbor_activity_words import PressTargetAttribute

export agent_harbor_suggested_actions_words

static:
  doAssert OperationAttribute == "data-ct-operation"
  doAssert PressTargetAttribute == "data-ah-target"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc tagFacts[R, N](r: R; node: N; facts: openArray[(string, string)]) =
  mixin setAttribute
  for (k, v) in facts: r.setAttribute(node, "data-ah-" & k, v)

proc rowClass*(row: SuggestedActionRow): string =
  result = "ah-suggested-row"
  if row.checked: result.add " ah-suggested-checked"
  if row.dimmed: result.add " ah-suggested-dimmed"
  if row.disabled: result.add " ah-suggested-disabled"

proc renderRow[R, N](r: R; row: SuggestedActionRow): N =
  var text: N
  let node =
    if row.disabled:
      ui(r):
        tdiv(class = rowClass(row), role = "checkbox", `aria-checked` = "false",
             `aria-disabled` = "true"):
          span(class = "ah-suggested-box")
          tdiv(ref = text, class = "ah-suggested-text")
    else:
      ui(r):
        tdiv(class = rowClass(row), role = "checkbox",
             `aria-checked` = (if row.checked: "true" else: "false"), tabindex = "-1",
             `data-ct-operation` = SuggestedToggleOperation, `data-ah-target` = row.id):
          span(class = "ah-suggested-box"):
            text (if row.checked: CheckMarkGlyph else: "")
          tdiv(ref = text, class = "ah-suggested-text")
  r.tagFacts(node, row.rowFacts)
  let words = ui(r):
    span(class = "ah-suggested-words"):
      text row.description
  r.appendRendered(text, words)
  if row.reason.len > 0:
    let why = ui(r):
      span(class = "ah-suggested-why"):
        text row.reason
    r.appendRendered(text, why)
  node

proc renderAgentHarborSuggestedActions*[R, N](r: R; vm: SuggestedActionsVM): N =
  ## The block, for every renderer, drawn once for the state `vm` holds now:
  ## the timeline view draws it again when the block's revision moves.
  var rows, actions: N
  result = ui(r):
    tdiv(class = "ah-suggested", `data-ah-suggested` = "block"):
      tdiv(class = "ah-suggested-label"):
        text SuggestedActionsLabel
      tdiv(class = "ah-suggested-reason"):
        text vm.reasonText
      tdiv(ref = rows, class = "ah-suggested-rows")
      tdiv(ref = actions, class = "ah-suggested-actions")
  r.tagFacts(result, vm.blockFacts)
  for row in vm.rows:
    r.appendRendered(rows, renderRow[R, N](r, row))
  let why = vm.approveDisabledReason
  let approve =
    if vm.canApprove:
      ui(r):
        button(class = "ah-suggested-button-primary",
               `data-ct-operation` = SuggestedApproveOperation):
          text vm.approveLabel
    else:
      ui(r):
        button(class = "ah-suggested-button-primary", disabled = "true", title = why):
          text vm.approveLabel
  r.tagFacts(approve, [("suggested-button", "approve")])
  r.appendRendered(actions, approve)
  let dismiss =
    if vm.canDismiss:
      ui(r):
        button(class = "ah-suggested-button-dismiss",
               `data-ct-operation` = SuggestedDismissOperation):
          text DismissLabel
    else:
      ui(r):
        button(class = "ah-suggested-button-dismiss", disabled = "true"):
          text DismissLabel
  r.tagFacts(dismiss, [("suggested-button", "dismiss")])
  r.appendRendered(actions, dismiss)
  if why.len > 0:
    let hint = ui(r):
      span(class = "ah-suggested-hint", `data-ah-approve-why` = why):
        text why
    r.appendRendered(actions, hint)
