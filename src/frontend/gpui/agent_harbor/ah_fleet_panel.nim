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

import std/strutils

import isonim/core/[signals, computation]
import nim_agents_isonim_viewmodels/agent_harbor/fleet_vm
from ../../viewmodel/views/agent_harbor_words import
  filterLabel, filterCount, metaParts, metaPartsShort, withheldNote, headerSummary,
  AgentHarborFleetLoadingText, AgentHarborFleetEmptyText,
  AgentHarborFleetFilteredEmptyText

import ./ah_theme
import ./ah_initiative_panels

export fleet_vm, ah_theme

const
  ColumnsFromPx = 960        ## `@container ah-fleet (min-width: 60rem)`
  TitleColumnPx = 512        ## 32rem
  AgentColumnPx = 144        ## 9rem
  HostColumnPx = 112         ## 7rem
  InitiativeColumnPx = 192   ## 12rem
  DurationColumnPx = 80      ## 5rem
  AgeColumnPx = 48           ## 3rem

proc markOf(p: AhPalette; category: FleetCategory): MarkStyle =
  ## The row's status dot (`.ah-fleet-cat-*`), in the sessions' status roles.
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
  else: p.textCaption

proc agentText(row: FleetRow): string =
  if row.agentCount > 1: row.agentLabel & " \xC3\x97" & $row.agentCount else: row.agentLabel

proc drawFilter(r: GpuiRenderer; p: AhPalette; vm: FleetSnapshotVM; filter: FleetFilter;
                count: int; active: bool): GpuiElement =
  let chosen = filter
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"), ("gap", "6px"),
                          ("padding-left", "8px"), ("padding-right", "8px"),
                          ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "0"),
                          ("cursor", "pointer")])
  if active: r.setStyle(result, "background", p.hover)
  r.tag(result, "filter", $filter)
  r.tag(result, "filter-count", $count)
  r.tag(result, "active", $active)
  r.appendChild(result, r.text(filterLabel(filter), CaptionPx,
                               if active: p.textBody else: p.textLabel, shrink = false))
  r.appendChild(result, r.text($count, CaptionPx,
                               if count == 0: p.textDisabled
                               elif active: p.textBody else: p.textCaption, shrink = false))
  r.addEventListener(result, "click", proc() = vm.setFilter(chosen))

proc cell(r: GpuiRenderer; p: AhPalette; s: string; widthPx: int; name: string;
          right = false): GpuiElement =
  result = r.text(s, CaptionPx, p.textLabel, pairs = [("width", $widthPx & "px"),
                                                     ("min-width", $widthPx & "px")])
  if right: r.setStyle(result, "text-align", "right")
  r.tag(result, "col", name)

