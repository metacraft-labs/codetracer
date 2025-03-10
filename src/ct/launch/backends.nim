import
  std/[strformat, strutils, osproc],
  ../../common/[start_utils, types, trace_index],
  ../utilities/[env],
  ../cli/[logging],
  cleanup

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
  let code = waitForExit(process)
  discard code
  stopCoreProcess(process, recordCore)
