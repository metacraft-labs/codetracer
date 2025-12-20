import std/[sequtils, os, osproc, strutils, strtabs ],
  ../../common/[paths, types, path_utils ],
  ../globals

type
  ElectronLaunchMode* {.pure.} = enum
    Default
    ArbExplorer = "arb.explorer"

# returns true only if it should restart
proc launchElectron*(
    args: seq[string] = @[],
    trace: Trace = nil,
    mode = ElectronLaunchMode.Default,
    recordCore: bool = false,
    test: bool = false): bool =
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

  if mode != ElectronLaunchMode.Default:
    env["CODETRACER_LAUNCH_MODE"] = $mode

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
    ensureExists(electronExe)
    var electronArgs = @[electronIndexPath].concat(args)
    if not trace.isNil:
      electronArgs = electronArgs.concat(@["--caller-pid", $getCurrentProcessId()])
    electronArgs = electronArgs.concat(optionalElectronArgs)
    var processUI = startProcess(
      electronExe,
      workingDir = workdir,
      args = electronArgs,
      env = env,
      options = {poParentStreams})
    electronPid = processUI.processID
    let electronExitCode = waitForExit(processUI)
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

when defined(posix):
  import std / posix

  proc wrapElectron*(args: seq[string]) =
    let startIndex = getEnv("CODETRACER_START_INDEX", "") == "1"

    # internal ct runs should be normal, not wrapping electron again
    putEnv("CODETRACER_WRAP_ELECTRON", "")
    putEnv("CODETRACER_START_INDEX", "")

    # Ensure Electron receives the same path hints that launchElectron() provides.
    # The UI tests set CODETRACER_WRAP_ELECTRON=1 so we execv() directly here,
    # bypassing the code that would normally populate these env vars.
    if getEnv("LINKS_PATH_DIR", "") == "" and linksPath.len > 0:
      putEnv("LINKS_PATH_DIR", linksPath)
    if getEnv("NIX_CODETRACER_EXE_DIR", "") == "" and
        codetracerExeDir.len > 0 and codetracerExeDir != "<unknown>":
      putEnv("NIX_CODETRACER_EXE_DIR", codetracerExeDir)
    if getEnv("ELECTRON_ENABLE_LOGGING", "") == "":
      putEnv("ELECTRON_ENABLE_LOGGING", "1")

    let execvArgsCount = if startIndex: args.len + 2 else: args.len + 1

    # copied and adapted from nim forum: nucky9 and Araq:
    #   https://forum.nim-lang.org/t/7415#47044
    var execvArgs = cast[cstringArray](alloc0((execvArgsCount + 1) * sizeof(cstring)))
    execvArgs[0] = electronExe.cstring
    for i, arg in args:
      execvArgs[i + 1] = arg.cstring

    if startIndex:
      execvArgs[execvArgsCount - 1] = electronIndexPath.cstring

    execvArgs[execvArgsCount] = nil

    discard execv(
      electronExe.cstring,
      execvArgs)

    #   options = {poParentStreams})
    # let code = waitForExit(process)
    # quit(code)

else:
  proc wrapElectron*(args: seq[string]) =
    echo "UNSUPPORTED: wrapping electron with ct currently on this platform"
    # TODO find the equivalent of `execv` on windows, if it makes sense for
    # the e2e (playwright) case
