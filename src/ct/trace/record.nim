import std/[os, osproc, streams, strutils, sequtils, strtabs, strformat, json, options],
  multitrace,
  native_backend_selection,
  ../../common/[ lang, paths, types, trace_index, config, ct_logging ],
  ../utilities/[language_detection ],
  ../cli/build,
  ../online_sharing/upload,
  ../globals

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

proc storeTraceFolderInfoForPid(traceId: string, traceFolder: string, pid: int) =
  ## M-REC-2: ``traceId`` is now a UUIDv7 recording-id string.
  let pidFolder = codetracerTmpPath / fmt"source-folders-{pid}"
  createDir(pidFolder)
  writeFile(pidFolder / fmt"trace-{traceId}", traceFolder)

proc streamRecorderOutput(p: Process): tuple[lines: seq[string], exitCode: int] =
  ## Relay the recorder's merged stdout/stderr to our own stdout AS IT
  ## ARRIVES, while keeping every line so the ``recordingId:`` marker can
  ## still be found afterwards.
  ##
  ## ``osproc.readLines`` (what this replaced) waits for the child to exit
  ## before returning anything, which is invisible for a script that finishes
  ## in a second and fatal for ``ct record --server``: the whole point of that
  ## flag is that you watch the session while it runs, and the "watch it live
  ## with: ct replay -t …" guidance would not have appeared until the server
  ## was already stopped.
  var lines: seq[string] = @[]
  let stream = p.outputStream
  var line = ""
  while stream.readLine(line):
    echo line
    flushFile(stdout)
    lines.add(line)
  (lines, p.waitForExit)

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

  let (lines, exCode) = streamRecorderOutput(p)
  # Flush the relayed recorder output (which ends with the
  # ``recordingId:`` marker) so it durably reaches our caller before
  # ``ct`` exits — see the matching note in ``db_backend_record.nim``.
  flushFile(stdout)

  if exCode == 0:
    # M-REC-6: stdout marker renamed from ``traceId:`` to
    # ``recordingId:`` to stop overloading "trace_id" with our local
    # recording identity.  The payload is still a UUIDv7 string.  Both
    # the writer (in ``record.nim`` / ``db_backend_record.nim``) and
    # every reader in the tree flip atomically — there is no legacy
    # ``traceId:`` parser path.
    #
    # The marker is NOT reliably the last line of the recorder's output:
    # ``db-backend-record`` runs the traced program as a child whose
    # stdout is merged in via ``poStdErrToStdOut``.  When the traced
    # program prints a trailing banner/separator (e.g. the sudoku board
    # followed by a row of dashes) the child's final flush can land
    # *after* the ``recordingId:`` marker.  Scan every captured line for
    # the marker (last occurrence wins) rather than assuming ``lines[^1]``
    # — the old ``lines[^1]`` form also crashed outright when the
    # recorder produced no output at all.
    var markerLine = ""
    for line in lines:
      if line.startsWith("recordingId:"):
        markerLine = line
    if markerLine.len > 0:
      let traceId = markerLine[("recordingId:").len .. ^1].strip
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
  else:
    # The recorder failed and has already explained why on the stream we
    # relayed above.  `ct record` used to return nil here and then exit 0,
    # so `ct record app.php` reported "ERROR: unsupported trace kind db" with
    # a SUCCESS status — invisible to any script or CI job checking `$?`.
    # Propagate the recorder's own exit code instead.
    quit(exCode)

