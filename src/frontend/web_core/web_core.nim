## web_core.nim — the ViewModel core of the browser front-end, as a module
## that cannot hold a DOM node.
##
## Built two ways from this one file (`ci/test/web-core-browser.sh`):
##
##   * **wasm32**, `-d:ctWasmCore`, through Emscripten for the web
##     (`-sENVIRONMENT=web`): the core the browser front-end adopts
##     (Uniform-WASM-Core.md §10, "adopt");
##   * **`nim js`**, `-d:ctWasmCore`, the same core compiled the current way,
##     drawing through the same boundary — the comparison the browser test
##     makes, document for document.
##
## ## WHAT IT OWNS AND WHAT THE HOST OWNS
##
## The core owns a `DebuggerSession` (the Embed SDK's session: the replay
## data store and the panel ViewModels) and three panes drawn through IsoNim's
## frame renderer: the variables pane, Call Trace and the event log. It never
## holds a DOM node and never reaches the network.
##
## The host (`web_core_host.js`) owns the document, through IsoNim's frame
## applier, and the transport to the replay engine. Both directions of that
## transport are text:
##
##   * out: the core calls the host's `ctwHostPost(json)` with one DAP request
##     (`WorkerBackendService`'s `{seq, type, command, arguments}`);
##   * in: the host calls `ctwDeliver(json)` with each message the engine
##     sends, a response or an event.
##
## ## THE LOOP
##
## A future's callbacks run from `drainPlatformCallbacks`
## (`isonim/core/async_compat`). A browser host has no native event loop to
## run it from, so the host drives it: `ctwDeliver` drains after every
## message, and `ctwPump` drains on demand. Every call into the core ends with
## the host flushing the frame the call produced.
##
## ## WHY `main` MUST NOT RETURN
##
## ORC destroys the main module's globals at the end of `NimMainModule`
## (Uniform-WASM-Core.md §9.2). The host calls in after `main`, so on wasm32
## `main` ends in `emscripten_exit_with_live_runtime()`.

import std/[json, options, strutils, tables]

import isonim/core/[signals, owner, computation, async_compat]
import isonim/web/frame_renderer

import ../viewmodel/codetracer_embed
import ../viewmodel/backend/worker_backend
import ../viewmodel/sdk/stop_loader
import ../viewmodel/viewport
import ../viewmodel/input/pane_presses
import ../viewmodel/viewmodels/[calltrace_vm, state_vm, event_log_vm, terminal_output_vm, origin_chain_vm, origin_chain_bridges, scratchpad_vm]
from ../viewmodel/store/types import Location
from ../viewmodel/store/types import CallLine
from ../viewmodel/views/state_view import fullValueOf
import ../viewmodel/views/isonim_state_view
import ../viewmodel/views/isonim_calltrace_view
import ../viewmodel/views/isonim_event_log_view
import ../viewmodel/views/[isonim_build_view, isonim_command_palette_view,
  isonim_errors_view, isonim_filesystem_view, isonim_low_level_code_view,
  isonim_point_list_view, isonim_repl_view, isonim_scratchpad_view,
  isonim_search_results_view, isonim_step_list_view,
  isonim_terminal_output_view, isonim_trace_log_view]

when defined(emscripten):
  proc hostPostRaw(json: cstring) {.importc: "ctwHostPost".}
    ## Provided by the host through `--js-library web_core_library.js`.
  proc hostActionRaw(json: cstring) {.importc: "ctwHostAction".}
  proc emscriptenExitWithLiveRuntime()
      {.importc: "emscripten_exit_with_live_runtime", header: "<emscripten.h>".}
elif defined(js):
  proc hostPostRaw(json: cstring) {.importjs: "globalThis.ctwHostPost(#)".}
  proc hostActionRaw(json: cstring) {.importjs: "(globalThis.ctwHostAction && globalThis.ctwHostAction(#))".}
else:
  {.error: "web_core.nim is the browser front-end's core: build it for wasm32 or nim js".}

let r = FrameRenderer()
var
  worker: WorkerBackend
  session: DebuggerSession
  panes: array[3, FrameNode]
  mounted = false

proc paneContainer(name: string): FrameNode =
  ## One container per pane under the host's mount point, named so the host
  ## can place it.
  result = r.createElement("div")
  r.setAttribute(result, "class", "ct-web-core-pane")
  r.setAttribute(result, "data-pane", name)
  r.appendChild(NoFrameNode, result)

