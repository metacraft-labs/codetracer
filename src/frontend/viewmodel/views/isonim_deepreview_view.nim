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

proc renderFileRow(r: MockRenderer; vm: DeepReviewVM; index: int;
                   file: DeepReviewFileEntry;
                   callbacks: DeepReviewCallbacks): MockNode =
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

proc renderHeader(r: MockRenderer; vm: DeepReviewVM;
                  callbacks: DeepReviewCallbacks): MockNode =
  ui(r):
    tdiv(class = DeepReviewHeaderClass):
      if vm.sessionTitle.val.len > 0:
        span(class = "deepreview-session-title"):
          text vm.sessionTitle.val
      span(class = "deepreview-commit"):
        text "Commit: " & vm.commitDisplay.val
      if vm.traceContexts.val.len > 0:
        select(class = "deepreview-trace-select",
               onchange = proc() =
                 if callbacks.onSetTraceContext != nil:
                   callbacks.onSetTraceContext(vm.selectedTraceContextId.val)):
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

proc renderSliders(r: MockRenderer; vm: DeepReviewVM;
                   callbacks: DeepReviewCallbacks): MockNode =
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
          input(class = "deepreview-slider-input", `type` = "range",
                min = "0", max = $(vm.flowCount.val - 1),
                value = $vm.selectedExecutionIndex.val)
          span(class = "deepreview-slider-info"):
            text executionInfoText(vm)
      if vm.maxIterations.val > 0:
        tdiv(class = "deepreview-slider"):
          span(class = "deepreview-slider-label"):
            text "Iteration:"
          input(class = "deepreview-slider-input", `type` = "range",
                min = "0", max = $(vm.maxIterations.val - 1),
                value = $vm.selectedIteration.val)
          span(class = "deepreview-slider-info"):
            text iterationInfoText(vm)

proc renderUnifiedDiff(r: MockRenderer; vm: DeepReviewVM;
                       callbacks: DeepReviewCallbacks): MockNode =
  let selected = vm.selectedHunks.val
  ui(r):
    tdiv(class = DeepReviewUnifiedDiffClass):
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
        let fileHunks = file.hunks
        tdiv(class = "deepreview-unified-file",
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
          for hunkIdx, hunk in fileHunks:
            let capturedFileIdx = fileIndexVal
            let capturedHunkIdx = hunkIdx
            let hunkSelected = isHunkSelected(selected, capturedFileIdx, capturedHunkIdx)
            tdiv(class = hunkClass(hunkSelected)):
              tdiv(class = "deepreview-unified-hunk-header hunk-header-selectable",
                   onclick = proc() =
                     if callbacks.onSelectHunk != nil:
                       callbacks.onSelectHunk(capturedFileIdx, capturedHunkIdx)):
                if hunkSelected:
                  span(class = "hunk-selection-indicator"):
                    text "selected"
                text fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@"
              for line in hunk.lines:
                let lineTypeVal = line.lineType
                let lineContentVal = line.content
                let oldLineVal = line.oldLine
                let newLineVal = line.newLine
                let valuesVal = line.values
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

proc renderCallTrace(r: MockRenderer; vm: DeepReviewVM): MockNode =
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
                   style = fmt"padding-left: {nodeDepth * 16}px"):
                span(class = "deepreview-calltrace-name"):
                  text nodeName
                span(class = "deepreview-calltrace-count"):
                  text " x" & $nodeCount

