## entries/vscode_host.nim — the VS Code extension host's side of CodeTracer.
##
## Shared-DOM-Front-Ends D2 and D5: the extension host owns one primary
## `DebuggerSession` per CodeTracer debug session, and every webview panel
## mirrors the ACTIVE one (`entries/vscode_panel`) over `postMessage`. One
## stop is loaded once, not once per webview, and every panel shows the same
## revision of the session (SDF-AREQ8: several sessions may be active; VS
## Code's own debug toolbar and session picker switch between them, and the
## extension tells the host which one is active).
##
## THE HOST NEVER LAUNCHES THE REPLAY. VS Code's debug adapter does, through
## its own `launch` request; the host's session is a second client of that
## replay, attaching on the first stop it reports and taking every later move
## from the replay's events (`DebuggerSession.followBackendMoves`), as the
## `ct host` server's does (`sync/hosted_primary`). Its requests go through
## the debug session's `customRequest`; the replay's events reach it from the
## extension's `DebugAdapterTracker`.
##
## The extension (TypeScript) calls the functions exported at the end of this
## module. TypeScript keeps only VS Code integration: panel lifecycle, the
## debug adapter, and the editor decorations VS Code draws itself, which are
## fed from here (`ctHostOnFlowLines`).
##
## Compiled with `nim js -d:nodejs` to `vscode_host.js`.

when not defined(js):
  {.error: "entries/vscode_host runs in the VS Code extension host (JS).".}

import std/[asyncjs, json, jsffi, strutils, tables]

import isonim/core/[signals, computation, owner, async_compat]

import ../viewmodel/backend/backend_service
import ../viewmodel/sdk/[debugger_session, trace_source]
import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/session_vm
import ../viewmodel/viewport
import ../viewmodel/sync/[sync_host, transport, webview_transport]
import ../viewmodel/viewmodels/[calltrace_vm, debug_controls_vm,
                                filesystem_vm, flow_vm, flow_line_values,
                                scratchpad_vm, state_vm, trace_log_vm]
import ../../common/lang as common_lang

const TracepointRunRefused* = "the replay refused to run the tracepoint"
  ## A tracepoint row's detail when `ct/run-tracepoints` was refused.

type
  HostedDebugSession = ref object
    ## One VS Code debug session's primary.
    debugger: DebuggerSession
    handlers: seq[EventHandler]
      ## The backend's event handlers: the replay's events, delivered by the
      ## extension's tracker (`ctHostDeliverEvent`).
    tracepoints: seq[TracepointSweepSpec]
      ## The tracepoints run over the recording so far; each sweep's answer
      ## is applied for all of them (`applyTracepointResults`).
    sourceFiles: seq[string]
      ## The recording's source files, for the file tree once it exists.

  VsCodeHost* = ref object
    sync: SyncHost
    sessions: Table[string, HostedDebugSession]
    active: Signal[string]
      ## The session the panels show; "" before VS Code names one.
    hosted: Signal[int]
      ## Bumped when a session starts being hosted, so effects that read
      ## the active session's ViewModels re-run.
    disposeRoot: proc()
    openFileListener: proc(path: string)
      ## Opens a file in VS Code's editor: the file tree's "open" (the source
      ## editor role is always the editor's, Shared-DOM-Front-Ends D9).

proc stringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc jsParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}

proc jsonOf(o: JsObject): JsonNode =
  if o.isNil or jsTypeOf(o) == cstring"undefined": newJNull()
  else: parseJson($stringify(o))

proc jsOf(n: JsonNode): JsObject =
  jsParse(cstring($(if n.isNil: newJNull() else: n)))

proc callRequest(send: JsObject; command: cstring; args: JsObject;
                 done: proc(result: JsObject)) {.importjs: """
  (function(f, c, a, d) {
    Promise.resolve().then(function() { return f(c, a); })
      .then(function(r) { d(r === undefined ? null : r); },
            function() { d(null); });
  })(#, #, #, #)""".}
  ## `send(command, args)` — the debug session's `customRequest` — settled
  ## into `done`, with `null` for a refused or failed request: the replay's
  ## answer body, or nothing (`backend_service.responseSucceeded` reads a
  ## bare body and `null` exactly so).

