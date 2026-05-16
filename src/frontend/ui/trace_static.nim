## Trace Static Block Execution (CTFS-M-StaticBlockTrace)
##
## Sibling of ``trace_macro.nim`` (M11).  Provides the
## "Trace Static Block Execution" right-click action in the CodeTracer
## editor for Nim source files.
##
## When the cursor is inside a ``static:`` block, a ``const`` initializer,
## a ``{.compileTime.}`` proc body, or a ``static(expr)``, this sends the
## ``workspace/executeCommand`` request with ``nim/traceStaticBlock`` to
## the Nim language server.  The langserver forwards the
## ``tracestatic <file>:<line>:<col>`` query to nimsuggest, which matches
## at ``evalConstExprAux`` entry points and emits a ``.ct`` trace file
## under ``<nimcache>/static_trace_<line>.ct``.
##
## On success, the resulting ``.ct`` file is loaded in a new session tab
## via the same ``CODETRACER::load-trace-file`` IPC pathway M11 added
## for macro traces — both flows produce the same kind of CTFS trace.

import
  std/[asyncjs, jsffi, strformat],
  ui_imports,
  ../[event_helpers, lsp_router],
  session_switch

# JS interop helpers for building the LSP request payload — mirrors the
# helpers in trace_macro.nim verbatim so the two modules stay parallel.
proc newJsObj(): JsObject {.importjs: "({})".}
proc jsArr(): JsObject {.importjs: "([])".}
proc jsPush(target: JsObject; value: JsObject) {.importjs: "#.push(#)".}
proc setStr(target: JsObject; name: cstring; value: cstring) {.importjs: "#[#] = #".}
proc setInt(target: JsObject; name: cstring; value: int) {.importjs: "#[#] = #".}
proc setObj(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
proc getField(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
proc toStr(value: JsObject): cstring {.importjs: "String(#)".}
proc jsIsNilOrUndefined(value: JsObject): bool {.importjs: "((function(v){return v == null || v === undefined})(#))".}

proc traceStaticBlock*(data: Data; filePath: cstring; line: int;
                       character: int) {.async.} =
  ## Send ``nim/traceStaticBlock`` via ``workspace/executeCommand`` and
  ## open the resulting ``.ct`` trace in a new session tab.
  ##
  ## ``line`` and ``character`` use zero-based LSP coordinates (the
  ## Monaco editor position is 1-based, so the caller must subtract 1
  ## from the line number before calling this proc).
  let nimClient = getActiveClient("nim")
  if nimClient.isNil:
    data.viewsApi.warnMessage(
      cstring"Nim language server is not connected. " &
      cstring"Cannot trace static block.")
    return

  # Build the workspace/executeCommand request payload.  The Nim
  # langserver's executeCommand handler for nim/traceStaticBlock expects
  # a single argument object: {uri, line, character}.
  let arg = newJsObj()
  let uri = cstring("file://" & $filePath)
  arg.setStr("uri", uri)
  arg.setInt("line", line)
  arg.setInt("character", character)

  let args = jsArr()
  args.jsPush(arg)

  let params = newJsObj()
  params.setStr("command", cstring"nim/traceStaticBlock")
  params.setObj("arguments", args)

  data.viewsApi.infoMessage(cstring"Tracing static block execution...")

  var response: JsObject
  try:
    response = await sendLspRequest("nim",
      cstring"workspace/executeCommand", params)
  except CatchableError as e:
    let msg = e.msg
    if "not a static" in msg or "No trace result" in msg or
       "compileTime" in msg:
      data.viewsApi.warnMessage(
        cstring"No static block / const / compileTime body found at " &
        cstring"this position.")
    elif "not support" in msg or "traceStatic" in msg:
      data.viewsApi.errorMessage(
        cstring"The Nim language server does not support static block " &
        cstring"tracing. Ensure a trace-enabled nimsuggest is configured.")
    else:
      data.viewsApi.errorMessage(
        cstring("Trace static block failed: " & msg))
    return

  if response.isNil:
    data.viewsApi.errorMessage(
      cstring"Trace static block returned an empty response.")
    return

  let tracePathField = response.getField("tracePath")
  if jsIsNilOrUndefined(tracePathField):
    data.viewsApi.errorMessage(
      cstring"Trace static block response did not contain a trace path.")
    return

  let tracePath = tracePathField.toStr
  if tracePath.len == 0:
    data.viewsApi.errorMessage(
      cstring"Trace static block returned an empty trace path.")
    return

  clog cstring(fmt"trace_static: received trace path: {tracePath}")

  # Open the .ct file in a new session tab via the same IPC pathway used
  # for macro traces (M11).  The main process handles the actual trace
  # loading: it resolves the trace metadata and starts the replay backend.
  createNewSession(data)
  data.ipc.send(cstring"CODETRACER::load-trace-file",
                js{tracePath: tracePath})
