# Praise Lord Jesus!

import
  std / [
    jsffi, strformat, strutils, sequtils, sugar,
    async, jsconsole
  ],
  # third party
  karax, karaxdsl, kdom, vdom, results,
  # internal
  lib, ui_helpers, types, utils, lang,
  communication, dap,
  .. / common / ct_event,
  services / [
    event_log_service, debugger_service, editor_service,
    flow_service, search_service, shell_service]
  # ui / datatable

# (alexander): if i remember correctly: to prevent clashes with other dom-related modules 
from std / dom import Element, getAttribute, Node, preventDefault, document, window,
                Document, getElementById, querySelectorAll, querySelector,
                getElementsByClassName, contains, add


var configureUiIPC*: js
var ipc*: js
var socketdebug*: js

var start* = now()

var electron* {.importc.}: JsObject
var Chart* {.importc.}: JsObject
var vex* {.importc.}: JsObject
var tippy* {.importc.}: JsObject
var monaco* {.importc.}: Monaco
var fuzzysort* {.importc.}: Fuzzysort
var noUiSlider* {.importc.}: js
proc wNumb*(options: js): js {.importc.}

proc duration*(name: string) =
  echo &"TIME {name} {now() - start}"

if inElectron:
  ipc = electron.ipcRenderer
  data.ipc = ipc
else:
  ipc = undefined

var escapeHandler*: proc: void
escapeHandler = nil


const TRACEDEPTH* = 2
const HISTORYDEPTH* = 2
# const STATEDEPTH = 2

# var uiGraphEngine* {.exportc: "graphEngine".}: GraphEngine
# var oldGraphEngine* {.exportc.}: GraphEngine

# proc contextMenuHandler*(self: ContextMenu, event: MouseEvent) =
#   let clientX = event.clientX
#   let clientY = event.clientY

#   self.dom.style.top = &"{clientY}px"
#   self.dom.style.left = &"{clientX}px"

#   self.dom.toJs.classList.add("visible")
#   cast[kdom.Node](self.dom).focus()

proc contextMenuOption(self: ContextMenu, key: int): VNode =
  buildHtml(
    tdiv(class = "context-menu-option",
         onclick = proc =
          self.actions[key]()
          self.dom.toJs.classList.remove("visible"))):
      tdiv(class = "context-menu-option-text"): text self.options[key]

proc renderContextMenu*(self: ContextMenu): dom.Node =
  let vNode = buildHtml(
    tdiv(
      class = "context-menu",
      tabindex = "0",
      onblur = proc =
        self.dom.toJs.classList.remove("visible"))):
    for key, option in self.options:
      contextMenuOption(self, key)
  return cast[dom.Node](vnodeToDom(vNode, KaraxInstance()))


proc loadTheme*(name: cstring)

proc loadShellTheme*(data: Data, name: cstring) =
  let shellComponent = data.shellComponent(0)
  shellComponent.shell.options.theme = shellComponent.themes[name]

proc loadMonacoTheme*(themeName: cstring) =
  monaco.editor.toJs.setTheme(themeName)

proc gotoLine*(line: int, highlight: bool = false, change: bool = false) {.exportc.}
proc lowAsm*(data: Data): bool
proc highlightLine*(path: cstring, line: int)
proc saveFiles*(data: Data, path: cstring = j"", saveAs: bool = false)
proc step*(data: Data, action: CtEventKind, repeat: int = 1, fromShortcutArg: bool = false, taskId: TaskId = NO_TASK_ID)
proc openLocation*(data: Data, path: cstring, line: int) {.async.}

# UTILS

# TODO: templates


proc viewerPanel*(data: Data): GoldenContentItem =
  # TODO store it based on content
  if not data.ui.layout.isNil and data.ui.openComponentIds[Content.EditorView].len > 0:
    let lastViewerComponentIndex = data.ui.openComponentIds[Content.EditorView][^1]
    cast[GoldenContentItem](
      data.ui.componentMapping[Content.EditorView][lastViewerComponentIndex].layoutItem.parent)
  else:
    nil


proc editorPanel*(data: Data, editorView: EditorView): GoldenContentItem =
  data.ui.editorPanels[editorView]


proc currentLine*(data: Data): int =
  data.services.debugger.location.line


proc openCallViewer*(panel: GoldenContentItem, path: cstring, name: cstring, editorView: EditorView, lang: Lang) =
  let tab = GoldenLayoutConfig(
    `type`: j"component",
    componentName: j"genericUiComponent",
    componentState: GoldenItemState(
      id: 0,
      label: cstring"calls",
      content: Content.CalltraceEditor,
      fullPath: cstring"",
      name: cstring"calls",
      editorView: editorView,
      lang: lang,
      isEditor: false
    ) # calltrace of editors, not editor
  )

  let resolvedConfig = data.ui.contentItemConfig.resolve(tab)

  let contentItem = data.ui.layout.createAndInitContentItem(resolvedConfig, panel)
  discard panel.addChild(contentItem)


proc saveConfig*(data: Data, layoutConfig: GoldenLayoutConfig) =
  # kout layoutConfig.toJs
  if data.ui.mode == DebugMode:
    ipc.send "CODETRACER::save-config", js{
      name: j"default_layout",
      layout: JSON.stringify(layoutConfig.toJs)}


var redrawIndex* = 0


