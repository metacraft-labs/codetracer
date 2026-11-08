## gpui/agent_harbor/ah_fleet_panel.nim — CTF-P1b. The GPUI view of an Agent
## Harbor fleet, over `FleetSnapshotVM` (nim-agents-isonim-viewmodels).
##
## The web prototype is `viewmodel/views/isonim_agent_harbor_fleet_view.nim`.
## Top to bottom, as there: the section header (`AGENT HARBOR SESSIONS`, the
## source, the withheld-prompts caveat, the count), the filter strip (one
## toggle per category with its count), the column names at a laptop's
## width, then one row per session -- status dot, title, the status word and
## meta line, a failure reason, the first activity line with `+N` (all of
## them when the row is unfolded), and the age at the right; at 60rem and
## wider, agent, host, initiative and duration take columns of their own.
## Every word is the viewmodel's or the words the web view shares through
## `viewmodel/views/agent_harbor_words.nim` (`filterLabel`, `filterCount`, `metaParts`,
## `metaPartsShort`, `withheldNote`, `headerSummary` and the notices).

import ../../../common/pointer_shape
import std/strutils

import isonim/core/[signals, computation]
import nim_agents_isonim_viewmodels/agent_harbor/fleet_vm
from ../../viewmodel/views/agent_harbor_words import
  filterLabel, filterCount, metaParts, metaPartsShort, withheldNote, headerSummary,
  AgentHarborFleetLoadingText, AgentHarborFleetEmptyText,
  AgentHarborFleetFilteredEmptyText, AgentHarborFleetEmptyCellText

import ./ah_theme
import ./ah_initiative_panels

export fleet_vm, ah_theme

const
  ColumnsFromPx = 960        ## `@container ah-fleet (min-width: 60rem)`
  NarrowHeaderPx = 640       ## `@container ah-fleet (max-width: 40rem)`
  DurationColumnPx = 80      ## 5rem
  LinePx = 16                ## a row's lines: `type-ui-lineheight-body-sm` / `-caption-md`
  ChipLinePx = 18            ## the activity line: the `+N` chip's 16px line and its 1px border
  TitleMetaGapPx = 12        ## a wide row's title and meta on one line: `column-gap: 0.75rem`
  WideAgeColumnPx = 64       ## 4rem: the "Active" column
  GridGapPx = 8

type
  FleetGrid = object
    ## The wide panel's columns (`.ah-fleet-row` / `.ah-fleet-columns`,
    ## a grid): the dot, then the session at two shares of the free width,
    ## agent, host and (when any row has one) initiative at one share each,
    ## then duration (5rem) and active (4rem), 8px apart -- measured in the
    ## browser at 1440px: 8, 486, 243, 243, 243, 80, 64. Fluid, so a wider
    ## window widens every share.
    session, share: int

proc fleetGrid(widthPx: int; anyInitiative: bool): FleetGrid =
  let shares = if anyInitiative: 5 else: 4
  let columns = if anyInitiative: 7 else: 6
  let free = widthPx - 2 * InsetPx - MarkPx - DurationColumnPx - WideAgeColumnPx -
             GridGapPx * (columns - 1)
  let share = max(0, free) div shares
  FleetGrid(session: 2 * share, share: share)

proc markOf(p: AhPalette; category: FleetCategory): MarkStyle =
  ## The row's status dot (`.ah-fleet-cat-*`), in the sessions' status roles.
  case category
  of fcNeedsInput: MarkStyle(colour: p.iconWarning)
  of fcRunning: MarkStyle(colour: p.iconSuccess)
  of fcQueued: MarkStyle(colour: p.iconInfo)
  of fcFailed: MarkStyle(colour: p.iconError)
  of fcEnded: MarkStyle(colour: p.iconSubtle)

proc statusColour(p: AhPalette; category: FleetCategory): string =
  ## The status word (`.ah-fleet-status-label`): the label role, or the
  ## status's own text role for failed, running and needs input.
  case category
  of fcNeedsInput: p.textWarning
  of fcRunning: p.textSuccess
  of fcFailed: p.textError
  else: p.textLabel

proc agentText(row: FleetRow): string =
  if row.agentCount > 1: row.agentLabel & " \xC3\x97" & $row.agentCount else: row.agentLabel

