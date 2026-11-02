## viewmodel/host/agent_live_worker.nim — a LIVE agent session for a native
## front-end: a real ACP agent over its real stdio, driven from a thread so
## the terminal's and the GPUI window's loops keep painting while it works.
##
## The desktop speaks ACP from its Electron main process (`index/
## ipc_subsystems/acp_ipc.nim`) and forwards updates to the renderer over
## IPC. A native front-end has no second process to put the protocol in, and
## `nim-agents`' client is synchronous: `sendPromptStreaming` returns when the
## turn ends, calling back per update as frames arrive. So the client lives on
## a worker thread that owns it entirely, and the two threads exchange JSON
## lines over two channels:
##
##   commands in   {"t":"start","command":…,"args":[…],"cwd":…}
##                 {"t":"prompt","text":…}
##                 {"t":"stop"}
##   reports out   {"t":"started","sessionId":…}
##                 {"t":"event","event":<AgentEvent.toJson>}
##                 {"t":"turn-ended","stopReason":…}
##                 {"t":"error","message":…}
##                 {"t":"stopped"}
##
## The event form is `nim-agents`' own `toJson` / `agentEventFromJson` pair
## (the transport form a resolved session crosses `ct`'s process boundary in),
## so nothing here invents a protocol of its own. The main thread applies
## events to the store through `agent_service.applyEvents`, exactly as a
## desktop session's events are applied.
##
## A prompt sent while a turn is running waits for it to end (the agent
## protocol has one turn per session at a time); "stop" is honoured between
## turns, and ends the agent process.

import std/[json, os]

import nim_agents

type
  AgentLiveWorker* = ref object
    thread: Thread[int]
    slot: int
    running*: bool

var
  gCommands: array[4, Channel[string]]
  gReports: array[4, Channel[string]]
  gSlotsUsed: array[4, bool]

proc send(slot: int; payload: JsonNode) =
  gReports[slot].send($payload)

proc workerMain(slot: int) {.thread.} =
  {.cast(gcsafe).}:
    var client: AgentClient
    var session: AgentSession
    var connected = false
    while true:
      let line = gCommands[slot].recv()
      var cmd: JsonNode
      try:
        cmd = parseJson(line)
      except CatchableError:
        continue
      let t = cmd{"t"}.getStr("")
      try:
        case t
        of "start":
          var args: seq[string] = @[]
          for a in cmd{"args"}.getElems(@[]):
            args.add a.getStr("")
          client = fromStdioAcpAgent(cmd{"command"}.getStr(""), args)
          discard client.acp.initialize(InitializeRequest(
            protocolVersion: 1,
            clientInfo: ClientInfo(name: "codetracer", version: "native"),
            clientCapabilities: ClientCapabilities(streaming: true)))
          let cwd = cmd{"cwd"}.getStr(getCurrentDir())
          session = client.startSession(cwd)
          connected = true
          send(slot, %*{"t": "started", "sessionId": session.id})
        of "prompt":
          if not connected:
            send(slot, %*{"t": "error",
                          "message": "the agent is not connected"})
            continue
          let onEvent: AgentEventCallback = proc(event: AgentEvent) {.gcsafe.} =
            {.cast(gcsafe).}:
              send(slot, %*{"t": "event", "event": event.toJson()})
          let turn = client.sendPromptStreaming(session,
            @[textBlock(cmd{"text"}.getStr(""))], onEvent)
          send(slot, %*{"t": "turn-ended",
                        "stopReason": $turn.stopReason})
        of "stop":
          if connected:
            client.shutdown()
            connected = false
          send(slot, %*{"t": "stopped"})
          return
        else:
          discard
      except CatchableError as e:
        send(slot, %*{"t": "error", "message": e.msg})
        if t == "start":
          send(slot, %*{"t": "stopped"})
          return

proc startLiveWorker*(): AgentLiveWorker =
  ## A worker thread with its own channel pair, or nil when every slot is in
  ## use.
  for i in 0 ..< gSlotsUsed.len:
    if not gSlotsUsed[i]:
      gSlotsUsed[i] = true
      gCommands[i].open()
      gReports[i].open()
      result = AgentLiveWorker(slot: i, running: true)
      createThread(result.thread, workerMain, i)
      return

proc command*(w: AgentLiveWorker; payload: JsonNode) =
  if not w.isNil and w.running:
    gCommands[w.slot].send($payload)

proc drain*(w: AgentLiveWorker): seq[JsonNode] =
  ## Every report the worker has sent since the last drain, in order.
  if w.isNil:
    return
  while true:
    let (ok, line) = gReports[w.slot].tryRecv()
    if not ok:
      break
    try:
      let node = parseJson(line)
      result.add node
      if node{"t"}.getStr("") == "stopped":
        w.running = false
    except CatchableError:
      discard

proc release*(w: AgentLiveWorker; wait = true) =
  ## Stop the worker (after its current turn) and free its slot. With `wait`
  ## false — a turn still running as the window closes — the stop is sent and
  ## the thread left to end with the process: joining it would hold the
  ## window open until the agent's turn is over.
  if w.isNil:
    return
  if w.running:
    w.command(%*{"t": "stop"})
  if not wait:
    return
  joinThread(w.thread)
  w.running = false
  discard w.drain()
  gCommands[w.slot].close()
  gReports[w.slot].close()
  gSlotsUsed[w.slot] = false
