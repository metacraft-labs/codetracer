## tui/agent_harbor/ah_tui_fleet_panel.nim — CTF-P1b. The terminal view of
## the Agent Harbor fleet (`FleetSnapshotVM`): the section head, the filter
## chips with their counts, the column names when the panel is wide, and
## one row per session — its mark, title, status and meta, its failure, its
## latest activity and `+N` to unfold the rest.
##
## The same parts, order and words as the web prototype
## (`isonim_agent_harbor_fleet_view.nim`) and GPUI
## (`gpui/agent_harbor/ah_fleet_panel.nim`); the words are
## `agent_harbor_words`'. Areas are told apart by background: the head, the filters and the column names
## are three bands, and the rows alternate their ground where the web draws a
## hairline under each; the selected row is the action role's; `+N` unfolds
## a row's activity with a click.

import std/strutils
import isonim/core/signals
import nim_agents_isonim_viewmodels/agent_harbor/fleet_vm
from ../../viewmodel/views/agent_harbor_words import
  filterLabel, filterCount, metaParts, metaPartsShort, withheldNote, headerSummary,
  AgentHarborFleetLoadingText, AgentHarborFleetEmptyText,
  AgentHarborFleetFilteredEmptyText, AgentHarborFleetEmptyCellText

import ./ah_tui_canvas
import ./ah_tui_initiative_panels

export fleet_vm, ah_tui_canvas

const
  ColumnsFromPx = 960        ## `@container ah-fleet (min-width: 60rem)`
  NarrowHeaderPx = 640       ## `@container ah-fleet (max-width: 40rem)`
  DurationCells = 80 div CellPx
  AgeCells = 64 div CellPx

type
  FleetGrid = object
    session, share: int

proc fleetGrid(width: int; anyInitiative: bool): FleetGrid =
  ## The wide grid: the session column two shares, agent / host /
  ## initiative one each, then duration and age.
  let shares = if anyInitiative: 5 else: 4
  let columns = if anyInitiative: 7 else: 6
  let free = width - 2 - 2 - DurationCells - AgeCells - (columns - 1)
  let share = max(1, free div shares)
  FleetGrid(session: 2 * share, share: share)

proc markOf(p: AhPalette; category: FleetCategory): MarkStyle =
  case category
  of fcNeedsInput: MarkStyle(colour: p.iconWarning)
  of fcRunning: MarkStyle(colour: p.iconSuccess)
  of fcQueued: MarkStyle(colour: p.iconInfo)
  of fcFailed: MarkStyle(colour: p.iconError)
  of fcEnded: MarkStyle(colour: p.iconSubtle)

proc statusColour(p: AhPalette; category: FleetCategory): string =
  case category
  of fcNeedsInput: p.textWarning
  of fcRunning: p.textSuccess
  of fcFailed: p.textError
  else: p.textLabel

proc agentText(row: FleetRow): string =
  if row.agentCount > 1: row.agentLabel & " \xC3\x97" & $row.agentCount else: row.agentLabel

proc cell(c: var AhCanvas; parent: AhNode; row, col, width: int; s, name: string;
          right = false; colour = "") =
  ## One grid cell; an empty one says "—" in the disabled role.
  let empty = s.len == 0
  let shown = if empty: AgentHarborFleetEmptyCellText else: s
  let n = c.node(parent, row, col, width, 1, [("col", name)])
  if empty: n.tag("empty", "true")
  discard c.text(n, row, col, width, shown,
                 if empty: c.p.textDisabled elif colour.len > 0: colour else: c.p.textLabel,
                 alignRight = right)

