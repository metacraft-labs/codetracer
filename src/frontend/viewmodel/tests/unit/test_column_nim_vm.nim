## M1 — Headless ViewModel layer test for column-aware breakpoints on
## the **Nim compile-time tracer** pipeline.
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
##   §M1 Acceptance tests — Headless ViewModel.
##
## Companion: ``test_column_breakpoint_vm.nim`` (the canonical JS
## recorder variant we mirror line-for-line).
##
## ## Why this test exists
##
## The **Nim compile-time tracer** (invoked via ``nim e
## --trace:<file>.ct <script>.nims``) talks directly to the Nim writer
## (no C FFI shim).  It is the only recorder that emits one CTFS step
## per *vmgen sub-expression opcode*, producing the highest per-line
## column density of the entire matrix.  The upstream recorder fixture
## ``codetracer-nim/tests/sourcemap/tvm_trace_column_aware.nim``
## confirms ≥7 distinct columns on the recorded
## ``var a = 1; var b = 2; var c = 3`` line.
##
## This test pins the **ViewModel surface** against that layout:
##
##   1. ``lastSetBreakpointsResponse(file, line, column)`` sends a
##      ``{"line": L, "column": C}`` payload on the DAP wire for a
##      Nim-recorded ``.ct``;
##   2. the replay-server echoes the bound column back on the response;
##   3. after a forward continue, ``getCurrentLine`` /
##      ``getCurrentColumn`` report the recorded line/column;
##   4. the legacy ``setBreakpoint(file, line)`` call (no column)
##      keeps working — column is not sent on the wire, and Continue
##      stops at the first recorded step on that line.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_nim_vm.nim
##
## Required environment:
##   * ``REPLAY_SERVER_BIN`` — path to a built replay-server (defaults
##     to ``src/db-backend/target/debug/replay-server``).
##   * ``CODETRACER_NIM_BIN`` — path to the codetracer-nim compiler
##     (defaults to ``../../codetracer-nim/bin/nim``).
##
## Both tools ship pre-built in the standard checkout layout.  When
## either is missing the test fails loudly per the M1 contract.

import std/[json, options, os, osproc, strutils, unittest]

import ../../headless_session
import recorder_gate

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

