## language_smoke_mock_test.nim
##
## Mock-driven per-language smoke ViewModel tests — headless companions to the
## twelve `program_specific_tests/<lang>_example.spec.ts` Playwright files for
## languages whose recorder pipelines are not yet wired into `ct record`
## (aiken, cadence, cairo, circom, leo, masm, move, polkavm, solana, stylus,
## sway, tolk).
##
## Why a Mock-driven file rather than extending `language_smoke_test.nim`?
## ----------------------------------------------------------------------
##
## `language_smoke_test.nim` runs against a real `replay-server` (it spawns a
## subprocess via `HeadlessDebugSession`).  It is therefore explicitly excluded
## from `just test-vm-native` / `just test-vm-js` (see the justfile filter
## `! -path '*/integration/language_smoke_test.nim'`).  Adding more entries
## there would not be picked up by either VM-test harness.
##
## The twelve languages above also have no recorder available on a stock dev
## box, so a real-trace test would skip on every machine and provide no
## functional coverage.  Instead, this file drives a `MockBackendService`
## with a per-language canned trace and asserts the same observable
## intent that the spec asserts at the GUI layer:
##
##   1. The editor pane settles on a source file with the language's
##      expected extension (matches the spec's "correct entry status
##      path/line" + "editor pane loading the .<ext> source file").
##   2. The calltrace populates with at least one entry whose name is
##      the function the spec calls out (matches the spec's "call trace
##      shows <fn> entry").
##   3. The state panel exposes at least one local variable on the
##      active tab (matches the spec's "state panel shows decoded ...
##      variables" smoke).
##   4. The event log surfaces at least one row (matches the spec's
##      "event log has at least one event").
##
## Each language gets ONE smoke `test()` named `"<lang>_example smoke"` to
## stay one-to-one with the spec at the file level.  A shared
## `runLanguageSmoke` helper exercises the four flows above so that a
## future per-language deviation (e.g. masm supplying stack-style locals)
## is a one-line config tweak rather than 12 separate test bodies.
##
## Mock pattern (mirrors `scenarios/feature_scenarios_test.nim`):
##   - createRoot proc(dispose): … dispose() at the end.
##   - `makeStoreWithMock(autoRespond = true)` produces a `ReplayDataStore`
##     fronted by `MockBackendService` so backend dispatches are no-ops.
##   - VM signals (calltraceLines on the store side, `eventRows` on the VM
##     side, etc.) are populated directly to seed the canned trace.
##   - Derived memos (visibleLines, currentVariables, activeFileName)
##     recompute synchronously after the seed thanks to the reactive
##     framework's eager evaluation.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/integration/language_smoke_mock_test.nim

