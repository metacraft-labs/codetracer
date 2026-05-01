import
  ui_imports, colors, typetraits, strutils, base64,
  ../[ types, communication ],
  ../../common/ct_event

# ---------------------------------------------------------------------------
# ViewModel layer — IsoNim is the primary renderer.
#
# The legacy Karax `method render` was dropped in favour of an IsoNim
# view (`viewmodel/views/isonim_terminal_output_view.nim`) that mounts
# directly into the GoldenLayout container. The legacy
# `TerminalOutputComponent` retains its event-bus subscriptions so the
# frontend's existing wiring (CtLoadedTerminal, CtUpdatedEvents,
# CtCompleteMove) keeps feeding data; the component now mirrors every
# update into a `TerminalOutputVM` whose signals drive the IsoNim view.
# ---------------------------------------------------------------------------

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  TerminalLine, TerminalEventFragment
from ../viewmodel/viewmodels/terminal_output_vm import
  TerminalOutputVM, createTerminalOutputVM, setLines, clearLines,
  setCurrentRRTicks
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_terminal_output_view import
  mountIsoNimTerminalOutput

var newAnsiUp* {.importcpp: "new AnsiUp".}: proc: js
let ansiUp {.exportc.} = newAnsiUp()

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls. Mirrors
# the pattern used by the event-log and calltrace migrations.
var terminalOutputVMInstance: TerminalOutputVM
var terminalOutputVMStore: ReplayDataStore
var terminalOutputComponentRef: TerminalOutputComponent
var isoNimTerminalOutputMounted*: bool = false

proc tryMountIsoNimTerminalOutputPanel()

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initTerminalOutputVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel ``TerminalOutputVM`` using an externally
  ## provided ``ReplayDataStore`` (typically the shared store from
  ## ``SessionViewModel``). If a stub-backed instance already exists
  ## (created by ``initTerminalOutputVM`` before the real backend was
  ## available) it is replaced so the panel uses the real backend.
  if terminalOutputVMInstance != nil:
    clog "TerminalOutputVM: replacing existing instance with shared-store version"
    isoNimTerminalOutputMounted = false
  terminalOutputVMStore = store
  terminalOutputVMInstance = createTerminalOutputVM(store)
  clog "TerminalOutputVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimTerminalOutputPanel()

proc initTerminalOutputVM() =
  ## Lazily create the parallel ``TerminalOutputVM`` backed by a stub
  ## ``BackendService``. Fallback when no shared store has been
  ## provided via ``initTerminalOutputVMWithStore``.
  if terminalOutputVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
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

  terminalOutputVMStore = createReplayDataStore(stubBackend)
  terminalOutputVMInstance = createTerminalOutputVM(terminalOutputVMStore)
  clog "TerminalOutputVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimTerminalOutputPanel()

