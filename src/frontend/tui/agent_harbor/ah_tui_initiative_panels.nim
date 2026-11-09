## tui/agent_harbor/ah_tui_initiative_panels.nim — CTF-P1b. The terminal
## views of the Initiatives panel (`InitiativesVM`) and the Initiative
## Progress panel (`InitiativeProgressVM`), and the pieces the initiative
## tab bar's popup shares with them: the milestone bar, the current
## milestone, a session line.
##
## The same parts, order and words as the web prototypes
## (`isonim_agent_harbor_initiatives_view.nim`, `..._progress_view.nim`) and
## the GPUI views (`gpui/agent_harbor/ah_initiative_panels.nim`); the words
## are `agent_harbor_words`'. Areas are told apart by
## background: the section head, the
## status groups and alternate rows are bands of their own ground where the
## web draws a hairline; a node folds with a click on its ▸/▾ and shows all
## its sessions with a click on `+N more`; the selected initiative is told
## by its ground and the action role's bar at its left edge.

import std/strutils
from std/unicode import runes, Rune, `$`
import isonim/core/signals
import nim_agents_isonim_viewmodels/agent_harbor/[initiatives_vm, initiative_progress_vm]
from ../../viewmodel/views/agent_harbor_words import
  statusCountsText, milestoneMetaParts, InitiativeSessionLinesShown,
  InitiativesLoadingText, InitiativesEmptyText, ProgressEmptyText

import ./ah_tui_canvas

export initiatives_vm, initiative_progress_vm, ah_tui_canvas

const
  MilestoneBarOrder* = [mscCompleted, mscInProgress, mscPartial, mscBlocked,
                        mscPlanned, mscOther]
  BarGlyphHalf = "\xE2\x96\x80"   ## ▀ a milestone bar's segment (upper half)
  SessionIndent = 20 div CellPx + 1
  WidePanelPx = 960               ## `@container ah-initiatives (min-width: 60rem)`
  WideInfoMaxCells = 576 div CellPx
  MilestoneMetaCells = 352 div CellPx
  MilestoneIdCells = 72 div CellPx
  NarrowProgressPx = 480
  BarMaxCells = 580 div CellPx    ## the bar beside a legend: max-width 580px
  LegendMinCells = 144 div CellPx

# ---------------------------------------------------------------------------
# Pieces
# ---------------------------------------------------------------------------

