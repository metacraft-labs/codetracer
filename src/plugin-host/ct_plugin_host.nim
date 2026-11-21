## ct_plugin_host.nim — CodeTracer's WebAssembly plugin host
## (Extensibility-Model.md §11.9).
##
## ONE PROCESS, MANY PACKAGES, ONE INSTANCE PER PLUGIN. The supervisor starts
## this program once per primary session with every installed WASM package
## (`--package <component dir>`, repeated). From the supervisor's side it is a
## plugin process like any other: it speaks §11.4 on stdin/stdout, its `hello`
## lists every plugin of every package it was given, and every message it
## writes names its plugin. Inside, each plugin that is activated gets its own
## engine store — its own linear memory, its own memory limit, its own
## per-call deadline — instantiated from its package's `plugin.wasm`.
##
## ## WHAT A FAULT COSTS
##
## A trap, a deadline overrun or a memory-limit hit ends that plugin's
## instance, and nothing else: the host writes one `fault` message naming the
## plugin (the `instance-faults` feature it announces in `hello`), drops
## whatever that instance had in flight, and keeps serving every other
## instance. The supervisor gives the plugin a strike and removes what it
## pushed (§11.6.3), and may activate it again, which builds a fresh instance.
## The host process does not restart.
##
## A fault of the HOST — the engine crashing, the process killed — is a process
## fault, handled by the supervisor's native path (§11.6.4): the crash is
## charged to the plugin that was executing, which the watchdog (the stdin
## reader thread, answering `ping` with the plugin whose call is running) and
## the crash record (`ct-plugin-crash: <plugin>` on stderr, from a fatal-signal
## handler) name.
##
## ## CAPABILITIES ARE IMPORTS
##
## A module may import only what `declareImports` declares; anything else is
## an instantiation error naming the import, reported as `activation-failed`.
## The imports are:
##
## | import | what it does |
## |---|---|
## | `ct.send(ptr, len)` | one protocol message from the plugin. Its `plugin` must be the instance's own; anything else is a protocol violation and is dropped |
## | `ct.io(ptr, len) -> i32` | an I/O request (`readPath`, `writePath`, `runProcess`, `connectTcp`, `connectUnix`, `streamRead`, `streamWrite`, `streamClose`), run by `plugin_io.nim`'s primitives — which call `capabilities.decide` before anything exists — under the GRANTS THE USER GAVE (the `activate` message's `grants`, intersected with the manifest's declaration). The answer arrives later as an `io-result` frame |
## | `ct.now_ms() -> i64` | the monotonic clock |
## | WASI `fd_write` (1, 2 only), `proc_exit`, `clock_time_get`, `random_get`, `environ_*`/`args_*` (empty), `fd_close`/`fd_seek`/`fd_fdstat_get` (refused with EBADF), `sched_yield`, and Emscripten's `emscripten_notify_memory_growth` | what the Nim runtime under Emscripten's `STANDALONE_WASM` links, and nothing that reaches a file, a socket or a process |
##
## A WASM plugin may therefore hold less than `process` — or nothing at all.

import std/[json, locks, monotimes, os, posix, sequtils, strutils, tables, times,
            sysrand, asyncdispatch]

import ../common/plugin_model
import ../frontend/viewmodel/plugin_host/[protocol, plugin_api, plugin_io]
import ./engine

const
  HostPackage* = "ct-plugin-host"
    ## The `package` this process names in its `hello`.
  InstanceFaultsFeature* = "instance-faults"
  DefaultMemoryMb = 64
  DefaultCallDeadlineMs = 2_000
  IdleIntervalMs = 20
  MaxLogPerCall = 64 * 1024

type
  PackageEntry = ref object
    name: string
    dir: string
    modulePath: string
    spec: PluginPackage
    module: WasmModule
    compileError: string

  Guest = ref object
    id: string
    pkg: PackageEntry
    inst: WasmInstance
    ctx: PluginContext
    io: PluginIoContext
    helloSeen: bool
    helloProblem: string
    dead: bool
    wantsIdle: bool
    nextIdleMs: int64
    streams: Table[int, PluginStream]
    processes: Table[int, PluginProcess]
    nextHandle: int

