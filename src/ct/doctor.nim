## ``ct doctor`` — recorder readiness probe.
##
## P7.1 introduced the user-facing ``ct doctor`` subcommand so that
## the book never has to ask users to invoke recorder binaries
## directly (e.g. ``python -m codetracer_python_recorder --help``).
## ``ct doctor`` answers a single question: "are my recorders ready
## to record?" Without arguments it probes every known recorder and
## prints a summary table. With an explicit language argument
## (``ct doctor python``) it runs a focused, single-language probe
## that reports PASS or FAIL along with diagnostic hints.
##
## Each probe is self-contained: import the recorder module / binary,
## report the path used and the discovered version, and convert
## non-zero status into a hint without crashing ``ct``. This module
## is designed to be safe to call from CI and integration tests; in
## particular, it never raises and always exits 0 (the textual
## PASS/FAIL is what tests inspect).
##
## We deliberately reuse the existing ``resolvePythonInterpreter`` /
## ``checkPythonRecorder`` helpers from ``trace/record.nim`` so the
## doctor stays in lock-step with the actual recording code path.

import
  std/[ os, osproc, strutils, strformat, json ]

type
  ProbeStatus* = enum
    probePass,    ## Recorder is importable and reports a version (or no version is exposed).
    probeFail,    ## Recorder discovery failed — actionable diagnostic in ``details``.
    probeSkip     ## Probe is not implemented for this recorder yet.

  ProbeResult* = object
    language*: string   ## Public language identifier (``python``, ``ruby`` ...).
    status*: ProbeStatus
    binary*: string     ## Resolved interpreter / recorder binary path.
    version*: string    ## Reported version string, or "".
    details*: string    ## Free-form diagnostic message, empty on PASS.

const
  KnownLanguages* = ["python"]
    ## Recorder languages that ``ct doctor`` (no-arg) iterates.  This
    ## list is intentionally short to start — other languages can be
    ## added incrementally as we wire their probes in.  Keeping the
    ## list narrow avoids spurious FAILs that would force users to
    ## install recorders they do not actually need.

proc stripEnclosingQuotes(value: string): string =
  if value.len >= 2:
    let first = value[0]
    let last = value[^1]
    if (first == '"' and last == '"') or (first == '\'' and last == '\''):
      return value[1..^2]
  value

proc resolveInterpreterCandidate(candidate: string): string =
  ## Mirrors ``trace/record.nim``: accept tilde-expansion, strip
  ## quoting, and validate the binary via ``findExe``.  Keep the
  ## helper local so ``doctor`` does not depend on the recorder
  ## module pulling in network / GUI imports.
  var trimmed = candidate.strip()
  if trimmed.len == 0:
    return ""
  trimmed = stripEnclosingQuotes(trimmed)
  trimmed = expandTilde(trimmed)

  let hasPathSeparator = trimmed.contains({'/', '\\'})
  if hasPathSeparator or trimmed.startsWith("."):
    try:
      if fileExists(trimmed):
        if trimmed.isAbsolute():
          return trimmed
        else:
          return absolutePath(trimmed)
    except CatchableError:
      discard

  let direct = findExe(trimmed, followSymlinks=false)
  if direct.len > 0:
    return direct
  let wsIdx = trimmed.find({' ', '\t'})
  if wsIdx != -1:
    let head = trimmed[0 ..< wsIdx]
    let headResolved = findExe(head, followSymlinks=false)
    if headResolved.len > 0:
      return headResolved
  ""

proc resolvePythonInterpreterForDoctor(): tuple[path: string, error: string] =
  ## Same precedence as ``trace/record.nim``: explicit env override
  ## first, then ``python3`` / ``python`` / ``py`` on ``PATH``.
  let envCandidates = @[
    "CODETRACER_PYTHON_INTERPRETER",
    "PYTHON_EXECUTABLE",
    "PYTHONEXECUTABLE",
    "PYTHON"
  ]
  for envName in envCandidates:
    let value = getEnv(envName, "")
    if value.len > 0:
      let resolved = resolveInterpreterCandidate(value)
      if resolved.len > 0:
        return (resolved, "")
      else:
        return ("", fmt"{envName} is set to '{value}' but does not resolve to a Python interpreter.")

  for binary in ["python3", "python", "py"]:
    let resolved = resolveInterpreterCandidate(binary)
    if resolved.len > 0:
      return (resolved, "")
  ("", "Python interpreter not found. Set CODETRACER_PYTHON_INTERPRETER or install python3 on PATH.")

