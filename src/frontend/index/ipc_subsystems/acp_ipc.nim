import
  std / [ async, jsffi, strutils, asyncjs, strformat],
  ../../lib/[ jslib ],
  ../../../common/ct_logging,
  ../../../ct/acp/acp,
  ../../../frontend/index/electron_vars

proc getEnv(name: cstring): cstring {.importjs: "(process.env[#] || '')".}
proc parseArgs(env: cstring): seq[cstring] {.importjs: "((val) => val ? val.split(' ').filter(Boolean) : [])(#)".}

proc spawnProcess(cmd: cstring, args: seq[cstring]): JsObject {.
  importjs: "require('child_process').spawn(#, #, { stdio: ['pipe', 'pipe', 'inherit'] })".}

proc stdoutOf(p: JsObject): JsObject {.importjs: "#.stdout".}
proc stdinOf(p: JsObject): JsObject {.importjs: "#.stdin".}

proc toWebReadable(nodeReadable: JsObject): WebReadableStream {.
  importjs: "require('node:stream').Readable.toWeb(#)".}

proc toWebWritable(nodeWritable: JsObject): WebWritableStream {.
  importjs: "require('node:stream').Writable.toWeb(#)".}

proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}
proc jsTypeof(obj: JsObject): cstring {.importjs: "typeof #".}

proc initRequest(): JsObject {.importjs: "({ protocolVersion: __acpSdk.PROTOCOL_VERSION, clientCapabilities: {} })".}
proc newSessionRequest(): JsObject {.importjs: "({ cwd: process.cwd(), mcpServers: [] })".}

proc promptRequest(sessionId: cstring, message: cstring): JsObject {.importjs: "({ sessionId: #, prompt: [{ type: 'text', text: # }] })".}

proc stringify(obj: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc readFileUtf8(path: cstring): Future[cstring] {.importjs: "require('fs').promises.readFile(#, 'utf8')".}

proc makeClient(onSessionUpdate: js, onReadTextFile: js): JsObject {.importjs: "(() => ({ requestPermission: async () => ({ outcome: { outcome: 'denied', optionId: '' } }), sessionUpdate: async (params) => { await #(params); }, writeTextFile: async () => ({}), readTextFile: async (params) => await #(params), createTerminal: async () => ({ id: 'term-1' }), extMethod: async () => ({}), extNotification: async () => {} }))()".}
proc asFactory(obj: JsObject): js {.importjs: "(function(v){ return function(){ return v; }; })(#)".}

proc sessionIdFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.sessionId) || 'session-1')(#)".}
proc stopReasonFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.stopReason) || '')(#)".}

proc log(obj: JsObject) {.importjs: "console.log(#)"}

const
  defaultCmd = cstring"opencode"
  defaultArgs: seq[cstring] = @[cstring"acp"]

var msgId = 100

proc onAcpPrompt*(sender: js, response: JsObject) {.async.} =
  let rawText = response[cstring"text"]
  let text =
    block:
      let tType = jsTypeof(rawText)
      if tType == cstring"string":
        rawText.to(cstring)
      elif tType == cstring"object" and jsHasKey(rawText, cstring"text"):
        rawText[cstring"text"].to(cstring)
      else:
        # Last resort: stringify the payload so the agent sees the data, not an internal symbol.
        stringify(rawText)

  echo fmt"[acp_ipc] got text: {text}"
  let messageId = cstring($msgId)

  let procHandle = spawnProcess(defaultCmd, defaultArgs)

  echo "[acp_ipc] started the acp server"

  let stream = ndJsonStream(
    toWebWritable(stdinOf(procHandle)),
    toWebReadable(stdoutOf(procHandle)))

  echo "[acp_ipc] set up the pipes"

  var aggregatedContent = cstring""
  var collectedUpdates: seq[JsObject] = @[]

  let handleReadTextFile = functionAsJS(proc(params: JsObject): Future[JsObject] {.async.} =
    let path =
      if jsHasKey(params, cstring"path"):
        params[cstring"path"].to(cstring)
      else:
        cstring""

    if path.len == 0:
      return js{ "error": "missing path" }

    try:
      let content = await readFileUtf8(path)
      return js{ "content": content }
    except:
      return js{ "error": cstring(fmt"[acp_ipc] readTextFile failed: {getCurrentExceptionMsg()}") }
  )

  let handleSessionUpdate = functionAsJS(proc(params: JsObject) {.async.} =
    collectedUpdates.add(params)

    try:
      if jsHasKey(params, cstring"update"):
        let updateObj = params[cstring"update"]
        if jsHasKey(updateObj, cstring"sessionUpdate"):
          let updateKind = updateObj[cstring"sessionUpdate"].to(cstring)
          if updateKind == cstring"agent_message_chunk" and
             jsHasKey(updateObj, cstring"content") and
             jsHasKey(updateObj[cstring"content"], cstring"text"):
            let chunk = updateObj[cstring"content"][cstring"text"].to(cstring)
            aggregatedContent &= chunk
            mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
              "id": messageId,
              "content": chunk
            })
    except:
      errorPrint cstring(fmt"[acp_ipc] failed to process session update: {getCurrentExceptionMsg()}"))

  # ClientSideConnection expects a factory function, not a plain object
  let clientConn = newClientSideConnection(asFactory(makeClient(handleSessionUpdate, handleReadTextFile)), stream)

  echo "[acp_ipc] established a client-side connection"

  let initResp = await clientConn.initialize(initRequest())
  echo "[acp_ipc] initialized response raw=", stringify(initResp)

  let sessionResp = await clientConn.newSession(newSessionRequest())

  let sessionId = sessionIdFrom(sessionResp)

  echo "[acp_ipc] sending prompt: ", text

  let promptResp = await clientConn.prompt(promptRequest(sessionId, text))
  let stopReason = stopReasonFrom(promptResp)

  # Final notification with stop reason only (no aggregated content to avoid duplication)
  mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
    "id": messageId,
    "stopReason": stopReason,
    "updates": collectedUpdates
  })

  msgId += 1
