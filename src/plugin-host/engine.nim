## plugin-host/engine.nim — the Nim side of `ct-plugin-engine`'s C ABI
## (`engine/src/lib.rs`). One `WasmInstance` is one plugin's store.
##
## The Rust static library is linked from `-d:ctPluginEngineLib=<path to
## libct_plugin_engine.a>`; `just build-plugin-host` builds it and passes it.

const ctPluginEngineLib {.strdefine.} = ""

when ctPluginEngineLib.len == 0:
  {.error: "ct-plugin-host links the WebAssembly engine: build it with " &
           "`just build-plugin-host`, or pass -d:ctPluginEngineLib=<path to " &
           "libct_plugin_engine.a>".}

{.passL: ctPluginEngineLib.}
when defined(linux):
  {.passL: "-lpthread -ldl -lm -lrt".}
elif defined(macosx):
  {.passL: "-framework CoreFoundation -framework Security".}

type
  CEngine = distinct pointer
  CModule = distinct pointer
  CInstance = distinct pointer

  HostCallback* = proc(ctx: pointer; id: uint32; args: ptr UncheckedArray[int64];
                       nargs: uint32; results: ptr UncheckedArray[int64];
                       nresults: uint32; mem: ptr UncheckedArray[byte];
                       memLen: csize_t; err: cstring; errCap: csize_t): cint
                      {.cdecl, gcsafe.}

  EngineKind* = enum
    ekWasmtime = 0
    ekWasmi = 1

  DeadlineMode* = enum
    dmNone = 0
    dmEpoch = 1
    dmFuel = 2

  CallStatus* = enum
    csOk = 0
    csTrap = 1
    csDeadline = 2
    csMemoryLimit = 3
    csHostRefused = 4
    csNoSuchExport = 5
    csBadArguments = 6

  WasmEngine* = ref object
    raw: CEngine
    kind*: EngineKind
    mode*: DeadlineMode

  WasmModule* = ref object
    raw: CModule

  WasmInstance* = ref object
    raw: CInstance

  CallOutcome* = object
    status*: CallStatus
    message*: string
    results*: array[4, int64]

  EngineError* = object of CatchableError

proc cte_engine_new(kind, mode: uint32; fuelPerMs, fuelSlice: uint64;
                    err: cstring; cap: csize_t): CEngine {.importc, cdecl.}
proc cte_engine_add_import(e: CEngine; module, name, sig: cstring): cint
  {.importc, cdecl.}
proc cte_engine_free(e: CEngine) {.importc, cdecl.}
proc cte_module_new(e: CEngine; bytes: pointer; len: csize_t; err: cstring;
                    cap: csize_t): CModule {.importc, cdecl.}
proc cte_module_free(m: CModule) {.importc, cdecl.}
proc cte_instance_new(e: CEngine; m: CModule; memoryBytes: csize_t;
                      cb: HostCallback; ctx: pointer; err: cstring;
                      cap: csize_t): CInstance {.importc, cdecl.}
proc cte_instance_free(i: CInstance) {.importc, cdecl.}
proc cte_call(i: CInstance; name: cstring; args: ptr int64; nargs: uint32;
              results: ptr int64; nresults: uint32; deadlineMs: uint64;
              err: cstring; cap: csize_t): cint {.importc, cdecl.}
proc cte_memory(i: CInstance; len: ptr csize_t): ptr UncheckedArray[byte]
  {.importc, cdecl.}

proc isNil(p: CEngine): bool {.borrow.}
proc isNil(p: CModule): bool {.borrow.}
proc isNil(p: CInstance): bool {.borrow.}

const ErrCap = 2048

proc errText(buf: string): string =
  let n = buf.find('\0')
  if n < 0: buf else: buf[0 ..< n]

proc newWasmEngine*(kind: EngineKind; mode: DeadlineMode;
                    fuelPerMs = 0'u64; fuelSlice = 0'u64): WasmEngine =
  var err = newString(ErrCap)
  let raw = cte_engine_new(kind.uint32, mode.uint32, fuelPerMs, fuelSlice,
                           err.cstring, ErrCap)
  if raw.isNil:
    raise newException(EngineError, "WebAssembly engine " & $kind & ": " &
                       errText(err))
  WasmEngine(raw: raw, kind: kind, mode: mode)

proc addImport*(e: WasmEngine; module, name, signature: string): int =
  ## Declare one import every instance may call; `signature` is
  ## `"<params>:<results>"` over `i` (i32) and `I` (i64). Returns its id, the
  ## number the callback is called with.
  result = cte_engine_add_import(e.raw, module.cstring, name.cstring,
                                 signature.cstring).int
  if result < 0:
    raise newException(EngineError, "could not declare import " & module &
                       "." & name & " (" & signature & ")")

proc compile*(e: WasmEngine; bytes: string): WasmModule =
  var err = newString(ErrCap)
  let raw = cte_module_new(e.raw, (if bytes.len > 0: bytes[0].unsafeAddr else: nil),
                           bytes.len.csize_t, err.cstring, ErrCap)
  if raw.isNil:
    raise newException(EngineError, errText(err))
  WasmModule(raw: raw)

proc instantiate*(e: WasmEngine; m: WasmModule; memoryBytes: int;
                  cb: HostCallback; ctx: pointer): WasmInstance =
  var err = newString(ErrCap)
  let raw = cte_instance_new(e.raw, m.raw, memoryBytes.csize_t, cb, ctx,
                             err.cstring, ErrCap)
  if raw.isNil:
    raise newException(EngineError, errText(err))
  WasmInstance(raw: raw)

proc call*(i: WasmInstance; name: string; args: openArray[int64];
           deadlineMs: int; nresults = 0): CallOutcome =
  var err = newString(ErrCap)
  var a: seq[int64] = @args
  let rc = cte_call(i.raw, name.cstring,
                    (if a.len > 0: a[0].addr else: nil), a.len.uint32,
                    result.results[0].addr, min(nresults, 4).uint32,
                    max(deadlineMs, 1).uint64, err.cstring, ErrCap)
  result.status = if rc in 0..6: CallStatus(rc) else: csTrap
  if result.status != csOk:
    result.message = errText(err)

proc memory*(i: WasmInstance): (ptr UncheckedArray[byte], int) =
  var n: csize_t
  let p = cte_memory(i.raw, n.addr)
  (p, n.int)

proc release*(i: WasmInstance) =
  if not i.isNil and not i.raw.isNil:
    cte_instance_free(i.raw)
    i.raw = CInstance(nil)

proc release*(m: WasmModule) =
  if not m.isNil and not m.raw.isNil:
    cte_module_free(m.raw)
    m.raw = CModule(nil)

proc release*(e: WasmEngine) =
  if not e.isNil and not e.raw.isNil:
    cte_engine_free(e.raw)
    e.raw = CEngine(nil)
