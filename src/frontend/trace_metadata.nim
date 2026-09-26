import
  std / [jsffi, jsconsole, asyncjs, strformat, strutils],
  results,
  types, paths, lang,
  lib/[ jslib, electron_lib ],
  ../common/ct_logging

# ---------------------------------------------------------------------------
# Trace metadata normalization
# ---------------------------------------------------------------------------
#
# ``ct trace-metadata`` serializes the ``Trace`` record with
# ``json_serialization``'s ``Json.encode``, which writes ``lang`` as its
# *string name* (``"lang": "LangPythonDb"``) since LRS-4 (2026-09-21).  The
# renderer/Electron side, however, reconstructs the trace with a raw
# ``cast[Trace](JSON.parse(...))`` — a reinterpret that expects every enum
# field to already hold the integer ordinal that Nim's JS backend uses for
# enum values at runtime.
#
# **Correction (LRS-4).**  This comment used to say ``Json.encode`` writes
# enum fields as their string names, ``calltraceMode`` included.  It did
# not: the vendored ``json_serialization`` writes an enum as ``ord(value)``
# unless the type opts in with ``serializesAsTextInJson``, and none had.  So
# ``"lang"`` arrived here as the INTEGER, the string branch below never ran,
# and the integer went straight through ``cast[Trace]`` — an ordinal on the
# ``ct`` -> Electron hop that every document in the Lang series believed
# carried the name.  ``src/common/trace_index.nim`` now opts ``Lang`` in,
# so the name is what arrives and the decoder below is what runs.
# ``calltraceMode`` kept arriving as an integer until LRS-6 (2026-09-23)
# opted it in as well; until then the string branch of the hand-written
# ``MODE`` map that decoded it was dead code (see below).
#
# Left unconverted, a string ``trace.lang`` would break the renderer: any
# ``lang in {…}`` set-membership test compiles (because ``set[Lang]``
# exceeds 32 bits) to ``BigInt(ord(lang))`` — and ``BigInt("LangPythonDb")``
# throws ``Cannot convert LangPythonDb to a BigInt``, an uncaught renderer
# exception that aborts trace loading before the editor panel mounts.
#
# ``normalizeTraceEnums`` rewrites the string enum fields on the parsed JS
# object to the values the frontend's ``cast[Trace]`` assumes.
#
# **The ``lang`` half is ``parseEnum[Lang]`` (LRS-4, 2026-09-21).**  It used
# to be a hand-written JS object literal, ``var LANG = { LangC:0, … }``, a
# complete second copy of every ``Lang`` ordinal that no compiler checked
# (``lang_enum_contract_test.nim`` pinned it against the enum, entry for
# entry, which is how it stayed right).  ``parseEnum`` compiles and runs on
# Nim's JS backend and reads the ordinal from the enum itself, so there is
# no second list to renumber -- LRS-4 renumbered the enum and this file did
# not have to change with it.  The lookup-miss policy is the retired-name
# policy of ``src/common/trace_index.nim`` (design §5.6): a name this build
# does not have -- ``"LangRuby"`` from an older index, or a value ``ct`` was
# handed that it does not know -- becomes ``LangUnknown``, and the name the
# recording was made under is kept in ``langRetiredName`` if ``ct`` did not
# already fill it, so nothing displays as "unknown" that was recorded under
# a name.  ``ct trace-metadata`` itself already decodes a retired row that
# way and sends ``"lang": "LangUnknown"`` beside ``langRetiredName``.  The
# decoder is ``decodeLangName`` in ``src/common/common_lang.nim`` -- pure,
# backend-agnostic, and pinned on the JS backend by
# ``src/frontend/tests/frontend_lang_test.nim`` (this module is
# Electron-only and no lane can import it).
#
# **The ``calltraceMode`` half is ``parseEnum[CalltraceMode]`` (LRS-6,
# 2026-09-23).**  It was the last hand-written map here: a JS object literal
# ``var MODE = { NoInstrumentation:0, CallKeyOnly:1, … }`` with the same
# silent-fallback shape the ``LANG`` map had, and no test at all
# (Language-Enum-Ordinal-Contracts.md recorded it that way).  It was also DEAD:
# the map ran only for a string, and ``ct trace-metadata`` sent the integer
# until ``serializesAsTextInJson(CalltraceMode)`` in
# ``src/common/trace_index.nim`` made the hop carry the name.  Now the name
# arrives, and ``parseEnum`` reads the ordinal from the enum.
#
# A name this build does not have -- only a newer ``ct`` could send one --
# becomes ``FullRecord``, the value the deleted map fell back to, so no
# reader sees a different mode than before: no Nim module under
# ``src/frontend`` reads ``trace.calltraceMode`` today (measured by grep,
# 2026-09-23; ``index/traces.nim`` only constructs one).  **But it is no
# longer SILENT** (LRS-6's review, 2026-09-24).  The deleted map's defect was
# never the map as such -- it was that an unknown name became a confident,
# valid-looking mode with no trace, the failure mode
# Language-Enum-Ordinal-Contracts.md recorded for it and for the ``LANG``
# map.  ``parseEnum`` with a default argument would have kept exactly that.
# Unlike ``lang`` (``LangUnknown`` plus the preserved ``langRetiredName``)
# and ``approach`` (the ``raUnknown`` sentinel), ``CalltraceMode`` has no
# "unknown" member to decode to, so ``FullRecord`` is a GUESS, and the miss
# prints a warning naming the value, the recording and the known names.
# ``lang_enum_contract_test`` pins that the default-argument form stays gone.

