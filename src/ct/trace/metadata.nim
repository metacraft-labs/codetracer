import std/strutils,
  ../../common/[trace_index],
  json_serialization

# `Trace.lang` crosses the `ct trace-metadata` -> Electron main process hop
# as the enum's NAME, never its ordinal (LRS-4, 2026-09-21).  The rule that
# makes `Json.encode(trace)` below spell the name is `serializesAsTextInJson(Lang)`
# in `src/common/trace_index.nim` (imported here), beside the persisted
# column's own name-only rule; see the comment there for the finding that
# put it in.

# Returns a number of types of info from trace_index in JSON format
proc traceMetadata*(
    # M-REC-2: ``idArg`` is a UUIDv7 recording-id string.  Proc/param
    # names unchanged (M-REC-3 owns the rename).
    idArg: Option[string], pathArg: Option[string],
    programArg: Option[string], recordPidArg: Option[int],
    recent: bool, recentFolders: bool, addRecentFolder: Option[string],
    recentLimit: int, test: bool) =
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
  elif recentFolders:
    let folders = trace_index.findRecentFolders(limit=recentLimit, test)
    echo Json.encode(folders)
  elif addRecentFolder.isSome:
    trace_index.addRecentFolder(addRecentFolder.get, test)
    echo "null"
  else:
    echo "null"
