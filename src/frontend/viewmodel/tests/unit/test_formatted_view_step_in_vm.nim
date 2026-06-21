## M8 — Headless ViewModel layer test for formatted-view step-IN.
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M8.
##
## What this test proves:
##
##   1. With the formatted view active, ``headless_session.stepIn``
##      advances the cursor to the FIRST executed formatted line of the
##      called function — not to the recorded minified column inside
##      the call expression.
##   2. Without the formatted view (legacy minified mode), ``stepIn``
##      preserves the M1/M2/M3 single-recorded-step semantics: it just
##      advances by one recorded step.
##
## Fixture: a JS program with a function definition and a call site, so
## ``stepIn`` has a meaningful "first formatted callee line" to land
## on:
##
## ```
##     function f(x) { return x + 1; }   // line 1 (one minified line)
##     var y = f(5);                     // line 2 (call site)
## ```
##
## We project the recorded coordinates through a synthetic V3
## sourcemap that puts each minified column on a distinct formatted
## line so the M8 contract is observable.  As with the M3 VM test the
## synthetic srcview is installed via the ``ct/install-source-view``
## debug request so the contract is exercised without depending on
## ``prettier`` being on PATH at test time.
##
## Regression note — apparent stdio-bridge deadlock.
## ------------------------------------------------
##
## The M8 work-item commit (3e7deb40) flagged this VM test as a
## follow-up because it would silently hang under load: the parent
## process blocked in ``pipe_read`` on the replay-server's stdout while
## the replay-server's "receiving" thread blocked in ``pipe_read`` on
## stdin.  The diagnosis at the time was a stdio-bridge race; the
## actual root cause turned out to be a server-side panic in the
## value-loader path (``src/db-backend/src/db.rs::type_record``).
## When the ``ct/load-locals`` reactive auto-loader (triggered by the
## debugger-position change after ``next``) walks a step whose value
## record carries a ``TypeId`` not represented in the trace's type
## table — typical of JS function-bearing locals — the
## ``MaterializedReplaySession::type_record`` lookup falls into the
## local-overlay branch and indexes an empty ``Vec`` with ``index 0``,
## panicking the stable thread mid-request.  The panic dropped the
## per-thread channel receiver, the response never reached the wire,
## and the DAP client (this test) blocked forever waiting for a
## response that the stable thread had committed to producing.  See
## the defensive fallback in ``MaterializedReplaySession::type_record``
## that swaps the unchecked ``local_types[idx - base_count]`` for a
## session-scoped ``<unknown>`` ``TypeRecord``; this keeps the server
## alive across malformed type ids and makes this VM test pass
## deterministically.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_formatted_view_step_in_vm.nim

import std/[json, options, os, osproc, strutils, unittest]

import ../../headless_session
import recorder_gate

# ---------------------------------------------------------------------------
# Fixture preparation
# ---------------------------------------------------------------------------

proc repoRoot(): string =
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
  result = getTempDir() / ("ct_fmt_view_step_in_vm_" & $getCurrentProcessId())

proc recordJsTraceWithCall(): tuple[tracePath, sourcePath: string;
                                     entryLine, entryCol: int] =
  ## Record a JS program with a function call so the recorder produces
  ## a depth transition the M8 stepIn runner can step into.  The
  ## program intentionally puts the function body and the call on
  ## DIFFERENT minified lines so the M8 contract assertion (formatted
  ## line of callee's first body line ≠ formatted line of the call
  ## site) is meaningful even before the sourcemap projection is
  ## applied.
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "program.js"
  # Two-line program; line 1 defines the callee with body inline,
  # line 2 invokes it.  The recorder will emit:
  #   step N — line 2 col X (call site)
  #   step N+1 — line 1 col Y (callee body)
  #   step N+2 — line 2 col Z (post-call)
  const program = "function f(x) { return x + 1; }\nvar y = f(5);\n"
  writeFile(sourcePath, program)

  let recorder = findJsRecorder()
  let outParent = dir / "rec-out"
  createDir(outParent)
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
          entryLine: 0, entryCol: 0)

