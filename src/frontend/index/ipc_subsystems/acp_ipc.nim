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
proc writeFileUtf8(path: cstring, content: cstring): Future[void] {.importjs: "require('fs').promises.writeFile(#, #, 'utf8')".}

proc makeClient(onRequestPermission: js, onSessionUpdate: js, onWriteTextFile: js, onReadTextFile: js, onCreateTerminal: js): JsObject {.importjs: "(() => ({ requestPermission: async (params) => await #(params), sessionUpdate: async (params) => await #(params), writeTextFile: async (params) => await #(params), readTextFile: async (params) => await #(params), createTerminal: async (params) => await #(params), extMethod: async () => ({}), extNotification: async () => {} }))()".}
proc asFactory(obj: JsObject): js {.importjs: "(function(v){ return function(){ return v; }; })(#)".}

proc sessionIdFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.sessionId) || 'session-1')(#)".}
proc stopReasonFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.stopReason) || '')(#)".}

proc log(obj: JsObject) {.importjs: "console.log(#)"}

const
  defaultCmd = cstring"opencode"
  defaultArgs: seq[cstring] = @[cstring"acp"]

var msgId = 100
var terminalCounter = 0
var acpProcess: JsObject
var acpStream: AcpStream
var acpClient: ClientSideConnection
var acpSessionId: cstring
var acpInitialized = false
var activeAggregatedContent = cstring""
var activeCollectedUpdates: seq[JsObject] = @[]
var currentMessageId = cstring""
var currentSessionId: cstring

let handleCreateTerminal = functionAsJS(proc(params: JsObject): Future[JsObject] {.async.} =
  echo fmt"[acp_ipc] createTerminal request: {stringify(params)}"
  terminalCounter += 1
  let terminalId =
    if jsHasKey(params, cstring"id"):
      params[cstring"id"].to(cstring)
    else:
      cstring(fmt"acp-term-{terminalCounter}")
  echo fmt"[acp_ipc] createTerminal requested id={terminalId}"

  # Notify renderer so it can open/attach a terminal UI when we eventually wire it.
  mainWindow.webContents.send("CODETRACER::acp-create-terminal", js{
    "id": terminalId,
    "params": params
  })

  return js{ "id": terminalId }
)

let handleReadTextFile = functionAsJS(proc(params: JsObject): Future[JsObject] {.async.} =
  echo fmt"[acp_ipc] fs.readTextFile request: {stringify(params)}"
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

let handleWriteTextFile = functionAsJS(proc(params: JsObject): Future[JsObject] {.async.} =
  echo fmt"[acp_ipc] fs.writeTextFile request: {stringify(params)}"
  let path =
    if jsHasKey(params, cstring"path"):
      params[cstring"path"].to(cstring)
    else:
      cstring""
  let content =
    if jsHasKey(params, cstring"content"):
      params[cstring"content"].to(cstring)
    else:
      cstring""

  if path.len == 0:
    return js{ "error": "missing path" }
  try:
    await writeFileUtf8(path, content)
    # Notify renderer so open Monaco tabs can reload updated content.
    mainWindow.webContents.send("CODETRACER::reload-file", js{ "path": path })
    return js{ "ok": true }
  except:
    return js{ "error": cstring(fmt"[acp_ipc] writeTextFile failed: {getCurrentExceptionMsg()}") }
)

let handleRequestPermission = functionAsJS(proc(params: JsObject): Future[JsObject] {.async.} =
  echo fmt"[acp_ipc] requestPermission received: {stringify(params)}"
  # Default: allow the "allow_always" option if present, else first option.
  let options =
    if jsHasKey(params, cstring"options"):
      params[cstring"options"]
    else:
      jsUndefined

  var optionId = cstring""
  if not options.isUndefined:
    try:
      let opts = options.to(seq[JsObject])
      for opt in opts:
        if jsHasKey(opt, cstring"kind") and opt[cstring"kind"].to(cstring) == cstring"allow_always" and jsHasKey(opt, cstring"optionId"):
          optionId = opt[cstring"optionId"].to(cstring)
          break
      if optionId.len == 0 and opts.len > 0 and jsHasKey(opts[0], cstring"optionId"):
        optionId = opts[0][cstring"optionId"].to(cstring)
    except:
      discard

  return js{
    "outcome": js{
      "outcome": cstring"selected",
      "optionId": optionId
    },
    "options": options
  }
)

let handleSessionUpdate = functionAsJS(proc(params: JsObject) {.async.} =
  echo fmt"[acp_ipc] sessionUpdate: {stringify(params)}"

  activeCollectedUpdates.add(params)

  try:
    if jsHasKey(params, cstring"update"):
      let updateObj = params[cstring"update"]
      if jsHasKey(updateObj, cstring"sessionUpdate"):
        let updateKind = updateObj[cstring"sessionUpdate"].to(cstring)
        if updateKind == cstring"tool_call" and jsHasKey(updateObj, cstring"options"):
          # Permission-like tool call: auto-allow the allow_always option when present.
          try:
            let opts = updateObj[cstring"options"].to(seq[JsObject])
            var optionId = cstring""
            for opt in opts:
              if jsHasKey(opt, cstring"kind") and opt[cstring"kind"].to(cstring) == cstring"allow_always" and jsHasKey(opt, cstring"optionId"):
                optionId = opt[cstring"optionId"].to(cstring)
                break
            if optionId.len == 0 and opts.len > 0 and jsHasKey(opts[0], cstring"optionId"):
              optionId = opts[0][cstring"optionId"].to(cstring)

            if optionId.len > 0:
              let toolCallId =
                if jsHasKey(updateObj, cstring"toolCallId"):
                  updateObj[cstring"toolCallId"].to(cstring)
                else:
                  cstring""
              echo fmt"[acp_ipc] auto-allow tool_call permission toolCallId={toolCallId} optionId={optionId}"
              # Respond by issuing a tool_call_update with status=approved to mirror agent expectations.
              discard acpClient.extNotification(cstring"tool_permission", js{
                "sessionId": currentSessionId,
                "toolCallId": toolCallId,
                "outcome": js{
                  "outcome": cstring"selected",
                  "optionId": optionId
                }
              })
          except:
            errorPrint cstring(fmt"[acp_ipc] auto-allow tool permission failed: {getCurrentExceptionMsg()}")
        if updateKind == cstring"agent_message_chunk" and currentMessageId.len > 0 and
           jsHasKey(updateObj, cstring"content") and
           jsHasKey(updateObj[cstring"content"], cstring"text"):
          let chunk = updateObj[cstring"content"][cstring"text"].to(cstring)
          activeAggregatedContent &= chunk
          mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
            "id": currentMessageId,
            "content": chunk
          })
        if updateKind == cstring"tool_call_update":
          echo "[acp_ipc] tool_call_update received; inspecting for filepath"
          try:
            var path = cstring""
            if jsHasKey(updateObj, cstring"rawInput"):
              let rawIn = updateObj[cstring"rawInput"]
              if jsHasKey(rawIn, cstring"filepath"):
                path = rawIn[cstring"filepath"].to(cstring)

            if path.len == 0 and jsHasKey(updateObj, cstring"content"):
              try:
                let contentItems = updateObj[cstring"content"].to(seq[JsObject])
                for item in contentItems:
                  if jsHasKey(item, cstring"type") and item[cstring"type"].to(cstring) == cstring"diff" and
                     jsHasKey(item, cstring"path"):
                    path = item[cstring"path"].to(cstring)
                    break
              except:
                echo fmt"[acp_ipc] tool_call_update content parsing failed: {getCurrentExceptionMsg()}"
                let contentObj = updateObj[cstring"content"]
                if jsHasKey(contentObj, cstring"path"):
                  path = contentObj[cstring"path"].to(cstring)

            if path.len == 0 and jsHasKey(updateObj, cstring"rawOutput"):
              let rawOut = updateObj[cstring"rawOutput"]
              if jsHasKey(rawOut, cstring"filediff") and jsHasKey(rawOut[cstring"filediff"], cstring"file"):
                path = rawOut[cstring"filediff"][cstring"file"].to(cstring)

            if path.len > 0:
              echo fmt"[acp_ipc] tool_call_update with filepath; notifying reload + change-file for {path}"
              mainWindow.webContents.send("CODETRACER::reload-file", js{ "path": path })
              mainWindow.webContents.send("CODETRACER::change-file", js{ "path": path })
          except:
            errorPrint cstring(fmt"[acp_ipc] tool_call_update reload/change-file notify failed: {getCurrentExceptionMsg()}")
  except:
    errorPrint cstring(fmt"[acp_ipc] failed to process session update: {getCurrentExceptionMsg()}"))

