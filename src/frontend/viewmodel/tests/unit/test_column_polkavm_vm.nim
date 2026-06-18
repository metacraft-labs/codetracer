## M-polkavm — Headless ViewModel column-aware breakpoint test driven
## through the PolkaVM recorder pipeline.
##
## Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1.
## Companions: ``test_column_breakpoint_vm.nim`` (JS recorder),
## ``codetracer/src/db-backend/tests/dap_column_polkavm.rs``,
## ``codetracer-polkavm-recorder/tests/test_column_aware_steps.rs``.
##
## End-to-end invariants pinned here:
##   1. ``lastSetBreakpointsResponse(file, line, column)`` ships
##      ``{"line": L, "column": C}`` to a backend fed by a real PolkaVM
##      trace, and the response echoes ``column``.
##   2. Legacy line-only calls preserve a column-stripped wire +
##      verified breakpoint.
##   3. ``ct/complete-move`` exposes ``column`` as an ``Option<int>``
##      (present-and-int with DWARF, null/absent without) and
##      ``getCurrentColumn`` mirrors that shape.  Pins the back-compat
##      path codified recorder-side by
##      ``test_column_aware_flag_set_even_without_dwarf_columns``.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_polkavm_vm.nim
##
## Auto-discovered tools (envvar overrides in parens):
##   * replay-server (``REPLAY_SERVER_BIN``)
##   * polkavm recorder (``CODETRACER_POLKAVM_RECORDER_PATH``)
##   * .polkavm blob (``CODETRACER_POLKAVM_FLOW_TEST``)
## Missing tools fail loudly per the M1 strictness contract.

import std/[json, options, os, osproc, unittest]

import ../../headless_session

# ---------------------------------------------------------------------------
# Fixture discovery
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## Walk upward to locate the codetracer repo root.  Same scheme as
  ## ``test_column_breakpoint_vm.nim``.
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if dirExists(dir / "src" / "db-backend") and dirExists(dir / "src" / "frontend"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate codetracer repo root from " & currentSourcePath())

proc findReplayServer(): string =
  ## Mirrors ``test_column_breakpoint_vm.nim``.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidates = [
    repoRoot() / "src" / "build-debug" / "bin" / "replay-server",
    repoRoot() / "src" / "db-backend" / "target" / "debug" / "replay-server",
    repoRoot() / "src" / "db-backend" / "target" / "release" / "replay-server",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  raise newException(IOError,
    "missing replay-server; set REPLAY_SERVER_BIN or build via " &
    "`cd src/db-backend && cargo build`")

proc findPolkavmRecorder(): string =
  ## Mirrors ``find_polkavm_recorder`` in ``test_harness/mod.rs``.
  let envBin = getEnv("CODETRACER_POLKAVM_RECORDER_PATH", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidate = repoRoot() / ".." / "codetracer-polkavm-recorder" /
    "target" / "debug" / "codetracer-polkavm-recorder"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "missing PolkaVM recorder; set CODETRACER_POLKAVM_RECORDER_PATH or " &
    "build the sibling codetracer-polkavm-recorder repo " &
    "(`cargo build`)")

proc findPolkavmBlob(): string =
  ## Default ``flow_test.polkavm`` lives at
  ## ``codetracer-polkavm-recorder/test-programs/rust/`` (built via
  ## ``cargo run --example build_flow_test_blob``).
  let envBlob = getEnv("CODETRACER_POLKAVM_FLOW_TEST", "")
  if envBlob.len > 0 and fileExists(envBlob):
    return envBlob
  let candidate = repoRoot() / ".." / "codetracer-polkavm-recorder" /
    "test-programs" / "rust" / "flow_test.polkavm"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "missing .polkavm blob; set CODETRACER_POLKAVM_FLOW_TEST or build " &
    "the flow test blob via " &
    "`cd codetracer-polkavm-recorder && cargo run --example build_flow_test_blob`")

proc recordPolkavmTrace(): tuple[tracePath, blobPath: string] =
  ## Record a trace from the discovered blob.  Per-PID temp dir so
  ## concurrent runs don't stomp each other.  With no DWARF, the
  ## recorder labels ``step.path`` after the blob itself, so
  ## ``blobPath`` doubles as the DAP source identifier.
  let dir = getTempDir() / ("ct_column_polkavm_vm_" & $getCurrentProcessId())
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  let stagedBlob = dir / "fixture.polkavm"
  copyFile(findPolkavmBlob(), stagedBlob)
  let outDir = dir / "trace"
  createDir(outDir)
  let cmd = quoteShell(findPolkavmRecorder()) & " record --out-dir " &
    quoteShell(outDir) & " " & quoteShell(stagedBlob)
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "polkavm recorder failed (exit " & $code & "): " & output
  # The ``.ct`` bundle lives at the top of outDir — the trace folder a
  # DAP launch references.
  result = (tracePath: outDir, blobPath: stagedBlob)

