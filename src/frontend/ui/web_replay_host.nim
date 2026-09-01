## The in-page host for the replay engine's DAP channel.
##
## ## The one sentence this module exists for
##
## `dap.asyncSendCtRequest` ends in
## `api.ipc.send("CODETRACER::dap-raw-message", packet)`, and on the web that
## id has no responder — `newWebIpc` logs *"no host for … this surface is not
## ported to the browser yet"* and every request resolves `{}` after its
## timeout. Give that id a responder and the entire existing pipeline starts
## working with no other change: `resolvePendingDapResponse` settles the
## `BackendService.send` futures, `receiveEvent` runs the legacy fan-out,
## `middleware` reaches `editor_service.onCompleteMove`, and every panel VM's
## store sees the same events it sees on the desktop.
##
## That is why the engine is installed HERE and not as a `BackendService`.
## Source text does not travel over the ViewModel backend at all:
## `editor_service` reads `location.missingPath` off a `ct/complete-move`
## event and then fetches the text with a `CODETRACER::tab-load` round trip,
## neither of which a backend swap touches. A session wired at the backend
## would step, resolve positions, and paint nothing.
##
## `installTemplateHost` answers `CODETRACER::tab-load` from the bundled
## template by exactly this method, and `enterTemplateEditMode` delivers
## `CODETRACER::no-trace` by it too — *"one door into edit mode, not two"*.
## This is that pattern applied to the channel beside them.
##
## ## The path spellings, which are the difference between painted and blank
##
## The browser Noir compiler is handed a virtual package tree and records
## `hello_noir/src/main.nr`; the renderer opens tabs by
## `/hello_noir/src/main.nr`. The engine echoes the recorded spelling in every
## location it reports, so a frame handed to `editor_service` unretargeted
## opens a SECOND, empty tab beside the one the user is looking at — and the
## bundled template host, which is what actually has the bytes, answers only
## for the renderer's spelling. `retargetLocationPaths` is applied to every
## inbound frame for that reason, and it reports a count so the walk cannot
## quietly stop finding anything.

import
  std/[ json, jsffi ],
  ui_imports

import ../viewmodel/backend/replay_session_service
import ../viewmodel/platform/replay_engine_vfs
import ../viewmodel/platform/web_deployment
import ../viewmodel/host/browser_replay_engine
import ../viewmodel/host/web_browser
import ../dap
from ../../common/ct_event import
  CtEventKind, DapInitialize, DapLaunch, DapConfigurationDone

var activeReplayTerminate: proc()
  ## The worker holding the current session, so a second Run replaces it
  ## rather than leaving two 18 MB wasm instances answering one store.
var replayFramesOut* = 0
var replayFramesIn* = 0
  ## Frames delivered into the renderer, and locations retargeted. Counters
  ## rather than a boolean because "a session opened" is the claim a broken
  ## one also makes; `ci/test/noir-replay-in-browser.sh` reads both.
var replayLocationsRetargeted* = 0
var lastReplayFailure* = ""