proc ctwBoot() {.exportc.} =
  ## Build the session over the host's transport. Sends nothing.
  resetFrameRenderer()
  resetFrameHandlers()
  worker = newWorkerBackend(proc(messageJson: string) =
    hostPostRaw(cstring(messageJson)))
  session = newDebuggerSession(worker.toBackendService())
  mounted = false

var lastMeasured = initTable[string, string]()
  ## The last measurement `ctwMeasured` applied to each pane.

var pendingMirror: seq[JsonNode] = @[]
  ## What the page mirrored into the event log before the panes were up.
var mirroring = false
  ## The event log's columns are being set from the page's: not a change of
  ## this pane's to send back.

proc applyEventLogMirror(vm: EventLogVM; m: JsonNode) =
  ## The page's own Event Log state, which the shell's integrations keep —
  ## the filter (`kinds`), the columns (`columns`: widths remembered across
  ## sessions, the Columns menu, the header grips) and a reload after a
  ## tracepoint run or a new recording (`reload`) — set on this core's.
  if m.hasKey("kinds") and m["kinds"].kind == JArray:
    var kinds: seq[bool] = @[]
    for k in m["kinds"]: kinds.add k.getBool
    if kinds != vm.selectedKinds.val:
      vm.setSelectedKinds(kinds)
  if m.hasKey("columns"):
    let columns = columnsFromJson(m["columns"], vm.columns.val)
    if columns != vm.columns.val:
      mirroring = true
      try: vm.columns.val = columns
      finally: mirroring = false
  if m{"reload"}.getBool(false):
    vm.reload()

proc applyShellMirror(m: JsonNode) =
  let s = session.session
  if not s.eventLogVM.isNil:
    applyEventLogMirror(s.eventLogVM, m)
  if m.hasKey("codeStateLine") and not s.store.isNil:
    let line = m["codeStateLine"].getStr
    if s.store.locals.codeStateLine.val != line:
      s.store.locals.codeStateLine.val = line

proc watchEventLogColumns(vm: EventLogVM) =
  ## A change this pane makes to its columns (a column shown or hidden from
  ## its Columns menu, a header's sort) goes back to the page, whose
  ## EventLogVM the shell remembers and resizes.
  var first = true
  createEffect proc() =
    let columns = vm.columns.val
    if first:
      first = false
      return
    if not mirroring:
      hostActionRaw(cstring($(%*{"eventLogColumns": columnsToJson(columns)})))

proc mountPanes() =
  ## The panes need their ViewModels, and `DebuggerSession` builds those when
  ## the trace is open.
  if mounted or not session.isReady:
    return
  mounted = true
  lastMeasured.clear()
  let s = session.session
  # THE FLOW IS THE PAGE'S. No pane this core draws shows it (the editor and
  # its inline flow are the shell's), and the flow's window arrives as
  # `ct/updated-flow` EVENTS, which every listener on the tab's connection
  # is handed: a window this core asked for, at its own stop and in its own
  # mode, was drawn in the shell's editor between the shell's own, and the
  # editor's values flickered between the two.
  if not session.stops.isNil:
    session.stops.setPaneOpen(spFlow, false)
    session.stops.setPaneOpen(spDiffFlow, false)
  # THE VALUE-ORIGIN BRIDGES, as the desktop's shell installs them on its
  # own StateVM (`ui/state.createSessionOriginChainVM`), on this core's: the
  # in-row chain a row's badge expands is fetched and drawn here.
  if not s.stateVM.isNil and s.originChainVM.isNil:
    let originVM = createOriginChainVM(s.stateVM.store)
    wireOriginChainBridges(s.stateVM, originVM, proc(): ScratchpadVM = nil)
    s.attachOriginChainVM(originVM)
    # The side panel is the shell's: "Show in side panel", and "Show value
    # origin" on a row whose chain the engine has not summarised, open it
    # through the shell's own bridge (`ui/panel_host.shellAction`).
    s.stateVM.onShowOriginProc = proc(expression: string; location: Location) =
      hostActionRaw(cstring($(%*{"showOrigin": {"expression": expression,
        "file": location.file, "line": location.line,
        "column": location.column}})))
  createRoot proc(dispose: proc()) =
    panes[0] = paneContainer("state")
    r.appendChild(panes[0], renderStatePanel[FrameRenderer, FrameNode](r, s.stateVM))
    panes[1] = paneContainer("calltrace")
    r.appendChild(panes[1], renderCalltracePanel[FrameRenderer, FrameNode](r, s.calltraceVM))
    panes[2] = paneContainer("event-log")
    r.appendChild(panes[2], renderEventLogPanel[FrameRenderer, FrameNode](r, s.eventLogVM))
  # The event log marks the current event and asks for it after a move, as
  # every other front-end's host sets it up (`ui/panel_host.prepare`).
  if not s.eventLogVM.isNil:
    s.eventLogVM.followStop()
    watchEventLogColumns(s.eventLogVM)
  for m in pendingMirror:
    applyShellMirror(m)
  pendingMirror = @[]

