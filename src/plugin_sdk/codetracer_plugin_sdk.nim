## codetracer_plugin_sdk.nim — the library a native CodeTracer plugin links
## (Extensibility-Model.md §11.5).
##
## A plugin executable builds a `PluginSdk` for its package, adds one `Plugin`
## per plugin the package's `plugin.json` lists, installs handlers, and calls
## `run`. The SDK then:
##
## * speaks the plugin protocol (`plugin_host/protocol.nim`) on the channel the
##   host opened (below): the handshake, the plugin list, every message of
##   §11.4.4;
## * gives each active plugin a MIRROR `SessionViewModel` (`mirror_session`),
##   so a plugin reads the debugger's state as signals and acts through action
##   procs, which the SDK relays to the primary session (§5.1, §5.2). The
##   ViewModel modules whose types those signals carry are exported, so a
##   plugin names `VariableDiff` or `StateVM` without a path into CodeTracer's
##   source tree;
## * runs every handler, timer and async continuation on ONE thread, one at a
##   time, inside an `asyncdispatch` event loop, and records whose code is
##   running;
## * gives each plugin §8.1's primitives — processes, streams, sockets,
##   framing — owned by that plugin and closed when it is deactivated;
## * answers `ping` from a WATCHDOG thread, so a plugin stuck in a loop still
##   lets the host learn which plugin is stuck (§11.6.2). That is what lets the
##   host blame one plugin for a hang in a process it shares with others;
## * reports a `CatchableError` raised by a handler, a timer or an async
##   continuation as that plugin's `error` and keeps the other plugins
##   running.
##
## ## WEBASSEMBLY (`--cpu:wasm32`, Extensibility-Model.md §11.9)
##
## ## THE CHANNEL (§11.4.1)
##
## The host starts the process with `CODETRACER_PLUGIN_CHANNEL=fds:3,4,5,6`:
## frames arrive on descriptor 3 and go out on 4; `ping`s arrive on 5 and
## `pong`s go out on 6. The process's stdin is `/dev/null`, and its stdout and
## stderr both go to the plugin's log, so an `echo` while debugging, or a child
## started with inherited stdio, is a log line and never a broken frame. The
## SDK marks the channel's descriptors close-on-exec, so no program a plugin
## starts inherits them.
##
## Started by a host that does not set the variable, the SDK falls back to the
## standard streams: it keeps stdin for the protocol, moves the protocol's
## output to a private duplicate of stdout, and points stdout at stderr, so a
## stray `echo` still cannot corrupt the protocol.
##
## ## LIVENESS
##
## The watchdog thread owns descriptors 5 and 6 and nothing else. It is the
## only writer of 6, so a `pong` never waits for the lock the main thread
## holds while it writes a frame into a full pipe: that is what made a healthy
## plugin look hung at high load. (In the fallback, `pong` shares the
## protocol's output and its lock.)
##
## ## ATTRIBUTION
##
## Whose code runs is tracked as an OWNER. A handler, a timer (`every`,
## `after`) and the SDK's activation and deactivation run with their plugin as
## owner. An async continuation runs with the owner that was current when it
## was scheduled: the SDK installs its own `callSoon`, which captures the owner
## and restores it when the callback runs. A future completed by the event
## loop itself (a pipe became readable) has no owner, so the SDK's primitives
## and `own` complete the plugin's future under the plugin's owner — a
## continuation after `await p.read(stream)` is the plugin's. A future from
## somewhere else should be wrapped in `p.own(…)` to be attributed.
##
## While an owner runs, the watchdog reports it as busy. An exception that
## escapes it is that plugin's `error` (with no request id: the host strikes
## the plugin), and the process keeps running.
##
## ## WHAT IT DOES ABOUT A CRASH
##
## A `Defect` is not caught: it ends the process, as §11.5 requires. Before it
## does, the SDK writes `ct-plugin-crash: <plugin>` to stderr, and a
## SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT handler writes the same line with the
## plugin whose code was running and then RE-RAISES the signal with its
## default action, so the process still dies by that signal. The host reads the
## last such line to attribute the crash (§11.6.1). The handler is the one
## signal disposition the SDK touches, and it changes nothing about how the
## process ends.
##
## ## THREADS
##
## Three: the main thread, which owns the reactive graph, the event loop and
## every plugin's code; the reader, which owns the protocol's input and hands
## every frame to the main thread through a channel (waking the event loop
## through a pipe); and the watchdog, which owns the liveness descriptors.

