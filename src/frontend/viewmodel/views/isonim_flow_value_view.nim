## views/isonim_flow_value_view.nim — the Omniscience value chip and the
## parallel-column band, as views (Shared-DOM-Front-Ends D7.4 (b)).
##
## "Keep the standard CodeTracer Omniscience appearance, produced by the same
## code path as normal debugging." — `DeepReview-GUI.md` §4.4. The chip and the
## band were built by hand in `ui/flow_value_dom.nim` for the debugger's inline
## flow and the review's diff tab; they are now one set of procs generic over
## the renderer (`[R, N]`, the shape every `isonim_*_view.nim` has), rendered
## under `WebRenderer` in the editor and under `MockRenderer` in the headless
## tests. `ui/flow_value_dom` keeps its procs as the web host's thin wrappers,
## so its callers are unchanged.
##
## The shapes, exactly as the debugger draws them:
##
##   span.ct-omni-value                       (renderFlowValueContainer)
##     span.ct-omni-name : "x"                (renderFlowValueName)
##     span.flow-<mode>-value-box#id[iteration] : "10"   (renderFlowValueBox)
##
##   div.flow-parallel.flow-parallel-loop[left]          (renderFlowValueBand)
##     div.flow-parallel-loop-values.loop-N             (renderFlowValueLoopValues)
##       div.flow-parallel-group                        (renderFlowValueGroup)
##         div.flow-parallel-values.flow-parallel-values-width-W[width] …
##                                                       (renderFlowValueColumn)
##
## The procs build one element each; a host composes them (the band's columns
## and chips are appended by whoever knows which passes and values exist), as
## the hand-built versions were composed.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

export signals, computation, components

const
  FlowValueContainerClass* = "ct-omni-value"
    ## The flex container a chip's name and value live in; it carries the
    ## appearance (`styles/components/flow.styl` has no rule for the value box
    ## alone).
  FlowValueNameClass* = "ct-omni-name"
  FlowValueColumnClass* = "flow-parallel-values"
  FlowValueGroupClass* = "flow-parallel-group"
  FlowValueLoopValuesClass* = "flow-parallel-loop-values"
  FlowValueBandClass* = "flow-parallel"
  FlowValueBandLoopClass* = "flow-parallel-loop"
  FlowValueBandSingleClass* = "flow-parallel-value-single"
  FlowValueEmptyClass* = "flow-parallel-value"
    ## The span drawn where a name has no value at a step, or a whole pass
    ## never reached the line.

type
  FlowStyle* = seq[(string, string)]
    ## Inline style properties, by the DOM's property name (`width`, `left`,
    ## `fontSize`, …), applied in order.

proc applyFlowStyle[R, N](r: R; node: N; style: FlowStyle) =
  for (name, value) in style:
    r.setStyle(node, name, value)

proc renderFlowValueContainer*[R, N](r: R; style: FlowStyle = @[]): N =
  ## `span.ct-omni-value` — one variable's name and value together.
  result = ui(r):
    span(class = FlowValueContainerClass)
  applyFlowStyle[R, N](r, result, style)

proc renderFlowValueName*[R, N](r: R; name: string): N =
  ## `span.ct-omni-name` — the name half of a chip.
  ui(r):
    span(class = FlowValueNameClass):
      text name

proc renderFlowValueBox*[R, N](r: R; id, className, valueText: string;
                              iteration: int; style: FlowStyle = @[];
                              maxWidth = ""): N =
  ## The value half of a chip: `span.<className>#<id>[iteration]`.
  ##
  ## `maxWidth` is applied only when non-empty — how the debugger caps a value
  ## long enough to need "view more" without capping every other one. The
  ## `iteration` attribute is part of the DOM contract (`ui/flow.nim`'s readers
  ## select spans by it).
  result = ui(r):
    span(id = id, class = className, iteration = $iteration):
      text valueText
  applyFlowStyle[R, N](r, result, style)
  if maxWidth.len > 0:
    r.setStyle(result, "maxWidth", maxWidth)

proc renderFlowValueEmpty*[R, N](r: R; style: FlowStyle = @[];
                                valueText = "no value"): N =
  ## The placeholder drawn where a value is missing.
  result = ui(r):
    span(class = FlowValueEmptyClass):
      text valueText
  applyFlowStyle[R, N](r, result, style)

proc renderFlowValueColumn*[R, N](r: R; id: string; widthPx: float): N =
  ## One `.flow-parallel-values` column — the values of ONE pass through a
  ## loop. The width goes into the style and into a class, because
  ## `flow.styl` animates the column and Monaco reuses DOM nodes: a class that
  ## changes with the width is what makes a re-render at a new width land.
  let width = int(widthPx)
  let klass = FlowValueColumnClass & " " & FlowValueColumnClass & "-width-" &
    $width
  result = ui(r):
    tdiv(class = klass)
  if id.len > 0:
    r.setAttribute(result, "id", id)
  r.setStyle(result, "width", $width & "px")

proc renderFlowValueGroup*[R, N](r: R): N =
  ## `div.flow-parallel-group` — the columns of one loop, side by side.
  ui(r):
    tdiv(class = FlowValueGroupClass)

proc renderFlowValueLoopValues*[R, N](r: R; loopIndex: int): N =
  ## `div.flow-parallel-loop-values.loop-N` — one loop's band.
  ui(r):
    tdiv(class = FlowValueLoopValuesClass & " loop-" & $loopIndex)

proc flowValueBandClass*(isLoop: bool; extraClass = ""): string =
  ## The band's class: a loop's band or a single line's.
  result = FlowValueBandClass & " " &
    (if isLoop: FlowValueBandLoopClass else: FlowValueBandSingleClass)
  if extraClass.len > 0:
    result.add " " & extraClass

proc renderFlowValueBand*[R, N](r: R; leftPx: float; isLoop: bool;
                               extraClass = ""; positioned = false;
                               maxWidthPx = 0.0): N =
  ## `div.flow-parallel…` — the row that holds one line's whole band.
  ##
  ## `left` is an offset from the editor's content left, and it is the SAME
  ## for every line: that is what makes the values columns rather than
  ## trailing strips (the debugger computes it as `maxFlowLineWidth +
  ## distanceToSource`). `positioned` asks for `position: relative` — for a
  ## host with no positioned wrapper (the review's diff tab), where `left`
  ## would otherwise do nothing. `maxWidthPx` caps the row at the visible
  ## width, so an empty stretch of a view zone as wide as the editor's scroll
  ## width is not part of the band's box.
  result = ui(r):
    tdiv(class = flowValueBandClass(isLoop, extraClass))
  r.setStyle(result, "left", $int(leftPx) & "px")
  if positioned:
    r.setStyle(result, "position", "relative")
  if maxWidthPx > 0.0:
    r.setStyle(result, "maxWidth", $int(maxWidthPx) & "px")
