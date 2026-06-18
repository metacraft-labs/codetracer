## M1 — Headless ViewModel layer test for column-aware breakpoints on
## the Flow/Cadence recorder pipeline.
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
##   §M1 Acceptance tests — Headless ViewModel.
##
## Companion to:
##   * ``test_column_breakpoint_vm.nim`` — the canonical M1 ViewModel
##     test, parameterised on the JavaScript recorder.
##   * ``src/db-backend/tests/dap_column_flow.rs`` — wire-level half of
##     the Cadence column-aware contract, exercised against the
##     production ``Handler`` with a hand-crafted in-memory trace.
##
## ## What this test proves end-to-end
##
##   1. The Flow recorder (Cadence/Go-helper) writes a column on every
##      step it emits.  The helper copies ``ast.Position.Column`` from
##      the Cadence AST verbatim (see
##      ``codetracer-flow-recorder/go-helper/main.go`` around the
##      ``convertCadencePos`` definition).
##   2. The replay server, fed such a column-aware Cadence trace, echoes
##      the bound column back on the DAP ``setBreakpoints`` response.
##   3. After a forward continue, the ViewModel's ``getCurrentLine`` /
##      ``getCurrentColumn`` accessors report the recorded line/column
##      of the step the backend halted at — proving the column flows
##      through ``ct/complete-move`` into the store-backed signals the
##      GUI reads, identically to the JS pipeline.
##   4. The legacy ``setBreakpoint(file, line)`` call (no column)
##      preserves the line-only behaviour on Cadence traces: column is
##      not sent on the wire, and the continue stops at the first
##      recorded step on that line.
##
## ## Cadence multi-statement fixture
##
## The fixture is a Cadence script with a deliberate multi-statement
## line (Cadence treats ``;`` as a statement separator and the parser
## records ``ast.Position.Column`` for every statement):
##
## .. code-block:: cadence
##    access(all) fun compute(): Int {
##        let a: Int = 10; let b: Int = 32; let c: Int = a + b
##        let d: Int = c * 2
##        return d
##    }
##
##    access(all) fun main(): Int {
##        return compute()
##    }
##
## Within ``compute()``:
##   line 2 — 3 statements at columns 5, 22, 39 (approx; computed from
##           the source text by ``findCol``).
##   line 3 — 1 statement (``let d``) at column 5.
##
## Compile + run:
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_flow_vm.nim
##
## Required environment:
##
##   * ``REPLAY_SERVER_BIN`` — path to a built replay-server binary.
##     Defaults to ``src/build-debug/bin/replay-server`` or
##     ``src/db-backend/target/debug/replay-server``.
##
##   * ``CODETRACER_CADENCE_RECORDER_PATH`` — path to a built
##     ``codetracer-flow-recorder`` binary.  Defaults to
##     ``../codetracer-flow-recorder/target/debug/codetracer-flow-recorder``.
##
##   * ``CADENCE_HELPER_BIN`` — path to a built ``cadence-trace-helper``
##     Go binary.  Defaults to the helper at
##     ``../codetracer-flow-recorder/target/debug/cadence-trace-helper``
##     (built by the flow recorder's Go-helper build step).
##
## All three tools ship pre-built in the standard checkout layout when
## the flow recorder sibling repo is built (``cargo build`` for the Rust
## CLI; ``go build`` inside ``go-helper/`` for the Cadence helper).  If
## any of them is missing or the recording fails, the test fails loudly
## per the M1 contract ("no test.skip, no #[ignore]").

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

import ../../headless_session

# ---------------------------------------------------------------------------
# Fixture preparation
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## Locate the codetracer repo root by walking upward from this file.
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

