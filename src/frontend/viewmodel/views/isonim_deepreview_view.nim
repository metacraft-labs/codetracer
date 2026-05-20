## views/isonim_deepreview_view.nim
##
## IsoNim DOM-rendering view for the standalone DeepReview panel.

import std/[strformat, strutils]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/deepreview_vm

const DeepReviewContainerClass* = "deepreview-container"
const DeepReviewErrorClass* = "deepreview-error"
const DeepReviewNoDataText* =
  "No DeepReview data loaded. Use --deepreview <path> to load a file."
const DeepReviewHeaderClass* = "deepreview-header"
const DeepReviewBodyClass* = "deepreview-body"
const DeepReviewFileListClass* = "deepreview-file-list"
const DeepReviewEditorAreaClass* = "deepreview-editor-area"
const DeepReviewEditorClass* = "deepreview-editor"
const DeepReviewEditorPrefix* = "deepreview-editor"
const DeepReviewUnifiedDiffClass* = "deepreview-unified-diff"
const DeepReviewUnifiedEmptyText* = "No files to display."
const DeepReviewCalltraceClass* = "deepreview-calltrace"

const DeepReviewExpandStep* = 10
  ## Number of context lines revealed per click of an "Expand" row.
  ## Mirrors ``EXPAND_STEP`` in ``ui/deepreview.nim``.

type
  DeepReviewCallbacks* = object
    onSelectFile*: proc(index: int)
    onSetExecution*: proc(index: int)
    onSetIteration*: proc(index: int)
    onSetTraceContext*: proc(id: int)
    onSetViewMode*: proc(mode: DeepReviewPanelViewMode)
    onSelectHunk*: proc(fileIdx, hunkIdx: int)
    onCopySelectedHunks*: proc()
    onClearSelectedHunks*: proc()
    onExpandAbove*: proc(fileIdx, hunkIdx: int)
    onExpandBelow*: proc(fileIdx, hunkIdx: int)
    afterDynamicRender*: proc()

proc editorId*(componentId: int): string =
  DeepReviewEditorPrefix & "-" & $componentId

proc fileBasename*(path: string): string =
  let idx = path.rfind('/')
  if idx >= 0:
    path[idx + 1 .. ^1]
  else:
    path

proc diffStatusCssClass*(status: string): string =
  case status
  of "A", "added": " deepreview-diff-added"
  of "M", "modified": " deepreview-diff-modified"
  of "D", "deleted": " deepreview-diff-deleted"
  else: ""

proc diffLinesSummary*(added, removed: int): string =
  "+" & $added & " / -" & $removed

proc fileItemClass*(selected: bool): string =
  if selected:
    "deepreview-file-item selected"
  else:
    "deepreview-file-item"

proc modeButtonClass*(active: bool): string =
  if active:
    "deepreview-mode-btn deepreview-mode-btn-active"
  else:
    "deepreview-mode-btn"

proc lineClass*(lineType: string): string =
  case lineType
  of "added": "deepreview-unified-line deepreview-unified-line-added"
  of "removed": "deepreview-unified-line deepreview-unified-line-removed"
  else: "deepreview-unified-line deepreview-unified-line-context"

proc hunkClass*(selected: bool): string =
  if selected:
    "deepreview-unified-hunk hunk-selected"
  else:
    "deepreview-unified-hunk"

proc isHunkSelected*(selected: seq[(int, int)]; fileIdx, hunkIdx: int): bool =
  for pair in selected:
    if pair[0] == fileIdx and pair[1] == hunkIdx:
      return true
  false

proc executionInfoText*(vm: DeepReviewVM): string =
  if vm.flowCount.val <= 0:
    "No execution data"
  else:
    let key = if vm.currentFunctionKey.val.len == 0: "?" else: vm.currentFunctionKey.val
    fmt"{vm.selectedExecutionIndex.val + 1}/{vm.flowCount.val} ({key})"

proc iterationInfoText*(vm: DeepReviewVM): string =
  fmt"{vm.selectedIteration.val + 1}/{vm.maxIterations.val}"

proc hunkHeaderText*(hunk: DeepReviewHunkEntry): string =
  "@@ -" & $hunk.oldStart & "," & $hunk.oldCount &
    " +" & $hunk.newStart & "," & $hunk.newCount & " @@"

proc callTraceIndentStyle*(depth: int): string =
  "padding-left: " & $(depth * 16) & "px"

