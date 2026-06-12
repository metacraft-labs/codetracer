## M3 — Headless ViewModel layer test for formatted-view step-over.
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
##   §M3 Acceptance tests — Headless ViewModel.
##
## What this test proves:
##
##   1. ``headless_session.setActiveSourceView`` installs a srcview V3
##      map under the recorded minified path AND flips the replay-server
##      into formatted-view mode.
##   2. With the formatted view active, ``stepForward`` advances one
##      /formatted line/ at a time even though the underlying recorded
##      steps all sit on the same minified line — proving the runner
##      consults the sourcemap rather than the recorded coordinates.
##   3. Without the formatted view (legacy minified mode), ``stepForward``
##      preserves the M1/M2 line-granularity behaviour: it advances
##      directly past every same-minified-line step to the next minified
##      line.
##   4. With the formatted view active, ``stepOverStatement`` advances
##      one /formatted statement/ at a time — proving M3 composes
##      cleanly with the M2 statement-granularity runner.  The runner
##      treats any change in the formatted (line, column) tuple as a
##      boundary, mirroring M2's minified-side predicate.
##
## Compile + run:
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_formatted_view_step_over_vm.nim
##
## Required environment:
##
##   * ``REPLAY_SERVER_BIN`` — path to a built replay-server binary.
##     Defaults to ``src/db-backend/target/debug/replay-server``.
##   * ``CODETRACER_JS_RECORDER_PATH`` — path to a built JS recorder
##     CLI (``packages/cli/dist/index.js`` in the sibling repo).
##
## Why the test synthesises the srcview rather than recording one:
##
## The JS recorder writes srcviews when its built-in autoformat path
## fires (which requires ``prettier`` on PATH).  Pinning M3 on
## ``prettier`` availability would tie a runner-level contract to an
## external toolchain.  Instead we record a normal column-aware trace
## (no autoformat) and inject a synthetic srcview V3 map at runtime via
## the ``ct/install-source-view`` debug request.  The map projects each
## recorded minified column to a distinct formatted line, exercising
## the exact same code path the production srcviews record would.

import std/[json, options, os, osproc, strutils, unittest]

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

proc findJsRecorder(): string =
  let envPath = getEnv("CODETRACER_JS_RECORDER_PATH", "")
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let candidate = repoRoot() / ".." / "codetracer-js-recorder" /
    "packages" / "cli" / "dist" / "index.js"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "missing JS recorder; set CODETRACER_JS_RECORDER_PATH or build " &
    "the codetracer-js-recorder sibling repo (npm run build)")

proc fixtureDir(): string =
  ## Per-process temp directory for the JS source + recorded trace.
  result = getTempDir() / ("ct_fmt_view_step_over_vm_" & $getCurrentProcessId())

proc recordMinifiedJsTrace(): tuple[tracePath, sourcePath: string;
                                    colS1: int; colS2: int; lineTwo: int] =
  ## Record a JS program with the "two statements on a minified line"
  ## shape the M2 ViewModel test already pins (`var a = 1; var b = 2;`
  ## on line 1, `var c = a + b;` on line 2).  The M3 srcview injected
  ## below projects each recorded (minified) column to a distinct
  ## formatted line, giving us a fixture the formatted-view runner can
  ## meaningfully step through.
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "program.js"
  # NB: same "two-statement on one line" shape as the M2 fixture so the
  # recorder reliably emits a column transition we can pin.  See M2
  # Notes for why three-statement-on-one-line breaks the recorder's
  # column-cursor.
  const program = "var a = 1; var b = 2;\nvar c = a + b;\n"
  writeFile(sourcePath, program)
  let lineOne = program.split('\n')[0]
  let colA = lineOne.find("var a") + 1
  let colB = lineOne.find("var b") + 1
  doAssert colA == 1
  doAssert colB > colA

  let recorder = findJsRecorder()
  let outParent = dir / "rec-out"
  createDir(outParent)
  # `--no-autoformat` keeps the recorder from emitting a srcview (we
  # inject our own synthetic one via `ct/install-source-view` below so
  # the M3 contract is exercised without depending on `prettier` being
  # available in the test environment).
  let (_, code) = execCmdEx(
    "node " & quoteShell(recorder) & " record --no-autoformat " &
    quoteShell(sourcePath) & " --out-dir " & quoteShell(outParent))
  doAssert code == 0,
    "JS recorder failed to record " & sourcePath & " (exit " & $code & ")"

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
          colS1: colA, colS2: colB,
          lineTwo: 2)

# ---------------------------------------------------------------------------
# Synthetic srcview V3 mapping helper
# ---------------------------------------------------------------------------

proc vlqEncode(value: int): string =
  ## V3 VLQ encoding — zigzag-encode signed int, emit base64 6-bit chunks.
  var z: uint = if value < 0:
                  (uint(-value) shl 1) or 1
                else:
                  uint(value) shl 1
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  result = ""
  while true:
    var digit = (z and 0x1F).int
    z = z shr 5
    if z != 0:
      digit = digit or 0x20
    result.add(alphabet[digit])
    if z == 0:
      break

proc segment(buf: var string; genColDelta, srcIdxDelta, srcLineDelta, srcColDelta: int) =
  buf.add(vlqEncode(genColDelta))
  buf.add(vlqEncode(srcIdxDelta))
  buf.add(vlqEncode(srcLineDelta))
  buf.add(vlqEncode(srcColDelta))

