## codetracer_plugin_sdk.nim — the library a native CodeTracer plugin links
## (Extensibility-Model.md §11.5).
##
## A plugin executable builds a `PluginSdk` for its package, adds one `Plugin`
## per plugin the package's `plugin.json` lists, installs handlers, and calls
## `run`. The SDK then:
##
## * speaks the plugin protocol (`plugin_host/protocol.nim`) on stdin/stdout:
##   the handshake, the plugin list, every message of §11.4.4;
## * gives each active plugin a MIRROR `SessionViewModel` (`mirror_session`),
##   so a plugin reads the debugger's state as signals and acts through action
##   procs, which the SDK relays to the primary session (§5.1, §5.2);
## * runs every handler on one thread, ONE AT A TIME, and records whose handler
##   is running;
## * answers `ping` from a WATCHDOG thread — the thread that reads stdin — so a
##   handler stuck in a loop still lets the host learn which plugin is stuck
##   (§11.6.2). That is what lets the host blame one plugin for a hang in a
##   process it shares with others;
## * reports a handler's `CatchableError` as that plugin's `error` and keeps the
##   other plugins running.
##
## ## WHAT IT DOES ABOUT A CRASH
##
## A `Defect` is not caught: it ends the process, as §11.5 requires. Before it
## does, the SDK writes `ct-plugin-crash: <plugin>` to stderr, and a
## SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT handler writes the same line with the
## plugin whose handler was running and then RE-RAISES the signal with its
## default action, so the process still dies by that signal. The host reads the
## last such line to attribute the crash (§11.6.1). The handler is the one
## signal disposition the SDK touches, and it changes nothing about how the
## process ends.
##
## ## WEBASSEMBLY (`--cpu:wasm32`, Extensibility-Model.md §11.9)
##
## The same source builds a plugin for `ct-plugin-host`. There the instance has
## no stdin, no threads and no signals: a frame arrives through the exported
## `ct_plugin_frame`, every frame the plugin sends leaves through the host's
## `ct.send` import (`writeFrame`), `ping` is answered by the host's own
## watchdog, and a trap or an overrun ends the instance rather than the
## process. `run` registers the SDK and returns; the host drives it. The
## authoring model — `addPlugin`, handlers, the mirror, `run` — is the same.
##
## ## THREADS
##
## Two: the main thread, which owns the reactive graph and every plugin's
## code, and the reader, which owns stdin. The reader answers `ping` itself and
## hands every other frame to the main thread through a channel. Writes to
## stdout from either thread are whole frames under one lock.

import std/[json, monotimes, strutils, tables, times]
when not defined(wasm32):
  import std/[locks, os, posix]

import isonim/core/[computation, owner, signals]

import ../frontend/viewmodel/session_vm
import ../frontend/viewmodel/store/[replay_data_store, types as store_types]
import ../frontend/viewmodel/sync/[mirror_session, transport]
import ../frontend/viewmodel/plugin_host/protocol
import ../common/view_vocabulary/vocabulary as view_vocabulary

export protocol, json, session_vm, mirror_session, view_vocabulary,
       signals, computation, replay_data_store, store_types

type
  Request* = object
    ## An `invoke` or a `query` the plugin is answering.
    id*: string
    op*: string
    kind*: string
    epoch*: Epoch
    deadlineMs*: int
    fromKey*: bool

  InvokeHandler* = proc(p: Plugin; args: JsonNode; req: Request) {.closure.}
  QueryHandler* = proc(p: Plugin; input: JsonNode; req: Request) {.closure.}

  Plugin* = ref object
    id*: string
    version*: string
    sdk*: PluginSdk
    active*: bool
    settings*: JsonNode
    grants*: seq[string]
    mirror*: MirrorSession
    disposeRoot: proc()
    onActivate*: proc(p: Plugin) {.closure.}
      ## Runs inside the plugin's own reactive root: effects and memos it
      ## creates are released when the plugin is deactivated.
    onDeactivate*: proc(p: Plugin) {.closure.}
    onSettingsChanged*: proc(p: Plugin) {.closure.}
    onSignals*: proc(p: Plugin) {.closure.}
      ## After every batch of mirrored state the plugin's mirror applied.
    onViewEvent*: proc(p: Plugin; surface: string; event: JsonNode) {.closure.}
    onLayerPopped*: proc(p: Plugin; token, reason: string) {.closure.}
    invokes*: Table[string, InvokeHandler]
    queries*: Table[string, QueryHandler]
    autoAck*: bool
      ## Acknowledge every `invoke` as it is taken, before its handler runs
      ## (the default). A plugin that wants to acknowledge later clears it and
      ## calls `ack` itself.
    nextToken: int

  PluginSdk* = ref object
    package*: string
    plugins*: OrderedTable[string, Plugin]
    epoch*: Epoch
    sessionId*: string
    hostInfo*: JsonNode
    running: bool
    idle*: seq[proc() {.closure.}]

