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

import ../../../common/pointer_shape
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
  LegendPx = 14            ## the counts beside a bar: `.ah-ms-legend`, 14px high
  LinePx = 16              ## `type-ui-lineheight-body-sm` / `-caption-md`
  HeadLinePx = 24          ## an initiative's head line (its fold and counts inherit 24px)
  SessionLinePx = 18       ## a session line: 16px and 1px above and below
  MarkGapWidePx = 24       ## a wide milestone table's column gap
  MilestoneIdPx = 72       ## `.ah-milestone-id` min-width: 4.5rem
  MilestoneIdNarrowPx = 56 ## at most 30rem wide: 3.5rem
  NarrowProgressPx = 480   ## `@container ah-initiatives (max-width: 30rem)`

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
    # Upright, as the web sets it (`.ah-fleet-caveat`: "Plain, not italic").
    cv = r.text(caveat, CaptionPx, p.textCaption)
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
    if cv != nil:
      # After the count, set off by a dot 8px before it (`.ah-fleet-caveat
      # ::before`, `content: "\00B7"`); the narrow header drops the dot.
      let withDot = r.box(pairs = [("gap", "8px"), ("items", "center"), ("min-width", "0px")])
      r.appendChild(withDot, r.text("\xC2\xB7", CaptionPx, p.textCaption, shrink = false))
      r.appendChild(withDot, cv)
      items.add FlowItem(el: withDot,
                         widthPx: textPx("\xC2\xB7", CaptionPx) + 8 + textPx(caveat, CaptionPx))
  r.appendChild(result, r.flowLines(items, max(1, widthPx - 2 * InsetPx), 8,
                                    if narrow: 16 else: 24, if narrow: 0 else: 2))

proc drawMilestoneBar*(r: GpuiRenderer; p: AhPalette;
                       counts: array[MilestoneStatusClass, int];
                       labelled: bool; availPx = 0): GpuiElement =
  ## Progress at a glance: one thin bar split by status, done first, each
  ## segment its share; the counts with their marks beside it (a row of the
  ## Initiatives panel) or, `labelled`, named under it -- WRAPPING onto more
  ## lines, 10px apart, when they do not fit in `availPx` (`.ah-ms-labelled
  ## .ah-ms-legend`: `flex-wrap: wrap`, `gap: 10px`, 14px lines).
  # `.ah-ms-progress`: the bar and its legend 12px apart on one line, or,
  # labelled, 6px apart one above the other.
  result = r.box(column = labelled, pairs = [("gap", if labelled: "6px" else: "12px"),
                                             ("items", if labelled: "stretch" else: "center")])
  r.tag(result, "milestone-bar", statusCountsText(counts))
  let bar = r.box(pairs = [("height", $BarPx & "px"), ("flex-grow", "1"),
                           ("rounded", "3px"), ("overflow", "hidden"), ("gap", "1px")])
  if not labelled: r.setStyle(bar, "max-width", "580px")
  let legend = r.box(pairs = [("gap", $LegendGapPx & "px"), ("items", "center"),
                              ("height", $LegendPx & "px"), ("flex-shrink", "0")])
  var flow: seq[FlowItem]
  for status in MilestoneBarOrder:
    let n = counts[status]
    if n == 0: continue
    let seg = r.box(pairs = [("flex-grow", $n), ("height", $BarPx & "px"),
                             ("min-width", "2px"), ("background", p.segmentOf(status))])
    r.tag(seg, "segment", $status & ":" & $n)
    r.appendChild(bar, seg)
    let item = r.box(pairs = [("gap", "4px"), ("items", "center"), ("flex-shrink", "0")])
    let words = $n & (if labelled: " " & $status else: "")
    r.appendChild(item, r.mark(p.markOf(status)))
    r.appendChild(item, r.text(words, CaptionPx, p.textLabel, shrink = false,
                               pairs = [("line-height", $LegendPx & "px")]))
    if labelled and availPx > 0:
      flow.add FlowItem(el: item, widthPx: MarkPx + 4 + textPx(words, CaptionPx),
                        exactPx: float(MarkPx + 4) + textWidth(words, CaptionPx))
    else:
      r.appendChild(legend, item)
  r.appendChild(result, bar)
  if flow.len > 0:
    r.appendChild(result, r.flowLines(flow, availPx, LegendGapPx, LegendPx, LegendGapPx))
  else:
    r.appendChild(result, legend)

