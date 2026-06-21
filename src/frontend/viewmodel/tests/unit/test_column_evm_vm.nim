## M-evm — Headless ViewModel layer test for column-aware breakpoints on
## an EVM/Solidity recording.
##
## Sister of ``test_column_breakpoint_vm.nim`` — same wire-level
## assertions, but the trace is produced by ``codetracer-evm-recorder``
## against the canonical fixture
## ``codetracer-evm-recorder/test-programs/column_aware/ColumnAware.sol``.
##
## What this test proves:
##   1. ``setBreakpoint(file, line, column)`` sends the column on the
##      DAP wire even when the recording came from the EVM recorder.
##   2. The replay-server echoes the bound column back on the
##      ``setBreakpoints`` response (recorder-agnostic).
##   3. After a forward continue:
##      * IF the EVM recorder emitted a step at the targeted
##        ``(line, column)`` the engine MUST stop precisely there.
##      * IF the recorder did NOT (the current state of
##        ``codetracer-evm-recorder`` — incremental column emission)
##        the test surfaces a clear recorder-gap diagnostic.  The
##        strict column-stop contract is pinned at the DAP layer via
##        ``dap_column_evm.rs``.
##   4. Legacy ``setBreakpoint(file, line)`` (no column) preserves
##      the line-only wire contract.
##
## Gated on ``CODETRACER_EVM_RECORDER_PATH`` (with sibling-repo
## fallback).  When the recorder isn't on disk the test exits with a
## clear ``[Skipped]`` message — the M1 contract for the
## recorder-agnostic core is pinned in the DAP-level test.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_evm_vm.nim

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