const ExtraPanes* = ["build", "command-palette", "errors", "filesystem",
                     "low-level-code", "point-list", "repl", "scratchpad",
                     "search-results", "step-list", "terminal-output",
                     "trace-log"]
  ## Panes a host can ask for by name beyond the three every host gets
  ## (`ctwMountPane`); the panel host's pane kinds, in the views' names.

var extraMounted: seq[string] = @[]

proc renderExtraPane(name: string): bool =
  ## Draw pane `name` into a container of its own. False for an unknown
  ## name, or before the session's ViewModels exist.
  let s = session.session
  let box = paneContainer(name)
  var panel: FrameNode
  case name
  of "build": panel = renderBuildPanel[FrameRenderer, FrameNode](r, s.buildVM)
  of "command-palette": panel = renderCommandPalettePanel[FrameRenderer, FrameNode](r, s.commandPaletteVM)
  of "errors": panel = renderErrorsPanel[FrameRenderer, FrameNode](r, s.errorsVM)
  of "filesystem": panel = renderFilesystemPanel[FrameRenderer, FrameNode](r, s.fileTreeVM)
  of "low-level-code": panel = renderLowLevelCodePanel[FrameRenderer, FrameNode](r, s.lowLevelCodeVM)
  of "point-list": panel = renderPointListPanel[FrameRenderer, FrameNode](r, s.pointListVM)
  of "repl": panel = renderReplPanel[FrameRenderer, FrameNode](r, s.replVM)
  of "scratchpad": panel = renderScratchpadPanel[FrameRenderer, FrameNode](r, s.scratchpadVM)
  of "search-results": panel = renderSearchResultsPanel[FrameRenderer, FrameNode](r, s.searchResultsVM)
  of "step-list": panel = renderStepListPanel[FrameRenderer, FrameNode](r, s.stepListVM)
  of "terminal-output":
    panel = renderTerminalOutputPanel[FrameRenderer, FrameNode](r, s.terminalOutputVM)
    # The desktop's shell hands the pane the recording's writes; this core
    # has no shell, so the ViewModel asks the engine for them.
    s.terminalOutputVM.loadWrites()
  of "trace-log": panel = renderTraceLogPanel[FrameRenderer, FrameNode](r, s.traceLogVM)
  else: return false
  r.appendChild(box, panel)
  true

var wantedPanes: seq[string] = @[]

proc mountOne(name: string) =
  ## A proc of its own, so the root's closure captures this pane's name.
  var ok = false
  createRoot proc(dispose: proc()) =
    ok = renderExtraPane(name)
  if ok: extraMounted.add name

proc mountWanted() =
  if not mounted: return
  for name in wantedPanes:
    if name notin extraMounted:
      mountOne(name)

proc ctwMountPane(name: cstring) {.exportc.} =
  ## Ask for a pane beyond the three every host gets; drawn as soon as the
  ## session's ViewModels exist, into a container named `data-pane=<name>`.
  let n = $name
  if n in ExtraPanes and n notin wantedPanes:
    wantedPanes.add n
  mountWanted()

proc ctwPump() {.exportc.} =
  ## Run every callback that is due, then mount the panes once the session is
  ## ready. The host calls this from its own loop and after each message.
  drainPlatformCallbacks()
  mountPanes()
  mountWanted()
  drainPlatformCallbacks()

proc ctwDeliver(json: cstring) {.exportc.} =
  ## One message from the engine.
  worker.deliver($json)
  ctwPump()

proc ctwOpenFolder(folder: cstring) {.exportc.} =
  ## Open a recording the engine reads from its own disk (a replay-server's
  ## `traceFolder`).
  session.followBackendMoves()
  session.launch(localFolderTrace($folder))
  ctwPump()

