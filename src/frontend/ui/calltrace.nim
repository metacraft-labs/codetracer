import
  ui_imports, show_code, value, ../utils,
  ../communication, ../../common/ct_event

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The CalltraceVM receives the same data but does not affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
from ../viewmodel/store/types as vm_types import nil
from ../viewmodel/store/replay_data_store import
  ReplayDataStore, createReplayDataStore, updateCalltraceSection,
  updateDebuggerPosition, makeCallLine
from ../viewmodel/viewmodels/calltrace_vm import CalltraceVM, createCalltraceVM

# Module-level CalltraceVM instance. Created once in `register()` and
# fed data whenever the legacy event-bus handlers fire.  Rendering
# still reads from the legacy `self.callLines` so behaviour is unchanged.
var calltraceVMInstance: CalltraceVM
var calltraceVMStore: ReplayDataStore

let returnValueName: cstring = "<return value>"

const
  CALL_OFFSET_WIDTH_PX  = 20
  CALL_HEIGHT_PX        = 24
  CALL_BUFFER           = 20
  START_BUFFER          = 10
  CALLTRACE_MARKER_SELECTOR = cstring".collapse-call-img, .expand-call-img, .dot-call-img, .end-of-program-img, .active-call-location"
  CALLTRACE_TOGGLE_SELECTOR = cstring".toggle-call"
  EXPAND_CALLS_KIND     = CtExpandCalls
  COLLAPSE_CALLS_KIND   = CtCollapseCalls

proc getCurrentMonacoTheme(editor: MonacoEditor): cstring {.importjs:"#._themeService._theme.themeName".}
proc getBoundingClientRect(node: js): HTMLBoundingRect {.importjs:"#.getBoundingClientRect()".}
proc replaceChildren(node: js) {.importjs:"#.replaceChildren()".}
proc redrawCallLines(self: CalltraceComponent)
proc loadLines(self: CalltraceComponent, fromScroll: bool)

when defined(ctInExtension):
  var calltraceComponentForExtension* {.exportc.}: CalltraceComponent = makeCalltraceComponent(data, 0, inExtension = true)

  proc makeCalltraceComponentForExtension*(id: cstring): CalltraceComponent {.exportc.} =
    if calltraceComponentForExtension.kxi.isNil:
      calltraceComponentForExtension.kxi = setRenderer(proc: VNode = calltraceComponentForExtension.render(), id, proc = discard)
    result = calltraceComponentForExtension

proc calltraceJump(self: CalltraceComponent, location: types.Location) =
  # if not self.supportCallstackOnly:
  self.api.emit(CtCalltraceJump, location)
  self.api.emit(InternalNewOperation, NewOperation(stableBusy: true, name: "calltrace-jump"))
  # else:
    # self.callstackJump(location.depth)

# proc callstackJump(self: CalltraceComponent, depth: int) =
#   self.api.emit(CtCallstackJump, location)
#   self.api.emit(InternalNewOperation, NewOperation(stableBusy: true, name: "calltrace-jump"))

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
  if self.inExtension:
    ev.preventDefault()
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

proc createContextMenuItems(self: CallArg, component: CalltraceComponent, ev: js): seq[ContextMenuItem] =
  var addToScratchpad:  ContextMenuItem
  var contextMenu:      seq[ContextMenuItem]

  addToScratchpad =
    ContextMenuItem(
      name: "Add value to scratchpad",
      hint: "CTRL+&lt;click on value&gt;",
      handler: proc(e: Event) =
        component.api.emit(InternalAddToScratchpad, ValueWithExpression(expression: self.name, value: self.value))
    )
  contextMenu &= addToScratchpad

  return contextMenu

