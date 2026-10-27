## test_flow_value_view.nim
##
## The Omniscience value chip and the parallel-column band are views generic
## over the renderer (Shared-DOM-Front-Ends D7.4 (b)). This suite renders the
## very procs the debugger's inline flow and the review's diff tab render,
## under `MockRenderer`, and checks the markup the Playwright page objects
## read (`FlowValue`, `OmniscientLoopControls`, the review band): the classes,
## the value box's id scheme and `iteration` attribute, and the inline styles
## that place a band and size a column.
##
## No mock beyond `MockRenderer`: the views take plain values.

import std/[strutils, tables, unittest]

import isonim/testing/mock_dom

import views/isonim_flow_value_view

proc renderFlowValueChip[R, N](r: R; name, boxId, boxClass, valueText: string;
                               iteration: int; style: FlowStyle = @[];
                               boxStyle: FlowStyle = @[]; maxWidth = ""): N =
  ## A whole chip: the container with its name and its value box.
  result = renderFlowValueContainer[R, N](r, style)
  r.appendChild(result, renderFlowValueName[R, N](r, name))
  r.appendChild(result, renderFlowValueBox[R, N](r, boxId, boxClass, valueText,
                                                 iteration, boxStyle, maxWidth))

proc classes(node: MockNode): seq[string] =
  node.attributes.getOrDefault("class", "").splitWhitespace()

proc textOf(node: MockNode): string =
  if node.kind == mnkText:
    return node.text
  for child in node.children:
    result.add textOf(child)

suite "the flow value chip":

  test "the container carries the appearance class and the given style":
    let node = renderFlowValueContainer[MockRenderer, MockNode](
      MockRenderer(), @[("fontSize", "12px"), ("lineHeight", "18px")])
    check node.tag == "span"
    check FlowValueContainerClass in node.classes
    check node.styles["fontSize"] == "12px"
    check node.styles["lineHeight"] == "18px"

  test "the name half carries the name":
    let node = renderFlowValueName[MockRenderer, MockNode](MockRenderer(), "x")
    check node.classes == @[FlowValueNameClass]
    check node.textOf == "x"

  test "the value box carries its id, class, iteration and text":
    let node = renderFlowValueBox[MockRenderer, MockNode](
      MockRenderer(), "flow-1-0-3-12-x", "flow-loop-value-box flow-std-default-box",
      "10", 3)
    check node.attributes["id"] == "flow-1-0-3-12-x"
    check "flow-std-default-box" in node.classes
    check node.attributes["iteration"] == "3"
    check node.textOf == "10"
    check "maxWidth" notin node.styles

  test "a value box is capped only when a max width is given":
    let capped = renderFlowValueBox[MockRenderer, MockNode](
      MockRenderer(), "id", "box", "a long value", 0, maxWidth = "80px")
    check capped.styles["maxWidth"] == "80px"

  test "the empty placeholder says no value unless told otherwise":
    let r = MockRenderer()
    let empty = renderFlowValueEmpty[MockRenderer, MockNode](r)
    check empty.classes == @[FlowValueEmptyClass]
    check empty.textOf == "no value"
    let skipped = renderFlowValueEmpty[MockRenderer, MockNode](
      r, @[("width", "40px")], "—")
    check skipped.textOf == "—"
    check skipped.styles["width"] == "40px"

  test "a whole chip is the container with its name, then its value":
    let chip = renderFlowValueChip[MockRenderer, MockNode](
      MockRenderer(), "i", "flow-1-0-2-5-i", "flow-inline-value-box", "2", 2)
    check FlowValueContainerClass in chip.classes
    check chip.children.len == 2
    check chip.children[0].classes == @[FlowValueNameClass]
    check chip.children[0].textOf == "i"
    check chip.children[1].attributes["iteration"] == "2"
    check chip.children[1].textOf == "2"

suite "the parallel-column band":

  test "a column carries its width as a style and as a class":
    let column = renderFlowValueColumn[MockRenderer, MockNode](
      MockRenderer(), "flow-parallel-values-7", 42.6)
    check column.tag == "div"
    check column.classes == @[FlowValueColumnClass,
                              FlowValueColumnClass & "-width-42"]
    check column.styles["width"] == "42px"
    check column.attributes["id"] == "flow-parallel-values-7"

  test "a column with no id has no id attribute":
    let column = renderFlowValueColumn[MockRenderer, MockNode](
      MockRenderer(), "", 10.0)
    check "id" notin column.attributes

  test "the group and the loop band carry their classes":
    let r = MockRenderer()
    check renderFlowValueGroup[MockRenderer, MockNode](r).classes ==
      @[FlowValueGroupClass]
    check renderFlowValueLoopValues[MockRenderer, MockNode](r, 2).classes ==
      @[FlowValueLoopValuesClass, "loop-2"]

  test "a loop band and a single line's band differ by class":
    let r = MockRenderer()
    let loop = renderFlowValueBand[MockRenderer, MockNode](r, 120.4, true)
    check loop.classes == @[FlowValueBandClass, FlowValueBandLoopClass]
    check loop.styles["left"] == "120px"
    check "position" notin loop.styles
    check "maxWidth" notin loop.styles
    let single = renderFlowValueBand[MockRenderer, MockNode](
      r, 120.0, false, "review-flow-band-host")
    check single.classes == @[FlowValueBandClass, FlowValueBandSingleClass,
                              "review-flow-band-host"]

  test "a band in an unpositioned host positions itself and caps its width":
    let band = renderFlowValueBand[MockRenderer, MockNode](
      MockRenderer(), 8.0, true, positioned = true, maxWidthPx = 600.0)
    check band.styles["position"] == "relative"
    check band.styles["maxWidth"] == "600px"
