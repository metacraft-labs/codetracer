import
  std / [ options, strformat, strutils, osproc, os, json ],
  ../../common/[ types, trace_index, paths, lang ],
  storage_and_import,
  ctfs_sources,
  ../online_sharing/mcr_enrichment


# hosts a codetracer server that can be accessed in the browser
# codetracer host --port <port>
#        [--backend-socket-port <port>]
#        [--frontend-socket <port>]
#        [--frontend-socket-parameters <parameters>]
#        [--trace-path <path-to-.ct-file-or-trace-folder>]
#        <trace-id>/<trace-folder>

const
  DEFAULT_SOCKET_PORT: int = 5_000
  DEFAULT_IDLE_TIMEOUT_MS = 10 * 60 * 1_000
  IDLE_TIMEOUT_DISABLED = -1

type
  IdleTimeoutResult* = object
    ok*: bool
    value*: int
    error*: string

proc okResult(value: int): IdleTimeoutResult =
  IdleTimeoutResult(ok: true, value: value, error: "")

proc errResult(message: string): IdleTimeoutResult =
  IdleTimeoutResult(ok: false, value: 0, error: message)

proc parseIdleTimeoutMs*(raw: string): IdleTimeoutResult =
  ## Parse a human-friendly duration string into milliseconds.
  ## Supports suffixes: ms, s, m, h. Empty => default. 0/never/off => disabled.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return okResult(DEFAULT_IDLE_TIMEOUT_MS)

  let lower = trimmed.toLowerAscii()
  if lower in ["never", "off"]:
    return okResult(IDLE_TIMEOUT_DISABLED)

  var multiplier = 1_000
  var numberPart = lower
  if lower.endsWith("ms"):
    numberPart = lower[0 .. ^3]
    multiplier = 1
  elif lower.endsWith("s"):
    numberPart = lower[0 .. ^2]
    multiplier = 1_000
  elif lower.endsWith("m"):
    numberPart = lower[0 .. ^2]
    multiplier = 60_000
  elif lower.endsWith("h"):
    numberPart = lower[0 .. ^2]
    multiplier = 60 * 60 * 1_000

  var base = 0
  try:
    base = parseInt(numberPart)
  except CatchableError:
    return errResult(fmt"invalid idle timeout value: {raw}")

  if base < 0:
    return errResult(fmt"idle timeout must be non-negative: {raw}")
  if base == 0:
    return okResult(IDLE_TIMEOUT_DISABLED)

  return okResult(base * multiplier)

proc copyDirContents(srcDir, destDir: string) =
  ## Recursively copy all contents of srcDir into destDir.
  ## Creates destDir if it does not exist.
  createDir(destDir)
  for entry in walkDir(srcDir):
    let destPath = destDir / entry.path.extractFilename
    case entry.kind
    of pcFile, pcLinkToFile:
      copyFile(entry.path, destPath)
    of pcDir, pcLinkToDir:
      copyDirContents(entry.path, destPath)

