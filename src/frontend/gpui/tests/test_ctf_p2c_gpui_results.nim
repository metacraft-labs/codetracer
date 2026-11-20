## CTF-P2c step 2: the GPUI omnibox result commands' presses and keys are
## routed (study D48; Input-Routing-And-Keymaps.md §4 and §5.1), in the
## story host that mounts them (`gpui/agent_harbor/ah_stories.nim`), and the
## field has the sheet's edges (D36).
##
## * **A press is routed**: every row carries `results.open` and its index,
##   `+N more` `results.more` and its group, `← All providers`
##   `results.all`; a press-down on it is resolved by the story host's
##   router in the `results` scope and run on the viewmodel, and the view
##   redraws from it.
## * **A key is routed**: `Down` / `Up` move the selection, `Enter` opens,
##   `Tab` inserts a completion, through `resultsKey`.
##
## No mocks: the real isonim-gpui shadow tree (the shim loaded in process, no
## window) and the results stories' own viewmodels over their scripted
## providers and Agent Harbor source.

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

proc facts(root: GpuiElement; name: string): seq[string] =
  var all: seq[GpuiElement]
  collect(root, "data-ah-" & name, all)
  all.mapIt(getAttribute(it, "data-ah-" & name))

proc mount(fixture: string; width = 1440; height = 900): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-results", fixture, width, height, dmDark)

suite "CTF-P2c: the GPUI results' presses are routed":
  test "every row carries results.open and its index; +N more its group":
    # A window tall enough for every row: the sheet draws the rows that fit
    # its body (the wrapped lines of the program's text make them tall).
    let m = mount("search-final", height = 2000)
    let rows = m.view.carrying(ResultsOpenOperation)
    check rows.len == m.results.selectableRows.len
    for i, e in rows: check getAttribute(e, ResultsTargetAttribute) == $i
    check m.view.carrying(ResultsMoreOperation).mapIt(getAttribute(it, ResultsTargetAttribute)) ==
          @["symbols", "program-text"]
    m.dispose()

  test "+N more shows the group alone; the way back shows every group":
    let m = mount("search-long")
    fireEvent(m.view.carrying(ResultsMoreOperation)[0], "mousedown")
    check m.results.alone.val == "program-text"
    check m.view.facts("group") == @["program-text"]
    fireEvent(m.view.carrying(ResultsAllOperation)[0], "mousedown")
    check m.results.alone.val == ""
    check m.view.facts("group").len == 4
    m.dispose()

  test "a press on a row opens it":
    let m = mount("search-final")
    fireEvent(m.view.carrying(ResultsOpenOperation)[0], "mousedown")
    check m.results.openedLine == "Opened src/shield.nr"
    check m.view.facts("header") == @["Opened src/shield.nr"]
    m.dispose()

suite "CTF-P2c: the GPUI results' keys are routed":
  test "Down and Up move the selection, Enter opens, Tab inserts":
    let m = mount("search-final")
    check m.resultsKey("Down") == ResultsNextOperation
    check m.results.selected.val == 1
    check m.resultsKey("Up") == ResultsPreviousOperation
    check m.results.selected.val == 0
    check m.resultsKey("Enter") == ResultsOpenOperation
    check m.results.openedLine == "Opened src/shield.nr"
    check m.resultsKey("x") == ""
    m.dispose()
    let c = mount("at-completion")
    check c.resultsKey("Tab") == ResultsInsertOperation
    check c.results.input == "/ai Run drained_field_fails again with @Claude "
    c.dispose()

suite "CTF-P2c: the field has the sheet's edges (D36)":
  test "the field is as wide as the sheet, at laptop and sidebar width":
    for width in [1440, 360]:
      let m = mount("at-completion", width)
      var fields, sheets: seq[GpuiElement]
      collect(m.view, "data-ah-field", fields)
      collect(m.view, "data-ah-sheet", sheets)
      check fields.len == 1 and sheets.len == 1
      check getAttribute(fields[0], "data-ah-field") == m.results.input
      check m.results.sheetWidthFor(width) == min(640, width - 16)
      m.dispose()