proc buildMinifiedToFormattedMapV3(formattedSourceName: string;
                                   colS1, colS2: int;
                                   fmtLine1, fmtLine2: int): string =
  ## Build a Source Map V3 JSON projecting:
  ##   minified (1, colS1) → formatted (fmtLine1, 1)
  ##   minified (1, colS2) → formatted (fmtLine2, 1)
  ##   minified (2, 1)     → formatted (fmtLine2 + 3, 1)
  ##
  ## We deliberately use deltas relative to the previous segment, the
  ## way the V3 spec mandates.  Generated-line transitions are
  ## semicolon-separated; segments on the same generated line are
  ## comma-separated.
  var mappings = ""
  # Generated line 1 — three segments.
  #
  # Segment 0: minified (line 1, col colS1) → formatted (fmtLine1, 1).
  #   gen_col delta = colS1 - 1; src_idx delta = 0;
  #   src_line delta = fmtLine1 - 1; src_col delta = 0.
  segment(mappings, colS1 - 1, 0, fmtLine1 - 1, 0)
  mappings.add(',')
  # Segment 1: minified (line 1, col colS2) → formatted (fmtLine2, 1).
  #   gen_col delta = colS2 - colS1; src_line delta = fmtLine2 - fmtLine1.
  segment(mappings, colS2 - colS1, 0, fmtLine2 - fmtLine1, 0)
  mappings.add(';')
  # Generated line 2 — single segment.  Generated-column delta resets
  # to 0 (always relative to line start); source-line delta is +3 from
  # the previous formatted line.
  segment(mappings, 0, 0, 3, 0)
  result = "{\"version\":3,\"file\":\"program.js\",\"sources\":[\"" &
    formattedSourceName & "\"],\"names\":[],\"mappings\":\"" & mappings & "\"}"

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

const FormattedViewPath = "/tmp/m3-vm-test-formatted-view.fmt.js"
const FmtLine1 = 1
const FmtLine2 = 3

suite "M3 — Formatted-view step-over through the ViewModel":

  test "test_formatted_view_step_over_advances_one_formatted_line":
    ## STRICT: with the formatted srcview active, ``stepForward`` from
    ## ``var a`` (formatted line 1) MUST land at the formatted line
    ## representation of ``var b`` (formatted line 3) — not at the
    ## ``var b`` column on the same minified line.  This is the M3
    ## contract: one formatted line per step under the formatted view.
    let fixture = recordMinifiedJsTrace()
    let replayServer = findReplayServer()
    var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

    # Inject a synthetic srcview V3 map under the recorded minified
    # path.  The map sends minified (1, colS1) → formatted (FmtLine1,1)
    # and minified (1, colS2) → formatted (FmtLine2, 1) so the formatted-
    # view runner has a meaningful per-statement projection to step
    # through.
    let mapJson = buildMinifiedToFormattedMapV3(
      FormattedViewPath,
      fixture.colS1, fixture.colS2,
      FmtLine1, FmtLine2)
    session.installSourceViewForTest(
      recordedPath = fixture.sourcePath,
      formattedViewPath = FormattedViewPath,
      sourcemapV3Json = mapJson)
    session.setActiveSourceView(FormattedViewPath)

    # Sanity — initial position.  The recorder lands on minified line 1
    # column colS1.  The replay-server's stack-frame translation already
    # surfaces the formatted-view coordinates, so the ViewModel store
    # sees formatted line FmtLine1 after activation.
    check session.getCurrentLine() == FmtLine1

    # First formatted-view step.  Without the M3 reverse-mapping the
    # runner would advance from minified (1, colS1) directly to
    # minified line 2 (the M2 line-granularity hop), bypassing the
    # ``var b`` column entirely.  With M3 active the runner must stop
    # at the formatted line that the next-column projection lands on.
    session.stepForward()
    check session.getCurrentLine() == FmtLine2

  test "test_minified_view_step_over_preserves_legacy_line_granularity":
    ## Non-negotiable back-compat: WITHOUT activating the formatted
    ## view, ``stepForward`` MUST behave exactly like M1/M2's
    ## line-granularity runner — advancing past every same-minified-
    ## line column delta directly to the next minified line.  Users
    ## who haven't toggled the formatted view see the legacy behaviour
    ## unchanged.
    let fixture = recordMinifiedJsTrace()
    let replayServer = findReplayServer()
    var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

    check session.getCurrentLine() == 1
    let initialCol = session.getCurrentColumn()
    check initialCol.isSome
    check initialCol.get() == fixture.colS1

    # Legacy step-over: lands directly on minified line 2.
    session.stepForward()
    check session.getCurrentLine() == fixture.lineTwo

  test "test_formatted_view_step_over_statement_composes_with_m2":
    ## STRICT: with the formatted srcview active, ``stepOverStatement``
    ## advances one /formatted statement/ per invocation — i.e. it
    ## stops at the next change in the formatted (line, column) tuple.
    ## On our fixture each minified column maps to a distinct formatted
    ## line, so the first ``stepOverStatement`` from formatted line 1
    ## MUST land at formatted line FmtLine2 (the projected ``var b``).
    ## This pins that M3 composes with M2 — statement granularity under
    ## the formatted view stops at the formatted-side statement
    ## boundary, not at the minified one.
    let fixture = recordMinifiedJsTrace()
    let replayServer = findReplayServer()
    var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

    let mapJson = buildMinifiedToFormattedMapV3(
      FormattedViewPath,
      fixture.colS1, fixture.colS2,
      FmtLine1, FmtLine2)
    session.installSourceViewForTest(
      recordedPath = fixture.sourcePath,
      formattedViewPath = FormattedViewPath,
      sourcemapV3Json = mapJson)
    session.setActiveSourceView(FormattedViewPath)

    check session.getCurrentLine() == FmtLine1
    session.stepOverStatement()
    check session.getCurrentLine() == FmtLine2

when isMainModule:
  discard
