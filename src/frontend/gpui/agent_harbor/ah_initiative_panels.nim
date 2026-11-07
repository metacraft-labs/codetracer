## gpui/agent_harbor/ah_initiative_panels.nim — CTF-P1b. The GPUI views of
## the Initiatives panel (`InitiativesVM`) and the Initiative Progress panel
## (`InitiativeProgressVM`), and the milestone bar both share with the
## initiative tab bar's popup.
##
## The web prototype is `viewmodel/views/isonim_agent_harbor_initiatives_view.nim`:
## a section header (`INITIATIVES`, the source, the summary), then one node
## per initiative -- fold control, state mark, title, `n/m · p%`, the thin
## milestone bar with its counts, the current milestone, repository and
## manager, and its sessions (the first four, `+N more`) -- in alternating
## bands, the selected one on the action surface. The progress panel: the
## headline, the labelled bar, the executive summary and the current
## milestone, then the milestones grouped by status. The words and their
## order are the viewmodels'; the few view texts are the ones the web view
## shares through `viewmodel/views/agent_harbor_words.nim` (`statusCountsText`,
## `milestoneMetaParts` and the notices).

import std/strutils

import isonim/core/[signals, computation]
import nim_agents_isonim_viewmodels/agent_harbor/[initiatives_vm, initiative_progress_vm]
from ../../viewmodel/views/agent_harbor_words import
  statusCountsText, milestoneMetaParts, InitiativeSessionLinesShown,
  InitiativesLoadingText, InitiativesEmptyText, ProgressEmptyText

import ./ah_theme

export initiatives_vm, initiative_progress_vm, ah_theme

const
  MilestoneBarOrder* = [mscCompleted, mscInProgress, mscPartial, mscBlocked,
                        mscPlanned, mscOther]
  BarPx = 6                ## `.ah-ms-bar` height: 0.375rem
  SessionIndentPx = 20     ## `.ah-initiative-sessions` padding-left: 1.25rem
  WidePanelPx = 960        ## `@container ah-initiatives (min-width: 60rem)`
  WideInfoMaxPx = 576      ## the wide row's first column: `minmax(0, 36rem)`
  WideColumnGapPx = 32     ## `column-gap: 2rem`
  MilestoneMetaPx = 352    ## the wide table's counts column, at most 22rem
  LegendGapPx = 10

proc bandOf(p: AhPalette): string =
  ## The even rows' quiet band: `by-mode(secondary-hover, base-card)`.
  if p.mode == dmDark: p.hover else: p.menu

proc drawSectionHeader*(r: GpuiRenderer; p: AhPalette; title, source,
                        summary: string; widthPx: int; caveat = "";
                        narrow = false; sourceBasisPx = -1): GpuiElement =
  ## The VCS panel's section header (`.ah-fleet-section-header`): an
  ## uppercase label, a quieter source taking the free width, the summary
  ## pushed to the right, a caveat after it, over a hairline, 4px by 8px in
  ## and WRAPPING as the web header does when the panel is too narrow for
  ## one line (24px lines, 2px apart). `narrow` is the fleet's own narrow
  ## header (`@container ah-fleet (max-width: 40rem)`): the title and the
  ## summary on the first line, the source and the caveat each on one of
  ## their own, 16px lines.
  result = r.box(column = true, pairs = [("padding-top", "4px"), ("padding-bottom", "4px"),
                                         ("padding-left", $InsetPx & "px"),
                                         ("padding-right", $InsetPx & "px"),
                                         ("flex-shrink", "0")])
  r.rule(result, p.borderSecondary)
  let upper = title.toUpperAscii
  let t = r.text(upper, CaptionPx, p.textBody, bold = true, shrink = false)
  let s = r.text(source, CaptionPx, p.textCaption)
  r.tag(s, "source", source)
  let sm = r.text(summary, CaptionPx, p.textCaption)
  r.tag(sm, "summary", summary)
  # The label is set semibold and spaced; measured in the browser it is a
  # tenth wider than the regular face's metrics say (130, 69 and 159px for
  # the three panels' labels against 118, 63 and 145).
  var items = @[FlowItem(el: t, widthPx: textPx(upper, CaptionPx) * 11 div 10)]
  var cv: GpuiElement
  if caveat.len > 0:
    cv = r.text(caveat, CaptionPx, p.textCaption, pairs = [("font-style", "italic")])
    r.tag(cv, "caveat", caveat)
  if narrow:
    items.add FlowItem(el: sm, widthPx: textPx(summary, CaptionPx), alignEnd: true)
    items.add FlowItem(el: s, widthPx: textPx(source, CaptionPx), grow: true, ownLine: true)
    if cv != nil:
      items.add FlowItem(el: cv, widthPx: textPx(caveat, CaptionPx), ownLine: true)
  else:
    # The source's flex basis: its text, or (the progress panel's, `flex: 1 1
    # 8rem`) a fixed one, which is what decides whether it wraps.
    items.add FlowItem(el: s, widthPx: if sourceBasisPx >= 0: sourceBasisPx
                                       else: textPx(source, CaptionPx), grow: true)
    items.add FlowItem(el: sm, widthPx: textPx(summary, CaptionPx), alignEnd: true)
    if cv != nil: items.add FlowItem(el: cv, widthPx: textPx(caveat, CaptionPx))
  r.appendChild(result, r.flowLines(items, max(1, widthPx - 2 * InsetPx), 8,
                                    if narrow: 16 else: 24, if narrow: 0 else: 2))

