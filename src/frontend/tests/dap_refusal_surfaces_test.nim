## dap_refusal_surfaces_test.nim
##
## A REQUEST THE BACKEND REFUSES MUST PRODUCE TEXT THE USER CAN READ, and
## that text must not be the one a timeout produces.
##
## ## The chain, and where it died
##
##   `ct/run-tracepoints` reaches an unimplemented path
##     -> `dap_server.rs::handle_message_browser` turns the `Err` into a real
##        response: `success: false`, `message: Some("...")`, `body: {}`
##     -> `index/ipc_subsystems/dap.nim` forwards the frame untouched
##     -> `ui_js.nim::onDapReceiveResponse` -> `resolvePendingDapResponse`
##     -> `pending(raw["body"])`                                  <-- HERE
##
## The refusal's sentence was ON THE WIRE and this last step threw it away,
## handing on `body` — which for every failure is `{}`. The 30-second liveness
## timeout also released its continuation with `js{}`. So the two were
## BYTE-IDENTICAL to every caller: "the backend refused this by name" and "the
## backend has not answered at all" were the same empty object, and no caller
## could render either.
##
## And no caller was even looking. `sendCtRequest` — the send used by 66 of
## the 82 call sites in `src/frontend`, `ct/run-tracepoints`
## (`middleware.nim`) among them — was `discard dap.asyncSendCtRequest(...)`.
## A caller that cannot observe the outcome of its own request cannot render
## one, so fixing a single pane would have left the other 65 exactly as blind.
##
## ## What is asserted here
##
## The RENDERED TEXT, read back out of the real status-bar view
## (`views/isonim_status_view.renderStatusShell`) via `MockRenderer` — not a
## boolean, not "an observer was called", not a class name. `notification-message`
## is the element a user actually reads.
##
## Every case below drives the REAL `sendCtRequest` and the REAL
## `resolvePendingDapResponse` over a recording `ipc`, so the frame under test
## is the frame `handle_message_browser` builds.
##
## Lane: `frontend-js`. `types.nim`'s `Data` is `std/jsffi`-based so this is
## JS-only, and the code under test lives in dap.nim's
## `when not defined(ctInExtension)` arm — so this compiles with `-d:ctRenderer`
## and WITHOUT `-d:ctInExtension`. The extension arm correlates responses
## through VS Code's own client and has no `pendingResponses` table to test.

import std/[unittest, jsffi, strutils, tables]

import ../types
import ../dap
import ../../common/ct_event

import isonim/testing/mock_dom
import ../viewmodel/views/isonim_status_view

# ---------------------------------------------------------------------------
# Reading the painted status bar
# ---------------------------------------------------------------------------

proc findAllByClass(node: MockNode; className: string;
                    acc: var seq[MockNode]) =
  if node.kind == mnkElement and
      className in node.attributes.getOrDefault("class", ""):
    acc.add(node)
  for child in node.children:
    findAllByClass(child, className, acc)

proc allByClass(node: MockNode; className: string): seq[MockNode] =
  result = @[]
  findAllByClass(node, className, result)

proc collectText(node: MockNode; acc: var string) =
  if node.kind == mnkText:
    acc.add node.text
  for child in node.children:
    collectText(child, acc)

proc textOf(node: MockNode): string =
  ## Every character a reader would see under `node`, in document order.
  ##
  ## TEXT AND NOT A CLASS. A class tells you which branch the view took;
  ## painted text tells you what the user is looking at, and the two are only
  ## the same until someone changes one of them.
  collectText(node, result)

proc notificationText(shell: MockNode): string =
  let nodes = allByClass(shell, "notification-message")
  if nodes.len == 0: "" else: textOf(nodes[0]).strip()

# ---------------------------------------------------------------------------
# The status bar, rendered from the notifications a refusal produced
# ---------------------------------------------------------------------------

var rendered: seq[string] = @[]
  ## Every notification text the hook produced, in order. Stands in for
  ## `StatusComponent.notifications`, which `ui/status.nim` appends to on
  ## `CtNotification` and turns into `StatusShellModel.activeNotifications`
  ## verbatim (`statusNotificationRecord` sets `text: $notification.text`).

proc paintStatusBar(): MockNode =
  ## Render the REAL status shell over whatever the hook has produced.
  var records: seq[StatusNotificationRecord] = @[]
  for index, text in rendered:
    records.add(StatusNotificationRecord(
      index: index,
      kindClass: "error",
      variantClass: "primary",
      text: text,
      dismissible: true))
  let r = MockRenderer()
  renderStatusShell(r, StatusShellModel(activeNotifications: records))

# ---------------------------------------------------------------------------
# A DapApi whose transport is a recorder
# ---------------------------------------------------------------------------

var sentPackets: seq[JsObject] = @[]

proc makeRecordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) =
    sentPackets.add(packet)
  ipc

proc freshDap(): DapApi =
  sentPackets = @[]
  rendered = @[]
  DapApi(ipc: makeRecordingIpc(), seq: 0, sessionId: 0)

proc lastSeq(): int =
  ## The wire `seq` of the request just sent — the key
  ## `resolvePendingDapResponse` correlates on. Read back from the recorded
  ## packet rather than assumed to be 0, so the test still holds if the
  ## counter's starting value ever changes.
  sentPackets[^1]["seq"].to(int)

proc refusalFrame(requestSeq: int; command, message: cstring): JsObject =
  ## EXACTLY the frame `dap_server.rs::handle_message_browser` builds for a
  ## request whose handler returned `Err` — including `body: {}`, which is the
  ## whole reason the message had to be carried separately.
  JsObject{
    `type`: cstring"response",
    request_seq: requestSeq,
    success: false,
    command: command,
    message: message,
    body: JsObject{}
  }

