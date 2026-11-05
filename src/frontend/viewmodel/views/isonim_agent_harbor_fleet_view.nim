## IsoNim view of an Agent Harbor fleet: every session an Agent Harbor server
## lists, grouped by what it needs from the reader, over `FleetSnapshotVM`
## (nim-agents-isonim-viewmodels).
##
## Layout, top to bottom:
##
## - a section header naming the source ("fleet snapshot, … UTC" or a live
##   server) and the session count, in the VCS panel's header style;
## - a filter strip, one toggle per category with its count (All, Needs
##   input, Running, Queued, Failed, Ended), in the VCS diff toggle's style;
## - the session list. Each row carries a status dot, the session's title (its
##   prompt; when the server withholds it, what a person calls the session --
##   its name, branch or workspace -- and only failing those its short id), a
##   meta line (the effective status, agent · repository · workspace ·
##   initiative · host · short id · duration), a failure reason, and ONE
##   activity line -- the most informative recent event, repeats collapsed --
##   with a "+N" control that unfolds the rest; the age of its last activity
##   sits on the right, like a commit row's timestamp. When the server
##   withholds prompts, the header says so once; rows do not repeat it.
##   Given a laptop's width, agent, host, initiative and duration leave the
##   meta line for columns of their own (a container query in
##   `agent_harbor.styl`), so the row uses the width instead of leaving an
##   empty middle.
##
## The loading, error and empty states use the shared empty-state overlay
## every CodeTracer panel uses. The view only renders: what a row says, and in
## what order the rows come, is the viewmodel's (`FleetSnapshotVM.rows`), so
## the native front-ends and the headless tests read the same words.

import std/strutils
when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}

import nim_agents_isonim_viewmodels/agent_harbor/fleet_vm

export signals, computation, components, fleet_vm

const
  AgentHarborFleetClass* = "component-container agent-harbor-fleet"
  AgentHarborFleetLoadingText* = "Loading sessions\xE2\x80\xA6"
  AgentHarborFleetEmptyText* = "No sessions on this server yet."
  AgentHarborFleetFilteredEmptyText* = "No session in this category."

type
  AgentHarborFleetCallbacks* = object
    ## Host hooks. A missing hook falls back to the viewmodel's own action,
    ## so a story or a test works with no host at all.
    onSelect*: proc(sessionId: string)
    onFilter*: proc(filter: FleetFilter)
    onRetry*: proc()

proc filterLabel*(filter: FleetFilter): string =
  case filter
  of ffAll: "All"
  of ffNeedsInput: "Needs input"
  of ffRunning: "Running"
  of ffQueued: "Queued"
  of ffFailed: "Failed"
  of ffEnded: "Ended"

proc filterCount*(counts: FleetCounts; filter: FleetFilter): int =
  case filter
  of ffAll: counts.listed
  of ffNeedsInput: counts.byCategory[fcNeedsInput]
  of ffRunning: counts.byCategory[fcRunning]
  of ffQueued: counts.byCategory[fcQueued]
  of ffFailed: counts.byCategory[fcFailed]
  of ffEnded: counts.byCategory[fcEnded]

proc categoryClass*(category: FleetCategory): string =
  "ah-fleet-cat-" & $category

proc rowClass*(row: FleetRow): string =
  result = "ah-fleet-row " & categoryClass(row.category)
  if row.selected: result.add(" ah-fleet-row-selected")

proc metaPartsShort*(row: FleetRow): seq[string] =
  ## The meta line when agent, host, initiative and duration have columns.
  if row.repository.len > 0:
    result.add(if row.branch.len > 0: row.repository & " \xC2\xB7 " & row.branch
               else: row.repository)
  if row.workspace.len > 0: result.add(row.workspace)
  if row.titleSource != "id": result.add(row.shortId)

