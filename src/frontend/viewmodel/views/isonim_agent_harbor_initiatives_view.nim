## IsoNim views of Agent Harbor initiatives -- the running plans and the
## sessions behind each -- and of one initiative's progress, over
## `InitiativesVM` and `InitiativeProgressVM` (nim-agents-isonim-viewmodels).
##
## Both are CodeTracer panels built from the VCS panel's parts, as the fleet
## panel is (`isonim_agent_harbor_fleet_view.nim`, `agent_harbor.styl`): a
## section header, list rows that highlight like commit rows, quiet meta lines.
##
## - The Initiatives panel: one row per initiative -- its title, the
##   repository, its manager and current milestone, a thin progress bar with
##   `n of m milestones · p%` and its milestone counts by status -- and under
##   it the sessions launched for it, each with its status mark. Selecting an
##   initiative is the host's to act on (it focuses the initiative's session
##   tabs and shows its progress).
## - The Initiative Progress panel: the initiative's headline and executive
##   summary, its current milestone, then its milestones grouped by status
##   (in progress first, completed last), each with its deliverables and
##   test counts.

import std/strutils
when defined(js):
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents_isonim_viewmodels/agent_harbor/[initiatives_vm, initiative_progress_vm]

export signals, computation, components, initiatives_vm, initiative_progress_vm

const
  AgentHarborInitiativesClass* = "component-container agent-harbor-initiatives"
  AgentHarborProgressClass* = "component-container agent-harbor-progress"
  InitiativesLoadingText* = "Loading initiatives\xE2\x80\xA6"
  InitiativesEmptyText* = "No initiative is running on this server."
  ProgressEmptyText* = "Select an initiative to see its progress."
  InitiativeSessionLinesShown* = 4
    ## Session lines under an initiative before "+N more".

type
  AgentHarborInitiativesCallbacks* = object
    onSelect*: proc(initiativeId: string)
    onRetry*: proc()

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc statusClassName*(status: MilestoneStatusClass): string =
  case status
  of mscInProgress: "in-progress"
  of mscPartial: "partial"
  of mscBlocked: "blocked"
  of mscPlanned: "planned"
  of mscCompleted: "completed"
  of mscOther: "other"

proc statusCountsText*(counts: array[MilestoneStatusClass, int]): string =
  ## `2 in progress · 1 blocked · 9 planned · 5 completed`.
  var parts: seq[string]
  for status in MilestoneStatusClass:
    if counts[status] > 0: parts.add $counts[status] & " " & $status
  parts.join(" \xC2\xB7 ")

proc renderError[R](r: R; title, message: string; retry: proc()): auto =
  ui(r):
    tdiv(class = "ah-fleet-error"):
      tdiv(class = "ah-fleet-error-title"):
        text title
      tdiv(class = "ah-fleet-error-message"):
        text message
      button(class = "ah-fleet-retry", onclick = retry):
        text "Retry"

proc renderOverlay[R](r: R; message, extra: string): auto =
  ui(r):
    tdiv(class = "empty-overlay ah-fleet-overlay " & extra):
      text message

proc renderSessionLine[R](r: R; item: SessionItem): auto =
  ui(r):
    tdiv(class = "ah-initiative-session ah-att-" & $item.attention, title = item.tooltip):
      span(class = "ah-tab-mark"):
        discard
      span(class = "ah-initiative-session-title"):
        text item.title
      span(class = "ah-initiative-session-status"):
        text item.statusLabel

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}