proc redrawAll* =
  # echo "redraw"
  # echo "## REDRAW"
  # if not data.ui.layout.isNil: # TODO: Remove
    # data.updateViewer()
  var e = 0
  for name, kxi in kxiMap:
    try:
      # echo "redraw ", name
      redraw(kxi)
    except:
      cerror "redrawAll: error when calling redraw"
    e += 1
  if e != kxiMap.len:
    cerror "redrawAll: not all redrawed, e != kxiMap.len"
  # if redrawIndex mod 50 == 0 and not data.ui.layout.isNil:
    # var build = data.ui.layout.root.contentItems[0].contentItems[0].contentItems[2]
    # workaround
    # if not build.config.isNil:
    #   var oldWidth = build.config.width
    #   build.config.width = 45
    # data.saveConfig(data.ui.layout)
    #   build.config.width = oldWidth
  data.ui.lastRedraw = now()
  redrawIndex += 1
  # echo "## FINISH REDRAW ", redrawIndex
data.redraw = redrawAll


# proc getSelectionText: cstring =
#   var text = cstring""
#   let window = cast[JsObject](dom.window)
#   let document = cast[JsObject](dom.document)
#   let documentSelection = document.selection
#   if not window.getSelection.isNil:
#     let selection = window.getSelection()
#     text = cast[cstring](selection.toString())
#   elif not documentSelection.isNil:
#     let selectionRange = documentSelection.createRange()
#     text = cast[cstring](selectionRange.text)
#   # kout text
#   return text

proc langs*: string =
  result = ""
  for z in SUPPORTED_LANGS:
    result.add("<option value='$1'>$2</option>" % [toCLang(z), toName(z)])


var traceTime = Date.now()
const traceRedrawLimit = 500

proc maybeRedrawTraces*(length: int) =
  let newTime = Date.now()
  if length <= 20 and newTime - traceTime > traceRedrawLimit or
     length > 20 and length <= 100 and newTime - traceTime > 5 * traceRedrawLimit or
     length > 100 and newTime - traceTime > 20 * traceRedrawLimit:
    traceTime = newTime
    redrawAll()
  else:
    log cstring(fmt"wait: {(newTime - traceTime)} {20 * traceRedrawLimit}")


  # TODO tabInfo.lowLevelMap = map
  # TODO tabInfo.name = if lowLevel == 2: map.name else: j""


proc asmTabLoad*(path: cstring, name: cstring): Future[void] =
  # TODO data.servics.tabLoad(path, name, data.lang, lowLevel=2)
  discard

proc getLine*(element: kdom.Node): int =
  let e = cast[dom.Element](element)
  parseInt($eattr(e, "line")) + 1

proc getColumn*(element: kdom.Node): int =
  let e = cast[dom.Element](element)
  parseInt($eattr(e, "line")) + 1

# INIT

proc loadFlowUI*(ui: cstring): FlowUI =
  if ui == j"parallel":
    FlowParallel
  elif ui == j"inline":
    FlowInline
  else:
    FlowMultiline



# IPC HANDLERS

var helpers*: Helpers

proc createUIComponent(componentState: JsObject) =
  try:
    discard data.makeComponent(
      cast[Content](componentState.content),
      componentState.id.to(int),
      componentState.fullPath.to(cstring),
      componentState.noInfoMessage.to(cstring))
  except ValueError:
    cerror "createUIComponent: " & getCurrentExceptionMsg()

proc createUILayoutComponents(content: JsObject) =
  if content["type"].to(cstring) == j"component":
      createUIComponent(content.componentState)
  else:
    for key, contentConfig in content.content:
      createUILayoutComponents(contentConfig)

proc createUIComponents*(data: Data) =
  # create singletons
  discard data.makeDebugComponent()
  discard data.makeMenuComponent()
  discard data.makeBuildComponent()
  discard data.makeErrorsComponent()
  discard data.makeStatusComponent(
    data.buildComponent(0), data.errorsComponent(0), data.ui.searchResults)
  discard data.makeSearchResultsComponent()
  discard data.makeCommandPaletteComponent()

  # create components defined in layout
  if not data.ui.resolvedConfig.isNil:
    createUILayoutComponents(data.ui.resolvedConfig.root)

# proc saveNew(data: Data, file: SaveFile) =
#   ipc.send "CODETRACER::save-new", file

# proc saveClose(data: Data, index: int) =
#   ipc.send "CODETRACER::save-close", index

proc onTabReloaded*(sender: js, response: jsobject(argId=cstring, value=TabInfo)) =
  var tab = data.services.editor.open[response.value.path]
  tab.source = response.value.source
  tab.sourceLines = response.value.sourceLines
  tab.changed = false
  redrawAll()
  tab.reloadChange = true
  data.ui.editors[response.value.path].monacoEditor.setValue(response.value.source)
  tab.changed = false

proc placeByRRTicks*(stops: var seq[Stop], currentStop: Stop): int =
  var resultIndex: int

  if stops.len == 0:
    stops.add(currentStop)
    resultIndex = 0
  else:
    var startIndex = 0
    var endIndex = stops.len
    while true:
      let midIndex = (startIndex + endIndex) div 2
      let midStop = stops[midIndex]
      var newMidIndex: int
      if currentStop.rrTicks < midStop.rrTicks:
        newMidIndex = (startIndex + midIndex) div 2
        if newMidIndex == midIndex:
          resultIndex = midIndex
          break
        endIndex = midIndex
      elif currentStop.rrTicks > midStop.rrTicks:
        newMidIndex = (midIndex + endIndex) div 2
        if newMidIndex == midIndex:
          resultIndex = midIndex + 1
          break
        startIndex = midIndex
      else:
        resultIndex = midIndex + 1
        break

    stops.insert(@[currentStop], resultIndex)

  return resultIndex

