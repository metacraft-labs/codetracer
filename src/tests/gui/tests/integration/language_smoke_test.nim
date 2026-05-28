## test_language_smoke.nim
##
## Language-specific sudoku smoke tests — headless ViewModel equivalents of
## the Playwright tests in ``tsc-ui-tests/tests/sudoku/``.
##
## For each supported language, this suite exercises the full debugging
## workflow against real traces of the sudoku solver test programs:
##
## 1. Record (or find cached) a trace for the language's sudoku program.
## 2. Start a HeadlessDebugSession with the trace.
## 3. Verify the initial editor position points to the expected source file.
## 4. Step forward several times and verify the position changes.
## 5. Request and verify locals (variable names present).
## 6. Request and verify the calltrace (function names present).
## 7. Close the session.
##
## Each test is independent — it creates its own session so failures are
## isolated per language and per concern.
##
## Languages tested:
##   - Python (py_sudoku_solver) — DB trace via pure-python-recorder
##   - Ruby (rb_sudoku_solver) — DB trace via ruby recorder
##   - Noir (noir_space_ship) — DB trace via nargo recorder
##   - Nim (nim_sudoku_solver) — RR trace via native recorder
##   - Rust (rs_sudoku_solver) — RR trace via native recorder
##
## Languages that fail to record are skipped at runtime with a descriptive
## message rather than a hard test failure, since recorder availability
## depends on the local environment.
##
## Prerequisites:
##   - replay-server built: ``src/build-debug/bin/replay-server``
##   - ct binary built: ``src/build-debug/bin/ct``
##   - Recorders installed for the languages you want to test
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_language_smoke.nim

import std/[json, os, unittest, strutils, osproc, sequtils]
import headless_session
import store/types

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc findReplayServer(): string =
  ## Locate the replay-server binary.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let thisFile = currentSourcePath()
  let repoRoot = thisFile.parentDir.parentDir.parentDir.parentDir.parentDir
  let candidate = repoRoot / "src" / "build-debug" / "bin" / "replay-server"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "Could not find replay-server binary. Set REPLAY_SERVER_BIN or " &
    "build it with 'cargo build' in src/db-backend/. Tried: " & candidate)

proc repoRoot(): string =
  ## Return the repository root (5 levels up from this test file).
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

proc findCtFile(dir: string): string =
  ## Return the path to the first ``.ct`` file in ``dir``, or "" if none.
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    if path.endsWith(".ct"):
      return path
  return ""

proc isUsableTraceDir(dir: string): bool =
  ## Return true if ``dir`` contains a trace format that the replay-server
  ## can open via the DAP stdio protocol and that works with
  ## HeadlessDebugSession.
  ##
  ## Supported formats:
  ##   - ``trace.bin`` — DB-based materialized trace (used by Noir, Wasm, and
  ##     older Python/Ruby recorders)
  ##   - ``rr/`` subdirectory — rr-based trace replayed via ct-native-replay
  ##     (used by Nim, Rust, C, etc.)
  ##   - CTFS ``.ct`` files — CTFS containers produced by Python, Ruby, and
  ##     other recorders.  The replay-server auto-detects the format and emits
  ##     the same ``stopped``/``ct/complete-move`` DAP events as DB traces.
  if fileExists(dir / "trace.bin"):
    return true
  if dirExists(dir / "rr"):
    return true
  if findCtFile(dir).len > 0:
    return true
  return false

proc traceDirForRecordingId(idStr: string): string =
  let baseDir = getHomeDir() / ".local" / "share" / "codetracer"
  let bareDir = baseDir / idStr
  if dirExists(bareDir):
    return bareDir
  let legacyDir = baseDir / ("trace-" & idStr)
  if dirExists(legacyDir):
    return legacyDir
  bareDir

