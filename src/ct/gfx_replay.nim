## ``ct gfx-replay`` — visual replay player forwarder.
##
## Forwards to the internal ``ct_gfx_player`` binary.  Discovery
## order mirrors the conventions documented in
## ``docs/book/src/usage_guide/visual_recordings.md``:
##
## 1. ``CODETRACER_CT_GFX_PLAYER_CMD`` env var (absolute path).
## 2. Sibling of the running ``ct`` binary
##    (``<appDir>/ct_gfx_player``).
## 3. ``ct_gfx_player`` on ``PATH``.
##
## The CLI surface lives in ``codetracerconf.nim``; this module is
## the dispatcher that turns parsed flags back into a ``ct_gfx_player``
## command line and execs it.

import std/[ os, osproc, strutils, options ]

proc findCtGfxPlayerBinary*(): string =
  ## Resolve the visual-replay player binary.  Returns "" when no
  ## candidate is found so callers can surface a clear install hint.
  let envCmd = getEnv("CODETRACER_CT_GFX_PLAYER_CMD")
  if envCmd.len > 0:
    if fileExists(envCmd):
      return envCmd
    let resolved = findExe(envCmd)
    if resolved.len > 0:
      return resolved

  let siblingPath = getAppDir() / "ct_gfx_player"
  if fileExists(siblingPath):
    return siblingPath

  let onPath = findExe("ct_gfx_player")
  if onPath.len > 0:
    return onPath

  ""

proc gfxReplayCommand*(
    gfxStream: string,
    http: bool,
    port: Option[int],
    backend: string): int =
  ## Forward the parsed arguments to ``ct_gfx_player``.  Returns the
  ## child's exit code so the caller can propagate it.  Performs
  ## up-front validation of the required ``--gfx-stream`` argument
  ## so the user sees a clear error from ``ct`` rather than the
  ## player's own (terser) usage message.
  if gfxStream.len == 0:
    echo "error: ct gfx-replay requires --gfx-stream <dir>"
    return 1

  let player = findCtGfxPlayerBinary()
  if player.len == 0:
    echo "error: ct_gfx_player binary not found."
    echo "  Set CODETRACER_CT_GFX_PLAYER_CMD to its absolute path, "
    echo "  drop the binary next to ct, or install it on PATH."
    return 1

  var args: seq[string] = @[
    "--gfx-stream", gfxStream
  ]
  if http:
    args.add("--http")
  if port.isSome:
    args.add("--port")
    args.add($port.get)
  if backend.len > 0:
    args.add("--backend")
    args.add(backend)

  let process = startProcess(
    player,
    args = args,
    options = {poParentStreams, poUsePath})
  return waitForExit(process)