proc ctwAttach(folder: cstring) {.exportc.} =
  ## Adopt a recording another client already opened on this transport — a
  ## host whose page already runs a session (the desktop renderer, the web
  ## build) and that hands this core its own connection to share. Nothing is
  ## sent; the panes fill from the next move the engine reports.
  session.followBackendMoves()
  session.attach(localFolderTrace($folder))
  ctwPump()

proc ctwPhase(): cint {.exportc.} =
  ## The session's phase, as `DebuggerSessionPhase`'s ordinal.
  cint(ord(session.phase.val))

proc ctwFailure(): cstring {.exportc.} =
  ## Why the session failed, or the empty string.
  cstring(session.failureMessage.val)

proc ctwStep(direction: cint) {.exportc.} =
  ## Move the debugger: `StepDirection`'s ordinal (`sdForward` is a `next`).
  session.store.requestStep(StepDirection(direction))
  ctwPump()

proc ctwStepping(): cint {.exportc.} =
  ## Whether a step is still in flight.
  cint(ord(session.store.debugger.val.status == dsStepping))

proc ctwPosition(): cstring {.exportc.} =
  ## Where the debugger is, as `file:line`.
  let p = session.position
  cstring(p.file & ":" & $p.line)

proc ctwReadCrossings(): cint {.exportc.} = cint(readCrossings)

proc ctwSetViewport(pane, rows, cols, firstRow: cint) {.exportc.} =
  ## What the host measured for a pane (0 state, 1 Call Trace, 2 event log),
  ## in rows. A pane's ViewModel asks for a window only once it has one: on a
  ## DOM build the view measures itself, and a core that cannot read layout
  ## is told instead.
  if not mounted:
    return
  let v = Viewport(rows: int(rows), cols: int(cols), firstRow: int(firstRow))
  let s = session.session
  case pane
  of 0: s.stateVM.setViewport(v)
  of 1: s.calltraceVM.setViewport(v)
  of 2: s.eventLogVM.setViewport(v)
  else: discard
  ctwPump()

proc ctwMeasured(pane: cstring; rows, cols, firstRow: cint; rowPx: cdouble) {.exportc.} =
  ## What the page measured for pane `pane` (the core's pane names) the way
  ## the desktop measures its own panes (`views/pane_measure_dom`): the rows
  ## shown, the columns, the first row (the scroll position) and the rows'
  ## measured pitch. Reported to the pane's ViewModel as the desktop reports
  ## it to its own.
  if not mounted:
    return
  # The same measurement again changes nothing: reporting it would only
  # re-run the pane's effects and redraw it.
  let key = $pane & ":" & $rows & ":" & $cols & ":" & $firstRow & ":" & $rowPx
  if lastMeasured.getOrDefault($pane) == key:
    return
  lastMeasured[$pane] = key
  let v = Viewport(rows: int(rows), cols: int(cols), firstRow: int(firstRow))
  let s = session.session
  case $pane
  of "calltrace":
    if not s.calltraceVM.isNil:
      s.calltraceVM.setRowHeightPx(float(rowPx))
      s.calltraceVM.setViewport(v)
  of "state":
    if not s.stateVM.isNil: s.stateVM.setViewport(v)
  of "terminal-output":
    if not s.terminalOutputVM.isNil: terminal_output_vm.setViewport(s.terminalOutputVM, v)
  of "event-log":
    if not s.eventLogVM.isNil: s.eventLogVM.reportMeasure(v, float(rowPx))
  else: discard
  ctwPump()

proc ctwMounted(): cint {.exportc.} = cint(ord(mounted))

# What the host's decoration (`web_core_decorations.nim`) asks of the panes'
# ViewModels: the same calls the `nim js` views' DOM decoration makes in
# process.

proc ctwFullValueOf(path: cstring): cstring {.exportc.} =
  ## A cut variable's whole value, for the state pane's overflow hover.
  if not mounted: return cstring""
  cstring(session.session.stateVM.fullValueOf($path))

proc ctwEventLogMetrics(cells: cint; charPx: cdouble) {.exportc.} =
  ## The event log's columns viewport, in characters of its font.
  if not mounted: return
  session.session.eventLogVM.setTableMetrics(int(cells), float(charPx))
  ctwPump()

proc ctwShellMirror(json: cstring) {.exportc.} =
  ## What the page keeps of the panes' state, mirrored into this core's:
  ## the Event Log's (`applyEventLogMirror`) and the Variables pane's code
  ## line, which the page's editor fills from the source it shows
  ## (`ui/editor.syncCodeStateLine`). Held until the panes are up.
  let m = try: parseJson($json) except CatchableError: newJObject()
  if mounted:
    applyShellMirror(m)
  else:
    pendingMirror.add m
  ctwPump()

