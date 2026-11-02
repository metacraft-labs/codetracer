## dap_replay_selection_test.nim
##
## THE MAIN PROCESS RUNS A TAB'S REQUEST ON THAT TAB'S REPLAY — the replay the
## Backend Manager answered `ct/start-replay` with for it — and never on a
## replay chosen by the tab's own id.
##
## ## The defect this pins
##
## codetracer-pm issue
## `2026-10-23-a-tab-opened-after-closing-a-middle-tab-reuses-a-live-tabs-session-id.md`.
## The router (`index/ipc_subsystems/dap.nim`) selected a request's replay with
## `ct/select-replay` whose argument was the request's `sessionId` — the
## renderer TAB's id (`ReplaySession.id`, `DapApi.sessionId`). The replay a tab
## talks to is a different number: the Backend Manager allocates replay ids in
## the order it starts replays, never reusing one (`backend_manager.rs`
## `start_replay_raw`: `children.push(None)`, id = `children.len() - 1`;
## `stop_replay` leaves the slot empty and `check_id` refuses it), and a refused
## start consumes one too. The renderer learns its tab's replay from
## `dap-replay-selected` / `dap-live-session-selected`
## (`ReplaySession.replayId`). The two numbers agree only while every tab has
## started exactly one replay, in tab order, and none failed. They part after
## Stop and a new run in one tab (`ui/stop_command.nim` keeps the tab; the next
## replay gets a new id), after a failed start, or when a "+" tab stays on the
## welcome screen while a later tab loads — and then a tab's requests ran on
## another tab's replay, or on a stopped one's slot (which the Backend Manager
## refuses to select, leaving whichever replay it served before).
##
## Two more consequences of keying on the tab id, pinned here too:
##
## * The desktop router did not record the `ct/select-replay` the trace loader
##   writes itself (`traces.startReplayForTrace` -> `noteReplaySelected`), nor
##   that `ct/stop-replay` leaves the Backend Manager serving nothing
##   (`noteReplayStopped`). So after another tab's replay was started, a
##   request of the tab it believed selected skipped its switch and ran on the
##   new replay.
## * An event was attributed to "the session the Backend Manager is serving"
##   — whichever tab sent the last request — although the Backend Manager
##   names the replay of every message it relays (`ctReplayId`,
##   `REPLAY_ID_TAG`).
##
## ## What is asserted
##
## * A request carries its tab's replay (`replayId`, stamped by the renderer's
##   `DapApi`) and the router selects THAT replay, for tabs whose id differs
##   from their replay's, crossed ids included; the answer still reaches the
##   tab that asked.
## * The router knows what the Backend Manager serves after a selection or a
##   stop it did not write itself.
## * An event reaches the tab that owns the replay that sent it.
## * A request that names no replay is dropped — never run on the replay
##   served, another tab's or none's; the window's first tab, told its
##   startup replay (`startup.init`), runs on it from its first request.
##
## ## What is real, and the stand-ins
##
## As in `dap_session_routing_test.nim`: the router — `onDapRawMessage`,
## `setupProxyForDap`, `handleFrame` / `resolveSessionId`,
## `noteReplaySelected` / `noteReplayStopped` (what `index/traces.nim` calls)
## — and `electron_vars.broadcastToSession` are real. The Backend Manager
## socket records the frames written to it and hands the test the router's
## stream handler; each window's `webContents.send` records what the window
## would be told. Request frames are shaped as `dap.dispatchCtRequest` builds
## them.
##
## Lane: `main-process` (`nim js -d:nodejs -d:ctIndex -d:server`, run under
## node). No `installServerSessionRouting`: this is the desktop's routing.

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

# ---------------------------------------------------------------------------
# The Backend Manager socket
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

proc backendSends(frames: varargs[JsObject]) =
  var chunk = ""
  for f in frames:
    let body = $jsonStringify(f)
    chunk.add "Content-Length: " & $body.len & "\r\n\r\n" & body
  streamHandler(cstring(chunk))