proc renderDeepReviewPanel*(r: MockRenderer; vm: DeepReviewVM;
    componentId: int; callbacks: DeepReviewCallbacks =
      DeepReviewCallbacks()): MockNode =
  var header: MockNode
  var body: MockNode
  let panel = ui(r):
    tdiv(class = DeepReviewContainerClass):
      tdiv(ref = header):
        discard
      tdiv(ref = body):
        discard

  createRenderEffect proc() =
    r.clearChildren(header)
    r.clearChildren(body)
    if not vm.hasData.val:
      let errorNode = ui(r):
        tdiv(class = DeepReviewErrorClass):
          text DeepReviewNoDataText
      r.appendChild(body, errorNode)
      return
    r.appendChild(header, renderHeader(r, vm, callbacks))
    if vm.glEmbedded.val:
      var embeddedArea: MockNode
      let embeddedNode = ui(r):
        tdiv(ref = embeddedArea, class = DeepReviewEditorAreaClass)
      r.appendChild(embeddedArea, renderUnifiedDiff(r, vm, callbacks))
      r.appendChild(body, embeddedNode)
    else:
      var fileList: MockNode
      var editorArea: MockNode
      var calltraceArea: MockNode
      let bodyNode = ui(r):
        tdiv(class = DeepReviewBodyClass):
          tdiv(ref = fileList, class = DeepReviewFileListClass)
          tdiv(ref = editorArea, class = DeepReviewEditorAreaClass)
          tdiv(ref = calltraceArea)
      for i, file in vm.files.val:
        r.appendChild(fileList, renderFileRow(r, vm, i, file, callbacks))
      if vm.viewMode.val == drpvmUnified:
        r.appendChild(editorArea, renderUnifiedDiff(r, vm, callbacks))
      else:
        r.appendChild(editorArea, renderSliders(r, vm, callbacks))
        let editorNode = ui(r):
          tdiv(class = DeepReviewEditorClass, id = editorId(componentId))
        r.appendChild(editorArea, editorNode)
      r.appendChild(calltraceArea, renderCallTrace(r, vm))
      r.appendChild(body, bodyNode)
    if callbacks.afterDynamicRender != nil:
      callbacks.afterDynamicRender()

  panel

