## DeepReview component for the CodeTracer GUI.
##
## Renders as a Golden Layout panel containing the Modified Files sidebar
## with per-file coverage summary, execution/iteration sliders, call trace,
## and mode switching controls.  In Full Files mode, file selection opens
## the file in the standard CodeTracer GL editor panel with diff and
## coverage decorations applied via Monaco's decoration API.  In Unified
## Diff mode, the DOM-based diff view is rendered within this panel.
##
## When ``glEmbedded`` is true, the component runs alongside the VCS panel
## which owns file selection via ``data.deepReviewSelectedFileIndex``.  The
## component's own file-list sidebar is hidden and it renders only the
## unified diff / editor area for the currently selected file.
##
## The component is activated via the ``--deepreview <path>`` CLI argument.
## It operates in a read-only, offline mode without a debugger connection.

import
  ui_imports, ../utils, ../communication,
  std/[strformat, jsconsole]

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  DeepReviewPanelViewMode, DeepReviewTraceContextEntry, DeepReviewFileEntry,
  DeepReviewFlowValueEntry, DeepReviewDiffLineEntry, DeepReviewHunkEntry,
  DeepReviewUnifiedFileEntry, DeepReviewCallNodeEntry,
  drpvmFullFiles, drpvmUnified
import ../viewmodel/viewmodels/deepreview_vm
when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil
  from ../viewmodel/views/isonim_deepreview_view import
    mountIsoNimDeepReviewPanel, DeepReviewCallbacks

type langstring = cstring

var deepReviewVMStore: ReplayDataStore
var deepReviewVMInstances*: JsAssoc[int, DeepReviewVM] =
  JsAssoc[int, DeepReviewVM]{}
var deepReviewComponentRefs: JsAssoc[int, DeepReviewComponent] =
  JsAssoc[int, DeepReviewComponent]{}
var isoNimDeepReviewMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc syncLegacyDeepReviewIntoVM*(self: DeepReviewComponent)
proc tryMountIsoNimDeepReviewPanel*(componentId: int)

# ---------------------------------------------------------------------------
# Monaco FFI helpers
# ---------------------------------------------------------------------------

proc drCreateMonacoEditor(divId: cstring, options: JsObject): MonacoEditor
  {.importjs: "monaco.editor.create(document.getElementById(#), #)".}

proc drCreateModel(value, language: cstring): js
  {.importjs: "monaco.editor.createModel(#, #)".}

proc drSetModelLanguage(model: js, language: cstring)
  {.importjs: "monaco.editor.setModelLanguage(#, #)".}

proc drGetMonacoModel(editor: MonacoEditor): js
  {.importjs: "#.getModel()".}

proc drSetMonacoValue(editor: MonacoEditor, value: cstring)
  {.importjs: "#.setValue(#)".}

proc drDeltaDecorations(editor: MonacoEditor, oldDecorations: js, newDecorations: js): js
  {.importjs: "#.deltaDecorations(#, #)".}

proc drCreateDecorationsCollection(editor: MonacoEditor, decorations: js): js
  {.importjs: "#.createDecorationsCollection(#)".}

proc drCollectionSet(collection: js, decorations: js)
  {.importjs: "#.set(#)".}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc effectiveFileIndex(self: DeepReviewComponent): int =
  ## Return the effective selected file index.  In GL-embedded mode the
  ## VCS panel owns file selection via ``data.deepReviewSelectedFileIndex``;
  ## otherwise the component's own ``selectedFileIndex`` is used.
  if self.glEmbedded:
    return self.data.deepReviewSelectedFileIndex
  return self.selectedFileIndex

proc selectedFile(self: DeepReviewComponent): DeepReviewFileData =
  ## Return the currently selected file, or nil if no files are present.
  if self.drData.isNil or self.drData.files.len == 0:
    return nil
  let idx = self.effectiveFileIndex()
  if idx >= self.drData.files.len:
    return self.drData.files[0]
  return self.drData.files[idx]

proc coverageSummary(file: DeepReviewFileData): cstring =
  ## Compute a human-readable coverage summary string like "42/60".
  if file.isNil or file.coverage.len == 0:
    return cstring"--"
  var executed = 0
  for cov in file.coverage:
    if cov.executed:
      executed += 1
  result = cstring(fmt"{executed}/{file.coverage.len}")

proc fileBasename(path: langstring): cstring =
  ## Extract the filename from a path for sidebar display.
  let s = $path
  let idx = s.rfind('/')
  if idx >= 0:
    return cstring(s[idx + 1 .. ^1])
  return cstring(s)

proc guessLanguageFromPath(path: langstring): cstring =
  ## Heuristically map a file extension to a Monaco language id.
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

proc safeStr(s: cstring): string =
  if s.isNil:
    ""
  else:
    $s

proc legacyViewModeToVm(mode: DeepReviewViewMode): DeepReviewPanelViewMode =
  case mode
  of FullFiles: drpvmFullFiles
  of Unified: drpvmUnified

proc vmViewModeToLegacy(mode: DeepReviewPanelViewMode): DeepReviewViewMode =
  case mode
  of drpvmFullFiles: FullFiles
  of drpvmUnified: Unified

proc buildSourcePlaceholder(file: DeepReviewFileData): cstring =
  ## Build a placeholder source text using line numbers from coverage
  ## and flow data, since the JSON export does not include file content.
  ## Lines without any data are left empty.
  if file.isNil:
    return cstring"// No file selected"

  # Determine the maximum line number we know about.
  var maxLine = 0
  for cov in file.coverage:
    if cov.line > maxLine:
      maxLine = cov.line
  for fn in file.functions:
    if fn.endLine > maxLine:
      maxLine = fn.endLine
  for flow in file.flow:
    for step in flow.steps:
      if step.line > maxLine:
        maxLine = step.line

  if maxLine == 0:
    return cstring"// Empty file (no coverage or flow data)"

  # Build lines with annotations derived from coverage and flow values.
  var lines = newSeq[string](maxLine)
  for i in 0 ..< maxLine:
    lines[i] = ""

  # Annotate coverage status.
  for cov in file.coverage:
    if cov.line >= 1 and cov.line <= maxLine:
      let idx = cov.line - 1
      if cov.unreachable:
        lines[idx] = "// [unreachable]"
      elif cov.executed:
        lines[idx] = fmt"// [executed x{cov.executionCount}]"
      elif cov.partial:
        lines[idx] = "// [partial]"

  # Annotate function boundaries.
  for fn in file.functions:
    if fn.startLine >= 1 and fn.startLine <= maxLine:
      let idx = fn.startLine - 1
      let existing = lines[idx]
      let fnInfo = fmt"fn {fn.name} (calls: {fn.callCount})"
      lines[idx] = if existing.len > 0: existing & "  " & fnInfo else: fnInfo

  result = cstring(lines.join("\n"))

# ---------------------------------------------------------------------------
# Decoration builders
# ---------------------------------------------------------------------------

proc buildCoverageDecorations(file: DeepReviewFileData): seq[JsObject] =
  ## Build Monaco decoration descriptors for line coverage highlighting.
  result = @[]
  if file.isNil:
    return

  for i in 0 ..< file.coverage.len:
    let cov = file.coverage[i]
    if cov.line < 1:
      continue
    var className: cstring
    if cov.unreachable:
      className = cstring"deepreview-line-unreachable"
    elif cov.partial:
      # Partial takes priority over executed — a line that was only
      # executed in some code paths should be highlighted as partial.
      className = cstring"deepreview-line-partial"
    elif cov.executed:
      className = cstring"deepreview-line-executed"
    else:
      continue

    result.add(js{
      range: js{
        startLineNumber: cov.line,
        startColumn: 1,
        endLineNumber: cov.line,
        endColumn: 1
      },
      options: js{
        isWholeLine: true,
        className: className,
        # Show the execution count in the gutter.
        glyphMarginClassName: className
      }
    })