proc answer(wireSeq: int; replay: int; marker: int): JsObject =
  ## The Backend Manager's relay of a replay's answer: tagged with the replay
  ## (`ctReplayId`), as its single-client forwarder tags every message.
  result = newJsObject()
  result["type"] = cstring"response"
  result["request_seq"] = wireSeq
  result["success"] = true
  result["command"] = cstring"ct/load-locals"
  result["body"] = js{"marker": marker}
  result["ctReplayId"] = replay

proc event(replay: int; marker: int): JsObject =
  result = newJsObject()
  result["type"] = cstring"event"
  result["event"] = cstring"ct/complete-move"
  result["body"] = js{"marker": marker}
  result["ctReplayId"] = replay

# ---------------------------------------------------------------------------
# One window per tab, so what each tab is told can be read apart
# ---------------------------------------------------------------------------

const Tabs = 3
var received: array[Tabs, seq[(cstring, JsObject)]]

proc windowFor(tab: int): JsObject =
  let contents = newJsObject()
  contents["send"] = proc(channel: cstring; payload: JsObject) =
    received[tab].add((channel, payload))
  result = newJsObject()
  result["webContents"] = contents

for tab in 0 ..< Tabs:
  windowTable[20 + tab] = windowFor(tab)
  sessionWindows[tab] = @[20 + tab]

proc told(tab: int; channel: string): seq[JsObject] =
  for (c, payload) in received[tab]:
    if c == cstring(channel):
      result.add payload

proc markers(payloads: seq[JsObject]): seq[int] =
  for p in payloads:
    result.add p["body"]["marker"].to(int)

# ---------------------------------------------------------------------------
# The renderer's request, as `dap.dispatchCtRequest` builds it
# ---------------------------------------------------------------------------

proc tabSends(tab: int; replay: int; seq: int) =
  ## Tab `tab` sends a request; `replay` is the replay the Backend Manager
  ## answered for it, `-1` for a tab that has none (no `replayId` field).
  let packet = newJsObject()
  packet["seq"] = seq
  packet["type"] = cstring"request"
  packet["command"] = cstring"ct/load-locals"
  packet["arguments"] = newJsObject()
  packet["sessionId"] = tab
  if replay >= 0:
    packet["replayId"] = replay
  discard onDapRawMessage(nil, packet)

proc selections(): seq[int] =
  ## The `ct/select-replay` arguments the router wrote, in order.
  for f in written:
    if f["command"].to(cstring) == cstring"ct/select-replay":
      result.add f["arguments"].to(int)

proc forwarded(): seq[JsObject] =
  for f in written:
    if f["command"].to(cstring) != cstring"ct/select-replay":
      result.add f

proc servedBefore(request: JsObject): int =
  ## The replay the Backend Manager serves when `request` reaches it: the
  ## argument of the last `ct/select-replay` written before it, or `-2` when
  ## the router wrote none (the Backend Manager serves whatever was selected
  ## before this test looked).
  result = -2
  for f in written:
    if f == request:
      return
    if f["command"].to(cstring) == cstring"ct/select-replay":
      result = f["arguments"].to(int)

proc reset() =
  written = @[]
  received = default(array[Tabs, seq[(cstring, JsObject)]])