# ---------------------------------------------------------------------------
# The shared state the watchdog reads
# ---------------------------------------------------------------------------

when defined(wasm32):
  proc ctSend(p: pointer; n: int32) {.importc: "ct_send",
    codegenDecl: "__attribute__((import_module(\"ct\"), import_name(\"send\"))) $# $#$#".}

  proc writeFrame(payload: string) =
    ## One message to `ct-plugin-host`: the JSON itself, unframed; the host
    ## frames what it passes on.
    if payload.len > 0:
      ctSend(payload[0].unsafeAddr, payload.len.int32)

  proc sendRaw(msg: JsonNode) =
    writeFrame($msg)

  proc ctIo(p: pointer; n: int32): int32 {.importc: "ct_io",
    codegenDecl: "__attribute__((import_module(\"ct\"), import_name(\"io\"))) $# $#$#".}

  var
    ioWaiting: Table[int, proc(r: JsonNode) {.closure.}]
    nextIo: int

  proc ioRequest*(req: JsonNode; onDone: proc(r: JsonNode) {.closure.}) =
    ## One I/O request to the host (`plugin_io.nim`'s primitives, `decide`
    ## first). `onDone` runs with the `io-result` when it arrives, in a later
    ## call: there is no synchronous I/O, here as natively.
    inc nextIo
    let id = nextIo
    var r = req.copy
    r["id"] = %id
    ioWaiting[id] = onDone
    let text = $r
    if ctIo(text[0].unsafeAddr, text.len.int32) != 0:
      ioWaiting.del(id)
      onDone(%*{"status": "ioFailed", "message": "the host did not accept the request"})

  proc setBusy(id: string) = discard
  proc clearBusy() = discard
  proc crashLine(id: string) = discard