proc probePython*(): ProbeResult =
  ## Run ``<interpreter> -c "import codetracer_python_recorder"`` and
  ## report success / failure.  The actual recorder version is read
  ## from ``codetracer_python_recorder.__version__`` when present.
  result.language = "python"
  let (interpreter, resolverError) = resolvePythonInterpreterForDoctor()
  if interpreter.len == 0:
    result.status = probeFail
    result.details = resolverError
    return

  result.binary = interpreter

  const checkPrefix = "CODETRACER_DOCTOR_PYTHON_RECORDER::"
  let script = """
import importlib, importlib.util, json, sys, traceback
result = {"status": "ok", "version": ""}
try:
    spec = importlib.util.find_spec("codetracer_python_recorder")
    if spec is None:
        result["status"] = "missing"
    else:
        module = importlib.import_module("codetracer_python_recorder")
        version = getattr(module, "__version__", "")
        result["version"] = version if isinstance(version, str) else repr(version)
except Exception as exc:
    result["status"] = "error"
    result["error"] = repr(exc)
    result["traceback"] = traceback.format_exc()

print("CODETRACER_DOCTOR_PYTHON_RECORDER::" + json.dumps(result))
if result["status"] == "ok":
    sys.exit(0)
elif result["status"] == "missing":
    sys.exit(3)
else:
    sys.exit(4)
"""
  var process: Process
  try:
    process = startProcess(interpreter, args = @["-c", script], options = {poStdErrToStdOut})
  except OSError as exc:
    result.status = probeFail
    result.details = "Failed to launch Python interpreter: " & exc.msg
    return

  let (lines, exitCode) = process.readLines
  var payload = ""
  for line in lines:
    if line.startsWith(checkPrefix):
      payload = line[checkPrefix.len .. ^1]

  if payload.len > 0:
    try:
      let node = parseJson(payload)
      if node.kind == JObject:
        let statusStr =
          if node.hasKey("status") and node["status"].kind == JString:
            node["status"].getStr()
          else: ""
        if node.hasKey("version") and node["version"].kind == JString:
          result.version = node["version"].getStr()
        case statusStr
        of "ok":
          result.status = probePass
          return
        of "missing":
          result.status = probeFail
          result.details = "Module `codetracer_python_recorder` is not installed. " &
                           "Install it with `python -m pip install codetracer_python_recorder`."
          return
        else:
          var diag = ""
          if node.hasKey("error") and node["error"].kind == JString:
            diag = node["error"].getStr()
          if node.hasKey("traceback") and node["traceback"].kind == JString:
            if diag.len > 0: diag.add("\n")
            diag.add(node["traceback"].getStr())
          result.status = probeFail
          result.details = diag
          return
    except CatchableError as parseError:
      result.status = probeFail
      result.details = "Failed to parse probe output: " & parseError.msg & "\nPayload: " & payload
      return

  result.status = probeFail
  if exitCode != 0:
    result.details = fmt"Python recorder probe exited with status {exitCode}: " & lines.join("\n")
  else:
    result.details = "Python recorder probe produced no parseable output: " & lines.join("\n")

proc renderProbe(p: ProbeResult): string =
  ## Single-line summary for the table output.  The first token is
  ## the PASS/FAIL/SKIP keyword so callers can grep for it.
  let statusLabel =
    case p.status
    of probePass: "PASS"
    of probeFail: "FAIL"
    of probeSkip: "SKIP"
  result = fmt"  {statusLabel:<5} {p.language:<12}"
  if p.binary.len > 0:
    result.add fmt"  binary={p.binary}"
  if p.version.len > 0:
    result.add fmt"  version={p.version}"
  if p.details.len > 0:
    result.add "\n        " & p.details.replace("\n", "\n        ")

proc runProbe(language: string): ProbeResult =
  ## Dispatch the probe by language.  Add new arms here as more
  ## recorder probes are implemented.
  case language.toLowerAscii
  of "python", "py":
    return probePython()
  else:
    result.language = language
    result.status = probeSkip
    result.details = "No probe implemented for language '" & language &
      "' yet. ``ct doctor`` will gain coverage as more recorders ship."

proc doctorCommand*(language: string): int =
  ## Public entry point.  Returns an exit code so that the caller can
  ## decide whether to ``quit()``.  Returns ``0`` when every probe
  ## reports PASS (or is intentionally SKIP), ``1`` when at least one
  ## probe reports FAIL.
  let targets =
    if language.len == 0:
      @KnownLanguages
    else:
      @[language]

  echo "ct doctor: recorder readiness check"
  echo "-----------------------------------"

  var anyFail = false
  for target in targets:
    let probe = runProbe(target)
    echo renderProbe(probe)
    if probe.status == probeFail:
      anyFail = true

  echo ""
  if anyFail:
    echo "Result: FAIL (one or more recorders are not ready)."
    return 1
  echo "Result: PASS"
  return 0
