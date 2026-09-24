## dap_session_routing_test.nim
##
## A DAP ANSWER REACHES THE SESSION THAT ASKED — in the Electron main
## process's real router, when two sessions have a request with the SAME
## `seq` in flight.
##
## ## The defect this pins
##
## Every session's renderer-side `DapApi` numbers its requests from zero, and
## the main process forwards all of them to ONE Backend Manager socket. The
## backend's answer names its request only by `request_seq` — the number it
## was sent with. The router (`index/ipc_subsystems/dap.nim`) used to record
## "which session sent `seq` N" in a table keyed by `seq` ALONE, so with two
## sessions' request N in flight the second overwrote the first: one answer
## was tagged with the wrong session and the other fell through to whichever
## session the Backend Manager happened to be serving. For `ct/load-locals`
## that means one session's values judged against — and possibly drawn in —
## the other session's pane.
##
## The router now forwards every request under a wire `seq` unique across
## sessions, records the `(sessionId, seq)` pair it stands for, and on the
## answer restores the session's own `seq` into `request_seq` and tags the
## session. This suite asserts exactly that, end to end through the router.
##
## ## What is real, and the stand-ins
##
## REAL: the main process's router — `onDapRawMessage` (the
## `CODETRACER::dap-raw-message` IPC handler), `sendDapForSession` (the
## `ct/select-replay` switch and the request bookkeeping),
## `setupProxyForDap` (the `Content-Length` framing of the Backend Manager's
## stream) and the private `handleFrame` / `resolveSessionId` it drives, and
## `electron_vars.broadcastToSession` (the session -> window fan-out). The
## request frames are shaped as `dap.dispatchCtRequest` builds them (`seq`,
## `type`, `command`, `arguments`, `sessionId`); the answer bodies are the
## real backend's `ct/load-locals` answer
## (`ci/test/watch-expressions-probe/backend-response.json`).
##
## THE TWO STAND-INS, and why neither is a mock:
##
##   1. The Backend Manager SOCKET: an object whose `write` records each frame
##      the router writes and whose `on("data", …)` hands the test the
##      router's own stream handler. The test plays the backend by echoing
##      each request's wire `seq` as `request_seq` — which is what the real
##      backend does (`dap_handler.respond_dap` copies `request.base.seq`) —
##      and writes the answers back in the framing the router parses. It is
##      the only way to control the ORDER answers arrive in relative to the
##      requests, which is the whole property; nothing in the router is
##      replaced or observed through it.
##   2. Each window's `webContents.send`: records what the window would be
##      told. `broadcastToSession` itself runs, over the real
##      `sessionWindows` / `windowTable` maps.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, the
## defines `server_index.js` is built with (`src/Tupfile`), run under node.
## `-d:server` is what lets `electron_vars` load without Electron; the router
## has no `when defined(server)` arm, so the code under test is the code
## `index.js` ships.

import std/[unittest, jsffi, strutils]

import ../index/ipc_subsystems/dap
import ../index/electron_vars

var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