proc metaParts*(row: FleetRow): seq[string] =
  ## The meta line, in reading order; empty parts are left out.
  if row.agentLabel.len > 0:
    result.add(if row.agentCount > 1: row.agentLabel & " \xC3\x97" & $row.agentCount
               else: row.agentLabel)
  if row.repository.len > 0:
    result.add(if row.branch.len > 0: row.repository & " \xC2\xB7 " & row.branch
               else: row.repository)
  if row.workspace.len > 0: result.add(row.workspace)
  if row.initiative.len > 0: result.add(row.initiative)
  if row.host.len > 0: result.add(row.host)
  if row.titleSource != "id": result.add(row.shortId)
  if row.durationLabel.len > 0: result.add(row.durationLabel)

proc withheldNote*(vm: FleetSnapshotVM): string =
  ## Said once, in the header, after the session count: the server withheld
  ## the prompts, so rows are titled by what else names them.
  let counts = vm.counts
  if counts.withheldPrompts == 0: ""
  elif counts.withheldPrompts >= counts.listed:
    "prompts withheld by the server"
  else:
    "prompts of " & $counts.withheldPrompts & " withheld by the server"

proc headerSummary*(vm: FleetSnapshotVM): string =
  ## `471 sessions`; `13 of 471 sessions` while a filter shows some of them
  ## (or while the server reports more than it listed).
  let counts = vm.counts
  let filtered = vm.filter.val != ffAll
  let shown = if filtered: vm.rows.len else: counts.listed
  let outOf = if filtered: counts.listed else: counts.total
  if outOf > shown or filtered:
    $shown & " of " & $outOf & " sessions"
  else:
    $shown & (if shown == 1: " session" else: " sessions")

proc appendRendered[R, N](r: R; host, child: N) =
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin appendChild
  r.appendChild(host, child)

proc invokeSelect(vm: FleetSnapshotVM; callbacks: AgentHarborFleetCallbacks;
                  sessionId: string) =
  if callbacks.onSelect != nil: callbacks.onSelect(sessionId)
  else: vm.select(sessionId)

proc invokeFilter(vm: FleetSnapshotVM; callbacks: AgentHarborFleetCallbacks;
                  filter: FleetFilter) =
  if callbacks.onFilter != nil: callbacks.onFilter(filter)
  else: vm.setFilter(filter)

proc invokeRetry(vm: FleetSnapshotVM; callbacks: AgentHarborFleetCallbacks) =
  if callbacks.onRetry != nil: callbacks.onRetry()
  else: vm.load()

proc renderFilterButton[R](r: R; vm: FleetSnapshotVM;
                           callbacks: AgentHarborFleetCallbacks;
                           filter: FleetFilter; count: int;
                           active: bool): auto =
  ## One toggle. A proc of its own so the click captures `filter` through a
  ## parameter, not a loop variable.
  let chosen = filter
  ui(r):
    button(class = "ah-fleet-filter" & (if active: " ah-fleet-filter-active" else: "") &
                   (if count == 0: " ah-fleet-filter-empty" else: ""),
           title = filterLabel(filter) & ": " & $count,
           onclick = proc() = vm.invokeFilter(callbacks, chosen)):
      span(class = "ah-fleet-filter-label"):
        text filterLabel(filter)
      span(class = "ah-fleet-filter-count"):
        text $count