proc drawMilestoneBar*(r: GpuiRenderer; p: AhPalette;
                       counts: array[MilestoneStatusClass, int];
                       labelled: bool): GpuiElement =
  ## Progress at a glance: one thin bar split by status, done first, each
  ## segment its share; the counts with their marks beside it (a row of the
  ## Initiatives panel) or, `labelled`, named on a line under it.
  result = r.box(column = labelled, pairs = [("gap", if labelled: "4px" else: "12px"),
                                             ("items", if labelled: "stretch" else: "center")])
  r.tag(result, "milestone-bar", statusCountsText(counts))
  let bar = r.box(pairs = [("height", $BarPx & "px"), ("flex-grow", "1"),
                           ("rounded", "3px"), ("overflow", "hidden"), ("gap", "1px")])
  if not labelled: r.setStyle(bar, "max-width", "580px")
  let legend = r.box(pairs = [("gap", $LegendGapPx & "px"), ("items", "center"),
                              ("flex-shrink", "0")])
  for status in MilestoneBarOrder:
    let n = counts[status]
    if n == 0: continue
    let seg = r.box(pairs = [("flex-grow", $n), ("height", $BarPx & "px"),
                             ("min-width", "2px"), ("background", p.segmentOf(status))])
    r.tag(seg, "segment", $status & ":" & $n)
    r.appendChild(bar, seg)
    let item = r.box(pairs = [("gap", "4px"), ("items", "center")])
    r.appendChild(item, r.mark(p.markOf(status)))
    r.appendChild(item, r.text($n & (if labelled: " " & $status else: ""), CaptionPx,
                               p.textLabel, shrink = false))
    r.appendChild(legend, item)
  r.appendChild(result, bar)
  r.appendChild(result, legend)

proc drawCurrent*(r: GpuiRenderer; p: AhPalette; text: string; colour = ""): GpuiElement =
  ## `CURRENT  RC-M2: Core change`.
  result = r.box(pairs = [("gap", "8px"), ("items", "center")])
  r.tag(result, "current", text)
  r.appendChild(result, r.text("CURRENT", CaptionPx - 1,
                               if colour.len > 0: colour else: p.textLabel,
                               bold = true, shrink = false))
  r.appendChild(result, r.text(text, CaptionPx,
                               if colour.len > 0: colour else: p.textBody))

proc drawSessionLine*(r: GpuiRenderer; p: AhPalette; item: SessionItem;
                      onAction = false): GpuiElement =
  ## A session under an initiative: mark, title, its status at the right.
  result = r.box(pairs = [("gap", "8px"), ("items", "center"), ("height", "19px")])
  r.tag(result, "session", item.id)
  r.tag(result, "attention", $item.attention)
  r.tag(result, "tooltip", item.tooltip)
  r.appendChild(result, r.mark(p.markOf(item.attention)))
  let title = r.text(item.title, BodyPx - 1, if onAction: p.onAction else: p.textBody,
                     pairs = [("flex-grow", "1")])
  r.tag(title, "title", item.title)
  r.appendChild(result, title)
  let status = r.text(item.statusLabel, CaptionPx,
                      if onAction: p.onAction else: p.statusWordColour(item.attention),
                      shrink = false)
  r.tag(status, "status", item.statusLabel)
  r.appendChild(result, status)

