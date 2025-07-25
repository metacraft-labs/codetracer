import ui_imports, show_code, value, ../utils
import ../communication, ../../common/ct_event


let returnValueName: cstring = "<return value>"

const CALL_OFFSET_WIDTH_PX = 20
const LOCAL_CALL_HEIGHT_PX = 24
const CALL_HEIGHT_PX = 24
const CALL_BUFFER = 20
const START_BUFFER = 10
const TRACE_LINE_OFFSET = 10
const EXPAND_CALLS_KIND = CtExpandCalls
const COLLAPSE_CALLS_KIND = CtCollapseCalls

proc getCurrentMonacoTheme(editor: MonacoEditor): cstring {.importjs:"#._themeService._theme.themeName".}
proc redrawCallLines(self: CalltraceComponent)
proc loadLines(self: CalltraceComponent, fromScroll: bool)

var calltraceComponentForExtension* {.exportc.}: CalltraceComponent = makeCalltraceComponent(data, 0, inExtension = true)

proc calltraceJump(self: CalltraceComponent, location: types.Location) =
  self.api.emit(CtCalltraceJump, location)

proc makeCalltraceComponentForExtension*(id: cstring): CalltraceComponent {.exportc.} =
  if calltraceComponentForExtension.kxi.isNil:
    calltraceComponentForExtension.kxi = setRenderer(proc: VNode = calltraceComponentForExtension.render(), id, proc = discard)
  result = calltraceComponentForExtension

proc isAtStart(self: CalltraceComponent): bool =
  self.startCallLineIndex < START_BUFFER

proc getStartBufferLen(self: CalltraceComponent): int =
  if self.isAtStart():
    self.startCallLineIndex
  else:
    START_BUFFER

func calcScrollHeight(self: CalltraceComponent): cstring =
  cstring(fmt"{self.totalCallsCount * CALL_HEIGHT_PX}px")

func calltraceStyle(self: CalltraceComponent): VStyle =
  style((StyleAttr.height, self.calcScrollHeight()))

func calltraceLinesTransformTranslateY(self: CalltraceComponent): cstring =
  let buffer = self.getStartBufferLen()
  cstring(fmt"translateY({(self.startCallLineIndex - buffer) * CALL_HEIGHT_PX}px)")

func calltraceLinesStyle(self: CalltraceComponent): VStyle =
  style((StyleAttr.transform, self.calltraceLinesTransformTranslateY()))

proc toggleCalls*(
  self: CalltraceComponent,
  kind: CtEventKind,
  callKey: cstring,
  nonExpandedKind: CalltraceNonExpandedKind,
  count: int
) =
  let target = CollapseCallsArgs(callKey: callKey, nonExpandedKind: nonExpandedKind, count: count)
  self.api.emit(kind, target)

proc createContextMenuItems(
  self: CalltraceComponent,
  ev: js,
  callLine: CallLineContent
): seq[ContextMenuItem] =
  var expandCallstack:  ContextMenuItem
  var collapseCallChildren: ContextMenuItem
  var expandCallChildren: ContextMenuItem
  var contextMenu:      seq[ContextMenuItem]

  let call = callLine.call

  if callLine.hiddenChildren:
    expandCallChildren =
      ContextMenuItem(
        name: "Expand Call Children",
        hint: "",
        handler: proc(e: Event) =
          self.toggleCalls(EXPAND_CALLS_KIND, call.key, CalltraceNonExpandedKind.Children, 0)
          self.loadLines(fromScroll=false)
      )
    contextMenu&= expandCallChildren
  elif callLine.count > 0 or call.children.len() > 0:
    collapseCallChildren =
      ContextMenuItem(
        name: "Collapse Call Children",
        hint: "",
        handler: proc(e: Event) =
          self.toggleCalls(COLLAPSE_CALLS_KIND, call.key, CalltraceNonExpandedKind.Children, 0)
          self.loadLines(fromScroll=false)
      )
    contextMenu&= collapseCallChildren

  expandCallstack = ContextMenuItem(name: "Expand Full Callstack", hint: "", handler: proc(e: Event) =
    self.toggleCalls(EXPAND_CALLS_KIND, "0", CalltraceNonExpandedKind.CallstackInternal, -1)
    self.loadLines(fromScroll=false))
  contextMenu &= expandCallstack

  return contextMenu

proc createContextMenuItems(self: CallArg, ev: js): seq[ContextMenuItem] =
  var addToScratchpad:  ContextMenuItem
  var contextMenu:      seq[ContextMenuItem]

  addToScratchpad =
    ContextMenuItem(
      name: "Add value to scratchpad",
      hint: "CTRL+&lt;click on value&gt;",
      handler: proc(e: Event) =
        openValueInScratchpad((self.name, self.value))
        data.redraw()
    )
  contextMenu &= addToScratchpad

  return contextMenu

proc `$`*(c: CallCount): string =
  case c.kind:
  of Eq:
    $c.i
  of GtOrEq:
    &">= {c.i}"
  of LsOrEq:
    &"<= {c.i}"
  of Gt:
    &"> {c.i}"
  of Ls:
    &"< {c.i}"

proc panelDepth*(self: CalltraceComponent): int =
  cast[int](jq("#calltraceComponent-" & $self.id).offsetWidth) div CALL_OFFSET_WIDTH_PX

proc panelHeight*(self: CalltraceComponent): int =
  cast[int](jq("#calltraceComponent-" & $self.id).offsetHeight) div CALL_HEIGHT_PX