proc importCtFile(ctFilePath: string): int =
  ## Import a standalone .ct file by creating a minimal trace folder
  ## around it and importing into the database.
  ##
  ## Copies the entire parent directory contents (not just the .ct file)
  ## so that companion files such as `binaries/` and source files are
  ## preserved. After copying, MCR trace enrichment is attempted via
  ## `ct-mcr export --portable` (best-effort — skipped when ct-mcr is
  ## not available).
  ##
  ## Returns the assigned trace ID.
  let tempDir = getTempDir() / "ct-host-" & $getCurrentProcessId()
  createDir(tempDir)

  # Copy the entire source directory into the temp folder so that
  # companion artifacts (binaries/, source files, etc.) are available
  # for enrichment and import.
  let sourceDir = ctFilePath.parentDir
  copyDirContents(sourceDir, tempDir)

  # Ensure the .ct file is named trace.ct for the import machinery.
  let ctFileName = ctFilePath.extractFilename
  if ctFileName != "trace.ct":
    let copiedCtPath = tempDir / ctFileName
    if fileExists(copiedCtPath):
      moveFile(copiedCtPath, tempDir / "trace.ct")

  # Attempt MCR trace enrichment (adds binaries and debug symbols to the
  # .ct container). This is best-effort: if ct-mcr is not found or the
  # file is not an MCR trace, we continue without enrichment.
  let enriched = enrichMcrTraceIfNeeded(tempDir)
  if enriched:
    echo "ct host: MCR trace enriched with portable binaries/symbols"

  # Create minimal trace_db_metadata.json so importTrace can read it
  # (only if enrichment or a prior recording step did not already produce one).
  if not fileExists(tempDir / "trace_db_metadata.json"):
    let metaJson = %*{
      "program": "imported",
      "args": newJArray(),
      "workdir": tempDir,
      "lang": "c"
    }
    writeFile(tempDir / "trace_db_metadata.json", $metaJson)

  let ctfsSourcesExtracted = materializeCtfsSources(tempDir / "trace.ct", tempDir)
  if ctfsSourcesExtracted:
    echo "ct host: extracted CTFS source metadata"

  if not fileExists(tempDir / "trace_paths.json"):
    writeFile(tempDir / "trace_paths.json", "[]")

  # Copy source files into files/ subdirectory if not already present.
  # This mirrors the layout expected by the frontend for source display.
  if not dirExists(tempDir / "files"):
    for entry in walkDir(tempDir):
      if entry.kind == pcFile:
        let ext = entry.path.splitFile.ext.toLowerAscii
        if ext in [".c", ".cpp", ".h", ".hpp", ".rs", ".py", ".rb", ".nim", ".js", ".ts"]:
          let filesDir = tempDir / "files" / sourceDir.strip(chars = {'/'})
          createDir(filesDir)
          copyFile(entry.path, filesDir / entry.path.extractFilename)

  let trace = importTrace(
    tempDir,
    NO_TRACE_ID,
    NO_PID,
    LangUnknown,
    traceKind = "rr")
  if trace.isNil:
    echo "ct host: error: failed to import trace from ", ctFilePath
    quit(1)

  result = trace.id


proc importTraceFolder(traceFolderPath: string): int =
  ## Import a trace folder into the database.
  ## The folder should contain trace_metadata.json or trace_db_metadata.json.
  ##
  ## If the folder contains an MCR trace (.ct file with CTFS magic),
  ## enrichment via `ct-mcr export --portable` is attempted first
  ## (best-effort).
  ##
  ## Returns the assigned trace ID.
  let fullPath = expandFilename(expandTilde(traceFolderPath))

  # Attempt MCR trace enrichment before import. This adds binaries and
  # debug symbols to the .ct container in-place. Best-effort: if ct-mcr
  # is not found or the folder has no MCR trace, this is a no-op.
  let enriched = enrichMcrTraceIfNeeded(fullPath)
  if enriched:
    echo "ct host: MCR trace enriched with portable binaries/symbols"

  let traceKind =
    if fileExists(fullPath / "trace_metadata.json"):
      "db"
    else:
      # Replay trace imports (RR/TTD) carry trace_db_metadata.json.
      "rr"

  let metaFile = if traceKind == "db":
      fullPath / "trace_metadata.json"
    else:
      fullPath / "trace_db_metadata.json"
  if not fileExists(metaFile):
    # For MCR trace folders that lack metadata, create a minimal one
    # so the import can proceed.
    if findCtFileInFolder(fullPath).len > 0:
      let metaJson = %*{
        "program": "imported",
        "args": newJArray(),
        "workdir": fullPath,
        "lang": "c"
      }
      writeFile(fullPath / "trace_db_metadata.json", $metaJson)
      if not fileExists(fullPath / "trace_paths.json"):
        writeFile(fullPath / "trace_paths.json", "[]")
    else:
      echo "ct host: error: trace folder missing metadata file: ", metaFile
      quit(1)

  let trace = importTrace(
    fullPath,
    NO_TRACE_ID,
    NO_PID,
    LangUnknown,
    traceKind = traceKind)
  if trace.isNil:
    echo "ct host: error: failed to import trace from folder ", traceFolderPath
    quit(1)

  result = trace.id