proc drawSectionHeader*(c: var AhCanvas; parent: AhNode; row, col, width: int;
                        title, source, summary: string; caveat = "";
                        narrow = false): int =
  ## A panel's head band, laid out as the web's wrapping flex row
  ## (`.ah-fleet-section-header`: `flex-wrap: wrap`): its title in
  ## capitals, then the source beside it when it fits there whole, else on
  ## its own line(s); the summary at the end of the last line when it fits
  ## there, else right-aligned on its own line(s); the caveat after the
  ## summary when both fit, else on its own line(s). `narrow` is the fleet's
  ## narrow header (`@container ah-fleet (max-width: 40rem)`): the summary
  ## beside the title, the source and the caveat each on a line below.
  ## Nothing is cut: a part a line cannot hold wraps. Returns the rows.
  let upper = title.toUpperAscii
  let inner = width - 2
  let tw = widthOf(upper)
  let sw = widthOf(summary)
  let cw = widthOf(caveat)
  # Plan the lines first (the band is painted under all of them).
  type Part = object
    text, fact: string
    line, col, cells: int   # col 0-based within the band; cells: the wrap width
    right: bool
  var parts: seq[Part]
  var line = 0
  var x = 1 + tw              # the end of what the current line holds
  proc fits(x, w: int): bool = x + 2 + w <= width - 1
  proc ownLines(text: string; right: bool; fact: string) =
    inc line
    parts.add Part(text: text, fact: fact, line: line, col: 1, cells: inner, right: right)
    let lines = wrapCells(text, inner)
    line += lines.len - 1
    # A part that wrapped is a box the line's width: nothing follows it on
    # its last line (a flex item that wrapped fills its line).
    x = (if right or lines.len > 1: width - 1 else: 1 + widthOf(lines[^1]))
  proc summaryAndCaveat() =
    if summary.len == 0: return
    let both = caveat.len > 0 and not narrow and fits(x, sw + widthOf(Middot) + cw)
    if both:
      parts.add Part(text: summary, fact: "summary", line: line,
                     col: width - 1 - (sw + widthOf(Middot) + cw), cells: sw)
      parts.add Part(text: Middot, line: line, col: width - 1 - widthOf(Middot) - cw,
                     cells: widthOf(Middot))
      parts.add Part(text: caveat, fact: "caveat", line: line, col: width - 1 - cw, cells: cw)
      x = width - 1
    elif fits(x, sw):
      parts.add Part(text: summary, fact: "summary", line: line, col: width - 1 - sw, cells: sw)
      x = width - 1
    else:
      ownLines(summary, true, "summary")
  if narrow:
    summaryAndCaveat()
    if source.len > 0: ownLines(source, false, "source")
  else:
    if source.len > 0:
      if fits(x, widthOf(source)):
        parts.add Part(text: source, fact: "source", line: line, col: x + 2,
                       cells: widthOf(source))
        x += 2 + widthOf(source)
      else:
        ownLines(source, false, "source")
    summaryAndCaveat()
  var caveatDrawn = false
  for p in parts:
    if p.fact == "caveat": caveatDrawn = true
  if caveat.len > 0 and not caveatDrawn: ownLines(caveat, false, "caveat")
  let rows = line + 1
  c.area("head", row, col, width, rows, c.tone.head)
  let n = c.node(parent, row, col, width, rows, [("head", "section header")])
  discard c.put(row, col + 1, upper, c.p.textBody, bold = true)
  for p in parts:
    if p.fact.len == 0:
      discard c.put(row + p.line, col + p.col, p.text, c.p.textCaption)
    else:
      discard c.para(n, row + p.line, col + p.col, p.cells, p.text, c.p.textCaption,
                     fact = p.fact, alignRight = p.right)
  if summary.len == 0:
    discard c.node(n, row, col + width - 1, 0, 1, [("summary", "")])
  rows

proc legendCells*(counts: array[MilestoneStatusClass, int]): int =
  ## The width of the numbers-only legend beside a bar: each status's mark,
  ## a space and its count, two cells apart.
  for s in MilestoneBarOrder:
    if counts[s] > 0: result += 2 + widthOf($counts[s]) + 2
  result = max(0, result - 2)