proc jsTypeOfLang(trace: JsObject): cstring {.importjs: "(typeof #.lang)".}
proc jsLangString(trace: JsObject): cstring {.importjs: "(#.lang)".}
proc jsLangRetiredName(trace: JsObject): cstring {.importjs: "(#.langRetiredName)".}
proc jsTypeOfApproach(trace: JsObject): cstring {.importjs: "(typeof #.approach)".}
proc jsApproachString(trace: JsObject): cstring {.importjs: "(#.approach)".}
proc jsTypeOfCalltraceMode(trace: JsObject): cstring {.importjs: "(typeof #.calltraceMode)".}
proc jsCalltraceModeString(trace: JsObject): cstring {.importjs: "(#.calltraceMode)".}

proc normalizeTraceEnums(trace: Trace) =
  if trace.isNil:
    return
  let obj = cast[JsObject](trace)
  if jsTypeOfLang(obj) == cstring"string":
    let decoded = decodeLangName($jsLangString(obj))
    # Assigning a ``Lang`` to the field stores the JS-backend ordinal, which
    # is exactly what ``cast[Trace]`` reinterprets it as.
    trace.lang = decoded.lang
    let alreadyNamed = jsLangRetiredName(obj)
    if decoded.retiredName.len > 0 and
        (alreadyNamed.isNil or alreadyNamed.len == 0):
      trace.langRetiredName = cstring(decoded.retiredName)
  # ``Trace.approach`` (LRS-5's second deletion round) crosses this hop as a
  # NAME for the same reason ``lang`` does -- ``serializesAsTextInJson`` in
  # ``src/common/trace_index.nim`` -- and needs the same rewrite to the
  # ordinal ``cast[Trace]`` assumes.  ``parseEnum`` rather than a second
  # hand-written map, exactly as ``decodeLangName``: the map is what LRS-4
  # deleted here and it must not come back one field over.  An unknown or
  # absent value becomes ``raUnknown``, which every reader already handles as
  # "not a materialized recording".
  if jsTypeOfApproach(obj) == cstring"string":
    var approach = raUnknown
    try:
      approach = parseEnum[RecordingApproach]($jsApproachString(obj))
    except ValueError:
      approach = raUnknown
    trace.approach = approach
  # ``calltraceMode``: the same rewrite, for the same reason.  A name this
  # build does not have becomes ``FullRecord`` -- and SAYS so (see the block
  # comment above for why that is not left silent).
  if jsTypeOfCalltraceMode(obj) == cstring"string":
    let name = $jsCalltraceModeString(obj)
    try:
      trace.calltraceMode = parseEnum[CalltraceMode](name)
    except ValueError:
      var known: seq[string] = @[]
      for mode in CalltraceMode:
        known.add($mode)
      echo "warning: `ct trace-metadata` sent calltraceMode \"", name,
        "\" for recording ", trace.recordingId, ", which is not a ",
        "CalltraceMode this build knows (", known.join(", "), ").  A newer ",
        "`ct` than this front end wrote it.  Treating it as FullRecord, ",
        "which is a GUESS, not the recording's mode."
      trace.calltraceMode = CalltraceMode.FullRecord

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

proc findRecentTracesWithCodetracer*(
    app: ElectronApp, limit: int, quitOnError: bool = true): Future[seq[Trace]] {.async.} =
  ## List the most recent recordings.
  ##
  ## ``quitOnError = false`` degrades a failed ``trace-metadata --recent`` run
  ## to an empty list instead of terminating CodeTracer.  The recent list is
  ## also fetched on startup paths that are already showing a live debugging
  ## session (issue #568); losing the quick-access list there must never cost
  ## the user their session.
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
    if quitOnError:
      app.quit(1)

  # should be an unreachable default..
  # otherwise it doesn't compiler, maybe because of my async
  # template/macro, sorry
  var emptyTraces: seq[Trace] = @[]
  return emptyTraces

proc findRecentTransactions*(
    app: ElectronApp, limit: int, quitOnError: bool = true): Future[seq[StylusTransaction]] {.async.} =
  ## List the most recent Stylus transactions.  See
  ## ``findRecentTracesWithCodetracer`` for ``quitOnError``.
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
      if quitOnError:
        app.quit(1)
  else:
    echo "error: trying to run the codetracer arb listRecentTx command: ", res.error
    if quitOnError:
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

proc findRecentFoldersWithCodetracer*(
    app: ElectronApp, limit: int, quitOnError: bool = true): Future[seq[RecentFolder]] {.async.} =
  ## List the most recently opened project folders.  See
  ## ``findRecentTracesWithCodetracer`` for ``quitOnError``.
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring"--recent-folders", cstring(fmt"--limit={limit}")])

  if res.isOk:
    let raw = res.value
    let folders = cast[seq[RecentFolder]](JSON.parse(raw))
    return folders
  else:
    echo "error: trying to run the codetracer trace metadata command: ", res.error
    if quitOnError:
      app.quit(1)

  # should be an unreachable default..
  # otherwise it doesn't compiler, maybe because of my async
  # template/macro, sorry
  var emptyFolders: seq[RecentFolder] = @[]
  return emptyFolders
