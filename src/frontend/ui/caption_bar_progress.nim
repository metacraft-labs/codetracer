## Caption bar progress indicator for the CodeTracer GUI (M9).
##
## Displays an animated progress bar in the application caption/title bar
## area showing the agent's current milestone progress. The indicator:
##
## - Shows the agent state (Idle, Working, Completed, etc.) with colour coding
## - Displays a progress bar based on completed/total milestones
## - Shows the name of the current milestone being worked on
## - Is clickable to toggle between user workspace and agent workspace views
## - Expands on hover to show the full milestone list with statuses
##
## The component receives state updates via ``AgentProgress`` objects pushed
## through the ``IPC_AGENT_PROGRESS`` IPC channel by the agent runtime.
##
## Reference: codetracer-specs/DeepReview/Agentic-Coding-Integration.md

import
  ui_imports, ../utils, ../communication,
  std/[strformat, jsconsole, math]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  from isonim/dsl/ui import ui
  from isonim/core/computation import createRenderEffect

# ---------------------------------------------------------------------------
# IsoNim mount state
# ---------------------------------------------------------------------------

var isoNimCaptionBarMounted: bool = false


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc stateLabel(state: AgentProgressState): cstring =
  ## Human-readable label for each agent state.
  case state
  of AgentIdle: cstring"Idle"
  of AgentInitializing: cstring"Initializing..."
  of AgentWorking: cstring"Working"
  of AgentWaitingInput: cstring"Waiting for input"
  of AgentPaused: cstring"Paused"
  of AgentCompleted: cstring"Completed"
  of AgentFailed: cstring"Failed"

proc stateCssClass(state: AgentProgressState): cstring =
  ## CSS modifier class for the progress indicator based on state.
  case state
  of AgentIdle: cstring"caption-progress-idle"
  of AgentInitializing: cstring"caption-progress-initializing"
  of AgentWorking: cstring"caption-progress-working"
  of AgentWaitingInput: cstring"caption-progress-waiting"
  of AgentPaused: cstring"caption-progress-paused"
  of AgentCompleted: cstring"caption-progress-completed"
  of AgentFailed: cstring"caption-progress-failed"

proc milestoneStatusIcon(status: MilestoneStatus): cstring =
  ## Character icon for milestone status in the expanded list.
  case status
  of MilestonePending: cstring"[ ]"
  of MilestoneInProgress: cstring"[>]"
  of MilestoneCompleted: cstring"[x]"
  of MilestoneFailed: cstring"[!]"
  of MilestoneSkipped: cstring"[-]"

proc milestoneStatusClass(status: MilestoneStatus): cstring =
  ## CSS class for milestone status colouring.
  case status
  of MilestonePending: cstring"milestone-pending"
  of MilestoneInProgress: cstring"milestone-in-progress"
  of MilestoneCompleted: cstring"milestone-completed"
  of MilestoneFailed: cstring"milestone-failed"
  of MilestoneSkipped: cstring"milestone-skipped"

proc progressPercent(progress: AgentProgress): float =
  ## Compute the progress percentage (0.0 .. 100.0).
  if progress.milestonesTotal <= 0:
    return 0.0
  result = clamp(
    (progress.milestonesCompleted.float / progress.milestonesTotal.float) * 100.0,
    0.0, 100.0)

# ---------------------------------------------------------------------------
# Component lifecycle
# ---------------------------------------------------------------------------

method register*(self: CaptionBarProgressComponent, api: MediatorWithSubscribers) =
  ## Register the component with the mediator event system.
  self.api = api

proc updateProgress*(self: CaptionBarProgressComponent, progress: AgentProgress) =
  ## Update the component with new progress state from the agent runtime.
  self.progress = progress
  # Track the last update time for animation purposes.
  # In a browser environment we would use performance.now(); here we use
  # a simple counter that the caller increments.
  self.lastUpdateMs += 1

# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------

