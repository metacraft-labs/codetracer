## Pure per-line rules for the Omniscience flow overlay.
##
## Like `ui/flow_loop_math.nim`, `ui/trace_redraw_policy.nim` and
## `ui/editor_decoration_layers.nim`, this module deliberately has **no
## imports**: `ui/editor.nim` is JS-only (karax plus the Monaco bindings), so
## the decision that turns a loaded flow window into one inline CSS class per
## source line could not be unit-tested at all while it lived inline in
## `flowStyleLines`. Everything here compiles on the C backend, so
## `src/tests/gui/tests/editor/flow_line_styles_test.nim` exercises it
## headlessly on both the native and the JS lane.
##
## Why it was extracted (RV-5)
## ---------------------------
## `flowStyleLines` read
##
##     flow.flow.branchesTaken[0][0].table.hasKey(position)
##
## with no bounds and no nil check. `FlowViewUpdate.branchesTaken` is a
## `seq[seq[BranchesTaken]]`, and the backend's own constructor
## (`FlowViewUpdate::new` in `src/db-backend/src/task.rs`) is the only thing
## that guarantees it starts life as `vec![vec![BranchesTaken::default()]]`.
## Any `FlowViewUpdate` that did *not* come from that constructor — a hand-built
## one, a partially decoded one, or the review-dataset adapter this milestone
## adds — makes that expression an out-of-bounds access rather than a no-op, and
## the resulting `IndexDefect` aborts `applyEventualStylesLines` before any
## decoration is applied. `conditionStyleLines` in the same file already checked
## all three conditions; this one did not. The guard now lives in
## `hasBranchStateAt` and is shared by both readings of the same data.
##
## Genericity
## ----------
## The procs are generic over the flow value rather than typed against
## `FlowViewUpdate` because that type is declared in an *included* module
## (`common/common_types/codetracer_features/flow.nim`) and therefore exists
## twice with incompatible field types — once through `common/types.nim`
## (`langstring = string`, `TableLike = Table`) and once through
## `frontend/types.nim` (`langstring = cstring`, `TableLike = JsAssoc`). A
## module naming either copy would only be usable from one of the two worlds.
## Instantiating one generic proc over both is what makes the renderer and the
## headless tests run *the same* code — the same reasoning `review_entry.
## reviewDatasetFrom` records.

type
  FlowLineStyleKind* = enum ## Which inline flow class a source line earns.
    flskHit      ## the line was executed in this flow window
    flskSkip     ## the window is finished and the line was never reached
    flskUnknown  ## the window is still loading, so nothing is known yet

  FlowStyledLine* = object
    ## One line of the displayed function and the class it earns.
    position*: int
    kind*: FlowLineStyleKind

const
  FlowLineHitClass* = "line-flow-hit"
  FlowLineSkipClass* = "line-flow-skip"
  FlowLineUnknownClass* = "line-flow-unknown"

func flowLineStyleClass*(kind: FlowLineStyleKind): string =
  ## The CSS class `styles/components/flow.styl` styles this kind with.
  case kind
  of flskHit: FlowLineHitClass
  of flskSkip: FlowLineSkipClass
  of flskUnknown: FlowLineUnknownClass

proc hasBranchStateAt*[B](branchesTaken: openArray[B]; position: int): bool =
  ## Does the *outer* branch table — `branchesTaken[0][0]`, the one holding the
  ## conditions that are not inside any loop — record a state for `position`?
  ##
  ## False whenever the answer cannot be looked up: an empty outer seq, an
  ## empty inner seq, or a nil table. Those are the three ways the unguarded
  ## `[0][0].table` raised instead of answering. Reporting "no state recorded"
  ## for them is the correct reading, not a papering-over: a flow window that
  ## carries no branch information has no branch to exclude from the per-line
  ## styling, which is exactly what an absent key means.
  if branchesTaken.len == 0:
    return false
  if branchesTaken[0].len == 0:
    return false
  let table = branchesTaken[0][0].table
  # `JsAssoc` is nilable, `Table` is not; `when compiles` picks the check that
  # exists in the world this instantiation is compiled for.
  when compiles(table.isNil):
    if table.isNil:
      return false
  table.hasKey(position)

proc flowLineStyleKind*[F](flow: F; position: int; finished: bool):
    FlowLineStyleKind =
  ## The class `position` earns in `flow`.
  ##
  ## Identical to `common_types/codetracer_features/flow.toLineFlowKind`, which
  ## this module cannot call: that proc lives in an included module, so calling
  ## it would mean naming one of the two `FlowViewUpdate` copies and losing the
  ## genericity the header explains. `relevantStepCount` is, despite its name, a
  ## list of *line numbers* the walker visited — see
  ## `flow_preloader.rs:761`, which pushes `line`, not a step count.
  if position in flow.relevantStepCount:
    flskHit
  elif finished:
    flskSkip
  else:
    flskUnknown

proc flowStyledLines*[F](flow: F; finished: bool): seq[FlowStyledLine] =
  ## Every line of the function `flow` describes, with the class it earns.
  ##
  ## Excluded, matching the behaviour `flowStyleLines` has always had:
  ##
  ##   * lines the outer branch table has a state for — those are painted by
  ##     `conditionStyleLines`' `flow-taken` / `flow-not-taken` pass instead, and
  ##     painting both would fight over the same line;
  ##   * comment lines, which are not executable and would all report as skipped.
  ##
  ## A nil flow, or one whose location spans no lines, yields an empty seq
  ## rather than raising.
  result = @[]
  when compiles(flow.isNil):
    if flow.isNil:
      return
  let first = flow.location.functionFirst + 1
  let last = flow.location.functionLast
  for position in first .. last:
    if hasBranchStateAt(flow.branchesTaken, position):
      continue
    if position in flow.commentLines:
      continue
    result.add(FlowStyledLine(
      position: position,
      kind: flowLineStyleKind(flow, position, finished)))
