## tui/agent_harbor/ah_tui_initiative_tab_bar.nim — CTF-P1b. The terminal
## view of the initiative tab bar (`InitiativeTabStripVM`): one tab per active
## initiative beside the session tabs, the active initiative's recording
## buttons, the hover popup with the initiative's progress, `+N` and its
## menu, the sessions started elsewhere and their menu, and the inbox's
## Previous / Next and auto-switch.
##
## The same parts, order and words as the web prototype
## (`isonim_agent_harbor_initiative_tabs_view.nim`, `isonim_recording_switcher_view.nim`)
## and GPUI (`gpui/agent_harbor/ah_initiative_tab_bar.nim`). Which tabs fit,
## whether the bar is compact or stacked, the recording slots and the popup's
## content are the viewmodel's; it is told the bar's width in CSS pixels
## (`cols * CellPx`). The popup opens on hover (SGR mouse motion) and
## the menus on a click; nothing is boxed: a dropdown is set off by
## its own ground.

import isonim/core/signals
import nim_agents_isonim_viewmodels/agent_harbor/initiative_tabs_vm
from ../../viewmodel/views/agent_harbor_words import stateSuffix

import ./ah_tui_canvas
import ./ah_tui_session_views
import ./ah_tui_initiative_panels

export initiative_tabs_vm, ah_tui_canvas

const
  TabMinCells = 128 div CellPx          ## `min-width: 8rem`
  InactiveTabMaxCells = 256 div CellPx  ## 16rem
  ActiveTabMaxCells = 384 div CellPx    ## 24rem: it holds its recordings
  PopupCells = 384 div CellPx           ## `.ah-initiative-popup`: 24rem, at most 80vw
  ElsewhereMenuCells = 608 div CellPx   ## 38rem
  ElsewhereInitiativeCells = 144 div CellPx
  ElsewhereStatusCells = 88 div CellPx
  ElsewhereOriginCells = 4

proc keyOf(tab: StripTab): string =
  if tab.kind == stkInitiative: initiativeKey(tab.id) else: sessionKey(tab.id)

proc buttonLabel(rb: RecordingButton): string = $rb.number & stateSuffix(rb.state)

proc recordingsCells(buttons: RecordingButtons): int =
  ## The switcher's width: " n " per button, a cell apart, and `+N`.
  if buttons.buttons.len == 0: return 0
  result = 1
  for rb in buttons.buttons: result += widthOf(buttonLabel(rb)) + 2 + 1
  if buttons.hidden > 0: result += widthOf("+" & $buttons.hidden) + 2

proc tabContent(vm: InitiativeTabStripVM; tab: StripTab): int =
  result = 1 + 2 + widthOf(tab.title) + 1
  if tab.kind == stkInitiative:
    result += 1 + widthOf(tab.progressText)
    if tab.active: result += recordingsCells(vm.recordingButtonsOf(tab.id))
  elif tab.session.originShort.len > 0:
    result += 1 + widthOf(tab.session.originShort)

proc tabCellsOf(vm: InitiativeTabStripVM; tab: StripTab): int =
  clamp(tabContent(vm, tab), TabMinCells,
        if tab.active: ActiveTabMaxCells else: InactiveTabMaxCells)

proc tabMinCellsOf(vm: InitiativeTabStripVM; tab: StripTab): int =
  ## A tab never shrinks below its title's first 9 cells (72px) and the
  ## parts it cannot lose.
  result = 1 + 2 + 9 + 1
  if tab.kind == stkInitiative:
    result += 1 + widthOf(tab.progressText)
    if tab.active: result += recordingsCells(vm.recordingButtonsOf(tab.id))
  result = max(result, TabMinCells)

proc drawRecordingButton(c: var AhCanvas; parent: AhNode; vm: InitiativeTabStripVM;
                         initiativeId: string; rb: RecordingButton; row, col: int): int =
  ## A numbered button: its ground says it is a control; the active one is
  ## the action role's, a failed or missing one's number is in its role.
  let id = rb.id
  let label = " " & buttonLabel(rb) & " "
  let w = widthOf(label)
  var fg = c.p.textLabel
  var bg = c.p.panel
  case rb.state
  of rsReady: discard
  of rsLoading: fg = c.p.textCaption
  of rsFailed: fg = c.p.textError
  of rsMissing: fg = c.p.textWarning
  if rb.active:
    bg = if c.p.mode == dmDark: c.p.action else: c.p.borderAction
    fg = c.p.onAction
  discard c.put(row, col, label, fg, bg = bg)
  discard c.node(parent, row, col, w, 1,
                 [("recording", $rb.number), ("recording-state", $rb.state),
                  ("recording-active", $rb.active), ("tooltip", rb.tooltip)])
  let target = vm
  c.target(row, col, w, 1, proc() = discard target.selectRecording(initiativeId, id))
  w

