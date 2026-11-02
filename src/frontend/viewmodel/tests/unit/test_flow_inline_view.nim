## test_flow_inline_view.nim
##
## Inline flow's elements are views generic over the renderer
## (Shared-DOM-Front-Ends D7.4 (b)). This suite renders the very procs
## `ui/flow.nim` places in Monaco's view zones and content widgets, under
## `MockRenderer`, and checks two things per element: the markup the GUI page
## objects select on (`FlowValue`, `OmniscientLoopControls`, the noir-space-ship
## loop tests), and what each gesture reports — the jump, the scratchpad, the
## context menu, the loop control's back / forward / typed iteration.
##
## No mock beyond `MockRenderer` and the `MockEvent`s it dispatches: the views
## take plain values and report gestures through handlers this suite records.

import std/[strutils, tables, unittest]

import isonim/testing/mock_dom

import views/isonim_flow_inline_view

proc classes(node: MockNode): seq[string] =
  node.attributes.getOrDefault("class", "").splitWhitespace()

proc attr(node: MockNode; name: string): string =
  node.attributes.getOrDefault(name, "")

proc textOf(node: MockNode): string =
  if node.kind == mnkText:
    return node.text
  for child in node.children:
    result.add textOf(child)

proc collect(node: MockNode; cls: string; found: var seq[MockNode]) =
  if node.isNil: return
  if node.kind == mnkElement and cls in node.classes:
    found.add node
  for child in node.children:
    collect(child, cls, found)

proc allByClass(node: MockNode; cls: string): seq[MockNode] =
  collect(node, cls, result)

proc byClass(node: MockNode; cls: string): MockNode =
  let found = allByClass(node, cls)
  doAssert found.len > 0, "no ." & cls
  found[0]

proc fire(node: MockNode; event: string; ctrl = false; shift = false;
          key = ""): MockEvent =
  result = MockEvent(`type`: event, target: node, currentTarget: node,
                     ctrlKey: ctrl, shiftKey: shift, key: key)
  fireEventWith(node, event, result)

let r = MockRenderer()