proc hostCommand*(
    port: int,
    backendSocketPort: Option[int],
    frontendSocketPort: Option[int],
    frontendSocketParameters: string,
    traceArg: string,
    idleTimeoutRaw: string,
    tracePath: string = "") =

  putEnv("NODE_PATH", nodeModulesPath)
  putEnv("CODETRACER_PREFIX", codetracerPrefix)

  let isSetBackendSocketPort = backendSocketPort.isSome
  let isSetFrontendSocketPort = frontendSocketPort.isSome
  let backendSocketPort = if backendSocketPort.isSome:
      backendSocketPort.get
    else:
      DEFAULT_SOCKET_PORT
  let frontendSocketPort = if frontendSocketPort.isSome:
      frontendSocketPort.get
    else:
      DEFAULT_SOCKET_PORT
  var traceId = -1
  let envIdleTimeout = getEnv("CODETRACER_HOST_IDLE_TIMEOUT", "")
  let parsedIdleTimeout = parseIdleTimeoutMs(
    if idleTimeoutRaw.len > 0: idleTimeoutRaw else: envIdleTimeout)
  if not parsedIdleTimeout.ok:
    echo "ct host: error: ", parsedIdleTimeout.error
    quit(1)
  let idleTimeoutMs = parsedIdleTimeout.value

  if port < 0:
    echo fmt"ct host: error: no valid port specified: {port}"
    quit(1)

  if isSetBackendSocketPort and not isSetFrontendSocketPort or
      not isSetBackendSocketPort and isSetFrontendSocketPort:
    echo "ct host: error: pass either both backend and frontend port or neither"
    quit(1)

  if tracePath.len > 0:
    # --trace-path provided: auto-import the trace before hosting.
    if fileExists(tracePath) and tracePath.endsWith(".ct"):
      echo "ct host: importing .ct file: ", tracePath
      traceId = importCtFile(tracePath)
      echo "ct host: imported as trace id ", traceId
    elif dirExists(tracePath):
      echo "ct host: importing trace folder: ", tracePath
      traceId = importTraceFolder(tracePath)
      echo "ct host: imported as trace id ", traceId
    else:
      echo "ct host: error: --trace-path not found: ", tracePath
      quit(1)
  elif traceArg.len > 0:
    try:
      traceId = traceArg.parseInt
    except CatchableError:
      # probably traceId is a folder
      # TODO don't depend on db?
      let traceFolder = traceArg
      var traceFolderFullPath = ""
      try:
        traceFolderFullPath = expandFilename(expandTilde(traceFolder))
      except OsError as e:
        echo "ct host error: folder os error: ", e.msg
        quit(1)
      var trace = trace_index.findByPath(traceFolderFullPath, test=false)
      if trace.isNil:
        trace = trace_index.findByPath(traceFolderFullPath & "/", test=false)
        if trace.isNil:
          echo "ct host error: trace not found: maybe you should import it first"
          quit(1)
      traceId = trace.id
  else:
    echo "ct host: error: no trace specified. " &
      "Provide a trace ID or folder as a positional argument, " &
      "or use --trace-path to auto-import a .ct file or trace folder."
    quit(1)

  let callerPid = getCurrentProcessId()
  echo "server index ", codetracerExeDir
  var process = startProcess(
    nodeExe,
    workingDir = codetracerInstallDir,
    args = @[
      codetracerExeDir / "server_index.js",
      $traceId,
      "--port",
      $port,
      "--frontend-socket-port",
      $frontendSocketPort,
      "--frontend-socket-parameters",
      frontendSocketParameters,
      # "--backend-socket-host",
      # backendSocketHost,
      "--backend-socket-port",
      $backendSocketPort,
      "--caller-pid",
      $callerPid,
      "--idle-timeout-ms",
      $idleTimeoutMs
    ],
    options={poParentStreams})
  var electronPid = process.processID
  echo "status code:", waitForExit(process)
