## tui/agent_harbor/ah_tui_control_center.nim — CTF-P2c step 4. The
## terminal's control center: the tab titled `Control Center` that fills the
## window, over `ControlCenterVM` (nim-agents-isonim-viewmodels), drawn as
## the web's `isonim_agent_harbor_control_center_view` draws it, from the same
## words (`agent_harbor_control_center_words`).
##
## Two columns, a column of the window's ground between them (TUI §3.4: the
## terminal tells areas apart by their grounds), the launch column 45% of the
## width, between 40 and 80 cells; one column below `NarrowBelowCells`,
## launching first (what is below the screen is left out). A terminal cannot
## scroll, so in one column the launch form is one summary line -- where and
## how the launch goes, or its first problem (`formSummary`, study D75) --
## and the overview has room under it.
##
## - **Launch**, on the composer's band (`inksFor(c).band`, the ground its
##   form's inks are chosen against), under a panel's head band (`LAUNCH`):
##   the mode chips; `For` and its chips; the instruction's field; the
##   composer's own form (`ah_tui_composer.drawLaunchForm`) and send line
##   (`drawSendLine`); Agent Harbor's answer to the last launch; `RECENT
##   LAUNCHES`.
## - **Overview** (study D73): `WAITING FOR YOU` under a panel's head band,
##   one row per waiting session -- its title; its state word in its role,
##   its initiative and age; why it waits (at most two lines); no dot and no
##   pie -- as tall as its rows and at most 45% of the height in two
##   columns; then the Initiatives panel, the same drawing as everywhere
##   (`ah_tui_initiative_panels.drawInitiativesPanel`, unchanged; with an
##   empty fleet `No initiatives yet.` in its place), filling the rest.
##
## Presses are routed: each element a press acts on carries its operation
## and target (`operation`, `target` facts) and a press over its cells
## reports both to the host's `ControlCenterPress`.
##
## Facts: `centerFacts` on the root, `cc-launch` and `cc-overview` on the
## columns, `waitingFacts` on each waiting row, `recentFacts` on each recent
## launch, `cc-notice-line`, `toggle` / `chosen` on each chip.

import std/strutils
import ../../viewmodel/views/agent_harbor_control_center_words
import ./ah_tui_canvas
import ./ah_tui_composer
import ./ah_tui_initiative_panels

export agent_harbor_control_center_words

const
  LaunchMinCells* = 40

proc renameFact(n: AhNode; name, to: string) =
  ## Every `name` fact in `n`'s tree renamed `to`.
  for i in 0 ..< n.facts.len:
    if n.facts[i][0] == name: n.facts[i][0] = to
  for ch in n.children: renameFact(ch, name, to)

proc pressOf(press: ControlCenterPress; operation, target: string): proc() =
  result = proc() =
    if press != nil: press(operation, target)

proc pressable(c: var AhCanvas; n: AhNode; press: ControlCenterPress;
               operation, target: string) =
  n.tag("operation", operation)
  n.tag("target", target)
  c.target(n.row, n.col, max(1, n.width), max(1, n.height), pressOf(press, operation, target))

proc launchCellsOf*(width: int): int =
  ## The launch column's width in two columns: 45% of the tab, never under
  ## 40 cells and never over 80 (the web's 20rem and 40rem at 8px a cell).
  max(LaunchMinCells, min(80, width * 45 div 100))

proc chipRow(c: var AhCanvas; parent: AhNode; ink: Inks; row, col, width: int;
             chips: seq[(string, string, string, bool)];
             press: ControlCenterPress; locked = false): int =
  ## Chips (label, operation, target, chosen) flowed into `width` cells from
  ## (`row`, `col`), a cell apart, each on its own ground; the chosen ones
  ## on the chosen ground, bold and underlined in the action colour (the
  ## composer's choices). `locked` (a launch waiting for its answer): no
  ## chip takes a press. Returns the rows taken.
  var r = row
  var at = col
  for (label, operation, target, on) in chips:
    let shown = " " & elide(label, max(1, width - 2)) & " "
    let w = widthOf(shown)
    if at > col and at + w > col + width:
      inc r
      at = col
    # Locked, an option not chosen loses its chip's ground: it is no longer
    # one to press, and the disabled role holds 3:1 on the column's ground
    # (it fell to 2.7:1 on Light's chip ground; review of the step-4
    # follow-up). "" keeps the ground already there.
    let (fg, bg) = if on: (ink.citedText, ink.cited)
                   elif locked: (c.p.textDisabled, "")
                   else: (c.p.textLabel, ink.quiet)
    discard c.put(r, at, shown, fg, bold = on, bg = bg)
    if on:
      # Underlined in the action border's colour, as the form's chosen
      # options are (`ah_tui_composer.putMarked`).
      c.putMarked(r, at + 1, shown[1 .. ^2], fg, bg, c.p.borderAction, bold = true)
    let n = c.node(parent, r, at, w, 1, [("toggle", label), ("chosen", $on),
                                         ("disabled", $locked)])
    c.pressable(n, if locked: nil else: press, operation, target)
    at += w + 1
  r - row + 1

