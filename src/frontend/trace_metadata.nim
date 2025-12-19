import
  std / [jsffi, jsconsole, async, strformat],
  results,
  types, paths,
  lib/[ jslib, electron_lib ],
  ../common/ct_logging

proc findRawTraceWithCodetracer(app: ElectronApp, traceId: int): Future[cstring] {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring(fmt"--id={traceId}")])

  let isOk = res.isOk

  debugPrint "raw trace-metadata result ", res
  if isOk:
    let raw = res.value
    return raw
  else:
    echo "error: trying to run the codetracer trace metadata command: ", res.error
    app.quit(1)

  # should be an unreachable default..
  # otherwise it doesn't compiler, maybe because of my async
  # template/macro, sorry
  return cstring""

proc findTraceWithCodetracer*(app: ElectronApp, traceId: int): Future[Trace] {.async.} =
  let raw = await app.findRawTraceWithCodetracer(traceId)
  let trace = cast[Trace](JSON.parse(raw))
  return trace

proc findRecentTracesWithCodetracer*(app: ElectronApp, limit: int): Future[seq[Trace]] {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring"--recent", cstring(fmt"--limit={limit}")])

  if res.isOk:
    let raw = res.value
    let traces = cast[seq[Trace]](JSON.parse(raw))
    return traces
  else:
    echo "error: trying to run the codetracer trace metadata command: ", res.error
    app.quit(1)

  # should be an unreachable default..
  # otherwise it doesn't compiler, maybe because of my async
  # template/macro, sorry
  var emptyTraces: seq[Trace] = @[]
  return emptyTraces

proc findRecentTransactions*(app: ElectronApp, limit: int): Future[seq[StylusTransaction]] {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"arb",  cstring"listRecentTx"]
  )

  if res.isOk:
    let raw = res.value
    try:
      let traces = cast[seq[StylusTransaction]](JSON.parse(raw))
      return traces
    except:
      # assuming that json parse failed => assuming this is raw error output and output it
      echo ""
      echo "error: loading recent transactions problem: ", raw, " (or possibly invalid json)"
      app.quit(1)
  else:
    echo "error: trying to run the codetracer arb listRecentTx command: ", res.error
    app.quit(1)

  # should be an unreachable default..
  # otherwise it doesn't compiler, maybe because of my async
  # template/macro, sorry
  var emptyTraces: seq[StylusTransaction] = @[]
  return emptyTraces

proc findTraceByRecordProcessId*(app: ElectronApp, pid: int): Future[Trace] {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring(fmt"--record-pid={pid}")])

  if res.isOk:
    let raw = res.value
    let trace = cast[Trace](JSON.parse(raw))
    return trace
  else:
    echo "error: trying to run the codetracer trace metadata command: ", res.error
    app.quit(1)

proc findByPath*(app: ElectronApp, path: cstring): Future[Trace] {.async.} =
  # expects folder with a trailing slash currently, so we should make sure
  # we're passign such to `findByPath`, otherwise it doesn't find a trace
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring(fmt("--path=\"{path}\""))])

  if res.isOk:
    let raw = res.value
    let trace = cast[Trace](JSON.parse(raw))
    return trace
  else:
    echo "error: trying to run the codetracer trace metadata command: ", res.error
    app.quit(1)

proc findRecentFoldersWithCodetracer*(app: ElectronApp, limit: int): Future[seq[RecentFolder]] {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring"--recent-folders", cstring(fmt"--limit={limit}")])

  if res.isOk:
    let raw = res.value
    let folders = cast[seq[RecentFolder]](JSON.parse(raw))
    return folders
  else:
    echo "error: trying to run the codetracer trace metadata command: ", res.error
    app.quit(1)

  # should be an unreachable default..
  # otherwise it doesn't compiler, maybe because of my async
  # template/macro, sorry
  var emptyFolders: seq[RecentFolder] = @[]
  return emptyFolders
