import
  std / [ async, jsffi, strutils, asyncjs, strformat, tables],
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
proc loadSessionRequest(sessionId: cstring): JsObject {.importjs: "({ cwd: process.cwd(), mcpServers: [], sessionId: # })".}

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
  defaultCmd = cstring"ah"
  defaultArgs: seq[cstring] = @[cstring"acp"]

type
  SessionState = object
    currentMessageId: cstring
    aggregatedContent: cstring
    collectedUpdates: seq[JsObject]
    activePrompt: bool

var msgId = 100
var terminalCounter = 0
var acpProcess: JsObject
var acpStream: AcpStream
var acpClient: ClientSideConnection
var acpInitialized = false
var sessionsById: Table[cstring, SessionState] = initTable[cstring, SessionState]()
var acpSessionIdsByClient: Table[cstring, cstring] = initTable[cstring, cstring]()
var clientSessionIdsByAcp: Table[cstring, cstring] = initTable[cstring, cstring]()

proc getSessionState(sessionId: cstring; state: var SessionState): bool =
  if sessionsById.hasKey(sessionId):
    state = sessionsById[sessionId]
    true
  else:
    false

proc saveSessionState(sessionId: cstring; state: SessionState) =
  sessionsById[sessionId] = state

proc acpSessionForClient(clientSessionId: cstring): cstring =
  if acpSessionIdsByClient.hasKey(clientSessionId):
    acpSessionIdsByClient[clientSessionId]
  else:
    cstring""

proc clientSessionForAcp(acpSessionId: cstring): cstring =
  if clientSessionIdsByAcp.hasKey(acpSessionId):
    clientSessionIdsByAcp[acpSessionId]
  else:
    cstring""

let handleCreateTerminal = functionAsJS(proc(params: JsObject): Future[JsObject] {.async.} =
  terminalCounter += 1
  let acpSessionId =
    if jsHasKey(params, cstring"sessionId"):
      params[cstring"sessionId"].to(cstring)
    else:
      cstring""
  let clientSessionId = clientSessionForAcp(acpSessionId)
  let terminalId =
    if jsHasKey(params, cstring"id"):
      params[cstring"id"].to(cstring)
    else:
      cstring(fmt"acp-term-{terminalCounter}")
  # Notify renderer so it can open/attach a terminal UI when we eventually wire it.
  mainWindow.webContents.send("CODETRACER::acp-create-terminal", js{
    "id": terminalId,
    "sessionId": acpSessionId,
    "clientSessionId": clientSessionId,
    "params": params
  })

  return js{ "id": terminalId }
)

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

let handleWriteTextFile = functionAsJS(proc(params: JsObject): Future[JsObject] {.async.} =
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
  let acpSessionId =
    if jsHasKey(params, cstring"sessionId"):
      params[cstring"sessionId"].to(cstring)
    else:
      cstring""

  let clientSessionId = clientSessionForAcp(acpSessionId)
  if clientSessionId.len == 0:
    return

  var state: SessionState
  if acpSessionId.len == 0 or not getSessionState(acpSessionId, state):
    # unknown session; ignore
    return
  if not state.activePrompt:
    return

  var updateKind = cstring""
  if jsHasKey(params, cstring"update"):
    let u = params[cstring"update"]
    if jsHasKey(u, cstring"sessionUpdate"):
      updateKind = u[cstring"sessionUpdate"].to(cstring)
  let contentLen =
    if jsHasKey(params, cstring"update") and jsHasKey(params[cstring"update"], cstring"content"):
      stringify(params[cstring"update"][cstring"content"]).len
    else:
      0
  var contentPreview = cstring""
  if jsHasKey(params, cstring"update") and jsHasKey(params[cstring"update"], cstring"content"):
    let contentStr = $stringify(params[cstring"update"][cstring"content"])
    if contentStr.len > 200:
      contentPreview = contentStr[0..199].cstring
    else:
      contentPreview = contentStr.cstring

  echo fmt"[acp_ipc] update sessionId={acpSessionId} clientSessionId={clientSessionId} kind={updateKind} contentLen={contentLen} contentPreview={contentPreview}"

  state.collectedUpdates.add(params)

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
              discard
              # Respond by issuing a tool_call_update with status=approved to mirror agent expectations.
              discard acpClient.extNotification(cstring"tool_permission", js{
                "sessionId": acpSessionId,
                "toolCallId": toolCallId,
                "outcome": js{
                  "outcome": cstring"selected",
                  "optionId": optionId
                }
              })
          except:
            errorPrint cstring(fmt"[acp_ipc] auto-allow tool permission failed: {getCurrentExceptionMsg()}")
        if updateKind == cstring"agent_message_chunk" and state.currentMessageId.len > 0 and
           jsHasKey(updateObj, cstring"content") and
           jsHasKey(updateObj[cstring"content"], cstring"text"):
          let chunk = updateObj[cstring"content"][cstring"text"].to(cstring)
          state.aggregatedContent &= chunk
          mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
            "sessionId": acpSessionId,
            "clientSessionId": clientSessionId,
            "id": state.currentMessageId,
            "content": chunk
          })
        if updateKind == cstring"tool_call_update":
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
                let contentObj = updateObj[cstring"content"]
                if jsHasKey(contentObj, cstring"path"):
                  path = contentObj[cstring"path"].to(cstring)

            if path.len == 0 and jsHasKey(updateObj, cstring"rawOutput"):
              let rawOut = updateObj[cstring"rawOutput"]
              if jsHasKey(rawOut, cstring"filediff") and jsHasKey(rawOut[cstring"filediff"], cstring"file"):
                path = rawOut[cstring"filediff"][cstring"file"].to(cstring)

            if path.len > 0:
              mainWindow.webContents.send("CODETRACER::reload-file", js{ "path": path })
              mainWindow.webContents.send("CODETRACER::change-file", js{ "path": path })
          except:
            errorPrint cstring(fmt"[acp_ipc] tool_call_update reload/change-file notify failed: {getCurrentExceptionMsg()}")
  except:
    errorPrint cstring(fmt"[acp_ipc] failed to process session update: {getCurrentExceptionMsg()}")

  saveSessionState(acpSessionId, state)
)

