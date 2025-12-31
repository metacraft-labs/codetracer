import
  std/[ cstrutils, jsre ],
  ui_imports, trace, debug, menu, flow, no_source, shortcuts, kdom,
  ../[ renderer, communication, event_helpers, lsp_router ],
  ../../common/ct_event

from welcome_screen import resetView
from event_log import findTRNode
from dom import createElement

include system/timers

type langstring = cstring

# for now applied to user config, but not to commands:
# the commands shortcuts are hardcoded in this file
# so review them if needed!
const MONACO_SHORTCUTS_WHITELIST: seq[cstring] =
  @[
      "F2",
      "F8",
      "F10",
      "F11",
      "F12",
      "SHIFT+F2",
      "SHIFT+F8",
      "SHIFT+F10",
      "SHIFT+F11",
      "SHIFT+F12",
      "CTRL+KeyS",
  ]
const EDITOR_GUTTER_PADDING = 2 #px

method render*(self: EditorViewComponent): VNode
proc getLineFunctionName(self: EditorViewComponent, line: int): cstring
proc removeClasses(index: int, class: cstring, name: string)
proc styleLines(self: EditorViewComponent, editor: MonacoEditor, lines: seq[MonacoLineStyle])
proc ensureExpanded*(self: EditorViewComponent, expanded: EditorViewComponent, line: int)
proc editorLineJump(self: EditorViewComponent, line: int, behaviour: JumpBehaviour)
proc sourceCallJump(self: EditorViewComponent, path: cstring, line: int, targetToken: cstring, behaviour: JumpBehaviour)
func multilineFlowLines*: JsAssoc[int, KaraxInstance]

proc insideLocation(x: float, y: float, location: HTMLBoundingRect): bool =
  x >= location.left and x <= location.right and y >= location.top and y <= location.bottom

proc clearViewZones*(self: EditorViewComponent) =
  self.monacoEditor.changeViewZones do (view: js):
    for viewZone in self.viewZones:
      view.removeZone(viewZone)

proc toggleMacroExpansion*(self: EditorViewComponent) =
  if self.lastMouseMoveLine != -1:
    if self.expanded.hasKey(self.lastMouseMoveLine):
      self.expanded[self.lastMouseMoveLine].isExpanded = not self.expanded[self.lastMouseMoveLine].isExpanded
      self.data.redraw()
    else:
      expand(self.path, self.lastMouseMoveLine)

proc loadKeyPlugins*(self: Component) =
  cdebug "load key plugins"
  for keys, plugin in self.data.keyPlugins[Content.EditorView]:
    var shMonaco = shortcut($keys)
    if shMonaco == -1:
      cwarn "cant create shorctut for key plugin " & $keys
    else:
      self.toJs.monacoEditor.addCommand(shMonaco, proc =
        let position = self.toJs.monacoEditor.getPosition()
        let wordInfo = self.toJs.monacoEditor.getModel().getWordAtPosition(position)

        let path = if not self.toJs.path.isNil: cast[cstring](self.toJs.path) else: cast[cstring](self.toJs.lowLevelTab.path)
        let line = cast[int](position.lineNumber)
        let column = cast[int](position.column)
        let word = if not wordInfo.isNil: cast[cstring](wordInfo.word) else: cstring""
        let startColumn = if not wordInfo.isNil: cast[int](wordInfo.startColumn) else: -1
        let endColumn = if not wordInfo.isNil: cast[int](wordInfo.endColumn) else: -1
        let context = KeyPluginContext(
          path: path,
          line: line,
          column: column,
          startColumn: startColumn,
          endColumn: endColumn,
          word: if not word.isNil: word else: cstring"",
          data: self.data)
        discard plugin(context), cstring"")

func getLine(editor: MonacoEditor): int =
  editor.getPosition().lineNumber

func getLineAndColumn(editor: MonacoEditor): (int, int) =
  let position = editor.getPosition()

  (position.lineNumber, position.column)

func loadCallName(lineText: cstring, column: int): cstring =
  if column >= lineText.len:
    return NO_NAME

  var i = column

  while i >= 0 and (lineText[i].isAlphaNumeric or lineText[i] == '_'):
    i -= 1

  var start = i + 1
  i = column + 1

  while i < lineText.len and (lineText[i].isAlphaNumeric or lineText[i] == '_'):
    i += 1

  var finish = i - 1
  lineText.slice(start, finish + 1)

var commands = JsAssoc[cstring, (proc(editor: MonacoEditor, e: EditorViewComponent): void)]{ ## commands for each monaco editor instance
  # TODO improve or retire other modes
  # cstring"ALT+P":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.flow.switchFlowUI(FlowParallel),
  # cstring"ALT+I":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.flow.switchFlowUI(FlowInline),
  # cstring"ALT+M":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.flow.switchFlowUI(FlowMultiline),
  cstring"ALT+KeyE":      proc(editor: MonacoEditor, e: EditorViewComponent) = e.toggleMacroExpansion(),

  cstring"ALT+KeyT":      proc(editor: MonacoEditor, e: EditorViewComponent) =
    runTracepoints(data),


  cstring"CTRL+Enter": proc(editor: MonacoEditor, e: EditorViewComponent) =
    runTracepoints(data),

  cstring"CTRL+KeyS":      proc(editor: MonacoEditor, e: EditorViewComponent) =
    if not data.functions.update.isNil:
      data.functions.update(data, false)
    else:
      data.saveFiles(data.services.editor.active),

  cstring"CTRL+F5":     proc(editor: MonacoEditor, e: EditorViewComponent) =
    if not data.functions.toggleMode.isNil:
      data.functions.toggleMode(data),

  cstring"CTRL+KeyE":   proc(editor: MonacoEditor, e: EditorViewComponent) =
    ## Mirror the Mousetrap shortcut so toggling works while Monaco has focus.
    if not data.functions.toggleReadOnly.isNil:
      data.functions.toggleReadOnly(data)
      return
    if not data.functions.toggleMode.isNil:
      data.functions.toggleMode(data),

  # TODO: support concurrent when add later on
  # cstring"CTRL+F10": proc(editor: MonacoEditor, e: EditorViewComponent) =
  #   let taskId = genTaskId(Step)
  #   data.step("co-next", CoNext, reverse=false, taskId=taskId),

  cstring"CTRL+F8": proc(editor: MonacoEditor, e: EditorViewComponent) =
    if editor.hasTextFocus():
      let line = editor.getLine()
      e.editorLineJump(line, SmartJump),

  cstring"CTRL+F11": proc(editor: MonacoEditor, e: EditorViewComponent) =
    if editor.hasTextFocus():
      let position = editor.getPosition()
      let targetToken = editor.toJs.getModel().getWordAtPosition(position)

      if not targetToken.isNil:
        e.sourceCallJump(e.name, position.lineNumber, if not targetToken.word.isNil: cast[cstring](targetToken.word) else: cstring"", SmartJump)
}

for i in 1 .. 9:
  capture [i]:
    commands[cstring("CTRL+Digit" & $i)] = proc(editor: MonacoEditor, e: EditorViewComponent) =
      discard data.ui.activeFocus.onCtrlNumber(i)

proc delegateShortcuts*(self: EditorViewComponent, editor: MonacoEditor) =
  cdebug "create context key"
  console.log("SETTING READONLY")
  self.readOnly = editor.toJs.createContextKey(cstring"readOnly", self.data.ui.readOnly)
  for sh, command in commands:
    cdebug "editor: delegate shortcut " & sh
    self.delegateShortcut(sh, command, editor)

  for action, shortcuts in data.config.shortcutMap.actionShortcuts:
    for shortcut in shortcuts:
      let editorShortcut = shortcut.editor
      if editorShortcut notin MONACO_SHORTCUTS_WHITELIST:
        cdebug "editor: ignoring, because not in monaco shortcuts whitelist: " & $editorShortcut
        continue
      cdebug "editor: delegate config monaco shortcut " & $editorShortcut
      capture action, editorShortcut:
        let command = proc(editor: MonacoEditor, e: EditorViewComponent) =
          cdebug "editor: shortcuts: monaco handle " & $editorShortcut & " " & $action
          data.actions[action](nil)
        self.delegateShortcut(editorShortcut, command, editor)

proc closeEditorTab*(data: Data, id: cstring) =
  cdebug "tabs: closeEditorTab " & $id
  if not data.ui.editors.hasKey(id):
    raise newException(Exception, "There is not any editor with the given id.")

  # get the editor
  let editor = data.ui.editors[id]
  unregisterLspEditor(editor)

  # remove editor from open editors registry
  if editor.service.open.hasKey(id):
    discard jsDelete(editor.service.open[id])

  # remove all instances of editor's path from tab history
  let newTabHistory = data.services.editor.tabHistory.filterIt(
    it.name != id
  )

  data.services.editor.tabHistory = newTabHistory
  data.services.editor.historyIndex = data.services.editor.tabHistory.len - 1

  cdebug "tabs: closeEditorTab: historyIndex -> " & $data.services.editor.historyIndex

  # remove editor component from editors registry
  discard jsDelete(data.ui.editors[id])

  # remove editor karax instance
  discard jsDelete(kxiMap[id])

  # add editor to closed tabs registry
  let header = EditorViewTabArgs(name: id, editorView: editor.editorView)
  data.services.editor.closedTabs.add(header)

  # set editor view type panel to nil
  if editor.service.open.len == 0:
    data.ui.editorPanels[EditorView.ViewSource] = nil
    cdebug "editor: on close tab, no tabs left: active = nil"
    data.services.editor.active = nil

