## visual_replay_host.nim — a recording's graphics, for the pane server
## (Editor-Hosted-Front-Ends §E7 and Q2, HSF-E1).
##
## A recording whose folder carries a gfx stream has graphics: frames a
## visual-replay player re-renders (CodeTracer-TUI-Graphics.md §4, the frame
## viewer). This module is the native host's half of showing them in an
## editor: it finds the stream the way the desktop does
## (`visual_replay_layout.traceHasVisualReplayArtifacts`), starts the same
## player the desktop starts (`ct_gfx_player --gfx-stream <dir> --http
## --port <p>`, found as `ct gfx-replay` finds it), and reads frames from its
## HTTP endpoints — `/info` for the extent, `/frame?frame=N` (or `?draw=N`
## on a legacy stream) for a frame's RGBA8888 pixels (`X-Width` /
## `X-Height`) — which it encodes as PNG
## (`common/png.encodePng`) for an editor that declared the image medium.
##
## The player's own output never reaches the process's stdout: that stream is
## the editor's protocol.

import std/[httpclient, json, net, os, osproc, strutils, times]

import ../../../common/png
import ../../../ct/gfx_replay
import ../../viewmodel/viewmodels/visual_replay_layout

type
  GraphicsHost* = ref object
    ## One recording's player, and what was learned from it.
    streamDir*: string
    url*: string
    frameCount*: int
    width*, height*: int
    error*: string
      ## Why the graphics cannot be shown; "" when they can.
    selector*: string
      ## How a position is asked for: `frame` (a split stream, what the
      ## desktop's extractor writes) or `draw` (a legacy stream, which the
      ## player can only seek by draw call).
    process: Process

  RgbaFrame* = object
    width*, height*: int
    pixels*: string

proc gfxStreamDirOf*(folder: string): string =
  ## The gfx stream of the recording in `folder`: the folder itself, its
  ## `gfx_stream/`, or the first subfolder holding one — the places
  ## `traceHasVisualReplayArtifacts` looks. "" when it has none.
  let exists = proc(p: string): bool = fileExists(p) or dirExists(p)
  if directoryHasGfxStreamArtifacts(folder, exists):
    return folder
  if directoryHasGfxStreamArtifacts(folder / "gfx_stream", exists):
    return folder / "gfx_stream"
  if dirExists(folder):
    for kind, path in walkDir(folder):
      if kind in {pcDir, pcLinkToDir} and
         directoryHasGfxStreamArtifacts(path, exists):
        return path
  ""

proc freePort(): int =
  ## A loopback port nothing listens on now.
  let s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  int(s.getLocalAddr()[1])

proc getInfo(url: string): JsonNode =
  let client = newHttpClient(timeout = 2_000)
  defer: client.close()
  let resp = client.get(url & "/info")
  if not resp.code.is2xx:
    raise newException(IOError, "/info answered " & $resp.code)
  parseJson(resp.body)

proc startGraphics*(folder: string; readinessMs = 30_000): GraphicsHost =
  ## The player for the recording in `folder`, ready, or nil when the
  ## recording has no gfx stream. A recording that has one but cannot be
  ## shown (no player installed, a player that exits) answers a host whose
  ## `error` says why.
  let dir = gfxStreamDirOf(folder)
  if dir.len == 0:
    return nil
  result = GraphicsHost(streamDir: dir)
  let player = findCtGfxPlayerBinary()
  if player.len == 0:
    result.error = "the visual replay player (ct_gfx_player) is not " &
      "installed: set CODETRACER_CT_GFX_PLAYER_CMD, put it beside ct or on PATH"
    return
  let port = freePort()
  result.url = "http://127.0.0.1:" & $port
  # Through `sh` so the player's stdout and stderr go to /dev/null: the
  # pane server's stdout is the editor's protocol, and an undrained pipe
  # would stall the player.
  result.process = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" >/dev/null 2>&1", player,
             "--gfx-stream", dir, "--http", "--port", $port],
    options = {})
  let deadline = epochTime() + readinessMs.float / 1000.0
  while true:
    if not result.process.running:
      result.error = "the visual replay player exited before it answered"
      return
    var info: JsonNode = nil
    try:
      info = getInfo(result.url)
    except CatchableError:
      discard
    if not info.isNil:
      result.frameCount = info{"frameCount"}.getInt(info{"frames"}.getInt(0))
      result.width = info{"width"}.getInt(0)
      result.height = info{"height"}.getInt(0)
      # A split stream seeks by frame; a legacy one answers `?frame=` with a
      # 400 naming the split streams it lacks, and seeks by draw call.
      result.selector = "frame"
      try:
        let client = newHttpClient(timeout = 30_000)
        defer: client.close()
        if not client.get(result.url & "/frame?frame=0").code.is2xx:
          result.selector = "draw"
          let draws = info{"drawCallCount"}.getInt(0)
          if draws > 0:
            result.frameCount = draws
      except CatchableError as e:
        result.error = "the visual replay player did not answer a frame: " & e.msg
      return
    if epochTime() > deadline:
      result.error = "the visual replay player did not answer at " & result.url
      return
    os.sleep(100)

proc frameRgba*(g: GraphicsHost; frame: int): RgbaFrame =
  ## Frame `frame`'s pixels, as the player renders them.
  let client = newHttpClient(timeout = 30_000)
  defer: client.close()
  let resp = client.get(g.url & "/frame?" & g.selector & "=" & $frame)
  if not resp.code.is2xx:
    raise newException(IOError, "frame " & $frame & ": " & resp.body)
  result.width = parseInt(resp.headers.getOrDefault("X-Width"))
  result.height = parseInt(resp.headers.getOrDefault("X-Height"))
  result.pixels = resp.body
  if result.pixels.len != result.width * result.height * 4:
    raise newException(IOError, "frame " & $frame & ": " & $result.pixels.len &
      " bytes for " & $result.width & "x" & $result.height & " RGBA")
  if g.width == 0:
    g.width = result.width
    g.height = result.height

proc framePng*(g: GraphicsHost; frame: int): (RgbaFrame, string) =
  ## Frame `frame` and its PNG encoding.
  let f = g.frameRgba(frame)
  (f, encodePng(f.width, f.height,
                toOpenArrayByte(f.pixels, 0, f.pixels.len - 1)))

proc close*(g: GraphicsHost) =
  if g.isNil or g.process.isNil:
    return
  if g.process.running:
    g.process.terminate()
    discard g.process.waitForExit(2_000)
  g.process.close()
  g.process = nil
