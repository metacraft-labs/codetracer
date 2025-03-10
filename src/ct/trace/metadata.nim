import std/strutils,
  ../../common/[trace_index],
  json_serialization

# Returns a number of types of info from trace_index in JSON format
proc traceMetadata*(
    idArg: Option[int], pathArg: Option[string],
    programArg: Option[string], recordPidArg: Option[int],
    recent: bool, recentLimit: int, test: bool) =
  if idArg.isSome:
    let trace = trace_index.find(idArg.get, test)
    echo Json.encode(trace)
  elif pathArg.isSome:
    var path = pathArg.get
    if path.len > 2 and path.startsWith('"') and path.endsWith('"'):
      path = path[1..^2]
    let trace = trace_index.findByPath(path, test)
    echo Json.encode(trace)
  elif programArg.isSome:
    let trace = trace_index.findByProgramPattern(programArg.get, test)
    echo Json.encode(trace)
  elif recordPidArg.isSome:
    let trace = trace_index.findByRecordProcessId(recordPidArg.get, test)
    echo Json.encode(trace)
  elif recent:
    let traces = trace_index.findRecentTraces(limit=recentLimit, test)
    echo Json.encode(traces)
  else:
    echo "null"
