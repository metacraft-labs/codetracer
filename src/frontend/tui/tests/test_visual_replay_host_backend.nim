## The terminal's visual replay host passes the player the backend the
## environment names (`CODETRACER_CT_GFX_PLAYER_BACKEND`), as the desktop's
## host does.
##
## Without it the player runs `auto`, which on a host with no GPU driver cannot
## create its EGL context: on CI runners every frame request failed and the
## Video Player never showed "Frame 0 / 59" (TUI shard 8/8 of run 45951898448),
## while the same suites passed on a workstation whose GPU `auto` finds. The
## last case starts the host against a fake player that records its arguments,
## so it holds the host itself to passing them, not only `playerArgs`.

import std/[os, strutils, unittest]

import ../host/visual_replay_host

suite "the terminal visual replay host names the player's backend":
  test "a named backend is passed as --backend":
    let args = playerArgs("/rec/gfx_stream", 50123, "software")
    check args == @["--gfx-stream", "/rec/gfx_stream", "--http", "--port",
                    "50123", "--backend", "software"]

  test "no backend named: the player chooses":
    check "--backend" notin playerArgs("/rec/gfx_stream", 50123, "")

  test "the default is CODETRACER_CT_GFX_PLAYER_BACKEND":
    putEnv("CODETRACER_CT_GFX_PLAYER_BACKEND", "software")
    let args = playerArgs("/rec/gfx_stream", 50123)
    check args[^2 .. ^1] == @["--backend", "software"]
    delEnv("CODETRACER_CT_GFX_PLAYER_BACKEND")
    check "--backend" notin playerArgs("/rec/gfx_stream", 50123)

  test "startGraphics starts the player with that backend":
    let root = getTempDir() / ("ct-vr-backend-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "gfx_stream")
    writeFile(root / "gfx_stream" / "gfx_frames.idx", "")
    let argsFile = root / "player-args.txt"
    let fake = root / "fake_ct_gfx_player"
    # Records its arguments, one per line, and exits: the host then reports
    # that the player exited, which this case does not assert on.
    writeFile(fake, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > " &
      quoteShell(argsFile) & "\n")
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
    putEnv("CODETRACER_CT_GFX_PLAYER_CMD", fake)
    putEnv("CODETRACER_CT_GFX_PLAYER_BACKEND", "software")
    let host = startGraphics(root, readinessMs = 3_000)
    check not host.isNil
    var recorded: seq[string]
    for i in 0 ..< 30:
      if fileExists(argsFile) and readFile(argsFile).len > 0:
        recorded = readFile(argsFile).strip.splitLines
        break
      sleep(100)
    checkpoint("player arguments: " & recorded.join(" "))
    check recorded.len > 0
    check recorded[^2 .. ^1] == @["--backend", "software"]
    check (root / "gfx_stream") in recorded
    delEnv("CODETRACER_CT_GFX_PLAYER_BACKEND")
    delEnv("CODETRACER_CT_GFX_PLAYER_CMD")
    removeDir(root)
