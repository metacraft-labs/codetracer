import
  async, strutils, strformat, sequtils, algorithm, jsffi, jsconsole,
  karax, vdom, kdom,
  types, lang,
  lib / [ logging, monaco_lib, jslib ]

var kxiMap* = JsAssoc[cstring, KaraxInstance]{}
const
  VALUE_COMPONENT_NAME_WIDTH*: float = 40.0
  VALUE_COMPONENT_VALUE_WIDTH*: float = 55.0

proc openLayoutTab*(
  data: Data,
  content: Content,
  id: int = -1,
  isEditor: bool = false,
  path: cstring = "",
  editorView: EditorView = ViewSource,
  noInfoMessage: cstring = ""
)

proc asyncSend*[T](data: Data, id: string, arg: T, argId: string, U: type, noCache: bool = false): Future[U] =
  if data.asyncSendCache.hasKey(cstring(id)) and data.asyncSendCache[cstring(id)].hasKey(cstring(argId)):
    return cast[Future[U]](data.asyncSendCache[cstring(id)][cstring(argId)])
  result = newPromise() do (resolve: proc(response: U)):
    if not data.network.futures.hasKey(cstring(id)):
      data.network.futures[cstring(id)] = JsAssoc[cstring, JsObject]{}
    if not noCache and data.network.futures[cstring(id)].hasKey(cstring(argId)):
      cerror &"asyncSend: existing future {id} {argId}"
      return
    data.network.futures[cstring(id)][cstring(argId)] = functionAsJs(proc(value: JsObject): U =
      discard jsdelete data.asyncSendCache[cstring(id)][cstring(argId)]
      discard jsdelete data.network.futures[cstring(id)][cstring(argId)]
      resolve(value.to(U)))

    data.ipc.send cstring("CODETRACER::" & id), arg
    echo "<- sent: ", "CODETRACER::" & id
  if not data.asyncSendCache.hasKey(cstring(id)):
    data.asyncSendCache[cstring(id)] = JsAssoc[cstring, Future[JsObject]]{}
  data.asyncSendCache[cstring(id)][cstring(argId)] = cast[Future[JsObject]](result)

proc openPanel*(
  data: Data,
  content: Content,
  componentId: int,
  parent: GoldenContentItem,
  label: cstring,
  isEditor: bool,
  editorView: EditorView = ViewSource,
  noInfoMessage: cstring
): GoldenContentItem

proc makeEditorViewDetailed(
  data: Data,
  name: cstring,
  editorView: EditorView,
  tabInfo: TabInfo,
  location: types.Location
)

proc generateId*(data: Data, content: Content): int =
  if data.ui.componentMapping[content].len > 0:
    var id = 0
    while true:
      if not data.ui.componentMapping[content].hasKey(id):
        return id
      id += 1
  else:
    return 0

proc makeEventLogComponent*(data: Data, id: int, inExtension: bool = false): EventLogComponent =
  var dropDownsInit: array[EventDropDownBox,bool]
  dropDownsInit.fill(false);

  var selectedKinds: array[EventLogKind,bool]
  selectedKinds.fill(true)

  # TODO: Remove hardcode bool value
  if inExtension:
    data.services.eventLog.updatedContent = true

  result = EventLogComponent(
    id: id,
    service: data.services.eventLog,
    traceService: data.services.trace,
    kinds: JsAssoc[EventLogKind, bool]{},
    kindsEnabled: JsAssoc[EventLogKind, bool]{},
    columns: JsAssoc[EventOptionalColumn, bool]{},
    tags: JsAssoc[EventTag, bool]{},
    traceRenderedLength: 0,
    dropDowns: dropDownsInit,
    selectedKinds: selectedKinds,
    denseTable: DataTableComponent(rowHeight: 35, autoScroll: true),
    detailedTable: DataTableComponent(rowHeight: 35, autoScroll: true),
    traceSessionID: -1,
    traceUpdateId: -1,
    lastJumpFireTime: 0,
    inExtension: inExtension,
    drawId: 0,
    started: false,
    isDbBasedTrace: true, #TODO: For now hardcoded needs to be set dynamically to the component
  )
  data.registerComponent(result, Content.EventLog)

proc makeShellComponent*(data: Data, id: int): ShellComponent =
  result = ShellComponent(
    id: id,
    events: JsAssoc[int, JsAssoc[int, SessionEvent]]{},
    eventContainers: JsAssoc[int, kdom.Node]{},
    eventsDoms: JsAssoc[int, kdom.Node]{},
    lineHeight: 17,
    buffer: ShellBuffer(),
    themes: JsAssoc[cstring, ShellTheme]{
      "mac_classic": ShellTheme( background: "white", foreground: "black"),
      "default_white": ShellTheme( background: "#F5F5F5", foreground: "#6e6e6e"),
      "default_black": ShellTheme( background: "#black", foreground: "white"),
      "default_dark": ShellTheme( background: "#1e1f26", foreground: "#8e8f92"),
    }
  )
  data.registerComponent(result, Content.Shell)