proc newCustomRequestBackend(h: HostedDebugSession;
                             send: JsObject): BackendService =
  ## A `BackendService` over a VS Code debug session.
  proc request(command: string; args: JsonNode): BackendFuture[JsonNode] =
    let arguments = jsOf(if args.isNil: newJObject() else: args)
    newPromise(proc(resolve: proc(response: JsonNode)) =
      callRequest(send, cstring(command), arguments,
        proc(response: JsObject) = resolve(jsonOf(response))))
  proc onEvent(handler: EventHandler) =
    h.handlers.add(handler)
  proc disconnect() =
    h.handlers = @[]
  BackendService(sendProc: request, onEventProc: onEvent,
                 disconnectProc: disconnect)

proc sessionLanguage(file: string): string =
  ## A file's language as `ct/load-locals` names it.
  langWireName(common_lang.toLangFromFilename(file))

proc sourceFileTree*(paths: openArray[string]): FilesystemEntryNode =
  ## The file tree of a recording's sources: their folders nested by path,
  ## the files as leaves, under one root.
  result = FilesystemEntryNode(text: "source folders", isFolder: true,
                               isExpanded: true)
  for path in paths:
    let parts = path.split('/')
    var node = addr result
    var prefix = ""
    for i, part in parts:
      if part.len == 0:
        continue
      prefix &= "/" & part
      let isFile = i == parts.high
      var found = -1
      for j, child in node.children:
        if child.text == part and child.isFolder == not isFile:
          found = j
          break
      if found < 0:
        node.children.add FilesystemEntryNode(text: part, path: prefix,
                                              isFolder: not isFile)
        found = node.children.high
      node = addr node.children[found]

proc newVsCodeHost*(): VsCodeHost =
  let host = VsCodeHost(sync: newSyncHost(),
                        sessions: initTable[string, HostedDebugSession]())
  createRoot proc(dispose: proc()) =
    host.disposeRoot = dispose
    host.active = createSignal("")
    host.hosted = createSignal(0)
  host

proc activate*(host: VsCodeHost; id: string) =
  ## Make debug session `id` the one every panel shows.
  host.active.val = id
  if not host.sync.primary(id).isNil:
    host.sync.activate(id)

proc openSession*(host: VsCodeHost; id, traceFolder: string;
                  send: JsObject) =
  ## Host debug session `id`, recording `traceFolder`; `send` is its
  ## `customRequest`. The session is attached on the first stop the replay
  ## reports, and published to the panels then.
  if host.sessions.hasKey(id):
    return
  let hosted = HostedDebugSession()
  let backend = newCustomRequestBackend(hosted, send)
  let debugger = newDebuggerSession(backend)
  hosted.debugger = debugger
  debugger.store.sourceLanguageOf = sessionLanguage
  debugger.store.viewportScheduler = timeoutScheduler()
  host.sessions[id] = hosted
  let trace = localFolderTrace(traceFolder)
  let theHost = host
  backend.onEvent proc(event: JsonNode) =
    if debugger.phase.val != dspReady and not event.isNil and
       event.kind == JObject and
       event{"kind"}.getStr("") in CompleteMoveEventNames:
      debugger.store.applyCompleteMove(
        if event.hasKey("data"): event["data"] else: event)
      debugger.attach(trace)
      # The panels mark the call the debugger is in after every move, as on
      # the desktop.
      debugger.session.calltraceVM.followDebuggerCall()
      # The Request Panel role (Shared-DOM-Front-Ends Q8): the first poll
      # says how many requests the recording served (`recordedTotal`, the
      # panel's count); a completed recording asks nothing more, and its
      # rows are the window the panel's webview reports
      # (`RequestPanelVM.setViewport`, relayed to this primary).
      debugger.store.requestRequestSpansSince()
      let files = debugger.session.fileTreeVM
      if not files.isNil:
        if hosted.sourceFiles.len > 0:
          files.setRoot(sourceFileTree(hosted.sourceFiles))
        files.onOpenFile = proc(path: string) =
          if not theHost.openFileListener.isNil:
            theHost.openFileListener(path)
      theHost.sync.addPrimary(id, debugger.session)
      if theHost.active.val == id or theHost.active.val.len == 0:
        theHost.activate(id)
      theHost.hosted.val = theHost.hosted.val + 1
  # Tracepoint sweeps answer with an event, not a response
  # (`Handler::run_tracepoints`).
  backend.onEvent proc(event: JsonNode) =
    if event.isNil or event.kind != JObject or
       event{"kind"}.getStr("") != "ct/tracepoint-results":
      return
    var hits: seq[TracepointSweepHit] = @[]
    for stop in event{"data", "results"}.getElems:
      hits.add TracepointSweepHit(
        tracepointId: stop{"tracepointId"}.getInt(0),
        rrTicks: stop{"rrTicks"}.getBiggestInt(0).uint64,
        path: stop{"path"}.getStr(""),
        line: stop{"line"}.getBiggestInt(0).int,
        errorMessage: stop{"errorMessage"}.getStr(""))
    debugger.store.applyTracepointResults(hosted.tracepoints, hits)
    # The Trace Log lists the sweep's hits: the panel `addTracepoint` opens.
    if not debugger.session.traceLogVM.isNil:
      debugger.session.traceLogVM.setSweepHits(hits,
        int(debugger.store.eventLog.maxRRTicks.val))
  debugger.followBackendMoves()

