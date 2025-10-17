import
  ../../common/trace_index,
  logging,
  interactive_replay

type
  ListFormat = enum FormatText, FormatJson
  ListTarget {.pure.} = enum Local, Remote


proc parseListFormat(arg: string): ListFormat =
  if arg == "text":
    FormatText
  elif arg == "json":
    FormatJson
  else:
    errorMessage "error: expected --format text/json"
    quit(1)


proc parseListTarget(arg: string): ListTarget =
  if arg == "local":
    ListTarget.Local
  elif arg == "remote":
    ListTarget.Remote
  else:
    errorMessage "error: expected local or remote"
    quit(1)


proc listLocalTraces(format: ListFormat) =
  let traces = trace_index.all(test=false)
  case format:
  of FormatText:
    echo tracesInText(traces)
  of FormatJson:
    echo tracesInJson(traces)


proc listCommand*(rawTarget: string, rawFormat: string) =
  # list [local/remote (default local)] [--format text/json (default text)]
  let target = parseListTarget(rawTarget)
  let format = parseListFormat(rawFormat)
  case target:
  of ListTarget.Local:
    listLocalTraces(format)
  of ListTarget.Remote:
    echo "error: unsupported currently!"
    # listRemoteTraces(format)