proc nativeRecordingBackendForHost(requested: string): string =
  ## MCR is the default native recorder. Linux can explicitly select RR,
  ## Windows can explicitly select TTD, and macOS always uses MCR.
  ##
  ## NTR-2 / Q6: a value this host cannot honour is now a **hard error before
  ## any recording starts**, not a silent coercion to `mcr`.  The rule itself
  ## is a pure function of `(requested, host)` in
  ## `native_backend_selection.nim` so every host's row can be asserted from
  ## any host; this wrapper is the only place the compile-time host and the
  ## exit live.
  let selection =
    resolveNativeRecordingBackend(requested, hostRecordingPlatform())
  if not selection.ok:
    for line in selection.errorLines:
      stderr.writeLine(line)
    quit(1)
  # Not a refusal: the desktop's `db` sentinel arriving on the native path.
  # stderr, so this line does not add to what `ct record`'s stdout carries
  # beside the `recordingId:` marker the GUI and `recordTest` parse.  (stdout is
  # not clean either way — `recordInternal` relays the recorder's merged output
  # onto it — but the parser scans for the marker rather than reading the last
  # line, so both stay safe.)
  for line in selection.noteLines:
    stderr.writeLine(line)
  selection.backend

proc nativeReplayTraceKindForBackend(backend: string): string =
  ## The replay/import layer still treats native MCR CTFS recordings as the
  ## native replay-worker family rather than materialized DB traces.
  if backend == "ttd": "ttd" else: "rr"

proc isExistingExecutable(path: string): bool =
  if not fileExists(path):
    return false
  try:
    fpUserExec in getFilePermissions(path)
  except OSError:
    false

