## tui/agent_harbor/ah_tui_process_switcher.nim — CTF-P2c step 5. The
## terminal's multi-process recording session tab with its process
## switcher, over `ProcessSwitcherVM` (`viewmodel/process_switcher_vm.nim`),
## drawn as the web's `isonim_agent_harbor_process_switcher_view` draws it,
## from the same words (`agent_harbor_process_switcher_words`; codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## §2.6, D25, D76-D83).
##
## The story draws the caption bar on the window's first row (the bar's
## ground): the recording's tab, active (the active tab's ground), its name
## and, at its end, the recording switcher's numbered buttons for the
## processes; then a plain tab; an empty working area below; and the status
## line on the window's last row.
##
## THE HINT. A terminal draws no tooltip, so while the switcher has the
## focus the status line shows the focused button's tooltip
## (`ProcessSwitcherVM.focusHint`: the process, its pid and binary, its
## state), at the line's start, cut with `…` where the line cannot hold it;
## without the focus the line is empty. The line is the gaze story's
## (`statusLineInks`).
##
## THE BUTTONS ARE THE INITIATIVE BAR'S OWN DRAWING. The tab takes a
## `SwitcherSlot`; `RecordingSwitcherSlot`, the default, measures and draws
## the buttons with the recording switcher's terminal drawing where it lives,
## in the initiative bar (`ah_tui_initiative_tab_bar`: `recordingsCells`,
## `drawRecordingButton` with the press reported here, `drawRecordingsMore`;
## P1d site 19), which also draws the ring (D81). Moving that drawing to a
## module of its own comes after CTF-P1d step 5b (manager note 143).
##
## Facts: `tabFacts` and `tooltip` on the tab, `surface` on the story's root,
## `status-line` on the line and `hint` (the whole tooltip) on the hint.

import ../../viewmodel/views/agent_harbor_process_switcher_words
import ./ah_tui_canvas
import ./ah_tui_initiative_tab_bar

export agent_harbor_process_switcher_words

type
  ProcessPress* = proc(operation, target: string)
    ## A host's route for a press: the operation and its target (the
    ## process's recording id).

  SwitcherSlot* = object
    ## How a tab measures and draws the recording switcher's buttons.
    cells*: proc(buttons: RecordingButtons): int
      ## The cells the buttons take, a cell before them included.
    draw*: proc(c: var AhCanvas; parent: AhNode; buttons: RecordingButtons;
                row, col: int; press: ProcessPress)
      ## Draws them from `col`; each button's press reports
      ## `process-switcher.select` with its process.

const
  OtherTabTitleCells = 10   ## a plain tab's width (`sudoku`, its padding)

proc switcherDraw(c: var AhCanvas; parent: AhNode; buttons: RecordingButtons;
                  row, col: int; press: ProcessPress) =
  ## The buttons `RecordingGap` apart and `+N`, as the initiative tab draws
  ## them, a cell after `col`; a press reports `process-switcher.select`.
  let w = recordingsCells(buttons)
  let switcher = c.node(parent, row, col, w, 1, [("process-recordings", $buttons.buttons.len)])
  let route = press
  let select = proc(id: string) =
    if route != nil: route(ProcessSelectOperation, id)
  var at = col + 1
  for i, rb in buttons.buttons:
    if i > 0: at += RecordingGap
    at += c.drawRecordingButton(switcher, nil, "", rb, row, at, select)
  if buttons.hidden > 0:
    at += RecordingGap
    at += c.drawRecordingsMore(switcher, buttons, row, at, "process", "processes")

let RecordingSwitcherSlot* = SwitcherSlot(cells: recordingsCells, draw: switcherDraw)
  ## The recording switcher's own drawing (`ah_tui_initiative_tab_bar`).

proc slotsForCells*(cols: int): int =
  ## The buttons a tab draws before `+N` on a terminal `cols` wide: the
  ## narrow window's two below 90 cells (720px at 8px a cell), else five.
  if cols < 90: 2 else: 5

proc drawSwitcherStatusLine*(c: var AhCanvas; parent: AhNode; vm: ProcessSwitcherVM;
                             row, col, width: int) =
  ## The status line at `row`: its own ground across the window, and, while
  ## the switcher has the focus, the focused button's tooltip from its
  ## second cell, cut with `…` a cell before the window's edge.
  let (ground, ink) = statusLineInks(c)
  c.area("status-line", row, col, width, 1, ground)
  let line = c.node(parent, row, col, width, 1, [("status-line", "true")])
  let hint = vm.focusHint
  if hint.len > 0:
    discard c.text(line, row, col + 1, max(1, width - 2), hint, ink, fact = "hint")

proc drawProcessSwitcherStory*(c: var AhCanvas; vm: ProcessSwitcherVM;
                               row, col, width, height: int; otherTab: string;
                               nextChord, previousChord: string;
                               slot = RecordingSwitcherSlot; press: ProcessPress = nil) =
  ## The story's window: the caption bar's tabs on the first row, an empty
  ## working area below.
  let host = c.node(nil, row, col, width, height, [("surface", ProcessSwitcherSurface)])
  # The caption bar's row on its ground, the tabs on it; the rest is the
  # story window's own ground. Like the initiative bar, it declares no area
  # of its own: its row and the window below meet on one ground in Dark (the
  # web's #menu and body), and the recording buttons sit on the panel's
  # ground inside the tab, so no ground can be given to an area beside them
  # that none of them shares (`test_ctf_p1b_tui_no_box_borders_between_areas`;
  # P2c study D76).
  c.fill(row, col, width, 1, c.tone.frame)
  let slots = slotsForCells(width)
  let buttons = vm.buttons(slots)
  let switcherCells = slot.cells(buttons)
  # The recording's tab: a cell, its name, the switcher, a cell; the name is
  # cut before the switcher gives up a cell, and the plain tab keeps its
  # width when it can.
  let room = max(0, width - 1 - OtherTabTitleCells - 1)
  let nameCells = min(widthOf(vm.title), max(1, room - 2 - switcherCells))
  let tabW = 1 + nameCells + switcherCells + 1
  let tabCol = col + 1
  c.fill(row, tabCol, tabW, 1, c.p.activeTab)
  var facts = @[("tab", vm.title), ("active", "true"),
                ("tooltip", vm.tabTooltipOf(nextChord, previousChord))]
  facts.add vm.tabFacts(slots)
  let tab = c.node(host, row, tabCol, tabW, 1, facts)
  discard c.text(tab, row, tabCol + 1, nameCells, vm.title, c.p.activeTabText, fact = "label")
  if buttons.buttons.len > 0:
    slot.draw(c, tab, buttons, row, tabCol + 1 + nameCells, press)
  # The plain tab, on the bar's ground, its name in the caption role.
  let otherCol = tabCol + tabW + 1
  if otherCol + 2 < col + width:
    let w = min(OtherTabTitleCells, col + width - otherCol)
    let other = c.node(host, row, otherCol, w, 1, [("tab", otherTab), ("active", "false")])
    discard c.text(other, row, otherCol + 1, max(1, w - 2), otherTab, c.p.textCaption,
                   fact = "label")
  if height >= 3:
    c.drawSwitcherStatusLine(host, vm, row + height - 1, col, width)