var tracepointStart* = 0i64

proc onContextStartTrace*(sender: js, response: seq[Tracepoint]) =
  data.services.trace.traceSessions.add(TraceSession(
    tracepoints: response,
    id: data.services.trace.traceSessions.len))
  data.pointList.lastTracepoint = 0
  data.pointList.redrawTracepoints = true
  # TODO inline toggleIn(response[0].line, text=j(&"log {response[0].expression}"))

proc onContextStartHistory*(sender: js, response: jsobject(inState=bool, expression=cstring)) =
  # TODO
  # # data.inStateHistory = response.inState
  # if response.inState:
  #   data.stateHistory[response.expression] = @[]
  #   data.stateHistoryGraphics[response.expression] = GraphicText
  # else:
  #   data.history.query = response.expression
  #   data.history.results = @[]
  # redrawAll()
  discard

proc onLoadParsedExprsReceived*(sender: js, response: jsobject(argId=cstring, value=JsAssoc[cstring, seq[FlowExpression]])) =
  jsAsFunction[proc(response: JsAssoc[cstring, seq[FlowExpression]]): void](data.network.futures["load-parsed-exprs"][response.argId])(response.value)

proc onUploadTraceFileReceived*(sender: js, response: jsobject(argId=cstring, value=UploadedTraceData)) =
  jsAsFunction[proc(response: UploadedTraceData): void](data.network.futures["upload-trace-file"][response.argId])(response.value)

proc onDeleteOnlineTraceFileReceived*(sender: js, response: jsobject(argId=cstring, value=bool)) =
  jsAsFunction[proc(response: bool): void](data.network.futures["delete-online-trace-file"][response.argId])(response.value)

# TODO: make some kind of dsl?
# locals
proc onLoadLocalsReceived*(sender: js, response: jsobject(argId=cstring, value=JsAssoc[cstring, Value])) =
  jsAsFunction[proc(response: JsAssoc[cstring, Value]): void](data.network.futures["load-locals"][response.argId])(response.value)

# calltrace / callstack


proc onLoadCallstackReceived*(sender: js, response: jsobject(argId=cstring, value=seq[Call])) =
  jsAsFunction[proc(response: seq[Call]): void](data.network.futures["load-callstack"][response.argId])(response.value)


proc onLoadCallstackDirectChildrenBeforeReceived*(sender: js, response: jsobject(argId=cstring, value=seq[Call])) =
  jsAsFunction[proc(response: seq[Call]): void](data.network.futures["load-callstack-direct-children-before"][response.argId])(response.value)

# value
proc onEvaluateExpressionReceived*(sender: js, response: jsobject(argId=cstring, value=Value)) =
  jsAsFunction[proc(response: Value): void](data.network.futures["evaluate-expression"][response.argId])(response.value)

proc onExpandValueReceived*(sender: js, response: jsobject(argId=cstring, value=Value)) =
  jsAsFunction[proc(response: Value): void](data.network.futures["expand-value"][response.argId])(response.value)

proc onExpandValuesReceived*(sender: js, response: jsobject(argId=cstring, value=seq[Value])) =
  jsAsFunction[proc(response: seq[Value]): void](data.network.futures["expand-values"][response.argId])(response.value)

# editor

proc onTabLoadReceived*(sender: js, response: jsobject(argId=cstring, value=TabInfo)) =
  # cdebug "onTabLoadReceived"
  # console.debug response
  jsAsFunction[proc(response: TabInfo): void](data.network.futures["tab-load"][response.argId])(response.value)

proc onAsmLoadReceived*(sender: js, response: jsobject(argId=cstring, value=Instructions))=
  jsAsFunction[proc(response: Instructions): void](data.network.futures["asm-load"][response.argId])(response.value)
# search

proc onSearchCalltraceReceived*(sender: js, response: jsobject(argId=cstring, value=seq[Call])) =
  jsAsFunction[proc(response: seq[Call]): void](data.network.futures["search-calltrace"][response.argId])(response.value)

# on-  => call service callback and service updates lead to redraw

# await updateCalltrace() => send ipc, and get it back

proc onOpenLocation*(sender: js, response: types.Location) =
  # echo "open location"
  # kout response
  if response.isExpanded:
    discard data.services.editor.openExpanded(response)
  else:
    discard data.openLocation(response.highLevelPath, response.highLevelLine)

proc onCollapseExpansion*(sender: js, response: jsobject(path=cstring, line=int, expansionFirstLine=int, update=MacroExpansionLevelUpdate))  =
  let expandEditorId = cstring(fmt"expanded-{response.expansionFirstLine}")
  if data.ui.editors.hasKey(expandEditorId):
    var editor = data.ui.editors[expandEditorId]
    editor.isExpanded = false
    data.redraw()
  # kout response

proc onCollapseAllExpansion*(sender: js, response: jsobject(path=cstring, line=int, expansionFirstLine=int, update=MacroExpansionLevelUpdate)) =
  # kout response
  discard

proc onFollowHistory*(sender: js, response: jsobject(address=cstring)) =
  redrawAll()

proc expand*(path: cstring, line: int) {.exportc, used.} =
  ipc.send "CODETRACER::update-expansion", js{
    path: path,
    line: line,
    update: MacroExpansionLevelUpdate(kind: MacroUpdateExpand, times: 1)
  }

  # TODO
  # expandUpdate(path, line, MacroExpansion)

var debugResponse* = DebugOutput(kind: DebugResult, output: cstring"")

karaxSilent = true #SILENT_LOG