proc makeWelcomeScreenComponent*(data: Data): WelcomeScreenComponent =
  result = WelcomeScreenComponent(
    id: data.generateId(Content.WelcomeScreen),
    welcomeScreen: true,
    copyMessageActive: JsAssoc[int, bool]{},
    infoMessageActive: JsAssoc[int, bool]{},
    errorMessageActive: JsAssoc[int, MessageKind]{},
    isUploading: JsAssoc[int, bool]{}
  )
  data.ui.welcomeScreen = result
  data.registerComponent(result, Content.WelcomeScreen)

proc makeStateComponent*(data: Data, id: int, inExtension: bool = false): StateComponent =
  result = StateComponent(
    id: id,
    locals: data.services.debugger.locals,
    values: JsAssoc[cstring, ValueComponent]{},
    completeMoveIndex: 0,
    nameWidth: 40,
    chevronClicked: false,
    minNameWidth: 30,
    maxNameWidth: 85,
    totalValueWidth: 95,
    inExtension: inExtension,
    valueHistory: JsAssoc[cstring, ValueHistory]{},
  )
  data.registerComponent(result, Content.State)

proc makeBuildComponent*(data: Data): BuildComponent =
  result = BuildComponent(
    id: data.generateId(Content.Build),
    service: data.services.debugger,
    expanded: false)
  data.registerComponent(result, Content.Build)

proc makeErrorsComponent*(data: Data): ErrorsComponent =
  result = ErrorsComponent(
    id: data.generateId(Content.BuildErrors),
    service: data.services.debugger,
    expanded: false,
    errors: @[])
  data.registerComponent(result, Content.BuildErrors)


proc makeStatusComponent*(
  data: Data,
  build: BuildComponent,
  errors: ErrorsComponent,
  searchResults: SearchResultsComponent): StatusComponent =

  result = StatusComponent(
    build: build,
    errors: errors,
    maxNotificationsCount: 100,
    activeNotificationDuration: 3_000,
    # searchResults: searchResults -> not yet implemented
    searchResults: searchResults,
    versionControlBranch: cstring"master",
    service: data.services.debugger,
    copyMessageActive: false,
    state: StatusState(
      lastDirection: DebForward,
      currentOperation: cstring"",
      currentHistoryOperation: cstring"",
      finished: false,
      stableBusy: true,
      historyBusy: false,
      traceBusy: false,
      hasStarted: false,
      lastAction: cstring"",
      operationCount: 0,
    ))
  data.ui.status = result
  data.registerComponent(result, Content.Status)


proc makeSearchResultsComponent*(data: Data): SearchResultsComponent =
  result = SearchResultsComponent(
    service: data.services.search)
  data.ui.searchResults = result
  data.registerComponent(result, Content.SearchResults)

proc makeTraceLogComponent*(data: Data, id: int): TraceLogComponent =
  result = TraceLogComponent(
    id: id,
    renderedLength: 0,
    service: data.services.trace,
    table: DataTableComponent(rowHeight: 35, autoScroll: true),
    traceSessionID: -1,
    traceUpdateId: -1)
  data.registerComponent(result, Content.TraceLog)


# lowLevel: enum TODO
proc tabLoad*(self: EditorService, location: types.Location, editorView: EditorView, lang: Lang): Future[TabInfo] {.async.} =
  var name = cstring""
  if not location.isExpanded:
    name = if editorView in {ViewSource, ViewTargetSource}:
        location.path
      elif editorView == ViewCalltrace:
        location.path & cstring":" & location.functionName & cstring"-" & location.key
      else:
        # <path>:<functionName> for the most general case
        cstring(fmt"{location.path}:{location.functionName}")
    if self.open.hasKey(name) and self.open[name].received:
      return self.open[name]

    # self.open[name].index = -2

  else:
    name = location.functionName # using it for expanded-<firstLine>

  if name.isNil:
    cwarn "tabs: tab load name is nil " & $editorView
    return TabInfo()

  cdebug "tabs: tab load " & $name & " " & $editorView & " " & $lang

  # TODO refactor out in smaller functions
  var tabInfo = await self.data.asyncSend("tab-load", js{location: location, name: name, editorView: editorView, lang: lang}, $name, TabInfo)
  # TODO do we need location here
  tabInfo.viewLine = location.line # if tabInfo.fileInfo.isNil or tabInfo.fileInfo.line == -1: -1 else: tabInfo.fileInfo.line
  # if editorView != ViewCalltrace:
  #   tabInfo.index = len(self.open) + len(self.expandedOpen) - 1
  # else:
  #   tabInfo.index = len(self.open) + len(self.expandedOpen)

  proc formatLine(instruction: Instruction): cstring =
    # TODO : address? 10 length?
    cstring(align($instruction.offset, 4, ' ') & " " & alignLeft($instruction.name, 10, ' ') & alignLeft($instruction.args, 10, ' ') & alignLeft($instruction.other, 0, ' '))

  tabInfo.highlightLine = -1
  # tabInfo.fileInfo = if not tabInfo.fileLoaded.isNil: fileLoaded else: FileLoaded(tokens: @[], symbols: JsAssoc[cstring, seq[Symbol]]{}, sourceLines: @[], exe: @[])
  tabInfo.name = name
  if editorView == ViewInstructions:
    tabInfo.sourceLines = tabInfo.instructions.instructions.mapIt(formatLine(it))
    tabInfo.source = tabInfo.sourceLines.join(jsNl) & jsNl

  if not self.data.services.debugger.breakpointTable.hasKey(location.path):
    self.data.services.debugger.breakpointTable[location.path] = JsAssoc[int, UIBreakpoint]{}

  if not location.isExpanded:
    self.open[name] = tabInfo
    # self.data.ui.editors[name].tabInfo = tabInfo
    # if not self.data.ui.editors[name].flow.isNil:
    #   self.data.ui.editors[name].flow.tab = tabInfo

    self.data.redraw()
  return tabInfo

