import std/[os, osproc, strutils, sequtils, strtabs, strformat],
  multitrace,
  ../../common/[ lang, paths, types, trace_index, config ],
  ../utilities/[language_detection ],
  ../cli/build

proc stripEnclosingQuotes(value: string): string =
  ## Remove a single layer of matching quotes from ``value`` if present.
  if value.len >= 2:
    let first = value[0]
    let last = value[^1]
    if (first == '"' and last == '"') or (first == '\'' and last == '\''):
      return value[1..^2]
  value

proc resolveInterpreterCandidate(candidate: string): string =
  ## Best-effort resolution of an interpreter command or path to an absolute path.
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

proc resolvePythonInterpreter(): string =
  ## Resolve the Python interpreter by inspecting common environment variables and PATH.
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
        return resolved

  for binary in ["python3", "python", "py"]:
    let resolved = resolveInterpreterCandidate(binary)
    if resolved.len > 0:
      return resolved

  ""

proc recordInternal(exe: string, args: seq[string], withDiff: string, configPath: string): Trace =
  let env = if configPath.len > 0:
      setupEnv(configPath)
    else:
      var env = newStringTable(modeStyleInsensitive)
      for name, value in envPairs():
        env[name] = value
      env
  let p = startProcess(
    exe,
    args = args,
    env = env,
    options = {poStdErrToStdOut})

  let (lines, exCode) = p.readLines
  # echo args
  # echo exCode
  for line in lines:
    echo line

  if exCode == 0:
    let lastLine = lines[^1]
    if lastLine.startsWith("traceId:"):
      let traceId = parseInt(lastLine[8..^1])
      result = trace_index.find(traceId, test=false)

      if withDiff.len > 0:
        makeMultitrace(@[traceId], withDiff, fmt"multitrace-with-diff-for-trace-{traceId}.zip")

proc record*(lang: string,
             outputFolder: string,
             exportFile: string,
             stylusTrace: string,
             address: string,
             socketPath: string,
             withDiff: string,
             program: string,
             args: seq[string]): Trace =
  let detectedLang = detectLang(program, toLang(lang))
  var pargs: seq[string] = @[]
  if lang != "":
    pargs.add("--lang")
    pargs.add(lang)
  if outputFolder != "" and outputFolder != ".":
    pargs.add("-o")
    pargs.add(outputFolder)
  if exportFile != "":
    pargs.add("-e")
    pargs.add(exportFile)
  if stylusTrace != "":
    pargs.add("--stylus-trace")
    pargs.add(stylusTrace)
  if address != "":
    pargs.add("--address")
    pargs.add(address)
  if socketPath != "":
    pargs.add("--socket")
    pargs.add(socketPath)

  if detectedLang == LangPythonDb:
    let pythonInterpreter = resolvePythonInterpreter()
    if pythonInterpreter.len == 0:
      echo "error: Python interpreter not found. Set CODETRACER_PYTHON_INTERPRETER or ensure `python` is on PATH."
      quit(1)

    pargs.add("--python-interpreter")
    pargs.add(pythonInterpreter)

  pargs.add(program)
  if args.len != 0:
    pargs = concat(pargs, args)

  # echo "detected lang ", detectedLang
  # TODO: eventually maybe simplify how this works
  # currently recording from startup screen form(index.nim)
  # calls `ct record` which calls another process and we need to
  # map correctly our `ct record` pid to the trace id
  # that's why we pass it as an env var to the process that
  # actually records in sqlite (except if in tup build
  # we already pass it from ct_wrapper)
  #
  # eventually Dimo/Petar want to simplify this to maybe
  # directly read the traceId from the record process output 
  if getEnv("CODETRACER_WRAPPER_PID", "").len == 0:
    putEnv("CODETRACER_WRAPPER_PID", $getCurrentProcessId())

  if detectedLang in @[LangRubyDb, LangNoir, LangRustWasm, LangCppWasm, LangSmall, LangPythonDb]:
    return recordInternal(dbBackendRecordExe, pargs, withDiff, "")
  else:
    let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
    if ctConfig.rrBackend.enabled:
      let configPath = ctConfig.rrBackend.ctPaths
      return recordInternal(ctConfig.rrBackend.path, concat(@["record"], pargs), withDiff, configPath)
    else:
      echo "This functionality requires a codetracer-rr-backend installation"