proc onDebugOutput*(sender: js, response: jsobject(output=DebugOutput)) =
  clog fmt"debug output: {response.output}"
  debugResponse = response.output
  # if .replHistory.len > 0 and data.replHistory[^1][1].len == 0:
  #   echo "repl history"
  #   data.replHistory[^1][1] = response.output

  redrawAll()


# data.logs = js{}

# TODO
proc onLogOutput*(sender: js, response: jsobject(debuggerA=cstring, gdb=cstring)) =
  discard

proc onAddBreakpoint*(sender: js, response: jsobject(path=cstring, line=int)) =
  data.services.debugger.addBreakpoint(response.path, response.line)
  data.ui.editors[response.path].refreshEditorLine(response.line)

proc onRunTo*(sender: js, response: jsobject(path=cstring, line=int, reverse=bool)) =
  # TODO
  data.services.debugger.runTo(response.path, response.line, reverse=response.reverse)

# UI HANDLERS

## JUMP

proc jumpInlineCall*(path: cstring, line: int, name: cstring) =
  ipc.send "CODETRACER::inline-call-jump", types.Location(path: path, line: line, functionName: name)




# TODO
#proc macroExpansionJump*(path: cstring, line: int) {.async.} =
  #await tabLoad(path, j"", data.lang)
  #highlightLine(path, line)


proc codeIDJump*(codeID: int64) =
  ipc.send "CODETRACER::codeID-jump", js{codeID: codeID}

proc jumpLocation*(location: types.Location) {.async.} =
  # TODO await tabLoad(location.path, j"", data.lang)
  highlightLine(location.path, location.line)

## MOVE
proc step*(
    data: Data,
    action: CtEventKind,
    repeat: int = 1,
    fromShortcutArg: bool = false,
    taskId: TaskId = NO_TASK_ID) =
  let taskId = if taskId == NO_TASK_ID: genTaskId(Step) else: taskId
  if fromShortcutArg:
    cdebug &"shortcut for step {action}", taskId
  else:
    cdebug &"renderer: step call for step {action}", taskId

  # for now directly depend here on the active view
  # maybe we should instead pass it as arg from the action handlers
  var editorView: EditorView
  if not data.ui.editors[data.services.editor.active].isNil:
    editorView = data.ui.editors[data.services.editor.active].editorView
  else:
    editorView = ViewSource

  # eventually always sending a different custom ct/step with more args?
  data.viewsApi.receive(InternalNewOperation, NewOperation(name: ($action).cstring, stableBusy: true).toJs, data.viewsApi.asSubscriber)
  data.dapApi.sendCtRequest(action, DapStepArguments(threadId: 1).toJs) # TODO: For now hardcode the threadId

template forwardContinue*(fromShortcut: bool) =
  data.step DapContinue, fromShortcutArg=fromShortcut

template next*(fromShortcut: bool) =
  data.step DapNext, fromShortcutArg=fromShortcut

template stepIn*(fromShortcut: bool) =
  data.step DapStepIn, fromShortcutArg=fromShortcut

template stepOut*(fromShortcut: bool) =
  data.step DapStepOut, fromShortcutArg=fromShortcut

template reverseContinue*(fromShortcut: bool) =
  data.step DapReverseContinue, fromShortcutArg=fromShortcut

template reverseNext*(fromShortcut: bool) =
  data.step DapStepBack, fromShortcutArg=fromShortcut

template reverseStepIn*(fromShortcut: bool) =
  data.step CtReverseStepIn, fromShortcutArg=fromShortcut

template reverseStepOut*(fromShortcut: bool) =
  data.step CtReverseStepOut, fromShortcutArg=fromShortcut

# proc continueTo(breakpoints: seq[UIBreakpoint]) =
#   changeLine(data.lastLine)
#   data.stableBusy = true
#   data.currentOperation = "continue"
#   event data.currentOperation
#   ipc.send "CODETRACER::continue-to", js{breakpoints: breakpoints}

# proc continueToFirst* =
#   if not data.stableBusy:
#     continueTo(data.breakpoints)

proc stopAction* {.locks: 0.}=
  discard


proc loadTheme*(name: cstring) =
  var link = jq("#theme")
  let currentTheme = cast[JsObject](link).dataset.theme.to(cstring)
  if currentTheme != name:
    let linkValue = cstring(fmt"frontend/styles/{name}_theme_electron.css?theme={now()}")
    cast[js](link).href = linkValue
    cast[js](link).dataset.theme = name


let monacoThemeNames* = JsAssoc[cstring, cstring]{"mac classic": j"codetracerWhite", # TODO
                                                  "default white": j"codetracerWhite",
                                                  "default black": j"codetracerDark", # TODO
                                                  "default dark": j"codetracerDark"}

let themeProgramNames* = JsAssoc[cstring, cstring]{"mac classic": j"mac_classic",
                                                   "default white": j"default_white",
                                                   "default black": j"default_black",
                                                   "default dark": j"default_dark"}

let themeNames*: array[4, cstring] = [cstring"mac classic",
                                      cstring"default white",
                                      cstring"default black",
                                      cstring"default dark"];

proc loadThemeFromName*(name: cstring) =
  var programName = themeProgramNames[name]
  let monacoTheme = monacoThemeNames[name]
  if not (programName.isNil or monacoTheme.isNil):
    loadMonacoTheme(monacoTheme)
    loadTheme(programName)
  if data.startOptions.shellUi:
    loadShellTheme(data, programName)
  data.config.theme = programName

proc loadThemeForIndex*(index: int) =
  let name = themeNames[index]
  loadThemeFromName(name)


# var resizedLowLevel = false


