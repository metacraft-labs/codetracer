## views/isonim_flow_inline_view.nim — the elements of inline flow (Omniscience
## drawn over the source), as views (Shared-DOM-Front-Ends D7.4 (b)).
##
## `ui/flow.nim` built every element it places in Monaco's view zones and
## content widgets by hand: the value chips (before, after and before→after),
## the event chips, the loop control (its buttons and its iteration field), the
## noUiSlider's host, the collapsed and continuous iteration cells, the loop
## legend and background, the multiline value boxes and the view zones
## themselves. They are now procs generic over the renderer (`[R, N]`, the
## shape of every `isonim_*_view.nim`), so the same markup renders under
## `WebRenderer` in the editor and under `MockRenderer` in the headless tests
## (`viewmodel/tests/unit/test_flow_inline_view.nim`). Monaco still positions
## them — `ui/flow.nim` decides WHERE and WHEN (view-zone lifecycle, widths
## measured from the editor, the slider's library); these procs decide WHAT.
##
## Each view takes plain values, never the flow component, and reports a
## user's gesture through a `FlowInput` handler. That record is the one place
## a browser event and a `MockEvent` meet: a handler reads the button, the
## modifiers, the pointer position, the key or the control's value from it,
## and sets `prevent` / `stop` instead of calling the DOM, so the same handler
## runs in a test that fires the event on a `MockNode`.
##
## The markup is a DOM contract: the GUI page objects select on these classes
## and ids (`FlowValue`, `OmniscientLoopControls`, the noir-space-ship loop
## tests). Each proc says which of its names are load-bearing.

import std/strutils

import isonim/testing/mock_dom
when defined(js):
  # Both renderers' primitives in scope, so the generic procs below resolve
  # `createElement` & co. at instantiation for either.
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/flow_layout
import isonim_flow_value_view

export isonim_flow_value_view, FlowValueMode

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

type
  FlowInput* = ref object
    ## One gesture on a flow element, whichever renderer drew it.
    button*: int        ## The mouse button (`MouseEvent.button`; 0 = main).
    ctrl*, shift*: bool
    x*, y*: int         ## The pointer, in client coordinates.
    key*: string        ## `KeyboardEvent.key`.
    keyCode*: int       ## `KeyboardEvent.keyCode`, for the hosts that still
                        ## report Enter only that way.
    value*: string      ## The control's current value (an input event).
    prevent*: bool      ## Set by a handler: suppress the default action.
    stop*: bool         ## Set by a handler (or the view): stop propagation.

  FlowInputHandler* = proc(input: FlowInput) {.closure.}

when defined(js):
  proc evInt(ev: isonim_dom.Event; field: cstring): int
    {.importjs: "((#)[#] | 0)".}
  proc evBool(ev: isonim_dom.Event; field: cstring): bool
    {.importjs: "!!((#)[#])".}
  proc evKey(ev: isonim_dom.Event): cstring
    {.importjs: "((e) => e.key == null ? '' : String(e.key))(#)".}
  proc evTargetValue(ev: isonim_dom.Event): cstring
    {.importjs: "((e) => (e.target && e.target.value != null) ? String(e.target.value) : '')(#)".}
  proc evPreventDefault(ev: isonim_dom.Event) {.importjs: "#.preventDefault()".}
  proc evStopPropagation(ev: isonim_dom.Event) {.importjs: "#.stopPropagation()".}