proc trackDeepReviewRender(vm: DeepReviewVM) =
  discard vm.hasData.val
  discard vm.glEmbedded.val
  discard vm.sessionTitle.val
  discard vm.commitDisplay.val
  discard vm.statsText.val
  discard vm.traceContexts.val
  discard vm.selectedTraceContextId.val
  discard vm.viewMode.val
  discard vm.files.val
  discard vm.selectedFileIndex.val
  discard vm.flowCount.val
  discard vm.selectedExecutionIndex.val
  discard vm.currentFunctionKey.val
  discard vm.maxIterations.val
  discard vm.selectedIteration.val
  discard vm.unifiedFiles.val
  discard vm.callNodes.val
  discard vm.selectedHunks.val
  discard vm.hunkToolbarVisible.val
  discard vm.hunkCopyFeedback.val

proc parseControlInt(value: string; fallback: int): int =
  try:
    parseInt(value)
  except ValueError:
    fallback

proc readControlInt(r: MockRenderer; node: MockNode; fallback: int): int =
  parseControlInt(r.inputValue(node), fallback)

when defined(js):
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}

  proc readControlInt(r: WebRenderer; node: isonim_dom.Element;
                      fallback: int): int =
    let asNode = isonim_dom.Node(node)
    parseControlInt($asNode.inputValue(), fallback)

template renderFileRowImpl(r, vm, index, file, callbacks: untyped): untyped =
  let fileIdx = index
  ui(r):
    tdiv(class = fileItemClass(index == vm.selectedFileIndex.val),
         onclick = proc() =
           vm.setSelectedFileIndex(fileIdx)
           if callbacks.onSelectFile != nil:
             callbacks.onSelectFile(fileIdx)):
      tdiv(class = "deepreview-file-name-row"):
        if file.diffStatus.len > 0:
          span(class = "deepreview-diff-status" &
                       diffStatusCssClass(file.diffStatus)):
            text file.diffStatus
        tdiv(class = "deepreview-file-name"):
          text fileBasename(file.path)
      tdiv(class = "deepreview-file-path-full"):
        text file.path
      tdiv(class = "deepreview-file-badges"):
        if file.linesAdded > 0 or file.linesRemoved > 0:
          span(class = "deepreview-diff-lines" &
                       diffStatusCssClass(file.diffStatus)):
            text diffLinesSummary(file.linesAdded, file.linesRemoved)
        if file.hasCoverage:
          span(class = "deepreview-coverage-badge"):
            text file.coverageText

proc renderFileRow(r: MockRenderer; vm: DeepReviewVM; index: int;
                   file: DeepReviewFileEntry;
                   callbacks: DeepReviewCallbacks): MockNode =
  renderFileRowImpl(r, vm, index, file, callbacks)

when defined(js):
  proc renderFileRow(r: WebRenderer; vm: DeepReviewVM; index: int;
                     file: DeepReviewFileEntry;
                     callbacks: DeepReviewCallbacks): isonim_dom.Element =
    renderFileRowImpl(r, vm, index, file, callbacks)

template renderHeaderImpl(r, vm, callbacks: untyped): untyped =
  var traceSelect: typeof(r.createElement("select"))
  ui(r):
    tdiv(class = DeepReviewHeaderClass):
      if vm.sessionTitle.val.len > 0:
        span(class = "deepreview-session-title"):
          text vm.sessionTitle.val
      span(class = "deepreview-commit"):
        text "Commit: " & vm.commitDisplay.val
      if vm.traceContexts.val.len > 0:
        tdiv(class = "deepreview-trace-selector"):
          select(ref = traceSelect,
                 class = "deepreview-trace-select",
                 onchange = proc() =
                   let selectedId = readControlInt(
                     r, traceSelect, vm.selectedTraceContextId.val)
                   if callbacks.onSetTraceContext != nil:
                     callbacks.onSetTraceContext(selectedId)):
            for ctx in vm.traceContexts.val:
              let ctxId = ctx.id
              let ctxLabel = ctx.label
              if ctxId == vm.selectedTraceContextId.val:
                option(value = $ctxId, selected = "selected"):
                  text ctxLabel
              else:
                option(value = $ctxId):
                  text ctxLabel
      if not vm.glEmbedded.val:
        tdiv(class = "deepreview-mode-toggle"):
          button(class = modeButtonClass(vm.viewMode.val == drpvmFullFiles),
                 onclick = proc() =
                   vm.setViewMode(drpvmFullFiles)
                   if callbacks.onSetViewMode != nil:
                     callbacks.onSetViewMode(drpvmFullFiles)):
            text "Full Files"
          button(class = modeButtonClass(vm.viewMode.val == drpvmUnified),
                 onclick = proc() =
                   vm.setViewMode(drpvmUnified)
                   if callbacks.onSetViewMode != nil:
                     callbacks.onSetViewMode(drpvmUnified)):
            text "Unified Diff"
      span(class = "deepreview-stats"):
        text vm.statsText.val

