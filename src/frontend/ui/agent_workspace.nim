## Agent Workspace view component for the CodeTracer GUI (M9).
##
## Displays the agent's working directory files with DeepReview coverage
## annotations overlaid on a Monaco editor. This component is activated
## when the user clicks the caption bar progress indicator to switch
## from their own workspace to the agent's workspace view.
##
## Key features:
## - File list sidebar showing agent workspace files with coverage badges
## - Monaco editor with coverage line highlighting (reuses DeepReview
##   decoration patterns from ``deepreview.nim``)
## - Real-time updates via ``DeepReviewNotification`` messages from the
##   ACP agent runtime
## - Test coverage overlay toggle
## - Workspace view switching via ``WorkspaceViewState``
##
## The component follows the same architecture as ``DeepReviewComponent``
## (offline Monaco viewer) but adds real-time notification handling and
## integration with the ACP session lifecycle.
##
## Reference: codetracer-specs/DeepReview/Agentic-Coding-Integration.md

import
  ui_imports, ../utils, ../communication,
  std/[strformat, jsconsole]


# ---------------------------------------------------------------------------
# Monaco FFI helpers (similar to deepreview.nim but prefixed to avoid
# symbol clashes when both modules are compiled together)
# ---------------------------------------------------------------------------

proc awCreateMonacoEditor(divId: cstring, options: JsObject): MonacoEditor
  {.importjs: "monaco.editor.create(document.getElementById(#), #)".}

proc awDeltaDecorations(editor: MonacoEditor, oldDecorations: js, newDecorations: js): js
  {.importjs: "#.deltaDecorations(#, #)".}

proc awSetMonacoValue(editor: MonacoEditor, value: cstring)
  {.importjs: "#.setValue(#)".}

proc awGetMonacoModel(editor: MonacoEditor): js
  {.importjs: "#.getModel()".}

proc awSetModelLanguage(model: js, language: cstring)
  {.importjs: "monaco.editor.setModelLanguage(#, #)".}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc selectedFileEntry(self: AgentWorkspaceComponent): ActivityFileEntry =
  ## Return the currently selected file entry.
  ## Returns a default (empty) entry if no files are present.
  if self.fileEntries.len == 0:
    return ActivityFileEntry()
  let idx = clamp(self.selectedFileIndex, 0, self.fileEntries.len - 1)
  return self.fileEntries[idx]

proc coverageBadgeText(entry: ActivityFileEntry): cstring =
  ## Format coverage as "covered/total" for display in the file list badge.
  if entry.totalLines == 0:
    return cstring"--"
  result = cstring(fmt"{entry.coveredLines}/{entry.totalLines}")

proc guessLanguageFromPath(path: cstring): cstring =
  ## Heuristically map a file extension to a Monaco language id.
  ## This mirrors the logic in ``deepreview.nim`` for consistency.
  let s = $path
  let dotIdx = s.rfind('.')
  if dotIdx < 0:
    return cstring"plaintext"
  let ext = s[dotIdx + 1 .. ^1]
  case ext
  of "rs": return cstring"rust"
  of "nim": return cstring"nim"
  of "py": return cstring"python"
  of "js": return cstring"javascript"
  of "ts": return cstring"typescript"
  of "c", "h": return cstring"c"
  of "cpp", "hpp", "cxx", "hxx", "cc": return cstring"cpp"
  of "go": return cstring"go"
  of "java": return cstring"java"
  of "rb": return cstring"ruby"
  of "json": return cstring"json"
  of "yaml", "yml": return cstring"yaml"
  of "toml": return cstring"toml"
  of "md": return cstring"markdown"
  of "sh", "bash": return cstring"shell"
  else: return cstring"plaintext"

proc fileBasename(path: cstring): cstring =
  ## Extract the filename from a path for sidebar display.
  let s = $path
  let idx = s.rfind('/')
  if idx >= 0:
    return cstring(s[idx + 1 .. ^1])
  return path

# ---------------------------------------------------------------------------
# Notification handling
# ---------------------------------------------------------------------------