proc listen*[R, N](r: R; node: N; event: string; handler: FlowInputHandler;
                   stop = false) =
  ## Deliver `event` on `node` to `handler` as a `FlowInput`. `stop` stops
  ## propagation whatever the handler decides — the elements whose gestures
  ## must not reach Monaco underneath (which would move the cursor) ask for it.
  if handler.isNil:
    return
  when N is MockNode:
    let target = node
    r.addEventListener(node, event, proc(ev: MockEvent) =
      let input = FlowInput(ctrl: ev.ctrlKey, shift: ev.shiftKey,
                            x: int(ev.clientX), y: int(ev.clientY),
                            key: ev.key, value: r.inputValue(target),
                            stop: stop)
      handler(input)
      if input.prevent: ev.preventDefault()
      if input.stop: ev.stopPropagation())
  else:
    when defined(js):
      when N is isonim_dom.Element:
        isonim_dom.addEventListener(isonim_dom.Node(node), cstring(event),
          proc(ev: isonim_dom.Event) =
            let input = FlowInput(
              button: evInt(ev, "button"),
              ctrl: evBool(ev, "ctrlKey"), shift: evBool(ev, "shiftKey"),
              x: evInt(ev, "clientX"), y: evInt(ev, "clientY"),
              key: $evKey(ev), keyCode: evInt(ev, "keyCode"),
              value: $evTargetValue(ev), stop: stop)
            handler(input)
            if input.prevent: evPreventDefault(ev)
            if input.stop: evStopPropagation(ev))
      else:
        {.error: "listen: no event binding for this renderer".}
    else:
      {.error: "listen: no event binding for this renderer".}

# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------

proc element[R, N](r: R; tag, class: string; id = ""): N =
  result = r.createElement(tag)
  if id.len > 0:
    r.setAttribute(result, "id", id)
  if class.len > 0:
    r.setAttribute(result, "class", class)

proc addText[R, N](r: R; node: N; text: string) =
  r.appendChild(node, r.createTextNode(text))

proc applyStyle[R, N](r: R; node: N; style: FlowStyle) =
  for (name, value) in style:
    r.setStyle(node, name, value)

proc px*(value: float): string =
  ## A pixel length as the hand-built DOM wrote it: Nim's `$` of the number.
  $value & "px"

proc px*(value: int): string =
  $value & "px"

# ---------------------------------------------------------------------------
# Value chips
# ---------------------------------------------------------------------------

type
  FlowValueSide* = enum
    fvsBefore   ## The value before the step ran.
    fvsAfter    ## The value the step produced.

  FlowChipBox* = object
    ## One value box of a chip: what it shows and the names it carries.
    side*: FlowValueSide
    id*: string
      ## `flow-<mode>-value-box-<index>-<step>-<name>`; a dual chip's boxes are
      ## `…-<step>-before-<name>` and `…-<step>-after-<name>`. Each is ONE
      ## token, the id the popups look their box up by, and each ends in
      ## `-<name>` because the page objects match `[id$="-<name>"]`
      ## (`FlowValue.supportsScratchpad` also counts the dashes).
    className*: string
    text*: string
    maxWidth*: string
      ## Set when the value was cut short, so it is capped and the chip shows
      ## its "view more" button.

func flowValueBoxClass*(flowMode: string): string =
  ## The class every value box carries (`assertFlowValueVisible` reads
  ## `[class*="flow-parallel-value-box"]` even on before-only spans).
  "flow-" & flowMode & "-value-box"

func flowValueBoxId*(flowMode: string; index, stepCount: int;
                     name: string): string =
  "flow-" & flowMode & "-value-box-" & $index & "-" & $stepCount & "-" & name

func planFlowValueChip*(flowMode: string; mode: FlowValueMode;
                        index, stepCount: int; name: string;
                        beforeText, afterText: string;
                        beforeMaxWidth = ""; afterMaxWidth = ""):
    seq[FlowChipBox] =
  ## The boxes a variable's chip draws, in order, for a value mode
  ## (`flow_layout.resolveFlowValueMode`).
  let box = flowValueBoxClass(flowMode)
  let id = flowValueBoxId(flowMode, index, stepCount, name)
  case mode
  of fvmBefore:
    @[FlowChipBox(side: fvsBefore, id: id, text: beforeText,
                  maxWidth: beforeMaxWidth,
                  className: box & " flow-" & flowMode & "-value-before-only")]
  of fvmAfter:
    @[FlowChipBox(side: fvsAfter, id: id, text: afterText,
                  maxWidth: afterMaxWidth,
                  className: box & " flow-" & flowMode & "-value-after-only")]
  of fvmBeforeAndAfter:
    let dual = "flow-" & flowMode & "-value-dual"
    let prefix = "flow-" & flowMode & "-value-box-" & $index & "-" &
      $stepCount & "-"
    @[FlowChipBox(side: fvsBefore, id: prefix & "before-" & name,
                  text: beforeText, maxWidth: beforeMaxWidth,
                  className: box & " flow-dual-value-before " & dual),
      FlowChipBox(side: fvsAfter, id: prefix & "after-" & name,
                  text: afterText,
                  maxWidth: afterMaxWidth,
                  className: box & " " & dual)]