proc scrollRawPosition*(self: CalltraceComponent): int =
  cast[int](jq("#calltraceScroll-" & $self.id).toJs.scrollTop)

proc scrollLineIndex*(self: CalltraceComponent): int =
  (self.scrollRawPosition() / CALL_HEIGHT_PX).floor

proc showCallValue*(self: CalltraceComponent, arg: CallArg, keyOrIndex: cstring) =
  let id = keyOrIndex & "_" & arg.name
  let value = ValueComponent(
    expanded: JsAssoc[cstring, bool]{arg.name: true},
    charts: JsAssoc[cstring, ChartComponent]{},
    showInLine: JsAssoc[cstring, bool]{},
    baseExpression: arg.name,
    baseValue: arg.value,
    service: data.services.history,
    stateID: -1,
    nameWidth: VALUE_COMPONENT_NAME_WIDTH,
    valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
    data: data,
    location: self.location
  )

  self.forceRerender[id] = true
  self.modalValueComponent[id] = value

proc getLastKey(assoc: JsAssoc[cstring, ValueComponent]): cstring =
  var keys: seq[cstring] = @[]

  for key in assoc.keys:
    keys.add(key)

  result = keys[keys.len - 1]

proc codeCallView(id: cstring, path: cstring, line: int): VNode =
  showCode(id, path, line-3, line+5, line)

proc callOffset(depth: int): VStyle =
  style((StyleAttr.minWidth, j(&"{depth * 8}px")))

proc setCallOffset(
  depth: int,
  backIndentCounter: int = 1,
  isFirstChild: bool = false,
  isLastChild: bool = false,
  isLastElement: bool = false,
  hasChildren: bool = false,
  hasExpandedValues: bool = false,
  isNextCall: bool = false,
  isActiveCall: bool = false,
  parentIsActive: bool = false
): VNode =
  var emptyOffsetCount = depth - backIndentCounter
  var bottomBorderedOffsetCount = backIndentCounter

  if isFirstChild:
    emptyOffsetCount -= 1

    if bottomBorderedOffsetCount > 0:
      bottomBorderedOffsetCount -= 1

    if isLastChild and not hasChildren:
      emptyOffsetCount += 1

  if (isLastChild and hasExpandedValues) or isLastElement:
    emptyOffsetCount += bottomBorderedOffsetCount
    bottomBorderedOffsetCount = 0

  buildHtml(
    tdiv(class = "call-offsets")
  ):

    for i in 0..<emptyOffsetCount:
      tdiv(class = "empty-offset"):
        text " "

    for i in 0..<bottomBorderedOffsetCount:
      tdiv(class = "empty-offset empty-offset-bottom-border"):
        text " "

    if isFirstChild:
      if isLastChild:
        if hasChildren or hasExpandedValues or isLastElement:
          tdiv(class = "empty-offset empty-offset-top-border"):
            text " "
        else:
          tdiv(class = "empty-offset empty-offset-top-border empty-offset-bottom-border"):
            text " "
      else:
        tdiv(class = "empty-offset empty-offset-top-border"):
          text " "

    tdiv(class = "call-offset-icon"):
      tdiv(class = "call-offset-icon-1")

      if isLastElement:
        tdiv(class = "call-offset-icon-6")
      else:
        tdiv(class = "call-offset-icon-2")

      tdiv(class = "call-offset-icon-3")

      if isNextCall and parentIsActive:
        tdiv(class = "call-offset-icon-4")
      if isActiveCall and not hasChildren:
        tdiv(class = "call-offset-icon-5")

proc setExpandedValueOffset(
  depth: int,
  isLastValue: bool = false,
  backIndentCount: int = 0,
  callHasChildren: bool = false,
  callIsLastChild: bool = false,
  callIsCollapsed: bool = false,
  callIsLastElement: bool = false
): VNode =
  var emptyOffsetCount = depth - 1

  if isLastValue:
    if backIndentCount > 0:
      emptyOffsetCount -= (backIndentCount - 1)

  buildHtml(
    tdiv(class = "call-offsets")
  ):
    if callIsLastElement:
      for i in 0..<depth:
        tdiv(class = "empty-offset")
    else:
      for i in 0..<emptyOffsetCount:
        tdiv(class = "empty-offset")
      if isLastValue:
        for i in 0..<backIndentCount - 1 :
          tdiv(class = "empty-offset empty-offset-bottom-border")
      if isLastValue and (not callHasChildren or callIsCollapsed):
        if callIsLastChild:
          tdiv(class = "empty-offset empty-offset-right-border empty-offset-bottom-border")
        else:
          tdiv(class = "empty-offset empty-offset-right-border")
      else:
        tdiv(class = "empty-offset empty-offset-right-border")

proc childlessCallView(self: CalltraceComponent, call: Call, active: cstring): VNode =
  let internalActive =
    if active != "" and call.location.key == self.location.key:
      "active"
    else:
      ""
  buildHtml(
    span(
      class = "toggle-call",
    )
  ):
    tdiv(class = fmt"dot-call-img {internalActive}")
    if call.location.rrTicks < self.location.rrTicks and active != "" and call.location.key != self.location.key:
      tdiv(class = "active-call-location")

proc endOfProgramCallView(self: CalltraceComponent, isError: bool): VNode =
  let cl = if isError: "end-of-program-error" else: ""
  buildHtml(
    span(
      class = "toggle-call",
    )
  ):
    tdiv(class = "end-of-program-img " & cl)