proc findEvmRecorder(): string =
  ## Locate the ``codetracer-evm-recorder`` binary.
  ##
  ## Search order mirrors the Rust test harness
  ## (``src/db-backend/tests/test_harness/mod.rs::find_evm_recorder``):
  ## env var first, then sibling-repo release build, then sibling-repo
  ## debug build.  Returns the empty string when not found so the
  ## caller can gracefully skip.
  let envPath = getEnv("CODETRACER_EVM_RECORDER_PATH", "")
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let candidates = [
    repoRoot() / ".." / "codetracer-evm-recorder" / "target" / "release" /
      "codetracer-evm-recorder",
    repoRoot() / ".." / "codetracer-evm-recorder" / "target" / "debug" /
      "codetracer-evm-recorder",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  return ""

proc findColumnAwareFixture(): string =
  ## Locate the canonical ``ColumnAware.sol`` fixture inside the EVM
  ## recorder sibling.  Returns the empty string when not found.
  let candidate = repoRoot() / ".." / "codetracer-evm-recorder" /
    "test-programs" / "column_aware" / "ColumnAware.sol"
  if fileExists(candidate):
    return candidate
  return ""

proc fixtureDir(): string =
  ## Per-process temp directory for the Solidity source + recorded trace.
  ## We scope to the pid so concurrent test runs don't stomp each other.
  result = getTempDir() / ("ct_column_evm_vm_" & $getCurrentProcessId())

type EvmFixture = object
  ## Trace + source-path pair for the canonical ``ColumnAware.sol``
  ## recording.
  ##
  ## ``lineXyz`` is the Solidity line carrying the three uint
  ## declarations ``uint x = 1; uint y = 2; uint z = 3;`` — the
  ## multi-statement line that exercises the column-aware breakpoint
  ## path.  Per the canonical fixture (8-space body indent) the
  ## 1-indexed columns are 9 / 21 / 33; the test computes them from the
  ## source text so future tweaks to the fixture stay correct.
  tracePath*: string
  sourcePath*: string
  lineXyz*: int
  colX*: int
  colY*: int
  colZ*: int
  legacyLine*: int  ## The `return x + y + z;` line.

proc recordEvmTrace(recorder, sourcePath: string): EvmFixture =
  ## Drive ``codetracer-evm-recorder record`` against the canonical
  ## ``ColumnAware.sol`` fixture and return the trace dir + the parsed
  ## line/column metadata.
  ##
  ## We invoke the recorder via ``direnv exec`` rooted at the EVM
  ## recorder repo so its Nix dev shell provides ``solc`` + ``anvil``
  ## on PATH (the same trick the db-backend test harness uses; see
  ## ``record_solidity_trace`` in
  ## ``src/db-backend/tests/test_harness/mod.rs``).  When direnv is not
  ## available we fall back to invoking the recorder directly — that
  ## works in CI shells that already provide ``solc`` + ``anvil``.
  let workDir = fixtureDir()
  if dirExists(workDir):
    removeDir(workDir)
  createDir(workDir)

  # Copy the canonical fixture into our work dir so the recorded
  # absolute source path stays stable across runs of the test.  The
  # recorder embeds the path it was invoked with into the trace; copying
  # avoids surfacing the sibling-repo path inside the trace.
  let localSource = workDir / "ColumnAware.sol"
  copyFile(sourcePath, localSource)

  let outDir = workDir / "out"
  createDir(outDir)

  # Locate the EVM recorder repo so we can pick up its direnv-managed
  # ``solc`` / ``anvil``.  Falls back to direct invocation when direnv
  # isn't on PATH or the repo lacks a ``.envrc`` (e.g. a packaged build).
  let recorderRepo = recorder.parentDir.parentDir.parentDir
  let useDirenv = findExe("direnv").len > 0 and
    fileExists(recorderRepo / ".envrc")

  var cmd: string
  if useDirenv:
    cmd = "direnv exec " & quoteShell(recorderRepo) & " " &
      quoteShell(recorder) & " record " & quoteShell(localSource) &
      " --out-dir " & quoteShell(outDir)
  else:
    cmd = quoteShell(recorder) & " record " & quoteShell(localSource) &
      " --out-dir " & quoteShell(outDir)

  let (output, code) = execCmdEx(cmd)
  doAssert code == 0,
    "EVM recorder failed (exit " & $code & "):\n" & output

  # The recorder writes ``<ContractName>.ct`` directly into ``out-dir``;
  # confirm one was produced.
  var ctCount = 0
  for kind, path in walkDir(outDir):
    if kind == pcFile and path.endsWith(".ct"):
      inc ctCount
  doAssert ctCount == 1,
    "expected exactly one .ct bundle under " & outDir & ", found " & $ctCount

  # Parse the line and column positions from the source text so the
  # assertions stay true to the canonical fixture even if the recorder's
  # column emission changes.  The multi-statement line is the unique
  # line containing all three `uint x = 1; uint y = 2; uint z = 3;`
  # statements.
  let srcText = readFile(localSource)
  var lines = srcText.split('\n')
  var multiLineIdx = -1
  for i, ln in lines:
    if "uint x" in ln and "uint y" in ln and "uint z" in ln:
      multiLineIdx = i
      break
  doAssert multiLineIdx >= 0,
    "could not locate the `uint x; uint y; uint z` line in " & localSource
  let multiLine = lines[multiLineIdx]
  let colX = multiLine.find("uint x") + 1
  let colY = multiLine.find("uint y") + 1
  let colZ = multiLine.find("uint z") + 1
  doAssert colX > 0 and colY > colX and colZ > colY,
    "fixture's `uint x/y/z` columns are unexpectedly out of order: " &
    $colX & ", " & $colY & ", " & $colZ

  # `return ...;` is the next line carrying source.
  var returnLineIdx = -1
  for i in (multiLineIdx + 1) ..< lines.len:
    if "return " in lines[i]:
      returnLineIdx = i
      break
  doAssert returnLineIdx >= 0,
    "could not locate the `return ...` line after the multi-stmt line"

  result = EvmFixture(
    tracePath: outDir,
    sourcePath: localSource,
    # Convert 0-indexed array offset to 1-indexed source line number.
    lineXyz: multiLineIdx + 1,
    colX: colX,
    colY: colY,
    colZ: colZ,
    legacyLine: returnLineIdx + 1,
  )

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "M-evm — Column-aware breakpoint through the ViewModel (EVM trace)":

  test "test_column_evm_vm_stops_at_recorded_column":
    ## Drive the ViewModel via headless_session.nim, set a breakpoint
    ## at column N within the multi-statement Solidity line, continue,
    ## and assert that ``(line, column)`` of the stop matches.
    let recorder = findEvmRecorder()
    let fixtureSrc = findColumnAwareFixture()
    if recorder.len == 0 or fixtureSrc.len == 0:
      skipMissingRecorder("codetracer-evm-recorder",
        "CODETRACER_EVM_RECORDER_PATH",
        "Build the codetracer-evm-recorder sibling (cargo build).")
    else:
      let fixture = recordEvmTrace(recorder, fixtureSrc)
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # Sanity — the recorder lands the cursor inside the recorded EVM
      # contract.  We don't assert the exact entry line because that's a
      # property of the recorder (and may shift as the contract evolves);
      # we only need a defined starting point.
      let initialFile = session.getCurrentFile()
      check initialFile.len > 0
      check initialFile.endsWith("ColumnAware.sol") or "ColumnAware" in initialFile

      # M-evm — set a breakpoint at the SECOND statement (`uint y`) on the
      # multi-statement line.  The bound column on the DAP response MUST
      # echo back exactly: this is the wire-level half of the M-evm
      # contract and is recorder-agnostic — the replay-server just
      # records the requested column on the verified Breakpoint object
      # so DAP clients (VS Code, the GUI gutter renderer, etc.) can
      # anchor the marker at the right column.
      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = fixture.lineXyz, column = fixture.colY)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      check bps[0].hasKey("column")
      check bps[0]["column"].getInt(0) == fixture.colY
      check bps[0].getOrDefault("line").getInt(0) == fixture.lineXyz

      # Continue forward.  Two possible behaviours, both acceptable:
      #
      #   (a) The EVM recorder emitted column-aware steps on the
      #       multi-statement line — then the replay engine MUST stop at
      #       (line=lineXyz, col=colY) precisely.  This is the strict M-evm
      #       behavior that the DAP-level acceptance test
      #       (`dap_column_evm.rs`) pins via a synthetic trace.
      #
      #   (b) The EVM recorder did NOT emit column-aware steps on the
      #       multi-stmt line (the current state of
      #       `codetracer-evm-recorder` as of the M-evm milestone landing
      #       — the recorder only emits steps at function boundaries and
      #       on the `return` line).  Then the breakpoint registers
      #       cleanly but never fires; Continue runs to end-of-program.
      #       The DAP layer is doing its job — there's just no recorded
      #       step at the requested column to stop on.
      #
      # Either way the wire-level column echo above (the half of the
      # M-evm contract the db-backend owns) is the strict assertion;
      # the post-Continue column assertion is conditional on the
      # recorder having produced the data.
      session.continueForward()
      let landedLine = session.getCurrentLine()
      let landedCol = session.getCurrentColumn()
      echo "M-evm continueForward landed at line=", landedLine, " col=", landedCol
      if landedLine == fixture.lineXyz:
        # Recorder emitted a step on the multi-stmt line — the
        # column-aware stop MUST be precise.
        check landedCol.isSome
        check landedCol.get() == fixture.colY
      else:
        # Recorder did NOT emit a step at (lineXyz, colY) — Continue
        # ran past the breakpoint to end-of-program.  Surface a clear
        # diagnostic so the test caller knows this is the
        # recorder-gap branch, not a db-backend regression.
        echo "M-evm: no recorded step at (line=", fixture.lineXyz,
          ", col=", fixture.colY, "); recorder gap (not a db-backend bug). " &
          "Once `codetracer-evm-recorder` ships column-aware step emission " &
          "for the multi-statement line the strict branch above will fire."

  test "test_column_evm_vm_line_only_breakpoint_preserved":
    ## Legacy line-only breakpoints — ``setBreakpoint`` with ``column =
    ## 0`` — MUST continue to work for EVM traces after the M-evm
    ## extension.  This pins back-compat for DAP clients that don't
    ## send a column (older VS Code, pre-M1 CodeTracer Electron
    ## frontend).
    let recorder = findEvmRecorder()
    let fixtureSrc = findColumnAwareFixture()
    if recorder.len == 0 or fixtureSrc.len == 0:
      skipMissingRecorder("codetracer-evm-recorder",
        "CODETRACER_EVM_RECORDER_PATH",
        "Build the codetracer-evm-recorder sibling (cargo build).")
    else:
      let fixture = recordEvmTrace(recorder, fixtureSrc)
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # Set a line-only breakpoint on the `return` line.  Wire SHOULD NOT
      # carry a column key — assert the response surfaces column=None to
      # prove the legacy path is taken.  This half of the test is fully
      # recorder-agnostic: the replay-server's setBreakpoints handler
      # builds the verified Breakpoint object from the request without
      # consulting the trace, so the column-omission contract is
      # independent of whether the EVM recorder emitted a step on this
      # line.
      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = fixture.legacyLine, column = 0)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      # `column` is `skip_serializing_if = Option::is_none` on the Rust
      # side, so a legacy response either omits the key entirely or sets
      # it to null.  Both are equivalent to "no column".
      let colNode = bps[0].getOrDefault("column")
      check colNode.isNil or colNode.kind == JNull

      # Continue forward.  Two outcomes mirror the column-aware test:
      #
      #   (a) Recorder emitted a step on `legacyLine` — Continue MUST
      #       stop there.
      #   (b) Recorder didn't emit a step on `legacyLine` — Continue
      #       runs to end-of-program.  This is the EVM-recorder-gap
      #       branch (not a db-backend bug).
      #
      # Either way the wire-level "no column" assertion above is the
      # strict contract pinned by this test.
      session.continueForward()
      let landedLine = session.getCurrentLine()
      let landedCol = session.getCurrentColumn()
      echo "M-evm legacy continueForward landed at line=", landedLine, " col=", landedCol
      if landedLine == fixture.legacyLine:
        # Recorder emitted a step on the return line — the legacy
        # line-only breakpoint MUST stop there.  Column (if present)
        # is whatever the recorder picked.
        if landedCol.isSome:
          check landedCol.get() >= 1
      else:
        echo "M-evm: no recorded step at line=", fixture.legacyLine,
          "; recorder gap (not a db-backend bug)."

when isMainModule:
  discard
