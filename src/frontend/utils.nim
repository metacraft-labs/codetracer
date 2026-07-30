import
  async, strutils, strformat, sequtils, algorithm, jsffi, jsconsole,
  kdom, dom,
  types, lang,
  lib / [ logging, monaco_lib, jslib ],
  ui / auto_hide

proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}

const
  VALUE_COMPONENT_NAME_WIDTH*: float = 40.0
  VALUE_COMPONENT_VALUE_WIDTH*: float = 55.0
  SVG_NAMESPACE            = cstring"http://www.w3.org/2000/svg"

proc monacoLineNumbersMinChars*(lineCount: int): int =
  ## Reserve enough width for the largest line number currently visible in the
  ## editor model. We keep one extra character because the custom HTML gutter
  ## adds internal padding before the right-aligned text.
  max(4, ($max(1, lineCount)).len + 2)

proc monacoLineDecorationsWidth*(fontSize: int): int =
  ## Reserve only the custom marker lane and the folding chevron lane.
  ## The line-number column width is controlled separately via
  ## `lineNumbersMinChars`.
  let markerLane = (fontSize * 9) div 5
  let foldingLane = fontSize div 2
  max(20, markerLane + foldingLane)

proc renderLineElement*(x1, y1, x2, y2: float): dom.Element =
  result = dom.createElementNS(dom.document, SVG_NAMESPACE, cstring"line")
  result.setAttribute(cstring"x1", cstring($x1))
  result.setAttribute(cstring"y1", cstring($y1))
  result.setAttribute(cstring"x2", cstring($x2))
  result.setAttribute(cstring"y2", cstring($y2))
  result.setAttribute(cstring"stroke-width", cstring"0.5")

proc lineCountForGutter*(content: cstring): int =
  ## Count logical lines for gutter sizing from Monaco-facing cstring content.
  ($content).splitLines().len

const DEFAULT_SESSION_ID* = 0
  ## The session id used when there is only one replay session (M8 default).

proc sendWithSession*(data: Data, channel: cstring, msg: JsObject) =
  ## Send an IPC message with the active session's id attached.
  ## This is the renderer-side helper introduced in M8 (session-scoped IPC).
  ## Callers that already build a JsObject payload can use this instead of
  ## ``data.ipc.send`` to ensure the message is routable once multiple
  ## sessions exist.
  msg["sessionId"] = data.activeSessionIndex
  data.ipc.send(channel, msg)

proc sendWithSession*(data: Data, channel: cstring) =
  ## Overload for messages that carry no payload beyond the session id.
  let msg = js{}
  msg["sessionId"] = data.activeSessionIndex
  data.ipc.send(channel, msg)

proc getSessionIdFromMessage*(raw: JsObject): int =
  ## Extract the sessionId from an incoming IPC message.
  ## Returns ``DEFAULT_SESSION_ID`` when the field is absent, which keeps
  ## backward compatibility during M8 (single session).
  if jsHasKey(raw, cstring"sessionId"):
    return raw["sessionId"].to(int)
  return DEFAULT_SESSION_ID

proc connectionLossMessage*(reason: ConnectionLossReason): cstring =
  ## Human-readable message describing why the connection is inactive.
  case reason:
  of ConnectionLossIdleTimeout:
    cstring"Host timed out after inactivity."
  of ConnectionLossSuperseded:
    cstring"Another browser tab took over the connection."
  else:
    cstring"Lost connection to the host."

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
    dropdownOutsideHandlerInstalled: false,
    selectedKinds: selectedKinds,
    denseTable: DataTableComponent(rowHeight: 35, autoScroll: true),
    detailedTable: DataTableComponent(rowHeight: 35, autoScroll: true),
    traceSessionID: -1,
    traceUpdateId: -1,
    lastJumpFireTime: 0,
    inExtension: inExtension,
    drawId: 0,
    started: false,
    liveDebugRows: @[],
    usesMaterializedTracesTrace: true, #TODO: For now hardcoded needs to be set dynamically to the component
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
    isUploading: JsAssoc[cstring, bool]{}
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
    errors: @[],
    filter: FilterAll,
    groupByFile: false)
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