proc expandCallView(self: CalltraceComponent, call: Call, count: int, active: cstring): VNode =
  buildHtml(
    span(
      class = "toggle-call",
      onclick = proc(ev: Event, v: VNode) =
        self.toggleCalls(EXPAND_CALLS_KIND, call.key, CalltraceNonExpandedKind.Children, count)
        self.loadLines(fromScroll=false)
    )
  ):
    tdiv(class = fmt"expand-call-img {active}") 

proc collapseCallView(
  self: CalltraceComponent,
  call: Call,
  kind: CalltraceNonExpandedKind,
  count: int,
  active: cstring,
): VNode =
  buildHtml(
    span(
      class = "toggle-call",
      onclick = proc(ev: Event, v: VNode) =
        self.toggleCalls(COLLAPSE_CALLS_KIND, call.key, kind, count)
        self.loadLines(fromScroll=false)
    )
  ):
    tdiv(class=fmt"collapse-call-img {active}")

proc resetValueView(self: CalltraceComponent) =
  for key in self.forceRerender.keys:
    self.forceRerender[key] = false

proc calcValueLeftPosition(self: CalltraceComponent, ev: Event, id: cstring) =
  let scrollLeft = cast[float](jq("#" & "calltraceScroll-" & $self.id).toJs.scrollLeft)
  self.callValuePosition[id] = cast[float](ev.toJs.clientX) - self.startPositionX + scrollLeft

proc callArgView(self: CalltraceComponent, arg: CallArg, keyOrIndex: cstring): VNode =
  let id = fmt"{keyOrIndex}_{arg.name}"

  buildHtml(
    tdiv(
      class = "call-arg",
      id = &"call-arg-{keyOrIndex}-{arg.name}",
      onclick = proc(ev: Event, v: VNode) =
        if cast[bool](ev.toJs.ctrlKey):
          ev.stopPropagation()
          openValueInScratchpad((arg.name, arg.value))
          data.redraw()
        elif not self.modalValueComponent.hasKey(id):
          self.resetValueView()
          showCallValue(self, arg, keyOrIndex)
          self.calcValueLeftPosition(ev, id)
        else:
          if not self.forceRerender[id]:
            self.resetValueView()
          self.calcValueLeftPosition(ev, id)
          self.forceRerender[id] = not self.forceRerender[id]
        self.data.redraw(),
      oncontextmenu = proc(ev: Event, v: VNode) {.gcsafe.} =
        let e = ev.toJs
        ev.stopPropagation()
        let contextMenu = arg.createContextMenuItems(e)
        if contextMenu != @[]:
            showContextMenu(contextMenu, cast[int](e.x), cast[int](e.y))
    )
  ):
    let value = arg.value.textRepr
    tdiv(class = "call-arg-header", id = &"call-arg-header-{keyOrIndex}-{arg.name}"):
      tdiv(class = "call-arg-name", id = &"call-arg-name-{keyOrIndex}-{arg.name}"):
        text &"{arg.name}="
      tdiv(class = "call-arg-text", id = &"call-arg-text-{keyOrIndex}-{arg.name}"):
        text value

proc callArgListView(
  self: CalltraceComponent,
  arg: CallArg,
  callKey: cstring,
  callDepth: int
): VNode =
  buildHtml(
    li(
      onclick = proc =
        if not self.expandedValues.hasKey(callKey):
          self.expandedValues[callKey] = makeCallExpandedValueComponent(self.data, callDepth)
        ensureValueComponent(self.expandedValues[callKey], arg.name, arg.value)
    )
  ):
    span(class = "call-arg-tooltip-name"): text $(arg.name)
    text " : "
    span(class = "call-arg-tooltip-value"): text $(arg.value.textRepr)

proc renderExpandedValue(value: ValueComponent): VNode =
  value.render()

proc callArgsView(
  self: CalltraceComponent,
  args: seq[CallArg],
  isCallstack: bool,
  keyOrIndex: cstring,
  callDepth: int
): VNode =
  if self.modalValueComponent.isNil:
    self.modalValueComponent = JsAssoc[cstring, ValueComponent]{}
    self.forceRerender = JsAssoc[cstring, bool]{}

  buildHtml(
    tdiv(
      id = &"call-args-{isCallstack}-{keyOrIndex}",
      class = "call-args"
    )
  ):
    text "("
    for i, arg in args:
      let id = fmt"{keyOrIndex}_{arg.name}"
      callArgView(self, arg, keyOrIndex)
      if self.forceRerender[id]:
        tdiv(class = "call-tooltip",
          style = style(StyleAttr.left, fmt"{self.callValuePosition[id]}px")
        ):
          renderExpandedValue(self.modalValueComponent[id])
      if i < args.len - 1:
        text ", "
    text ")"

proc returnValueView(
  self: CalltraceComponent,
  callkey: cstring,
  callDepth: int,
  ret: Value
): VNode =
  buildHtml(
    span(
      class="return",
      onclick = proc =
        if not self.expandedValues.hasKey(callKey):
          self.expandedValues[callKey] = makeCallExpandedValueComponent(self.data, callDepth)
        ensureValueComponent(self.expandedValues[callKey], "<return value>", ret)
    )
  ):
    let value = ret.textRepr
    span(class = "return-arrow"):
      text " => "
    span(class = "return-text"):
      text value