proc renderHeader(r: MockRenderer; vm: DeepReviewVM;
                  callbacks: DeepReviewCallbacks): MockNode =
  renderHeaderImpl(r, vm, callbacks)

when defined(js):
  proc renderHeader(r: WebRenderer; vm: DeepReviewVM;
                    callbacks: DeepReviewCallbacks): isonim_dom.Element =
    renderHeaderImpl(r, vm, callbacks)

template renderSlidersImpl(r, vm, callbacks: untyped): untyped =
  var executionInput: typeof(r.createElement("input"))
  var iterationInput: typeof(r.createElement("input"))
  ui(r):
    tdiv:
      if vm.flowCount.val == 0:
        tdiv(class = "deepreview-slider deepreview-slider-empty"):
          span(class = "deepreview-slider-label"):
            text "No execution data"
      else:
        tdiv(class = "deepreview-slider"):
          span(class = "deepreview-slider-label"):
            text "Execution:"
          input(ref = executionInput,
                class = "deepreview-slider-input", `type` = "range",
                min = "0", max = $(vm.flowCount.val - 1),
                value = $vm.selectedExecutionIndex.val,
                oninput = proc() =
                  let selected = readControlInt(
                    r, executionInput, vm.selectedExecutionIndex.val)
                  if callbacks.onSetExecution != nil:
                    callbacks.onSetExecution(selected))
          span(class = "deepreview-slider-info"):
            text executionInfoText(vm)
      if vm.maxIterations.val > 0:
        tdiv(class = "deepreview-slider"):
          span(class = "deepreview-slider-label"):
            text "Iteration:"
          input(ref = iterationInput,
                class = "deepreview-slider-input", `type` = "range",
                min = "0", max = $(vm.maxIterations.val - 1),
                value = $vm.selectedIteration.val,
                oninput = proc() =
                  let selected = readControlInt(
                    r, iterationInput, vm.selectedIteration.val)
                  if callbacks.onSetIteration != nil:
                    callbacks.onSetIteration(selected))
          span(class = "deepreview-slider-info"):
            text iterationInfoText(vm)

proc renderSliders(r: MockRenderer; vm: DeepReviewVM;
                   callbacks: DeepReviewCallbacks): MockNode =
  renderSlidersImpl(r, vm, callbacks)

when defined(js):
  proc renderSliders(r: WebRenderer; vm: DeepReviewVM;
                     callbacks: DeepReviewCallbacks): isonim_dom.Element =
    renderSlidersImpl(r, vm, callbacks)

template renderUnifiedContextLineImpl(r, line: untyped): untyped =
  ## Render one already-revealed context (expanded) diff line.
  let lineContentVal = line.content
  let oldLineVal = line.oldLine
  let newLineVal = line.newLine
  ui(r):
    tdiv(class = lineClass("context") & " deepreview-expanded-context"):
      span(class = "deepreview-unified-gutter-old"):
        if oldLineVal > 0:
          text $oldLineVal
      span(class = "deepreview-unified-gutter-new"):
        if newLineVal > 0:
          text $newLineVal
      span(class = "deepreview-unified-line-content"):
        text lineContentVal

proc renderUnifiedContextLine(r: MockRenderer;
                              line: DeepReviewDiffLineEntry): MockNode =
  renderUnifiedContextLineImpl(r, line)

when defined(js):
  proc renderUnifiedContextLine(r: WebRenderer;
                                line: DeepReviewDiffLineEntry):
                                isonim_dom.Element =
    renderUnifiedContextLineImpl(r, line)

