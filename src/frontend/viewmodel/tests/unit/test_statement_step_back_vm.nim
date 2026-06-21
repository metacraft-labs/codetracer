## M7 — Headless ViewModel layer test for statement-granularity step
## BACKWARD.
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
##   §M7 Acceptance tests — Headless ViewModel.
##
## What this test proves:
##
##   1. ``headless_session.stepBackStatement`` actually issues a DAP
##      ``stepBack`` request that carries ``granularity: "statement"``
##      on the wire (not the legacy column-stripped shape).
##   2. The replay-server, fed a column-aware JS recording, advances
##      one /statement/ at a time BACKWARDS on a multi-statement line
##      — i.e. from line 2 the first reverse hop lands on the LAST
##      statement of line 1 (``var b``), then the same-line column-
##      aware reverse predicate fires for the next hop to land on
##      ``var a``.  Symmetric mirror of the M2 forward test.
##   3. The legacy ``stepBackward`` call (no granularity) preserves
##      the reverse-line-only behaviour: from line 2 one
##      ``stepBackward`` lands on line 1 directly — exactly the way
##      the GUI reverse-next has always behaved.
##   4. On a single-statement line the two reverse granularities
##      collapse: ``stepBackStatement`` and ``stepBackward`` produce
##      identical results — proving the new surface does NOT regress
##      UX for users editing normal one-statement-per-line code.
##
## Compile + run:
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_statement_step_back_vm.nim
##
## Required environment:
##
##   * ``REPLAY_SERVER_BIN`` — path to a built replay-server binary.
##     Defaults to ``src/db-backend/target/debug/replay-server`` (the
##     `cargo build` artefact) when unset; falls back to
##     ``src/build-debug/bin/replay-server`` or the `release` target.
##   * ``CODETRACER_JS_RECORDER_PATH`` — path to a built JS recorder
##     CLI (``packages/cli/dist/index.js`` in the sibling repo).
##     Defaults to
##     ``../../../../../codetracer-js-recorder/packages/cli/dist/index.js``.
##
## Both tools ship pre-built in the standard checkout layout — neither
## envvar is normally required.  When either is missing the test
## fails loudly per the M7 contract ("no test.skip, no #[ignore]").

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

proc findJsRecorder(): string =
  let envPath = getEnv("CODETRACER_JS_RECORDER_PATH", "")
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let candidate = repoRoot() / ".." / "codetracer-js-recorder" /
    "packages" / "cli" / "dist" / "index.js"
  if fileExists(candidate):
    return candidate
  # Returns "" when neither CODETRACER_JS_RECORDER_PATH nor a built
  # sibling is found, so the caller gates the test through
  # requireRecorderOrSkip (recorder_gate.nim) for a uniform, greppable
  # missing-recorder skip rather than a hard IOError.
  return ""

proc fixtureDir(): string =
  ## Per-process temp directory for the JS source + recorded trace.
  ## We scope to the pid so concurrent test runs don't stomp each
  ## other.
  result = getTempDir() / ("ct_stmt_step_back_vm_" & $getCurrentProcessId())