proc findFlowRecorder(): string =
  ## Locate the ``codetracer-flow-recorder`` binary.  This mirrors the
  ## Rust harness's ``find_cadence_recorder`` in
  ## ``src/db-backend/tests/test_harness/mod.rs``.
  let envBin = getEnv("CODETRACER_CADENCE_RECORDER_PATH", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidates = [
    repoRoot() / ".." / "codetracer-flow-recorder" / "target" / "debug" /
      "codetracer-flow-recorder",
    repoRoot() / ".." / "codetracer-flow-recorder" / "target" / "release" /
      "codetracer-flow-recorder",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  raise newException(IOError,
    "missing Flow recorder; set CODETRACER_CADENCE_RECORDER_PATH or " &
    "build the codetracer-flow-recorder sibling repo (cargo build).  " &
    "Required for the M1 Cadence ViewModel test.")

proc findCadenceHelper(): string =
  ## Locate the Go-built ``cadence-trace-helper`` binary.  Required by
  ## the Flow recorder at run-time — it shells out to the helper for
  ## Cadence AST interpretation and ``ast.Position`` capture.
  let envBin = getEnv("CADENCE_HELPER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidate = repoRoot() / ".." / "codetracer-flow-recorder" / "target" /
    "debug" / "cadence-trace-helper"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "missing cadence-trace-helper; set CADENCE_HELPER_BIN or build " &
    "the helper via `go build -o target/debug/cadence-trace-helper .` " &
    "inside codetracer-flow-recorder/go-helper/")

proc fixtureDir(): string =
  ## Per-process temp directory for the Cadence source + recorded trace.
  ## Scoped to the pid so concurrent test runs don't stomp each other.
  result = getTempDir() / ("ct_column_flow_vm_" & $getCurrentProcessId())

const cadenceProgram = """access(all) fun compute(): Int {
    let a: Int = 10; let b: Int = 32; let c: Int = a + b
    let d: Int = c * 2
    return d
}

access(all) fun main(): Int {
    return compute()
}
"""

proc findCol(line, needle: string): int =
  ## 1-based column where ``needle`` first appears in ``line``.  Used to
  ## recompute the Cadence column constants directly from the source
  ## text so the test stays honest if the program string is tweaked.
  let idx = line.find(needle)
  doAssert idx >= 0, "needle '" & needle & "' not found in line: " & line
  idx + 1

proc recordCadenceTrace(): tuple[tracePath, sourcePath: string;
                                 statementLine: int;
                                 colA, colB, colC: int;
                                 legacyLine: int] =
  ## Record a Cadence program with a multi-statement line and return
  ## the recorded trace dir + the 1-based ``ast.Position.Column``
  ## values the parser would assign to each statement on line 2 of the
  ## script (the ``let a; let b; let c`` line inside ``compute()``).
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "flow_column_test.cdc"
  writeFile(sourcePath, cadenceProgram)

  # Compute columns directly from the source text.  Cadence's
  # ``ast.Position.Column`` is 1-based, matching what ``findCol``
  # returns.  Line numbers below are 1-based and match the literal
  # newlines in ``cadenceProgram``.
  let programLines = cadenceProgram.split('\n')
  doAssert programLines.len >= 4,
    "Cadence fixture must have at least 4 lines; got " & $programLines.len
  let stmtLine = programLines[1]
  let colA = findCol(stmtLine, "let a")
  let colB = findCol(stmtLine, "let b")
  let colC = findCol(stmtLine, "let c")
  doAssert colA == 5,
    "expected `let a` at column 5 (4-space indent + 1); got " & $colA
  doAssert colB > colA
  doAssert colC > colB

  # Drive the Flow recorder CLI:
  #   <flow-recorder> record <source.cdc> --out-dir <out-dir>
  # The recorder requires the Cadence Go helper on the
  # ``CADENCE_HELPER_BIN`` env var.
  let recorder = findFlowRecorder()
  let helper = findCadenceHelper()
  let outParent = dir / "rec-out"
  createDir(outParent)

  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["CADENCE_HELPER_BIN"] = helper

  let process = startProcess(
    recorder,
    args = @["record", sourcePath, "--out-dir", outParent],
    env = env,
    options = {poStdErrToStdOut, poUsePath})
  let exitCode = process.waitForExit()
  let output = process.outputStream.readAll()
  process.close()
  doAssert exitCode == 0,
    "Flow recorder failed to record " & sourcePath &
    " (exit " & $exitCode & "): " & output

  # The Flow recorder writes the trace bundle directly under
  # --out-dir.  If it produced a trace-* subdir (matching the JS
  # recorder convention) move that to a stable path; otherwise the
  # bundle IS the out-dir.
  var traceDir = ""
  for kind, path in walkDir(outParent):
    if kind == pcDir and path.lastPathPart.startsWith("trace"):
      traceDir = path
      break
  if traceDir.len == 0:
    # No trace-* subdir — the recorder wrote directly into outParent.
    traceDir = outParent
  else:
    let stable = dir / "trace"
    moveDir(traceDir, stable)
    traceDir = stable

  return (tracePath: traceDir, sourcePath: sourcePath,
          statementLine: 2, colA: colA, colB: colB, colC: colC,
          legacyLine: 3)

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "M1 — Column-aware breakpoint through the ViewModel (Cadence/Flow)":

  test "test_column_flow_vm_stops_at_recorded_column":
    ## Drive the ViewModel via headless_session.nim against a Cadence
    ## recording: set a breakpoint at the SECOND statement on the
    ## multi-statement line, continue, and assert that the
    ## ``(line, column)`` of the stop matches.
    let fixture = recordCadenceTrace()
    let replayServer = findReplayServer()
    var session = newHeadlessDebugSession(fixture.tracePath, replayServer)
    defer: session.close()

    # Sanity — the initial position lands somewhere inside the Cadence
    # program.  The Flow recorder's first reported step is typically
    # the first executable statement (the ``main`` entrypoint).  We
    # don't pin a specific initial column here — Cadence's first step
    # depends on the helper's startup sequence — but the file must be
    # the recorded Cadence source.
    check session.getCurrentFile().endsWith("flow_column_test.cdc")

    # M1 — set a breakpoint at the SECOND statement (``let b``) on the
    # multi-statement line.  The bound column on the response MUST echo
    # back exactly the column the Cadence parser would assign.
    let resp = session.lastSetBreakpointsResponse(
      fixture.sourcePath, line = fixture.statementLine,
      column = fixture.colB)
    check resp.getOrDefault("success").getBool(false)
    let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
    check bps.kind == JArray
    check bps.len == 1
    check bps[0].getOrDefault("verified").getBool(false)
    check bps[0].hasKey("column")
    check bps[0]["column"].getInt(0) == fixture.colB
    check bps[0].getOrDefault("line").getInt(0) == fixture.statementLine

    # Continue forward.  The replay engine MUST honour the column —
    # otherwise it would (wrongly) stop at the first ``let a`` step on
    # the same line (the same-line fallback the M1 anti-regression
    # guards against).  Assert exact match on both axes.
    session.continueForward()
    check session.getCurrentLine() == fixture.statementLine
    let afterCol = session.getCurrentColumn()
    check afterCol.isSome
    check afterCol.get() == fixture.colB

  test "test_column_flow_vm_line_only_breakpoint_preserved":
    ## Legacy line-only breakpoints — ``setBreakpoint`` with
    ## ``column = 0`` — MUST continue to work after the M1 extension
    ## on Cadence traces.  Pins back-compat for DAP clients that don't
    ## send a column.
    let fixture = recordCadenceTrace()
    let replayServer = findReplayServer()
    var session = newHeadlessDebugSession(fixture.tracePath, replayServer)
    defer: session.close()

    # Set a line-only breakpoint on the next line (``let d``).  Wire
    # SHOULD NOT carry a column key — assert the response surfaces
    # column=None to prove the legacy path is taken.
    let resp = session.lastSetBreakpointsResponse(
      fixture.sourcePath, line = fixture.legacyLine, column = 0)
    check resp.getOrDefault("success").getBool(false)
    let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
    check bps.kind == JArray
    check bps.len == 1
    check bps[0].getOrDefault("verified").getBool(false)
    # ``column`` is ``skip_serializing_if = Option::is_none`` on the
    # Rust side, so a legacy response either omits the key entirely or
    # sets it to null.  Both are equivalent to "no column".
    let colNode = bps[0].getOrDefault("column")
    check colNode.isNil or colNode.kind == JNull

    # Continue forward.  Should stop at the first step of the legacy
    # line.  The Cadence helper still emits a column for the recorded
    # step in column-aware mode — line-only matching just means the
    # breakpoint hit fires regardless of column, NOT that the recorded
    # step's column is absent.
    session.continueForward()
    check session.getCurrentLine() == fixture.legacyLine
    let landedCol = session.getCurrentColumn()
    if landedCol.isSome:
      check landedCol.get() >= 1

when isMainModule:
  discard