type
  FlowChipHandlers* = object
    ## What a chip's gestures do; a nil handler leaves the gesture alone.
    onViewMore*: FlowInputHandler
      ## The "view more" button of a cut-short value (propagation stopped).
    onNamePress*, onNameContext*: FlowInputHandler
    onBoxPress*, onBoxContext*, onBoxHover*:
      proc(side: FlowValueSide; boxId: string; input: FlowInput) {.closure.}

proc bindFlowChipBox[R, N](r: R; node: N; box: FlowChipBox;
                           handlers: FlowChipHandlers) =
  ## One box's gestures, reported with ITS side and id. A proc of its own so
  ## each box's closures capture their own `box`: closures created in a loop
  ## body share that body's variables across iterations, which reported every
  ## box of a dual chip as its last ("after") box.
  if not handlers.onBoxPress.isNil:
    let act = handlers.onBoxPress
    listen(r, node, "mousedown", proc(input: FlowInput) =
      act(box.side, box.id, input))
  if not handlers.onBoxContext.isNil:
    let act = handlers.onBoxContext
    listen(r, node, "contextmenu", proc(input: FlowInput) =
      act(box.side, box.id, input))
  if not handlers.onBoxHover.isNil:
    let act = handlers.onBoxHover
    listen(r, node, "mouseover", proc(input: FlowInput) =
      act(box.side, box.id, input))

proc renderFlowVariableChip*[R, N](r: R; flowMode, name: string;
                                   boxes: seq[FlowChipBox]; iteration: int;
                                   showName, viewMore: bool;
                                   style: FlowStyle;
                                   handlers: FlowChipHandlers): N =
  ## A variable's chip: `span.ct-omni-value` holding, in order, the "view
  ## more" button (when a value was cut short), the name (when the line shows
  ## names), and the boxes `planFlowValueChip` planned — a dual chip's two
  ## with the `=>` arrow between them.
  result = renderFlowValueContainer[R, N](r, style)
  if viewMore:
    let button = element[R, N](r, "span",
      "flow-" & flowMode & "-value-name flow-view-more-button flow-hide-content")
    applyStyle[R, N](r, button, style)
    listen(r, button, "mousedown", handlers.onViewMore, stop = true)
    r.appendChild(result, button)
  if showName:
    let nameNode = renderFlowValueName[R, N](r, name)
    listen(r, nameNode, "mousedown", handlers.onNamePress)
    listen(r, nameNode, "contextmenu", handlers.onNameContext)
    r.appendChild(result, nameNode)
  for i, box in boxes:
    if i > 0:
      let arrow = element[R, N](r, "span",
        "flow-" & flowMode & "-value-name flow-dual-arrow")
      addText[R, N](r, arrow, "=>")
      r.appendChild(result, arrow)
    let node = renderFlowValueBox[R, N](r, box.id, box.className, box.text,
                                        iteration, style, box.maxWidth)
    bindFlowChipBox[R, N](r, node, box, handlers)
    r.appendChild(result, node)

type
  FlowEventChip* = object
    ## An event a step recorded, as its chip draws it.
    name*: string
      ## `stdout`, `stderr`, `stdin`, `error`, or an EVM event's metadata;
      ## drawn as `<name>`.
    nameClassSuffix*: string
      ## `-std` or `-error`: the name span is `ct-omni-name<suffix>`.
    valueClass*: string
      ## `flow-std-default-box` or `flow-error-box` (the page objects find an
      ## output chip by the former).
    text*: string
    truncated*: bool