proc openInstructions*(data: Data, name: cstring) =
  data.openTab(name, ViewInstructions)
  data.ui.openViewOnCompleteMove[ViewInstructions] = true

proc openTargetSource*(data: Data, path: cstring) =
  data.openTab(path, ViewTargetSource) # , LangC)
  data.ui.openViewOnCompleteMove[ViewTargetSource] = true

proc openAlternativeView*(data: Data, id: int) =
  if id == 1:
    case data.trace.lang:
    of LangC, LangCpp, LangRust, LangGo:
      data.openInstructions(data.services.debugger.location.asmName)
    of LangNim:
      data.openTargetSource(data.services.debugger.cLocation.path)
    else:
      discard
  elif id == 2:
    case data.trace.lang:
    of LangNim:
      data.openInstructions(data.services.debugger.cLocation.asmName)
    else:
      discard

proc openProject*(project: Project) {.async.} =
  ipc.send "CODETRACER::open-project", project.toJs


## CLICK

proc highlightLine*(path: cstring, line: int) =
  # cdebug "highlightLine: " & $path & ":" & $line
  # cdebug "active = " & $path
  data.services.editor.active = path
  let editor = data.ui.editors[path]
  data.services.editor.switchHistory(path, editor.editorView)
  var tabInfo = data.services.editor.activeTabInfo()
  if tabInfo.isNil:
    return

  tabInfo.highlightLine = line
  redrawAll()
  discard windowSetTimeout((proc =
    tabInfo.highlightLine = -1
    redrawAll()), 2000)

proc gotoLine*(line: int, highlight: bool = false, change: bool = false) {.exportc.} =
  # echo "gotoLine ", line
  if line > 2:
    var active = data.services.editor.active
    var tab = data.services.editor.activeTabInfo() # data.services.editor.open[active]
    if tab.isNil:
      return

    tab.viewLine = line
    if not tab.monacoEditor.isNil:
      # echo "revealLine", line
      tab.monacoEditor.revealLineInCenterIfOutsideViewport(parseJSInt(cast[cstring](line)), Immediate)
      if change:
        data.services.editor.changeLine = false
      if highlight:
        highlightLine(active, line)

proc focusComponent*(data: Data, component: Component) =
  cast[kdom.Element](dom.window.document.activeElement).blur()
  data.ui.activeFocus = component
  discard component.onFocus()

proc focusEditorView*(data: Data) =
  let map = data.ui.componentMapping
  focusComponent(data, map[Content.EditorView][0])
  cast[JsObject](data.ui.editors[data.services.editor.active].monacoEditor).focus()

proc focusEventLog*(data: Data) =
  let map = data.ui.componentMapping
  focusComponent(data, map[Content.EventLog][0])
  kdom.document.getElementsByClassName("component-container eventLog")[0].focus()

proc focusCalltrace*(data: Data) =
  let map = data.ui.componentMapping
  focusComponent(data, map[Content.Calltrace][0])
  kdom.document.getElementsByClassName("component-container calltrace-view")[0].focus()

proc switchTab*(change: int) {.exportc.} =
  var panel = data.ui.activeEditorPanel
  var active = panel.getActiveContentItem()
  var index = -1
  var i = 0

  for element in panel.contentItems:
    if active == element:
      index = i
      break
    i += 1
  if index == -1:
    return

  let length = panel.contentItems.len
  var newIndex = index + change

  if newIndex >= length:
    newIndex = 0
  elif newIndex < 0:
    newIndex = length - 1

  panel.setActiveContentItem(panel.contentItems[newIndex])

proc switchTabHistory*(data: Data) {.exportc, locks: 0.} =
  log "tabs: switchTabHistory"
  # get editor service
  let editorService = data.services.editor

  # check if we already reach first tab in history
  if editorService.historyIndex == 0:
    # cycle again through history
    editorService.historyIndex =  editorService.tabHistory.len - 1
    cdebug "tabs: switchTabHistory: 0, cycle again through history: historyIndex -> " &
      $editorService.historyIndex
  else:
    cdebug "tabs: switchTabHistory: historyIndex = " & $editorService.historyIndex &
         " -> " & $(editorService.historyIndex - 1)

    editorService.historyIndex = editorService.historyIndex - 1
  let newTab: EditorViewTabArgs = editorService.tabHistory[editorService.historyIndex]
  if data.ui.mode != CalltraceLayoutMode:
    data.openTab(newTab.name, newTab.editorView)

proc openLocation*(data: Data, path: cstring, line: int) {.async.} =
  utils.openTab(data, path, ViewSource) # , fromPath(path))
  # TODO add a handler like `onTabReady` and check if it's already ready first
  discard windowSetTimeout(proc =
    gotoLine(line, highlight=true),
    1_000)

proc openFile* =
  ipc.send "CODETRACER::open-tab", js{}

proc reopenLastTab*(data: Data) {.locks: 0.} =
  let editorService = data.services.editor
  if editorService.closedTabs.len == 0:
    return

  let tab = editorService.closedTabs[editorService.closedTabs.len - 1]
  data.openTab(tab.name, tab.editorView)

# openNewTab is used only to open a new empty file
# for open any other kind of tab - use openLayoutTab !
proc openNewTab*(data: Data) {.locks: 0.} =
  let path = cstring(fmt"#untitled{data.services.editor.untitledIndex}")
  data.services.editor.untitledIndex += 1

  let lang = fromPath(path)
  data.services.editor.open[path] = TabInfo(
    overlayExpanded: -1,
    highlightLine: -1,
    changed: true,
    untitled: true,
    name: path,
    source: cstring"",
    lang: lang)
  data.openTab(path, ViewSource)
  data.focusComponent(data.ui.editors[path])
  # TODO
  if not data.services.search.paths.hasKey(path):
    data.services.search.pathsPrepared.add(fuzzysort.prepare(path))
    data.services.search.paths[path] = true
  # TODO functionsPrepared ?
  data.redraw()
  # ipc.send "CODETRACER::new-tab", js{path: path}