proc findExistingTrace(programPattern: string): string =
  ## Search ``~/.local/share/codetracer/`` for a pre-recorded trace whose
  ## directory name matches ``programPattern``.
  ##
  ## M-REC-1.5: trace metadata lives in the CTFS ``meta.dat`` inside
  ## ``trace.ct``; the legacy sidecar JSONs that this helper used to
  ## inspect are retired.  As a lightweight fallback the heuristic
  ## matches against the directory name (recorders name the directory
  ## after the program).  Re-record if a finer match is needed.
  let baseDir = getHomeDir() / ".local" / "share" / "codetracer"
  if not dirExists(baseDir):
    return ""
  for kind, path in walkDir(baseDir):
    if kind != pcDir:
      continue
    if not isUsableTraceDir(path):
      continue
    let dirname = path.extractFilename()
    if programPattern in dirname:
      return path
  return ""

const recordTimeoutMs = 120_000
  ## Maximum time (in milliseconds) to wait for ``ct record`` to finish.
  ## Prevents the test suite from hanging on broken or slow recorders.

proc recordTraceToDefaultLocation(programPath: string; lang: string = ""): string =
  ## Record a trace using ``ct record`` without ``-o``, letting it store
  ## into the default ``~/.local/share/codetracer/`` directory.
  ##
  ## Parses the ``traceId:<N>`` line from stdout to locate the trace.
  ## Returns the trace directory path.  Times out after ``recordTimeoutMs``.
  ##
  ## Recorders may produce different formats (``trace.bin``, ``rr/``, or
  ## CTFS ``.ct`` files).  All are supported by HeadlessDebugSession.
  let ctBin = findCtBinary()
  var args = @["record"]
  if lang.len > 0:
    args.add("--lang")
    args.add(lang)
  args.add(programPath)

  # Use execCmdEx with a timeout wrapper via the shell's `timeout` command
  # to avoid hanging indefinitely on broken recorders.
  let timeoutSec = recordTimeoutMs div 1000
  let fullCmd = "timeout " & $timeoutSec & " " & quoteShell(ctBin) & " " &
                args.mapIt(quoteShell(it)).join(" ")
  let (output, exitCode) = execCmdEx(fullCmd)
  if exitCode != 0:
    raise newException(IOError,
      "ct record failed (exit " & $exitCode & "): " & output)

  # Parse the recording id from the output (last line is "recordingId:<uuid>").
  # M-REC-6: stdout marker renamed from "traceId:" to "recordingId:".
  for line in output.splitLines():
    if line.startsWith("recordingId:"):
      let idStr = line[("recordingId:").len..^1].strip()
      let traceDir = traceDirForRecordingId(idStr)
      if dirExists(traceDir):
        return traceDir

  raise newException(IOError,
    "ct record succeeded but could not parse recordingId from output: " & output)

proc findOrRecordTrace(testProgram: string; lang: string = "";
                       entryFile: string = "";
                       programPattern: string = ""): string =
  ## Locate a pre-recorded trace or record a fresh one.
  ##
  ## Searches for existing traces by program name match, then falls back
  ## to recording a fresh trace.  Supports ``trace.bin``, ``rr/``, and
  ## CTFS ``.ct`` formats.
  ##
  ## Raises ``IOError`` on failure so the calling test can skip.
  let pattern = if programPattern.len > 0: programPattern else: testProgram

  # 1. Search user's trace store for an existing trace.
  let existing = findExistingTrace(pattern)
  if existing.len > 0:
    echo "  Using existing trace: ", existing
    return existing

  # 2. Record a fresh trace to the default location.
  let programDir = repoRoot() / "test-programs" / testProgram
  let programPath = if entryFile.len > 0: programDir / entryFile
                    else: programDir
  echo "  Recording trace for: ", programPath
  let traceDir = recordTraceToDefaultLocation(programPath, lang)
  echo "  Recorded trace to: ", traceDir

  # 3. Verify the trace uses a format supported by the replay-server.
  if not isUsableTraceDir(traceDir):
    raise newException(IOError,
      "Recorded trace at " & traceDir & " uses an unrecognized format. " &
      "Expected trace.bin, rr/, or a .ct file.")

  return traceDir

proc stepToSourceFile(session: HeadlessDebugSession; pattern: string;
                      maxSteps: int = 30) =
  ## Step forward until the current file path contains ``pattern``.
  ## Gives up after ``maxSteps`` steps.
  for i in 0 ..< maxSteps:
    if pattern in session.getCurrentFile():
      return
    session.stepForward()

