import
  std/[ json, os, osproc, strutils, options, sequtils ],
  ../../common/[ paths ],
  ../cli/[ logging, list, help, build]

proc runCtRemote*(args: seq[string]): int =
  var execPath = ctRemoteExe
  if not fileExists(execPath):
    execPath = findExe("ct-remote")

  if execPath.len == 0 or not fileExists(execPath):
    echo "Failed to locate ct-remote. Ensure it is installed alongside ct or available on PATH."
    return 1

  try:
    let fullArgs = args.concat(@["--binary-name", "ct remote"])
    var options = {poParentStreams}
    if getEnv("CODETRACER_DEBUG_CT_REMOTE", "0") == "1":
      options.incl(poEchoCmd)
    let process = startProcess(execPath, args = fullArgs, options = options)
    result = waitForExit(process)
  except CatchableError as err:
    echo "Failed to launch ct-remote (" & execPath & "): " & err.msg
    result = 1

proc loginCommand*(defaultOrg: Option[string]) =
  var args = @["login"]
  if defaultOrg.isSome:
    args.add("-org")
    args.add(defaultOrg.get)
  quit(runCtRemote(args))

proc updateDefaultOrg*(newOrg: string) =
  quit(runCtRemote(@["set-default-org", "-org", newOrg]))