proc renderHeader[R](r: R; vm: FleetSnapshotVM;
                     callbacks: AgentHarborFleetCallbacks): auto =
  var filters, section: typeof(r.createElement("div"))
  let header = ui(r):
    tdiv(class = "ah-fleet-head"):
      tdiv(ref = section, class = "ah-fleet-section-header"):
        span(class = "ah-fleet-title"):
          text "Agent Harbor sessions"
        span(class = "ah-fleet-source", title = vm.sourceLabel):
          text vm.sourceLabel
      tdiv(ref = filters, class = "ah-fleet-filters")
      # The columns' names, shown only when the rows have columns (a laptop's
      # width; agent_harbor.styl).
      tdiv(class = "ah-fleet-columns"):
        span(class = "ah-fleet-columns-session"):
          text "Session"
        span(class = "ah-fleet-columns-cell"):
          text "Agent"
        span(class = "ah-fleet-columns-cell"):
          text "Host"
        span(class = "ah-fleet-columns-cell ah-fleet-columns-initiative"):
          text "Initiative"
        span(class = "ah-fleet-columns-right"):
          text "Duration"
        span(class = "ah-fleet-columns-right"):
          text "Active"
  if vm.state.val == asReady:
    let note = vm.withheldNote
    if note.len > 0:
      let caveat = ui(r):
        span(class = "ah-fleet-caveat",
             title = "Rows are titled by the session's name, branch or workspace, or its id"):
          text note
      r.appendRendered(section, caveat)
  if vm.state.val == asReady:
    let counts = vm.counts
    let current = vm.filter.val
    for filter in FleetFilter:
      r.appendRendered(filters,
        renderFilterButton(r, vm, callbacks, filter, counts.filterCount(filter),
                           filter == current))
    let summary = ui(r):
      span(class = "ah-fleet-summary"):
        text vm.headerSummary
    # In the section header, not the filter strip: a narrow panel wraps the
    # strip, and the count must not ride on its last line.
    r.appendRendered(section, summary)
  header

proc renderActivityToggle[R](r: R; vm: FleetSnapshotVM; row: FleetRow): auto =
  ## "+N" unfolds a row's other activity lines; "less" folds them.
  let sessionId = row.id
  let hidden = row.activity.len - 1 + row.activityMore
  let label = if row.expanded: "less" else: "+" & $hidden
  var button: typeof(r.createElement("button"))
  let node = ui(r):
    button(ref = button, class = "ah-fleet-activity-more",
           title = (if row.expanded: "Show one activity line" else: "Show " & $hidden & " more activity lines"),
           onclick = proc() = vm.toggleExpanded(sessionId)):
      text label
  when defined(js):
    when typeof(button) is isonim_dom.Element:
      # The row's own click selects it; this one only unfolds.
      isonim_dom.addEventListener(isonim_dom.Node(button), cstring"click",
        proc(ev: isonim_dom.Event) = ev.stopPropagation())
  node

proc renderRow[R](r: R; vm: FleetSnapshotVM;
                  callbacks: AgentHarborFleetCallbacks; row: FleetRow): auto =
  let sessionId = row.id
  var activity: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(role = "button", tabindex = "0", class = rowClass(row),
         title = row.id,
         onclick = proc() = vm.invokeSelect(callbacks, sessionId)):
      span(class = "ah-fleet-dot", title = row.statusLabel):
        discard
      tdiv(class = "ah-fleet-row-main"):
        # The title plainly, whatever named it: the header says once that the
        # server withholds prompts.
        tdiv(class = "ah-fleet-row-title",
             title = (if row.labelTooltip.len > 0: row.title & " (" & row.labelTooltip & ")"
                      else: row.title)):
          text row.title
        tdiv(class = "ah-fleet-row-meta"):
          # The effective status (FleetRow.statusLabel): "needs input" wins
          # over the wire status, so no separate badge repeats it.
          span(class = "ah-fleet-status-label",
               title = (if row.needsInput and row.inputSource.len > 0:
                          "waiting for: " & row.inputSource
                        else: row.statusLabel)):
            text row.statusLabel
          span(class = "ah-fleet-meta-text ah-fleet-meta-full"):
            text row.metaParts.join(" \xC2\xB7 ")
          span(class = "ah-fleet-meta-text ah-fleet-meta-short"):
            text row.metaPartsShort.join(" \xC2\xB7 ")
        if row.failureText.len > 0:
          tdiv(class = "ah-fleet-row-failure", title = row.failureText):
            text row.failureText
        tdiv(ref = activity, class = "ah-fleet-row-activity")
      # Columns of their own at a laptop's width (hidden in a narrow panel,
      # where the meta line carries the same facts).
      span(class = "ah-fleet-col ah-fleet-col-agent", title = row.agentLabel):
        text (if row.agentCount > 1: row.agentLabel & " \xC3\x97" & $row.agentCount else: row.agentLabel)
      span(class = "ah-fleet-col ah-fleet-col-host", title = row.host):
        text row.host
      span(class = "ah-fleet-col ah-fleet-col-initiative", title = row.initiative):
        text row.initiative
      span(class = "ah-fleet-col ah-fleet-col-duration"):
        text row.durationLabel
      span(class = "ah-fleet-row-age"):
        text row.ageLabel
  let shown = if row.expanded: row.activity.len else: min(1, row.activity.len)
  let allLines = row.activity.join("\n")
  for i in 0 ..< shown:
    let line = row.activity[i]
    let level = if i < row.activityLevels.len: row.activityLevels[i] else: ""
    var lineHost: typeof(r.createElement("div"))
    let lineNode = ui(r):
      tdiv(ref = lineHost, class = "ah-fleet-activity-row"):
        tdiv(class = "ah-fleet-activity-line" &
                     (if level == "error": " ah-fleet-activity-error" else: ""),
             title = allLines):
          text line
    # The unfold control rides on the first line, so a folded row stays one
    # line of activity.
    if i == 0 and row.activity.len + row.activityMore > 1:
      r.appendRendered(lineHost, renderActivityToggle(r, vm, row))
    r.appendRendered(activity, lineNode)
  node

