import std/[sequtils, os, osproc, strutils, strtabs ],
  ../../common/[paths, types, path_utils, start_utils],
  ../globals,
  cleanup

proc launchElectron*(args: seq[string] = @[], trace: Trace = nil, recordCore: bool = false, test: bool = false): bool =
  createDir codetracerCache
  let saveDir = codetracerShareFolder / "saves/"
  let workdir = getCurrentDir()
  createDir saveDir

  # sometimes things like "--no-sandbox" are useful e.g. for now for
  # experimenting with appimage
  let optionalElectronArgs = getEnv("CODETRACER_ELECTRON_ARGS", "").splitWhitespace()

  var env = newStringTable(modeStyleInsensitive)
  for name, value in envPairs():
    env[name] = value
  env["ELECTRON_ENABLE_LOGGING"] = "1"

  when defined(builtWithNix):
    env["NODE_PATH"] = nodeModulesPath

  env["NIX_CODETRACER_EXE_DIR"] = codetracerExeDir
  env["LINKS_PATH_DIR"] = linksPath

  # https://www.electronjs.org/docs/latest/api/environment-variables#electron_enable_logging
  env["ELECTRON_LOG_FILE"] = ensureLogPath(
    "frontend",
    getCurrentProcessId(),
    "frontend",
    0,
    "log"
  )

  if args.len > 0:
    if not trace.isNil:
      let process = startCoreProcess(traceId=trace.id, recordCore=recordCore, callerPid=getCurrentProcessId(), test=test)
      ensureExists(electronExe)
      let args = @[
          electronIndexPath].
            concat(args).
            concat(@["--caller-pid", $getCurrentProcessId()].
            concat(optionalElectronArgs))
      var processUI = startProcess(
        electronExe,
        workingDir = workdir,
        args = args,
        env = env,
        options = {poParentStreams})
      electronPid = processUI.processID
      let electronExitCode = waitForExit(processUI)
      stopCoreProcess(process, recordCore)
      sleep(100)

      return electronExitCode == RESTART_EXIT_CODE

  else:
    ensureExists(electronExe)
    let args = @[codetracerExeDir].concat(args).concat(optionalElectronArgs)
    var processUI = startProcess(
      electronExe,
      workingDir = workdir,
      args = args,
      env = env,
      options={poParentStreams})
    electronPid = processUI.processID

    # TODO: seems some processes don't exit
    let electronExitCode = waitForExit(processUI)
    return electronExitCode == RESTART_EXIT_CODE

  return false
