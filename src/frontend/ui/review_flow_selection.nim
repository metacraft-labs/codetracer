## Which invocation of which reviewed function the reader is looking at.
##
## RV-5's invocation selector is an in-editor control (DeepReview-GUI.md §7),
## and a review shows the same function on two surfaces: the unified diff tab
## (`ui/unified_diff.nim`) and, in Open File mode, the ordinary editor tab
## (`ui/editor.nim`, §5.3). Both must draw the *same* call, or switching view
## mode would silently switch which execution the reader is being shown.
##
## The selection therefore lives here rather than on either host. It is keyed by
## `(file path, function key)` because that is the identity §7 gives it —
## "which invocation is displayed is a property of the code on screen" — so
## moving between functions, or between files, does not carry a choice made
## somewhere else.
##
## Module-level state is a deliberate exception to the project's
## no-globals rule, taken for the same reason `ui/unified_diff.nim`'s
## `unifiedDiffVMInstances` is module-level: the two hosts are separate
## Karax/Monaco components with no common owner, and threading a registry
## through both would mean widening every constructor between them. The state
## is confined to this module and is only reachable through the three procs
## below.
##
## The same reasoning applies to the *loop iteration* a review displays. A
## review renders one chip strip per line, so a line inside a loop has to name
## which pass through the loop it is showing; that is the question the
## debugger's own loop control answers, and it is a property of the code on
## screen for exactly the reason §7 gives for the invocation. It is keyed by
## `(file path, function key, loop index)` — the loop index is the one
## `ReviewFlowPlan.loops` uses, which is the dataset's own `loopId`.
##
## `clearReviewFlowSelections` is not called by the app, and deliberately
## so: there is no "leave a review" path today — a review is a process-lifetime
## mode, entered once by `ct review` and never torn down — and calling it from
## `startReviewNavigation` would be wrong, because that runs again on every
## re-sync of the review's data and would throw away the reader's choice each
## time. It exists as the seam for the moment a teardown path appears, and it
## is what the suite uses to isolate its cases from one another.
##
## Pure apart from that state: no DOM, no Monaco, no signals, and it compiles on
## both backends, so `src/tests/gui/tests/deepreview/review_flow_overlay_test.nim`
## can exercise it headlessly.

import std/tables

var reviewInvocationOrdinals: Table[string, int]
var reviewLoopIterations: Table[string, int]

proc reviewSelectionKey*(path, functionKey: string): string =
  ## The identity of one selectable function. The path comes first so the key
  ## reads as a location.
  path & ":" & functionKey

proc reviewInvocationOrdinal*(path, functionKey: string): int =
  ## Which invocation of `functionKey` in `path` is displayed, 0-based.
  ##
  ## An unseen function shows its first invocation — the same default the
  ## exported dataset's own contract gives a trace context ("The first entry is
  ## selected by default").
  reviewInvocationOrdinals.getOrDefault(
    reviewSelectionKey(path, functionKey), 0)

proc setReviewInvocationOrdinal*(path, functionKey: string; ordinal: int) =
  ## Record the reader's choice. Negative ordinals are refused rather than
  ## stored, so a host that miscomputes a step cannot poison the selection for
  ## every later read.
  if ordinal < 0:
    return
  reviewInvocationOrdinals[reviewSelectionKey(path, functionKey)] = ordinal

proc reviewLoopSelectionKey*(path, functionKey: string;
                             loopIndex: int): string =
  ## The identity of one selectable loop. The loop index is the dataset's own
  ## `loopId`, which `ReviewFlowPlan.loops` indexes by, so the key survives a
  ## re-decode of the same dataset.
  path & ":" & functionKey & ":loop" & $loopIndex

proc reviewLoopIteration*(path, functionKey: string; loopIndex: int): int =
  ## Which pass through `loopIndex` is displayed, 0-based.
  ##
  ## An unseen loop shows its first iteration, which is what the debugger's own
  ## loop control starts at (`FLOW_ITERATION_START = 0`).
  reviewLoopIterations.getOrDefault(
    reviewLoopSelectionKey(path, functionKey, loopIndex), 0)

proc setReviewLoopIteration*(path, functionKey: string;
                             loopIndex, iteration: int) =
  ## Record the reader's choice. Negative iterations are refused rather than
  ## stored, for the reason `setReviewInvocationOrdinal` refuses negative
  ## ordinals: a host that miscomputes a step must not poison every later read.
  if iteration < 0:
    return
  reviewLoopIterations[
    reviewLoopSelectionKey(path, functionKey, loopIndex)] = iteration

proc clearReviewFlowSelections*() =
  ## Forget every choice — invocation *and* loop iteration. Called when a
  ## review is entered or left, so neither can outlive the dataset that gave it
  ## meaning. Both are cleared together because both are keyed by a path and a
  ## function key that only that dataset defines.
  reviewInvocationOrdinals.clear()
  reviewLoopIterations.clear()