suite "a variable's chip":

  test "a before-only chip is one box with the page objects' id and classes":
    let boxes = planFlowValueChip("parallel", fvmBefore, 2, 17, "x", "10", "")
    check boxes.len == 1
    check boxes[0].id == "flow-parallel-value-box-2-17-x"
    check boxes[0].className ==
      "flow-parallel-value-box flow-parallel-value-before-only"
    # `FlowValue.supportsScratchpad` wants at least six dash-separated parts.
    check boxes[0].id.split('-').len >= 6

  test "an after-only chip shows the produced value":
    let boxes = planFlowValueChip("inline", fvmAfter, 0, 4, "y", "1", "2")
    check boxes.len == 1
    check boxes[0].side == fvsAfter
    check boxes[0].text == "2"
    check "flow-inline-value-after-only" in boxes[0].className.split(' ')

  test "a dual chip is before, the arrow, then after, each with one id":
    let boxes = planFlowValueChip("parallel", fvmBeforeAndAfter, 1, 9, "s",
                                  "1", "2")
    check boxes.len == 2
    check boxes[0].id == "flow-parallel-value-box-1-9-before-s"
    check boxes[1].id == "flow-parallel-value-box-1-9-after-s"
    for b in boxes:
      check ' ' notin b.id
      check b.id.endsWith("-s")
    let chip = renderFlowVariableChip[MockRenderer, MockNode](r, "parallel",
      "s", boxes, 3, showName = true, viewMore = false, @[],
      FlowChipHandlers())
    check chip.children.len == 4
    check chip.children[0].classes == @["ct-omni-name"]
    check "flow-dual-value-before" in chip.children[1].classes
    check chip.children[2].classes ==
      @["flow-parallel-value-name", "flow-dual-arrow"]
    check chip.children[2].textOf == "=>"
    check chip.children[3].textOf == "2"
    check chip.children[3].attr("iteration") == "3"

  test "a cut-short value gets the view-more button and its cap":
    let boxes = planFlowValueChip("parallel", fvmBefore, 0, 1, "big",
                                  "[1, 2, 3…", "", beforeMaxWidth = "120px")
    var opened = 0
    let chip = renderFlowVariableChip[MockRenderer, MockNode](r, "parallel",
      "big", boxes, 0, showName = false, viewMore = true,
      @[("fontSize", "13px")],
      FlowChipHandlers(onViewMore: (proc(input: FlowInput) = inc opened)))
    let button = chip.byClass("flow-view-more-button")
    check "flow-hide-content" in button.classes
    check button.styles["fontSize"] == "13px"
    let ev = button.fire("mousedown")
    check opened == 1
    check ev.propagationStopped   # the press must not reach Monaco
    check chip.byClass("flow-parallel-value-box").styles["maxWidth"] == "120px"
    check chip.allByClass("ct-omni-name").len == 0

  test "pressing a box reports which value; ctrl is the scratchpad's":
    let boxes = planFlowValueChip("parallel", fvmBeforeAndAfter, 0, 5, "v",
                                  "1", "2")
    var pressed: seq[(FlowValueSide, string, bool)]
    proc onPress(side: FlowValueSide; id: string; input: FlowInput) =
      pressed.add((side, id, input.ctrl))
      input.stop = true
    let chip = renderFlowVariableChip[MockRenderer, MockNode](r, "parallel",
      "v", boxes, 0, showName = false, viewMore = false, @[],
      FlowChipHandlers(onBoxPress: onPress))
    let shown = chip.allByClass("flow-parallel-value-box")
    discard shown[0].fire("mousedown")
    let ev = shown[1].fire("mousedown", ctrl = true)
    # Each box reports ITSELF: a dual chip's before box is not its after box.
    check pressed == @[(fvsBefore, boxes[0].id, false),
                       (fvsAfter, boxes[1].id, true)]
    check ev.propagationStopped

  test "each box of a dual chip hovers its own value":
    let boxes = planFlowValueChip("parallel", fvmBeforeAndAfter, 0, 5, "v",
                                  "1", "2")
    var hovered: seq[(FlowValueSide, string)]
    proc onHover(side: FlowValueSide; id: string; input: FlowInput) =
      hovered.add((side, id))
    let chip = renderFlowVariableChip[MockRenderer, MockNode](r, "parallel",
      "v", boxes, 0, showName = false, viewMore = false, @[],
      FlowChipHandlers(onBoxHover: onHover))
    for node in chip.allByClass("flow-parallel-value-box"):
      discard node.fire("mouseover")
    check hovered == @[(fvsBefore, boxes[0].id), (fvsAfter, boxes[1].id)]

  test "a right click and a hover reach the host with the box":
    let boxes = planFlowValueChip("parallel", fvmBefore, 0, 5, "v", "1", "")
    var contexts, hovers: seq[string]
    proc onContext(side: FlowValueSide; id: string; input: FlowInput) =
      if not input.shift:
        input.prevent = true
        contexts.add id
    proc onHover(side: FlowValueSide; id: string; input: FlowInput) =
      hovers.add id
    let chip = renderFlowVariableChip[MockRenderer, MockNode](r, "parallel",
      "v", boxes, 0, showName = true, viewMore = false, @[],
      FlowChipHandlers(onBoxContext: onContext, onBoxHover: onHover))
    let box = chip.byClass("flow-parallel-value-box")
    check box.fire("contextmenu").defaultPrevented
    check not box.fire("contextmenu", shift = true).defaultPrevented
    discard box.fire("mouseover")
    check contexts == @[boxes[0].id]
    check hovers == @[boxes[0].id]

  test "pressing the name jumps; a right click on it opens the menu":
    var jumps, menus = 0
    let chip = renderFlowVariableChip[MockRenderer, MockNode](r, "parallel",
      "i", planFlowValueChip("parallel", fvmBefore, 0, 0, "i", "0", ""), 0,
      showName = true, viewMore = false, @[],
      FlowChipHandlers(onNamePress: (proc(input: FlowInput) = inc jumps),
                       onNameContext: (proc(input: FlowInput) = inc menus)))
    let name = chip.byClass("ct-omni-name")
    check name.textOf == "i"
    discard name.fire("mousedown")
    discard name.fire("contextmenu")
    check jumps == 1
    check menus == 1

suite "an event's chip":

  test "an output event is <stdout> and a standard box":
    var jumps = 0
    let chip = renderFlowEventChip[MockRenderer, MockNode](r, "parallel",
      FlowEventChip(name: "stdout", nameClassSuffix: "-std",
                    valueClass: "flow-std-default-box", text: "hello"),
      12, 0, 2, @[], "120px",
      onJump = (proc(input: FlowInput) = inc jumps), onViewMore = nil)
    check chip.children.len == 2
    check chip.children[0].classes == @["ct-omni-name-std"]
    check chip.children[0].textOf == "<stdout>"
    let box = chip.children[1]
    check box.attr("id") == "flow-parallel-value-box-12-0"
    check box.attr("id") == flowEventBoxId("parallel", 12, 0)
    check "flow-std-default-box" in box.classes
    check "flow-parallel-value-before-only" in box.classes
    check box.attr("iteration") == "2"
    check "maxWidth" notin box.styles
    discard box.fire("mousedown")
    discard chip.children[0].fire("mousedown")
    check jumps == 2

  test "a long event is capped and opens its popup":
    var opened = 0
    let chip = renderFlowEventChip[MockRenderer, MockNode](r, "inline",
      FlowEventChip(name: "error", nameClassSuffix: "-error",
                    valueClass: "flow-error-box", text: "x".repeat(200),
                    truncated: true),
      3, 1, 0, @[], "120px",
      onJump = nil, onViewMore = (proc(input: FlowInput) = inc opened))
    let button = chip.byClass("flow-view-more-button")
    check "ct-omni-name-error" in button.classes
    check button.fire("mousedown").propagationStopped
    check opened == 1
    check chip.byClass("flow-error-box").styles["maxWidth"] == "120px"
    let popup = renderFlowEventPopup[MockRenderer, MockNode](r, "full text")
    check popup.classes == @["flow-event-value-popup"]
    check popup.textOf == "full text"

