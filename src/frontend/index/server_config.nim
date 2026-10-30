import
  std / [ async, json, jsffi, macros, jsconsole, strformat, strutils ],
  electron_vars, base_handlers, config, idle_timeout, facade_endpoint,
  host_session_guard,
  ../lib/[ jslib, electron_lib, misc_lib ],
  ../[ types ],
  ../../common/[ paths, ct_logging ]

# `cacheClassFor` / `headerFor` — the Pages deployment's own, so `ct host` and
# the CDN cannot disagree about what a path may be cached for.
proc flushStdoutSync() {.importjs:
  "(process.stdout.write('') , undefined)".}
  ## `process.stdout.write('')` forces the pending buffer out on a pipe. There
  ## is no synchronous `flush` in node; an empty write is the documented way to
  ## make the queue drain.

from ../viewmodel/platform/web_deployment import cacheClassFor, headerFor
import ../viewmodel/platform/deployment_descriptor
import host_clients   # every client its own replay and session

proc nodeRelative(fromPath, toPath: cstring): cstring {.importjs:
  "require('path').relative(require('path').resolve(#), #)".}

when defined(server):
  type
    ExpressLib* = ref object
      `static`*: proc(path: cstring, options: JsObject): JsObject

    ExpressServer* = ref object
      get*: proc(path: cstring, handler: proc(req: Jsobject, response: JsObject))
      # THE HOST ARGUMENT IS THE POINT OF THIS DECLARATION.
      #
      # Node's `server.listen(port, cb)` binds 0.0.0.0. This binding omitted
      # the host parameter, so there was no way to say otherwise from Nim and
      # `ct host` served every interface while its own spec required loopback.
      # Declaring the three-argument form is what makes the rule expressible.
      # RETURNS THE LISTENER, and that return is load-bearing rather than
      # incidental: with `--port 0` the kernel chooses the port, so the only
      # place the real one can be read is `listener.address().port`. Declared
      # `void` this was unreachable from Nim, which is the same shape as the
      # host argument this type was widened for.
      listen*: proc(port: int, host: cstring, handler: proc: void): JsObject
      use*: proc(prefix: cstring, value: JsObject)


when not defined(server):
  # chalk 5.x is ESM-only and cannot be require()'d in CommonJS Electron.
  # Two-step: catch the ESM error with an `except: undefined` (matches how
  # electron-debug is handled), then substitute a passthrough object outside
  # the try block so chalk.blue/red/etc degrade gracefully to identity functions
  # instead of crashing the main process at module load time.
  proc passthroughChalk(): js {.importjs: """(function() {
    var id = function(s) { return s; };
    return { yellow: id, blue: id, red: id, green: id,
             bold: id, underline: id,
             keyword: function() { return id; } };
  })()""".}
  var chalkRaw: js = try: require(cstring"chalk") except: undefined
  var chalk*: Chalk = cast[Chalk](if not isUndefined(chalkRaw): chalkRaw else: passthroughChalk())
  type DebugMainIPC = ref object
    electron*: js

  proc on*(ipc: DebugMainIPC, id: cstring, handler: JsObject) =
    ipc.electron[cstring"on2"] = ipc.electron[cstring"on"]
    ipc.electron.on2(id) do (sender: js, data: js):
      var values = loadValues(data, id)
      let kind = cast[cstring](id)
      if kind != cstring"CODETRACER::save-config":
        debugPrint cstring($(chalk.blue(cstring(fmt"frontend =======> index: {kind}"))))
        # TODO: think more: flag for enabling/disabling printing those values?
      else:
        debugPrint cstring($(chalk.blue(cstring(fmt"frontend =======> index: {kind}"))))
      let rawTaskId = if not data.isNil: data.taskId else: NO_TASK_ID.toJs
      let taskId = if not rawTaskId.isUndefined:
          cast[TaskId](rawTaskId)
        else:
          NO_TASK_ID
      # TODO: QA NOTE FIX THE CIRCULAR DEPENDENCY
      #debugIndex fmt"frontend =======> index: {kind}", taskId
      let handlerFunction = jsAsFunction[proc(sender: js, response: js): Future[void]](handler)
      discard handlerFunction(sender, data)

  var ipc* = DebugMainIPC(electron: electron.ipcMain)
else:
  var ipc* = initFrontendIPC()