proc drawCurrent*(r: GpuiRenderer; p: AhPalette; text: string; colour = ""): GpuiElement =
  ## `CURRENT  RC-M2: Core change`.
  # `.ah-initiative-current`: one 16px caption line; the label semibold at
  # the caption size (`.ah-initiative-label`), the milestone in the body
  # colour.
  let lh = ("line-height", $LinePx & "px")
  result = r.box(pairs = [("gap", "8px"), ("items", "center"), ("height", $LinePx & "px")])
  r.tag(result, "current", text)
  r.appendChild(result, r.text("CURRENT", CaptionPx,
                               if colour.len > 0: colour else: p.textLabel,
                               bold = true, shrink = false, pairs = [lh]))
  r.appendChild(result, r.text(text, CaptionPx,
                               if colour.len > 0: colour else: p.textBody, pairs = [lh]))

proc sessionStatusColour(p: AhPalette; attention: SessionAttention): string =
  ## A session line's status word (`.ah-initiative-session-status`): the
  ## label role, or the status's own text role for needs input, running and
  ## failed -- so "completed", "idle" and "queued" read in the label role.
  case attention
  of saNeedsInput: p.textWarning
  of saRunning: p.textSuccess
  of saFailed: p.textError
  else: p.textLabel

proc drawSessionLine*(r: GpuiRenderer; p: AhPalette; item: SessionItem;
                      onAction = false): GpuiElement =
  ## A session under an initiative (the Initiatives panel and the hover
  ## popup alike): mark, title, its status at the right. The title at the
  ## session list's row-title size (`.ah-initiative-session`: 14px on a 16px
  ## line, 1px above and below).
  result = r.box(pairs = [("gap", "8px"), ("items", "center"),
                          ("height", $SessionLinePx & "px"), ("flex-shrink", "0")])
  r.tag(result, "session", item.id)
  r.tag(result, "attention", $item.attention)
  r.tag(result, "tooltip", item.tooltip)
  r.appendChild(result, r.mark(p.markOf(item.attention)))
  let title = r.text(item.title, BodyPx, if onAction: p.onAction else: p.textBody,
                     pairs = [("flex-grow", "1"), ("line-height", $LinePx & "px")])
  r.tag(title, "title", item.title)
  r.appendChild(result, title)
  let status = r.text(item.statusLabel, CaptionPx,
                      if onAction: p.onAction else: p.sessionStatusColour(item.attention),
                      shrink = false, pairs = [("line-height", $LinePx & "px")])
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
                                         ("cursor", cursorOf(hkControl)), ("flex-shrink", "0")])
  if selected:
    r.styles(result, [("background", p.selectedTint), ("position", "relative")])
    r.appendChild(result, r.insetBar(p.borderAction, 3))
  elif index mod 2 == 1: r.setStyle(result, "background", p.bandOf)
  r.tag(result, "initiative", id)
  r.tag(result, "state", $row.state)
  r.tag(result, "selected", $selected)
  r.tag(result, "folded", $row.folded)
  r.addEventListener(result, "click", proc() = vm.select(id))
  # `.ah-initiative-head`: a 24px line -- the fold control (12px wide) and
  # the counts in the label role, the title semibold on a 16px line.
  let head = r.box(pairs = [("gap", "8px"), ("items", "center"),
                            ("height", $HeadLinePx & "px")])
  let fold = r.text(if row.folded: "\xE2\x96\xB8" else: "\xE2\x96\xBE", CaptionPx, p.textLabel,
                    shrink = false, pairs = [("cursor", cursorOf(hkControl)), ("width", "12px")])
  r.tag(fold, "fold", id)
  r.addEventListener(fold, "click", proc() = vm.toggleFolded(id))
  r.appendChild(head, fold)
  r.appendChild(head, r.mark(p.markOf(row.state)))
  let title = r.text(row.title, BodyPx, fg, bold = true,
                     pairs = [("flex-grow", "1"), ("line-height", $LinePx & "px")])
  r.tag(title, "title", row.title)
  r.appendChild(head, title)
  let progress = r.text(row.progressText, CaptionPx, p.textLabel, shrink = false)
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
    let m = r.text(meta.join(Middot), CaptionPx, quiet, pairs = [("line-height", $LinePx & "px")])
    r.tag(m, "meta", meta.join(Middot))
    r.appendChild(info, m)
  if not row.folded:
    # `.ah-initiative-sessions`: indented 20px -- in the wide row's second
    # column too -- 2px below the meta line, its lines 1px apart.
    let sessions = r.box(column = true, pairs = [("padding-left", $SessionIndentPx & "px"),
                                                 ("gap", "1px"), ("margin-top", "2px")])
    let shown = if row.expanded: row.sessions.len
                else: min(row.sessions.len, InitiativeSessionLinesShown)
    for i in 0 ..< shown:
      r.appendChild(sessions, r.drawSessionLine(p, row.sessions[i]))
    let hidden = row.sessions.len - shown
    if hidden > 0 or row.expanded and row.sessions.len > InitiativeSessionLinesShown:
      let label = if row.expanded: "Show fewer" else: "+" & $hidden & " more"
      # `.ah-initiative-more-toggle`: a 20px chip, 8px in, the control
      # radius, outlined in the primary border role on no fill, 2px clear of
      # the lines above and below, its label in the label role.
      let more = r.box(pairs = [("height", "20px"), ("items", "center"),
                                ("padding-left", "8px"), ("padding-right", "8px"),
                                ("rounded", $ControlRadiusPx & "px"),
                                ("border-width", "1px"), ("border-color", p.borderPrimary),
                                ("margin-top", "2px"), ("margin-bottom", "2px"),
                                ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
      r.appendChild(more, r.text(label, CaptionPx, p.textLabel, shrink = false))
      let chipRow = r.box(pairs = [("flex-shrink", "0")])
      r.appendChild(chipRow, more)
      r.tag(more, "more", label)
      r.addEventListener(more, "click", proc() = vm.toggleExpanded(id))
      r.appendChild(sessions, chipRow)
    if row.sessions.len == 0:
      let label = if row.missingSessions == 0: "No session is working on it"
                  else: $row.missingSessions &
                    (if row.missingSessions == 1: " session" else: " sessions") &
                    " on other servers"
      # `.ah-initiative-more`: upright caption text on the 24px line it
      # inherits, 16px further in than the session lines.
      let tail = r.text(label, CaptionPx, quiet,
                        pairs = [("line-height", $HeadLinePx & "px"), ("margin-left", "16px")])
      r.tag(tail, "more", label)
      r.appendChild(sessions, tail)
    if wide:
      # The second column (`minmax(0, 1fr)`): the rest of the row, never
      # widened by a long title, which is cut instead.
      r.styles(sessions, [("flex-grow", "1"), ("flex-basis", "0px"), ("min-width", "0px"),
                          ("overflow", "hidden")])
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
                   index: int; wide, narrow: bool): GpuiElement =
  ## One milestone (`.ah-milestone`): 5px above and below, the mark then the
  ## title line (id, name) and the meta line, 16px each and 1px apart; a
  ## wide panel puts title and meta on one line, the mark 24px before them.
  let lh = ("line-height", $LinePx & "px")
  result = r.box(pairs = [("gap", (if wide: $MarkGapWidePx else: "8") & "px"),
                          ("items", "start"), ("padding-top", "5px"),
                          ("padding-bottom", "5px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
  # The current milestone, a step above the panel (`.ah-milestone-current`:
  # `by-mode(tertiary, base-card)`); in the wide table every other row is
  # banded (`by-mode(secondary-hover, base-card)`) and the current one a step
  # above the bands (`by-mode(tertiary, secondary-hover)`). A narrow list has
  # no bands.
  if m.current:
    r.setStyle(result, "background",
               if p.mode == dmDark: p.tertiary elif wide: p.hover else: p.menu)
  elif wide and index mod 2 == 1: r.setStyle(result, "background", p.bandOf)
  r.tag(result, "milestone", m.id)
  r.tag(result, "status-class", $m.statusClass)
  r.tag(result, "current", $m.current)
  # `.ah-ms-mark`: 6px down from the row's first line (`margin-top:
  # 0.375rem`), inside that 16px line, so the mark never makes the row taller.
  let markHolder = r.box(pairs = [("height", $LinePx & "px"), ("padding-top", "6px"),
                                  ("items", "start"), ("flex-shrink", "0")])
  r.appendChild(markHolder, r.mark(p.markOf(m.statusClass)))
  r.appendChild(result, markHolder)
  let main = r.box(column = true, pairs = [("flex-grow", "1"), ("gap", "1px")])
  let title = r.box(pairs = [("gap", "8px"), ("items", "center"), ("height", $LinePx & "px")])
  let idPx = if narrow: MilestoneIdNarrowPx else: MilestoneIdPx
  r.appendChild(title, r.text(m.id, BodyPx, p.textLabel, shrink = false,
                              pairs = [("min-width", $idPx & "px"), lh]))
  let name = r.text(m.title, BodyPx, p.textBody, pairs = [lh])
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
  # `.ah-milestone-meta`: a 16px caption line; CURRENT semibold at the
  # caption size, 6px before the counts.
  let meta = r.box(pairs = [("gap", "6px"), ("items", "center"), ("height", $LinePx & "px")])
  if m.current:
    r.appendChild(meta, r.text("CURRENT", CaptionPx, p.textLabel, bold = true,
                               shrink = false, pairs = [lh]))
  let metaRun = r.box(pairs = [("items", "center")])
  r.tag(metaRun, "meta", parts.before & parts.failing & parts.after)
  r.appendChild(metaRun, r.text(parts.before, CaptionPx, p.textCaption, shrink = false,
                                pairs = [lh]))
  if parts.failing.len > 0:
    r.appendChild(metaRun, r.text(parts.failing, CaptionPx, p.textError, shrink = false,
                                  pairs = [lh]))
    r.appendChild(metaRun, r.text(parts.after, CaptionPx, p.textCaption, shrink = false,
                                  pairs = [lh]))
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
    # `.ah-progress-summary-block`: 8px in, 10px below, its parts 6px apart.
    let summaryBlock = r.box(column = true, pairs = [("gap", "6px"), ("padding-top", "8px"),
                                                     ("padding-bottom", "10px"),
                                                     ("padding-left", $InsetPx & "px"),
                                                     ("padding-right", $InsetPx & "px"),
                                                     ("flex-shrink", "0")])
    r.rule(summaryBlock, p.borderSecondary)
    r.appendChild(summaryBlock, r.drawMilestoneBar(p, vm.statusCounts, labelled = true,
                                                   availPx = widthPx - 2 * InsetPx))
    let summaryText = if initiative.executiveSummary.len > 0: initiative.executiveSummary
                      else: "The plan states no executive summary."
    # `.ah-progress-summary`: body text on 24px lines (`type-ui-lineheight-
    # body-md`), at most 48rem wide; the "no summary" line upright in the
    # caption role (`.ah-progress-summary-none`).
    let summary = r.text(summaryText, BodyPx,
                         if initiative.executiveSummary.len > 0: p.textBody else: p.textCaption,
                         shrink = false, pairs = [("white-space", "normal"),
                                                  ("line-height", "24px"),
                                                  ("max-width", "768px")])
    r.tag(summary, "executive-summary", summaryText)
    r.appendChild(summaryBlock, summary)
    let current = currentMilestoneText(initiative.progress)
    if current.len > 0: r.appendChild(summaryBlock, r.drawCurrent(p, current))
    r.appendChild(list, summaryBlock)
    for group in vm.groups:
      # `.ah-progress-group-header`: the VCS section header -- 6px above, a
      # 24px line, 4px below, over a hairline.
      let header = r.box(pairs = [("gap", "6px"), ("items", "center"), ("height", "35px"),
                                  ("padding-top", "6px"), ("padding-bottom", "4px"),
                                  ("padding-left", $InsetPx & "px"), ("flex-shrink", "0")])
      r.rule(header, p.borderSecondary)
      r.tag(header, "group", group.name)
      r.appendChild(header, r.text(group.name.toUpperAscii, CaptionPx, p.textLabel,
                                   bold = true, shrink = false))
      r.appendChild(header, r.text("(" & $group.count & ")", CaptionPx, p.textCaption,
                                   shrink = false))
      r.appendChild(list, header)
      for i, m in group.milestones:
        r.appendChild(list, r.drawMilestone(p, m, i, widthPx >= WidePanelPx,
                                            widthPx <= NarrowProgressPx))
    r.appendChild(host, list)

proc mountProgressPanel*(r: GpuiRenderer; host: GpuiElement; vm: InitiativeProgressVM;
                         p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawProgressPanel(r, host, vm, p, widthPx)
