## dom_suggested_actions_presses.nim — a DOM story host's procedures for the
## suggested-actions block's presses
## (`viewmodel/views/isonim_agent_harbor_suggested_actions_view`): what
## StoryBook registers (`storybook_components.mountAgentHarborSuggestedActions`).
##
## Input-Routing-And-Keymaps.md §4 and §5.1, as the timeline's
## (`dom_activity_presses`): the block's elements carry their operations
## (`suggested-actions.toggle`, `-approve`, `-dismiss`,
## `agent_harbor_suggested_actions_words`) and hold no handler. The page's
## one pointer listener resolves a press on one through the pointer keymap
## and, with no row of the user's, runs the procedure registered here for the
## operation the element carries, on the element's target (`data-ah-target`).
## The block has no keys of its own (study D59): its toggles and buttons are
## pressed.
##
## Refuses to own: what an operation does
## (`agent_harbor_suggested_actions_words`) and which operation a press runs
## (the router).

when not defined(js):
  {.error: "stories/dom_suggested_actions_presses is a DOM front-end's (JS).".}

import ../viewmodel/views/agent_harbor_suggested_actions_words
import ../viewmodel/input/[dom_pointer, dom_pane_presses]
from ../viewmodel/views/agent_harbor_activity_words import PressTargetAttribute

var shownBlock: proc(): SuggestedActionsVM
  ## The block on the page when a press comes (nil: none).

proc registerSuggestedActionsPresses*(shown: proc(): SuggestedActionsVM) =
  ## Register a procedure for every operation a press on the block carries,
  ## acting on the block `shown` answers when the press comes (nil: none is
  ## on the page, and the press is inert). The last registration wins.
  shownBlock = shown
  for each in SuggestedActionsOperations:
    closureScope:
      let operation = each
      registerElementOperation(operation, proc(p: ElementPress): bool =
        let vm = if shownBlock.isNil: nil else: shownBlock()
        if vm.isNil: return false
        vm.runSuggestedActionsPress(operation,
                                    readerOf(p.element)(PressTargetAttribute)))

proc routeSuggestedActionsPresses*(shown: proc(): SuggestedActionsVM) =
  ## `registerSuggestedActionsPresses`, and the base keymap's pointer rows
  ## for a page with no keymap of its own (`installBaseElementRouting`).
  registerSuggestedActionsPresses(shown)
  installBaseElementRouting()