proc drawFilter(r: GpuiRenderer; p: AhPalette; vm: FleetSnapshotVM; filter: FleetFilter;
                count: int; active: bool): GpuiElement =
  let chosen = filter
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"), ("gap", "6px"),
                          ("padding-left", "8px"), ("padding-right", "8px"),
                          ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "0"),
                          ("cursor", cursorOf(hkControl))])
  if active: r.setStyle(result, "background", p.hover)
  r.tag(result, "filter", $filter)
  r.tag(result, "filter-count", $count)
  r.tag(result, "active", $active)
  r.appendChild(result, r.text(filterLabel(filter), CaptionPx,
                               if active: p.textBody else: p.textLabel, shrink = false))
  # `.ah-fleet-filter-count`: tabular figures.
  r.appendChild(result, r.text($count, CaptionPx,
                               if count == 0: p.textDisabled
                               elif active: p.textBody else: p.textCaption, shrink = false,
                               tabular = true))
  r.addEventListener(result, "click", proc() = vm.setFilter(chosen))

proc cell(r: GpuiRenderer; p: AhPalette; s: string; widthPx: int; name: string;
          right = false; colour = ""; tabular = false): GpuiElement =
  ## A column cell, on a 16px line (`.ah-fleet-col`: caption size,
  ## `type-ui-lineheight-body-sm`). An empty one shows the shared placeholder
  ## in the disabled role, whatever the row's own text colour
  ## (`.ah-fleet-col-empty`). `tabular`: figures one width
  ## (`.ah-fleet-col-duration`).
  let empty = s.len == 0
  let words = r.text(if empty: AgentHarborFleetEmptyCellText else: s, CaptionPx,
                     if empty: p.textDisabled
                     elif colour.len > 0: colour else: p.textLabel,
                     tabular = tabular, pairs = [("line-height", "16px")])
  if right:
    # Right-aligned (the stylesheet's `text-align: right`): the words at the
    # end of a box of the column's width. The shim draws `text-align` too
    # (isonim-gpui, 2026-11-08), but a cell is one line, which `justify: end`
    # places exactly where the alignment would.
    result = r.box(pairs = [("width", $widthPx & "px"), ("min-width", $widthPx & "px"),
                            ("justify", "end"), ("flex-shrink", "0")])
    r.appendChild(result, words)
  else:
    result = words
    r.styles(result, [("width", $widthPx & "px"), ("min-width", $widthPx & "px")])
  r.tag(result, "col", name)
  if empty: r.tag(result, "empty", "true")