template renderUnifiedDiffLineImpl(r, line: untyped): untyped =
  ## Render one hunk diff line (added/removed/context) with optional
  ## inline Omniscience flow values.
  let lineTypeVal = line.lineType
  let lineContentVal = line.content
  let oldLineVal = line.oldLine
  let newLineVal = line.newLine
  let valuesVal = line.values
  ui(r):
    tdiv(class = lineClass(lineTypeVal)):
      span(class = "deepreview-unified-gutter-old"):
        if lineTypeVal != "added" and oldLineVal > 0:
          text $oldLineVal
      span(class = "deepreview-unified-gutter-new"):
        if lineTypeVal != "removed" and newLineVal > 0:
          text $newLineVal
      span(class = "deepreview-unified-line-content"):
        text lineContentVal
      if valuesVal.len > 0:
        span(class = "deepreview-flow-values"):
          for value in valuesVal:
            let nameVal = value.name
            let valueVal = value.value
            let truncatedVal = value.truncated
            span(class = "flow-parallel-value"):
              span(class = "flow-parallel-value-name"):
                text "<" & nameVal & ">"
              span(class = "flow-parallel-value-box flow-parallel-value-before-only"):
                text valueVal & (if truncatedVal: "..." else: "")

proc renderUnifiedDiffLine(r: MockRenderer;
                           line: DeepReviewDiffLineEntry): MockNode =
  renderUnifiedDiffLineImpl(r, line)

when defined(js):
  proc renderUnifiedDiffLine(r: WebRenderer;
                             line: DeepReviewDiffLineEntry):
                             isonim_dom.Element =
    renderUnifiedDiffLineImpl(r, line)

template renderUnifiedHunkImpl(r, hunk, fileIdx, hunkIdx, hunkSelected,
                               callbacks: untyped): untyped =
  ## Render a single hunk.  Extracted into a proc so the per-hunk
  ## ``onclick`` closures capture ``fileIdx`` / ``hunkIdx`` through proc
  ## parameters — a guaranteed-fresh binding.  A bare ``for``-loop-body
  ## ``let`` is not a reliable closure-capture boundary in Nim, so inline
  ## hunk handlers would otherwise all target the last hunk.
  ##
  ## The diff/context line children are appended with explicit
  ## ``r.appendChild`` calls (plain Nim ``for`` loops outside the ``ui``
  ## block).  A bare proc-call as a ``for``-loop body *inside* a ``ui``
  ## block is dropped by the IsoNim DSL macro, so the rows would never
  ## render — surfaced by the context-expansion E2E tests.
  let capturedFileIdx = fileIdx
  let capturedHunkIdx = hunkIdx
  var hunkRoot: typeof(r.createElement("div"))
  let hunkNode = ui(r):
    tdiv(ref = hunkRoot, class = hunkClass(hunkSelected)):
      tdiv(class = "deepreview-unified-hunk-header hunk-header-selectable",
           onclick = proc() =
             if callbacks.onSelectHunk != nil:
               callbacks.onSelectHunk(capturedFileIdx, capturedHunkIdx)):
        if hunkSelected:
          span(class = "hunk-selection-indicator"):
            text "selected"
        text hunkHeaderText(hunk)
      # "Expand above" row — reveals context lines preceding the hunk.
      if hunk.canExpandAbove:
        tdiv(class = "deepreview-expand-row deepreview-expand-row-above",
             onclick = proc() =
               if callbacks.onExpandAbove != nil:
                 callbacks.onExpandAbove(capturedFileIdx, capturedHunkIdx)):
          span(class = "deepreview-expand-icon"):
            text "..."
          span(class = "deepreview-expand-label"):
            text "Expand " & $DeepReviewExpandStep & " lines"
  # Already-revealed context lines above the hunk.
  for line in hunk.expandedAbove:
    r.appendChild(hunkRoot, renderUnifiedContextLine(r, line))
  # The hunk's own diff lines.
  for line in hunk.lines:
    r.appendChild(hunkRoot, renderUnifiedDiffLine(r, line))
  # Already-revealed context lines below the hunk.
  for line in hunk.expandedBelow:
    r.appendChild(hunkRoot, renderUnifiedContextLine(r, line))
  # "Expand below" row — reveals context lines following the hunk.
  if hunk.canExpandBelow:
    let expandBelowRow = ui(r):
      tdiv(class = "deepreview-expand-row deepreview-expand-row-below",
           onclick = proc() =
             if callbacks.onExpandBelow != nil:
               callbacks.onExpandBelow(capturedFileIdx, capturedHunkIdx)):
        span(class = "deepreview-expand-icon"):
          text "..."
        span(class = "deepreview-expand-label"):
          text "Expand " & $DeepReviewExpandStep & " lines"
    r.appendChild(hunkRoot, expandBelowRow)
  hunkNode

proc renderUnifiedHunk(r: MockRenderer; hunk: DeepReviewHunkEntry;
                       fileIdx, hunkIdx: int; hunkSelected: bool;
                       callbacks: DeepReviewCallbacks): MockNode =
  renderUnifiedHunkImpl(r, hunk, fileIdx, hunkIdx, hunkSelected, callbacks)