proc renderMilestoneBar*[R](r: R; counts: array[MilestoneStatusClass, int];
                            labelled = false): auto =
  ## Progress at a glance: one thin bar split by milestone status --
  ## completed, in progress, partially completed, blocked, planned -- each
  ## segment as long as its share (done fills from the left, as a progress
  ## bar does), and each status's count with its mark. `labelled` (one bar
  ## in view: the Initiative Progress panel, the tab's popup) names each
  ## status beside its count, on a line under the bar; a row of the
  ## Initiatives panel keeps the counts beside its bar, the names in the
  ## tooltip.
  const order = [mscCompleted, mscInProgress, mscPartial, mscBlocked, mscPlanned, mscOther]
  var bar, legend: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(class = "ah-ms-progress" & (if labelled: " ah-ms-labelled" else: ""),
         title = statusCountsText(counts)):
      tdiv(ref = bar, class = "ah-ms-bar")
      tdiv(ref = legend, class = "ah-ms-legend")
  for status in order:
    if counts[status] == 0: continue
    let segment = ui(r):
      span(class = "ah-ms-seg ah-ms-" & statusClassName(status),
           style = "flex-grow: " & $counts[status]):
        discard
    r.appendRendered(bar, segment)
    let item = ui(r):
      span(class = "ah-ms-legend-item ah-ms-" & statusClassName(status),
           title = $counts[status] & " " & $status):
        span(class = "ah-ms-mark"):
          discard
        # Named as the group headers below name it (the legend wraps).
        text $counts[status] & (if labelled: " " & $status else: "")
    r.appendRendered(legend, item)
  node

proc renderMoreToggle[R](r: R; vm: InitiativesVM; row: InitiativeRow; hidden: int): auto =
  ## `+N more` (or `Show fewer`), a small chip that unfolds the node.
  let id = row.id
  let label = if row.expanded: "Show fewer" else: "+" & $hidden & " more"
  var chip: typeof(r.createElement("button"))
  let node = ui(r):
    button(ref = chip, class = "ah-initiative-more-toggle",
           onclick = proc() = vm.toggleExpanded(id)):
      text label
  when defined(js):
    when typeof(chip) is isonim_dom.Element:
      isonim_dom.addEventListener(isonim_dom.Node(chip), cstring"click",
        proc(ev: isonim_dom.Event) = ev.stopPropagation())
  node

proc renderInitiativeRow[R](r: R; vm: InitiativesVM;
                            cb: AgentHarborInitiativesCallbacks;
                            row: InitiativeRow): auto =
  ## One initiative, a node of the tree: its fold control, state mark, title
  ## and `n/m · p%`, the milestone bar, its current milestone and meta; then
  ## its sessions (the first few, all once expanded; none while folded).
  let id = row.id
  var sessions, barHost, fold: typeof(r.createElement("div"))
  var meta: seq[string]
  if row.repository.len > 0: meta.add row.repository
  if row.manager.len > 0: meta.add "manager " & row.manager
  let chevron = if row.folded: "\xE2\x96\xB8" else: "\xE2\x96\xBE"
  let foldTitle = if row.folded: "Show its sessions" else: "Hide its sessions"
  let node = ui(r):
    tdiv(class = "ah-initiative-row ah-ist-" & $row.state &
                 (if row.selected: " ah-initiative-row-selected" else: "") &
                 (if row.folded: " ah-initiative-row-folded" else: ""),
         role = "treeitem", tabindex = "0", title = row.title,
         onclick = proc() =
           if cb.onSelect != nil: cb.onSelect(id) else: vm.select(id)):
      tdiv(class = "ah-initiative-info"):
        tdiv(class = "ah-initiative-head"):
          span(ref = fold, class = "ah-initiative-fold", title = foldTitle,
               onclick = proc() = vm.toggleFolded(id)):
            text chevron
          span(class = "ah-tab-mark"):
            discard
          span(class = "ah-initiative-title"):
            text row.title
          span(class = "ah-initiative-progress-text", title = row.progressLong):
            text row.progressText
        tdiv(ref = barHost, class = "ah-initiative-bar-host")
        if row.currentMilestone.len > 0:
          tdiv(class = "ah-initiative-current", title = row.currentMilestone):
            span(class = "ah-initiative-label"):
              text "Current"
            span(class = "ah-initiative-current-text"):
              text row.currentMilestone
        if meta.len > 0:
          tdiv(class = "ah-initiative-meta"):
            span(class = "ah-initiative-meta-text"):
              text meta.join(" \xC2\xB7 ")
      tdiv(ref = sessions, class = "ah-initiative-sessions", role = "group")
  r.appendRendered(barHost, renderMilestoneBar(r, row.statusCounts))
  when defined(js):
    when typeof(fold) is isonim_dom.Element:
      isonim_dom.addEventListener(isonim_dom.Node(fold), cstring"click",
        proc(ev: isonim_dom.Event) = ev.stopPropagation())
  if not row.folded:
    let shown = if row.expanded: row.sessions.len
                else: min(row.sessions.len, InitiativeSessionLinesShown)
    for i in 0 ..< shown:
      r.appendRendered(sessions, renderSessionLine(r, row.sessions[i]))
    let hidden = row.sessions.len - shown
    if hidden > 0 or row.expanded and row.sessions.len > InitiativeSessionLinesShown:
      r.appendRendered(sessions, renderMoreToggle(r, vm, row, hidden))
    if row.sessions.len == 0:
      let label = if row.missingSessions == 0: "No session is working on it"
                  else: $row.missingSessions &
                    (if row.missingSessions == 1: " session" else: " sessions") & " on other servers"
      let tail = ui(r):
        tdiv(class = "ah-initiative-more"):
          text label
      r.appendRendered(sessions, tail)
  node