func flowEventBoxId*(flowMode: string; stepCount, index: int): string =
  ## An event chip's value box — the anchor its "view more" popup opens on.
  "flow-" & flowMode & "-value-box-" & $stepCount & "-" & $index

proc renderFlowEventChip*[R, N](r: R; flowMode: string; event: FlowEventChip;
                                stepCount, index, iteration: int;
                                style: FlowStyle; maxWidth: string;
                                onJump, onViewMore: FlowInputHandler): N =
  ## An event's chip: `<stdout>` and the text. The value box is
  ## `#flow-<mode>-value-box-<step>-<index>`; a cut-short text gets a "view
  ## more" button (propagation stopped) and the cap.
  result = renderFlowValueContainer[R, N](r, style)
  if event.truncated:
    let button = element[R, N](r, "span", "ct-omni-name" &
      event.nameClassSuffix & " flow-view-more-button flow-hide-content")
    applyStyle[R, N](r, button, style)
    listen(r, button, "mousedown", onViewMore, stop = true)
    r.appendChild(result, button)
  let nameNode = element[R, N](r, "span", "ct-omni-name" & event.nameClassSuffix)
  listen(r, nameNode, "mousedown", onJump)
  addText[R, N](r, nameNode, "<" & event.name & ">")
  r.appendChild(result, nameNode)
  let box = renderFlowValueBox[R, N](r,
    flowEventBoxId(flowMode, stepCount, index),
    flowValueBoxClass(flowMode) & " " & event.valueClass & " flow-" &
      flowMode & "-value-before-only",
    event.text, iteration, style,
    if event.truncated: maxWidth else: "")
  listen(r, box, "mousedown", onJump)
  r.appendChild(result, box)

proc renderFlowEventPopup*[R, N](r: R; text: string): N =
  ## The full text of a cut-short event, shown in the chip's popup.
  result = element[R, N](r, "div", "flow-event-value-popup")
  addText[R, N](r, result, text)

# ---------------------------------------------------------------------------
# A line's values and the step cells of a loop
# ---------------------------------------------------------------------------

proc renderFlowLineHost*[R, N](r: R): N =
  ## `div.flow-content-widget` — the content widget Monaco places at a flow
  ## line; its children are the line's bands.
  element[R, N](r, "div", "flow-content-widget")

proc renderFlowComplexStep*[R, N](r: R; flowMode: string; position: int;
                                  style: FlowStyle): N =
  ## One step's values on a line outside a collapsed loop:
  ## `div#flow-<mode>-value-<line>.flow-<mode>.flow-<mode>-value-single`.
  result = element[R, N](r, "div",
    "flow-" & flowMode & " flow-" & flowMode & "-value-single",
    "flow-" & flowMode & "-value-" & $position)
  applyStyle[R, N](r, result, style)

proc renderFlowValueGap*[R, N](r: R; style: FlowStyle = @[]): N =
  ## `div.flow-loop-empty-space` — the gap between two of a step's chips, and
  ## between two legend headings.
  result = element[R, N](r, "div", "flow-loop-empty-space")
  applyStyle[R, N](r, result, style)

type
  FlowCollapse* = enum
    fcNone        ## The iteration's values are drawn.
    fcContinuous  ## Collapsed to a continuous strip of cells.
    fcShrinked    ## Collapsed to one narrow cell per iteration.

proc renderFlowLoopStepContainer*[R, N](r: R; loopIndex, iteration: int;
                                        collapse = fcNone): N =
  ## `div#flow-loop-step-container-<loop>-<iteration>` — one iteration's cell
  ## at a line; `continuous` / `shrinked` when the loop is collapsed.
  let class =
    case collapse
    of fcNone: "flow-loop-step-container"
    of fcContinuous: "flow-loop-step-container continuous"
    of fcShrinked: "flow-loop-step-container shrinked"
  element[R, N](r, "div", class,
    "flow-loop-step-container-" & $loopIndex & "-" & $iteration)