when defined(js):
  proc renderUnifiedHunk(r: WebRenderer; hunk: DeepReviewHunkEntry;
                         fileIdx, hunkIdx: int; hunkSelected: bool;
                         callbacks: DeepReviewCallbacks): isonim_dom.Element =
    renderUnifiedHunkImpl(r, hunk, fileIdx, hunkIdx, hunkSelected, callbacks)

template renderUnifiedDiffImpl(r, vm, callbacks: untyped): untyped =
  let selected = vm.selectedHunks.val
  var diffRoot: typeof(r.createElement("div"))
  let panel = ui(r):
    tdiv(ref = diffRoot, class = DeepReviewUnifiedDiffClass):
      if vm.hunkToolbarVisible.val:
        tdiv(class = "hunk-toolbar"):
          span(class = "hunk-toolbar-count"):
            text $vm.selectedHunks.val.len & " hunk" &
              (if vm.selectedHunks.val.len == 1: "" else: "s") & " selected"
          tdiv(class = "hunk-toolbar-actions"):
            tdiv(class = "hunk-toolbar-button",
                 onclick = proc() =
                   if callbacks.onCopySelectedHunks != nil:
                     callbacks.onCopySelectedHunks()):
              text (if vm.hunkCopyFeedback.val: "Copied!" else: "Copy as patch")
            tdiv(class = "hunk-toolbar-button hunk-toolbar-button-subtle",
                 onclick = proc() =
                   vm.setSelectedHunks([])
                   if callbacks.onClearSelectedHunks != nil:
                     callbacks.onClearSelectedHunks()):
              text "Clear"
      if vm.unifiedFiles.val.len == 0:
        tdiv(class = "deepreview-unified-empty"):
          text DeepReviewUnifiedEmptyText
  for file in vm.unifiedFiles.val:
    let fileIndexVal = file.fileIndex
    let filePathVal = file.path
    let fileStatusVal = file.diffStatus
    let fileAddedVal = file.linesAdded
    let fileRemovedVal = file.linesRemoved
    var hunkHost: typeof(r.createElement("div"))
    let fileNode = ui(r):
      tdiv(ref = hunkHost, class = "deepreview-unified-file",
           `data-file-index` = $fileIndexVal):
        tdiv(class = "deepreview-unified-file-header"):
          if fileStatusVal.len > 0:
            span(class = "deepreview-diff-status" &
                         diffStatusCssClass(fileStatusVal)):
              text fileStatusVal
          span(class = "deepreview-unified-file-path"):
            text filePathVal
          if fileAddedVal > 0 or fileRemovedVal > 0:
            span(class = "deepreview-unified-file-stats"):
              span(class = "deepreview-unified-additions"):
                text "+" & $fileAddedVal
              span(class = "deepreview-unified-deletions"):
                text "-" & $fileRemovedVal
    for hunkIdx, hunk in file.hunks:
      let hunkSelected = isHunkSelected(selected, fileIndexVal, hunkIdx)
      r.appendChild(hunkHost,
                    renderUnifiedHunk(r, hunk, fileIndexVal, hunkIdx,
                                      hunkSelected, callbacks))
    r.appendChild(diffRoot, fileNode)
  panel

proc renderUnifiedDiff(r: MockRenderer; vm: DeepReviewVM;
                       callbacks: DeepReviewCallbacks): MockNode =
  renderUnifiedDiffImpl(r, vm, callbacks)

when defined(js):
  proc renderUnifiedDiff(r: WebRenderer; vm: DeepReviewVM;
                         callbacks: DeepReviewCallbacks): isonim_dom.Element =
    renderUnifiedDiffImpl(r, vm, callbacks)

template renderCallTraceImpl(r, vm: untyped): untyped =
  ui(r):
    tdiv(class = DeepReviewCalltraceClass):
      tdiv(class = "deepreview-calltrace-header"):
        text "Call Trace"
      if vm.callNodes.val.len == 0:
        tdiv(class = "deepreview-calltrace-empty"):
          text "No call trace data"
      else:
        tdiv(class = "deepreview-calltrace-body"):
          for node in vm.callNodes.val:
            let nodeName = node.name
            let nodeCount = node.executionCount
            let nodeDepth = node.depth
            tdiv(class = "deepreview-calltrace-node"):
              tdiv(class = "deepreview-calltrace-entry",
                   style = callTraceIndentStyle(nodeDepth)):
                span(class = "deepreview-calltrace-name"):
                  text nodeName
                span(class = "deepreview-calltrace-count"):
                  text " x" & $nodeCount

