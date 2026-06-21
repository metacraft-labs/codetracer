## M1 — Headless ViewModel test for column-aware breakpoints driven
## through the Noir recorder pipeline (`nargo trace`).
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1.
##
## Mirrors the JS variant ``test_column_breakpoint_vm.nim`` but feeds
## a real Noir-recorded trace (the ``multi_stmt_per_line`` fixture,
## three `let` statements on a single line) into the
## headless_session.nim driver.  Asserts the column round-trips on
## the DAP wire (``setBreakpoints`` response echoes the bound column)
## and that ``continueForward`` lands on the recorded ``(line, column)``
## reported by ``getCurrentLine`` / ``getCurrentColumn``.  A
## back-compat case pins the line-only behaviour.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_noir_vm.nim
##
## Environment:
##   * ``NARGO_PATH`` — REQUIRED.  Path to a `nargo` built from the
##     ``feature/M-noir-column-aware`` branch.  Unset => SKIPPED
##     (legacy `nargo` builds emit traces without columns, which would
##     make the column assertions fail confusingly; force opt-in).
##   * ``REPLAY_SERVER_BIN`` — path to a built replay-server binary.
##     Defaults to the standard cargo-debug or just-build path.

import std/[json, options, os, osproc, strutils, unittest]

import ../../headless_session
import recorder_gate

# ---------------------------------------------------------------------------
# Repo root discovery — shared with the JS sibling test
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## Walk upward from this file to find the codetracer repo root.
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if dirExists(dir / "src" / "db-backend") and dirExists(dir / "src" / "frontend"):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(IOError, "no codetracer root from " & currentSourcePath())

proc findReplayServer(): string =
  ## Resolve a replay-server binary (env override or standard build paths).
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin): return envBin
  for c in [repoRoot() / "src" / "build-debug" / "bin" / "replay-server",
            repoRoot() / "src" / "db-backend" / "target" / "debug" / "replay-server",
            repoRoot() / "src" / "db-backend" / "target" / "release" / "replay-server"]:
    if fileExists(c): return c
  raise newException(IOError,
    "missing replay-server; set REPLAY_SERVER_BIN or build via " &
    "`cd src/db-backend && cargo build`")

# ---------------------------------------------------------------------------
# Noir gating — NARGO_PATH must point at a column-aware nargo build
# ---------------------------------------------------------------------------

proc findColumnAwareNargo(): string =
  ## REQUIRES ``NARGO_PATH`` (absolute path to a column-aware `nargo`).
  ## Empty string => test should skip.  We deliberately do NOT fall back
  ## to ``which nargo``: legacy `nargo` builds emit traces without column
  ## data, which would make the column assertions fail confusingly.
  let envPath = getEnv("NARGO_PATH", "")
  if envPath.len == 0: return ""
  if not fileExists(envPath):
    raise newException(IOError,
      "NARGO_PATH=" & envPath & " does not point at an existing file")
  return envPath

# ---------------------------------------------------------------------------
# Fixture — `multi_stmt_per_line` from the column-aware Noir branch
# ---------------------------------------------------------------------------

const NoirFixtureSource = """fn main() {
    let a: Field = 1; let b: Field = 2; let c: Field = 3;
    assert(a + b + c == 6);
}
"""

const NoirFixtureNargoToml = """[package]
name = "multi_stmt_per_line"
version = "0.1.0"
type = "bin"
authors = [""]

[dependencies]
"""

# Columns 9 / 27 / 45 are the 1-based byte positions of `a` / `b` / `c`
# (LHS identifiers) on line 2, as emitted by the Noir column-aware tracer
# (`Span::start()` → `Files::column_number`).  See the sibling recorder
# test ``test_multi_stmt_per_line_column_aware`` on
# `feature/M-noir-column-aware`.
const MultiStmtLine = 2
const ColLetA = 9
const ColLetB = 27
const ColLetC = 45
const AssertLine = 3

proc fixtureDir(): string =
  result = getTempDir() / ("ct_column_noir_vm_" & $getCurrentProcessId())

proc materializeNoirFixture(): tuple[projectDir, sourcePath: string] =
  ## Write the ``multi_stmt_per_line`` Noir project to a fresh temp dir.
  ## The fixture is inlined here rather than read from the sibling
  ## `noir/test_programs/trace/multi_stmt_per_line` directory because that
  ## path lives on the `feature/M-noir-column-aware` branch.
  let dir = fixtureDir()
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  let projectDir = dir / "multi_stmt_per_line"
  createDir(projectDir)
  createDir(projectDir / "src")
  writeFile(projectDir / "Nargo.toml", NoirFixtureNargoToml)
  writeFile(projectDir / "Prover.toml", "")
  let sourcePath = projectDir / "src" / "main.nr"
  writeFile(sourcePath, NoirFixtureSource)
  return (projectDir: projectDir, sourcePath: sourcePath)

