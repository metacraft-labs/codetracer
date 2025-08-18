import
  std/[strformat, strutils, osproc, posix, posix_utils, os, options],
  ../../common/[start_utils, types, trace_index, paths, config],
  ../utilities/[env],
  ../cli/[logging],
  cleanup

var coreProcessId* = -1

proc startBackend*(backendKind: string, isStdio: bool, socketPath: Option[string]) =
  let backendExe =
    if backendKind == "db":
      dbBackendExe
    elif backendKind == "rr":
      let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
      if ctConfig.rrBackend.enabled:
        ctConfig.rrBackend.path
      else:
        echo "ERROR: rr backend not enabled!"
        quit(1)
    else:
      echo "ERROR: Backend kind not recognized, needs to be 'rr' or 'db'"
      quit(1)

  let args =
    if isStdio:
      @["--stdio"]
    elif socketPath.isSome:
      @[socketPath.get()]
    else: 
      echo "ERRROR: Needs to have either --stdio or a valid socket path"
      quit(1)

  let process = startProcess(
    backendExe,
    args = args,
    options = { poParentStreams }
  )

  coreProcessId = process.processId
  onSignal(SIGTERM):
    if coreProcessId != -1:
      echo "ct: stopping core process"
      sendSignal(coreProcessId.Pid, SIGTERM)

  let code = waitForExit(process)
  quit(code)

proc startCore*(traceArg: string, callerPid: int, test: bool) =
  # start_core <trace-program-pattern> <caller-pid> [--test]
  let recordCore = envLoadRecordCore()
  var trace: Trace = nil
  try:
    let traceId = traceArg.parseInt
    trace = trace_index.find(traceId, test=test)
  except ValueError:
    trace = trace_index.findByProgramPattern(traceArg, test=test)
  except CatchableError as e:
    errorMessage fmt"start core loading trace error: {e.msg}"
    quit(1)

  if trace.isNil:
    echo "error: start core: trace not found for ", traceArg
    quit(1)
  # echo trace.repr
  let process = startCoreProcess(traceId = trace.id, recordCore=recordCore, callerPid=callerPid, test=test)
  coreProcessId = process.processId

  onSignal(SIGTERM):
    if coreProcessId != -1:
      echo "ct: stopping core process"
      sendSignal(coreProcessId.Pid, SIGTERM)

  let code = waitForExit(process)
  discard code

