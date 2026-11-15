## desktop_window_routing_test.nim
##
## A DESKTOP WINDOW HEARS WHAT IS ITS OWN: the answers to its requests, the
## events of the replays its tabs show, and — when it opens after startup —
## the session it was opened for.
##
## ## The defect this pins
##
## codetracer-pm issue `2026-11-15-a-second-desktop-window-opens-blank.md`.
## The main process sent the renderer's startup and every answer and event to
## the first window (`mainWindow.webContents.send`). A window opened by a
## session tab's "Open in New Window" or a pane tab's "Send to New Window" was
## sent nothing — no startup handshake, no trace, no answer to its requests —
## and stayed an empty dark surface. And because tab ids are per window (the
## first tab of every window is 0), a message for "tab 0" could not say
## WHICH window's tab 0 it was for.
##
## ## What is asserted
##
## * An answer goes to the window that asked, outside it to no other window,
##   and is dropped when that window has closed; what no window asked for
##   goes to every window, except a message naming a tab, which is the
##   primary window's — the first one still open, so the second window when
##   the first has closed.
## * Two windows showing one replay under different tab ids: a request of the
##   second window is answered to it under its own tab; an event of the
##   replay reaches both windows, each under its own tab, and the first
##   window's other tabs not at all.
## * A window opened for a tab is sent `init`, that tab's session messages
##   re-addressed to its first tab, `init-session` and the replay's latest
##   stop — and from then on the replay's events.
## * Closing a tab (or Stop) in one window does not stop a replay another
##   window shows; closing the last window showing a replay names it to be
##   stopped.
## * An IPC request runs as the window whose `webContents` sent it, and the
##   desktop's `mainWindow` (`windowRouter`) acts on that window.
##
## ## What is real, and the stand-ins
##
## Real: `window_routing` (its window, tab and replay tables, `routeSend`,
## `bootstrapWindow`, `runForSender`, `windowRouter`), the DAP router
## (`index/ipc_subsystems/dap`: `onDapRawMessage`, `setupProxyForDap` and the
## frame handling) and `served_client`'s `AsyncLocalStorage` contexts, which
## carry the asking window across the awaits below.
##
## The stand-ins, and why neither is a mock:
##
##   1. Each window's send (`registerAppWindow`'s `rawSend`) records what the
##      window would be told — in the application it is the window's own
##      `webContents.send`; nothing in the routing is replaced by it.
##   2. The Backend Manager socket records the frames written to it and hands
##      the test the router's stream handler, through which the test plays
##      the backend's answers and events, as `dap_session_routing_test.nim`
##      does.
##
## The `BrowserWindow`s are plain objects carrying the `id`, `webContents.id`
## and `getTitle` the routing reads: this lane runs under node, without
## Electron.
##
## Lane: `main-process` (`nim js -d:nodejs -d:ctIndex -d:server`, run under
## node).

import std/[unittest, jsffi, strutils, asyncjs, tables]

import ../index/ipc_subsystems/dap
import ../index/window_routing

var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

proc jsonParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc jsonStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc nextTick(): Future[void] {.importjs:
  "(new Promise(function (r) { setTimeout(r, 0); }))".}
proc setExitCode(code: int) {.importjs: "process.exitCode = #".}

# ---------------------------------------------------------------------------
# Windows (stand-in 1)
# ---------------------------------------------------------------------------

type Told = ref object
  messages: seq[(cstring, JsObject)]

proc fakeBrowserWindow(id, contentsId: int; title: string): JsObject =
  result = js{"id": id, "webContents": js{"id": contentsId}}
  let t = cstring(title)
  result["getTitle"] = proc(): cstring = t

proc openWindow(id: int; title: string): (AppWindow, Told) =
  let told = Told()
  let w = registerAppWindow(id, id + 100, fakeBrowserWindow(id, id + 100, title),
    proc(channel: cstring; payload: JsObject) =
      told.messages.add((channel, payload)))
  (w, told)

proc said(t: Told; channel: string): seq[JsObject] =
  for (c, p) in t.messages:
    if c == cstring(channel):
      result.add p

proc channels(t: Told): seq[string] =
  for (c, _) in t.messages:
    result.add $c

# ---------------------------------------------------------------------------
# The Backend Manager (stand-in 2)
# ---------------------------------------------------------------------------

var written: seq[JsObject] = @[]
var streamHandler: proc(data: cstring)

let socket = newJsObject()
socket["write"] = proc(frame: cstring) =
  let text = $frame
  let hdrEnd = text.find("\r\n\r\n")
  written.add jsonParse(cstring(text[hdrEnd + 4 .. ^1]))
socket["on"] = proc(event: cstring; handler: proc(data: cstring)) =
  streamHandler = handler
backendManagerSocket = socket
setupProxyForDap(socket)

proc backendSays(frame: JsObject) =
  let body = $jsonStringify(frame)
  streamHandler(cstring("Content-Length: " & $body.len & "\r\n\r\n" & body))