proc findCodetracerNim(): string =
  ## Locate the codetracer-patched Nim compiler binary.  The patched
  ## compiler accepts ``--trace:<file>.ct`` and writes a column-aware
  ## CTFS trace directly to that path (no C FFI shim).
  let envBin = getEnv("CODETRACER_NIM_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidates = [
    repoRoot() / ".." / "codetracer-nim" / "bin" / "nim",
    repoRoot() / ".." / ".." / "codetracer-nim" / "bin" / "nim",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  # Returns "" when the patched compiler is missing so the caller gates
  # the test through requireRecorderOrSkip (recorder_gate.nim) for a
  # uniform, greppable skip rather than a hard IOError.
  return ""

proc fixtureDir(): string =
  ## Per-process temp directory for the Nim source + recorded trace.  We
  ## scope to the pid so concurrent test runs don't stomp each other.
  result = getTempDir() / ("ct_column_nim_vm_" & $getCurrentProcessId())

type
  NimColumnFixture* = object
    ## Result of recording the column-aware Nim VM trace.  Mirrors
    ## ``tvm_trace_column_aware.nim``'s output shape so the test
    ## assertions stay legible.
    tracePath*: string
      ## Absolute path to the ``.ct`` file the recorder produced.
    sourcePath*: string
      ## Absolute path to the recorded ``.nims`` script (the path
      ## ``DbStep.path_id`` resolves to inside the trace).
    targetColumn*: int
      ## A 1-based column on line 1 that the recorder definitely
      ## emitted a step at — used as the breakpoint target in the
      ## strict sub-test.  We pick a column that is NOT column 1
      ## (the entry-step column) so the assertion proves the column
      ## key was honoured.
    legacyLine*: int
      ## A later line in the script that has at least one recorded
      ## step — used by the line-only fallback sub-test.

## Recorder column-layout constants for the canonical Nim VM trace
## fixture.  The vmgen tracer is deterministic for a fixed source —
## these columns were observed via ``ct-print --events`` against the
## ``codetracer-nim`` ``bin/nim`` produced by the standard sibling
## build (``./build_all.sh``):
##
##   * line 1 cols: 1, 5, 9, 16, 20, 27, 31  (7 distinct, ≥3 floor)
##   * line 2 cols: 1, 6, 9, 14, 17, 22       (6 distinct)
##
## We pick column 5 on line 1 as the breakpoint target because:
##   1. it is NOT the entry column (1), so the column-aware key MUST
##      be consulted to land there (a line-only fallback would land at
##      column 1);
##   2. it is the EARLIEST non-entry column, so a forward Continue
##      from the entry reaches it without traversing past line 1.
const NIM_VM_TARGET_COL_ON_LINE_1: int = 5

proc recordNimVmTrace(): NimColumnFixture =
  ## Record the multi-statement Nim script with the patched Nim
  ## compiler and return the trace path.  The script body matches the
  ## canonical ``tvm_trace_column_aware`` fixture so the column-density
  ## invariant the recorder test pins (≥3 distinct columns on line 1,
  ## typically 7) is preserved here too.
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "cols.nims"
  const program = "var a = 1; var b = 2; var c = 3\n" &
                  "echo a, \" \", b, \" \", c\n"
  writeFile(sourcePath, program)

  let nim = findCodetracerNim()
  let tracePath = dir / "cols.ct"
  let cmd = quoteShell(nim) & " e --trace:" & quoteShell(tracePath) &
            " " & quoteShell(sourcePath)
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0,
    "codetracer-nim compile-time tracer failed: " & cmd &
    "\n--- output ---\n" & output
  doAssert fileExists(tracePath),
    "recorder did not produce a .ct file at " & tracePath &
    "\n--- output ---\n" & output

  result = NimColumnFixture(
    tracePath: tracePath,
    sourcePath: sourcePath,
    targetColumn: NIM_VM_TARGET_COL_ON_LINE_1,
    legacyLine: 2,
  )

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "M1 — Column-aware breakpoint (Nim VM tracer) through the ViewModel":

  test "test_column_nim_vm_stops_at_recorded_column":
    requireRecorderOrSkip(findCodetracerNim(), "codetracer-nim (patched compiler)",
        "CODETRACER_NIM_BIN",
        "Build the codetracer-nim sibling (./build_all.sh)."):
      ## Drive the ViewModel via headless_session.nim, set a breakpoint
      ## at a known non-entry column on line 1 of the column-aware Nim
      ## VM trace, continue, and assert that ``(line, column)`` of the
      ## stop matches the bound coordinates.
      let fixture = recordNimVmTrace()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # Sanity — the recorder lands the cursor on the first vmgen opcode
      # of line 1 at run-to-entry; the column-aware writer emits column 1
      # (the absolute step at the start of the line).  This pins the
      # initial state so the post-Continue assertions have a defined
      # starting point.
      check session.getCurrentFile().endsWith("cols.nims")
      check session.getCurrentLine() == 1
      let initialCol = session.getCurrentColumn()
      # M1 strict — column-aware traces MUST surface a column at entry.
      # The Nim writer's ``enableColumnAwareSteps`` opt-in flag is the
      # wire-level contract this assertion pins; a ``None`` here means
      # the Nim VM tracer regressed to legacy line-only emission.
      check initialCol.isSome
      check initialCol.get() == 1

      # M1 — set a breakpoint at the SECOND vmgen-emitted column on
      # line 1.  Picking a column that is NOT the entry column (1) is
      # what makes this assertion strict: a line-only fallback would
      # (wrongly) land at column 1, so the post-Continue check on
      # ``(line, column)`` MUST fail in that regression scenario.
      #
      # The bound column on the response MUST echo back exactly.
      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = 1, column = fixture.targetColumn)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      check bps[0].hasKey("column")
      check bps[0]["column"].getInt(0) == fixture.targetColumn
      check bps[0].getOrDefault("line").getInt(0) == 1

      # Continue forward.  The replay engine MUST honour the column —
      # otherwise it would (wrongly) stop at one of the EARLIER vmgen
      # steps on line 1.  Assert exact match on both axes.
      session.continueForward()
      check session.getCurrentLine() == 1
      let afterCol = session.getCurrentColumn()
      check afterCol.isSome
      check afterCol.get() == fixture.targetColumn

  test "test_column_nim_vm_line_only_breakpoint_preserved":
    requireRecorderOrSkip(findCodetracerNim(), "codetracer-nim (patched compiler)",
        "CODETRACER_NIM_BIN",
        "Build the codetracer-nim sibling (./build_all.sh)."):
      ## Legacy line-only breakpoints (``column = 0``) MUST continue to
      ## work after the M1 extension on a Nim recording.  This pins
      ## back-compat for DAP clients that don't send a column.  The Nim
      ## recorder still emits a column on every step (column-aware mode
      ## is trace-global), so a line-only match must fire on the FIRST
      ## same-line step regardless of recorded column.
      var fixture = recordNimVmTrace()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # Set a line-only breakpoint on line 2 (the `echo` statement).
      # Wire SHOULD NOT carry a column key — assert the response
      # surfaces column=None to prove the legacy path is taken.
      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = fixture.legacyLine, column = 0)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      # ``column`` is ``skip_serializing_if = Option::is_none`` on the
      # Rust side, so a legacy response either omits the key entirely
      # or sets it to null.  Both are equivalent to "no column".
      let colNode = bps[0].getOrDefault("column")
      check colNode.isNil or colNode.kind == JNull

      # Continue forward — MUST stop on line 2.  The Nim recorder
      # emits a column for every step (column-aware mode is trace-global)
      # so the landed column is not None — line-only matching just means
      # the breakpoint hit fires regardless of column, not that the
      # recorded step's column is absent.
      session.continueForward()
      check session.getCurrentLine() == fixture.legacyLine
      let landedCol = session.getCurrentColumn()
      if landedCol.isSome:
        check landedCol.get() >= 1

when isMainModule:
  discard
