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
      return newCompletedFuture(VisualReplayPlayerProcess(
        pid: 0,
        terminateProc: proc() = discard,
        runningProc: proc(): bool = true))

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