proc lastRequest(): JsObject =
  for i in countdown(written.high, 0):
    if written[i]["command"].to(cstring) != cstring"ct/select-replay":
      return written[i]

proc tabRequest(tab, replay, seq: int): JsObject =
  js{"seq": seq, "type": cstring"request", "command": cstring"ct/load-locals",
     "arguments": newJsObject(), "sessionId": tab, "replayId": replay}

proc answer(request: JsObject; replay, marker: int): JsObject =
  js{"type": cstring"response", "request_seq": request["seq"],
     "success": true, "command": cstring"ct/load-locals",
     "body": js{"marker": marker}, "ctReplayId": replay}

proc moveEvent(replay, marker: int): JsObject =
  js{"type": cstring"event", "event": cstring"ct/complete-move",
     "body": js{"marker": marker}, "ctReplayId": replay}

proc ipcEventFrom(contentsId: int): JsObject =
  ## What Electron hands an `ipcMain` handler: `sender` is the sending
  ## window's `webContents`.
  js{"sender": js{"id": contentsId}}

proc resetWindows() =
  for w in windows:
    w.closed = true
  windows.setLen(0)

# ---------------------------------------------------------------------------

suite "the desktop routes what the main process says per window":

  test "a message no window asked for: every window, or the primary when it names a tab":
    resetWindows()
    let (first, firstTold) = openWindow(1, "first")
    let (second, secondTold) = openWindow(2, "second")
    routeSend(cstring"CODETRACER::keybindings", js{"text": cstring""})
    ck firstTold.said("CODETRACER::keybindings").len == 1
    ck secondTold.said("CODETRACER::keybindings").len == 1
    routeSend(cstring"CODETRACER::trace-loaded", js{"tab": 0})
    ck firstTold.said("CODETRACER::trace-loaded").len == 1
    ck secondTold.said("CODETRACER::trace-loaded").len == 0
    # The first window closes: the second is the primary one now.
    discard closeAppWindow(first)
    routeSend(cstring"CODETRACER::failed-record", js{"tab": 0})
    ck secondTold.said("CODETRACER::failed-record").len == 1
    ck firstTold.said("CODETRACER::failed-record").len == 0

  test "an answer for a window that has closed reaches no other window":
    resetWindows()
    let (first, firstTold) = openWindow(1, "first")
    let (second, secondTold) = openWindow(2, "second")
    discard closeAppWindow(second)
    runAsWindow(second, proc() =
      routeSend(cstring"CODETRACER::tab-load-response", js{"tab": 0}))
    ck firstTold.said("CODETRACER::tab-load-response").len == 0
    ck secondTold.messages.len == 0

  test "mainWindow acts on the window being served":
    resetWindows()
    let (first, firstTold) = openWindow(1, "first")
    let (second, secondTold) = openWindow(2, "second")
    let router = windowRouter()
    var title = cstring""
    runAsWindow(second, proc() =
      title = router.getTitle().to(cstring)
      router.webContents.send(cstring"CODETRACER::reset-layout-done", js{}))
    ck title == cstring"second"
    ck secondTold.said("CODETRACER::reset-layout-done").len == 1
    ck firstTold.said("CODETRACER::reset-layout-done").len == 0
    ck router.getTitle().to(cstring) == cstring"first"