proc drawRow(c: var AhCanvas; parent: AhNode; vm: FleetSnapshotVM; row: FleetRow;
             index, top, col, width: int; columns, anyInitiative: bool;
             grid: FleetGrid): int =
  let id = row.id
  let sel = row.selected
  let selText = c.p.selectedText
  let shown = if row.expanded: row.activity.len else: min(1, row.activity.len)
  let mainW = if columns: grid.session else: width - 3 - widthOf(row.ageLabel) - 2
  let metaWords = (if columns: row.metaPartsShort else: row.metaParts).join(Middot)
  # Wide: the title and meta share a line while both fit.
  let oneLine = columns and widthOf(row.title) + 2 + widthOf(row.statusLabel) + 1 +
                widthOf(metaWords) <= mainW
  let height = (if oneLine: 1 else: 2) + (if row.failureText.len > 0: 1 else: 0) + shown
  let ground = if sel: c.p.action elif index mod 2 == 1: c.tone.band else: c.tone.body
  if ground == c.tone.body:
    # A row on the panel's ground is an item of the list: the stripes and
    # the selection are the areas set off from it.
    c.fill(top, col, width, height, ground)
  else:
    c.area("fleet-row", top, col, width, height, ground)
  let n = c.node(parent, top, col, width, height,
                 [("row", id), ("category", $row.category), ("selected", $sel),
                  ("expanded", $row.expanded)])
  c.target(top, col, width, height, proc() = vm.select(id))
  discard c.mark(n, top, col + 1, c.p.markOf(row.category))
  let mc = col + 3
  discard c.text(n, top, mc, if oneLine: widthOf(row.title) else: mainW, row.title,
                 if sel: selText elif row.titleIsPlaceholder: c.p.textCaption else: c.p.textBody,
                 fact = "title")
  var r = top + 1
  var metaRow = top + 1
  var metaCol = mc
  if oneLine:
    metaRow = top
    metaCol = mc + widthOf(row.title) + 2
    r = top + 1
  else:
    r = top + 2
  let sw = c.text(n, metaRow, metaCol, mainW - (metaCol - mc), row.statusLabel,
                  if sel: selText else: c.p.statusColour(row.category), fact = "status")
  let room = mainW - (metaCol - mc) - sw - 1
  if room > 0:
    discard c.text(n, metaRow, metaCol + sw + 1, room, metaWords,
                   if sel: selText else: c.p.textCaption, fact = "meta")
  else:
    discard c.node(n, metaRow, metaCol + sw, 0, 1, [("meta-hidden", metaWords)])
  if row.failureText.len > 0:
    discard c.text(n, r, mc, mainW, row.failureText, if sel: selText else: c.p.textError,
                   fact = "failure")
    inc r
  for i in 0 ..< shown:
    let level = if i < row.activityLevels.len: row.activityLevels[i] else: ""
    let hasChip = i == 0 and row.activity.len + row.activityMore > 1
    var label = ""
    if hasChip:
      let hidden = row.activity.len - 1 + row.activityMore
      label = " " & (if row.expanded: "less" else: "+" & $hidden) & " "
    let tw = c.text(n, r, mc, mainW - (if hasChip: widthOf(label) + 1 else: 0),
                    row.activity[i],
                    if sel: selText elif level == "error": c.p.textError else: c.p.rowDetail,
                    fact = "activity")
    if hasChip:
      let at = mc + tw + 1
      # On the selected row the chip keeps the row's ground and is told by
      # its words' colour; elsewhere it has the chip's ground.
      discard c.put(r, at, label, if sel: selText else: c.p.textLabel,
                    bg = if sel: "" else: c.tone.chip)
      discard c.node(n, r, at + 1, widthOf(label) - 2, 1,
                     [("activity-more", label.strip), ("outlined", $sel)])
      c.target(r, at, widthOf(label), 1, proc() = vm.toggleExpanded(id))
    inc r
  if columns:
    let colour = if sel: selText else: ""
    var at = mc + grid.session + 1
    c.cell(n, top, at, grid.share, row.agentText, "agent", colour = colour)
    at += grid.share + 1
    c.cell(n, top, at, grid.share, row.host, "host", colour = colour)
    at += grid.share + 1
    if anyInitiative:
      c.cell(n, top, at, grid.share, row.initiative, "initiative", colour = colour)
      at += grid.share + 1
    c.cell(n, top, at, DurationCells, row.durationLabel, "duration", right = true,
           colour = colour)
    discard c.text(n, top, col + width - 1 - AgeCells, AgeCells, row.ageLabel,
                   if sel: selText else: c.p.textBodySubtle, fact = "age", alignRight = true)
  else:
    let aw = widthOf(row.ageLabel)
    discard c.text(n, top, col + width - 1 - aw, aw, row.ageLabel,
                   if sel: selText else: c.p.textBodySubtle, fact = "age")
  height