proc recordNoirTrace(nargoPath, projectDir: string): string =
  ## Invoke ``nargo trace --out-dir <traceDir>``; return the trace dir.
  ## Mirrors ``src/db-backend/tests/test_harness/mod.rs::record_noir_trace``.
  let traceDir = projectDir.parentDir / "trace"
  if dirExists(traceDir): removeDir(traceDir)
  createDir(traceDir)
  let nargoTmp = projectDir.parentDir / "nargo_tmp"
  if dirExists(nargoTmp): removeDir(nargoTmp)
  createDir(nargoTmp)
  let cmd = quoteShell(nargoPath) & " trace --out-dir " & quoteShell(traceDir)
  putEnv("TMPDIR", nargoTmp)
  let prevCwd = getCurrentDir()
  setCurrentDir(projectDir)
  let (output, code) = execCmdEx(cmd)
  setCurrentDir(prevCwd)
  doAssert code == 0, "nargo trace failed (exit " & $code & "):\n" & output
  return traceDir

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

template gateOnNargo(testName: string, body: untyped): untyped =
  ## Run ``body`` only when ``NARGO_PATH`` is set; otherwise skip().
  ## Exposes ``nargoPath``, ``replayServer``, ``traceDir``,
  ## ``fixture``, and ``session`` to ``body``.
  let nargoPath = findColumnAwareNargo()
  if nargoPath.len == 0:
    skipMissingRecorder("noir (column-aware nargo)",
      "NARGO_PATH",
      "Build the column-aware nargo from the noir sibling " &
        "(feature/M-noir-column-aware branch).")
  else:
    let fixture {.inject.} = materializeNoirFixture()
    let replayServer {.inject.} = findReplayServer()
    let traceDir {.inject.} = recordNoirTrace(nargoPath, fixture.projectDir)
    var session {.inject.} = newHeadlessDebugSession(traceDir, replayServer)
    body

suite "M1 — Column-aware breakpoint through the ViewModel (Noir)":

  test "test_column_noir_vm_stops_at_recorded_column":
    ## Set breakpoint at column 27 (`b`), continue, assert (line, column)
    ## of the stop matches the second `let` binding.
    gateOnNargo("test_column_noir_vm_stops_at_recorded_column"):
      check session.getCurrentFile().endsWith("main.nr")
      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = MultiStmtLine, column = ColLetB)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      check bps[0].hasKey("column")
      check bps[0]["column"].getInt(0) == ColLetB
      check bps[0].getOrDefault("line").getInt(0) == MultiStmtLine
      # Continue MUST honour column; without column, would stop at COL 9.
      session.continueForward()
      check session.getCurrentLine() == MultiStmtLine
      let afterCol = session.getCurrentColumn()
      check afterCol.isSome
      check afterCol.get() == ColLetB

  test "test_column_noir_vm_line_only_breakpoint_preserved":
    ## Back-compat: ``setBreakpoint`` with ``column = 0`` MUST stop at
    ## the first step of the matched line and surface column=None on
    ## the DAP response.
    gateOnNargo("test_column_noir_vm_line_only_breakpoint_preserved"):
      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = AssertLine, column = 0)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      # `Option::is_none` => key absent OR null; both mean "no column".
      let colNode = bps[0].getOrDefault("column")
      check colNode.isNil or colNode.kind == JNull
      session.continueForward()
      check session.getCurrentLine() == AssertLine
      # Recorder still emits a column even in line-only-breakpoint mode.
      let landedCol = session.getCurrentColumn()
      if landedCol.isSome:
        check landedCol.get() >= 1

  test "test_column_noir_vm_skips_same_line_other_columns":
    ## STRICT — column 45 (`c`); a line-only fallback would (wrongly)
    ## stop at column 9 (`a`).  Without this case a trivially-wrong
    ## implementation that just stores the column without consulting
    ## it on the stop check would pass the first test (column 27
    ## happens to be the second step on line 2 anyway).
    gateOnNargo("test_column_noir_vm_skips_same_line_other_columns"):
      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = MultiStmtLine, column = ColLetC)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      check bps[0].hasKey("column")
      check bps[0]["column"].getInt(0) == ColLetC
      session.continueForward()
      check session.getCurrentLine() == MultiStmtLine
      let afterCol = session.getCurrentColumn()
      check afterCol.isSome
      check afterCol.get() == ColLetC
      discard ColLetA  # documents column 9; suppress unused-warning

when isMainModule:
  discard