proc searchResultView(self: CalltraceComponent, call: Call): VNode =
  let location = call.location
  let ticksText = if self.isDbBasedTrace: "stepId" else: "rrTicks"

  buildHtml(
    tdiv(
      class = "search-result",
      onmousedown = proc =
        self.calltraceJump(location)
        self.redrawForExtension()
    )
  ):
    text &"#{location.key} - {ticksText}({location.rrTicks}): {location.highLevelFunctionName}"


proc emptyResultView(self: CalltraceComponent): VNode =
  buildHtml(
    tdiv(
      class = "empty-search-result",
      onclick = proc =
        self.isSearching = false
        self.data.redraw()
    )
  ):
    text &"Couldn't find any results for '{self.searchText}'!\n-Click To Close-"

proc searchResultsView(self: CalltraceComponent): VNode =
  let hiddenClass = if self.isSearching: "" else: "hidden"
  result = buildHtml(
    tdiv(class = fmt"call-search-results {hiddenClass}")
  ):
    if self.searchResults.len > 0:
      for call in self.searchResults:
        searchResultView(self, call)
    elif self.searchText.len() > 0:
      emptyResultView(self)

proc searchCalltraceView(self: CalltraceComponent): VNode =
  let onSearch = proc(ev: KeyboardEvent, v: VNode) =
    ev.target.focus()
    if ev.keyCode == ENTER_KEY_CODE:
      self.searchText = cast[cstring](ev.target.toJs.value)
      self.api.emit(CtSearchCalltrace, CallSearchArg(value: self.searchText))

  buildHtml(
    tdiv(class = "calltrace-search")
  ):
    form(
      class = &"calltrace-search-form-{self.id}",
      onsubmit = proc(ev: Event, v: VNode) =
        ev.preventDefault()
        ev.stopPropagation()
        discard
    ):
      input(
        tabIndex = "0",
        class = "calltrace-search-input",
        `type` = "text",
        placeholder = "Search",
        onkeydown = onSearch,
        onblur = proc() =
          self.isSearching = false)

    searchResultsView(self)

method locationLang*(self: CalltraceComponent): Lang =
  self.location.path.toLangFromFilename()

proc filterCalltraceView(self: CalltraceComponent): VNode =
  let onFilterKeyUp = proc(ev: Event, v: VNode) {.async.} =
    if cast[cstring](ev.toJs.key) == cstring"Enter":
      ev.preventDefault()
      ev.stopPropagation()
      let rawIgnorePatterns = cast[cstring](ev.target.toJs.value)
      if self.rawIgnorePatterns != rawIgnorePatterns:
        self.rawIgnorePatterns = rawIgnorePatterns
        self.startCallLineIndex = 0
        self.loadLines(fromScroll=false)

        self.data.redraw()

  if self.rawIgnorePatterns.isNil:
    if self.locationLang() != LangNim:
      self.rawIgnorePatterns = cstring""
    else:
      self.rawIgnorePatterns = cstring"path~lib/system;path~chronicles"

  let value = self.rawIgnorePatterns

  buildHtml(
    tdiv(class = "calltrace-filter")
  ):
    form(
        class = &"calltrace-filter-form",
        onsubmit = proc(ev: Event, v: VNode) =
          ev.preventDefault()
    ):
      input(
        class = "calltrace-filter-raw-ignored-patterns",
        `type` = "text",
        placeholder = "filter: ignore those patterns",
        value = value,
        onkeyup = proc(ev: Event, v: VNode) = discard onFilterKeyUp(ev, v)
      )

proc callView*(
  self: CalltraceComponent,
  callLine: CallLineContent,
  index: int,
  depth: int
): VNode =
  let currentCallKey = self.location.key
  let call = callLine.call
  let childrenCount = callLine.count
  let hiddenChildren = callLine.hiddenChildren
  let isCurrentCall = call.key == currentCallKey
  let callClass = if isCurrentCall: "call-current" else: ""
  let key = call.key
  let activeClass = ""

  var isExpanded = false
  var args: seq[CallArg]
  var returnValue: Value

  args = 
    if self.args.hasKey(key):
      self.args[key]
    else:
      call.args

  returnValue =
    if self.returnValues.hasKey(key):
      self.returnValues[key]
    else:
      call.returnValue

  buildHtml(
    tdiv(class = "calltrace-child call-depth")
  ):
    tdiv(
      id = fmt"local-call-{key}",
      class = fmt"{activeClass} {callClass} call-child-box",
      oncontextmenu = proc(ev: Event, v: VNode) {.gcsafe.} =
        let e = ev.toJs
        let contextMenu = self.createContextMenuItems(e, callLine)
        if contextMenu != @[]:
          showContextMenu(contextMenu, cast[int](e.x), cast[int](e.y))
    ):
      codeCallView(&"{key}", call.location.highLevelPath, call.location.highLevelLine)
      let count = if childrenCount > 0:
          childrenCount
        else:
          call.children.len
      let active =
        if call.location.key == self.location.globalCallKey:
          "active"
        else:
          ""
      if count == 0:
        childlessCallView(self, call, active)
      elif not hiddenChildren or call.children.len > 0:
        isExpanded = true
        collapseCallView(self, call, CalltraceNonExpandedKind.Children, count, active)
      elif not isExpanded:
        expandCallView(self, call, count, active)

      tdiv(
        id = &"local-call-text-{key}",
        class = "call-text",
        onclick = proc =
          clog fmt"calltrace: jump onclick call key " & $key
          self.resetValueView()
          self.selectedCallNumber = self.lineIndex[call.key]
          self.lastSelectedCallKey = call.key
          self.calltraceJump(call.location)
          # TODO: send event to middleware to change status state
          # or auto-change on move events there
          # inc self.data.services.debugger.operationCount
          self.redrawCallLines()
      ):
        if key != cstring"-1 -1 -1":
          text $call.location.highLevelFunctionName & " #" & $call.key

      callArgsView(self, args, isCallstack = false, keyOrIndex = key, callDepth = depth)

      if not returnValue.isNil:
        returnValueView(self, key, call.depth, returnValue)