proc closeActiveTab*(data: Data) {.locks: 0.} =
  var panel = data.ui.activeEditorPanel
  var active = panel.getActiveContentItem()
  var oldActive = data.services.editor.active

  if data.services.editor.open.hasKey(oldActive) and data.services.editor.open[oldActive].changed:
    data.saveDialog(oldActive, proc = data.closeActiveTab())
  elif data.services.editor.open.hasKey(oldActive):
    active.toJs.remove()
    data.closeEditorTab(oldActive)
  else:
    cwarn "editor: closing tab, but  implemented close expanded.nim"

proc getBoundingClientRect(s: js): HTMLBoundingRect {.importcpp: "#.getBoundingClientRect()".}

proc assemblyRegisterView(state: JsAssoc[cstring, cstring]): VNode =
  buildHtml(table(class = "assembly-registers")):
    for label, value in state:
      tr(class = "assembly-register"):
        td(class = "assembly-register-label"):
          text(label)
        td(class = "assembly-register-value"):
          text(value)


proc removeClasses(index: int, class: cstring, name: string) =
  let elements = jqall(&"#{name}-{index} .{class}")

  for element in elements:
    cast[ClassList](element.classList).remove(class)

proc disableDebugShortcuts*(self: EditorViewComponent) =
  console.log("EDITOR VIEW COMPONENT")
  console.log(self)
  if not self.isNil and not self.readOnly.isNil:
    self.readOnly.set(false)

proc enableDebugShortcuts*(self: EditorViewComponent) =
  console.log("EDITOR VIEW COMPONENT")
  console.log(self)
  if not self.isNil and not self.readOnly.isNil:
    self.readOnly.set(true)

proc highlightTag(path: cstring, tag: Tag, name: cstring) =
  var line = -1
  var highlightEditor = data.ui.editors[path].monacoEditor
  if tag.kind == TagLine and tag.line != -1:
    line = tag.line
  else:
    let regex = if tag.kind == TagRegex: tag.regex else: name
    let location = cast[seq[js]](highlightEditor.getModel().findMatches(regex, false, true, false, false))
    if location.len > 0:
      line = cast[int](location[0][cstring"range"].startLineNumber)
  if line != -1:
    highlightLine(data.services.editor.active, line)
    gotoLine(line)

proc styleLines(self: EditorViewComponent, editor: MonacoEditor, lines: seq[MonacoLineStyle]) =
  if editor.decorations.toJs.isNil:
    editor.decorations = @[]

  let textModel = self.monacoEditor.getModel()
  var newDecorations: seq[DeltaDecoration] = @[]

  for line in lines:
    let lineContent = textModel.getLineContent(line.line)
    let endIndex = lineContent.len() + 1
    let startIndex = textModel.getLineFirstNonWhitespaceColumn(line.line)
    newDecorations.add(DeltaDecoration(
      `range`: newMonacoRange(line.line, startIndex, line.line, endIndex),
      options: js{
        isWholeLine: line.class.isNil or ui_imports.jslib.startsWith(line.class, "on") or line.class == "diff-added",
        className: line.class,
        inlineClassName: line.inlineClass}))

  self.decorations = self.decorations.filterIt(not it[1]).concat(newDecorations.mapIt((it, true)))

  editor.decorations = editor.deltaDecorations(
    editor.decorations,
    self.decorations.mapIt(it[0]))

  if not self.data.ui.welcomeScreen.isNil:
    self.data.ui.welcomeScreen.resetView()

proc lineActionClick(self: EditorViewComponent, tabInfo: TabInfo, line: js) =
  var element = line
  var dataset = element.dataset

  if dataset.line.isNil:
    element = element.parentNode
    dataset = element.dataset

  if not dataset.line.isNil:
    let lineNumber = cast[cstring](dataset.line).parseJSInt()
    self.data.services.debugger.toggleBreakpoint(tabInfo.name, lineNumber)
    self.refreshEditorLine(lineNumber)

proc lineActionContextMenu(self: EditorViewComponent, tabInfo: TabInfo, line: js) =
  var element = line
  let dataset = element.dataset

  if dataset.line.isNil:
    element = element.parentNode
  if not dataset.line.isNil:
    let lineNumber = cast[cstring](dataset.line).parseJSInt()
    let path = tabInfo.name
    if self.data.services.debugger.isEnabled(path, lineNumber):
      self.data.services.debugger.disable(path, lineNumber)
    else:
      self.data.services.debugger.enable(path, lineNumber)
    self.refreshEditorLine(lineNumber)

method clear*(self: EditorViewComponent) =
  self.flow.clear()

func has(tab: TabInfo, instruction: Instruction, i: int, offset: int): bool =
  if i + 1 < tab.instructions.instructions.len:
    var limit = tab.instructions.instructions[i + 1].offset

    result = offset >= instruction.offset and offset < limit
  else:
    result = offset >= instruction.offset

method position*(self: EditorViewComponent): int =
  if self.data.services.debugger.frameInfo.hasSelected and
    self.data.services.debugger.frameInfo.offset != NO_OFFSET:

    for i, instruction in self.tabInfo.instructions.instructions:
      if self.tabInfo.has(instruction, i, self.data.services.debugger.frameInfo.offset):
        return i + 1

  return NO_OFFSET

proc colorLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  var tabInfo = self.tabInfo

  case self.editorView:
  of ViewSource, ViewTargetSource:
    var debuggerLine = NO_LINE
    var debuggerPath = cstring""
    if self.editorView == ViewSource:
      debuggerLine = self.data.services.debugger.location.line
      debuggerPath = self.data.services.debugger.location.path
    else:
      debuggerLine = self.data.services.debugger.cLocation.line
      debuggerPath = self.data.services.debugger.cLocation.path

    if debuggerLine != NO_LINE and debuggerPath == tabInfo.name:
      let line = if not self.data.services.debugger.location.isExpanded:
        debuggerLine
      else:
        self.data.services.debugger.location.line - self.data.services.debugger.location.expansionFirstLine + 1 # e.g. 2 - 1 + 1 -> 2. 2 - 2 + 1 -> 1
      lines.add(MonacoLineStyle(line: line, class: cstring(fmt"on on-{line}")))

  of ViewInstructions:
    cdebug "editor: asmName " & self.data.services.debugger.location.asmName
    cdebug "editor: instructions name " & self.name
    if self.data.trace.lang in {LangC, LangCpp, LangRust, LangGo} and self.data.services.debugger.location.asmName == self.name or
       self.data.trace.lang == LangNim and self.data.services.debugger.cLocation.asmName == self.name:
      var position = self.position()
      if position != NO_POSITION:
        lines.add(MonacoLineStyle(line: position, class: cstring(fmt"on on-{position}")))

  of ViewCalltrace:
      let currentLocation = self.data.services.debugger.location
      let currentLocationName = currentLocation.path & cstring":" & currentLocation.functionName & cstring"-" & currentLocation.key
      if currentLocationName == self.name:
        if currentLocation.line != NO_LINE and currentLocation.line in currentLocation.functionFirst .. currentLocation.functionLast:
          lines.add(MonacoLineStyle(line: currentLocation.line - currentLocation.functionFirst + 1, class: cstring"on"))

  else:
    discard

  if tabInfo.highlightLine != NO_LINE:
    lines.add(MonacoLineStyle(line: tabInfo.highlightLine, class: cstring"highlight"))
    self.monacoEditor.revealLineInCenterIfOutsideViewport(tabInfo.highlightLine)

  lines

proc isLineStyleSet(conditionFlowLines: seq[MonacoLineStyle], position: int): bool =
  MonacoLineStyle(line: position, inlineClass: cstring"line-flow-hit") notin conditionFlowLines

proc flowStyleLines(self: EditorViewComponent, conditionFlowLines: seq[MonacoLineStyle]): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  var flow = self.flow

  if not flow.isNil and not flow.flow.isNil and not self.flowUpdate.isNil:
    let finished = self.flowUpdate.finished
    for position in flow.flow.location.functionFirst + 1 .. flow.flow.location.functionLast:
      if not flow.flow.branchesTaken[0][0].table.hasKey(position):
        let lineFlowKind = toLineFlowKind(flow.flow, position, finished)
        if isLineStyleSet(conditionFlowLines, position) and position notin flow.flow.commentLines:
          case lineFlowKind:
          of LineFlowHit:
              lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-hit"))

          of LineFlowSkip:
            lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-skip"))

          of LineFlowUnknown:
            lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-unknown"))

  lines

