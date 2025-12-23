import std/[sequtils, options, os, strutils ],
  ../../common/[paths, types, path_utils ],
  ../globals

when not defined(posix):
  import std/[osproc, strtabs]

when defined(posix):
  import std / posix

type
  ElectronLaunchMode* {.pure.} = enum
    Default
    ArbExplorer = "arb.explorer"

proc launchElectron*(
    args: seq[string] = @[],
    trace: Trace = nil,
    mode = ElectronLaunchMode.Default,
    recordCore: bool = false,
    test: bool = false,
    inspect: Option[string] = none(string),
    remoteDebuggingPort: Option[string] = none(string)) =
  ## Launch Electron, replacing the current process via execv on POSIX.
  ## On non-POSIX platforms, spawns Electron as a child process and waits.
  ## This function does not return on POSIX systems.
  createDir codetracerCache
  let saveDir = codetracerShareFolder / "saves/"
  createDir saveDir

  # sometimes things like "--no-sandbox" are useful e.g. for now for
  # experimenting with appimage
  let optionalElectronArgs = getEnv("CODETRACER_ELECTRON_ARGS", "").splitWhitespace()

  # Set up environment variables
  putEnv("ELECTRON_ENABLE_LOGGING", "1")
  when defined(builtWithNix):
    putEnv("NODE_PATH", nodeModulesPath)
  putEnv("NIX_CODETRACER_EXE_DIR", codetracerExeDir)
  putEnv("LINKS_PATH_DIR", linksPath)
  if mode != ElectronLaunchMode.Default:
    putEnv("CODETRACER_LAUNCH_MODE", $mode)

  # https://www.electronjs.org/docs/latest/api/environment-variables#electron_enable_logging
  putEnv("ELECTRON_LOG_FILE", ensureLogPath(
    "frontend",
    getCurrentProcessId(),
    "frontend",
    0,
    "log"
  ))

  ensureExists(electronExe)

  # Build electron args:
  # [runtimeFlags] [entryPoint] [appArgs] [optionalElectronArgs]
  var runtimeFlags: seq[string] = @[]
  if inspect.isSome:
    runtimeFlags.add("--inspect=" & inspect.get)
  if remoteDebuggingPort.isSome:
    runtimeFlags.add("--remote-debugging-port=" & remoteDebuggingPort.get)

  var entryPoint: string
  var appArgs: seq[string]
  if args.len > 0:
    entryPoint = electronIndexPath
    appArgs = args
    if not trace.isNil:
      appArgs = appArgs.concat(@["--caller-pid", $getCurrentProcessId()])
  else:
    entryPoint = codetracerExeDir
    appArgs = @[]

  let electronArgs = runtimeFlags.concat(@[entryPoint]).concat(appArgs).concat(optionalElectronArgs)

  when defined(posix):
    # Use execv to replace current process with Electron.
    # This allows Playwright to connect via CDP to the Electron process.
    let execvArgsCount = electronArgs.len + 1
    var execvArgs = cast[cstringArray](alloc0((execvArgsCount + 1) * sizeof(cstring)))
    execvArgs[0] = electronExe.cstring
    for i, arg in electronArgs:
      execvArgs[i + 1] = arg.cstring
    execvArgs[execvArgsCount] = nil

    discard execv(electronExe.cstring, execvArgs)
    # execv only returns on error
    quit(1)
  else:
    # Fallback for non-POSIX: spawn as child process
    var env = newStringTable(modeStyleInsensitive)
    for name, value in envPairs():
      env[name] = value

    var processUI = startProcess(
      electronExe,
      workingDir = getCurrentDir(),
      args = electronArgs,
      env = env,
      options = {poParentStreams})
    electronPid = processUI.processID
    let electronExitCode = waitForExit(processUI)
    quit(electronExitCode)

when defined(posix):
  proc wrapElectron*(electronArgs: seq[string], appArgs: seq[string]) =
    ## Launch Electron via execv, replacing the current process.
    ## Used by `ct electron` command.
    ## electronArgs: Electron/Node runtime flags (e.g., --inspect=0) - passed before the app entry point
    ## appArgs: Application arguments (e.g., edit /path) - passed after the app entry point

    # Set up environment variables
    putEnv("ELECTRON_ENABLE_LOGGING", "1")
    putEnv("NIX_CODETRACER_EXE_DIR", codetracerExeDir)
    putEnv("LINKS_PATH_DIR", linksPath)

    # Build execv args: electron [electronArgs] [indexPath] [appArgs]
    let finalArgs = electronArgs.concat(@[electronIndexPath]).concat(appArgs)
    let execvArgsCount = finalArgs.len + 1

    var execvArgs = cast[cstringArray](alloc0((execvArgsCount + 1) * sizeof(cstring)))
    execvArgs[0] = electronExe.cstring
    for i, arg in finalArgs:
      execvArgs[i + 1] = arg.cstring
    execvArgs[execvArgsCount] = nil

    discard execv(electronExe.cstring, execvArgs)
    # execv only returns on error
    quit(1)

else:
  proc wrapElectron*(electronArgs: seq[string], appArgs: seq[string]) =
    echo "UNSUPPORTED: ct electron command is not supported on this platform"
    quit(1)
