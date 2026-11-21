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
import ../viewmodel/views/isonim_state_view
import ../viewmodel/views/isonim_calltrace_view
import ../viewmodel/views/isonim_event_log_view

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

proc ctwPump() {.exportc.} =
  ## Run every callback that is due, then mount the panes once the session is
  ## ready. The host calls this from its own loop and after each message.
  drainPlatformCallbacks()
  mountPanes()
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
  phase: `ctwPhase`, failure: `ctwFailure`, step: `ctwStep`, stepping: `ctwStepping`,
  position: `ctwPosition`, readCrossings: `ctwReadCrossings`,
  setViewport: `ctwSetViewport`, mounted: `ctwMounted`, pending: `ctwPending`,
  frameBytes: function() { return globalThis.isonimFrameBytes(); },
  frameOps: `frameOps`, frameReset: `frameReset`, frameManifest: `frameManifest`,
  dispatch: `frameDispatch`,
};
""".}

when isMainModule:
  when defined(emscripten):
    emscriptenExitWithLiveRuntime()