proc `$`*(c: CallCount): string =
  case c.kind:
  of Equal:
    $c.i
  of GreaterOrEqual:
    &">= {c.i}"
  of LessOrEqual:
    &"<= {c.i}"
  of Greater:
    &"> {c.i}"
  of Less:
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
  style((StyleAttr.minWidth, cstring(&"{depth * 8}px")))

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
          self.api.emit(
            InternalAddToScratchpad,
            ValueWithExpression(
              expression: arg.name,
              value: arg.value
            )
          )
        elif not self.modalValueComponent.hasKey(id):
          self.resetValueView()
          showCallValue(self, arg, keyOrIndex)
          self.calcValueLeftPosition(ev, id)
        else:
          if not self.forceRerender[id]:
            self.resetValueView()
          self.calcValueLeftPosition(ev, id)
          self.forceRerender[id] = not self.forceRerender[id]
        self.redraw(),
      oncontextmenu = proc(ev: Event, v: VNode) {.gcsafe.} =
        let e = ev.toJs
        ev.stopPropagation()
        let contextMenu = arg.createContextMenuItems(self, e)
        if contextMenu != @[]:
            showContextMenu(contextMenu, cast[int](e.x), cast[int](e.y), self.inExtension)
    )
  ):
    let value = arg.value.textRepr
    tdiv(class = "call-arg-header", id = &"call-arg-header-{keyOrIndex}-{arg.name}"):
      tdiv(class = "call-arg-name", id = &"call-arg-name-{keyOrIndex}-{arg.name}"):
        text &"{arg.name}="
      tdiv(class = "call-arg-text", id = &"call-arg-text-{keyOrIndex}-{arg.name}"):
        text value

proc ensureValueComponent(self: CallExpandedValuesComponent, name: cstring, value: Value) =
  if not self.values.hasKey(name):
     self.values[name] = ValueComponent(
       expanded: JsAssoc[cstring, bool]{},
       charts: JsAssoc[cstring, ChartComponent]{},
       showInline: JsAssoc[cstring, bool]{},
       baseExpression: name,
       baseValue: value,
       stateID: -1,
       data: self.data,
       nameWidth: VALUE_COMPONENT_NAME_WIDTH,
       valueWidth: VALUE_COMPONENT_VALUE_WIDTH)
     self.data.registerComponent(self.values[name], Content.Value)

proc makeCallExpandedValueComponent(data: Data, callDepth: int): CallExpandedValuesComponent =
  result = CallExpandedValuesComponent(
    values: JsAssoc[cstring, ValueComponent]{},
    depth: callDepth
  )
  data.registerComponent(result, Content.CallExpandedValue)

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
  let ticksText = if self.usesMaterializedTracesTrace: "stepId" else: "rrTicks"

  buildHtml(
    tdiv(
      class = "search-result",
      onmousedown = proc =
        self.calltraceJump(location)
        self.redraw()
    )
  ):
    text &"#{location.key} - {ticksText}({location.rrTicks}): {location.highLevelFunctionName}"


