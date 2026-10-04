## test_plat50_column_ops_vm.nim — PLAT-50: the desktop's Alt+click on the
## editor's text (a breakpoint ANCHORED AT A COLUMN, `ui/editor.
## lineActionClickAt` → `DebuggerService.addColumnBreakpoint`) as the shared
## operation both native front-ends run, `HeadlessDebugSession.
## setColumnBreakpoint`, and the point list it keeps:
##
##   * the breakpoint is sent with its column and the replay stops at the
##     step recorded at that column — the second statement of a line, not the
##     first;
##   * it REPLACES the line's breakpoint (one per line, as the desktop's
##     `breakpointTable[path][line]` holds one) and is not a toggle;
##   * the point list carries the column (`PointListEntry.column`), and a
##     toggle on ANOTHER line, a disable and a re-enable keep it — each of
##     them re-sends the file's whole set (DAP's `setBreakpoints` replaces
##     it), which before PLAT-50 dropped every column;
##   * a disabled column breakpoint no longer stops the replay.
##
## No mocks: a real JS program recorded by the real JS recorder (it lands a
## step at every statement, so a line has steps at several columns), a real
## `replay-server`, the real session. Recorder-gated (`recorder_gate`), as
## `test_column_breakpoint_vm.nim` is.

import std/[options, os, osproc, strutils, unittest]

import ../../headless_session
import ../../store/types
import isonim/core/signals
import recorder_gate

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 24

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

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

proc findJsRecorder(): string =
  ## Locate the JS recorder CLI.  Returns the empty string when neither
  ## ``CODETRACER_JS_RECORDER_PATH`` nor a built sibling is found so the
  ## caller can gate the test through ``skipMissingRecorder`` — see
  ## ``recorder_gate.nim`` for why missing-recorder handling is a uniform
  ## skip across these headless_session tests rather than a hard IOError.
  let envPath = getEnv("CODETRACER_JS_RECORDER_PATH", "")
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let candidate = repoRoot() / ".." / "codetracer-js-recorder" /
    "packages" / "cli" / "dist" / "index.js"
  if fileExists(candidate):
    return candidate
  return ""

proc fixtureDir(): string =
  ## Per-process temp directory for the JS source + recorded trace.  We
  ## scope to the pid so concurrent test runs don't stomp each other.
  result = getTempDir() / ("ct_plat50_column_vm_" & $getCurrentProcessId())

proc recordTinyJsTrace(): tuple[tracePath, sourcePath: string;
                                lineCol1: int; lineCol14: int;
                                lineCol28: int; legacyLine: int] =
  ## Record a JS program with two distinct lines:
  ##
  ##   line 1: ``var a = 1; var b = 2; var c = a + b;``  (three statements)
  ##   line 2: ``var d = c * 2;``                          (one statement)
  ##
  ## The recorder lands a step at the start of every statement, so line 1
  ## has three steps at columns 1, 12, and 24 respectively (the recorder
  ## uses 1-indexed columns), and line 2 has a single step at column 1.
  ##
  ## Returns the trace folder and the columns recorded for line 1's
  ## three statements + the line-only legacy target line.
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "program.js"
  # NB: the column positions below are recomputed from the source text;
  # callers should not hard-code them outside this helper.
  const program = "var a = 1; var b = 2; var c = a + b;\nvar d = c * 2;\n"
  writeFile(sourcePath, program)

  # Compute the 1-indexed columns of `var a`, `var b`, `var c` on line 1
  # directly from the source text so the test stays true to the recorder
  # output even if the program string changes.
  let lineOne = program.split('\n')[0]
  let colA = lineOne.find("var a") + 1
  let colB = lineOne.find("var b") + 1
  let colC = lineOne.find("var c") + 1
  doAssert colA == 1
  doAssert colB > colA
  doAssert colC > colB

  let recorder = findJsRecorder()
  let outParent = dir / "rec-out"
  createDir(outParent)
  let (_, code) = execCmdEx(
    "node " & quoteShell(recorder) & " record " & quoteShell(sourcePath) &
    " --out-dir " & quoteShell(outParent))
  doAssert code == 0,
    "JS recorder failed to record " & sourcePath & " (exit " & $code & ")"

  # The recorder writes a `trace-N` subdir; rename to a stable path.
  var traceSubdir = ""
  for kind, path in walkDir(outParent):
    if kind == pcDir and path.lastPathPart.startsWith("trace-"):
      traceSubdir = path
      break
  doAssert traceSubdir.len > 0,
    "JS recorder produced no trace-* directory under " & outParent
  let traceDir = dir / "trace"
  moveDir(traceSubdir, traceDir)

  return (tracePath: traceDir, sourcePath: sourcePath,
          lineCol1: colA, lineCol14: colB, lineCol28: colC,
          legacyLine: 2)

proc breakpointRows(session: HeadlessDebugSession;
                    path: string): seq[PointListEntry] =
  for r in session.session.store.pointList.rows.val:
    if r.kind == PointKindBreakpoint and r.path == path:
      result.add r

suite "PLAT-50: a column breakpoint, the shared operation":

  test "it stops at the column; it replaces the line's; edits keep it":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      let fixture = recordTinyJsTrace()
      var session = newHeadlessDebugSession(fixture.tracePath,
                                            findReplayServer())
      ck session.getCurrentLine() == 1
      ck session.getCurrentColumn() == some(fixture.lineCol1)
      let path = fixture.sourcePath
      # A line breakpoint first: the Alt+click REPLACES it.
      ck session.toggleBreakpoint(path, 1)
      ck session.setColumnBreakpoint(path, 1, fixture.lineCol14)
      var rows = session.breakpointRows(path)
      ck rows.len == 1
      ck rows[0].line == 1 and rows[0].column == fixture.lineCol14
      ck rows[0].enabled
      ck rows[0].label.endsWith(":1:" & $fixture.lineCol14)
      # Not a column: refused, nothing changed.
      ck not session.setColumnBreakpoint(path, 1, 0)
      ck session.breakpointRows(path).len == 1
      # A toggle on ANOTHER line re-sends the file's set: the column stays.
      ck session.toggleBreakpoint(path, fixture.legacyLine)
      rows = session.breakpointRows(path)
      ck rows.len == 2
      for r in rows:
        if r.line == 1: ck r.column == fixture.lineCol14
        else: ck r.column == 0
      # Disabled and enabled again: still anchored.
      ck session.setBreakpointEnabled(path, 1, false)
      for r in session.breakpointRows(path):
        if r.line == 1: ck (not r.enabled) and r.column == fixture.lineCol14
      ck session.setBreakpointEnabled(path, 1, true)
      for r in session.breakpointRows(path):
        if r.line == 1: ck r.enabled and r.column == fixture.lineCol14
      # The replay stops at the anchored column — the SECOND statement of
      # line 1, not the step at its first column it started on.
      session.continueForward()
      ck session.getCurrentLine() == 1
      ck session.getCurrentColumn() == some(fixture.lineCol14)
      session.close()

  test "a disabled column breakpoint does not stop the replay":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      let fixture = recordTinyJsTrace()
      var session = newHeadlessDebugSession(fixture.tracePath,
                                            findReplayServer())
      let path = fixture.sourcePath
      ck session.setColumnBreakpoint(path, 1, fixture.lineCol28)
      ck session.toggleBreakpoint(path, fixture.legacyLine)
      ck session.setBreakpointEnabled(path, 1, false)
      session.continueForward()
      # Past line 1's third statement, onto line 2's breakpoint.
      ck session.getCurrentLine() == fixture.legacyLine
      session.close()

suite "PLAT-50 column ops: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
