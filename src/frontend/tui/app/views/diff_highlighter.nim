## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/diff_highlighter.nim — CTUI-7. CodeTracer-TUI.md §3.3.4's "Diff
## Highlighting: when stepping forward or backward, any variable whose value
## changed at the step that produced the current state is styled exactly as
## the desktop styles a changed value" — AMENDED 2026-10-05 (PLAT-51): the
## `[MOD]` badge is DROPPED; the changed value takes the shared changed-value
## style (`ChangedValueStyle`, the same design token the desktop's
## `.value-changed` and GPUI's state pane use).
##
## THE MODEL MOVED (PLAT-51): the timeline of observed stops and the diff are
## now the shared `viewmodels/value_changes.nim`, re-exported here, so every
## front-end marks the same rows. What follows is the rule it implements.
##
## ## THE ANCHOR IS THE RECORDING'S PREDECESSOR, NOT THE TICK YOU CAME FROM
##
## This is the whole file, and it is CTUI-7's one genuinely subtle contract:
##
##   > "The diff compares the current tick against the tick before the last
##   > navigation — including *backward* navigation, where the naive
##   > implementation marks everything modified."
##
## Read as "compare against whatever was on screen a moment ago", that sentence
## produces a pane which, after `step forward` over `total = …` and then `step
## back`, marks `total` MODIFIED AGAIN — because the value did indeed differ
## between the two ticks. And CTUI-7's own test says the opposite must happen:
##
##   > "steps *backward* and asserts the value reverts and THE BADGE CLEARS."
##
## Both sentences are true at once under exactly one reading, and it is the one
## §3.3.4 states directly: the badge means *"the step that produced this state
## changed this variable"*, so the comparison is always against **the tick
## immediately before the current one IN THE RECORDING**, whichever direction
## the user arrived from.
##
##   * forward `T-1 → T`: the anchor is `T-1` — which IS "the tick before the
##     last navigation", so the two readings agree here and a forward-only test
##     cannot tell them apart. `total` is marked.
##   * backward `T → T-1`: the anchor is `T-2`, NOT `T`. `total` at `T-1` equals
##     `total` at `T-2`, so the badge clears, the value has reverted, and the
##     pane says what the statement at `T-1` did rather than what undoing `T`
##     did.
##
## Two properties fall out of this and both are worth having: the badges at a
## tick are a property OF THAT TICK, so revisiting it shows the same screen; and
## a backward step cannot mark a row that no statement ever wrote.
##
## **A naive implementation is not a strawman here.** Diffing the previously
## *displayed* values against the new ones marks every difference on a backward
## step and every difference after a jump — which on a jump between frames is
## every row. `tests/test_variable_diff_highlighting.nim` drives all three
## cases: forward over an assignment, backward over the same one, and a step
## that changes nothing.
##
## ## THE TIMELINE HOLDS OBSERVATIONS, AND SAYS WHEN IT HAS NONE
##
## The anchor has to come from somewhere, and nothing in the ViewModel layer
## keeps a variable's value at a tick the session is not on: `StateVM`'s
## `valueHistory` is filled only by an explicit `ct/load-history` request for
## one named expression (`toggleHistory`), and `store.locals.locals` holds
## exactly the current stop's answer. So this module keeps what the session has
## already seen, and a tick whose predecessor was never observed reports
## `anchorKnown == false` and marks NOTHING.
##
## That is the honest answer and not a degradation: with no predecessor the pane
## cannot know what the step changed, and a pane that guessed would mark every
## row on the first stop of every session.
##
## ## Pure
##
## Nothing here knows a ViewModel or a debugger exists. `app/variables_binding`
## feeds it.

import codetracer_embed
export ValueTimeline, VariableDiff, VariableChange, ValueSnapshot,
  initValueTimeline, observedTicks, observe, snapshotAt, hasTick,
  anchorTickFor, diffAt, changeFor, isModified, modifiedPaths, describe,
  DefaultTimelineCapacity, snapshotOf

import ./styled_row

const
  ChangedValueStyle* = CellStyle(role: srValueModified)
    ## PLAT-51: THE CHANGED VALUE'S STYLE — the value cell of a row the step
    ## changed, in the shared changed-value accent (`srValueModified`, bound
    ## to the design token the desktop's `.value-changed` uses). No badge.