proc renderAgentHarborInitiativesPanel*[R, N](r: R; vm: InitiativesVM;
    cb: AgentHarborInitiativesCallbacks = AgentHarborInitiativesCallbacks()): N =
  mixin clearChildren
  var body: N
  let panel = ui(r):
    tdiv(class = AgentHarborInitiativesClass):
      tdiv(ref = body, class = "ah-fleet-body")
  createRenderEffect proc() =
    r.clearChildren(body)
    let summary = if vm.state.val == asReady: vm.summaryText else: ""
    let head = ui(r):
      tdiv(class = "ah-fleet-head"):
        tdiv(class = "ah-fleet-section-header"):
          span(class = "ah-fleet-title"):
            text "Initiatives"
          span(class = "ah-fleet-source", title = vm.sourceLabel):
            text vm.sourceLabel
          span(class = "ah-fleet-summary"):
            text summary
    r.appendRendered(body, head)
    let target = vm
    case vm.state.val
    of asIdle, asLoading:
      r.appendRendered(body, renderOverlay(r, InitiativesLoadingText, "ah-fleet-loading"))
    of asError:
      r.appendRendered(body, renderError(r, "Could not load the initiatives",
        vm.error.val, proc() =
          if cb.onRetry != nil: cb.onRetry() else: target.load()))
    of asReady:
      let rows = vm.rows
      if rows.len == 0:
        r.appendRendered(body, renderOverlay(r, InitiativesEmptyText, ""))
      else:
        var list: N
        let listNode = ui(r):
          tdiv(ref = list, class = "ah-fleet-list ah-initiative-list")
        for row in rows:
          r.appendRendered(list, renderInitiativeRow(r, vm, cb, row))
        r.appendRendered(body, listNode)
  panel

# ---------------------------------------------------------------------------
# Initiative Progress
# ---------------------------------------------------------------------------

proc milestoneMetaParts*(m: MilestoneLine): tuple[before, failing, after: string] =
  ## The meta line split around its failing count (`1 failing`), which a
  ## view draws in the error role; `failing` is "" when no test fails.
  let full = (if m.deliverablesText.len > 0: m.deliverablesText & " \xC2\xB7 " else: "") &
             m.testsText
  let word = $m.failing & " failing"
  let at = if m.failing > 0: full.find(word) else: -1
  if at < 0: return (full, "", "")
  (full[0 ..< at], word, full[at + word.len .. ^1])