suite "two windows showing one replay":

  test "a window opened for a tab is sent that tab's session, re-addressed to its first tab":
    resetWindows()
    let (first, firstTold) = openWindow(1, "main.py — CodeTracer")
    # The first window's tab 2 loaded a trace on replay 5 and stopped once.
    for (channel, payload) in [
        (cstring"CODETRACER::dap-replay-selected", js{"tab": 2, "replayId": 5}),
        (cstring"CODETRACER::filenames-loaded", js{"tab": 2, "names": 3}),
        (cstring"CODETRACER::trace-loaded", js{"tab": 2, "trace": js{"program": cstring"basics.py"}}),
        (cstring"CODETRACER::trace-loaded", js{"tab": 0, "trace": js{"program": cstring"main.py"}})]:
      first.sendTo(channel, payload)
    backendSays(moveEvent(5, 41))
    ck firstTold.said("CODETRACER::dap-receive-event").len == 1
    ck firstTold.said("CODETRACER::dap-receive-event")[0]["sessionId"].to(int) == 2

    let (second, secondTold) = openWindow(2, "")
    bootstrapWindow(second, first, 2, js{"layout": js{"root": cstring"all"}})
    ck secondTold.channels == @["CODETRACER::init",
      "CODETRACER::dap-replay-selected", "CODETRACER::filenames-loaded",
      "CODETRACER::trace-loaded", "CODETRACER::init-session",
      "CODETRACER::dap-receive-event"]
    ck secondTold.said("CODETRACER::init")[0]["tab"].to(int) == 0
    let trace = secondTold.said("CODETRACER::trace-loaded")[0]
    ck trace["tab"].to(int) == 0
    ck trace["trace"]["program"].to(cstring) == cstring"basics.py"
    # The first window's own record of its tab is left as it was.
    ck firstTold.said("CODETRACER::trace-loaded")[0]["tab"].to(int) == 2
    ck secondTold.said("CODETRACER::init-session")[0]["replayId"].to(int) == 5
    let stop = secondTold.said("CODETRACER::dap-receive-event")[0]
    ck stop["sessionId"].to(int) == 0
    ck stop["body"]["marker"].to(int) == 41
    ck second.tabReplays.getOrDefault(0, -1) == 5

    # A request of the second window's tab 0 is answered to it, under tab 0.
    secondTold.messages.setLen(0)
    firstTold.messages.setLen(0)
    runForSender(ipcEventFrom(second.contentsId), proc() =
      discard onDapRawMessage(nil, tabRequest(0, 5, 7)))
    let request = lastRequest()
    ck request["sessionId"].to(int) == 0
    backendSays(answer(request, 5, 42))
    ck secondTold.said("CODETRACER::dap-receive-response").len == 1
    let reply = secondTold.said("CODETRACER::dap-receive-response")[0]
    ck reply["sessionId"].to(int) == 0
    ck reply["request_seq"].to(int) == 7
    ck firstTold.said("CODETRACER::dap-receive-response").len == 0

    # The step it caused stops the replay: both windows move, each under its
    # own tab, and the first window's tab 0 (another trace) is told nothing.
    backendSays(moveEvent(5, 43))
    let firstEvents = firstTold.said("CODETRACER::dap-receive-event")
    let secondEvents = secondTold.said("CODETRACER::dap-receive-event")
    ck firstEvents.len == 1
    ck secondEvents.len == 1
    ck firstEvents[0]["sessionId"].to(int) == 2
    ck secondEvents[0]["sessionId"].to(int) == 0
    ck secondEvents[0]["body"]["marker"].to(int) == 43

  test "a pane window's edit session carries the pane's layout":
    resetWindows()
    let (first, _) = openWindow(1, "first")
    first.sendTo(cstring"CODETRACER::no-trace",
                 js{"tab": 0, "layout": cstring"edit-layout"})
    let (second, secondTold) = openWindow(2, "")
    bootstrapWindow(second, first, 0, js{"layout": cstring"pane"}, cstring"pane".toJs)
    ck secondTold.said("CODETRACER::init").len == 0
    let noTrace = secondTold.said("CODETRACER::no-trace")
    ck noTrace.len == 1
    ck noTrace[0]["layout"].to(cstring) == cstring"pane"

  test "a replay another window shows is not stopped with one window's tab":
    resetWindows()
    let (first, _) = openWindow(1, "first")
    let (second, _) = openWindow(2, "second")
    first.noteTabReplay(3, 9)
    second.noteTabReplay(0, 9)
    first.noteTabReplay(0, 4)
    ck not releaseReplay(first, 9)
    ck first.tabReplays.getOrDefault(3, -1) == -1
    ck viewersOf(9).len == 1
    # The second window closes: replay 9 is shown by no window and is named
    # to be stopped; replay 4 is still the first window's.
    let orphans = closeAppWindow(second)
    ck orphans == @[9]
    ck releaseReplay(first, 4)

  test "the list of windows a pane can go to is per window":
    resetWindows()
    let (first, _) = openWindow(1, "first")
    let (second, _) = openWindow(2, "second")
    ck windowWithContentsId(102) == second
    ck primaryWindow() == first
    ck openWindowCount() == 2
    discard closeAppWindow(first)
    ck primaryWindow() == second
    ck openWindowCount() == 1

  test "every check ran":
    ck checks > 30
    ck failedChecks == 0

# ---------------------------------------------------------------------------
# Across awaits: run after the suites, on the event loop; a failure sets the
# exit code.
# ---------------------------------------------------------------------------

proc answerAcrossAwaits() {.async.} =
  ## A handler that answers after an await (a timer, here; I/O in the
  ## application) still answers the window that asked: the context goes with
  ## the work the handler started.
  resetWindows()
  let (_, firstTold) = openWindow(1, "first")
  let (second, secondTold) = openWindow(2, "second")
  var done = false
  proc handler() {.async.} =
    await nextTick()
    await nextTick()
    routeSend(cstring"CODETRACER::tab-load-response", js{"tab": 0, "n": 1})
    done = true
  runForSender(ipcEventFrom(second.contentsId), proc() =
    discard handler())
  while not done:
    await nextTick()
  if secondTold.said("CODETRACER::tab-load-response").len == 1 and
      firstTold.said("CODETRACER::tab-load-response").len == 0:
    echo "[OK] an answer made after awaits goes to the window that asked"
  else:
    echo "[FAILED] an answer made after awaits goes to the window that asked: second ",
      secondTold.channels, " first ", firstTold.channels
    setExitCode(1)

discard answerAcrossAwaits()
