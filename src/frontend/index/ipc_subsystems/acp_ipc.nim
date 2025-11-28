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

proc initRequest(): JsObject {.importjs: "({ protocolVersion: __acpSdk.PROTOCOL_VERSION, clientCapabilities: {} })".}
proc newSessionRequest(): JsObject {.importjs: "({ cwd: process.cwd(), mcpServers: [] })".}

proc promptRequest(sessionId: cstring, message: cstring): JsObject {.importjs: "({ sessionId: #, prompt: [{ type: 'text', text: '#' }] })".}

proc stringify(obj: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc makeClient(): JsObject {.importjs: "(() => ({ requestPermission: async () => ({ outcome: { outcome: 'denied', optionId: '' } }), sessionUpdate: async (params) => { console.log('[client] sessionUpdate', params); }, writeTextFile: async () => ({}), readTextFile: async () => ({ content: '' }), createTerminal: async () => ({ id: 'term-1' }), extMethod: async () => ({}), extNotification: async () => {} }))()".}
proc asFactory(obj: JsObject): js {.importjs: "(function(v){ return function(){ return v; }; })(#)".}

proc sessionIdFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.sessionId) || 'session-1')(#)".}
proc stopReasonFrom(response: JsObject): cstring {.importjs: "((resp) => (resp && resp.stopReason) || '')(#)".}

proc log(obj: JsObject) {.importjs: "console.log(#)"}

const
  defaultCmd = cstring"opencode"
  defaultArgs: seq[cstring] = @[cstring"acp"]

var msgId = 100

proc onAcpPrompt*(sender: js, response: JsObject) {.async.} =

  let text = response["text"]

  echo fmt"[acp_ipc] got text: {text}"

  let procHandle = spawnProcess(defaultCmd, defaultArgs)

  echo "[acp_ipc] started the acp server"

  let stream = ndJsonStream(
    toWebWritable(stdinOf(procHandle)),
    toWebReadable(stdoutOf(procHandle)))

  echo "[acp_ipc] set up the pipes"

  # ClientSideConnection expects a factory function, not a plain object
  let clientConn = newClientSideConnection(asFactory(makeClient()), stream)

  echo "[acp_ipc] established a client-side connection"

  let initResp = await clientConn.initialize(initRequest())
  echo "[acp_ipc] initialized response raw=", stringify(initResp)

  let sessionResp = await clientConn.newSession(newSessionRequest())

  let sessionId = sessionIdFrom(sessionResp)

  var promptResp = await clientConn.prompt(promptRequest(sessionId, cstring"Hello, how are you"));

  mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
    "id": cstring($msgId),
    "content": "wassup"
  })

  msgId += 1