proc makeEditorViewComponent*(
  data: Data,
  id: int,
  path: cstring,
  line: int,
  name: cstring,
  editorView: EditorView,
  isExpansion: bool,
  expandedLocation: types.Location,
  lang: Lang): EditorViewComponent =

  let editorName = if not isExpansion:
      if editorView in {ViewSource, ViewTargetSource}:
        path
      else:
        name
    else:
      name #cstring(&"expanded-{expandedLocation.expansionFirstLine}")
  if data.ui.editors.hasKey(editorName):
    cerror "tabs: " & $editorName & " already exists"
    raise newException(ValueError, &"editor {editorName} exists")
  let parentLine = if not isExpansion: -1 else: expandedLocation.expansionParents[0][1]

  result = EditorViewComponent(
    id: id,
    path: path, # TODO: fix this and .name , maybe use this for actual path, for asm files now this seems == to name, think of something here
    line: line,
    lang: lang,
    name: editorName,
    # lowLevel: lowLevel,
    editorView: editorView,
    tokens: JsAssoc[int, JsAssoc[cstring, int]]{},
    decorations: @[],
    whitespace: Whitespace(character: WhitespaceSpaces, width: 2),
    encoding: cstring"UTF-8",
    lastMouseMoveLine: -1,
    isExpansion: isExpansion,
    parentLine: parentLine,
    traces: JsAssoc[int, TraceComponent]{},
    expanded: JsAssoc[int, EditorViewComponent]{},
    # monacoJsonSchemes: JsAssoc[cstring, js]{},
    service: data.services.editor,
    viewZones: JsAssoc[int, int]{},
    diffViewZones: JsAssoc[int, MultilineZone]{},
    diffEditors: JsAssoc[int, MonacoEditor]{},
    lastScrollFireTime: now())
  if not isExpansion:
    result.topLevelEditor = result
  # else: nil # will be assigned after
  data.ui.editors[editorName] = result
  data.registerComponent(result, Content.EditorView)

proc makeCalltraceComponent*(data: Data, id: int, inExtension: bool = false): CalltraceComponent =
  result = CalltraceComponent(
    id: id,
    searchResults: @[],
    service: data.services.calltrace,
    debugger: data.services.debugger,
    expandedValues: JsAssoc[cstring, CallExpandedValuesComponent]{},
    callLines: @[],
    args: JsAssoc[cstring, seq[CallArg]]{},
    returnValues: JsAssoc[cstring, Value]{},
    lineIndex: JsAssoc[cstring, int]{},
    rawIgnorePatterns: "",
    loadedCallKeys: JsAssoc[cstring, int]{},
    callsByLine: @[],
    forceCollapse: false,
    depthStart: 0,
    coordinates: @[],
    startPositionX: -1,
    startPositionY: -1,
    width: "300",
    callValuePosition: JsAssoc[cstring, float]{},
    inExtension: inExtension,
    config: Config(calltrace: true), #TODO: For now hardcoded
    isDbBasedTrace: true, #TODO: For now hardcoded needs to be set dynamically to the component
  )
  data.registerComponent(result, Content.Calltrace)

proc makeAgentActivityComponent*(data: Data, id: int, inExtension: bool = false): AgentActivityComponent =
  result = AgentActivityComponent(
    id: id,
    shell: ShellComponent(
      id: 0,
      events: JsAssoc[int, JsAssoc[int, SessionEvent]]{},
      eventContainers: JsAssoc[int, kdom.Node]{},
      eventsDoms: JsAssoc[int, kdom.Node]{},
      lineHeight: 18,
      buffer: ShellBuffer(),
      themes: JsAssoc[cstring, ShellTheme]{
        "mac_classic": ShellTheme( background: "white", foreground: "black"),
        "default_white": ShellTheme( background: "#F5F5F5", foreground: "#6e6e6e"),
        "default_black": ShellTheme( background: "#black", foreground: "white"),
        "default_dark": ShellTheme( background: "#1e1f26", foreground: "#8e8f92"),
      }
    ),
    logData: @[
      LogEntry(title: "Analyzing the codebase structure and understanding the project requirements", output: "", status: ""),
      LogEntry(title: "Running cargo check to validate current code", output: "Finished dev [unoptimized + debuginfo] target(s) in 2.34s", status: "success"),
      LogEntry(title: "Modified src/main.rs {+5 -2}", output: "", status: "modified"),
      LogEntry(title: "Considering how to implement the new feature based on the existing patterns", output: "", status: ""),
      LogEntry(title: "Running tests to ensure no regressions", output: "running 5 tests... 5 passed, 0 failed", status: "info"),
      LogEntry(title: "Modified src/lib.rs {+12 -0}", output: "", status: "modified"),
      LogEntry(title: "Formatting code with rustfmt", output: "Format successful", status: "success"),
    ],
    inExtension: inExtension
  )
  data.registerComponent(result, Content.AgentActivity)