proc renderProgressBar(self: CaptionBarProgressComponent): VNode =
  ## Render the animated progress bar fill.
  let pct = progressPercent(self.progress)
  let widthStr = cstring(fmt"{pct:.1f}%")

  buildHtml(tdiv(class = "caption-progress-bar")):
    tdiv(
      class = "caption-progress-bar-fill",
      style = style(StyleAttr.width, widthStr)
    )

proc renderMilestoneList(self: CaptionBarProgressComponent): VNode =
  ## Render the expanded milestone checklist (visible on hover/click).
  buildHtml(tdiv(class = "caption-progress-milestones")):
    if self.progress.milestones.len == 0:
      tdiv(class = "caption-progress-milestone-empty"):
        text "No milestones defined"
    else:
      for milestone in self.progress.milestones:
        let statusClass = milestoneStatusClass(milestone.status)
        tdiv(class = cstring(fmt"caption-progress-milestone-item {statusClass}")):
          span(class = "caption-progress-milestone-icon"):
            text milestoneStatusIcon(milestone.status)
          span(class = "caption-progress-milestone-content"):
            text $milestone.content
          if milestone.priority == cstring"high":
            span(class = "caption-progress-milestone-priority"):
              text "HIGH"

proc renderCompactView(self: CaptionBarProgressComponent): VNode =
  ## Render the compact (non-expanded) progress indicator.
  let stateClass = stateCssClass(self.progress.state)
  let pct = progressPercent(self.progress)
  let progressText =
    if self.progress.milestonesTotal > 0:
      fmt"{self.progress.milestonesCompleted}/{self.progress.milestonesTotal}"
    else:
      "0/0"

  buildHtml(tdiv(class = cstring(fmt"caption-progress-compact {stateClass}"))):
    span(class = "caption-progress-state"):
      text stateLabel(self.progress.state)

    if self.progress.taskName.len > 0:
      span(class = "caption-progress-task"):
        text $self.progress.taskName

    renderProgressBar(self)

    span(class = "caption-progress-count"):
      text progressText

    if self.progress.currentMilestone.len > 0:
      span(class = "caption-progress-current"):
        text $self.progress.currentMilestone

# ---------------------------------------------------------------------------
# Main render
# ---------------------------------------------------------------------------

method render*(self: CaptionBarProgressComponent): VNode =
  ## Legacy Karax render stub. The IsoNim renderer
  ## (renderIsoNimCaptionBarProgress) is the primary rendering path.
  ## This returns an empty container that GoldenLayout or vnodeToDom
  ## can work with.
  buildHtml(tdiv(class = "caption-progress-container"))

# ---------------------------------------------------------------------------
# IsoNim WebRenderer rendering
# ---------------------------------------------------------------------------

