import std/[os, osproc, strutils, sequtils, strtabs, strformat, json, options],
  multitrace,
  ../../common/[ lang, paths, types, trace_index, config ],
  ../utilities/[language_detection ],
  ../cli/build,
  ../online_sharing/upload

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

proc resolvePythonInterpreter(): tuple[path: string, error: string] =
  ## Resolve the Python interpreter by inspecting common environment variables and PATH.
  ## Authoritative overrides (env vars) must point to a valid interpreter; otherwise we surface the failure.
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
        let trimmedValue = value.strip()
        let presentedValue = if trimmedValue.len > 0: trimmedValue else: value
        return ("", fmt"{envName} is set to '{presentedValue}' but it does not resolve to a Python interpreter. Update the variable or unset it to fall back to PATH detection.")

  for binary in ["python3", "python", "py"]:
    let resolved = resolveInterpreterCandidate(binary)
    if resolved.len > 0:
      return (resolved, "")

  ("", "")

type PythonRecorderCheckStatus = enum
  recorderPresent,
  recorderMissing,
  recorderError

proc checkPythonRecorder(interpreter: string): tuple
    [status: PythonRecorderCheckStatus, version: string, diagnostics: string] =
  ## Run a short Python snippet to ensure codetracer_python_recorder is importable.
  const checkPrefix = "CODETRACER_PYTHON_RECORDER_CHECK::"
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
        if isinstance(version, str):
            result["version"] = version
        else:
            result["version"] = repr(version)
except Exception as exc:
    result["status"] = "error"
    result["error"] = repr(exc)
    result["traceback"] = traceback.format_exc()

print("CODETRACER_PYTHON_RECORDER_CHECK::" + json.dumps(result))
if result["status"] == "ok":
    sys.exit(0)
elif result["status"] == "missing":
    sys.exit(3)
else:
    sys.exit(4)