proc makeDebugComponent*(data: Data): DebugComponent =
  result = DebugComponent(
    id: data.generateId(Content.Debug),
    message: LogMessage(message: "", level: MsgInfo, time: -1),
    service: data.services.debugger)
  data.registerComponent(result, Content.Debug)

proc makeFilesystemComponent*(data: Data, id: int): FilesystemComponent =
  result = FilesystemComponent(
    id: id,
    service: data.services.editor,
    forceRedraw: true,)
  data.registerComponent(result, Content.Filesystem)

proc makeScratchpadComponent*(data: Data, id: int, inExtension: bool = false): ScratchpadComponent =
  result = ScratchpadComponent(
    id: id,
    service: data.services.debugger,
    inExtension: inExtension,
  )
  data.registerComponent(result, Content.Scratchpad)

func setId*(c: ChartComponent, id: int) =
  c.chartId = id

proc makeChartComponent*(data:Data): ChartComponent =
  result = ChartComponent(
    data: data,
    datasets: @[],
    lineDatasetIndices: JsAssoc[cstring, int]{},
    lineDatasetValues: JsAssoc[cstring, seq[Value]]{},
    expressions: @[],
    pieLabels: @[],
    pieValues: @[])

proc makeTraceComponent*(data: Data, editorUI: EditorViewComponent, name: cstring, line: int): TraceComponent =
  let offset =
    if editorUI.lang == LangAsm:
      editorUI.tabInfo.instructions.instructions[line - 1].offset
    else:
      NO_OFFSET
  let id = data.services.trace.tracePID
  data.services.trace.tracePID += 1

  result = TraceComponent(
    id: id,
    lineCount: 1,
    resultsHeight: 36,
    name: name,
    line: line,
    tracepoint: Tracepoint(
      tracepointId: id,
      mode: TracInlineCode,
      name: name,
      line: line,
      offset: offset,
      lang: editorUI.lang,
      expression: cstring"",
      lastRender: 0,
      results: @[],
      tracepointError: ""),
    chart: makeChartComponent(data),
    editorUI: editorUI,
    service: data.services.trace,
    editorWidth: 50,
    traceHeight: 210,
    dataTable: DataTableComponent(rowHeight: 30, inputFieldChange: false))
  result.chart.setId(data.ui.idMap["chart"])
  data.ui.idMap["chart"] = data.ui.idMap["chart"] + 1
  data.ui.editors[name].traces[line] = result
  data.registerComponent(result, Content.Trace)

proc makeMenuComponent*(data: Data): MenuComponent =
  result = MenuComponent(
    id: data.generateId(Content.Menu),
    elements: MenuData(),
    active: false,
    activePath: @[],
    activePathWidths: JsAssoc[int,int]{},
    activePathOffsets: JsAssoc[int,int]{},
    prepared: @[],
    searchResults: @[],
    nameMap: JsAssoc[cstring, ClientAction]{},
    debug: data.debugComponent,
    service: data.services.editor,
    iconWidth: 24,
    mainMenuWidth: 18,
    folderArrowCharWidth: 2,
    keyNavigation: false)
  data.ui.menu = result
  data.registerComponent(result, Content.Menu)

proc makeReplComponent*(data: Data, id: int): ReplComponent =
  result = ReplComponent(
    id: id,
    service: data.services.debugger,
    history: @[])
  data.registerComponent(result, Content.Repl)

proc makeCalltraceEditorComponent*(data: Data, id: int): CalltraceEditorComponent =
  result = CalltraceEditorComponent(
    id: id,
    loading: JsAssoc[cstring, bool]{},
    service: data.services.editor,
    calltrace: data.services.calltrace)
  data.registerComponent(result, Content.CalltraceEditor)

proc makeTerminalOutputComponent*(data: Data, id: int, inExtension: bool = false): TerminalOutputComponent =
  result = TerminalOutputComponent(
    id: id,
    cachedLines: JsAssoc[int, seq[TerminalEvent]]{},
    cachedEvents: @[],
    lineEventIndices: JsAssoc[int, int]{},
    service: data.services.eventLog,
    initialUpdate: true,
    inExtension: inExtension,
    isDbBasedTrace: true, #TODO: For now hardcoded needs to be set dynamically to the component
  )
  data.registerComponent(result, Content.TerminalOutput)

proc makeCommandPaletteComponent*(data: Data): CommandPaletteComponent =
  result = CommandPaletteComponent(
    id: data.generateId(Content.CommandPalette),
    interpreter: CommandInterpreter(
      data: data,
      commands: JsAssoc[cstring, Command]{},
      files: JsAssoc[cstring, cstring]{}),
    inputValue: cstring(""),
    inputPlaceholder: cstring(""))
  data.ui.commandPalette = result
  data.registerComponent(result, Content.CommandPalette)