else:
  var
    writeLock: Lock
    busyName: array[256, char]
    busyLen {.volatile.}: int
    busySinceNs {.volatile.}: int64
    inbox: Channel[string]
    readerThread: Thread[void]

  proc nowNs(): int64 = getMonoTime().ticks

  proc setBusy(id: string) =
    let n = min(id.len, busyName.len - 1)
    for i in 0 ..< n:
      busyName[i] = id[i]
    busySinceNs = nowNs()
    busyLen = n

  proc clearBusy() =
    busyLen = 0

  proc busyNow(): string =
    let n = busyLen
    result = newString(n)
    for i in 0 ..< n:
      result[i] = busyName[i]

  proc writeAll(fd: cint; data: string) =
    var off = 0
    while off < data.len:
      let n = posix.write(fd, data[off].unsafeAddr, data.len - off)
      if n > 0:
        off += n
      elif n < 0 and errno == EINTR:
        continue
      else:
        return

  proc sendRaw(msg: JsonNode) =
    let frame = encodeMessage(msg)
    if frame.len == 0:
      return
    withLock writeLock:
      writeAll(1, frame)

  proc crashLine(id: string) =
    writeAll(2, "\nct-plugin-crash: " & id & "\n")

  proc onFatalSignal(sig: cint) {.noconv.} =
    # Async-signal-safe: `write` of a static buffer, `signal`, `raise`.
    const prefix = "\nct-plugin-crash: "
    discard posix.write(2, prefix.cstring, prefix.len)
    if busyLen > 0:
      discard posix.write(2, busyName[0].addr, busyLen)
    discard posix.write(2, "\n".cstring, 1)
    discard signal(sig, SIG_DFL)
    discard posix.raise(sig)

  proc installCrashRecord() =
    for sig in [SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT]:
      var sa: Sigaction
      sa.sa_handler = onFatalSignal
      discard sigemptyset(sa.sa_mask)
      sa.sa_flags = SA_RESETHAND
      discard sigaction(sig, sa, nil)

  proc readerLoop() {.thread.} =
    ## The watchdog. Owns stdin; answers `ping` here, so a stuck main thread
    ## still produces a `pong` naming the plugin it is stuck in.
    var reader: FrameReader
    var buf: array[65536, char]
    while true:
      let n = posix.read(0, buf[0].addr, buf.len)
      if n == 0:
        break
      if n < 0:
        if errno == EINTR: continue
        break
      var s = newString(n)
      copyMem(s[0].addr, buf[0].addr, n)
      reader.feed(s)
      var frame: string
      while true:
        let st = reader.next(frame)
        if st != fsFrame:
          if st == fsOversize:
            inbox.send("")
            return
          break
        if frame.contains("\"ping\""):
          var parsed: JsonNode
          try: parsed = parseJson(frame)
          except CatchableError: parsed = nil
          if not parsed.isNil and parsed{"type"}.getStr("") == "ping":
            let busy = busyNow()
            let ms = if busy.len > 0: (nowNs() - busySinceNs) div 1_000_000 else: 0
            sendRaw(%*{"type": "pong", "seq": parsed{"seq"},
                       "busy": (if busy.len > 0: %busy else: newJNull()),
                       "busyMs": ms})
            continue
        inbox.send(frame)
    inbox.send("")

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newPluginSdk*(package: string): PluginSdk =
  PluginSdk(package: package, plugins: initOrderedTable[string, Plugin]())

proc addPlugin*(sdk: PluginSdk; id, version: string): Plugin =
  ## Register one plugin of this executable. Its id must be one the package's
  ## `plugin.json` lists: the host refuses a process whose list differs.
  result = Plugin(id: id, version: version, sdk: sdk, autoAck: true,
                  settings: newJObject(),
                  invokes: initTable[string, InvokeHandler](),
                  queries: initTable[string, QueryHandler]())
  sdk.plugins[id] = result

proc onInvoke*(p: Plugin; op: string; h: InvokeHandler) = p.invokes[op] = h
proc onQuery*(p: Plugin; kind: string; h: QueryHandler) = p.queries[kind] = h

proc session*(p: Plugin): SessionViewModel =
  ## The plugin's mirror of the primary session. nil while inactive.
  if p.mirror.isNil: nil else: p.mirror.session

proc epoch*(p: Plugin): Epoch = p.sdk.epoch

# ---------------------------------------------------------------------------
# What a plugin sends
# ---------------------------------------------------------------------------

proc send(p: Plugin; msg: JsonNode) =
  msg["plugin"] = %p.id
  sendRaw(msg)

proc pushView*(p: Plugin; surface: string; tree: ViewNode) =
  ## The whole tree for one of the plugin's surfaces (its LOCAL id).
  p.send(%*{"type": "view", "surface": surface, "tree": tree.toJson,
            "epoch": p.sdk.epoch.toJson})

proc pushViewPatch*(p: Plugin; surface: string; patch: JsonNode) =
  p.send(%*{"type": "view-patch", "surface": surface, "patch": patch,
            "epoch": p.sdk.epoch.toJson})

proc pushStatus*(p: Plugin; item: string; tree: ViewNode) =
  p.send(%*{"type": "status", "item": item, "tree": tree.toJson,
            "epoch": p.sdk.epoch.toJson})

proc pushDecorations*(p: Plugin; document: string; items: JsonNode) =
  p.send(%*{"type": "decorations", "document": document, "items": items,
            "epoch": p.sdk.epoch.toJson})