when defined(js):
  proc renderDeepReviewPanel*(r: WebRenderer; vm: DeepReviewVM;
      componentId: int; callbacks: DeepReviewCallbacks =
        DeepReviewCallbacks()): isonim_dom.Element =
    var rootBody: isonim_dom.Element
    let panel = ui(r):
      tdiv(class = DeepReviewContainerClass):
        tdiv(ref = rootBody):
          discard

    createRenderEffect proc() =
      var componentIdValue = componentId
      var hasData = vm.hasData.val
      var embedded = vm.glEmbedded.val
      var sessionTitle = cstring(vm.sessionTitle.val)
      var commitDisplay = cstring(vm.commitDisplay.val)
      var statsText = cstring(vm.statsText.val)
      var showToggle = not vm.glEmbedded.val
      var isUnified = vm.viewMode.val == drpvmUnified
      var flowCount = vm.flowCount.val
      var execIndex = vm.selectedExecutionIndex.val
      var funcKey = cstring(vm.currentFunctionKey.val)
      var maxIterations = vm.maxIterations.val
      var iterIndex = vm.selectedIteration.val
      {.emit: """
        `rootBody`.innerHTML = '';
        if (!`hasData`) {
          const err = document.createElement('div');
          err.className = 'deepreview-error';
          err.textContent = 'No DeepReview data loaded. Use --deepreview <path> to load a file.';
          `rootBody`.appendChild(err);
          return;
        }
        const header = document.createElement('div');
        header.className = 'deepreview-header';
        if (`sessionTitle`.length > 0) {
          const title = document.createElement('span');
          title.className = 'deepreview-session-title';
          title.textContent = `sessionTitle`;
          header.appendChild(title);
        }
        const commit = document.createElement('span');
        commit.className = 'deepreview-commit';
        commit.textContent = 'Commit: ' + `commitDisplay`;
        header.appendChild(commit);
        if (`showToggle`) {
          const toggle = document.createElement('div');
          toggle.className = 'deepreview-mode-toggle';
          const full = document.createElement('button');
          full.className = `isUnified` ? 'deepreview-mode-btn' : 'deepreview-mode-btn deepreview-mode-btn-active';
          full.textContent = 'Full Files';
          full.addEventListener('click', () => {
            if (`callbacks`.onSetViewMode) `callbacks`.onSetViewMode(0);
          });
          const unified = document.createElement('button');
          unified.className = `isUnified` ? 'deepreview-mode-btn deepreview-mode-btn-active' : 'deepreview-mode-btn';
          unified.textContent = 'Unified Diff';
          unified.addEventListener('click', () => {
            if (`callbacks`.onSetViewMode) `callbacks`.onSetViewMode(1);
          });
          toggle.appendChild(full);
          toggle.appendChild(unified);
          header.appendChild(toggle);
        }
        const stats = document.createElement('span');
        stats.className = 'deepreview-stats';
        stats.textContent = `statsText`;
        header.appendChild(stats);
        `rootBody`.appendChild(header);

        const renderUnified = (parent) => {
          const unified = document.createElement('div');
          unified.className = 'deepreview-unified-diff';
          parent.appendChild(unified);
          return unified;
        };

        if (`embedded`) {
          const area = document.createElement('div');
          area.className = 'deepreview-editor-area';
          renderUnified(area);
          `rootBody`.appendChild(area);
        } else {
          const body = document.createElement('div');
          body.className = 'deepreview-body';
          const list = document.createElement('div');
          list.className = 'deepreview-file-list';
          body.appendChild(list);
          const area = document.createElement('div');
          area.className = 'deepreview-editor-area';
          if (`isUnified`) {
            renderUnified(area);
          } else {
            if (`flowCount` <= 0) {
              const slider = document.createElement('div');
              slider.className = 'deepreview-slider deepreview-slider-empty';
              const label = document.createElement('span');
              label.className = 'deepreview-slider-label';
              label.textContent = 'No execution data';
              slider.appendChild(label);
              area.appendChild(slider);
            } else {
              const slider = document.createElement('div');
              slider.className = 'deepreview-slider';
              const label = document.createElement('span');
              label.className = 'deepreview-slider-label';
              label.textContent = 'Execution:';
              const input = document.createElement('input');
              input.className = 'deepreview-slider-input';
              input.type = 'range';
              input.min = '0';
              input.max = String(`flowCount` - 1);
              input.value = String(`execIndex`);
              input.addEventListener('input', () => {
                if (`callbacks`.onSetExecution) `callbacks`.onSetExecution(Number(input.value));
              });
              const info = document.createElement('span');
              info.className = 'deepreview-slider-info';
              info.textContent = String(`execIndex` + 1) + '/' + `flowCount` + ' (' + (`funcKey` || '?') + ')';
              slider.appendChild(label);
              slider.appendChild(input);
              slider.appendChild(info);
              area.appendChild(slider);
            }
            if (`maxIterations` > 0) {
              const slider = document.createElement('div');
              slider.className = 'deepreview-slider';
              const label = document.createElement('span');
              label.className = 'deepreview-slider-label';
              label.textContent = 'Iteration:';
              const input = document.createElement('input');
              input.className = 'deepreview-slider-input';
              input.type = 'range';
              input.min = '0';
              input.max = String(`maxIterations` - 1);
              input.value = String(`iterIndex`);
              input.addEventListener('input', () => {
                if (`callbacks`.onSetIteration) `callbacks`.onSetIteration(Number(input.value));
              });
              const info = document.createElement('span');
              info.className = 'deepreview-slider-info';
              info.textContent = String(`iterIndex` + 1) + '/' + `maxIterations`;
              slider.appendChild(label);
              slider.appendChild(input);
              slider.appendChild(info);
              area.appendChild(slider);
            }
            const editor = document.createElement('div');
            editor.className = 'deepreview-editor';
            editor.id = 'deepreview-editor-' + `componentIdValue`;
            area.appendChild(editor);
          }
          body.appendChild(area);
          const ct = document.createElement('div');
          ct.className = 'deepreview-calltrace';
          ct.innerHTML = '<div class="deepreview-calltrace-header">Call Trace</div>';
          body.appendChild(ct);
          `rootBody`.appendChild(body);
        }
      """.}

      for i, file in vm.files.val:
        var fileIdx = i
        var rowClass = cstring(fileItemClass(i == vm.selectedFileIndex.val))
        var status = cstring(file.diffStatus)
        var name = cstring(fileBasename(file.path))
        var path = cstring(file.path)
        var coverage = cstring(file.coverageText)
        var hasCoverage = file.hasCoverage
        var diffLines = cstring(diffLinesSummary(file.linesAdded, file.linesRemoved))
        var hasDiffLines = file.linesAdded > 0 or file.linesRemoved > 0
        var diffLinesClass = cstring("deepreview-diff-lines" &
          diffStatusCssClass(file.diffStatus))
        {.emit: """
          const list = `rootBody`.querySelector('.deepreview-file-list');
          if (list) {
            const row = document.createElement('div');
            row.className = `rowClass`;
            row.addEventListener('click', () => {
              if (`callbacks`.onSelectFile) `callbacks`.onSelectFile(`fileIdx`);
            });
            row.innerHTML = '<div class="deepreview-file-name-row"></div>' +
              '<div class="deepreview-file-path-full"></div>' +
              '<div class="deepreview-file-badges"></div>';
            const nameRow = row.querySelector('.deepreview-file-name-row');
            if (`status`.length > 0) {
              const st = document.createElement('span');
              st.className = 'deepreview-diff-status';
              st.textContent = `status`;
              nameRow.appendChild(st);
            }
            const nm = document.createElement('div');
            nm.className = 'deepreview-file-name';
            nm.textContent = `name`;
            nameRow.appendChild(nm);
            row.querySelector('.deepreview-file-path-full').textContent = `path`;
            if (`hasDiffLines`) {
              const diff = document.createElement('span');
              diff.className = `diffLinesClass`;
              diff.textContent = `diffLines`;
              row.querySelector('.deepreview-file-badges').appendChild(diff);
            }
            if (`hasCoverage`) {
              const badge = document.createElement('span');
              badge.className = 'deepreview-coverage-badge';
              badge.textContent = `coverage`;
              row.querySelector('.deepreview-file-badges').appendChild(badge);
            }
            list.appendChild(row);
          }
        """.}

      for ctx in vm.traceContexts.val:
        var ctxId = ctx.id
        var ctxLabel = cstring(ctx.label)
        var selected = ctx.id == vm.selectedTraceContextId.val
        {.emit: """
          let select = `rootBody`.querySelector('.deepreview-trace-select');
          if (!select) {
            const header = `rootBody`.querySelector('.deepreview-header');
            const stats = `rootBody`.querySelector('.deepreview-stats');
            select = document.createElement('select');
            select.className = 'deepreview-trace-select';
            select.addEventListener('change', () => {
              if (`callbacks`.onSetTraceContext) `callbacks`.onSetTraceContext(Number(select.value));
            });
            header.insertBefore(select, stats);
          }
          const option = document.createElement('option');
          option.value = String(`ctxId`);
          option.textContent = `ctxLabel`;
          option.selected = `selected`;
          select.appendChild(option);
        """.}

      for file in vm.unifiedFiles.val:
        var fileIndex = file.fileIndex
        var path = cstring(file.path)
        var status = cstring(file.diffStatus)
        var added = file.linesAdded
        var removed = file.linesRemoved
        {.emit: """
          const unified = `rootBody`.querySelector('.deepreview-unified-diff');
          if (unified) {
            const fileEl = document.createElement('div');
            fileEl.className = 'deepreview-unified-file';
            fileEl.setAttribute('data-file-index', String(`fileIndex`));
            const header = document.createElement('div');
            header.className = 'deepreview-unified-file-header';
            if (`status`.length > 0) {
              const st = document.createElement('span');
              st.className = 'deepreview-diff-status';
              st.textContent = `status`;
              header.appendChild(st);
            }
            const p = document.createElement('span');
            p.className = 'deepreview-unified-file-path';
            p.textContent = `path`;
            header.appendChild(p);
            if (`added` > 0 || `removed` > 0) {
              const stats = document.createElement('span');
              stats.className = 'deepreview-unified-file-stats';
              stats.textContent = '+' + `added` + ' -' + `removed`;
              header.appendChild(stats);
            }
            fileEl.appendChild(header);
            unified.appendChild(fileEl);
          }
        """.}
        for hunkIdx, hunk in file.hunks:
          var hunkHeader = cstring(fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@")
          var selected = isHunkSelected(vm.selectedHunks.val, file.fileIndex, hunkIdx)
          var hunkCls = cstring(hunkClass(selected))
          var hidx = hunkIdx
          {.emit: """
            const fileEl = `rootBody`.querySelector('.deepreview-unified-file[data-file-index="' + `fileIndex` + '"]');
            if (fileEl) {
              const hunk = document.createElement('div');
              hunk.className = `hunkCls`;
              const header = document.createElement('div');
              header.className = 'deepreview-unified-hunk-header hunk-header-selectable';
              header.textContent = `hunkHeader`;
              header.addEventListener('click', () => {
                if (`callbacks`.onSelectHunk) `callbacks`.onSelectHunk(`fileIndex`, `hidx`);
              });
              hunk.appendChild(header);
              fileEl.appendChild(hunk);
            }
          """.}
          for line in hunk.lines:
            var cls = cstring(lineClass(line.lineType))
            var content = cstring(line.content)
            var oldLine = if line.lineType != "added" and line.oldLine > 0: cstring($line.oldLine) else: cstring""
            var newLine = if line.lineType != "removed" and line.newLine > 0: cstring($line.newLine) else: cstring""
            {.emit: """
              const hunks = `rootBody`.querySelectorAll('.deepreview-unified-file[data-file-index="' + `fileIndex` + '"] .deepreview-unified-hunk');
              const hunk = hunks[hunks.length - 1];
              if (hunk) {
                const row = document.createElement('div');
                row.className = `cls`;
                row.innerHTML = '<span class="deepreview-unified-gutter-old"></span>' +
                  '<span class="deepreview-unified-gutter-new"></span>' +
                  '<span class="deepreview-unified-line-content"></span>';
                row.querySelector('.deepreview-unified-gutter-old').textContent = `oldLine`;
                row.querySelector('.deepreview-unified-gutter-new').textContent = `newLine`;
                row.querySelector('.deepreview-unified-line-content').textContent = `content`;
                hunk.appendChild(row);
              }
            """.}

      for node in vm.callNodes.val:
        var name = cstring(node.name)
        var count = node.executionCount
        var padding = cstring(fmt"padding-left: {node.depth * 16}px")
        {.emit: """
          const ct = `rootBody`.querySelector('.deepreview-calltrace');
          if (ct) {
            let body = ct.querySelector('.deepreview-calltrace-body');
            if (!body) {
              body = document.createElement('div');
              body.className = 'deepreview-calltrace-body';
              ct.appendChild(body);
            }
            const node = document.createElement('div');
            node.className = 'deepreview-calltrace-node';
            const entry = document.createElement('div');
            entry.className = 'deepreview-calltrace-entry';
            entry.setAttribute('style', `padding`);
            const nm = document.createElement('span');
            nm.className = 'deepreview-calltrace-name';
            nm.textContent = `name`;
            const cnt = document.createElement('span');
            cnt.className = 'deepreview-calltrace-count';
            cnt.textContent = ' x' + `count`;
            entry.appendChild(nm);
            entry.appendChild(cnt);
            node.appendChild(entry);
            body.appendChild(node);
          }
        """.}

      if vm.callNodes.val.len == 0:
        {.emit: """
          const ct = `rootBody`.querySelector('.deepreview-calltrace');
          if (ct && !ct.querySelector('.deepreview-calltrace-empty')) {
            const empty = document.createElement('div');
            empty.className = 'deepreview-calltrace-empty';
            empty.textContent = 'No call trace data';
            ct.appendChild(empty);
          }
        """.}

      if callbacks.afterDynamicRender != nil:
        callbacks.afterDynamicRender()

    panel

  proc mountIsoNimDeepReviewPanel*(container: isonim_dom.Element;
                                   vm: DeepReviewVM;
                                   componentId: int;
                                   callbacks: DeepReviewCallbacks =
                                     DeepReviewCallbacks()) =
    let r = WebRenderer()
    let panel = renderDeepReviewPanel(r, vm, componentId, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