proc deliverEvent*(host: VsCodeHost; id: string; message: JsonNode) =
  ## A DAP event of debug session `id` (`{"event", "body"}`), as the
  ## extension's tracker saw it leave the adapter.
  if not host.sessions.hasKey(id) or message.isNil or
     message.kind != JObject:
    return
  let body = message{"body"}
  let event = %*{"kind": message{"event"}.getStr(""),
                 "data": (if body.isNil: newJObject() else: body)}
  # A copy: attaching on the first stop registers more handlers (the stop
  # loader's) while this one runs.
  let handlers = host.sessions[id].handlers
  for handler in handlers:
    handler(event)

proc closeSession*(host: VsCodeHost; id: string) =
  ## Debug session `id` ended.
  if not host.sessions.hasKey(id):
    return
  host.sync.removePrimary(id)
  host.sessions[id].debugger.dispose()
  host.sessions.del(id)
  if host.active.val == id:
    host.active.val = host.sync.active

proc setSourceFiles*(host: VsCodeHost; id: string; paths: seq[string]) =
  ## The recording's source files (its `trace_paths.json`), for debug
  ## session `id`'s file tree.
  if not host.sessions.hasKey(id):
    return
  host.sessions[id].sourceFiles = paths
  let s = host.sync.primary(id)
  if not s.isNil and not s.fileTreeVM.isNil:
    s.fileTreeVM.setRoot(sourceFileTree(paths))

proc onOpenFile*(host: VsCodeHost; listener: proc(path: string)) =
  host.openFileListener = listener

proc revealFile*(host: VsCodeHost; path: string) =
  ## The editor showed `path`: the file tree reveals it (the file-tree role's
  ## floor: selection follows the editor).
  let s = host.sync.primary(host.active.val)
  if not s.isNil and not s.fileTreeVM.isNil:
    s.fileTreeVM.expandToFile(path)

proc sessionView*(host: VsCodeHost; id: string): SessionViewModel =
  ## Debug session `id`'s ViewModels once it is hosted (its first stop);
  ## nil before, and after it ended.
  host.sync.primary(id)

proc activeSession(host: VsCodeHost): SessionViewModel =
  host.sync.primary(host.active.val)

proc showValueOrigin*(host: VsCodeHost; expression: string) =
  ## Where `expression`'s value came from, at the current stop: the State
  ## pane's origin view of the active session.
  let s = host.activeSession
  if s.isNil or s.stateVM.isNil:
    return
  s.stateVM.onShowOrigin(expression, s.store.debugger.val.location)