proc getMonacoOfActiveEditor(data: Data): MonacoEditor =
  let activeEditorPath = data.services.editor.active
  let editor = data.ui.editors[activeEditorPath]
  return editor.monacoEditor

proc getMonacoSelectionText*(data: Data): cstring =
  let monaco = data.getMonacoOfActiveEditor()
  let selection = monaco.getSelection()
  let monacoRange = newMonacoRange(
    selection.startLineNumber,
    selection.startColumn,
    selection.endLineNumber,
    selection.endColumn)
  let textModel = monaco.getModel()
  textModel.getValueInRange(monacoRange)

proc removeTextAtCurrentPosition*(monaco: MonacoEditor, numChars: int) =
  let currentPosition = monaco.getPosition()
  let model = monaco.getModel()

  let lineNumber = currentPosition.lineNumber
  let column = currentPosition.column
  var startLine = lineNumber
  var startColumn = column

  # Traverse backward to calculate the start position
  var remainingChars = numChars
  while remainingChars > 0:
    if startColumn > 1:
      let charsToRemove = min(remainingChars, startColumn - 1)
      startColumn -= charsToRemove
      remainingChars -= charsToRemove
    else:
      # If we're at the beginning of the line, move to the previous line
      if startLine > 1:
        startLine -= 1
        startColumn = model.getLineMaxColumn(startLine)
        remainingChars -= 1 # Account for '\n'
      else:
        break

  # Ensure the edit range is valid
  let editRange = newMonacoRange(
    startLine, startColumn,
    lineNumber, column
  )

  # Execute the delete operation
  monaco.executeEdits(j"", @[
    MonacoEditOperation(
      forceMoveMarkers: true,
      `range`: editRange,
      text: "" # Replace the range with an empty string
    )])

proc insertTextAtCurrentPosition*(monaco: MonacoEditor, text: cstring) =
  let currentPosition = monaco.getPosition()
  let editRange = newMonacoRange(
    currentPosition.lineNumber,
    currentPosition.column,
    currentPosition.lineNumber,
    currentPosition.column)

  monaco.executeEdits(j"", @[
    MonacoEditOperation(
      forceMoveMarkers: true,
      `range`: editRange,
      text: text)])

proc clipboardCopy*(text: cstring) =
  electron.clipboard.writeText(text)

proc clipboardPaste*(data: Data) =
  data.ui.menu.activeDomElement.toJs.focus()
  let activeElement = cast[dom.Node](dom.window.document.activeElement)
  let clipboardText = electron.clipboard.readText().to(cstring)

  if activeElement.isNil or clipboardText == j"":
    return

  let monaco = data.getMonacoOfActiveEditor()

  if not monaco.viewModel.hasFocus:
    if activeElement.nodeName == "INPUT":
      activeElement.toJs.value = clipboardText
    elif activeElement.nodeName == "TEXTAREA":
      activeElement.toJs.textContent = clipboardText
  else:
    monaco.insertTextAtCurrentPosition(clipboardText)

proc openPreferences*(data: Data) =
  # can be a panel going up similar to search results
  # TODO
  discard

proc saveDialog*(data: Data, path: cstring, handler: proc: void) =
  vex.dialog.open(js{
    message: j"",
    input: j(&"{path} changed, save?"),
    buttons: @[
      vex.dialog.buttons.YES, vex.dialog.buttons.NO
    ],
    callback: proc (update: bool) =
      if update:
        data.saveFiles(path)
        data.services.editor.open[path].changed = false
      else:
        data.services.editor.open[path].changed = false
      handler()
  })

let FUZZY_OPTIONS = FuzzyOptions(
  limit: 20,
  allowTypo: true,
  threshold: -10000
)

proc onCommandSearch*(query: cstring) {.async.} =
  # echo query
  data.services.search.queries[SearchCommandRealTime] = query
  # fuzzysort.goAsync(data.commandData.query, data.commandData.prepared).then(proc(results: seq[FuzzyResult]) =
  let tokens = query.split(cstring" ")
  var fuzzyQuery = cstring""
  var prepared: seq[js] = @[]
  # kout tokens
  if tokens.len == 1:
    let commandQuery = tokens[0]
    fuzzyQuery = commandQuery
    prepared = data.services.search.commandsPrepared
    data.services.search.activeCommandName = cstring""
  else:
    let searchQuery = tokens[1]
    fuzzyQuery = searchQuery
    data.services.search.activeCommandName = tokens[0]

    if tokens[0] == "open":
      prepared = data.services.search.pathsPrepared
    elif tokens[0] == "view":
      prepared = data.services.search.functionsInSourcemapPrepared
    else:
      prepared = @[]

  let results = await fuzzysort.goAsync(
    # data.services.search.queries[SearchCommandRealTime],
    fuzzyQuery,
    prepared,
    FUZZY_OPTIONS) #.then(proc(results: seq[FuzzyResult]) =
  # kout results
  data.services.search.results[SearchCommandRealTime] = results.mapIt(
    if it.obj.isNil:
      SearchResult(path: it.target, text: it.target)
    else:
      let function = it.obj.to(Function)
      SearchResult(text: it.target, path: function.path, line: function.line))
  data.redraw()