proc renderFlowCollapsedStep*[R, N](r: R; stepCount: int; collapse: FlowCollapse;
                                    style: FlowStyle;
                                    onJump, onOpen: FlowInputHandler): N =
  ## A collapsed iteration's cell: a click jumps to the step, a double click
  ## opens its values in the scratchpad, and hovering it does not reach the
  ## chip tooltips underneath.
  let class =
    if collapse == fcContinuous: "flow-loop-continuous-iteration"
    else: "flow-loop-shrinked-iteration"
  result = element[R, N](r, "div", class,
    "flow-loop-shrinked-iteration-step-" & $stepCount)
  applyStyle[R, N](r, result, style)
  listen(r, result, "click", onJump)
  listen(r, result, "dblclick", onOpen)
  listen(r, result, "mouseover", proc(input: FlowInput) = discard, stop = true)

proc renderFlowShrinkedIteration*[R, N](r: R; iteration: int): N =
  ## The marker a shrunk loop appends to each of its line's cells.
  element[R, N](r, "div", "flow-loop-shrinked-iteration",
    "flow-loop-shrinked-iteration-" & $iteration)

proc renderFlowLegend*[R, N](r: R; leftPx, widthPx: float;
                             headings: seq[(string, float)];
                             gapPercent: float): N =
  ## `div.flow-loop-legend` — the expression headings over a loop's columns,
  ## each `widthPercent` wide, with a `gapPercent` gap between two.
  result = element[R, N](r, "div", "flow-loop-legend")
  r.setStyle(result, "left", px(leftPx))
  r.setStyle(result, "width", px(widthPx))
  for i, (expression, widthPercent) in headings:
    let heading = element[R, N](r, "div", "flow-loop-legend-expression")
    r.setStyle(heading, "width", $widthPercent & "%")
    addText[R, N](r, heading, expression)
    r.appendChild(result, heading)
    if i < headings.high:
      r.appendChild(result, renderFlowValueGap[R, N](r,
        @[("width", $gapPercent & "%")]))

proc renderFlowLoopContainer*[R, N](r: R; id: string; nested: bool;
                                    style: FlowStyle): N =
  ## A line's loop container: `.flow-loop-container` holds the line's
  ## `.flow-nested-loop-container`s, one per loop at that line.
  result = element[R, N](r, "div",
    if nested: "flow-nested-loop-container" else: "flow-loop-container", id)
  applyStyle[R, N](r, result, style)

proc renderFlowLoopBackground*[R, N](r: R; loopIndex: int;
                                     left, top, width, height: float): N =
  ## `#flow-loop-<loop>-background` — the band behind a loop's lines.
  result = element[R, N](r, "div", "flow-loop-background",
    "flow-loop-" & $loopIndex & "-background")
  r.setStyle(result, "left", px(left))
  r.setStyle(result, "top", px(top))
  r.setStyle(result, "width", px(width))
  r.setStyle(result, "height", px(height))

proc renderFlowMultilineValue*[R, N](r: R; position: int; expression: string;
                                     topOffsetPx, leftPx: float;
                                     pointer: bool): N =
  ## A multiline-mode value box, under its expression: `#flow-multiline-value-
  ## <line>-<expression>`. Below the first row it draws a pointer up to the
  ## expression it belongs to.
  result = element[R, N](r, "div", "flow-multiline-value-container",
    "flow-multiline-value-" & $position & "-" & expression)
  r.setStyle(result, "top", px(topOffsetPx))
  r.setStyle(result, "left", px(leftPx))
  if pointer:
    let arrow = element[R, N](r, "div", "flow-multiline-value-pointer")
    r.setStyle(arrow, "top", px(-topOffsetPx))
    r.setStyle(arrow, "height", px(topOffsetPx))
    r.appendChild(result, arrow)

