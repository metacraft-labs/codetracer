## read_only_transition_test.nim
##
## Headless tests for `src/frontend/ui/read_only_transition.nim`, the decision
## the Debug → Edit transition turns on.
##
## Reported: *"After stopping a debug session, the editor remains read-only I
## think."*
##
## `GUI/Layout-And-Navigation/Mode-Transitions.md` § *5a. Arriving in Edit mode
## means the editor accepts typing*:
##
##   > After any Debug → Edit transition — *Stop* or the mode toggle — the
##   > editor on screen accepts a keystroke into its buffer. Editability is a
##   > property of the mode the user is in, not of the route they took to it.
##
## THE CONTROL-DATA RUN. Every assertion below has been observed FAILING
## against the pre-fix answer. The old behaviour is not deleted — it is
## reachable, and only from here:
##
##     nim c -r -d:ctReadOnlyTransitionDiffGuard \
##       --path:src src/tests/gui/tests/editor/read_only_transition_test.nim
##
## which restores `readOnlyTransitionAppliesEditability` to `flagChanged`, the
## expression `beginReadOnlyTransition` and `finishReadOnlyTransition` were
## guarded on. Nothing in the product defines that symbol. An assertion that has
## never been seen failing is not evidence, and a new module's tests cannot be
## run against a tree that does not contain the module, so the defect is carried
## rather than the whole tree reverted.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/editor/read_only_transition_test.nim

import std/unittest

import ../../../../frontend/ui/read_only_transition

suite "a transition arrives at a state, it does not apply a difference":

  test "STOP AFTER CTRL+E: the flag already says Edit, and the editors are " &
       "still reconciled":
    # THE REPORTED DEFECT, in the exact shape that reaches it.
    #
    # `toggleReadOnly` (CTRL+E, `aToggleReadOnly`) clears `data.ui.readOnly`
    # mid-session and deliberately does NOT touch `data.ui.mode` — that is
    # `Mode-Transitions.md` §4.4, working as specified. So a Stop pressed
    # afterwards asks for `readOnly = false` when the flag already reads
    # `false`, and the transition saw nothing to do.
    #
    # It had plenty to do. `data.ui.readOnly` is a model flag; the `readOnly`
    # option on a live Monaco instance is a different fact, and `switchToEdit`
    # swaps the whole GoldenLayout tree between the two halves of the
    # transition — during which editors are detached, reattached, and rebuilt.
    # Whether the two facts agree at that moment is precisely what the guard
    # could not see.
    let plan = planReadOnlyTransition(
      flagChanged = false,      # CTRL+E already cleared it
      readOnly = false,         # Stop asks for an editable session
      rearrangePanels = false,  # switchToEdit installed the edit layout itself
      modeIsEdit = true)

    check plan.applyEditability
    check plan.applyShortcutContextKeys

  test "the editors are reconciled on every combination, including the " &
       "no-change ones":
    # Stated exhaustively rather than for the one reported case, because §5a is
    # about the state arrived at and says nothing about the route. A table with
    # a hole in it is a rule with an exception nobody wrote down.
    for flagChanged in [false, true]:
      for readOnly in [false, true]:
        for rearrangePanels in [false, true]:
          for modeIsEdit in [false, true]:
            let plan = planReadOnlyTransition(
              flagChanged, readOnly, rearrangePanels, modeIsEdit)
            check plan.applyEditability
            check plan.applyShortcutContextKeys

  test "the shortcut context keys are reset whenever the editors are":
    # Not a restatement of the case above. `finishReadOnlyTransition`'s early
    # return skipped BOTH the `setEditorsEditable` call and the
    # `enableDebugShortcuts`/`disableDebugShortcuts` loop, and the second is
    # what resets Monaco's `readOnly` context key. A fix that reconciled only
    # the editability option would leave the session's key saying Debug in an
    # Edit-mode window, and would pass a test that asked only about
    # `applyEditability`.
    let plan = planReadOnlyTransition(
      flagChanged = false, readOnly = false,
      rearrangePanels = false, modeIsEdit = true)
    check plan.applyEditability == plan.applyShortcutContextKeys

suite "the panel half is unchanged, and is the only thing `changed` decides":
  ## Only the EDITOR half was wrong. These pin the existing behaviour so a
  ## reader can see the fix did not quietly move the panels too — and so a
  ## failure in the suite above cannot be confused for one here.

  test "a caller that installed a whole layout is left alone":
    # `Mode-Transitions.md` §4.5: "panels are not created or destroyed by a
    # transition beyond what each mode's layout declares". Running the
    # incremental hide-and-show as well is not redundant, it is destructive —
    # it restored the edit arrangement over a debug layout that had just been
    # installed.
    for flagChanged in [false, true]:
      for readOnly in [false, true]:
        for modeIsEdit in [false, true]:
          check panelAction(flagChanged, readOnly,
                            rearrangePanels = false,
                            modeIsEdit = modeIsEdit) == apaLeaveAlone

  test "CTRL+E, which changes editability without changing the layout":
    # The only caller that still needs the incremental path.
    check panelAction(flagChanged = true, readOnly = true,
                      rearrangePanels = true,
                      modeIsEdit = true) == apaReopenDebugPanels
    check panelAction(flagChanged = true, readOnly = false,
                      rearrangePanels = true,
                      modeIsEdit = true) == apaCloseDebugPanels

  test "an unchanged flag closes the debugger's panels but never reopens them":
    # The asymmetry `setEditorsReadOnlyState` has always had, preserved
    # deliberately: entering Edit mode still closes the auxiliary panels when
    # the flag was already `false`, and no arm of the no-change case reopens
    # them.
    check panelAction(flagChanged = false, readOnly = false,
                      rearrangePanels = true,
                      modeIsEdit = true) == apaCloseDebugPanels
    check panelAction(flagChanged = false, readOnly = true,
                      rearrangePanels = true,
                      modeIsEdit = true) == apaLeaveAlone
    check panelAction(flagChanged = false, readOnly = false,
                      rearrangePanels = true,
                      modeIsEdit = false) == apaLeaveAlone