proc newPolkavmFixtureSession(): tuple[session: HeadlessDebugSession;
                                       sourceFile: string; startLine: int] =
  ## Record + boot a headless session.  ``sourceFile`` is the path the
  ## recorder labelled steps with (``getCurrentFile()`` after launch);
  ## falls back to the blob basename if empty (regression signal).
  let fixture = recordPolkavmTrace()
  let session = newHeadlessDebugSession(fixture.tracePath, findReplayServer())
  let cur = session.getCurrentFile()
  let sourceFile = if cur.len > 0: cur else: fixture.blobPath.lastPathPart
  doAssert sourceFile.len > 0
  let startLine = session.getCurrentLine()
  doAssert startLine >= 1
  result = (session: session, sourceFile: sourceFile, startLine: startLine)

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "M-polkavm — Column-aware breakpoint through the ViewModel":

  test "test_column_polkavm_vm_setBreakpoints_response_echoes_bound_column":
    ## STRICT — column-aware ``setBreakpoints`` against a real PolkaVM
    ## trace MUST surface ``column`` on the response.  Recorder-pipeline
    ## analogue of the M1 JS wire-contract assertion.
    let f = newPolkavmFixtureSession()
    # Column-aware bp at col 5 on the current line.  Default
    # ``flow_test.polkavm`` has no DWARF, so pin the WIRE-LEVEL
    # invariant only: ``column`` MUST be echoed; ``verified`` MAY be
    # false when no step has that column.
    const ProbeColumn = 5
    let resp = f.session.lastSetBreakpointsResponse(
      f.sourceFile, line = f.startLine, column = ProbeColumn)
    check resp.getOrDefault("success").getBool(false)
    let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
    check bps.kind == JArray
    check bps.len == 1
    let echoed = bps[0].getOrDefault("column")
    check (not echoed.isNil) and echoed.kind == JInt
    check echoed.getInt(0) == ProbeColumn
    check bps[0].getOrDefault("line").getInt(0) == f.startLine

  test "test_column_polkavm_vm_line_only_breakpoint_preserved":
    ## STRICT — legacy line-only breakpoints (``column = 0``) keep
    ## working end-to-end on a PolkaVM trace.  The wire MUST NOT carry
    ## ``column`` and the response MUST surface ``column = None``.
    let f = newPolkavmFixtureSession()
    # ``column = 0`` omits the column key on the wire.
    let resp = f.session.lastSetBreakpointsResponse(
      f.sourceFile, line = f.startLine, column = 0)
    check resp.getOrDefault("success").getBool(false)
    let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
    check bps.kind == JArray
    check bps.len == 1
    check bps[0].getOrDefault("verified").getBool(false)
    # A line-only bp MUST NOT surface a column — would mislead DAP
    # clients into reading the request as column-aware.
    let colNode = bps[0].getOrDefault("column")
    check colNode.isNil or colNode.kind == JNull

  test "test_column_polkavm_vm_complete_move_carries_column_option":
    ## STRICT — ``ct/complete-move`` exposes ``column`` as
    ## ``Option<int>``: ``Some(c)`` with DWARF, ``None`` without.
    ## Without this a DWARF-rich blob would surface columns as JSON
    ## null and the GUI gutter glyph would lose its anchor.
    let f = newPolkavmFixtureSession()
    check (not f.session.lastCompleteMoveEvent.isNil)
    let body = f.session.lastCompleteMoveEvent.getOrDefault("body")
    check (not body.isNil)
    check body.hasKey("location")
    let loc = body["location"]
    # MUST carry ``line``; MAY carry ``column`` (null or positive int).
    check loc.hasKey("line")
    check loc["line"].getInt(0) >= 1
    if loc.hasKey("column"):
      let c = loc["column"]
      check c.kind == JNull or (c.kind == JInt and c.getInt(0) >= 1)

    # ``getCurrentColumn`` MUST mirror the wire shape.
    let observed = f.session.getCurrentColumn()
    if loc.hasKey("column") and loc["column"].kind == JInt:
      check observed.isSome
      check observed.get() == loc["column"].getInt(0)
    else:
      check observed.isNone

when isMainModule:
  discard
