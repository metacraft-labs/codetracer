## The Omniscience loop slider — the dragged control, extracted so a review can
## have the same one.
##
## RV-10 recorded why the review's loop control was a stepper and not this:
##
##   "The reason is layout state, not intent. `ui/flow.nim` sizes the slider
##    from measurements it takes off `FlowComponent`: `loopControlWidth` reads
##    `flowLoops[position].flowDom.clientWidth`, `ensureLoopSlider` defers
##    creation until that width is non-zero (the fix for #562) […] A review has
##    no `FlowComponent`, so none of that state exists."
##
## What changed is not that a review grew a `FlowComponent`. It is that the
## measurement stopped being the thing that is hard: the review's loop control
## is a flex row in a Monaco view zone, so the slider is a flex child that
## takes the space left over, and "how wide is it" is answered by the layout
## rather than by arithmetic over a component's fields. What remains — and what
## is here — is the part that is genuinely shared: noUiSlider's options, the
## rule that it is never constructed before it is measurable, the marker that
## keeps a resize from destroying an in-progress drag, and the removal of a
## slider for a loop with nothing to choose between.
##
## #562's three lessons are all carried here rather than restated at each call
## site, because they were all learned the hard way:
##
##   1. **Never construct at zero width.** A freshly registered Monaco view zone
##      has no box during the tick in which it is built; a slider made then is
##      0x2 px, parked left of its control, and invisible.
##   2. **Never leave a dead container behind.** Rebuilding used to append a
##      second `.flow-loop-slider` and keep pointing at the first, stacking
##      empty divs.
##   3. **`connect` MUST be the string `"lower"`.** Nim's JS backend compiles
##      `array[2, bool]` to a `Uint8Array`, which noUiSlider rejects with
##      `Array.isArray`, and the throw took the whole render pass with it.

import std/[dom, jsffi, jsconsole]

# Kept to the DOM and noUiSlider (not `ui_imports`), so a browser suite can
# load this module on its own: `flow_loop_slider_chromium_test.nim`.
var noUiSlider {.importc.}: JsObject
proc jsFloor(x: float): int {.importjs: "Math.floor(#)".}

const
  FlowLoopSliderClass* = "flow-loop-slider"
  FlowLoopSliderContainerClass* = "flow-loop-slider-container"
  FlowLoopSliderFirstIteration* = 0
    ## The value the range starts at. The debugger's `FLOW_ITERATION_START`,
    ## restated here so this module needs nothing from `ui/flow.nim` — it is
    ## the one that depends on this, not the other way round.

proc flowLoopSliderChildDom*(id: cstring): Node =
  ## The element noUiSlider is constructed over.
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring(FlowLoopSliderClass))
  if id.len > 0:
    result.setAttribute(cstring"id", id)
  result.appendChild(document.createTextNode(cstring""))

proc flowLoopSliderContainerDom*(id: cstring; extraClass: string = ""): Node =
  ## The box the slider is laid out inside.
  var klass = FlowLoopSliderContainerClass
  if extraClass.len > 0:
    klass = klass & " " & extraClass
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring(klass))
  if id.len > 0:
    result.setAttribute(cstring"id", id)
  result.appendChild(flowLoopSliderChildDom(cstring""))

proc flowLoopSliderIsMeasurable*(element: Node): bool =
  ## Whether `element` has been laid out yet.
  ##
  ## Lesson 1. The answer is "not yet" during the tick a Monaco view zone or
  ## content widget is registered in, and a caller must come back rather than
  ## build against a zero.
  if element.isNil:
    return false
  cast[Element](element).clientWidth > 0

proc stopWaitingForLayout(element: Node) {.importjs: """
  (function(el) {
    if (el && el.__ctSliderLayoutObserver) {
      el.__ctSliderLayoutObserver.disconnect();
      el.__ctSliderLayoutObserver = null;
      el.__ctSliderLayoutRetry = null;
    }
  })(#)""".}

proc buildWhenLaidOut(element: Node; build: proc(): bool) {.importjs: """
  (function(el, build) {
    // The latest request wins: a control re-rendered before its first layout
    // asks again with its current pass.
    el.__ctSliderLayoutRetry = build;
    if (el.__ctSliderLayoutObserver || typeof ResizeObserver === 'undefined') {
      return;
    }
    var observer = new ResizeObserver(function() {
      if (!el.isConnected) {
        // The zone was replaced; its successor waits for itself.
        observer.disconnect();
        el.__ctSliderLayoutObserver = null;
        el.__ctSliderLayoutRetry = null;
        return;
      }
      if (el.clientWidth <= 0) { return; }
      // Built on the next frame, not inside the observer's delivery: making
      // the slider changes the box being observed, and a size change during
      // delivery is the browser's `ResizeObserver loop` error.
      requestAnimationFrame(function() {
        var retry = el.__ctSliderLayoutRetry;
        if (!el.__ctSliderLayoutObserver || !retry) { return; }
        if (retry()) {
          observer.disconnect();
          el.__ctSliderLayoutObserver = null;
          el.__ctSliderLayoutRetry = null;
        }
      });
    });
    el.__ctSliderLayoutObserver = observer;
    observer.observe(el);
  })(#, #)""".}