proc drawMilestoneBar*(c: var AhCanvas; parent: AhNode; row, col, width: int;
                       counts: array[MilestoneStatusClass, int];
                       labelled: bool; legendSlot = 0): int =
  ## Milestones by status: a bar of segments, each as wide as its count's
  ## share (at least one cell), and its legend — under it with the words
  ## (`labelled`, wrapping), or beside it with the numbers. Beside it, the
  ## legend has a slot of `legendSlot` cells (at least the 9rem the
  ## stylesheet gives it) with the counts at its end, so every bar of a list
  ## given the same slot is one width and ends in one column, on one scale.
  ## Returns the rows.
  let n = c.node(parent, row, col, width, 1, [("milestone-bar", statusCountsText(counts))])
  var total = 0
  var present: seq[MilestoneStatusClass]
  for s in MilestoneBarOrder:
    if counts[s] > 0:
      total += counts[s]
      present.add s
  # The legend's items.
  var items: seq[(MilestoneStatusClass, string)]
  for s in present:
    items.add (s, $counts[s] & (if labelled: " " & $s else: ""))
  var legendW = 0
  for (_, words) in items: legendW += 2 + widthOf(words) + 2
  legendW = max(0, legendW - 2)
  let slot = max(LegendMinCells, max(legendSlot, legendW))
  let barW = if labelled: max(1, width - 2)
             else: max(present.len, min(BarMaxCells, width - 2 - slot - 2))
  # Segments, by largest remainder, none narrower than a cell.
  var cells = newSeq[int](present.len)
  if total > 0:
    var given = 0
    for i, s in present:
      cells[i] = max(1, counts[s] * barW div total)
      given += cells[i]
    var i = 0
    while given < barW and present.len > 0:
      inc cells[i mod present.len]
      inc given
      inc i
    while given > barW:
      var widest = 0
      for k in 0 ..< cells.len:
        if cells[k] > cells[widest]: widest = k
      if cells[widest] <= 1: break
      dec cells[widest]
      dec given
  var at = col + 1
  let track = c.node(n, row, col + 1, barW, 1, [("ms-bar", "track")])
  for i, s in present:
    discard c.put(row, at, repeat(BarGlyphHalf, cells[i]), c.p.segmentOf(s))
    discard c.node(track, row, at, cells[i], 1, [("segment", $s & ":" & $counts[s])])
    at += cells[i]
  var r = row
  var lc: int
  if labelled:
    inc r
    lc = col + 1
  else:
    lc = col + 1 + barW + 2
  let legend = c.node(n, r, lc, width - (lc - col), 1,
                      [("ms-legend", if labelled: "under" else: "beside")])
  if not labelled:
    # The counts at the legend's end (`min-width: 9rem`).
    lc = max(lc, lc + max(0, slot - legendW))
  for (s, words) in items:
    let need = 2 + widthOf(words)
    if labelled and lc + need > col + width - 1 and lc > col + 1:
      inc r
      lc = col + 1
    discard c.mark(legend, r, lc, c.p.markOf(s))
    discard c.put(r, lc + 2, words, c.p.textLabel)
    lc += need + 2
  n.height = r - row + 1
  r - row + 1

proc drawCurrent*(c: var AhCanvas; parent: AhNode; row, col, width: int; text: string) =
  ## `CURRENT` and the milestone in progress.
  let n = c.node(parent, row, col, width, 1, [("current", text)])
  let w = c.put(row, col, "CURRENT", c.p.textLabel, bold = true)
  discard c.text(n, row, col + w + 1, max(1, width - w - 1), text, c.p.textBody)

proc sessionStatusColour(p: AhPalette; attention: SessionAttention): string =
  case attention
  of saNeedsInput: p.textWarning
  of saRunning: p.textSuccess
  of saFailed: p.textError
  else: p.textLabel

proc drawSessionLine*(c: var AhCanvas; parent: AhNode; item: SessionItem;
                      row, col, width: int) =
  ## One of an initiative's sessions: its mark, title and status word.
  let n = c.node(parent, row, col, width, 1, [("session", item.id),
                                              ("attention", $item.attention),
                                              ("tooltip", item.tooltip)])
  discard c.mark(n, row, col, c.p.markOf(item.attention))
  let sw = widthOf(item.statusLabel)
  discard c.text(n, row, col + 2, max(1, width - 2 - sw - 1), item.title, c.p.textBody,
                 fact = "title")
  discard c.text(n, row, col + width - sw, sw, item.statusLabel,
                 c.p.sessionStatusColour(item.attention), fact = "status")

# ---------------------------------------------------------------------------
# Initiatives
# ---------------------------------------------------------------------------