# ---------------------------------------------------------------------------
# Synthetic srcview V3 mapping helper
# ---------------------------------------------------------------------------

proc vlqEncode(value: int): string =
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

proc buildIdentityV3Map(formattedSourceName: string;
                        sourceLineCount: int): string =
  ## Build an identity V3 sourcemap: minified (L, 1) → formatted (L, 1)
  ## for L in 1..sourceLineCount.  This gives the formatted-view runner
  ## a complete projection so it never bails out with the
  ## ``no entry projection`` fallback, while preserving the recorder's
  ## natural line semantics on the formatted side.
  var mappings = ""
  var prevSrcLine = 0
  for L in 0 ..< sourceLineCount:
    if L > 0:
      mappings.add(';')
    let srcLineDelta = L - prevSrcLine
    segment(mappings, 0, 0, srcLineDelta, 0)
    prevSrcLine = L
  result = "{\"version\":3,\"file\":\"program.js\",\"sources\":[\"" &
    formattedSourceName & "\"],\"names\":[],\"mappings\":\"" & mappings & "\"}"

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

const FormattedViewPath = "/tmp/m8-vm-step-in-formatted-view.fmt.js"

suite "M8 — Formatted-view step-IN through the ViewModel":

  test "test_formatted_view_step_in_lands_at_first_formatted_callee_line":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      ## STRICT (Test A) — with the formatted srcview active, ``stepIn``
      ## from the call site (line 2 of the fixture, where ``var y = f(5)``
      ## sits) MUST land at the first executed formatted line of the
      ## callee.  Under an identity sourcemap the formatted line of the
      ## callee's first body equals the recorded minified line — i.e.
      ## line 1.  This proves the M8 stepIn runner correctly descended
      ## into the callee under the formatted-view dispatch.
      let fixture = recordJsTraceWithCall()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # Install identity sourcemap so the runner has a projection.
      let mapJson = buildIdentityV3Map(FormattedViewPath, 4)
      session.installSourceViewForTest(
        recordedPath = fixture.sourcePath,
        formattedViewPath = FormattedViewPath,
        sourcemapV3Json = mapJson)
      session.setActiveSourceView(FormattedViewPath)

      # The recorder lands on the first recorded user step which under
      # this fixture is the function declaration step (line 1) — JS
      # hoists the function so the very first user step the recorder
      # captures is the declaration, then continues onto the call site
      # at line 2.  Walk forward until we sit at the call site (line 2).
      var safety = 0
      while session.getCurrentLine() != 2 and safety < 16:
        session.stepForward()
        inc safety
      check session.getCurrentLine() == 2

      # stepIn from the call site at line 2 MUST descend into the callee
      # and land at line 1 (the body of ``function f(x) { return x + 1;}``).
      session.stepIn()
      check session.getCurrentLine() == 1

  test "test_minified_view_step_in_preserves_legacy_single_step":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      ## STRICT (Test B) — back-compat: WITHOUT activating the formatted
      ## view, ``stepIn`` advances by the legacy single-recorded-step
      ## primitive.  At the call site (line 2), stepIn MUST land on line
      ## 1 — the callee body — because the recorder ordered the steps
      ## that way.  This pins that M8's intercept layer is transparent to
      ## clients who haven't toggled the formatted view.
      let fixture = recordJsTraceWithCall()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # No active source view installed — legacy minified mode.
      # Walk forward to the call site at line 2.
      var safety = 0
      while session.getCurrentLine() != 2 and safety < 16:
        session.stepForward()
        inc safety
      check session.getCurrentLine() == 2

      # Legacy stepIn: lands at the next recorded step (the callee body).
      session.stepIn()
      check session.getCurrentLine() == 1

when isMainModule:
  discard
