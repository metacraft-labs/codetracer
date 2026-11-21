## The words, roles and rules the three hosts share for the suggested-actions
## block at the end of a session's timeline (the web's
## `isonim_agent_harbor_suggested_actions_view`, GPUI's
## `gpui/agent_harbor/ah_suggested_actions`, the terminal's
## `tui/agent_harbor/ah_tui_suggested_actions`), over `SuggestedActionsVM`
## (nim-agents-isonim-viewmodels).
##
## The block (codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## D23, D54-D58): a label (`SUGGESTED UI ACTIONS`), the agent's reason in the
## body role, one row per action -- a check toggle and what the action does,
## wrapped, never cut (it is what the operator consents to) -- an action
## CodeTracer cannot perform unchecked and disabled with its reason under
## it, then `Approve` (CodeTracer's primary button) and `Dismiss`. It sits on
## the raised ground the timeline's `Running:` strip uses, pinned beneath the
## timeline's list so it never scrolls out of view while it waits. Once
## decided, it is gone and the timeline draws its record lines
## (`SuggestedActionsVM.recordLines`) after its own lines, with its own line
## renderers.
##
## Presses are routed operations (Input-Routing-And-Keymaps.md §5.1): a
## row's toggle carries `suggested-actions.toggle` with the action's id,
## `Approve` and `Dismiss` carry theirs; the host resolves a press through
## its pointer keymap and runs it here (`runSuggestedActionsPress`).

import nim_agents_isonim_viewmodels/agent_harbor/[suggested_actions_vm, session_timeline_vm]

export suggested_actions_vm, session_timeline_vm

const
  SuggestedActionsSurface* = "agent-harbor-suggested-actions"
  SuggestedToggleOperation* = "suggested-actions.toggle"
  SuggestedApproveOperation* = "suggested-actions.approve"
  SuggestedDismissOperation* = "suggested-actions.dismiss"
  SuggestedActionsOperations* = [SuggestedToggleOperation, SuggestedApproveOperation,
                                 SuggestedDismissOperation]
  SuggestedActionsLabel* = "SUGGESTED UI ACTIONS"
    ## The block's label, as the composer's section labels (capitals, the
    ## label role at the caption size).
  CheckedTerminalGlyph* = "[x]"
  UncheckedTerminalGlyph* = "[ ]"
  CheckMarkGlyph* = "\xE2\x9C\x94"   ## ✔ (heavy), inside a checked box (web, GPUI)

proc rowTextRole*(row: SuggestedActionRow): string =
  ## A row's words: the body role while checked; the caption-subtle role
  ## (`AhPalette.editedOut`, study D52's role for a left-out item) when the
  ## operator unchecked it or CodeTracer cannot perform it.
  if row.checked: "body" else: "edited-out"

proc reasonRole*(): string = "caption"
  ## The role of the reason under a disabled row.

proc blockFacts*(vm: SuggestedActionsVM): seq[(string, string)] =
  ## The facts the block carries in every host (`data-ah-*`), read back by
  ## the hosts' tests and the play checks.
  var checked = 0
  let rows = vm.rows
  for r in rows:
    if r.checked: inc checked
  @[("suggestion-phase", $vm.phase),
    ("suggestion-reason", vm.reasonText), ("actions", $rows.len),
    ("checked", $checked), ("approve-label", vm.approveLabel),
    ("approve-disabled", vm.approveDisabledReason)]

proc rowFacts*(row: SuggestedActionRow): seq[(string, string)] =
  result = @[("suggested-action", row.id), ("action-checked", $row.checked),
             ("action-disabled", $row.disabled), ("action-text", row.description)]
  if row.dimmed: result.add ("action-dimmed", "true")
  if row.reason.len > 0: result.add ("action-reason", row.reason)

proc runSuggestedActionsPress*(vm: SuggestedActionsVM; operation, target: string): bool =
  ## Runs the operation a press resolved to: toggling the action `target`,
  ## approving, dismissing. False for an operation that is not the block's,
  ## or a toggle with no target.
  if vm.isNil: return false
  case operation
  of SuggestedToggleOperation:
    if target.len == 0: return false
    vm.toggle(target)
    true
  of SuggestedApproveOperation:
    vm.approve()
    true
  of SuggestedDismissOperation:
    vm.dismiss()
    true
  else: false

proc timelineLinesWith*(lines: seq[TimelineLine]; tail: SuggestedActionsVM): seq[TimelineLine] =
  ## The timeline's lines followed by a decided suggestion's record lines
  ## (none while the block is shown, or with no tail).
  result = lines
  if tail != nil: result.add tail.recordLines

proc showsBlock*(tail: SuggestedActionsVM): bool =
  tail != nil and tail.shown

proc timelineSurfaceOf*(tail: SuggestedActionsVM): string =
  ## The surface a timeline's view says it is (`data-ah-surface`): the
  ## suggested-actions surface when it ends in a block or its record, the
  ## session activity timeline's otherwise.
  if tail != nil: SuggestedActionsSurface else: "agent-harbor-session-activity"
