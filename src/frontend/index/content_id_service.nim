## The main process's content-id service: the certificate indicator's
## content ids and declared scopes, computed in a worker thread.
##
## The renderer's VCS facade (`viewmodel/host/desktop_electron.nim`) no longer
## runs git for `vcs.contentId` and `vcs.declaredScopes`. It sends
## `CODETRACER::content-id` / `CODETRACER::declared-scopes` here, and this
## module answers on `-received` with the outcome. The computation runs in
## ONE node `worker_thread` (`content_id_worker.nim`), started on the first
## request and kept for later ones, so it costs neither the renderer's thread
## nor this process's event loop. Why the work moved at all is in the
## worker's header.
##
## ## Failures are values
##
## A worker that cannot start (its bundle missing from a package), throws, or
## exits answers every request in flight with a `pkFailed` outcome, and the
## next request starts a new one. A request is never left unanswered by a
## worker that went away.
##
## ## Whose answer
##
## A handler runs as the window that sent the request (`window_routing.
## runForSender`), and the answer is sent from that context, so it reaches
## that window alone. It carries the request's `id` (several are in flight at
## once: W, H and S) and, through `tab_answers.answerFor`, its tab.

when not defined(js):
  {.error: "index/content_id_service runs in the index process (JS).".}

import std/[async, jsffi, json, tables]

import electron_vars, tab_answers
import ../viewmodel/platform/outcome
import ../viewmodel/platform/capabilities
import ../viewmodel/platform/vcs
import ../viewmodel/platform/endpoint_codec
import ../viewmodel/host/main_process_wire

const ContentIdWorkerScript* = "content_id_worker.js"
  ## The worker's bundle, shipped beside `index.js` / `server_index.js`.

type
  ContentIdService* = ref object
    scriptPath: string
    worker: JsObject
      ## The running worker, or nil before the first request and after one
      ## has gone away.
    nextId: int
    pending: Table[int, proc(answer: cstring)]
    started*: int
      ## How many workers this service has started. For the suites: a worker
      ## that went away is replaced, and a healthy one is reused.

proc newWorker(script: cstring): JsObject {.importjs: """
  (function (script) {
    var wt = require('worker_threads');
    // SHARE_ENV: the worker reads this process's environment as it is when
    // git runs, not a copy taken when the worker started — `PATH`, `TMPDIR`
    // and git's own variables are the process's, as they were in the
    // renderer before the computation moved here.
    return new wt.Worker(script, {env: wt.SHARE_ENV,
                                  workerData: {ctContentIdWorker: true}});
  })(#)""".}
proc postTo(worker: JsObject; id: int; request: cstring)
  {.importjs: "#.postMessage({id: #, request: #})".}
proc onWorker(worker: JsObject; event: cstring; handler: proc(value: JsObject))
  {.importjs: "#.on(#, #)".}
proc refWorker(worker: JsObject) {.importjs: "#.ref()".}
proc unrefWorker(worker: JsObject) {.importjs: "#.unref()".}
proc terminateWorker(worker: JsObject) {.importjs: "#.terminate()".}
proc errorMessage(value: JsObject): cstring {.importjs: """
  (function (e) {
    if (e === null || e === undefined) { return ''; }
    return String(e.message !== undefined ? e.message : e);
  })(#)""".}