proc destroyFlowLoopSlider*(element: Node) =
  ## Tear a slider down, if one was ever built over `element`.
  if element.isNil:
    return
  stopWaitingForLayout(element)
  if not element.toJs.noUiSlider.isNil:
    element.toJs.noUiSlider.destroy()
    element.toJs.ctSliderMax = nil

proc ensureFlowLoopSlider*(element: Node; maxIteration, iteration: int;
                           onSlide: proc(iteration: int);
                           requireMeasurable: bool = true): bool =
  ## Create — or, when it already exists over the same range, re-position — the
  ## noUiSlider for a loop control.
  ##
  ## Returns true when a usable slider is in place afterwards. False means one
  ## of the three honest refusals, and a caller should keep its stepper visible
  ## either way: the element is missing, the loop has a single pass and so
  ## nothing to drag between, or the element is not measurable yet and the
  ## caller must come back.
  ##
  ## `requireMeasurable` is that last refusal, and it is a parameter because
  ## lesson 1 is only half a rule on its own. "Never construct at zero width"
  ## is safe exactly when somebody comes BACK — and only a host that has a
  ## re-scheduling path can; `ui/flow.ensureLoopSlider` has one
  ## (`resizeFlowSlider`) and passes true.
  if element.isNil:
    return false
  if maxIteration <= FlowLoopSliderFirstIteration:
    # Lesson 2, and the reason `removeSliderWidget` exists: noUiSlider throws
    # on a zero-width range, and an empty container next to the counter is
    # worse than no container.
    destroyFlowLoopSlider(element)
    return false
  if requireMeasurable and not flowLoopSliderIsMeasurable(element):
    return false

  # `ctSliderMax` is our own marker for "which range is this instance built
  # for". Re-creating on every resize pass would both waste work and cancel an
  # in-progress drag, so the widget is rebuilt only when the range changed.
  if not element.toJs.noUiSlider.isNil:
    if cast[int](element.toJs.ctSliderMax) == maxIteration:
      element.toJs.noUiSlider.set(iteration)
      return true
    element.toJs.noUiSlider.destroy()

  try:
    let range = newJsObject()
    range["min"] = FlowLoopSliderFirstIteration
    range["max"] = maxIteration
    let options = newJsObject()
    options["start"] = iteration
    options["range"] = range
    options["behaviour"] = cstring"drag-tap"
    # Lesson 3. `"lower"` is noUiSlider's own shorthand for `[true, false]`,
    # in a form that survives the Nim -> JS translation.
    # https://refreshless.com/nouislider/slider-options/#section-connect
    options["connect"] = cstring"lower"
    options["step"] = 1
    discard noUiSlider.create(element, options)
  except:
    # A slider that cannot be constructed must not take the rest of the render
    # pass with it — the counter and its arrows are still usable without one.
    console.error cstring("flow: noUiSlider.create failed: " & getCurrentExceptionMsg())
    return false

  element.toJs.ctSliderMax = maxIteration
  let handler = proc(values: seq[cstring], handle: int, unencoded: seq[float],
                     tap: bool, positions: seq[float]) =
    onSlide(jsFloor(unencoded[0]))
  cast[JsObject](element).noUiSlider.on(cstring"slide", handler)
  true

proc ensureFlowLoopSliderWhenLaidOut*(element: Node; maxIteration, iteration: int;
                                      onSlide: proc(iteration: int)): bool =
  ## `ensureFlowLoopSlider` for a host with no render pass of its own to come
  ## back from — a review's loop control in a Monaco view zone.
  ##
  ## Lesson 1 says never build at zero width; this is the half that makes it
  ## safe: when the element has no box yet, the slider is built the moment the
  ## browser lays it out (a `ResizeObserver` on the element), however long that
  ## takes. A zone revealed by a context expansion is laid out late, and the
  ## bounded timer this replaces gave up first under load, leaving the control
  ## without its slider for good.
  ##
  ## Returns whether the slider is in place now.
  if ensureFlowLoopSlider(element, maxIteration, iteration, onSlide):
    stopWaitingForLayout(element)
    return true
  if element.isNil or maxIteration <= FlowLoopSliderFirstIteration or
     flowLoopSliderIsMeasurable(element):
    return false
  buildWhenLaidOut(element, proc(): bool =
    ensureFlowLoopSlider(element, maxIteration, iteration, onSlide))
  false
