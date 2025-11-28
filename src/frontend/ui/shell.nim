import
  kdom,
  ui_imports,
  ../renderer

var
  xtermLib {.importc.}: XtermJsLib
  fitAddonLib {.importc.}: XtermFitAddonLib

proc createTerminal(terminal: Terminal, terminalOptions: js): Terminal {.importjs: "new #(#)".}
proc createFitAddon(fitAddon: XtermFitAddon): XtermFitAddon {.importjs: "new #()".}
proc open(terminal: Terminal, node: Node) {.importjs: "#.open(#)".}
proc write(terminal: Terminal, content: cstring) {.importjs: "#.write(#)".}
proc onData(terminal: Terminal, handler: proc(data: cstring): void) {.importcpp: "#.onData(#)".}
proc onKey(terminal: Terminal, handler: proc(event: TerminalIEvent): void) {.importcpp: "#.onKey(#)".}
proc onResize(terminal: Terminal, handler: proc(event: TerminalIEvent): void) {.importcpp: "#.onResize(#)".}
proc onRender(decoration: js, handler: proc) {.importjs: "#.onRender(#)".}
proc onRender(terminal: Terminal, handler: proc(event: RenderEvent): void) {.importjs: "#.onRender(#)".}
proc onScroll(terminal: Terminal, handler: proc(viewportY: int): void) {.importjs: "#.onScroll(#)".}
proc resize(terminal: Terminal, cols: int, rows: int) {.importjs: "#.resize(#,#)".}
proc registerMarker(terminal: Terminal, position: int): js {.importjs: "#.registerMarker(#)".}
proc registerDecoration(terminal: Terminal, decoration: js): js {.importjs: "#.registerDecoration(#)".}
proc loadAddon(terminal: Terminal, addon: TerminalAddon) {.importjs: "#.loadAddon(#)".}
proc fit(addon: XtermFitAddon) {.importjs: "#.fit()".}
proc proposeDimensions(addon: XtermFitAddon): TerminalDimensions {.importjs: "#.proposeDimensions()".}

proc createShellLayoutContainer*(self: ShellComponent) =
  let label = convertComponentLabel(
    Content.Shell, self.data.ui.componentMapping[Content.Shell].len
  )
  let childConfig = GoldenLayoutConfig(
    `type`: cstring"component",
    componentName: cstring"genericUiComponent",
    componentState: GoldenItemState(
      id: self.data.ui.componentMapping[Content.Shell].len,
      label: label,
      content: Content.Shell,
      fullPath: cstring"",
      name: label)
  )

  let resolvedConfig = self.data.ui.contentItemConfig.resolve(childConfig)
  let parent = self.data.ui.layout.groundItem.contentItems[0]
  let index = parent.contentItems.len
  let child = self.data.ui.layout.createAndInitContentItem(resolvedConfig, parent)

  discard parent.addChild(child, index)

proc send(self: ShellComponent, raw: cstring) =
  cwarn "shell: TODO send " & $raw
  self.data.ipc.send "CODETRACER::send-to-shell", ShellEvent(kind: ShellRaw, id: self.id, raw: raw)

proc ensureShellContainer(self: ShellComponent): Node =
  let parentContainerId = cstring(&"shellComponent-{self.id}")
  var parent = cast[Element](jq(cstring(&"#{parentContainerId}")))

  if parent.isNil:
    let root = cast[Element](jq("#ROOT"))
    let shellMainContainer = document.createElement("div")
    shellMainContainer.id = parentContainerId
    shellMainContainer.classList.add(cstring("component-container"))
    root.appendChild(shellMainContainer)
    parent = shellMainContainer

  let containerSelector = cstring(&"#shellComponent-{self.id} .shell-container")
  var container = cast[Element](jq(containerSelector))

  if container.isNil:
    # create inner container with id
    let newContainer = document.createElement("div")
    newContainer.classList.add("shell-container")
    container = newContainer
    parent.appendChild(container)

  return container

proc shellReady(self: ShellComponent): bool =
  ## Defensive helper so callers can check if the xterm instance exists before writing.
  not self.shell.isNil

proc writeShellRaw*(self: ShellComponent, chunk: cstring) =
  ## Write raw data into the shell; drops writes if the terminal is not initialized yet.
  if not self.shellReady():
    cwarn "shell: writeShellRaw dropped because terminal is not initialized"
    return
  self.shell.write(chunk)

proc writeShellLine*(self: ShellComponent, line: cstring) =
  ## Convenience for writing a single line with the proper newline sequence.
  self.writeShellRaw(line & "\r\n")

proc openTrace*(self: ShellComponent, event: SessionEvent) {.exportc.} =
  if event.kind == RecordingCommand:
    self.data.ipc.send "CODETRACER::show-in-debug-instance", js{traceId: event.trace.id, outputLine: -1}

