import
  std / [os, osproc, strformat, strtabs, posix, posix_utils],
  json_serialization, json_serialization / std / tables

type
  PathsConfig = Table[string, string]

    # PATH: string
    # LD_LIBRARY_PATH: string
    # PYTHONPATH: string

var ctProcess: Process = nil

proc start(args: seq[string]) =
  let configPath = getEnv(
    "CODETRACER_CT_PATHS",
    getAppDir().parentDir.parentDir.parentDir / "ct_paths.json")
  if not existsFile(configPath):
    echo fmt"error: expected a runtime paths config at {configPath}:"
    echo "  start ct from a prepared dev env (Nix shellHook or non-nix-build/windows/env.{sh,ps1})"
    quit(1)

  try:
    var config = Json.decode(readFile(configPath), PathsConfig)
    var env = newStringTable(modeStyleInsensitive)
    for name, value in envPairs():
      env[name] = value

    for name, ct_value in config:
      if name in env:
        env[name] = ct_value & $PathSep & env[name]
      else:
        env[name] = ct_value
      # echo name, " ", ct_value, " ", env[name]

    # needed by `ct record` when called by the interactive recording form
    # and index.nim, so it can use the correct pid (index.nim sees the pid
    # of the process of ct_wrapper in the tup/dev build)
    let codetracerWrapperPid = getCurrentProcessId()
    env["CODETRACER_WRAPPER_PID"] = $codetracerWrapperPid

    # don't debug/log with echo: breaks ct trace_metadata json output
    # writeFile("ct_wrapper.log", "CT WRAPPER: putting pid " & $codetracerWrapperPid)

    let helperBasePath = getAppDir() / "codetracer_depending_on_env_vars_in_tup"
    let helperPath = when defined(windows): helperBasePath & ".exe" else: helperBasePath

    ctProcess = startProcess(
      helperPath,
      # workingDir = getAppDir().parentDir.parentDir, # repo folder
      args = args,
      env = env,
      options = {poParentStreams, poStdErrToStdOut})
    quit(waitForExit(ctProcess))
  except:
    echo "ct helper error: ", getCurrentExceptionMsg()
    echo "  ct paths config path: ", configPath
    quit(1)

onSignal(SIGTERM):
  if not ctProcess.isNil:
    when defined(windows):
      terminate(ctProcess)
    else:
      discard kill(ctProcess.processID().cint, SIGTERM)
    quit(128 + SIGTERM)

onSignal(SIGINT):
  if not ctProcess.isNil:
    when defined(windows):
      terminate(ctProcess)
    else:
      discard kill(ctProcess.processID().cint, SIGINT)
    quit(128 + SIGINT)

start(commandLineParams())
