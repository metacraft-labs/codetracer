## CTF-P2c (P2c-G): the GPUI omnibox composer's presses and keys are routed
## (study D31; Input-Routing-And-Keymaps.md §4 and §5.1), in the story host
## that mounts it (`gpui/agent_harbor/ah_stories.nim`).
##
## * **A press is routed**: every element a press acts on carries its
##   operation (`data-ct-operation`) and its target (`data-ah-target`); a
##   press-down on it is resolved by the story host's router in the
##   `composer` scope and run on the viewmodel, and the view redraws from it
##   (a chip is cited, `+` opens the menu, `Send to …` sends again, the send
##   button sends).
## * **A key is routed**: `Down` / `Up` move the destination and `Enter`
##   sends, through `composerKey`.
##
## No mocks: the real isonim-gpui shadow tree (the shim loaded in process, no
## window) and the composer stories' own viewmodels over their scripted
## router and action source.

import std/[sequtils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
from ../../viewmodel/input/element_press import OperationAttribute

let r = GpuiRenderer()

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc carrying(root: GpuiElement; operation: string): seq[GpuiElement] =
  var all: seq[GpuiElement]
  collect(root, OperationAttribute, all)
  all.filterIt(getAttribute(it, OperationAttribute) == operation)

proc mount(fixture: string): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-composer", fixture, 1440, 900, dmDark)

suite "CTF-P2c: the GPUI composer's presses are routed":
  test "every pressable element carries its operation and its target":
    let m = mount("typing")
    for op in [ComposerCiteOperation, ComposerAddContextOperation, ComposerSendOperation]:
      check m.view.carrying(op).len >= 1
    for chip in m.view.carrying(ComposerCiteOperation):
      check getAttribute(chip, ComposerTargetAttribute).len > 0
    m.dispose()

  test "a press on a chip cites it through the viewmodel, and the view redraws":
    let m = mount("typing")
    let chip = m.view.carrying(ComposerCiteOperation)[0]
    let id = getAttribute(chip, ComposerTargetAttribute)
    let cited = m.composer.chips.filterIt(it.item.id == id)[0].cited
    fireEvent(chip, "mousedown")
    check m.composer.chips.filterIt(it.item.id == id)[0].cited != cited
    var redrawn: seq[GpuiElement]
    collect(m.view, "data-ah-chip", redrawn)
    let state = redrawn.filterIt(getAttribute(it, "data-ah-chip") == id)[0]
    check getAttribute(state, "data-ah-chip-state") == (if cited: "uncited" else: "cited")
    m.dispose()

  test "+ opens the add-context menu; the send button sends":
    let m = mount("typing")
    fireEvent(m.view.carrying(ComposerAddContextOperation)[0], "mousedown")
    check m.composer.addContextOpen.val
    fireEvent(m.view.carrying(ComposerSendOperation)[0], "mousedown")
    check m.composer.phase in {cpSending, cpSent}
    m.dispose()

  test "Send to … sends again":
    let m = mount("sent")
    let before = m.composer.draft.deliveries.len
    fireEvent(m.view.carrying(ComposerSendAgainOperation)[0], "mousedown")
    check m.composer.draft.deliveries.len == before + 1
    m.dispose()

suite "CTF-P2c: the GPUI composer's keys are routed":
  test "Down and Up move the destination, Enter sends":
    let m = mount("typing")
    let before = m.composer.draft.chosen
    check m.composerKey("Down") == ComposerNextOperation
    check m.composer.draft.chosen != before
    check m.composerKey("Up") == ComposerPreviousOperation
    check m.composer.draft.chosen == before
    check m.composerKey("Enter") == ComposerSendOperation
    check m.composer.phase in {cpSending, cpSent}
    check m.composerKey("x") == ""
    m.dispose()