proc drawInitiativeRow(c: var AhCanvas; parent: AhNode; vm: InitiativesVM;
                       row: InitiativeRow; index, top, col, width, legendSlot: int): int =
  ## One initiative and, unless folded, its sessions. Returns its rows.
  let id = row.id
  let wide = width * CellPx >= WidePanelPx
  let infoW = if wide: min(WideInfoMaxCells, (width - 2 - 4) div 2) else: width - 2
  # How tall: the head, the bar, the current milestone and meta, then the
  # sessions (beside the info when wide).
  var meta: seq[string]
  if row.repository.len > 0: meta.add row.repository
  if row.manager.len > 0: meta.add "manager " & row.manager
  let infoRows = 2 + (if row.currentMilestone.len > 0: 1 else: 0) + (if meta.len > 0: 1 else: 0)
  var sessionRows = 0
  let shown = if row.folded: 0
              elif row.expanded: row.sessions.len
              else: min(row.sessions.len, InitiativeSessionLinesShown)
  let hidden = row.sessions.len - shown
  let more = not row.folded and
             (hidden > 0 or row.expanded and row.sessions.len > InitiativeSessionLinesShown)
  if not row.folded:
    sessionRows = shown + (if more: 1 else: 0) + (if row.sessions.len == 0: 1 else: 0)
  let height = if wide: max(infoRows, sessionRows) else: infoRows + sessionRows
  let selected = row.selected
  let ground = if selected: c.p.selectedGround
               elif index mod 2 == 1: c.tone.band else: c.tone.body
  if ground == c.tone.body:
    c.fill(top, col, width, height, ground)
  else:
    c.area("initiative", top, col, width, height, ground)
  let n = c.node(parent, top, col, width, height,
                 [("initiative", id), ("state", $row.state), ("selected", $selected),
                  ("folded", $row.folded)])
  c.target(top, col, width, height, proc() = vm.select(id))
  if selected:
    for r in top ..< top + height: discard c.put(r, col, BarGlyph, c.p.borderAction)
  discard c.put(top, col + 1, if row.folded: FoldedGlyph else: UnfoldedGlyph, c.p.textLabel)
  discard c.node(n, top, col + 1, 1, 1, [("fold", id)])
  c.target(top, col + 1, 1, 1, proc() = vm.toggleFolded(id))
  discard c.mark(n, top, col + 3, c.p.markOf(row.state))
  let pw = widthOf(row.progressText)
  discard c.text(n, top, col + 5, max(1, infoW - 5 - pw - 1), row.title, c.p.textBody,
                 bold = true, fact = "title")
  discard c.text(n, top, col + 1 + infoW - pw, pw, row.progressText, c.p.textLabel,
                 fact = "progress")
  var r = top + 1
  r += c.drawMilestoneBar(n, r, col + 4, infoW - 3, row.statusCounts, labelled = false,
                          legendSlot = legendSlot)
  if row.currentMilestone.len > 0:
    c.drawCurrent(n, r, col + 5, infoW - 4, row.currentMilestone)
    inc r
  if meta.len > 0:
    discard c.text(n, r, col + 5, infoW - 4, meta.join(Middot), c.p.textCaption,
                   fact = "meta")
    inc r
  if row.folded: return height
  var sr = if wide: top else: r
  let sc = if wide: col + 1 + infoW + 4 else: col + 3 + SessionIndent
  let sw = if wide: width - (sc - col) - 1 else: width - (sc - col) - 1
  for i in 0 ..< shown:
    c.drawSessionLine(n, row.sessions[i], sr, sc, sw)
    inc sr
  if more:
    let label = if row.expanded: "Show fewer" else: "+" & $hidden & " more"
    discard c.put(sr, sc, " " & label & " ", c.p.textLabel, bg = c.tone.chip)
    discard c.node(n, sr, sc + 1, widthOf(label), 1, [("more", label)])
    c.target(sr, sc, widthOf(label) + 2, 1, proc() = vm.toggleExpanded(id))
    inc sr
  if row.sessions.len == 0:
    let label = if row.missingSessions == 0: "No session is working on it"
                else: $row.missingSessions &
                  (if row.missingSessions == 1: " session" else: " sessions") &
                  " on other servers"
    discard c.text(n, sr, sc, sw, label, c.p.textCaption, fact = "more")
  height