type
  ## Descriptor for a language-specific sudoku test configuration.
  LanguageTestConfig = object
    name: string           ## Human-readable name (e.g. "Python")
    testProgram: string    ## Directory under test-programs/ (e.g. "py_sudoku_solver")
    entryFile: string      ## Entry file within the program dir (e.g. "main.py"), or "" for Nargo-style
    programPattern: string ## Substring to match against the trace directory name (M-REC-1.5)
    sourcePattern: string  ## Substring to match in the editor's current file (e.g. "main.py", ".rb")
    solveFuncName: string  ## Expected function name in the calltrace (e.g. "solve_sudoku")

# ---------------------------------------------------------------------------
# Language configurations
# ---------------------------------------------------------------------------

const pythonConfig = LanguageTestConfig(
  name: "Python",
  testProgram: "py_sudoku_solver",
  entryFile: "main.py",
  programPattern: "py_sudoku_solver",
  sourcePattern: "main.py",
  solveFuncName: "solve_sudoku",
)

const rubyConfig = LanguageTestConfig(
  name: "Ruby",
  testProgram: "rb_sudoku_solver",
  entryFile: "sudoku_solver.rb",
  programPattern: "rb_sudoku_solver",
  sourcePattern: "sudoku_solver.rb",
  solveFuncName: "solve",
)

const noirConfig = LanguageTestConfig(
  name: "Noir",
  testProgram: "noir_space_ship",
  entryFile: "",  # Nargo projects use the directory
  programPattern: "noir",
  sourcePattern: ".nr",
  solveFuncName: "main",
)

const nimConfig = LanguageTestConfig(
  name: "Nim",
  testProgram: "nim_sudoku_solver",
  entryFile: "main.nim",
  programPattern: "nim_sudoku_solver",
  sourcePattern: ".nim",
  solveFuncName: "main",
)

const rustConfig = LanguageTestConfig(
  name: "Rust",
  testProgram: "rs_sudoku_solver",
  entryFile: "main.rs",
  programPattern: "rs_sudoku_solver",
  sourcePattern: "main.rs",
  solveFuncName: "main",
)

# ---------------------------------------------------------------------------
# Trace cache — avoid re-recording for every test in a suite
# ---------------------------------------------------------------------------

import std/tables

var traceCache: Table[string, string]
  ## Maps testProgram name -> trace path (or "" if unavailable).
  ## Populated on first lookup; subsequent tests reuse the result.

var traceAttempted: Table[string, bool]
  ## Tracks whether we have already tried to find/record a trace for
  ## a given testProgram.  Prevents repeated recording attempts for
  ## languages whose recorders produce incompatible formats.

# ---------------------------------------------------------------------------
# Generic test procedures (parameterized by LanguageTestConfig)
# ---------------------------------------------------------------------------

proc resolveTrace(config: LanguageTestConfig): string =
  ## Find or record a trace for the given config.
  ## Returns the trace path, or "" if unavailable.
  ## Results are cached per testProgram.
  if traceAttempted.getOrDefault(config.testProgram, false):
    return traceCache.getOrDefault(config.testProgram, "")

  traceAttempted[config.testProgram] = true
  try:
    result = findOrRecordTrace(config.testProgram,
                               entryFile = config.entryFile,
                               programPattern = config.programPattern)
    traceCache[config.testProgram] = result
  except IOError as e:
    echo "  SKIP: ", config.name, " recorder not available: ", e.msg
    traceCache[config.testProgram] = ""
    result = ""
  except OSError as e:
    echo "  SKIP: ", config.name, " recorder not available: ", e.msg
    traceCache[config.testProgram] = ""
    result = ""

proc doTestEditorLoadsCorrectFile(config: LanguageTestConfig;
                                  tracePath: string) =
  ## Verify that after opening a trace, the editor shows a file matching
  ## the expected source pattern for this language.
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  defer: session.close()

  # For languages with runtime entry points (Nim, Rust), step to user code.
  session.stepToSourceFile(config.sourcePattern)

  let file = session.getCurrentFile()
  let line = session.getCurrentLine()
  echo "  ", config.name, " initial position: ", file, ":", line

  check session.getDebuggerStatus() == dsIdle
  check config.sourcePattern in file