proc buildDiffDecorations(file: DeepReviewFileData): seq[JsObject] =
  ## Build Monaco decoration descriptors for diff line highlighting.
  ## Uses the hunk data from ``file.diff.hunks`` to mark added and
  ## modified lines with coloured left borders in the Full Files editor
  ## view, matching the unified diff colour scheme.
  ##
  ## Line types:
  ## - Added lines (``newLine > 0``, type "added"): green left border.
  ## - Modified lines: when a hunk contains both removed and added lines
  ##   in sequence, the added lines are treated as "modified" (yellow
  ##   border) since they replace existing content.
  ## - Removed lines are not decorated because they have no line in the
  ##   new file version displayed in the editor.
  result = @[]
  if file.isNil or file.diff.isNil:
    return

  for hunk in file.diff.hunks:
    # Determine whether this hunk has both removals and additions,
    # which indicates modification rather than pure insertion.
    var hasRemoved = false
    var hasAdded = false
    for line in hunk.lines:
      let lt = $line.`type`
      if lt == "removed":
        hasRemoved = true
      elif lt == "added":
        hasAdded = true

    let isModification = hasRemoved and hasAdded

    for line in hunk.lines:
      let lt = $line.`type`
      if lt != "added":
        # Only added lines have a position in the new file.
        continue
      if line.newLine < 1:
        continue

      let className = if isModification:
        cstring"deepreview-diff-line-modified"
      else:
        cstring"deepreview-diff-line-added"

      result.add(js{
        range: js{
          startLineNumber: line.newLine,
          startColumn: 1,
          endLineNumber: line.newLine,
          endColumn: 1
        },
        options: js{
          isWholeLine: true,
          className: className,
          glyphMarginClassName: className
        }
      })

proc buildInlineValueDecorations(file: DeepReviewFileData, executionIndex: int): seq[JsObject] =
  ## Build Monaco afterContent decorations for inline variable values
  ## from the flow data of a specific execution index.
  result = @[]
  if file.isNil or executionIndex < 0 or executionIndex >= file.flow.len:
    return

  let flow = file.flow[executionIndex]
  for stepItem in flow.steps:
    let step = stepItem
    if step.values.len == 0:
      continue
    # Build a summary of variable values at this step.
    var parts: seq[string] = @[]
    for v in step.values:
      let truncMarker = if v.truncated: "..." else: ""
      parts.add(fmt"{v.name} = {v.value}{truncMarker}")
    let inlineText = cstring("  // " & parts.join(", "))

    result.add(js{
      range: js{
        startLineNumber: step.line,
        startColumn: 1,
        endLineNumber: step.line,
        endColumn: 10000
      },
      options: js{
        after: js{
          content: inlineText,
          inlineClassName: cstring"deepreview-inline-value"
        }
      }
    })

# ---------------------------------------------------------------------------
# Component methods
# ---------------------------------------------------------------------------

# Forward declarations for mutual references.
proc updateDecorations(self: DeepReviewComponent)

proc ensureDeepReviewVM(self: DeepReviewComponent): DeepReviewVM =
  if self.isNil:
    return nil
  if deepReviewVMInstances.hasKey(self.id):
    return deepReviewVMInstances[self.id]

  if deepReviewVMStore.isNil:
    let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
      when defined(js):
        result = newPromise proc(resolve: proc(resp: JsonNode)) =
          resolve(%*{})
      else:
        var fut = newFuture[JsonNode]("stub-backend")
        fut.complete(%*{})
        result = fut
    let stubBackend = BackendService(
      sendProc: stubSend,
      onEventProc: proc(handler: proc(event: JsonNode)) = discard,
      disconnectProc: proc() = discard,
    )
    deepReviewVMStore = createReplayDataStore(stubBackend)

  result = createDeepReviewVM(deepReviewVMStore)
  deepReviewVMInstances[self.id] = result

proc initDeepReviewVMWithStore*(store: ReplayDataStore) =
  deepReviewVMStore = store
  deepReviewVMInstances = JsAssoc[int, DeepReviewVM]{}
  isoNimDeepReviewMountedIds = JsAssoc[int, bool]{}
  for _, component in deepReviewComponentRefs:
    discard ensureDeepReviewVM(component)
    component.syncLegacyDeepReviewIntoVM()
    tryMountIsoNimDeepReviewPanel(component.id)

proc initDeepReviewVM*(self: DeepReviewComponent) =
  discard ensureDeepReviewVM(self)

method register*(self: DeepReviewComponent, api: MediatorWithSubscribers) =
  ## Register the component with the mediator event system.
  ## DeepReview operates in offline mode so it does not subscribe to
  ## any debugger events.
  self.api = api
  self.initDeepReviewVM()
  self.syncLegacyDeepReviewIntoVM()

proc initEditor(self: DeepReviewComponent) =
  ## Lazily initialise the Monaco editor after the DOM container is rendered.
  ## Called from ``afterRedraws`` to ensure the target div exists.
  if self.editorInitialized:
    return

  let divId = cstring(fmt"deepreview-editor-{self.id}")
  let el = document.getElementById(divId)
  if el.isNil:
    return

  let file = self.selectedFile()
  let lang = if file.isNil: cstring"plaintext" else: guessLanguageFromPath(file.path)
  let content = if file.isNil: cstring"" else: buildSourcePlaceholder(file)
  let theme = if self.data.config.theme == cstring"default_white":
    cstring"codetracerWhite"
  else:
    cstring"codetracerDark"

  self.editor = drCreateMonacoEditor(divId, js{
    value: content,
    language: lang,
    readOnly: true,
    theme: theme,
    automaticLayout: true,
    folding: true,
    fontSize: self.data.ui.fontSize,
    minimap: js{ enabled: false },
    renderIndentGuides: true,
    renderLineHighlight: cstring"none",
    lineNumbersMinChars: monacoLineNumbersMinChars(lineCountForGutter(content)),
    lineDecorationsWidth: monacoLineDecorationsWidth(self.data.ui.fontSize),
    showFoldingControls: cstring"always",
    scrollBeyondLastLine: false,
    contextmenu: false,
    glyphMargin: true
  })
  self.editorInitialized = true
  self.currentDecorationIds = newJsObject()

  # Apply initial decorations.
  self.updateDecorations()

proc updateDecorations(self: DeepReviewComponent) =
  ## Recompute and apply all Monaco decorations for the selected file and
  ## execution index.
  if not self.editorInitialized or self.editor.isNil:
    return

  let file = self.selectedFile()
  var allDecorations: seq[JsObject] = @[]

  # Coverage decorations.
  let coverageDecos = buildCoverageDecorations(file)
  for d in coverageDecos:
    allDecorations.add(d)

  # Diff line decorations (added/modified lines from hunk data).
  let diffDecos = buildDiffDecorations(file)
  for d in diffDecos:
    allDecorations.add(d)

  # Inline value decorations.
  let valueDecos = buildInlineValueDecorations(file, self.selectedExecutionIndex)
  for d in valueDecos:
    allDecorations.add(d)

  # Use createDecorationsCollection (Monaco 0.36+) instead of the
  # deprecated deltaDecorations so that ``after`` injected text
  # (inline variable values) renders correctly as DOM spans.
  if self.decorationCollection.isNil:
    self.decorationCollection = self.editor.drCreateDecorationsCollection(allDecorations.toJs)
  else:
    self.decorationCollection.drCollectionSet(allDecorations.toJs)