proc jsonParse(text: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc readFixture(): cstring {.importjs:
  "require('fs').readFileSync(require('path').join(process.cwd(), 'ci/test/watch-expressions-probe/backend-response.json'), 'utf8')".}

# ---------------------------------------------------------------------------
# The Backend Manager socket (stand-in 1)
# ---------------------------------------------------------------------------

var written: seq[JsObject] = @[]
var streamHandler: proc(data: cstring)

proc frameBody(frame: cstring): JsObject =
  let text = $frame
  let hdrEnd = text.find("\r\n\r\n")
  doAssert hdrEnd > 0, "a frame without a Content-Length header: " & text
  jsonParse(cstring(text[hdrEnd + 4 .. ^1]))

let socket = newJsObject()
socket["write"] = proc(frame: cstring) =
  written.add frameBody(frame)
socket["on"] = proc(event: cstring; handler: proc(data: cstring)) =
  doAssert event == cstring"data"
  streamHandler = handler
backendManagerSocket = socket
setupProxyForDap(socket)

proc backendAnswers(frames: varargs[JsObject]) =
  ## Write answer frames onto the router's stream in ONE chunk, framed as
  ## the Backend Manager frames them.
  var chunk = ""
  for f in frames:
    let body = $jsonStringify(f)
    chunk.add "Content-Length: " & $body.len & "\r\n\r\n" & body
  streamHandler(cstring(chunk))

proc localsAnswer(wireSeq: int; marker: int): JsObject =
  ## The backend's `ct/load-locals` answer to the request written under
  ## `wireSeq`, around the real backend's body with its one primitive local's
  ## value replaced by `marker` — the only thing telling one answer from
  ## another.
  let fixture = jsonParse(readFixture())
  let shield = fixture["locals"][1]
  doAssert shield["expression"].to(cstring) == cstring"initial_shield"
  shield["value"]["i"] = cstring($marker)
  let body = newJsObject()
  body[cstring"locals"] = [shield].toJs
  result = newJsObject()
  result["type"] = cstring"response"
  result["request_seq"] = wireSeq
  result["success"] = true
  result["command"] = cstring"ct/load-locals"
  result["body"] = body

proc markerOf(response: JsObject): int =
  parseInt($response["body"]["locals"][0]["value"]["i"].to(cstring))

# ---------------------------------------------------------------------------
# Two windows, one per session (stand-in 2)
# ---------------------------------------------------------------------------

var received: array[2, seq[(cstring, JsObject)]]

proc windowFor(session: int): JsObject =
  let contents = newJsObject()
  contents["send"] = proc(channel: cstring; payload: JsObject) =
    received[session].add((channel, payload))
  result = newJsObject()
  result["webContents"] = contents

windowTable[10] = windowFor(0)
windowTable[11] = windowFor(1)
sessionWindows[0] = @[10]
sessionWindows[1] = @[11]

proc responsesTo(session: int): seq[JsObject] =
  for (channel, payload) in received[session]:
    if channel == cstring"CODETRACER::dap-receive-response":
      result.add payload

proc eventsTo(session: int): seq[JsObject] =
  for (channel, payload) in received[session]:
    if channel == cstring"CODETRACER::dap-receive-event":
      result.add payload

# ---------------------------------------------------------------------------
# The renderer's request, as `dap.dispatchCtRequest` builds it
# ---------------------------------------------------------------------------

proc rendererSends(session: int; seq: int; command = "ct/load-locals") =
  let packet = newJsObject()
  packet["seq"] = seq
  packet["type"] = cstring"request"
  packet["command"] = cstring(command)
  packet["arguments"] = newJsObject()
  packet["sessionId"] = session
  discard onDapRawMessage(nil, packet)

proc forwarded(): seq[JsObject] =
  ## The renderer's requests as the backend received them — without the
  ## router's own `ct/select-replay` switches.
  for f in written:
    if f["command"].to(cstring) != cstring"ct/select-replay":
      result.add f

proc wireSeqOf(f: JsObject): int = f["seq"].to(int)

proc resetWindows() =
  received = default(array[2, seq[(cstring, JsObject)]])

suite "the main process routes each DAP answer to the session that asked":

  test "two sessions' requests with the same seq, answered out of order":
    written = @[]
    resetWindows()
    rendererSends(0, 7)
    rendererSends(1, 7)
    let reqs = forwarded()
    ck reqs.len == 2
    # Each session's request reached the backend, under numbers that differ.
    ck reqs[0]["sessionId"].to(int) == 0
    ck reqs[1]["sessionId"].to(int) == 1
    ck wireSeqOf(reqs[0]) != wireSeqOf(reqs[1])
    # The router still switches the Backend Manager to session 1 before its
    # request (the `ct/select-replay` it writes itself).
    ck written.len == 3
    ck written[1]["command"].to(cstring) == cstring"ct/select-replay"
    ck written[1]["arguments"].to(int) == 1

    # Session 1's answer first, then session 0's.
    backendAnswers(localsAnswer(wireSeqOf(reqs[1]), 11),
                   localsAnswer(wireSeqOf(reqs[0]), 10))
    let to0 = responsesTo(0)
    let to1 = responsesTo(1)
    ck to0.len == 1
    ck to1.len == 1
    if to0.len == 1 and to1.len == 1:
      ck markerOf(to0[0]) == 10
      ck markerOf(to1[0]) == 11
      ck to0[0]["sessionId"].to(int) == 0
      ck to1[0]["sessionId"].to(int) == 1
      # Each session is told the number IT sent, not the wire number.
      ck to0[0]["request_seq"].to(int) == 7
      ck to1[0]["request_seq"].to(int) == 7

  test "colliding and distinct seqs across sessions, answered in send order":
    written = @[]
    resetWindows()
    rendererSends(1, 3)
    rendererSends(0, 3)
    rendererSends(0, 4)
    rendererSends(1, 4)
    let reqs = forwarded()
    ck reqs.len == 4
    var wire: seq[int] = @[]
    for r in reqs:
      ck wireSeqOf(r) notin wire
      wire.add wireSeqOf(r)
    backendAnswers(localsAnswer(wire[0], 13), localsAnswer(wire[1], 3))
    backendAnswers(localsAnswer(wire[2], 4), localsAnswer(wire[3], 14))
    let to0 = responsesTo(0)
    let to1 = responsesTo(1)
    ck to0.len == 2
    ck to1.len == 2
    if to0.len == 2 and to1.len == 2:
      ck markerOf(to0[0]) == 3 and to0[0]["request_seq"].to(int) == 3
      ck markerOf(to0[1]) == 4 and to0[1]["request_seq"].to(int) == 4
      ck markerOf(to1[0]) == 13 and to1[0]["request_seq"].to(int) == 3
      ck markerOf(to1[1]) == 14 and to1[1]["request_seq"].to(int) == 4

  test "an answered request is retired; an unknown answer goes to the served session":
    written = @[]
    resetWindows()
    rendererSends(0, 20)
    let wireSeq = wireSeqOf(forwarded()[0])
    backendAnswers(localsAnswer(wireSeq, 20))
    ck responsesTo(0).len == 1
    # The same answer again: its request is no longer pending, so it is
    # attributed to the session the Backend Manager is serving (0, the last
    # one switched to) and keeps the number it came with.
    backendAnswers(localsAnswer(wireSeq, 21))
    let to0 = responsesTo(0)
    ck to0.len == 2
    ck responsesTo(1).len == 0
    if to0.len == 2:
      ck to0[1]["request_seq"].to(int) == wireSeq

  test "events go to the session the Backend Manager is serving":
    written = @[]
    resetWindows()
    rendererSends(1, 30, "ct/step")
    let event = newJsObject()
    event["type"] = cstring"event"
    event["event"] = cstring"ct/complete-move"
    event["body"] = newJsObject()
    backendAnswers(event)
    ck eventsTo(1).len == 1
    ck eventsTo(0).len == 0

  echo "CHECKS: ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}
