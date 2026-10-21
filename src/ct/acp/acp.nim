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
  if (!__acpSdk) {
    // ESM-only package — degrade gracefully so the main process still boots
    const noop = () => {};
    __acpSdk = {
      PROTOCOL_VERSION: 0,
      ndJsonStream: noop,
      createServer: noop,
      createClient: noop,
    };
  }
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

proc settle*(request: Future[JsObject]): Future[JsObject] {.
  importjs: "(#).then((value) => ({ ok: true, value: value }), (error) => ({ ok: false, error: error }))".}
  ## Turn a request's rejection into a value: the result resolves to
  ## `{ ok: true, value }` or `{ ok: false, error }` and never rejects.
  ##
  ## The SDK rejects a request whose response carries a JSON-RPC `error`
  ## member with that member itself — a plain `{ code, message, data }`
  ## object, not an `Error` (`ClientSideConnection`'s response handler).  A
  ## Nim `try`/`except` around the `await` only offers it back as a Nim
  ## exception, whose message is at most `message` ("Internal error"); the
  ## agent's actual reason is in `data`.  Settling keeps the raw object for
  ## `describeAcpError`.

proc describeAcpError*(error: JsObject): cstring {.importjs: """
((err) => {
  // A JSON-RPC 2.0 error object (link in the doc comment below; this body
  // must not contain a hash character, which importjs reads as a parameter):
  // `message` is the generic class ("Internal error"), `data` is where an ACP
  // agent puts the specific reason, as a string or as an object.
  if (err === null || err === undefined) return '';
  if (typeof err === 'string') return err;
  const message = typeof err.message === 'string' ? err.message : '';
  const data = err.data;
  let detail = '';
  if (typeof data === 'string') {
    detail = data;
  } else if (data !== null && typeof data === 'object') {
    if (typeof data.details === 'string') detail = data.details;
    else if (typeof data.message === 'string') detail = data.message;
    else { try { detail = JSON.stringify(data); } catch (e) { detail = ''; } }
  }
  const head = message + (typeof err.code === 'number' ? ' (' + err.code + ')' : '');
  if (message.length > 0 && detail.length > 0 && detail !== message) return head + ': ' + detail;
  if (message.length > 0) return head;
  if (detail.length > 0) return detail;
  // Nothing recognisable: show the value itself, unless it is an empty
  // object, which says nothing (the caller then supplies its own wording).
  try {
    const json = JSON.stringify(err);
    if (typeof json === 'string' && json !== '{}') return json;
  } catch (e) {}
  return err instanceof Error ? String(err) : '';
})(#)
""".}
  ## A one-line, user-readable description of a rejected ACP request: the
  ## JSON-RPC message and code, then the agent's own detail from `data`.
  ## The error object: https://www.jsonrpc.org/specification#error_object
  ## For #862's refusal this is "Internal error (-32603): unexpected status
  ## 400 Bad Request: {…"The 'gpt-6.1-sol' model is not supported…"}".
  ## Empty only for a rejection that carries nothing at all.