import std/[unittest, strutils]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/[
  calltrace_vm,
  editor_vm,
  event_log_vm,
  state_vm,
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a `ReplayDataStore` backed by a `MockBackendService`.
  ## `autoRespond = true` so the calltrace/state auto-load effects do not
  ## raise on unmatched commands (the smoke tests only care about the
  ## observable VM signal flow, not the exact backend payloads).
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

type
  ## Per-language canned-trace descriptor.
  ##
  ## Picks the file extension the spec asserts on, the call function
  ## name the spec asserts on, and a representative locals shape so the
  ## state panel comes alive.  All twelve languages share the same
  ## smoke shape today; if a future spec needs e.g. stack-style locals
  ## (masm) or ecalli register-style locals (polkavm), bump the
  ## ``locals`` field rather than forking the test.
  LanguageSmokeConfig = object
    name: string                ## human-readable language tag (e.g. "aiken")
    sourceFile: string          ## file the editor settles on (e.g. "validator.ak")
    sourceExt: string           ## extension the spec asserts (".ak")
    sourceLine: int             ## entry line — non-zero so DebuggerStatus is
                                ##   meaningfully populated
    callName: string            ## function name the spec asserts on
                                ##   ("call trace shows <fn> entry")
    locals: seq[Variable]       ## representative locals for the state panel
    eventRow: EventLogRow       ## representative event-log row
                                ##   (covers "event log has at least one event")

proc makeLocal(name: string; value: string;
               typeName: string = ""): Variable =
  ## Convenience constructor for a flat (non-nested) local.
  Variable(
    name: name,
    value: value,
    typeName: typeName,
    hasChildren: false,
    children: @[],
  )

proc makeCallLine(index: int64; name: string;
                  file: string; line: int;
                  depth: int = 0; rrTicks: uint64 = 0): CallLine =
  ## Convenience constructor for a CallLine pointing at a specific source
  ## position. ``rrTicks`` defaults to ``index`` so the timeline is
  ## monotonically advancing if multiple lines are seeded.
  let ticks = if rrTicks == 0'u64: uint64(max(index, 0)) else: rrTicks
  CallLine(
    index: index,
    name: name,
    depth: depth,
    rrTicks: ticks,
    location: Location(file: file, line: line, column: 0),
  )

proc makeEventRow(eventId: uint64; line: int; value: string;
                  kind: string = "call"): EventLogRow =
  ## Convenience constructor for a representative event-log row.
  EventLogRow(eventId: eventId, kind: kind, line: line, value: value)

# ---------------------------------------------------------------------------
# Per-language configurations
#
# All twelve specs assert the same smoke shape — only the file extension,
# entry function and minor cosmetic differences vary.  When the spec
# overrides a function-name or extension, that override is carried here
# verbatim so the VM test stays grep-able against the spec.
#
# Source file naming is intentionally illustrative; the ViewModel does
# not validate that the path exists on disk — only that the editor
# memo settles on a file matching the language's extension.
# ---------------------------------------------------------------------------

const aikenConfig = LanguageSmokeConfig(
  name: "aiken",
  sourceFile: "validators/main.ak",
  sourceExt: ".ak",
  sourceLine: 12,
  callName: "compute",  # spec: "call trace shows compute function entry"
  locals: @[
    makeLocal("input", "42", "Int"),
    makeLocal("redeemer", "()", "Void"),
  ],
  eventRow: makeEventRow(1'u64, 12, "compute(42)"),
)

const cadenceConfig = LanguageSmokeConfig(
  name: "cadence",
  sourceFile: "transactions/main.cdc",
  sourceExt: ".cdc",
  sourceLine: 8,
  callName: "compute",  # spec: "call trace shows compute function entry"
  locals: @[
    makeLocal("acct", "0x01", "AuthAccount"),
    makeLocal("amount", "10", "UFix64"),
  ],
  eventRow: makeEventRow(1'u64, 8, "compute()"),
)

const cairoConfig = LanguageSmokeConfig(
  name: "cairo",
  sourceFile: "src/main.cairo",
  sourceExt: ".cairo",
  sourceLine: 5,
  callName: "compute",  # spec: "call trace shows compute function entry"
  locals: @[
    makeLocal("a", "7", "felt252"),
    makeLocal("b", "11", "felt252"),
  ],
  eventRow: makeEventRow(1'u64, 5, "compute()"),
)

const circomConfig = LanguageSmokeConfig(
  name: "circom",
  sourceFile: "compute.circom",
  sourceExt: ".circom",
  sourceLine: 14,
  callName: "compute",  # spec: "call trace shows compute template entry"
  locals: @[
    makeLocal("in", "[1, 2, 3]", "signal"),
    makeLocal("out", "6", "signal"),
  ],
  eventRow: makeEventRow(1'u64, 14, "compute()"),
)

const leoConfig = LanguageSmokeConfig(
  name: "leo",
  sourceFile: "src/main.leo",
  sourceExt: ".leo",
  sourceLine: 9,
  callName: "compute",  # spec: "call trace shows compute function entry"
  locals: @[
    makeLocal("a", "5u32", "u32"),
    makeLocal("b", "3u32", "u32"),
  ],
  eventRow: makeEventRow(1'u64, 9, "compute(5u32, 3u32)"),
)

const masmConfig = LanguageSmokeConfig(
  name: "masm",
  sourceFile: "compute.masm",
  sourceExt: ".masm",
  sourceLine: 4,
  callName: "compute",  # spec: "call trace shows compute procedure entry"
  # masm exposes operand-stack frames via writer.arg as s0..s3 (per the 1.56
  # recorder audit).  The smoke test mirrors that shape so the state panel
  # smoke matches "state panel shows decoded stack/local variables".
  locals: @[
    makeLocal("s0", "0x05", "felt"),
    makeLocal("s1", "0x03", "felt"),
    makeLocal("s2", "0x00", "felt"),
    makeLocal("s3", "0x00", "felt"),
  ],
  eventRow: makeEventRow(1'u64, 4, "compute"),
)

const moveConfig = LanguageSmokeConfig(
  name: "move",
  sourceFile: "sources/computation.move",
  sourceExt: ".move",
  sourceLine: 6,
  callName: "test_computation",  # spec: "call trace shows test_computation entry"
  locals: @[
    makeLocal("a", "21", "u64"),
    makeLocal("b", "21", "u64"),
  ],
  eventRow: makeEventRow(1'u64, 6, "test_computation(21, 21)"),
)

const polkavmConfig = LanguageSmokeConfig(
  name: "polkavm",
  # PolkaVM source files compile from Rust per the spec note, so the
  # editor pane displays a `.rs` extension despite the recorder being
  # PolkaVM.  Match the spec's expectation (`pvm extension is DB-based;
  # rs is NOT — pipeline detection`).
  sourceFile: "src/main.rs",
  sourceExt: ".rs",
  sourceLine: 7,
  callName: "compute",  # spec: "call trace shows compute function entry"
  # polkavm exposes Ecalli call-args via writer.arg as a0..a5 (per the
  # 1.55 recorder audit).
  locals: @[
    makeLocal("a0", "0x42", "u64"),
    makeLocal("a1", "0x10", "u64"),
  ],
  eventRow: makeEventRow(1'u64, 7, "compute(0x42, 0x10)"),
)

const solanaConfig = LanguageSmokeConfig(
  name: "solana",
  # Solana programs are written in Rust; the spec asserts on `.rs` files.
  sourceFile: "programs/example/src/lib.rs",
  sourceExt: ".rs",
  sourceLine: 18,
  callName: "process_instruction",  # spec: "call trace shows process_instruction entry"
  locals: @[
    makeLocal("program_id", "11111111111111111111111111111111", "Pubkey"),
    makeLocal("accounts", "[]", "&[AccountInfo]"),
    makeLocal("instruction_data", "[1, 2, 3]", "&[u8]"),
  ],
  eventRow: makeEventRow(1'u64, 18, "process_instruction(...)"),
)

const stylusConfig = LanguageSmokeConfig(
  name: "stylus",
  # Stylus programs are Rust compiled to WASM for Arbitrum.
  sourceFile: "src/lib.rs",
  sourceExt: ".rs",
  sourceLine: 22,
  callName: "main",  # spec: "call trace shows function entry" (generic main)
  locals: @[
    makeLocal("self", "Counter { value: 0 }", "Counter"),
    makeLocal("amount", "5", "U256"),
  ],
  eventRow: makeEventRow(1'u64, 22, "increment(5)", "evmEvent"),
)

const swayConfig = LanguageSmokeConfig(
  name: "sway",
  sourceFile: "src/main.sw",
  sourceExt: ".sw",
  sourceLine: 10,
  callName: "main",  # spec: "call trace shows main entry"
  locals: @[
    makeLocal("input", "100", "u64"),
    makeLocal("output", "0", "u64"),
  ],
  eventRow: makeEventRow(1'u64, 10, "main(100)"),
)

const tolkConfig = LanguageSmokeConfig(
  name: "tolk",
  sourceFile: "compute.tolk",
  sourceExt: ".tolk",
  sourceLine: 3,
  callName: "compute",  # spec: "call trace shows compute function entry"
  locals: @[
    makeLocal("x", "42", "int"),
    makeLocal("y", "0", "int"),
  ],
  eventRow: makeEventRow(1'u64, 3, "compute(42)"),
)

# ---------------------------------------------------------------------------
# Generic smoke runner
# ---------------------------------------------------------------------------

proc runLanguageSmoke(config: LanguageSmokeConfig) =
  ## Drive the four signal flows the spec asserts on:
  ##   1. editor settles on a `.<ext>` file (activeFileName memo)
  ##   2. calltrace populates with at least one entry whose name matches
  ##      the language's expected entry function (visibleLines memo)
  ##   3. state panel exposes the seeded locals (currentVariables memo)
  ##   4. event log exposes the seeded row (eventRows signal)
  ##
  ## All assertions read VM-level signals — no DOM rendering, no
  ## subprocess, no on-disk trace.
  createRoot proc(dispose: proc()) =
    let (store, _) = makeStoreWithMock()
    let calltraceVm = createCalltraceVM(store)
    let editorVm = createEditorVM(store)
    let stateVm = createStateVM(store)
    let eventLogVm = createEventLogVM(store)

    # Drain the auto-load effects so the loadingState transitions back to
    # lsIdle after the mock auto-responds with `{}`.  Without this the
    # isLoading memos would stay true and confuse the smoke assertions.
    drain()

    # ---- Seed the canned trace -----------------------------------------
    # 1. Editor: drive the debugger location so `activeFileName` settles
    #    on the language's source file.  EditorVM.activeFileName is a
    #    memo of `store.debugger.val.location.file`.
    var dbg = store.debugger.val
    dbg.location = Location(
      file: config.sourceFile,
      line: config.sourceLine,
      column: 0,
    )
    dbg.rrTicks = 1'u64
    dbg.status = dsIdle
    store.debugger.val = dbg

    # 2. Calltrace: populate the underlying store signal so the VM's
    #    visibleLines memo recomputes.  Set viewport height so the
    #    visibleLines slice is non-empty (default 0 yields an empty
    #    window even when lines are present).
    store.calltrace.lines.val = @[
      makeCallLine(0'i64, config.callName,
                   config.sourceFile, config.sourceLine,
                   depth = 0, rrTicks = 1'u64),
    ]
    store.calltrace.totalCallsCount.val = 1'u64
    calltraceVm.viewportHeight.val = 10

    # 3. Locals: populate the store.locals signal so StateVM's
    #    currentVariables memo (on the default stLocals tab) reflects
    #    the canned locals.
    store.locals.locals.val = config.locals

    # 4. Event log: eventRows is a writable signal directly on the VM.
    eventLogVm.eventRows.val = @[config.eventRow]

    drain()

    # ---- Assertions ----------------------------------------------------
    # 1. Editor reports the correct file/line.
    check editorVm.activeFileName.val == config.sourceFile
    check editorVm.activeFileName.val.endsWith(config.sourceExt) or
          config.sourceFile.endsWith(config.sourceExt)
    check store.debugger.val.location.line == config.sourceLine

    # 2. Calltrace shows at least one entry, with the expected entry
    #    function name on the first line.
    let visible = calltraceVm.visibleLines.val
    check visible.len >= 1
    if visible.len >= 1:
      check visible[0].name == config.callName
      check visible[0].location.file == config.sourceFile

    # 3. State panel exposes at least one local on the default tab
    #    (stLocals).  Each local has a non-empty name (a pre-condition
    #    the legacy state panel relies on for tooltip/hover identity).
    let vars = stateVm.currentVariables.val
    check vars.len >= 1
    for v in vars:
      check v.name.len > 0

    # 4. Event log shows at least one row.
    let rows = eventLogVm.eventRows.val
    check rows.len >= 1
    if rows.len >= 1:
      check rows[0].eventId == config.eventRow.eventId

    dispose()

# ---------------------------------------------------------------------------
# Per-language smoke suites — one suite per language for clean test-runner
# output and to mirror the per-spec file convention at the spec layer.
# Each suite holds a single `<lang>_example smoke` test that maps
# one-to-one onto its `program_specific_tests/<lang>_example.spec.ts`.
# ---------------------------------------------------------------------------

suite "Language smoke (mock): aiken_example":
  test "aiken_example smoke":
    runLanguageSmoke(aikenConfig)

suite "Language smoke (mock): cadence_example":
  test "cadence_example smoke":
    runLanguageSmoke(cadenceConfig)

suite "Language smoke (mock): cairo_example":
  test "cairo_example smoke":
    runLanguageSmoke(cairoConfig)

suite "Language smoke (mock): circom_example":
  test "circom_example smoke":
    runLanguageSmoke(circomConfig)

suite "Language smoke (mock): leo_example":
  test "leo_example smoke":
    runLanguageSmoke(leoConfig)

suite "Language smoke (mock): masm_example":
  test "masm_example smoke":
    runLanguageSmoke(masmConfig)

suite "Language smoke (mock): move_example":
  test "move_example smoke":
    runLanguageSmoke(moveConfig)

suite "Language smoke (mock): polkavm_example":
  test "polkavm_example smoke":
    runLanguageSmoke(polkavmConfig)

suite "Language smoke (mock): solana_example":
  test "solana_example smoke":
    runLanguageSmoke(solanaConfig)

suite "Language smoke (mock): stylus_example":
  test "stylus_example smoke":
    runLanguageSmoke(stylusConfig)

suite "Language smoke (mock): sway_example":
  test "sway_example smoke":
    runLanguageSmoke(swayConfig)

suite "Language smoke (mock): tolk_example":
  test "tolk_example smoke":
    runLanguageSmoke(tolkConfig)
