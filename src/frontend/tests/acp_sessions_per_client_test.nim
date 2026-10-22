## acp_sessions_per_client_test.nim — `ct host`'s clients each get their own
## agent (ACP) sessions.
##
## `ct host` serves several clients from one index process and one agent
## connection (`index/host_clients`; `CLI/ct/host.md`, "Sessions are
## isolated"). Every page names its agent session `agent-session-<component
## id>`, so two pages send the SAME name. The index must keep one ACP session
## per (client, name), send what the agent says about a session to the client
## that opened it — the agent's callbacks arrive on the agent connection, in no
## client's request — and refuse a client that names another client's ACP
## session. The desktop (no client) must behave as before.
##
## Doubles, and why: the agent connection is an object answering `newSession`
## and `cancel` (a real agent needs an installed binary and an account, and
## the property is about the index's bookkeeping, not the agent), and the
## window records each send together with the client it was made for, read
## from the real `served_client` context (`AsyncLocalStorage`) — the same
## value the server's send path routes by. The handlers, the routing wrapper
## and the context are the production ones. `include` keeps the session
## tables private to the module.
include ../index/ipc_subsystems/acp_ipc

{.emit: """
const assert = require('node:assert/strict');
let nextAcpSession = 0;
const cancelled = [];
""".}

type Sent = tuple[client, channel: cstring, payload: JsObject]

var sent: seq[Sent] = @[]

proc label(client: JsObject): cstring =
  if client.isNil: cstring"" else: client[cstring"label"].to(cstring)

proc recordSend(channel: cstring; payload: JsObject) =
  sent.add((label(currentClient()), channel, payload))

proc fakeConnection(): ClientSideConnection {.importjs: """
({newSession: () => Promise.resolve({sessionId: 'acp-' + (++nextAcpSession)}),
  cancel: (params) => { cancelled.push(params.sessionId); return Promise.resolve(); }})
""".}
proc cancelledIds(): seq[cstring] {.importjs: "cancelled.slice()".}

proc asClient(client: JsObject; work: proc(): Future[void]): Future[void] =
  ## Run `work` as `client`'s, as a handler bound to its socket would.
  var future: Future[void]
  runAsClient(client, proc() = future = work())
  future

proc lookupAs(client: JsObject; clientSessionId: cstring): cstring =
  var found: cstring
  runAsClient(client, proc() = found = acpSessionForClient(clientSessionId))
  found

proc agentCreatesTerminal(acpSessionId: cstring): Future[void] =
  ## The agent's `createTerminal` callback, arriving as the agent connection
  ## delivers it: through the routing wrapper, in no client's context.
  cast[Future[void]](callWith(runAsSessionOwner(handleCreateTerminal),
                              js{"sessionId": acpSessionId}))

proc sentOn(channel: cstring): seq[Sent] =
  for s in sent:
    if s.channel == channel:
      result.add s

proc run() {.async.} =
  mainWindow = js{"webContents": js{"send": functionAsJS(recordSend)}}
  acpClient = fakeConnection()
  acpInitialized = true

  let a = js{"label": cstring"A"}
  let b = js{"label": cstring"B"}
  let shared = cstring"agent-session-0"

  # Two clients open an agent session under the same page-side name.
  await asClient(a, proc(): Future[void] =
    onAcpSessionInit(jsUndefined, js{"clientSessionId": shared}))
  await asClient(b, proc(): Future[void] =
    onAcpSessionInit(jsUndefined, js{"clientSessionId": shared}))
  let ready = sentOn(cstring"CODETRACER::acp-session-ready")
  doAssert ready.len == 2, $ready.len
  doAssert ready[0].client == cstring"A" and
    ready[0].payload["sessionId"].to(cstring) == cstring"acp-1"
  doAssert ready[1].client == cstring"B" and
    ready[1].payload["sessionId"].to(cstring) == cstring"acp-2"
  # Each client's name reaches its own ACP session, not the last one opened.
  doAssert lookupAs(a, shared) == cstring"acp-1", $lookupAs(a, shared)
  doAssert lookupAs(b, shared) == cstring"acp-2", $lookupAs(b, shared)

  # The agent speaks about B's session: only B hears it, under B's own name.
  await agentCreatesTerminal(cstring"acp-2")
  await agentCreatesTerminal(cstring"acp-1")
  let terminals = sentOn(cstring"CODETRACER::acp-create-terminal")
  doAssert terminals.len == 2
  doAssert terminals[0].client == cstring"B", $terminals[0].client
  doAssert terminals[0].payload["clientSessionId"].to(cstring) == shared
  doAssert terminals[1].client == cstring"A", $terminals[1].client

  # A names B's ACP session directly: refused, the agent is not asked.
  await asClient(a, proc(): Future[void] =
    onAcpCancelPrompt(jsUndefined, js{"sessionId": cstring"acp-2"}))
  await asClient(a, proc(): Future[void] =
    onAcpStop(jsUndefined, js{"sessionId": cstring"acp-2"}))
  doAssert cancelledIds().len == 0, $cancelledIds().len
  # Positive control: B may cancel its own.
  await asClient(b, proc(): Future[void] =
    onAcpCancelPrompt(jsUndefined, js{"sessionId": cstring"acp-2"}))
  doAssert cancelledIds() == @[cstring"acp-2"]

  # The desktop: no client. The name is the page's own and the agent's
  # callbacks are not routed — sent outside every client, as before.
  await onAcpSessionInit(jsUndefined, js{"clientSessionId": shared})
  doAssert acpSessionForClient(shared) == cstring"acp-3"
  await agentCreatesTerminal(cstring"acp-3")
  let desktop = sentOn(cstring"CODETRACER::acp-create-terminal")
  doAssert desktop.len == 3 and desktop[2].client == cstring""
  await onAcpCancelPrompt(jsUndefined, js{"sessionId": cstring"acp-3"})
  doAssert cancelledIds() == @[cstring"acp-2", cstring"acp-3"]
  echo "PASS: ACP sessions are kept, routed and guarded per ct host client"

proc checkRun(future: Future[void]) {.
  importjs: "(#).catch(error => { console.error(error); process.exitCode = 1; })".}
checkRun(run())