suite "the main process selects a tab's request onto that tab's replay":

  test "the window's first tab runs on the replay started for it":
    # Startup: the trace loader started replay 0 and selected it
    # (`startReplayForTrace`), and announced it to the first tab once the
    # renderer listened (`startup.init`), so the tab names it from its first
    # request on. No switch is needed: replay 0 is the one served.
    reset()
    noteReplaySelected(0)
    tabSends(0, 0, 1)
    ck forwarded().len == 1
    ck selections().len == 0
    let reqs = forwarded()
    if reqs.len == 1:
      backendSends(answer(reqs[0]["seq"].to(int), 0, 1))
    ck told(0, "CODETRACER::dap-receive-response").markers == @[1]

  test "a request naming no replay is dropped, whatever replay is served":
    # Even when the replay served is no tab's — the router does not guess
    # that a tab which names no replay meant that one.
    reset()
    noteReplaySelected(1)
    tabSends(1, -1, 2)
    ck forwarded().len == 0
    ck selections().len == 0
    ck told(1, "CODETRACER::dap-receive-response").len == 0

  test "a tab whose replay id is not its tab id":
    # Tab 1's first replay (1) was refused or stopped; its replay is 2, the
    # one the trace loader just started and selected.
    reset()
    noteReplaySelected(2)
    tabSends(0, 0, 10)
    tabSends(1, 2, 10)
    let reqs = forwarded()
    ck reqs.len == 2
    if reqs.len == 2:
      ck reqs[0].servedBefore == 0
      ck reqs[1].servedBefore == 2
      backendSends(answer(reqs[1]["seq"].to(int), 2, 21),
                   answer(reqs[0]["seq"].to(int), 0, 20))
    ck 1 notin selections()
    ck told(0, "CODETRACER::dap-receive-response").markers == @[20]
    ck told(1, "CODETRACER::dap-receive-response").markers == @[21]
    let to1 = told(1, "CODETRACER::dap-receive-response")
    if to1.len == 1:
      ck to1[0]["sessionId"].to(int) == 1
      ck to1[0]["request_seq"].to(int) == 10

  test "crossed ids: tab 2 holds replay 1, tab 1 holds replay 2":
    reset()
    tabSends(2, 1, 30)
    tabSends(1, 2, 30)
    tabSends(2, 1, 31)
    let reqs = forwarded()
    ck reqs.len == 3
    if reqs.len == 3:
      ck reqs[0].servedBefore == 1
      ck reqs[1].servedBefore == 2
      ck reqs[2].servedBefore == 1
      backendSends(answer(reqs[0]["seq"].to(int), 1, 230),
                   answer(reqs[1]["seq"].to(int), 2, 130),
                   answer(reqs[2]["seq"].to(int), 1, 231))
    ck told(2, "CODETRACER::dap-receive-response").markers == @[230, 231]
    ck told(1, "CODETRACER::dap-receive-response").markers == @[130]

  test "an event reaches the tab that owns the replay that sent it":
    reset()
    # The last request was tab 0's, so the Backend Manager serves replay 0;
    # replay 2 (tab 1's) and replay 1 (tab 2's) still send events.
    tabSends(0, 0, 40)
    backendSends(event(2, 41), event(0, 40), event(1, 42))
    ck told(0, "CODETRACER::dap-receive-event").markers == @[40]
    ck told(1, "CODETRACER::dap-receive-event").markers == @[41]
    ck told(2, "CODETRACER::dap-receive-event").markers == @[42]

  test "Stop and a new run in one tab: the new replay, and a fresh selection":
    reset()
    # Tab 1 stops replay 2 (`ct/stop-replay`: the Backend Manager then serves
    # nothing) and runs again: the trace loader starts replay 3 and selects
    # it. Then tab 0, then tab 1 again.
    noteReplayStopped(2)
    noteReplaySelected(3)
    tabSends(1, 3, 50)
    tabSends(0, 0, 51)
    tabSends(1, 3, 52)
    let reqs = forwarded()
    ck reqs.len == 3
    if reqs.len == 3:
      ck reqs[0].servedBefore == -2   # replay 3 is already the one served
      ck reqs[1].servedBefore == 0
      ck reqs[2].servedBefore == 3
    ck 2 notin selections()
    # After a stop the Backend Manager serves nothing, whichever replay was
    # stopped: the next request selects its replay again even when the router
    # had last selected that very replay.
    reset()
    tabSends(0, 0, 53)
    noteReplayStopped(3)
    tabSends(0, 0, 54)
    ck selections() == @[0, 0]
    ck written.len == 4
    if written.len == 4:
      ck written[2]["command"].to(cstring) == cstring"ct/select-replay"

  test "a tab with no replay is not run on another tab's replay":
    reset()
    # Tab 2 is Stopped (its replay, 1, is stopped: `close-replay-session`)
    # and has no replay; replay 0, which the Backend Manager serves, is tab
    # 0's, and replay 2 — tab 2's id — once was tab 1's.
    noteReplayStopped(1)
    tabSends(0, 0, 60)
    reset()
    tabSends(2, -1, 61)
    ck forwarded().len == 0
    ck 2 notin selections()
    ck told(2, "CODETRACER::dap-receive-response").len == 0

  echo "CHECKS: ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}