when defined(js):
  proc renderIsoNimCaptionBarProgress*(
      r: WebRenderer;
      container: isonim_dom.Element;
      self: CaptionBarProgressComponent) =
    ## Build the caption bar progress DOM using IsoNim WebRenderer,
    ## producing the same DOM structure as the legacy Karax render.
    ##
    ## Structure:
    ##   div.caption-progress-container[.caption-progress-active]
    ##     div.caption-progress-compact.{stateClass}
    ##       span.caption-progress-state  "Working"
    ##       span.caption-progress-task   "task name"  (if non-empty)
    ##       div.caption-progress-bar
    ##         div.caption-progress-bar-fill  (width: N%)
    ##       span.caption-progress-count  "3/7"
    ##       span.caption-progress-current "milestone"  (if non-empty)
    ##     div.caption-progress-milestones  (if expanded)
    ##       div.caption-progress-milestone-item.{statusClass} ...

    # Clear existing content for re-render.
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    let isActive = self.progress.state != AgentIdle
    let outerClass =
      if isActive: "caption-progress-container caption-progress-active"
      else: "caption-progress-container"

    let outer = ui(r):
      tdiv(class = outerClass):
        discard
    r.appendChild(container, outer)

    # Click handler: toggle workspace view
    isonim_dom.addEventListener(isonim_dom.Node(outer), cstring"click",
      proc(ev: isonim_dom.Event) =
        self.viewState.activeView =
          if self.viewState.activeView == UserWorkspace: AgentWorkspace
          else: UserWorkspace
        self.data.ipc.send(cstring(IPC_WORKSPACE_VIEW_SWITCH), js{
          "view": cstring($self.viewState.activeView),
          "sessionId": self.viewState.agentSessionId
        })
        redrawAll()
    )

    # Hover handlers: expand/collapse milestone list
    isonim_dom.addEventListener(isonim_dom.Node(outer), cstring"mouseenter",
      proc(ev: isonim_dom.Event) =
        self.expanded = true
        redrawAll()
    )
    isonim_dom.addEventListener(isonim_dom.Node(outer), cstring"mouseleave",
      proc(ev: isonim_dom.Event) =
        self.expanded = false
        redrawAll()
    )

    # -- Compact view --
    let stateClass = stateCssClass(self.progress.state)
    let compactClass = "caption-progress-compact " & $stateClass
    let compact = ui(r):
      tdiv(class = compactClass):
        discard
    r.appendChild(outer, compact)

    # State label
    let stateSpan = ui(r):
      span(class = "caption-progress-state"):
        text $stateLabel(self.progress.state)
    r.appendChild(compact, stateSpan)

    # Task name (if non-empty)
    if self.progress.taskName.len > 0:
      let taskSpan = ui(r):
        span(class = "caption-progress-task"):
          text $self.progress.taskName
      r.appendChild(compact, taskSpan)

    # Progress bar
    let pct = progressPercent(self.progress)
    let widthStr = fmt"{pct:.1f}%"
    let bar = ui(r):
      tdiv(class = "caption-progress-bar"):
        discard
    r.appendChild(compact, bar)
    let fill = ui(r):
      tdiv(class = "caption-progress-bar-fill"):
        discard
    r.setStyle(fill, "width", widthStr)
    r.appendChild(bar, fill)

    # Progress count
    let progressText =
      if self.progress.milestonesTotal > 0:
        fmt"{self.progress.milestonesCompleted}/{self.progress.milestonesTotal}"
      else:
        "0/0"
    let countSpan = ui(r):
      span(class = "caption-progress-count"):
        text progressText
    r.appendChild(compact, countSpan)

    # Current milestone (if non-empty)
    if self.progress.currentMilestone.len > 0:
      let currentSpan = ui(r):
        span(class = "caption-progress-current"):
          text $self.progress.currentMilestone
      r.appendChild(compact, currentSpan)

    # -- Milestone list (expanded only) --
    if self.expanded and self.progress.milestones.len > 0:
      let milestoneContainer = ui(r):
        tdiv(class = "caption-progress-milestones"):
          discard
      r.appendChild(outer, milestoneContainer)

      if self.progress.milestones.len == 0:
        let emptyDiv = ui(r):
          tdiv(class = "caption-progress-milestone-empty"):
            text "No milestones defined"
        r.appendChild(milestoneContainer, emptyDiv)
      else:
        for milestone in self.progress.milestones:
          let statusClass = milestoneStatusClass(milestone.status)
          let itemClass = "caption-progress-milestone-item " & $statusClass
          let item = ui(r):
            tdiv(class = itemClass):
              discard
          r.appendChild(milestoneContainer, item)

          let iconSpan = ui(r):
            span(class = "caption-progress-milestone-icon"):
              text $milestoneStatusIcon(milestone.status)
          r.appendChild(item, iconSpan)

          let contentSpan = ui(r):
            span(class = "caption-progress-milestone-content"):
              text $milestone.content
          r.appendChild(item, contentSpan)

          if milestone.priority == cstring"high":
            let prioritySpan = ui(r):
              span(class = "caption-progress-milestone-priority"):
                text "HIGH"
            r.appendChild(item, prioritySpan)

  proc tryMountCaptionBarProgress*(containerId: cstring;
                                    self: CaptionBarProgressComponent) =
    ## Mount the IsoNim caption bar progress into a DOM container.
    ## Called from layout.nim when the GL component is created.
    ## Re-renders on every call (used as the redraw callback).
    let container = isonim_dom.getElementById(isonim_dom.document, containerId)
    if isonim_dom.isNodeNil(isonim_dom.Node(container)):
      return
    let r = WebRenderer()
    renderIsoNimCaptionBarProgress(r, container, self)

