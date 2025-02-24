import std / [os, osproc, strformat]
import types, paths, lang, trace_index, ct_logging

proc startCustomBackend(traceFolder: string, recordCore: bool, callerPid: int, noOutput: bool = false): Process

proc startCoreProcess*(traceId: int, recordCore: bool, callerPid: int, test: bool = false, noOutput: bool = false): Process =
  let trace = trace_index.find(traceId, test=test)
  if trace.isNil:
    echo fmt"error: trace not found for {traceId}"
    quit(1)

  let lastStartPidPath = codetracerTmpPath / "last-start-pid"
  createDir(codetracerTmpPath)
  writeFile(lastStartPidPath, $callerPid & "\n")
  let traceLogsPath = codetracerTmpPath / fmt"run-{callerPid}"
  createDir(traceLogsPath)

  try:
    removeFile(codetracerTmpPath / "last")
    createSymlink(traceLogsPath, codetracerTmpPath / "last")
  except OsError as e:
    echo "warning: tried to create symlink to last, but error: ", e.msg
    echo "continuing despite that, you just won't have the special `last` symlink"

  if IS_DB_BASED[trace.lang]:
    startCustomBackend(trace.outputFolder, recordCore, callerPid, noOutput)
  else:
    echo "The specified recording is not compatible with the current version of CodeTracer"
    quit 1

proc startCustomBackend(traceFolder: string, recordCore: bool, callerPid: int, noOutput: bool = false): Process =
  # echo "  custom backend path", dbBackendExe

  let workdir = codetracerInstallDir
  let options: set[ProcessOption] = {poParentStreams}

  # TODO: not sure why noOutput true for
  # nix build: if not noOutput: {poParentStreams} else: {}

  putEnv("CODETRACER_LINKS_PATH", linksPath)
  let process = if not recordCore:
    debugprint "not recordCore"
    debugprint "noOutput ", noOutput
    debugprint "options ", options

    startProcess(
      dbBackendExe,
      workingDir = workdir,
        args = @[
          $callerPid,
          traceFolder / "trace.json",
          traceFolder / "trace_metadata.json"
        ],
        options=options)
    else:
      startProcess(
        codetracerExe,
        workingDir = workdir,
        args = @[
          "record",
          dbBackendExe,
          $callerPid,
          traceFolder / "trace.json",
          traceFolder / "trace_metadata.json"
        ],
        options=options)
  process
