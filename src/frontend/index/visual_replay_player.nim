## Lifecycle orchestration for the MCR visual replay HTTP player.
##
## The production pipeline is:
##   ct-mcr extract-gfx -o <gfx_stream> trace.ct
##   ct-gfx-player --gfx-stream <gfx_stream> --http --port <port>
##
## Tests inject the port allocator, process starter, readiness probe, and
## sleeper so they never depend on real MCR/player binaries.

import std/[sequtils, strformat, strutils, tables]

import isonim/core/async_compat

when defined(js):
  import std/jsffi

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
    gfxStreamDir: string;
    port: int;
    ctMcr = "ct-mcr";
    gfxPlayer = "ct-gfx-player";
    gfxPlayerBackend = ""): VisualReplayPipelineCommand =
  var gfxPlayerArgs = @["--gfx-stream", gfxStreamDir, "--http", "--port", $port]
  if gfxPlayerBackend.strip.len > 0:
    gfxPlayerArgs.add(@["--backend", gfxPlayerBackend.strip])
  VisualReplayPipelineCommand(
    ctMcr: ctMcr,
    ctMcrArgs: @["extract-gfx", "-o", gfxStreamDir, tracePath],
    gfxPlayer: gfxPlayer,
    gfxPlayerArgs: gfxPlayerArgs)

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

proc startAsync(lifecycle: VisualReplayPlayerLifecycle):
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

when defined(js):
  proc requireCompleted[T](future: PlatformFuture[T]; label: string): T =
    if future.isSyncResolved:
      future.getSyncValue
    elif future.isSyncFailed:
      raise newException(CatchableError, future.getSyncError)
    else:
      raise newException(CatchableError,
        label & " returned an async Promise in completed-dependencies mode")

  proc requireCompleted(future: PlatformFuture[void]; label: string) =
    if future.isSyncResolved:
      return
    elif future.isSyncFailed:
      raise newException(CatchableError, future.getSyncError)
    else:
      raise newException(CatchableError,
        label & " returned an async Promise in completed-dependencies mode")

  proc startWithCompletedDeps(lifecycle: VisualReplayPlayerLifecycle):
      VisualReplayPlayerResult =
    if lifecycle.isNil:
      return VisualReplayPlayerResult(
        ok: false,
        error: "Visual replay player lifecycle is not initialized")

    lifecycle.state = vrpStarting
    lifecycle.error = ""

    try:
      lifecycle.port = lifecycle.deps.allocatePort().requireCompleted(
        "allocatePort")
      if lifecycle.port <= 0:
        return lifecycle.fail("Unable to allocate a visual replay player port.")

      lifecycle.url = fmt"http://127.0.0.1:{lifecycle.port}"
      lifecycle.process = lifecycle.deps.startProcess(
        lifecycle.tracePath, lifecycle.port).requireCompleted("startProcess")
      if lifecycle.process.isNil:
        return lifecycle.fail("Unable to start the visual replay player.")

      for attempt in 0 ..< lifecycle.readinessAttempts:
        if not lifecycle.process.isRunning():
          return lifecycle.fail(
            "Visual replay player exited before becoming ready at " &
            infoUrl(lifecycle.url))
        let ready = lifecycle.deps.probeInfo(infoUrl(lifecycle.url)).
          requireCompleted("probeInfo")
        if ready:
          lifecycle.state = vrpReady
          return VisualReplayPlayerResult(ok: true, url: lifecycle.url, error: "")
        if attempt < lifecycle.readinessAttempts - 1:
          lifecycle.deps.sleep(lifecycle.readinessDelayMs).
            requireCompleted("sleep")

      return lifecycle.fail(
        "Visual replay player did not become ready at " & infoUrl(lifecycle.url))
    except CatchableError as e:
      return lifecycle.fail(e.msg)

