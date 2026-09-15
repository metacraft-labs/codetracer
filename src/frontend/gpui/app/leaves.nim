## LAYER RULE — `src/frontend/gpui/app/` is the SDK-CONSUMING half of the GPUI
## front-end. See the `.sdk-consumer` marker beside this file.
##
## gpui/app/leaves.nim — PLAT-20. **The leaves, and this is the ONLY module of
## this front-end that imports GPUI.**
##
## ## What the split buys, said where it is paid for
##
## PLAT-20: *"the shell is `HeadlessApp` plus the layout model, and only the
## leaves are GPUI. This is the same split the TUI already demonstrates, and the
## reason a third front-end is a binding rather than a rewrite."*
##
## `shell.nim` asserts the first half — it cannot see a renderer, at compile
## time. This module is the second half, and the whole of it: everything GPUI
## in the CodeTracer GPUI front-end is one `import isonim_gpui/renderer`, below,
## and the element tree built out of a `GpuiLeafSet`. Nothing in here knows what
## a `Layout` is, what a `LayoutCommand` is, or what a session is. It is handed
## slots and ViewModels and it draws them.
##
## ## The arrangement is NOT drawn here, and that is the dock binding's job
##
## A leaf's rectangle comes from the dock, not from this module: `DockPaneSlot`
## carries a placement and a tab group and no pixels, and the pixels are in the
## document `dock_projection` hands the dock host. So this module emits one
## element subtree per leaf, tagged with the slot, and lets the container place
## it — which is exactly what makes a real `DockArea` a drop-in for the
## placeholder container below on the day gpui-kit is a dependency.
##
## ## WHAT IS A PLACEHOLDER HERE, NAMED RATHER THAN IMPLIED
##
## `gpuiKitDockAvailable` is `false`, and it is a constant rather than a
## comment. gpui-kit is not a dependency of this workspace — measured, with
## three independent blockers, in PLAT-20's status block — so there is no
## `DockArea` to hand this tree to and the container below is a plain flex
## `div`. That is a LAYOUT placeholder and not a model placeholder: the
## placement it draws is read from the same projected document a `DockArea`
## would be given, so replacing the container does not change a single leaf.

import std/[json, strutils]

import isonim_gpui/renderer
import ./shell

export shell

const gpuiKitDockAvailable* = false
  ## **Whether a real gpui-kit `DockArea` is hosting these leaves.**
  ##
  ## `false`, and asserted as `false` by `tests/test_gpui_shell_split.nim`
  ## rather than left as prose, so the day it becomes `true` a test has to be
  ## updated by somebody who has read why. A `when` on this constant is what a
  ## milestone that vendors gpui-kit edits; nothing else here needs to move.
  ##
  ## Verification-Harness-Traps §7a is the reason it is a value: a header
  ## sentence saying "the dock is not wired yet" is the most comfortable place
  ## for a claim that stops being true without anything going red.

const
  PaneRoleAttribute* = "data-ct-pane"
  SlotPathAttribute* = "data-ct-slot-path"
  TabAttribute* = "data-ct-tab"
  StateAttribute* = "data-ct-state"
    ## The four attributes a leaf carries into the element tree. They are what
    ## `renderPlanJson` shows, so a test can assert *which pane was drawn where*
    ## without a display and without a pixel — the render-plan tier PLAT-19
    ## established for isonim-gpui, used here for the arrangement rather than
    ## for a component.

type
  LeafRenderOutcome* = object
    root*: GpuiElement
      ## The container holding one child per leaf.
    drawn*: int
      ## How many leaves produced a subtree. Equal to `leaves.len` on every
      ## path — a leaf with no ViewModel draws its REPORT rather than nothing,
      ## which is PLAT-9's rule and the reason this number is asserted rather
      ## than trusted.
    reported*: int
      ## How many of those were a report (no ViewModel, or an unloaded
      ## extension) rather than a live pane.

proc slotPath(slot: DockPaneSlot): string =
  var parts: seq[string] = @[$slot.region]
  for i in slot.path:
    parts.add $i
  parts.join("/")

proc renderLeaf(r: GpuiRenderer; leaf: GpuiLeaf): (GpuiElement, bool) =
  ## One leaf's subtree, and whether it is a REPORT rather than a live pane.
  ##
  ## Three states and not two, which is PLAT-9's `PaneRefKind` arriving at a
  ## renderer: a live pane, a pane whose session has not launched, and a
  ## contributed pane from an extension that is not loaded. The third keeps its
  ## slot and names the extension — *"the layout keeps the slot, the front-end
  ## renders a report naming the extension, and reinstalling it restores the
  ## pane where it was"* — and none of the three is a blank region.
  let node = r.createElement("div")
  r.setAttribute(node, PaneRoleAttribute, leaf.paneId)
  r.setAttribute(node, SlotPathAttribute, slotPath(leaf.slot))
  r.setAttribute(node, TabAttribute,
                 $leaf.slot.tabIndex & "/" & $leaf.slot.tabCount &
                 "@" & $leaf.slot.activeIndex)
  case leaf.kind
  of glkUnloadedExtension:
    r.setAttribute(node, StateAttribute, "unloaded-extension")
    let text = r.createTextNode(
      "This pane is provided by an extension that is not loaded: " &
      leaf.paneId)
    r.appendChild(node, text)
    return (node, true)
  of glkBuiltin, glkContributed:
    if not leaf.live:
      r.setAttribute(node, StateAttribute, "not-launched")
      let text = r.createTextNode(
        (if leaf.title.len > 0: leaf.title else: leaf.paneId) &
        " — waiting for the session to launch")
      r.appendChild(node, text)
      return (node, true)
    r.setAttribute(node, StateAttribute, "live")
    let text = r.createTextNode(
      if leaf.title.len > 0: leaf.title else: leaf.paneId)
    r.appendChild(node, text)
    return (node, false)

