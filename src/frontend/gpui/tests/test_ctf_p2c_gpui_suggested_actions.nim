## CTF-P2c step 3: the GPUI suggested-actions block at the end of a
## session's timeline (study §2.3, D23, D54-D59), in the story host that
## mounts it (`gpui/agent_harbor/ah_stories.nim`).
##
## * **The block is pinned beneath the list** on a ground a step off the
##   panel, after the timeline's lines.
## * **An unchecked action is dimmer** than a checked one (D52), and one
##   CodeTracer cannot perform carries no press.
## * **Presses are routed**: a press-down on a row toggles it, on Approve
##   performs the checked actions; the view redraws from the viewmodel: no
##   block, the record lines after the timeline's lines, at levels 0 and 1.
##
## No mocks: the real isonim-gpui shadow tree (the shim loaded in process,
## no window) and the stories' own viewmodels over the scripted performer
## and action source.

import std/[math, sequtils, strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
import ../agent_harbor/ah_suggested_actions
from ../../viewmodel/input/element_press import OperationAttribute

let r = GpuiRenderer()

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc tagged(root: GpuiElement; fact: string): seq[GpuiElement] =
  collect(root, "data-ah-" & fact, result)

proc carrying(root: GpuiElement; operation: string): seq[GpuiElement] =
  var all: seq[GpuiElement]
  collect(root, OperationAttribute, all)
  all.filterIt(getAttribute(it, OperationAttribute) == operation)

proc fact(e: GpuiElement; name: string): string = getAttribute(e, "data-ah-" & name)

proc mount(fixture: string; width = 760; height = 640; mode = dmDark): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-suggested-actions", fixture, width, height, mode,
                              frameTitle = "Agent Activity")

# WCAG 2's contrast ratio (https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio).
proc luminance(hex: string): float =
  for k, i in [1, 3, 5]:
    let c = float(parseHexInt(hex[i .. i + 1])) / 255.0
    let lin = if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)
    result += [0.2126, 0.7152, 0.0722][k] * lin
proc contrast(a, b: string): float =
  let (la, lb) = (luminance(a), luminance(b))
  (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

suite "CTF-P2c: the GPUI suggested-actions block":
  test "on a ground a step off the panel, after the timeline's lines":
    for mode in [dmDark, dmLight]:
      let m = mount("unsupported", mode = mode)
      let blocks = m.view.tagged("suggestion-phase")
      check blocks.len == 1
      let blk = blocks[0]
      let p = ahPalette(mode)
      check blockGround(p) != p.panel
      check blk.fact("ground") == blockGround(p)
      check blk.tagged("suggested-action").len == 3
      check blk.tagged("suggested-button").mapIt(it.fact("suggested-button")) == @["approve", "dismiss"]
      # Pinned: the block is the timeline's last child, after its list.
      let host = m.view.tagged("surface").filterIt(
        it.fact("surface") == SuggestedActionsSurface)[0]
      check nthChild(host, childCount(host) - 1).fact("suggestion-phase") == "pending"
      m.dispose()

  test "an unchecked action is dimmer than a checked one; a disabled one carries no press":
    for mode in [dmDark, dmLight]:
      let m = mount("partial", mode = mode)
      let p = ahPalette(mode)
      let rows = m.view.tagged("suggested-action")
      check rows.mapIt(it.fact("action-checked")) == @["true", "false", "true"]
      var rowInk: seq[string]
      for row in rows: rowInk.add row.tagged("ink")[0].fact("ink")
      check contrast(rowInk[1], blockGround(p)) < contrast(rowInk[0], blockGround(p))
      m.dispose()
    let u = mount("unsupported")
    let rows = u.view.tagged("suggested-action")
    let disabled = rows.filterIt(it.fact("action-disabled") == "true")
    check disabled.len == 1
    check getAttribute(disabled[0], OperationAttribute) == ""
    u.dispose()

  test "a press on a row toggles it; on Approve performs the actions":
    let m = mount("several")
    let before = m.view.tagged("line").mapIt(it.fact("line"))
    fireEvent(m.view.carrying(SuggestedToggleOperation)[1], "mousedown")
    check m.suggestion.approveLabel == "Approve 2 of 3"
    check m.view.tagged("approve-label")[0].fact("approve-label") == "Approve 2 of 3"
    fireEvent(m.view.carrying(SuggestedApproveOperation)[0], "mousedown")
    check m.view.tagged("suggestion-phase").len == 0
    let records = m.view.tagged("item-kind").filterIt(it.fact("item-kind") in
                                                      ["ui-action", "ui-action-outcome"])
    check records.mapIt(it.fact("text")) == @["Approved 2 UI actions",
      "Opened the recording of drained_field_fails in a new tab, at pass 5",
      "Showed the Variables panel"]
    check records.mapIt(it.fact("level")) == @["0", "1", "1"]
    let after = m.view.tagged("line").mapIt(it.fact("line"))
    check after[^3 .. ^1].allIt(it.startsWith("suggestion:"))
    check before.len > 0
    m.dispose()

  test "the decided stories draw their line, and no block":
    let d = mount("dismissed")
    check d.view.tagged("suggestion-phase").len == 0
    let line = d.view.tagged("item-kind").filterIt(it.fact("item-kind") == "ui-action")
    check line.mapIt(it.fact("text")) == @["Dismissed 2 suggested UI actions"]
    d.dispose()
