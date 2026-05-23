## Headless tests for M2 visual replay player lifecycle orchestration.

import std/unittest

import isonim/core/async_compat
import vm_test_helpers

import ../../../../frontend/index/visual_replay_player

suite "Visual replay player lifecycle":
  test "pipeline command keeps trace path as argv data":
    let tracePath = "/tmp/trace dir/trace'; touch injected #.ct"
    let command = createVisualReplayPipelineCommand(
      tracePath,
      "/tmp/gfx stream",
      41237,
      "/opt/tools/ct mcr",
      "/opt/tools/ct gfx player")

    check command.ctMcr == "/opt/tools/ct mcr"
    check command.ctMcrArgs == @["extract-gfx", "-o", "/tmp/gfx stream", tracePath]
    check command.gfxPlayer == "/opt/tools/ct gfx player"
    check command.gfxPlayerArgs == @[
      "--gfx-stream", "/tmp/gfx stream", "--http", "--port", "41237"]

  test "pipeline command can pin the player backend":
    let command = createVisualReplayPipelineCommand(
      "/tmp/trace.ct",
      "/tmp/gfx",
      41237,
      "ct-mcr",
      "ct-gfx-player",
      "software")

    check command.gfxPlayerArgs == @[
      "--gfx-stream", "/tmp/gfx", "--http", "--port", "41237",
      "--backend", "software"]

  test "test_visual_player_lifecycle_ready_and_shutdown":
    var allocatedPorts: seq[int] = @[]
    var startedTracePath = ""
    var startedPort = 0
    var probeUrls: seq[string] = @[]
    var sleepCalls: seq[int] = @[]
    var terminated = false

    let deps = VisualReplayPlayerDeps(
      allocatePort: proc(): PlatformFuture[int] =
        allocatedPorts.add(41237)
        newCompletedFuture(41237),
      startProcess: proc(tracePath: string; port: int):
          PlatformFuture[VisualReplayPlayerProcess] =
        startedTracePath = tracePath
        startedPort = port
        newCompletedFuture(VisualReplayPlayerProcess(
          pid: 99,
          terminateProc: proc() = terminated = true,
          runningProc: proc(): bool = not terminated)),
      probeInfo: proc(url: string): PlatformFuture[bool] =
        probeUrls.add(url)
        newCompletedFuture(probeUrls.len >= 2),
      sleep: proc(ms: int): PlatformFuture[void] =
        sleepCalls.add(ms)
        newCompletedFuture())

    let lifecycle = createVisualReplayPlayerLifecycle(
      "/tmp/trace.ct",
      deps,
      readinessAttempts = 3,
      readinessDelayMs = 7)

    let result = waitForTest lifecycle.start(completedDepsOnly = true)

    check result.ok
    check result.url == "http://127.0.0.1:41237"
    check result.error == ""
    check allocatedPorts == @[41237]
    check startedTracePath == "/tmp/trace.ct"
    check startedPort == 41237
    check probeUrls == @[
      "http://127.0.0.1:41237/info",
      "http://127.0.0.1:41237/info"]
    check sleepCalls == @[7]
    check lifecycle.state == vrpReady
    check lifecycle.process.isRunning()

    registerVisualReplayPlayer(42, lifecycle)
    stopVisualReplayPlayer(42)

    check terminated
    check lifecycle.state == vrpStopped
    check lifecycle.process.isNil
