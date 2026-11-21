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

import std/[json, options]

import isonim/core/[signals, owner, async_compat]
import isonim/web/frame_renderer

import ../viewmodel/codetracer_embed
import ../viewmodel/backend/worker_backend
import ../viewmodel/viewport
import ../viewmodel/input/pane_presses
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
  proc emscriptenExitWithLiveRuntime()
      {.importc: "emscripten_exit_with_live_runtime", header: "<emscripten.h>".}
elif defined(js):
  proc hostPostRaw(json: cstring) {.importjs: "globalThis.ctwHostPost(#)".}
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

proc mountPanes() =
  ## The panes need their ViewModels, and `DebuggerSession` builds those when
  ## the trace is open.
  if mounted or not session.isReady:
    return
  mounted = true
  let s = session.session
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
  of "terminal-output": panel = renderTerminalOutputPanel[FrameRenderer, FrameNode](r, s.terminalOutputVM)
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

proc ctwEventLogSearch(query: cstring) {.exportc.} =
  if not mounted: return
  session.session.eventLogVM.setSearchQuery($query)
  ctwPump()

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
  attach: `ctwAttach`, mountPane: `ctwMountPane`, press: `ctwPress`,
  expire: `ctwExpire`,
  phase: `ctwPhase`, failure: `ctwFailure`, step: `ctwStep`, stepping: `ctwStepping`,
  position: `ctwPosition`, readCrossings: `ctwReadCrossings`,
  setViewport: `ctwSetViewport`, mounted: `ctwMounted`, pending: `ctwPending`,
  fullValueOf: `ctwFullValueOf`, eventLogMetrics: `ctwEventLogMetrics`,
  eventLogSearch: `ctwEventLogSearch`, eventLogTotal: `ctwEventLogTotal`,
  eventLogCurrent: `ctwEventLogCurrent`, eventLogRowPx: `ctwEventLogRowPx`,
  calltraceMeasured: `ctwCalltraceMeasured`,
  frameBytes: function() { return globalThis.isonimFrameBytes(); },
  frameOps: `frameOps`, frameReset: `frameReset`, frameManifest: `frameManifest`,
  dispatch: `frameDispatch`,
};
""".}

when isMainModule:
  when defined(emscripten):
    emscriptenExitWithLiveRuntime()
