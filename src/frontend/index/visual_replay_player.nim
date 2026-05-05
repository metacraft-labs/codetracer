## Lifecycle orchestration for the MCR visual replay HTTP player.
##
## The production pipeline is:
##   ct-mcr extract-gfx --stdout trace.ct | ct-gfx-player --http --port <port>
##
## Tests inject the port allocator, process starter, readiness probe, and
## sleeper so they never depend on real MCR/player binaries.

import std/[sequtils, strformat, strutils, tables]

import isonim/core/async_compat

when defined(js):
  import std/jsffi

  import ../lib/[electron_lib, jslib]

type
  VisualReplayPlayerState* = enum
    vrpStopped,
    vrpStarting,
    vrpReady,
    vrpFailed

  VisualReplayPlayerProcess* = ref object
    pid*: int
    terminateProc*: proc()
    runningProc*: proc(): bool

  VisualReplayPlayerResult* = object
    ok*: bool
    url*: string
    error*: string

  VisualReplayPipelineCommand* = object
    ctMcr*: string
    ctMcrArgs*: seq[string]
    gfxPlayer*: string
    gfxPlayerArgs*: seq[string]

  VisualReplayPortAllocator* = proc(): PlatformFuture[int]
  VisualReplayProcessStarter* =
    proc(tracePath: string; port: int): PlatformFuture[VisualReplayPlayerProcess]
  VisualReplayReadinessProbe* = proc(url: string): PlatformFuture[bool]
  VisualReplaySleeper* = proc(ms: int): PlatformFuture[void]

  VisualReplayPlayerDeps* = object
    allocatePort*: VisualReplayPortAllocator
    startProcess*: VisualReplayProcessStarter
    probeInfo*: VisualReplayReadinessProbe
    sleep*: VisualReplaySleeper

  VisualReplayPlayerLifecycle* = ref object
    tracePath*: string
    port*: int
    url*: string
    state*: VisualReplayPlayerState
    error*: string
    process*: VisualReplayPlayerProcess
    readinessAttempts*: int
    readinessDelayMs*: int
    deps*: VisualReplayPlayerDeps

var visualReplayPlayers*: Table[int, VisualReplayPlayerLifecycle] =
  initTable[int, VisualReplayPlayerLifecycle]()

proc infoUrl*(playerUrl: string): string =
  playerUrl.strip(chars = {'/'}) & "/info"

proc createVisualReplayPipelineCommand*(
    tracePath: string;
    port: int;
    ctMcr = "ct-mcr";
    gfxPlayer = "ct-gfx-player"): VisualReplayPipelineCommand =
  VisualReplayPipelineCommand(
    ctMcr: ctMcr,
    ctMcrArgs: @["extract-gfx", "--stdout", tracePath],
    gfxPlayer: gfxPlayer,
    gfxPlayerArgs: @["--http", "--port", $port])

proc terminate*(process: VisualReplayPlayerProcess) =
  if process.isNil or process.terminateProc.isNil:
    return
  process.terminateProc()

proc isRunning*(process: VisualReplayPlayerProcess): bool =
  if process.isNil or process.runningProc.isNil:
    return false
  process.runningProc()

proc shutdown*(lifecycle: VisualReplayPlayerLifecycle) =
  if lifecycle.isNil:
    return
  if not lifecycle.process.isNil:
    lifecycle.process.terminate()
    lifecycle.process = nil
  lifecycle.state = vrpStopped

proc fail(lifecycle: VisualReplayPlayerLifecycle; message: string):
    VisualReplayPlayerResult =
  lifecycle.error = message
  lifecycle.state = vrpFailed
  if not lifecycle.process.isNil:
    lifecycle.process.terminate()
    lifecycle.process = nil
  VisualReplayPlayerResult(ok: false, url: "", error: message)