proc endOfProgramView*(
  self: CalltraceComponent,
  callLine: CallLineContent,
  index: int,
  depth: int
): VNode =
  let call = callLine.call
  let childrenCount = callLine.count
  let hiddenChildren = callLine.hiddenChildren
  let key = call.key

  let errorClass = if callLine.isError: "end-of-program-error" else: ""

  buildHtml(
    tdiv(class = "calltrace-child call-depth")
  ):
    tdiv(
      id = fmt"local-call--1",
      class = "call-child-box",
      onclick = proc(e: Event, tg: VNode) =
        self.calltraceJump(callLine.call.location)
    ):
      endOfProgramCallView(self, callLine.isError)
      tdiv(
        id = fmt"local-call-text-{key}",
        class = fmt"end-of-program-text {errorClass}"
      ):
        if key != cstring"-1 -1 -1":
          text call.rawName

proc hiddenCallstackView(
  self: CalltraceComponent,
  content: CallLineContent,
  index: int,
  depth: int
): VNode =
  let call = content.call
  let count = content.count
  let key = call.key

  buildHtml(
    tdiv(class = "calltrace-child call-depth")
  ):
    tdiv(
      class = "call-child-box",
      id = fmt"local-call-{key}"
    ):
      span(
        class = "toggle-call",
      )
      span(
        class = "collapse-call",
        onclick = proc(ev: Event, v: VNode) =
          if content.kind == CallLineContentKind.StartCallstackCount:
            self.depthStart = call.depth
            self.toggleCalls(EXPAND_CALLS_KIND, "0", CalltraceNonExpandedKind.Callstack, count)
          else:
            self.toggleCalls(EXPAND_CALLS_KIND, call.key, CalltraceNonExpandedKind.CallstackInternal, count)
          self.loadLines(fromScroll=false)
      ):
        if content.kind == CallLineContentKind.CallstackInternalCount:
          text fmt"{count} calls"
        else:
          text fmt"{count} callstack calls"

proc callLineContentView*(
  self: CalltraceComponent,
  content: CallLineContent,
  index: int,
  depth: int
): VNode =
  if content.kind == CallLineContentKind.EndOfProgramCall:
    endOfProgramView(self, content, index, depth)
  elif content.kind != CallLineContentKind.CallstackInternalCount and
      content.kind != CallLineContentKind.StartCallstackCount:
    callView(self, content, index, depth)
  else:
    hiddenCallstackView(self, content, index, depth)

proc callLineView*(self: CalltraceComponent, callLine: CallLine, index: int): VNode =
  let buffer = self.getStartBufferLen()

  let selected =
    if self.activeCallIndex == self.startCallLineIndex + index - buffer:
      "event-selected"
    else:
      ""

  if callLine.content.kind == CallLineContentKind.StartCallstackCount:
    self.depthStart = callLine.depth

  result = buildHtml(
    tdiv(class = fmt"calltrace-call-line calltrace-row {selected}")
  ):
    span(style = callOffset(callLine.depth - self.depthStart))
    callLineContentView(self, callLine.content, index, callLine.depth)

proc renderLine(self: CalltraceComponent, x1, y1, x2, y2: float): VNode =
  buildHtml(
    line(x1 = $x1, y1 = $y1, x2 = $x2, y2 = $y2, "stroke-width" = "0.5px")
  )

proc ensureSvgContainer(self: CalltraceComponent): VNode =
  buildHtml(
    svg(
      class = "calltrace-svg-line",
      id = fmt"svg-content-{self.id}",
      width = self.width,
      height = $(self.callLines.len() * CALL_HEIGHT_PX),
      viewBox = fmt"0 0 {self.width} {self.callLines.len() * CALL_HEIGHT_PX}",
      xmlns = "http://www.w3.org/2000/svg"
    )
  )

proc calltraceLines*(self: CalltraceComponent): VNode =
  let callLineCountLimit = self.panelHeight()
    
  # based on https://dev.to/adamklein/build-your-own-virtual-scroll-part-i-11ib
  result = buildHtml(
    tdiv(class="calltrace-lines", style=calltraceLinesStyle(self))
  ):
    ensureSvgContainer(self)
    for i, callLine in self.callLines:
      callLineView(self, callLine, i)

proc localCalltraceView*(self: CalltraceComponent): VNode =
  buildHtml(tdiv(class= &"local-calltrace")):
    tdiv(class="calltrace-lines")

proc registerSearchRes(self: CalltraceComponent, searchResults: seq[Call]) =
  self.searchResults = searchResults
  self.isSearching = true
  self.redrawForExtension()


  self.lastSearch = now()

  let current = cast[cstring](jq(".calltrace-search-input").toJs.value)

  if current.len > 0:
    self.lastChange = self.lastSearch

func findCall(call: Call, key: cstring): Call =
  if call.key == key:
    return call
  for child in call.children:
    let res = child.findCall(key)
    if not res.isNil:
      return res
  return nil