proc successFrame(requestSeq: int; command: cstring): JsObject =
  JsObject{
    `type`: cstring"response",
    request_seq: requestSeq,
    success: true,
    command: command,
    body: JsObject{}
  }

# The sentence the backend actually sends for the refusal that started this:
# `toggle_breakpoint`'s named refusal for an id it does not know. Quoted here
# so the test fails if the pipeline ever substitutes a generic string for it.
const BackendSentence =
  cstring"no tracepoint with id 7 exists in this session"

# ---------------------------------------------------------------------------

# The observer `middleware.setupMiddlewareApis` installs in production, with
# `viewsApi.errorMessage` replaced by an append to `rendered`. Registered ONCE,
# at module scope, exactly as the real one is: `onCtRequestFailed` appends, so
# registering per-test would stack duplicate observers and inflate every count
# below.
onCtRequestFailed(proc(outcome: DapRequestOutcome) =
  let text = requestFailureText(outcome)
  if text.len > 0:
    rendered.add($text))

suite "a refused ct/ request reaches the user as readable text":

  test "the refusal's own sentence is painted into the status bar":
    let dap = freshDap()

    # BEFORE. The status bar shows no notification at all — so the assertion
    # below cannot be green over a bar that always shows one.
    check notificationText(paintStatusBar()) == ""

    dap.sendCtRequest(CtRunTracepoints, JsObject{})
    check sentPackets.len == 1

    # Still nothing: the request is in flight and nothing has failed.
    check notificationText(paintStatusBar()) == ""

    dap.resolvePendingDapResponse(
      refusalFrame(lastSeq(), cstring"ct/run-tracepoints", BackendSentence))

    let painted = notificationText(paintStatusBar())

    # AFTER — and this is the defect, as one assertion: this used to be "".
    check painted != ""
    # THE BACKEND'S OWN WORDS, verbatim. The half that would still pass if the
    # notification rendered a fixed "the request failed" string.
    check painted.contains($BackendSentence)
    # And it names the request, so a user knows WHICH thing failed.
    check painted.contains("ct/run-tracepoints")

  test "a refusal and a timeout do not say the same thing":
    ## The point of `DapRequestOutcome`. Both used to arrive as `{}`.
    let refused = DapRequestOutcome(
      succeeded: false, timedOut: false,
      command: cstring"ct/run-tracepoints", message: BackendSentence)
    let timedOut = DapRequestOutcome(
      succeeded: false, timedOut: true,
      command: cstring"ct/run-tracepoints", message: cstring"")

    let refusedText = $requestFailureText(refused)
    let timedOutText = $requestFailureText(timedOut)

    check refusedText.len > 0
    check timedOutText.len > 0
    check refusedText != timedOutText

    # A timeout must not claim anything was refused — nothing answered at all,
    # and the backend may still be working.
    check not timedOutText.contains("refused")
    check timedOutText.contains("no answer")
    # ...and it must not invent a reason it was never given.
    check not timedOutText.contains($BackendSentence)

    check refusedText.contains("refused")

  test "a refusal with no message still says it was refused":
    ## The arm that would otherwise fall through to silence: `success: false`
    ## with an absent `message` is a refusal the user must still learn about.
    let dap = freshDap()
    dap.sendCtRequest(CtRunTracepoints, JsObject{})
    dap.resolvePendingDapResponse(JsObject{
      `type`: cstring"response",
      request_seq: lastSeq(),
      success: false,
      command: cstring"ct/run-tracepoints",
      body: JsObject{}
    })

    let painted = notificationText(paintStatusBar())
    check painted != ""
    check painted.contains("refused")
    check painted.contains("without saying why")

  test "a request that succeeded paints nothing":
    ## THE OVER-FIRING GUARD. Without it every check above would still be
    ## green over a hook that notified on every response, and the status bar
    ## would fill with errors during normal use.
    let dap = freshDap()
    dap.sendCtRequest(CtRunTracepoints, JsObject{})
    dap.resolvePendingDapResponse(
      successFrame(lastSeq(), cstring"ct/run-tracepoints"))

    check rendered.len == 0
    check notificationText(paintStatusBar()) == ""

  test "a response frame carrying no success field is not reported as a failure":
    ## Frames reach `resolvePendingDapResponse` that DAP does not require to
    ## carry `success`. Defaulting the missing field to "failed" would make
    ## the notification fire on traffic that never failed, which is a louder
    ## version of the same defect.
    let dap = freshDap()
    dap.sendCtRequest(CtRunTracepoints, JsObject{})
    dap.resolvePendingDapResponse(JsObject{
      `type`: cstring"response",
      request_seq: lastSeq(),
      command: cstring"ct/run-tracepoints",
      body: JsObject{}
    })

    check rendered.len == 0
    check notificationText(paintStatusBar()) == ""

  test "the outcome names the request even when the frame does not":
    ## `requestFailureText` must never produce "something failed". When the
    ## response omits `command`, the name is recovered from the request that
    ## was sent.
    let dap = freshDap()
    dap.sendCtRequest(CtRunTracepoints, JsObject{})
    dap.resolvePendingDapResponse(JsObject{
      `type`: cstring"response",
      request_seq: lastSeq(),
      success: false,
      message: BackendSentence,
      body: JsObject{}
    })

    let painted = notificationText(paintStatusBar())
    check painted.contains("ct/run-tracepoints")
    check painted.contains($BackendSentence)