proc emptyResultView(self: CalltraceComponent): VNode =
  buildHtml(
    tdiv(
      class = "empty-search-result",
      onclick = proc =
        self.isSearching = false
        self.redraw()
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

func calltraceSearchInputId(self: CalltraceComponent): cstring =
  cstring(fmt"calltrace-search-input-{self.id}")

proc submitCalltraceSearch(self: CalltraceComponent) =
  let query = if self.searchText.isNil: cstring"" else: self.searchText

  if query.len == 0:
    self.searchResults = @[]
    self.isSearching = false
    self.redraw()
    return

  self.lastQuery = query
  self.api.emit(CtSearchCalltrace, CallSearchArg(value: query))

proc searchCalltraceView(self: CalltraceComponent): VNode =
  let onSearch = proc(ev: KeyboardEvent, v: VNode) =
    if ev.keyCode == ENTER_KEY_CODE:
      ev.preventDefault()
      ev.stopPropagation()
      self.searchText = cast[cstring](ev.target.toJs.value)
      self.submitCalltraceSearch()

  buildHtml(
    tdiv(class = "calltrace-search")
  ):
    form(
      class = &"calltrace-search-form-{self.id}",
      onsubmit = proc(ev: Event, v: VNode) =
        ev.preventDefault()
        ev.stopPropagation()
        self.submitCalltraceSearch()
    ):
      input(
        tabIndex = "0",
        id = self.calltraceSearchInputId(),
        class = fmt"calltrace-search-input calltrace-search-input-{self.id} ct-input-panel ct-input-search-image",
        `type` = "text",
        value = if self.searchText.isNil: cstring"" else: self.searchText,
        placeholder = "Search",
        oninput = proc(ev: Event, v: VNode) =
          self.searchText = cast[cstring](ev.target.toJs.value)
          if self.searchText.len == 0 and (self.isSearching or self.searchResults.len > 0):
            self.searchResults = @[]
            self.isSearching = false
            self.redraw()
        ,
        onkeydown = onSearch,
        onblur = proc() =
          self.isSearching = false
      )

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

        self.redraw()

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
          showContextMenu(contextMenu, cast[int](e.x), cast[int](e.y), self.inExtension)
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
        if self.usesMaterializedTracesTrace:
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
          self.redrawCallLines()
      ):
        if key != cstring"-1 -1 -1":
          text $call.location.highLevelFunctionName & " #" & $call.key

        # Continuation jump link: show ↗ icon if this call has an async continuation
        if self.continuationsByCallKey.hasKey(key):
          let link = self.continuationsByCallKey[key]
          span(
            class = "continuation-jump-link",
            title = cstring("Jump to continuation (" & $link.linkType & ")"),
          ):
            proc onclick(ev: Event, v: VNode) =
              ev.stopPropagation()
              # Seek to the continuation GEID
              console.log("Jump to continuation at GEID ", link.continuationGEID)
              # In full integration: self.api.emit(CtSeekToGEID, link.continuationGEID)
            text "↗"

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
    if self.usesMaterializedTracesTrace:
      hiddenCallstackView(self, content, index, depth)
    else:
      buildHtml(tdiv())

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
    if self.usesMaterializedTracesTrace:
      span(style = callOffset(callLine.depth - self.depthStart))
    callLineContentView(self, callLine.content, index, callLine.depth)

proc updateTooltipOrigin(self: CalltraceComponent, callLine: kdom.Node) =
  if self.startPositionX != -1:
    return

  let rowRect = getBoundingClientRect(callLine.toJs)
  self.startPositionX = rowRect.left + self.scrollLeftOffset

proc syncSvgContainerBounds(svgContainer: Element, width, height: float) =
  let safeWidth = max(width, 1.0)
  let safeHeight = max(height, 1.0)

  svgContainer.setAttribute(cstring"width", cstring($safeWidth))
  svgContainer.setAttribute(cstring"height", cstring($safeHeight))
  svgContainer.setAttribute(cstring"viewBox", cstring(fmt"0 0 {safeWidth} {safeHeight}"))

proc ensureSvgContainer(self: CalltraceComponent): VNode =
  buildHtml(
    svg(
      class = "calltrace-svg-line",
      id = fmt"svg-content-{self.id}",
      width = "1",
      height = "1",
      viewBox = "0 0 1 1",
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
    if self.usesMaterializedTracesTrace:
      for i, callLine in self.callLines:
        callLineView(self, callLine, i)
    else:
      for i in countdown(self.callLines.len - 1, 0):
        callLineView(self, self.callLines[i], i)

proc localCalltraceView*(self: CalltraceComponent): VNode =
  buildHtml(tdiv(class= &"local-calltrace")):
    tdiv(class="calltrace-lines")

proc registerSearchRes(self: CalltraceComponent, searchResults: seq[Call]) =
  let current = if self.searchText.isNil: cstring"" else: self.searchText

  self.lastSearch = now()

  if current.len > 0:
    self.searchResults = searchResults
    self.isSearching = true
    self.lastChange = self.lastSearch
  else:
    self.searchResults = @[]
    self.isSearching = false

  self.redraw()

func findCall(call: Call, key: cstring): Call =
  if call.key == key:
    return call
  for child in call.children:
    let res = child.findCall(key)
    if not res.isNil:
      return res
  return nil

proc calltraceScroll(self: CalltraceComponent, height: int) =
  let calltraceElement = jqFind(cstring"#" & "calltraceScroll-" & $self.id)
  if not calltraceElement.isNil and not calltraceElement.toJs[0].isNil:
    calltraceElement.toJs[0].scrollTop = height

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# Placed before onUpdatedCalltrace / onCompleteMove so they are visible at
# the call sites without forward declarations.
# ---------------------------------------------------------------------------

proc initCalltraceVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel CalltraceVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel
  ## which is backed by a real DapApi).  If the CalltraceVM has already
  ## been created this is a no-op — the first caller wins.
  if calltraceVMInstance != nil:
    return
  calltraceVMStore = store
  calltraceVMInstance = createCalltraceVM(store)
  clog "CalltraceVM: parallel ViewModel instance created (shared store)"

proc initCalltraceVM() =
  ## Lazily create the parallel CalltraceVM instance backed by a stub
  ## BackendService.  This fallback is used when no shared store has
  ## been provided via `initCalltraceVMWithStore` (e.g. in the VS Code
  ## extension where the SessionViewModel is not yet wired).
  if calltraceVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    # Return an immediately-resolved future so the store's loading
    # state transitions correctly but no real I/O happens.
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

  calltraceVMStore = createReplayDataStore(stubBackend)
  calltraceVMInstance = createCalltraceVM(calltraceVMStore)
  clog "CalltraceVM: parallel ViewModel instance created (stub backend)"

proc syncCalltraceData(results: CtUpdatedCalltraceResponseBody) =
  ## Mirror the legacy calltrace section data into the ViewModel store
  ## so the CalltraceVM's visibleLines memo sees the same data.
  if calltraceVMStore.isNil:
    return
  var vmLines: seq[vm_types.CallLine] = @[]
  for callLine in results.callLines:
    let call = callLine.content.call
    let loc = call.location
    vmLines.add(makeCallLine(
      name = $loc.highLevelFunctionName,
      depth = callLine.depth,
      rrTicks = cast[uint64](loc.rrTicks),
      file = $loc.highLevelPath,
      line = loc.highLevelLine,
    ))
  calltraceVMStore.updateCalltraceSection(
    vmLines,
    startIndex = 0'i64,
    totalCount = cast[uint64](results.totalCallsCount),
  )
  clog fmt"CalltraceVM: synced {vmLines.len} calltrace lines into store"

proc syncCalltraceDebuggerPosition(rrTicks: int, path: cstring, line: int) =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the CalltraceVM's reactive pipeline sees the same rrTicks value.
  if calltraceVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  calltraceVMStore.updateDebuggerPosition(ticks, $path, line)
  clog fmt"CalltraceVM: synced debugger rrTicks={ticks}"

method onUpdatedCalltrace*(self: CalltraceComponent, results: CtUpdatedCalltraceResponseBody) {.async.} =
  self.totalCallsCount = results.totalCallsCount

  # Feed the same data into the parallel ViewModel store.
  syncCalltraceData(results)

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

  self.redraw()

# proc processStackFrame*(self: CalltraceComponent, index: int, frame: DapStackFrame) =
#   # TODO
#   discard

# method onUpdatedStackTrace(self: CalltraceComponent, frames: seq[DapStackFrame]) =
#   self.callLines = @[]
#   self.args = JsAssoc[cstring, seq[CallKey]]()
#   self.returnValues = JsAssoc[cstring, Value]()
#   for i, frame in self.stackFrameToCallLine:
#     self.processStackFrame(i, frame)
#   self.redrawCallLines()
#   self.redraw()

func supportCallstackOnly(self: CalltraceComponent): bool =
  not self.config.calltrace or self.locationLang() == LangRust or not self.usesMaterializedTracesTrace


method register*(self: CalltraceComponent, api: MediatorWithSubscribers) =
  self.api = api

  # Initialize the parallel ViewModel instance (no-op if already created).
  initCalltraceVM()

  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtUpdatedCalltrace, proc(kind: CtEventKind, response: CtUpdatedCalltraceResponseBody, sub: Subscriber) =
    discard self.onUpdatedCalltrace(response)
  )
  api.subscribe(CtCalltraceSearchResponse, proc(kind: CtEventKind, response: seq[Call], sub: Subscriber) =
    self.registerSearchRes(response)
  )
  api.emit(InternalLastCompleteMove, EmptyArg())

proc registerCalltraceComponent*(component: CalltraceComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

proc loadLines(self: CalltraceComponent, fromScroll: bool) =
  if not self.usesMaterializedTracesTrace or not (not self.usesMaterializedTracesTrace and fromScroll) or not self.loadedCallKeys.hasKey(self.lastSelectedCallKey):
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
      autoCollapsing: not self.loadedCallKeys.hasKey(self.lastSelectedCallKey) and self.forceCollapse,
      renderCallLineIndex: 0,
    )

    echo "LOAD CALLTRACE SECTION"
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
  if not activeCalltrace.isNil:
    self.resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
      for entry in entries:
        let timeout = setTimeout((proc =
          let scrollPosition = jq(fmt"#calltraceScroll-{self.id}")
          self.startPositionX = -1
          self.scrollLeftOffset =
            if not scrollPosition.isNil:
              cast[float](scrollPosition.toJs.scrollLeft)
            else:
              0
          try:
            let index = self.scrollLineIndex()
            self.startCallLineIndex = index
            self.loadLines(fromScroll=false)
          except:
            cwarn "scroll or load lines exception in mutation observer: ok if in editor mode"),
          100
        )
      )
    self.resizeObserver.observe(cast[Node](activeCalltrace))

proc redrawTraceLine(self: CalltraceComponent) =
  let scrollElement = jq(cstring(fmt"#calltraceScroll-{self.id}"))
  let svgContainer = document.getElementById(fmt"svg-content-{self.id}")

  if scrollElement.isNil or svgContainer.isNil:
    return

  let localCalltraceNode = findNodeInElement(cast[kdom.Node](scrollElement), ".local-calltrace")
  if localCalltraceNode.isNil:
    return
  let localCalltraceElement = cast[Element](localCalltraceNode)

  let calltraceLinesNode = findNodeInElement(cast[kdom.Node](localCalltraceElement), ".calltrace-lines")
  if calltraceLinesNode.isNil:
    return
  let calltraceLinesElement = cast[Element](calltraceLinesNode)

  let scrollLeft = cast[float](scrollElement.toJs.scrollLeft)
  self.scrollLeftOffset = scrollLeft
  let calltraceLinesRect = calltraceLinesElement.getBoundingClientRect()
  let svgWidth = max(cast[float](scrollElement.toJs.scrollWidth), calltraceLinesRect.width + scrollLeft)
  let svgHeight = max(cast[float](calltraceLinesElement.scrollHeight), calltraceLinesRect.height)
  var coordinates: seq[tuple[x, top, center, bottom: float]] = @[]

  self.startPositionX = -1
  self.startPositionY = -1
  replaceChildren(svgContainer.toJs)
  svgContainer.syncSvgContainerBounds(svgWidth, svgHeight)

  for callLine in findAllNodesInElement(cast[kdom.Node](calltraceLinesElement), ".calltrace-call-line"):
    self.updateTooltipOrigin(callLine)

    let rowRect = getBoundingClientRect(callLine.toJs)
    var marker = findNodeInElement(callLine, CALLTRACE_MARKER_SELECTOR)
    if marker.isNil:
      marker = findNodeInElement(callLine, CALLTRACE_TOGGLE_SELECTOR)
    if marker.isNil:
      continue

    let markerRect = getBoundingClientRect(marker)
    let rowTop = rowRect.top - calltraceLinesRect.top
    let rowBottom = rowRect.bottom - calltraceLinesRect.top
    let centerY = min(max(markerRect.top + (markerRect.height / 2.0) - calltraceLinesRect.top, rowTop), rowBottom)
    let centerX = markerRect.left + (markerRect.width / 2.0) - calltraceLinesRect.left + scrollLeft

    coordinates.add((centerX, rowTop, centerY, rowBottom))

  if coordinates.len > 1:
    for i in 0..<coordinates.len:
      let (x1, top1, center1, bottom1) = coordinates[i]
      let startY = if i == 0: center1 else: top1
      let endY = if i == coordinates.high: center1 else: bottom1

      if endY > startY:
        cast[Node](svgContainer).appendChild(cast[Node](renderLineElement(x1, startY, x1, endY)))

      if i < coordinates.high:
        let (x2, _, _, _) = coordinates[i + 1]
        cast[Node](svgContainer).appendChild(cast[Node](renderLineElement(x1, bottom1, x2, bottom1)))

proc refreshTraceOverlay*(self: CalltraceComponent) =
  if self.usesMaterializedTracesTrace:
    self.redrawTraceLine()

proc redrawCallLines(self: CalltraceComponent) =
  let scrollElement = jq(cstring(fmt"#calltraceScroll-{self.id}"))
  let calltraceLinesVdom = self.calltraceLines()
  let calltraceLinesDom = cast[kdom.Element](vnodeToDom(calltraceLinesVdom, KaraxInstance()))
  let localCalltraceNode =
    if scrollElement.isNil:
      nil
    else:
      findNodeInElement(cast[kdom.Node](scrollElement), ".local-calltrace")
  let calltraceLinesNode =
    if localCalltraceNode.isNil:
      nil
    else:
      findNodeInElement(cast[kdom.Node](localCalltraceNode), ".calltrace-lines")

  if not localCalltraceNode.isNil and not calltraceLinesNode.isNil:
    let localCalltraceElement = cast[Element](localCalltraceNode)
    let calltraceLinesElement = cast[Node](calltraceLinesNode)

    localCalltraceElement.style.height = self.calcScrollHeight()

    localCalltraceElement.replaceChild(
      cast[Node](calltraceLinesDom),
      calltraceLinesElement)
    if self.usesMaterializedTracesTrace:
      self.redrawTraceLine()

  if not self.inExtension and self.resizeObserver.isNil:
    self.setCalltraceMutationObserver()

proc changeLastCallSelection(self: CalltraceComponent) =
  self.lastSelectedCallKey = self.callsByLine[self.selectedCallNumber].call.key

proc changeCallSelection(self: CalltraceComponent, key: cstring) =
  self.selectedCallNumber = self.lineIndex[key]
  self.changeLastCallSelection()
  self.redraw()

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

  # Mirror the debugger position into the parallel ViewModel store.
  syncCalltraceDebuggerPosition(
    response.location.rrTicks, response.location.path, response.location.line)

  #TODO: pass explicitly in trace as trace kind/in init/other way?
  let lang = toLangFromFilename(self.location.path)
  if not self.usesMaterializedTracesTraceSet:
    self.usesMaterializedTracesTrace = lang != LangUnknown and lang.usesMaterializedTraces
    self.usesMaterializedTracesTraceSet = true

  # for rr traces: try to always load lines again!
  #   eventually when we have a reliable key, maybe check again
  echo "ON COMPLETE MOVE; is db?: ", self.usesMaterializedTracesTrace
  if self.usesMaterializedTracesTrace and self.loadedCallKeys.hasKey(response.location.key):
    let buffer = self.getStartBufferLen()

    self.activeCallIndex = self.startCallLineIndex + self.loadedCallKeys[response.location.key] - buffer

    if self.loadedCallKeys[response.location.key] >= self.panelHeight() - 1 + buffer:
      self.calltraceScroll((self.activeCallIndex - (self.panelHeight() / 2).floor) * CALL_HEIGHT_PX)
  elif not self.usesMaterializedTracesTrace or not self.loadedCallKeys.hasKey(response.location.key):
    self.lastSelectedCallKey = response.location.key
    self.forceCollapse = true
    echo "LOAD LINES"
    self.loadLines(fromScroll=false)
  self.redraw()

proc asyncFlowToggleView(self: CalltraceComponent): VNode =
  ## Renders the Real/Virtual call trace mode toggle.
  ## Only visible when the current view has async continuation data.
  if self.continuationLinks.len == 0:
    return buildHtml(tdiv())  # Hidden when no async data

  buildHtml(
    tdiv(class = "calltrace-async-toggle")
  ):
    span(class = "async-toggle-label"):
      text "Call Trace:"
    tdiv(class = "async-toggle-buttons"):
      let realClass = if self.asyncFlowMode == afmReal: "toggle-btn active" else: "toggle-btn"
      let virtualClass = if self.asyncFlowMode == afmVirtual: "toggle-btn active" else: "toggle-btn"
      button(class = cstring(realClass)):
        proc onclick(ev: Event, v: VNode) =
          self.asyncFlowMode = afmReal
        text "Real"
      button(class = cstring(virtualClass)):
        proc onclick(ev: Event, v: VNode) =
          self.asyncFlowMode = afmVirtual
        text "Virtual"

proc setContinuationLinks*(self: CalltraceComponent, links: seq[ContinuationLinkInfo]) =
  ## Called by the backend when continuation links are discovered.
  ## Builds the lookup table mapping registration GEIDs to their links
  ## so the call view can show jump icons next to await expressions.
  self.continuationLinks = links
  self.continuationsByCallKey = JsAssoc[cstring, ContinuationLinkInfo]{}
  for link in links:
    # Map the registration GEID to the link.
    # The call key format depends on the trace type;
    # for now, use the GEID as the key string.
    let key = cstring($link.registrationGEID)
    self.continuationsByCallKey[key] = link

proc setAsyncThreads*(self: CalltraceComponent, threads: seq[AsyncThreadInfo]) =
  ## Called by the backend when async thread groupings are discovered.
  self.asyncThreads = threads

method render*(self: CalltraceComponent): VNode =
  self.callsByLine = @[]
  self.lineIndex = JsAssoc[cstring, int]{}

  # if self.data.trace.isNil:
  #   return buildHtml(tdiv())

  if self.inExtension:
    self.kxi.afterRedraws.add(proc = self.redrawCallLines())
  else:
    if not self.kxi.isNil:
      self.kxi.afterRedraws.add(proc =
        self.redrawCallLines()
      )

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
      asyncFlowToggleView(self)
      # TODO: not ready for rr traces too: for now just comment out!
      # if not self.inExtension and not self.usesMaterializedTracesTrace:
      #  filterCalltraceView(self)
    if self.service.isCalltrace:
      if self.asyncFlowMode == afmVirtual:
        tdiv(class = "calltrace-virtual-placeholder"):
          text "Virtual call trace: follow the ↗ links to navigate async continuations"
      else:
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
