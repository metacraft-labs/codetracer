## index/hosted_session.nim — the `ct host` server's connection between a
## session it owns for a client (`sync/hosted_primary`) and that client's
## replay.
##
## The server's session is a second client of the replay the page drives: it
## talks to the Backend Manager over the index's own connection
## (`ipc_subsystems/dap.sendLocalDapRequest`), beside the page's requests,
## and its answers come back to it alone.
##
## JS only: it runs in the `ct host` server process.

when not defined(js):
  {.error: "index/hosted_session runs in the ct host server (JS).".}

import std/[asyncjs, json, jsffi]

import ipc_subsystems/dap
import ../viewmodel/backend/backend_service
import ../viewmodel/sync/hosted_primary
import ../../common/lang as common_lang
export hosted_primary

proc stringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc jsParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}

proc jsonOf(o: JsObject): JsonNode =
  if o.isNil: newJNull() else: parseJson($stringify(o))

proc newIndexDapBackendService*(sessionId: int): BackendService =
  ## A `BackendService` over the index's connection to the Backend Manager,
  ## for the replay `sessionId` names. A request resolves with the whole DAP
  ## response, or `null` when there is no Backend Manager to send to; an
  ## event reaches the handler as `{"kind": <event>, "data": <body>}`, the
  ## envelope every ViewModel event handler reads.
  var stopListening: seq[proc()] = @[]

  proc send(command: string; args: JsonNode): BackendFuture[JsonNode] =
    let arguments = jsParse(cstring($(if args.isNil: newJObject() else: args)))
    newPromise(proc(resolve: proc(response: JsonNode)) =
      let sent = sendLocalDapRequest(sessionId, cstring(command), arguments,
        proc(response: JsObject) = resolve(jsonOf(response)))
      if not sent:
        resolve(newJNull()))

  proc onEvent(handler: EventHandler) =
    proc listener(event: JsObject) =
      let e = jsonOf(event)
      let body = e{"body"}
      handler(%*{"kind": e{"event"}.getStr(""),
                 "data": (if body.isNil: newJObject() else: body)})
    stopListening.add addLocalDapEventListener(sessionId, listener)

  proc disconnect() =
    for stop in stopListening:
      stop()
    stopListening = @[]

  BackendService(sendProc: send, onEventProc: onEvent,
                 disconnectProc: disconnect)

proc openHostedSession*(sessions: HostedSessions; id: string; replayId: int;
                        traceFolder: string): HostedPrimary =
  ## Session `id` among `sessions`, over the replay `replayId` (a client's,
  ## `host_clients`), naming each file's language as the page names it
  ## (`ui/state.installSourceLanguage`).
  openHostedPrimary(sessions, id, newIndexDapBackendService(replayId), traceFolder,
    proc(file: string): string =
      langWireName(common_lang.toLangFromFilename(file)))