proc drawLaunch(c: var AhCanvas; parent: AhNode; vm: ControlCenterVM;
                row, col, width, height: int; press: ControlCenterPress;
                folded = false): int =
  ## The launch column; returns the rows its content takes. `folded` (one
  ## column, study D75): the form is one summary line, so the overview has
  ## room under it on a screen that cannot scroll.
  let ink = inksFor(c)
  c.area("cc-launch", row, col, width, height, c.tone.body)
  let host = c.node(parent, row, col, width, height, [("cc-launch", "launch")])
  let left = col + 1
  let inner = max(1, width - 2)
  let bottom = row + height
  let composer = vm.composer
  # While a launch waits for its answer the form is locked (study D74):
  # drawn as it was sent, no part of it pressable, `Launch` busy.
  let locked = vm.launching
  # The head band every panel of the tab has (the Initiatives panel's own),
  # so the columns' heads line up.
  var r = row + c.drawSectionHeader(host, row, col, width, LaunchHeading, "", "")
  # The head band's summary place (empty here) is not the tab's summary: the
  # tab's is the Initiatives panel's own, which a reader of the tab finds.
  renameFact(host.children[^1], "summary", "launch-summary")
  var modes: seq[(string, string, string, bool)]
  for (_, label, operation, on) in vm.modeChoices: modes.add (label, operation, "", on)
  let modesNode = c.node(host, r, left, inner, 1, [("cc-modes", $vm.mode)])
  r += c.chipRow(modesNode, ink, r, left, inner, modes, press, locked)
  r += 1
  discard c.text(host, r, left, inner, ForLabel, c.p.textLabel, fact = "field-name")
  r += 1
  var choices: seq[(string, string, string, bool)]
  for choice in vm.launchChoices:
    choices.add (choice.title, ControlCenterLaunchForOperation, choice.id, choice.chosen)
  r += c.chipRow(host, ink, r, left, inner, choices, press, locked)
  r += 1
  discard c.text(host, r, left, inner, InstructionLabel, c.p.textLabel, fact = "field-name")
  r += 1
  # The instruction's field: never cut (study D84), its words wrapped onto
  # as many rows as they take. Locked (a launch in flight): no field ground,
  # the words in the label role (study D74), so the form reads as what was
  # sent and stays above the options not chosen.
  let fieldBg = if locked: c.tone.body else: ink.field
  let whole = composer.text
  if whole.len > 0:
    let lines = wrapCells(whole, max(1, inner - 2))
    for i, line in lines:
      discard c.put(r + i, left, repeat(' ', inner), c.p.textBody, bg = fieldBg)
      # Locked, no field ground and no inset: the words start under the
      # label (study D74).
      discard c.put(r + i, (if locked: left else: left + 1), line,
                    if locked: c.p.textLabel else: c.p.textBody, bg = fieldBg)
    discard c.node(host, r, (if locked: left else: left + 1), inner - 2, lines.len,
                   [("value", whole), ("readonly", $locked)])
    r += lines.len
  else:
    discard c.put(r, left, repeat(' ', inner), c.p.textBody, bg = fieldBg)
    discard c.text(host, r, left + 1, inner - 2, vm.instructionPlaceholder,
                   readable(c.p, fieldBg), bg = fieldBg, fact = "value")
    r += 1
  let sendPress = proc(operation, target: string) =
    if press != nil: press(operation, target)
  let formPress: ComposerPress = if locked: nil else: sendPress
  if vm.showsLaunchForm and folded:
    # The whole summary, wrapped: a cut summary would hide where and how
    # the launch runs (manager note 167).
    let (summary, problem) = vm.formSummary
    r += 1
    # Locked, it is what is being launched: the label role, as the whole
    # form's values are (study D74; terminal review of 2026-11-24).
    r += c.para(host, r, left, inner, summary,
                if problem: ink.bandError elif locked: c.p.textLabel else: c.p.textCaption,
                fact = "form-summary", breakSeparators = true)
  elif vm.showsLaunchForm:
    r += 1
    # Whole fields only, as far as the column goes; the rest of the column
    # follows them, clipped at the screen's foot with everything below it.
    r += c.drawLaunchForm(composer, host, r, left, inner, max(0, bottom - r), formPress,
                          locked = locked)
  if composer.showsSendLine:
    r += 1
    c.drawSendLine(ink, sendPress, composer, host, r, left, inner, busy = locked,
                   label = vm.launchSendLabel)
    r += 1
  let (words, failed, _) = vm.launchNotice
  if words.len > 0:
    r += 1
    let fg = if noticeRole(failed) == "error": ink.bandError else: c.p.textBody
    # A ` · ` the wrap leaves at a line's end is dropped (review of the
    # step-4 follow-up: `Plan started on hub-a ·`).
    r += c.para(host, r, left, inner, words, fg, fact = "cc-notice-line",
                breakSeparators = true)
  block:
    r += 1
    discard c.text(host, r, left, inner, RecentLaunchesLabel, c.p.textLabel, bold = true,
                   fact = "section")
    r += 1
    let launches = vm.recent
    if launches.len == 0:
      discard c.text(host, r, left, inner, NoRecentLaunchesWords, ink.bandCaption)
      r += 1
    for launch in launches:
      let n = c.node(host, r, left, inner, 2, launch.recentFacts)
      discard c.text(n, r, left, inner, launch.text, c.p.textBody)
      discard c.text(n, r + 1, left, inner, recentLine(launch),
                     if launch.failed: ink.bandError else: ink.bandCaption)
      r += 2
  r - row