proc calltraceScroll(self: CalltraceComponent, height: int) =
  let calltraceElement = jqFind(j"#" & "calltraceScroll-" & $self.id)
  if not calltraceElement.isNil and not calltraceElement.toJs[0].isNil:
    calltraceElement.toJs[0].scrollTop = height

method onUpdatedCalltrace*(self: CalltraceComponent, results: CtUpdatedCalltraceResponseBody) {.async.} =
  self.totalCallsCount = results.totalCallsCount

  for key, res in results.args:
    self.args[key] = res

  for key, ret in results.returnValues:
    self.returnValues[key] = ret

  for i, call in results.callLines:
    self.loadedCallKeys[call.content.call.key] = i

  self.callLines = results.callLines
  self.originalCallLines = results.callLines

  let element = document.getElementById(fmt"calltrace-toggle-loading-{self.id}")

  if element != nil:
    element.style.display = "none"

  if self.forceCollapse:
    let scrollTo = max(results.scrollPosition - 2, 0)

    if results.scrollPosition > 0:
      self.calltraceScroll(scrollTo * CALL_HEIGHT_PX)
    if self.loadedCallKeys.hasKey(self.lastSelectedCallKey):
      self.activeCallIndex = self.loadedCallKeys[self.lastSelectedCallKey]
    self.forceCollapse = false
  else:
    self.redrawCallLines()

  self.redrawForExtension()

func supportCallstackOnly(self: CalltraceComponent): bool =
  not self.config.calltrace or self.locationLang() == LangRust

method register*(self: CalltraceComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtUpdatedCalltrace, proc(kind: CtEventKind, response: CtUpdatedCalltraceResponseBody, sub: Subscriber) =
    discard self.onUpdatedCalltrace(response)
  )
  api.subscribe(CtCalltraceSearchResponse, proc(kind: CtEventKind, response: seq[Call], sub: Subscriber) =
    self.registerSearchRes(response)
  )

proc registerCalltraceComponent*(component: CalltraceComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

proc loadLines(self: CalltraceComponent, fromScroll: bool) =
  if not (not self.isDbBasedTrace and fromScroll) or not self.loadedCallKeys.hasKey(self.lastSelectedCallKey):
    let depth = self.panelDepth()
    let height = self.panelHeight()
    let startBuffer = self.getStartBufferLen()
    let calltraceLoadArgs = CalltraceLoadArgs(
      location: self.location,
      startCallLineIndex: self.startCallLineIndex - startBuffer,
      depth: depth,
      height: height + CALL_BUFFER + startBuffer,
      rawIgnorePatterns: self.rawIgnorePatterns,
      optimizeCollapse: true,
      autoCollapsing: not self.loadedCallKeys.hasKey(self.lastSelectedCallKey) and self.forceCollapse
    )

    self.api.emit(CtLoadCalltraceSection, calltraceLoadArgs)

    self.loadedCallKeys = JsAssoc[cstring, int]{}
  else:
    cwarn "ignore"

proc scroll(self: CalltraceComponent) =
  let index = self.scrollLineIndex()
  self.startCallLineIndex = index
  self.loadLines(fromScroll=true)

# debouncing algorithm based on
# multiple answers to https://stackoverflow.com/questions/25991367/difference-between-throttling-and-debouncing-a-function
# and made after first throttling based on
# https://johnkavanagh.co.uk/articles/throttling-scroll-events-in-javascript/
const DELAY: int64 = 100 # milliseconds

proc afterScroll(self: CalltraceComponent) =
  let currentTime: int64 = now()
  let lastTimePlusDelay = (self.lastScrollFireTime.toJs + DELAY.toJs).to(int64)

  if lastTimePlusDelay <= currentTime:
    self.scroll()

proc eventuallyScroll(self: CalltraceComponent) =
  let currentTime: int64 = now()

  self.lastScrollFireTime = currentTime

  let element = document.getElementById(fmt"calltrace-toggle-loading-{self.id}")
  if element != nil:
    element.style.display = "block"

  discard windowSetTimeout(
    proc =
      self.afterScroll(),
      cast[int](DELAY)
  )

proc setCalltraceMutationObserver(self: CalltraceComponent) =
  let calltrace = "\"" & fmt"calltrace-data-label-{self.id}" & "\""
  let activeCalltrace = jq(fmt"[data-label={calltrace}]")

  self.resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
    for entry in entries:
      let timeout = setTimeout(proc =
        self.startPositionX = -1
        let index = self.scrollLineIndex()
        self.startCallLineIndex = index
        self.loadLines(fromScroll=false),
        100
      )
    )
  self.resizeObserver.observe(cast[Node](activeCalltrace))