proc switchToFile(self: DeepReviewComponent, fileIndex: int) =
  ## Switch the editor to display a different file.
  if fileIndex == self.effectiveFileIndex() and self.editorInitialized:
    return
  self.selectedFileIndex = fileIndex
  # Keep the data-level index in sync so the VCS panel highlights
  # the correct file when in GL-embedded mode.
  if self.glEmbedded:
    self.data.deepReviewSelectedFileIndex = fileIndex
  self.selectedExecutionIndex = 0
  self.selectedIteration = 0

  if self.editorInitialized and not self.editor.isNil:
    let file = self.selectedFile()
    if not file.isNil:
      let content = buildSourcePlaceholder(file)
      self.editor.drSetMonacoValue(content)
      let options = cast[MonacoEditorOptions](self.editor.getOptions())
      options.lineNumbersMinChars = monacoLineNumbersMinChars(lineCountForGutter(content))
      options.lineDecorationsWidth = monacoLineDecorationsWidth(self.data.ui.fontSize)
      self.editor.updateOptions(options)
      let lang = guessLanguageFromPath(file.path)
      let model = self.editor.drGetMonacoModel()
      if not model.isNil:
        drSetModelLanguage(model, lang)
    self.updateDecorations()
  self.syncLegacyDeepReviewIntoVM()

# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------

proc makeFileClickHandler(self: DeepReviewComponent, idx: int): proc(ev: Event, n: VNode) =
  ## Create a click handler for a file list item.
  ## Using a separate proc avoids the Nim 1.6 JS backend closure-in-loop
  ## bug where all closures capture the same loop variable by reference
  ## (JS ``var`` is function-scoped, not block-scoped).
  result = proc(ev: Event, n: VNode) =
    self.switchToFile(idx)
    redrawAll()

proc diffStatusLabel(diff: DeepReviewFileDiff): cstring =
  ## Return a single-letter label for the diff status.
  if diff.isNil:
    return cstring""
  let s = $diff.status
  case s
  of "A": return cstring"A"
  of "M": return cstring"M"
  of "D": return cstring"D"
  else: return cstring""

proc diffStatusCssClass(diff: DeepReviewFileDiff): string =
  ## Return a CSS modifier class for the diff status colour.
  if diff.isNil:
    return ""
  let s = $diff.status
  case s
  of "A": return " deepreview-diff-added"
  of "M": return " deepreview-diff-modified"
  of "D": return " deepreview-diff-deleted"
  else: return ""

proc diffLinesSummary(diff: DeepReviewFileDiff): cstring =
  ## Return a short "+N / -M" summary of changed lines.
  if diff.isNil:
    return cstring""
  result = cstring(fmt"+{diff.linesAdded} / -{diff.linesRemoved}")

proc renderFileList(self: DeepReviewComponent): VNode =
  ## Render the file list sidebar.
  ## Each file entry shows a diff status indicator (A/M/D), the file
  ## basename and path, a modified line count, and a coverage badge.
  buildHtml(tdiv(class = "deepreview-file-list")):
    for i, file in self.drData.files:
      let isSelected = (i == self.selectedFileIndex)
      let selectedClass = if isSelected: " selected" else: ""
      tdiv(
        class = cstring(fmt"deepreview-file-item{selectedClass}"),
        onclick = self.makeFileClickHandler(i)
      ):
        # Top row: diff status indicator + file basename.
        tdiv(class = "deepreview-file-name-row"):
          if not file.diff.isNil and ($file.diff.status).len > 0:
            span(class = cstring("deepreview-diff-status" & diffStatusCssClass(file.diff))):
              text diffStatusLabel(file.diff)
          tdiv(class = "deepreview-file-name"):
            text fileBasename(file.path)
        tdiv(class = "deepreview-file-path-full"):
          text $file.path
        # Badge row: diff line count and coverage.
        tdiv(class = "deepreview-file-badges"):
          if not file.diff.isNil and (file.diff.linesAdded > 0 or file.diff.linesRemoved > 0):
            span(class = cstring("deepreview-diff-lines" & diffStatusCssClass(file.diff))):
              text diffLinesSummary(file.diff)
          if file.flags.hasCoverage:
            span(class = "deepreview-coverage-badge"):
              text coverageSummary(file)

proc renderExecutionSlider(self: DeepReviewComponent): VNode =
  ## Render the function execution index slider.
  let file = self.selectedFile()
  let flowCount = if file.isNil: 0 else: file.flow.len
  if flowCount == 0:
    return buildHtml(tdiv(class = "deepreview-slider deepreview-slider-empty")):
      span(class = "deepreview-slider-label"): text "No execution data"
  else:
    let maxVal = max(0, flowCount - 1)
    let funcKey = if self.selectedExecutionIndex < flowCount:
      $file.flow[self.selectedExecutionIndex].functionKey
    else:
      "?"
    buildHtml(tdiv(class = "deepreview-slider")):
      span(class = "deepreview-slider-label"): text "Execution:"
      input(
        class = "deepreview-slider-input",
        `type` = "range",
        min = "0",
        max = cstring($maxVal),
        value = cstring($self.selectedExecutionIndex),
        oninput = proc(ev: Event, n: VNode) =
          let val = cast[cstring](ev.target.toJs.value)
          self.selectedExecutionIndex = ($val).parseInt
          self.updateDecorations()
          redrawAll()
      )
      span(class = "deepreview-slider-info"):
        text fmt"{self.selectedExecutionIndex + 1}/{flowCount} ({funcKey})"

proc renderLoopSlider(self: DeepReviewComponent): VNode =
  ## Render the loop iteration slider for the current execution.
  let file = self.selectedFile()
  if file.isNil or file.loops.len == 0:
    return buildHtml(tdiv())

  # Find maximum iteration count across all loops in the file.
  var maxIter = 0
  for loop in file.loops:
    if loop.totalIterations > maxIter:
      maxIter = loop.totalIterations

  if maxIter == 0:
    return buildHtml(tdiv())

  buildHtml(tdiv(class = "deepreview-slider")):
    span(class = "deepreview-slider-label"): text "Iteration:"
    input(
      class = "deepreview-slider-input",
      `type` = "range",
      min = "0",
      max = cstring($max(0, maxIter - 1)),
      value = cstring($self.selectedIteration),
      oninput = proc(ev: Event, n: VNode) =
        let val = cast[cstring](ev.target.toJs.value)
        self.selectedIteration = ($val).parseInt
        redrawAll()
    )
    span(class = "deepreview-slider-info"):
      text fmt"{self.selectedIteration + 1}/{maxIter}"

proc renderViewModeToggle(self: DeepReviewComponent): VNode =
  ## Render toggle buttons to switch between Unified diff and Full Files modes.
  ## Mode switching preserves the current ``selectedFileIndex`` so the user
  ## does not lose their place when toggling views.
  let isUnified = self.viewMode == Unified
  let isFullFiles = self.viewMode == FullFiles
  buildHtml(tdiv(class = "deepreview-mode-toggle")):
    button(
      class = cstring(if isFullFiles: "deepreview-mode-btn deepreview-mode-btn-active" else: "deepreview-mode-btn"),
      onclick = proc(ev: Event, n: VNode) =
        # Preserve selectedFileIndex across mode switch.
        # Reset editor state so it re-initialises after the DOM
        # is re-created by Karax (see setViewMode comment).
        self.viewMode = FullFiles
        self.editorInitialized = false
        self.decorationCollection = nil
        redrawAll()
    ):
      text "Full Files"
    button(
      class = cstring(if isUnified: "deepreview-mode-btn deepreview-mode-btn-active" else: "deepreview-mode-btn"),
      onclick = proc(ev: Event, n: VNode) =
        # Preserve selectedFileIndex across mode switch.
        self.viewMode = Unified
        redrawAll()
    ):
      text "Unified Diff"

