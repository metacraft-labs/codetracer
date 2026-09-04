## What a read-only transition must DO, decided separately from doing it.
##
## Like `ui/flow_line_styles.nim`, `ui/flow_loop_math.nim` and
## `ui/trace_redraw_policy.nim`, this module deliberately has **no imports**:
## `ui_js.nim` is JS-only and enormous, so the decision that the Debug → Edit
## transition turns on could not be exercised at all while it lived inline as
## two `if`s. Everything here compiles on the C backend, so
## `src/tests/gui/tests/editor/read_only_transition_test.nim` runs it headlessly.
##
## The rule it encodes
## -------------------
## `Mode-Transitions.md` § *5a. Arriving in Edit mode means the editor accepts
## typing* states the transition as an **arrival**:
##
##   > After any Debug → Edit transition — *Stop* or the mode toggle — the
##   > editor on screen accepts a keystroke into its buffer. Editability is a
##   > property of the mode the user is in, not of the route they took to it.
##
## A postcondition is not a diff. The transition was implemented as one:
## `beginReadOnlyTransition` called `setEditorsEditable` only `if result` — the
## flag having *changed* — and `finishReadOnlyTransition` returned early on
## `not changed`, which under Stop also skipped the `disableDebugShortcuts`
## loop that resets Monaco's `readOnly` context key. So with `data.ui.readOnly`
## already `false` when Stop is pressed, **Stop made no `setEditorsEditable`
## call at all** and every live Monaco instance kept whatever it was last
## given.
##
## That disagreement is reachable, and by a documented route rather than an
## exotic one: `CTRL+E` (`aToggleReadOnly`) clears the flag mid-session without
## moving `data.ui.mode`, which is `Mode.ReadOnlyDoesNotMoveMode` working as
## specified. A transition specified as a diff cannot repair a disagreement it
## does not see, because the disagreement is precisely what it is blind to.
##
## THE PANEL HALF IS DELIBERATELY LEFT ALONE. Only the editor half was wrong,
## and `panelAction` below reproduces the existing behaviour exactly — including
## the asymmetry that an unchanged flag never *reopens* the debugger's auxiliary
## panels, only closes them. Keeping it identical is what lets the test isolate
## the editability half: if the fix had moved both, a failure could not say
## which one it was about.

type
  AuxiliaryPanelAction* = enum
    ## What the transition does to the debugger's auxiliary panels.
    apaLeaveAlone           ## the caller installed a whole layout; §4.5 says
                            ## the layout already declares which panes exist
    apaCloseDebugPanels     ## going editable without a layout swap
    apaReopenDebugPanels    ## going read-only without a layout swap

  ReadOnlyTransitionPlan* = object
    ## Everything `finishReadOnlyTransition` has to decide.
    applyEditability*: bool
      ## call `setEditorsEditable(not readOnly)` over `data.ui.editors`
    applyShortcutContextKeys*: bool
      ## run the `enableDebugShortcuts` / `disableDebugShortcuts` loop, which is
      ## what resets Monaco's `readOnly` context key
    panels*: AuxiliaryPanelAction

func readOnlyTransitionAppliesEditability*(flagChanged: bool): bool =
  ## THE DEFECT WAS EXACTLY THIS ANSWER, AND THIS IS THE WHOLE FIX.
  ##
  ## It was `flagChanged`. It is now unconditional, because §5a is a statement
  ## about the state the transition ARRIVES AT and the flag is not that state —
  ## the editors are. `data.ui.readOnly` and the `readOnly` option on a live
  ## Monaco instance are two different facts, and the guard assumed they could
  ## not disagree.
  ##
  ## Reconciling unconditionally is cheap and idempotent: `setEditorsEditable`
  ## is one `updateOptions({ readOnly, minimap })` per open editor, and handing
  ## Monaco the value it already holds is a no-op inside Monaco.
  ##
  ## `flagChanged` is still a parameter, and is still what the pre-fix build
  ## returned, so `read_only_transition_test.nim` can state the old answer next
  ## to the new one and say which case separates them.
  when defined(ctReadOnlyTransitionDiffGuard):
    # THE PRE-FIX ANSWER, reachable only by defining this symbol, and defined
    # ONLY by the control-data run in `read_only_transition_test.nim`'s header.
    # It exists so the new assertions can be observed FAILING against the
    # behaviour they were written to detect — an assertion never seen failing is
    # not evidence. Nothing in the product defines it.
    flagChanged
  else:
    true

func panelAction*(flagChanged: bool; readOnly: bool;
                  rearrangePanels: bool; modeIsEdit: bool): AuxiliaryPanelAction =
  ## Unchanged behaviour, restated. See the module header for why it is not
  ## being fixed here.
  if not rearrangePanels:
    # The caller has already installed the entering mode's whole layout.
    apaLeaveAlone
  elif flagChanged:
    if readOnly: apaReopenDebugPanels else: apaCloseDebugPanels
  else:
    # The no-change arm `setEditorsReadOnlyState` has always had: entering Edit
    # mode still closes the debugger's auxiliary panels even when the flag was
    # already `false`. It has never reopened them from this arm.
    if modeIsEdit and not readOnly: apaCloseDebugPanels else: apaLeaveAlone

func planReadOnlyTransition*(flagChanged: bool; readOnly: bool;
                             rearrangePanels: bool;
                             modeIsEdit: bool): ReadOnlyTransitionPlan =
  ## The whole decision, in one value the caller can also log.
  ReadOnlyTransitionPlan(
    applyEditability: readOnlyTransitionAppliesEditability(flagChanged),
    applyShortcutContextKeys: readOnlyTransitionAppliesEditability(flagChanged),
    panels: panelAction(flagChanged, readOnly, rearrangePanels, modeIsEdit))