proc drawBarTab(c: var AhCanvas; parent: AhNode; vm: InitiativeTabStripVM;
                tab: StripTab; row, col, width: int) =
  let key = keyOf(tab)
  let id = tab.id
  let n = c.node(parent, row, col, width, 1,
                 [("tab", key), ("active", $tab.active), ("tooltip", tab.tooltip)])
  if tab.active: c.fill(row, col, width, 1, c.p.activeTab)
  let target = vm
  if tab.kind == stkInitiative:
    n.tag("state", $tab.state)
    discard c.mark(n, row, col + 1, c.p.markOf(tab.state))
    c.target(row, col, width, 1, proc() = discard target.activate(key),
             hover = proc() = target.popupId.val = id)
  else:
    n.tag("attention", $tab.session.attention)
    discard c.mark(n, row, col + 1, c.p.markOf(tab.session.attention))
    c.target(row, col, width, 1, proc() = discard target.activate(key))
  # From the right: the recording buttons, `n/m`, then the title takes the rest.
  var right = col + width - 1
  if tab.kind == stkInitiative:
    var buttons: RecordingButtons
    if tab.active: buttons = vm.recordingButtonsOf(id)
    let rw = recordingsCells(buttons)
    let pw = widthOf(tab.progressText)
    let progressCol = right - rw - pw
    discard c.text(n, row, progressCol, pw, tab.progressText,
                   if tab.active: c.p.activeRowQuiet else: c.p.textCaption,
                   fact = "progress")
    if buttons.buttons.len > 0:
      let switcher = c.node(n, row, right - rw + 1, rw, 1,
                            [("recordings", $buttons.buttons.len)])
      var at = right - rw + 1
      for rb in buttons.buttons:
        at += c.drawRecordingButton(switcher, vm, id, rb, row, at) + 1
      if buttons.hidden > 0:
        let more = " +" & $buttons.hidden & " "
        discard c.put(row, at, more, c.p.textLabel, bg = c.tone.chip)
        discard c.node(switcher, row, at, widthOf(more), 1,
                       [("recordings-hidden", $buttons.hidden)])
    right = progressCol - 1
  elif tab.session.originShort.len > 0:
    let ow = widthOf(tab.session.originShort)
    discard c.put(row, right - ow, tab.session.originShort, c.p.textCaption)
    right -= ow + 1
  discard c.text(n, row, col + 3, max(1, right - (col + 3)), tab.title,
                 if tab.active: c.p.activeTabText else: c.p.textCaption, fact = "label")

proc drawPopup(c: var AhCanvas; parent: AhNode; popup: InitiativePopup;
               row, col, width: int) =
  ## The hovered initiative's progress: mark, title and state word; the
  ## headline; the milestone bar and its legend; the current milestone; the
  ## executive summary; then its sessions.
  let inner = width - 2
  let summary = wrapWords(popup.executiveSummary, inner)
  let legendRows = 3   # an upper bound for the labelled legend, trimmed below
  var height = 1 + 1 + 1 + legendRows + (if popup.currentMilestone.len > 0: 1 else: 0) +
               summary.len + 1 + popup.sessions.len + 1
  c.area("popup", row, col, width, min(height, c.rows - row), c.tone.menu)
  let n = c.node(parent, row, col, width, height, [("popup", popup.id)])
  var r = row + 1
  discard c.mark(n, r, col + 1, c.p.markOf(popup.state))
  let stateColour = case popup.state
                    of isNeedsInput, isWorking, isBlocked: c.p.stateWordColour(popup.state)
                    else: c.p.textLabel
  let word = stateWord(popup.state)
  let ww = widthOf(word)
  discard c.text(n, r, col + 3, max(1, inner - 2 - ww - 1), popup.title, c.p.textBody,
                 bold = true, fact = "title")
  discard c.text(n, r, col + width - 1 - ww, ww, word, stateColour, fact = "state")
  inc r
  discard c.text(n, r, col + 1, inner, popup.headline, c.p.textCaption, fact = "headline")
  inc r
  r += c.drawMilestoneBar(n, r, col, width, popup.statusCounts, labelled = true)
  if popup.currentMilestone.len > 0:
    c.drawCurrent(n, r, col + 1, inner, popup.currentMilestone)
    inc r
  if summary.len > 0:
    discard c.node(n, r, col + 1, inner, summary.len,
                   [("executive-summary", popup.executiveSummary)])
    for line in summary:
      discard c.put(r, col + 1, line, c.p.textBody)
      inc r
  inc r   # a blank line before the sessions (the web's rule above them)
  for item in popup.sessions:
    c.drawSessionLine(n, item, r, col + 1, inner)
    inc r
  let bound = height
  height = r - row + 1
  n.height = height
  # Trim the area to what was drawn: the rows the bound over-counted go back
  # to the window.
  for a in countdown(c.areas.high, 0):
    if c.areas[a].name == "popup":
      c.areas[a].height = min(height, c.rows - row)
      break
  if bound > height: c.fill(row + height, col, width, bound - height, c.tone.frame)