proc pushEnablement*(p: Plugin; op: string; enabled: bool; reason = "") =
  p.send(%*{"type": "enablement", "op": op, "enabled": enabled,
            "reason": reason, "epoch": p.sdk.epoch.toJson})

proc pushContext*(p: Plugin; key: string; value: JsonNode) =
  p.send(%*{"type": "context", "key": key, "value": value,
            "epoch": p.sdk.epoch.toJson})

proc pushLayer*(p: Plugin; owner: string; bindings: seq[PluginBinding];
                label = ""): string =
  ## Push a modal layer owned by `owner` (one of the plugin's surfaces, or
  ## `window`). Returns the token that pops it.
  inc p.nextToken
  result = p.id & "#" & $p.nextToken
  var bs = newJArray()
  for b in bindings: bs.add b.toJson
  p.send(%*{"type": "push-layer", "token": result, "owner": owner,
            "bindings": bs, "label": label})

proc popLayer*(p: Plugin; token: string) =
  p.send(%*{"type": "pop-layer", "token": token})

proc ack*(p: Plugin; req: Request) =
  p.send(%*{"type": "ack", "id": req.id})

proc answer*(p: Plugin; req: Request; value: JsonNode) =
  p.send(%*{"type": "answer", "id": req.id, "value": value,
            "epoch": p.sdk.epoch.toJson})

proc rows*(p: Plugin; req: Request; rows: JsonNode) =
  p.send(%*{"type": "rows", "id": req.id, "rows": rows,
            "epoch": p.sdk.epoch.toJson})

proc done*(p: Plugin; req: Request) =
  p.send(%*{"type": "done", "id": req.id, "epoch": p.sdk.epoch.toJson})

proc fail*(p: Plugin; req: Request; message: string) =
  p.send(%*{"type": "error", "id": req.id, "message": message,
            "epoch": p.sdk.epoch.toJson})

proc publish*(p: Plugin; viewModel: string; batch: JsonNode) =
  ## A published ViewModel's batch (§2 "publish"), stamped with the epoch it
  ## was computed at.
  p.send(%*{"type": "publish-batch", "viewModel": viewModel, "batch": batch,
            "epoch": p.sdk.epoch.toJson})

proc relay*(p: Plugin; vm, action: string; args: JsonNode = newJObject()) =
  ## Run `vm`.`action` on the primary session (the action relay).
  p.send(%*{"type": "action", "session": p.sdk.sessionId, "vm": vm,
            "action": action, "args": args})

proc log*(p: Plugin; message: string; level = "info") =
  p.send(%*{"type": "log", "level": level, "message": message})

# ---------------------------------------------------------------------------
# Handler dispatch: one at a time, attributed
# ---------------------------------------------------------------------------

template attributed(p: Plugin; reqId: string; body: untyped) =
  setBusy(p.id)
  try:
    body
  except CatchableError as e:
    p.send(%*{"type": "error", "id": reqId, "message": e.msg,
              "exception": $e.name, "epoch": p.sdk.epoch.toJson})
  except Defect:
    crashLine(p.id)
    raise
  finally:
    clearBusy()

proc mirrorChannel(p: Plugin): SyncChannel =
  ## The plugin's mirror talks to this channel as if it were a sync host. Its
  ## `hello` and `subscribe` are answered by the SDK (the host sends the
  ## snapshot with `activate`); its relayed actions go to the host.
  let plugin = p
  newSyncChannel(proc(msg: JsonNode) =
    case msg{"type"}.getStr("")
    of "action":
      var m = msg.copy
      plugin.send(m)
    else:
      discard)

