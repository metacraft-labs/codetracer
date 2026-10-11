when defined(ctInExtension):
  import std / [asyncjs, jsffi, jsconsole, strformat, strutils]
  import .. / common / [ct_event, paths]
  import communication
  import results

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

  {.emit: "var vscode = null; try { vscode = require(\"vscode\"); } catch { if (typeof acquireVsCodeApi !== 'undefined') { vscode = acquireVsCodeApi(); } else { vscode = { postMessage: function(msg) { console.log('MOCK VSCODE POSTMESSAGE:', msg); } }; } }".}

  var vscode* {.importc.}: VsCode # vscode in extension central context; acquireVsCodeApi() in webview;

  const ctExtensionLogging {.booldefine.}: bool = true # TODO: false default for production
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
    let transport = VsCodeViewTransport(vscode: vscode)
    vscodeWindow.addEventListener(cstring"message", proc(event: JsObject) =
      if logging: console.log cstring"vscode view received new message in event listener: ", event.toJs
      let data = event.data
      if not data.kind.isNil and not data.value.isNil:
        # check that it's probably a ct raw event: as maybe we can receive other messages?
        transport.onVsCodeMessage(cast[CtRawEvent](data)))
    transport

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
    import lib/[ jslib, electron_lib ], std/sequtils

    proc parseCTJson(raw: cstring): js =
      let rawString = $raw
      let idx = rawString.find(".AppImage installed")
      if idx != NO_INDEX:
        let jsonIdx = rawString.find("\n", idx)
        if jsonIdx != NO_INDEX:
          let jsonText = rawString[jsonIdx + 1..^1]
          return JSON.parse(jsonText)
      return JSON.parse(raw)

    proc readCTOutput(
        codetracerExe: cstring,
        args: seq[cstring],
        isNixOS: bool = false,
        options: JsObject = js{}
      ): Future[Result[cstring, JsObject]] =
        if not isNixOS or not ($codetracerExe).endsWith(".AppImage"):
          readProcessOutput(
            codetracerExe,
            args,
            options
          )
        else:
          readProcessOutput(
            "appimage-run",
            @[codetracerExe].concat(args),
            options
          )

    proc getRecentTracesFromFs(): seq[JsObject] =
      ## List the most recent trace folders from the codetracer store directory.
      ## Used as fallback when trace-metadata --recent returns empty (e.g. after
      ## a DB migration that reset the recording index).
      var results: seq[JsObject] = @[]
      {.emit: """
        (function() {
          var path = require('path');
          var fs = require('fs');
          var os = require('os');
          // `$CODETRACER_HOME/data`, else (as always) `~/.local/share/codetracer`
          // — common/ct_home's rule, spelt in JS because this is emitted verbatim.
          var ctHome = process.env.CODETRACER_HOME;
          var storeDir = ctHome
            ? path.join(path.resolve(ctHome), 'data')
            : path.join(os.homedir(), '.local', 'share', 'codetracer');
          var entries = [];
          try {
            entries = fs.readdirSync(storeDir, { withFileTypes: true })
              .filter(function(e) { return e.isDirectory(); })
              .map(function(e) {
                var p = path.join(storeDir, e.name);
                var mtime = 0;
                try { mtime = fs.statSync(p).mtimeMs; } catch(e) {}
                return { outputFolder: p, program: e.name, mtime: mtime };
              })
              .sort(function(a, b) { return b.mtime - a.mtime; })
              .slice(0, 10);
          } catch(e) {}
          `results` = entries;
        })();
      """.}
      return results

    proc getRecentTraces*(codetracerExe: cstring, isNixOS: bool): Future[seq[JsObject]] {.async, exportc.} =
      let res = await readCTOutput(
        codetracerExe.cstring,
        @[cstring"trace-metadata", cstring"--recent"],
        isNixOS
      )

      if res.isOk:
        let raw = res.value
        let traces = cast[seq[JsObject]](parseCTJson(raw))
        if traces.len > 0:
          return traces
      else:
        echo "[CodeTracer] trace-metadata --recent failed: ", res.error

      # Index is empty (e.g. after DB migration) — fall back to filesystem listing.
      echo "[CodeTracer] falling back to filesystem trace listing"
      return getRecentTracesFromFs()

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
          # M-REC-6: stdout-marker renamed to ``recordingId:``; the
          # payload is a UUIDv7 recording-id string (M-REC-2 / M-REC-3),
          # so pass it through verbatim — no ``parseInt`` coercion.
          if traceIdLine.startsWith("recordingId:"):
            let recordingId = traceIdLine[("recordingId:").len .. ^1].strip()
            let res = await readCTOutput(
              codetracerExe.cstring,
              @[cstring"trace-metadata", cstring(fmt"--id={recordingId}")],
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

    proc extractRecordingId(output: cstring): string =
      ## Pull the recording-id out of a ``ct record`` stdout dump.
      ## Accepts both ``recordingId:<uuid>`` (M-REC-6 UUIDv7) and
      ## ``traceId:<int>`` (older integer-ID builds).
      ## Returns "" when neither marker is present.
      let outputString = $output
      for marker in ["recordingId:", "traceId:"]:
        let idx = outputString.find(marker)
        if idx != NO_INDEX:
          let colon = outputString.find(":", idx)
          if colon != NO_INDEX:
            return outputString[colon + 1..^1].strip()
      return ""

    proc extractTracePath(output: cstring): string =
      ## Extract the trace folder path from ``ct record`` output lines like
      ## "Saved trace to /path/to/<uuid>"
      ## Only captures the path itself (first line after the marker).
      let outputString = $output
      let marker = "Saved trace to "
      let idx = outputString.find(marker)
      if idx != NO_INDEX:
        let pathStart = idx + marker.len
        var lineEnd = outputString.find("\n", pathStart)
        if lineEnd == NO_INDEX:
          lineEnd = outputString.len
        return outputString[pathStart..<lineEnd].strip()
      return ""

    proc getFlowList*() {.async, exportc.}=
      discard

    proc readCTRecordOutput(
        codetracerExe: cstring,
        workDir: cstring,
        isNixOS: bool = false
      ): Future[cstring] =
      ## Run ``ct record <workDir>`` and return the full stdout, even if the
      ## recorder exits with a non-zero code. Recorders like Noir may produce
      ## "Saved trace to <path>" on stdout before failing (e.g. meta.dat version
      ## mismatch), so we must not discard stdout on non-zero exit.
      if not isNixOS or not ($codetracerExe).endsWith(".AppImage"):
        readProcessOutputAnyExit(
          codetracerExe,
          @[cstring"record", workDir]
        )
      else:
        readProcessOutputAnyExit(
          "appimage-run",
          @[codetracerExe, cstring"record", workDir]
        )

    proc getCurrentTrace*(codetracerExe: cstring, workDir: cstring, isNixOS: bool): Future[JsObject] {.async, exportc.} =
      echo "[CodeTracer] getCurrentTrace: exe=", codetracerExe, " workDir=", workDir
      let output = await readCTRecordOutput(codetracerExe, workDir, isNixOS)
      echo "[CodeTracer] ct record output: ", output

      # M-REC-6: ct record emits `recordingId:<uuid>` on the last (non-empty)
      # line.  Resolve the folder by querying `ct trace-metadata --id=<uuid>`,
      # which returns a JSON Trace object whose `outputFolder` field is the
      # folder path the extension passes on to the DAP launch request.
      let recordingId = extractRecordingId(output)
      if recordingId.len > 0:
        echo "[CodeTracer] getCurrentTrace: got recordingId=", recordingId
        let res = await readCTOutput(
          codetracerExe,
          @[cstring"trace-metadata", cstring(fmt"--id={recordingId}")],
          isNixOS
        )
        if res.isOk:
          let raw = res.value
          echo "[CodeTracer] getCurrentTrace: trace-metadata raw=", raw
          return cast[JsObject](parseCTJson(raw))
        else:
          echo "[CodeTracer] getCurrentTrace: trace-metadata failed: ", res.error
        return js{}

      # Legacy fallback: older builds print "Saved trace to <path>".
      let tracePath = extractTracePath(output)
      if tracePath.len > 0:
        echo "[CodeTracer] getCurrentTrace: using legacy trace folder: ", tracePath
        return cast[JsObject](js{ outputFolder: cstring(tracePath), program: cstring("") })

      echo "[CodeTracer] getCurrentTrace: no recordingId or trace path in output: ", output
      return js{}