# ---------------------------------------------------------------------------
# Initiatives
# ---------------------------------------------------------------------------

proc drawInitiativeRow(r: GpuiRenderer; p: AhPalette; vm: InitiativesVM;
                       row: InitiativeRow; index: int; widthPx: int): GpuiElement =
  let id = row.id
  let selected = row.selected
  # The selected initiative keeps its words' colours -- status words
  # included -- over a tint, with a 3px bar in the action role down its
  # left edge (`.ah-initiative-row-selected`: Dark a 28% action tint, Light
  # the secondary-hover surface).
  let fg = p.textBody
  let quiet = p.textCaption
  result = r.box(column = true, pairs = [("gap", "6px"), ("padding-top", "10px"),
                                         ("padding-bottom", "10px"),
                                         ("padding-left", $InsetPx & "px"),
                                         ("padding-right", $InsetPx & "px"),
                                         ("cursor", "pointer"), ("flex-shrink", "0")])
  if selected:
    r.styles(result, [("background", p.selectedTint), ("position", "relative")])
    r.appendChild(result, r.insetBar(p.borderAction, 3))
  elif index mod 2 == 1: r.setStyle(result, "background", p.bandOf)
  r.tag(result, "initiative", id)
  r.tag(result, "state", $row.state)
  r.tag(result, "selected", $selected)
  r.tag(result, "folded", $row.folded)
  r.addEventListener(result, "click", proc() = vm.select(id))
  let head = r.box(pairs = [("gap", "8px"), ("items", "center")])
  let fold = r.text(if row.folded: "\xE2\x96\xB8" else: "\xE2\x96\xBE", CaptionPx, quiet,
                    shrink = false, pairs = [("cursor", "pointer")])
  r.tag(fold, "fold", id)
  r.addEventListener(fold, "click", proc() = vm.toggleFolded(id))
  r.appendChild(head, fold)
  r.appendChild(head, r.mark(p.markOf(row.state)))
  let title = r.text(row.title, BodyPx, fg, bold = true, pairs = [("flex-grow", "1")])
  r.tag(title, "title", row.title)
  r.appendChild(head, title)
  let progress = r.text(row.progressText, CaptionPx, quiet, shrink = false)
  r.tag(progress, "progress", row.progressText)
  r.appendChild(head, progress)
  # A wide panel (`@container ah-initiatives (min-width: 60rem)`): each
  # initiative one row across the width -- what it is and how far it got in
  # a column on the left (at most 36rem), its sessions on the right, 2rem
  # apart. Narrower, one column, the sessions indented under it.
  let wide = widthPx >= WidePanelPx
  var info = result
  if wide:
    r.styles(result, [("flex-direction", "row"), ("gap", $WideColumnGapPx & "px"),
                      ("items", "start")])
    info = r.box(column = true, pairs = [("gap", "6px"), ("flex-shrink", "0"),
      ("width", $min(WideInfoMaxPx, (widthPx - 2 * InsetPx - WideColumnGapPx) div 2) & "px")])
    r.appendChild(result, info)
  r.appendChild(info, head)
  r.appendChild(info, r.drawMilestoneBar(p, row.statusCounts, labelled = false))
  if row.currentMilestone.len > 0:
    r.appendChild(info, r.drawCurrent(p, row.currentMilestone, ""))
  var meta: seq[string]
  if row.repository.len > 0: meta.add row.repository
  if row.manager.len > 0: meta.add "manager " & row.manager
  if meta.len > 0:
    let m = r.text(meta.join(Middot), CaptionPx, quiet)
    r.tag(m, "meta", meta.join(Middot))
    r.appendChild(info, m)
  if not row.folded:
    let sessions = r.box(column = true, pairs = [("padding-left", (if wide: "0" else: $SessionIndentPx) & "px"),
                                                 ("gap", "0px")])
    let shown = if row.expanded: row.sessions.len
                else: min(row.sessions.len, InitiativeSessionLinesShown)
    for i in 0 ..< shown:
      r.appendChild(sessions, r.drawSessionLine(p, row.sessions[i]))
    let hidden = row.sessions.len - shown
    if hidden > 0 or row.expanded and row.sessions.len > InitiativeSessionLinesShown:
      let label = if row.expanded: "Show fewer" else: "+" & $hidden & " more"
      let more = r.text(label, CaptionPx, quiet, shrink = false,
                        pairs = [("cursor", "pointer"), ("margin-top", "2px")])
      r.tag(more, "more", label)
      r.addEventListener(more, "click", proc() = vm.toggleExpanded(id))
      r.appendChild(sessions, more)
    if row.sessions.len == 0:
      let label = if row.missingSessions == 0: "No session is working on it"
                  else: $row.missingSessions &
                    (if row.missingSessions == 1: " session" else: " sessions") &
                    " on other servers"
      let tail = r.text(label, CaptionPx, quiet, pairs = [("font-style", "italic")])
      r.tag(tail, "more", label)
      r.appendChild(sessions, tail)
    if wide: r.setStyle(sessions, "flex-grow", "1")
    r.appendChild(result, sessions)

