## vscode_request_panel_role_dom_test.nim
##
## The Request Panel is a VS Code panel role (Shared-DOM-Front-Ends Q8 and
## D9; `GUI/Core-Panes/Request-Panel.md` § The VS Code extension): a webview
## whose HTML names `requestPanel` mounts the shared `renderRequestPanel`
## over a mirror of the extension host's session, its rows are the window
## the host's PRIMARY loaded, and a click on a row runs on the primary.
##
## The suite drives `entries/vscode_panel.mountVsCodePanel` — the webview's
## real entry — over the real webview transport (`sync/webview_transport`),
## with the host's end served by a real `SyncHost` over a primary built by
## `initializePanelViewModels`, in jsdom's document.
##
## THE STAND-INS, and why each is needed:
## - `acquireVsCodeApi` and the `message` event: VS Code gives a webview a
##   `postMessage` to its extension host and delivers the host's messages as
##   window `message` events. Here the webview's `postMessage` hands the
##   message to the host's channel (`deliverFromWebview`), and the host's
##   messages are dispatched as `message` events on jsdom's window — the two
##   halves of the bridge `webview_transport` is written against, with no
##   extension host process in between.
## - `MockBackendService` behind the primary: the property under test is
##   what crosses between the webview and the host. The primary's one
##   engine request (`ct/load-request-spans`) is answered with two rows in
##   the engine's shape; its filtering is tested where it lives
##   (`test_request_panel_window`, `request_spans.rs`).
## - A manual scheduler for the host's publisher, so the suite decides when
##   a batch is cut.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/[json, jsffi, options, strutils, unittest]

import isonim/core/[owner, async_compat, signals]
import isonim/web/[web_renderer, dom_api]

import ../viewmodel/backend/mock_backend
import ../viewmodel/session_vm
import ../viewmodel/sync/[sync_host, sync_publisher, transport,
                          webview_transport, mirror_session]
import ../viewmodel/viewmodels/request_panel_vm
import ../viewmodel/viewport
import ../entries/vscode_panel

{.emit: """
// The webview's `postMessage` goes to the host's channel, which the suite
// installs as `window.ctToHost` before the panel mounts.
// A bare name, as VS Code defines it, and on the window too.
globalThis.acquireVsCodeApi = window.acquireVsCodeApi = function () {
  return { postMessage: function (m) { window.ctToHost(m); } };
};
// jsdom has no ResizeObserver; the mounted pane observes its host with one.
if (!window.ResizeObserver) {
  window.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
}
""".}

proc setToHost(f: proc(m: JsObject)) {.importjs: "window.ctToHost = #".}
proc toWebview(m: JsObject) {.importjs:
  "window.dispatchEvent(new window.MessageEvent('message', { data: # }))".}
proc query(root: Element; selector: cstring): Element
  {.importjs: "(#.querySelector(#) || null)".}
proc countOf(root: Element; selector: cstring): int
  {.importjs: "#.querySelectorAll(#).length".}
proc textOf(el: Element): cstring {.importjs: "(#.textContent || '')".}
proc click(el: Element) {.importjs: "#.click()".}
proc newRoot(): Element {.importjs: """(function(){
  const r = document.createElement('div'); r.id = 'ct-panel-root';
  document.body.appendChild(r); return r; })()""".}

var failed = 0
template ck(cond: untyped) =
  if not (cond):
    inc failed
  check cond

var queued: seq[proc()]
let manual: Scheduler = proc(callback: proc()) = queued.add callback

proc settle() =
  ## Cut every scheduled batch and let the platform settle, until quiet; the
  ## bridge itself delivers synchronously.
  for _ in 0 ..< 100:
    drainPlatformCallbacks()
    if queued.len == 0:
      return
    let run = queued
    queued = @[]
    for callback in run:
      callback()
  doAssert false, "the webview and its host did not settle"

proc request(id: int; httpMethod: string): JsonNode =
  %*{"id": id, "httpMethod": httpMethod, "url": "/r/" & $id,
     "statusCode": 200, "durationMs": 1, "startGeid": id * 10,
     "status": "ok"}

proc windowAnswer(rows: seq[JsonNode]): JsonNode =
  %*{"type": "response", "success": true,
     "body": {"requests": rows, "total": rows.len, "source": "span-stream"}}

suite "the Request Panel role in a VS Code webview":
  test "it mounts the shared view, shows the primary's window and acts on the primary":
    createRoot proc(done: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let primary = createSessionVM(mock.toBackendService())
      primary.initializePanelViewModels()
      let host = newSyncHost(manual)
      let hostEnd = newHostWebviewChannel(proc(m: JsObject) = toWebview(m))
      setToHost(proc(m: JsObject) = discard hostEnd.deliverFromWebview(m))
      host.attach(hostEnd)
      host.addPrimary("s1", primary)

      let root = newRoot()
      let mirror = mountVsCodePanel("requestPanel", root)
      settle()

      # The role mounted: the shared Request Panel view, in the webview's
      # root, over a mirror whose request panel relays its actions.
      ck "requestPanel" in PanelKinds
      ck not isNodeNil(Node(root.query(cstring".request-table-body")))
      ck not mirror.session.requestPanelVM.actionSink.isNil
      # CONTROL: a kind the entry does not know mounts nothing.
      let other = newRoot()
      discard mountVsCodePanel("noSuchPanel", other)
      ck isNodeNil(Node(other.query(cstring".request-table-body")))

      # The size the webview reports is the PRIMARY's, which asks the
      # replay for that window; the mirror's own backend is inert.
      mock.expect("ct/load-request-spans",
        windowAnswer(@[request(1, "GET"), request(2, "POST")]))
      mirror.session.requestPanelVM.setViewport(Viewport(rows: 5, firstRow: 0))
      settle()
      ck primary.requestPanelVM.viewport.val.rows == 5
      ck mock.findCommand("ct/load-request-spans").isSome
      ck primary.requestPanelVM.windowed
      ck mirror.session.requestPanelVM.matchingCount == 2
      ck root.countOf(cstring".request-row") == 2
      let first = root.query(cstring".request-row")
      ck not isNodeNil(Node(first))
      if not isNodeNil(Node(first)):
        ck "/r/1" in $first.textOf
        # A click on the row selects it on the primary, and the selection
        # comes back to the webview as the primary's.
        first.click()
        settle()
        ck primary.requestPanelVM.selectedIndex.val == 0
        ck mirror.session.requestPanelVM.selectedIndex.val == 0

      # A filter is the primary's: its next window is asked filtered.
      mock.expect("ct/load-request-spans", windowAnswer(@[request(2, "POST")]))
      mirror.session.requestPanelVM.setFilterMethod("POST")
      settle()
      ck primary.requestPanelVM.filterMethod.val == "POST"
      ck root.countOf(cstring".request-row") == 1

      mirror.dispose()
      host.dispose()
      done()

if failed > 0:
  {.emit: "process.exitCode = 1;".}
