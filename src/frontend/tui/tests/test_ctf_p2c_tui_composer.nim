## CTF-P2c (P2c-G): the terminal omnibox composer's presses and keys are
## routed (study D31; Input-Routing-And-Keymaps.md §4 and §5.1), in the
## story host that mounts it (`tui/agent_harbor/ah_tui_stories.nim`).
##
## * **A press is routed**: every element a press acts on carries its
##   operation and its target (the terminal's `data-ct-operation` and
##   `data-ah-target`); a click on its cells (an SGR-1006 report, as the
##   terminal delivers it) is resolved by the story host's router in the
##   `composer` scope, run on the viewmodel, and the screen is drawn again
##   from it.
## * **A key is routed**: the bytes for `Down`, `Up` and `Enter`, decoded by
##   the terminal's decoder, move the destination and send.
## * **A form's input holds one line** (study D35, provisional under
##   ACI-AREQ4): a value wider than its field is cut in its middle with
##   "…", keeping its start and as much of its end as fits, so the plan
##   file's name is whole wherever it fits and the value never wraps.
##
## No mocks: the composer stories' own viewmodels over their scripted router
## and action source, drawn by the real view onto the real canvas.

import std/[sequtils, strutils, unittest]

import ../agent_harbor/ah_tui_stories
from ../../viewmodel/views/agent_harbor_words import danglesAroundEllipsis

proc mount(fixture: string): AhTuiMount =
  mountAgentHarborStoryTui("agent-harbor-composer", fixture, 180, 56)

proc carrying(m: AhTuiMount; operation: string): seq[AhNode] =
  m.view.all("operation").filterIt(it.attr("operation") == operation)

proc click(m: AhTuiMount; n: AhNode): bool =
  ## A primary press on the node's first cell, as an SGR-1006 report.
  m.handleInput("\x1b[<0;" & $(n.col + 1) & ";" & $(n.row + 1) & "M")

suite "CTF-P2c: the terminal composer's presses are routed":
  test "every pressable element carries its operation and its target":
    let m = mount("typing")
    for op in [ComposerCiteOperation, ComposerAddContextOperation, ComposerSendOperation]:
      check m.carrying(op).len >= 1
    for chip in m.carrying(ComposerCiteOperation):
      check chip.attr("target").len > 0
    m.dispose()

  test "a click on a chip cites it through the viewmodel, and the screen is redrawn":
    let m = mount("typing")
    let chip = m.carrying(ComposerCiteOperation)[0]
    let id = chip.attr("target")
    let cited = m.composer.chips.filterIt(it.item.id == id)[0].cited
    check m.click(chip)
    check m.lastOperation == ComposerCiteOperation
    check m.composer.chips.filterIt(it.item.id == id)[0].cited != cited
    let redrawn = m.view.all("chip").filterIt(it.attr("chip") == id)[0]
    check redrawn.attr("chip-state") == (if cited: "uncited" else: "cited")
    m.dispose()

  test "+ opens the add-context menu; the send button sends":
    let m = mount("typing")
    check m.click(m.carrying(ComposerAddContextOperation)[0])
    check m.composer.addContextOpen.val
    check m.view.all("context-menu").len == 1
    check m.click(m.carrying(ComposerSendOperation)[0])
    check m.composer.phase in {cpSending, cpSent}
    m.dispose()

  test "Send to … sends again; a recent instruction is recalled":
    let m = mount("sent")
    let before = m.composer.draft.deliveries.len
    check m.click(m.carrying(ComposerSendAgainOperation)[0])
    check m.composer.draft.deliveries.len == before + 1
    m.dispose()
    let r = mount("recent")
    check r.carrying(ComposerRecallOperation).len == r.composer.recent.len
    check r.click(r.carrying(ComposerRecallOperation)[0])
    check not r.composer.isEmptyField
    r.dispose()