proc showOutputInDebugInstance*(self: ShellComponent, event: SessionEvent, outputLine: int) {.exportc.} =
  if event.kind == RecordingCommand:
    self.data.ipc.send "CODETRACER::show-in-debug-instance", js{traceId: event.trace.id, outputLine: outputLine}

proc determineClickedShellRow(self: ShellComponent, targetNode: Node): int =
  let rowsContainer = cast[Node](jq".xterm-rows")
  let shellRows = rowsContainer.childNodes
  var clickedBufferRow: int = -1

  for index, child in shellRows:
    if targetNode == child:
      clickedBufferRow = index

  let viewportFirstRow = self.shell.buffer.normal.viewportY

  return viewportFirstRow + clickedBufferRow

proc resizeTerminal(terminal: Terminal, fitAddon: XtermFitAddon) =
  clog "shell: resize"
  let proposedDimensions = fitAddon.proposeDimensions()
  terminal.resize(proposedDimensions.cols - 5, proposedDimensions.rows)

proc createShell*(self: ShellComponent) =
  # self.createShellLayoutContainer()
  let container = self.ensureShellContainer()
  # create terminal object
  let terminal = createTerminal(
    xtermLib.Terminal,
    js{
      allowProposedApi: true,
      lineHeight: 1,
      fontSize: 14,
      rows: 3,
      cols: 60,
      theme: self.themes["default_dark"],

      scrollback: 0,
      scrollOnUserInput: false
    }
  )

  let shellprompt = "$ "

  terminal.prompt = proc =
    terminal.write("\r\n" & shellprompt)

  terminal.prompt()

  # open xterm terminal
  terminal.open(container)
  self.shell = terminal

  # # load xterm-addon-fit
  # let fitAddon = createFitAddon(fitAddonLib.FitAddon)

  # terminal.loadAddon(fitAddon)
  # resizeTerminal(terminal, fitAddon)

  # # set resize observer to terminal container
  # let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
  #   for entry in entries:
  #     resizeTerminal(terminal, fitAddon))

  # resizeObserver.observe(container)

  # terminal.write("Welcome to CodeTracer shell!")

  # add listener to termnal rows
  # let rowsDom = cast[Node](jq(&"#shellComponent-{self.id} .xterm-rows"))

  # try:
  #   rowsDom.addEventListener(cstring"mousedown", proc(ev: Event) =
  #     if ev.target.nodeName == "SPAN":
  #       self.rowIsClicked = true
  #       self.clickedRow = self.determineClickedShellRow(ev.target.parentNode))
  #   rowsDom.addEventListener(cstring"mouseup", proc(ev: Event) =
  #     let target = ev.target
  #     if target.nodeName == "SPAN" and
  #       self.rowIsClicked and
  #       self.clickedRow == self.determineClickedShellRow(ev.target.parentNode):
  #         var lastPreviousEventLine: int = 0
  #         for line, events in self.events:
  #           if line <= self.clickedRow and line > lastPreviousEventLine:
  #             lastPreviousEventLine = line
  #         if lastPreviousEventLine > 0:
  #           let lastRecordEvents = toSeq(self.events[lastPreviousEventLine].items()).filterIt(
  #             it.kind == RecordingCommand)
  #           if lastRecordEvents.len > 0:
  #             let lastRecordEvent = lastRecordEvents[lastRecordEvents.len - 1]
  #             let firstLine = lastRecordEvent.firstLine + self.progressOffset
  #             let lastLine = firstLine + (lastRecordEvent.lastLine - lastRecordEvent.firstLine)
  #             if firstLine <= self.clickedRow and self.clickedRow <= lastLine:
  #               # echo "will open trace with id: ", lastRecordEvent.traceId
  #               self.showOutputInDebugInstance(lastRecordEvents[lastRecordEvents.len - 1], self.clickedRow - lastPreviousEventLine - 4)
  #     self.rowIsClicked = false
  #     self.clickedRow = -1
  #   )
  # except:
  #   cerror "shell: " & getCurrentExceptionMsg()

  # # create gutter
  # let gutter = document.createElement("div")
  # gutter.classList.add("shell-gutter")
  # let scrollableArea = cast[Node](jq(&"#shellComponent-{self.id} .xterm-scroll-area"))
  # scrollableArea.appendChild(gutter)
  # self.gutterDom = gutter

  # self.shell.onRender do (event: RenderEvent):
  #   discard

  # self.shell.onScroll do (viewportY: int):
  #   self.buffer.viewportY = viewportY

  # self.shell.onResize do (event: TerminalIEvent):
  #   discard

  # self.shell.onData do (data: cstring):
  #   self.send(data)

  self.shell.onKey do (e: TerminalIEvent):
    self.shell.write(e.key)
    # clog "shell: key " & $e.key
    # var raw = ""

    # if e.domEvent.keyCode == ENTER_KEY_CODE:
    #   raw = "\n"
    # elif e.domEvent.keyCode == TAB_KEY_CODE:
    #   raw = "\t"
    # elif e.domEvent.keyCode == BACKSPACE_KEY_CODE:
    #   raw = "\b"
    # if raw.len > 0:
    #   self.send(cstring(raw))