proc drawInitiativesPanel*(c: var AhCanvas; vm: InitiativesVM; row, col, width, height: int) =
  let host = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-initiatives"), ("state", stateName(vm.state.val))])
  c.area("panel", row, col, width, height, c.tone.body)
  let headRows = c.drawSectionHeader(host, row, col, width, "Initiatives", vm.sourceLabel,
                                     if vm.state.val == asReady: vm.summaryText else: "")
  let top = row + headRows
  let bodyH = height - headRows
  case vm.state.val
  of asIdle, asLoading:
    c.notice(host, top, col, width, bodyH, InitiativesLoadingText, "loading")
  of asError:
    let target = vm
    c.errorBlock(host, top, col, width, bodyH, "Could not load the initiatives",
                 vm.error.val, proc() = target.load())
  of asReady:
    let rows = vm.rows
    if rows.len == 0:
      c.notice(host, top, col, width, bodyH, InitiativesEmptyText, "empty")
      return
    let list = c.node(host, top, col, width, bodyH, [("rows", "list")])
    # One legend slot for the list: every bar one width, on one scale.
    var legendSlot = LegendMinCells
    for ir in rows: legendSlot = max(legendSlot, legendCells(ir.statusCounts))
    var r = top
    for i, ir in rows:
      r += c.drawInitiativeRow(list, vm, ir, i, r, col, width, legendSlot)

# ---------------------------------------------------------------------------
# Initiative Progress
# ---------------------------------------------------------------------------

proc drawMilestone(c: var AhCanvas; parent: AhNode; m: MilestoneLine; index, row, col,
                   width: int; wide, narrow: bool): int =
  ## One milestone: its mark, id and title, then its deliverables and tests
  ## (beside them when wide); `failing` in the error colour. Wide, the meta
  ## is a right-hand column that grows to hold its words (the title gives
  ## way); narrow, it is a line under the title that wraps rather than cut.
  let parts = milestoneMetaParts(m)
  let metaText = parts.before & parts.failing & parts.after
  let tagW = if m.current: widthOf("CURRENT") + 1 else: 0
  let idW = if narrow: 7 else: MilestoneIdCells
  # Wide: the meta column, CURRENT hanging to its left, at least the
  # stylesheet's 22rem and as wide as its words, leaving the title 12 cells.
  let metaW = if wide: min(max(MilestoneMetaCells, tagW + widthOf(metaText)),
                           max(MilestoneMetaCells, width - 3 - idW - 1 - 2 - 12))
              else: width - 4
  # Narrow: the meta's lines under the title (CURRENT on the first).
  let metaLines = if wide: @[WrappedLine(text: metaText, start: 0)]
                  else: wrapRuns(metaText, max(1, metaW - tagW))
  let height = if wide: 1 else: 1 + metaLines.len
  let ground = if m.current:
                 # Dark's tertiary is the stripe's ground here; the active
                 # tab's grey is the next role up.
                 (if c.p.mode == dmDark: c.p.activeTab elif wide: c.p.hover else: c.p.menu)
               elif wide and index mod 2 == 1: c.tone.band
               else: c.tone.body
  if ground == c.tone.body:
    # A plain milestone is an item of the list, not an area: the web
    # separates it from the next by spacing alone.
    c.fill(row, col, width, height, ground)
  else:
    c.area("milestone", row, col, width, height, ground)
  let n = c.node(parent, row, col, width, height,
                 [("milestone", m.id), ("status-class", $m.statusClass),
                  ("current", $m.current)])
  discard c.mark(n, row, col + 1, c.p.markOf(m.statusClass))
  discard c.text(n, row, col + 3, idW, m.id, c.p.textLabel)
  let titleW = if wide: width - 3 - idW - 1 - metaW - 2 else: width - 3 - idW - 2
  discard c.text(n, row, col + 3 + idW + 1, max(1, titleW), m.title, c.p.textBody,
                 fact = "title")
  let mr = if wide: row else: row + 1
  var mc = if wide: col + width - 1 - metaW else: col + 3
  if wide:
    mc = max(mc, col + width - 1 - widthOf(metaText) - tagW)
  if m.current:
    mc += c.put(mr, mc, "CURRENT", c.p.textLabel, bold = true) + 1
  let room = col + width - 1 - mc
  # The failing count in the error colour, inside the same run, on
  # whichever line it falls.
  let failFrom = if parts.failing.len > 0: widthOf(parts.before) else: -1
  let failTo = failFrom + widthOf(parts.failing)
  var drawn: seq[string]
  for i, ml in metaLines:
    let shown = if wide: elide(ml.text, room) else: ml.text
    drawn.add shown
    var k = 0
    for ch in shown.runes:
      let at = ml.start + k
      let colour = if failFrom >= 0 and at >= failFrom and at < failTo: c.p.textError
                   else: c.p.textCaption
      discard c.put(mr + i, mc + k, $ch, colour)
      k += 1
  var metaWidth = 0
  for d in drawn: metaWidth = max(metaWidth, widthOf(d))
  discard c.node(n, mr, mc, metaWidth, metaLines.len, [("meta", metaText)])
  height