proc drawRow(r: GpuiRenderer; p: AhPalette; vm: FleetSnapshotVM; row: FleetRow;
             columns, anyInitiative: bool; grid: FleetGrid): GpuiElement =
  let id = row.id
  result = r.box(pairs = [("gap", "8px"), ("items", "start"), ("padding-top", "6px"),
                          ("padding-bottom", "6px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                          ("cursor", cursorOf(hkControl))])
  r.rule(result, p.borderSecondary)
  # The selected row: the action surface, and every text of it -- status
  # words and notes included -- in the selected commit row's text colour
  # (`.ah-fleet-row-selected`, after vcs.styl).
  let sel = row.selected
  let selText = p.selectedText
  if sel: r.setStyle(result, "background", p.action)
  r.tag(result, "row", id)
  r.tag(result, "category", $row.category)
  r.tag(result, "selected", $row.selected)
  r.tag(result, "expanded", $row.expanded)
  r.addEventListener(result, "click", proc() = vm.select(id))
  let markHolder = r.box(pairs = [("height", "20px"), ("items", "center")])
  r.appendChild(markHolder, r.mark(p.markOf(row.category)))
  r.appendChild(result, markHolder)
  # Every line of the row is 16px (`.ah-fleet-row-title`, `-meta`,
  # `-failure`, `.ah-fleet-activity-line`), 2px apart, so a row is as tall as
  # the web's: 6px, title, meta, activity (18px with its chip), 6px, the
  # hairline -- 67px.
  let lh = ("line-height", $LinePx & "px")
  let main = r.box(column = true, pairs = [("gap", "2px"), ("flex-grow", "1"),
                                           ("overflow", "hidden")])
  if columns: r.styles(main, [("width", $grid.session & "px"), ("flex-grow", "0"),
                              ("min-width", "0px")])
  let title = r.text(row.title, BodyPx,
                     if sel: selText
                     elif row.titleIsPlaceholder: p.textCaption else: p.textBody,
                     pairs = [lh])
  r.tag(title, "title", row.title)
  let meta = r.box(pairs = [("gap", "6px"), ("items", "center"), ("min-width", "0px")])
  let status = r.text(row.statusLabel, CaptionPx,
                      if sel: selText else: p.statusColour(row.category), shrink = false,
                      pairs = [lh])
  r.tag(status, "status", row.statusLabel)
  r.appendChild(meta, status)
  let metaWords = (if columns: row.metaPartsShort else: row.metaParts).join(Middot)
  let metaText = r.text(metaWords, CaptionPx, if sel: selText else: p.textCaption,
                        pairs = [lh])
  r.tag(metaText, "meta", metaWords)
  r.appendChild(meta, metaText)
  if columns:
    # A wide row's title and meta share a line when both fit at their own
    # widths, 12px apart, and wrap otherwise (`.ah-fleet-row-main`: a
    # wrapping flex row; title and meta `flex: 0 1 auto`).
    let metaPx = textPx(row.statusLabel, CaptionPx) + 6 + textPx(metaWords, CaptionPx)
    r.appendChild(main, r.flowLines([
      FlowItem(el: title, widthPx: textPx(row.title, BodyPx)),
      FlowItem(el: meta, widthPx: metaPx)], grid.session, TitleMetaGapPx, LinePx, 2))
  else:
    r.appendChild(main, title)
    r.appendChild(main, meta)
  if row.failureText.len > 0:
    let failure = r.text(row.failureText, CaptionPx, if sel: selText else: p.textError,
                         pairs = [lh])
    r.tag(failure, "failure", row.failureText)
    r.appendChild(main, failure)
  let shown = if row.expanded: row.activity.len else: min(1, row.activity.len)
  # `.ah-fleet-row-activity`: the activity lines stacked with no gap of
  # their own -- an unfolded row's later lines follow the first directly,
  # 16px apart, not the row's 2px further each.
  let activity = r.box(column = true, pairs = [("min-width", "0px")])
  for i in 0 ..< shown:
    let level = if i < row.activityLevels.len: row.activityLevels[i] else: ""
    let hasChip = i == 0 and row.activity.len + row.activityMore > 1
    # `.ah-fleet-activity-row`: the line and the chip 8px apart.
    let line = r.box(pairs = [("gap", "8px"), ("items", "center"), ("min-width", "0px")])
    if hasChip: r.setStyle(line, "height", $ChipLinePx & "px")
    let t = r.text(row.activity[i], CaptionPx,
                   if sel: selText
                   elif level == "error": p.textError else: p.rowDetail,
                   pairs = [lh])
    r.tag(t, "activity", row.activity[i])
    r.appendChild(line, t)
    if hasChip:
      let hidden = row.activity.len - 1 + row.activityMore
      let label = if row.expanded: "less" else: "+" & $hidden
      # `.ah-fleet-activity-more`: a chip 4px further on, 6px in, the control
      # radius, a 1px border round a 16px caption line. At rest it sits on
      # the tertiary surface with a transparent border; on a selected row it
      # is OUTLINED in the selection's text colour, with no fill
      # (`.ah-fleet-row-selected .ah-fleet-activity-more`).
      let more = r.box(pairs = [("height", $ChipLinePx & "px"), ("items", "center"),
                                ("margin-left", "4px"),
                                ("padding-left", "6px"), ("padding-right", "6px"),
                                ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "0"),
                                ("border-width", "1px"),
                                ("border-color", if sel: selText else: p.tertiary),
                                ("cursor", cursorOf(hkControl))])
      if not sel: r.setStyle(more, "background", p.tertiary)
      r.tag(more, "activity-more", label)
      r.tag(more, "outlined", $sel)
      r.appendChild(more, r.text(label, CaptionPx, if sel: selText else: p.textLabel,
                                 shrink = false, pairs = [lh]))
      r.addEventListener(more, "click", proc() = vm.toggleExpanded(id))
      r.appendChild(line, more)
    r.appendChild(activity, line)
  if shown > 0: r.appendChild(main, activity)
  r.appendChild(result, main)
  if columns:
    let c = if sel: selText else: ""
    r.appendChild(result, r.cell(p, row.agentText, grid.share, "agent", colour = c))
    r.appendChild(result, r.cell(p, row.host, grid.share, "host", colour = c))
    if anyInitiative:
      r.appendChild(result, r.cell(p, row.initiative, grid.share, "initiative",
                                   colour = c))
    r.appendChild(result, r.cell(p, row.durationLabel, DurationColumnPx, "duration", true,
                                 colour = c, tabular = true))
  # The age: the "Active" column (4rem) at a laptop's width; in a narrow
  # panel the row's last grid column, sized to its text (`auto`).
  # `.ah-fleet-row-age`: tabular figures.
  let age = r.text(row.ageLabel, CaptionPx, if sel: selText else: p.textBodySubtle, shrink = false,
                   tabular = true, pairs = [("flex-shrink", "0"), lh])
  r.tag(age, "age", row.ageLabel)
  if columns:
    # The column's end, as `text-align: right` puts it.
    let ageCell = r.box(pairs = [("width", $WideAgeColumnPx & "px"), ("justify", "end"),
                                 ("flex-shrink", "0")])
    r.appendChild(ageCell, age)
    r.appendChild(result, ageCell)
  else:
    r.appendChild(result, age)

proc drawFleetPanel*(r: GpuiRenderer; host: GpuiElement; vm: FleetSnapshotVM;
                     p: AhPalette; widthPx: int) =
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-fleet")
  let ready = vm.state.val == asReady
  r.tag(host, "state", stateName(vm.state.val))
  let header = r.drawSectionHeader(p, "Agent Harbor sessions", vm.sourceLabel,
                                   if ready: vm.headerSummary else: "", widthPx,
                                   caveat = if ready: vm.withheldNote else: "",
                                   narrow = widthPx <= NarrowHeaderPx)
  # The head, as the web's `.ah-fleet-head`: the section header, the filter
  # strip and the column names, one block above the rows.
  let head = r.box(column = true, pairs = [("flex-shrink", "0")])
  r.tag(head, "head", "section header, filters, columns")
  r.appendChild(head, header)
  r.appendChild(host, head)
  let columns = widthPx >= ColumnsFromPx
  let grid = fleetGrid(widthPx, ready and vm.anyInitiative)
  let anyInitiative = ready and vm.anyInitiative
  # The filter strip shows over data only; the column names whenever the
  # panel is wide, loading and failing included (`.ah-fleet-columns`).
  if ready:
    # The filter strip wraps at a narrow width (`.ah-fleet-filters`:
    # `flex-wrap: wrap`, 6px by 8px in, 4px apart).
    let filters = r.box(column = true, pairs = [("padding-top", "6px"),
                                                ("padding-bottom", "6px"),
                                                ("padding-left", $InsetPx & "px"),
                                                ("padding-right", $InsetPx & "px"),
                                                ("flex-shrink", "0")])
    r.rule(filters, p.borderSecondary)
    let counts = vm.counts
    var chips: seq[FlowItem]
    for filter in FleetFilter:
      let n = counts.filterCount(filter)
      chips.add FlowItem(el: r.drawFilter(p, vm, filter, n, filter == vm.filter.val),
                         widthPx: 16 + textPx(filterLabel(filter), CaptionPx) + 6 +
                                  textPx($n, CaptionPx, tabular = true))
    r.appendChild(filters, r.flowLines(chips, max(1, widthPx - 2 * InsetPx), 4,
                                       ControlPx, 4))
    r.appendChild(head, filters)
  if columns:
    # `.ah-fleet-columns`: 24px names, 4px by 8px in, over a hairline.
    let names = r.box(pairs = [("gap", $GridGapPx & "px"), ("items", "center"), ("height", "33px"),
                               ("padding-left", $(InsetPx + MarkPx + GridGapPx) & "px"),
                               ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
    r.rule(names, p.borderSecondary)
    r.tag(names, "columns", "")
    r.appendChild(names, r.cell(p, "Session", grid.session, "session"))
    r.appendChild(names, r.cell(p, "Agent", grid.share, "agent"))
    r.appendChild(names, r.cell(p, "Host", grid.share, "host"))
    if anyInitiative:
      r.appendChild(names, r.cell(p, "Initiative", grid.share, "initiative"))
    r.appendChild(names, r.cell(p, "Duration", DurationColumnPx, "duration", true))
    r.appendChild(names, r.cell(p, "Active", WideAgeColumnPx, "age", true))
    r.appendChild(head, names)
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(host, r.notice(p, AgentHarborFleetLoadingText, "loading"))
  of asError:
    let target = vm
    r.appendChild(host, r.errorBlock(p, "Could not load the sessions", vm.error.val,
                                     proc() = target.load()))
  of asReady:
    let rows = vm.rows
    if rows.len == 0:
      r.appendChild(host, r.notice(p,
        if vm.counts.listed == 0: AgentHarborFleetEmptyText
        else: AgentHarborFleetFilteredEmptyText, "empty"))
    else:
      let list = r.box(column = true, pairs = [("flex-grow", "1"), ("overflow", "hidden")])
      r.tag(list, "rows", "list")
      for row in rows: r.appendChild(list, r.drawRow(p, vm, row, columns, anyInitiative, grid))
      r.appendChild(host, list)

proc mountFleetPanel*(r: GpuiRenderer; host: GpuiElement; vm: FleetSnapshotVM;
                      p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawFleetPanel(r, host, vm, p, widthPx)