proc existsSync(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
proc pathJoin(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc bundleDir(): cstring {.importjs: "(typeof __dirname === 'string' ? __dirname : process.cwd())".}

proc defaultWorkerScript*(): string =
  ## Where the worker's bundle is: beside this bundle, which is `index.js` /
  ## `server_index.js` in `<prefix>/src/` or in `<prefix>/` depending on the
  ## package. The first candidate that exists, else the first (whose absence
  ## the worker's `error` then reports).
  let here = bundleDir()
  let candidates = [pathJoin(here, cstring(ContentIdWorkerScript)),
                    pathJoin(pathJoin(here, cstring".."), cstring(ContentIdWorkerScript)),
                    pathJoin(pathJoin(here, cstring"src"), cstring(ContentIdWorkerScript))]
  for candidate in candidates:
    if existsSync(candidate):
      return $candidate
  $candidates[0]

proc newContentIdService*(scriptPath = ""): ContentIdService =
  ## A service whose worker runs `scriptPath` (default: the shipped bundle).
  ContentIdService(scriptPath: scriptPath,
                   pending: initTable[int, proc(answer: cstring)]())

proc failureAnswer(message, detail: string): cstring =
  cstring($encodeOutcome(failed[Nothing](pkFailed, message, detail),
                         proc(value: Nothing): JsonNode = newJNull()))

proc abandon(service: ContentIdService; worker: JsObject; message, detail: string) =
  ## `worker` went away: answer everything in flight, and let the next request
  ## start a new one. A stale worker's late event changes nothing.
  if service.worker != worker or worker.isNil:
    return
  service.worker = nil
  try: terminateWorker(worker)
  except: discard
  let answer = failureAnswer(message, detail)
  var waiting: seq[proc(answer: cstring)] = @[]
  for done in service.pending.values:
    waiting.add done
  service.pending.clear()
  for done in waiting:
    done(answer)

proc ensureWorker(service: ContentIdService): JsObject =
  if not service.worker.isNil:
    return service.worker
  let script = if service.scriptPath.len > 0: service.scriptPath
               else: defaultWorkerScript()
  var worker: JsObject = nil
  try:
    worker = newWorker(cstring(script))
  except:
    return nil
  service.worker = worker
  inc service.started
  onWorker(worker, cstring"message", proc(message: JsObject) =
    let id = message[cstring"id"].to(int)
    if id notin service.pending:
      return
    let done = service.pending[id]
    service.pending.del(id)
    if service.pending.len == 0 and service.worker == worker:
      # Idle: an idle worker must not keep `ct host` or a suite alive.
      unrefWorker(worker)
    done(message[cstring"outcome"].to(cstring)))
  onWorker(worker, cstring"error", proc(error: JsObject) =
    service.abandon(worker, "the content-id worker failed",
                    "running " & script & ": " & $errorMessage(error)))
  onWorker(worker, cstring"exit", proc(code: JsObject) =
    service.abandon(worker, "the content-id worker exited",
                    "running " & script & ": exit " & $errorMessage(code)))
  worker

proc ask(service: ContentIdService; request: ContentIdRequest;
         done: proc(answer: cstring)) =
  ## Send `request` to the worker; `done` receives the outcome's JSON text,
  ## exactly once, on a later turn of the event loop.
  let worker = service.ensureWorker()
  if worker.isNil:
    done(failureAnswer("the content-id worker could not be started",
                       service.scriptPath))
    return
  inc service.nextId
  let id = service.nextId
  service.pending[id] = done
  refWorker(worker)
  postTo(worker, id, cstring($encodeRequest(request)))

proc contentId*(service: ContentIdService; profile: PlatformProfile;
                repository: string; state: VcsBlobSource; algorithm: string;
                scope: seq[string]): PlatformFuture[PlatformOutcome[VcsContentId]] =
  ## `vcs.contentId`, computed by the worker. A profile without
  ## `ContentIdRequires` is refused here, before any worker starts.
  if not profile.hasAll(ContentIdRequires):
    return resolved(contentIdRefusal(profile))
  let request = ContentIdRequest(op: OpContentId, repository: repository,
                                 state: state, algorithm: algorithm,
                                 scope: scope)
  settledLater(proc(settle: proc(value: PlatformOutcome[VcsContentId])) =
    service.ask(request, proc(answer: cstring) =
      settle(decodeContentIdOutcome($answer))))

proc declaredScopes*(service: ContentIdService; profile: PlatformProfile;
                     repository: string
                    ): PlatformFuture[PlatformOutcome[VcsDeclaredScopes]] =
  ## `vcs.declaredScopes`, read by the worker.
  if not profile.hasAll(DeclaredScopesRequires):
    return resolved(declaredScopesRefusal(profile))
  let request = ContentIdRequest(op: OpDeclaredScopes, repository: repository)
  settledLater(proc(settle: proc(value: PlatformOutcome[VcsDeclaredScopes])) =
    service.ask(request, proc(answer: cstring) =
      settle(decodeDeclaredScopesOutcome($answer))))

proc answerRaw*(service: ContentIdService; requestText: string;
                done: proc(answer: cstring)) =
  ## The IPC handlers' path: a request as the renderer encoded it, answered
  ## with the outcome's JSON text. A request that cannot be read is answered
  ## as a failure without reaching the worker.
  var request: ContentIdRequest
  try:
    request = decodeRequest(parseJson(requestText))
  except:
    # Bare: on the JS backend `JSON.parse` throws a JS `SyntaxError`,
    # which a typed arm re-throws.
    done(failureAnswer("the content-id request could not be read",
                       getCurrentExceptionMsg()))
    return
  service.ask(request, done)

var processWorkerScript* = ""
  ## The worker script `processContentIdService` starts; empty for the
  ## shipped bundle (`defaultWorkerScript`). A suite, whose bundle is not
  ## shipped beside a worker, points it at a worker of its own before the
  ## first request.

var desktopService: ContentIdService = nil
  ## The process's one service, made on the first request.

proc processContentIdService*(): ContentIdService =
  if desktopService.isNil:
    desktopService = newContentIdService(processWorkerScript)
  desktopService

proc answerOnChannel(channel: cstring; request: JsObject) =
  let id = request[cstring"id"]
  var text = ""
  try:
    text = $request[cstring"request"].to(cstring)
  except:
    text = ""
  processContentIdService().answerRaw(text, proc(answer: cstring) =
    mainWindow.webContents.send(channel,
      answerFor(request, JsObject{id: id, outcome: answer})))

proc onContentId*(sender: JsObject; response: JsObject) {.async.} =
  ## `CODETRACER::content-id` {id, request}: answered on
  ## `CODETRACER::content-id-received` {id, outcome}.
  answerOnChannel(cstring(ContentIdReceivedChannel), response)

proc onDeclaredScopes*(sender: JsObject; response: JsObject) {.async.} =
  ## `CODETRACER::declared-scopes` {id, request}: answered on
  ## `CODETRACER::declared-scopes-received` {id, outcome}.
  answerOnChannel(cstring(DeclaredScopesReceivedChannel), response)
