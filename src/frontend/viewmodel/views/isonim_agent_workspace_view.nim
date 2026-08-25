## views/isonim_agent_workspace_view.nim
##
## IsoNim DOM-rendering view for the Agent Workspace panel.

import std/[strformat, strutils]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/agent_workspace_vm

const AgentWorkspaceContainerClass* = "agent-workspace-container"
const AgentWorkspaceEmptyClass* = "agent-workspace-empty"
const AgentWorkspaceEmptyText* =
  "No agent workspace available. Start an agent session to see workspace files."
const AgentWorkspaceHeaderClass* = "agent-workspace-header"
const AgentWorkspaceSummaryClass* = "agent-workspace-summary"
const AgentWorkspaceBodyClass* = "agent-workspace-body"
const AgentWorkspaceFileListClass* = "agent-workspace-file-list"
const AgentWorkspaceEditorAreaClass* = "agent-workspace-editor-area"
const AgentWorkspaceEditorClass* = "agent-workspace-editor"
const AgentWorkspaceEditorPrefix* = "agent-workspace-editor"

type
  AgentWorkspaceCallbacks* = object
    onToggleView*: proc()
    onToggleOverlay*: proc()
    onSelectFile*: proc(index: int)
    afterDynamicRender*: proc()

proc editorId*(componentId: int): string =
  AgentWorkspaceEditorPrefix & "-" & $componentId

proc fileBasename*(path: string): string =
  let idx = path.rfind('/')
  if idx >= 0:
    path[idx + 1 .. ^1]
  else:
    path

proc viewLabel*(kind: AgentWorkspaceViewKind): string =
  case kind
  of awvkUserWorkspace: "User Workspace"
  of awvkAgentWorkspace: "Agent Workspace"

proc toggleViewText*(kind: AgentWorkspaceViewKind): string =
  case kind
  of awvkUserWorkspace: "Switch to Agent"
  of awvkAgentWorkspace: "Switch to User"

proc fileItemClass*(selected: bool): string =
  if selected:
    "agent-workspace-file-item selected"
  else:
    "agent-workspace-file-item"

proc hasCoverageData*(summary: AgentWorkspaceSummary): bool {.noSideEffect.} =
  ## Whether anything ever measured coverage for this workspace.
  ##
  ## Zero lines *known* is not zero lines covered.  The distinction is the
  ## whole point: the counters are filled by `CoverageUpdate` notifications
  ## from the agent runtime, and a workspace that has received none has no
  ## coverage rather than no *covered* lines.
  ##
  ## A non-zero `coveragePercent` counts on its own, even with no line totals
  ## beside it.  The rule this helper implements is about *absent* data, and a
  ## percentage somebody measured is present data however incompletely it was
  ## reported — suppressing it would be the mirror of the defect AA-2 removed,
  ## a real measurement hidden rather than an invented one shown.  The
  ## accumulating producer always writes all three together
  ## (`ui/agent_workspace.handleDeepReviewNotification`), so this arm only ever
  ## catches a partially-filled summary; it is deliberately generous there.
  summary.totalLinesCovered + summary.totalLinesUncovered > 0 or
    summary.coveragePercent > 0.0

proc hasTestResults*(summary: AgentWorkspaceSummary): bool {.noSideEffect.} =
  ## Whether any test result was ever reported for this workspace.
  ##
  ## The counters are only ever incremented by a `TestComplete` notification
  ## (`ui/agent_workspace.handleDeepReviewNotification`), so all-zero means
  ## "no suite reported", never "a suite ran and nothing passed".
  summary.testsRun + summary.testsPassed + summary.testsFailed > 0

proc summaryCoverageText*(summary: AgentWorkspaceSummary): string =
  ## The coverage figure, or nothing at all.
  ##
  ## AA-2 / AA-1's preserved rule: absent data is stated, never rendered as a
  ## zero that reads as a measurement.  This panel used to print "100.0%"
  ## whenever review mode was on and "0.0%" whenever it was off — both derived
  ## from a boolean, for a workspace nothing had measured
  ## (`Agent-Activity-Panel.milestones.org`, "a live violation of it
  ## elsewhere").  The fabrication is gone from the producer; this is the rule
  ## executing in the renderer, so a future producer cannot reintroduce it
  ## silently.
  ##
  ## The same decision as `review_entry.coverageText`, which returns an empty
  ## badge rather than "0/0" for a file with no coverage, and the same one
  ## `test_run_summary_vm.summaryText` makes for a run that reported no tests
  ## — with one difference that is deliberate.  There, a run *happened*, so
  ## the absence gets a sentence ("No tests reported").  Here nothing
  ## happened, so there is nothing to make a sentence about and the item is
  ## simply not rendered.
  if not summary.hasCoverageData:
    return ""
  fmt"{summary.coveragePercent:.1f}%"

proc testsText*(summary: AgentWorkspaceSummary): string =
  ## "<passed>/<run> passed", or nothing at all when no suite reported.
  ## See `summaryCoverageText` for why the empty string rather than "0/0".
  if not summary.hasTestResults:
    return ""
  $summary.testsPassed & "/" & $summary.testsRun & " passed"

