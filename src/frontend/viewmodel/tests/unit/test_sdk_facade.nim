## SDK-CONSUMER: the Embed SDK's own conformance suite. It is the first
## declared consumer of the facade, and it is what stops
## ci/test/sdk-facade-boundary.sh from passing vacuously: every import below
## must resolve either to `codetracer_embed` or to something outside the SDK
## subtree, exactly as BlockTracer's debugger panes will have to.
##
## test_sdk_facade.nim
##
## What the CodeTracer Embed SDK facade promises, driven entirely through
## `codetracer_embed` — no import of a ViewModel internal anywhere in this
## file, deliberately.
##
## Two things are proved here:
##
##   1. **The facade exposes what the spec says it does.** Every row of
##      CodeTracer-Embed-SDK.md §3.1 that has a Nim symbol is named and used.
##      Most of that is a *compile-time* assertion: if a re-export is dropped
##      from `codetracer_embed.nim`, this file stops compiling, which is the
##      earliest and loudest possible failure.
##
##   2. **The session lifecycle and its error taxonomy behave**, driven by
##      `MockBackendService` — no Electron, no rendering, no replay-server, no
##      network (BlockTracer.milestones.org M2a,
##      `test_session_lifecycle_and_error_taxonomy`).
##
## The third property — that reaching past the facade *fails* — cannot be
## asserted by a Nim compile, because Nim is perfectly happy to import an
## internal. It is asserted by running the import lint against a synthetic
## tree, and that lives in `test_sdk_facade_boundary.nim`: it needs
## `std/osproc`, which does not compile on the JS target, and keeping it here
## made this file — the whole of M2a's
## `test_session_lifecycle_and_error_taxonomy` evidence — C-backend-only. See
## that file's header for the defect the limit was hiding.
##
## Compile and run, on BOTH backends:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_sdk_facade.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_sdk_facade.nim

import std/[json, options, strutils, unittest]

import codetracer_embed

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mockBackend(strict = false; autoRespond = true): MockBackendService =
  newMockBackendService(strict = strict, autoRespond = autoRespond)

proc failingLaunch(message: string): MockBackendService =
  ## A backend whose `launch` answers `success: false` with `message`, and
  ## whose handshake otherwise succeeds.
  let mock = newMockBackendService(autoRespond = true)
  mock.expect("initialize", %*{"success": true})
  mock.expect("configurationDone", %*{"success": true})
  mock.expect("launch", %*{"success": false, "message": message})
  mock

# ---------------------------------------------------------------------------
# §3.1 row 1 and row 8 — ReplayDataStore, and the trace/location/value models
# ---------------------------------------------------------------------------