"""
  let process = startProcess(
    interpreter,
    args = @["-c", script],
    options = {poStdErrToStdOut})
  let (lines, exitCode) = process.readLines

  var payload = ""
  for line in lines:
    if line.startsWith(checkPrefix):
      if line.len > checkPrefix.len:
        payload = line[checkPrefix.len .. ^1]
      else:
        payload = ""

  var status = recorderError
  var version = ""
  var diagnostics = ""

  if payload.len > 0:
    try:
      let node = parseJson(payload)
      if node.kind == JObject:
        let statusStr = if node.hasKey("status") and node["status"].kind == JString:
            node["status"].getStr()
          else:
            ""
        case statusStr
        of "ok":
          status = recorderPresent
        of "missing":
          status = recorderMissing
        else:
          status = recorderError

        if node.hasKey("version") and node["version"].kind == JString:
          version = node["version"].getStr()

        if node.hasKey("error") and node["error"].kind == JString:
          diagnostics = node["error"].getStr()
        if node.hasKey("traceback") and node["traceback"].kind == JString:
          let tb = node["traceback"].getStr()
          if diagnostics.len > 0:
            diagnostics.add("\n")
          diagnostics.add(tb)
    except CatchableError as parseError:
      diagnostics = "Failed to parse recorder check output: " & parseError.msg & "\nPayload: " & payload
  else:
    diagnostics = lines.join("\n")

  if status == recorderPresent and exitCode == 0:
    return (recorderPresent, version, diagnostics)
  elif status == recorderMissing and exitCode == 3:
    return (recorderMissing, version, diagnostics)
  elif status == recorderError:
    if diagnostics.len == 0:
      diagnostics = lines.join("\n")
    return (recorderError, version, diagnostics)
  else:
    let combined = if diagnostics.len > 0: diagnostics else: lines.join("\n")
    return (recorderError, version, combined)

proc storeTraceFolderInfoForPid(traceId: int, traceFolder: string, pid: int) =
  let pidFolder = codetracerTmpPath / fmt"source-folders-{pid}"
  createDir(pidFolder)
  writeFile(pidFolder / fmt"trace-{traceId}", traceFolder)

proc recordInternal(exe: string, args: seq[string], withDiff: string, storeTraceFolderForPid: int, upload: bool): Trace =
  # let env = if configPath.len > 0:
  #     setupEnv(configPath)
  #   else:
  #     var env = newStringTable(modeStyleInsensitive)
  #     for name, value in envPairs():
  #       env[name] = value
  #     env
  let p = startProcess(
    exe,
    args = args,
    # env = env,
    options = {poStdErrToStdOut, poUsePath})

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
        # makeMultitrace(@[traceId], withDiff, fmt"multitrace-with-diff-for-trace-{traceId}.zip")
        addDiffToTrace(result, withDiff)

      if storeTraceFolderForPid > 0:
        storeTraceFolderInfoForPid(traceId, result.outputFolder, storeTraceFolderForPid)

      if upload:
        # ct-remote must add its default organization if it exists
        # if not, for now there is not an org arg for ct record yet
        let org = none(string)
        # IMPORTANT: currently this calls ct-remote and leaves the output mostly to it
        # and after this directly exists the program
        # we assume this is ok, as ct record --upload .. is a bit like
        # ct record + ct upload
        discard uploadTrace(result, org)
    else:
      echo "ERROR: maybe something wrong with record; couldn't read trace id after recording"
      quit(1)

proc record*(lang: string,
             outputFolder: string,
             exportFile: string,
             stylusTrace: string,
             address: string,
             socketPath: string,
             withDiff: string,
             storeTraceFolderForPid: int,
             upload: bool,
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
    let (pythonInterpreter, resolverError) = resolvePythonInterpreter()
    if resolverError.len > 0:
      echo "error: " & resolverError
      quit(1)
    if pythonInterpreter.len == 0:
      echo "error: Python interpreter not found. Set CODETRACER_PYTHON_INTERPRETER or ensure `python` is on PATH."
      quit(1)

    let checkResult = checkPythonRecorder(pythonInterpreter)
    case checkResult.status
    of recorderPresent:
      discard
    of recorderMissing:
      echo "error: Python module `codetracer_python_recorder` is not installed for interpreter: " & pythonInterpreter
      if checkResult.diagnostics.len > 0:
        echo checkResult.diagnostics
      echo "help: Install it in that environment with `python -m pip install codetracer_python_recorder`"
      echo "help: Or point CodeTracer at a different interpreter via CODETRACER_PYTHON_INTERPRETER=/path/to/python"
      quit(1)
    of recorderError:
      echo "error: Failed to import `codetracer_python_recorder` using interpreter: " & pythonInterpreter
      if checkResult.diagnostics.len > 0:
        echo checkResult.diagnostics
      else:
        echo "help: Inspect the interpreter output above for details."
      echo "help: Ensure the package is installed and the environment activates correctly before running `ct record`."
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
    return recordInternal(
      dbBackendRecordExe,
      pargs.concat(@["--trace-kind", "db"]),
      withDiff,
      storeTraceFolderForPid,
      upload)
  else:
    let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
    if ctConfig.rrBackend.enabled:
      return recordInternal(
        dbBackendRecordExe,
        pargs.concat(@["--trace-kind", "rr", "--rr-support-path", ctConfig.rrBackend.path]),
        withDiff,
        storeTraceFolderForPid,
        upload)
    else:
      let guidance = rrBackendMissingGuidanceLines()
      echo fmt"Assuming recording language {detectedLang}:"
      for line in guidance:
        echo "  " & line
      quit(1)

proc recordTest*(testName: string, path: string, line: int, column: int, withDiff: string, storeTraceFolderForPid: int) =
  # TODO: not sure about wasm, for now not supported for tests
  let fullPath = expandFileName(expandTilde(path))
  let lang = detectLangFromPath(fullPath, isWasm=false)
  if not lang.isDBBased:
    let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
    if ctConfig.rrBackend.enabled:
      # assume `Lang<Name/Label>'
      let langAsText = if ($lang).len > 4: ($lang)[4..^1] else: "Unknown"
      # pass our own `ct` path as well, so the recorder can use `ct` to record the test after building it
      var args = @[
        "record-test",
        testName, fullPath, $line, $column,
        langAsText, getAppFilename()
      ]
      if withDiff.len > 0:
        args.add("--with-diff")
        args.add(withDiff)
      args.add("--store-trace-folder-for-pid")
      args.add($storeTraceFolderForPid)

      let output = execProcess(
        ctConfig.rrBackend.path,
        args = args,
        options = {poEchoCmd})
      # copied/adapted by memory and src/frontend/vscode.nim, probably originatd in ct/other code
      let lines = output.splitLines()
      if lines.len > 0:
        let traceIdLine = lines[^2]
        if traceIdLine.startsWith("traceId:"):
          let traceId = traceIdLine[("traceId:").len..^1].parseInt
          let trace = trace_index.find(traceId, test=false)
          writeFile(trace.outputFolder / "custom-entrypoint.txt", testName)

          echo output
          quit(0)
      
      echo output
      quit(1)
      #let exitCode = waitForExit(process)
      #quit(exitCode)
    else:
      let guidance = rrBackendMissingGuidanceLines()
      echo fmt"Assuming recording language {lang}:"
      for line in guidance:
        echo "  " & line
      quit(1)
  else:
    echo fmt"Assuming recording language {lang}: currently `ct record-test` not supported for db traces"
    # quit(1)
