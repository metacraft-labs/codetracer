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
## This module is JS-only (it builds DOM). Everything that *decides* anything —
## which passes are drawn, which of them is selected, how many fit — is pure and
## lives in `viewmodel/viewmodels/review_flow_overlay.nim` for the review and in
## `FlowComponent`'s layout arithmetic for the debugger, so both are testable
## without a browser.

import ui_imports
import ../lib/isonim_styles

const
  FlowValueContainerClass* = "ct-omni-value"
    ## The flex container a chip's name and value live in. It carries the
    ## appearance: `styles/components/flow.styl` has no rule for
    ## `.flow-parallel-value-box` itself (the block is commented out at
    ## :213-228), so a value box that is NOT inside one of these is unstyled —
    ## which is why RV-5's injected spans had to restate the container's
    ## declarations on themselves, and why they no longer have to.
  FlowValueNameClass* = "ct-omni-name"
  FlowValueColumnClass* = "flow-parallel-values"
  FlowValueGroupClass* = "flow-parallel-group"
  FlowValueLoopValuesClass* = "flow-parallel-loop-values"
  FlowValueBandClass* = "flow-parallel"
  FlowValueBandLoopClass* = "flow-parallel-loop"
  FlowValueBandSingleClass* = "flow-parallel-value-single"
  FlowValueEmptyClass* = "flow-parallel-value"
    ## The span `renderFlow` puts in a column when a name has no value at that
    ## step. Reused for a whole pass that never reached the line.

proc flowValueContainerDom*(style: VStyle): Node =
  ## `span.ct-omni-value` — one variable's name and value together.
  result = document.createElement(cstring"span")
  result.setAttribute(cstring"class", cstring(FlowValueContainerClass))
  result.applyStyle(style)

proc flowValueNameDom*(name: cstring): Node =
  ## `span.ct-omni-name` — the name half of a chip.
  result = document.createElement(cstring"span")
  result.setAttribute(cstring"class", cstring(FlowValueNameClass))
  result.appendChild(document.createTextNode(name))

proc flowValueBoxDom*(id: cstring; className: cstring; text: cstring;
                      iteration: int; style: VStyle;
                      maxWidth: cstring = cstring""): Node =
  ## `span.flow-<mode>-value-box …` — the value half of a chip.
  ##
  ## `maxWidth` is applied only when non-empty, which is how the debugger caps a
  ## value long enough to need the "view more" button without capping every
  ## other one; the review passes the same cap so a single enormous value cannot
  ## push a column past the pane edge.
  ##
  ## The `iteration` attribute is part of the DOM contract — `ui/flow.nim`'s own
  ## readers select spans by it — so it is set here rather than by each caller.
  result = document.createElement(cstring"span")
  result.setAttribute(cstring"id", id)
  result.applyStyle(style)
  if maxWidth.len > 0:
    result.style.maxWidth = maxWidth
  result.setAttribute(cstring"iteration", cstring($iteration))
  result.setAttribute(cstring"class", className)
  result.appendChild(document.createTextNode(text))

proc flowValueEmptyDom*(style: VStyle; text: cstring = cstring"no value"): Node =
  ## The placeholder `renderFlow` draws where a value is missing.
  result = document.createElement(cstring"span")
  result.setAttribute(cstring"class", cstring(FlowValueEmptyClass))
  result.applyStyle(style)
  result.appendChild(document.createTextNode(text))

proc flowValueColumnDom*(id: cstring; widthPx: float): Node =
  ## One `.flow-parallel-values` column — the values of ONE pass through a loop.
  ##
  ## The width goes both into the inline style and into a class, because
  ## `flow.styl` animates the column (`transition: all 400ms ease`) and Monaco
  ## reuses DOM nodes: without a class that changes with the width, a re-render
  ## at a new width can be skipped.
  result = document.createElement(cstring"div")
  if id.len > 0:
    result.setAttribute(cstring"id", id)
  let width = int(widthPx)
  result.setAttribute(
    cstring"class",
    cstring(FlowValueColumnClass & " " & FlowValueColumnClass & "-width-" & $width))
  result.applyStyle(style((StyleAttr.width, cstring($width & "px"))))

proc flowValueGroupDom*(): Node =
  ## `div.flow-parallel-group` — the columns of one loop, side by side.
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring(FlowValueGroupClass))

proc flowValueLoopValuesDom*(loopIndex: int): Node =
  ## `div.flow-parallel-loop-values.loop-N` — one loop's band.
  result = document.createElement(cstring"div")
  result.setAttribute(
    cstring"class",
    cstring(FlowValueLoopValuesClass & " loop-" & $loopIndex))

proc flowValueBandDom*(leftPx: float; isLoop: bool;
                       extraClass: string = "";
                       positioned: bool = false;
                       maxWidthPx: float = 0.0): Node =
  ## `div.flow-parallel…` — the row that holds one line's whole band.
  ##
  ## `left` is an absolute pixel offset from the editor's content left, and it
  ## is the SAME for every line: that is what makes the values a set of columns
  ## rather than a set of trailing strips. The debugger computes it as
  ## `maxFlowLineWidth + distanceToSource`.
  var klass = FlowValueBandClass & " " &
    (if isLoop: FlowValueBandLoopClass else: FlowValueBandSingleClass)
  if extraClass.len > 0:
    klass = klass & " " & extraClass
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring(klass))
  # `positioned` asks for `position: relative` alongside the offset.
  #
  # The debugger does not need it: its bands are children of
  # `.flow-loop-line` / `.flow-loop-multiline`, which `flow.styl` already
  # positions. A host that has no such wrapper — the review's diff tab — does,
  # because `left` on a statically positioned element does nothing and the
  # band would be drawn from the line's first column, on top of the code.
  #
  # `relative` and NOT `absolute`, and on a CHILD of the content widget rather
  # than on the widget node itself: Monaco writes `position: absolute` and its
  # own `left`/`top` onto a content widget's node on every frame, so an offset
  # put there is overwritten within a frame of being set.
  result.applyStyle(style((StyleAttr.left, cstring($int(leftPx) & "px"))))
  if positioned:
    result.style.position = cstring"relative"
  if maxWidthPx > 0.0:
    # A flex row inside a Monaco view zone stretches to the zone's own box,
    # which is as wide as the editor's SCROLL width — 811px against a 576px
    # pane on the design corpus, because one line of the file is 214
    # characters. Nothing is drawn out there, but the empty box is what a
    # bounding-box screenshot crops to, so a review capture came back "~85%
    # empty background". The cap is the visible width.
    result.style.maxWidth = cstring($int(maxWidthPx) & "px")