proc drawFleetPanel*(c: var AhCanvas; vm: FleetSnapshotVM; row, col, width, height: int) =
  let ready = vm.state.val == asReady
  let host = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-fleet"), ("state", stateName(vm.state.val))])
  c.area("panel", row, col, width, height, c.tone.body)
  var r = row
  r += c.drawSectionHeader(host, r, col, width, "Agent Harbor sessions", vm.sourceLabel,
                           if ready: vm.headerSummary else: "",
                           caveat = if ready: vm.withheldNote else: "",
                           narrow = width * CellPx <= NarrowHeaderPx)
  let columns = width * CellPx >= ColumnsFromPx
  let anyInitiative = ready and vm.anyInitiative
  let grid = fleetGrid(width, anyInitiative)
  if ready:
    # The filter chips, wrapping, on their own band.
    let counts = vm.counts
    var chips: seq[(FleetFilter, int, int)]
    for filter in FleetFilter:
      let n = counts.filterCount(filter)
      chips.add (filter, n, widthOf(filterLabel(filter)) + 1 + widthOf($n) + 2)
    var lines = 1
    var used = 1
    for (_, _, w) in chips:
      if used + w > width - 1 and used > 1:
        inc lines
        used = 1
      used += w + 1
    c.area("filters", r, col, width, lines, c.tone.filters)
    var at = col + 1
    var fr = r
    for (filter, n, w) in chips:
      if at + w > col + width - 1 and at > col + 1:
        inc fr
        at = col + 1
      let active = filter == vm.filter.val
      let chosen = filter
      let chip = c.node(host, fr, at, w, 1, [("filter", $filter), ("filter-count", $n),
                                             ("active", $active)])
      if active: c.fill(fr, at, w, 1, c.tone.chosen)
      let lw = c.put(fr, at + 1, filterLabel(filter),
                     if active: c.p.textBody else: c.p.textLabel)
      discard c.put(fr, at + 1 + lw + 1, $n,
                    if n == 0: c.p.textDisabled elif active: c.p.textBody else: c.p.textCaption)
      discard chip
      c.target(fr, at, w, 1, proc() = vm.setFilter(chosen))
      at += w + 1
    r += lines
  if columns:
    # Under the filters' band, or straight under the head when there are no
    # filters yet (loading, an error): never on the ground just above it.
    c.area("columns", r, col, width, 1, if ready: c.tone.head else: c.tone.filters)
    let names = c.node(host, r, col, width, 1, [("columns", "")])
    var at = col + 3
    c.cell(names, r, at, grid.session, "Session", "session")
    at += grid.session + 1
    c.cell(names, r, at, grid.share, "Agent", "agent")
    at += grid.share + 1
    c.cell(names, r, at, grid.share, "Host", "host")
    at += grid.share + 1
    if anyInitiative:
      c.cell(names, r, at, grid.share, "Initiative", "initiative")
      at += grid.share + 1
    c.cell(names, r, at, DurationCells, "Duration", "duration", right = true)
    c.cell(names, r, col + width - 1 - AgeCells, AgeCells, "Active", "age", right = true)
    inc r
  let bodyH = row + height - r
  case vm.state.val
  of asIdle, asLoading:
    c.notice(host, r, col, width, bodyH, AgentHarborFleetLoadingText, "loading")
  of asError:
    let target = vm
    c.errorBlock(host, r, col, width, bodyH, "Could not load the sessions", vm.error.val,
                 proc() = target.load())
  of asReady:
    let rows = vm.rows
    if rows.len == 0:
      c.notice(host, r, col, width, bodyH,
               if vm.counts.listed == 0: AgentHarborFleetEmptyText
               else: AgentHarborFleetFilteredEmptyText, "empty")
      return
    let list = c.node(host, r, col, width, bodyH, [("rows", "list")])
    for i, fr in rows:
      r += c.drawRow(list, vm, fr, i, r, col, width, columns, anyInitiative, grid)
