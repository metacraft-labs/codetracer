import std / [os, osproc, strformat]
import types, paths, lang, trace_index, ct_logging, config
import ../ct/cli/build


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

  let ct_config = loadConfig(folder=getCurrentDir(), inTest=false)

  let workdir = codetracerInstallDir
  let options: set[ProcessOption] = {poParentStreams}
  let traceFolder = trace.outputFolder
  # TODO: not sure why noOutput true for
  # nix build: if not noOutput: {poParentStreams} else: {}

  putEnv("CODETRACER_LINKS_PATH", linksPath)
  if not recordCore:
    debugprint "not recordCore"
    debugprint "noOutput ", noOutput
    debugprint "options ", options
    if IS_DB_BASED[trace.lang]:
      result = startProcess(
        dbBackendExe,
        workingDir = workdir,
        args = @[
          $callerPid,
          traceFolder / "trace.json",
          traceFolder / "trace_metadata.json"
        ],
        options=options)
    elif ct_config.rrBackend.enabled:
      var env = setup_env(ct_config.rrBackend.ctPaths)
      result = startProcess(
        ct_config.rrBackend.path,
        workingDir = workdir,
        args = @[
          "dispatcher",
          virtualizationLayersExe,
          $callerPid
        ],
        env = env,
        options = options)
    else:
      echo "The specified recording is not compatible with the current version of CodeTracer"
      quit(1)
  else:
    result = startProcess(
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