proc canonicalSourceRevisionPath*(path: cstring): cstring =
  if path.isNil or path.len == 0:
    return cstring""
  let pathText = $path
  if pathText.startsWith("/private/var/"):
    return cstring(pathText.substr("/private".len))
  path

proc sameSourceRevisionPath*(left, right: cstring): bool =
  let canonicalLeft = canonicalSourceRevisionPath(left)
  let canonicalRight = canonicalSourceRevisionPath(right)
  canonicalLeft.len > 0 and canonicalRight.len > 0 and
    canonicalLeft == canonicalRight

proc sourceRevisionHasIdentity*(location: types.Location): bool =
  location.sourceGeneration != 0 or
    (not location.sourceDigest.isNil and location.sourceDigest.len > 0) or
    (not location.path.isNil and location.path.len > 0 and location.line > 0)

proc editorTabPath*(path: cstring; editorView: EditorView): cstring =
  if editorView in {ViewSource, ViewTargetSource}:
    canonicalSourceRevisionPath(path)
  else:
    path

proc sourceRevisionPath*(location: types.Location): cstring =
  ## User-facing source identity prefers the high-level path when sourcemaps
  ## are present, and otherwise falls back to the debugger path.
  let path = if not location.highLevelPath.isNil and location.highLevelPath.len > 0:
    location.highLevelPath
  else:
    location.path
  canonicalSourceRevisionPath(path)

proc sourceRevisionKey*(location: types.Location): cstring =
  if not sourceRevisionHasIdentity(location):
    return cstring""
  let path = sourceRevisionPath(location)
  if path.isNil or path.len == 0:
    return cstring""
  let digest =
    if location.sourceDigest.isNil:
      cstring""
    else:
      location.sourceDigest
  cstring($path & "\n" & $location.sourceGeneration & "\n" &
          $digest)

proc cacheSourceRevision*(self: EditorService; location: types.Location;
                          source: cstring) =
  if source.isNil:
    return
  let key = sourceRevisionKey(location)
  if key.len > 0:
    self.sourceRevisionCache[key] = source

proc hasSourceRevision*(self: EditorService; location: types.Location): bool =
  let key = sourceRevisionKey(location)
  key.len > 0 and self.sourceRevisionCache.hasKey(key)

proc sourceRevisionSource*(self: EditorService; location: types.Location): cstring =
  let key = sourceRevisionKey(location)
  if key.len > 0 and self.sourceRevisionCache.hasKey(key):
    self.sourceRevisionCache[key]
  else:
    cstring""