proc start*(lifecycle: VisualReplayPlayerLifecycle):
    Future[VisualReplayPlayerResult] {.async.} =
  if lifecycle.isNil:
    return VisualReplayPlayerResult(
      ok: false,
      error: "Visual replay player lifecycle is not initialized")

  lifecycle.state = vrpStarting
  lifecycle.error = ""

  try:
    lifecycle.port = await lifecycle.deps.allocatePort()
    if lifecycle.port <= 0:
      return lifecycle.fail("Unable to allocate a visual replay player port.")

    lifecycle.url = fmt"http://127.0.0.1:{lifecycle.port}"
    lifecycle.process = await lifecycle.deps.startProcess(
      lifecycle.tracePath, lifecycle.port)
    if lifecycle.process.isNil:
      return lifecycle.fail("Unable to start the visual replay player.")

    for attempt in 0 ..< lifecycle.readinessAttempts:
      if not lifecycle.process.isRunning():
        return lifecycle.fail(
          "Visual replay player exited before becoming ready at " &
          infoUrl(lifecycle.url))
      let ready = await lifecycle.deps.probeInfo(infoUrl(lifecycle.url))
      if ready:
        lifecycle.state = vrpReady
        return VisualReplayPlayerResult(ok: true, url: lifecycle.url, error: "")
      if attempt < lifecycle.readinessAttempts - 1:
        await lifecycle.deps.sleep(lifecycle.readinessDelayMs)

    return lifecycle.fail(
      "Visual replay player did not become ready at " & infoUrl(lifecycle.url))
  except CatchableError as e:
    return lifecycle.fail(e.msg)

proc createVisualReplayPlayerLifecycle*(
    tracePath: string;
    deps: VisualReplayPlayerDeps;
    readinessAttempts = 50;
    readinessDelayMs = 100): VisualReplayPlayerLifecycle =
  VisualReplayPlayerLifecycle(
    tracePath: tracePath,
    state: vrpStopped,
    readinessAttempts: readinessAttempts,
    readinessDelayMs: readinessDelayMs,
    deps: deps)