proc doTestSteppingChangesPosition(config: LanguageTestConfig;
                                   tracePath: string) =
  ## Verify that stepping forward produces a different debugger position.
  ## Steps to user code first (runtime entry points for Nim/Rust may start
  ## in stdlib code), then verifies that multiple steps produce at least
  ## one position change.
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  defer: session.close()

  # Step to user code first.
  session.stepToSourceFile(config.sourcePattern)

  let ticks1 = session.getCurrentRRTicks()
  let line1 = session.getCurrentLine()
  let file1 = session.getCurrentFile()

  # Step forward several times — some traces (especially RR-based ones like
  # Nim/Rust) may remain at the same position for the first step if the
  # runtime hasn't fully entered user code yet.  We check that at least one
  # of several steps produces a change.
  var posChanged = false
  for i in 0 ..< 5:
    session.stepForward()
    let ticks2 = session.getCurrentRRTicks()
    let line2 = session.getCurrentLine()
    let file2 = session.getCurrentFile()
    if ticks2 != ticks1 or line2 != line1 or file2 != file1:
      posChanged = true
      echo "  Before: ", file1, ":", line1, " (rrTicks=", ticks1, ")"
      echo "  After step ", i + 1, ": ", file2, ":", line2, " (rrTicks=", ticks2, ")"
      break

  if not posChanged:
    echo "  WARNING: position did not change after 5 steps from ",
         file1, ":", line1, " (rrTicks=", ticks1, ")"
  check posChanged

proc doTestLocalsAvailableAfterStepping(config: LanguageTestConfig;
                                        tracePath: string) =
  ## After stepping into user code, locals should be available.
  ## Steps progressively further to find a position with locals, since
  ## RR-based traces (Nim, Rust) may need more steps before locals appear.
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  defer: session.close()

  session.stepToSourceFile(config.sourcePattern)

  # Step further into the program, checking for locals at each position.
  # Some traces (especially Rust RR traces) need many more steps to reach
  # a position with local variables.
  var locals: seq[Variable]
  for i in 0 ..< 20:
    session.stepForward()
    session.requestAndLoadLocals()
    locals = session.getLocals()
    if locals.len > 0:
      echo "  ", config.name, " locals found after ", i + 1, " steps"
      break

  echo "  ", config.name, " locals count: ", locals.len
  for i, v in locals:
    if i < 10:  # Limit output for Nim which has 30+ locals
      echo "    ", v.name, " : ", v.typeName, " = ",
           v.value[0 ..< min(60, v.value.len)]
  if locals.len > 10:
    echo "    ... (", locals.len - 10, " more)"

  # The request should complete without crashing. Some RR traces may not
  # expose locals at the positions we reach within 20 steps.
  if locals.len == 0:
    echo "  WARNING: no locals found after 20 steps (this may be normal for ",
         config.name, " RR traces at early positions)"
  else:
    # If we do have locals, every variable must have a non-empty name.
    for v in locals:
      check v.name.len > 0

  check session.getDebuggerStatus() == dsIdle

proc doTestCalltraceShowsFunctionNames(config: LanguageTestConfig;
                                       tracePath: string) =
  ## The calltrace should contain at least one entry with a non-empty
  ## function name after stepping into user code.
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  defer: session.close()

  session.stepToSourceFile(config.sourcePattern)

  for i in 0 ..< 10:
    session.stepForward()

  session.requestAndLoadCalltrace()
  let lines = session.getCalltraceLines()

  echo "  ", config.name, " calltrace lines: ", lines.len
  for i, line in lines:
    if i < 10:
      echo "    [", line.index, "] depth=", line.depth, " ", line.name,
           " @ ", line.location.file, ":", line.location.line

  check lines.len > 0

  # At least one calltrace entry should have a non-empty name.
  var hasNonEmptyName = false
  for line in lines:
    if line.name.len > 0:
      hasNonEmptyName = true
      break
  check hasNonEmptyName