proc makeTraceContextChangeHandler(self: DeepReviewComponent): proc(ev: Event, n: VNode) =
  ## Create a change handler for the trace context selector dropdown.
  result = proc(ev: Event, n: VNode) =
    let val = cast[cstring](ev.target.toJs.value)
    self.selectedTraceContextId = ($val).parseInt
    # TODO(DR-6): When actual per-context data switching is implemented,
    # reload coverage/flow overlays for the selected trace context here.
    self.updateDecorations()
    redrawAll()

proc renderTraceContextSelector(self: DeepReviewComponent): VNode =
  ## Render a dropdown to select between available trace contexts.
  ## Each trace context represents a different recording run (e.g.
  ## "latest passing run", "previous run"). When no contexts are
  ## available, the selector is hidden.
  let drData = self.drData
  if drData.isNil or drData.traceContexts.len == 0:
    return buildHtml(tdiv())

  buildHtml(tdiv(class = "deepreview-trace-selector")):
    select(
      class = "deepreview-trace-select",
      onchange = self.makeTraceContextChangeHandler()
    ):
      for ctx in drData.traceContexts:
        let isSelected = (ctx.id == self.selectedTraceContextId)
        if isSelected:
          option(
            value = cstring($ctx.id),
            selected = "selected"
          ):
            text $ctx.label
        else:
          option(value = cstring($ctx.id)):
            text $ctx.label

proc renderCallTraceNode(node: DeepReviewCallNode, depth: int): VNode =
  ## Recursively render a call trace tree node.
  let indent = depth * 16
  buildHtml(tdiv(class = "deepreview-calltrace-node")):
    tdiv(
      class = "deepreview-calltrace-entry",
      style = style(StyleAttr.paddingLeft, cstring(fmt"{indent}px"))
    ):
      span(class = "deepreview-calltrace-name"): text $node.name
      span(class = "deepreview-calltrace-count"): text fmt" x{node.executionCount}"
    if node.children.len > 0:
      for child in node.children:
        renderCallTraceNode(child, depth + 1)

# ---------------------------------------------------------------------------
# Context expansion helpers
# ---------------------------------------------------------------------------

proc drHasKey(obj: JsObject, key: cstring): bool
  {.importjs: "#.hasOwnProperty(#)".}
  ## Check if a JS object has a given own property. Works on JsAssoc and
  ## JsObject alike since both compile to plain JS objects.

const EXPAND_STEP = 10
  ## Number of lines to expand on each click of "Expand above/below".

proc ensureExpansionState(self: DeepReviewComponent) =
  ## Lazily initialise the expansion state tables if they are nil.
  if self.expandAbove.isNil:
    self.expandAbove = newJsAssoc[cstring, JsAssoc[cstring, int]]()
  if self.expandBelow.isNil:
    self.expandBelow = newJsAssoc[cstring, JsAssoc[cstring, int]]()

proc getExpand(table: JsAssoc[cstring, JsAssoc[cstring, int]], fileIdx, hunkIdx: int): int =
  ## Read an expansion count from the nested table, defaulting to 0.
  let fk = cstring($fileIdx)
  let hk = cstring($hunkIdx)
  if table.isNil:
    return 0
  if not drHasKey(table.toJs, fk):
    return 0
  let inner = table[fk]
  if inner.isNil or not drHasKey(inner.toJs, hk):
    return 0
  return inner[hk]

proc setExpand(table: JsAssoc[cstring, JsAssoc[cstring, int]], fileIdx, hunkIdx, value: int) =
  ## Write an expansion count into the nested table.
  let fk = cstring($fileIdx)
  let hk = cstring($hunkIdx)
  if not drHasKey(table.toJs, fk):
    table[fk] = newJsAssoc[cstring, int]()
  table[fk][hk] = value

type
  FlowValuePair = object
    ## A single variable name/value pair from a flow step, used to render
    ## Omniscience annotations in the unified diff view.
    name: string
    value: string
    truncated: bool

proc flowValuesForLine(file: DeepReviewFileData, lineNum: int): seq[FlowValuePair] =
  ## Look up inline variable values from the file's flow data for a given
  ## line number (1-based, matching the "new" side of the diff). Scans all
  ## flow executions and returns the first match as structured pairs so that
  ## the caller can render each variable using the standard flow CSS classes
  ## (``flow-parallel-value-name``, ``flow-parallel-value-box``, etc.).
  if file.isNil or file.flow.len == 0 or lineNum < 1:
    return @[]
  for flow in file.flow:
    for step in flow.steps:
      if step.line == lineNum and step.values.len > 0:
        var pairs: seq[FlowValuePair] = @[]
        for v in step.values:
          pairs.add(FlowValuePair(
            name: $v.name,
            value: $v.value,
            truncated: v.truncated
          ))
        return pairs
  return @[]

proc splitSourceLines(file: DeepReviewFileData): seq[string] =
  ## Split the file's sourceContent into individual lines.
  ## Returns an empty seq if sourceContent is nil or empty.
  if file.isNil or file.sourceContent.isNil or ($file.sourceContent).len == 0:
    return @[]
  result = ($file.sourceContent).split('\n')

proc legacyTraceContextsToVm(drData: DeepReviewData):
    seq[DeepReviewTraceContextEntry] =
  result = @[]
  if drData.isNil:
    return
  for ctx in drData.traceContexts:
    result.add(DeepReviewTraceContextEntry(
      id: ctx.id,
      label: safeStr(ctx.label),
    ))

proc legacyFileToVm(file: DeepReviewFileData): DeepReviewFileEntry =
  let status = if file.isNil or file.diff.isNil: "" else: safeStr(file.diff.status)
  let added = if file.isNil or file.diff.isNil: 0 else: file.diff.linesAdded
  let removed = if file.isNil or file.diff.isNil: 0 else: file.diff.linesRemoved
  result = DeepReviewFileEntry(
    path: if file.isNil: "" else: safeStr(file.path),
    diffStatus: status,
    linesAdded: added,
    linesRemoved: removed,
    coverageText: safeStr(coverageSummary(file)),
    hasCoverage: not file.isNil and not file.flags.isNil and file.flags.hasCoverage,
    hasFlow: not file.isNil and not file.flags.isNil and file.flags.hasFlow,
  )

proc legacyFilesToVm(drData: DeepReviewData): seq[DeepReviewFileEntry] =
  result = @[]
  if drData.isNil:
    return
  for file in drData.files:
    result.add(legacyFileToVm(file))

proc legacyLineValuesToVm(file: DeepReviewFileData; lineNum: int):
    seq[DeepReviewFlowValueEntry] =
  result = @[]
  for value in flowValuesForLine(file, lineNum):
    result.add(DeepReviewFlowValueEntry(
      name: value.name,
      value: value.value,
      truncated: value.truncated,
    ))