# lowLevel: enum TODO
proc tabLoad*(self: EditorService, location: types.Location, editorView: EditorView, lang: Lang, forceReload: bool = false): Future[TabInfo] {.async.} =
  var name = cstring""
  if not location.isExpanded:
    name = if editorView in {ViewSource, ViewTargetSource}:
        sourceRevisionPath(location)
      elif editorView == ViewCalltrace:
        location.path & cstring":" & location.functionName & cstring"-" & location.key
      else:
        # <path>:<functionName> for the most general case
        cstring(fmt"{location.path}:{location.functionName}")
    if not forceReload and self.open.hasKey(name) and self.open[name].received:
      return self.open[name]

    # self.open[name].index = -2

  else:
    name = location.functionName # using it for expanded-<firstLine>

  if name.isNil:
    cwarn "tabs: tab load name is nil " & $editorView
    return TabInfo()

  cdebug "tabs: tab load " & $name & " " & $editorView & " " & $lang

  # TODO refactor out in smaller functions
  var tabInfo = await self.data.asyncSend(
    "tab-load",
    js{location: location, name: name, editorView: editorView, lang: lang},
    $name,
    TabInfo,
    noCache = forceReload)
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
  if editorView in {ViewSource, ViewTargetSource}:
    tabInfo.path = name
    tabInfo.location.path = canonicalSourceRevisionPath(tabInfo.location.path)
    tabInfo.location.highLevelPath = canonicalSourceRevisionPath(tabInfo.location.highLevelPath)
  if editorView == ViewInstructions:
    tabInfo.sourceLines = tabInfo.instructions.instructions.mapIt(formatLine(it))
    tabInfo.source = tabInfo.sourceLines.join(jsNl) & jsNl
  if self.hasSourceRevision(location):
    tabInfo.source = self.sourceRevisionSource(location)
    tabInfo.sourceLines = tabInfo.source.split(jsNl)
  else:
    self.cacheSourceRevision(location, tabInfo.source)
  if tabInfo.lastSyncedSource.isNil:
    tabInfo.lastSyncedSource = tabInfo.source

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

  let canonicalPath = editorTabPath(path, editorView)
  let editorName = if not isExpansion:
      if editorView in {ViewSource, ViewTargetSource}:
        canonicalPath
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
    path: canonicalPath, # TODO: fix this and .name , maybe use this for actual path, for asm files now this seems == to name, think of something here
    line: line,
    lang: lang,
    name: editorName,
    # lowLevel: lowLevel,
    editorView: editorView,
    testDom: JsAssoc[int, kdom.Node]{},
    testLines: JsAssoc[int, FlowLine]{},
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
    usesMaterializedTracesTrace: true, #TODO: For now hardcoded needs to be set dynamically to the component
    asyncFlowMode: afmReal,
    continuationLinks: @[],
    asyncThreads: @[],
    continuationsByCallKey: JsAssoc[cstring, ContinuationLinkInfo]{},
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
    inExtension: inExtension,
    expandControl: @[],
    # messages: JsAssoc[cstring, AgentMessage]{},
    messageOrder: @[],
    terminals: JsAssoc[cstring, AgentTerminal]{},
    terminalOrder: @[],
    sessionId: cstring"",
    pendingSessionId: cstring(fmt"agent-session-{id}"),
    pendingPrompts: @[],
    promptInFlight: false,
    messageBuffers: JsAssoc[cstring, cstring]{},
    sessionMessageIds: JsAssoc[cstring, seq[AgentMessage]]{},
    diffEditors: JsAssoc[cstring, DiffEditor]{},
    workspaceDir: cstring"",
    acpInitSent: false,
    acpInitFailed: false,
    activeAgentMessageId: cstring""
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

proc makeVCSComponent*(data: Data, id: int): VCSComponent =
  result = VCSComponent(
    id: id,
    diffTarget: cstring"",
    currentBranch: cstring"",
    branches: @[],
    commits: @[],
    changedFiles: @[],
    selectedCommitIndices: @[],
    lastClickedCommitIndex: -1,
    branchDropdownOpen: false,
    initialized: false,
    isGitRepo: false,
    errorMessage: cstring"")
  data.registerComponent(result, Content.VCS)

proc makeScratchpadComponent*(data: Data, id: int, inExtension: bool = false): ScratchpadComponent =
  result = ScratchpadComponent(
    id: id,
    service: data.services.debugger,
    inExtension: inExtension,
  )
  data.registerComponent(result, Content.Scratchpad)

proc makeTimelineComponent*(data: Data, id: int): TimelineComponent =
  result = TimelineComponent(
    id: id,
    active: TimelineVariables,
    service: data.services.flow,
  )
  data.registerComponent(result, Content.Timeline)

proc makeRequestPanelComponent*(data: Data, id: int, inExtension: bool = false): RequestPanelComponent =
  result = RequestPanelComponent(
    id: id,
    inExtension: inExtension,
    panelState: RequestPanelState(
      requests: @[],
      selectedIndex: -1,
      filterMethod: cstring"",
      filterStatus: cstring"",
      searchText: cstring"",
    ),
  )
  data.registerComponent(result, Content.RequestPanel)

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

