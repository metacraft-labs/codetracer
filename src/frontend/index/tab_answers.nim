## THE RENDERER TAB AN ANSWER IS FOR.
##
## One desktop window holds several tabs, each an independent session
## (`GUI/Multi-Window-Tab-Management.md` §Tab Behavior rules 1, 2 and 6). The
## renderer names the asking tab on every request it sends — a `tab` field
## holding that tab's `ReplaySession.id`, stamped by `ui_js.stampAskingTab` —
## and the main process hands it back on the answer, so the answer reaches
## that tab whichever tab is on screen when it arrives
## (`ui/tab_answer_routing.deliverTabAnswer`). An answer without a `tab` is for
## the tab on screen, which is also what a request from a sender that names
## none (an older renderer, a CLI start) gets.
##
## Two ways an answer gets its tab:
##
## * `answerFor(request, payload)` — the answer is sent from the handler of
##   the request it answers: echo the request's `tab`.
## * `loadTab` — the trace-load pipeline (`index/traces.nim`): a load started
##   by one request answers with a dozen messages from deep inside
##   `prepareForLoadingTrace` / `loadExistingRecord` / `loadTrace`. The main
##   process runs one load at a time over ONE `data.trace` (and one
##   `prefetchedTrace`, one `selectedReplayId`), so the tab of the load in
##   progress is one value too. `load_admission` enforces that invariant for
##   the ENTIRE asynchronous IPC operation (and startup): a second load is
##   refused in its asking tab before changing shared state. Each entrypoint
##   records its request's `tab` here, and every message of that load carries
##   it (`forLoadTab`). Nested steps retain their admitted operation's tab.
##
## Messages that are about the window rather than a reply to one tab's
## request carry no `tab` and stay window-scoped; `ui_js.configureIPC` lists
## them with the reason for each.

import std/jsffi

proc askingTab*(request: JsObject): JsObject =
  ## The `tab` the request names, or `undefined` when it names none.
  if request.isNil or request.isUndefined or request.isNull:
    return jsUndefined
  let tab = request[cstring"tab"]
  if tab.isNull or tab.isUndefined: jsUndefined else: tab

proc withTab*(payload: JsObject; tab: JsObject): JsObject =
  ## `payload` with `tab` set, unless `tab` is `undefined`. Returns the same
  ## object, for use inline in a `send`.
  if not payload.isNil and not tab.isUndefined:
    payload[cstring"tab"] = tab
  payload

proc answerFor*(request: JsObject; payload: JsObject): JsObject =
  ## `payload`, the answer to `request`, carrying the tab `request` named.
  withTab(payload, askingTab(request))

var loadTab*: JsObject = jsUndefined
  ## The tab of the trace load in progress (see the module doc). `undefined`
  ## for a legacy sender that names none, whose messages then go to the tab
  ## on screen. Startup names the renderer's first session (0); a new tab
  ## requests its own load after the renderer has created its identity.

proc startLoadFor*(request: JsObject) =
  ## A load-starting entrypoint records the tab its `request` came from.
  loadTab = askingTab(request)

proc forLoadTab*(payload: JsObject): JsObject =
  ## `payload` of a message of the load in progress, carrying its tab.
  withTab(payload, loadTab)