proc ensureAcpConnection(): Future[void] {.async.} =
  if acpInitialized and not acpClient.isNil:
    return

  try:
    acpProcess = spawnProcess(defaultCmd, defaultArgs)

    acpStream = ndJsonStream(
      toWebWritable(stdinOf(acpProcess)),
      toWebReadable(stdoutOf(acpProcess)))

    # acpClient = newClientSideConnection(asFactory(makeClient(handleSessionUpdate, handleReadTextFile, handleWriteTextFile, handleCreateTerminal)), acpStream)

    acpClient = newClientSideConnection(asFactory(makeClient(
      handleRequestPermission,
      handleSessionUpdate,
      handleWriteTextFile,
      handleReadTextFile,
      handleCreateTerminal
    )), acpStream)
    let initResp = await acpClient.initialize(initRequest())

    acpInitialized = true
  except:
    # assuming acp server cmd not in PATH, or other error
    errorPrint "[acp_ipc]: error: ", getCurrentExceptionMsg()
    return

proc onAcpPrompt*(sender: js, response: JsObject) {.async.} =
  if not acpInitialized or acpClient.isNil:
    discard
    return

  let clientSessionId =
    if jsHasKey(response, cstring"clientSessionId"):
      response[cstring"clientSessionId"].to(cstring)
    else:
      cstring""
  let requestedSessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""
  let sessionId =
    if clientSessionId.len > 0:
      let mapped = acpSessionForClient(clientSessionId)
      if mapped.len == 0:
        errorPrint cstring(fmt"[acp_ipc] prompt for unknown clientSessionId={clientSessionId}")
        return
      mapped
    else:
      requestedSessionId

  if clientSessionId.len == 0:
    errorPrint cstring(fmt"[acp_ipc] prompt missing clientSessionId for sessionId={sessionId}")
    return

  if sessionId.len == 0:
    errorPrint cstring"[acp_ipc] prompt missing sessionId/clientSessionId"
    return

  var state: SessionState
  if not getSessionState(sessionId, state):
    errorPrint cstring(fmt"[acp_ipc] prompt for unknown sessionId={sessionId}")
    return

  let rawText = response[cstring"text"]
  let text =
    block:
      let tType = jsTypeof(rawText)
      if tType == cstring"string":
        rawText.to(cstring)
      elif tType == cstring"object" and jsHasKey(rawText, cstring"text"):
        rawText[cstring"text"].to(cstring)
      else:
        stringify(rawText)

  echo fmt"[acp_ipc] prompt received clientSessionId={clientSessionId} sessionId={sessionId} text={text}"

  let messageId = cstring($msgId)
  msgId += 1

  state.currentMessageId = messageId
  state.aggregatedContent = cstring""
  state.collectedUpdates = @[]
  state.activePrompt = true
  saveSessionState(sessionId, state)

  mainWindow.webContents.send("CODETRACER::acp-prompt-start", js{
    "sessionId": sessionId,
    "clientSessionId": clientSessionId,
    "id": messageId
  })

  let promptResp = await acpClient.prompt(promptRequest(sessionId, text))
  let stopReason = stopReasonFrom(promptResp)

  mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
    "sessionId": sessionId,
    "clientSessionId": clientSessionId,
    "id": messageId,
    "stopReason": stopReason,
    "updates": state.collectedUpdates
  })

  state.currentMessageId = cstring""
  state.aggregatedContent = cstring""
  state.collectedUpdates = @[]
  state.activePrompt = false
  saveSessionState(sessionId, state)

