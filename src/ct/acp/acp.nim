import std/[jsffi, asyncjs]

# Lightweight Nim bindings for @agentclientprotocol/sdk (To be used as part of the main index process)

# Try to require from several common locations so dev/prod builds both work.
{.emit: """
let __acpSdk;
try {
  __acpSdk = require('@agentclientprotocol/sdk');
} catch (e) {
  const path = require('path');
  const candidates = [
    path.join(process.cwd(), 'node_modules', '@agentclientprotocol', 'sdk'),
    path.join(process.cwd(), 'node-packages', 'node_modules', '@agentclientprotocol', 'sdk')
  ];
  for (const c of candidates) {
    try {
      __acpSdk = require(c);
      break;
    } catch {}
  }
  if (!__acpSdk) throw e;
}
""".}

type
  AcpStream* = JsObject
  WebReadableStream* = JsObject
  WebWritableStream* = JsObject

  ## Client-side connection (editor) view of ACP.
  ClientSideConnection* = ref object of js
    initialize*:       proc(params: JsObject): Future[JsObject]
    newSession*:       proc(params: JsObject): Future[JsObject]
    loadSession*:      proc(params: JsObject): Future[JsObject]
    setSessionMode*:   proc(params: JsObject): Future[JsObject]
    setSessionModel*:  proc(params: JsObject): Future[JsObject]
    authenticate*:     proc(params: JsObject): Future[JsObject]
    prompt*:           proc(params: JsObject): Future[JsObject]
    cancel*:           proc(params: JsObject): Future[void]
    extMethod*:        proc(methodName: cstring, params: JsObject): Future[JsObject]
    extNotification*:  proc(methodName: cstring, params: JsObject): Future[void]
    signal*:           JsObject
    closed*:           Future[void]

  ## Agent-side connection (LLM agent) view of ACP.
  AgentSideConnection* = ref object of js
    sessionUpdate*:     proc(params: JsObject): Future[void]
    requestPermission*: proc(params: JsObject): Future[JsObject]
    readTextFile*:      proc(params: JsObject): Future[JsObject]
    writeTextFile*:     proc(params: JsObject): Future[JsObject]
    createTerminal*:    proc(params: JsObject): Future[JsObject]
    extMethod*:         proc(methodName: cstring, params: JsObject): Future[JsObject]
    extNotification*:   proc(methodName: cstring, params: JsObject): Future[void]
    signal*:            JsObject
    closed*:            Future[void]

  TerminalHandle* = ref object of js
    currentOutput*: proc(): Future[JsObject]
    waitForExit*:   proc(): Future[JsObject]
    kill*:          proc(): Future[JsObject]
    release*:       proc(): Future[JsObject]

proc ndJsonStream*(output: WebWritableStream; input: WebReadableStream): AcpStream {.
  importjs: "__acpSdk.ndJsonStream(#, #)".}

proc newClientSideConnection*(toClient: js; stream: AcpStream): ClientSideConnection {.
  importjs: "(new __acpSdk.ClientSideConnection(#, #))".}

# NOTE: This will probably not be needed
proc newAgentSideConnection*(toAgent: js; stream: AcpStream): AgentSideConnection {.
  importjs: "(new __acpSdk.AgentSideConnection(#, #))".}

let PROTOCOL_VERSION* {.importjs: "__acpSdk.PROTOCOL_VERSION".}: int