proc whyLines(row: WaitingRow; cells: int): seq[string] =
  let why = row.waitingWhy
  if why.len == 0: return
  result = wrapCells(why, cells)
  if result.len > 2:
    # The rest of the question on the second line, cut at a word boundary
    # by the one rule (`elideAtWord`: whole words, no space or separator
    # before its `…`; TUI reviews of 2026-11-24 found `over to …` and then
    # `loader; o…`).
    let rest = result[1 .. ^1].join(" ")
    result.setLen 2
    result[1] = elideAtWord(rest, cells)

proc waitingRows*(vm: ControlCenterVM; cells: int): int =
  ## The rows the waiting section's content takes: its head band, then each
  ## row (title, state and where, why), a blank row between rows.
  result = 1
  let rows = vm.waiting
  if rows.len == 0: return 2
  for i, row in rows:
    result += 2 + whyLines(row, cells).len
    if i < rows.high: inc result

proc stateInk(c: AhCanvas; attention: SessionAttention): string =
  if attention == saNeedsInput: warningInk(c.p) else: c.p.textCaption

const ClippedShift = 100_000
  ## How far a node below the control center's foot is moved: off every
  ## screen, so a reader of the tree finds it clipped (wholly below the
  ## foot), as a list the web clips.

proc clipBelow(n: AhNode; foot: int) =
  ## The nodes of `n`'s tree that start at or below `foot`, moved off the
  ## screen: what the host draws at its foot (a playback bar) is not theirs.
  if n.row >= foot: n.row += ClippedShift
  for ch in n.children: clipBelow(ch, foot)

proc contentBottom(n: AhNode): int =
  ## The row under the last thing drawn in `n`'s tree, leaving out the areas
  ## that only stake out a height (a panel's host and its list).
  result = 0
  if not (n.has("surface") or n.has("rows")): result = n.row + max(1, n.height)
  for ch in n.children: result = max(result, contentBottom(ch))

