## CTF-P2c step 3: the terminal's suggested-actions block at the end of a
## session's timeline (study §2.3, D23, D54-D59), in the story host that
## mounts it (`tui/agent_harbor/ah_tui_stories.nim`).
##
## * **The block follows the timeline's last line** (at the panel's foot
##   once the lines fill the rest) on a ground of its own, a step off the
##   panel, and holds every action and both buttons at every size.
## * **An unchecked action is dimmer** than a checked one (D52's rule for
##   the terminal), and one CodeTracer cannot perform carries no press.
## * **Presses are routed**: a click on a row toggles it, on Approve
##   performs the checked actions, and the screen is drawn again: the
##   block gone, the record lines after the timeline's lines.
## * **The record lines** are the timeline's own lines, at levels 0 and 1,
##   and the timeline's lines before them are the same with the block as
##   without.
##
## No mocks: the stories' own viewmodels over the scripted performer and
## action source, drawn by the real view onto the real canvas.

import std/[sequtils, strutils, unittest]

import ../agent_harbor/ah_tui_stories
import ../../viewmodel/views/agent_harbor_suggested_actions_words

proc mount(fixture: string; cols = 95; rows = 40; mode = dmDark): AhTuiMount =
  mountAgentHarborStoryTui("agent-harbor-suggested-actions", fixture, cols, rows, mode,
                           frameTitle = "Agent Activity")

proc click(m: AhTuiMount; n: AhNode): bool =
  m.handleInput("\x1b[<0;" & $(n.col + 1) & ";" & $(n.row + 1) & "M")

proc rowsOf(m: AhTuiMount): seq[AhNode] = m.view.all("suggested-action")

suite "CTF-P2c: the terminal suggested-actions block":
  test "under the timeline's last line, on a ground a step off the panel, whole at every size":
    for (cols, rows) in [(95, 40), (45, 56), (180, 56)]:
      for mode in [dmDark, dmLight]:
        let m = mount("unsupported", cols, rows, mode)
        let blk = m.view.first("suggestion-phase")
        check blk.attr("suggestion-phase") == "pending"
        let list = m.view.first("lines")
        check list.row + list.height == blk.row
        check blk.row + blk.height <= rows
        let ground = m.canvas.bgAt(blk.row, blk.col)
        let panel = m.canvas.bgAt(list.row, list.col + list.width - 1)
        check ground != panel
        check contrastOf(ground, panel) >= 1.05
        check m.rowsOf.len == 3
        check m.view.all("suggested-button").mapIt(it.attr("suggested-button")) == @["approve", "dismiss"]
        m.dispose()

  test "the buttons sit inside the block, its own ground under them":
    # Dismiss is drawn on the panel's ground, the timeline's (a quiet
    # button, a step off the block's). On the block's last row it touched
    # the timeline's ground under a block that follows the last line: two
    # areas on one ground, which CodeTracer-TUI §3.4 forbids (codetracer-pm
    # issues/2026-11-21-suggested-actions-tui-stories-fail-the-no-box-borders-test.md).
    # The block keeps an inset row of its own ground under its buttons, as
    # the web's block pads its buttons off its edge.
    for fixture in ["one", "several", "partial", "unsupported"]:
      for (cols, rows) in [(95, 40), (45, 56), (180, 56)]:
        for mode in [dmDark, dmLight]:
          let m = mount(fixture, cols, rows, mode)
          let blk = m.view.first("suggestion-phase")
          let ground = m.canvas.bgAt(blk.row, blk.col)
          for b in m.view.all("suggested-button"):
            check b.row + 1 < blk.row + blk.height
            for x in b.col ..< b.col + b.width:
              check m.canvas.bgAt(b.row + 1, x) == ground
          m.dispose()

  test "an unchecked action is dimmer than a checked one; a disabled one carries no press":
    for mode in [dmDark, dmLight]:
      let m = mount("partial", mode = mode)
      let rows = m.rowsOf
      check rows.mapIt(it.attr("action-checked")) == @["true", "false", "true"]
      let ground = m.canvas.bgAt(rows[0].row, rows[0].col)
      let checkedInk = m.canvas.grid.styleAt(rows[0].row, rows[0].col + 5).fg
      let dimInk = m.canvas.grid.styleAt(rows[1].row, rows[1].col + 5).fg
      check contrastOf(dimInk, ground) < contrastOf(checkedInk, ground)
      m.dispose()
    let u = mount("unsupported")
    let disabled = u.rowsOf.filterIt(it.attr("action-disabled") == "true")
    check disabled.len == 1
    check not disabled[0].has("operation")
    check disabled[0].attr("action-reason") ==
      "No recording of drained_field_fails on macos-arm64 has been uploaded"
    u.dispose()

  test "a click on a row toggles it, and the label follows":
    let m = mount("several")
    let second = m.rowsOf[1]
    check second.attr("operation") == SuggestedToggleOperation
    check m.click(second)
    check m.lastOperation == SuggestedToggleOperation
    check m.view.first("approve-label").attr("approve-label") == "Approve 2 of 3"
    check m.click(m.rowsOf[1])
    check m.view.first("approve-label").attr("approve-label") == "Approve"
    m.dispose()

  test "a click on Approve performs the actions; the record lines follow the timeline's":
    let m = mount("several")
    let before = m.view.all("line").mapIt(it.attr("line"))
    let approve = m.view.all("suggested-button").filterIt(it.attr("suggested-button") == "approve")[0]
    check m.click(approve)
    check m.lastOperation == SuggestedApproveOperation
    check m.view.first("suggestion-phase").isNil
    let ids = m.view.all("line").mapIt(it.attr("line"))
    let records = m.view.all("item-kind").filterIt(it.attr("item-kind") in
                                                    ["ui-action", "ui-action-outcome"])
    check records.mapIt(it.attr("text")) == @["Approved 3 UI actions",
      "Opened the recording of drained_field_fails in a new tab, at pass 5",
      "Showed the call trace beside the editor", "Showed the Variables panel"]
    check records.mapIt(it.attr("level")) == @["0", "1", "1", "1"]
    # The timeline's own lines are the same, then the record's.
    check ids[0 ..< ids.len - 4] == before[before.len - (ids.len - 4) .. ^1]
    m.dispose()

  test "the decided stories draw their line, and no block":
    let d = mount("dismissed")
    check d.view.first("suggestion-phase").isNil
    let line = d.view.all("item-kind").filterIt(it.attr("item-kind") == "ui-action")
    check line.mapIt(it.attr("text")) == @["Dismissed 2 suggested UI actions"]
    check line[0].attr("role") == "quiet"
    d.dispose()
    let a = mount("auto-approved")
    let auto = a.view.all("item-kind").filterIt(it.attr("item-kind") == "ui-action")
    check auto.len == 1
    check auto[0].attr("text") == "Ran 1 UI action auto-approved"
    check "auto-approved" in a.canvas.grid.cellsText(auto[0].row, auto[0].col, auto[0].width)
    let outcome = a.view.all("item-kind").filterIt(it.attr("item-kind") == "ui-action-outcome")
    check outcome.mapIt(it.attr("text")) == @["Showed the Variables panel"]
    a.dispose()