import std/[json, monotimes, strutils, tables, times]
when not defined(wasm32):
  import std/[asyncdispatch, locks, os, posix]

import isonim/core/[computation, owner, signals]

import ../frontend/viewmodel/session_vm
import ../frontend/viewmodel/store/[replay_data_store, types as store_types]
import ../frontend/viewmodel/sync/[mirror_session, transport]
import ../frontend/viewmodel/viewmodels/[state_vm, value_changes,
                                         origin_chain_types, calltrace_vm,
                                         debug_controls_vm]
import ../frontend/viewmodel/plugin_host/protocol
import ../common/view_vocabulary/vocabulary as view_vocabulary
when not defined(wasm32):
  import ../frontend/viewmodel/plugin_host/[plugin_api, plugin_io]

export protocol, json, session_vm, mirror_session, view_vocabulary,
       signals, computation, replay_data_store, store_types,
       state_vm, value_changes, origin_chain_types, calltrace_vm,
       debug_controls_vm
when not defined(wasm32):
  export plugin_io

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

  PluginTimer* = ref object
    ## A timer one plugin installed (`every`, `after`). It runs with its
    ## plugin as owner, and it is cancelled when the plugin is deactivated.
    plugin: Plugin
    intervalMs: int
    dueNs: int64
    repeat: bool
    cb: proc(p: Plugin) {.closure.}
    cancelled*: bool

  Plugin* = ref object
    id*: string
    version*: string
    sdk*: PluginSdk
    active*: bool
    settings*: JsonNode
    grants*: seq[string]
    mirror*: MirrorSession
    when not defined(wasm32):
      io*: PluginContext
        ## What §8.1's primitives are resolved and accounted against while
        ## the plugin is active: its grants, the executables, hosts and paths
        ## its manifest declared (sent by the host with `activate`), and the
        ## table of every process, stream and socket it holds. nil while
        ## inactive. (Under wasm32, `wasm_io` asks the host instead.)
    disposeRoot: proc()
    timers: seq[PluginTimer]
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

proc nowNs(): int64 = getMonoTime().ticks