proc panelRows*(c: AhCanvas; vm: ControlCenterVM; width: int): int =
  ## The rows the Initiatives panel's own drawing takes at `width`: drawn on
  ## a canvas of its own first, as tall as it needs. The panel's view draws
  ## every row it has; the control center gives it that room, so nothing
  ## drawn after it lands on its rows.
  var scratch = newAhCanvas(width, 1000, c.p)
  scratch.drawInitiativesPanel(vm.initiatives, 0, 0, width, 1000)
  max(3, contentBottom(scratch.root))

proc drawWaiting(c: var AhCanvas; host: AhNode; vm: ControlCenterVM;
                 top, col, width, height: int; press: ControlCenterPress) =
  ## The waiting list at `top`, `height` rows (what does not fit is clipped
  ## at its foot by the caller): a panel's head band, then one row per
  ## waiting session.
  let inner = max(1, width - 2)
  c.area("cc-waiting", top, col, width, height, c.tone.body)
  let rows = vm.waiting
  let section = c.node(host, top, col, width, height, [("waiting-section", $rows.len)])
  var r = top + c.drawSectionHeader(section, top, col, width, WaitingHeading, "",
                                    waitingCountText(rows.len))
  # The count sits where a panel has its summary, but the tab's summary is
  # the Initiatives panel's own: a reader of the tab finds that one.
  renameFact(section, "summary", "waiting-count")
  if rows.len == 0:
    discard c.text(section, r, col + 1, inner, NothingWaitingWords, c.p.textCaption)
  let focused = vm.focused.val
  for i, row in rows:
    let why = whyLines(row, inner)
    let h = 2 + why.len
    let isFocused = row.item.id == focused
    let n = c.node(section, r, col, width, h, row.waitingFacts(isFocused))
    n.tag("accessible-name", row.item.title & ", " & row.words)
    if isFocused:
      # The row the keys are on: the inset bar in the action border role.
      for k in 0 ..< h:
        discard c.put(r + k, col, BarGlyph, c.p.borderAction)
    discard c.text(n, r, col + 1, inner, row.item.title, c.p.textBody)
    let word = row.stateWordOf
    let wordW = c.text(n, r + 1, col + 1, inner, word, c.stateInk(row.item.attention),
                       fact = "state-word")
    # Its initiative and age: where the line is too narrow the initiative is
    # cut and the age kept (TUI review of 2026-11-24: `· 9m` was lost).
    let metaAt = col + 1 + wordW + 2
    let metaRoom = max(1, inner - wordW - 2)
    let (initiative, age) = row.waitingMetaParts
    let ageW = widthOf(age)
    if widthOf(initiative) + ageW > metaRoom and ageW < metaRoom:
      let initW = c.text(n, r + 1, metaAt, metaRoom - ageW, initiative, c.p.textCaption)
      discard c.text(n, r + 1, metaAt + initW, ageW, age, c.p.textCaption)
    else:
      discard c.text(n, r + 1, metaAt, metaRoom, row.waitingMeta, c.p.textCaption)
    for k, line in why:
      discard c.put(r + 2 + k, col + 1, line, c.p.textBody)
    c.pressable(n, press, ControlCenterOpenSessionOperation, row.item.id)
    r += h + (if i < rows.high: 1 else: 0)