when defined(server):
  proc call*(lib: ExpressLib): ExpressServer {.importcpp: "#()".}
  proc newSocketIoServer*(serverClass: JsObject, httpServer: JsObject, options: JsObject): JsObject {.importcpp: "new #(#, #)" .}

  let express* = cast[ExpressLib](require("express"))

  var readyVar*: js
  var serverClients*: HostClients
    ## The server's clients (`host_clients`); made by `setupServer`, before
    ## any client can connect.
  proc nowMs(): int {.importjs: "Date.now()".}
  proc handshakeQueryValue(socket: JsObject; name: cstring): cstring {.importjs: """
    (function (socket, name) {
      var query = socket && socket.handshake && socket.handshake.query;
      var value = query ? query[name] : undefined;
      return typeof value === 'string' ? value : '';
    })(#, #)""".}

  proc handshakeClientId(socket: JsObject): string =
    ## The client id the page presented in its handshake (`ct_client`), or ""
    ## when it presented none (`host_clients.connect` then makes a new one).
    $handshakeQueryValue(socket, ClientIdParameter.cstring)

  proc handshakePageId(socket: JsObject): string =
    ## The page document the socket's page presented (`ct_page`), or "": a
    ## different one from the client's last tells a reload from a reconnect
    ## (`host_clients.connect`).
    $handshakeQueryValue(socket, PageIdParameter.cstring)
  proc setInterval*(cb: proc(): void, delay: int): JsObject {.importjs: "setInterval(#, #)".}

  proc setupServer* =
    # we create a server
    # and we receive socket messages instead of using ipc
    # Nikola hides all of this behind some kind of proxy

    var httpServer = require("http").createServer()
    var server = express.call()

    # §7'S DESCRIPTOR, SERVED AND SENT — WD1c.
    #
    # `views/server_index.ejs` interpolated `frontendSocketPort` and
    # `frontendSocketParameters` into the page, which is precisely why the
    # entry document could not be cached: two values that change per session
    # were compiled into the artefact that does not.
    #
    # §7 says the descriptor "arrives differently per deployment and is the
    # SAME document". Both spellings are built HERE from one value, so they
    # cannot disagree: `GET /deployment.json` for the page's first fetch, and
    # `welcome.deployment` for a client that already has the socket open and
    # should not pay a second round trip before first paint.
    proc hostDescriptor(): SessionDescriptor =
      SessionDescriptor(
        session: SessionCoordinates(
          # Empty for `ct host`: the trace is the one the process was started
          # on and the page already addresses it, and a project runtime is
          # WD4's per-project record, which this deployment does not read. An
          # invented value here would be a statement nothing acts on.
          traceId: "", projectId: "",
          runtime: ProjectRuntime(kind: prkStatic),
          # The server owns each client's session; the page mirrors its own
          # (`host_clients`).
          placement: spServer),
        connection: ConnectionParameters(
          frontendSocketPort: data.startOptions.frontendSocket.port,
          # `.isNil` first: the field is a `cstring` and its default is null,
          # which `$` turns into a crash rather than into "".
          frontendSocketParameters:
            (if data.startOptions.frontendSocket.parameters.isNil: ""
             else: $data.startOptions.frontendSocket.parameters),
          backendSocketPort: data.startOptions.backendSocket.port))

    # Built ONCE per server rather than per connection: it holds the settings
    # root and the temp root, and a per-connection endpoint would give two tabs
    # of one session two different settings stores.
    let facadeEndpoint = newFacadeEndpoint(
      deployment = encodeDescriptor(hostDescriptor()))

    # ADMISSION: ONE SECRET PER RUN, AND ONLY THIS PAGE'S ORIGIN.
    #
    # Both listeners are reachable by anything that can connect to the bound
    # address, including a web page in the operator's browser, which can make
    # the browser send requests to loopback. `host_session_guard` holds the
    # rule; it is built before either listener so that neither ever runs
    # without it. A malformed supervisor-supplied secret stops the server
    # rather than falling back to a generated one the supervisor cannot know.
    var guard: HostSessionGuard
    try:
      guard = newHostSessionGuard()
    except HostSessionError as e:
      errorPrint "ct host: " & e.msg
      nodeProcess.exit(1)
      return

    proc refuseHttp(response: JsObject; reason: string) =
      # The reason is ours, never the presented value.
      debugPrint "ct host: page request refused: " & reason
      response.status(403)
      response.setHeader(cstring"Cache-Control", cstring"no-store")
      response.setHeader(cstring"Content-Type", cstring"text/plain; charset=utf-8")
      response.send(cstring("This CodeTracer session needs the address `ct host` " &
        "printed (CODETRACER_HOST_URL), which carries the session secret.\n"))

    # Every request: a foreign `Origin` is refused before any route answers,
    # so a page elsewhere cannot use this server even for the public bundle.
    proc refuseForeignOrigin(request: JsObject, response: JsObject, next: JsObject) =
      let origin = request.headers[cstring"origin"]
      if not origin.isUndefined and
          not guard.originAllowed($origin.to(cstring)):
        refuseHttp(response, "origin not allowed")
      else:
        jsAsFunction[proc(): void](next)()
    server.use(cstring"/", toJs(refuseForeignOrigin))

    # The routes that carry this session (the entry page and its descriptor)
    # need the secret too. The static bundle under them does not: it is the
    # shipped UI, the same bytes for every session and every deployment, and
    # it is cached across sessions (`cacheClassFor`), which a per-session
    # credential on each asset would defeat.
    proc admitted(request, response: JsObject): bool =
      let reason = guard.refusal(request)
      if reason.len > 0:
        refuseHttp(response, reason)
        return false
      true

    proc renderIndex(request: JsObject, response: JsObject) =
      if not admitted(request, response):
        return
      # The page URL carries the secret in its query; a Referer must not take
      # it to another origin.
      response.setHeader(cstring"Referrer-Policy", cstring"no-referrer")
      response.render(cstring"server_index", js{
        frontendSocketPort: data.startOptions.frontendSocket.port,
        frontendSocketParameters: data.startOptions.frontendSocket.parameters
      })

    server.toJs.set(cstring"view engine", cstring"ejs")
    server.get(cstring"/", renderIndex)
    server.get(cstring"/collab/join/:inviteToken", renderIndex)

    # THE CACHE CLASSES ARE THE DEPLOYMENT'S OWN, NOT SIMILAR ONES — WD1c.
    #
    # `express.static` defaults to `public, max-age=0`, so `ct host` served the
    # whole bundle uncacheable while the Pages deployment served the same bytes
    # `immutable, max-age=31536000`. Opening a second trace re-downloaded the
    # entire UI — which is exactly what
    # `test_the_bundle_is_cached_across_traces` is about.
    #
    # `cacheClassFor` and `headerFor` are `platform/web_deployment.nim`'s, the
    # same two functions that generate the Pages `_headers` file. Not a copy:
    # a wrong header is then wrong in ONE place rather than in the deployment
    # nobody is looking at. That module declares `webRuntimeAssets()` and the
    # digest rule too, so a bundled asset that starts carrying a digest moves
    # to `ccStaticAsset` on both deployments on the same day.
    #
    # The path handed to `cacheClassFor` is the URL the client asked for — the
    # mount prefix plus what `express.static` resolved under it — because the
    # class follows from the URL and nothing else. Passing the filesystem path
    # would classify `/nix/store/...-codetracer/ui.js` and answer for a path no
    # browser ever names.
    proc cached(mount: string; root: cstring): JsObject =
      # The URL is the mount prefix plus the path BELOW THE ROOT, not the
      # basename: `/public/dist/frontend_bundle.js` is one of the four bundled
      # assets and `/public/frontend_bundle.js` is not, so a basename would
      # move it out of `ccMutableAsset` into the entry document's class and
      # serve a stale renderer for sixty seconds instead of four hours —
      # different bug, same cause.
      let prefix = mount
      let rootPath = root
      express.`static`(root, js{
        setHeaders: proc(response: JsObject, filePath: cstring, stat: JsObject) =
          # `path.relative` rather than a prefix strip: the root is what the
          # caller wrote (trailing slash or not, absolute or relative to the
          # process cwd) and `filePath` is what `send` resolved, so the two are
          # not string-comparable and a strip that missed left the whole
          # absolute path glued onto the mount — which classifies as the entry
          # document and is wrong in the direction nobody notices.
          var below = $nodeRelative(rootPath, filePath)
          while below.len > 0 and below[0] == '/':
            below = below[1 .. ^1]
          var url = prefix
          if not url.endsWith("/"): url.add "/"
          url.add below
          response.setHeader(cstring"Cache-Control",
                             headerFor(cacheClassFor(url)).cstring)
      })

    server.get(cstring"/deployment.json", proc(request: JsObject, response: JsObject) =
      if not admitted(request, response):
        return
      # Uncacheable BY CLASS, not by a header written here: it is the mutable
      # pointer the immutable document is cacheable because of, and
      # `cacheClassFor` is what decides that for every other path this server
      # answers.
      response.setHeader(cstring"Cache-Control",
                         headerFor(cacheClassFor("/deployment.json")).cstring)
      response.setHeader(cstring"Content-Type", cstring"application/json")
      response.send(($encodeDescriptor(hostDescriptor())).cstring))

    debugPrint codetracerExeDir & cstring"/frontend/styles/"
    server.use(cstring"/golden-layout", cached("/golden-layout", codetracerInstallDir & cstring"/libs/golden-layout"))
    server.use(cstring"/public/", cached("/public/", codetracerExeDir & cstring"/public/"))
    server.use(cstring"/styles/", cached("/styles/", codetracerExeDir & cstring"/frontend/styles/"))
    server.use(cstring"/frontend/styles/", cached("/frontend/styles/", codetracerExeDir & cstring"/frontend/styles/"))
    server.use(cstring"/node_modules", cached("/node_modules", codetracerInstallDir & cstring"/node_modules"))
    # The design system's typefaces. `styles/generated/fonts.styl` names them
    # relative to the stylesheet (`../../../../libs/codetracer-design-system/…`),
    # which the desktop resolves on the filesystem and a served page resolves
    # to `/libs/codetracer-design-system/…` — so that is the mount.
    # An empty install dir (a suite run from the checkout root) means the
    # checkout itself, so the root is then relative rather than `/libs/…`.
    let designSystemRoot =
      if codetracerInstallDir.len == 0: cstring"libs/codetracer-design-system"
      else: codetracerInstallDir & cstring"/libs/codetracer-design-system"
    server.use(cstring"/libs/codetracer-design-system",
               cached("/libs/codetracer-design-system", designSystemRoot))
    server.use(cstring"/ui.js", cached("/ui.js", userInterfacePath))
    # BIND THE ADDRESS, AND REPORT THE ONE ACTUALLY BOUND.
    #
    # `server.listen(port, cb)` with no host argument binds 0.0.0.0. This line
    # used to do that while printing "localhost", so the operator's only signal
    # was wrong in the direction that matters — `CLI/ct/host.md` requires
    # loopback by default because "a trace contains the recorded program's
    # memory and I/O", and a reader watching the log had no way to tell the
    # rule was not being kept.
    let bindAddress = data.startOptions.address
    var httpListener: JsObject
    httpListener = server.listen(data.startOptions.port, bindAddress.cstring, proc =
      # THE PORT IS READ BACK FROM THE SOCKET, not echoed from the argument.
      #
      # `--port 0` means "let the kernel choose" (`ct host`'s auto-assign, which
      # is what a substrate-allocated session uses), and then the argument is
      # `0` while the server is on some real port. Printing the argument would
      # tell a supervisor to connect to port 0.
      #
      # `CLI/ct/host.md` §High-Level Rules requires the URL on stdout "in a form
      # a supervising process can parse before the first client connects", so
      # the machine-readable line is emitted here — inside the listen callback,
      # which is the first moment the port is known and still before any client
      # can have connected.
      var boundPort = data.startOptions.port
      if not httpListener.isNil:
        let address = httpListener.address()
        if not address.isNil and not address[cstring"port"].isUndefined:
          boundPort = address[cstring"port"].to(int)
      data.startOptions.port = boundPort
      # The page's own origins follow from the bound port, so they are set
      # here; until now the socket has accepted no page origin at all.
      guard.setPagePort($bindAddress, boundPort)
      infoPrint fmt"listening on {bindAddress}:{boundPort}"
      # One line, one prefix, the whole URL. A supervisor greps for the prefix
      # and takes the rest; `infoPrint` above is for a person and carries a
      # timestamp and a source location that a parser would have to strip.
      # It is the one place the session secret is written, and only when this
      # process generated it (`sessionUrl`); the log lines never carry it.
      echo "CODETRACER_HOST_URL=" & guard.sessionUrl($bindAddress, boundPort)
      # An explicit flush: node buffers stdout when it is a pipe, which is
      # exactly the case a supervisor reads it through, and "before the first
      # client connects" is a promise about when the bytes ARRIVE.
      flushStdoutSync())

    debugPrint "in server"
    debugPrint data.startOptions

    let port = data.startOptions.port
    let backendSocketPort = data.startOptions.backendSocket.port

    var socketIoServerClass = (require("socket.io"))[cstring"Server"]
    # `allowRequest` runs on every handshake, before a session exists, for
    # the polling and the WebSocket transport alike: a refused request gets a
    # 403 and never reaches `connection`. Later requests of an admitted
    # session name its random `sid`, which only the admitted client holds.
    # `cors` answers the page's cross-port polling requests for the allowed
    # origins only.
    proc allowRequest(request: JsObject, callback: JsObject) =
      let reason = guard.refusal(request)
      if reason.len > 0:
        debugPrint "ct host: socket handshake refused: " & reason
      jsAsFunction[proc(message: cstring, success: bool): void](callback)(
        reason.cstring, reason.len == 0)
    proc corsOrigin(origin: JsObject, callback: JsObject) =
      let allowed = origin.isUndefined or guard.originAllowed($origin.to(cstring))
      jsAsFunction[proc(error: JsObject, allow: bool): void](callback)(
        jsNull, allowed)
    var socketIoServer = newSocketIoServer(socketIoServerClass, httpServer, js{
      allowRequest: allowRequest,
      cors: js{
        origin: corsOrigin,
        credentials: false
      }
    })
    var lastConnectionMs = nowMs()
    var lastActivityMs = lastConnectionMs
    var idleTimer: JsObject
    # EVERY CLIENT ITS OWN SESSION (`host_clients`, `CLI/ct/host.md`
    # "Sessions are isolated"): a client per id its page holds, each with its
    # own replay and its own server-owned session, kept across that page's
    # reloads for as long as the idle timeout, and released after it.
    serverClients = newHostClients(ipc, data.startOptions.idleTimeoutMs)
    serverClients.installRouting()

    proc resetActivity() =
      lastActivityMs = nowMs()

    proc resetConnection() =
      lastConnectionMs = nowMs()
      resetActivity()

    proc startIdleTimer(timeoutMs: int) =
      let interval = idleCheckInterval(timeoutMs)
      if interval < 0:
        return
      idleTimer = setInterval(proc =
        let now = nowMs()
        # A client gone for the timeout is released, before deciding whether
        # the server itself is idle: its replay is not kept for a page that is
        # not coming back.
        serverClients.releaseGone(now.float)
        let attached = serverClients.attachedCount > 0
        if shouldExitIdle(attached, lastConnectionMs, lastActivityMs, now, timeoutMs):
          let reason = if attached: "no activity" else: "no connection"
          infoPrint fmt"ct host idle timeout reached ({reason}); exiting."
          if attached:
            serverClients.disconnectAll(cstring"idle-timeout", cstring"Host timed out after inactivity.")
          nodeProcess.exit(0)
      , interval)

    startIdleTimer(data.startOptions.idleTimeoutMs)

    socketIOServer.on(cstring"connection") do (client: base_handlers.WebSocket):
      debugPrint "connection"
      resetConnection()

      client.onAny(proc() =
        resetActivity()
      )

      # Fallback activity hook until full heartbeats land: listen for generic activity ping.
      client.on(cstring"__activity__") do ():
        resetActivity()

      # The client this socket serves: the id its page holds, or a new one.
      discard serverClients.connect(client, handshakeClientId(client.toJs),
                                    handshakePageId(client.toJs))

      # THE FACADE ENDPOINT, on the SAME socket — §6.1.
      #
      # `UI-Bundle-And-Endpoints.md` §6.1 chose this connection rather than a
      # second listener, for a reason that is about capability and not about
      # tidiness: three facade operations take a callback and hand back a handle
      # (`fs.watch`, `process.start`, `shell.onWindowStateChanged`), and a
      # request/response endpoint can only be polled. The socket is also the
      # thing WD1a narrowed, so a second listener would be a second thing to
      # bind and narrow.
      #
      # ONE MESSAGE NAME, and the frame decides the rest. `handleFrame` reads
      # `kind` and answers `hello` with `welcome` and `call` with `reply`;
      # anything it does not own comes back as "" and is dropped rather than
      # raising, because this connection also carries the index IPC surface and
      # taking it down over someone else's message would end the session.
      client.on(FacadeChannel.cstring) do (frame: cstring):
        resetActivity()
        let answer = facadeEndpoint.handleFrame($frame)
        if answer.len > 0:
          client.emit(FacadeChannel.cstring, answer.cstring)

      client.on(cstring"disconnect") do ():
        debugPrint "socket disconnect"
        serverClients.disconnect(client)
        lastConnectionMs = nowMs()
        lastActivityMs = lastConnectionMs

      if not readyVar.isNil:
        debugPrint "call ready"
        discard jsAsFunction[proc: Future[void]](readyVar)()
        readyVar = undefined

    # The socket carries the whole index IPC surface — filesystem reads,
    # ripgrep, process spawns — so it binds the same address as the page
    # server rather than defaulting wider than the thing it serves.
    infoPrint fmt"socket.io listening on {data.startOptions.address}:{backendSocketPort}"
    httpServer.listen(backendSocketPort, data.startOptions.address.cstring)