proc functionsTracedText*(summary: AgentWorkspaceSummary): string
    {.noSideEffect.} =
  ## The traced-function count, or nothing.
  ##
  ## Included in the same rule for the same reason: it was fabricated from
  ## `deepReviewMode` alongside the other two, and "Functions traced: 0" for a
  ## workspace nothing traced is the same false measurement in a third place.
  if summary.functionsTraced <= 0:
    return ""
  $summary.functionsTraced

proc overlayToggleText*(enabled: bool): string =
  if enabled:
    "Hide Coverage"
  else:
    "Show Coverage"

proc renderFileRow(r: MockRenderer; vm: AgentWorkspaceVM; index: int;
                   entry: AgentWorkspaceFileEntry;
                   callbacks: AgentWorkspaceCallbacks): MockNode =
  let selected = index == vm.selectedFileIndex.val
  let fileIdx = index
  ui(r):
    tdiv(class = fileItemClass(selected),
         onclick = proc() =
           vm.setSelectedFileIndex(fileIdx)
           if callbacks.onSelectFile != nil:
             callbacks.onSelectFile(fileIdx)):
      tdiv(class = "agent-workspace-file-name"):
        text fileBasename(entry.path)
      tdiv(class = "agent-workspace-file-path"):
        text entry.path
      span(class = "agent-workspace-coverage-badge"):
        text coverageBadgeText(entry)
      if entry.hasFlow:
        span(class = "agent-workspace-flow-badge"):
          text "flow"

proc renderAgentWorkspacePanel*(r: MockRenderer; vm: AgentWorkspaceVM;
    componentId: int; callbacks: AgentWorkspaceCallbacks =
      AgentWorkspaceCallbacks()): MockNode =
  var header: MockNode
  var summary: MockNode
  var body: MockNode

  let panel = ui(r):
    tdiv(class = AgentWorkspaceContainerClass):
      tdiv(ref = header):
        discard
      tdiv(ref = summary):
        discard
      tdiv(ref = body):
        discard

  createRenderEffect proc() =
    r.clearChildren(header)
    r.clearChildren(summary)
    r.clearChildren(body)

    if not vm.hasWorkspace.val:
      let emptyNode = ui(r):
        tdiv(class = AgentWorkspaceEmptyClass):
          text AgentWorkspaceEmptyText
      r.appendChild(body, emptyNode)
      return

    let currentKind = vm.viewKind.val
    let currentPath = vm.workspacePath.val
    let currentSummary = vm.summary.val
    let overlayEnabled = vm.coverageOverlayEnabled.val

    let headerNode = ui(r):
      tdiv(class = AgentWorkspaceHeaderClass):
        span(class = "agent-workspace-header-label"):
          text viewLabel(currentKind)
        if currentPath.len > 0:
          span(class = "agent-workspace-header-path"):
            text currentPath
        tdiv(class = "agent-workspace-view-toggle",
             onclick = proc() =
               if vm.viewKind.val == awvkUserWorkspace:
                 vm.setViewKind(awvkAgentWorkspace)
               else:
                 vm.setViewKind(awvkUserWorkspace)
               if callbacks.onToggleView != nil:
                 callbacks.onToggleView()):
          text toggleViewText(currentKind)
    r.appendChild(header, headerNode)

    let summaryNode = ui(r):
      tdiv(class = AgentWorkspaceSummaryClass):
        # Each item renders only when there is a measurement behind it.  A
        # rendered "Coverage: 0.0%" / "Tests: 0/0 passed" for a workspace
        # nothing measured is the zero-that-reads-as-a-measurement AA-1
        # preserved its rule against and AA-2 owns; see `summaryCoverageText`.
        if summaryCoverageText(currentSummary).len > 0:
          span(class = "agent-workspace-summary-item"):
            text "Coverage: " & summaryCoverageText(currentSummary)
        if testsText(currentSummary).len > 0:
          span(class = "agent-workspace-summary-item"):
            text "Tests: " & testsText(currentSummary)
        if functionsTracedText(currentSummary).len > 0:
          span(class = "agent-workspace-summary-item"):
            text "Functions traced: " & functionsTracedText(currentSummary)
        tdiv(class = "agent-workspace-overlay-toggle",
             onclick = proc() =
               vm.toggleCoverageOverlay()
               if callbacks.onToggleOverlay != nil:
                 callbacks.onToggleOverlay()):
          text overlayToggleText(overlayEnabled)
    r.appendChild(summary, summaryNode)

    var fileList: MockNode
    let bodyNode = ui(r):
      tdiv(class = AgentWorkspaceBodyClass):
        tdiv(ref = fileList, class = AgentWorkspaceFileListClass)
        tdiv(class = AgentWorkspaceEditorAreaClass):
          tdiv(class = AgentWorkspaceEditorClass,
               id = editorId(componentId))
    for i, entry in vm.files.val:
      r.appendChild(fileList, renderFileRow(r, vm, i, entry, callbacks))
    r.appendChild(body, bodyNode)

  panel