proc renderMilestone[R](r: R; m: MilestoneLine): auto =
  let metaParts = milestoneMetaParts(m)
  ui(r):
    tdiv(class = "ah-milestone ah-ms-" & statusClassName(m.statusClass) &
                 (if m.current: " ah-milestone-current" else: ""),
         title = m.id & ": " & m.title & " (" & m.status & ")"):
      span(class = "ah-ms-mark"):
        discard
      tdiv(class = "ah-milestone-main"):
        tdiv(class = "ah-milestone-title"):
          span(class = "ah-milestone-id"):
            text m.id
          span(class = "ah-milestone-name"):
            text m.title
        # The current milestone is tagged in its meta line, so every title
        # starts in the same column; failing tests read in the error role.
        tdiv(class = "ah-milestone-meta"):
          if m.current:
            span(class = "ah-milestone-current-tag"):
              text "Current"
          span(class = "ah-milestone-meta-text"):
            text metaParts.before
          if metaParts.failing.len > 0:
            span(class = "ah-milestone-tests-failing"):
              text metaParts.failing
            span(class = "ah-milestone-meta-text"):
              text metaParts.after

proc renderProgressGroup[R](r: R; group: MilestoneGroupView): auto =
  var rows: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(class = "ah-progress-group ah-ms-group-" & statusClassName(group.status)):
      tdiv(class = "ah-progress-group-header"):
        span(class = "ah-progress-group-name"):
          text group.name
        span(class = "ah-progress-group-count"):
          text "(" & $group.count & ")"
      tdiv(ref = rows, class = "ah-progress-group-rows")
  for m in group.milestones:
    r.appendRendered(rows, renderMilestone(r, m))
  node

proc renderAgentHarborProgressPanel*[R, N](r: R; vm: InitiativeProgressVM;
    onRetry: proc() = nil): N =
  mixin clearChildren
  var body: N
  let panel = ui(r):
    tdiv(class = AgentHarborProgressClass):
      tdiv(ref = body, class = "ah-fleet-body")
  createRenderEffect proc() =
    r.clearChildren(body)
    let ready = vm.state.val == asReady and vm.found
    let initiative = vm.current
    let title = if ready: initiative.title else: ""
    let headline = if ready: vm.headline else: ""
    let head = ui(r):
      tdiv(class = "ah-fleet-head"):
        tdiv(class = "ah-fleet-section-header"):
          span(class = "ah-fleet-title"):
            text "Initiative progress"
          span(class = "ah-fleet-source", title = title):
            text title
          span(class = "ah-fleet-summary"):
            text headline
    r.appendRendered(body, head)
    let target = vm
    case vm.state.val
    of asIdle, asLoading:
      r.appendRendered(body, renderOverlay(r, InitiativesLoadingText, "ah-fleet-loading"))
    of asError:
      r.appendRendered(body, renderError(r, "Could not load the initiative",
        vm.error.val, proc() =
          if onRetry != nil: onRetry() else: target.load()))
    of asReady:
      if not vm.found:
        r.appendRendered(body, renderOverlay(r, ProgressEmptyText, ""))
      else:
        var list, barHost: N
        let current = currentMilestoneText(initiative.progress)
        let listNode = ui(r):
          tdiv(ref = list, class = "ah-fleet-list ah-progress-list"):
            tdiv(class = "ah-progress-summary-block"):
              tdiv(ref = barHost, class = "ah-initiative-bar-host")
              if initiative.executiveSummary.len > 0:
                tdiv(class = "ah-progress-summary"):
                  text initiative.executiveSummary
              else:
                tdiv(class = "ah-progress-summary ah-progress-summary-none"):
                  text "The plan states no executive summary."
              if current.len > 0:
                tdiv(class = "ah-initiative-current"):
                  span(class = "ah-initiative-label"):
                    text "Current"
                  span(class = "ah-initiative-current-text"):
                    text current
        r.appendRendered(barHost, renderMilestoneBar(r, vm.statusCounts, labelled = true))
        for group in vm.groups:
          r.appendRendered(list, renderProgressGroup(r, group))
        r.appendRendered(body, listNode)
  panel

when defined(js):
  proc mountAgentHarborInitiativesPanel*(container: isonim_dom.Element;
      vm: InitiativesVM; cb = AgentHarborInitiativesCallbacks()) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborInitiativesPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm, cb)))

  proc mountAgentHarborProgressPanel*(container: isonim_dom.Element;
                                      vm: InitiativeProgressVM) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborProgressPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