when defined(js):
  proc hasEnv(name: cstring): bool =
    nodeProcess.env.hasKey(name) and nodeProcess.env[name].len > 0

  proc envOrDefault(name, fallback: cstring): cstring =
    if hasEnv(name): nodeProcess.env[name] else: fallback

  proc allocateTcpPortJs(): PlatformFuture[int] {.importjs: """
    (new Promise((resolve) => {
      const net = require("net");
      const server = net.createServer();
      server.on("error", () => resolve(0));
      server.listen(0, "127.0.0.1", () => {
        const address = server.address();
        const port = address && address.port ? address.port : 0;
        server.close(() => resolve(port));
      });
    }))
  """.}

  proc fetchOkJs(url: cstring): PlatformFuture[bool] {.importjs: """
    ((async function(url) {
      try {
        const response = await fetch(url);
        return !!response && response.ok;
      } catch (_) {
        return false;
      }
    })(#))
  """.}

  proc startFakeVisualReplayHttpServer(port: int):
      PlatformFuture[VisualReplayPlayerProcess] {.importjs: """
    (new Promise((resolve) => {
      const http = require("http");

      function corsHeaders(contentType) {
        return {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET, OPTIONS",
          "access-control-allow-headers": "content-type",
          "content-type": contentType,
        };
      }

      function sendJson(res, value) {
        res.writeHead(200, corsHeaders("application/json"));
        res.end(JSON.stringify(value));
      }

      function frameSvg(geid, frame) {
        const fill = geid % 2 === 0 ? "%232c7be5" : "%23d9730d";
        const accent = geid % 3 === 0 ? "%23f4d35e" : "%234ade80";
        return "data:image/svg+xml;charset=utf-8," +
          "<svg xmlns='http://www.w3.org/2000/svg' width='320' height='180' viewBox='0 0 320 180'>" +
          "<rect width='320' height='180' fill='%230b1020'/>" +
          "<rect x='24' y='22' width='272' height='136' fill='" + fill + "'/>" +
          "<circle cx='" + (72 + (geid % 160)) + "' cy='88' r='42' fill='" + accent + "'/>" +
          "<text x='44' y='142' fill='%23ffffff' font-size='22'>GEID " + geid + " frame " + frame + "</text>" +
          "</svg>";
      }

      const server = http.createServer((req, res) => {
        const url = new URL(req.url || "/", "http://127.0.0.1");
        if (req.method === "OPTIONS") {
          res.writeHead(204, corsHeaders("text/plain"));
          res.end();
          return;
        }
        if (url.pathname === "/info") {
          sendJson(res, { frameCount: 4, width: 320, height: 180 });
          return;
        }
        if (url.pathname === "/draw-calls") {
          sendJson(res, [
            { index: 0, geid: 200, name: "glClear", pipeline: "Framebuffer clear" },
            { index: 1, geid: 210, name: "glDrawElements", pipeline: "Mesh pass" },
            { index: 2, geid: 220, name: "glDrawArrays", pipeline: "Overlay pass" },
          ]);
          return;
        }
        if (url.pathname === "/frame") {
          const hasDraw = url.searchParams.has("draw");
          const hasFrame = url.searchParams.has("frame");
          const hasGeid = url.searchParams.has("geid");
          const draw = hasDraw ? Number(url.searchParams.get("draw")) : NaN;
          const frameParam = hasFrame ? Number(url.searchParams.get("frame")) : NaN;
          const geidParam = hasGeid ? Number(url.searchParams.get("geid")) : NaN;
          const geid = hasDraw ? 200 + draw * 10 :
            (Number.isFinite(geidParam) ? geidParam :
              (hasFrame ? 120 + frameParam * 10 : 120));
          const frame = hasDraw ? draw :
            (hasFrame ? frameParam : geid % 4);
          sendJson(res, {
            imageSrc: frameSvg(geid, frame),
            geid,
            frame,
            width: 320,
            height: 180,
          });
          return;
        }
        res.writeHead(404, corsHeaders("text/plain"));
        res.end("not found");
      });

      server.on("error", () => resolve(null));
      server.listen(#, "127.0.0.1", () => {
        resolve({
          pid: 0,
          terminateProc: function() { server.close(); },
          runningProc: function() { return server.listening; },
        });
      });
    }))
  """.}

  proc spawnExtractorJs(command, tracePath: cstring): JsObject {.importjs: """
    require("child_process").spawn(
      #,
      ["extract-gfx", "--stdout", #],
      { stdio: ["ignore", "pipe", "ignore"], windowsHide: true })
  """.}

  proc spawnPlayerJs(command: cstring; port: int): JsObject {.importjs: """
    require("child_process").spawn(
      #,
      ["--http", "--port", String(#)],
      { stdio: ["pipe", "ignore", "ignore"], windowsHide: true })
  """.}

  proc pipeProcessOutputToInput(source, target: JsObject) {.importjs: """
    (function(source, target) {
      if (source && target && source.stdout && target.stdin) {
        source.stdout.pipe(target.stdin);
      }
    })(#, #);
  """.}

  proc jsOn(target: JsObject; eventName: cstring; handler: proc()) {.
    importjs: "#.on(#, #)".}

  proc jsKill(target: JsObject): bool {.importjs: "#.kill()".}
  proc jsPid(target: JsObject): int {.
    importjs: "((function(child) { return (child && child.pid) || 0; })(#))".}
  proc jsKilled(target: JsObject): bool {.
    importjs: "((function(child) { return (child && child.killed) || false; })(#))".}

  proc joinPath(left, right: string): string =
    if left.endsWith("/") or left.endsWith("\\"):
      left & right
    else:
      left & "/" & right

  proc findTraceContainerPath*(traceOutputFolder: string): string =
    let ctPath = joinPath(traceOutputFolder, "trace.ct")
    if fs.existsSync(cstring(ctPath)):
      ctPath
    else:
      traceOutputFolder

  proc visualReplayPipelineCommand(tracePath: string; port: int):
      VisualReplayPipelineCommand =
    let ctMcr = $envOrDefault(cstring"CODETRACER_CT_MCR_CMD", cstring"ct-mcr")
    let gfxPlayer = $envOrDefault(
      cstring"CODETRACER_CT_GFX_PLAYER_CMD", cstring"ct-gfx-player")
    createVisualReplayPipelineCommand(tracePath, port, ctMcr, gfxPlayer)

  proc defaultSleep(ms: int): PlatformFuture[void] =
    newPromise proc(resolve: proc()) =
      discard windowSetTimeout(resolve, ms)

  proc fakePlayerMode(): string =
    if hasEnv(cstring"CODETRACER_VISUAL_REPLAY_FAKE_PLAYER"):
      $nodeProcess.env[cstring"CODETRACER_VISUAL_REPLAY_FAKE_PLAYER"]
    else:
      ""

  proc defaultAllocatePort*(): PlatformFuture[int] =
    allocateTcpPortJs()

  proc defaultProbeInfo*(url: string): PlatformFuture[bool] =
    if fakePlayerMode() == "ready":
      return newCompletedFuture(true)
    fetchOkJs(cstring(url))

  proc defaultStartProcess*(tracePath: string; port: int):
      PlatformFuture[VisualReplayPlayerProcess] =
    let mode = fakePlayerMode()
    if mode == "fail":
      return newCompletedFuture[VisualReplayPlayerProcess](nil)
    if mode == "ready":
      return startFakeVisualReplayHttpServer(port)

    let command = visualReplayPipelineCommand(tracePath, port)
    newPromise proc(resolve: proc(process: VisualReplayPlayerProcess)) =
      var settled = false
      var extractorSpawned = false
      var playerSpawned = false
      var playerExited = false
      let extractor = spawnExtractorJs(
        cstring(command.ctMcr), cstring(command.ctMcrArgs[2]))
      let player = spawnPlayerJs(cstring(command.gfxPlayer), port)

      proc killBoth() =
        discard jsKill(extractor)
        discard jsKill(player)

      proc maybeResolveReady() =
        if settled:
          return
        if not extractorSpawned or not playerSpawned:
          return
        settled = true
        let extractorRef = extractor
        let playerRef = player
        resolve(VisualReplayPlayerProcess(
          pid: jsPid(playerRef),
          terminateProc: proc() =
            discard jsKill(extractorRef)
            discard jsKill(playerRef),
          runningProc: proc(): bool =
            not playerExited and not jsKilled(playerRef)))

      pipeProcessOutputToInput(extractor, player)
      jsOn(extractor, cstring"spawn", proc() =
        extractorSpawned = true
        maybeResolveReady())
      jsOn(player, cstring"spawn", proc() =
        playerSpawned = true
        maybeResolveReady())
      jsOn(extractor, cstring"error", proc() =
        if settled:
          return
        settled = true
        killBoth()
        resolve(nil))
      jsOn(player, cstring"error", proc() =
        if settled:
          return
        settled = true
        killBoth()
        resolve(nil))
      jsOn(player, cstring"exit", proc() =
        playerExited = true
        if settled:
          return
        settled = true
        killBoth()
        resolve(nil))

  proc defaultVisualReplayPlayerDeps*(): VisualReplayPlayerDeps =
    VisualReplayPlayerDeps(
      allocatePort: defaultAllocatePort,
      startProcess: defaultStartProcess,
      probeInfo: defaultProbeInfo,
      sleep: defaultSleep)

proc registerVisualReplayPlayer*(replayId: int;
                                  lifecycle: VisualReplayPlayerLifecycle) =
  if replayId < 0 or lifecycle.isNil:
    return
  visualReplayPlayers[replayId] = lifecycle

proc stopVisualReplayPlayer*(replayId: int) =
  if replayId notin visualReplayPlayers:
    return
  visualReplayPlayers[replayId].shutdown()
  visualReplayPlayers.del(replayId)

proc stopAllVisualReplayPlayers*() =
  for replayId in toSeq(visualReplayPlayers.keys):
    stopVisualReplayPlayer(replayId)
