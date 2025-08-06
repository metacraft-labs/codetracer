when defined(ctInExtension):
  import std / [async, jsffi, jsconsole, strformat, strutils]
  import .. / common / [ct_event, paths]
  import communication
  import lib, results

  type
    VsCode* = ref object
      postMessage*: proc(raw: JsObject): void
      # valid only in extension-level, not webview context
      debug*: VsCodeDebugApi
      window*: JsObject

    VsCodeDebugApi* = ref object
      activeDebugSession*: VsCodeDebugSession

    VsCodeDebugSession* = ref object of JsObject
      customRequest*: proc(command: cstring, value: JsObject): Future[JsObject]

    VsCodeWebview* = ref object
      postMessage*: proc(raw: JsObject)

    VsCodeContext* = ref object of JsObject

    VsCodeDapMessage* = ref object of JsObject
      # type for now can be also accessed as ["type"] because of JsObject
      `type`*: cstring
      event*: cstring
      command*: cstring
      body*: JsObject 
      
  proc acquireVsCodeApi*(): VsCode {.importc.}

  {.emit: "var vscode = null; try { vscode = require(\"vscode\"); } catch { vscode = acquireVsCodeApi(); }".}

  var vscode* {.importc.}: VsCode # vscode in extension central context; acquireVsCodeApi() in webview;

  const ctExtensionLogging {.strdefine.}: bool = true # TODO: false default for production
  const logging = ctExtensionLogging
  const NO_INDEX = -1

  ### WebviewSubscriber:

  type
    WebviewSubscriber* = ref object of Subscriber
      webview*: VsCodeWebview

  method emitRaw*(w: WebviewSubscriber, kind: CtEventKind, value: JsObject, sourceSubscriber: Subscriber) =
    # on receive the other transport should set the actual subscriber: for now always vscode extension context (middleware)
    if logging: console.log cstring"webview subscriber emitRaw: ", cstring($kind), cstring" ", value
    w.webview.postMessage(CtRawEvent(kind: kind, value: value).toJs)
    if logging: echo cstring"  after postMessage"

  proc newWebviewSubscriber*(webview: VsCodeWebview): WebviewSubscriber {.exportc.}=
    WebviewSubscriber(webview: webview)

  ### VsCodeViewTransport:

  type
    VsCodeViewTransport* = ref object of Transport
      vscode: VsCode

  method send*(t: VsCodeViewTransport, data: JsObject, subscriber: Subscriber)  =
    t.vscode.postMessage(data)

  method onVsCodeMessage*(t: VsCodeViewTransport, eventData: CtRawEvent) {.base.}=
    t.internalRawReceive(eventData.toJs, Subscriber(name: cstring"vscode extenson context"))

  proc newVsCodeViewTransport*(vscode: VsCode, vscodeWindow: JsObject): VsCodeViewTransport =
    result = VsCodeViewTransport(vscode: vscode)
    vscodeWindow.addEventListener(cstring"message", proc(event: JsObject) =
      if logging: console.log cstring"vscode view received new message in event listener: ", event.toJs
      let data = event.data
      if not data.kind.isNil and not data.value.isNil:
        # check that it's probably a ct raw event: as maybe we can receive other messages?
        result.onVsCodeMessage(cast[CtRawEvent](data)))

  proc newVsCodeViewApi*(name: cstring, vscode: VsCode, vscodeWindow: JsObject): MediatorWithSubscribers {.exportc.} =
    let transport = newVsCodeViewTransport(vscode, vscodeWindow)
    newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=true, transport=transport)

  type
    VsCodeExtensionToViewsTransport* = ref object of Transport

  proc setupVsCodeExtensionViewsApi*(name: cstring): MediatorWithSubscribers {.exportc.} =
    let transport = VsCodeExtensionToViewsTransport() # for now not used for sending;
    # viewsApi.receive called in message handler in `getOrCreatePanel` in initPanels.ts
    newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=false, transport=transport)

  when defined(ctInCentralExtensionContext):
    # let EVM_TRACE_DIR_PATH* = getTempDir() / "codetracer"

    proc parseCTJson(raw: cstring): js =
      let rawString = $raw
      let idx = rawString.find(".AppImage installed")
      if idx != NO_INDEX:
        let jsonIdx = rawString.find("\n", idx)
        if jsonIdx != NO_INDEX:
          let jsonText = rawString[jsonIdx + 1..^1]
          return JSON.parse(jsonText)
      return JSON.parse(raw)

    proc getRecentTraces*(codetracerExe: cstring, isNixOS: bool): Future[seq[JsObject]] {.async, exportc.} =
      let res = await readCTOutput(
        codetracerExe.cstring,
        @[cstring"trace-metadata", cstring"--recent"],
        isNixOS
      )

      if res.isOk:
        let raw = res.value
        let traces = cast[seq[JsObject]](parseCTJson(raw))
        return traces
      else:
        echo "error: trying to run the codetracer trace metadata command: ", res.error

    proc getRecentTransactions*(codetracerExe: cstring, isNixOS: bool): Future[seq[JsObject]] {.async, exportc.} =
      let res = await readCTOutput(
        codetracerExe,
        @[cstring"arb",  cstring"listRecentTx"],
        isNixOS
      )

      if res.isOk:
        let raw = res.value
        try:
          let traces = cast[seq[JsObject]](parseCTJson(raw))
          return traces
        except:
          echo "\nerror: loading recent transactions problem: ", raw, " (or possibly invalid json)"
      else:
        echo "error: trying to run the codetracer arb listRecentTx command: ", res.error

    proc getTransactionTrace*(codetracerExe: cstring, txHash: cstring, isNixOS: bool): Future[JsObject] {.async, exportc.} =
      let outputResult = await readCTOutput(
        codetracerExe,
        @[cstring"arb", cstring"record", txHash],
        isNixOS
      )
      var output = cstring""
      if outputResult.isOk:
        output = outputResult.value
        let lines = output.split(jsNl)
        if lines.len > 1:
          let traceIdLine = $lines[^2]
          if traceIdLine.startsWith("traceId:"):
            let traceId = traceIdLine[("traceId:").len .. ^1].parseInt
            let res = await readCTOutput(
              codetracerExe.cstring,
              @[cstring"trace-metadata", cstring(fmt"--id={traceId}")],
              isNixOS
            )

            if res.isOk:
              let raw = res.value
              return cast[JsObject](parseCTJson(raw))
            else:
              echo "error: trying to run the codetracer trace metadata command: ", res.error
            return js{}
      else:
        output = JSON.stringify(outputResult.error)
      return cast[JsObject](output)

    proc getTraceId(output: cstring): int =
      let outputString = $output
      let idx = outputString.find("traceId:")
      if idx != NO_INDEX:
        let traceIdx = outputString.find(":", idx)
        if traceIdx != NO_INDEX:
          let traceNumber = outputString[traceIdx + 1..^1]
          return parseInt(traceNumber.strip())
      return NO_INDEX

    proc getCurrentTrace*(codetracerExe: cstring, workDir: cstring, isNixOS: bool): Future[JsObject] {.async, exportc.} =
      let outputResult = await readCTOutput(
        codetracerExe,
        @[cstring"record", workDir],
        isNixOS
      )

      if outputResult.isOk:
        let traceId = getTraceId(outputResult.value)
        if traceId != NO_INDEX:
          let res = await readCTOutput(
            codetracerExe.cstring,
            @[cstring"trace-metadata", cstring(fmt"--id={traceId}")],
            isNixOS
          )

          if res.isOk:
            let raw = res.value
            return cast[JsObject](parseCTJson(raw))
          else:
            echo "error: trying to run the codetracer trace metadata command: ", res.error
        else:
          echo "error: couldn't manage to get the trace id!"
      return js{}
