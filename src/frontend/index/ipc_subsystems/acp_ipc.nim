import
  std / [ async, jsffi, strutils, asyncjs, strformat, tables],
  ../../lib/[ jslib ],
  ../../../common/ct_logging,
  ../../../ct/acp/acp,
  ../../../frontend/index/electron_vars

proc getEnv(name: cstring): cstring {.importjs: "(process.env[#] || '')".}
proc parseArgs(env: cstring): seq[cstring] {.importjs: "((val) => val ? val.split(' ').filter(Boolean) : [])(#)".}
proc normalizePath(p: cstring): cstring {.importjs: "require('path').resolve(#)".}

proc spawnProcess(cmd: cstring, args: seq[cstring]): JsObject {.
  importjs: "require('child_process').spawn(#, #, { stdio: ['pipe', 'pipe', 'inherit'], windowsHide: true })".}

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

# Returns the content of a file at git HEAD (empty string if the file is new/untracked).
proc gitFileAtHead(absPath: cstring): cstring {.importjs: """
(() => {
  try {
    const cp = require('child_process');
    const path = require('path');
    const rel = path.relative(process.cwd(), #);
    const r = cp.spawnSync('git', ['show', 'HEAD:' + rel],
      { encoding: 'utf8', timeout: 10000, cwd: process.cwd() });
    return (!r.error && r.status === 0) ? (r.stdout || '') : '';
  } catch(e) { return ''; }
})()
""".}


proc makeClient(onRequestPermission: js, onSessionUpdate: js, onWriteTextFile: js, onReadTextFile: js, onCreateTerminal: js): JsObject {.importjs: "(() => ({ requestPermission: async (params) => await #(params), sessionUpdate: async (params) => await #(params), writeTextFile: async (params) => await #(params), readTextFile: async (params) => await #(params), createTerminal: async (params) => await #(params), extMethod: async () => ({}), extNotification: async () => {} }))()".}
proc asFactory(obj: JsObject): js {.importjs: "(function(v){ return function(){ return v; }; })(#)".}