proc handleDeepReviewNotification*(self: AgentWorkspaceComponent, notification: DeepReviewNotification) =
  ## Process an incoming DeepReview notification from the ACP agent runtime.
  ## Updates the component state and triggers a redraw.
  self.notifications.add(notification)

  case notification.kind
  of CoverageUpdate:
    # Update the file entry's coverage counts if we already have it.
    for i in 0 ..< self.fileEntries.len:
      if self.fileEntries[i].path == notification.filePath:
        self.fileEntries[i].coveredLines = notification.linesCovered.len
        self.fileEntries[i].totalLines =
          notification.linesCovered.len + notification.linesUncovered.len
        break
    # Update the summary.
    var totalCovered = 0
    var totalUncovered = 0
    for entry in self.fileEntries:
      totalCovered += entry.coveredLines
      totalUncovered += (entry.totalLines - entry.coveredLines)
    self.drSummary.totalLinesCovered = totalCovered
    self.drSummary.totalLinesUncovered = totalUncovered
    let totalLines = totalCovered + totalUncovered
    self.drSummary.coveragePercent =
      if totalLines > 0: (totalCovered.float / totalLines.float) * 100.0
      else: 0.0

  of FlowTraceUpdate:
    # Update the file entry's flow flag.
    for i in 0 ..< self.fileEntries.len:
      if self.fileEntries[i].path == notification.flowFilePath:
        self.fileEntries[i].hasFlow = true
        break
    self.drSummary.functionsTraced += 1

  of TestComplete:
    self.drSummary.testsRun += 1
    if notification.passed:
      self.drSummary.testsPassed += 1
    else:
      self.drSummary.testsFailed += 1

  of CollectionComplete:
    # Final summary; could trigger a full refresh.
    discard

# ---------------------------------------------------------------------------
# Decoration builders (coverage overlay)
# ---------------------------------------------------------------------------

proc buildCoverageOverlay(self: AgentWorkspaceComponent): seq[JsObject] =
  ## Build Monaco decoration descriptors for the test coverage overlay.
  ## Uses the same CSS classes as the standalone DeepReview viewer so
  ## that styling is consistent.
  result = @[]
  if not self.coverageOverlayEnabled:
    return

  # For each notification of type CoverageUpdate matching the selected file,
  # build line decorations.
  let selectedPath = self.selectedFileEntry().path
  if selectedPath.len == 0:
    return

  for notif in self.notifications:
    if notif.kind != CoverageUpdate:
      continue
    if notif.filePath != selectedPath:
      continue

    # Covered lines get the "executed" decoration.
    for line in notif.linesCovered:
      if line < 1:
        continue
      result.add(js{
        range: js{
          startLineNumber: line,
          startColumn: 1,
          endLineNumber: line,
          endColumn: 1
        },
        options: js{
          isWholeLine: true,
          className: cstring"deepreview-line-executed",
          glyphMarginClassName: cstring"deepreview-line-executed"
        }
      })

    # Uncovered lines get the "unreachable" decoration.
    for line in notif.linesUncovered:
      if line < 1:
        continue
      result.add(js{
        range: js{
          startLineNumber: line,
          startColumn: 1,
          endLineNumber: line,
          endColumn: 1
        },
        options: js{
          isWholeLine: true,
          className: cstring"deepreview-line-unreachable",
          glyphMarginClassName: cstring"deepreview-line-unreachable"
        }
      })

proc updateDecorations(self: AgentWorkspaceComponent) =
  ## Recompute and apply all Monaco decorations for the selected file.
  if not self.editorInitialized or self.editor.isNil:
    return

  let allDecorations = self.buildCoverageOverlay()
  let oldIds = if self.currentDecorationIds.isNil: newJsObject() else: self.currentDecorationIds
  self.currentDecorationIds = self.editor.awDeltaDecorations(oldIds, allDecorations.toJs)

# ---------------------------------------------------------------------------
# Component lifecycle
# ---------------------------------------------------------------------------

method register*(self: AgentWorkspaceComponent, api: MediatorWithSubscribers) =
  ## Register the component with the mediator event system.
  self.api = api