proc ensureAcpConnection(): Future[void] {.async.} =
  if acpInitialized and not acpClient.isNil:
    return

  acpProcess = spawnProcess(defaultCmd, defaultArgs)
  echo "[acp_ipc] started the acp server"

  acpStream = ndJsonStream(
    toWebWritable(stdinOf(acpProcess)),
    toWebReadable(stdoutOf(acpProcess)))

  echo "[acp_ipc] set up the pipes"

  acpClient = newClientSideConnection(asFactory(makeClient(
    handleRequestPermission,
    handleSessionUpdate,
    handleWriteTextFile,
    handleReadTextFile,
    handleCreateTerminal
  )), acpStream)

  echo "[acp_ipc] established a client-side connection"

  let initResp = await acpClient.initialize(initRequest())
  echo "[acp_ipc] initialized response raw=", stringify(initResp)

  let sessionResp = await acpClient.newSession(newSessionRequest())
  acpSessionId = sessionIdFrom(sessionResp)
  currentSessionId = acpSessionId
  acpInitialized = true

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

  await ensureAcpConnection()

  echo "[acp_ipc] sending prompt: ", text
  activeAggregatedContent = cstring""
  activeCollectedUpdates = @[]
  currentMessageId = messageId
  # Notify UI of the in-flight message id up front so cancel can target it.
  mainWindow.webContents.send("CODETRACER::acp-prompt-start", js{
    "id": messageId,
    "sessionId": currentSessionId
  })

  let promptResp = await acpClient.prompt(promptRequest(acpSessionId, text))
  let stopReason = stopReasonFrom(promptResp)

  # Final notification with stop reason only (no aggregated content to avoid duplication)
  mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
    "id": messageId,
    "stopReason": stopReason,
    "updates": activeCollectedUpdates
  })

  currentMessageId = cstring""
  msgId += 1