proc legacyHunkToVm(file: DeepReviewFileData; hunk: DeepReviewHunk):
    DeepReviewHunkEntry =
  result = DeepReviewHunkEntry(
    oldStart: hunk.oldStart,
    oldCount: hunk.oldCount,
    newStart: hunk.newStart,
    newCount: hunk.newCount,
    lines: @[],
  )
  for line in hunk.lines:
    let lineType = safeStr(line.`type`)
    result.lines.add(DeepReviewDiffLineEntry(
      lineType: lineType,
      content: safeStr(line.content),
      oldLine: line.oldLine,
      newLine: line.newLine,
      values:
        if lineType != "removed" and line.newLine > 0:
          legacyLineValuesToVm(file, line.newLine)
        else:
          @[],
    ))

proc legacyUnifiedFilesToVm(drData: DeepReviewData):
    seq[DeepReviewUnifiedFileEntry] =
  result = @[]
  if drData.isNil:
    return
  for fileIdx, file in drData.files:
    if file.diff.isNil or file.diff.hunks.len == 0:
      continue
    var hunks: seq[DeepReviewHunkEntry] = @[]
    for hunk in file.diff.hunks:
      hunks.add(legacyHunkToVm(file, hunk))
    result.add(DeepReviewUnifiedFileEntry(
      fileIndex: fileIdx,
      path: safeStr(file.path),
      diffStatus: safeStr(file.diff.status),
      linesAdded: file.diff.linesAdded,
      linesRemoved: file.diff.linesRemoved,
      hunks: hunks,
    ))

proc flattenCallNodes(nodes: seq[DeepReviewCallNode]; depth: int;
                      outNodes: var seq[DeepReviewCallNodeEntry]) =
  for node in nodes:
    if node.isNil:
      continue
    outNodes.add(DeepReviewCallNodeEntry(
      name: safeStr(node.name),
      executionCount: node.executionCount,
      depth: depth,
    ))
    flattenCallNodes(node.children, depth + 1, outNodes)

proc legacyCallNodesToVm(drData: DeepReviewData): seq[DeepReviewCallNodeEntry] =
  result = @[]
  if drData.isNil or drData.callTrace.isNil:
    return
  flattenCallNodes(drData.callTrace.nodes, 0, result)

proc selectedFlowCount(self: DeepReviewComponent): int =
  let file = self.selectedFile()
  if file.isNil:
    0
  else:
    file.flow.len

proc selectedFunctionKey(self: DeepReviewComponent): string =
  let file = self.selectedFile()
  if file.isNil or self.selectedExecutionIndex < 0 or
     self.selectedExecutionIndex >= file.flow.len:
    "?"
  else:
    safeStr(file.flow[self.selectedExecutionIndex].functionKey)

proc selectedMaxIterations(self: DeepReviewComponent): int =
  let file = self.selectedFile()
  if file.isNil:
    return 0
  for loop in file.loops:
    result = max(result, loop.totalIterations)

proc syncLegacyDeepReviewIntoVM*(self: DeepReviewComponent) =
  if self.isNil:
    return
  deepReviewComponentRefs[self.id] = self
  if self.glEmbedded and not self.drData.isNil:
    let sharedIdx = self.data.deepReviewSelectedFileIndex
    if sharedIdx >= 0 and sharedIdx < self.drData.files.len:
      self.selectedFileIndex = sharedIdx
  let vm = ensureDeepReviewVM(self)
  if vm.isNil:
    return
  let drData = self.drData
  vm.setHasData(not drData.isNil)
  vm.setGlEmbedded(self.glEmbedded)
  vm.setViewMode(legacyViewModeToVm(self.viewMode))
  vm.setSelectedFileIndex(self.effectiveFileIndex())
  vm.setSelectedTraceContextId(self.selectedTraceContextId)
  vm.setSelectedHunks(self.drSelectedHunks)
  vm.setHunkToolbarVisible(self.drHunkToolbarVisible)
  vm.setHunkCopyFeedback(self.drHunkCopyFeedback)
  if drData.isNil:
    vm.clearPanel()
    vm.setGlEmbedded(self.glEmbedded)
    vm.setViewMode(legacyViewModeToVm(self.viewMode))
    return

  let commitDisplay =
    if drData.commitSha.len > 12:
      ($drData.commitSha)[0 ..< 12] & "..."
    else:
      safeStr(drData.commitSha)
  let sessionTitle =
    if drData.sessionTitle.isNil: "" else: safeStr(drData.sessionTitle)
  vm.setHeader(
    sessionTitle,
    commitDisplay,
    fmt"{drData.files.len} files | {drData.recordingCount} recordings | {drData.collectionTimeMs}ms")
  vm.setTraceContexts(legacyTraceContextsToVm(drData))
  vm.setFiles(legacyFilesToVm(drData))
  vm.setSelectedFileIndex(self.effectiveFileIndex())
  vm.setExecutionState(
    self.selectedExecutionIndex, self.selectedFlowCount(),
    self.selectedFunctionKey())
  vm.setIterationState(self.selectedIteration, self.selectedMaxIterations())
  vm.setUnifiedFiles(legacyUnifiedFilesToVm(drData))
  vm.setCallNodes(legacyCallNodesToVm(drData))

proc makeExpandAboveHandler(self: DeepReviewComponent, fileIdx, hunkIdx: int): proc(ev: Event, n: VNode) =
  ## Create a click handler for expanding context above a hunk.
  result = proc(ev: Event, n: VNode) =
    self.ensureExpansionState()
    let current = self.expandAbove.getExpand(fileIdx, hunkIdx)
    self.expandAbove.setExpand(fileIdx, hunkIdx, current + EXPAND_STEP)
    redrawAll()

proc makeExpandBelowHandler(self: DeepReviewComponent, fileIdx, hunkIdx: int): proc(ev: Event, n: VNode) =
  ## Create a click handler for expanding context below a hunk.
  result = proc(ev: Event, n: VNode) =
    self.ensureExpansionState()
    let current = self.expandBelow.getExpand(fileIdx, hunkIdx)
    self.expandBelow.setExpand(fileIdx, hunkIdx, current + EXPAND_STEP)
    redrawAll()

# ---------------------------------------------------------------------------
# Hunk editor helpers (DeepReview)
# ---------------------------------------------------------------------------

proc isDrHunkSelected(self: DeepReviewComponent, fileIdx, hunkIdx: int): bool =
  ## Return true if the given (fileIndex, hunkIndex) pair is selected.
  for pair in self.drSelectedHunks:
    if pair[0] == fileIdx and pair[1] == hunkIdx:
      return true
  return false

proc drFlatHunkOrdinal(drData: DeepReviewData, fileIdx, hunkIdx: int): int =
  ## Compute a flat ordinal for a (fileIdx, hunkIdx) pair.
  result = 0
  for fi in 0 ..< drData.files.len:
    if fi == fileIdx:
      result += hunkIdx
      return
    let file = drData.files[fi]
    if not file.diff.isNil:
      result += file.diff.hunks.len

proc drHunkPairFromOrdinal(drData: DeepReviewData, ordinal: int): (int, int) =
  ## Reverse of ``drFlatHunkOrdinal``.
  var remaining = ordinal
  for fi in 0 ..< drData.files.len:
    let file = drData.files[fi]
    let hunkCount = if file.diff.isNil: 0 else: file.diff.hunks.len
    if remaining < hunkCount:
      return (fi, remaining)
    remaining -= hunkCount
  return (0, 0)

proc toggleDrHunkSelection(self: DeepReviewComponent, fileIdx, hunkIdx: int) =
  ## Toggle a single hunk in/out of the selection.
  var found = -1
  for i in 0 ..< self.drSelectedHunks.len:
    if self.drSelectedHunks[i][0] == fileIdx and self.drSelectedHunks[i][1] == hunkIdx:
      found = i
      break
  if found >= 0:
    self.drSelectedHunks.delete(found)
  else:
    self.drSelectedHunks.add((fileIdx, hunkIdx))
  self.drHunkToolbarVisible = self.drSelectedHunks.len > 0