var
  engineRef: WasmEngine
  packages: OrderedTable[string, PackageEntry]
  pluginPackage: Table[string, PackageEntry]
  guests: OrderedTable[string, Guest]
  hostHello: JsonNode
  current: Guest
  memoryBytes = DefaultMemoryMb * 1024 * 1024
  callDeadlineMs = DefaultCallDeadlineMs
  traceRoots: seq[string]
  running = true
  traceFrames = existsEnv("CT_PLUGIN_HOST_TRACE")
    ## Log every frame handed to an instance to stderr (the plugin log).
  ioCompletions: seq[(string, JsonNode)]
    ## (plugin, io-result) waiting to be delivered by the main loop.

# ---------------------------------------------------------------------------
# Output, the watchdog's shared state, the crash record
# ---------------------------------------------------------------------------

var
  writeLock: Lock
  busyName: array[256, char]
  busyLen {.volatile.}: int
  busySinceNs {.volatile.}: int64
  inbox: Channel[string]
  readerThread: Thread[void]

proc nowNs(): int64 = getMonoTime().ticks
proc nowMs(): int64 = nowNs() div 1_000_000

proc setBusy(id: string) =
  let n = min(id.len, busyName.len - 1)
  for i in 0 ..< n: busyName[i] = id[i]
  busySinceNs = nowNs()
  busyLen = n

proc clearBusy() = busyLen = 0

proc busyNow(): string =
  let n = busyLen
  result = newString(n)
  for i in 0 ..< n: result[i] = busyName[i]

proc writeAll(fd: cint; data: string) =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, data[off].unsafeAddr, data.len - off)
    if n > 0: off += n
    elif n < 0 and errno == EINTR: continue
    else: return

proc sendRaw(msg: JsonNode) =
  let frame = encodeMessage(msg)
  if frame.len == 0: return
  withLock writeLock:
    writeAll(1, frame)

proc logLine(s: string) =
  withLock writeLock:
    writeAll(2, s & "\n")

proc onFatalSignal(sig: cint) {.noconv.} =
  const prefix = "\nct-plugin-crash: "
  discard posix.write(2, prefix.cstring, prefix.len)
  if busyLen > 0:
    discard posix.write(2, busyName[0].addr, busyLen)
  discard posix.write(2, "\n".cstring, 1)
  discard signal(sig, SIG_DFL)
  discard posix.raise(sig)

proc installCrashRecord() =
  ## BEFORE the engine exists: wasmtime installs its own SIGSEGV/SIGBUS
  ## handlers for its guard pages and chains to the handler it found for a
  ## fault outside WebAssembly. Installed after it, this handler would take
  ## wasmtime's own traps.
  for sig in [SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT]:
    var sa: Sigaction
    sa.sa_handler = onFatalSignal
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = SA_RESETHAND
    discard sigaction(sig, sa, nil)

proc readerLoop() {.thread.} =
  ## The watchdog: owns stdin and answers `ping` itself, naming the plugin
  ## whose call is running, so a call stuck in the engine still lets the host
  ## learn who is stuck.
  var reader: FrameReader
  var buf: array[65536, char]
  while true:
    let n = posix.read(0, buf[0].addr, buf.len)
    if n == 0: break
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
# Guest memory
# ---------------------------------------------------------------------------

proc readGuest(mem: ptr UncheckedArray[byte]; memLen: int; p, n: int64;
               dest: var string): bool =
  if p < 0 or n < 0 or p + n > memLen: return false
  dest = newString(n.int)
  if n > 0: copyMem(dest[0].addr, mem[p.int].addr, n.int)
  true

proc u32At(mem: ptr UncheckedArray[byte]; memLen: int; p: int64;
           v: var uint32): bool =
  if p < 0 or p + 4 > memLen: return false
  copyMem(v.addr, mem[p.int].addr, 4)
  true

proc putU32(mem: ptr UncheckedArray[byte]; memLen: int; p: int64;
            v: uint32): bool =
  if p < 0 or p + 4 > memLen: return false
  var x = v
  copyMem(mem[p.int].addr, x.addr, 4)
  true

proc putU64(mem: ptr UncheckedArray[byte]; memLen: int; p: int64;
            v: uint64): bool =
  if p < 0 or p + 8 > memLen: return false
  var x = v
  copyMem(mem[p.int].addr, x.addr, 8)
  true

# ---------------------------------------------------------------------------
# Faults
# ---------------------------------------------------------------------------