proc loadFileDialog*(options: js) =
  electron.dialog.showOpenDialogSync(options)

proc search*(data: Data, mode: SearchMode, query: cstring = j"") =
  cdebug fmt"search: {query}"
  data.ui.commandPalette.active = not data.ui.commandPalette.active
  if not data.ui.commandPalette.active:
    # data.services.search.queries[mode] = j""
    data.ui.commandPalette.results = @[]
    # TODO command component
    # data.activeFocus = Content.EditorView
  else:
    data.ui.commandPalette.selected = 0
    let name = j"menu"
    let input = j"#command-query-text"
    if query.len == 0:
      kxiMap[name].afterRedraws.add(proc =
        discard windowSetTimeout(
          proc =
            data.ui.commandPalette.inputField = cast[dom.Node](jq(input))
            data.ui.commandPalette.inputField.toJs.focus()
            case mode
            of SearchCommandRealTime:
              data.ui.commandPalette.inputField.toJs.value = cstring(commandPrefix)
            of SearchFindInFiles:
              data.ui.commandPalette.inputField.toJs.value = cstring(":grep ")
            of SearchFindSymbol:
              data.ui.commandPalette.inputField.toJs.value = cstring(":sym ")
            else:
              discard
          ,
          100
        )
      )
    else:
      kxiMap[name].afterRedraws.add(proc =
        discard windowSetTimeout(proc =
         let element = jq(input)
         element.toJs.value = query
         let event = dom.window.toJs.document.createEvent(j"Event")
         event.initEvent(j"keydown")
         event.keyCode = ENTER_KEY_CODE # enter
         # TODO do we need event.which
         element.toJs.dispatchEvent(event), 50))
    # data.activeFocus = Content.CommandView
  data.redraw()


proc commandSearch*(data: Data, query: cstring = j"") =
  data.search(SearchCommandRealTime, query)

proc fileSearch*(data: Data, query: cstring = j"") =
  data.search(SearchFileRealTime, query)

proc fixedSearch*(data: Data, query: cstring = j"") =
  data.search(SearchFixed, query)

proc findInFiles*(data: Data, query: cstring = j"") =
  data.search(SearchFindInFiles, query)

proc findSymbol*(data: Data, query: cstring = j"") =
  data.search(SearchFindSymbol, query)

proc toggleTraceSettings*(id: int) =
  if data.ui.componentMapping[Content.Trace].hasKey(id):
    var trace = TraceComponent(data.ui.componentMapping[Content.Trace][id])
    trace.showSettings = not trace.showSettings
    data.redraw()


# todo
proc lowAsm*(data: Data): bool =
  false # data.lang == LangNim and data.lowLevel == 2 or data.lang in {LangC, LangCpp, LangRust} and data.lowLevel == 1



proc onShowSubmit*(ev: Event, tg: VNode) =
  cast[js](ev).preventDefault()
  # TODO traceShow(byId("trace-query"))


proc moveTab*(right: bool = true) =
  discard
  # let panel = data.ui.activeEditorPanel
  # TODO


proc moveTab*(path: cstring) =
  discard
  # TODO
  # var viewers = sys.panels.filterIt(it.kind == Single and it.homogeneous and it.content == Content.EditorView)
  # if viewers.len == 0:
  #   return
  # var viewer = viewers[0]
  # for i, tab in data.tabManager.tabList:
  #   if tab == path:
  #     data.tabManager.active = path
  #     viewer.activeTab = viewer.tabs[i]
  #     break
  # redraw()

proc separateBar*(): VNode =
  buildHtml(tdiv(class="separate-bar"))

proc isWindowMaximized(): bool {.importjs: "(window.outerWidth == screen.availWidth) && (window.outerHeight == screen.availHeight)".} =
  false

proc windowMenu*(data: Data, fromWelcomeScreen: bool = false): VNode =
  buildHtml(tdiv(class = "window-menu")):
    tdiv(
      class = "menu-button-svg minimize",
      onclick = proc =
        data.ipc.send "CODETRACER::minimize-window")
    if isWindowMaximized():
      tdiv(
        class = "menu-button-svg restore",
        onclick = proc =
          data.ipc.send "CODETRACER::restore-window"
          if fromWelcomeScreen:
            discard setTimeout(proc() = data.redraw(), 100)
      )
    else:
      tdiv(
        class = "menu-button-svg maximize",
        onclick = proc =
          data.ipc.send "CODETRACER::maximize-window"
          if fromWelcomeScreen:
            discard setTimeout(proc() = data.redraw(), 100)
      )
    tdiv(
      class = "menu-button-svg close",
      onclick = proc =
        data.ipc.send "CODETRACER::close-app")