proc makeNoSourceComponent*(data: Data, id: int, noInfoMessage: cstring): NoSourceComponent =
  result = NoSourceComponent(
    id: id,
    message: noInfoMessage)
  data.registerComponent(result, Content.NoInfo)

proc makeLowLevelCodeComponent*(data: Data, id: int): LowLevelCodeComponent =
  let location = data.services.debugger.location
  let name = location.path

  result = LowLevelCodeComponent(
    id: id,
    viewZones: JsAssoc[int, int]{},
    multilineZones: JsAssoc[int, MultilineZone]{},
    viewDom: JsAssoc[int, kdom.Node]{},
    instructionsMapping: JsAssoc[int, int]{},
    path: name,
    editor: EditorViewComponent(
      id: data.generateId(Content.EditorView),
      path: name,
      data: data,
      lang: LangAsm,
      name: name,
      editorView: ViewLowLevelCode,
      tokens: JsAssoc[int, JsAssoc[cstring, int]]{},
      decorations: @[],
      whitespace: Whitespace(character: WhitespaceSpaces, width: 2),
      encoding: cstring"UTF-8",
      lastMouseMoveLine: -1,
      traces: JsAssoc[int, TraceComponent]{},
      expanded: JsAssoc[int, EditorViewComponent]{},
      service: data.services.editor,
      viewZones: JsAssoc[int, int]{}
    )
  )

  data.registerComponent(result, Content.LowLevelCode)

proc openLowLevelCode*(data: Data) =
  if data.ui.componentMapping[Content.LowLevelCode].len() > 0:
    data.redraw()
  else:
    var lowLevelComponent = data.makeLowLevelCodeComponent(data.generateId(Content.LowLevelCode))
    data.openLayoutTab(Content.LowLevelCode, lowLevelComponent.id)

proc makeStepListComponent*(data: Data, id: int): StepListComponent =
  result = StepListComponent(
    id: id,
    lineSteps: @[],
    # startStepLineIndex: 0,
    # totalStepsCount: 0,
    # lastScrollFireTime: 0,
    service: data.services.flow)
  data.registerComponent(result, Content.StepList)

data.ui = Components(
  editors: JsAssoc[cstring, EditorViewComponent]{},
  idMap: JsAssoc[cstring, int]{value: 0, chart: 0},
  layoutSizes: LayoutSizes(startSize: true),
  monacoEditors: @[],
  traceMonacoEditors: @[],
  fontSize: 15)
  # mode: CalltraceMode)

for content in Content:
  data.ui.componentMapping[content] = JsAssoc[int, Component]{}
  data.ui.openComponentIds[content] = @[]

proc makeComponent*(data: Data, content: Content, id: int, path: cstring = "", noInfoMessage: cstring = ""): Component =
  case content:
  # singletons
  of Content.Debug:           data.makeDebugComponent()
  of Content.Build:           data.makeBuildComponent()
  of Content.BuildErrors:     data.makeErrorsComponent()
  of Content.Status:          data.makeStatusComponent(
    data.buildComponent(0), data.errorsComponent(0), data.ui.searchResults) # TODO: fix components id
  of Content.SearchResults:   data.makeSearchResultsComponent()
  of Content.Menu:            data.makeMenuComponent()
  of Content.WelcomeScreen:   data.makeWelcomeScreenComponent()
  of Content.CommandPalette:  data.makeCommandPaletteComponent()
  of Content.NoInfo:          data.makeNoSourceComponent(id, noInfoMessage)
  of Content.EditorView:      data.makeEditorViewComponent(
    id, path, 1, "", EditorView.ViewSource, false, types.Location(), fromPath(path))
  # non-singleton
  of Content.EventLog:        data.makeEventLogComponent(id)
  of Content.State:           data.makeStateComponent(id)
  of Content.Calltrace:       data.makeCalltraceComponent(id)
  of Content.Filesystem:      data.makeFilesystemComponent(id)
  of Content.Scratchpad:      data.makeScratchpadComponent(id)
  of Content.Repl:            data.makeReplComponent(id)
  of Content.TraceLog:        data.makeTraceLogComponent(id)
  of Content.CalltraceEditor: data.makeCalltraceEditorComponent(id)
  of Content.TerminalOutput:  data.makeTerminalOutputComponent(id)
  of Content.Shell:           data.makeShellComponent(id)
  of Content.StepList:        data.makeStepListComponent(id)
  of Content.LowLevelCode:    data.makeLowLevelCodeComponent(id)
  of Content.AgentActivity:   data.makeAgentActivityComponent(id)
  # of Content.PointList:       data.makePointListComponent()
  else:
    raise newException(ValueError, &"Could not create a component. Unexpected content {content} type was given.")

data.services.eventLog.data = data
data.services.debugger.data = data
data.services.editor.data = data
data.services.calltrace.data = data
data.services.history.data = data
data.services.flow.data = data
data.services.eventLog.debugger = data.services.debugger
data.services.search.data = data
data.keyPlugins[Content.EditorView] = JsAssoc[cstring, proc(context: KeyPluginContext): Future[void]]{}

