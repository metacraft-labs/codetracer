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
  BarPx = 4
  SessionIndentPx = 20     ## `.ah-initiative-sessions` padding-left: 1.25rem
  LegendGapPx = 10

proc bandOf(p: AhPalette): string =
  ## The even rows' quiet band: `by-mode(secondary-hover, base-card)`.
  if p.mode == dmDark: p.hover else: p.menu

proc drawSectionHeader*(r: GpuiRenderer; p: AhPalette; title, source,
                        summary: string): GpuiElement =
  ## The VCS panel's section header: an uppercase label, a quieter source,
  ## the summary at the right, over a hairline.
  result = r.box(pairs = [("items", "center"), ("gap", "8px"), ("min-height", "28px"),
                          ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
  r.rule(result, p.borderSecondary)
  r.appendChild(result, r.text(title.toUpperAscii, CaptionPx, p.textBody, bold = true,
                               shrink = false))
  let s = r.text(source, CaptionPx, p.textCaption, pairs = [("flex-grow", "1")])
  r.tag(s, "source", source)
  r.appendChild(result, s)
  let sm = r.text(summary, CaptionPx, p.textCaption, shrink = false)
  r.tag(sm, "summary", summary)
  r.appendChild(result, sm)

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
                       row: InitiativeRow; index: int): GpuiElement =
  let id = row.id
  let selected = row.selected
  let fg = if selected: p.onAction else: p.textBody
  let quiet = if selected: p.onAction else: p.textCaption
  result = r.box(column = true, pairs = [("gap", "6px"), ("padding-top", "10px"),
                                         ("padding-bottom", "10px"),
                                         ("padding-left", $InsetPx & "px"),
                                         ("padding-right", $InsetPx & "px"),
                                         ("cursor", "pointer"), ("flex-shrink", "0")])
  if selected: r.setStyle(result, "background", p.action)
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
  r.appendChild(result, head)
  r.appendChild(result, r.drawMilestoneBar(p, row.statusCounts, labelled = false))
  if row.currentMilestone.len > 0:
    r.appendChild(result, r.drawCurrent(p, row.currentMilestone,
                                        if selected: p.onAction else: ""))
  var meta: seq[string]
  if row.repository.len > 0: meta.add row.repository
  if row.manager.len > 0: meta.add "manager " & row.manager
  if meta.len > 0:
    let m = r.text(meta.join(Middot), CaptionPx, quiet)
    r.tag(m, "meta", meta.join(Middot))
    r.appendChild(result, m)
  if not row.folded:
    let sessions = r.box(column = true, pairs = [("padding-left", $SessionIndentPx & "px"),
                                                 ("gap", "0px")])
    let shown = if row.expanded: row.sessions.len
                else: min(row.sessions.len, InitiativeSessionLinesShown)
    for i in 0 ..< shown:
      r.appendChild(sessions, r.drawSessionLine(p, row.sessions[i], selected))
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
    r.appendChild(result, sessions)

proc drawInitiativesPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativesVM;
                           p: AhPalette; widthPx: int) =
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-initiatives")
  r.tag(host, "state", stateName(vm.state.val))
  r.appendChild(host, r.drawSectionHeader(p, "Initiatives", vm.sourceLabel,
    if vm.state.val == asReady: vm.summaryText else: ""))
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
      for i, row in rows: r.appendChild(list, r.drawInitiativeRow(p, vm, row, i))
      r.appendChild(host, list)

proc mountInitiativesPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativesVM;
                            p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawInitiativesPanel(r, host, vm, p, widthPx)

# ---------------------------------------------------------------------------
# Initiative Progress
# ---------------------------------------------------------------------------

proc drawMilestone(r: GpuiRenderer; p: AhPalette; m: MilestoneLine;
                   index: int): GpuiElement =
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
  r.appendChild(host, r.drawSectionHeader(p, "Initiative progress",
    if ready: initiative.title else: "", if ready: vm.headline else: ""))
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
      for i, m in group.milestones: r.appendChild(list, r.drawMilestone(p, m, i))
    r.appendChild(host, list)

proc mountProgressPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativeProgressVM;
                         p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawProgressPanel(r, host, vm, p, widthPx)