proc sessionIdFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.sessionId) || 'session-1')(#)".}
proc stopReasonFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.stopReason) || '')(#)".}

proc log(obj: JsObject) {.importjs: "console.log(#)"}

const
  defaultCmd = cstring"codex-acp"
  defaultArgs: seq[cstring] = @[]
  # defaultCmd = cstring"ah"
  # defaultArgs: seq[cstring] = @[cstring"acp"]

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
# Cache originals before writes so we can render diffs when ACP only sends the
# new content (consumed per tool_call_update event).
var originalFileCache: Table[cstring, cstring] = initTable[cstring, cstring]()
# Per-session set of file paths touched by the agent (any tool), used at session
# completion to compute authoritative diffs for ALL touched files.
var sessionTouchedPaths: Table[cstring, seq[cstring]] = initTable[cstring, seq[cstring]]()
# Paths written via the writeTextFile ACP callback (session-agnostic, single session assumed).
var writeTrackedPaths: seq[cstring] = @[]
# Snapshot of file content BEFORE the agent first touched it during the current
# prompt (not consumed by tool_call_update, lives until end-of-session diff computation).
# Key: absolute file path. Only the FIRST write per file per prompt is stored.
var promptOriginalCache: Table[cstring, cstring] = initTable[cstring, cstring]()
# Last known file content after each prompt's diff computation. Used as the original
# baseline for the NEXT prompt when the agent uses bash (or any tool that modifies
# files without going through ACP writeTextFile or producing a structured filediff).
var lastKnownContent: Table[cstring, cstring] = initTable[cstring, cstring]()
# Git-level snapshot of changed+new files captured just before each prompt starts.
# Used at end of prompt to find only what the agent changed during this prompt.
var promptGitBaseline: seq[cstring] = @[]

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
    # Capture the previous contents (best-effort) so diffs can render even when
    # ACP only provides the new text.
    var prevContent = cstring""
    if not originalFileCache.hasKey(path):
      try:
        prevContent = await readFileUtf8(path)
        originalFileCache[path] = prevContent
      except:
        discard
    else:
      prevContent = originalFileCache[path]
    # promptOriginalCache stores the FIRST pre-write content for each file per
    # prompt so the end-of-session diff shows only what the agent changed, not
    # the full file (critical for untracked files not in git HEAD).
    if not promptOriginalCache.hasKey(path):
      promptOriginalCache[path] = prevContent

    await writeFileUtf8(path, content)
    # Track every path written so end-of-session diffs can cover them all.
    var alreadyTracked = false
    for tp in writeTrackedPaths:
      if tp == path:
        alreadyTracked = true
        break
    if not alreadyTracked:
      writeTrackedPaths.add(path)
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
        if updateKind == cstring"tool_call":
          let toolCallId =
            if jsHasKey(updateObj, cstring"toolCallId"):
              updateObj[cstring"toolCallId"].to(cstring)
            else:
              cstring""
          let toolTitle =
            if jsHasKey(updateObj, cstring"title"):
              updateObj[cstring"title"].to(cstring)
            else:
              cstring""
          # Forward tool call info to the renderer so it can display it in real-time.
          mainWindow.webContents.send("CODETRACER::acp-tool-call", js{
            "sessionId": acpSessionId,
            "clientSessionId": clientSessionId,
            "messageId": state.currentMessageId,
            "id": cstring("tool-" & $toolCallId),
            "toolCallId": toolCallId,
            "toolName": toolTitle
          })
          if jsHasKey(updateObj, cstring"options"):
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
          # Forward file/content tool outputs directly to the renderer so the AgentActivity can render them.
          let toolCallId =
            if jsHasKey(updateObj, cstring"toolCallId"):
              updateObj[cstring"toolCallId"].to(cstring)
            else:
              cstring""
          var original = cstring""
          var modified = cstring""
          var path = cstring""
          if jsHasKey(updateObj, cstring"rawOutput") and jsHasKey(updateObj[cstring"rawOutput"], cstring"output"):
            original = updateObj[cstring"rawOutput"][cstring"output"].to(cstring)
          if jsHasKey(updateObj, cstring"rawOutput") and jsHasKey(updateObj[cstring"rawOutput"], cstring"filediff"):
            let fd = updateObj[cstring"rawOutput"][cstring"filediff"]
            if path.len == 0 and jsHasKey(fd, cstring"file"):
              path = fd[cstring"file"].to(cstring)
            if original.len == 0 and jsHasKey(fd, cstring"original"):
              original = fd[cstring"original"].to(cstring)
            if modified.len == 0 and jsHasKey(fd, cstring"modified"):
              modified = fd[cstring"modified"].to(cstring)
            if modified.len == 0 and jsHasKey(fd, cstring"newText"):
              modified = fd[cstring"newText"].to(cstring)
          if jsHasKey(updateObj, cstring"rawInput"):
            let rawInput = updateObj[cstring"rawInput"]
            if jsHasKey(rawInput, cstring"content"):
              modified = rawInput[cstring"content"].to(cstring)
            if jsHasKey(rawInput, cstring"filePath"):
              path = rawInput[cstring"filePath"].to(cstring)
            elif jsHasKey(rawInput, cstring"filepath"):
              path = rawInput[cstring"filepath"].to(cstring)
            elif jsHasKey(rawInput, cstring"path"):
              path = rawInput[cstring"path"].to(cstring)
          # Fallbacks: newer payloads may carry the path/new text only in "content".
          if path.len == 0 and jsHasKey(updateObj, cstring"content"):
            try:
              let contentItems = updateObj[cstring"content"].to(seq[JsObject])
              for item in contentItems:
                if jsHasKey(item, cstring"path"):
                  path = item[cstring"path"].to(cstring)
                if jsHasKey(item, cstring"text"):
                  modified = item[cstring"text"].to(cstring)
                elif jsHasKey(item, cstring"newText"):
                  modified = item[cstring"newText"].to(cstring)
                elif jsHasKey(item, cstring"modified"):
                  modified = item[cstring"modified"].to(cstring)
                if original.len == 0 and jsHasKey(item, cstring"original"):
                  original = item[cstring"original"].to(cstring)
                if path.len > 0 and modified.len > 0:
                  break
            except:
              let contentObj = updateObj[cstring"content"]
              if jsHasKey(contentObj, cstring"path"):
                path = contentObj[cstring"path"].to(cstring)
              if modified.len == 0:
                if jsHasKey(contentObj, cstring"text"):
                  modified = contentObj[cstring"text"].to(cstring)
                elif jsHasKey(contentObj, cstring"newText"):
                  modified = contentObj[cstring"newText"].to(cstring)
          # Another fallback for path: some payloads nest it under location.
          if path.len == 0 and jsHasKey(updateObj, cstring"location") and jsHasKey(updateObj[cstring"location"], cstring"path"):
            path = updateObj[cstring"location"][cstring"path"].to(cstring)

          # If ACP only delivered the new content, try to recover the original
          # from our pre-write cache, or as a last resort from disk.
          if original.len == 0 and path.len > 0 and originalFileCache.hasKey(path):
            original = originalFileCache[path]
            originalFileCache.del(path)
          if original.len == 0 and path.len > 0:
            try:
              original = await readFileUtf8(path)
            except:
              discard
          # If ACP omitted the modified text, fall back to the current file
          # contents so the renderer still shows a diff.
          if modified.len == 0 and path.len > 0:
            try:
              modified = await readFileUtf8(path)
            except:
              discard

          # Snapshot the pre-modification original for the authoritative end-of-session diff.
          # str_replace_editor and similar tools supply the real pre-modification content in
          # rawOutput.filediff.original; saving it here ensures the end-of-prompt loop uses
          # the correct baseline instead of falling back to an empty original.
          if path.len > 0 and original.len > 0 and not promptOriginalCache.hasKey(path):
            promptOriginalCache[path] = original

          # Log what we are about to forward (trim content to avoid huge console noise).
          let origPreview =
            block:
              let s = $original
              (if s.len > 200: (s[0 .. 199] & "...") else: s).cstring
          let modPreview =
            block:
              let s = $modified
              (if s.len > 200: (s[0 .. 199] & "...") else: s).cstring
          echo fmt"[acp_ipc] render-diff payload path={path} origLen={original.len} modLen={modified.len} origPreview={origPreview} modPreview={modPreview}"

          if path.len > 0 and (original.len > 0 or modified.len > 0):
            mainWindow.webContents.send("CODETRACER::acp-render-diff", js{
              "sessionId": acpSessionId,
              "clientSessionId": clientSessionId,
              "id": toolCallId,
              "path": path,
              "original": original,
              "modified": modified
            })
            # Track every path the agent touches for authoritative end-of-session diffs.
            if not sessionTouchedPaths.hasKey(acpSessionId):
              sessionTouchedPaths[acpSessionId] = @[]
            var touched = sessionTouchedPaths[acpSessionId]
            var alreadyTracked = false
            for tp in touched:
              if tp == path:
                alreadyTracked = true
                break
            if not alreadyTracked:
              touched.add(path)
            sessionTouchedPaths[acpSessionId] = touched
        if updateKind == cstring"tool_call_update":
          let toolCallIdForUpdate =
            if jsHasKey(updateObj, cstring"toolCallId"):
              updateObj[cstring"toolCallId"].to(cstring)
            else:
              cstring""
          let statusForUpdate =
            if jsHasKey(updateObj, cstring"status"):
              updateObj[cstring"status"].to(cstring)
            else:
              cstring"completed"
          if toolCallIdForUpdate.len > 0:
            mainWindow.webContents.send("CODETRACER::acp-tool-call-update", js{
              "sessionId": acpSessionId,
              "clientSessionId": clientSessionId,
              "toolCallId": toolCallIdForUpdate,
              "status": statusForUpdate
            })
        if updateKind == cstring"tool_call_update":
          try:
            var path = cstring""
            if jsHasKey(updateObj, cstring"rawInput"):
              let rawIn = updateObj[cstring"rawInput"]
              if jsHasKey(rawIn, cstring"filepath"):
                path = rawIn[cstring"filepath"].to(cstring)
              elif jsHasKey(rawIn, cstring"filePath"):
                path = rawIn[cstring"filePath"].to(cstring)
              elif jsHasKey(rawIn, cstring"path"):
                path = rawIn[cstring"path"].to(cstring)

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
            if path.len == 0 and jsHasKey(updateObj, cstring"location") and jsHasKey(updateObj[cstring"location"], cstring"path"):
              path = updateObj[cstring"location"][cstring"path"].to(cstring)

            if path.len == 0 and jsHasKey(updateObj, cstring"rawOutput"):
              let rawOut = updateObj[cstring"rawOutput"]
              if jsHasKey(rawOut, cstring"filediff") and jsHasKey(rawOut[cstring"filediff"], cstring"file"):
                path = rawOut[cstring"filediff"][cstring"file"].to(cstring)

            if path.len > 0:
              mainWindow.webContents.send("CODETRACER::reload-file", js{ "path": path })
              mainWindow.webContents.send("CODETRACER::change-file", js{ "path": path })
              # Track path for end-of-session diffs even when the streaming diff block
              # couldn't find original/modified content (e.g. bash tool calls where the
              # agent puts the path in rawInput but produces no structured filediff output).
              if not sessionTouchedPaths.hasKey(acpSessionId):
                sessionTouchedPaths[acpSessionId] = @[]
              var touchedPaths = sessionTouchedPaths[acpSessionId]
              var pathAlreadyTracked = false
              for tp in touchedPaths:
                if tp == path: pathAlreadyTracked = true; break
              if not pathAlreadyTracked: touchedPaths.add(path)
              sessionTouchedPaths[acpSessionId] = touchedPaths
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

  # Snapshot all git-visible files (modified tracked + untracked) before the prompt starts.
  # For files not yet in lastKnownContent: read and store their current content so the
  # end-of-prompt comparison can detect bash modifications to ANY of them, not just
  # previously-tracked files.  The baseline set is also used by git detection to
  # identify truly brand-new files (created from scratch during the prompt).
  promptGitBaseline = @[]
  {.emit: """
  (() => {
    try {
      const cp = require('child_process');
      const path = require('path');
      const cwd = process.cwd();
      function gitLines(args) {
        const r = cp.spawnSync('git', args, { encoding: 'utf8', timeout: 10000, cwd });
        return (!r.error && r.status === 0 && r.stdout)
          ? r.stdout.trim().split('\n').filter(Boolean) : [];
      }
      const paths = [...gitLines(['diff', '--name-only', 'HEAD']),
                     ...gitLines(['ls-files', '--others', '--exclude-standard'])];
      for (const p of paths) { `promptGitBaseline`.push(path.resolve(cwd, p)); }
    } catch(e) {}
  })();
  """.}
  # Read content of git-visible files not yet in lastKnownContent so we have a
  # pre-prompt baseline for every file the agent might touch via bash.
  for gitPath in promptGitBaseline:
    if not lastKnownContent.hasKey(gitPath):
      try:
        let content = await readFileUtf8(gitPath)
        lastKnownContent[gitPath] = content
      except:
        discard

  let promptResp = await acpClient.prompt(promptRequest(sessionId, text))
  let stopReason = stopReasonFrom(promptResp)

  # Compute authoritative diffs for every file the agent touched during this
  # session.  Merge paths from tool_call_update events and writeTextFile calls,
  # then for each path compute original (pre-session git content) and modified
  # (current file content) so the renderer gets accurate diffs even when the
  # agent used bash/apply_patch/str_replace_editor instead of writeTextFile.
  var allTouchedPaths: seq[cstring] = @[]
  if sessionTouchedPaths.hasKey(sessionId):
    allTouchedPaths = sessionTouchedPaths[sessionId]
  for p in writeTrackedPaths:
    var found = false
    for tp in allTouchedPaths:
      if tp == p:
        found = true
        break
    if not found:
      allTouchedPaths.add(p)
  writeTrackedPaths = @[]
  sessionTouchedPaths.del(sessionId)

  # Always check previously-known files for bash-induced changes that primary
  # tracking missed.  Run unconditionally so we catch files whether or not
  # primary tracking already found some others in this prompt.
  for prevPath, prevContent in lastKnownContent.pairs:
    try:
      let currentContent = await readFileUtf8(prevPath)
      if currentContent != prevContent:
        var alreadyTracked = false
        for tp in allTouchedPaths:
          if tp == prevPath: alreadyTracked = true; break
        if not alreadyTracked:
          allTouchedPaths.add(prevPath)
          if not promptOriginalCache.hasKey(prevPath):
            promptOriginalCache[prevPath] = prevContent
    except:
      discard

  # Git-based detection: files modified or created during this prompt that
  # weren't caught by primary tracking or lastKnownContent (e.g. brand-new
  # files written for the first time via bash this prompt).
  var gitCurrentPaths: seq[cstring] = @[]
  {.emit: """
  (() => {
    try {
      const cp = require('child_process');
      const path = require('path');
      const cwd = process.cwd();
      function gitLines2(args) {
        const r = cp.spawnSync('git', args, { encoding: 'utf8', timeout: 10000, cwd });
        return (!r.error && r.status === 0 && r.stdout)
          ? r.stdout.trim().split('\n').filter(Boolean) : [];
      }
      const paths = [...gitLines2(['diff', '--name-only', 'HEAD']),
                     ...gitLines2(['ls-files', '--others', '--exclude-standard'])];
      for (const p of paths) { `gitCurrentPaths`.push(path.resolve(cwd, p)); }
    } catch(e) {}
  })();
  """.}
  for gitPath in gitCurrentPaths:
    # Skip files that were already changed before this prompt started.
    var wasInBaseline = false
    for bp in promptGitBaseline:
      if bp == gitPath: wasInBaseline = true; break
    if wasInBaseline: continue
    # Skip files already in the tracked set.
    var alreadyTracked = false
    for tp in allTouchedPaths:
      if tp == gitPath: alreadyTracked = true; break
    if alreadyTracked: continue
    allTouchedPaths.add(gitPath)
    # Supply the pre-prompt original from git HEAD (empty for brand-new files).
    if not promptOriginalCache.hasKey(gitPath):
      let headContent = gitFileAtHead(gitPath)
      if headContent.len > 0:
        promptOriginalCache[gitPath] = headContent

  if allTouchedPaths.len > 0:
    # Tell the renderer to reset stale incremental diffs for this message before
    # we send the fresh authoritative set.
    mainWindow.webContents.send("CODETRACER::acp-clear-diffs", js{
      "sessionId": sessionId,
      "clientSessionId": clientSessionId,
      "id": messageId
    })
    for filePath in allTouchedPaths:
      try:
        # Use the content snapshotted before the first write this prompt as the
        # original, so the diff shows only what the agent changed — not the full
        # file vs git HEAD (which breaks for untracked files).
        var original = cstring""
        if promptOriginalCache.hasKey(filePath):
          original = promptOriginalCache[filePath]
        var modified = cstring""
        var fileExists = false
        try:
          modified = await readFileUtf8(filePath)
          fileExists = true
        except:
          discard
        # Send diff when file exists now (even empty new file) or had content before (deletion).
        if fileExists or original.len > 0:
          mainWindow.webContents.send("CODETRACER::acp-render-diff", js{
            "sessionId": sessionId,
            "clientSessionId": clientSessionId,
            "id": messageId,
            "path": filePath,
            "original": original,
            "modified": modified
          })
        # Always track file content (even empty) so subsequent prompts can detect further changes.
        if fileExists:
          lastKnownContent[filePath] = modified
      except:
        errorPrint cstring(fmt"[acp_ipc] end-of-session diff failed for {filePath}: {getCurrentExceptionMsg()}")
  promptOriginalCache = initTable[cstring, cstring]()

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