suite "a line's values":

  test "a step's values sit in one single-value band, gaps between chips":
    let step = renderFlowComplexStep[MockRenderer, MockNode](r, "parallel", 14,
      @[("left", "calc(40ch)")])
    check step.attr("id") == "flow-parallel-value-14"
    check step.classes == @["flow-parallel", "flow-parallel-value-single"]
    check step.styles["left"] == "calc(40ch)"
    check renderFlowValueGap[MockRenderer, MockNode](r).classes ==
      @["flow-loop-empty-space"]

  test "a multiline value under a later row points up at its expression":
    let first = renderFlowMultilineValue[MockRenderer, MockNode](r, 6, "a",
      0.0, 88.0, pointer = false)
    check first.attr("id") == "flow-multiline-value-6-a"
    check first.styles["top"] == "0.0px"
    check first.styles["left"] == "88.0px"
    check first.children.len == 0
    let later = renderFlowMultilineValue[MockRenderer, MockNode](r, 6, "b",
      38.0, 120.0, pointer = true)
    let arrow = later.byClass("flow-multiline-value-pointer")
    check arrow.styles["top"] == "-38.0px"
    check arrow.styles["height"] == "38.0px"

  test "the content widget host is a content widget":
    let host = renderFlowLineHost[MockRenderer, MockNode](r)
    check host.tag == "div"
    check host.classes == @["flow-content-widget"]
    check host.children.len == 0

suite "a loop's cells":

  test "an iteration's cell is keyed by loop and iteration":
    let cell = renderFlowLoopStepContainer[MockRenderer, MockNode](r, 2, 5)
    check cell.attr("id") == "flow-loop-step-container-2-5"
    check cell.classes == @["flow-loop-step-container"]
    check "continuous" in renderFlowLoopStepContainer[MockRenderer, MockNode](
      r, 2, 5, fcContinuous).classes
    check "shrinked" in renderFlowLoopStepContainer[MockRenderer, MockNode](
      r, 2, 5, fcShrinked).classes

  test "a collapsed cell jumps on a click and opens on a double click":
    var jumps, opens = 0
    let cell = renderFlowCollapsedStep[MockRenderer, MockNode](r, 31,
      fcContinuous, @[("top", "0px")],
      onJump = (proc(input: FlowInput) = inc jumps),
      onOpen = (proc(input: FlowInput) = inc opens))
    check cell.attr("id") == "flow-loop-shrinked-iteration-step-31"
    check cell.classes == @["flow-loop-continuous-iteration"]
    discard cell.fire("click")
    discard cell.fire("dblclick")
    check jumps == 1
    check opens == 1
    check cell.fire("mouseover").propagationStopped
    let shrunk = renderFlowCollapsedStep[MockRenderer, MockNode](r, 31,
      fcShrinked, @[], nil, nil)
    check shrunk.classes == @["flow-loop-shrinked-iteration"]

  test "a shrunk loop marks each of its cells":
    let mark = renderFlowShrinkedIteration[MockRenderer, MockNode](r, 4)
    check mark.attr("id") == "flow-loop-shrinked-iteration-4"
    check mark.classes == @["flow-loop-shrinked-iteration"]

  test "the legend lays its headings out by percentage":
    let legend = renderFlowLegend[MockRenderer, MockNode](r, 300.0, 180.0,
      @[("i", 40.0), ("sum", 50.0)], 10.0)
    check legend.classes == @["flow-loop-legend"]
    check legend.styles["left"] == "300.0px"
    check legend.children.len == 3
    check legend.children[0].textOf == "i"
    check legend.children[0].styles["width"] == "40.0%"
    check legend.children[1].classes == @["flow-loop-empty-space"]
    check legend.children[1].styles["width"] == "10.0%"
    check legend.children[2].textOf == "sum"

  test "a loop's containers and background carry their ids":
    let outer = renderFlowLoopContainer[MockRenderer, MockNode](r,
      "flow-loop-container-7", nested = false, @[("height", "19px")])
    check outer.classes == @["flow-loop-container"]
    check outer.styles["height"] == "19px"
    let inner = renderFlowLoopContainer[MockRenderer, MockNode](r,
      "flow-loop-container-7-1-0", nested = true, @[])
    check inner.classes == @["flow-nested-loop-container"]
    let back = renderFlowLoopBackground[MockRenderer, MockNode](r, 1,
      10.0, 20.0, 300.0, 57.0)
    check back.attr("id") == "flow-loop-1-background"
    check back.styles["height"] == "57.0px"

