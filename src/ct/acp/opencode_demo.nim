import std/[asyncjs, jsffi, strformat]

import acp

## Demo: connect as an ACP client to an external agent (e.g., OpenCode) via stdio.
## Adjust OPENCODE_ACP_CMD / OPENCODE_ACP_ARGS to match your agent binary and flags.

const
  defaultCmd = cstring"opencode"
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
proc promptRequest(sessionId: cstring): JsObject {.importjs: "({ sessionId: #, prompt: [{ type: 'text', text: 'Hello there, which model are you ?' }] })".}
proc stringify(obj: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc makeClient(): JsObject {.importjs: "(() => ({ requestPermission: async () => ({ outcome: { outcome: 'denied', optionId: '' } }), sessionUpdate: async (params) => { console.log('[client] sessionUpdate', params); }, writeTextFile: async () => ({}), readTextFile: async () => ({ content: '' }), createTerminal: async () => ({ id: 'term-1' }), extMethod: async () => ({}), extNotification: async () => {} }))()".}
proc asFactory(obj: JsObject): js {.importjs: "(function(v){ return function(){ return v; }; })(#)".}

proc sessionIdFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.sessionId) || 'session-1')(#)".}
proc stopReasonFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.stopReason) || '')(#)".}

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

  let sessionResp = await clientConn.newSession(newSessionRequest())
  let sessionId = sessionIdFrom(sessionResp)
  echo fmt"[demo] sessionId={sessionId}"

  let promptResp = await clientConn.prompt(promptRequest(sessionId))
  echo fmt"[demo] stopReason={stopReasonFrom(promptResp)}"

when isMainModule:
  discard main()