proc faultKindOf(st: CallStatus): string =
  case st
  of csDeadline: "deadline"
  of csMemoryLimit: "memory-limit"
  of csHostRefused: "exited"
  else: "trap"

proc retire(g: Guest) =
  if g.dead: return
  g.dead = true
  for s in g.streams.values:
    try: closeStream(s) except CatchableError: discard
  for p in g.processes.values:
    try: closeProcess(p) except CatchableError: discard
  g.streams.clear()
  g.processes.clear()
  g.inst.release()
  g.inst = nil
  guests.del(g.id)

proc fault(g: Guest; kind, detail: string) =
  ## One instance is over; the host and every other instance go on.
  logLine("ct-plugin-host: " & g.id & ": " & kind & ": " & detail)
  sendRaw(%*{"type": "fault", "plugin": g.id, "kind": kind, "detail": detail})
  g.retire()

proc violation(g: Guest; detail: string) =
  ## A message the host would not pass on. The instance keeps running; the
  ## supervisor strikes the plugin.
  sendRaw(%*{"type": "fault", "plugin": g.id, "kind": "protocol",
             "detail": detail})

# ---------------------------------------------------------------------------
# What a plugin sends
# ---------------------------------------------------------------------------

proc checkGuestHello(g: Guest; msg: JsonNode) =
  let check = checkProcessHello(msg, g.pkg.name, g.pkg.spec.pluginIds)
  g.helloSeen = true
  if not check.ok:
    g.helloProblem = check.problems.join("; ")

proc fromGuest(g: Guest; text: string) =
  if text.len > MaxProtocolFrameBytes:
    g.violation("a message larger than " &
                $(MaxProtocolFrameBytes div (1024 * 1024)) & " MiB")
    return
  var msg: JsonNode
  try:
    msg = parseJson(text)
  except CatchableError:
    g.violation("a message that is not JSON")
    return
  if msg.kind != JObject:
    g.violation("a message that is not an object")
    return
  let t = msg{"type"}.getStr("")
  if t == "hello":
    g.checkGuestHello(msg)
    return
  if t in ["pong", "fault", "ping"]:
    g.violation("a '" & t & "' message, which only the host sends")
    return
  let named = msg{"plugin"}.getStr("")
  if named != g.id:
    # The instance belongs to one plugin. A message naming another — even a
    # sibling from the same package — would be charged to that plugin.
    g.violation("a message naming plugin '" & named & "'; this instance is '" &
                g.id & "'")
    return
  sendRaw(msg)

# ---------------------------------------------------------------------------
# I/O through plugin_io.nim
# ---------------------------------------------------------------------------

proc outcomeJson(status: IoStatus; message: string): JsonNode =
  %*{"status": $status, "message": message}

proc complete(g: Guest; id: JsonNode; payload: JsonNode) =
  var p = payload
  p["type"] = %"io-result"
  p["plugin"] = %g.id
  p["id"] = id
  ioCompletions.add (g.id, p)

proc onDone[T](f: Future[T]; cb: proc() {.closure.}) =
  ## `addCallback` for this module's callbacks, which read the host's tables.
  ## The host's one other thread (the watchdog) touches none of them.
  {.cast(gcsafe).}:
    f.addCallback(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        cb())

proc startIo(g: Guest; req: JsonNode)

proc ioImport(g: Guest; text: string): int64 =
  var req: JsonNode
  try:
    req = parseJson(text)
  except CatchableError:
    return -1
  if req.kind != JObject or req{"id"}.isNil: return -1
  g.startIo(req)
  0