var currentOwner: Plugin
  ## Main thread only: whose code is running (see "ATTRIBUTION").

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
  # ---------------------------------------------------------------------------
  # The shared state the watchdog reads
  # ---------------------------------------------------------------------------

  type
    ChannelLoop = object
      readFd: cint
      toInbox: bool
        ## Frames other than `ping` go to the main thread.
      answerPings: bool
      pongFd: cint
      pongLocked: bool
        ## `pongFd` is the protocol's output, shared with the main thread.

  var
    writeLock: Lock
    busyName: array[256, char]
    busyLen {.volatile.}: int
    busySinceNs {.volatile.}: int64
    inbox: Channel[string]
    readerThread: Thread[ChannelLoop]
    watchdogThread: Thread[ChannelLoop]
    protoIn = cint(0)
    protoOut = cint(1)
      ## The protocol's descriptors; see "THE CHANNEL". Only `writeFrameBytes`
      ## writes `protoOut`.
    livenessIn = cint(-1)
    livenessOut = cint(-1)
    wakeRead = cint(-1)
    wakeWrite = cint(-1)
      ## The reader writes a byte here after every frame it queues, so the
      ## event loop wakes for it instead of polling.

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

  proc writeFrameBytes*(frame: string) =
    ## THE one place a frame leaves the process: whole, under the lock, on the
    ## protocol's output descriptor.
    if frame.len == 0:
      return
    withLock writeLock:
      writeAll(protoOut, frame)

  proc sendRaw(msg: JsonNode) =
    writeFrameBytes(encodeMessage(msg))

  proc crashLine(id: string) =
    writeAll(2, "\nct-plugin-crash: " & id & "\n")

  proc onFatalSignal(sig: cint) {.noconv.} =
    # Async-signal-safe: `write` of a static buffer, `sigaction`, `raise`.
    # `sigaction`, not `signal`: `posix.signal` returns nothing on Nim 2.2.4.
    const prefix = "\nct-plugin-crash: "
    discard posix.write(2, prefix.cstring, prefix.len)
    if busyLen > 0:
      discard posix.write(2, busyName[0].addr, busyLen)
    discard posix.write(2, "\n".cstring, 1)
    var dfl: Sigaction
    dfl.sa_handler = SIG_DFL
    discard sigemptyset(dfl.sa_mask)
    discard sigaction(sig, dfl, nil)
    discard posix.raise(sig)

  proc installCrashRecord() =
    for sig in [SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT]:
      var sa: Sigaction
      sa.sa_handler = onFatalSignal
      discard sigemptyset(sa.sa_mask)
      sa.sa_flags = SA_RESETHAND
      discard sigaction(sig, sa, nil)

  proc wake() =
    if wakeWrite >= 0:
      var b = 'w'
      discard posix.write(wakeWrite, b.addr, 1)

  proc channelLoop(c: ChannelLoop) {.thread.} =
    ## The reader (protocol input) and the watchdog (liveness input) are this
    ## loop with different settings. Answering `ping` here, off the main
    ## thread, is what lets a stuck main thread still produce a `pong` naming
    ## the plugin it is stuck in.
    var reader: FrameReader
    var buf: array[65536, char]
    while true:
      let n = posix.read(c.readFd, buf[0].addr, buf.len)
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
          if st == fsOversize and c.toInbox:
            inbox.send("")
            wake()
            return
          break
        if c.answerPings and frame.contains("\"ping\""):
          var parsed: JsonNode
          try: parsed = parseJson(frame)
          except CatchableError: parsed = nil
          if not parsed.isNil and parsed{"type"}.getStr("") == "ping":
            let busy = busyNow()
            let ms = if busy.len > 0: (nowNs() - busySinceNs) div 1_000_000 else: 0
            let pong = encodeMessage(%*{"type": "pong", "seq": parsed{"seq"},
                       "busy": (if busy.len > 0: %busy else: newJNull()),
                       "busyMs": ms})
            if c.pongLocked:
              writeFrameBytes(pong)
            else:
              writeAll(c.pongFd, pong)
            continue
        if c.toInbox:
          inbox.send(frame)
          wake()
    if c.toInbox:
      inbox.send("")
      wake()

  proc fdOpen(fd: cint): bool = fcntl(fd, F_GETFD) >= 0

  proc privateFd(fd: cint) =
    ## Close-on-exec, so no program the plugin starts inherits the channel; and
    ## blocking, because the reader and the watchdog block in `read`.
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 and (flags and O_NONBLOCK) != 0:
      discard fcntl(fd, F_SETFL, flags and not O_NONBLOCK)

  proc openChannel() =
    ## See "THE CHANNEL".
    let spec = getEnv(ChannelEnv)
    var fds: seq[cint]
    if spec.startsWith("fds:"):
      for part in spec[4 .. ^1].split(','):
        try: fds.add cint(parseInt(part.strip))
        except ValueError: discard
    if fds.len == 4 and fds[0].fdOpen and fds[1].fdOpen:
      protoIn = fds[0]
      protoOut = fds[1]
      if fds[2].fdOpen and fds[3].fdOpen:
        livenessIn = fds[2]
        livenessOut = fds[3]
      for fd in [protoIn, protoOut, livenessIn, livenessOut]:
        if fd >= 0: privateFd(fd)
      delEnv(ChannelEnv)
    else:
      # The fallback: the standard streams, with stdout made the log.
      protoIn = 0
      protoOut = dup(1)
      privateFd(protoOut)
      discard dup2(2, 1)

# ---------------------------------------------------------------------------
# Owners: who is running
# ---------------------------------------------------------------------------

proc enter(p: Plugin): Plugin =
  result = currentOwner
  currentOwner = p
  if p.isNil: clearBusy() else: setBusy(p.id)

proc leave(prev: Plugin) =
  currentOwner = prev
  if prev.isNil: clearBusy() else: setBusy(prev.id)

proc send(p: Plugin; msg: JsonNode) =
  msg["plugin"] = %p.id
  sendRaw(msg)

