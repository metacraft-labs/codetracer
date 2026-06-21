## M8 — Headless ViewModel layer test for formatted-view step-OUT.
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M8.
##
## What this test proves:
##
##   1. With the formatted view active, ``headless_session.stepOut``
##      from inside a callee advances the cursor to the formatted line
##      where execution resumes in the caller — not to the recorded
##      minified anchor (which may project back to the same formatted
##      line as the entry under certain srcview shapes).
##   2. Without the formatted view (legacy minified mode), ``stepOut``
##      preserves the M1/M2/M3 ``step_out`` semantic: walk one call
##      depth shallower than the entry frame.
##
## Fixture: a JS program with a function call (same shape as the M8
## step-IN VM test).  We position the cursor INSIDE the callee body and
## drive ``stepOut`` to verify the landing position.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_formatted_view_step_out_vm.nim

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
  result = getTempDir() / ("ct_fmt_view_step_out_vm_" & $getCurrentProcessId())

proc recordJsTraceWithCall(): tuple[tracePath, sourcePath: string;
                                     calleeLine, callerLine: int] =
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "program.js"
  # Three-line fixture: callee on line 1, call site on line 2, and a
  # POST-CALL statement on line 3 so the JS recorder emits a depth-0
  # step AFTER the callee returns.  Without that trailing line the
  # recorder's last step lands inside the callee body
  # (``return x + 1;`` at line 1 column 17 under the inline form) and
  # the legacy ``step_out`` primitive — which walks forward looking for
  # the next step at depth ≤ caller_depth — would clamp at the last
  # in-callee step instead of advancing to a real caller-resume
  # position.  The extra ``var z = 10;`` line gives the recorder a
  # natural depth-0 anchor to land on after the callee returns, so
  # ``stepOut`` from inside the callee resolves to line 3 — the post-
  # call resume the M8 contract is supposed to surface.
  const program =
    "function f(x) { return x + 1; }\n" &
    "var y = f(5);\n" &
    "var z = 10;\n"
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
          calleeLine: 1, callerLine: 2)

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
  ## Identity sourcemap so the M8 runner has a complete projection.
  ## See ``test_formatted_view_step_in_vm.nim`` for rationale.
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

const FormattedViewPath = "/tmp/m8-vm-step-out-formatted-view.fmt.js"

proc walkToCalleeBody(s: HeadlessDebugSession; calleeLine, callerLine: int) =
  ## Drive the cursor into the callee body — i.e. land on
  ## ``calleeLine`` while the call stack is one frame deep.  We do this
  ## by stepping forward past the function-declaration step and the
  ## call-site step, then issuing ``stepIn`` at the call site.
  var safety = 0
  while s.getCurrentLine() != callerLine and safety < 16:
    s.stepForward()
    inc safety
  doAssert s.getCurrentLine() == callerLine,
    "could not reach call site line " & $callerLine &
    " (currently at " & $s.getCurrentLine() & ")"
  # Step into the callee.
  s.stepIn()
  doAssert s.getCurrentLine() == calleeLine,
    "stepIn from call site did not land inside the callee body line " &
    $calleeLine & " (landed at " & $s.getCurrentLine() & ")"

suite "M8 — Formatted-view step-OUT through the ViewModel":

  test "test_formatted_view_step_out_returns_to_formatted_caller_line":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      ## STRICT (Test A) — with the formatted srcview active and the
      ## cursor inside the callee body (line 1, depth 1), ``stepOut``
      ## MUST advance to the caller's resume line.  Under the identity
      ## sourcemap fixture the formatted line equals the recorded line,
      ## so the assertion is "the cursor is no longer on the callee body
      ## line" — i.e. either at the call site line (some recorders
      ## anchor the post-call step at the call site) or past it.  This
      ## pins the M8 stepOut contract: the cursor lands at a formatted
      ## line that DIFFERS from the callee body line.
      let fixture = recordJsTraceWithCall()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      # 5 covers lines 1..5 — enough for the 3-line fixture above with
      # a one-line safety margin so the V3 map is dense across every
      # recorded line the JS recorder might emit (post-call steps the
      # recorder anchors past the source's last code line included).
      let mapJson = buildIdentityV3Map(FormattedViewPath, 5)
      session.installSourceViewForTest(
        recordedPath = fixture.sourcePath,
        formattedViewPath = FormattedViewPath,
        sourcemapV3Json = mapJson)
      session.setActiveSourceView(FormattedViewPath)

      walkToCalleeBody(session, fixture.calleeLine, fixture.callerLine)

      let entryLine = session.getCurrentLine()
      check entryLine == fixture.calleeLine

      # stepOut from inside the callee MUST advance off the callee body line.
      session.stepOut()
      let landed = session.getCurrentLine()
      check landed != fixture.calleeLine

  test "test_minified_view_step_out_preserves_legacy_step_out":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      ## STRICT (Test B) — back-compat: WITHOUT activating the formatted
      ## view, ``stepOut`` advances out of the callee frame using the
      ## legacy depth-1 step-out primitive.  The landing line MUST differ
      ## from the callee body line (the legacy step-out always exits the
      ## current frame).  This pins that M8's intercept layer is
      ## transparent to clients who haven't toggled the formatted view.
      let fixture = recordJsTraceWithCall()
      let replayServer = findReplayServer()
      var session = newHeadlessDebugSession(fixture.tracePath, replayServer)

      walkToCalleeBody(session, fixture.calleeLine, fixture.callerLine)
      let entryLine = session.getCurrentLine()
      check entryLine == fixture.calleeLine

      session.stepOut()
      let landed = session.getCurrentLine()
      check landed != fixture.calleeLine

when isMainModule:
  discard