data.asyncSendCache = JsAssoc[cstring, JsAssoc[cstring, Future[JsObject]]]{}

# example - if it is an event log component content will be set to 8 which coresponds to Content enumeration in types.nim
proc openPanel*(
  data: Data,
  content: Content,
  componentId: int,
  parent: GoldenContentItem,
  label: cstring,
  isEditor: bool,
  editorView: EditorView = ViewSource,
  noInfoMessage: cstring): GoldenContentItem =
  # works for non-viewer tabs, TODO?
  # cdebug "tabs: openPanel " & label & " " & $content & " " & $editorView

  let componentName = if isEditor: cstring"editorComponent" else: cstring"genericUiComponent"

  var itemConfig = GoldenLayoutConfig(
    `type`: cstring"component",
    componentName: componentName,
    componentState: GoldenItemState(
      id: componentId,
      label: label,
      content: content,
      fullPath: label,
      name: label,
      editorView: editorView,
      isEditor: content in {Content.EditorView},
      noInfoMessage: noInfoMessage
    )
  )

  var contentItem: GoldenContentItem

  try:
    let index =
      if parent.contentItems.len == 0:
        0
      else:
        parent.contentItems.len

    let resolvedConfig = data.ui.contentItemConfig.resolve(itemConfig)
    contentItem = data.ui.layout.createAndInitContentItem(resolvedConfig, parent)
    discard parent.addChild(contentItem, index)
  except:
    cerror "tabs: panel: " & getCurrentExceptionMsg()
    raise newException(CatchableError, "Not able to add a new panel")

  return contentItem

proc convertComponentLabel*(content: Content, id: int): cstring =
  cstring(&"{($content)[0].toLowerAscii()}{($content).substr(1)}Component-{id}")

proc openNewLayoutContainer*(data: Data, itemType: cstring, isEditor: bool = false): GoldenContentItem =
  var index: int

  let parent = data.ui.layout.groundItem
                             .contentItems[0]

  if isEditor:
    index = 1
  else:
    index += parent.contentItems.len

  let config = GoldenLayoutConfig(
    `type`: itemType,
    content: @[]
  )

  let resolvedConfig = data.ui.contentItemConfig.resolve(config)

  let contentItem = data.ui.layout.createAndInitContentItem(resolvedConfig, parent)

  discard parent.addChild(contentItem, index)

  return cast[GoldenContentItem](data.ui.layout.groundItem
                                               .contentItems[0]
                                               .contentItems[index])

proc removeEditorFromClosedTabs*(data: Data, path: cstring) =
  let editorService = data.services.editor

  if editorService.closedTabs.len == 0:
    return

  var editorPathIndex = -1
  for i, tab in editorService.closedTabs:
    if tab.name == path:
      editorPathIndex = i
      break

  if editorPathIndex != -1:
    editorService.closedTabs.delete(editorPathIndex)

proc removeEditorFromLoading*(data: Data, path: cstring) =
  let editorService = data.services.editor

  if editorService.loading.len == 0:
    return

  let editorPathIndex = editorService.loading.find(path)

  if editorPathIndex != -1:
    editorService.loading.delete(editorPathIndex)

proc openLayoutTab*(
  data: Data,
  content: Content,
  id: int = -1,
  isEditor: bool = false,
  path: cstring = "",
  editorView: EditorView = ViewSource,
  noInfoMessage: cstring = "") =

  var parent: GoldenContentItem
  let similarComponents = data.ui.componentMapping[content]
  let openSimilarComponentsTabs = data.ui.openComponentIds[content]

  if content != Content.EditorView and
    data.ui.componentMapping[content].len() > 0 and
    not data.ui.componentMapping[content][0].layoutItem.isNil and
    not data.ui.componentMapping[content].toJs[0].isUndefined:
      data.ui.componentMapping[content][0].
        layoutItem.parent.setActiveContentItem(
          data.ui.componentMapping[content][0].layoutItem)
      return

  if similarComponents.len > 0 and openSimilarComponentsTabs.len > 0 and
    not similarComponents[openSimilarComponentsTabs[^1]].isNil and not similarComponents[openSimilarComponentsTabs[^1]].layoutItem.isNil:
      let lastComponentIndex = openSimilarComponentsTabs[^1]
      let lastComponent = similarComponents[lastComponentIndex]
      parent = cast[GoldenContentItem](lastComponent.layoutItem.parent)

  else:
    if (content == Content.EditorView or content == Content.NoInfo) and
      not data.ui.editorPanels[EditorView.ViewSource].isNil:
      parent = cast[GoldenContentItem](data.ui.editorPanels[EditorView.ViewSource])
    else:
      parent = data.openNewLayoutContainer(cstring"stack", isEditor)
      if content == Content.EditorView:
        data.ui.editorPanels[EditorView.ViewSource] = parent

  var newComponent =
    if not (isEditor and data.ui.editors.hasKey(path)):
      var newId =
        if id != -1:
          id
        else:
          data.generateId(content)

      data.makeComponent(content, newId, path)
    else:
      data.ui.editors[path]

  if content == Content.NoInfo:
    # (written by Alexander: sorry)
    cast[NoSourceComponent](newComponent).message = noInfoMessage

  var label: cstring

  if content == Content.EditorView:
    label = path
  else:
    label = convertComponentLabel(content, newComponent.id)

  try:
    discard data.openPanel(content, newComponent.id, parent, label, isEditor = isEditor, editorView = editorView, noInfoMessage = noInfoMessage)
  except CatchableError:
    cerror "tabs: open panel: " & $getCurrentExceptionMsg()