proc activate(sdk: PluginSdk; p: Plugin; msg: JsonNode) =
  if p.active:
    sendRaw(%*{"type": "activated", "plugin": p.id})
    return
  p.settings = if msg{"settings"}.isNil: newJObject() else: msg["settings"]
  p.grants = @[]
  if not msg{"grants"}.isNil:
    for g in msg["grants"]: p.grants.add g.getStr("")
  var failed = ""
  setBusy(p.id)
  try:
    let ch = p.mirrorChannel()
    p.mirror = createMirrorSession(ch)
    if sdk.sessionId.len > 0:
      ch.deliver(%*{"type": "activate", "session": sdk.sessionId})
    createRoot proc(dispose: proc()) =
      p.disposeRoot = dispose
      if not p.onActivate.isNil:
        p.onActivate(p)
  except CatchableError as e:
    failed = e.msg
  except Defect:
    crashLine(p.id)
    raise
  finally:
    clearBusy()
  if failed.len > 0:
    sendRaw(%*{"type": "activation-failed", "plugin": p.id, "reason": failed})
  else:
    p.active = true
    sendRaw(%*{"type": "activated", "plugin": p.id})

proc deactivate(p: Plugin) =
  if not p.active:
    return
  p.attributed(""):
    if not p.onDeactivate.isNil:
      p.onDeactivate(p)
  if not p.disposeRoot.isNil:
    p.disposeRoot()
    p.disposeRoot = nil
  if not p.mirror.isNil:
    p.mirror.dispose()
    p.mirror = nil
  p.active = false

proc deliverState(sdk: PluginSdk; msg: JsonNode) =
  ## A snapshot or a batch of the primary's mirrored state, to every active
  ## plugin's mirror in turn, each delivery attributed to its plugin.
  if not msg{"epoch"}.isNil:
    sdk.epoch = epochFrom(msg["epoch"])
  let sid = msg{"session"}.getStr("")
  for p in sdk.plugins.values:
    if not p.active or p.mirror.isNil:
      continue
    let target = msg{"plugin"}.getStr("")
    if target.len > 0 and target != p.id:
      continue
    p.attributed(""):
      if sid.len > 0 and p.mirror.following != sid:
        p.mirror.channel.deliver(%*{"type": "activate", "session": sid})
      p.mirror.channel.deliver(msg)
      if not p.onSignals.isNil:
        p.onSignals(p)

proc requestOf(msg: JsonNode): Request =
  Request(id: msg{"id"}.getStr(""), op: msg{"op"}.getStr(""),
          kind: msg{"kind"}.getStr(""), epoch: epochFrom(msg{"epoch"}),
          deadlineMs: msg{"deadlineMs"}.getInt(0),
          fromKey: msg{"fromKey"}.getBool(false))

proc handle(sdk: PluginSdk; msg: JsonNode) =
  let t = msg{"type"}.getStr("")
  let p = sdk.plugins.getOrDefault(msg{"plugin"}.getStr(""), nil)
  case t
  of "hello":
    sdk.hostInfo = msg
    var list: seq[(string, string)]
    for p in sdk.plugins.values:
      list.add (p.id, p.version)
    sendRaw(processHello(sdk.package, list))
  of "activate":
    if not msg{"epoch"}.isNil:
      sdk.epoch = epochFrom(msg["epoch"])
      if sdk.epoch.session.len > 0:
        sdk.sessionId = sdk.epoch.session
    if not p.isNil:
      sdk.activate(p, msg)
  of "deactivate":
    if not p.isNil:
      p.deactivate()
  of "settings-changed":
    if not p.isNil:
      p.settings = msg{"settings"}
      if not p.onSettingsChanged.isNil:
        p.attributed(""):
          p.onSettingsChanged(p)
  of "signal-snapshot", "signal-batch":
    let sid = msg{"session"}.getStr("")
    if sid.len > 0:
      sdk.sessionId = sid
    sdk.deliverState(msg)
  of "invoke":
    if p.isNil or not p.active:
      return
    let req = requestOf(msg)
    if p.autoAck:
      p.ack(req)
    let h = p.invokes.getOrDefault(req.op, nil)
    p.attributed(req.id):
      if h.isNil:
        raise newException(ValueError, "no handler for operation '" &
                           req.op & "'")
      h(p, msg{"args"}, req)
  of "query":
    if p.isNil or not p.active:
      return
    let req = requestOf(msg)
    let h = p.queries.getOrDefault(req.kind, nil)
    p.attributed(req.id):
      if h.isNil:
        raise newException(ValueError, "no handler for query '" &
                           req.kind & "'")
      h(p, msg{"input"}, req)
  of "view-event":
    if not p.isNil and p.active and not p.onViewEvent.isNil:
      p.attributed(""):
        p.onViewEvent(p, msg{"surface"}.getStr(""), msg{"event"})
  of "layer-popped":
    if not p.isNil and p.active and not p.onLayerPopped.isNil:
      p.attributed(""):
        p.onLayerPopped(p, msg{"token"}.getStr(""), msg{"reason"}.getStr(""))
  of "io-result":
    when defined(wasm32):
      let id = msg{"id"}.getInt(0)
      if ioWaiting.hasKey(id):
        var cb: proc(r: JsonNode) {.closure.}
        discard ioWaiting.pop(id, cb)
        if not p.isNil:
          p.attributed(""):
            cb(msg)
  of "cancel":
    discard
  of "shutdown":
    for q in sdk.plugins.values:
      q.deactivate()
    sdk.running = false
  else:
    discard