proc openShellTab*(data: Data) =
  data.openLayoutTab(Content.Shell)

  let componentId = data.ui.openComponentIds[Content.Shell][^1]
  let shellComponent =
    cast[ShellComponent](
      data.ui.componentMapping[Content.Shell][componentId])

  shellComponent.createShell()

proc eventSummary(event: SessionEvent): string =
  let explanation = case event.kind:
    of CustomCompilerFlagCommand:
      &"custom compiling flags:     {event.program}"

    of LinkingBinary:
      if event.status == WorkingStatus:
        &"linking binary:             {event.binary}"
      elif event.status == OkStatus:
        &"linked and marked binary:   {event.binary}"
      else:
        &"didn't link binary:         {event.binary}: error {event.errorMessage}"

    of RecordingCommand:
      if event.status == WorkingStatus:
        &"recording command:          {event.command}"
      elif event.status == OkStatus:
        &"recorded command:           trace #{event.trace.id}({event.command})"
      else:
        &"error recording command:    {event.command} error: {event.errorMessage}"

  let time =
    if event.time.toJs.isNil:
      ""
    else:
      $event.time

  &"{explanation} ({event.time})"

proc renderEventStatusView(self: ShellComponent, event: SessionEvent): Node =
  var class = "shell-event-status "

  # style statusDom according to event status
  case event.status:
  of WorkingStatus:
    class = &"{class} working"

  of ErrorStatus:
    class = &"{class} error"

  of OkStatus:
    class = &"{class} done"

  let vNode = buildHtml(tdiv(class = class))

  vnodeToDom(vNode, KaraxInstance())

proc renderEventView(self: ShellComponent, event: SessionEvent, eventContainer: kdom.Node) =
  # add event dom
  let eventDom = document.createElement("div")

  eventDom.id = &"shell-event-{event.actionId}"
  eventDom.classList.add("shell-event")

  # add range dom
  let eventRange = document.createElement("div")

  eventRange.classList.add("shell-event-range")

  # add shell summary dom
  let eventSummary = document.createElement("div")

  eventSummary.classList.add("shell-event-summary")
  eventSummary.innerHTML = event.eventSummary()
  eventRange.appendChild(eventSummary)

  let statusDom = self.renderEventStatusView(event)

  # style eventDom according to the event kind
  case event.kind:
  of CustomCompilerFlagCommand:
    eventDom.classList.add("custom-compiler-flag-command")

  of LinkingBinary:
    eventDom.classList.add("linking-binary")

  of RecordingCommand:
    eventDom.classList.add("recording-command")

  eventDom.appendChild(eventRange)
  eventDom.appendChild(statusDom)

  # eventDom.appendChild(typeDom)
  eventContainer.appendChild(eventDom)

  # add reference to event dom
  self.eventsDoms[event.actionId] = eventDom

proc updateEventStatus(self: ShellComponent, event: SessionEvent) =
  let eventDom = self.eventsDoms[event.actionId]
  discard jsDelete(eventDom.findNodeInElement("shell-event-status"))

  let newStatusDom = self.renderEventStatusView(event)
  eventDom.appendChild(newStatusDom)


method onUpdatedShell*(self: ShellComponent, response: ShellUpdate) {.async.} =
  clog "shell: onUpdatedShell: " & $response.kind
  case response.kind:
  of ShellUpdateRaw:
    self.shell.write(response.raw)

  of ShellEvents:
    if self.progressOffset == 0:
      let localProgress =
        self.shell.buffer.normal.length -
        self.shell.rows +
        self.shell.buffer.normal.cursorY
      self.progressOffset = localProgress - response.progress
    for event in response.events:
      let firstLine = event.firstLine + self.progressOffset
      if not self.eventContainers.hasKey(firstLine):
        let newContainer = document.createElement("div")
        newContainer.id = &"shell-events-{firstLine}"
        newContainer.classList.add("shell-events")
        newContainer.style.top = &"{firstLine * self.lineHeight}px"
        self.gutterDom.appendChild(newContainer)
        self.eventContainers[firstLine] = newContainer
      let eventContainer = self.eventContainers[firstLine]
      eventContainer.style.height =
        &"{(event.lastLine - event.firstLine) * self.lineHeight}px"
      if not self.events.hasKey(firstLine):
        self.events[firstLine] = JsAssoc[int, SessionEvent]{}
      var lineEvents = self.events[firstLine]
      if not lineEvents.hasKey(event.actionId) and
        not self.eventsDoms.hasKey(event.actionId):
        lineEvents[event.actionId] = event
        self.renderEventView(event, eventContainer)
      elif lineEvents[event.actionId].status != event.status:
        await wait(2_000)
        lineEvents[event.actionId] = event
        self.updateEventStatus(event)
      else:
        continue