proc redrawTraceLine(self: CalltraceComponent) =
  let localCalltraceElement = document.querySelector(".local-calltrace")
  let calltraceLines = localCalltraceElement.children[0]
  let scrollLeft = cast[float](jq("#" & "calltraceScroll-" & $self.id).toJs.scrollLeft)

  self.coordinates = @[]
  self.startPositionY = -1

  for callLine in calltraceLines.children[1..calltraceLines.children.len()-1]:
    let spanWidth = callLine[0].getBoundingClientRect().width
    let line = callLine.children[1]
    let rect = line.getBoundingClientRect()

    if self.startPositionX == -1:
      self.startPositionX = rect.left - spanWidth

    if self.startPositionY == -1:
      self.startPositionY = rect.top

    let x = rect.left - self.startPositionX + TRACE_LINE_OFFSET + scrollLeft
    let y = rect.top - self.startPositionY
    let bottom = rect.bottom - self.startPositionY

    self.coordinates.add((x, y, bottom))

  let svgContainer = document.getElementById(fmt"svg-content-{self.id}")

  if self.coordinates.len > 1:
    for i in 0..<self.coordinates.len:
      let topOffset = if i == 0 or i == self.coordinates.len - 1: 12.0 else: 0.0
      let (x1, y1, bottom1) = self.coordinates[i]

      if i < self.coordinates.len - 1:
        let (x2, y2, bottom2) = self.coordinates[i + 1]

        svgContainer.appendCHild(vnodeToDom(renderLine(self, x1, y1 + topOffset, x1, bottom1), KaraxInstance()))
        svgContainer.appendChild(vnodeToDom(renderLine(self, x1, bottom1, x2, bottom1), KaraxInstance()))
      else:
        svgContainer.appendCHild(vnodeToDom(renderLine(self, x1, y1, x1, bottom1 - topOffset), KaraxInstance()))

proc redrawCallLines(self: CalltraceComponent) =
  var localCalltraceElement = findElement(".local-calltrace")
  let calltraceLinesVdom = self.calltraceLines()
  let calltraceLinesDom = cast[kdom.Element](vnodeToDom(calltraceLinesVdom, KaraxInstance()))
  let calltraceLinesElement = findElement(".calltrace-lines")

  if not localCalltraceElement.isNil:
    self.width =
      if localCalltraceElement.style.width != "":
        localCalltraceElement.style.width
      else:
        self.width

    localCalltraceElement.style.height = self.calcScrollHeight()

    localCalltraceElement.replaceChild(
      calltraceLinesDom,
      calltraceLinesElement)
    self.redrawTraceLine()

  if not self.inExtension and self.resizeObserver.isNil:
    self.setCalltraceMutationObserver()

proc changeLastCallSelection(self: CalltraceComponent) =
  self.lastSelectedCallKey = self.callsByLine[self.selectedCallNumber].call.key

proc changeCallSelection(self: CalltraceComponent, key: cstring) =
  self.selectedCallNumber = self.lineIndex[key]
  self.changeLastCallSelection()
  self.data.redraw()

proc getSelectedCall(self: CalltraceComponent): Call =
  self.callsByLine[self.selectedCallNumber].call

method onLeft*(self: CalltraceComponent) {.async.} =
  let call = self.getSelectedCall()

  if not call.parent.isNil:
    self.changeCallSelection(call.parent.key)

method onRight*(self: CalltraceComponent) {.async.} =
  var call: Call = self.getSelectedCall()

  if call.children.len() > 0:
    self.changeCallSelection(call.children[0].key)

method onUp*(self: CalltraceComponent) {.async.} =
  if self.activeCallIndex > 0:
    self.activeCallIndex -= 1

    if self.activeCallIndex < self.startCallLineIndex:
      self.calltraceScroll(max((self.activeCallIndex - self.panelHeight() + 1), 0) * CALL_HEIGHT_PX)
    else:
      self.redrawCallLines()

method onDown*(self: CalltraceComponent) {.async.} =
  if self.activeCallIndex < self.totalCallsCount - 1:
    self.activeCallIndex += 1

    if self.activeCallIndex >= self.startCallLineIndex + self.panelHeight() - 1:
      self.calltraceScroll(self.activeCallIndex * CALL_HEIGHT_PX)
    else:
      self.redrawCallLines()

method onEnter*(self: CalltraceComponent) {.async.} =
  let buffer = self.getStartBufferLen()

  if self.activeCallIndex - self.startCallLineIndex + buffer < self.callLines.len():
    let callIndex = self.callLines[self.activeCallIndex - self.startCallLineIndex + buffer].content.call.key

    if self.loadedCallKeys.hasKey($callIndex):
      let callLinesIndex = self.loadedCallKeys[$callIndex]

      case self.callLines[callLinesIndex].content.kind:
      of CallLineContentKind.Call:
        let call = self.callLines[callLinesIndex].content.call

        self.resetValueView()
        
        self.lastSelectedCallKey = call.key
        self.calltraceJump(call.location)
        # TODO: middleware: stableBusy true and operationCount increase
        # either directly from all those jumps
        # or by an additional 
        # NewMove event?
        # self.data.services.debugger.stableBusy = true
        # inc self.data.services.debugger.operationCount

      of CallLineContentKind.CallstackInternalCount:
        let content = self.callLines[callLinesIndex].content

        self.toggleCalls(EXPAND_CALLS_KIND, content.call.key, CalltraceNonExpandedKind.CallstackInternal, content.count)
        self.loadLines(fromScroll=false)

      of CallLineContentKind.StartCallstackCount:
        let content = self.callLines[callLinesIndex].content

        self.depthStart = content.call.depth
        self.toggleCalls(EXPAND_CALLS_KIND, "0", CalltraceNonExpandedKind.Callstack, content.count)
        self.loadLines(fromScroll=false)

      of CallLineContentKind.NonExpanded:
        discard

      of CallLineContentKind.WithHiddenChildren:
        discard

      of CallLineContentKind.EndOfProgramCall:
        discard

method onPageUp*(self: CalltraceComponent) {.async.} =
  let index = max((self.startCallLineIndex - self.panelHeight()), 0)

  self.calltraceScroll(index * CALL_HEIGHT_PX)
  self.activeCallIndex = index
  self.redrawCallLines()

