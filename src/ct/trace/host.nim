import
  std / [ options, strformat, strutils, osproc, os ],
  ../utilities/[ env ],
  ../../common/[ types, trace_index, paths ]


# hosts a codetracer server that can be accessed in the browser
# codetracer host --port <port>
#        [--backend-socket-port <port>]
#        [--frontend-socket <port>]
#        [--frontend-socket-parameters <parameters>]
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

proc hostCommand*(
    port: int,
    backendSocketPort: Option[int],
    frontendSocketPort: Option[int],
    frontendSocketParameters: string,
    traceArg: string,
    idleTimeoutRaw: string) =

  putEnv("NODE_PATH", nodeModulesPath)
  putEnv("NIX_CODETRACER_EXE_DIR", codetracerExeDir)
  putEnv("LINKS_PATH_DIR", linksPath)

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

  let callerPid = getCurrentProcessId()
  let recordCore = envLoadRecordCore()
  # TODO: discuss how to start backend manager
  # let coreProcess = startCoreProcess(traceId=traceId, recordCore=recordCore, callerPid=callerPid)
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
  # let code = waitForExit(coreProcess)
  # echo "core exit code ", code
  # stopCoreProcess(coreProcess, recordCore)