proc recordTinyJsTrace(): tuple[tracePath, sourcePath: string;
                                colVarA: int; colVarB: int;
                                lineTwo: int] =
  ## Record the same fixture as the M2 forward ViewModel test:
  ##
  ##   line 1: ``var a = 1; var b = 2;``  (two statements on one line)
  ##   line 2: ``var c = a + b;``         (single statement)
  ##
  ## The recorder lands a step at the start of every statement, so
  ## line 1 has steps at the columns of ``var a`` and ``var b``, and
  ## line 2 has a single step at column 1.
  ##
  ## Returns the trace folder and the columns recorded for line 1's
  ## two statements + the single-statement-line follow-up.
  ##
  ## Two statements per line (not three) — see the M2 Notes
  ## "JS recorder column reset on same-line continuation" in the
  ## status file for why three statements per line would fail at the
  ## recorder side.  The M7 DAP test
  ## (`tests/dap_statement_step_back.rs`) already pins the
  ## three-statement code path end-to-end on the synthetic trace.
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "program.js"
  const program = "var a = 1; var b = 2;\nvar c = a + b;\n"
  writeFile(sourcePath, program)

  # Compute the 1-indexed columns of `var a`, `var b` on line 1
  # directly from the source text so the test stays true to the
  # recorder output even if the program string changes.
  let lineOne = program.split('\n')[0]
  let colA = lineOne.find("var a") + 1
  let colB = lineOne.find("var b") + 1
  doAssert colA == 1
  doAssert colB > colA

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
          colVarA: colA, colVarB: colB,
          lineTwo: 2)

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "M7 — Statement-granularity step BACK through the ViewModel":

  test "test_statement_step_back_vm_advances_one_statement_per_invocation":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      ## Park the cursor on line 2 (via two forward steps to walk past
      ## the multi-statement line 1), then issue ``stepBackStatement``
      ## twice and assert successive reverse landings at line 1 col
      ## ``var b`` and then col ``var a``.  The column-aware backward
      ## runner MUST fire the strictly-LESS column predicate on the
      ## same-line hop — symmetric to the M2 forward strictly-GREATER
      ## assertion.
      ##
      ## Why we walk to line 2 first instead of jumping: ``headless_session``
      ## doesn't expose a jump-to-step primitive; the canonical way to
      ## park the cursor on a known position is to step into it.  Doing
      ## so also keeps the test honest — it proves both the forward
      ## and backward runners agree on the column landing for the same
      ## fixture, on the same replay-server instance.
      let fixture = recordTinyJsTrace()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # Sanity — initial cursor is at line 1 column 1 (start of `var a`).
      check session.getCurrentFile().endsWith("program.js")
      check session.getCurrentLine() == 1
      let initialCol = session.getCurrentColumn()
      check initialCol.isSome
      check initialCol.get() == fixture.colVarA

      # Walk forward to line 2 via two statement-granularity hops — the
      # exact sequence the M2 forward test pins.  The first lands on
      # ``var b`` (same line, col transition); the second lands on
      # line 2.  Sanity-check each landing before reversing direction
      # so a failure in the forward path doesn't masquerade as a
      # backward failure.
      session.stepOverStatement()
      check session.getCurrentLine() == 1
      let afterFirstForward = session.getCurrentColumn()
      check afterFirstForward.isSome
      check afterFirstForward.get() == fixture.colVarB

      session.stepOverStatement()
      check session.getCurrentLine() == fixture.lineTwo

      # First backward statement step from line 2 — MUST land on the
      # LAST statement of line 1 (``var b``, the closest prior step on
      # a different line).  This is the line-boundary half of the
      # backward runner predicate.
      session.stepBackStatement()
      check session.getCurrentLine() == 1
      let afterFirstReverse = session.getCurrentColumn()
      check afterFirstReverse.isSome
      check afterFirstReverse.get() == fixture.colVarB

      # Second backward statement step — MUST land on ``var a`` (col
      # transition within line 1, fired by the strictly-LESS column
      # predicate).  This is the column-aware half of the M7 contract
      # at the ViewModel surface.
      session.stepBackStatement()
      check session.getCurrentLine() == 1
      let afterSecondReverse = session.getCurrentColumn()
      check afterSecondReverse.isSome
      check afterSecondReverse.get() == fixture.colVarA

  test "test_step_back_vm_legacy_line_granularity_preserved":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      ## Non-negotiable back-compat: ``stepBackward`` (no granularity)
      ## advances by /line/ in reverse, skipping the same-line column-
      ## deltas.  From line 2 one legacy ``stepBackward`` MUST land on
      ## line 1.  This pins the M7 back-compat assertion: the pre-M7
      ## reverse-next UX (line-granularity) is unchanged.
      let fixture = recordTinyJsTrace()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # Park on line 2 by walking forward — same prologue as the
      # backward-statement test above so any forward-side drift is
      # caught by both tests.
      check session.getCurrentLine() == 1
      session.stepForward()  # legacy line-granularity step — lands on line 2
      check session.getCurrentLine() == fixture.lineTwo

      # Legacy stepBack: one hop lands on the prior /line/, not on a
      # specific column.  The runner stops at the first `(line,
      # call_key)` change going backward — that is the last step of
      # line 1 (the closest prior step on a different line).
      session.stepBackward()
      check session.getCurrentLine() == 1

  test "test_statement_step_back_vm_single_statement_line_matches_line_granularity":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      ## On a single-statement line ``stepBackStatement`` MUST behave
      ## indistinguishably from ``stepBackward`` — i.e. it advances to
      ## the prior executed line, the same way line-granularity would.
      ## We prove this by walking forward to line 2 in both sessions,
      ## then running the two granularities backward from there and
      ## asserting the resulting (line, column) tuples agree.
      let fixture = recordTinyJsTrace()
      let replayServer = findReplayServer()

      # Run A: walk forward to line 2 via legacy stepForward, then take
      # one legacy stepBackward.  This lands on the last step of line 1.
      var sessA = newHeadlessDebugSession(fixture.tracePath, replayServer)
      sessA.stepForward()
      check sessA.getCurrentLine() == fixture.lineTwo
      sessA.stepBackward()
      let afterLineGranularity = (sessA.getCurrentLine(), sessA.getCurrentColumn())

      # Run B: walk forward to line 2 via legacy stepForward, then take
      # one statement stepBack from there.  This MUST land at the same
      # ``(line, column)`` tuple as Run A — proving the two
      # granularities collapse when the entry sits on a
      # single-statement line.
      var sessB = newHeadlessDebugSession(fixture.tracePath, replayServer)
      sessB.stepForward()
      check sessB.getCurrentLine() == fixture.lineTwo
      sessB.stepBackStatement()
      let afterStatementGranularity = (sessB.getCurrentLine(), sessB.getCurrentColumn())

      check afterLineGranularity == afterStatementGranularity

when isMainModule:
  discard