proc drawRow(r: GpuiRenderer; p: AhPalette; vm: FleetSnapshotVM; row: FleetRow;
             columns, anyInitiative: bool): GpuiElement =
  let id = row.id
  result = r.box(pairs = [("gap", "8px"), ("items", "start"), ("padding-top", "6px"),
                          ("padding-bottom", "6px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                          ("cursor", "pointer")])
  r.rule(result, p.borderSecondary)
  if row.selected: r.setStyle(result, "background", p.hover)
  r.tag(result, "row", id)
  r.tag(result, "category", $row.category)
  r.tag(result, "selected", $row.selected)
  r.tag(result, "expanded", $row.expanded)
  r.addEventListener(result, "click", proc() = vm.select(id))
  let markHolder = r.box(pairs = [("height", "20px"), ("items", "center")])
  r.appendChild(markHolder, r.mark(p.markOf(row.category)))
  r.appendChild(result, markHolder)
  let main = r.box(column = true, pairs = [("gap", "2px"), ("flex-grow", "1"),
                                           ("overflow", "hidden")])
  if columns: r.styles(main, [("width", $TitleColumnPx & "px"), ("flex-grow", "0"),
                              ("min-width", "0px")])
  let title = r.text(row.title, BodyPx,
                     if row.titleIsPlaceholder: p.textCaption else: p.textBody)
  r.tag(title, "title", row.title)
  r.appendChild(main, title)
  let meta = r.box(pairs = [("gap", "6px"), ("items", "center")])
  let status = r.text(row.statusLabel, CaptionPx, p.statusColour(row.category), shrink = false)
  r.tag(status, "status", row.statusLabel)
  r.appendChild(meta, status)
  let metaWords = (if columns: row.metaPartsShort else: row.metaParts).join(Middot)
  let metaText = r.text(metaWords, CaptionPx, p.textCaption)
  r.tag(metaText, "meta", metaWords)
  r.appendChild(meta, metaText)
  r.appendChild(main, meta)
  if row.failureText.len > 0:
    let failure = r.text(row.failureText, CaptionPx, p.textError)
    r.tag(failure, "failure", row.failureText)
    r.appendChild(main, failure)
  let shown = if row.expanded: row.activity.len else: min(1, row.activity.len)
  for i in 0 ..< shown:
    let level = if i < row.activityLevels.len: row.activityLevels[i] else: ""
    let line = r.box(pairs = [("gap", "6px"), ("items", "center")])
    let t = r.text(row.activity[i], CaptionPx,
                   if level == "error": p.textError else: p.textLabel)
    r.tag(t, "activity", row.activity[i])
    r.appendChild(line, t)
    if i == 0 and row.activity.len + row.activityMore > 1:
      let hidden = row.activity.len - 1 + row.activityMore
      let label = if row.expanded: "less" else: "+" & $hidden
      let more = r.box(pairs = [("height", "16px"), ("items", "center"),
                                ("padding-left", "6px"), ("padding-right", "6px"),
                                ("rounded", "4px"), ("background", p.tertiary),
                                ("flex-shrink", "0"), ("cursor", "pointer")])
      r.tag(more, "activity-more", label)
      r.appendChild(more, r.text(label, CaptionPx - 1, p.textLabel, shrink = false))
      r.addEventListener(more, "click", proc() = vm.toggleExpanded(id))
      r.appendChild(line, more)
    r.appendChild(main, line)
  r.appendChild(result, main)
  if columns:
    r.appendChild(result, r.cell(p, row.agentText, AgentColumnPx, "agent"))
    r.appendChild(result, r.cell(p, row.host, HostColumnPx, "host"))
    if anyInitiative:
      r.appendChild(result, r.cell(p, row.initiative, InitiativeColumnPx, "initiative"))
    r.appendChild(result, r.cell(p, row.durationLabel, DurationColumnPx, "duration", true))
  let age = r.text(row.ageLabel, CaptionPx, p.textCaption, shrink = false,
                   pairs = [("width", $AgeColumnPx & "px"), ("text-align", "right")])
  r.tag(age, "age", row.ageLabel)
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
                                   if ready: vm.headerSummary else: "")
  if ready and vm.withheldNote.len > 0:
    let caveat = r.text(vm.withheldNote, CaptionPx, p.textCaption, shrink = false,
                        pairs = [("font-style", "italic")])
    r.tag(caveat, "caveat", vm.withheldNote)
    r.insertBefore(header, caveat, nthChild(header, childCount(header) - 1))
  r.appendChild(host, header)
  let columns = widthPx >= ColumnsFromPx
  let anyInitiative = ready and vm.anyInitiative
  if ready:
    let filters = r.box(pairs = [("gap", "4px"), ("items", "center"), ("padding-top", "6px"),
                                 ("padding-bottom", "6px"), ("padding-left", $InsetPx & "px"),
                                 ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
    r.rule(filters, p.borderSecondary)
    let counts = vm.counts
    for filter in FleetFilter:
      r.appendChild(filters, r.drawFilter(p, vm, filter, counts.filterCount(filter),
                                          filter == vm.filter.val))
    r.appendChild(host, filters)
    if columns:
      let names = r.box(pairs = [("gap", "8px"), ("items", "center"), ("height", "22px"),
                                 ("padding-left", $(InsetPx + MarkPx + 8) & "px"),
                                 ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
      r.rule(names, p.borderSecondary)
      r.tag(names, "columns", "")
      r.appendChild(names, r.cell(p, "Session", TitleColumnPx, "session"))
      r.appendChild(names, r.cell(p, "Agent", AgentColumnPx, "agent"))
      r.appendChild(names, r.cell(p, "Host", HostColumnPx, "host"))
      if anyInitiative:
        r.appendChild(names, r.cell(p, "Initiative", InitiativeColumnPx, "initiative"))
      r.appendChild(names, r.cell(p, "Duration", DurationColumnPx, "duration", true))
      r.appendChild(names, r.cell(p, "Active", AgeColumnPx, "age", true))
      r.appendChild(host, names)
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
      for row in rows: r.appendChild(list, r.drawRow(p, vm, row, columns, anyInitiative))
      r.appendChild(host, list)

proc mountFleetPanel*(r: GpuiRenderer; host: GpuiElement; vm: FleetSnapshotVM;
                      p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawFleetPanel(r, host, vm, p, widthPx)
