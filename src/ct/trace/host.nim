import 
  std / [ options, strformat, strutils, osproc, os ],
  ../utilities/[ env ],
  ../cli/[ interactive_replay ],
  .. / launch / cleanup,
  ../../common/[ types, trace_index, start_utils, paths ],
  ../codetracerconf,
  shell,
  run


# hosts a codetracer server that can be accessed in the browser
# codetracer host --port <port>
#        [--backend-socket-port <port>]
#        [--frontend-socket <port>]
#        [--frontend-socket-parameters <parameters>]
#        <trace-id>/<trace-folder>

const DEFAULT_SOCKET_PORT: int = 5_000

proc hostCommand*(
    port: int,
    backendSocketPort: Option[int],
    frontendSocketPort: Option[int],
    frontendSocketParameters: string,
    traceArg: string) =

  # var env = newStringTable(modeStyleInsensitive)

  # for name, value in envPairs():
  #   env[name] = value

  when defined(builtWithNix):
    putEnv("NODE_PATH", nodeModulesPath)
    putEnv("NIX_CODETRACER_EXE_DIR", nixCodetracerExeDir) 
    # env["NODE_PATH"] = nodeModulesPath
    # env["NIX_CODETRACER_EXE_DIR"] = nixCodetracerExeDir

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
      traceFolderFullPath = expandFilename(traceFolder)
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
  let coreProcess = startCoreProcess(traceId=traceId, recordCore=recordCore, callerPid=callerPid)
  echo "server index ", codetracerExeDir
  var process = startProcess(
    electronExe,
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
      $callerPid
    ],
    options={poParentStreams})
  var electronPid = process.processID
  echo "status code:", waitForExit(process)
  let code = waitForExit(coreProcess)
  echo "core exit code ", code
  stopCoreProcess(coreProcess, recordCore)