proc jsObjectFromJson(text: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsReportReplay(line: cstring) {.importjs: """
(function (s) { try { console.log(s); } catch (e) {} })(#)""".}

proc report(line: string) =
  ## One spelling of every milestone, on the console, where the browser gate
  ## reads it. `noir-build-in-browser.sh` reads `codetracer-` prefixed lines
  ## for the same reason: a probe that scraped the DOM for progress would be
  ## measuring the layout rather than the session.
  jsReportReplay(cstring("codetracer-replay: " & line))

proc deliverFrame(request: ReplaySessionRequest; frame: JsObject) =
  ## One inbound DAP frame, retargeted and routed to the entry point that
  ## matches its kind.
  ##
  ## Responses and events go to DIFFERENT ids. `dap-receive-response` settles
  ## the `asyncSendCtRequest` continuation waiting on `request_seq` and then
  ## runs the legacy fan-out; `dap-receive-event` only runs the fan-out. A
  ## response delivered as an event would leave every ViewModel future
  ## unresolved until its timeout while the legacy panels updated — the exact
  ## asymmetry `dap.nim`'s M49 comment records having cost a campaign.
  var decoded: JsonNode
  try:
    decoded = parseJson($frameJsonText(frame))
  except:
    # A BARE except: under `nim js` a malformed frame raises a `SyntaxError`
    # that `except CatchableError` does not catch, and an unhandled rejection
    # here would drop the frame with no reason recorded.
    decoded = nil
  if decoded.isNil:
    report("dropped a frame that is not JSON")
    return
  replayLocationsRetargeted += retargetLocationPaths(
    decoded, request.packageDir, request.projectRoot)
  let outbound = jsObjectFromJson(($decoded).cstring)
  replayFramesIn += 1
  # EVERY FRAME, not only the moves. A session that hands back nothing and a
  # session that hands back refusals are indistinguishable from the move log
  # alone, and both look exactly like "the engine is thinking". This line is
  # what turns the second into a sentence with a name in it.
  block:
    if decoded.kind != JObject:
      report("frame (not an object): " & ($decoded)[0 .. min(80, ($decoded).high)])
      return
    let kind =
      if decoded.hasKey("type") and decoded["type"].kind == JString:
        decoded["type"].getStr
      else: "?"
    let what =
      if decoded.hasKey("command") and decoded["command"].kind == JString:
        decoded["command"].getStr
      elif decoded.hasKey("event") and decoded["event"].kind == JString:
        decoded["event"].getStr
      else: "?"
    var detail = ""
    if decoded.hasKey("success") and decoded["success"].kind == JBool:
      detail = " success=" & $decoded["success"].getBool
    if decoded.hasKey("message") and decoded["message"].kind == JString:
      detail.add " message=" & decoded["message"].getStr
    report("frame " & kind & " " & what & detail)
  # EVERY MOVE IS REPORTED, with its path and whether the engine could reach
  # the source. This is the one line `ci/test/noir-replay-in-browser.sh` reads
  # to tell the two false passes apart: a session that steps but resolves
  # nothing, and a session that resolves positions that are all
  # `missingPath`. Neither is visible from "a session opened".
  if decoded.kind == JObject and decoded.hasKey("event") and
     decoded["event"].kind == JString and
     decoded["event"].getStr == "ct/complete-move" and
     decoded.hasKey("body") and decoded["body"].kind == JObject and
     decoded["body"].hasKey("location") and
     decoded["body"]["location"].kind == JObject:
    let location = decoded["body"]["location"]
    let path =
      if location.hasKey("path") and location["path"].kind == JString:
        location["path"].getStr
      else: ""
    let line =
      if location.hasKey("line") and location["line"].kind == JInt:
        location["line"].getInt
      else: 0
    let missing =
      location.hasKey("missingPath") and
      location["missingPath"].kind == JBool and
      location["missingPath"].getBool
    report("move " & path & ":" & $line & " missingPath=" & $missing)
  # ROUTED FROM THE DECODED FRAME, not from a property read off the raw
  # JsObject. The engine posts frames as TEXT, so `raw.type` is `undefined`
  # and every response would have been delivered as an event — which settles
  # no `asyncSendCtRequest` continuation, so every ViewModel future would sit
  # unresolved until its timeout while the legacy panels updated. That is the
  # precise asymmetry `dap.nim`'s M49 comment records having cost a campaign.
  let isResponse =
    decoded.kind == JObject and decoded.hasKey("type") and
    decoded["type"].kind == JString and decoded["type"].getStr == "response"
  if isResponse:
    discard data.ipc.deliver(cstring"CODETRACER::dap-receive-response", outbound)
  else:
    discard data.ipc.deliver(cstring"CODETRACER::dap-receive-event", outbound)

proc openSession(request: ReplaySessionRequest) =
  ## Turn a `MemoryTrace` into a live session, or say why not.
  ##
  ## THE FIRST LINE IS THE ARRIVAL, and it is reported before anything can
  ## fail. A browser gate found a Run that traced 36 events and then nothing:
  ## no session, and neither of the two rows the producer writes for the
  ## outcome. That leaves two candidates — the producer never asks, or the
  ## host never hears — and a headless case in `test_noir_build_producer`
  ## has since removed the first. This line removes the second from guesswork:
  ## it is the one fact that separates "the ask did not arrive" from "the ask
  ## arrived and the session failed", and every later report is downstream of
  ## it.
  report("asked for a session over " & $request.rawMemoryTrace.len &
         " bytes, package=" & request.packageDir &
         " root=" & request.projectRoot)
  let payload = replayVfsPayload(request.rawMemoryTrace)
  if payload.defects.len > 0:
    lastReplayFailure = payload.defects[0]
    report("refused: " & lastReplayFailure)
    return
  report("trace accepted: " & $payload.steps & " steps, " & $payload.calls &
         " calls, " & $payload.sourceViews & " source view(s)")

  if not activeReplayTerminate.isNil:
    # A second Run replaces the first. Two engines answering one store would
    # interleave two recordings into one timeline.
    activeReplayTerminate()
    activeReplayTerminate = nil

  let requested = request
  # THE WORKER'S URL COMES FROM THE DEPLOYMENT, not from a constant. It was
  # `"/" & replayWorkerScriptPath` until the assembly step began renaming every
  # `/assets/` file to carry its content digest — which is what makes the
  # year-long `immutable` on those URLs a true promise, and which a compiled-in
  # path cannot follow.
  #
  # An undeclared worker is REFUSED BY NAME rather than requested anyway.
  # Cloudflare Pages answers an unknown path with the SPA entry document at 200
  # `text/html`, so `new Worker("/assets/replay-worker.js")` on a deployment
  # that published no such file would load the application shell into a worker
  # and fail inside it — the manifest's own sentence for this absence says the
  # session reports that this deployment ships no engine, which is both true and
  # findable.
  let descriptor = deploymentDescriptor()
  let replayWorkerUrl = assetUrl(descriptor, replayWorkerModuleId)
  if replayWorkerUrl.len == 0:
    lastReplayFailure =
      "this deployment declares no `" & replayWorkerModuleId &
      "`, so there is no worker to instantiate the replay engine in"
    report("refused: " & lastReplayFailure)
    return
  newBrowserReplaySession(
    scriptUrl = replayWorkerUrl,
    moduleUrls = declaredModuleUrls(descriptor),
    payload = payload,
    onFrame = proc(frame: JsObject) =
      deliverFrame(requested, frame),
    onSettled = proc(outcome: ReplaySessionOutcome) =
      if not outcome.ready:
        lastReplayFailure = outcome.failure
        report("engine did not start: " & outcome.failure)
        return
      activeReplayTerminate = outcome.terminate
      # THE RESPONDER GOES IN BEFORE THE HANDSHAKE. `data.ipc.send` warns and
      # drops when there is no responder, so an `initialize` issued first
      # would be lost and the session would wait on a reply nobody was asked
      # for.
      data.ipc.respond(cstring"CODETRACER::dap-raw-message",
        proc(sender: js, packet: JsObject) =
          # REPORTED ON THE WAY OUT TOO. A silent engine and a host whose
          # requests never left look identical from the inbound side, and
          # forty minutes went into telling them apart once already.
          replayFramesOut += 1
          report("send " & $frameJsonText(packet))
          outcome.send(packet))
      report("engine ready; opening the trace")
      # `initialize` was already sent once, from `configureMiddleware`, into a
      # channel with no peer — it timed out and resolved `{}`. Re-sending is
      # what gives the engine the handshake it expects; the DapApi's `seq`
      # counter makes the second one a distinct request.
      data.dapApi.sendCtRequest(DapInitialize, js{clientName: cstring"codetracer"})
      data.dapApi.sendCtRequest(DapLaunch, js{traceFolder: cstring"trace"})
      data.dapApi.sendCtRequest(DapConfigurationDone, js{}))

proc installReplayHost*() =
  ## Make this tab able to answer a request for a replay session.
  ##
  ## Called from `enterTemplateEditMode`, beside `installTemplateHost`, and for
  ## the same reason its own comment gives: registered BEFORE the `no-trace`
  ## delivery, so the responder exists before anything can ask.
  installReplaySessionService(ReplaySessionService(startProc: openSession))
  report("host installed")
