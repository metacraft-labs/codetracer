## Pure layering rules for the editor's Monaco line decorations.
##
## Like `ui/flow_loop_math.nim` and `ui/trace_redraw_policy.nim`, this module
## deliberately has **no imports**: `ui/editor.nim` is JS-only (karax + the
## Monaco bindings), so the rule that decides *when a decoration layer may be
## replaced* could not be unit-tested at all while it lived inline in
## `styleLines`. Everything here compiles on the C backend, so
## `src/tests/gui/tests/editor/editor_decorations_test.nim` exercises it
## headlessly on both the native and the JS lane.
##
## Why the split exists (issue #594)
## ---------------------------------
## `styleLines` used to keep a single flat `seq[(DeltaDecoration, bool)]` where
## the `bool` was always `true`, and rebuilt it as
##
##     self.decorations = self.decorations.filterIt(not it[1]).concat(new...)
##
## — i.e. it dropped *everything* it had ever written and replaced it with
## whatever the current call computed. That is fine when the inputs are always
## available, and fatal when one of them is not: `onCompleteMove` reloads the
## flow on every step, `loadFlow` installs a brand-new `FlowComponent` whose
## `flow` field is nil, and `editorAfterRedraw` then runs *synchronously* while
## it is still nil. The conditional-branch styles (`flow-taken` /
## `flow-not-taken`) and the per-line hit/skip styles therefore computed as
## empty sets and were handed to `deltaDecorations`, which removed them from
## Monaco. Nothing repainted them when the flow data finally arrived.
##
## The cure is to stop treating "no flow data right now" as "no flow
## decorations": decorations are tracked as two independent layers and the flow
## layer is *retained* across the window in which the flow is being reloaded.
## The `bool` in the existing `(DeltaDecoration, bool)` pair is repurposed as
## that layer tag, so no shared type has to change.

const
  BaseDecorationLayer* = false
    ## Decorations whose inputs are always available on any redraw: the
    ## current-line highlight, the diff / DeepReview stripes and the value
    ## origin-chain hop markers. Recomputed from scratch every time.
  FlowDecorationLayer* = true
    ## Decorations derived from omniscience flow data: `flow-taken` /
    ## `flow-not-taken` whole-line classes and the `line-flow-hit` /
    ## `line-flow-skip` / `line-flow-unknown` inline classes. Only meaningful
    ## when flow data is actually loaded.

func decorationLayer*[T](decorations: openArray[(T, bool)], layer: bool): seq[T] =
  ## Extract one layer out of the interleaved bookkeeping array.
  result = @[]
  for entry in decorations:
    if entry[1] == layer:
      result.add(entry[0])

func flowDecorationLayer*[T](decorations: openArray[(T, bool)]): seq[T] =
  ## The flow-derived decorations currently applied to the editor.
  decorationLayer(decorations, FlowDecorationLayer)

func baseDecorationLayer*[T](decorations: openArray[(T, bool)]): seq[T] =
  ## The always-recomputed decorations currently applied to the editor.
  decorationLayer(decorations, BaseDecorationLayer)

func nextFlowDecorationLayer*[T](
    previous, computed: openArray[T],
    flowDataAvailable: bool): seq[T] =
  ## The flow decoration layer to apply on this redraw.
  ##
  ## `flowDataAvailable` is false exactly in the window between `loadFlow`
  ## installing a fresh `FlowComponent` and the `ct/updated-flow` event
  ## delivering its data. In that window `computed` is necessarily empty — not
  ## because the branches stopped being taken, but because nobody has told the
  ## frontend about them yet. Replacing the layer with that empty set is what
  ## made the branch colours flicker away on every step, so we keep what is on
  ## screen instead.
  ##
  ## When data *is* available the layer is replaced wholesale rather than
  ## merged: `computed` is the complete truth for the new position, and merging
  ## would accumulate duplicate decorations for lines that are still taken.
  if flowDataAvailable:
    @computed
  else:
    @previous

func mergeDecorationLayers*[T](base, flowLayer: openArray[T]): seq[(T, bool)] =
  ## Recombine the two layers into the tagged bookkeeping array, so the next
  ## redraw can tell them apart again.
  result = @[]
  for decoration in base:
    result.add((decoration, BaseDecorationLayer))
  for decoration in flowLayer:
    result.add((decoration, FlowDecorationLayer))
