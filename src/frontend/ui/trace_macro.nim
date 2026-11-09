## Trace Macro Execution (M11) — the desktop's route for Nim's compile-time
## tracing.
##
## What is offered at the caret, the request, its progress and its failure,
## and where the recording opens are the shared ViewModel's
## (`viewmodel/viewmodels/nim_tracing_vm`, which the terminal and the GPUI
## window use too). This module is the one thing the desktop does
## differently: it sends the request through its JavaScript LSP router
## (`lsp_router`) to the Nim language server as `workspace/executeCommand`
## — `nim/traceExpandMacro` for a macro call, `nim/traceStaticBlock` for a
## static block or a constant (`trace_static`) — and opens the `.ct` the
## language server names through `CODETRACER::load-nim-trace-file`, which
## imports it first (`index/traces.onLoadNimTraceFile`).

import
  std/[asyncjs, jsffi, strformat],
  ui_imports,
  ../[event_helpers, lsp_router],
  session_switch,
  ../viewmodel/viewmodels/nim_tracing_vm

export nim_tracing_vm

# JS interop helpers for building the LSP request payload.
proc newJsObj(): JsObject {.importjs: "({})".}
proc jsArr(): JsObject {.importjs: "([])".}
proc jsPush(target: JsObject; value: JsObject) {.importjs: "#.push(#)".}
proc setStr(target: JsObject; name: cstring; value: cstring) {.importjs: "#[#] = #".}
proc setInt(target: JsObject; name: cstring; value: int) {.importjs: "#[#] = #".}
proc setObj(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
proc getField(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
proc toStr(value: JsObject): cstring {.importjs: "String(#)".}
proc jsIsNilOrUndefined(value: JsObject): bool {.importjs: "((function(v){return v == null || v === undefined})(#))".}

var desktopNimTracing* = newNimTracingVM()
  ## The window's one Nim trace — the shared ViewModel's state, which the
  ## status bar's messages below read.

proc showNimTraceState(data: Data; vm: NimTracingVM) =
  case vm.phase
  of ntpRunning, ntpDone: data.viewsApi.infoMessage(cstring(vm.message))
  of ntpFailed:
    if vm.failure in {ntfNotAvailable, ntfNotAMacro, ntfNotAStaticBlock,
                      ntfBusy}:
      data.viewsApi.warnMessage(cstring(vm.message))
    else:
      data.viewsApi.errorMessage(cstring(vm.message))
  of ntpIdle: discard

proc sendNimTrace*(data: Data; vm: NimTracingVM) {.async.} =
  ## Send `vm`'s started request to the Nim language server and open the
  ## recording it names where the shared rule places it.
  let request = vm.request
  let command = lspCommandOf(request.action)
  if command.len == 0:
    # The language server runs no NimScript; the evaluation is the native
    # front-ends' (`host/native_nim_tracer`, `nim e --trace`).
    vm.fail(ntfNoLanguageServer, "the desktop's Nim language server runs " &
            "no NimScript; trace the evaluation from the terminal or GPUI")
    data.showNimTraceState(vm)
    return
  if getActiveClient("nim").isNil:
    vm.fail(ntfNoLanguageServer,
            "Nim language server is not connected. Cannot trace.")
    data.showNimTraceState(vm)
    return

  # The language server's executeCommand handler expects a single argument
  # object: {uri, line, character}, zero-based (`wirePositionOf`).
  let at = wirePositionOf(request)
  let arg = newJsObj()
  arg.setStr("uri", cstring(fileUriOf(request.path)))
  arg.setInt("line", at.line)
  arg.setInt("character", at.character)
  let args = jsArr()
  args.jsPush(arg)
  let params = newJsObj()
  params.setStr("command", cstring(command))
  params.setObj("arguments", args)

  data.showNimTraceState(vm)

  var response: JsObject
  try:
    response = await sendLspRequest("nim",
      cstring"workspace/executeCommand", params)
  except CatchableError as e:
    vm.refuse(e.msg)
    data.showNimTraceState(vm)
    return

  let tracePath =
    if response.isNil or jsIsNilOrUndefined(response.getField("tracePath")):
      ""
    else: $response.getField("tracePath").toStr
  vm.succeed(tracePath)
  data.showNimTraceState(vm)
  if vm.phase != ntpDone:
    return
  clog cstring(fmt"nim trace: received trace path: {tracePath}")
  # Where it opens is the shared rule's (`nimTracePlacement`): a new session
  # tab. The main process imports the bare `.ct` nimsuggest wrote (with the
  # sources of the file the request was made in), then starts its replay.
  let placed = traceOpenRequestOf(tracePath)
  if placed.policy == topNewTab:
    createNewSession(data)
  data.ipc.send(cstring"CODETRACER::load-nim-trace-file",
                js{tracePath: cstring(placed.tracePath),
                   sourcePath: cstring(request.path)})

proc startNimTrace*(data: Data; action: NimTraceAction; path: cstring;
                    line, column: int; lines: seq[string]) =
  ## The editor's entry (its menu, the `editor.trace-*` operations): the
  ## caret at the editor's 1-based `line:column` of `path`, whose text is
  ## `lines` — begun by the shared ViewModel, which refuses what the caret
  ## does not offer, then sent.
  let vm = desktopNimTracing
  if not vm.begin(NimTraceRequest(action: action, path: $path, line: line,
                                  column: column), lines):
    data.showNimTraceState(vm)
    return
  discard sendNimTrace(data, vm)

proc traceExpandMacro*(data: Data; filePath: cstring; line, column: int;
                       lines: seq[string]) =
  ## "Trace Macro Execution" at the editor's 1-based `line:column`.
  startNimTrace(data, ntaMacro, filePath, line, column, lines)