proc autoLabel(vm: InitiativeTabStripVM): string =
  (if vm.compact: "Auto: " else: "Auto-switch: ") & (if vm.autoSwitch.val: "on" else: "off")

proc inboxCells(vm: InitiativeTabStripVM): int =
  result = 3 + 3 + 1 + widthOf(autoLabel(vm)) + 2
  if vm.autoSwitch.val: result += 2
  if not vm.compact: result += 1 + 9

proc elsewhereCells(vm: InitiativeTabStripVM): int =
  result = widthOf($vm.elsewhereCount) + 2 + 1
  if not vm.compact: result += 1 + widthOf(vm.elsewhereLabel)

proc drawInbox(c: var AhCanvas; parent: AhNode; vm: InitiativeTabStripVM; row, col: int) =
  ## ← position → and the auto-switch toggle.
  let target = vm
  let position = vm.inboxPosition
  let shown = if position.len == 0: "inbox empty" else: position
  let n = c.node(parent, row, col, inboxCells(vm), 1, [("inbox", shown)])
  var at = col
  discard c.put(row, at, " \xE2\x86\x90 ", c.p.textLabel)
  discard c.node(n, row, at + 1, 1, 1, [("button", "\xE2\x86\x90")])
  c.target(row, at, 3, 1, proc() = discard target.stepInbox(-1))
  at += 3
  if not vm.compact:
    let pw = widthOf(shown)
    let slot = 9
    discard c.text(n, row, at + max(0, (slot - pw) div 2), slot, shown, c.p.textLabel,
                   fact = "inbox-position")
    at += slot + 1
  discard c.put(row, at, " \xE2\x86\x92 ", c.p.textLabel)
  discard c.node(n, row, at + 1, 1, 1, [("button", "\xE2\x86\x92")])
  c.target(row, at, 3, 1, proc() = discard target.stepInbox(1))
  at += 4
  let auto = vm.autoSwitch.val
  let start = at
  if auto:
    discard c.mark(n, row, at + 1, MarkStyle(colour: c.p.action))
    at += 2
  let label = autoLabel(vm)
  discard c.put(row, at + 1, label, if auto: c.p.textBody else: c.p.textLabel)
  let t = c.node(n, row, at + 1, widthOf(label), 1, [("button", label), ("auto-switch", $auto)])
  discard t
  c.target(row, start, at + 2 + widthOf(label) - start, 1,
           proc() = target.autoSwitch.val = not target.autoSwitch.val)

proc drawElsewhere(c: var AhCanvas; parent: AhNode; vm: InitiativeTabStripVM;
                   row, col: int) =
  ## `[N agent harbor sessions]`: the count on its badge and the label.
  let target = vm
  let w = elsewhereCells(vm)
  if vm.elsewhereOpen.val: c.fill(row, col, w, 1, c.tone.chip)
  let n = c.node(parent, row, col, w, 1, [("elsewhere", $vm.elsewhereCount),
                                          ("tooltip", vm.elsewhereTooltip)])
  let badge = " " & $vm.elsewhereCount & " "
  discard c.put(row, col, badge, c.p.textBody, bold = true,
                bg = if vm.elsewhereOpen.val: c.p.activeTab else: c.tone.chip)
  if not vm.compact:
    discard c.text(n, row, col + widthOf(badge) + 1, widthOf(vm.elsewhereLabel),
                   vm.elsewhereLabel, c.p.textLabel, fact = "elsewhere-label")
  c.target(row, col, w, 1, proc() = target.elsewhereOpen.val = not target.elsewhereOpen.val)