proc ctwEventLogSearch(query: cstring) {.exportc.} =
  if not mounted: return
  session.session.eventLogVM.setSearchQuery($query)
  ctwPump()

proc ctwTerminalWindow(): cstring {.exportc.} =
  ## The Terminal Output's line counts for the page's decoration
  ## (`web_core_decorations.decorateTerminalOutput`): every line, the
  ## current one, the first held, how many are held, and whether it holds a
  ## window ("1") or every line ("0").
  let vm = session.session.terminalOutputVM
  if not mounted or vm.isNil:
    return cstring"0,0,0,0,0"
  cstring($vm.lineCount() & "," & $vm.currentLine() & "," &
          $vm.linesStart.val & "," & $vm.lines.val.len & "," &
          (if vm.windowed: "1" else: "0"))

proc ctwEventLogTotal(): cint {.exportc.} =
  if not mounted: 0.cint else: cint(session.session.eventLogVM.listTotal)

proc ctwEventLogCurrent(): cint {.exportc.} =
  if not mounted: 0.cint else: cint(session.store.eventLog.currentIndex.val)

proc ctwEventLogRowPx(): cdouble {.exportc.} =
  if not mounted: 1.0 else: cdouble(session.session.eventLogVM.rowHeightPx.val)

proc ctwCalltraceMeasured(pitch, originX, centerY: cdouble) {.exportc.} =
  ## Call Trace's rows as the host measured them: their advance and the
  ## toggle anchor the guides are drawn from.
  if not mounted: return
  setFrameGuideMeasure(float(pitch), float(originX), float(centerY))
  ctwPump()

proc ctwPress(operation, attrsJson: cstring): cint {.exportc.} =
  ## A pointer press the host hit-tested: `operation` (one of
  ## `pane_presses.SessionPressOperations`) on the element whose attributes —
  ## its own, then each ancestor's, the nearest first — are `attrsJson`. The
  ## same procedure the desktop performs on its own ViewModels
  ## (`input/dom_pane_presses`), on this core's. 1 when it acted.
  if not mounted: return 0
  let attrs = try: parseJson($attrsJson) except CatchableError: newJObject()
  let reader: AttributeReader = proc(name: string): string =
    if attrs.kind == JObject: attrs{name}.getStr("") else: ""
  result = cint(ord(performSessionPress(session.session, $operation, reader)))
  ctwPump()

# ---------------------------------------------------------------------------
# Right-click menus on the core's panes. The shell opens them (its
# `context-menu.open`, `input/dom_pane_presses`) at the press, with the shared
# right-click menu; the ENTRIES and what they do are this core's, on its
# ViewModels — the shell's never see these panes' rows.
# ---------------------------------------------------------------------------

type MenuEntry = object
  label, hint: string
  enabled: bool
  run: proc(): string  ## what the host must still do ("" for nothing)

var openMenu: seq[MenuEntry] = @[]

proc callLineAt(vm: CalltraceVM; index: int): CallLine =
  for line in vm.store.calltrace.lines.val:
    if line.index == int64(index):
      return line
  CallLine(index: -1)

proc stateMenuEntry(entry: OriginContextMenuEntry): MenuEntry =
  ## One entry of a State-pane row's menu. Its own proc, so the closure has
  ## an environment of its own: one made in the loop body over the entries
  ## came out without one, and the core's call of it trapped.
  let action = entry.action
  MenuEntry(label: entry.label, hint: entry.hint, enabled: true,
    run: proc(): string =
      if not action.isNil: action()
      "")

proc menuEntries(pane: string; attr: proc(name: string): string): seq[MenuEntry] =
  let s = session.session
  case pane
  of "calltrace":
    let vm = s.calltraceVM
    if vm.isNil: return
    let argName = attr("data-arg-name")
    if argName.len > 0:
      # The value goes to the shell's Scratchpad, which the shell draws: the
      # host does it with what this answers.
      let text = attr("data-arg-text")
      result.add MenuEntry(label: "Add value to scratchpad", enabled: true,
        run: proc(): string = $(%*{"scratchpad": {"name": argName, "text": text}}))
      return
    let index = try: parseInt(attr("data-call-index")) except ValueError: -1
    let line = vm.callLineAt(index)
    if line.index >= 0:
      let label = if line.hasChildren and line.isExpanded: "Collapse Call Children"
                  else: "Expand Call Children"
      let lineIndex = line.index
      result.add MenuEntry(label: label, enabled: true,
        run: proc(): string =
          vm.toggleExpandCallChildren(lineIndex)
          "")
  of "state":
    let vm = s.stateVM
    let path = attr("data-variable-path")
    if vm.isNil or path.len == 0: return
    for e in vm.openVariableRowMenu(path):
      result.add stateMenuEntry(e)
  else: discard