proc runTracepoint*(host: VsCodeHost; path: string; line: int;
                    expression: string) =
  ## Run a tracepoint logging `expression` at `path`:`line` over the whole
  ## recording of the active session; its hits reach the Trace Log and the
  ## point list when the sweep answers.
  let id = host.active.val
  if not host.sessions.hasKey(id):
    return
  let hosted = host.sessions[id]
  hosted.tracepoints.add TracepointSweepSpec(
    tracepointId: hosted.tracepoints.len, path: path, line: line,
    expression: expression)
  # A sweep answers with an event and no response (`Handler::run_tracepoints`,
  # src/db-backend/src/dap_handler.rs), so the request settles only when the
  # replay REFUSES it, which `callRequest` reports as `null`. A refused run
  # is said on the tracepoint's row, as an errored sweep is.
  let debugger = hosted.debugger
  let specs = hosted.tracepoints
  let spec = specs[^1]
  onComplete(debugger.backend.send("ct/run-tracepoints",
      tracepointSweepRequest(specs)),
    proc(response: JsonNode) =
      if not responseSucceeded(response):
        debugger.store.applyTracepointResults(@[spec], @[TracepointSweepHit(
          tracepointId: spec.tracepointId, path: path, line: line,
          errorMessage: TracepointRunRefused)], replaceHits = false),
    proc(message: string) =
      debugger.store.applyTracepointResults(@[spec], @[TracepointSweepHit(
        tracepointId: spec.tracepointId, path: path, line: line,
        errorMessage: TracepointRunRefused & ": " & message)],
        replaceHits = false))

proc onFlowLines*(host: VsCodeHost;
                  listener: proc(path: string; lines: seq[FlowLineValue];
                                 loops: seq[FlowLoopLine])) =
  ## Call `listener` with the active session's flow, one line of text per
  ## source line and the lines its loop controls go on (`flow_line_values`),
  ## whenever it changes: what VS Code draws after each line and in an inset
  ## above each loop.
  let theHost = host
  createRoot proc(dispose: proc()) =
    createEffect proc() =
      discard theHost.hosted.val
      let id = theHost.active.val
      let s = theHost.sync.primary(id)
      if s.isNil or s.flowVM.isNil:
        listener("", @[], @[])
        return
      let window = s.flowVM.layoutWindow.val
      let path = s.flowVM.windowPath.val
      let debugger = s.store.debugger.val
      listener(path, flowLineValues(window, debugger.rrTicks.int),
               flowLoopLines(window, debugger.location.line))

proc addToScratchpad*(host: VsCodeHost; expression: string): bool
    {.discardable.} =
  ## Add `expression`'s value at the current stop to the active session's
  ## scratchpad: the editor's "Add to scratchpad". The value is the stop's
  ## local or watch of that name, as the State pane shows it. False when the
  ## stop has none, so the editor can say so instead of adding nothing.
  let s = host.activeSession
  if s.isNil or s.scratchpadVM.isNil:
    return
  for rows in [s.store.locals.locals.val, s.store.locals.watches.val]:
    for v in rows:
      if v.name == expression:
        s.scratchpadVM.addValue(ScratchpadValueEntry(
          expression: v.name, valueText: v.value, typeName: v.typeName,
          hasChildren: v.hasChildren, children: v.children))
        return true

proc moveInHistory*(host: VsCodeHost; back: bool) =
  ## The debug toolbar's history back / forward: move the active session's
  ## jump-history cursor one entry and jump there (`DebugControlsVM`).
  let s = host.activeSession
  if s.isNil or s.debugControlsVM.isNil:
    return
  if back: s.debugControlsVM.goBack() else: s.debugControlsVM.goForward()

proc attachWebview*(host: VsCodeHost; post: proc(message: JsObject)):
    SyncChannel =
  ## Serve a webview panel whose `postMessage` is `post`; it mirrors the
  ## active session.
  result = newHostWebviewChannel(post)
  host.sync.attach(result)

proc detachWebview*(host: VsCodeHost; channel: SyncChannel) =
  host.sync.detach(channel)
  channel.close()

proc dispose*(host: VsCodeHost) =
  for hosted in host.sessions.values:
    hosted.debugger.dispose()
  host.sessions.clear()
  host.sync.dispose()
  if not host.disposeRoot.isNil:
    host.disposeRoot()

# ---------------------------------------------------------------------------
# The extension's API (CommonJS exports)
# ---------------------------------------------------------------------------

proc ctHostCreate(): VsCodeHost {.exportc.} =
  newVsCodeHost()