proc renderLeaves*(r: GpuiRenderer; leafSet: GpuiLeafSet): LeafRenderOutcome =
  ## Build the element tree for one window.
  ##
  ## A REFUSED projection draws its refusal. It does not draw an empty window
  ## and it does not fall back to a default arrangement: the terminal's
  ## `ppDegrade` exists because a terminal must paint something on a real
  ## screen the user is already looking at, and a host that has not opened a
  ## window yet has no such obligation.
  let root = r.createElement("div")
  r.setAttribute(root, "data-ct-window", $int(leafSet.windowId))
  r.setAttribute(root, "data-ct-dock",
                 if gpuiKitDockAvailable: "gpui-kit" else: "flex-placeholder")
  r.setStyle(root, "display", "flex")
  result = LeafRenderOutcome(root: root, drawn: 0, reported: 0)
  if leafSet.refused.len > 0:
    r.setAttribute(root, StateAttribute, "refused")
    let text = r.createTextNode("layout refused: " &
                                describe(leafSet.refused))
    r.appendChild(root, text)
    return
  for leaf in leafSet.leaves:
    let (node, reported) = renderLeaf(r, leaf)
    r.appendChild(root, node)
    inc result.drawn
    if reported:
      inc result.reported

proc leafPlanJson*(r: GpuiRenderer; outcome: LeafRenderOutcome): string =
  ## The render plan GPUI would execute, as JSON. The verification tier
  ## PLAT-19 built for isonim-gpui, pointed at PLAT-20's arrangement.
  r.renderPlanJson(outcome.root)

proc leafPlanIsValid*(r: GpuiRenderer; outcome: LeafRenderOutcome): bool =
  r.verifyRenderPlan(outcome.root)

proc drawnPaneIds*(r: GpuiRenderer; outcome: LeafRenderOutcome): seq[string] =
  ## Which pane each child of the container is for, read back out of the
  ## shadow tree rather than out of the input. A test asserting the input
  ## would be asserting its own fixture.
  result = @[]
  let n = childCount(outcome.root)
  for i in 0 ..< n:
    let child = nthChild(outcome.root, i)
    if child.isNil: continue
    let id = getAttribute(child, PaneRoleAttribute)
    if id.len > 0:
      result.add id

proc planLeafTexts*(planJson: string): seq[string] =
  ## Every text node of the render plan, in plan order.
  ##
  ## **A SECOND READING OF THE SAME TREE THROUGH A DIFFERENT CODE PATH**, and
  ## it is the plan that GPUI would execute rather than the shadow tree this
  ## module wrote. `drawnPaneIds` reads what we put in; this reads what comes
  ## out of the shim's own plan builder, so a leaf that was appended to the
  ## wrong parent, or a container the plan builder dropped, is visible to one
  ## reader and not the other.
  ##
  ## **IT READS `text` AND NOT AN ATTRIBUTE, AND THAT IS MEASURED RATHER THAN
  ## PREFERRED.** The first version of this function read
  ## `attributes["data-ct-pane"]` out of the plan, which would have been the
  ## direct reading — and the shim's plan serialises `kind`, `tag`, `text`,
  ## `has_click_handler`, `has_input_handler`, `event_names`, `styles` and
  ## `children`, and no attribute map at all. Every call would have returned an
  ## empty seq, and an empty seq satisfies every assertion anybody would write
  ## over it (Verification-Harness-Traps §4). Measured on a real recording
  ## through a real `replay-server` before this comment was written; the plan
  ## printed by `codetracer-gpui --report-plan` is the evidence.
  var texts: seq[string] = @[]
  if planJson.len == 0:
    return texts
  var doc: JsonNode
  try:
    doc = parseJson(planJson)
  except CatchableError:
    return texts
  proc walk(n: JsonNode; acc: var seq[string]) =
    if n.isNil: return
    case n.kind
    of JObject:
      let t = n{"text"}
      if not t.isNil and t.kind == JString and t.getStr.len > 0:
        acc.add t.getStr
      let kids = n{"children"}
      if not kids.isNil:
        walk(kids, acc)
    of JArray:
      for v in n:
        walk(v, acc)
    else: discard
  walk(doc, texts)
  texts