proc drawElsewhereItem(c: var AhCanvas; menu: AhNode; entry: ElsewhereSession;
                       stacked: bool; row, col, width: int; onClick: proc()): int =
  ## A session started elsewhere: mark, title, its initiative, state and
  ## origin — in columns, or on two lines in a stacked bar's menu.
  let noInitiative = entry.initiativeTitle.len == 0
  let initiative = if noInitiative: "no initiative" else: entry.initiativeTitle
  let initiativeFg = if noInitiative: c.p.textCaption else: c.p.textLabel
  let height = if stacked: 2 else: 1
  let n = c.node(menu, row, col, width, height, [("menu-item", entry.item.id)])
  c.target(row, col, width, height, onClick)
  discard c.mark(n, row, col + 1, c.p.markOf(entry.item.attention))
  let ow = ElsewhereOriginCells
  if not stacked:
    let titleW = max(4, width - 3 - ElsewhereInitiativeCells - ElsewhereStatusCells - ow - 4)
    discard c.text(n, row, col + 3, titleW, entry.item.title, c.p.textBody)
    var at = col + 3 + titleW + 1
    discard c.text(n, row, at, ElsewhereInitiativeCells, initiative, initiativeFg)
    at += ElsewhereInitiativeCells + 1
    discard c.text(n, row, at, ElsewhereStatusCells, entry.item.statusLabel, c.p.textCaption)
    at += ElsewhereStatusCells + 1
    discard c.text(n, row, at, ow, entry.item.originShort, c.p.textCaption, alignRight = true)
  else:
    let third = max(widthOf(entry.item.originShort), widthOf(entry.item.statusLabel))
    discard c.text(n, row, col + 3, max(1, width - 4 - third - 1), entry.item.title,
                   c.p.textBody)
    discard c.text(n, row, col + width - 1 - third, third, entry.item.originShort,
                   c.p.textCaption, alignRight = true)
    discard c.text(n, row + 1, col + 3, max(1, width - 4 - third - 1), initiative,
                   initiativeFg)
    discard c.text(n, row + 1, col + width - 1 - third, third, entry.item.statusLabel,
                   c.p.textCaption, alignRight = true)
  height

