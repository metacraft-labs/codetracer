## CTF-P2c step 2: the terminal omnibox result commands' presses and keys
## are routed (study D48; Input-Routing-And-Keymaps.md §4 and §5.1), in the
## story host that mounts them (`tui/agent_harbor/ah_tui_stories.nim`), and
## the field holds one line with its end in view (D36, D35).
##
## * **A press is routed**: every row carries `results.open` and its index,
##   `+N more` `results.more` and its group, `← All providers`
##   `results.all`; a click on its cells (an SGR-1006 report) is resolved by
##   the story host's router in the `results` scope, run on the viewmodel,
##   and the screen is drawn again from it.
## * **A key is routed**: `Down`, `Up`, `Enter` and `Tab`, decoded by the
##   terminal's decoder, move the selection, open the row and insert a
##   completion.
## * **The field** is the sheet's width, and an input wider than it is cut
##   in its middle: its start and its end.
##
## No mocks: the results stories' own viewmodels over their scripted
## providers and Agent Harbor source, drawn by the real view onto the real
## canvas.

import std/[sequtils, strutils, unittest]

import ../agent_harbor/ah_tui_stories

proc mount(fixture: string; cols = 180): AhTuiMount =
  mountAgentHarborStoryTui("agent-harbor-results", fixture, cols, 56)

proc carrying(m: AhTuiMount; operation: string): seq[AhNode] =
  m.view.all("operation").filterIt(it.attr("operation") == operation)

proc click(m: AhTuiMount; n: AhNode): bool =
  ## A primary press on the node's first cell, as an SGR-1006 report.
  m.handleInput("\x1b[<0;" & $(n.col + 1) & ";" & $(n.row + 1) & "M")

suite "CTF-P2c: the terminal results' presses are routed":
  test "every row carries results.open and its index; +N more its group":
    let m = mount("search-final")
    let rows = m.carrying(ResultsOpenOperation)
    check rows.len == m.results.selectableRows.len
    for i, n in rows: check n.attr("target") == $i
    let more = m.carrying(ResultsMoreOperation)
    check more.len == 2
    check more.mapIt(it.attr("target")) == @["symbols", "program-text"]
    m.dispose()

  test "a click on +N more shows the group alone; the way back shows every group":
    let m = mount("search-long")
    check m.click(m.carrying(ResultsMoreOperation)[0])
    check m.lastOperation == ResultsMoreOperation
    check m.results.alone.val == "program-text"
    check m.view.values("group") == @["program-text"]
    check m.click(m.carrying(ResultsAllOperation)[0])
    check m.results.alone.val == ""
    check m.view.values("group").len == 4
    m.dispose()

  test "a click on a row opens it, and the header says what was opened":
    let m = mount("search-final")
    var opened: seq[(string, OpenTarget)]
    m.results.onOpen = proc(row: ResultRow; target: OpenTarget) = opened.add (row.id, target)
    let first = m.carrying(ResultsOpenOperation)[0]
    check m.click(first)
    check opened == @[("src/shield.nr", otEditor)]
    check m.view.values("header") == @["Opened src/shield.nr"]
    m.dispose()

suite "CTF-P2c: the terminal results' keys are routed":
  test "Down and Up move the selection, Enter opens":
    let m = mount("search-final")
    check m.handleInput("\x1b[B")
    check m.lastOperation == ResultsNextOperation
    check m.results.selected.val == 1
    check m.view.values("selected")[1] == "true"
    check m.handleInput("\x1b[A")
    check m.results.selected.val == 0
    check m.handleInput("\r")
    check m.lastOperation == ResultsOpenOperation
    check m.results.openedLine == "Opened src/shield.nr"
    m.dispose()

  test "Tab inserts the selected completion":
    let m = mount("at-completion")
    check m.handleInput("\t")
    check m.lastOperation == ResultsInsertOperation
    check m.results.input == "/ai Run drained_field_fails again with @Claude "
    check m.view.values("field") == @[m.results.input]
    m.dispose()

suite "CTF-P2c: the field has the sheet's edges and its end in view (D36)":
  test "the field is as wide as the sheet":
    for cols in [180, 45]:
      let m = mount("at-completion", cols)
      let field = m.view.first("field")
      let sheet = m.view.first("sheet")
      check field.width == sheet.width
      check field.col == sheet.col
      m.dispose()

  test "an input wider than the field keeps its start and its end":
    let m = mount("at-completion", 45)
    # The operator types on, past the field's width.
    m.results.setInput("/ai Run drained_field_fails again on the macOS runner with @")
    m.draw()
    let field = m.view.first("field")
    let drawn = m.canvas.grid.cellsText(field.row, field.col, field.width).strip
    check Ellipsis in drawn
    check drawn.startsWith("/ai")
    check drawn.endsWith("with @")
    m.dispose()