proc ctHostOpenSession(host: VsCodeHost; id, traceFolder: cstring;
                       send: JsObject) {.exportc.} =
  host.openSession($id, $traceFolder, send)

proc ctHostDeliverEvent(host: VsCodeHost; id: cstring;
                        message: JsObject) {.exportc.} =
  host.deliverEvent($id, jsonOf(message))

proc ctHostActivate(host: VsCodeHost; id: cstring) {.exportc.} =
  host.activate($id)

proc ctHostCloseSession(host: VsCodeHost; id: cstring) {.exportc.} =
  host.closeSession($id)

proc ctHostAttachWebview(host: VsCodeHost;
                         post: proc(message: JsObject)): SyncChannel
    {.exportc.} =
  host.attachWebview(post)

proc ctHostDeliverFromWebview(channel: SyncChannel;
                              data: JsObject): bool {.exportc.} =
  channel.deliverFromWebview(data)

proc ctHostDetachWebview(host: VsCodeHost; channel: SyncChannel)
    {.exportc.} =
  host.detachWebview(channel)

proc ctHostShowValueOrigin(host: VsCodeHost; expression: cstring)
    {.exportc.} =
  host.showValueOrigin($expression)

proc ctHostRunTracepoint(host: VsCodeHost; path: cstring; line: int;
                         expression: cstring) {.exportc.} =
  host.runTracepoint($path, line, $expression)

proc ctHostOnFlowLines(host: VsCodeHost;
                       listener: proc(path: cstring; lines, loops: JsObject))
    {.exportc.} =
  host.onFlowLines(proc(path: string; lines: seq[FlowLineValue];
                        loops: seq[FlowLoopLine]) =
    var lineArr = newJArray()
    for l in lines:
      lineArr.add %*{"line": l.line, "text": l.text}
    var loopArr = newJArray()
    for l in loops:
      loopArr.add %*{"line": l.line, "locationInside": l.locationInside}
    listener(cstring(path), jsOf(lineArr), jsOf(loopArr)))

proc ctHostAddToScratchpad(host: VsCodeHost; expression: cstring): bool
    {.exportc.} =
  host.addToScratchpad($expression)

proc ctHostSetSourceFiles(host: VsCodeHost; id: cstring;
                          paths: seq[cstring]) {.exportc.} =
  var files: seq[string] = @[]
  for p in paths: files.add $p
  host.setSourceFiles($id, files)

proc ctHostOnOpenFile(host: VsCodeHost; listener: proc(path: cstring))
    {.exportc.} =
  host.onOpenFile(proc(path: string) = listener(cstring(path)))

proc ctHostRevealFile(host: VsCodeHost; path: cstring) {.exportc.} =
  host.revealFile($path)

proc ctHostHistory(host: VsCodeHost; back: bool) {.exportc.} =
  host.moveInHistory(back)

proc ctHostDispose(host: VsCodeHost) {.exportc.} =
  host.dispose()

{.emit: """
module.exports.ctHostCreate = ctHostCreate;
module.exports.ctHostOpenSession = ctHostOpenSession;
module.exports.ctHostDeliverEvent = ctHostDeliverEvent;
module.exports.ctHostActivate = ctHostActivate;
module.exports.ctHostCloseSession = ctHostCloseSession;
module.exports.ctHostAttachWebview = ctHostAttachWebview;
module.exports.ctHostDeliverFromWebview = ctHostDeliverFromWebview;
module.exports.ctHostDetachWebview = ctHostDetachWebview;
module.exports.ctHostShowValueOrigin = ctHostShowValueOrigin;
module.exports.ctHostRunTracepoint = ctHostRunTracepoint;
module.exports.ctHostOnFlowLines = ctHostOnFlowLines;
module.exports.ctHostSetSourceFiles = ctHostSetSourceFiles;
module.exports.ctHostOnOpenFile = ctHostOnOpenFile;
module.exports.ctHostRevealFile = ctHostRevealFile;
module.exports.ctHostAddToScratchpad = ctHostAddToScratchpad;
module.exports.ctHostHistory = ctHostHistory;
module.exports.ctHostDispose = ctHostDispose;
""".}