# ---------------------------------------------------------------------------
# The loop control
# ---------------------------------------------------------------------------

type
  FlowLoopControl* = object
    ## What a loop's control shows.
    position*: int        ## The loop's header line.
    stepCount*: int       ## The header step the control belongs to.
    live*: bool
      ## The header has a trace tick, so its iterations can be jumped to; a
      ## control without one draws nothing but its container.
    iteration*: int       ## The active iteration.
    allIterations*: int   ## The highest iteration.
    canBack*, canForward*: bool

  FlowLoopControlHandlers* = object
    onBack*, onForward*: FlowInputHandler
    onCommit*: proc(iteration: int; viaBlur: bool) {.closure.}
      ## The iteration field was committed — by Enter or by leaving it — with
      ## the last in-range number typed (or the active iteration when none
      ## was).

func clampedIterationEntry*(raw: string; allIterations: int;
                            current: int): int =
  ## What the iteration field holds after an edit: the number typed when it
  ## is one and in `0 .. allIterations`, otherwise what it held before.
  result = current
  if raw.len > 0:
    try:
      let value = parseInt(raw)
      if value >= 0 and value <= allIterations:
        result = value
    except ValueError:
      discard

proc renderFlowLoopButton[R, N](r: R; forward, enabled: bool;
                                handler: FlowInputHandler): N =
  ## `#backward-loop` / `#forward-loop`: `.flow-loop-button.backward` and
  ## `.forward`, `disabled` at either end of the loop.
  result = element[R, N](r, "button",
    "ct-button-image-sm-secondary ct-button-no-border flow-loop-button " &
      (if forward: "forward" else: "backward"),
    if forward: "forward-loop" else: "backward-loop")
  if not enabled:
    r.setAttribute(result, "disabled", "disabled")
  listen(r, result, "click", handler)

proc renderFlowLoopIteration*[R, N](r: R; control: FlowLoopControl;
                                    style: FlowStyle;
                                    onCommit: proc(iteration: int;
                                                   viaBlur: bool) {.closure.}): N =
  ## `span.flow-loop-value`: "iteration [N] from M", the number an editable
  ## `textarea.flow-loop-textarea` (what the loop tests type into).
  let digits = len($control.allIterations)
  result = element[R, N](r, "span", "flow-loop-value")
  applyStyle[R, N](r, result, style)
  let loopSpan = element[R, N](r, "span", "ct-omniscience-loop")
  applyStyle[R, N](r, loopSpan, style)
  let start = element[R, N](r, "span", "flow-parallel-loop-iteration-start")
  addText[R, N](r, start, "iteration ")
  r.appendChild(loopSpan, start)

  let field = element[R, N](r, "textarea", "flow-loop-textarea")
  r.setAttribute(field, "value", $control.iteration)
  when N is MockNode:
    r.setInputValue(field, $control.iteration)
  else:
    when defined(js):
      when N is isonim_dom.Element:
        isonim_dom.setJsPropCstring(isonim_dom.Node(field), "value",
                                    cstring($control.iteration))
  r.setAttribute(field, "maxlength", $digits)
  r.setStyle(field, "width", $(digits + 1) & "ch")
  r.setStyle(field, "textAlign", "right")
  if not onCommit.isNil:
    var entered = control.iteration
    let allIterations = control.allIterations
    listen(r, field, "input", proc(input: FlowInput) =
      entered = clampedIterationEntry(input.value, allIterations, entered))
    listen(r, field, "blur", proc(input: FlowInput) =
      onCommit(entered, true))
    listen(r, field, "keydown", proc(input: FlowInput) =
      if input.key == "Enter" or input.keyCode == 13:
        input.prevent = true
        onCommit(entered, false))
  r.appendChild(loopSpan, field)

  let finish = element[R, N](r, "span", "flow-parallel-loop-iteration-end")
  addText[R, N](r, finish, "from " & $control.allIterations)
  r.appendChild(loopSpan, finish)
  r.appendChild(result, loopSpan)

