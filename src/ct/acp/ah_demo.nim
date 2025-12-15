import std/[asyncjs, jsffi, strformat]

import acp

## Demo: connect as an ACP client to an external agent (e.g., OpenCode) via stdio.
## Adjust OPENCODE_ACP_CMD / OPENCODE_ACP_ARGS to match your agent binary and flags.

const
  defaultCmd = cstring"ah"
  defaultArgs: seq[cstring] = @[cstring"acp"]

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

proc initRequest(): JsObject {.importjs: "({ protocolVersion: __acpSdk.PROTOCOL_VERSION, clientCapabilities: {} })".}
proc newSessionRequest(): JsObject {.importjs: "({ cwd: process.cwd(), mcpServers: [] })".}
proc loadSessionRequest(sessionId: cstring): JsObject {.importjs: "({ cwd: process.cwd(), mcpServers: [], sessionId: # })".}

proc promptRequest(sessionId: cstring, message: cstring): JsObject {.importjs: "({ sessionId: #, prompt: [{ type: 'text', text: '#' }] })".}

proc stringify(obj: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc makeClient(): JsObject {.importjs: "(() => ({ requestPermission: async () => ({ outcome: { outcome: 'denied', optionId: '' } }), sessionUpdate: async (params) => { console.log('[client] sessionUpdate', params); }, writeTextFile: async () => ({}), readTextFile: async () => ({ content: '' }), createTerminal: async () => ({ id: 'term-1' }), extMethod: async () => ({}), extNotification: async () => {} }))()".}
proc asFactory(obj: JsObject): js {.importjs: "(function(v){ return function(){ return v; }; })(#)".}

proc sessionIdFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.sessionId) || 'session-1')(#)".}
proc stopReasonFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.stopReason) || '')(#)".}

proc log(obj: JsObject) {.importjs: "console.log(#)"}

proc main() {.async.} =
  let cmd = block:
    let envCmd = getEnv(cstring"OPENCODE_ACP_CMD")
    if envCmd.len > 0: envCmd else: defaultCmd

  let args = block:
    let envArgs = getEnv(cstring"OPENCODE_ACP_ARGS")
    if envArgs.len > 0: parseArgs(envArgs) else: defaultArgs

  echo fmt"[demo] launching {cmd} {args}"
  let procHandle = spawnProcess(cmd, args)

  let stream = ndJsonStream(
    toWebWritable(stdinOf(procHandle)),
    toWebReadable(stdoutOf(procHandle)))

  # ClientSideConnection expects a factory function, not a plain object
  let clientConn = newClientSideConnection(asFactory(makeClient()), stream)

  let initResp = await clientConn.initialize(initRequest())
  echo "[demo] initialized response raw=", stringify(initResp)

  # Start a new session, then demonstrate loading it by id to resume later.
  let sessionResp = await clientConn.newSession(newSessionRequest())
  echo "[demo] session response raw=", stringify(sessionResp)

  let sessionId = sessionIdFrom(sessionResp)
  echo fmt"[demo] sessionId={sessionId}"

  try:
    let loadResp = await clientConn.loadSession(loadSessionRequest(sessionId))
    echo "[demo] loadSession response raw=", stringify(loadResp)
  except:
    echo fmt"[demo] loadSession failed for {sessionId}: {getCurrentExceptionMsg()}"

  var promptResp = await clientConn.prompt(promptRequest(sessionId, cstring"In the current dir, change the CHANGELOG file to include a change that we now use absolute paths"));
  echo fmt"[demo] stopReason={stopReasonFrom(promptResp)}"

  # let session2Id = sessionIdFrom(session2Resp)

  # echo fmt"[demo] sessionId={session1Id}"
  # echo fmt"[demo] sessionId={session2Id}"

  # var promptResp = await clientConn.prompt(promptRequest(session1Id, cstring"Hello, how are you"));
  # echo fmt"[demo] stopReason={stopReasonFrom(promptResp)}"
  #
  # promptResp = await clientConn.prompt(promptRequest(session2Id, cstring"When was Osama bin laden born"))
  # echo fmt"[demo] stopReason={stopReasonFrom(promptResp)}"
  #
  # promptResp = await clientConn.prompt(promptRequest(session1Id, cstring"When was barack obama born"));
  # echo fmt"[demo] stopReason={stopReasonFrom(promptResp)}"
  #
  # promptResp = await clientConn.prompt(promptRequest(session2Id, cstring"Who won the 2022 world football cup"))
  # echo fmt"[demo] stopReason={stopReasonFrom(promptResp)}"

when isMainModule:
  discard main()