proc showContextMenu*(options: seq[ContextMenuItem], x: int, yPos: int, inExtension: bool = false): void =
  let y = yPos - 30
  let container = dom.document.getElementById("context-menu-container")
  container.style.display = "flex"
  container.innerHTML = ""
  for i, option in options:
    capture [option]:
      let newElement = kdom.document.createElement("div")
      let itemContainer = kdom.document.createElement("div")
      itemContainer.classList.add("context-menu-item-container")
      newElement.classList.add("context-menu-item")
      newElement.id = cstring(fmt"menu-item-{i}")
      newElement.innerHTML = option.name
      newElement.onclick = proc(ev: Event) {.nimcall.} =
        option.handler(ev)
        container.style.display = "none"
      if option.hint != "":
        let hint = kdom.document.createElement("div")
        hint.classList.add("context-menu-hint")
        hint.id = cstring(fmt"menu-hint-{i}")
        hint.innerHTML = option.hint
        cast[dom.Element](newElement).append(cast[dom.Element](hint))
      cast[dom.Element](itemContainer).append(cast[dom.Element](newElement))
      container.append(cast[dom.Element](itemContainer))

  let contextWidth = cast[dom.Element](container).clientWidth
  let clientWidth = cast[int](jq("#ROOT").toJs.clientWidth)
  let contextHeight = cast[dom.Element](container).clientHeight
  let clientHeight = cast[int](jq("#ROOT").toJs.clientHeight)
  let leftPos =
    if x + contextWidth > clientWidth:
      x - ((x + contextWidth + 10) - clientWidth)
    else:
      x

  var heightOffset = 
    if inExtension:
      40
    else:
      0

  let topPos =
    if y + contextHeight > clientHeight:
      y - ((y + contextHeight + 10) - clientHeight)
    else:
      y
  container.style.top = cstring(fmt"{topPos + heightOffset}px")
  container.style.left = cstring(fmt"{leftPos}px") 

  kdom.document.addEventListener("click", proc(e: Event) =
    container.style.display = "none")

  kdom.document.addEventListener("keydown", proc(e: Event) =
    if cast[int](e.toJs.keyCode) == ESC_KEY_CODE:
      container.style.display = "none")

  # Close context menu if clicked outside on any other element
  try:
    let editorWindow = dom.document.getElementsByClassName("editor")
    let traceWindow = dom.document.getElementsByClassName("trace")
    let callTraceWindow = dom.document.getElementsByClassName("calltrace-view")
    let eventLogWindow = dom.document.getElementsByClassName("eventLog")
    for editor in editorWindow:
      editor.toJs.addEventListener("click", proc(e: Event) =
        container.style.display = "none")
    for trace in traceWindow:
      trace.toJs.addEventListener("click", proc(e: Event) =
        container.style.display = "none")
    for calltrace in callTraceWindow:
      calltrace.toJs.addEventListener("click", proc(e: Event) =
        container.style.display = "none")
    for eventLog in eventLogWindow:
      eventLog.toJs.addEventListener("click", proc(e: Event) =
        container.style.display = "none")
  except:
    discard

proc gotoDefinition*(e: Event, v: VNode) =
  let line = getLine(e.target)
  let column = getColumn(e.target)
  let path = eattr(e.target.parentNode.parentNode.parentNode, "label")
  ipc.send "CODETRACER::goto-definition", js{
    path: path,
    line: line,
    column: column
  }

# DEBUGGER

proc debugProgram(command: cstring) {.exportc.} =
  ipc.send "CODETRACER::debug-program", command

proc readLog {.exportc.} =
  ipc.send "CODETRACER::read-log"

proc debugCT(cmd: cstring) {.exportc.} =
  # debug codetracer write js expression that will eval in debugger
  # js: debugCT("pool.stable.mainLocation")
  ipc.send "CODETRACER::debug-ct", cmd

proc debugRepl*(expression: cstring) {.exportc.} =
  # TODO: await
  ipc.send "CODETRACER::debug-gdb", DebugGdbArg(process: cstring"stable", expression: expression)

proc debugGDB*(process: cstring, cmd: cstring) {.exportc.} =
  # debug GDB name the process you need (stable, trace, etc) and add the comma
  # js: debugGDB("stable", "pi 2 + 2")
  ipc.send "CODETRACER::debug-gdb", js{process: process, cmd: cmd}

var startedSent = false

proc onStarted*(sender: js, response: js) =
  if not startedSent:
    # echo "started"
    startedSent = true
    ipc.send "CODETRACER::started", js{}

proc updateDialog(data: Data, path: cstring) =
  vex.dialog.open(js{
    message: j"",
    input: j(&"{path} changed, update?"),
    buttons: @[
      vex.dialog.buttons.YES, vex.dialog.buttons.NO
    ],
    callback: proc (update: bool) =
      if update:
        data.services.editor.open[path].changed = false
        ipc.send "CODETRACER::reload-file", js{path: path}
      else:
        ipc.send "CODETRACER::no-reload-file", js{path: path}
  })


proc onChangeFile*(sender: js, response: jsobject(path=cstring)) =
  if data.services.editor.open.hasKey(response.path) and data.services.editor.open[response.path].changed:
    data.updateDialog(response.path)
  else:
    ipc.send "CODETRACER::reload-file", response

proc openNormalEditor* =
  # TODO
  discard

proc saveFiles*(data: Data, path: cstring = j"", saveAs: bool = false) =
  for name, tab in data.services.editor.open:
    if path.len == 0 or name == path:
      tab.source = tab.monacoEditor.toJs.getValue().to(cstring)
      if tab.untitled:
        ipc.send "CODETRACER::save-untitled", js{name: name, raw: tab.source, saveAs: true}
      else: #elif tab.changed or saveAs:
        ipc.send "CODETRACER::save-file", js{name: name, raw: tab.source, saveAs: saveAs}

proc commandSelectPrevious* =
  if data.ui.commandPalette.selected > 0:
    data.ui.commandPalette.selected -= 1
    redrawAll()

proc commandSelectNext* =
  if data.ui.commandPalette.selected < data.ui.commandPalette.results.len - 1:
    data.ui.commandPalette.selected += 1
    redrawAll()

proc setOpen* =
  ipc.send "CODETRACER::set-open"


var scrollAssembly* = -1

export event_log_service, debugger_service, editor_service, flow_service, search_service, shell_service, utils
