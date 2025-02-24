## Procedures for managing task and event directories

import strformat, os
import task_and_event

const codetracerTmpPath = "/tmp/codetracer" ## Temp run directory used by codetracer
const pipeTmpPath = "/tmp/codetracer_cache" ## Temp pipe directory used by codetracer

func runDirFor*(callerProcessPid: int): string =
  ## Return the tmp run directory path for the given `callerProcessPid`.
  codetracerTmpPath / fmt"run-{callerProcessPid}"

func pipeRunDirFor*(callerProcessPid: int): string =
  ## Return the tmp pipe directory path for the given `callerProcessPid`.
  pipeTmpPath / fmt"run-{callerProcessPid}"

when not defined(js):
  template ensureDir*(dir: string) =
    ## Ensure the directory exists
    createDir dir
else:
  import jsffi

  let fs = require("fs")
  template ensureDir*(dir: string) =
    ## Ensure the directory exists
    fs.mkdirSync(dir.cstring, js{recursive: true})

proc ensureLogPath*(
    logKind: string,
    callerProcessPid: int,
    process: string,
    instanceIndex: int,
    extension: string): string =
  ## Ensure the temp run directory for the given `callerProcessPid` exists
  ## and return the log path: `<runDir>/<logKind>_<process>_<instanceIndex>.<extension>`
  let runDir = runDirFor(callerProcessPid)
  ensureDir(runDir)
  runDir / fmt"{logKind}_{process}_{instanceIndex}.{extension}"

proc ensureArgPathFor*(callerProcessPid: int, taskId: TaskId): string =
  ## Ensure the temp args directory for the given `callerProcessPid` exists in the run dir
  ## and return arg file path: `<runDir>/args/<taskId>.json`
  let runDir = runDirFor(callerProcessPid)
  let argDir = runDir / "args"
  ensureDir(argDir)
  argDir / fmt"{taskId}.json"

proc ensureEventPathFor*(callerProcessPid: int, eventId: EventId): string =
  ## Ensure the temp events directory for the given `callerProcessPid` exists in the run dir
  ## and return the events file path: `<runDir>/events/<eventId>.json`
  let runDir = runDirFor(callerProcessPid)
  let eventsDir = runDir / "events"
  ensureDir(eventsDir)
  eventsDir / fmt"{eventId}.json"

proc ensureResultPathFor*(callerProcessPid: int, taskId: TaskId): string =
  ## Ensure the temp results directory for the given `callerProcessPid` exists in the run dir
  ## and return the results file path: `<runDir>/results/<taskId>.json`
  let runDir = runDirFor(callerProcessPid)
  let resultsDir = runDir / "results"
  ensureDir(resultsDir)
  resultsDir / fmt"{taskId}.json"

proc ensureAckPathFor*(callerProcessPid: int, name: string, sessionIndex: int): string =
  ## Ensure the temp ack directory for the given `callerProcessPid` exists in the run dir
  ## and return the results file path: `<runDir>/ack/<name>_<sessionIndex>.txt`
  let runDir = runDirFor(callerProcessPid)
  let ackDir = runDir / "ack"
  ensureDir(ackDir)
  ackDir / fmt"{name}_{sessionIndex}.txt"

proc ensureCancelPathFor*(callerProcessPid: int, name: string, sessionIndex: int): string =
  ## Ensure the temp cancel directory for the given `callerProcessPid` exists in the run dir
  ## and return the cancel file path: `<runDir>/cancel/<name>_<sessionIndex>.txt`
  let runDir = runDirFor(callerProcessPid)
  let cancelDir = runDir / "cancel"
  ensureDir(cancelDir)
  cancelDir / fmt"{name}_{sessionIndex}.txt"

proc ensureRRGDBRawPathFor*(callerProcessPid: int, name: string, instanceIndex: int): string =
  ## Ensure the temp run directory for the given `callerProcessPid` exists
  ## and return rr_gdb raw file path: `<runDir>/rr_gdb_raw_<name>_<instanceIndex>.txt`
  let runDir = runDirFor(callerProcessPid)
  ensureDir(runDir)
  runDir / fmt"rr_gdb_raw_{name}_{instanceIndex}.txt"

# not used currently: keep if we decide we need it again:
# proc ensureInstanceIndexPathFor*(callerProcessPid: int, name: string): string =
  # let runDir = runDirFor(callerProcessPid)
  # ensureDir(runDir)
  # runDir / fmt"instance_index_{callerProcessPid}_{name}.txt"

proc ensureRRGDBInputPipePathFor*(callerProcessPid: int, name: string, instanceIndex: int): string =
  ## Ensure the temp pipe directory for the given `callerProcessPid` exists
  ## and return the rrgdb input pipe file path: `<pipeRunDir>/rr_gdb_<name>_<instance_index>.pipe`
  let pipeRunDir = pipeRunDirFor(callerProcessPid)
  ensureDir(pipeRunDir)
  pipeRunDir / fmt"rr_gdb_{name}_{instanceIndex}.pipe"

proc ensureTaskProcessPipePathFor*(callerProcessPid: int, name: string, instanceIndex: int): string =
  ## Ensure the temp pipe directory for the given `callerProcessPid` exists
  ## and return task process pipe file path: `<pipeRunDir>/task_process_<name>_<instanceIndex>.pipe`
  let pipeRunDir = pipeRunDirFor(callerProcessPid)
  ensureDir(pipeRunDir)
  pipeRunDir / fmt"task_process_{name}_{instanceIndex}.pipe"

proc ensureTaskProcessStatePathFor*(callerProcessPid: int, name: string): string =
  ## Ensure the temp run directory for the given `callerProcessPid` exists
  ## and return the task process state file path: `<runDir>/task_process_state_<name>.json`
  let runDir = runDirFor(callerProcessPid)
  ensureDir(runDir)
  runDir / fmt"task_process_state_{name}.json"

proc ensureProcessesLogPathFor*(callerProcessPid: int): string =
  ## Ensure the temp run directory for the given `callerProcessPid` exists
  ## and return the process log path: `<runDir>/processes.txt`
  let runDir = runDirFor(callerProcessPid)
  ensureDir(runDir)
  runDir / "processes.txt"

proc ensureClientResultsPath*(callerProcessPid: int): string =
  ## Ensure the temp run directory for the given `callerProcessPid` exists
  ## and return the client results path: `<runDir>/client_results.txt`
  let runDir = runDirFor(callerProcessPid)
  ensureDir(runDir)
  runDir / "client_results.txt"