proc conditionToLine(self: EditorViewComponent, loopId: int, loopIteration: int): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  var flow = self.flow

  for position, typ in flow.flow.branchesTaken[loopId][loopIteration].table:
    if (position >= flow.flow.location.functionFirst and position <= flow.flow.location.functionLast) or
      (flow.flow.location.functionFirst == -1 and flow.flow.location.functionLast == -1):
      case typ:
      of Taken:
        lines.add(MonacoLineStyle(line: position, class: cstring"flow-taken"))
        if position in flow.flow.relevantStepCount:
          lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-hit"))
        else:
          lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-skip"))

      of NotTaken:
        lines.add(MonacoLineStyle(line: position, class: cstring"flow-not-taken"))
        if position notin flow.flow.relevantStepCount:
          lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-skip"))
        else:
          lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-hit"))

      of Unknown:
        lines.add(MonacoLineStyle(line: position, class: cstring"flow-not-taken"))
        lines.add(MonacoLineStyle(line: position, inlineClass: cstring"line-flow-skip"))

  lines

proc conditionStyleLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  let currentPosition = self.data.services.debugger.location.highLevelLine
  let currentRRTicks = self.data.services.debugger.location.rrTicks
  let flow = self.flow
  var lines: seq[MonacoLineStyle] = @[]

  if not flow.isNil and not flow.flow.isNil and not flow.flow.branchesTaken[0][0].table.isNil:
    # conditions outside of loops:
    lines.add(self.conditionToLine(0, 0))
    var currentStepCount = self.flow.getCurrentStepCount(currentPosition)

    # conditions inside of loops:
    if currentStepCount != NO_STEP_COUNT:
      for flowLoop in flow.flowLoops:
        var currentLoopStep = flowLoop.loopStep
        var loop = flow.flow.loops[currentLoopStep.loop]
        var closestStep = self.flow.getClosestIterationStepCount(loop, currentLoopStep.stepCount)
        var step = flow.flow.steps[closestStep]

        lines.add(self.conditionToLine(step.loop, step.iteration))

  lines

proc diffStyleLines(self: EditorViewComponent): seq[MonacoLineStyle] =
  var lines: seq[MonacoLineStyle] = @[]
  for file in self.data.startOptions.diff.files:
    if file.currentPath == self.path:
      for chunk in file.chunks:
        for diffLine in chunk.lines:
          case diffLine.kind:
          of DiffLineKind.NonChanged:
            discard
          of DiffLineKind.Deleted:
            discard
          of DiffLineKind.Added:
            lines.add(MonacoLineStyle(line: diffLine.currentLineNumber, class: cstring"diff-added"))

  lines

proc applyEventualStylesLines(self: EditorViewComponent) =
  var colorLineList = self.colorLines()
  var conditionFlowLines = self.conditionStyleLines()
  # var diffLineList = self.diffStyleLines()
  var flowLineList = self.flowStyleLines(conditionFlowLines)
  let lines = concat(colorLineList, concat(flowLineList, conditionFlowLines))

  self.styleLines(self.monacoEditor, lines)

proc statusWidgetDom(self: FlowComponent, line: int): Node =
  var dom = cast[Node](document.createElement(cstring"div"))
  var target = cast[Node](document.createElement(cstring"div"))
  dom.appendChild(target)
  let id = cstring(&"flow-status-widget-{line}")
  target.id = id
  cast[Element](target).classList.add(cstring"flow-status-widget")
  self.statusDom = dom
  return dom

proc ensureStatusWidget(self: FlowComponent, line: int) =
  var add = false

  if self.statusWidget.isNil:
    add = true
  elif cast[int](self.statusWidget.getPosition().position.lineNumber) != line:
    self.editorUI.monacoEditor.removeContentWidget(self.statusWidget)
    self.statusWidget = nil
    add = true
  else:
    add = false

  if add:
    let dom = self.statusWidgetDom(line)
    self.statusWidget = self.addContentWidget(dom, line, self.maxFlowLineWidth, &"flow-status-widget-{line}", isStatusWidget = true)

const flowStatusTexts: array[FlowUpdateStateKind, string] = [
  "not loading",
  "waiting for start ..",
  "loading ...",
  "finished"
];

func flowStatusText(status: FlowUpdateState): string =
  result = flowStatusTexts[status.kind]
  if status.kind == FlowLoading:
    result = result & " " & $status.steps

proc redrawFlowInfo(self: FlowComponent, centerLine: int, loadingLine: int) =
  let line = if self.status.kind == FlowWaitingForStart: centerLine else: loadingLine
  self.ensureStatusWidget(line)

  let text = flowStatusText(self.status)
  self.statusWidget.domNode.childNodes[0].innerText = cstring(text)

proc redrawFlow(self: EditorViewComponent) =
  var tabInfo = self.tabInfo

  if self.flow.tab.isNil:
    self.flow.tab = tabInfo
    if self.flow.tab.isNil:
      cerror fmt"flow: tab in service is still nil {self.path}"
      return

  try:
    if self.flow.maxFlowLineWidth == 0:
      let minimapLeft = self.flow.editorUI.monacoEditor
        .getOption(LAYOUT_INFO).minimap.minimapLeft
      let editorContentLeft = self.flow.editorUI.monacoEditor
        .getOption(LAYOUT_INFO).contentLeft

      self.flow.maxFlowLineWidth = self.flow.calculateMaxFlowLineWidth()
      self.flow.flowViewWidth = minimapLeft - self.flow.maxFlowLineWidth
  except:
    cerror "flow: max flow line width " & getCurrentExceptionMsg()

  if self.flow.flow.isNil:
    return

method register*(self: EditorViewComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtUpdatedFlow, proc(kind: CtEventKind, response: FlowUpdate, sub: Subscriber) =
    discard self.onUpdatedFlow(response)
  )

