import
  std/[ json, os, osproc, strutils ],
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