proc renderFlowLoopControl*[R, N](r: R; control: FlowLoopControl;
                                  style: FlowStyle;
                                  handlers: FlowLoopControlHandlers): N =
  ## A loop header's control: back, the iteration field, forward. The outer
  ## `flow-multiline-value-container` class is the noir-space-ship loop tests'
  ## selector and stays beside the design-system utilities.
  result = element[R, N](r, "div", "flow-multiline-value-container ct-flex ct-p-0",
    "flow-multiline-value-" & $control.position & "-" & $control.stepCount)
  if control.live:
    r.appendChild(result, renderFlowLoopButton[R, N](r, false, control.canBack,
                                                     handlers.onBack))
    r.appendChild(result, renderFlowLoopIteration[R, N](r, control, style,
                                                        handlers.onCommit))
    r.appendChild(result, renderFlowLoopButton[R, N](r, true, control.canForward,
                                                     handlers.onForward))

proc renderFlowLoopSliderTrack*[R, N](r: R; position: int;
                                      style: FlowStyle): N =
  ## `#flow-loop-slider-<line>` — the node the host hands to noUiSlider
  ## (`ui/flow_loop_slider`), the one third-party widget of inline flow,
  ## mounted on the DOM node only.
  result = element[R, N](r, "div", "flow-loop-slider",
    "flow-loop-slider-" & $position)
  applyStyle[R, N](r, result, style)

proc renderFlowLoopSlider*[R, N](r: R; position: int;
                                 containerStyle, sliderStyle: FlowStyle): N =
  ## `#flow-loop-slider-container-<line>` with its track inside it.
  result = element[R, N](r, "div", "flow-loop-slider-container",
    "flow-loop-slider-container-" & $position)
  applyStyle[R, N](r, result, containerStyle)
  r.appendChild(result, renderFlowLoopSliderTrack[R, N](r, position,
                                                        sliderStyle))

# ---------------------------------------------------------------------------
# View zones
# ---------------------------------------------------------------------------

proc renderFlowViewZone*[R, N](r: R; position: int;
                               lineNumbersWidth: string;
                               contentWidget = false): N =
  ## `#flow-view-zone-<line>` — the row Monaco opens under a line for its
  ## multiline values or its loop control (`contentWidget`: then it is also
  ## `.flow-content-widget`, as the line's content widgets are), with a
  ## `.line-numbers` strip so the gutter stays continuous through it.
  result = element[R, N](r, "div",
    if contentWidget: "flow-view-zone flow-content-widget" else: "flow-view-zone",
    "flow-view-zone-" & $position)
  r.setStyle(result, "display", "flex")
  let gutter = element[R, N](r, "div", "line-numbers")
  r.setStyle(gutter, "height", "100%")
  if lineNumbersWidth.len > 0:
    r.setStyle(gutter, "width", lineNumbersWidth)
  r.setStyle(gutter, "position", "absolute")
  r.setStyle(gutter, "left", "0px")
  r.appendChild(result, gutter)

# ---------------------------------------------------------------------------
# The value context menu
# ---------------------------------------------------------------------------

type
  FlowValueMenuAction* = enum
    fvmaJump              ## Jump to the step that produced the value.
    fvmaScratchpad        ## Add this value to the scratchpad.
    fvmaScratchpadAll     ## Add every value of the step to the scratchpad.

  FlowValueMenuEntry* = object
    name*, hint*: string
    action*: FlowValueMenuAction

func flowValueMenu*(): seq[FlowValueMenuEntry] =
  ## The entries a right click on a value offers, in order (the menu itself
  ## is the editor's shared context menu).
  @[FlowValueMenuEntry(name: "Jump to value", hint: "<click on value>",
                       action: fvmaJump),
    FlowValueMenuEntry(name: "Add value to scratchpad",
                       hint: "CTRL+<click on value>", action: fvmaScratchpad),
    FlowValueMenuEntry(name: "Add all values to scratchpad", hint: "",
                       action: fvmaScratchpadAll)]