proc renderOverlay[R](r: R; message: string; extraClass = ""): auto =
  ui(r):
    tdiv(class = "empty-overlay ah-fleet-overlay " & extraClass):
      text message

proc renderError[R](r: R; vm: FleetSnapshotVM;
                    callbacks: AgentHarborFleetCallbacks): auto =
  ui(r):
    tdiv(class = "ah-fleet-error"):
      tdiv(class = "ah-fleet-error-title"):
        text "Could not load the sessions"
      tdiv(class = "ah-fleet-error-message"):
        text vm.error.val
      button(class = "ah-fleet-retry",
             onclick = proc() = vm.invokeRetry(callbacks)):
        text "Retry"

proc renderAgentHarborFleetPanel*[R, N](
    r: R; vm: FleetSnapshotVM;
    callbacks: AgentHarborFleetCallbacks = AgentHarborFleetCallbacks()): N =
  ## The fleet panel, for every renderer. The body is rebuilt when the
  ## viewmodel's state, rows or counts move.
  mixin clearChildren, setAttribute
  var body: N
  let panel = ui(r):
    tdiv(class = AgentHarborFleetClass):
      tdiv(ref = body, class = "ah-fleet-body")

  createRenderEffect proc() =
    r.clearChildren(body)
    # No session of the snapshot names an initiative (the real snapshot):
    # its column, and the column's name, are left out. Decided over the
    # whole snapshot, so a filter does not change the columns.
    let anyInitiative = vm.state.val == asReady and vm.anyInitiative
    r.setAttribute(body, "class", "ah-fleet-body" &
      (if anyInitiative: "" else: " ah-fleet-no-initiative"))
    r.appendRendered(body, renderHeader(r, vm, callbacks))
    case vm.state.val
    of asIdle, asLoading:
      r.appendRendered(body, renderOverlay(r, AgentHarborFleetLoadingText,
                                           "ah-fleet-loading"))
    of asError:
      r.appendRendered(body, renderError(r, vm, callbacks))
    of asReady:
      let rows = vm.rows
      if rows.len == 0:
        r.appendRendered(body, renderOverlay(r,
          if vm.counts.listed == 0: AgentHarborFleetEmptyText
          else: AgentHarborFleetFilteredEmptyText))
      else:
        var list: N
        let listNode = ui(r):
          tdiv(ref = list, class = "ah-fleet-list")
        for row in rows:
          r.appendRendered(list, renderRow(r, vm, callbacks, row))
        r.appendRendered(body, listNode)

  panel

when defined(js):
  proc mountAgentHarborFleetPanel*(container: isonim_dom.Element;
                                   vm: FleetSnapshotVM;
                                   callbacks = AgentHarborFleetCallbacks()) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborFleetPanel[WebRenderer, isonim_dom.Element](
        WebRenderer(), vm, callbacks)))