proc startIo(g: Guest; req: JsonNode) =
  let id = req["id"]
  let op = req{"op"}.getStr("")
  let gid = g.id
  template guestAlive(): bool = guests.hasKey(gid) and guests[gid] == g
  case op
  of "readPath":
    let f = readPath(g.ctx, g.io, req{"path"}.getStr(""))
    f.onDone proc() =
      if not guestAlive(): return
      let o = f.read
      var j = outcomeJson(o.status, o.message)
      j["data"] = %o.data
      g.complete(id, j)
  of "writePath":
    let f = writePath(g.ctx, g.io, req{"path"}.getStr(""), req{"data"}.getStr(""))
    f.onDone proc() =
      if not guestAlive(): return
      let o = f.read
      var j = outcomeJson(o.status, o.message)
      j["written"] = %o.written
      g.complete(id, j)
  of "runProcess":
    var args: seq[string]
    for a in req{"args"}.getElems: args.add a.getStr("")
    let f = spawnProcess(g.ctx, req{"name"}.getStr(""), args,
                         workingDir = req{"workingDir"}.getStr(""))
    f.onDone proc() =
      if not guestAlive(): return
      let o = f.read
      if o.status != ioOk:
        g.complete(id, outcomeJson(o.status, o.message))
        return
      let pr = o.process
      inc g.nextHandle
      let h = g.nextHandle
      g.processes[h] = pr
      proc drain(s: PluginStream; into: ref string): Future[void] {.async.} =
        while true:
          let r = await s.read()
          if r.status != ioOk: break
          into[].add r.data
      let outBuf = new string
      let errBuf = new string
      let both = drain(pr.stdout, outBuf) and drain(pr.stderr, errBuf)
      both.onDone proc() =
        let ex = pr.awaitExit()
        ex.onDone proc() =
          g.processes.del(h)
          if not guestAlive(): return
          let e = ex.read
          var j = outcomeJson(e.status, e.message)
          j["code"] = %e.code
          j["signalled"] = %e.signalled
          j["stdout"] = %outBuf[]
          j["stderr"] = %errBuf[]
          g.complete(id, j)
  of "connectTcp", "connectUnix":
    let f = if op == "connectTcp":
              connectTcp(g.ctx, req{"host"}.getStr(""), req{"port"}.getInt(0))
            else:
              connectUnixSocket(g.ctx, req{"path"}.getStr(""))
    f.onDone proc() =
      if not guestAlive(): return
      let o = f.read
      var j = outcomeJson(o.status, o.message)
      if o.status == ioOk:
        inc g.nextHandle
        g.streams[g.nextHandle] = o.stream
        j["stream"] = %g.nextHandle
      g.complete(id, j)
  of "streamRead":
    let h = req{"stream"}.getInt(0)
    if not g.streams.hasKey(h):
      g.complete(id, outcomeJson(ioClosed, "no such stream"))
      return
    let f = g.streams[h].read(req{"maxBytes"}.getInt(DefaultReadChunk))
    f.onDone proc() =
      if not guestAlive(): return
      let o = f.read
      var j = outcomeJson(o.status, o.message)
      j["data"] = %o.data
      g.complete(id, j)
  of "streamWrite":
    let h = req{"stream"}.getInt(0)
    if not g.streams.hasKey(h):
      g.complete(id, outcomeJson(ioClosed, "no such stream"))
      return
    let f = g.streams[h].write(req{"data"}.getStr(""))
    f.onDone proc() =
      if not guestAlive(): return
      let o = f.read
      var j = outcomeJson(o.status, o.message)
      j["written"] = %o.written
      g.complete(id, j)
  of "streamClose":
    let h = req{"stream"}.getInt(0)
    if g.streams.hasKey(h):
      closeStream(g.streams[h])
      g.streams.del(h)
    g.complete(id, outcomeJson(ioOk, ""))
  else:
    g.complete(id, outcomeJson(ioUnsupported,
      "plugin '" & g.id & "': '" & op & "' is not an I/O primitive"))

# ---------------------------------------------------------------------------
# The imports
# ---------------------------------------------------------------------------

type ImportId = enum
  iSend, iIo, iNowMs, iProcExit, iFdWrite, iFdClose, iFdSeek, iFdFdstat,
  iMemGrowth, iClockTimeGet, iRandomGet, iEnvironSizes, iEnvironGet,
  iArgsSizes, iArgsGet, iSchedYield

const ImportTable: array[ImportId, tuple[module, name, sig: string]] = [
  ("ct", "send", "ii:"),
  ("ct", "io", "ii:i"),
  ("ct", "now_ms", ":I"),
  ("wasi_snapshot_preview1", "proc_exit", "i:"),
  ("wasi_snapshot_preview1", "fd_write", "iiii:i"),
  ("wasi_snapshot_preview1", "fd_close", "i:i"),
  ("wasi_snapshot_preview1", "fd_seek", "iIii:i"),
  ("wasi_snapshot_preview1", "fd_fdstat_get", "ii:i"),
  ("env", "emscripten_notify_memory_growth", "i:"),
  ("wasi_snapshot_preview1", "clock_time_get", "iIi:i"),
  ("wasi_snapshot_preview1", "random_get", "ii:i"),
  ("wasi_snapshot_preview1", "environ_sizes_get", "ii:i"),
  ("wasi_snapshot_preview1", "environ_get", "ii:i"),
  ("wasi_snapshot_preview1", "args_sizes_get", "ii:i"),
  ("wasi_snapshot_preview1", "args_get", "ii:i"),
  ("wasi_snapshot_preview1", "sched_yield", ":i"),
]