proc start*(lifecycle: VisualReplayPlayerLifecycle;
            completedDepsOnly = false): PlatformFuture[VisualReplayPlayerResult] =
  when defined(js):
    if completedDepsOnly:
      return newCompletedFuture(lifecycle.startWithCompletedDeps())
  lifecycle.startAsync()

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
  proc envOrDefault(name, fallback: cstring): cstring {.importjs: """
    ((function(name, fallback) {
      return (typeof process !== "undefined" &&
              process.env &&
              process.env[name] &&
              process.env[name].length > 0)
        ? process.env[name]
        : fallback;
    })(#, #))
  """.}

  proc setTimeoutJs(resolve: proc(); ms: int): int {.importjs: "setTimeout(#, #)".}

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
          "access-control-allow-methods": "GET, POST, OPTIONS",
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
        if (url.pathname === "/pixel-history") {
          const x = Number(url.searchParams.get("x") || 0);
          const y = Number(url.searchParams.get("y") || 0);
          const frame = Number(url.searchParams.get("frame") || 0);
          sendJson(res, {
            x,
            y,
            frame,
            modifications: [
              {
                geid: 210,
                draw_call_index: 1,
                fragment_index: 0,
                primitive_id: 12,
                pre_color: [0.04, 0.06, 0.12, 1.0],
                shader_output: [0.18, 0.48, 0.90, 1.0],
                post_color: [0.18, 0.48, 0.90, 1.0],
                pre_depth: 1.0,
                post_depth: 0.4,
                passed: true,
                failure_reason: "",
                testStatus: { depth: "pass", stencil: "pass", blend: "applied", cull: "pass" },
              },
              {
                geid: 220,
                draw_call_index: 2,
                fragment_index: 0,
                primitive_id: 18,
                pre_color: [0.18, 0.48, 0.90, 1.0],
                shader_output: [0.95, 0.36, 0.08, 1.0],
                post_color: [0.18, 0.48, 0.90, 1.0],
                pre_depth: 0.4,
                post_depth: 0.4,
                passed: false,
                failure_reason: "depth_failed",
                testStatus: { depth: "failed", stencil: "pass", blend: "unchanged", cull: "pass" },
              },
            ],
          });
          return;
        }
        if (url.pathname === "/shader-debug") {
          let raw = "";
          req.on("data", (chunk) => { raw += chunk; });
          req.on("end", () => {
            let body = {};
            try { body = raw ? JSON.parse(raw) : {}; } catch (_) { body = {}; }
            const x = Number(body.x || 0);
            const y = Number(body.y || 0);
            const frame = Number(body.frame || 0);
            const draw = Number(body.draw ?? body.draw_call_index ?? 1);
            const geid = Number(body.geid || (200 + draw * 10));
            sendJson(res, {
              stage: "fragment",
              entryPoint: "main",
              sourceLines: [
                String.fromCharCode(35) + "version 450",
                "layout(location = 0) in vec2 v_uv;",
                "layout(location = 0) out vec4 out_color;",
                "void main() {",
                "  vec4 base = vec4(v_uv, 0.25, 1.0);",
                "  out_color = base + vec4(0.10, 0.20, 0.00, 0.00);",
                "}",
              ],
              steps: [
                {
                  step: 0,
                  instruction: "OpLoad %v_uv",
                  line: 2,
                  variables: [
                    { name: "v_uv", type: "vec2", value: "[" + (x / 320).toFixed(3) + ", " + (y / 180).toFixed(3) + "]" },
                  ],
                  registers: [
                    { name: "%12", type: "ptr", value: "input.v_uv" },
                  ],
                },
                {
                  step: 1,
                  instruction: "OpCompositeConstruct %base",
                  line: 5,
                  variables: [
                    { name: "v_uv", type: "vec2", value: "[" + (x / 320).toFixed(3) + ", " + (y / 180).toFixed(3) + "]" },
                    { name: "base", type: "vec4", value: "[0.500, 0.500, 0.250, 1.000]" },
                  ],
                  registers: [
                    { name: "%18", type: "vec4", value: "base" },
                    { name: "%draw", type: "int", value: String(draw) },
                  ],
                },
                {
                  step: 2,
                  instruction: "OpStore %out_color",
                  line: 6,
                  variables: [
                    { name: "base", type: "vec4", value: "[0.500, 0.500, 0.250, 1.000]" },
                    { name: "out_color", type: "vec4", value: "[0.600, 0.700, 0.250, 1.000]" },
                  ],
                  registers: [
                    { name: "%out", type: "vec4", value: "rgba@GEID " + geid + " frame " + frame },
                  ],
                },
              ],
            });
          });
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

  proc startExtractedVisualReplayProcessJs(
      ctMcr, gfxPlayer, tracePath, backend: cstring; port: int):
      PlatformFuture[VisualReplayPlayerProcess] {.importjs: """
    (new Promise((resolve) => {
      const childProcess = require("child_process");
      const fs = require("fs");
      const os = require("os");
      const path = require("path");
      const ctMcrPath = String(#);
      const gfxPlayerPath = String(#);
      const tracePathString = String(#);
      const backendName = String(# || "");
      const portNumber = Number(#);
      const gfxStreamDir = fs.mkdtempSync(
        path.join(os.tmpdir(), "codetracer-visual-replay-")
      );
      let extractor = null;
      let player = null;
      let playerExited = false;
      let settled = false;

      function cleanupDir() {
        try { fs.rmSync(gfxStreamDir, { recursive: true, force: true }); } catch (_) {}
      }

      function killBoth() {
        try { if (extractor) extractor.kill(); } catch (_) {}
        try { if (player) player.kill(); } catch (_) {}
      }

      function fail(reason) {
        if (settled) return;
        settled = true;
        if (reason) {
          console.error("visual replay player start failed: " + reason);
        }
        killBoth();
        cleanupDir();
        resolve(null);
      }

      try {
        extractor = childProcess.spawn(
          ctMcrPath,
          ["extract-gfx", "-o", gfxStreamDir, tracePathString],
          { stdio: ["ignore", "ignore", "pipe"], windowsHide: true }
        );
      } catch (error) {
        fail(
          "could not spawn extractor " + ctMcrPath +
          " for trace " + tracePathString +
          ": " + (error && error.message ? error.message : String(error))
        );
        return;
      }

      let extractorErr = { value: "" };
      extractor.stderr && extractor.stderr.on("data", (chunk) => {
        extractorErr.value += chunk.toString();
      });
      extractor.on("error", (error) => fail("extractor error: " + error.message));
      extractor.on("exit", (code) => {
        if (settled) return;
        if (code !== 0) {
          fail("extractor exit " + code + ": " + extractorErr.value);
          return;
        }
        try {
          const playerArgs = [
            "--gfx-stream", gfxStreamDir,
            "--http",
            "--port", String(portNumber),
          ];
          if (backendName.trim().length > 0) {
            playerArgs.push("--backend", backendName.trim());
          }
          player = childProcess.spawn(
            gfxPlayerPath,
            playerArgs,
            { stdio: ["ignore", "ignore", "pipe"], windowsHide: true }
          );
        } catch (error) {
          fail(
            "could not spawn player " + gfxPlayerPath +
            ": " + (error && error.message ? error.message : String(error))
          );
          return;
        }
        let playerErr = { value: "" };
        player.stderr && player.stderr.on("data", (chunk) => {
          playerErr.value += chunk.toString();
        });
        player.on("error", (error) => fail("player error: " + error.message));
        player.on("exit", () => {
          playerExited = true;
          cleanupDir();
          if (!settled) fail("player exited before spawn settled: " + playerErr.value);
        });
        player.on("spawn", () => {
          if (settled) return;
          settled = true;
          const playerRef = player;
          resolve({
            pid: (playerRef && playerRef.pid) || 0,
            terminateProc: function() {
              killBoth();
              cleanupDir();
            },
            runningProc: function() {
              return !!playerRef && !playerExited && !playerRef.killed;
            },
          });
        });
      });
    }))
  """.}

  proc jsOn(target: JsObject; eventName: cstring; handler: proc()) {.
    importjs: "#.on(#, #)".}

  proc jsKill(target: JsObject): bool {.importjs: "#.kill()".}
  proc jsPid(target: JsObject): int {.
    importjs: "((function(child) { return (child && child.pid) || 0; })(#))".}
  proc jsKilled(target: JsObject): bool {.
    importjs: "((function(child) { return (child && child.killed) || false; })(#))".}

  proc fsExistsSync(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
  proc fsReaddirSync(path: cstring): seq[cstring] {.importjs: "require('fs').readdirSync(#)".}

  proc joinPath(left, right: string): string =
    if left.endsWith("/") or left.endsWith("\\"):
      left & right
    else:
      left & "/" & right

  proc findTraceContainerPath*(traceOutputFolder: string): string =
    let ctPath = joinPath(traceOutputFolder, "trace.ct")
    if fsExistsSync(cstring(ctPath)):
      ctPath
    else:
      let entries = fsReaddirSync(cstring(traceOutputFolder))
      for entry in entries:
        let candidateName = $entry
        if candidateName.endsWith(".ct"):
          let candidatePath = joinPath(traceOutputFolder, candidateName)
          if fsExistsSync(cstring(candidatePath)):
            return candidatePath
      traceOutputFolder

  proc visualReplayPipelineCommand(tracePath: string; gfxStreamDir: string; port: int):
      VisualReplayPipelineCommand =
    let ctMcr = $envOrDefault(cstring"CODETRACER_CT_MCR_CMD", cstring"ct-mcr")
    let gfxPlayer = $envOrDefault(
      cstring"CODETRACER_CT_GFX_PLAYER_CMD", cstring"ct-gfx-player")
    let gfxPlayerBackend = $envOrDefault(
      cstring"CODETRACER_CT_GFX_PLAYER_BACKEND", cstring"")
    createVisualReplayPipelineCommand(
      tracePath, gfxStreamDir, port, ctMcr, gfxPlayer, gfxPlayerBackend)

  proc defaultSleep(ms: int): PlatformFuture[void] =
    newPromise proc(resolve: proc()) =
      discard setTimeoutJs(resolve, ms)

  proc fakePlayerMode(): string =
    $envOrDefault(cstring"CODETRACER_VISUAL_REPLAY_FAKE_PLAYER", cstring"")

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

    let command = visualReplayPipelineCommand(tracePath, "", port)
    startExtractedVisualReplayProcessJs(
      cstring(command.ctMcr),
      cstring(command.gfxPlayer),
      cstring(tracePath),
      cstring($envOrDefault(cstring"CODETRACER_CT_GFX_PLAYER_BACKEND", cstring"")),
      port)

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