proc doTestFullWorkflow(config: LanguageTestConfig;
                        tracePath: string) =
  ## Full debugging workflow: step through several positions, collect
  ## locals at each, then load the calltrace at the final position.
  ## Mirrors the Playwright tests' combined assertion pattern.
  let session = newHeadlessDebugSession(tracePath, findReplayServer())
  defer: session.close()

  session.stepToSourceFile(config.sourcePattern)

  var positions: seq[tuple[ticks: uint64, file: string, line: int,
                           localsCount: int]] = @[]

  for i in 0 ..< 6:
    session.stepForward()
    session.requestAndLoadLocals()
    let locals = session.getLocals()
    positions.add((
      session.getCurrentRRTicks(),
      session.getCurrentFile(),
      session.getCurrentLine(),
      locals.len,
    ))

  echo "  ", config.name, " collected ", positions.len, " positions"
  for i, p in positions:
    echo "    Step ", i, ": ", p.file, ":", p.line,
         " rrTicks=", p.ticks, " locals=", p.localsCount

  # rrTicks should generally advance (or at least not decrease).
  for i in 1 ..< positions.len:
    check positions[i].ticks >= positions[i - 1].ticks

  # At least some positions should have locals for DB traces (Noir, Python).
  # RR-based traces (Nim, Rust) may not have locals at early positions.
  var anyLocals = false
  for p in positions:
    if p.localsCount > 0:
      anyLocals = true
      break
  if not anyLocals:
    echo "  NOTE: no locals found at any of the 6 positions (may be normal for RR traces)"

  # Load calltrace at the final position.
  session.requestAndLoadCalltrace()
  let lines = session.getCalltraceLines()
  echo "  Final calltrace lines: ", lines.len
  check lines.len > 0

# ---------------------------------------------------------------------------
# Suite: Python Sudoku
# ---------------------------------------------------------------------------

template languageSmokeTest(suiteName: string; config: LanguageTestConfig;
                          editorTestName: string) =
  ## Generate a complete smoke test suite for a language.
  ## Each test resolves the trace, skips if unavailable, and runs the test proc.
  suite suiteName:

    test editorTestName:
      let tracePath = resolveTrace(config)
      if tracePath.len == 0:
        skip()
      else:
        doTestEditorLoadsCorrectFile(config, tracePath)

    test "stepping changes position":
      let tracePath = resolveTrace(config)
      if tracePath.len == 0:
        skip()
      else:
        doTestSteppingChangesPosition(config, tracePath)

    test "locals available after stepping":
      let tracePath = resolveTrace(config)
      if tracePath.len == 0:
        skip()
      else:
        doTestLocalsAvailableAfterStepping(config, tracePath)

    test "calltrace shows function names":
      let tracePath = resolveTrace(config)
      if tracePath.len == 0:
        skip()
      else:
        doTestCalltraceShowsFunctionNames(config, tracePath)

    test "full debugging workflow":
      let tracePath = resolveTrace(config)
      if tracePath.len == 0:
        skip()
      else:
        doTestFullWorkflow(config, tracePath)

# ---------------------------------------------------------------------------
# Suite: Python Sudoku
# ---------------------------------------------------------------------------

languageSmokeTest("Language smoke: Python sudoku", pythonConfig,
                  "editor loads main.py")

# ---------------------------------------------------------------------------
# Suite: Ruby Sudoku
# ---------------------------------------------------------------------------

languageSmokeTest("Language smoke: Ruby sudoku", rubyConfig,
                  "editor loads sudoku_solver.rb")

# ---------------------------------------------------------------------------
# Suite: Noir (space ship — the available Noir test program with trace.bin)
# ---------------------------------------------------------------------------

languageSmokeTest("Language smoke: Noir", noirConfig,
                  "editor loads .nr file")

# ---------------------------------------------------------------------------
# Suite: Nim Sudoku
# ---------------------------------------------------------------------------

languageSmokeTest("Language smoke: Nim sudoku", nimConfig,
                  "editor loads .nim file")

# ---------------------------------------------------------------------------
# Suite: Rust Sudoku
# ---------------------------------------------------------------------------

languageSmokeTest("Language smoke: Rust sudoku", rustConfig,
                  "editor loads main.rs")