proc onAcpSessionInit*(sender: js, response: JsObject) {.async.} =
  let clientSessionId =
    if jsHasKey(response, cstring"clientSessionId"):
      response[cstring"clientSessionId"].to(cstring)
    elif jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  if clientSessionId.len == 0:
    errorPrint cstring"[acp_ipc] session-init missing clientSessionId"
    return

  await ensureAcpConnection()

  try:
    let sessionResp = await acpClient.newSession(newSessionRequest())
    let acpSessionId = sessionIdFrom(sessionResp)
    let state = SessionState(
      currentMessageId: cstring"",
      aggregatedContent: cstring"",
      collectedUpdates: @[],
      activePrompt: false
    )
    saveSessionState(acpSessionId, state)
    acpSessionIdsByClient[clientSessionId] = acpSessionId
    clientSessionIdsByAcp[acpSessionId] = clientSessionId

    var workspace = cstring""
    if jsHasKey(sessionResp, cstring"_ah") and jsHasKey(sessionResp[cstring"_ah"], cstring"workspaceDir"):
      workspace = sessionResp[cstring"_ah"][cstring"workspaceDir"].to(cstring)
    echo fmt"[acp_ipc] session-init clientSessionId={clientSessionId} acpSessionId={acpSessionId} workspace={workspace}"

    mainWindow.webContents.send("CODETRACER::acp-session-ready", js{
      "sessionId": acpSessionId,
      "clientSessionId": clientSessionId,
      "response": sessionResp
    })
  except:
    let errMsg = cstring(fmt"[acp_ipc] session-init failed for clientSession={clientSessionId}: {getCurrentExceptionMsg()}")
    errorPrint errMsg
    mainWindow.webContents.send("CODETRACER::acp-session-load-error", js{
      "sessionId": clientSessionId,
      "error": errMsg
    })

proc onAcpStop*(sender: js, response: JsObject) {.async.} =
  if not acpInitialized or acpClient.isNil:
    discard
    return

  let clientSessionId =
    if jsHasKey(response, cstring"clientSessionId"):
      response[cstring"clientSessionId"].to(cstring)
    else:
      cstring""
  let requestedSessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""
  let sessionId =
    if clientSessionId.len > 0:
      acpSessionForClient(clientSessionId)
    else:
      requestedSessionId

  if sessionId.len == 0 or not sessionsById.hasKey(sessionId):
    discard
    return

  var state = sessionsById[sessionId]

  try:
    await acpClient.cancel(js{ "sessionId": sessionId })
    if state.currentMessageId.len > 0:
      mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
        "sessionId": sessionId,
        "id": state.currentMessageId,
        "stopReason": "cancelled"
      })
    state.currentMessageId = cstring""
    state.aggregatedContent = cstring""
    state.collectedUpdates = @[]
    state.activePrompt = false
    saveSessionState(sessionId, state)
  except:
    errorPrint cstring(fmt"[acp_ipc] stop failed: {getCurrentExceptionMsg()}")

proc onAcpCancelPrompt*(sender: js, response: JsObject) {.async.} =
  if not acpInitialized or acpClient.isNil:
    discard
    return

  let clientSessionId =
    if jsHasKey(response, cstring"clientSessionId"):
      response[cstring"clientSessionId"].to(cstring)
    else:
      cstring""
  let requestedSessionId =
    if jsHasKey(response, cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  let sessionId =
    if clientSessionId.len > 0:
      acpSessionForClient(clientSessionId)
    else:
      requestedSessionId

  if sessionId.len == 0 or not sessionsById.hasKey(sessionId):
    discard
    return

  var state = sessionsById[sessionId]

  let requestMessageId =
    if jsHasKey(response, cstring"messageId"):
      let mid = response[cstring"messageId"].to(cstring)
      if mid.len > 0: mid else: state.currentMessageId
    else:
      state.currentMessageId

  try:
    await acpClient.cancel(js{ "sessionId": sessionId })
    if requestMessageId.len > 0:
      mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
        "sessionId": sessionId,
        "id": requestMessageId,
        "stopReason": "cancelled"
      })
    if requestMessageId == state.currentMessageId:
      state.currentMessageId = cstring""
      state.aggregatedContent = cstring""
      state.collectedUpdates = @[]
      state.activePrompt = false
      saveSessionState(sessionId, state)
  except:
    errorPrint cstring(fmt"[acp_ipc] cancel prompt failed: {getCurrentExceptionMsg()}")
