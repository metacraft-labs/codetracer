## The Omniscience value surface's own DOM, extracted so more than one host can
## draw it.
##
##   "Keep the standard CodeTracer Omniscience appearance, produced by the same
##    code path as normal debugging."
##   — `codetracer-specs/DeepReview/DeepReview-GUI.md` §4.4
##
## Why this module exists
## ----------------------
## Until UD-3 there were two producers of "an Omniscience value chip": the
## debugger's `ui/flow.flowSimpleValue`, which builds real elements, and the
## review's `ui/unified_diff.monacoValueDecorations`, which asked Monaco to
## inject text carrying the debugger's *class names*. The second is a look-alike
## by construction — it can copy a class but not a box model, not a nesting, and
## not a column — and §4.4 forbids exactly that ("produced by the same code
## path", "Do not create a separate DeepReview-specific inline style").
##
## So the elements move here and both hosts build them from one implementation.
## `ui/flow.nim` keeps every behaviour it had — the jump, the context menu, the
## tooltip, the scratchpad, the origin badge — by passing them in as hooks; the
## review passes the subset it can honour. What neither can do any more is
## disagree about what a value chip *is*.
##
## The shapes, exactly as the debugger draws them
## ----------------------------------------------
## A chip::
##
##   <span class="ct-omni-value">
##     <span class="ct-omni-name">x</span>
##     <span class="flow-parallel-value-box flow-parallel-value-before-only">10</span>
##   </span>
##
## A band — the *parallel columns* the flow view lays a loop's passes out in,
## one column per pass, side by side::
##
##   <div class="flow-parallel flow-parallel-loop" style="left: …px">
##     <div class="flow-parallel-loop-values loop-1">
##       <div class="flow-parallel-group">
##         <div class="flow-parallel-values flow-parallel-values-width-120">…chips…</div>
##         <div class="flow-parallel-values flow-parallel-values-width-120">…chips…</div>
##       </div>
##     </div>
##   </div>
##
## `left` is the same number for every line of the band — the debugger's
## `maxFlowLineWidth + distanceToSource` — which is what turns a set of trailing
## strips into a set of columns a reader can scan downwards.
##
## The elements are now views generic over the renderer
## (`viewmodel/views/isonim_flow_value_view`, Shared-DOM-Front-Ends D7.4 (b)),
## rendered here under `WebRenderer`; the procs below keep their signatures
## for their callers. This module is JS-only (it hands back DOM nodes). Everything that *decides* anything —
## which passes are drawn, which of them is selected, how many fit — is pure and
## lives in `viewmodel/viewmodels/review_flow_overlay.nim` for the review and in
## `FlowComponent`'s layout arithmetic for the debugger, so both are testable
## without a browser.

import ui_imports
import ../lib/isonim_styles
import isonim/web/web_renderer
from isonim/web/dom_api import nil
import ../viewmodel/views/isonim_flow_value_view

export FlowValueContainerClass, FlowValueNameClass, FlowValueColumnClass,
  FlowValueGroupClass, FlowValueLoopValuesClass, FlowValueBandClass,
  FlowValueBandLoopClass, FlowValueBandSingleClass, FlowValueEmptyClass

proc flowStyleOf*(s: VStyle): FlowStyle =
  ## A `VStyle`'s properties as the view's style list.
  if s.isNil:
    return @[]
  for (name, value) in s.attrs:
    result.add(($name, $value))

template asNode(e: dom_api.Element): Node = cast[Node](e)

proc flowValueContainerDom*(style: VStyle): Node =
  ## `span.ct-omni-value` — one variable's name and value together.
  asNode(renderFlowValueContainer[WebRenderer, dom_api.Element](
    WebRenderer(), flowStyleOf(style)))

proc flowValueNameDom*(name: cstring): Node =
  ## `span.ct-omni-name` — the name half of a chip.
  asNode(renderFlowValueName[WebRenderer, dom_api.Element](
    WebRenderer(), $name))

proc flowValueBoxDom*(id: cstring; className: cstring; text: cstring;
                      iteration: int; style: VStyle;
                      maxWidth: cstring = cstring""): Node =
  ## The value half of a chip (`renderFlowValueBox`).
  asNode(renderFlowValueBox[WebRenderer, dom_api.Element](
    WebRenderer(), $id, $className, $text, iteration, flowStyleOf(style),
    $maxWidth))

proc flowValueEmptyDom*(style: VStyle; text: cstring = cstring"no value"): Node =
  ## The placeholder drawn where a value is missing.
  asNode(renderFlowValueEmpty[WebRenderer, dom_api.Element](
    WebRenderer(), flowStyleOf(style), $text))

proc flowValueColumnDom*(id: cstring; widthPx: float): Node =
  ## One `.flow-parallel-values` column (`renderFlowValueColumn`).
  asNode(renderFlowValueColumn[WebRenderer, dom_api.Element](
    WebRenderer(), $id, widthPx))

proc flowValueGroupDom*(): Node =
  ## `div.flow-parallel-group` — the columns of one loop, side by side.
  asNode(renderFlowValueGroup[WebRenderer, dom_api.Element](WebRenderer()))

proc flowValueLoopValuesDom*(loopIndex: int): Node =
  ## `div.flow-parallel-loop-values.loop-N` — one loop's band.
  asNode(renderFlowValueLoopValues[WebRenderer, dom_api.Element](
    WebRenderer(), loopIndex))

proc flowValueBandDom*(leftPx: float; isLoop: bool;
                       extraClass: string = "";
                       positioned: bool = false;
                       maxWidthPx: float = 0.0): Node =
  ## `div.flow-parallel…` — the row that holds one line's whole band
  ## (`renderFlowValueBand`).
  asNode(renderFlowValueBand[WebRenderer, dom_api.Element](
    WebRenderer(), leftPx, isLoop, extraClass, positioned, maxWidthPx))
