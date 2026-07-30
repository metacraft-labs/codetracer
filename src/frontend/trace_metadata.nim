import
  std / [jsffi, jsconsole, asyncjs, strformat],
  results,
  types, paths,
  lib/[ jslib, electron_lib ],
  ../common/ct_logging

# ---------------------------------------------------------------------------
# Trace metadata normalization
# ---------------------------------------------------------------------------
#
# ``ct trace-metadata`` serializes the ``Trace`` record with
# ``json_serialization``'s ``Json.encode``, which writes enum fields as
# their *string names* (e.g. ``"lang": "LangPythonDb"``,
# ``"calltraceMode": "FullRecord"``).  The renderer/Electron side, however,
# reconstructs the trace with a raw ``cast[Trace](JSON.parse(...))`` — a
# reinterpret that expects every enum field to already hold the integer
# ordinal that Nim's JS backend uses for enum values at runtime.
#
# Left unconverted, ``trace.lang`` is a JS *string*.  Any later
# ``lang in {…}`` set-membership test compiles (because ``set[Lang]``
# exceeds 32 bits) to ``BigInt(ord(lang))`` — and ``BigInt("LangPythonDb")``
# throws ``Cannot convert LangPythonDb to a BigInt``, an uncaught renderer
# exception that aborts trace loading before the editor panel mounts.
#
# ``normalizeTraceEnums`` rewrites the string enum fields on the parsed JS
# object to the integer ordinals the frontend's ``cast[Trace]`` assumes.
# The ordinals mirror ``Lang`` / ``CalltraceMode`` in
# ``common/common_lang.nim`` and ``common_types/debugger_features/call.nim``
# (kept in lockstep with the Rust ``Lang`` enum's ``#[repr(u8)]`` order).

proc normalizeTraceEnumsJs(trace: JsObject) {.importjs: """
(function(t) {
  if (!t) return;
  var LANG = {
    LangC:0, LangCpp:1, LangRust:2, LangNim:3, LangGo:4, LangPascal:5,
    LangFortran:6, LangD:7, LangCrystal:8, LangLean:9, LangJulia:10,
    LangAda:11, LangPython:12, LangRuby:13, LangRubyDb:14, LangJavascript:15,
    LangLua:16, LangAsm:17, LangNoir:18, LangRustWasm:19, LangCppWasm:20,
    LangPythonDb:21, LangUnknown:22, LangBash:23, LangZsh:24, LangSolidity:25,
    LangMasm:26, LangSway:27, LangMove:28, LangPolkavm:29, LangCairo:30,
    LangCircom:31, LangLeo:32, LangTolk:33, LangAiken:34, LangCadence:35,
    LangSolana:36, LangElixir:37, LangErlang:38, LangPhp:39
  };
  var MODE = {
    NoInstrumentation:0, CallKeyOnly:1, RawRecordNoValues:2, FullRecord:3
  };
  if (typeof t.lang === 'string') {
    t.lang = (t.lang in LANG) ? LANG[t.lang] : LANG.LangUnknown;
  }
  if (typeof t.calltraceMode === 'string') {
    t.calltraceMode = (t.calltraceMode in MODE) ? MODE[t.calltraceMode] : MODE.FullRecord;
  }
})(#)
""".}
  ## Rewrite string-encoded ``lang`` / ``calltraceMode`` enum fields on a
  ## parsed trace JS object into their integer ordinals.

proc normalizeTraceEnums(trace: Trace) =
  if not trace.isNil:
    normalizeTraceEnumsJs(cast[JsObject](trace))

proc findRawTraceWithCodetracer(app: ElectronApp, traceId: cstring): Future[cstring] {.async.} =
  ## M-REC-2: ``traceId`` is a UUIDv7 recording-id string.
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

proc findTraceWithCodetracer*(app: ElectronApp, traceId: cstring): Future[Trace] {.async.} =
  ## M-REC-2: ``traceId`` is a UUIDv7 recording-id string.
  let raw = await app.findRawTraceWithCodetracer(traceId)
  let trace = cast[Trace](JSON.parse(raw))
  normalizeTraceEnums(trace)
  return trace

proc findRecentTracesWithCodetracer*(app: ElectronApp, limit: int): Future[seq[Trace]] {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring"--recent", cstring(fmt"--limit={limit}")])

  if res.isOk:
    let raw = res.value
    let traces = cast[seq[Trace]](JSON.parse(raw))
    for trace in traces:
      normalizeTraceEnums(trace)
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
    normalizeTraceEnums(trace)
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
    normalizeTraceEnums(trace)
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