proc openNoSourceView*(data: Data, name: cstring, noInfoMessage: cstring) =
  # should be usually a singleton-like no info page,
  # as we should usually pass always "NO SOURCE" as a name
  # so if one is open, we should just reopen the same tab earlier
  # .. however we do update the info with noInfoMessage
  # but this should be ok enough for early usage
  cdebug "editor: openNoSourceView"
  let tabInfo = TabInfo(
    name: name,
    loading: false,
    noInfo: true,
    lang: LangUnknown)

  data.services.editor.open[name] = tabInfo
  data.removeEditorFromClosedTabs(name)
  data.removeEditorFromLoading(name)

  var editorComponent = data.makeEditorViewComponent(
    data.generateId(Content.EditorView),
    name,
    1,
    name,
    ViewNoSource,
    false,
    types.Location(missingPath: true),
    LangUnknown)
  editorComponent.tabInfo = tabInfo
  editorComponent.noInfo = data.makeNoSourceComponent(data.generateId(Content.NoInfo), noInfoMessage)
  cdebug "editor: openNoSourceView: openLayoutTab"
  data.openLayoutTab(Content.EditorView, isEditor = true, path = name, editorView = ViewNoSource)
  cdebug "editor: openNoSourceView: active = " & $name
  data.services.editor.active = name


proc makeEditorView*(
    data: Data,
    name: cstring,
    content: cstring,
    editorView: EditorView,
    lang: Lang
) =
  cdebug "editor: make editor view: " & $name & " " & $editorView
  let tabInfo = TabInfo(
    name: name,
    lang: lang,
    viewLine: 1,
    highlightLine: NO_LINE,
    loading: false,
    # maybe rename? to ready?
    received: true,
    location: types.Location(
      path: cstring"",
      line: 1,
      highLevelPath: cstring"",
      highLevelLine: 1,
      functionName: cstring"",
      missingPath: true),
    source: content,
    sourceLines: content.split(jsNl),
    path: name
  )

  data.removeEditorFromClosedTabs(name)
  data.removeEditorFromLoading(name)

  data.makeEditorViewDetailed(
    name,
    editorView,
    tabInfo,
    tabInfo.location
  )
  var editorComponent = data.makeEditorViewComponent(
    data.generateId(Content.EditorView),
    name,
    1,
    name,
    editorView,
    false,
    tabInfo.location,
    lang)
  editorComponent.tabInfo = tabInfo

  cdebug "editor: make editor view: open layout tab"
  data.openLayoutTab(Content.EditorView, isEditor = true, path = name, editorView = editorView)
  cdebug "editor: make editor view: active = " & $name
  data.services.editor.active = name

proc focusLine(editor: EditorViewComponent, line: int) =
  editor.monacoEditor.revealLineInCenter(line)
  editor.monacoEditor.setPosition(MonacoPosition(lineNumber: line, column: 0))
  editor.monacoEditor.focus()

proc openNewEditorView*(
    data: Data,
    name: cstring,
    editorView: EditorView,
    noInfoMessage: cstring = cstring"",
    line:int = NO_LINE) {.async.} =
  if name == "NO SOURCE" or editorView == ViewNoSource:
    data.openNoSourceView(name, noInfoMessage)
    return
  elif not data.services.editor.open.hasKey(name):
    data.services.editor.open[name] = TabInfo(loading: true)
    data.removeEditorFromClosedTabs(name)
    data.removeEditorFromLoading(name)

    var location: types.Location
    var lang: Lang
    if editorView in {ViewSource, ViewTargetSource}:
      location = types.Location(
        path: name,
        line: NO_LINE,
        highLevelPath: name,
        highLevelLine: NO_LINE,
        functionName: cstring"")
      lang = LangUnknown
    elif editorView == ViewInstructions:
      let tokens = ($name).split(":", 1)
      # cdebug "editor: tokens: " & $tokens
      let (path, functionName) = (cstring(tokens[0]), cstring(tokens[1]))
      location = types.Location(
        path: path,
        line: NO_LINE,
        highLevelPath: name,
        highLevelLine: NO_LINE,
        functionName: functionName
      )
      lang = LangAsm
    else:
      cwarn "editor: such a view not currently supported: " & $editorView
      return
    cdebug "editor: openNewEditorView location: " & $location
    var tabInfo = await data.services.editor.tabLoad(location, editorView, lang)
    tabInfo.lang = if lang != LangAsm: toLangFromFilename(location.path) else: lang
    # try:
    #   cdebug "editor: tabInfo received " & $(tabInfo[])
    # except:
    #   cwarn $tabInfo
    #   cerror "editor: tabInfo print: " & getCurrentExceptionMsg()

    data.makeEditorViewDetailed(
      name,
      editorView,
      tabInfo,
      location
    )

    if line != NO_LINE:
      proc cb =
        if isNull(data.ui.editors[name].monacoEditor):
          discard setTimeout(cb, 10)
        else:
          data.ui.editors[name].focusLine(line)

      discard setTimeout(cb, 10)