proc record*(lang: string,
             outputFolder: string,
             exportFile: string,
             stylusTrace: string,
             address: string,
             socketPath: string,
             recordBackend: string,
             withDiff: string,
             storeTraceFolderForPid: int,
             upload: bool,
             useInterpose: bool,
             program: string,
             args: seq[string],
             server: bool = false): Trace =
  # NTR-2: recognize ONCE and carry the result along this invocation's own call
  # chain.  That is ordinary parameter passing, not a cache — Q7 decided there
  # is no cache, and nothing here is persisted, so there is no invalidation
  # question and an mtime-preserving rebuild cannot make a stale answer look
  # confident.
  #
  # `recognized.recognitionRan` is false when `--lang` was given (Q8: the
  # recognizer is not spawned at all) or when the folder/extension signal
  # answered first.  A consumer of the carried result must read a missing
  # `components` / `format` / `interpreter` / `debug_info` as "not computed",
  # never as "the target had none".  Recording those into trace metadata is
  # NTR-3; NTR-2 carries them and does not swallow them.
  let recognized = detectTarget(program, toLang(lang))
  let detectedLang = recognized.lang
  if recognized.recognitionRan and recognized.recognition.isSome:
    let recognition = recognized.recognition.get
    var summary = "recognition: kind=" & recognition.kind &
      " components=" & $recognition.components.len &
      " diagnostics=" & $recognition.diagnostics.len
    if recognition.format.isSome:
      summary.add(" container=" & recognition.format.get.container)
    if recognition.recommended.isSome:
      summary.add(" recommended-backend=" & recognition.recommended.get.backend)
    # Ridden on the shipping CODETRACER_LOG_LEVEL rather than on Q10's `-vv`,
    # which does not exist yet (see the NTR-2 report and §9 Q10).  This is a
    # trace of the carry, not the user-facing diagnostics display NTR-3 owes.
    debugPrint summary
  # echo "DEBUG record: detectedLang=", detectedLang, " usesMaterializedTraces=", detectedLang.usesMaterializedTraces, " program=", program, " outputFolder=", outputFolder

  # NTR-2 / Q6: resolve `--backend` HERE — after recognition, before any build,
  # any recorder spawn and any trace-folder creation — so a value this host
  # cannot honour is refused before the command does any work, and is refused
  # for the reason the user actually got wrong rather than being reported as a
  # missing ct-native-replay installation.
  #
  # It is scoped to the native path on purpose.  For a language with a
  # dedicated recorder `--backend` names nothing the recorder can act on and
  # has never been consulted; the desktop welcome screen relies on that, and
  # sends `--backend db` for every recording whose target it did not classify
  # as native (src/frontend/viewmodel/viewmodels/welcome_screen_vm.nim's
  # `effectiveRecordBackend` -> `recordBackendWireName` ->
  # src/frontend/index/traces.nim:1066,1199).  That the flag is still ignored
  # there is a SEPARATE gap, recorded in the design document, not closed here.
  #
  # Scoping alone is NOT sufficient, which the NTR-2 review measured against
  # the shipped binary: the GUI's classification and `usesMaterializedTraces`
  # are different functions and they disagree, so `--backend db` also reaches
  # the branch below for `myapp.bin` (`recordTargetAuto` in the GUI, `LangC`
  # here) and for a `.lua` script.  The `db` sentinel is therefore handled
  # inside `resolveNativeRecordingBackend` rather than being refused as a
  # misspelling; see `MaterializedBackendNames`.
  let nativeBackend =
    if detectedLang.usesMaterializedTraces:
      ""
    else:
      nativeRecordingBackendForHost(recordBackend)
  var outputFolderValue = outputFolder
  var programToRecord = program
  var nimcachePath = ""
  var pargs: seq[string] = @[]
  if lang != "":
    pargs.add("--lang")
    pargs.add(lang)
  if outputFolderValue != "" and outputFolderValue != ".":
    pargs.add("-o")
    pargs.add(outputFolderValue)
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
  if server:
    pargs.add("--server")

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

  if detectedLang in {LangRustWasm, LangCppWasm} and dirExists(program):
    # WASM Cargo project: build with wasm32-wasip1 target, then record the .wasm binary.
    let buildProcess = osproc.execProcess(
      "cargo",
      workingDir = program,
      args = @["build", "--target", "wasm32-wasip1"],
      options = {poUsePath, poStdErrToStdOut})
    # Read the package name from Cargo.toml to find the .wasm binary.
    var pkgName = ""
    for line in readFile(program / "Cargo.toml").splitLines:
      if line.strip.startsWith("name"):
        let parts = line.split("=", 1)
        if parts.len == 2:
          pkgName = parts[1].strip.strip(chars = {'"', '\''})
          break
    if pkgName.len == 0:
      echo "error: could not determine package name from Cargo.toml"
      quit(1)
    # Replace hyphens with underscores (Cargo convention for binary names).
    let binaryName = pkgName.replace('-', '_')
    let wasmPath = program / "target" / "wasm32-wasip1" / "debug" / (binaryName & ".wasm")
    if not fileExists(wasmPath):
      echo "error: WASM build failed or binary not found at: ", wasmPath
      echo buildProcess
      quit(1)
    programToRecord = wasmPath
  elif not detectedLang.usesMaterializedTraces:
    # Match `ct run` behavior for RR-based languages by building first.
    # M-REC-7: folder name is the bare ``recording_id`` (UUIDv7) — see paths.recordingFolder.
    if detectedLang == LangNim and outputFolderValue.len == 0:
      let traceID = trace_index.newID(test=false)
      outputFolderValue = recordingFolder(codetracerShareFolder, traceID)
      createDir(outputFolderValue)
      nimcachePath = outputFolderValue / "nimcache"
      # Ensure the output folder is passed to the recorder after we create it.
      pargs.add("-o")
      pargs.add(outputFolderValue)
    if isExistingExecutable(program):
      programToRecord = program
    else:
      programToRecord = build(program, "", nimcachePath)

  pargs.add(programToRecord)
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

  if detectedLang.usesMaterializedTraces:
    if useInterpose:
      # The interpose recorder is graphics-API specific and lives in
      # the MCR backend.  Materialized backends (e.g. Python's db
      # backend) cannot honour --use-interpose, so fail fast rather
      # than silently dropping the flag.
      echo "error: --use-interpose is only supported for native MCR recordings; "
      echo "  the detected language (" & $detectedLang & ") uses a materialized-trace backend."
      quit(1)
    return recordInternal(
      dbBackendRecordExe,
      pargs.concat(@["--trace-kind", "db"]),
      withDiff,
      storeTraceFolderForPid,
      upload)
  else:
    let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
    if ctConfig.rrBackend.enabled:
      # `nativeBackend` was resolved (and an unhonourable `--backend` already
      # refused) right after recognition, above.
      let traceKind = nativeReplayTraceKindForBackend(nativeBackend)
      if useInterpose and nativeBackend != "mcr":
        echo "error: --use-interpose requires the MCR backend; current backend is '" & nativeBackend & "'."
        echo "  Pass --backend=mcr explicitly or unset --use-interpose."
        quit(1)
      var nativeArgs =
        pargs.concat(@["--trace-kind", traceKind,
                       "--rr-support-path", ctConfig.rrBackend.path])
      if nativeBackend == "mcr":
        nativeArgs = nativeArgs.concat(@["--backend", "mcr"])
        if useInterpose:
          # Forwarded as a trailing recorder-side flag; db-backend-record
          # already passes unknown ``--`` args through to the native
          # recorder when ``--backend=mcr`` is in effect.
          #
          # THE RECORDER'S SPELLING IS ``--interpose``, NOT CODETRACER'S
          # ``--use-interpose``. They are two different CLIs: `--use-interpose`
          # is ct's own public flag (docs/book/src/reference/ct_cli.md), while
          # the flag that reaches ct_cli must be the one its parser knows
          # (`codetracer-native-recorder/ct_cli/src/ct_cli/arg_parser.nim:695`).
          # ct_cli RETIRED `--use-interpose` and its parser's `else` branch
          # returns `err("unknown option: ...")`, so sending the ct spelling
          # here does not degrade — it fails the recording outright. This is
          # the exact skew `src/common/target_assessment.nim:26` cites as the
          # precedent for versioning the launcher protocol.
          nativeArgs.add("--interpose")
      return recordInternal(
        dbBackendRecordExe,
        nativeArgs,
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
  if not lang.usesMaterializedTraces:
    let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
    if ctConfig.rrBackend.enabled:
      # assume `Lang<Name/Label>'
      let langAsText = if ($lang).len > 4: ($lang)[4..^1] else: "Unknown"
      # pass our own `ct` path as well, so the recorder can use `ct` to record the test after building it
      var args = @[
        "record-test",
        testName, fullPath, $line, $column,
        langAsText, ctAppFilename()
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
        # M-REC-6: stdout-marker renamed to ``recordingId:``.
        if traceIdLine.startsWith("recordingId:"):
          let traceId = traceIdLine[("recordingId:").len..^1].strip
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
  elif lang == LangPythonDb:
    # Python test recording using pytest
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
      quit(1)
    of recorderError:
      echo "error: Failed to import `codetracer_python_recorder` using interpreter: " & pythonInterpreter
      if checkResult.diagnostics.len > 0:
        echo checkResult.diagnostics
      quit(1)

    # Build pytest node ID: path::testName
    let pytestNodeId = fullPath & "::" & testName

    # Build arguments for db_backend_record
    # Note: --trace-kind must come BEFORE --pytest since --pytest captures all remaining args
    var pargs: seq[string] = @[]
    pargs.add("--lang")
    pargs.add("python")
    pargs.add("--python-interpreter")
    pargs.add(pythonInterpreter)
    pargs.add("--trace-kind")
    pargs.add("db")
    # Pass pytest arguments: --pytest <node_id> (must be last, captures remaining args)
    pargs.add("--pytest")
    pargs.add(pytestNodeId)
    pargs.add("-v")  # Verbose output for better test feedback

    if getEnv("CODETRACER_WRAPPER_PID", "").len == 0:
      putEnv("CODETRACER_WRAPPER_PID", $getCurrentProcessId())

    let trace = recordInternal(
      dbBackendRecordExe,
      pargs,
      withDiff,
      storeTraceFolderForPid,
      upload=false)

    if not trace.isNil:
      # M-REC-6: stdout marker renamed to ``recordingId:``.
      echo fmt"recordingId:{trace.recordingId}"
      quit(0)
    else:
      echo "error: Failed to record pytest test"
      quit(1)
  else:
    echo fmt"Assuming recording language {lang}: currently `ct record-test` not supported for this db-based language"
    quit(1)