when defined(ctPluginSdkTestHooks) and not defined(wasm32):
  proc sendTrickled*(p: Plugin; msg: JsonNode; chunk, delayMs: int) =
    ## TEST HOOK, compiled only into the host's test package: one frame
    ## written `chunk` bytes at a time, `delayMs` apart, on the protocol
    ## descriptor and holding the frame lock throughout, as a large frame
    ## draining into a full pipe does. The `pong` has a descriptor of its
    ## own (§11.4.1), so it does not wait for this; the hook now exercises
    ## the host's tolerance of a slow frame.
    msg["plugin"] = %p.id
    let frame = encodeMessage(msg)
    withLock writeLock:
      var off = 0
      while off < frame.len:
        let n = min(chunk, frame.len - off)
        writeAll(protoOut, frame[off ..< off + n])
        off += n
        os.sleep(delayMs)

template attributed(p: Plugin; reqId: string; body: untyped) =
  ## Run `body` with `p` as owner. Its `CatchableError` is `p`'s error.
  let prevOwner = enter(p)
  try:
    body
  except CatchableError as e:
    p.send(%*{"type": "error", "id": reqId, "message": e.msg,
              "exception": $e.name, "epoch": p.sdk.epoch.toJson})
  except Defect:
    crashLine(p.id)
    raise
  finally:
    leave(prevOwner)

when not defined(wasm32):
  proc runOwned(owner: Plugin; cb: proc()) =
    if owner.isNil:
      try:
        cb()
      except CatchableError as e:
        # No plugin was running when this was scheduled: the event loop's own
        # work. It is logged, and nobody's fault is guessed.
        writeAll(2, "codetracer_plugin_sdk: an unattributed callback raised " &
                    $e.name & ": " & e.msg & "\n")
    else:
      owner.attributed(""):
        cb()

when not defined(wasm32):
  proc installOwners() =
    ## `asyncdispatch` schedules every continuation through `callSoon`. The
    ## SDK's own captures the owner current at scheduling time and runs the
    ## callback under it (see "ATTRIBUTION").
    discard getGlobalDispatcher()
    let base = getCallSoonProc()
    setCallSoonProc(proc(cbproc: proc ()) {.gcsafe.} =
      {.cast(gcsafe).}:
        let owner = currentOwner
        base(proc() {.gcsafe.} =
          {.cast(gcsafe).}:
            runOwned(owner, cbproc)))

  proc own*[T](p: Plugin; f: Future[T]): Future[T] =
    ## `f`, completed under `p` as owner, so the code after `await p.own(f)`
    ## is attributed to `p` even when `f` was completed by the event loop.
    ## Every primitive below is already wrapped.
    let o = newFuture[T]("codetracer_plugin_sdk.own")
    let plugin = p
    f.addCallback(proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        let prev = enter(plugin)
        try:
          if f.failed:
            o.fail(f.error)
          else:
            when T is void:
              o.complete()
            else:
              o.complete(f.read)
        finally:
          leave(prev))
    o

  proc go*(p: Plugin; f: Future[void]) =
    ## Run `f` to completion in the background. If it fails, the failure is
    ## `p`'s error (as a raising handler's is), not the end of the process.
    asyncCheck p.own(f)

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
# Timers: per plugin, attributed
# ---------------------------------------------------------------------------

proc addTimer(p: Plugin; ms: int; repeat: bool;
              cb: proc(p: Plugin) {.closure.}): PluginTimer =
  let interval = max(1, ms)
  result = PluginTimer(plugin: p, intervalMs: interval, repeat: repeat, cb: cb,
                       dueNs: nowNs() + int64(interval) * 1_000_000)
  p.timers.add result

proc every*(p: Plugin; intervalMs: int;
            cb: proc(p: Plugin) {.closure.}): PluginTimer {.discardable.} =
  ## Run `cb` every `intervalMs` while `p` is active, with `p` as owner: a
  ## `CatchableError` it raises is `p`'s error, a loop in it is reported as
  ## `p` being busy. Cancelled at deactivation.
  p.addTimer(intervalMs, true, cb)

proc after*(p: Plugin; delayMs: int;
            cb: proc(p: Plugin) {.closure.}): PluginTimer {.discardable.} =
  ## Run `cb` once, `delayMs` from now, as `every` runs it.
  p.addTimer(delayMs, false, cb)