proc makeEditorViewDetailed(
    data: Data,
    name: cstring,
    editorView: EditorView,
    tabInfo: TabInfo,
    location: types.Location
) =
  data.services.editor.open[name] = tabInfo
  var editorComponent = data.makeEditorViewComponent(
    data.generateId(Content.EditorView),
    name,
    1,
    name,
    editorView,
    false,
    location,
    tabInfo.lang)
  editorComponent.tabInfo = tabInfo
  # if not self.data.ui.editors[name].flow.isNil:
    # self.data.ui.editors[name].flow.tab = tabInfo
  cdebug "editor: openLayoutTab.."
  data.openLayoutTab(Content.EditorView, isEditor = true, path = name, editorView = editorView)
  cdebug "editor: after open layout tab, active = " & $name
  data.services.editor.active = name

proc showTab*(data: Data, tab: cstring, noInfoMessage: cstring = cstring"", line: int = NO_LINE) =
  if tab.isNil:
    cerror "tabs: tab is nil in showTab"
    return
  if not data.ui.editors.hasKey(tab):
     # not data.ui.lowLevels.hasKey(tab):
    cerror "tabs: no editor in showTab for " & $tab
    return

  var contentItem: GoldenContentItem

  if data.ui.editors.hasKey(tab):
    var editor: EditorViewComponent
    if not data.ui.editors[tab].layoutItem.isNil:
      editor = data.ui.editors[tab]
    else:
      editor = data.ui.editors[tab].topLevelEditor

    if editor.isNil:
      cwarn "editor is nil in showTab " & $tab
      return

    if editor.layoutItem.isNil:
      cwarn "editor.layoutItem is nil in showTab " & $tab
      return
    contentItem = editor.layoutItem
    if not editor.noInfo.isNil:
      editor.noInfo.message = noInfoMessage

    if line != -1:
      editor.focusLine(line)

    # else:
    #   # TODO expansions in low level editors?
    #   var editor: LLViewComponent
    #   if not data.ui.lowLevels[tab].contentItem.isNil:
    #     editor = data.ui.lowLevels[tab]
    #   else:
    #     editor = nil

    #   if editor.isNil:
    #     cwarn "editor is nil in showTab ", tab
    #     return

    #   if editor.contentItem.isNil:
    #     cwarn "editor.contentItem is nil in showTab ", tab
    #     return
    #   contentItem = editor.contentItem
  else:
    cwarn "no editor for " & $tab
    return

  assert not contentItem.isNil

  if not contentItem.parent.isNil and contentItem.parent.isStack:
    # TODO: bug sometimes here
    contentItem.parent.toJs.setActiveContentItem(contentItem)
  else:
    contentItem.container.show()

# a function for opening various kinds of editor viewer tabs:
#   the `name` here is relatively generic:
#   it can mean:
#     a path usually, for files/sources
#     a name/path:name combination for functions/low level or asm views
#     a special name for no info/no location cases
#    eventually others
#   the `editorView` is about the editor-specific content: source/target source/instructions/ast or others
#   lang is .. not used for now actually
proc openTab*(
    data: Data,
    name: cstring,
    editorView: EditorView = EditorView.ViewSource,
    noInfoMessage: cstring = cstring"",
    line: int = NO_LINE) = #  lang: Lang = LangUnknown) =
  cdebug "editor: openTab: " & $name & " " & $editorView
  # let tabName = if name != "unknown": name else: "NO SOURCE"
  # singleton no info page?
  if not data.services.editor.open.hasKey(name):
    discard data.openNewEditorView(name, editorView, noInfoMessage=noInfoMessage, line=line)
  elif not data.services.editor.open[name].loading:
    data.showTab(name, noInfoMessage=noInfoMessage, line=line)
  # TODO: For now comment out and find a workaround later on
  # Issue is with recursion imports with event_helpers(communication.nim)
  # else:
  #   data.viewsApi.showNotification(
  #     newNotification(NotificationInfo, fmt"{name} already loading"))

  # let id = if level == 0 or level == 1: path else: cstring(fmt"low:{path}:{functionName}")
  # if level == 0 and not data.services.editor.open.hasKey(p) or level > 0:
  #   data.services.editor.loading[id] = (path, functionName, level)
  # elif data.services.editor.open.hasKey(id):
  #   data.showTab(id)

proc refreshEditorLine*(self: EditorViewComponent, line: int) =
  # moved here from ui/editor, so it can be used from here
  cdebug "editor: refreshEditorLine " & $line
  var editor = self.monacoEditor
  var zone = 0
  editor.changeViewZones do (view: js):
    zone = cast[int](view.addZone(js{afterLineNumber: line, heightInLines: 0, domNode: kdom.document.createElement(cstring"div")}))
  editor.changeViewZones do (view: js):
    view.removeZone(zone)
  # refresh editor