proc tryMountIsoNimTerminalOutputPanel() =
  ## Mount the IsoNim terminal-output view into the GoldenLayout-managed
  ## container. The container is created by GoldenLayout under the id
  ## ``terminalComponent-{id}`` (note the truncation — the default
  ## layout JSON in ``src/config/default_layout.json`` and the
  ## Playwright page object ``terminal-output-pane.ts`` both use the
  ## ``terminalComponent`` prefix rather than the
  ## ``convertComponentLabel`` ``terminalOutputComponent`` form).
  ## The terminal panel is a singleton (id always 0) but we still
  ## resolve through the registered component's id field for symmetry
  ## with the other IsoNim mounts.
  ##
  ## Safe to call multiple times — mounts only once. The retry loop
  ## handles GoldenLayout's asynchronous container creation: the
  ## container appears slightly after the layout state changes so we
  ## back off and retry until it lands (capped at 200 attempts, ~2 s).
  if isoNimTerminalOutputMounted or terminalOutputVMInstance.isNil:
    return
  if terminalOutputComponentRef.isNil:
    return

  let key = cstring("terminalComponent-" & $terminalOutputComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimTerminalOutputMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimTerminalOutputPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    # Replace any prior content (Karax may have planted a stub element
    # before the IsoNim mount fires).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimTerminalOutputMounted = true
    try:
      mountIsoNimTerminalOutput(container, terminalOutputVMInstance)
    except:
      cerror "tryMountIsoNimTerminalOutputPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

  doMount()

# ---------------------------------------------------------------------------
# Legacy line-cache logic (kept verbatim — converts ANSI-decorated
# program events into one ``TerminalEvent`` per text run, grouped by
# line). After the cache is rebuilt we mirror the data into the VM.
# ---------------------------------------------------------------------------

proc splitNewLines(text: cstring): seq[cstring] =
  text.split("\n")

proc ensureLine(self: TerminalOutputComponent) =
  if not self.cachedLines.hasKey(self.currentLine):
    self.cachedLines[self.currentLine] = @[]

proc appendToTerminalLine(self: TerminalOutputComponent, text: cstring, eventIndex: int) =
  self.ensureLine()
  var lineTerminalEvents = self.cachedLines[self.currentLine]

  lineTerminalEvents.add(TerminalEvent(
    text: text,
    eventIndex: eventIndex))

  self.cachedLines[self.currentLine] = lineTerminalEvents

proc addTerminalLine(self: TerminalOutputComponent, text: cstring, eventIndex: int) =
  self.appendToTerminalLine(text, eventIndex)
  self.currentLine += 1

when defined(ctInExtension):
  var terminalOutputComponentForExtension* {.exportc.}: TerminalOutputComponent = makeTerminalOutputComponent(data, 0, inExtension = true)

  proc makeTerminalOutputComponentForExtension*(id: cstring): TerminalOutputComponent {.exportc.} =
    if terminalOutputComponentForExtension.kxi.isNil:
      terminalOutputComponentForExtension.kxi = setRenderer(proc: VNode = terminalOutputComponentForExtension.render(), id, proc = discard)
    result = terminalOutputComponentForExtension

proc getLines(self: TerminalOutputComponent) =
  self.api.emit(CtLoadTerminal, EmptyArg())

proc cacheAnsiToHtmlLines(self: TerminalOutputComponent, eventList: seq[ProgramEvent]) =
  var raw = ""
  let regExPattern = regex("(<span[^>]*>)(.*?)(<\\/span>)")
  var nextLineStart: cstring = ""
  self.cachedEvents = eventList
  self.cachedLines = JsAssoc[int, seq[TerminalEvent]]{}
  self.lineEventIndices = JsAssoc[int, int]{}
  self.currentLine = 0

  for eventIndex, event in eventList:
    var content =
      if event.base64Encoded:
        cstring(decode($event.content))
      else:
        event.content
    var lines: seq[cstring] = @[]

    if content.len > 0:
      let html = cast[cstring](ansiUp.ansi_to_html(content))
      let matches = html.matchAll(regExPattern)
      var startIndex = 0

      if matches.len > 0:
        for match in matches:
          let preMatchText = html.slice(startIndex, match.index)

          # check if there is a text before the html tag
          if preMatchText.len > 0:
            # split it by new line "\n" and check if there is more than one results
            let tokens = preMatchText.split(jsNl)

            if tokens.len > 1:
              for j in 0..tokens.len - 2:
                self.addTerminalLine(tokens[j], eventIndex)
              nextLineStart = tokens[^1]
            else:
              self.appendToTerminalLine(nextLineStart & tokens[^1], eventIndex)

          let startTag = match[1]
          let endTag = match[3]
          let text = match[2]
          let tokens = text.split(jsNl)

          if tokens.len > 1:
            self.addTerminalLine(
              nextLineStart & startTag & tokens[0] & endTag,
              eventIndex)

            for j in 1..tokens.len - 2:
              self.addTerminalLine(startTag & tokens[j] & endTag, eventIndex)
            nextLineStart = startTag & tokens[^1] & endTag
          else:
            self.appendToTerminalLine(
              nextLineStart & startTag & tokens[^1] & endTag,
              eventIndex)

          startIndex = match.index + match[0].len

        let postMatchText = html.slice(startIndex)

        # check if there is a text after the last html tag
        if postMatchText.len > 0:
          # split it by new line "\n" and check if there is more than one results
          let tokens = postMatchText.split(jsNl)

          if tokens.len > 1:
            self.addTerminalLine(nextLineStart & tokens[0], eventIndex)

            for j in 1..tokens.len - 2:
              self.addTerminalLine(tokens[j], eventIndex)

            nextLineStart = tokens[^1]
          else:
            self.appendToTerminalLine(nextLineStart & tokens[^1], eventIndex)
      else:
        if html.len > 0:
          # split it by new line "\n" and check if there is more than one results
          let tokens = html.split(jsNl)

          if tokens.len > 1:
            self.addTerminalLine(nextLineStart & tokens[0], eventIndex)

            for j in 1..tokens.len - 2:
              self.addTerminalLine(tokens[j], eventIndex)

            nextLineStart = tokens[^1]
          else:
            self.appendToTerminalLine(nextLineStart & tokens[^1], eventIndex)

# ---------------------------------------------------------------------------
# VM sync — convert the JS line cache into platform-neutral
# ``TerminalLine`` values and push them through ``setLines``.
# ---------------------------------------------------------------------------

proc syncTerminalOutputVM(self: TerminalOutputComponent) =
  ## Mirror the legacy line cache into the IsoNim ``TerminalOutputVM``.
  ## Builds one ``TerminalLine`` per ``self.cachedLines`` row and one
  ## ``TerminalEventFragment`` per ``TerminalEvent``. The fragment's
  ## ``rrTicks`` is taken from the corresponding ``ProgramEvent`` so the
  ## view's past/active/future class flips track the debugger position.
  if terminalOutputVMInstance.isNil:
    return

  var lines: seq[TerminalLine] = @[]
  # ``cachedLines`` is keyed by line index but stored in a JsAssoc; iterate
  # by integer index from 0..max so output stays line-ordered. The legacy
  # render path used the same iteration via ``self.cachedLines.len()``.
  let maxLine = self.cachedLines.len()
  for i in 0 ..< maxLine:
    if not self.cachedLines.hasKey(i):
      continue
    let lineEvents = self.cachedLines[i]
    var fragments: seq[TerminalEventFragment] = @[]
    for ev in lineEvents:
      let event = self.cachedEvents[ev.eventIndex]
      fragments.add(TerminalEventFragment(
        htmlText: $ev.text,
        eventIndex: ev.eventIndex,
        rrTicks: cast[uint64](event.directLocationRRTicks),
      ))
    lines.add(TerminalLine(lineIndex: i, fragments: fragments))

  terminalOutputVMInstance.setLines(lines)

proc syncTerminalOutputDebuggerPosition(rrTicks: int) =
  ## Mirror the debugger's rrTicks into the VM's ``currentRRTicks``
  ## signal. Triggers the IsoNim view's per-fragment colour effect so
  ## past/active/future classes track the user's position.
  if terminalOutputVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  terminalOutputVMStore.updateDebuggerPosition(ticks, "", 0)
  if not terminalOutputVMInstance.isNil:
    terminalOutputVMInstance.setCurrentRRTicks(ticks)

# ---------------------------------------------------------------------------
# Component event handlers
# ---------------------------------------------------------------------------

method onLoadedTerminal*(self: TerminalOutputComponent, eventList: seq[ProgramEvent]) {.async.} =
  self.initialUpdate = false
  self.cacheAnsiToHtmlLines(eventList)
  self.syncTerminalOutputVM()


proc onTerminalEventClick(self: TerminalOutputComponent, eventElement: ProgramEvent) =
  self.api.emit(CtEventJump, eventElement)
  self.api.emit(InternalNewOperation, NewOperation(name: "event jump", stableBusy: true))

method onOutputJumpFromShellUi*(self: TerminalOutputComponent, response: int) {.async.} =
  if self.cachedLines[response].len > 0:
    let eventElement = self.cachedEvents[self.cachedLines[response][0].eventIndex]

    self.onTerminalEventClick(eventElement)

method restart*(self: TerminalOutputComponent) =
  self.cachedLines = JsAssoc[int, seq[TerminalEvent]]{}
  self.cachedEvents = @[]
  self.lineEventIndices = JsAssoc[int, int]{}
  self.currentLine = 0
  self.initialUpdate = true
  self.renderedEventIndex = 0
  self.location = types.Location()
  if not terminalOutputVMInstance.isNil:
    terminalOutputVMInstance.clearLines()

# TerminalOutputComponent.render() removed: IsoNim is the primary
# renderer.  The base ``Component.render()`` returns a valid empty
# VNode for any generic callers (auto-hide, vnodeToDom bridge); all
# real DOM construction happens in
# ``viewmodel/views/isonim_terminal_output_view.nim``.

method register*(self: TerminalOutputComponent, api: MediatorWithSubscribers) =
  self.api = api

  # Lazily create the VM and remember the component so the IsoNim
  # mount procedure can find both. ``initTerminalOutputVM`` is a no-op
  # if a shared-store instance was already installed by
  # ``configureMiddleware``.
  initTerminalOutputVM()
  if terminalOutputComponentRef.isNil:
    terminalOutputComponentRef = self
    tryMountIsoNimTerminalOutputPanel()

  api.subscribe(CtLoadedTerminal, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    discard self.onLoadedTerminal(response)
  )
  api.subscribe(CtUpdatedEvents, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    if self.initialUpdate:
      self.getLines()
      self.initialUpdate = false
  )
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    self.location = response.location
    syncTerminalOutputDebuggerPosition(response.location.rrTicks)
  )
  api.emit(InternalLastCompleteMove, EmptyArg())

# think if it's possible to directly exportc in this way the method
proc registerTerminalOutputComponent*(component: TerminalOutputComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