# ---------------------------------------------------------------------------
# IPC handler
# ---------------------------------------------------------------------------

proc onAcpAgentProgress*(sender: js, response: JsObject) {.async.} =
  ## IPC handler for agent progress updates from the agent runtime.
  ## Parses the ``AgentProgress`` object from the IPC message and
  ## updates all CaptionBarProgressComponent instances.
  ##
  ## Expected IPC message shape:
  ## ```json
  ## {
  ##   "state": "AgentWorking",
  ##   "taskName": "Implement feature X",
  ##   "milestonesCompleted": 3,
  ##   "milestonesTotal": 7,
  ##   "currentMilestone": "write-tests",
  ##   "milestones": [...]
  ## }
  ## ```

  # Parse the state enum from the string value.
  let stateStr =
    if response.hasOwnProperty(cstring"state"):
      response[cstring"state"].to(cstring)
    else:
      cstring"AgentIdle"

  let state = case $stateStr
    of "AgentIdle": AgentIdle
    of "AgentInitializing": AgentInitializing
    of "AgentWorking": AgentWorking
    of "AgentWaitingInput": AgentWaitingInput
    of "AgentPaused": AgentPaused
    of "AgentCompleted": AgentCompleted
    of "AgentFailed": AgentFailed
    else: AgentIdle

  let taskName =
    if response.hasOwnProperty(cstring"taskName"):
      response[cstring"taskName"].to(cstring)
    else:
      cstring""

  let milestonesCompleted =
    if response.hasOwnProperty(cstring"milestonesCompleted"):
      response[cstring"milestonesCompleted"].to(int)
    else:
      0

  let milestonesTotal =
    if response.hasOwnProperty(cstring"milestonesTotal"):
      response[cstring"milestonesTotal"].to(int)
    else:
      0

  let currentMilestone =
    if response.hasOwnProperty(cstring"currentMilestone"):
      response[cstring"currentMilestone"].to(cstring)
    else:
      cstring""

  # Build the milestones list from the JSON array.
  var milestones: seq[Milestone] = @[]
  if response.hasOwnProperty(cstring"milestones"):
    let milestonesJs = response[cstring"milestones"]
    let length = milestonesJs.toJs.length.to(int)
    for i in 0 ..< length:
      let mJs = milestonesJs[i]
      let mId =
        if mJs.hasOwnProperty(cstring"id"): mJs[cstring"id"].to(cstring) else: cstring""
      let mContent =
        if mJs.hasOwnProperty(cstring"content"): mJs[cstring"content"].to(cstring) else: cstring""
      let mPriority =
        if mJs.hasOwnProperty(cstring"priority"): mJs[cstring"priority"].to(cstring) else: cstring"medium"
      let mStatusStr =
        if mJs.hasOwnProperty(cstring"status"): mJs[cstring"status"].to(cstring) else: cstring"MilestonePending"
      let mStatus = case $mStatusStr
        of "MilestonePending": MilestonePending
        of "MilestoneInProgress": MilestoneInProgress
        of "MilestoneCompleted": MilestoneCompleted
        of "MilestoneFailed": MilestoneFailed
        of "MilestoneSkipped": MilestoneSkipped
        else: MilestonePending
      milestones.add(Milestone(
        id: mId,
        content: mContent,
        priority: mPriority,
        status: mStatus
      ))

  let progress = AgentProgress(
    state: state,
    taskName: taskName,
    milestonesCompleted: milestonesCompleted,
    milestonesTotal: milestonesTotal,
    currentMilestone: currentMilestone,
    milestones: milestones
  )

  # Update all CaptionBarProgressComponent instances.
  for _, comp in data.ui.componentMapping[Content.CaptionBarProgress]:
    let captionBar = CaptionBarProgressComponent(comp)
    captionBar.updateProgress(progress)
  redrawAll()
