## editor_decorations_test.nim
##
## Headless unit tests for the editor's Monaco decoration LAYERING rules
## (`src/frontend/ui/editor_decoration_layers.nim`).
##
## Regression target: issue #594 — "conditional branch colours vanish".
##
## The reporter's follow-up reframed the bug: the `flow-taken` /
## `flow-not-taken` styles ARE rendered and are then lost again, so this is a
## redraw-lifecycle bug, not a missing-CSS bug. The destructive sequence is:
##
##   1. every completed move makes `EditorViewComponent.onCompleteMove` decide
##      `needsFlowReload` (the rrTicks always differs), and call `loadFlow`;
##   2. `loadFlow` replaces `self.flow` with a brand-new `FlowComponent` whose
##      `flow` field is nil, and only then asks the backend for the data;
##   3. `editorAfterRedraw` runs synchronously, right there, while it is nil;
##   4. so `conditionStyleLines()` / `flowStyleLines()` return empty seqs — not
##      because no branch was taken, but because nobody has been told yet;
##   5. and `styleLines` handed that empty set to Monaco's `deltaDecorations`,
##      which removed the colours. Nothing repainted them when the flow data
##      finally arrived.
##
## `nextFlowDecorationLayer` is the pure decision that makes step 5 impossible:
## the flow layer is RETAINED while flow data is unavailable, and only replaced
## when there is real data to replace it with. These tests reproduce exactly the
## state `onCompleteMove` creates between `loadFlow` and `ct/updated-flow`.
##
## The decorations are modelled here as plain CSS class names rather than
## Monaco's `DeltaDecoration` — `lib/monaco_lib.nim` is JS-only (dom/kdom), and
## the layering rule is a property of the *sequence bookkeeping*, not of the
## decoration payload, so the module (and this test) is generic over it. That
## keeps the suite compiling and running on both the native and the JS lane.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/editor/editor_decorations_test.nim

import std/unittest

import ../../../../frontend/ui/editor_decoration_layers

type
  # Stand-in for `DeltaDecoration`: the layering rules only ever move whole
  # decoration values around, so a value with an observable identity is all
  # that is needed to detect a wipe, a duplicate or a mis-tagged layer.
  Decoration = object
    line: int
    class: string

func deco(line: int, class: string): Decoration =
  Decoration(line: line, class: class)

# The two decorations the reporter watches for: the taken branch of an
# `if`/`else` and the branch that was not taken.
let
  flowTaken = deco(4, "flow-taken")
  flowNotTaken = deco(7, "flow-not-taken")
  # `colorLines()` (current debugger line) and the DeepReview diff stripes are
  # the always-recomputable base layer.
  currentLine = deco(4, "on on-4")
  diffAdded = deco(9, "diff-added")

suite "editor flow decoration layer":

  test "flow layer survives the window where the flow is being reloaded":
    # THE regression case (#594). `loadFlow` has just installed a fresh
    # FlowComponent with `flow == nil`, so the computed flow styles are empty.
    # Before the fix this empty set was pushed straight into Monaco.
    let previous = @[flowTaken, flowNotTaken]
    let next = nextFlowDecorationLayer(
      previous = previous,
      computed = newSeq[Decoration](),
      flowDataAvailable = false)

    check next.len == 2
    check flowTaken in next
    check flowNotTaken in next

  test "flow layer is replaced wholesale once flow data arrives":
    # `ct/updated-flow` landed: the new set is the complete truth for the new
    # position and must replace — not merge with — the retained one, otherwise
    # every step would accumulate a duplicate decoration per still-taken line.
    let previous = @[flowTaken, flowNotTaken]
    let computed = @[deco(4, "flow-taken"), deco(11, "flow-not-taken")]
    let next = nextFlowDecorationLayer(previous, computed, flowDataAvailable = true)

    check next == computed
    check next.len == 2
    check flowNotTaken notin next

  test "flow layer is cleared when real data says no branch is taken":
    # Retention must not become stickiness: with data available, an empty
    # computed set is a genuine "this position has no branch styling".
    let next = nextFlowDecorationLayer(
      previous = @[flowTaken, flowNotTaken],
      computed = newSeq[Decoration](),
      flowDataAvailable = true)

    check next.len == 0

  test "retaining the flow layer does not disturb the base layer":
    # The base layer (current-line highlight, diff stripes, origin hops) is
    # recomputed on every redraw and must land exactly as computed, while the
    # retained flow layer rides along beside it.
    let applied = @[(currentLine, BaseDecorationLayer),
                    (diffAdded, BaseDecorationLayer),
                    (flowTaken, FlowDecorationLayer),
                    (flowNotTaken, FlowDecorationLayer)]

    let retained = nextFlowDecorationLayer(
      previous = flowDecorationLayer(applied),
      computed = newSeq[Decoration](),
      flowDataAvailable = false)
    # The base layer as a later redraw would recompute it: the debugger moved
    # one line down, the diff stripe is unchanged.
    let recomputedBase = @[deco(5, "on on-5"), diffAdded]
    let merged = mergeDecorationLayers(recomputedBase, retained)

    check baseDecorationLayer(merged) == recomputedBase
    check flowDecorationLayer(merged) == @[flowTaken, flowNotTaken]
    check merged.len == 4

  test "base layer is untouched when the flow layer is replaced":
    let applied = @[(currentLine, BaseDecorationLayer),
                    (flowTaken, FlowDecorationLayer)]
    let computed = @[deco(11, "flow-not-taken")]
    let merged = mergeDecorationLayers(
      @[currentLine, diffAdded],
      nextFlowDecorationLayer(flowDecorationLayer(applied), computed,
                              flowDataAvailable = true))

    check baseDecorationLayer(merged) == @[currentLine, diffAdded]
    check flowDecorationLayer(merged) == computed

  test "layer tags round-trip through merge and extraction":
    # `styleLines` stores both layers in one array and has to be able to tell
    # them apart on the next redraw; a mis-tag would silently resurrect the
    # wipe this module exists to prevent.
    let merged = mergeDecorationLayers(@[currentLine], @[flowTaken, flowNotTaken])

    check merged.len == 3
    check merged[0] == (currentLine, BaseDecorationLayer)
    check merged[1] == (flowTaken, FlowDecorationLayer)
    check merged[2] == (flowNotTaken, FlowDecorationLayer)
    check baseDecorationLayer(merged) == @[currentLine]
    check flowDecorationLayer(merged) == @[flowTaken, flowNotTaken]

  test "an empty applied set retains nothing and merges to nothing":
    let empty = newSeq[(Decoration, bool)]()
    check flowDecorationLayer(empty).len == 0
    check baseDecorationLayer(empty).len == 0
    check mergeDecorationLayers(newSeq[Decoration](), newSeq[Decoration]()).len == 0