proc drawOverview(c: var AhCanvas; parent: AhNode; vm: ControlCenterVM;
                  row, col, width, height: int; press: ControlCenterPress;
                  bounded: bool): int =
  ## The overview from (`row`, `col`), `width` cells wide (study D73): the
  ## waiting list first, then the Initiatives panel. `bounded` (two columns,
  ## `height` rows): the waiting list as tall as its rows and at most 45% of
  ## the height, as the web's, the panel filling the rest, what it draws
  ## below that clipped there as the web's panel scrolls. Unbounded (one
  ## column, under the launch column): each as tall as its own drawing, what
  ## falls below the screen clipped at its foot (a terminal does not scroll;
  ## the web's tab does). Returns the rows it takes.
  let inner = max(1, width - 2)
  let ready = vm.state == asReady
  let needed = if ready: vm.waitingRows(inner) else: 0
  let waitingH = if bounded: min(needed, max(2, height * 45 div 100)) else: needed
  let panelTop = row + (if waitingH > 0: waitingH + 1 else: 0)
  let panelH =
    if bounded: height - (panelTop - row)
    elif vm.isEmptyFleet: 3
    elif not ready: 8
      # The panel's own loading or error lines are centred in its height:
      # a few rows under its head, where a short screen still shows them.
    else: c.panelRows(vm, width)
  let total = panelTop - row + panelH
  let host = c.node(parent, row, col, width, total, [("cc-overview", "overview")])
  if waitingH > 0:
    let first = host.children.len
    c.drawWaiting(host, vm, row, col, width, waitingH, press)
    for i in first ..< host.children.len: clipBelow(host.children[i], row + waitingH)
  if vm.isEmptyFleet:
    # The panel's place keeps a panel's head band: the Initiatives panel's
    # title and source, then the line.
    c.area("cc-empty", panelTop, col, width, panelH, c.tone.body)
    let headRows = c.drawSectionHeader(host, panelTop, col, width, "Initiatives",
                                       vm.initiatives.sourceLabel, "")
    discard c.text(host, panelTop + headRows + 1, col + 1, inner, NoInitiativesWords,
                   c.p.textCaption, fact = "cc-empty-line")
  else:
    # The panel's own drawing (D64), whose drawer hangs its node at the
    # canvas's root; it is moved under the overview, so the panel is part of
    # the control center's tree, as the web's is part of its tab.
    let before = c.root.children.len
    c.drawInitiativesPanel(vm.initiatives, panelTop, col, width, panelH)
    while c.root.children.len > before:
      host.children.add c.root.children[before]
      c.root.children.delete(before)
  total

proc drawControlCenter*(c: var AhCanvas; vm: ControlCenterVM; row, col, width, height: int;
                        press: ControlCenterPress = nil) =
  ## The control center at (`row`, `col`), `width` × `height` cells. What
  ## its columns hold below `row + height` is clipped there.
  let first = c.root.children.len
  defer:
    for i in first ..< c.root.children.len: clipBelow(c.root.children[i], row + height)
  vm.narrowBelow = NarrowBelowCells
  let layout = vm.layoutFor(width)
  var facts = vm.centerFacts(width)
  facts.add ("columns", $layout)
  let host = c.node(nil, row, col, width, height, facts)
  # The window's ground between and under the columns: the web's canvas
  # role, a step off the panels in both themes.
  c.area("cc-window", row, col, width, height, tokenHexOf(dtColorsUiSurfaceBaseCanvas, c.p.mode))
  if layout == clTwoColumns:
    let launchW = launchCellsOf(width)
    # The form folds to its summary line when the column cannot hold it
    # with what follows it (a short screen, study D75): measured on a
    # canvas of its own first.
    var scratch = newAhCanvas(c.cols, max(c.rows, 1000), c.p)
    let whole = scratch.drawLaunch(nil, vm, row, col, launchW, 1000, nil)
    discard c.drawLaunch(host, vm, row, col, launchW, height, press, folded = whole > height)
    discard c.drawOverview(host, vm, row, col + launchW + 1, width - launchW - 1, height,
                           press, bounded = true)
  else:
    # The launch column as tall as its content: measured on a canvas of its
    # own first, so its area ends where the overview's begins. The form folds
    # to its summary only where the screen cannot hold it whole with the
    # overview under it (study D75, D84): an empty fleet's short overview
    # leaves room for the whole form.
    var scratch = newAhCanvas(c.cols, max(c.rows, 1000), c.p)
    let wholeH = scratch.drawLaunch(nil, vm, row, col, width, 1000, nil)
    var scratch2 = newAhCanvas(c.cols, max(c.rows, 1000), c.p)
    let overviewH = scratch2.drawOverview(nil, vm, row, col, width, 1000, nil, bounded = false)
    let fold = wholeH + 1 + 1 + overviewH > height
    var scratch3 = newAhCanvas(c.cols, max(c.rows, 1000), c.p)
    let launchH = min(height, scratch3.drawLaunch(nil, vm, row, col, width, 1000, nil,
                                                  folded = fold) + 1)
    discard c.drawLaunch(host, vm, row, col, width, launchH, press, folded = fold)
    # The overview under it, as tall as it needs: what is below the screen
    # is clipped at its foot, where the web's tab scrolls.
    discard c.drawOverview(host, vm, row + launchH + 1, col, width,
                           max(0, height - launchH - 1), press, bounded = false)