proc drawProgressPanel*(c: var AhCanvas; vm: InitiativeProgressVM; row, col, width,
                        height: int) =
  let host = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-initiative-progress"),
                     ("state", if vm.state.val == asReady and not vm.found: "empty"
                               else: stateName(vm.state.val))])
  c.area("panel", row, col, width, height, c.tone.body)
  let ready = vm.state.val == asReady and vm.found
  let initiative = vm.current
  let headRows = c.drawSectionHeader(host, row, col, width, "Initiative progress",
                                     if ready: initiative.title else: "",
                                     if ready: vm.headline else: "")
  let top = row + headRows
  let bodyH = height - headRows
  case vm.state.val
  of asIdle, asLoading:
    c.notice(host, top, col, width, bodyH, InitiativesLoadingText, "loading")
  of asError:
    let target = vm
    c.errorBlock(host, top, col, width, bodyH, "Could not load the initiative",
                 vm.error.val, proc() = target.load())
  of asReady:
    if not vm.found:
      c.notice(host, top, col, width, bodyH, ProgressEmptyText, "empty")
      return
    let list = c.node(host, top, col, width, bodyH, [("rows", "list")])
    var r = top
    r += c.drawMilestoneBar(list, r, col, width, vm.statusCounts, labelled = true)
    let summaryText = if initiative.executiveSummary.len > 0: initiative.executiveSummary
                      else: "The plan states no executive summary."
    let lines = wrapCells(summaryText, min(width - 2, 768 div CellPx))
    let sn = c.node(list, r, col + 1, width - 2, lines.len,
                    [("executive-summary", summaryText)])
    for line in lines:
      discard c.put(r, col + 1, line,
                    if initiative.executiveSummary.len > 0: c.p.textBody else: c.p.textCaption)
      inc r
    discard sn
    let current = currentMilestoneText(initiative.progress)
    if current.len > 0:
      c.drawCurrent(list, r, col + 1, width - 2, current)
      inc r
    let wide = width * CellPx >= WidePanelPx
    let narrow = width * CellPx <= NarrowProgressPx
    for gi, group in vm.groups:
      # Status groups are never neighbours (each holds a milestone), so
      # one ground serves, unlike the session tree's folded nodes.
      c.area("group", r, col, width, 1, c.tone.group[0])
      discard c.node(list, r, col, width, 1, [("group", group.name)])
      let w = c.put(r, col + 1, group.name.toUpperAscii, c.p.textLabel, bold = true)
      discard c.put(r, col + 1 + w + 1, "(" & $group.count & ")", c.p.textCaption)
      inc r
      for i, m in group.milestones:
        r += c.drawMilestone(list, m, i, r, col, width, wide, narrow)
