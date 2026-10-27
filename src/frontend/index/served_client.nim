## index/served_client.nim — which client the index is serving right now.
##
## `ct host` serves several clients from one index process
## (`host_clients`), and the index answers through one send path, long after
## a request and across awaits. The client a piece of work is for is carried
## in a Node `AsyncLocalStorage`
## (https://nodejs.org/api/async_context.html#class-asynclocalstorage): a
## handler bound to a client's socket runs inside that client's context, and
## the context follows the promises, timers and I/O the handler starts. The
## send path reads it (`currentClient`) to decide who hears what.
##
## Work that belongs to no client — a watch of a file every client reads —
## runs `forEveryClient`, so what it sends goes to every client even when the
## watch was started while serving one.
##
## The desktop has one window and never enters a client's context: there
## `currentClient` is always nil and `forEveryClient` just runs its proc.
##
## JS only.

when not defined(js):
  {.error: "index/served_client runs in the index process (JS).".}

import std/jsffi

proc newAsyncContext(): JsObject {.importjs:
  "new (require('async_hooks').AsyncLocalStorage)()".}
proc contextStore(context: JsObject): JsObject {.importjs: "#.getStore()".}
proc runIn(context: JsObject; store: JsObject; fn: proc()) {.importjs:
  "#.run(#, #)".}
proc exitFrom(context: JsObject; fn: proc()) {.importjs: "#.exit(#)".}
proc wrapIn(context: JsObject; store: JsObject; handler: JsObject): JsObject {.importjs: """
  (function (context, store, handler) {
    return function () {
      var self = this, args = arguments;
      return context.run(store, function () { return handler.apply(self, args); });
    };
  })(#, #, #)""".}

proc newWeakMap(): JsObject {.importjs: "new WeakMap()".}
proc weakGet(map: JsObject; key: JsObject): JsObject {.importjs: "#.get(#)".}
proc weakSet(map: JsObject; key: JsObject; value: cstring) {.importjs: "#.set(#, #)".}

var clientContext: JsObject = nil
var clientKeys: JsObject = nil
  ## Each client's key (`currentClientKey`), weakly held so a released
  ## client is not kept alive by it.
var nextClientKey = 0

proc context(): JsObject =
  if clientContext.isNil:
    clientContext = newAsyncContext()
  clientContext

proc currentClient*(): JsObject =
  ## The client being served, as given to `runAsClient` / `wrapAsClient`;
  ## nil outside every client's context.
  if clientContext.isNil:
    return nil
  let store = clientContext.contextStore()
  if store.isNil or store.isUndefined: nil else: store

proc currentClientKey*(): cstring =
  ## A key naming the client being served, unique for the process's life;
  ## "" outside every client's context (and always on the desktop).
  ##
  ## For index state a page names by a value of its own choosing, which two
  ## pages can choose alike (the Agent Activity pane's `agent-session-0`):
  ## keyed by the pair, one client's name cannot reach another client's
  ## state.
  let store = currentClient()
  if store.isNil:
    return cstring""
  if clientKeys.isNil:
    clientKeys = newWeakMap()
  let known = clientKeys.weakGet(store)
  if not known.isNil and not known.isUndefined:
    return known.to(cstring)
  inc nextClientKey
  result = cstring("client-" & $nextClientKey)
  clientKeys.weakSet(store, result)

proc runAsClient*(client: JsObject; fn: proc()) =
  ## Run `fn`, and everything it starts, as `client`'s.
  context().runIn(client, fn)

proc wrapAsClient*(client: JsObject; handler: JsObject): JsObject =
  ## `handler`, made to run as `client`'s whenever it is called.
  wrapIn(context(), client, handler)

proc forEveryClient*(fn: proc()) =
  ## Run `fn`, and everything it starts, as no client's: for every client.
  if clientContext.isNil:
    fn()
  else:
    clientContext.exitFrom(fn)