when defined(js):
  proc renderFileRow(r: WebRenderer; vm: AgentWorkspaceVM; index: int;
                     entry: AgentWorkspaceFileEntry;
                     callbacks: AgentWorkspaceCallbacks):
      isonim_dom.Element =
    let selected = index == vm.selectedFileIndex.val
    let fileIdx = index
    ui(r):
      tdiv(class = fileItemClass(selected),
           onclick = proc() =
             vm.setSelectedFileIndex(fileIdx)
             if callbacks.onSelectFile != nil:
               callbacks.onSelectFile(fileIdx)):
        tdiv(class = "agent-workspace-file-name"):
          text fileBasename(entry.path)
        tdiv(class = "agent-workspace-file-path"):
          text entry.path
        span(class = "agent-workspace-coverage-badge"):
          text coverageBadgeText(entry)
        if entry.hasFlow:
          span(class = "agent-workspace-flow-badge"):
            text "flow"

  proc renderAgentWorkspacePanel*(r: WebRenderer; vm: AgentWorkspaceVM;
      componentId: int; callbacks: AgentWorkspaceCallbacks =
        AgentWorkspaceCallbacks()): isonim_dom.Element =
    var header: isonim_dom.Element
    var summary: isonim_dom.Element
    var body: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = AgentWorkspaceContainerClass):
        tdiv(ref = header):
          discard
        tdiv(ref = summary):
          discard
        tdiv(ref = body):
          discard

    createRenderEffect proc() =
      # Host slots captured by `ref` are intentionally cleared here; all
      # replacement children are built through the IsoNim DSL below.
      r.clearChildren(header)
      r.clearChildren(summary)
      r.clearChildren(body)

      if not vm.hasWorkspace.val:
        let empty = ui(r):
          tdiv(class = AgentWorkspaceEmptyClass):
            text AgentWorkspaceEmptyText
        r.appendChild(body, empty)
        return

      let currentKind = vm.viewKind.val
      let currentPath = vm.workspacePath.val
      let currentSummary = vm.summary.val
      let overlayEnabled = vm.coverageOverlayEnabled.val

      let headerNode = ui(r):
        tdiv(class = AgentWorkspaceHeaderClass):
          span(class = "agent-workspace-header-label"):
            text viewLabel(currentKind)
          if currentPath.len > 0:
            span(class = "agent-workspace-header-path"):
              text currentPath
          tdiv(class = "agent-workspace-view-toggle",
               onclick = proc() =
                 if vm.viewKind.val == awvkUserWorkspace:
                   vm.setViewKind(awvkAgentWorkspace)
                 else:
                   vm.setViewKind(awvkUserWorkspace)
                 if callbacks.onToggleView != nil:
                   callbacks.onToggleView()):
            text toggleViewText(currentKind)
      r.appendChild(header, headerNode)

      let summaryNode = ui(r):
        tdiv(class = AgentWorkspaceSummaryClass):
          # See the MockRenderer branch above: an item without a measurement
          # behind it is not rendered at all.
          if summaryCoverageText(currentSummary).len > 0:
            span(class = "agent-workspace-summary-item"):
              text "Coverage: " & summaryCoverageText(currentSummary)
          if testsText(currentSummary).len > 0:
            span(class = "agent-workspace-summary-item"):
              text "Tests: " & testsText(currentSummary)
          if functionsTracedText(currentSummary).len > 0:
            span(class = "agent-workspace-summary-item"):
              text "Functions traced: " & functionsTracedText(currentSummary)
          tdiv(class = "agent-workspace-overlay-toggle",
               onclick = proc() =
                 vm.toggleCoverageOverlay()
                 if callbacks.onToggleOverlay != nil:
                   callbacks.onToggleOverlay()):
            text overlayToggleText(overlayEnabled)
      r.appendChild(summary, summaryNode)

      var fileList: isonim_dom.Element
      let bodyNode = ui(r):
        tdiv(class = AgentWorkspaceBodyClass):
          tdiv(ref = fileList, class = AgentWorkspaceFileListClass)
          tdiv(class = AgentWorkspaceEditorAreaClass):
            tdiv(class = AgentWorkspaceEditorClass,
                 id = editorId(componentId))
      r.appendChild(body, bodyNode)

      for i, entry in vm.files.val:
        r.appendChild(fileList, renderFileRow(r, vm, i, entry, callbacks))

      if callbacks.afterDynamicRender != nil:
        callbacks.afterDynamicRender()

    panel

  proc mountIsoNimAgentWorkspacePanel*(container: isonim_dom.Element;
                                       vm: AgentWorkspaceVM;
                                       componentId: int;
                                       callbacks: AgentWorkspaceCallbacks =
                                         AgentWorkspaceCallbacks()) =
    let r = WebRenderer()
    let panel = renderAgentWorkspacePanel(r, vm, componentId, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
