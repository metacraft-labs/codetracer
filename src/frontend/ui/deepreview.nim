## DeepReview component for the CodeTracer GUI.
##
## Provides a standalone review view that displays DeepReview data
## (exported from .dr binary format as JSON) with:
## - File list sidebar with per-file coverage summary
## - Monaco editor with coverage line highlighting
## - Inline variable values as Monaco decorations
## - Function execution navigation slider
## - Loop iteration navigation slider
## - Call trace tree panel
##
## The component is activated via the ``--deepreview <path>`` CLI argument.
## It operates in a read-only, offline mode without a debugger connection.

import
  ui_imports, ../utils, ../communication,
  std/[strformat, jsconsole]

type langstring = cstring

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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc selectedFile(self: DeepReviewComponent): DeepReviewFileData =
  ## Return the currently selected file, or nil if no files are present.
  if self.drData.isNil or self.drData.files.len == 0:
    return nil
  if self.selectedFileIndex >= self.drData.files.len:
    return self.drData.files[0]
  return self.drData.files[self.selectedFileIndex]

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

  for cov in file.coverage:
    if cov.line < 1:
      continue
    var className: cstring
    if cov.unreachable:
      className = cstring"deepreview-line-unreachable"
    elif cov.executed:
      className = cstring"deepreview-line-executed"
    elif cov.partial:
      className = cstring"deepreview-line-partial"
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

proc buildInlineValueDecorations(file: DeepReviewFileData, executionIndex: int): seq[JsObject] =
  ## Build Monaco afterContent decorations for inline variable values
  ## from the flow data of a specific execution index.
  result = @[]
  if file.isNil or executionIndex < 0 or executionIndex >= file.flow.len:
    return

  let flow = file.flow[executionIndex]
  for step in flow.steps:
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
        endColumn: 1
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

method register*(self: DeepReviewComponent, api: MediatorWithSubscribers) =
  ## Register the component with the mediator event system.
  ## DeepReview operates in offline mode so it does not subscribe to
  ## any debugger events.
  self.api = api

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
    renderLineHighlight: cstring"none",
    lineDecorationsWidth: 20,
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

  # Inline value decorations.
  let valueDecos = buildInlineValueDecorations(file, self.selectedExecutionIndex)
  for d in valueDecos:
    allDecorations.add(d)

  let oldIds = if self.currentDecorationIds.isNil: newJsObject() else: self.currentDecorationIds
  self.currentDecorationIds = self.editor.drDeltaDecorations(oldIds, allDecorations.toJs)

proc switchToFile(self: DeepReviewComponent, fileIndex: int) =
  ## Switch the editor to display a different file.
  if fileIndex == self.selectedFileIndex and self.editorInitialized:
    return
  self.selectedFileIndex = fileIndex
  self.selectedExecutionIndex = 0
  self.selectedIteration = 0

  if self.editorInitialized and not self.editor.isNil:
    let file = self.selectedFile()
    if not file.isNil:
      let content = buildSourcePlaceholder(file)
      self.editor.drSetMonacoValue(content)
      let lang = guessLanguageFromPath(file.path)
      let model = self.editor.drGetMonacoModel()
      if not model.isNil:
        drSetModelLanguage(model, lang)
    self.updateDecorations()

# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------

proc renderFileList(self: DeepReviewComponent): VNode =
  ## Render the file list sidebar.
  buildHtml(tdiv(class = "deepreview-file-list")):
    for i, file in self.drData.files:
      let isSelected = (i == self.selectedFileIndex)
      let selectedClass = if isSelected: " selected" else: ""
      let fileIdx = i
      tdiv(
        class = cstring(fmt"deepreview-file-item{selectedClass}"),
        onclick = proc(ev: Event, n: VNode) =
          self.switchToFile(fileIdx)
          redrawAll()
      ):
        tdiv(class = "deepreview-file-name"):
          text fileBasename(file.path)
        tdiv(class = "deepreview-file-path-full"):
          text $file.path
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

method render*(self: DeepReviewComponent): VNode =
  ## Render the full DeepReview view with sidebar, editor, and call trace.
  let drData = self.drData

  # Schedule editor initialisation after the DOM has been rendered.
  if not self.kxi.isNil:
    self.kxi.afterRedraws.add(proc() =
      self.initEditor()
    )

  if drData.isNil:
    return buildHtml(tdiv(class = "deepreview-container")):
      tdiv(class = "deepreview-error"):
        text "No DeepReview data loaded. Use --deepreview <path> to load a file."

  # Truncate commit SHA for display.
  let commitDisplay = if drData.commitSha.len > 12:
    cstring(($drData.commitSha)[0 ..< 12] & "...")
  else:
    drData.commitSha

  result = buildHtml(tdiv(class = "deepreview-container")):
    # Header bar with commit info and summary statistics.
    tdiv(class = "deepreview-header"):
      span(class = "deepreview-commit"):
        text fmt"Commit: {commitDisplay}"
      span(class = "deepreview-stats"):
        text fmt"{drData.files.len} files | {drData.recordingCount} recordings | {drData.collectionTimeMs}ms"

    tdiv(class = "deepreview-body"):
      # Left sidebar: file list.
      renderFileList(self)

      # Center: editor area with sliders.
      tdiv(class = "deepreview-editor-area"):
        renderExecutionSlider(self)
        renderLoopSlider(self)
        tdiv(
          class = "deepreview-editor",
          id = cstring(fmt"deepreview-editor-{self.id}")
        )

      # Right sidebar: call trace panel.
      renderCallTrace(self)