suite "Embed SDK facade — ReplayDataStore and types (spec §3.1 rows 1, 8)":

  test "the data store is constructible from the facade alone":
    let store = createReplayDataStore(mockBackend().toBackendService())
    check store.storeId > 0
    check store.debugger.val.status == dsIdle
    check store.timeline.val.currentRRTicks == 0'u64
    store.dispose()

  test "the trace data models are exported":
    # One value of each model family §3.1's "Types" row names, constructed by
    # name. Naming them is the assertion: a dropped export fails the compile.
    let loc = Location(file: "main.nim", line: 12, column: 3)
    let v = makeVariable("x", "1", "int")
    let call = makeCallLine("main", 0, 100'u64)
    let arg = makeCallArg("argc", "1")
    let row = EventLogRow()
    let step = StepLine()
    let span = RequestRecord()
    check loc.line == 12
    check v.name == "x"
    check call.name == "main"
    check arg.name == "argc"
    check row.kind.len == 0
    check step.delta == 0
    check span.id == 0

  test "the enum vocabularies are exported":
    # Each name below is a symbol the facade must re-export; the `ord`
    # comparisons are incidental. The compile is the assertion.
    check ord(lsIdle) < ord(lsError)
    check ord(csDisconnected) < ord(csConnected)
    check ord(dsIdle) < ord(dsFinished)
    check ord(sdForward) < ord(sdBackward)

# ---------------------------------------------------------------------------
# §3.1 row 3 — the BackendService seam
# ---------------------------------------------------------------------------

suite "Embed SDK facade — BackendService seam (spec §3.1 row 3)":

  test "MockBackendService satisfies BackendService":
    ## The subject is the seam — that a `MockBackendService` can stand where a
    ## `BackendService` is required and records what it was handed — not any
    ## particular command. It used `ct/ping`, which is not a DAP command at
    ## all; `MockBackendService.send` now validates against
    ## `VALID_DAP_COMMANDS`, because a mock that accepted any string is why the
    ## nine commands in `backend/dap_dialect.md` §7 each had passing tests over
    ## an engine implementing none of them.
    ##
    ## A seam test that does not care which command it sends can send a real
    ## one, so it does, rather than spending `validateCommands = false` to keep
    ## a placeholder.
    let mock = mockBackend()
    let backend: BackendService = mock.toBackendService()
    mock.expect("initialize", %*{"success": true})
    discard backend.send("initialize", %*{})
    check mock.receivedCommands.len == 1
    check mock.receivedCommands[0].command == "initialize"
    check mock.findCommand("initialize").isSome

  test "disconnect reaches the implementation":
    let mock = mockBackend()
    let backend = mock.toBackendService()
    check not mock.disconnected
    backend.disconnect()
    check mock.disconnected

  test "events registered through the seam are delivered":
    let mock = mockBackend()
    let backend = mock.toBackendService()
    var seen = 0
    backend.onEvent(proc(event: JsonNode) = inc seen)
    mock.emitEvent(%*{"event": "stopped"})
    check seen == 1

# ---------------------------------------------------------------------------
# §3.1 row 5 — TraceSource
# ---------------------------------------------------------------------------

suite "Embed SDK facade — TraceSource (spec §3.1 row 5)":

  test "all four spec kinds plus the native folder kind are constructible":
    check httpRangeTrace("https://example.test/t/ab/").kind == tskHttpRange
    check opfsTrace("/traces/abc").kind == tskOpfs
    check bytesTrace(@[1'u8, 2'u8]).kind == tskBytes
    check localFolderTrace("/tmp/trace").kind == tskLocalFolder
    let custom = customTrace(newBlockSource("memory",
      length = proc(): int64 = 4,
      readRange = proc(offset: int64; length: int): seq[byte] = @[0'u8]))
    check custom.kind == tskCustom
    check custom.blockSource.name == "memory"

  test "an incomplete source is rejected before anything is sent":
    expect TraceSourceDefect:
      httpRangeTrace("").validate()
    expect TraceSourceDefect:
      customTrace(nil).validate()
    # A custom source missing one of its two procs is just as unusable as a
    # nil one, and must fail at the consumer rather than inside the engine.
    expect TraceSourceDefect:
      customTrace(BlockSource(name: "half")).validate()

  test "the wire form keeps the native path byte-for-byte":
    # replay-server deserialises `traceFolder`; changing this spelling breaks
    # every native headless suite at once.
    check localFolderTrace("/tmp/t").toLaunchArgs() == %*{"traceFolder": "/tmp/t"}
    check httpRangeTrace("https://e.test/t/").toLaunchArgs() ==
      %*{"traceSource": {"kind": "http-range", "url": "https://e.test/t/"}}

  test "describe never leaks container bytes":
    let d = bytesTrace(@[9'u8, 9'u8, 9'u8]).describe()
    check d == "bytes:3B"

  test "the trace-source vocabulary is the one the engine names back":
    # `TRACE_SOURCE_KINDS` in src/db-backend/src/dap.rs holds the identical
    # list, and `src/db-backend/tests/launch_trace_source_test.rs` asserts
    # it. That pairing is what makes the engine able to *name* a source it
    # cannot open: before it had the field at all,
    # `#[serde(deny_unknown_fields)]` turned every browser kind into
    # `unknown field \`traceSource\``, which the §6.3 classifier can only
    # bucket as the catch-all `BackendError`, and which the native server
    # loop logs without answering the client at all.
    var kinds: seq[string] = @[]
    for k in TraceSourceKind.low .. TraceSourceKind.high:
      kinds.add($k)
    check kinds == @["local-folder", "http-range", "opfs", "bytes", "custom"]

  test "every browser kind puts its name in the traceSource envelope":
    # The engine branches on `kind` alone, so the spelling is the contract;
    # the payload fields are advisory.
    for source in [httpRangeTrace("https://e.test/t/"), opfsTrace("t/x.ct"),
                   bytesTrace(@[1'u8]),
                   customTrace(newBlockSource("b",
                     length = proc(): int64 = 0,
                     readRange = proc(offset: int64; length: int): seq[byte] = @[]))]:
      let args = source.toLaunchArgs()
      check args.hasKey("traceSource")
      check args["traceSource"]["kind"].getStr == $source.kind
      check not args.hasKey("traceFolder")

  test "a local folder is the one kind that goes as traceFolder":
    let args = localFolderTrace("/tmp/t").toLaunchArgs()
    check args.hasKey("traceFolder")
    check not args.hasKey("traceSource")

  test "an engine refusal of a browser kind is UnsupportedTraceKind":
    # The exact message shape `TraceSourceArgument::unsupported_reason`
    # produces. If the engine ever stops saying "unsupported", this lands in
    # the catch-all bucket and the §6.3 promise — "distinguish this trace
    # does not exist from the worker died without string matching" — is
    # quietly broken for the one failure the browser hits most.
    let refusal = %*{
      "success": false,
      "message": "unsupported launch traceSource kind `http-range` " &
                 "(the replay engine opens a trace that is already in its " &
                 "virtual file system; push the container's bytes with " &
                 "`vfs_write_file` and launch with `traceFolder`). " &
                 "Known kinds: local-folder, http-range, opfs, bytes, custom.",
    }
    check classifyBackendFailure(refusal) == dseUnsupportedTraceKind

# ---------------------------------------------------------------------------
# §3.1 row 4 / §6 — session lifecycle and the error taxonomy
# ---------------------------------------------------------------------------

suite "Embed SDK facade — DebuggerSession lifecycle (spec §3.1 row 4, §6)":

  test "construction is passive: no command is sent":
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    check session.phase.val == dspCreated
    check mock.receivedCommands.len == 0
    check not session.isReady
    session.dispose()

  test "launch runs the handshake, then lets the panels load":
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    check session.phase.val == dspReady
    check session.isReady
    # The handshake comes first, in order, and nothing precedes it. The panel
    # loads that follow are the ViewModels waking up on a trace that is now
    # open — the ordering is the property, not the count.
    check mock.receivedCommands.len >= 3
    check mock.receivedCommands[0].command == "initialize"
    check mock.receivedCommands[1].command == "configurationDone"
    check mock.receivedCommands[2].command == "launch"
    check mock.receivedCommands[2].args == %*{"traceFolder": "/tmp/trace"}
    check session.trace.kind == tskLocalFolder
    session.dispose()

  test "a failed launch never wakes the panels":
    # If the panels initialised regardless, a consumer whose trace 404s would
    # still see `ct/load-locals` go out at an engine with nothing open.
    let mock = failingLaunch("trace folder not found")
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/nope"))
    check session.phase.val == dspFailed
    check mock.findCommand("ct/load-locals").isNone
    check mock.findCommand("ct/load-calltrace-section").isNone
    session.dispose()

  test "launch records the opening position in the navigation history":
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    check session.history.val.len == 1
    check session.history.val[0].reason == "launch"
    session.dispose()

  test "navigation granularity is session state, not a per-call argument":
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    check session.granularity.val == ngLine
    session.setGranularity(ngStatement)
    check $session.granularity.val == "statement"
    session.dispose()

  test "dispose is idempotent and tears the transport down":
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    session.dispose()
    check session.phase.val == dspDisposed
    check session.isDisposed
    check mock.disconnected
    session.dispose()  # must not fault
    check session.phase.val == dspDisposed

  test "dispose(disconnectBackend = false) really leaves the transport up":
    # The flag's whole purpose is a host that owns the transport's lifetime:
    # `HeadlessDebugSession.close` passes `false` and then calls
    # `DapStdioBackend.close` itself, and its comment says why — routing a
    # second disconnect through `BackendService` would close the same child
    # process handle twice.
    #
    # It did not work. `DebuggerSession.dispose` honoured the flag on its own
    # `s.backend.disconnect()` line but called `AppViewModel.dispose` above
    # it, which reached `SessionViewModel.dispose`, which disconnected
    # unconditionally. Nothing caught it because no suite had ever asserted
    # on the flag: the four `vm-gui-headless` suites that exercise this path
    # against a real `replay-server` had never been run, only compiled
    # (BlockTracer.milestones.org M2a, item 3).
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    session.dispose(disconnectBackend = false)
    check session.isDisposed
    check not mock.disconnected

  test "dispose(disconnectBackend = false) still ends the session":
    # The other half of the same flag: it must not become a way to keep a
    # half-live session. Only the transport is spared — the session itself is
    # as dead as after an ordinary dispose, which is what stops the fix from
    # being "skip the teardown".
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    session.dispose(disconnectBackend = false)
    check session.phase.val == dspDisposed
    check not mock.disconnected
    var kind: DebuggerSessionErrorKind
    try:
      session.launch(localFolderTrace("/tmp/other"))
      session.raiseIfFailed()
    except DebuggerSessionError as e:
      kind = e.kind
    check kind == dseCancelled

  test "launching a disposed session is Cancelled, not a crash":
    let session = newDebuggerSession(mockBackend().toBackendService())
    session.dispose()
    var kind: DebuggerSessionErrorKind
    try:
      session.launch(localFolderTrace("/tmp/trace"))
      check false  # unreachable
    except DebuggerSessionError as err:
      kind = err.kind
    check kind == dseCancelled

  test "multi-session: two sessions in one process are independent":
    # Spec §3.1: "multi-session in one page".
    let mockA = mockBackend()
    let mockB = mockBackend()
    let a = newDebuggerSession(mockA.toBackendService())
    let b = newDebuggerSession(mockB.toBackendService())
    check a.id != b.id
    check a.store.storeId != b.store.storeId
    a.launch(localFolderTrace("/tmp/a"))
    b.launch(localFolderTrace("/tmp/b"))
    a.dispose()
    check a.isDisposed
    check not b.isDisposed
    check b.isReady
    check not mockB.disconnected
    b.dispose()

suite "Embed SDK facade — error taxonomy (spec §6.3)":

  test "every taxonomy value has the spec's name":
    check $dseTraceUnavailable == "TraceUnavailable"
    check $dseTraceCorrupt == "TraceCorrupt"
    check $dseUnsupportedTraceKind == "UnsupportedTraceKind"
    check $dseWorkerFailed == "WorkerFailed"
    check $dseCancelled == "Cancelled"
    check $dseBackendError == "BackendError"

  test "a missing trace is TraceUnavailable, not a generic failure":
    let mock = failingLaunch("trace folder not found: /tmp/nope")
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/nope"))
    check session.phase.val == dspFailed
    check session.failure.val == some(dseTraceUnavailable)
    session.dispose()

  test "a broken container is TraceCorrupt":
    let mock = failingLaunch("malformed CTFS container header")
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/bad"))
    check session.failure.val == some(dseTraceCorrupt)
    session.dispose()

  test "a format the engine cannot read is UnsupportedTraceKind":
    let mock = failingLaunch("unsupported trace format version 99")
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/future"))
    check session.failure.val == some(dseUnsupportedTraceKind)
    session.dispose()

  test "anything else is BackendError, and never a silent success":
    let mock = failingLaunch("the gremlins ate it")
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/x"))
    check session.failure.val == some(dseBackendError)
    check not session.isReady
    session.dispose()

  test "raiseIfFailed carries the kind, so no consumer matches on strings":
    let mock = failingLaunch("trace folder not found")
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/nope"))
    var kind: DebuggerSessionErrorKind
    try:
      session.raiseIfFailed()
      check false
    except DebuggerSessionError as err:
      kind = err.kind
    check kind == dseTraceUnavailable
    session.dispose()

# ---------------------------------------------------------------------------
# §6.3 against a genuinely asynchronous transport
# ---------------------------------------------------------------------------
#
# Every suite above drives a transport that answers before `send` returns.
# That is not the transport BlockTracer ships. `real_backend.nim` returns a
# bare `newPromise`, which `async_compat.onComplete` routes through `.then`
# — a real microtask, invisible to `drainPlatformCallbacks`, which only ever
# reaches the `__syncResolved` futures `newCompletedFuture` produces.
#
# `DebuggerSession.launch` used to call `markReady` on the strength of
# having *sent* three commands, so against a real worker it reported
# `dspReady` before a single response existed and the §6.3 taxonomy could
# never fire. That is the third time this taxonomy has shipped inert, each
# time for a different underlying reason, and each time no suite could see
# it because no suite had an asynchronous transport.
#
# `MockBackendService.deferResponses` is that transport: it takes exactly
# the same `onComplete` branch a promise does, while `settleDeferred` lets
# the test deliver the answers on its own schedule. These cases fail if
# `launch` ever again concludes anything it has not observed.

suite "Embed SDK facade — §6.3 over an asynchronous transport":

  proc deferredBackend(): MockBackendService =
    let mock = newMockBackendService(autoRespond = true)
    mock.deferResponses = true
    mock

  test "launch never claims ready before a single response has arrived":
    let mock = deferredBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))

    # All three commands went out...
    check mock.receivedCommands.len == 3
    check mock.pendingDeferredCount == 3
    # ...and not one of them has been answered, so there is nothing the
    # session could have concluded.
    check session.phase.val == dspLaunching
    check not session.isReady
    check session.failure.val.isNone
    session.dispose()

  test "the handshake completes when the last response arrives, not before":
    let mock = deferredBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))

    mock.settleDeferred(%*{"success": true})
    check session.phase.val == dspLaunching
    mock.settleDeferred(%*{"success": true})
    check session.phase.val == dspLaunching
    mock.settleDeferred(%*{"success": true})

    check session.phase.val == dspReady
    check session.isReady
    check session.trace.kind == tskLocalFolder
    session.dispose()

  test "a failure that arrives late is still classified, not swallowed":
    # The whole point of the taxonomy: this must not read as a ready
    # session merely because the refusal came back after `launch` returned.
    let mock = deferredBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/nope"))

    mock.settleDeferred(%*{"success": true})
    mock.settleDeferred(%*{"success": true})
    mock.settleDeferred(%*{"success": false,
                           "message": "trace folder not found: /tmp/nope"})

    check session.phase.val == dspFailed
    check session.failure.val == some(dseTraceUnavailable)
    check not session.isReady
    session.dispose()

  test "every taxonomy value fires over the async transport too":
    # If any of these regress to `dspReady`, the taxonomy has gone inert
    # again on the transport that actually ships.
    let cases = {
      "trace folder not found: /tmp/nope": dseTraceUnavailable,
      "malformed CTFS container header": dseTraceCorrupt,
      "unsupported launch traceSource kind `http-range`": dseUnsupportedTraceKind,
      "the gremlins ate it": dseBackendError,
    }
    for message, expected in cases.items:
      let mock = deferredBackend()
      let session = newDebuggerSession(mock.toBackendService())
      session.launch(localFolderTrace("/tmp/t"))
      check session.phase.val == dspLaunching
      mock.settleAllDeferred(%*{"success": false, "message": message})
      check session.phase.val == dspFailed
      check session.failure.val == some(expected)
      session.dispose()

  test "the first refusal wins, not whichever answer lands last":
    # With an async transport all three commands are in flight at once, so
    # "report the failure that stopped the handshake" cannot rely on
    # short-circuiting the sends.
    let mock = deferredBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/t"))
    mock.settleDeferred(%*{"success": false,
                           "message": "malformed CTFS container header"})
    mock.settleDeferred(%*{"success": false, "message": "the gremlins ate it"})
    mock.settleDeferred(%*{"success": false, "message": "the gremlins ate it"})
    check session.failure.val == some(dseTraceCorrupt)
    session.dispose()

  test "a transport that never answers leaves the session launching, not ready":
    # The honest end state for a worker that died: still `dspLaunching`,
    # never `dspReady`. A consumer watches the signal; what it must never
    # see is a readiness the session cannot justify.
    let mock = deferredBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/t"))
    check session.phase.val == dspLaunching
    check not session.isReady
    check session.failure.val.isNone
    session.dispose()

  test "a synchronous transport still settles inside launch":
    # The fix must not turn every existing consumer asynchronous: with a
    # transport that answers inline, `launch` still returns ready.
    let mock = mockBackend()
    let session = newDebuggerSession(mock.toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    check session.phase.val == dspReady
    session.dispose()

# ---------------------------------------------------------------------------
# §3.1 row 2 — the seven panel ViewModels
# ---------------------------------------------------------------------------

suite "Embed SDK facade — panel ViewModels (spec §3.1 row 2)":

  test "the session exposes the panels the spec names once a trace is open":
    let session = newDebuggerSession(mockBackend().toBackendService())
    # Before launch the panels do not exist at all — see DebuggerSessionPhase.
    check session.session.calltraceVM.isNil
    session.launch(localFolderTrace("/tmp/trace"))
    let vms = session.session
    # Naming each type is the assertion: dropping a re-export from the facade
    # makes this file fail to compile.
    let calltrace: CalltraceVM = vms.calltraceVM
    let eventLog: EventLogVM = vms.eventLogVM
    let state: StateVM = vms.stateVM
    let flow: FlowVM = vms.flowVM
    let editor: EditorVM = vms.editorVM
    let controls: DebugControlsVM = vms.debugControlsVM
    check not calltrace.isNil
    check not eventLog.isNil
    check not state.isNil
    check not flow.isNil
    check not editor.isNil
    check not controls.isNil
    session.dispose()

  test "the spans ViewModel is constructible from the facade":
    # §3.1 calls it `SpansVM`; in this tree it is `RequestPanelVM`, the VM over
    # `ReplayDataStore.requestSpans`. The name difference is recorded in
    # codetracer_embed.nim rather than papered over with an alias.
    let session = newDebuggerSession(mockBackend().toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    let spans: RequestPanelVM = createRequestPanelVM(session.store)
    check not spans.isNil
    check spans.requests.val.len == 0
    session.dispose()

  test "a panel reacts to the store it shares with the session":
    let session = newDebuggerSession(mockBackend().toBackendService())
    session.launch(localFolderTrace("/tmp/trace"))
    session.store.updateDebuggerPosition(42'u64, "main.nim", 7, none(uint64))
    check session.position.file == "main.nim"
    check session.position.line == 7
    check session.rrTicks == 42'u64
    session.dispose()

# ---------------------------------------------------------------------------
# §3.1 row 7 — the clock
# ---------------------------------------------------------------------------

suite "Embed SDK facade — clock (spec §3.1 row 7)":

  test "a session takes an injected clock":
    let tc = newTestClock()
    let session = newDebuggerSession(mockBackend().toBackendService(), clock = tc)
    check TestClock(session.clock).now() == 0.0
    tc.advance(250.0)
    check TestClock(session.clock).now() == 250.0
    session.dispose()

  test "the default clock is the real one":
    let session = newDebuggerSession(mockBackend().toBackendService())
    check not session.clock.isNil
    check session.clock of RealClock
    session.dispose()

  test "withFakeTime is available to consumer tests":
    withFakeTime:
      tc.advance(10.0)
      check tc.now() == 10.0