proc renderCallTrace(r: MockRenderer; vm: DeepReviewVM): MockNode =
  renderCallTraceImpl(r, vm)

when defined(js):
  proc renderCallTrace(r: WebRenderer; vm: DeepReviewVM): isonim_dom.Element =
    renderCallTraceImpl(r, vm)

proc renderDeepReviewLoadedContent(r: MockRenderer; vm: DeepReviewVM;
    componentId: int; callbacks: DeepReviewCallbacks): MockNode =
  ui(r):
    tdiv:
      renderHeader(r, vm, callbacks)
      if vm.glEmbedded.val:
        tdiv(class = DeepReviewEditorAreaClass):
          renderUnifiedDiff(r, vm, callbacks)
      else:
        tdiv(class = DeepReviewBodyClass):
          tdiv(class = DeepReviewFileListClass):
            for i, file in vm.files.val:
              renderFileRow(r, vm, i, file, callbacks)
          tdiv(class = DeepReviewEditorAreaClass):
            if vm.viewMode.val == drpvmUnified:
              renderUnifiedDiff(r, vm, callbacks)
            else:
              renderSliders(r, vm, callbacks)
              tdiv(class = DeepReviewEditorClass, id = editorId(componentId))
          renderCallTrace(r, vm)

when defined(js):
  proc renderDeepReviewLoadedContent(r: WebRenderer; vm: DeepReviewVM;
      componentId: int; callbacks: DeepReviewCallbacks): isonim_dom.Element =
    ui(r):
      tdiv:
        renderHeader(r, vm, callbacks)
        if vm.glEmbedded.val:
          tdiv(class = DeepReviewEditorAreaClass):
            renderUnifiedDiff(r, vm, callbacks)
        else:
          tdiv(class = DeepReviewBodyClass):
            tdiv(class = DeepReviewFileListClass):
              for i, file in vm.files.val:
                renderFileRow(r, vm, i, file, callbacks)
            tdiv(class = DeepReviewEditorAreaClass):
              if vm.viewMode.val == drpvmUnified:
                renderUnifiedDiff(r, vm, callbacks)
              else:
                renderSliders(r, vm, callbacks)
                tdiv(class = DeepReviewEditorClass, id = editorId(componentId))
            renderCallTrace(r, vm)

template renderDeepReviewPanelImpl(r, vm, componentId, callbacks: untyped):
    untyped =
  var rootBody: typeof(r.createElement("div"))
  let panel = ui(r):
    tdiv(class = DeepReviewContainerClass):
      tdiv(ref = rootBody):
        discard

  createRenderEffect proc() =
    # IsoNim natural `for` loops materialize when their `ui` block is
    # constructed, so collection/branch changes remount one DSL-built subtree.
    trackDeepReviewRender(vm)
    r.clearChildren(rootBody)
    if not vm.hasData.val:
      let errorNode = ui(r):
        tdiv(class = DeepReviewErrorClass):
          text DeepReviewNoDataText
      r.appendChild(rootBody, errorNode)
    else:
      r.appendChild(rootBody,
                    renderDeepReviewLoadedContent(
                      r, vm, componentId, callbacks))
    if callbacks.afterDynamicRender != nil:
      callbacks.afterDynamicRender()

  panel

proc renderDeepReviewPanel*(r: MockRenderer; vm: DeepReviewVM;
    componentId: int; callbacks: DeepReviewCallbacks =
      DeepReviewCallbacks()): MockNode =
  renderDeepReviewPanelImpl(r, vm, componentId, callbacks)

when defined(js):
  proc renderDeepReviewPanel*(r: WebRenderer; vm: DeepReviewVM;
      componentId: int; callbacks: DeepReviewCallbacks =
        DeepReviewCallbacks()): isonim_dom.Element =
    renderDeepReviewPanelImpl(r, vm, componentId, callbacks)

  proc mountIsoNimDeepReviewPanel*(container: isonim_dom.Element;
                                   vm: DeepReviewVM;
                                   componentId: int;
                                   callbacks: DeepReviewCallbacks =
                                     DeepReviewCallbacks()) =
    let r = WebRenderer()
    let panel = renderDeepReviewPanel(r, vm, componentId, callbacks)
    # Host interop: the GoldenLayout-owned container is outside this view's
    # DSL tree, so mounting the root element is an explicit DOM operation.
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
