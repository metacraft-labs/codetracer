import
  std/[os, sequtils, algorithm, strutils],
  ../globals

proc envLoadRecordCore*: bool =
  let recordCoreRaw = getEnv(CODETRACER_RECORD_CORE, "")
  recordCoreRaw == "true"

proc readRawEnv*: string =
  var variables: seq[(string, string)] = @[]
  for name, value in envPairs():
    variables.add((name, value))
  sorted(variables).mapIt($it[0] & "=" & $it[1]).join("\n")
