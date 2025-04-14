import
  std/[os, sequtils, algorithm, strutils],
  ../globals

const TRACE_SHARING_DISABLED_ERROR_MESSAGE* = """
trace sharing disabled in config!
you can enable it by editing `$HOME/.config/codetracer/.config.yaml`
and toggling `traceSharingEnabled` to true
"""

proc envLoadRecordCore*: bool =
  let recordCoreRaw = getEnv(CODETRACER_RECORD_CORE, "")
  recordCoreRaw == "true"

proc readRawEnv*: string =
  var variables: seq[(string, string)] = @[]
  for name, value in envPairs():
    variables.add((name, value))
  sorted(variables).mapIt($it[0] & "=" & $it[1]).join("\n")