proc ctwMenu(pane, attrsJson: cstring): cstring {.exportc.} =
  ## The right-click menu of the element `attrsJson` describes (its
  ## attributes and its ancestors', the nearest first) in `pane` (the shell's
  ## menu pane names: "calltrace", "state"), as JSON:
  ## `[{"label", "hint", "enabled"}]`, empty for no menu. The entries stay
  ## open for `ctwMenuChoose` until the next call.
  openMenu = @[]
  if mounted:
    let attrs = try: parseJson($attrsJson) except CatchableError: newJObject()
    let reader = proc(name: string): string =
      if attrs.kind == JObject: attrs{name}.getStr("") else: ""
    openMenu = menuEntries($pane, reader)
  var arr = newJArray()
  for e in openMenu:
    arr.add %*{"label": e.label, "hint": e.hint, "enabled": e.enabled}
  ctwPump()
  cstring($arr)

proc ctwMenuChoose(index: cint): cstring {.exportc.} =
  ## Perform entry `index` of the menu `ctwMenu` last answered. Answers what
  ## the host must still do, as JSON (`{"scratchpad": {"name", "text"}}`), or
  ## "" when the core did it all.
  result = cstring""
  if index >= 0 and index < cint(openMenu.len) and not openMenu[index].run.isNil:
    result = cstring(openMenu[index].run())
  ctwPump()

proc ctwExpire(requestSeq: cint): cint {.exportc.} =
  ## The host's request timeout: settle `requestSeq` as failed when it is
  ## still waiting (`WorkerBackend.expire`). 1 when it was.
  result = cint(ord(worker.expire(int(requestSeq),
    "the engine did not answer within the host's request timeout")))
  ctwPump()

proc ctwPending(): cint {.exportc.} =
  ## Requests sent to the engine and not yet answered.
  cint(worker.pendingCount)

# The frame and dispatch entry points are `isonim/web/frame_renderer`'s own
# (`isonimFrameBase`, `isonimFrameLen`, `isonimFrameOps`,
# `isonimFrameReset`, `isonimFrameManifest`, `isonimFrameDispatch`). Under
# `nim js` they are the same procs bound below.
when defined(js):
  proc frameOps(): int = wireOpCount()
  proc frameReset() = wireReset()
  proc frameManifest() = writeOpManifest()
  proc frameDispatch(id: int; t, v, k: cstring; dy: float; mods: int): int =
    dispatchFrameEvent(id, $t, $v, $k, dy, mods)
  {.emit: """
globalThis.ctwJsCore = {
  boot: `ctwBoot`, pump: `ctwPump`, deliver: `ctwDeliver`, openFolder: `ctwOpenFolder`,
  attach: `ctwAttach`, mountPane: `ctwMountPane`, press: `ctwPress`, menu: `ctwMenu`, measured: `ctwMeasured`, menuChoose: `ctwMenuChoose`,
  expire: `ctwExpire`,
  phase: `ctwPhase`, failure: `ctwFailure`, step: `ctwStep`, stepping: `ctwStepping`,
  position: `ctwPosition`, readCrossings: `ctwReadCrossings`,
  setViewport: `ctwSetViewport`, mounted: `ctwMounted`, pending: `ctwPending`,
  fullValueOf: `ctwFullValueOf`, eventLogMetrics: `ctwEventLogMetrics`,
  eventLogSearch: `ctwEventLogSearch`, eventLogTotal: `ctwEventLogTotal`,
  eventLogCurrent: `ctwEventLogCurrent`, eventLogRowPx: `ctwEventLogRowPx`,
  shellMirror: `ctwShellMirror`, terminalWindow: `ctwTerminalWindow`,
  calltraceMeasured: `ctwCalltraceMeasured`,
  frameBytes: function() { return globalThis.isonimFrameBytes(); },
  frameOps: `frameOps`, frameReset: `frameReset`, frameManifest: `frameManifest`,
  dispatch: `frameDispatch`,
};
""".}

when isMainModule:
  when defined(emscripten):
    emscriptenExitWithLiveRuntime()