proc onAcpInitSession*(sender: js, response: JsObject) {.async.} =
  await ensureAcpConnection()

proc onAcpStop*(sender: js, response: JsObject) {.async.} =
  if not acpInitialized or acpClient.isNil:
    echo "[acp_ipc] stop requested but ACP not initialized"
    return

  echo fmt"[acp_ipc] stopping session: {currentSessionId}"
  try:
    await acpClient.cancel(js{ "sessionId": currentSessionId })
    if currentMessageId.len > 0:
      mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
        "id": currentMessageId,
        "stopReason": "cancelled"
      })
    currentMessageId = cstring""
    activeAggregatedContent = cstring""
    activeCollectedUpdates = @[]
  except:
    errorPrint cstring(fmt"[acp_ipc] stop failed: {getCurrentExceptionMsg()}")

proc onAcpCancelPrompt*(sender: js, response: JsObject) {.async.} =
  if not acpInitialized or acpClient.isNil:
    echo "[acp_ipc] cancel requested but ACP not initialized"
    return

  let requestMessageId =
    if jsHasKey(response, cstring"messageId"):
      let mid = cast[cstring](response[cstring"messageId"])
      if mid.len > 0: mid else: currentMessageId
    else:
      currentMessageId

  echo fmt"[acp_ipc] cancelling prompt for session={currentSessionId} messageId={requestMessageId}"

  try:
    await acpClient.cancel(js{ "sessionId": currentSessionId })
    if requestMessageId.len > 0:
      mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
        "id": requestMessageId,
        "stopReason": "cancelled"
      })
    if requestMessageId == currentMessageId:
      currentMessageId = cstring""
      activeAggregatedContent = cstring""
      activeCollectedUpdates = @[]
  except:
    errorPrint cstring(fmt"[acp_ipc] cancel prompt failed: {getCurrentExceptionMsg()}")