method onPageDown*(self: CalltraceComponent) {.async.} =
  let index = self.startCallLineIndex + self.panelHeight() - 1

  self.calltraceScroll(index * CALL_HEIGHT_PX)
  self.activeCallIndex = index
  self.redrawCallLines()

method onFocus*(self: CalltraceComponent) {.async.} =
  if self.activeCallIndex == NO_INDEX:
    self.activeCallIndex = self.startCallLineIndex
  elif self.activeCallIndex < self.startCallLineIndex or self.activeCallIndex > self.startCallLineIndex + self.panelHeight():
    self.calltraceScroll(self.activeCallIndex * CALL_HEIGHT_PX)

  self.redrawCallLines()

method onGotoStart*(self: CalltraceComponent) {.async.} =
  self.activeCallIndex = 0
  self.startCallLineIndex = self.activeCallIndex

  self.calltraceScroll(0)

method onGotoEnd*(self: CalltraceComponent) {.async.} =
  self.activeCallIndex = self.totalCallsCount - 1
  self.startCallLineIndex = self.totalCallsCount - self.panelHeight()

  self.calltraceScroll(self.activeCallIndex * CALL_HEIGHT_PX)

method onFindOrFilter*(self: CalltraceComponent) {.async.} =
  let forms = document.getElementsByClass(fmt"calltrace-search-form-{self.id}")

  if forms.len() > 0:
    let form = forms[0].Element
    let inputElement = form.getElementsByTagName("input".cstring)
    if inputElement.len() > 0:
      inputElement[0].focus()

method onCompleteMove*(self: CalltraceComponent, response: MoveState) {.async.} =
  self.location = response.location
  if self.loadedCallKeys.hasKey(response.location.key):
    let buffer = self.getStartBufferLen()

    self.activeCallIndex = self.startCallLineIndex + self.loadedCallKeys[response.location.key] - buffer

    if self.loadedCallKeys[response.location.key] >= self.panelHeight() - 1 + buffer:
      self.calltraceScroll((self.activeCallIndex - (self.panelHeight() / 2).floor) * CALL_HEIGHT_PX)
  elif not self.loadedCallKeys.hasKey(response.location.key):
    self.lastSelectedCallKey = response.location.key
    self.forceCollapse = true
    self.loadLines(fromScroll=false)
  self.redrawForExtension()

method render*(self: CalltraceComponent): VNode =
  self.callsByLine = @[]
  self.lineIndex = JsAssoc[cstring, int]{}

  # if self.data.trace.isNil:
  #   return buildHtml(tdiv())

  if not self.inExtension:
    kxiMap["calltraceComponent-0"].afterRedraws.add(proc = self.redrawCallLines())

  if self.inExtension:
    self.kxi.afterRedraws.add(proc = self.redrawCallLines())

  result = buildHtml(
    tdiv(
      class = componentContainerClass("calltrace-view"),
      `data-label` = fmt"calltrace-data-label-{self.id}",
      tabIndex = "2",
      onclick = proc(ev: Event, v: VNode) =
        ev.stopPropagation()
        if self.data.ui.activeFocus != self:
          self.data.ui.activeFocus = self
    )
  ):
    tdiv():
      searchCalltraceView(self)
      if not self.inExtension and not self.isDbBasedTrace:
        filterCalltraceView(self)
    if self.isCalltrace:
      tdiv(
        id = fmt"calltraceScroll-{self.id}",
        class = "local-calltrace-view",
        onscroll = proc =
          self.eventuallyScroll()
      ):
        # TODO: This is commented out only for the demo recording
        # if self.panelHeight() < self.totalCallsCount:
        #   tdiv(
        #     class = "calltrace-loading",
        #     id = fmt"calltrace-toggle-loading-{self.id}",
        #     style = style(StyleAttr.display, "none")
        #   ):
        #     text "Loading..."
        localCalltraceView(self)
    else:
      discard

proc renderRemoveButtonView(self: CallExpandedValuesComponent, key: cstring): VNode =
  buildHtml(
    tdiv(
      id = fmt"expanded-value-remove-button-{key}",
      class = "remove-expanded-value",
      onclick = proc =
        discard jsDelete(self.values[key])
    )
  ):
    text "x"

proc renderExpandedValueView(
  self:CallExpandedValuesComponent,
  key: cstring,
  value: ValueComponent,
  isLastValue: bool = false,
  isReturnValue: bool
): VNode =
  var valueClass: string

  if isReturnValue:
    valueClass = "call-expanded-value return-value"
  else:
    valueClass = "call-expanded-value"

  buildHtml(
    tdiv(class = "value-expanded")
  ):
    setExpandedValueOffset(
      self.depth,
      isLastValue,
      self.backIndentCount,
      self.callHasChildren,
      self.callIsLastChild,
      self.callIsCollapsed,
      self.callIsLastElement
    )
    tdiv(class = valueClass):
      renderExpandedValue(value)
      renderRemoveButtonView(self, key)

method render*(self: CallExpandedValuesComponent) : VNode =
  let hasReturnValue = self.values.hasKey(returnValueName)
  var lastKey = cstring""

  buildHtml(tdiv(class = "call-expanded-values-container")):
    if not hasReturnValue:
     lastKey = getLastKey(self.values)

    for key,value in self.values:
      if key == returnValueName:
        continue
      let isLastValue = key == lastKey
      renderExpandedValueView(self, key, value, isLastValue, false)

    if hasReturnValue:
      renderExpandedValueView(self, returnValueName, self.values[returnValueName], true, true)