proc selectDrHunkRange(self: DeepReviewComponent, fromOrdinal, toOrdinal: int) =
  ## Select all hunks between two flat ordinals (inclusive).
  let lo = min(fromOrdinal, toOrdinal)
  let hi = max(fromOrdinal, toOrdinal)
  let drData = self.drData
  if drData.isNil:
    return
  for ord in lo .. hi:
    let pair = drHunkPairFromOrdinal(drData, ord)
    if not self.isDrHunkSelected(pair[0], pair[1]):
      self.drSelectedHunks.add(pair)
  self.drHunkToolbarVisible = self.drSelectedHunks.len > 0

proc clearDrHunkSelection(self: DeepReviewComponent) =
  ## Clear all selected hunks.
  self.drSelectedHunks = @[]
  self.drHunkToolbarVisible = false

proc buildDrPatchFromSelectedHunks(self: DeepReviewComponent): string =
  ## Build a unified diff patch string from the currently selected hunks.
  let drData = self.drData
  if drData.isNil or self.drSelectedHunks.len == 0:
    return ""

  # Group selected hunks by file index.
  var fileHunks: seq[(int, seq[int])] = @[]
  var fileMap: seq[int] = @[]
  for pair in self.drSelectedHunks:
    let fi = pair[0]
    let hi = pair[1]
    var found = false
    for j in 0 ..< fileMap.len:
      if fileMap[j] == fi:
        fileHunks[j][1].add(hi)
        found = true
        break
    if not found:
      fileMap.add(fi)
      fileHunks.add((fi, @[hi]))

  var parts: seq[string] = @[]
  for entry in fileHunks:
    let fi = entry[0]
    let hunkIndices = entry[1]
    if fi >= drData.files.len:
      continue
    let file = drData.files[fi]
    let path = $file.path

    parts.add("diff --git a/" & path & " b/" & path)
    parts.add("--- a/" & path)
    parts.add("+++ b/" & path)

    for hi in hunkIndices:
      if file.diff.isNil or hi >= file.diff.hunks.len:
        continue
      let hunk = file.diff.hunks[hi]
      parts.add(fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@")
      for line in hunk.lines:
        let lineType = $line.`type`
        let prefix = case lineType
          of "added": "+"
          of "removed": "-"
          else: " "
        parts.add(prefix & $line.content)

  result = parts.join("\n") & "\n"

proc copyDrSelectedHunksAsPatch(self: DeepReviewComponent) =
  ## Copy the selected hunks to the clipboard as a unified diff patch.
  let patch = self.buildDrPatchFromSelectedHunks()
  if patch.len > 0:
    clipboardCopy(cstring(patch))
    self.drHunkCopyFeedback = true
    discard windowSetTimeout(
      proc() =
        self.drHunkCopyFeedback = false
        redrawAll(),
      2000)

proc makeDrHunkHeaderClickHandler(self: DeepReviewComponent, fileIdx, hunkIdx: int): proc(ev: Event, n: VNode) =
  ## Create a click handler for a hunk header in the DeepReview diff view.
  ## Supports plain click, Ctrl/Cmd-click (toggle), and Shift-click (range).
  let selfCapture = self
  let drData = self.drData
  result = proc(ev: Event, n: VNode) =
    let jsEv = cast[JsObject](ev)
    let shiftKey = jsEv.shiftKey.to(bool)
    let ctrlKey = jsEv.ctrlKey.to(bool) or jsEv.metaKey.to(bool)

    if shiftKey and selfCapture.drLastHunkClickIndex >= 0 and not drData.isNil:
      let currentOrd = drFlatHunkOrdinal(drData, fileIdx, hunkIdx)
      selfCapture.selectDrHunkRange(selfCapture.drLastHunkClickIndex, currentOrd)
    elif ctrlKey:
      selfCapture.toggleDrHunkSelection(fileIdx, hunkIdx)
    else:
      if selfCapture.drSelectedHunks.len == 1 and
         selfCapture.isDrHunkSelected(fileIdx, hunkIdx):
        selfCapture.clearDrHunkSelection()
      else:
        selfCapture.clearDrHunkSelection()
        selfCapture.drSelectedHunks.add((fileIdx, hunkIdx))
        selfCapture.drHunkToolbarVisible = true

    if not drData.isNil:
      selfCapture.drLastHunkClickIndex = drFlatHunkOrdinal(drData, fileIdx, hunkIdx)

    ev.preventDefault()
    redrawAll()

proc renderDrHunkToolbar(self: DeepReviewComponent): VNode =
  ## Render the floating action toolbar for selected hunks in DeepReview.
  if not self.drHunkToolbarVisible or self.drSelectedHunks.len == 0:
    return buildHtml(tdiv())

  buildHtml(tdiv(class = "hunk-toolbar")):
    span(class = "hunk-toolbar-count"):
      text cstring($self.drSelectedHunks.len & " hunk" &
        (if self.drSelectedHunks.len > 1: "s" else: "") & " selected")

    tdiv(class = "hunk-toolbar-actions"):
      tdiv(class = "hunk-toolbar-button",
           onclick = proc(ev: Event, n: VNode) =
             self.copyDrSelectedHunksAsPatch()
             redrawAll()):
        if self.drHunkCopyFeedback:
          text "Copied!"
        else:
          text "Copy as patch"

      tdiv(class = "hunk-toolbar-button hunk-toolbar-button-subtle",
           onclick = proc(ev: Event, n: VNode) =
             self.clearDrHunkSelection()
             redrawAll()):
        text "Clear"

proc renderUnifiedDiff(self: DeepReviewComponent): VNode =
  ## Render all modified files as a vertical scrollable list of diff hunks.
  ## Each file gets a header with path and diff metadata, followed by its
  ## hunks with added/removed/context line colouring. This is a pure-DOM
  ## rendering approach (no Monaco editor) to keep things simple and
  ## performant for the diff overview.
  ##
  ## Context expansion: if the file has ``sourceContent``, "Expand above"
  ## and "Expand below" buttons appear around each hunk. Clicking them
  ## reveals additional unchanged source lines, rendered as context type.
  if self.drData.isNil or self.drData.files.len == 0:
    return buildHtml(tdiv(class = "deepreview-unified-diff")):
      tdiv(class = "deepreview-unified-empty"):
        text "No files to display."

  self.ensureExpansionState()

  buildHtml(tdiv(class = "deepreview-unified-diff")):
    # Floating hunk action toolbar (shown when hunks are selected).
    renderDrHunkToolbar(self)

    for fileIdx, file in self.drData.files:
      if file.diff.isNil:
        continue
      let hasHunks = file.diff.hunks.len > 0
      if not hasHunks:
        continue

      let sourceLines = splitSourceLines(file)
      let hasSource = sourceLines.len > 0

      # File header with path, status badge and line counts.
      # Add a data attribute so the unified diff can scroll to the
      # selected file's section when switching modes.
      tdiv(class = "deepreview-unified-file", `data-file-index` = cstring($fileIdx)):
        tdiv(class = "deepreview-unified-file-header"):
          if ($file.diff.status).len > 0:
            span(class = cstring("deepreview-diff-status" & diffStatusCssClass(file.diff))):
              text diffStatusLabel(file.diff)
          span(class = "deepreview-unified-file-path"):
            text $file.path
          if file.diff.linesAdded > 0 or file.diff.linesRemoved > 0:
            span(class = "deepreview-unified-file-stats"):
              span(class = "deepreview-unified-additions"):
                text cstring(fmt"+{file.diff.linesAdded}")
              span(class = "deepreview-unified-deletions"):
                text cstring(fmt"-{file.diff.linesRemoved}")

        # Render each hunk with optional expansion buttons.
        for hunkIdx, hunk in file.diff.hunks:
          let isSelected = self.isDrHunkSelected(fileIdx, hunkIdx)
          let hunkClass = if isSelected:
            "deepreview-unified-hunk hunk-selected"
          else:
            "deepreview-unified-hunk"

          tdiv(class = cstring(hunkClass)):
            # Hunk header (like @@ -40,6 +40,12 @@). Clickable for selection.
            tdiv(class = "deepreview-unified-hunk-header hunk-header-selectable",
                 onclick = self.makeDrHunkHeaderClickHandler(fileIdx, hunkIdx)):
              if isSelected:
                span(class = "hunk-selection-indicator"):
                  text "\xE2\x9C\x93" # checkmark
              text cstring(fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@")

            # --- "Expand above" button and expanded lines ---
            if hasSource:
              let aboveCount = self.expandAbove.getExpand(fileIdx, hunkIdx)

              # Determine the first line of the hunk (1-based) and the
              # upper boundary (line after previous hunk, or 1).
              var hunkFirstLine = 0
              for lineItem in hunk.lines:
                let ln = if lineItem.newLine > 0: lineItem.newLine
                          elif lineItem.oldLine > 0: lineItem.oldLine
                          else: 0
                if ln > 0:
                  hunkFirstLine = ln
                  break

              # Compute the earliest line we can show above. For the
              # first hunk this is line 1; for subsequent hunks it is
              # one line after the previous hunk's last line.
              var aboveLimit = 1
              if hunkIdx > 0:
                let prevHunk = file.diff.hunks[hunkIdx - 1]
                # The last line of the previous hunk in the new file.
                var prevLast = 0
                for pli in countdown(prevHunk.lines.len - 1, 0):
                  let pln = prevHunk.lines[pli].newLine
                  if pln > 0:
                    prevLast = pln
                    break
                # Also account for existing "expand below" on the
                # previous hunk.
                let prevBelowCount = self.expandBelow.getExpand(fileIdx, hunkIdx - 1)
                aboveLimit = max(aboveLimit, prevLast + prevBelowCount + 1)

              if hunkFirstLine > aboveLimit:
                # There are lines available to expand.
                let startLine = max(aboveLimit, hunkFirstLine - aboveCount)

                # Render the expand-above button.
                if startLine > aboveLimit or aboveCount == 0:
                  tdiv(
                    class = "deepreview-expand-row",
                    onclick = self.makeExpandAboveHandler(fileIdx, hunkIdx)
                  ):
                    span(class = "deepreview-expand-icon"): text "..."
                    span(class = "deepreview-expand-label"):
                      text cstring(fmt"Expand 10 lines above")

                # Render expanded lines above as context.
                if aboveCount > 0 and startLine < hunkFirstLine:
                  for lineNum in startLine ..< hunkFirstLine:
                    if lineNum >= 1 and lineNum <= sourceLines.len:
                      tdiv(class = "deepreview-unified-line deepreview-unified-line-context deepreview-expanded-context"):
                        span(class = "deepreview-unified-gutter-old"):
                          text cstring($lineNum)
                        span(class = "deepreview-unified-gutter-new"):
                          text cstring($lineNum)
                        span(class = "deepreview-unified-line-content"):
                          text cstring(sourceLines[lineNum - 1])

            # Hunk lines.
            for lineItem in hunk.lines:
              let lineType = $lineItem.`type`
              let lineClass = case lineType
                of "added": "deepreview-unified-line deepreview-unified-line-added"
                of "removed": "deepreview-unified-line deepreview-unified-line-removed"
                else: "deepreview-unified-line deepreview-unified-line-context"

              tdiv(class = cstring(lineClass)):
                # Gutter: old line number.
                span(class = "deepreview-unified-gutter-old"):
                  if lineType != "added" and lineItem.oldLine > 0:
                    text cstring($lineItem.oldLine)
                # Gutter: new line number.
                span(class = "deepreview-unified-gutter-new"):
                  if lineType != "removed" and lineItem.newLine > 0:
                    text cstring($lineItem.newLine)
                # Line content.
                span(class = "deepreview-unified-line-content"):
                  text $lineItem.content
                # Omniscience overlay: inline variable values from flow data.
                # Only shown for lines that exist in the new file version
                # (added or context lines with a valid newLine number).
                #
                # Renders each variable using the same CSS classes as the
                # standard CodeTracer flow visualization (flow-parallel-value,
                # flow-parallel-value-name, flow-parallel-value-box) so the
                # values look identical to flow annotations in the editor.
                if lineType != "removed" and lineItem.newLine > 0:
                  let valuePairs = flowValuesForLine(file, lineItem.newLine)
                  if valuePairs.len > 0:
                    span(class = "deepreview-flow-values"):
                      for vp in valuePairs:
                        span(class = "flow-parallel-value"):
                          span(class = "flow-parallel-value-name"):
                            text cstring("<" & vp.name & ">")
                          let valText = if vp.truncated: vp.value & "..."
                                        else: vp.value
                          span(class = "flow-parallel-value-box flow-parallel-value-before-only"):
                            text cstring(valText)

            # --- "Expand below" button and expanded lines ---
            if hasSource:
              let belowCount = self.expandBelow.getExpand(fileIdx, hunkIdx)

              # Determine the last line of the hunk (1-based).
              var hunkLastLine = 0
              for lineItem in hunk.lines:
                let ln = lineItem.newLine
                if ln > hunkLastLine:
                  hunkLastLine = ln
                let oln = lineItem.oldLine
                if oln > hunkLastLine:
                  hunkLastLine = oln

              # Compute the furthest line we can show below. For the
              # last hunk this is the end of the file; for earlier
              # hunks it is one line before the next hunk's first line.
              var belowLimit = sourceLines.len
              if hunkIdx < file.diff.hunks.len - 1:
                let nextHunk = file.diff.hunks[hunkIdx + 1]
                var nextFirst = 0
                for nli in nextHunk.lines:
                  let nln = if nli.newLine > 0: nli.newLine
                            elif nli.oldLine > 0: nli.oldLine
                            else: 0
                  if nln > 0:
                    nextFirst = nln
                    break
                # Also account for existing "expand above" on the
                # next hunk.
                let nextAboveCount = self.expandAbove.getExpand(fileIdx, hunkIdx + 1)
                if nextFirst > 0:
                  belowLimit = min(belowLimit, nextFirst - nextAboveCount - 1)

              if hunkLastLine < belowLimit:
                # There are lines available to expand.
                let endLine = min(belowLimit, hunkLastLine + belowCount)

                # Render expanded lines below as context.
                if belowCount > 0 and endLine > hunkLastLine:
                  for lineNum in (hunkLastLine + 1) .. endLine:
                    if lineNum >= 1 and lineNum <= sourceLines.len:
                      tdiv(class = "deepreview-unified-line deepreview-unified-line-context deepreview-expanded-context"):
                        span(class = "deepreview-unified-gutter-old"):
                          text cstring($lineNum)
                        span(class = "deepreview-unified-gutter-new"):
                          text cstring($lineNum)
                        span(class = "deepreview-unified-line-content"):
                          text cstring(sourceLines[lineNum - 1])

                # Render the expand-below button.
                if endLine < belowLimit or belowCount == 0:
                  tdiv(
                    class = "deepreview-expand-row",
                    onclick = self.makeExpandBelowHandler(fileIdx, hunkIdx)
                  ):
                    span(class = "deepreview-expand-icon"): text "..."
                    span(class = "deepreview-expand-label"):
                      text cstring(fmt"Expand 10 lines below")

proc renderCallTrace(self: DeepReviewComponent): VNode =
  ## Render the call trace panel.
  if self.drData.callTrace.isNil or self.drData.callTrace.nodes.len == 0:
    return buildHtml(tdiv(class = "deepreview-calltrace")):
      tdiv(class = "deepreview-calltrace-header"): text "Call Trace"
      tdiv(class = "deepreview-calltrace-empty"): text "No call trace data"
  else:
    buildHtml(tdiv(class = "deepreview-calltrace")):
      tdiv(class = "deepreview-calltrace-header"): text "Call Trace"
      tdiv(class = "deepreview-calltrace-body"):
        for node in self.drData.callTrace.nodes:
          renderCallTraceNode(node, 0)

# ---------------------------------------------------------------------------
# Main render
# ---------------------------------------------------------------------------

proc exposeTestHelpers(self: DeepReviewComponent) =
  ## Expose helper functions on the ``window`` object for E2E test
  ## interaction. Karax's event delegation can make programmatic
  ## ``dispatchEvent`` calls unreliable for range inputs, so the
  ## tests call these helpers directly.
  ##
  ## We use closures that capture ``self`` so the JS functions don't
  ## need to reference mangled Nim method names.
  let selfCapture = self
  proc setExec(idx: int) =
    selfCapture.selectedExecutionIndex = idx
    selfCapture.updateDecorations()
    selfCapture.syncLegacyDeepReviewIntoVM()
  proc setIter(idx: int) =
    selfCapture.selectedIteration = idx
    selfCapture.syncLegacyDeepReviewIntoVM()
  proc setViewMode(mode: cstring) =
    ## Switch the view mode. Accepts "unified" or "fullfiles".
    let modeStr = $mode
    if modeStr == "unified":
      selfCapture.viewMode = Unified
    else:
      # Switching back to FullFiles requires re-initialising the Monaco
      # editor because Karax destroys and re-creates the editor div when
      # toggling between the Unified diff VNode and the editor VNode.
      selfCapture.viewMode = FullFiles
      selfCapture.editorInitialized = false
      selfCapture.decorationCollection = nil
    selfCapture.syncLegacyDeepReviewIntoVM()

  proc setTraceContext(id: int) =
    ## Set the trace context to the given id.
    selfCapture.selectedTraceContextId = id
    selfCapture.updateDecorations()
    selfCapture.syncLegacyDeepReviewIntoVM()

  proc expandAbove(fileIdx: int, hunkIdx: int) =
    ## Expand context above a hunk by EXPAND_STEP lines.
    selfCapture.ensureExpansionState()
    let current = selfCapture.expandAbove.getExpand(fileIdx, hunkIdx)
    selfCapture.expandAbove.setExpand(fileIdx, hunkIdx, current + EXPAND_STEP)
    selfCapture.syncLegacyDeepReviewIntoVM()
  proc expandBelow(fileIdx: int, hunkIdx: int) =
    ## Expand context below a hunk by EXPAND_STEP lines.
    selfCapture.ensureExpansionState()
    let current = selfCapture.expandBelow.getExpand(fileIdx, hunkIdx)
    selfCapture.expandBelow.setExpand(fileIdx, hunkIdx, current + EXPAND_STEP)
    selfCapture.syncLegacyDeepReviewIntoVM()

  {.emit: """
  window.__deepreviewSetExecution = `setExec`;
  window.__deepreviewSetIteration = `setIter`;
  window.__deepreviewSetViewMode = `setViewMode`;
  window.__deepreviewSetTraceContext = `setTraceContext`;
  window.__deepreviewExpandAbove = `expandAbove`;
  window.__deepreviewExpandBelow = `expandBelow`;
  """.}

proc setDeepReviewViewMode(self: DeepReviewComponent;
                           mode: DeepReviewPanelViewMode) =
  self.viewMode = vmViewModeToLegacy(mode)
  if self.viewMode == FullFiles:
    self.editorInitialized = false
    self.decorationCollection = nil
  self.syncLegacyDeepReviewIntoVM()

proc setDeepReviewExecution(self: DeepReviewComponent; index: int) =
  self.selectedExecutionIndex = index
  self.updateDecorations()
  self.syncLegacyDeepReviewIntoVM()

proc setDeepReviewIteration(self: DeepReviewComponent; index: int) =
  self.selectedIteration = index
  self.syncLegacyDeepReviewIntoVM()

proc setDeepReviewTraceContext(self: DeepReviewComponent; id: int) =
  self.selectedTraceContextId = id
  self.updateDecorations()
  self.syncLegacyDeepReviewIntoVM()

proc selectDeepReviewHunk(self: DeepReviewComponent; fileIdx, hunkIdx: int) =
  self.toggleDrHunkSelection(fileIdx, hunkIdx)
  self.syncLegacyDeepReviewIntoVM()

proc clearSelectedDeepReviewHunks(self: DeepReviewComponent) =
  self.clearDrHunkSelection()
  self.syncLegacyDeepReviewIntoVM()

proc afterDeepReviewDynamicRender(self: DeepReviewComponent) =
  self.initEditor()
  if self.viewMode == Unified:
    {.emit: """
    var fileEl = document.querySelector(
      '.deepreview-unified-file[data-file-index="' + `self`.selectedFileIndex + '"]');
    if (fileEl) {
      fileEl.scrollIntoView({ behavior: 'auto', block: 'start' });
    }
    """.}

proc tryMountIsoNimDeepReviewPanel*(componentId: int) =
  when defined(js):
    if isoNimDeepReviewMountedIds.hasKey(componentId) and
       isoNimDeepReviewMountedIds[componentId]:
      return
    if not deepReviewComponentRefs.hasKey(componentId):
      return
    let component = deepReviewComponentRefs[componentId]
    let vm = ensureDeepReviewVM(component)
    if vm.isNil:
      return
    let container = document.getElementById(
      cstring(fmt"deepReviewComponent-{componentId}"))
    if container.isNil:
      return
    component.exposeTestHelpers()
    component.syncLegacyDeepReviewIntoVM()
    let callbacks = DeepReviewCallbacks(
      onSelectFile: proc(index: int) =
        component.switchToFile(index),
      onSetExecution: proc(index: int) =
        component.setDeepReviewExecution(index),
      onSetIteration: proc(index: int) =
        component.setDeepReviewIteration(index),
      onSetTraceContext: proc(id: int) =
        component.setDeepReviewTraceContext(id),
      onSetViewMode: proc(mode: DeepReviewPanelViewMode) =
        component.setDeepReviewViewMode(mode),
      onSelectHunk: proc(fileIdx, hunkIdx: int) =
        component.selectDeepReviewHunk(fileIdx, hunkIdx),
      onCopySelectedHunks: proc() =
        component.copyDrSelectedHunksAsPatch()
        component.syncLegacyDeepReviewIntoVM(),
      onClearSelectedHunks: proc() =
        component.clearSelectedDeepReviewHunks(),
      afterDynamicRender: proc() =
        component.afterDeepReviewDynamicRender(),
    )
    mountIsoNimDeepReviewPanel(
      cast[isonim_dom_api.Element](container), vm, componentId, callbacks)
    isoNimDeepReviewMountedIds[componentId] = true
  else:
    discard