proc handleFrame*(sdk: PluginSdk; frame: string) =
  ## One frame from the host: parse it and dispatch it. Both transports end
  ## here.
  var msg: JsonNode
  try:
    msg = parseJson(frame)
  except CatchableError:
    return
  sdk.handle(msg)

when defined(wasm32):
  var guestSdk: PluginSdk
    ## The SDK `run` registered. The host's calls below reach it.

  proc NimMain() {.importc.}

  proc run*(sdk: PluginSdk) =
    ## Under `ct-plugin-host` there is no loop to run: the host calls
    ## `ct_plugin_frame` with each frame. `run` registers the SDK and returns.
    guestSdk = sdk
    sdk.running = true

  proc ct_plugin_init() {.exportc,
      codegenDecl: "__attribute__((export_name(\"ct_plugin_init\"))) $# $#$#".} =
    ## The module's own initialisation: the plugin's top level, which builds
    ## its SDK, adds its plugins and calls `run`.
    NimMain()

  proc ct_plugin_alloc(n: int32): pointer {.exportc,
      codegenDecl: "__attribute__((export_name(\"ct_plugin_alloc\"))) $# $#$#".} =
    ## A buffer the host writes one frame into; `ct_plugin_frame` frees it.
    allocShared(max(n, 1))

  proc ct_plugin_frame(p: pointer; n: int32): int32 {.exportc,
      codegenDecl: "__attribute__((export_name(\"ct_plugin_frame\"))) $# $#$#".} =
    ## One frame from the host. Returns 1 when the plugin has idle work, so
    ## the host calls `ct_plugin_idle` again soon.
    var frame = newString(n)
    if n > 0:
      copyMem(frame[0].addr, p, n)
    deallocShared(p)
    if not guestSdk.isNil:
      guestSdk.handleFrame(frame)
      if not guestSdk.running:
        for q in guestSdk.plugins.values:
          q.deactivate()
    int32(not guestSdk.isNil and guestSdk.idle.len > 0)

  proc ct_plugin_idle(): int32 {.exportc,
      codegenDecl: "__attribute__((export_name(\"ct_plugin_idle\"))) $# $#$#".} =
    if guestSdk.isNil: return 0
    for f in guestSdk.idle:
      f()
    int32(guestSdk.idle.len > 0)

else:
  proc run*(sdk: PluginSdk) =
    ## The protocol loop. Returns after `shutdown`, or when the host closes
    ## stdin; the process should then exit.
    initLock(writeLock)
    inbox.open()
    installCrashRecord()
    createThread(readerThread, readerLoop)
    sdk.running = true
    while sdk.running:
      let (got, frame) = inbox.tryRecv()
      if not got:
        for f in sdk.idle:
          f()
        sleep(2)
        continue
      if frame.len == 0:
        break
      sdk.handleFrame(frame)
    for p in sdk.plugins.values:
      p.deactivate()
