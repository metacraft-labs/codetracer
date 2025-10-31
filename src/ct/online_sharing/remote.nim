import
  std/[ json, os, osproc, strutils, options ],
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
    let process = startProcess(execPath, args = args, options = {poEchoCmd, poParentStreams})
    result = waitForExit(process)
  except CatchableError as err:
    echo "Failed to launch ct-remote (" & execPath & "): " & err.msg
    result = 1

proc loginCommand*(defaultOrg: Option[string]) =
  var args = @["login"]
  if defaultOrg.isSome:
    args.add("--default-org")
    args.add(defaultOrg.get)
  quit(runCtRemote(args))

proc updateDefaultOrg*(newOrg: string) =
  quit(runCtRemote(@["update-default-org", newOrg]))