proc drawInitiativesPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativesVM;
                           p: AhPalette; widthPx: int) =
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-initiatives")
  r.tag(host, "state", stateName(vm.state.val))
  let head = r.drawSectionHeader(p, "Initiatives", vm.sourceLabel,
    if vm.state.val == asReady: vm.summaryText else: "", widthPx)
  r.tag(head, "head", "section header")
  r.appendChild(host, head)
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(host, r.notice(p, InitiativesLoadingText, "loading"))
  of asError:
    let target = vm
    r.appendChild(host, r.errorBlock(p, "Could not load the initiatives", vm.error.val,
                                     proc() = target.load()))
  of asReady:
    let rows = vm.rows
    if rows.len == 0:
      r.appendChild(host, r.notice(p, InitiativesEmptyText, "empty"))
    else:
      let list = r.box(column = true, pairs = [("flex-grow", "1"), ("overflow", "hidden")])
      r.tag(list, "rows", "list")
      for i, row in rows: r.appendChild(list, r.drawInitiativeRow(p, vm, row, i, widthPx))
      r.appendChild(host, list)

proc mountInitiativesPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativesVM;
                            p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawInitiativesPanel(r, host, vm, p, widthPx)

# ---------------------------------------------------------------------------
# Initiative Progress
# ---------------------------------------------------------------------------