proc drawInitiativeTabBar*(c: var AhCanvas; vm: InitiativeTabStripVM; row, col, width: int) =
  let ready = vm.state.val == asReady
  let tabs = vm.tabs
  let host = c.node(nil, row, col, width, if vm.stacked: 2 else: 1,
                    [("surface", "agent-harbor-initiative-tabs"),
                     ("state", if ready and tabs.len == 0: "empty" else: stateName(vm.state.val)),
                     ("compact", $vm.compact), ("stacked", $vm.stacked)])
  c.fill(row, col, width, if vm.stacked: 2 else: 1, c.tone.frame)
  let controlsRow = if vm.stacked: row + 1 else: row
  var controlsW = 0
  if vm.state.val in {asReady, asError}: controlsW += inboxCells(vm)
  if ready and vm.elsewhereCount > 0: controlsW += elsewhereCells(vm) + 1
  let controlsCol = col + width - 1 - controlsW
  let tabsRoom = if vm.stacked: width - 1 else: controlsCol - col - 1
  var at = col
  var popupCol = -1
  var overflow: seq[int]
  var chipCol = -1
  case vm.state.val
  of asIdle, asLoading:
    let n = c.node(host, row, col, tabsRoom - AddCells - 1, 1, [("notice", "loading")])
    discard c.text(n, row, col + 1, tabsRoom - AddCells - 2,
                   "Loading initiatives" & Ellipsis, c.p.textCaption)
    at = col + 1 + min(tabsRoom - AddCells - 2, widthOf("Loading initiatives" & Ellipsis)) + 1
  of asError:
    let message = "Initiatives unavailable: " & vm.error.val
    let n = c.node(host, row, col, tabsRoom - AddCells - 1, 1, [("notice", "error")])
    let room = tabsRoom - AddCells - 2 - 8
    let w = c.text(n, row, col + 1, room, message, c.p.textError, fact = "error")
    let rc = col + 1 + w + 1
    discard c.put(row, rc, " Retry ", c.p.textLabel, bg = c.tone.chip)
    discard c.node(n, row, rc + 1, 5, 1, [("button", "Retry")])
    let target = vm
    c.target(row, rc, 7, 1, proc() = target.load())
    at = rc + 8
  of asReady:
    if tabs.len == 0:
      let n = c.node(host, row, col, tabsRoom - AddCells - 1, 1, [("notice", "empty")])
      discard c.text(n, row, col + 1, tabsRoom - AddCells - 2, "No initiative is running.",
                     c.p.textCaption)
      at = col + 1 + widthOf("No initiative is running.") + 1
    let layout = vm.singleLine
    overflow = layout.overflow
    var widths, mins: seq[int]
    for i in layout.visible:
      widths.add tabCellsOf(vm, tabs[i])
      mins.add tabMinCellsOf(vm, tabs[i])
    var reserved = AddCells + 1
    if overflow.len > 0: reserved += chipWidth(overflow.len, true) + 1
    let fitted = fitCells(widths, tabsRoom - reserved, TabMinCells, 1, mins = mins)
    for k, i in layout.visible:
      if tabs[i].kind == stkInitiative and vm.popupId.val == tabs[i].id: popupCol = at
      c.drawBarTab(host, vm, tabs[i], row, at, fitted[k])
      at += fitted[k] + 1
    if overflow.len > 0:
      var waits = 0
      for i in overflow:
        if tabs[i].kind == stkInitiative and tabs[i].state == isNeedsInput or
            tabs[i].kind == stkSession and tabs[i].session.attention == saNeedsInput:
          inc waits
      let target = vm
      chipCol = at
      at += c.drawOverflowChip(host, row, at, overflow.len, waits, vm.overflowOpen.val,
                               proc() = target.overflowOpen.val = not target.overflowOpen.val) + 1
  c.drawPlus(host, row, at)
  # The controls: sessions started elsewhere, then the inbox.
  let controls = c.node(host, controlsRow, controlsCol, controlsW, 1,
                        [("controls", "bar controls")])
  var cc = controlsCol
  if ready and vm.elsewhereCount > 0:
    c.drawElsewhere(controls, vm, controlsRow, cc)
    cc += elsewhereCells(vm) + 1
  if vm.state.val in {asReady, asError}: c.drawInbox(controls, vm, controlsRow, cc)
  let below = controlsRow + 1
  if ready and popupCol >= 0:
    let popupW = min(PopupCells, width * 4 div 5)
    let left = min(popupCol, max(col, col + width - popupW))
    c.drawPopup(host, vm.popupOf(vm.popupId.val), row + 1, left, popupW)
    let target = vm
    c.leave.add proc() = target.popupId.val = ""
  if ready and overflow.len > 0 and vm.overflowOpen.val:
    var widest = MenuMinCells
    for i in overflow:
      widest = max(widest, 4 + widthOf(tabs[i].title) + 1 + widthOf(tabs[i].progressText) + 1)
    let menuW = min(widest, width - 1)
    let menuCol = max(col, min(chipCol, col + width - 1 - menuW))
    let menu = c.drawMenu(host, row + 1, menuCol, menuW, overflow.len, "overflow")
    for k, i in overflow:
      let tab = tabs[i]
      let key = keyOf(tab)
      let m = if tab.kind == stkInitiative: c.p.markOf(tab.state)
              else: c.p.markOf(tab.session.attention)
      let target = vm
      discard c.drawMenuItem(menu, row + 1 + k, menuCol, menuW, m, tab.title, key, tab.active,
        (if tab.progressText.len > 0: @[(tab.progressText, c.p.textCaption)] else: @[]),
        proc() = discard target.activate(key))
  if ready and vm.elsewhereCount > 0 and vm.elsewhereOpen.val:
    let entries = vm.elsewhere
    let menuW = if vm.stacked: width - 2 else: min(ElsewhereMenuCells, width - 2)
    let menuCol = if vm.stacked: col else: max(col, controlsCol + elsewhereCells(vm) - menuW)
    let per = if vm.stacked: 2 else: 1
    let menu = c.drawMenu(host, below, menuCol, menuW, entries.len * per, "elsewhere")
    var r = below
    for entry in entries:
      let id = entry.item.id
      let target = vm
      r += c.drawElsewhereItem(menu, entry, vm.stacked, r, menuCol, menuW,
                               proc() = discard target.openSession(id))

proc mountInitiativeTabBar*(vm: InitiativeTabStripVM; cols: int) =
  ## Tell the viewmodel the bar's width, in the unit its layout counts.
  if cols > 0 and vm.stripWidth.val != cols * CellPx: vm.stripWidth.val = cols * CellPx