proc initEditor(self: AgentWorkspaceComponent) =
  ## Lazily initialise the Monaco editor after the DOM container is rendered.
  if self.editorInitialized:
    return

  let divId = cstring(fmt"agent-workspace-editor-{self.id}")
  let el = document.getElementById(divId)
  if el.isNil:
    return

  let entry = self.selectedFileEntry()
  let lang = if entry.path.len == 0: cstring"plaintext" else: guessLanguageFromPath(entry.path)
  let theme = if self.data.config.theme == cstring"default_white":
    cstring"codetracerWhite"
  else:
    cstring"codetracerDark"

  self.editor = awCreateMonacoEditor(divId, js{
    value: cstring"// Select a file to view agent workspace content",
    language: lang,
    readOnly: true,
    theme: theme,
    automaticLayout: true,
    folding: true,
    fontSize: self.data.ui.fontSize,
    minimap: js{ enabled: false },
    renderLineHighlight: cstring"none",
    lineDecorationsWidth: 20,
    scrollBeyondLastLine: false,
    contextmenu: false,
    glyphMargin: true
  })
  self.editorInitialized = true
  self.currentDecorationIds = newJsObject()
  self.updateDecorations()

proc switchToFile(self: AgentWorkspaceComponent, fileIndex: int) =
  ## Switch the editor to display a different file from the agent workspace.
  if fileIndex == self.selectedFileIndex and self.editorInitialized:
    return
  self.selectedFileIndex = fileIndex

  if self.editorInitialized and not self.editor.isNil:
    let entry = self.selectedFileEntry()
    if entry.path.len > 0:
      # In a real implementation we would load the file content from the
      # agent workspace directory. For now, show a placeholder.
      let placeholder = cstring(fmt"// Agent workspace file: {entry.path}")
      self.editor.awSetMonacoValue(placeholder)
      let lang = guessLanguageFromPath(entry.path)
      let model = self.editor.awGetMonacoModel()
      if not model.isNil:
        awSetModelLanguage(model, lang)
    self.updateDecorations()

# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------

proc renderSummaryBar(self: AgentWorkspaceComponent): VNode =
  ## Render the top summary bar with coverage and test statistics.
  let summary = self.drSummary
  let coverageText = fmt"{summary.coveragePercent:.1f}%"
  let testsText = fmt"{summary.testsPassed}/{summary.testsRun} passed"

  buildHtml(tdiv(class = "agent-workspace-summary")):
    span(class = "agent-workspace-summary-item"):
      text fmt"Coverage: {coverageText}"
    span(class = "agent-workspace-summary-item"):
      text fmt"Tests: {testsText}"
    span(class = "agent-workspace-summary-item"):
      text fmt"Functions traced: {summary.functionsTraced}"
    # Coverage overlay toggle.
    tdiv(
      class = "agent-workspace-overlay-toggle",
      onclick = proc(ev: Event, n: VNode) =
        self.coverageOverlayEnabled = not self.coverageOverlayEnabled
        self.updateDecorations()
        redrawAll()
    ):
      let toggleLabel =
        if self.coverageOverlayEnabled: "Hide Coverage"
        else: "Show Coverage"
      text toggleLabel

proc renderFileList(self: AgentWorkspaceComponent): VNode =
  ## Render the file list sidebar with coverage badges.
  buildHtml(tdiv(class = "agent-workspace-file-list")):
    for i, entry in self.fileEntries:
      let isSelected = (i == self.selectedFileIndex)
      let selectedClass = if isSelected: " selected" else: ""
      let fileIdx = i
      tdiv(
        class = cstring(fmt"agent-workspace-file-item{selectedClass}"),
        onclick = proc(ev: Event, n: VNode) =
          self.switchToFile(fileIdx)
          redrawAll()
      ):
        tdiv(class = "agent-workspace-file-name"):
          text fileBasename(entry.path)
        tdiv(class = "agent-workspace-file-path"):
          text $entry.path
        span(class = "agent-workspace-coverage-badge"):
          text coverageBadgeText(entry)
        if entry.hasFlow:
          span(class = "agent-workspace-flow-badge"):
            text "flow"