proc registerEditorViewComponent*(component: EditorViewComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

proc sourceLineJump(self: EditorViewComponent, path: cstring, line: int, behaviour: JumpBehaviour) =
  self.api.emit(
    CtSourceLineJump,
    SourceLineJumpTarget(
      path: path,
      line: line,
      behaviour: behaviour,
    )
  )
  self.api.emit(
    InternalNewOperation,
    NewOperation(
      name: fmt"Source line jump - {line}",
      stableBusy: true,
    )
  )

proc sourceCallJump(self: EditorViewComponent, path: cstring, line: int, targetToken: cstring, behaviour: JumpBehaviour) =
  self.api.emit(
    CtSourceCallJump,
    SourceCallJumpTarget(
      path: path,
      line: line,
      token: targetToken,
      behaviour: behaviour,
    )
  )
  self.api.emit(
    InternalNewOperation,
    NewOperation(
      name: fmt"Source call jump - {targetToken}",
      stableBusy: true,
    )
  )

proc editorLineJump(self: EditorViewComponent, line: int, behaviour: JumpBehaviour) =
  if self.tabInfo.lang != LangAsm:
    self.sourceLineJump(self.name, line, behaviour)
  elif 0 <= line - 1 and line - 1 <= self.tabInfo.instructions.instructions.len():
    self.sourceLineJump(self.name, self.tabInfo.instructions.instructions[line-1].highLevelLine, behaviour)

type
  AmbiguousFunctionCallException = object of ValueError

proc getTokenFromPosition(self: EditorViewComponent, position: js): cstring =
  try:
    let model = self.monacoEditor.toJs.getModel()
    let currentWord = model.getWordAtPosition(position)

    if currentWord.isNil:
      return cstring""

    result = if not currentWord.word.isNil: cast[cstring](currentWord.word) else: cstring""

    let lang = fromPath(self.data.services.debugger.location.path)

    if lang == LangRust:
      let xidRegex = newRegExp(r"^\w$")
      let lineNumber = cast[int](position.lineNumber)
      let lineContent = $cast[cstring](model.getLineContent(lineNumber))
      var startColumn = cast[int](currentWord.startColumn) - 1
      var endColumn = cast[int](currentWord.endColumn) - 2

      while startColumn > 0 and (lineContent[startColumn - 1] == ':' or xidRegex.test($lineContent[startColumn - 1])):
        startColumn -= 1

      while endColumn < lineContent.len - 1 and (lineContent[endColumn + 1] == ':' or xidRegex.test($lineContent[endColumn + 1])):
        endColumn += 1

      result = lineContent[startColumn..endColumn]
      if lineContent.count($result) != 1:
        raise newException(AmbiguousFunctionCallException, &"Multiple calls of '{result}' on line {lineNumber}.")
  except AmbiguousFunctionCallException:
    raise
  except:
    cerror getCurrentExceptionMsg()
    result = ""


proc runTest(self: EditorViewComponent, testName: cstring, path: cstring, line: int, column: int) =
  let options = RunTestOptions(
    testName: testName,
    path: path,
    line: line,
    column: column,
    newWindow: false,
  )
  self.data.runTests(options)

# Fill contextMenu with ContextMenuItem variables and return it to be used in the context menu
proc createContextMenuItems(self: EditorViewComponent, ev: js): seq[ContextMenuItem] =
  # Editor context menu items
  var callLine:                   ContextMenuItem
  var callLineForward:            ContextMenuItem
  var callLineBackward:           ContextMenuItem
  var toggleBreakpoint:           ContextMenuItem
  var toggleBreakpointState:      ContextMenuItem
  var deleteBreakpoints:          ContextMenuItem
  var deleteAllBreakpoints:       ContextMenuItem
  var toggleBreakpoints:          ContextMenuItem
  var addDeleteTracepoint:        ContextMenuItem
  var toggleTracepoint:           ContextMenuItem
  var targetToken:                cstring
  var listLine:                   seq[int]
  var contextMenu:                seq[ContextMenuItem]

  # Trace context menu items
  var addToScratchpad:     ContextMenuItem
  var expandTraceValue:    ContextMenuItem

  var tabInfo = self.tabInfo

  if ev.isNil or ev.target.isNil or ev.target.position.isNil:
    return contextMenu

  var line = cast[int](ev.target.position.lineNumber)
  let path = tabInfo.name

  if ev.target.detail.isNil or ev.target.detail.afterLineNumber.isNil:
    # Source Line Jump Menu Item
    let sourceLine = ContextMenuItem(
      name: "Jump to line",
      hint: "&lt;Middle click on line&gt;, CTRL+&lt;click on line&gt;",
      handler: proc(e: Event) =
        self.editorLineJump(line, SmartJump)
    )
    let sourceLineForward = ContextMenuItem(
      name: "Jump forward to line",
      hint: "",
      handler: proc(e: Event) =
        self.editorLineJump(line, ForwardJump)
    )
    let sourceLineBackward = ContextMenuItem(
      name: "Jump backward to line",
      hint: "",
      handler: proc(e: Event) =
        self.editorLineJump(line, BackwardJump)
    )
    contextMenu &= sourceLine
    contextMenu &= sourceLineForward
    contextMenu &= sourceLineBackward

    try:
      targetToken = self.getTokenFromPosition(ev.target.position)
      # copied/adapted from getTokenFromPosition
      let model = self.monacoEditor.toJs.getModel()
      let lineContent = $cast[cstring](model.getLineContent(line))
      if lineContent.strip == "#[test]":
        # for now trying to guess where the function name for rust is
        # e.g.
        # ```
        # #[test]
        # fn test_1() {
        # ..
        # }
        let column = 1
        let path = self.name
        let testName = self.getLineFunctionName(line + 1)
        clog cstring"test name: " & testName
        let runTest = ContextMenuItem(
          name: "Re-record and replay this test",
          hint: "try to rebuild/re-record and replay this test",
          handler: proc(e: Event) =
            self.runTest(testName, path, line, column)
        )
        contextMenu &= runTest
      # Call Line Jump Menu Item
      if targetToken != "":
        callLine = ContextMenuItem(
          name: "Jump to call",
          hint: "CTRL+ALT+&lt;click function name&gt;",
          handler: proc(e: Event) =
            self.sourceCallJump(self.name, line, targetToken, SmartJump)
        )
        callLineForward = ContextMenuItem(
          name: "Jump forward to call",
          hint: "",
          handler: proc(e: Event) =
            self.sourceCallJump(self.name, line, targetToken, ForwardJump)
        )
        callLineBackward = ContextMenuItem(
          name: "Jump backward to call",
          hint: "",
          handler: proc(e: Event) =
            self.sourceCallJump(self.name, line, targetToken, BackwardJump)
        )
      else:
        let handler = proc(e: Event) = self.api.errorMessage("No word selected.")

        callLine = ContextMenuItem(
          name: "Jump to call",
          hint: "CTRL+ALT+&lt;click function name&gt;",
          handler: handler
        )
        callLineForward = ContextMenuItem(
          name: "Jump forward to call",
          hint: "", handler: handler)
        callLineBackward = ContextMenuItem(
          name: "Jump backward to call",
          hint: "",
          handler: handler
        )
    except AmbiguousFunctionCallException:
      let msg = getCurrentExceptionMsg()
      let handler = proc(e: Event) = self.api.errorMessage msg

      callLine = ContextMenuItem(
        name: "Jump to call",
        hint: "CTRL+ALT+&lt;click function name&gt;",
        handler: handler
      )
      callLineForward = ContextMenuItem(
        name: "Jump forward to call",
        hint: "",
        handler: handler
      )
      callLineBackward = ContextMenuItem(
        name: "Jump backward to call",
        hint: "",
        handler: handler
      )

    contextMenu &= callLine
    contextMenu &= callLineForward
    contextMenu &= callLineBackward

    # Delete/Add Breakpoint Menu Item
    if data.services.debugger.hasBreakpoint(path, line):
      toggleBreakpoint = ContextMenuItem(
        name: "Delete breakpoint",
        hint: "&lt;click on the red dot&gt;",
        handler: proc(e: Event) =
          self.data.services.debugger.deleteBreakpoint(path, line)
          self.refreshEditorLine(line)
      )
      # Enable/Disable Breakpoint
      if data.services.debugger.isEnabled(path, line):
        toggleBreakpointState = ContextMenuItem(
          name: "Disable breakpoint",
          hint: "",
          handler: proc(e: Event) =
            data.services.debugger.disable(path, line)
            self.refreshEditorLine(line)
        )
      else:
        toggleBreakpointState = ContextMenuItem(
          name: "Enable breakpoint",
          hint: "",
          handler: proc(e: Event) =
            data.services.debugger.enable(path, line)
            self.refreshEditorLine(line)
        )

      contextMenu &= toggleBreakpointState

    # Add/Delete Breakpoint Menu Item
    else:
      toggleBreakpoint = ContextMenuItem(
        name: "Add breakpoint",
        hint: "&lt;click line number gutter&gt;",
        handler: proc(e: Event) =
          data.services.debugger.addBreakpoint(path, line)
          self.refreshEditorLine(line)
      )

    contextMenu &= toggleBreakpoint

    # Delete Breakpoints in file
    if data.pointList.breakpoints.len > 0:
      deleteBreakpoints = ContextMenuItem(
        name: "Delete breakpoints in file",
        hint: "",
        handler: proc(e: Event) =
          let breakpointsCopy = data.pointList.breakpoints
          for i, b in breakpointsCopy:
            data.services.debugger.deleteBreakpoint(path, b.line)
            self.refreshEditorLine(b.line)
            data.pointList.breakpoints.delete(i, i)
      )

      contextMenu &= deleteBreakpoints

    # Delete ALL Breakpoints in project
    if data.pointList.breakpoints.len > 0:
      deleteAllBreakpoints = ContextMenuItem(
        name: "Delete ALL breakpoints",
        hint: "",
        handler: proc(e: Event) =
          data.services.debugger.deleteAllBreakpoints(self)
          data.pointList.breakpoints = @[]
      )

      contextMenu &= deleteAllBreakpoints

    # Delete/Add tracepoint field
    if not self.traces[line].isNil:
      addDeleteTracepoint = ContextMenuItem(
        name: "Delete tracepoint",
        hint: "",
        handler: proc (e: Event) =
          self.traces[line].closeTrace()
      )

      # Enable/Disable tracepoint
      if self.traces[line].isDisabled:
        toggleTracepoint = ContextMenuItem(
          name: "Enable tracepoint",
          hint: "",
          handler: proc(e: Event) =
            self.toggleTrace(path, line)
            self.traces[line].toggleTraceState()
        )
      else:
        toggleTracepoint = ContextMenuItem(
          name: "Disable tracepoint",
          hint: "",
          handler: proc(e: Event) =
            self.traces[line].toggleTraceState()
            self.toggleTrace(path, line)
        )

      contextMenu &= toggleTracepoint

    # Add/Delete tracepoint field
    else:
      addDeleteTracepoint = ContextMenuItem(
        name: "Add tracepoint",
        hint: "Enter&lt;on line&gt;",
        handler: proc(e: Event) =
          self.toggleTrace(self.name, line)
      )

    contextMenu &= addDeleteTracepoint

    # Add expression to Scratchpad
    let key = &"{self.path}:{self.lastMouseMoveLine}"

    if not data.services.debugger.expressionMap.isNil and data.services.debugger.expressionMap.hasKey(key):
      for item in data.services.debugger.expressionMap[key]:
        let startCol = cast[int](item.startCol)
        var endCol = cast[int](item.endCol)
        var expression: cstring
        case item.kind:
        of TkField:
          expression = item.base

        of TkIndex:
          expression = item.collection
          endCol -= 2

        else:
          expression = item.expression

        if startCol <= self.lastMouseClickCol and self.lastMouseClickCol <= endCol:
          for local in data.services.debugger.locals:
            if local.expression == expression:
              let baseValue = local.value
              addToScratchpad = ContextMenuItem(name: "Add value to scratchpad", hint: "", handler: proc(e: Event) =
                self.api.openValueInScratchpad(ValueWithExpression(expression: expression, value: baseValue))
                self.data.redraw())
              contextMenu &= addToScratchpad
          break
  else:
    let className = cast[cstring](ev.target.element.className)
    if not ($className).startsWith("flow"):
      var datatable: js

      try:
        datatable = self.traces[line].dataTable.context
      except:
        line -= 1
        datatable = self.traces[line].dataTable.context

      # Check how many values the trace datatable has
      # and generate the context menu based on that information
      try:
        let target = ev.target.element.findTRNode()
        let dataTableRow = datatable.row(target)
        let traceValue = cast[Stop](datatableRow.data())
        if traceValue.locals.len > 1:
          for localValue in traceValue.locals:
            # Add values to scratchpad
            let tempValue = localValue
            capture tempValue:
              addToScratchpad = ContextMenuItem(
                name: &"Add {tempValue[0]} to scratchpad",
                hint: "",
                handler: proc(e: Event) =
                  self.api.openValueInScratchpad(
                    ValueWithExpression(
                      expression: tempValue[0],
                      value: tempValue[1]))
                  self.data.redraw()
              )

              contextMenu &= addToScratchpad

              # Expand values
              expandTraceValue = ContextMenuItem(
                name: &"Expand {tempValue[0]} value",
                hint: "",
                handler: proc(e: Event) =
                  self.traces[line].showExpandValue(tempValue, line)
                  self.data.redraw()
              )

              contextMenu &= expandTraceValue

          # Add all values to scratchpad
          contextMenu &= ContextMenuItem(
            name: "Add all values to scratchpad",
            hint: "",
            handler: proc(e: Event) =
              for localValue in traceValue.locals:
                self.api.openValueInScratchpad(
                  ValueWithExpression(
                    expression: localValue[0],
                    value: localValue[1]))
                self.data.redraw()
          )

        else:
          # Add value to scratchpad
          addToScratchpad = ContextMenuItem(
            name: "Add value to scratchpad",
            hint: "CTRL+&lt;click on value&gt;",
            handler: proc(e: Event) =
              self.api.openValueInScratchpad(
                ValueWithExpression(
                  expression: traceValue.locals[0][0],
                  value: traceValue.locals[0][1]))
              self.data.redraw()
          )

          contextMenu &= addToScratchpad

          # Expand value
          expandTraceValue = ContextMenuItem(
            name: "Expand value",
            hint: "",
            handler: proc(e: Event) =
              self.traces[line].showExpandValue(traceValue.locals[0], line)
              self.data.redraw()
          )

          contextMenu &= expandTraceValue

      except:
        discard

  return contextMenu

proc getSourceLineDomIndex(self:EditorViewComponent, position: int): int =
  var result: int
  let editorId = self.id
  let overlayNodes = jq(&"#editorComponent-{editorId} .monaco-editor .view-overlays").children
  let marginOverlayNodes = jq(&"#editorComponent-{editorId} .monaco-editor .margin-view-overlays").children

  for index, overlayNode in marginOverlayNodes:
    let gutter = findNodeInElement(cast[Node](overlayNode),".gutter")
    let dataLine = cast[cstring](gutter.getAttribute("data-line"))

    if cast[int](dataLine) == position:
      result = index
      break

  return result

proc addViewZone(self: EditorViewComponent, vNode: VNode, line: int) =
  vNode.style = style(StyleAttr.left, &"{self.currentTooltip[0] * 9}px")

  let viewZone = js{
    afterLineNumber: line,
    heightInPx: 0,
    domNode: vnodeToDom(vNode, KaraxInstance())
  }

  self.monacoEditor.changeViewZones do (view: js):
    var zoneId = cast[int](view.addZone(viewZone))
    self.viewZones[line] = zoneId

proc renderValueView(self: EditorViewComponent, value: ValueComponent, line: int) =
  var vNode = value.render()
  self.addViewZone(vNode, line)

proc customRedraw(self: ValueComponent) =
  let editor = data.ui.editors[data.services.debugger.location.path]
  var line = editor.lastMouseClickLine
  var vNode = self.render()

  editor.clearViewZones()
  editor.addViewZone(vNode, line)

proc renderValueTooltip(self: EditorViewComponent) {.async.} =
  let key = &"{self.path}:{self.lastMouseClickLine}"

  self.currentTooltip = (0, 0, 0)

  if not data.services.debugger.expressionMap.isNil and data.services.debugger.expressionMap.hasKey(key):
    self.clearViewZones()
    if self.data.services.debugger.showInlineValues:
      for item in data.services.debugger.expressionMap[key]:
        let startCol = cast[int](item.startCol)
        var endCol = cast[int](item.endCol)
        var expression: cstring
        case item.kind:
        of TkField:
          expression = item.expression

        of TkIndex:
          expression = item.collection
          endCol -= 2

        else:
          expression = item.expression

        if startCol <= self.lastMouseClickCol and self.lastMouseClickCol <= endCol:
          var baseValue: Value

          for local in self.data.services.debugger.locals:
            if local.expression == expression:
              baseValue = local.value
              break

          if baseValue.isNil:
            baseValue = await self.data.services.debugger.evaluateExpression(self.data.services.debugger.location.rrTicks, item.expression)

          if not baseValue.isNil:
            let value = ValueComponent(
              expanded: JsAssoc[cstring, bool]{expression: false},
              charts: JsAssoc[cstring, ChartComponent]{},
              showInLine: JsAssoc[cstring, bool]{},
              baseExpression: expression,
              baseValue: baseValue,
              stateID: -1,
              nameWidth: VALUE_COMPONENT_NAME_WIDTH,
              valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
              data: data,
              customRedraw: customRedraw
            )
            self.currentTooltip = (startCol, endCol, self.lastMouseClickLine)
            if not self.viewZones.isNil:
              self.clearViewZones()
            self.renderValueView(value, self.lastMouseClickLine)
            break

  elif not self.monacoEditor.isNil:
    self.clearViewZones()

const DELAY: int64 = 400 # milliseconds

proc sourceOrCallJump(self: EditorViewComponent, position: js) =
  let currentTime: int64 = now()

  if currentTime - self.lastScrollFireTime <= DELAY:
    let targetToken = self.getTokenFromPosition(position)

    if targetToken != "":
      self.sourceCallJump(
        self.name,
        self.lastMouseMoveLine,
        targetToken,
        SmartJump
      )
    else:
      self.editorLineJump(self.lastMouseMoveLine, SmartJump)

  else:
    self.editorLineJump(self.lastMouseClickLine, SmartJump)

  self.lastScrollFireTime = currentTime

proc loadFlow*(self: EditorViewComponent, flowMode: FlowMode, location: types.Location) =
  # # possible to test/debug diff flow TEMP HACK:
  # if flowMode != FlowMode.Diff:
  #  return

  self.flow = FlowComponent(
    api: self.api,
    id: self.id,
    flow: nil,
    tab: self.tabInfo,
    location: location,
    multilineZones: JsAssoc[int, MultilineZone]{},
    flowDom: JsAssoc[int, Node]{},
    shouldRecalcFlow: false,
    flowLoops: JsAssoc[int, FlowLoop]{},
    flowLines: JsAssoc[int, FlowLine]{},
    activeStep: FlowStep(rrTicks: -1),
    selectedLine: -1,
    selectedLineInGroup: -1,
    selectedStepCount: -1,
    multilineFlowLines: multilineFlowLines(),
    multilineValuesDoms: JsAssoc[int, JsAssoc[cstring, Node]]{},
    loopLineSteps: JsAssoc[int, int]{},
    inlineDecorations: JsAssoc[int, InlineDecorations]{},
    editorUI: self,
    scratchpadUI: if self.data.ui.componentMapping[Content.Scratchpad].len > 0: self.data.scratchpadComponent(0) else: nil,
    editor: self.service,
    service: self.data.services.flow,
    data: self.data,
    lineGroups: JsAssoc[int, Group]{},
    status: FlowUpdateState(kind: FlowWaitingForStart),
    statusWidget: nil,
    sliderWidgets: JsAssoc[int, js]{},
    lineWidgets: JsAssoc[int, js]{},
    multilineWidgets: JsAssoc[int, JsAssoc[cstring, js]]{},
    stepNodes: JsAssoc[int, kdom.Node]{},
    loopStates: JsAssoc[int, LoopState]{},
    viewZones: JsAssoc[int, int]{},
    loopViewZones: JsAssoc[int, int]{},
    loopColumnMinWidth: 15,
    shrinkedLoopColumnMinWidth: 8,
    pixelsPerSymbol: 8,
    distanceBetweenValues: 10,
    distanceToSource: 50,
    inlineValueWidth: 80,
    bufferMaxOffsetInPx: 300,
    maxWidth: 0,
    modalValueComponent: JsAssoc[cstring, ValueComponent]{}
  )
  self.flow.valueMode = BeforeValueMode

  let taskId = genTaskId(LoadFlow)
  self.api.emit(CtLoadFlow, CtLoadFlowArguments(flowMode: flowMode, location: self.location))
  cdebug "start load-flow", taskId

proc createMonacoEditor*(selector: cstring, options: MonacoEditorOptions): MonacoEditor =
  result = monaco.editor.create(jq(selector), options)

proc drawDiffViewZones(self: EditorViewComponent, source: cstring, id: int, lineNumber: int): Node =
  var zoneDom = document.createElement("div")
  zoneDom.id = fmt"diff-view-zone-{self.id}-{id}"
  zoneDom.class = "diff-view-zone"
  zoneDom.style.display = "flex"
  zoneDom.style.fontSize = cstring($self.data.ui.fontSize) & cstring"px"

  var editorDom = document.createElement("div")
  var selector = fmt"diffEditorComponent-{self.id}-{id}"
  editorDom.id = selector

  let editorContentLeft = self.monacoEditor
    .getOption(LAYOUT_INFO).contentLeft + EDITOR_GUTTER_PADDING
  zoneDom.style.left = fmt"-{editorContentLeft}px"
  editorDom.style.height = "100%"

  zoneDom.appendChild(editorDom)

  var lang = fromPath(self.data.services.debugger.location.path)
  let theme = if self.data.config.theme == cstring"default_white": cstring"codetracerWhite" else: cstring"codetracerDark"
  if not self.diffEditors.hasKey(lineNumber):
    discard setTimeout(proc () =
      self.diffEditors[lineNumber] = createMonacoEditor(
        "#" & editorDom.id.cstring,
        MonacoEditorOptions(
          value: source,
          language: lang.toCLang(),
          readOnly: true,
          theme: theme,
          automaticLayout: true,
          folding: true,
          fontSize: self.data.ui.fontSize,
          minimap: js{ enabled: false },
          find: js{ addExtraSpaceOnTop: false },
          renderLineHighlight: if self.editorView == ViewLowLevelCode: "none".cstring else: "".cstring,
          lineNumbers: proc(line: int): cstring = self.editorLineNumber(self.path, line, true, lineNumber),
          lineDecorationsWidth: 20,
          contextmenu: false,
          mouseWheelScrollSensitivity: 0,
          fastScrollSensitivity: 0,
          scrollBeyondLastLine: false,
          smoothScrolling: false,
          scrollbar: js{
            "vertical": "hidden",
            "horizontal": "hidden",
            "useShadows": false
          }
        )
      ),
      0
    )

  return zoneDom

proc clearDiffViewZones(self: EditorViewComponent) =
 for line, zone in self.diffViewZones:
    self.monacoEditor.changeViewZones do (view: js):
      view.removeZone(self.diffViewZones[line].zoneId)

proc addDiffView(self: EditorViewComponent, source: cstring, removedLinesNumber: int, startLineNumber: int, firstDeletedLineNumber: int) =
  var offset = 1 # Offset for proper line placement and number
  var newZoneDom = self.drawDiffViewZones(source, startLineNumber, firstDeletedLineNumber)
  let viewZone = js{
    afterLineNumber: if startLineNumber == 1: 0 else: startLineNumber,
    heightInLines: removedLinesNumber + offset,
    domNode: newZoneDom
  }
  self.monacoEditor.changeViewZones do (view: js):
    var zoneId = cast[int](view.addZone(viewZone))
    self.diffViewZones[startLineNumber] =
      MultilineZone(
        dom: newZoneDom,
        zoneId: zoneId,
        variables: JsAssoc[cstring, bool]{}
      )

proc removeLastChar(cs: cstring): cstring =
  var str = $cs
  if str.len > 0:
    str.setLen(str.len - 1)
  result = str.cstring

proc makeDiffViewZones(self: EditorViewComponent) =
  for file in self.data.startOptions.diff.files:
    if file.currentPath == self.path:
      for chunk in file.chunks:
        var isInDeleteChunk = false
        var removedLinesNumber = NO_LINE # Number for lines to be included
        var firstDeletedLineNumber = NO_LINE
        var startLineNumber = chunk.currentFrom # initial start line for the viewZones
        var source = "".cstring # Source code
        for diffLine in chunk.lines:
          case diffLine.kind:
          of DiffLineKind.Deleted:
            removedLinesNumber.inc()
            source = source & diffLine.text.toCString() & "\n".cstring
            if firstDeletedLineNumber == NO_LINE:
              firstDeletedLineNumber = diffLine.previousLineNumber
            isInDeleteChunk = true
          else:
            if diffLine.kind == DiffLineKind.Added and diffLine.currentLineNumber notin self.diffAddedLines:
              self.diffAddedLines.add(diffLine.currentLineNumber)
            if removedLinesNumber != NO_LINE:
              self.addDiffView(source.removeLastChar(), removedLinesNumber, startLineNumber, firstDeletedLineNumber)
              source = ""
              removedLinesNumber = NO_LINE
              firstDeletedLineNumber = NO_LINE
            else:
              startLineNumber = diffLine.currentLineNumber
            isInDeleteChunk = false
        if isInDeleteChunk:
          self.addDiffView(source, removedLinesNumber, startLineNumber, firstDeletedLineNumber)

proc addContentWidget*(
  self: EditorViewComponent,
  dom: Node,
  line: int,
  column: int,
  id: cstring,
  isStatusWidget: bool = false,
  isSliderWidget: bool = false
): JsObject =
  dom.class = "flow-content-widget"
  var editor = self.monacoEditor

  let widget = js{
    domNode: cast[Node](nil),
    getId: proc: cstring = id,
    getDomNode: (proc: Node =
      if cast[Node](jsthis.domNode).isNil:
        jsthis.domNode = dom
      cast[Node](jsthis.domNode)),
    getPosition: (proc: js =
      js{position: js{lineNumber: parseJSInt(line), column: column}, preference: cast[seq[MonacoContent]](@[EXACT])})
  }

  self.testLines[line].contentWidget = cast[Node](widget)

  editor.addContentWidget(widget)

  return widget

proc makeTestContainer(self: EditorViewComponent, line: int): Node =
  let textModel = self.monacoEditor.getModel()
  let lineContent = textModel.getLineContent(line)
  let editorConfiguration = self.monacoEditor.config
  let lineHeight = editorConfiguration.lineHeight

  var style = style(
    (StyleAttr.left, cstring(fmt"calc({lineContent.len()}ch + 2ch)")),
    (StyleAttr.fontSize, cstring($(data.ui.fontSize - 2) & "px")),
    (StyleAttr.lineHeight, cstring($(lineHeight - 2) & "px")),
    (StyleAttr.height, cstring($(lineHeight - 2) & "px")),
    (StyleAttr.backgroundSize, cstring($(data.ui.fontSize) & "px"))
  )
  let vNode = buildHtml(
    tdiv(
      id = &"editor-test-container-{self.id}-{line}",
      class = "flow-loop-step-container",
      style = style
    )
  )

  return vnodeToDom(vNode, KaraxInstance())

proc makeTestLineContainer(self: EditorViewComponent, line: int) =
  var dom = cast[Node](document.createElement(cstring"div"))
  let id = cstring(&"ct-test-{self.id}-{line}")

  self.testDom[line] = dom

  discard self.addContentWidget(dom, line, 0, id)

proc ensureTestLineContainer(self: EditorViewComponent, line: int) =
  if not self.testDom.hasKey(line) and self.testLines[line].contentWidget.isNil:
    self.makeTestLineContainer(line)

proc getLineFunctionName(self: EditorViewComponent, line: int): cstring =
  let model = self.monacoEditor.getModel()
  let lineContent = $cast[cstring](model.getLineContent(line))

  let tokens = lineContent.split("fn ")
  var name = "".cstring
  if tokens.len() > 1:
    name = tokens[^1].split("(")[0]

  return name

proc getPythonTestFunctionName(self: EditorViewComponent, line: int): cstring =
  ## Extract Python test function name from a line containing def test_* or async def test_*
  let model = self.monacoEditor.getModel()
  let lineContent = $cast[cstring](model.getLineContent(line))
  let stripped = lineContent.strip()

  # Handle both "def test_*" and "async def test_*"
  var funcPart = ""
  if stripped.startsWith("def test_"):
    funcPart = stripped[4..^1]  # Skip "def "
  elif stripped.startsWith("async def test_"):
    funcPart = stripped[10..^1]  # Skip "async def "
  else:
    return "".cstring

  # Extract function name up to the opening paren
  let parenIdx = funcPart.find('(')
  if parenIdx > 0:
    return funcPart[0..<parenIdx].cstring
  return "".cstring

proc isPythonTestLine(lineContent: string): bool =
  ## Check if a line starts a Python test function (def test_* or async def test_*)
  let stripped = lineContent.strip()
  return stripped.startsWith("def test_") or stripped.startsWith("async def test_")

proc loadAnimation(self: EditorViewComponent, el: Element, i: var int) =
  let frames = ["Running.  ", "Running.. ", "Running..."]

  el.innerHTML = frames[i]
  i = (i + 1) mod frames.len
  discard setTimeout(proc() = loadAnimation(self, el, i), 300)

proc redrawActiveTestButton(self: EditorViewComponent) =
  let el = cast[Element](jq("#" & self.activeTestId))
  var i = 0

  el.classList.add("active-test-button")

  discard setTimeout(proc() = loadAnimation(self, el, i), 0)

proc testVNode(self: EditorViewComponent, line: int, isPythonTest: bool = false): VNode =
  # For Python tests, the function name is on the same line (line)
  # For Rust tests, the function is on the next line (line + 1, after #[test])
  let testName = if isPythonTest:
    self.getPythonTestFunctionName(line)
  else:
    self.getLineFunctionName(line + 1)
  let testId = &"ct-test-action-{self.id}-{line}"
  if self.activeTestId == testId:
    discard setTimeout(proc() = redrawActiveTestButton(self), 0)

  buildHtml(
    tdiv(
      id = testId,
      class = "flow-parallel flow-parallel-value-single editor-test-action",
      onclick = proc() =
        if testName.len() > 0:
          capture testId:
            self.activeTestId = testId
            self.redrawActiveTestButton()
          self.runTest(testName, self.name, line, 1)
          self.api.infoMessage(&"\"{testName}\" started")
        else:
          self.api.errorMessage("Coudln't extract test name.")
    )
  ):
    text "Run test"

proc makeFlowLine(self: EditorViewComponent, position: int): FlowLine =
  cdebug fmt"makeFlowLine position {position}"
  FlowLine(
    startBuffer: FlowBuffer(
      kind: FlowLineBuffer,
      position: position,
      loopIds: @[]
    ),
    number: position,
    variablesPositions: JsAssoc[cstring, int]{},
    sortedVariables: JsAssoc[cstring, Value]{},
    decorationsIds: @[],
    decorationsDoms: JsAssoc[cstring, Node]{},
    stepLoopCells: JsAssoc[int, JsAssoc[int, Node]]{},
    loopContainers: JsAssoc[int, Node]{},
    iterationContainers: JsAssoc[int, Node]{},
    loopIds: @[],
    sliderPositions: @[],
    activeLoopIteration: (-1,-1),
    loopStepCounts: JsAssoc[int, seq[int]]{}
  )

proc addTestActions(self: EditorViewComponent) =
  # Determine if this is a Python file
  let lang = fromPath(self.name)
  let isPythonFile = lang == LangPythonDb

  for i, line in self.tabInfo.sourceLines:
    let rLine = i + 1
    let lineStr = $line

    # Check for Rust tests (#[test] attribute)
    let isRustTest = lineStr.strip() == "#[test]" and not isPythonFile
    # Check for Python tests (def test_* or async def test_*)
    let isPythonTest = isPythonFile and isPythonTestLine(lineStr)

    if (isRustTest or isPythonTest) and not self.testDom.hasKey(rLine):
      self.testLines[rLine] = self.makeFlowLine(rLine)

      self.ensureTestLineContainer(rLine)

      let widget = self.testDom[rLine]
      let testContainer = self.makeTestContainer(rLine)
      let parentContainer = self.testDom[rLine]
      let testVNode = testVNode(self, rLine, isPythonTest)
      let testNode = vnodeToDom(testVNode, KaraxInstance())

      testContainer.appendChild(testNode)
      parentContainer.appendChild(testContainer)

proc clearTest(self: EditorViewComponent) =
  for testLine in self.testLines:
    if not testLine.contentWidget.isNil:
      self.monacoEditor.removeContentWidget(testLine.contentWidget.toJs)
      testLine.contentWidget = nil
  self.testDom = JsAssoc[int, Node]{}

proc editorView(self: EditorViewComponent): VNode = #{.time.} =
  var tabInfo = self.tabInfo

  if tabInfo.isNil:
    return buildHtml(
      tdiv()
    ):
      text "file not loaded"

  let index = self.id
  var selector = cstring""

  if not self.isExpansion:
    selector = cstring(&"#editorComponent-{index}")
  else:
    selector = cstring(&"#expanded-{self.parentLine}")

  let path = tabInfo.name

  if self.renderer.isNil:
    result = buildHtml(tdiv())
    return

  if tabInfo.monacoEditor.isNil:
    self.renderer.afterRedraws.add(proc: void =
      let trace = not self.data.trace.isNil
      var readOnly: bool
      if self.data.ui.readOnly:
        readOnly = true
      else:
        readOnly = false

      const whiteThemeDef = staticRead("../../public/third_party/monaco-themes/themes/customThemes/json/codetracerWhite.json")
      const darkThemeDef = staticRead("../../public/third_party/monaco-themes/themes/customThemes/json/codetracerDark.json")

      cdebug "HEHE XD"

      try:
        {.emit: "monaco.editor.defineTheme('codetracerWhite', " & whiteThemeDef & ")\n".}
        {.emit: "monaco.editor.defineTheme('codetracerDark', " & darkThemeDef & ")\n".}
      except:
        let message = getCurrentExceptionMsg()
        cerror "editor: defining themes: " & message

      let theme = if self.data.config.theme == cstring"default_white": cstring"codetracerWhite" else: cstring"codetracerDark"

      var editorReady = false
      try:
        let documentTmp = domWindow.document
        let overflowHost = documentTmp.createElement(cstring("div"))
        overflowHost.className = cstring("monaco-editor")
        documentTmp.body.appendChild(overflowHost)

        cdebug "editor: creating monaco editor " & $self.name
        var lang = fromPath(path)
        if lang == LangNoir:
          lang = LangRust

        cdebug lang

        tabInfo.monacoEditor = createMonacoEditor(
          selector,
          MonacoEditorOptions(
            value: tabInfo.source,
            language: lang.toCLang(),
            readOnly: readOnly,
            theme: theme,
            automaticLayout: true,
            folding: true,
            fontSize: self.data.ui.fontSize,
            minimap: js{ enabled: false },
            find: js{ addExtraSpaceOnTop: false },
            renderLineHighlight: if self.editorView == ViewLowLevelCode: "none".cstring else: "".cstring,
            lineNumbers: proc(line: int): cstring = self.editorLineNumber(path, line),
            lineDecorationsWidth: 20,
            scrollBeyondLastColumn: 0,
            contextmenu: false,
            scrollbar: js{
              horizontalScrollbarSize: 14,
              horizontalSliderSize: 8,
              verticalScrollbarSize: 14,
              verticalSliderSize: 8
            },
            overflowWidgetsDomNode: overflowHost,
            fixedOverflowWidgets: true
          )
        )

        tabInfo.monacoEditor.config = getConfiguration(tabInfo.monacoEditor)
        editorReady = true
      except:
        cerror "editor: " & getCurrentExceptionMsg()
        if tabInfo.monacoEditor.isNil:
          return
      finally:
        if not tabInfo.monacoEditor.isNil:
          self.monacoEditor = tabInfo.monacoEditor
          if self.monacoEditor notin self.data.ui.monacoEditors:
            self.data.ui.monacoEditors.add(self.monacoEditor)
          registerLspEditor(self)
          try:
            self.delegateShortcuts(self.monacoEditor)
          except:
            cerror "delegateShortcuts " & getCurrentExceptionMsg()
        if not editorReady:
          return

      self.monacoEditor = tabInfo.monacoEditor
      if self.monacoEditor notin self.data.ui.monacoEditors:
        self.data.ui.monacoEditors.add(self.monacoEditor)

      tabInfo.monacoEditor.onMouseWheel(proc(e: js) =
        if not self.flow.isNil and self.flow.shouldRecalcFlow:
          self.flow.resizeFlowSlider()
      )

      tabInfo.monacoEditor.onDidScrollChange(proc(e: js) =
        let leftPos = fmt"{e.scrollLeft}px".cstring
        for trace in self.traces:
          trace.viewZone.domNode.style.toJs.left = leftPos
        for flowLoop in self.flow.flowLoops:
          if not flowLoop.flowZones.isNil:
            self.flow.leftPos = leftPos
            flowLoop.flowZones.dom.style.toJs.left = leftPos
      )

      tabInfo.monacoEditor.onMouseDown(proc(e: js) =
        if cast[bool](e.event.ctrlKey) and cast[bool](e.event.altKey):
          try:
            let targetToken = self.getTokenFromPosition(e.target.position)
            if targetToken != "":
              self.sourceCallJump(
                self.name,
                self.lastMouseMoveLine,
                targetToken,
                SmartJump)
          except AmbiguousFunctionCallException:
            self.api.errorMessage getCurrentExceptionMsg()
        elif cast[bool](e.event.ctrlKey) or cast[bool](e.event.middleButton):
          self.lastMouseClickLine = self.lastMouseMoveLine
          self.lastMouseClickCol = cast[int](e.target.toJs.position.column)
          if cast[bool](e.event.middleButton) :
            self.sourceOrCallJump(e.target.position)
          else:
            self.editorLineJump(self.lastMouseMoveLine, SmartJump)
        else:
          let position = e.target.position
          let target = cast[cstring](e.target.element.classList.value).split(" ")[0]
          let line = cast[int](position.lineNumber)
          if target != "fa" and not ui_imports.jslib.startsWith(target, "value"):
            self.lastMouseClickLine = line
            self.lastMouseClickCol = cast[int](e.target.toJs.position.column)
            self.data.redraw()
        self.data.ui.activeFocus = self)

      tabInfo.monacoEditor.onContextMenu(proc(ev: js) =
        console.log(cstring"editor: onContextMenu fired")
        let contextMenu = createContextMenuItems(self, ev)
        console.log(cstring"editor: context menu items count = " & $contextMenu.len)
        if contextMenu.len > 0:
          showContextMenu(contextMenu, cast[int](ev.event.posx), cast[int](ev.event.posy)))

      tabInfo.monacoEditor.onMouseMove(proc(event: js) =
        let position = event.target.position
        let line = if not position.isNil:
            cast[int](position.lineNumber)
          else:
            (cast[int](event.target.element.parentElement.offsetTop) div 20) + tabInfo.location.expansionFirstLine
        self.lastMouseMoveLine = line)

      tabInfo.monacoEditor.toJs.getModel().onDidChangeContent(proc =
        if tabInfo.reloadChange:
          tabInfo.reloadChange = false
        else:
          tabInfo.changed = true)

      console.log("DELEGATING SHORTCUTS")

      try:
        # echo "delegate shortcuts"
        self.delegateShortcuts(self.monacoEditor)
      except:
        cerror "delegateShorcuts " & getCurrentExceptionMsg()

      try:
        self.loadKeyPlugins()
      except:
        cerror "loadKeyPlugins " & getCurrentExceptionMsg()

      document.querySelector(selector).addEventListener(cstring"click", proc(ev: Event) =
        ev.stopPropagation()
        for element in cast[seq[cstring]](ev.toJs.target.classList):
          if element == cstring"gutter-line" or element == cstring"gutter-breakpoint":
            self.lineActionClick(tabInfo, ev.target.toJs)
            return
          if ($element).contains("gutter"):
            self.lineActionClick(tabInfo, ev.target.toJs)
      )

      document.querySelector(selector).addEventListener(cstring"contextmenu", proc(ev: Event) =
        for element in cast[seq[cstring]](ev.toJs.target.classList):
          if element == cstring"gutter-line" or element == cstring"gutter-breakpoint":
            ev.preventDefault()
            ev.stopPropagation()
            self.lineActionContextMenu(tabInfo, ev.target.toJs)
            return
      )
    )

  var self2 = self

  self.renderer.afterRedraws.add(proc: void =
    try:
      if self.isExpansion:
        var zoneNode = cast[Node](self.viewZone.domNode)

      if not self.flow.isNil and self.data.config.flow.enabled and self.data.ui.mode == DebugMode:
        self.redrawFlow()
      else:
        if not self.flow.isNil and not self.flow.flow.isNil:
          self.flow.clear()

      if self.shouldLoadFlow and not self.tabInfo.monacoEditor.isNil:
        self.loadFlow(FlowMode.Call, tabInfo.location)
        self.shouldLoadFlow = false

      if not self.data.startOptions.diff.isNil and
        self.diffViewZones.len() == 0 and
        self.diffAddedLines.len() == 0:
          self.clearDiffViewZones()
          self.makeDiffViewZones()
          self.loadFlow(FlowMode.Diff, types.Location())

      self.addTestActions()
      self.applyEventualStylesLines()

    except Exception as e:
      cerror "afterRedraw redrawFlow" & getCurrentExceptionMsg()

    var toggleList: seq[int] = @[]

    for line, trace in self.traces:
      if trace.expanded:
        if not trace.m.isNil:
          trace.m.redraw()

    for line, expandedInstance in self.expanded:
      self.ensureExpanded(expandedInstance, line)
      if expandedInstance.isExpanded:
        expandedInstance.renderer.redraw()
  )

  let depth = self.tabInfo.location.expansionDepth
  let expansionClass = if self.isExpansion: &"expansion expansion-{depth}" else: ""

  if self.data.ui.activeFocus == self:
    discard self.renderValueTooltip()

  result = buildHtml(
    tdiv(
      id = &"editorComponent-{index}",
      class = &"editor code-editor tab {expansionClass}",
      `data-label`= tabInfo.name,
      tabIndex = "2"
    )
  )

proc ensureExpanded*(self: EditorViewComponent, expanded: EditorViewComponent, line: int) =
  if expanded.viewZone.isNil:
    let id = cstring(&"expanded-{line}")
    var expandedViewZoneNode = createElement(dom.document, cstring"div")
    var editorNode = createElement(dom.document, cstring"div")

    editorNode.toJs.id = id
    editorNode.toJs.classList.add(cstring"expansion")
    expandedViewZoneNode.append(editorNode)

    expanded.viewZone = js{
      afterLineNumber: line,
      heightInLines: 7,
      domNode: expandedViewZoneNode
    }

    self.monacoEditor.changeViewZones do (view: js):
      expanded.zoneId = cast[int](view.addZone(expanded.viewZone))

    expanded.renderer = setRenderer(proc: VNode = expanded.render(), id, proc = discard)
    domwindow.toJs.parent = expanded.viewZone.domNode.parentNode
    expanded.isExpanded = true

    return
  else:
    if not expanded.isExpanded:
      if expanded.zoneId >= 0:
        self.monacoEditor.changeViewZones do (view: js):
          try:
            view.removeZone(expanded.zoneId)
            expanded.zoneId = -1
          except:
            cerror "editor: non expanded: " & getCurrentExceptionMsg()
    else:
      if expanded.zoneId == -1:
        self.monacoEditor.changeViewZones do (view: js):
          expanded.zoneId = cast[int](view.addZone(expanded.viewZone))

    discard

proc loadingLowLevel: VNode =
  text("LOADING CODE")

proc loadingEditorView(index: int, tab: cstring): VNode =
  buildHtml(
    tdiv(
      id = &"editorComponent-{index}",
      class="editor code-editor tab",
      `data-label`= tab
    )
  )

method afterInit*(self: EditorViewComponent) {.async.} =
  if self.service.completeMoveResponses.hasKey(self.path):
    await self.onCompleteMove(self.service.completeMoveResponses[self.path])
    discard jsDelete(self.service.completeMoveResponses[self.path])

func multilineFlowLines*: JsAssoc[int, KaraxInstance] =
  JsAssoc[int, KaraxInstance]{}

func supportsFlow*(self: EditorViewComponent): bool =
  self.data.config.flow.enabled

method onFindOrFilter*(self: EditorViewComponent) {.async.} =
  self.monacoEditor.trigger("keyboard".cstring, "actions.find".cstring)

method onCompleteMove*(self: EditorViewComponent, response: MoveState) {.async.} =
  duration("complete move")
  self.location = response.location
  # cdebug fmt"reset Flow {response.resetFlow}"

  if self.editorView == ViewTargetSource and self.data.trace.lang == LangNim and
     response.cLocation.path == self.name:
    if not self.monacoEditor.isNil:
      self.monacoEditor.revealLineInCenterIfOutsideViewport(response.cLocation.line, Immediate)

  discard setTimeout(proc() = self.updateLineNumbersOnly(), 100)

  for view, isEnabled in self.data.ui.openViewOnCompleteMove:
    if isEnabled:
      case view:
      of ViewInstructions:
        if self.data.trace.lang in {LangC, LangCpp, LangRust, LangGo}:
          self.data.openInstructions(self.data.services.debugger.location.asmName)
        elif self.data.trace.lang == LangNim:
          self.data.openInstructions(self.data.services.debugger.cLocation.asmName)

      of ViewTargetSource:
        if self.data.trace.lang == LangNim:
          self.data.openTargetSource(self.data.services.debugger.cLocation.path)

      else:
        discard

  let sourceFilePath =
    if self.editorView != ViewInstructions:
      self.path
    else:
      self.path.split(cstring":")[0]

  if response.location.path == sourceFilePath:
    self.data.services.debugger.stableBusy = false
    if not response.location.isExpanded:
      self.service.active = response.location.path
    else:
      self.service.active = cstring(&"expanded-{response.location.expansionFirstLine}")
    self.service.changeLine = true
    self.service.currentLine = response.location.line

    if not self.flow.isNil:
      self.flow.activeStep = FlowStep(rrTicks: -1)

    if (response.resetFlow or self.flow.isNil) and self.supportsFlow():
      if not self.flow.isNil:
        self.flow.clear()
      cdebug "flow: create flow again"
      if self.tabInfo.monacoEditor.isNil:
        self.shouldLoadFlow = true
      else:
        self.loadFlow(FlowMode.Call, response.location)
        self.shouldLoadFlow = false

    elif self.supportsFlow() and not self.flow.isNil:
      self.flow.redrawFlow()
      self.adjustEditorWidth()

  if self.data.trace.lang != LangRubyDb:
    discard data.services.debugger.loadParsedExprs(self.service.currentLine, response.cLocation.path)

  if not self.flow.isNil:
    discard self.flow.onCompleteMove(response)
  self.data.redraw()

proc onSelectFlow*(data: Data) {.async.} =
  await data.ui.editors[data.services.editor.active].flow.select()

proc onSelectState*(data: Data) {.async.} =
  await data.ui.componentMapping[Content.State][0].select()

method render*(self: EditorViewComponent): VNode =
  if not self.data.lspStarted:
    self.data.ipc.send("CODETRACER::start-lsp", js{})
    self.data.lspStarted = true

  if self.editorView == ViewNoSource:
    result = self.noInfo.render()
  elif not self.isExpansion and (not self.service.open.hasKey(self.name) or not self.service.open[self.name].received):
    result = loadingEditorView(self.id, self.name)
  else:
    result = editorView(self)

method onEnter*(self: EditorViewComponent) {.async.} =

  console.log("This gonn get nasty")
  var editor = self.monacoEditor

  if self.data.ui.readOnly and editor.hasTextFocus():
    let line = editor.getLine()
    var flow = self.flow

    if not flow.isNil and flow.selected and flow.selectedStepCount != -1:
      flow.openValue(flow.selectedStepCount, cstring"", before=true)
      discard
    else:
      if data.services.editor.activeTabInfo().changed:
        cwarn("TAB IS EDITED, DOING NOTHING")
      else:
        self.toggleTrace(self.name, line)


  elif self.data.ui.readOnly:
    let line = editor.getLine()
    let code = self.traces[line].monacoEditor.getValue()
    let lineCount = code.split("\n").len() + 1

    self.traces[line].lineCount = lineCount
    self.traces[line].expandWithEnter(lineCount * (data.ui.fontSize + 5))
    self.traces[line].monacoEditor.insertTextAtCurrentPosition("\n")

    discard setTimeout(proc() =
      self.traces[line].monacoEditor.toJs.getDomNode().querySelector("textarea").focus(),
      1
    )
    data.ui.activeFocus = self.traces[line]

method onUpdatedFlow*(self: EditorViewComponent, update: FlowUpdate) {.async.} =
  if not self.flow.isNil:
    await self.flow.onUpdatedFlow(update)
    self.adjustEditorWidth()