proc makeFlowComponent*(data: Data, position: int, inExtension: bool = false): FlowComponent =
  FlowComponent(
    # api: self.api,
    # id: self.id,
    flow: nil,
    # tab: self.tabInfo,
    # location: location,
    inExtension: inExtension,
    multilineZones: JsAssoc[int, MultilineZone]{},
    flowDom: JsAssoc[int, kdom.Node]{},
    shouldRecalcFlow: false,
    flowLoops: JsAssoc[int, FlowLoop]{},
    flowLines: JsAssoc[int, FlowLine]{},
    activeStep: FlowStep(rrTicks: -1),
    selectedLine: -1,
    selectedLineInGroup: -1,
    selectedStepCount: -1,
    lineHeight: 20,
    # multilineFlowLines: multilineFlowLines(),
    multilineValuesDoms: JsAssoc[int, JsAssoc[cstring, kdom.Node]]{},
    loopLineSteps: JsAssoc[int, int]{},
    inlineDecorations: JsAssoc[int, InlineDecorations]{},
    # editorUI: self,
    # scratchpadUI: if self.data.ui.componentMapping[Content.Scratchpad].len > 0: self.data.scratchpadComponent(0) else: nil,
    # editor: self.service,
    # service: self.data.services.flow,
    # data: self.data,
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
    modalValueComponent: JsAssoc[cstring, ValueComponent]{},
    valueMode: BeforeValueMode,
    position: position
  )

proc makeTraceComponent*(data: Data, editorUI: EditorViewComponent = nil, name: cstring = "", line: int = 0, inExtension: bool = false, traceId: int = 0): TraceComponent = # editorUI: EditorViewComponent, name: cstring,
  # let offset =
  #   if editorUI.lang == LangAsm:
  #     editorUI.tabInfo.instructions.instructions[line - 1].offset
  #   else:
  #     NO_OFFSET
  # let traceId = 0 # data.services.trace.tracePID

  let id = if inExtension: traceId else: data.services.trace.tracePID
  if not inExtension:
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
      # offset: offset,
      # lang: editorUI.lang, # TODO: Fix this after extension implementation
      expression: "",
      lastRender: 0,
      results: @[],
      tracepointError: ""),
    chart: makeChartComponent(data),
    editorUI: editorUI,
    service: data.services.trace,
    editorWidth: 50,
    traceHeight: 210,
    inExtension: inExtension,
    dataTable: DataTableComponent(rowHeight: 30, inputFieldChange: false))

  if not inExtension:
    result.chart.setId(data.ui.idMap["chart"])
    data.ui.idMap["chart"] = data.ui.idMap["chart"] + 1
    data.ui.editors[name].traces[line] = result
  else:
    result.chart.setId(id)
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
    searchQuery: cstring"",
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
    usesMaterializedTracesTrace: true, #TODO: For now hardcoded needs to be set dynamically to the component
  )
  data.registerComponent(result, Content.TerminalOutput)