const
  WasiEbadf = 8'i64
  WasiEinval = 28'i64

proc setErr(err: cstring; cap: csize_t; s: string) =
  let n = min(s.len, cap.int - 1)
  if n > 0: copyMem(err, s[0].unsafeAddr, n)
  cast[ptr UncheckedArray[char]](err)[max(n, 0)] = '\0'

proc hostCall(ctx: pointer; id: uint32; args: ptr UncheckedArray[int64];
              nargs: uint32; results: ptr UncheckedArray[int64];
              nresults: uint32; mem: ptr UncheckedArray[byte]; memLen: csize_t;
              err: cstring; errCap: csize_t): cint {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    let g = current
    let ml = memLen.int
    template fail(msg: string) =
      setErr(err, errCap, msg)
      return 1
    if g.isNil: fail("an import called outside a call")
    if id.int > ImportId.high.int: fail("unknown import")
    case ImportId(id)
    of iSend:
      var text: string
      if not readGuest(mem, ml, args[0], args[1], text):
        fail("ct.send: a message outside the instance's memory")
      g.fromGuest(text)
    of iIo:
      var text: string
      if not readGuest(mem, ml, args[0], args[1], text):
        fail("ct.io: a request outside the instance's memory")
      results[0] = g.ioImport(text)
    of iNowMs:
      results[0] = nowMs()
    of iProcExit:
      fail("the plugin called proc_exit(" & $args[0] & ")")
    of iFdWrite:
      let fd = args[0]
      var total = 0'u32
      for k in 0 ..< args[2].int:
        var p, n: uint32
        if not u32At(mem, ml, args[1] + k * 8, p) or
           not u32At(mem, ml, args[1] + k * 8 + 4, n):
          fail("fd_write: an iovec outside the instance's memory")
        var s: string
        if not readGuest(mem, ml, p.int64, n.int64, s):
          fail("fd_write: a buffer outside the instance's memory")
        if fd in [1'i64, 2'i64] and total.int < MaxLogPerCall:
          for line in s.strip(leading = false).splitLines:
            logLine("[" & g.id & "] " & line)
        total += n
      if fd notin [1'i64, 2'i64]:
        results[0] = WasiEbadf
      else:
        discard putU32(mem, ml, args[3], total)
        results[0] = 0
    of iFdClose, iFdSeek, iFdFdstat:
      results[0] = WasiEbadf
    of iMemGrowth:
      discard
    of iClockTimeGet:
      let t = if args[0] == 0: uint64(epochTime() * 1e9) else: uint64(nowNs())
      if not putU64(mem, ml, args[2], t): results[0] = WasiEinval
      else: results[0] = 0
    of iRandomGet:
      if args[0] < 0 or args[0] + args[1] > ml:
        results[0] = WasiEinval
      else:
        var bytes = urandom(args[1].int)
        if bytes.len > 0:
          copyMem(mem[args[0].int].addr, bytes[0].addr, bytes.len)
        results[0] = 0
    of iEnvironSizes, iArgsSizes:
      discard putU32(mem, ml, args[0], 0)
      discard putU32(mem, ml, args[1], 0)
      results[0] = 0
    of iEnvironGet, iArgsGet:
      results[0] = 0
    of iSchedYield:
      results[0] = 0
    0

proc declareImports(e: WasmEngine) =
  for id in ImportId:
    let (m, n, s) = ImportTable[id]
    let got = e.addImport(m, n, s)
    doAssert got == id.int, "import ids out of step: " & m & "." & n

# ---------------------------------------------------------------------------
# Calling into an instance
# ---------------------------------------------------------------------------

proc invoke(g: Guest; name: string; args: openArray[int64]; nresults = 0;
            optional = false): (bool, array[4, int64]) =
  ## One call, attributed, under the instance's deadline. A failure ends the
  ## instance (`fault`) and returns false.
  if g.dead or g.inst.isNil: return (false, default(array[4, int64]))
  current = g
  setBusy(g.id)
  let r = g.inst.call(name, args, callDeadlineMs, nresults)
  clearBusy()
  current = nil
  if r.status == csOk:
    return (true, r.results)
  if r.status == csNoSuchExport and optional:
    return (true, default(array[4, int64]))
  if not g.dead:
    g.fault(faultKindOf(r.status), "in " & name & ": " & r.message)
  (false, r.results)

proc deliver(g: Guest; msg: JsonNode) =
  ## Copy one frame into the instance's memory and hand it over.
  let text = $msg
  if traceFrames:
    logLine("ct-plugin-host: deliver " & msg{"type"}.getStr("") & " to " & g.id &
            " (" & $text.len & " bytes)")
  let (ok, res) = g.invoke("ct_plugin_alloc", [text.len.int64], nresults = 1)
  if not ok: return
  let p = res[0]
  let (mem, ml) = g.inst.memory()
  if p <= 0 or p + text.len > ml:
    g.fault("trap", "ct_plugin_alloc returned a buffer outside its memory")
    return
  if text.len > 0:
    copyMem(mem[p.int].addr, text[0].unsafeAddr, text.len)
  let (ok2, idle) = g.invoke("ct_plugin_frame", [p, text.len.int64], nresults = 1)
  if ok2:
    g.wantsIdle = idle[0] != 0

proc grantsFor(spec: PackagedPlugin; granted: JsonNode): GrantSet =
  ## The manifest's declaration, narrowed to what the user granted: a
  ## capability the activation does not carry is not held, whatever the
  ## manifest declares.
  result = spec.parsed.manifest.grants
  var given: set[Capability]
  if not granted.isNil and granted.kind == JArray:
    for c in granted:
      for cap in Capability:
        if $cap == c.getStr(""): given.incl cap
  result.capabilities = result.capabilities * given

proc specOf(pkg: PackageEntry; id: string): PackagedPlugin =
  for pp in pkg.spec.plugins:
    if pp.parsed.manifest.id == id: return pp

proc activationFailed(id, reason: string) =
  sendRaw(%*{"type": "activation-failed", "plugin": id, "reason": reason})

proc startGuest(id: string; msg: JsonNode) =
  let pkg = pluginPackage.getOrDefault(id, nil)
  if pkg.isNil:
    activationFailed(id, "ct-plugin-host was not given the package of '" & id & "'")
    return
  if pkg.module.isNil and pkg.compileError.len == 0:
    try:
      pkg.module = engineRef.compile(readFile(pkg.modulePath))
    except CatchableError as e:
      pkg.compileError = pkg.modulePath & ": " & e.msg
  if pkg.module.isNil:
    activationFailed(id, "the module of package '" & pkg.name & "' did not " &
                     "load: " & pkg.compileError)
    return
  let g = Guest(id: id, pkg: pkg)
  try:
    g.inst = engineRef.instantiate(pkg.module, memoryBytes, hostCall, nil)
  except CatchableError as e:
    activationFailed(id, "plugin '" & id & "' could not be instantiated: " & e.msg)
    return
  let spec = pkg.specOf(id)
  var manifest = spec.parsed.manifest
  manifest.grants = grantsFor(spec, msg{"grants"})
  g.ctx = PluginContext(manifest: manifest, state: PluginRunState(id: id))
  g.io = PluginIoContext(traceRoots: traceRoots)
  guests[id] = g
  # Emscripten's reactor initialiser, then the SDK's own.
  if not g.invoke("_initialize", [], optional = true)[0]: return
  if not g.invoke("ct_plugin_init", [])[0]: return
  g.deliver(if hostHello.isNil: %*{"type": "hello"} else: hostHello)
  if g.dead: return
  if not g.helloSeen or g.helloProblem.len > 0:
    let why = if g.helloSeen: g.helloProblem
              else: "its module did not answer hello"
    g.retire()
    activationFailed(id, why)
    return
  g.deliver(msg)

# ---------------------------------------------------------------------------
# What the supervisor sends
# ---------------------------------------------------------------------------

proc handle(msg: JsonNode) =
  let t = msg{"type"}.getStr("")
  let id = msg{"plugin"}.getStr("")
  case t
  of "hello":
    hostHello = msg
    var list: seq[(string, string)]
    for pkg in packages.values:
      for pp in pkg.spec.plugins:
        list.add (pp.parsed.manifest.id, $pp.parsed.manifest.version)
    sendRaw(processHello(HostPackage, list, @[InstanceFaultsFeature]))
  of "activate":
    if guests.hasKey(id):
      guests[id].deliver(msg)
    else:
      startGuest(id, msg)
  of "deactivate":
    let g = guests.getOrDefault(id, nil)
    if not g.isNil:
      g.deliver(msg)
      g.retire()
  of "shutdown":
    for g in toSeq(guests.values):
      g.deliver(msg)
      g.retire()
    running = false
  of "signal-snapshot", "signal-batch":
    if id.len > 0:
      let g = guests.getOrDefault(id, nil)
      if not g.isNil: g.deliver(msg)
    else:
      for g in toSeq(guests.values):
        g.deliver(msg)
  of "cancel":
    discard
  else:
    if id.len > 0:
      let g = guests.getOrDefault(id, nil)
      if not g.isNil: g.deliver(msg)

proc pumpIo() =
  if hasPendingOperations():
    try:
      poll(0)
    except ValueError:
      discard
  while ioCompletions.len > 0:
    let batch = ioCompletions
    ioCompletions = @[]
    for (id, payload) in batch:
      let g = guests.getOrDefault(id, nil)
      if not g.isNil: g.deliver(payload)

proc pumpIdle() =
  let t = nowMs()
  for g in toSeq(guests.values):
    if g.wantsIdle and t >= g.nextIdleMs:
      g.nextIdleMs = t + IdleIntervalMs
      let (ok, r) = g.invoke("ct_plugin_idle", [], nresults = 1, optional = true)
      if ok: g.wantsIdle = r[0] != 0

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

proc usage() =
  stderr.writeLine "usage: ct-plugin-host --package <component dir> [...] " &
    "[--engine wasmtime|wasmi] [--memory-mb N] [--call-deadline-ms N] " &
    "[--trace-root DIR]"

proc loadPackage(dir: string) =
  let path = dir / "plugin.json"
  var text: string
  try:
    text = readFile(path)
  except CatchableError as e:
    logLine("ct-plugin-host: " & path & ": " & e.msg)
    return
  let spec = parsePluginPackage(text, path, dir.extractFilename.split('@')[0])
  if spec.hostKind != phkWasm or not spec.isOk:
    logLine("ct-plugin-host: " & path & ": not a loadable WASM package: " &
            renderAll(spec.allErrors))
    return
  let entry = PackageEntry(name: spec.name, dir: dir,
                           modulePath: dir / spec.executable, spec: spec)
  packages[spec.name] = entry
  for id in spec.pluginIds:
    pluginPackage[id] = entry

proc main() =
  var engineName = when defined(ctPluginHostWasmi): "wasmi" else: "wasmtime"
  var dirs: seq[string]
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    template value(): string =
      (if i + 1 <= n: (inc i; paramStr(i)) else: (usage(); quit(2)))
    case a
    of "--package": dirs.add value()
    of "--engine": engineName = value()
    of "--memory-mb": memoryBytes = parseInt(value()) * 1024 * 1024
    of "--call-deadline-ms": callDeadlineMs = parseInt(value())
    of "--trace-root": traceRoots.add value()
    of "--help", "-h":
      usage()
      quit(0)
    else:
      usage()
      quit(2)
    inc i
  initLock(writeLock)
  installCrashRecord()
  let (kind, mode) = if engineName == "wasmi": (ekWasmi, dmFuel)
                     else: (ekWasmtime, dmEpoch)
  try:
    engineRef = newWasmEngine(kind, mode)
    engineRef.declareImports()
  except CatchableError as e:
    stderr.writeLine "ct-plugin-host: " & e.msg
    quit(3)
  for d in dirs: loadPackage(d)
  inbox.open()
  createThread(readerThread, readerLoop)
  while running:
    let (got, frame) = inbox.tryRecv()
    if got:
      if frame.len == 0: break
      var msg: JsonNode
      try:
        msg = parseJson(frame)
      except CatchableError:
        continue
      handle(msg)
      continue
    pumpIo()
    pumpIdle()
    if not hasPendingOperations() and ioCompletions.len == 0:
      os.sleep(2)
  quit(0)

when isMainModule:
  main()