proc renderWorkspaceHeader(self: AgentWorkspaceComponent): VNode =
  ## Render the header bar with workspace path and view toggle.
  let viewLabel = case self.viewState.activeView
    of UserWorkspace: "User Workspace"
    of AgentWorkspace: "Agent Workspace"

  buildHtml(tdiv(class = "agent-workspace-header")):
    span(class = "agent-workspace-header-label"):
      text viewLabel
    if self.viewState.agentWorkspacePath.len > 0:
      span(class = "agent-workspace-header-path"):
        text $self.viewState.agentWorkspacePath
    tdiv(
      class = "agent-workspace-view-toggle",
      onclick = proc(ev: Event, n: VNode) =
        # Toggle between user and agent workspace views.
        self.viewState.activeView =
          if self.viewState.activeView == UserWorkspace: AgentWorkspace
          else: UserWorkspace
        # Notify main process of the view switch via IPC.
        self.data.ipc.send(cstring(IPC_WORKSPACE_VIEW_SWITCH), js{
          "view": cstring($self.viewState.activeView),
          "sessionId": self.viewState.agentSessionId
        })
        redrawAll()
    ):
      let toggleText =
        if self.viewState.activeView == UserWorkspace: "Switch to Agent"
        else: "Switch to User"
      text toggleText

# ---------------------------------------------------------------------------
# Main render
# ---------------------------------------------------------------------------

method render*(self: AgentWorkspaceComponent): VNode =
  ## Render the full agent workspace view with header, summary, file list,
  ## and Monaco editor with coverage overlay.

  # Schedule editor initialisation after the DOM has been rendered.
  if not self.kxi.isNil:
    self.kxi.afterRedraws.add(proc() =
      self.initEditor()
    )

  if self.fileEntries.len == 0 and self.viewState.agentSessionId.len == 0:
    return buildHtml(tdiv(class = "agent-workspace-container")):
      tdiv(class = "agent-workspace-empty"):
        text "No agent workspace available. Start an agent session to see workspace files."

  result = buildHtml(tdiv(class = "agent-workspace-container")):
    renderWorkspaceHeader(self)
    renderSummaryBar(self)
    tdiv(class = "agent-workspace-body"):
      renderFileList(self)
      tdiv(class = "agent-workspace-editor-area"):
        tdiv(
          class = "agent-workspace-editor",
          id = cstring(fmt"agent-workspace-editor-{self.id}")
        )

# ---------------------------------------------------------------------------
# IPC handlers
# ---------------------------------------------------------------------------

proc onAcpDeepReviewNotification*(sender: js, response: JsObject) {.async.} =
  ## IPC handler for DeepReview notifications from the agent runtime.
  ## Finds the matching AgentWorkspaceComponent by session id and
  ## dispatches the notification.
  let sessionId =
    if response.hasOwnProperty(cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  if sessionId.len == 0:
    return

  # Find the workspace component for this session.
  for _, comp in data.ui.componentMapping[Content.AgentWorkspace]:
    let workspace = AgentWorkspaceComponent(comp)
    if workspace.viewState.agentSessionId == sessionId:
      # Parse the notification kind from the response.
      let kindStr =
        if response.hasOwnProperty(cstring"kind"):
          response[cstring"kind"].to(cstring)
        else:
          cstring""

      # Build a minimal notification from the IPC message.
      # In a full implementation, this would deserialize the full
      # DeepReviewNotification object from JSON.
      case $kindStr
      of "CoverageUpdate":
        var linesCovered: seq[int] = @[]
        var linesUncovered: seq[int] = @[]
        # Parse arrays from the response (simplified).
        let notification = DeepReviewNotification(
          sessionId: sessionId,
          kind: CoverageUpdate,
          filePath: response[cstring"filePath"].to(cstring),
          linesCovered: linesCovered,
          linesUncovered: linesUncovered
        )
        workspace.handleDeepReviewNotification(notification)
      of "TestComplete":
        let notification = DeepReviewNotification(
          sessionId: sessionId,
          kind: TestComplete,
          testName: response[cstring"testName"].to(cstring),
          passed: response[cstring"passed"].to(bool),
          durationMs: response[cstring"durationMs"].to(int),
          traceContextId: response[cstring"traceContextId"].to(cstring)
        )
        workspace.handleDeepReviewNotification(notification)
      of "CollectionComplete":
        let notification = DeepReviewNotification(
          sessionId: sessionId,
          kind: CollectionComplete,
          totalFiles: response[cstring"totalFiles"].to(int),
          totalFunctions: response[cstring"totalFunctions"].to(int),
          totalTests: response[cstring"totalTests"].to(int)
        )
        workspace.handleDeepReviewNotification(notification)
      else:
        console.log cstring(fmt"[agent-workspace] unknown notification kind: {kindStr}")
      redrawAll()
      break
