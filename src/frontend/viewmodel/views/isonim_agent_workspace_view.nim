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

proc summaryCoverageText*(summary: AgentWorkspaceSummary): string =
  fmt"{summary.coveragePercent:.1f}%"

proc testsText*(summary: AgentWorkspaceSummary): string =
  $summary.testsPassed & "/" & $summary.testsRun & " passed"

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
        span(class = "agent-workspace-summary-item"):
          text "Coverage: " & summaryCoverageText(currentSummary)
        span(class = "agent-workspace-summary-item"):
          text "Tests: " & testsText(currentSummary)
        span(class = "agent-workspace-summary-item"):
          text "Functions traced: " & $currentSummary.functionsTraced
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
          span(class = "agent-workspace-summary-item"):
            text "Coverage: " & summaryCoverageText(currentSummary)
          span(class = "agent-workspace-summary-item"):
            text "Tests: " & testsText(currentSummary)
          span(class = "agent-workspace-summary-item"):
            text "Functions traced: " & $currentSummary.functionsTraced
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