proc cancel*(t: PluginTimer) =
  if not t.isNil: t.cancelled = true

proc runDue*(sdk: PluginSdk) =
  ## Run every timer that is due, each with its plugin as owner. The SDK's
  ## loop calls it; a host-driven arm can call it from its own tick.
  let now = nowNs()
  for p in sdk.plugins.values:
    if not p.active or p.timers.len == 0:
      continue
    let due = p.timers
    for t in due:
      if t.cancelled or t.dueNs > now:
        continue
      if t.repeat:
        t.dueNs = now + int64(t.intervalMs) * 1_000_000
      else:
        t.cancelled = true
      p.attributed(""):
        t.cb(p)
    var kept: seq[PluginTimer]
    for t in p.timers:
      if not t.cancelled: kept.add t
    p.timers = kept

proc nextDueMs(sdk: PluginSdk): int =
  ## Milliseconds until the next timer is due; -1 when none is set.
  result = -1
  let now = nowNs()
  for p in sdk.plugins.values:
    if not p.active: continue
    for t in p.timers:
      if t.cancelled: continue
      let ms = int(max(0'i64, (t.dueNs - now) div 1_000_000))
      if result < 0 or ms < result: result = ms

when not defined(wasm32):
  # ---------------------------------------------------------------------------
  # §8.1's primitives, owned by the plugin
  # ---------------------------------------------------------------------------

  proc refused[T](p: Plugin; what: string): Future[T] =
    result = newFuture[T]("codetracer_plugin_sdk." & what)
    result.complete(T(status: ioClosed,
      message: "plugin '" & p.id & "' is not active"))

  proc spawnProcess*(p: Plugin; name: string; args: seq[string] = @[];
                     env: seq[(string, string)] = @[];
                     workingDir = ""): Future[SpawnOutcome] =
    ## §8.1's Process row: `name` is a program the plugin's manifest declared
    ## in `executables`, resolved on the PATH the plugin process was started
    ## with; `args` is a list, and no shell is involved. The child gets exactly
    ## `env`, pipes of its own for stdin, stdout and stderr, and a process group
    ## of its own, which `closeProcess` and deactivation kill as a whole.
    if p.io.isNil: return refused[SpawnOutcome](p, "spawnProcess")
    p.own(plugin_io.spawnProcess(p.io, name, args, env, workingDir))

  proc read*(p: Plugin; s: PluginStream;
             maxBytes = DefaultReadChunk): Future[ReadOutcome] =
    ## A partial read (`plugin_io.read`), its continuation attributed to `p`.
    p.own(plugin_io.read(s, maxBytes))

  proc write*(p: Plugin; s: PluginStream; data: string): Future[WriteOutcome] =
    p.own(plugin_io.write(s, data))

  proc readFrame*(p: Plugin; s: PluginStream; framing: Framing;
                  delim = '\n'): Future[FrameOutcome] =
    p.own(plugin_io.readFrame(s, framing, delim))

  proc writeFrame*(p: Plugin; s: PluginStream; payload: string; framing: Framing;
                   delim = '\n'): Future[WriteOutcome] =
    p.own(plugin_io.writeFrame(s, payload, framing, delim))

  proc awaitExit*(p: Plugin; process: PluginProcess): Future[ExitOutcome] =
    p.own(plugin_io.awaitExit(process))

  proc signalProcess*(p: Plugin; process: PluginProcess;
                      sig: PluginSignal): Future[ExitOutcome] =
    p.own(plugin_io.signalProcess(process, sig))

  proc connectTcp*(p: Plugin; host: string; port: int;
                   tls = false): Future[SocketOutcome] =
    ## §8.1's Socket row. Loopback needs `socket:local`; anything else needs
    ## `socket:remote` and a declared host (`capabilities.decide`).
    if p.io.isNil: return refused[SocketOutcome](p, "connectTcp")
    p.own(plugin_io.connectTcp(p.io, host, port, tls))

  proc connectUnixSocket*(p: Plugin; path: string): Future[SocketOutcome] =
    if p.io.isNil: return refused[SocketOutcome](p, "connectUnixSocket")
    p.own(plugin_io.connectUnixSocket(p.io, path))

  proc listenTcp*(p: Plugin; host: string; port: int): Future[ListenOutcome] =
    ## Loopback only. `boundPort` reads the port when `port` is 0.
    if p.io.isNil: return refused[ListenOutcome](p, "listenTcp")
    p.own(plugin_io.listenTcp(p.io, host, port))

  proc listenUnixSocket*(p: Plugin; path: string): Future[ListenOutcome] =
    if p.io.isNil: return refused[ListenOutcome](p, "listenUnixSocket")
    p.own(plugin_io.listenUnixSocket(p.io, path))

  proc acceptFrom*(p: Plugin; l: PluginListener): Future[SocketOutcome] =
    p.own(plugin_io.acceptFrom(l))

  proc sleepFor*(p: Plugin; ms: int): Future[void] =
    ## `sleepAsync`, its continuation attributed to `p`.
    p.own(sleepAsync(ms))

  proc handleReport*(p: Plugin): string =
    ## The plugin's live processes, streams and sockets, one per line.
    if p.io.isNil: "" else: plugin_io.handleReport(p.io)

  # ---- running a tool to completion -------------------------------------------

  type
    ToolRun* = ref object
      ## One run of an external program, started by `runTool`.
      name*: string
      args*: seq[string]
      output*: string
        ## stdout and stderr together, in the order they were read.
      truncated*: bool
      exitCode*: int
        ## The exit status; 128 + the signal when it was killed by one.
      signalled*: bool
      timedOut*: bool
      cancelled*: bool
      startError*: string
        ## Non-empty when the program was not started: refused (not declared,
        ## `process` not granted), not on the PATH, or a working directory that
        ## does not exist.
      pid*: int
      finished*: Future[ToolRun]
        ## Completes, with this run, once the program has exited (or was
        ## killed) and its output is read; never fails.
      process: PluginProcess

  proc drainInto(p: Plugin; s: PluginStream; run: ToolRun;
                 maxOutput: int) {.async.} =
    while true:
      let r = await p.read(s)
      if r.status != ioOk:
        return
      if run.output.len < maxOutput:
        let keep = min(r.data.len, maxOutput - run.output.len)
        run.output.add r.data[0 ..< keep]
        if keep < r.data.len: run.truncated = true
      else:
        run.truncated = true

  proc toolBody(p: Plugin; run: ToolRun; env: seq[(string, string)];
                workingDir: string; timeoutMs, maxOutput: int) {.async.} =
    let started = await p.spawnProcess(run.name, run.args, env, workingDir)
    if started.status != ioOk:
      run.startError = started.message
      run.exitCode = -1
      return
    let child = started.process
    run.process = child
    run.pid = child.pid
    if run.cancelled:
      closeProcess(child)
      return
    # Nothing is written to the tool: a program that reads its stdin sees
    # end-of-file rather than waiting on the plugin.
    closeStream(child.stdin)
    let output = p.drainInto(child.stdout, run, maxOutput) and
                 p.drainInto(child.stderr, run, maxOutput)
    let exited = p.awaitExit(child)
    let inTime = await p.own(withTimeout(exited, max(1, timeoutMs)))
    if not inTime or run.cancelled:
      run.timedOut = not run.cancelled
      run.exitCode = -1
      run.signalled = true
      closeProcess(child)      # SIGKILL to the group, reaped
      return
    let e = exited.read
    run.exitCode = e.code
    run.signalled = e.signalled
    # What it wrote is in the pipes already; a grandchild still holding them
    # does not keep the run alive past a short grace.
    discard await p.own(withTimeout(output, 1_000))
    closeProcess(child)

  proc runTool*(p: Plugin; name: string; args: seq[string] = @[];
                workingDir = ""; timeoutMs = 15_000; maxOutput = 1 shl 20;
                env: seq[(string, string)] = @[]): ToolRun =
    ## Run the declared program `name` with `args`, collect what it writes (up
    ## to `maxOutput` bytes), and kill its whole process group if it has not
    ## exited within `timeoutMs`. Never blocks: `finished` completes later, and
    ## the code after `await run.finished` (or a callback on it) runs with `p`
    ## as owner. Deactivating `p` kills what is still running.
    result = ToolRun(name: name, args: args)
    let run = result
    run.finished = newFuture[ToolRun]("codetracer_plugin_sdk.runTool")
    let body = toolBody(p, run, env, workingDir, timeoutMs, maxOutput)
    body.addCallback(proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        let prev = enter(p)
        try:
          if body.failed and run.startError.len == 0:
            run.startError = body.error.msg
          if not run.finished.finished:
            run.finished.complete(run)
        finally:
          leave(prev))

  proc cancel*(run: ToolRun) =
    ## Stop the run: its process group is killed and `finished` completes with
    ## `cancelled` set.
    if run.isNil or run.finished.finished: return
    run.cancelled = true
    if not run.process.isNil:
      closeProcess(run.process)

# ---------------------------------------------------------------------------
# Handler dispatch: one at a time, attributed
# ---------------------------------------------------------------------------

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

when not defined(wasm32):
  proc ioContext(p: Plugin; msg: JsonNode): PluginContext =
    ## The context §8.1's primitives decide against: the grants and the
    ## declared sets the host sent with `activate`.
    var g: GrantSet
    for c in p.grants:
      try: g.capabilities.incl parseEnum[Capability](c)
      except ValueError: discard
    let d = msg{"declared"}
    if not d.isNil and d.kind == JObject:
      for e in d{"executables"}.getElems: g.executables.add e.getStr("")
      for h in d{"hosts"}.getElems:
        g.hosts.add DeclaredHost(host: h{"host"}.getStr(""),
                                 port: h{"port"}.getInt(AnyPort))
      for e in d{"readPaths"}.getElems: g.readPaths.add e.getStr("")
      for e in d{"writePaths"}.getElems: g.writePaths.add e.getStr("")
      let egress = d{"traceEgress"}
      g.traceEgress.acknowledged = egress{"acknowledged"}.getBool(false)
      g.traceEgress.statement = egress{"statement"}.getStr("")
    # §8.1.2: `process` subsumes every other capability, and every rule
    # that asks "may this plugin do X" asks it of the effective set. A
    # native plugin holds `process` by construction (§11.3).
    g.capabilities = effectiveCapabilities(g.capabilities)
    var m: PluginManifest
    m.id = p.id
    m.capabilities = g.capabilities
    m.grants = g
    # The budget is PLAT-7's in-process one and never runs here (no `inRun`);
    # the host's watchdog is what bounds a native plugin's time.
    PluginContext(manifest: m, state: newRunState(p.id, initDuration(seconds = 1)))

proc activate(sdk: PluginSdk; p: Plugin; msg: JsonNode) =
  if p.active:
    sendRaw(%*{"type": "activated", "plugin": p.id})
    return
  p.settings = if msg{"settings"}.isNil: newJObject() else: msg["settings"]
  p.grants = @[]
  if not msg{"grants"}.isNil:
    for g in msg["grants"]: p.grants.add g.getStr("")
  when not defined(wasm32):
    p.io = p.ioContext(msg)
  p.timers = @[]
  var failed = ""
  # `active` is set before `onActivate` runs, so a timer or a primitive it
  # starts works at once; a failed activation clears it again.
  p.active = true
  let prev = enter(p)
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
    leave(prev)
  if failed.len > 0:
    p.active = false
    for t in p.timers: t.cancel()
    p.timers = @[]
    when not defined(wasm32):
      if not p.io.isNil: discard p.io.state.handles.closeAll()
    sendRaw(%*{"type": "activation-failed", "plugin": p.id, "reason": failed})
  else:
    sendRaw(%*{"type": "activated", "plugin": p.id})

proc deactivate(p: Plugin) =
  if not p.active:
    return
  p.attributed(""):
    if not p.onDeactivate.isNil:
      p.onDeactivate(p)
  for t in p.timers: t.cancel()
  p.timers = @[]
  when not defined(wasm32):
    if not p.io.isNil:
      # §8.1.1: deactivation closes what the plugin holds — every process
      # group it started is killed and reaped, every socket closed.
      var failures: seq[HandleCloseFailure]
      discard p.io.state.handles.closeAll(failures)
      for f in failures:
        p.log("could not release " & f.description & ": " & f.message, "error")
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
  ## One frame from the host: parsed and dispatched. The loop's body, callable
  ## by an arm that receives frames some other way.
  var msg: JsonNode
  try:
    msg = parseJson(frame)
  except CatchableError:
    return
  sdk.handle(msg)

proc isRunning*(sdk: PluginSdk): bool = sdk.running

when defined(wasm32):
  var guestSdk: PluginSdk
    ## The SDK `run` registered. The host's calls below reach it.

  proc NimMain() {.importc.}

  template guarded(what: string; body: untyped) =
    ## Nothing may escape into the host: under Nim's C exceptions an
    ## exception left unhandled at an export would leave the module running
    ## in error mode, ignoring every later frame. A handler's
    ## `CatchableError` is already its plugin's `error`; what reaches here is
    ## a `Defect`, which ends the instance (§11.5's rule, the instance being
    ## this plugin's process), with the defect on the plugin log.
    try:
      body
    except CatchableError as e:
      stderr.writeLine "ct-plugin: " & what & ": " & $e.name & ": " & e.msg
    except Defect as e:
      stderr.writeLine "ct-plugin-crash: " & what & ": " & $e.name & ": " & e.msg
      stderr.writeLine e.getStackTrace()
      quit(70)

  proc run*(sdk: PluginSdk) =
    ## Under `ct-plugin-host` there is no loop to run: the host calls
    ## `ct_plugin_frame` with each frame. `run` registers the SDK and returns.
    guestSdk = sdk
    sdk.running = true

  proc ct_plugin_init() {.exportc,
      codegenDecl: "__attribute__((export_name(\"ct_plugin_init\"))) $# $#$#".} =
    ## The module's own initialisation: the plugin's top level, which builds
    ## its SDK, adds its plugins and calls `run`.
    guarded("init"):
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
      guarded("frame"):
        guestSdk.handleFrame(frame)
        if not guestSdk.running:
          for q in guestSdk.plugins.values:
            q.deactivate()
    int32(not guestSdk.isNil and guestSdk.nextDueMs() >= 0)

  proc ct_plugin_idle(): int32 {.exportc,
      codegenDecl: "__attribute__((export_name(\"ct_plugin_idle\"))) $# $#$#".} =
    if guestSdk.isNil: return 0
    guarded("idle"):
      guestSdk.runDue()
    int32(guestSdk.nextDueMs() >= 0)

else:
  proc run*(sdk: PluginSdk) =
    ## The protocol loop. Returns after `shutdown`, or when the host closes the
    ## channel; the process should then exit.
    initLock(writeLock)
    openChannel()
    inbox.open()
    installCrashRecord()
    installOwners()
    var wakeFds: array[2, cint]
    if pipe(wakeFds) == 0:
      wakeRead = wakeFds[0]
      wakeWrite = wakeFds[1]
      for fd in wakeFds:
        discard fcntl(fd, F_SETFD, FD_CLOEXEC)
        discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
      register(AsyncFD(wakeRead))
      addRead(AsyncFD(wakeRead), proc(fd: AsyncFD): bool {.gcsafe.} =
        var buf: array[256, char]
        while posix.read(cint(fd), buf[0].addr, buf.len) > 0: discard
        false)
    let separate = livenessIn >= 0
    createThread(readerThread, channelLoop,
      ChannelLoop(readFd: protoIn, toInbox: true, answerPings: not separate,
                  pongFd: protoOut, pongLocked: true))
    if separate:
      createThread(watchdogThread, channelLoop,
        ChannelLoop(readFd: livenessIn, toInbox: false, answerPings: true,
                    pongFd: livenessOut, pongLocked: false))
    sdk.running = true
    var ended = false
    while sdk.running and not ended:
      while sdk.running:
        let (got, frame) = inbox.tryRecv()
        if not got:
          break
        if frame.len == 0:
          ended = true
          break
        sdk.handleFrame(frame)
      if ended or not sdk.running:
        break
      sdk.runDue()
      let due = sdk.nextDueMs()
      let timeout = if due < 0: 500 else: min(due, 500)
      try:
        poll(if wakeRead >= 0: timeout else: min(timeout, 2))
      except ValueError:
        discard   # nothing registered and nothing pending
      except CatchableError as e:
        writeAll(2, "codetracer_plugin_sdk: the event loop raised " & $e.name &
                    ": " & e.msg & "\n")
    for p in sdk.plugins.values:
      p.deactivate()