proc drawMilestone(r: GpuiRenderer; p: AhPalette; m: MilestoneLine;
                   index: int; wide: bool): GpuiElement =
  result = r.box(pairs = [("gap", "8px"), ("items", "start"), ("padding-top", "6px"),
                          ("padding-bottom", "6px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
  if m.current: r.setStyle(result, "background",
                           if p.mode == dmDark: p.tertiary else: p.hover)
  elif index mod 2 == 1: r.setStyle(result, "background", p.bandOf)
  r.tag(result, "milestone", m.id)
  r.tag(result, "status-class", $m.statusClass)
  r.tag(result, "current", $m.current)
  let markHolder = r.box(pairs = [("height", "20px"), ("items", "center")])
  r.appendChild(markHolder, r.mark(p.markOf(m.statusClass)))
  r.appendChild(result, markHolder)
  let main = r.box(column = true, pairs = [("flex-grow", "1"), ("gap", "1px")])
  let title = r.box(pairs = [("gap", "8px"), ("items", "center")])
  r.appendChild(title, r.text(m.id, BodyPx, p.textLabel, shrink = false,
                              pairs = [("width", "72px")]))
  let name = r.text(m.title, BodyPx, p.textBody)
  r.tag(name, "title", m.title)
  r.appendChild(title, name)
  r.appendChild(main, title)
  if wide:
    # A wide panel lists the milestones as a table
    # (`.ah-milestone`: `AH_MARK minmax(0, 1fr) minmax(14rem, 22rem)`): the
    # title takes the width, its counts a right-aligned column on the same
    # line.
    r.styles(main, [("flex-direction", "row"), ("items", "center"), ("gap", "24px")])
    r.setStyle(title, "flex-grow", "1")
    r.setStyle(title, "min-width", "0px")
  let parts = milestoneMetaParts(m)
  let meta = r.box(pairs = [("gap", "6px"), ("items", "center")])
  if m.current:
    r.appendChild(meta, r.text("CURRENT", CaptionPx - 1, p.textLabel, bold = true,
                               shrink = false))
  let metaRun = r.box(pairs = [("items", "center")])
  r.tag(metaRun, "meta", parts.before & parts.failing & parts.after)
  r.appendChild(metaRun, r.text(parts.before, CaptionPx, p.textCaption, shrink = false))
  if parts.failing.len > 0:
    r.appendChild(metaRun, r.text(parts.failing, CaptionPx, p.textError, shrink = false))
    r.appendChild(metaRun, r.text(parts.after, CaptionPx, p.textCaption, shrink = false))
  r.appendChild(meta, metaRun)
  if wide:
    r.styles(meta, [("width", $MilestoneMetaPx & "px"), ("flex-shrink", "0"),
                    ("justify", "end")])
  r.appendChild(main, meta)
  r.appendChild(result, main)

proc drawProgressPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativeProgressVM;
                        p: AhPalette; widthPx: int) =
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-initiative-progress")
  let ready = vm.state.val == asReady and vm.found
  r.tag(host, "state", if vm.state.val == asReady and not vm.found: "empty"
                       else: stateName(vm.state.val))
  let initiative = vm.current
  let head = r.drawSectionHeader(p, "Initiative progress",
    if ready: initiative.title else: "", if ready: vm.headline else: "", widthPx,
    sourceBasisPx = 128)
  r.tag(head, "head", "section header")
  r.appendChild(host, head)
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(host, r.notice(p, InitiativesLoadingText, "loading"))
  of asError:
    let target = vm
    r.appendChild(host, r.errorBlock(p, "Could not load the initiative", vm.error.val,
                                     proc() = target.load()))
  of asReady:
    if not vm.found:
      r.appendChild(host, r.notice(p, ProgressEmptyText, "empty"))
      return
    let list = r.box(column = true, pairs = [("flex-grow", "1"), ("overflow", "hidden")])
    r.tag(list, "rows", "list")
    let summaryBlock = r.box(column = true, pairs = [("gap", "8px"), ("padding", "8px"),
                                                     ("flex-shrink", "0")])
    r.rule(summaryBlock, p.borderSecondary)
    r.appendChild(summaryBlock, r.drawMilestoneBar(p, vm.statusCounts, labelled = true))
    let summaryText = if initiative.executiveSummary.len > 0: initiative.executiveSummary
                      else: "The plan states no executive summary."
    let summary = r.text(summaryText, BodyPx,
                         if initiative.executiveSummary.len > 0: p.textBody else: p.textCaption,
                         shrink = false, pairs = [("white-space", "normal")])
    if initiative.executiveSummary.len == 0: r.setStyle(summary, "font-style", "italic")
    r.tag(summary, "executive-summary", summaryText)
    r.appendChild(summaryBlock, summary)
    let current = currentMilestoneText(initiative.progress)
    if current.len > 0: r.appendChild(summaryBlock, r.drawCurrent(p, current))
    r.appendChild(list, summaryBlock)
    for group in vm.groups:
      let header = r.box(pairs = [("gap", "6px"), ("items", "center"), ("height", "28px"),
                                  ("padding-left", $InsetPx & "px"), ("flex-shrink", "0")])
      r.rule(header, p.borderSecondary)
      r.tag(header, "group", group.name)
      r.appendChild(header, r.text(group.name.toUpperAscii, CaptionPx, p.textBody,
                                   bold = true, shrink = false))
      r.appendChild(header, r.text("(" & $group.count & ")", CaptionPx, p.textCaption,
                                   shrink = false))
      r.appendChild(list, header)
      for i, m in group.milestones:
        r.appendChild(list, r.drawMilestone(p, m, i, widthPx >= WidePanelPx))
    r.appendChild(host, list)

proc mountProgressPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativeProgressVM;
                         p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawProgressPanel(r, host, vm, p, widthPx)