proc makeCommandPaletteComponent*(data: Data): CommandPaletteComponent =
  result = CommandPaletteComponent(
    id: data.generateId(Content.CommandPalette),
    interpreter: CommandInterpreter(
      data: data,
      commands: JsAssoc[cstring, Command]{},
      commandsPrepared: @[],
      files: JsAssoc[cstring, cstring]{},
      filesPrepared: @[],
      symbols: JsAssoc[cstring, seq[Symbol]]{},
      symbolsPrepared: @[]),
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

proc makeDeepReviewComponent*(data: Data, id: int): DeepReviewComponent =
  ## Create a new DeepReviewComponent.
  ## The component is populated from ``data.startOptions.deepReview``.
  ## When ``data.deepReviewActive`` is set (i.e. the standard GL layout
  ## is used with separate filesystem/calltrace panels), the component
  ## is marked as ``glEmbedded`` and defaults to Unified diff view so
  ## it renders only the unified diff without duplicate sidebars.
  let embedded = data.deepReviewActive
  result = DeepReviewComponent(
    id: id,
    drData: data.startOptions.deepReview,
    selectedFileIndex: 0,
    selectedExecutionIndex: 0,
    selectedIteration: 0,
    editorInitialized: false,
    currentDecorationIds: jsNull,
    decorationCollection: jsNull,
    fileContentCache: JsAssoc[cstring, cstring]{},
    glEmbedded: embedded,
    viewMode: if embedded: Unified else: FullFiles
  )
  data.registerComponent(result, Content.DeepReview)

proc makeAgentWorkspaceComponent*(data: Data, id: int): AgentWorkspaceComponent =
  ## Create a new AgentWorkspaceComponent.
  ## The component starts with an empty file list and waits for DeepReview
  ## notifications from the agent runtime to populate the workspace view.
  result = AgentWorkspaceComponent(
    id: id,
    viewState: WorkspaceViewState(
      activeView: AgentWorkspace,
      agentWorkspacePath: cstring"",
      agentSessionId: cstring""
    ),
    progress: AgentProgress(
      state: AgentIdle,
      taskName: cstring"",
      milestonesCompleted: 0,
      milestonesTotal: 0,
      currentMilestone: cstring"",
      milestones: @[]
    ),
    drSummary: ActivityDeepReviewSummary(
      totalLinesCovered: 0,
      totalLinesUncovered: 0,
      coveragePercent: 0.0,
      testsRun: 0,
      testsPassed: 0,
      testsFailed: 0,
      functionsTraced: 0,
      lastUpdatedMs: 0
    ),
    fileEntries: @[],
    selectedFileIndex: 0,
    editorInitialized: false,
    currentDecorationIds: jsNull,
    notifications: @[],
    coverageOverlayEnabled: true
  )
  data.registerComponent(result, Content.AgentWorkspace)

proc makeCaptionBarProgressComponent*(data: Data, id: int): CaptionBarProgressComponent =
  ## Create a new CaptionBarProgressComponent.
  ## Starts in the idle state until the agent runtime sends progress updates.
  result = CaptionBarProgressComponent(
    id: id,
    progress: AgentProgress(
      state: AgentIdle,
      taskName: cstring"",
      milestonesCompleted: 0,
      milestonesTotal: 0,
      currentMilestone: cstring"",
      milestones: @[]
    ),
    viewState: WorkspaceViewState(
      activeView: UserWorkspace,
      agentWorkspacePath: cstring"",
      agentSessionId: cstring""
    ),
    containerId: cstring"",
    animationFrame: 0,
    expanded: false,
    lastUpdateMs: 0
  )
  data.registerComponent(result, Content.CaptionBarProgress)

## ``makeFrameViewerComponent`` was retired in M3 — Content.FrameViewer is no
## longer a registered pane.  The Video Player pane now owns the rendered
## frame and wraps the same ``FrameViewerVM`` for data loading.  The
## ``FrameViewerComponent`` type definition is kept in ``types.nim`` so legacy
## persisted layouts can still parse without throwing during the transition.

proc makePixelHistoryComponent*(data: Data, id: int): PixelHistoryComponent =
  result = PixelHistoryComponent(id: id)
  data.registerComponent(result, Content.PixelHistory)

proc makeShaderDebugComponent*(data: Data, id: int): ShaderDebugComponent =
  result = ShaderDebugComponent(id: id)
  data.registerComponent(result, Content.ShaderDebug)

proc makeVideoPlayerComponent*(data: Data, id: int): VideoPlayerComponent =
  result = VideoPlayerComponent(id: id)
  data.registerComponent(result, Content.VideoPlayer)

proc makeAgentActivityDeepReviewComponent*(data: Data, id: int): AgentActivityDeepReviewComponent =
  ## Create a new AgentActivityDeepReviewComponent.
  ## Starts with empty DeepReview data and waits for notifications from
  ## the agent runtime to populate coverage, test results, and flow data.
  result = AgentActivityDeepReviewComponent(
    id: id,
    sessionId: cstring"",
    drSummary: ActivityDeepReviewSummary(
      totalLinesCovered: 0,
      totalLinesUncovered: 0,
      coveragePercent: 0.0,
      testsRun: 0,
      testsPassed: 0,
      testsFailed: 0,
      functionsTraced: 0,
      lastUpdatedMs: 0
    ),
    fileEntries: @[],
    recentNotifications: @[],
    testResults: @[],
    expanded: false
  )
  data.registerComponent(result, Content.AgentActivityDeepReview)

data.ui = Components(
  editors: JsAssoc[cstring, EditorViewComponent]{},
  idMap: JsAssoc[cstring, int]{value: 0, chart: 0},
  layoutSizes: LayoutSizes(startSize: true),
  monacoEditors: @[],
  traceMonacoEditors: @[],
  fontSize: 16,
  editModeHiddenPanels: @[],
  savedLayoutBeforeEdit: nil,
  editModeLayout: nil,
  lastUsedEditLayout: nil,
  activeAgentSessionId: cstring"")
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
  of Content.Timeline:        data.makeTimelineComponent(id)
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
  of Content.DeepReview:      data.makeDeepReviewComponent(id)
  of Content.AgentWorkspace:  data.makeAgentWorkspaceComponent(id)
  of Content.CaptionBarProgress: data.makeCaptionBarProgressComponent(id)
  # Content.FrameViewer dispatch removed in M3 — see the comment above
  # ``makePixelHistoryComponent``.  If a stale layout still references the
  # FrameViewer content id, ``makeComponent`` falls through to the catch-all
  # ``raise`` branch below; the additive walker ensures fresh sessions never
  # emit one.
  of Content.PixelHistory:    data.makePixelHistoryComponent(id)
  of Content.ShaderDebug:     data.makeShaderDebugComponent(id)
  of Content.VideoPlayer:     data.makeVideoPlayerComponent(id)
  of Content.AgentActivityDeepReview: data.makeAgentActivityDeepReviewComponent(id)
  of Content.RequestPanel:    data.makeRequestPanelComponent(id)
  of Content.VCS:             data.makeVCSComponent(id)
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

block:
  let emptyCache = JsAssoc[cstring, JsAssoc[cstring, Future[JsObject]]]{}
  data.asyncSendCache = emptyCache

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

  let componentName = if isEditor and content == Content.EditorView: cstring"editorComponent" else: cstring"genericUiComponent"

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

proc isAttachedToLayout*(item: GoldenContentItem, layout: GoldenLayout): bool =
  ## Traverses the parent chain from the given item up to the root.
  ## Checks if the item is actually connected to the layout's ground item
  ## by verifying that each parent actually contains the current item in its
  ## contentItems array.
  if item.isNil or layout.isNil:
    return false
  var curr = item
  while not curr.isNil:
    if curr == layout.groundItem:
      return true
    let parent = curr.parent
    if parent.isNil:
      return false
    # Check if parent actually contains curr in its contentItems
    var found = false
    for child in parent.contentItems:
      if child == curr:
        found = true
        break
    if not found:
      return false
    curr = parent
  return false

proc hasActiveOpenEditors*(data: Data): bool =
  ## Returns true if there is at least one EditorView or NoInfo component
  ## that is currently attached to the GoldenLayout tree.
  for content in [Content.EditorView, Content.NoInfo]:
    let openIds = data.ui.openComponentIds[content]
    let mapping = data.ui.componentMapping[content]
    for id in openIds:
      if mapping.hasKey(id):
        let comp = mapping[id]
        if not comp.isNil and not comp.layoutItem.isNil:
          if isAttachedToLayout(comp.layoutItem, data.ui.layout):
            return true
  return false


proc openLayoutTab*(
  data: Data,
  content: Content,
  id: int = -1,
  isEditor: bool = false,
  path: cstring = "",
  editorView: EditorView = ViewSource,
  noInfoMessage: cstring = ""
) =
  let layoutPath = editorTabPath(path, editorView)

  # If this panel lives in the auto-hide state (e.g. BUILD, PROBLEMS,
  # SEARCH RESULTS), show it via the auto-hide overlay instead of
  # trying to activate or create a GL tab.
  if not autoHideState.isNil:
    let autoHidePanel = autoHideState.findPanelByContent(content)
    if not autoHidePanel.isNil:
      showOverlay(autoHidePanel)
      return

  var parent: GoldenContentItem
  let similarComponents = data.ui.componentMapping[content]
  let openSimilarComponentsTabs = data.ui.openComponentIds[content]

  if content != Content.EditorView and
    content != Content.AgentActivity and
    data.ui.componentMapping[content].len() > 0 and
    not data.ui.componentMapping[content][0].layoutItem.isNil and
    not data.ui.componentMapping[content].toJs[0].isUndefined and
    isAttachedToLayout(data.ui.componentMapping[content][0].layoutItem, data.ui.layout):
      data.ui.componentMapping[content][0].
        layoutItem.parent.setActiveContentItem(
          data.ui.componentMapping[content][0].layoutItem)
      return

  var similarParent: GoldenContentItem = nil
  if similarComponents.len > 0 and openSimilarComponentsTabs.len > 0:
    for i in countdown(openSimilarComponentsTabs.len - 1, 0):
      let similarId = openSimilarComponentsTabs[i]
      if similarComponents.hasKey(similarId):
        let comp = similarComponents[similarId]
        if not comp.isNil and not comp.layoutItem.isNil and isAttachedToLayout(comp.layoutItem, data.ui.layout):
          similarParent = cast[GoldenContentItem](comp.layoutItem.parent)
          break

  if not similarParent.isNil:
    parent = similarParent
  else:
    let hasOpenEditors = data.hasActiveOpenEditors()
    if (content == Content.EditorView or content == Content.NoInfo or (content == Content.VCS and isEditor)) and
      not data.ui.editorPanels[EditorView.ViewSource].isNil and
      hasOpenEditors:
      let activeEditorPanel = data.ui.editorPanels[EditorView.ViewSource]
      if isAttachedToLayout(activeEditorPanel, data.ui.layout):
        parent = activeEditorPanel
      else:
        parent = data.openNewLayoutContainer(cstring"stack", isEditor)
        if content == Content.EditorView:
          data.ui.editorPanels[EditorView.ViewSource] = parent
    else:
      parent = data.openNewLayoutContainer(cstring"stack", isEditor)
      if content == Content.EditorView:
        data.ui.editorPanels[EditorView.ViewSource] = parent

  var newComponent =
    if not (isEditor and data.ui.editors.hasKey(layoutPath)):
      var newId =
        if id != -1:
          id
        else:
          data.generateId(content)

      let comp = data.makeComponent(content, newId, layoutPath)
      if content == Content.VCS:
        let vcsComp = cast[VCSComponent](comp)
        vcsComp.diffTarget = layoutPath
      comp
    else:
      data.ui.editors[layoutPath]

  if content == Content.NoInfo:
    # (written by Alexander: sorry)
    cast[NoSourceComponent](newComponent).message = noInfoMessage

  var label: cstring

  if content == Content.EditorView:
    label = layoutPath
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
  let editorName = editorTabPath(name, editorView)
  cdebug "editor: make editor view: " & $editorName & " " & $editorView
  let tabInfo = TabInfo(
    name: editorName,
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
    lastSyncedSource: content,
    sourceLines: content.split(jsNl),
    path: editorName
  )

  data.removeEditorFromClosedTabs(editorName)
  data.removeEditorFromLoading(editorName)

  data.makeEditorViewDetailed(
    editorName,
    editorView,
    tabInfo,
    tabInfo.location
  )
  var editorComponent = data.makeEditorViewComponent(
    data.generateId(Content.EditorView),
    editorName,
    1,
    editorName,
    editorView,
    false,
    tabInfo.location,
    lang)
  editorComponent.tabInfo = tabInfo

  cdebug "editor: make editor view: open layout tab"
  data.openLayoutTab(Content.EditorView, isEditor = true, path = editorName, editorView = editorView)
  cdebug "editor: make editor view: active = " & $editorName
  data.services.editor.active = editorName

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
  let editorName = editorTabPath(name, editorView)
  if not data.services.editor.open.hasKey(editorName):
    data.services.editor.open[editorName] = TabInfo(loading: true)
    data.removeEditorFromClosedTabs(editorName)
    data.removeEditorFromLoading(editorName)

    var location: types.Location
    var lang: Lang
    if editorView in {ViewSource, ViewTargetSource}:
      location = types.Location(
        path: editorName,
        line: NO_LINE,
        highLevelPath: editorName,
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
      editorName,
      editorView,
      tabInfo,
      location
    )

    if line != NO_LINE:
      proc cb =
        if isNull(data.ui.editors[editorName].monacoEditor):
          discard kdom.setTimeout(cb, 10)
        else:
          data.ui.editors[editorName].focusLine(line)

      discard kdom.setTimeout(cb, 10)

proc makeEditorViewDetailed(
    data: Data,
    name: cstring,
    editorView: EditorView,
    tabInfo: TabInfo,
    location: types.Location
) =
  let editorName = editorTabPath(name, editorView)
  data.services.editor.open[editorName] = tabInfo
  var editorComponent = data.makeEditorViewComponent(
    data.generateId(Content.EditorView),
    editorName,
    1,
    editorName,
    editorView,
    false,
    location,
    tabInfo.lang)
  editorComponent.tabInfo = tabInfo
  # if not self.data.ui.editors[name].flow.isNil:
    # self.data.ui.editors[name].flow.tab = tabInfo
  cdebug "editor: openLayoutTab.."
  data.openLayoutTab(Content.EditorView, isEditor = true, path = editorName, editorView = editorView)
  cdebug "editor: after open layout tab, active = " & $editorName
  data.services.editor.active = editorName

proc showTab*(data: Data, tab: cstring, noInfoMessage: cstring = cstring"", line: int = NO_LINE) =
  if tab.isNil:
    cerror "tabs: tab is nil in showTab"
    return
  let editorName =
    if data.ui.editors.hasKey(tab):
      tab
    else:
      canonicalSourceRevisionPath(tab)
  if not data.ui.editors.hasKey(editorName):
     # not data.ui.lowLevels.hasKey(tab):
    cerror "tabs: no editor in showTab for " & $tab
    return

  var contentItem: GoldenContentItem

  if data.ui.editors.hasKey(editorName):
    var editor: EditorViewComponent
    if not data.ui.editors[editorName].layoutItem.isNil:
      editor = data.ui.editors[editorName]
    else:
      editor = data.ui.editors[editorName].topLevelEditor

    if editor.isNil:
      cwarn "editor is nil in showTab " & $editorName
      return

    if editor.layoutItem.isNil:
      cwarn "editor.layoutItem is nil in showTab " & $editorName
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
    cwarn "no editor for " & $editorName
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
  var tabName = editorTabPath(name, editorView)
  if editorView in {EditorView.ViewSource, EditorView.ViewTargetSource} and
      not data.services.editor.open.hasKey(tabName):
    let nameText = $name
    if nameText.len > 0 and not nameText.startsWith("/") and
        not (nameText.len >= 3 and nameText[1] == ':' and
             (nameText[2] == '\\' or nameText[2] == '/')):
      let suffix = "/" & nameText
      for openName, info in data.services.editor.open:
        let openText = $openName
        if openText == nameText or openText.endsWith(suffix):
          tabName = openName
          break

  cdebug "editor: openTab: " & $tabName & " " & $editorView
  # let tabName = if name != "unknown": name else: "NO SOURCE"
  # singleton no info page?
  if not data.services.editor.open.hasKey(tabName):
    discard data.openNewEditorView(tabName, editorView, noInfoMessage=noInfoMessage, line=line)
  elif not data.services.editor.open[tabName].loading:
    data.showTab(tabName, noInfoMessage=noInfoMessage, line=line)
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
