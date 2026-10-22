## sync/webview_transport.nim
##
## A `SyncChannel` between a VS Code extension host and one of its webviews
## (Shared-DOM-Front-Ends D2: "VS Code | extension host | a mirror per webview
## | `postMessage`").
##
## Each side has its own constructor:
##
## - the webview's, over `acquireVsCodeApi().postMessage` and the window's
##   `message` events (https://code.visualstudio.com/api/extension-guides/webview#passing-messages-from-a-webview-to-an-extension);
## - the host's, over a `post` function the extension passes in
##   (`webview.postMessage`) and `deliverFromWebview`, which the extension
##   calls from `onDidReceiveMessage`.
##
## A sync message crosses as `{"ctSync": "<json text>"}`, so it shares the
## webview's message stream with the extension's own messages without either
## reading the other's; the text form keeps it out of structured cloning.
## A message that does not parse is dropped: a webview reload can deliver
## anything.
##
## JS only.

when not defined(js):
  {.error: "sync/webview_transport carries postMessage traffic (JS only).".}

import std/[json, jsffi]

import transport

const SyncEnvelopeKey* = "ctSync"
  ## The field a sync message travels in.

proc envelopeText(data: JsObject): cstring {.importjs:
  "(function(d){ return (d && typeof d.ctSync === 'string') ? d.ctSync : null; })(#)".}

proc deliverEnvelope(channel: SyncChannel; data: JsObject) =
  let text = envelopeText(data)
  if text.isNil:
    return
  var msg: JsonNode
  try:
    msg = parseJson($text)
  except CatchableError:
    return
  channel.deliver(msg)

proc envelope(msg: JsonNode): JsObject =
  result = newJsObject()
  result[cstring(SyncEnvelopeKey)] = cstring($msg)

# ---------------------------------------------------------------------------
# Webview side
# ---------------------------------------------------------------------------

proc vsCodeApi(): JsObject {.importjs: """(function(){
  if (!window.ctVsCodeApi) { window.ctVsCodeApi = acquireVsCodeApi(); }
  return window.ctVsCodeApi; })()""".}
  ## `acquireVsCodeApi` may be called once per webview, so the handle is
  ## kept on `window` for any other script of the page.

proc onWindowMessage(handler: proc(data: JsObject)) {.importjs:
  "window.addEventListener('message', function(ev) { (#)(ev.data); })".}

proc newWebviewSyncChannel*(): SyncChannel =
  ## The webview's end: messages go to the extension host and arrive from it.
  let api = vsCodeApi()
  let channel = newSyncChannel(proc(msg: JsonNode) =
    discard api.postMessage(envelope(msg)))
  onWindowMessage(proc(data: JsObject) = channel.deliverEnvelope(data))
  channel

# ---------------------------------------------------------------------------
# Host side
# ---------------------------------------------------------------------------

proc newHostWebviewChannel*(post: proc(message: JsObject)): SyncChannel =
  ## The host's end of one webview: `post` is that webview's `postMessage`.
  newSyncChannel(proc(msg: JsonNode) = post(envelope(msg)))

proc deliverFromWebview*(channel: SyncChannel; data: JsObject): bool =
  ## Hand a message the webview posted to the channel; `false` when it is not
  ## a sync message (the extension's own traffic).
  if envelopeText(data).isNil:
    return false
  channel.deliverEnvelope(data)
  true