suite "the loop control":

  proc control(iteration = 3; all = 9): FlowLoopControl =
    FlowLoopControl(position: 12, stepCount: 40, live: true,
                    iteration: iteration, allIterations: all,
                    canBack: iteration > 0, canForward: iteration < all)

  test "back, the iteration field, forward; disabled at the ends":
    let node = renderFlowLoopControl[MockRenderer, MockNode](r, control(0), @[],
      FlowLoopControlHandlers())
    check node.attr("id") == "flow-multiline-value-12-40"
    check "flow-multiline-value-container" in node.classes
    let back = node.byClass("backward")
    check back.attr("id") == "backward-loop"
    check back.attr("disabled") == "disabled"
    check node.byClass("forward").attr("disabled") == ""
    let field = node.byClass("flow-loop-textarea")
    check field.tag == "textarea"
    check field.attr("value") == "0"
    check r.inputValue(field) == "0"
    check field.attr("maxlength") == "1"
    check field.styles["width"] == "2ch"
    check node.byClass("flow-parallel-loop-iteration-end").textOf == "from 9"

  test "a header with no tick draws only the container":
    var c = control()
    c.live = false
    let node = renderFlowLoopControl[MockRenderer, MockNode](r, c, @[],
      FlowLoopControlHandlers())
    check node.children.len == 0

  test "the buttons step; a typed iteration commits on Enter and on blur":
    var steps: seq[string]
    var commits: seq[(int, bool)]
    let node = renderFlowLoopControl[MockRenderer, MockNode](r, control(), @[],
      FlowLoopControlHandlers(
        onBack: (proc(input: FlowInput) = steps.add "back"),
        onForward: (proc(input: FlowInput) = steps.add "forward"),
        onCommit: (proc(iteration: int; viaBlur: bool) =
          commits.add((iteration, viaBlur)))))
    discard node.byClass("backward").fire("click")
    discard node.byClass("forward").fire("click")
    check steps == @["back", "forward"]
    let field = node.byClass("flow-loop-textarea")
    r.setInputValue(field, "7")
    discard field.fire("input")
    check field.fire("keydown", key = "Enter").defaultPrevented
    check not field.fire("keydown", key = "7").defaultPrevented
    r.setInputValue(field, "42")      # past the last iteration: ignored
    discard field.fire("input")
    discard field.fire("blur")
    check commits == @[(7, false), (7, true)]

  test "an entry is kept only when it is an in-range number":
    check clampedIterationEntry("4", 9, 1) == 4
    check clampedIterationEntry("10", 9, 1) == 1
    check clampedIterationEntry("-1", 9, 1) == 1
    check clampedIterationEntry("abc", 9, 1) == 1
    check clampedIterationEntry("", 9, 1) == 1

  test "the slider's host is the container and the slider inside it":
    let node = renderFlowLoopSlider[MockRenderer, MockNode](r, 12,
      @[("left", "calc(80px - 2ch)")], @[("marginLeft", "4ch")])
    check node.attr("id") == "flow-loop-slider-container-12"
    check node.styles["left"] == "calc(80px - 2ch)"
    let slider = node.byClass("flow-loop-slider")
    check slider.attr("id") == "flow-loop-slider-12"
    check slider.styles["marginLeft"] == "4ch"

suite "the view zone and the value menu":

  test "a view zone keeps the gutter continuous":
    let zone = renderFlowViewZone[MockRenderer, MockNode](r, 8, "52px")
    check zone.attr("id") == "flow-view-zone-8"
    check zone.classes == @["flow-view-zone"]
    check renderFlowViewZone[MockRenderer, MockNode](r, 8, "", true).classes ==
      @["flow-view-zone", "flow-content-widget"]
    check zone.styles["display"] == "flex"
    let gutter = zone.byClass("line-numbers")
    check gutter.styles["width"] == "52px"
    check gutter.styles["position"] == "absolute"
    check "width" notin renderFlowViewZone[MockRenderer, MockNode](r, 8, "")
      .byClass("line-numbers").styles

  test "a value's menu is jump, add, add all":
    let menu = flowValueMenu()
    check menu.len == 3
    check menu[0].name == "Jump to value"
    check menu[0].action == fvmaJump
    check menu[1].name == "Add value to scratchpad"
    check menu[1].hint == "CTRL+<click on value>"
    check menu[2].name == "Add all values to scratchpad"
    check menu[2].action == fvmaScratchpadAll