suite "CTF-P2c: the terminal composer's keys are routed":
  test "Down and Up move the destination, Enter sends":
    let m = mount("typing")
    let before = m.composer.draft.chosen
    check m.handleInput("\x1b[B")
    check m.lastOperation == ComposerNextOperation
    check m.composer.draft.chosen != before
    check m.handleInput("\x1b[A")
    check m.composer.draft.chosen == before
    check m.handleInput("\r")
    check m.lastOperation == ComposerSendOperation
    check m.composer.phase in {cpSending, cpSent}
    m.dispose()

const PlanFile = "milestones/2026-11-17-asteroid-fields-generated-from-seeds-end.milestones.org"
  ## The plan file the `new-initiative` story's form shows (the brief's).
const PlanFileName = "2026-11-17-asteroid-fields-generated-from-seeds-end.milestones.org"

suite "CTF-P2c: a form's input value is cut in its middle (D35)":
  test "a value that fits is whole; a wider one keeps its start and its end":
    check elideMiddle(PlanFile, widthOf(PlanFile)) == PlanFile
    check elideMiddle(PlanFile, 200) == PlanFile
    for cells in 3 .. widthOf(PlanFile) - 1:
      let shown = elideMiddle(PlanFile, cells)
      check widthOf(shown) <= cells
      check shown.count(Ellipsis) == 1
      let at = shown.find(Ellipsis)
      let head = shown[0 ..< at]
      let tail = shown[at + Ellipsis.len .. ^1]
      check head.len >= 1 and PlanFile.startsWith(head)
      check widthOf(head) <= MiddleCutStartCells
      check PlanFile.endsWith(tail)
      # As much of the end as fits: the start takes only its share.
      check widthOf(tail) == cells - 1 - widthOf(head)
      check not danglesAroundEllipsis(shown)
      # The file name, with its "/", is whole wherever it fits beside one
      # cell of the start; the start gives way to it.
      if widthOf(PlanFileName) + 1 + 1 + 1 <= cells:
        check shown.endsWith("/" & PlanFileName)

  test "neither side of the cut keeps a space, and a wide glyph is never split":
    check elideMiddle("Asteroid fields generated from seeds, end to end", 20) ==
          "Aste…eds, end to end"
    check elideMiddle(PlanFile, 76) ==
          "mileston…/2026-11-17-asteroid-fields-generated-from-seeds-end.milestones.org"
    check elideMiddle(PlanFile, 70) ==
          "mi…/2026-11-17-asteroid-fields-generated-from-seeds-end.milestones.org"
    check elideMiddle("src/upload/retry/client.py", 14) == "src…/client.py"
    for cells in 3 .. 30:
      let shown = elideMiddle("Asteroid fields generated from seeds, end to end", cells)
      check not danglesAroundEllipsis(shown)
      check widthOf(shown) <= cells
    let wide = "\u6563\u5217\u306E\u8A08\u753B/\u5C0F\u60D1\u661F.org"
    for cells in 3 .. widthOf(wide) - 1:
      check widthOf(elideMiddle(wide, cells)) <= cells

  test "the plan file is one line, its name whole at laptop width":
    for (cols, rows) in [(180, 56), (45, 56)]:
      let m = mountAgentHarborStoryTui("agent-harbor-composer", "new-initiative", cols, rows)
      let values = m.view.all("value").filterIt(it.attr("value") == PlanFile)
      check values.len == 1
      let n = values[0]
      check n.height == 1
      let drawn = m.canvas.grid.cellsText(n.row, n.col, n.width).strip
      check drawn == elideMiddle(PlanFile, n.width)
      # The row under the value is not a second line of it.
      let under = m.canvas.grid.cellsText(n.row + 1, n.col, n.width).strip
      check under.len == 0 or not PlanFile.contains(under)
      if cols == 180:
        check drawn.endsWith(PlanFileName)
        check drawn.startsWith("mileston")
      m.dispose()
