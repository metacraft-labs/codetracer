## The main process's content-id worker: a node `worker_thread` that computes
## the certificate indicator's content ids and declared scopes.
##
## ## Why a worker, and why the synchronous recipe in it
##
## Each refresh of the status bar's certificate indicator computes three
## content ids (W, H and S, Status-Bar.md) and reads the declared scopes. The
## renderer used to compute them itself:
## git in child processes, the recipe driven by
## `certificate_content_id.runResumable`. That kept the renderer from WAITING
## for git, but not from working: `runResumable` re-runs the whole recipe from
## the start each time a git call answers, replaying the earlier answers from
## a journal, so every later git call copies, splits and parses the full
## `git ls-files -z -s -v` output again. Over a 25,000-entry index that is
## seconds of synchronous renderer time per refresh, landing on whatever the
## user is doing (a call-trace jump included).
##
## Here the recipe runs ONCE, start to finish, through the synchronous host
## (`node_certificate_host.nodeContentIdHost`, `spawnSync`): one pass, no
## replay. That blocks this thread, which is the point of having one: neither
## the renderer nor the main process's event loop, which answers every other
## IPC request (`tab-load` included), waits for it.
## `index/content_id_service.nim` owns the worker and answers the renderer.
##
## ## The protocol
##
## In: `{id, request}`, `request` being `main_process_wire.encodeRequest`'s
## JSON text. Out: `{id, outcome}`, the outcome's JSON text. Requests are
## answered one at a time, in order. A malformed request is answered as a
## failure for its `id`; nothing here throws past a message.
##
## ## Built as its own bundle
##
## `repro.nim`'s `frontend-content-id-worker-js` compiles this module with the
## main process's defines into `content_id_worker.js` beside `index.js`, and
## every package ships it there (`nix/packages/default.nix`,
## `appimage-scripts/build_with_nim.sh`, `non-nix-build/build_with_nim.sh`).
## Run as the main module it serves at once; a suite imports it and calls
## `serveContentIdRequests` from a worker it started over its own file.

when not defined(js):
  {.error: "content_id_worker.nim is a node worker (JS backend)".}

import std/[json, jsffi, tables]

import ../viewmodel/platform/outcome
import ../viewmodel/platform/vcs
import ../viewmodel/platform/capabilities
import ../viewmodel/host/electron_profile
import ../viewmodel/host/node_certificate_host
import ../viewmodel/host/main_process_wire

proc workerProfile(): PlatformProfile =
  ## The profile the recipe is asked under. Whoever sends a request has
  ## already checked ITS profile (`content_id_service`), so this one only has
  ## to grant what `contentIdOver` and `declaredScopesOver` require, which
  ## the desktop's does.
  electronDesktopProfile(false)

proc failureText(message, detail: string): string =
  $encodeOutcome(failed[Nothing](pkFailed, message, detail),
                 proc(value: Nothing): JsonNode = newJNull())

proc answerRequest*(hostFor: proc(tempRoot: string): ContentIdHost;
                    requestText: string): string =
  ## The outcome's JSON text for one request. Synchronous: git runs through
  ## `spawnSync`, so this returns when the last git call has. `hostFor`
  ## gives the host whose temporary indexes go under the request's
  ## `tempRoot`.
  var request: ContentIdRequest
  try:
    request = decodeRequest(parseJson(requestText))
  except:
    # Bare: on the JS backend `JSON.parse` throws a JS `SyntaxError`,
    # which a typed arm re-throws.
    return failureText("the content-id request could not be read",
                       getCurrentExceptionMsg())
  let profile = workerProfile()
  let host = hostFor(request.tempRoot)
  case request.op
  of OpContentId:
    var outcome: PlatformOutcome[VcsContentId]
    try:
      outcome = contentIdOver(host, profile, request.repository,
                              request.state, request.algorithm, request.scope)
    except:
      # A BARE ARM: on the JS backend a node `Error` is not a Nim exception,
      # and a typed arm re-throws it.
      outcome = failed[VcsContentId](pkFailed, "computing a content id raised",
                                     getCurrentExceptionMsg())
    encodeContentIdOutcome(outcome)
  else:
    var outcome: PlatformOutcome[VcsDeclaredScopes]
    try:
      outcome = declaredScopesOver(host, profile, request.repository)
    except:
      outcome = failed[VcsDeclaredScopes](pkFailed,
        "reading the declared certificate scopes raised",
        getCurrentExceptionMsg())
    encodeDeclaredScopesOutcome(outcome)

proc parentPortOn(handler: proc(message: JsObject))
  {.importjs: "require('worker_threads').parentPort.on('message', #)".}
proc parentPortPost(id: JsObject; outcome: cstring)
  {.importjs: "require('worker_threads').parentPort.postMessage({id: #, outcome: #})".}

proc serveContentIdRequests*() =
  ## Answer the parent's requests until it terminates this worker.
  var hosts = initTable[string, ContentIdHost]()
  let hostFor = proc(tempRoot: string): ContentIdHost =
    if tempRoot notin hosts:
      hosts[tempRoot] = nodeContentIdHost(tempRoot)
    hosts[tempRoot]
  parentPortOn(proc(message: JsObject) =
    let id = message[cstring"id"]
    var answer = ""
    try:
      answer = answerRequest(hostFor, $message[cstring"request"].to(cstring))
    except:
      answer = failureText("the content-id worker failed", getCurrentExceptionMsg())
    parentPortPost(id, cstring(answer)))

when isMainModule:
  serveContentIdRequests()
