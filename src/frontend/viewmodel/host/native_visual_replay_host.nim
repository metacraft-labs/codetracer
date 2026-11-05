## viewmodel/host/native_visual_replay_host.nim — the Visual Replay panes'
## PRODUCER on the terminal and the GPUI window (Visual-Replay.md §
## Activation; CodeTracer-TUI-Graphics.md §4).
##
## The desktop starts a player for a recording that carries graphics
## (`index/visual_replay_player`: `ct-mcr extract-gfx` when the stream is
## still inside the container, then `ct_gfx_player --gfx-stream <dir> --http
## --port <p>`) and hands its panes an HTTP `VisualReplayClient`. Nothing in
## a native host did either, so the terminal's frame viewer had no frame and
## GPUI had no pane at all. This module is that half for both native hosts:
##
##   * **the stream** — found where the desktop looks
##     (`visual_replay_layout.traceHasVisualReplayArtifacts`: the folder, its
##     `gfx_stream/`, a subfolder), or extracted from the container as the
##     desktop extracts it;
##   * **the player** — the same binary, found as `ct gfx-replay` finds it,
##     its output kept off the host's stdout (the terminal's screen, the pane
##     server's protocol);
##   * **the client** — `VisualReplayClient` over HTTP, answering on a WORKER
##     THREAD so a frame the player takes long to render never stalls the
##     host's input. A host calls `pump` from its idle tick: the answers that
##     arrived complete their futures, and the panes' ViewModels apply them
##     when the platform's callbacks drain. Frames arrive as PIXELS
##     (`VisualReplayFrame.pixels`, RGBA8888), which the terminal's cell tiers
##     and the GPUI window draw.

import std/[httpclient, json, net, options, os, osproc, posix, strutils,
            tables, times]

import isonim/core/async_compat
import std/asyncdispatch

import ../store/replay_data_store
import ../viewmodels/visual_replay_client
import ../viewmodels/visual_replay_layout
import ../viewmodels/visual_replay_panes_vm
from ../../../ct/gfx_replay import findCtGfxPlayerBinary

export visual_replay_panes_vm

type
  HttpJobKind = enum
    hjGet
    hjPost
    hjStop

  HttpJob = object
    kind: HttpJobKind
    id: int
    url: string
    body: string

  HttpAnswer = object
    id: int
    ok: bool
    status: int
    body: string
    headers: seq[(string, string)]
    error: string

  HttpChannels = object
    jobs: Channel[HttpJob]
    answers: Channel[HttpAnswer]
    wakeWrite: cint

  PendingKind = enum
    pkInfo
    pkFrame
    pkDrawCalls
    pkPixelHistory
    pkShaderDebug

  Pending = object
    case kind: PendingKind
    of pkInfo: info: Future[VisualReplayInfo]
    of pkFrame:
      frame: Future[VisualReplayFrame]
      askedFrame: int
    of pkDrawCalls: calls: Future[seq[VisualReplayDrawCall]]
    of pkPixelHistory: history: Future[seq[VisualReplayPixelHistoryEntry]]
    of pkShaderDebug: shader: Future[VisualReplayShaderDebugInfo]

  NativeVisualReplay* = ref object
    ## One recording's player and the client the panes ask through.
    folder*: string
      ## The recording's folder.
    streamDir*: string
      ## The gfx stream the player reads; "" when the recording has none.
    url*: string
      ## The player's base URL; "" when it is not running.
    error*: string
      ## Why the graphics cannot be shown; "" when they can.
    client*: VisualReplayClient
    process: Process
    extractedDir: string
      ## A stream this host extracted (removed on `close`).
    chans: ptr HttpChannels
    thread: Thread[ptr HttpChannels]
    running: bool
    nextId: int
    pending: Table[int, Pending]

const
  PlayerReadinessMs* = 30_000
    ## How long a starting player is given to answer `/info` — the desktop's
    ## readiness budget.
  RequestTimeoutMs = 120_000
    ## One request's budget. A software-GL player rendering a pixel history
    ## replays every draw call of the recording, which takes seconds.

# ---------------------------------------------------------------------------
# The stream
# ---------------------------------------------------------------------------

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

proc traceContainerOf*(folder: string): string =
  ## The `.ct` container in `folder` (the desktop's `findTraceContainerPath`):
  ## `trace.ct` first, else the first `*.ct`. "" for none.
  if fileExists(folder / "trace.ct"):
    return folder / "trace.ct"
  if dirExists(folder):
    for kind, path in walkDir(folder):
      if kind in {pcFile, pcLinkToFile} and path.endsWith(".ct"):
        return path
  ""

proc recordingHasGraphics*(folder: string): bool =
  ## Whether the recording in `folder` carries graphics — the desktop's
  ## activation test (`detectVisualReplayAvailability`): an extracted stream,
  ## or a container whose metadata advertises one.
  detectVisualReplayAvailability(
    folder,
    proc(p: string): bool = fileExists(p) or dirExists(p),
    proc(p: string): string = readFile(p),
    proc(p: string): seq[string] =
      for _, entry in walkDir(p, relative = true):
        result.add entry)

proc findCtMcr(): string =
  ## The recorder that extracts a container's stream, as the desktop finds
  ## it (`CODETRACER_CT_MCR_CMD`, else `ct-mcr` on PATH).
  let env = getEnv("CODETRACER_CT_MCR_CMD")
  if env.len > 0:
    if fileExists(env): return env
    let found = findExe(env)
    if found.len > 0: return found
  findExe("ct-mcr")

# ---------------------------------------------------------------------------
# The worker
# ---------------------------------------------------------------------------

proc httpLoop(ch: ptr HttpChannels) {.thread.} =
  {.cast(gcsafe).}:
    let client = newHttpClient(timeout = RequestTimeoutMs)
    defer: client.close()
    while true:
      let job = ch.jobs.recv()
      if job.kind == hjStop:
        break
      var answer = HttpAnswer(id: job.id)
      try:
        let resp =
          if job.kind == hjPost:
            client.request(job.url, httpMethod = HttpPost, body = job.body,
                           headers = newHttpHeaders(
                             {"Content-Type": "application/json"}))
          else:
            client.get(job.url)
        answer.status = int(resp.code)
        answer.ok = resp.code.is2xx
        answer.body = resp.body
        for k, v in resp.headers:
          answer.headers.add (k.toLowerAscii, v)
      except CatchableError as e:
        answer.ok = false
        answer.error = e.msg
      ch.answers.send(answer)
      if ch.wakeWrite >= 0:
        var one = 'v'
        discard posix.write(ch.wakeWrite, addr one, 1)

proc submit(h: NativeVisualReplay; kind: HttpJobKind; url: string;
            body = ""): int =
  inc h.nextId
  result = h.nextId
  h.chans.jobs.send(HttpJob(kind: kind, id: result, url: url, body: body))

proc header(a: HttpAnswer; name: string): string =
  for (k, v) in a.headers:
    if k == name: return v
  ""

proc failure(a: HttpAnswer): string =
  if a.error.len > 0: a.error
  else:
    var why = a.body
    try:
      let j = parseJson(a.body)
      if j.kind == JObject and j.hasKey("error"):
        why = j["error"].getStr(a.body)
    except CatchableError:
      discard
    "the visual replay player answered " & $a.status & ": " & why

proc headerInt(a: HttpAnswer; name: string; default: int): int =
  let v = a.header(name)
  if v.len == 0: return default
  try: parseInt(v) except ValueError: default

proc frameOf(a: HttpAnswer; askedFrame: int): VisualReplayFrame =
  ## A `/frame` answer: RGBA8888 bytes with the image's size and the
  ## framebuffer's in the headers (MCR-Visual-Replay.md, `GET /frame`).
  result.width = a.headerInt("x-width", 0)
  result.height = a.headerInt("x-height", 0)
  result.sourceWidth = a.headerInt("x-source-width", result.width)
  result.sourceHeight = a.headerInt("x-source-height", result.height)
  result.drawIndex = a.headerInt("x-draw", -1)
  result.frameDrawStart = a.headerInt("x-frame-draw-start", -1)
  result.frameDrawCount = a.headerInt("x-frame-draw-count", 0)
  let f = a.headerInt("x-frame", askedFrame)
  if f >= 0:
    result.frame = some(f)
  if result.width <= 0 or result.height <= 0 or
     a.body.len < result.width * result.height * 4:
    raise newException(IOError,
      "the visual replay player answered a frame of " & $a.body.len &
      " bytes for " & $result.width & "x" & $result.height & " RGBA")
  let rowBytes = result.width * 4
  if a.header("x-row-order") == "bottom-up":
    # The framebuffer's rows as `glReadPixels` returns them: the image is
    # drawn top row first, so they are flipped (the desktop's client does the
    # same), and a picked pixel's `y` counts from the top as `/pixel-history`
    # takes it.
    result.pixels = newString(result.height * rowBytes)
    for row in 0 ..< result.height:
      copyMem(addr result.pixels[row * rowBytes],
              unsafeAddr a.body[(result.height - 1 - row) * rowBytes], rowBytes)
  else:
    result.pixels = a.body[0 ..< result.height * rowBytes]

proc settle(h: NativeVisualReplay; a: HttpAnswer) =
  ## Complete the future `a` answers.
  if a.id notin h.pending:
    return
  let p = h.pending[a.id]
  h.pending.del a.id
  template fail(fut: untyped) =
    fut.fail(newException(CatchableError, a.failure))
  try:
    case p.kind
    of pkInfo:
      if not a.ok: fail(p.info)
      else: p.info.complete(infoFromJson(parseJson(a.body)))
    of pkFrame:
      if not a.ok: fail(p.frame)
      else: p.frame.complete(frameOf(a, p.askedFrame))
    of pkDrawCalls:
      if not a.ok: fail(p.calls)
      else:
        var calls: seq[VisualReplayDrawCall] = @[]
        for item in parseJson(a.body).items:
          calls.add drawCallFromJson(item)
        p.calls.complete(calls)
    of pkPixelHistory:
      if not a.ok: fail(p.history)
      else:
        let node = parseJson(a.body)
        let items =
          if node.kind == JArray: node
          elif node.hasKey("modifications"): node["modifications"]
          elif node.hasKey("entries"): node["entries"]
          else: newJArray()
        var entries: seq[VisualReplayPixelHistoryEntry] = @[]
        for item in items.items:
          entries.add pixelHistoryEntryFromJson(item)
        p.history.complete(entries)
    of pkShaderDebug:
      if not a.ok: fail(p.shader)
      else: p.shader.complete(shaderDebugInfoFromJson(parseJson(a.body)))
  except CatchableError as e:
    let err = newException(CatchableError, e.msg)
    case p.kind
    of pkInfo: (if not p.info.finished: p.info.fail(err))
    of pkFrame: (if not p.frame.finished: p.frame.fail(err))
    of pkDrawCalls: (if not p.calls.finished: p.calls.fail(err))
    of pkPixelHistory: (if not p.history.finished: p.history.fail(err))
    of pkShaderDebug: (if not p.shader.finished: p.shader.fail(err))

proc pump*(h: NativeVisualReplay): bool =
  ## Apply every answer that has arrived, without blocking: their futures
  ## complete, and the ViewModels see them when the platform's callbacks
  ## drain (`drainPlatformCallbacks`). Whether anything arrived.
  if h.isNil or not h.running:
    return false
  while true:
    let (got, a) = h.chans.answers.tryRecv()
    if not got: break
    h.settle(a)
    result = true
  if result:
    drainPlatformCallbacks()

proc busy*(h: NativeVisualReplay): bool =
  ## A request is waiting for its answer.
  not h.isNil and h.pending.len > 0

proc settleAll*(h: NativeVisualReplay; timeoutMs = RequestTimeoutMs): bool =
  ## Wait until every request asked so far is answered and applied — a
  ## script's or a test's "the panes have caught up". False on timeout.
  if h.isNil or not h.running:
    return true
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while true:
    discard h.pump()
    drainPlatformCallbacks()
    if h.pending.len == 0:
      # An answer applied may have asked for more (a frame asks for its
      # draw calls; a coalesced scrub asks for the latest frame).
      discard h.pump()
      if h.pending.len == 0:
        return true
    if epochTime() > deadline:
      return false
    let (got, a) = h.chans.answers.tryRecv()
    if got:
      h.settle(a)
      drainPlatformCallbacks()
    else:
      os.sleep(5)

# ---------------------------------------------------------------------------
# The client
# ---------------------------------------------------------------------------

proc newHttpVisualReplayClient(h: NativeVisualReplay): VisualReplayClient =
  ## The panes' client over this host's worker.
  let base = normalizedPlayerUrl(h.url)
  var client: VisualReplayClient
  proc askFrame(url: string; askedFrame: int): Future[VisualReplayFrame] =
    result = newFuture[VisualReplayFrame]("visual replay frame")
    let id = h.submit(hjGet, client.sizedFrameUrl(url))
    h.pending[id] = Pending(kind: pkFrame, frame: result,
                            askedFrame: askedFrame)
  client = VisualReplayClient(
    playerUrl: base,
    getInfoProc: proc(): Future[VisualReplayInfo] =
      result = newFuture[VisualReplayInfo]("visual replay info")
      h.pending[h.submit(hjGet, infoUrl(base))] =
        Pending(kind: pkInfo, info: result),
    getFrameByGeidProc: proc(geid: uint64): Future[VisualReplayFrame] =
      askFrame(frameByGeidUrl(base, geid), -1),
    getFrameByFrameProc: proc(frame: int): Future[VisualReplayFrame] =
      askFrame(frameByFrameUrl(base, frame), frame),
    getFrameByDrawProc: proc(draw: int): Future[VisualReplayFrame] =
      askFrame(frameByDrawUrl(base, draw), -1),
    getFrameByFrameDrawProc: proc(frame, draw: int): Future[VisualReplayFrame] =
      askFrame(frameByFrameDrawUrl(base, frame, draw), frame),
    getDrawCallsProc: proc(frame: int): Future[seq[VisualReplayDrawCall]] =
      result = newFuture[seq[VisualReplayDrawCall]]("visual replay draws")
      h.pending[h.submit(hjGet, drawCallsUrl(base, frame))] =
        Pending(kind: pkDrawCalls, calls: result),
    getPixelHistoryProc: proc(x, y, frame: int):
        Future[seq[VisualReplayPixelHistoryEntry]] =
      result = newFuture[seq[VisualReplayPixelHistoryEntry]](
        "visual replay pixel history")
      h.pending[h.submit(hjPost, pixelHistoryUrl(base, x, y, frame),
                         $pixelHistoryRequestToJson(x, y, frame))] =
        Pending(kind: pkPixelHistory, history: result),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        Future[VisualReplayShaderDebugInfo] =
      result = newFuture[VisualReplayShaderDebugInfo]("visual replay shader")
      h.pending[h.submit(hjPost, shaderDebugUrl(base),
                         $shaderDebugRequestToJson(request))] =
        Pending(kind: pkShaderDebug, shader: result))
  client

# ---------------------------------------------------------------------------
# The player
# ---------------------------------------------------------------------------

proc freePort(): int =
  let s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  int(s.getLocalAddr()[1])

proc quietProcess(exe: string; args: seq[string]): Process =
  ## `exe` with its stdout and stderr on /dev/null: a native host's stdout is
  ## its screen (or the pane server's protocol), and an undrained pipe would
  ## stall the child.
  startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" >/dev/null 2>&1", exe] & args,
    options = {})

proc extractStream(h: NativeVisualReplay; container: string): string =
  ## The desktop's extraction (`ct-mcr extract-gfx --ctfs-visual-streams -o
  ## <dir> <trace.ct>`), into a directory this host owns.
  let mcr = findCtMcr()
  if mcr.len == 0:
    h.error = "the recording's graphics are inside its container and the " &
      "recorder that extracts them (ct-mcr) is not installed: set " &
      "CODETRACER_CT_MCR_CMD or put ct-mcr on PATH"
    return ""
  let root = getTempDir() / ("ct-visual-replay-" & $getCurrentProcessId() &
                             "-" & $epochTime().int64)
  createDir(root)
  h.extractedDir = root
  let dir = root / "gfx_stream"
  let (output, code) = execCmdEx(quoteShellCommand(
    [mcr, "extract-gfx", "--ctfs-visual-streams", "-o", dir, container]))
  if code != 0 or gfxStreamDirOf(root).len == 0:
    h.error = "extracting the recording's graphics failed (" & $code & "): " &
      output.strip
    return ""
  dir

proc startVisualReplay*(folder: string; wakeWrite: cint = -1;
                        readinessMs = PlayerReadinessMs): NativeVisualReplay =
  ## The player for the recording in `folder`, or nil when the recording
  ## carries no graphics. One that does but cannot be shown (no player
  ## installed, a player that exits, an extraction that fails) answers a
  ## host whose `error` says why — the panes are still added and say it.
  ## `wakeWrite` is written a byte per answer so a host's poll loop wakes
  ## (-1 for none).
  var dir = gfxStreamDirOf(folder)
  if dir.len == 0 and not recordingHasGraphics(folder):
    return nil
  result = NativeVisualReplay(folder: folder)
  if dir.len == 0:
    let container = traceContainerOf(folder)
    if container.len == 0:
      result.error = "the recording advertises graphics but has no " &
        "container to extract them from"
      return
    dir = result.extractStream(container)
    if dir.len == 0:
      return
  result.streamDir = dir
  let player = findCtGfxPlayerBinary()
  if player.len == 0:
    result.error = "the visual replay player (ct_gfx_player) is not " &
      "installed: set CODETRACER_CT_GFX_PLAYER_CMD, put it beside ct or on " &
      "PATH"
    return
  let port = freePort()
  result.url = "http://127.0.0.1:" & $port
  result.process = quietProcess(player,
    @["--gfx-stream", dir, "--http", "--port", $port])
  let deadline = epochTime() + readinessMs.float / 1000.0
  var ready = false
  while not ready:
    if not result.process.running:
      result.error = "the visual replay player exited before it answered"
      result.url = ""
      return
    try:
      let probe = newHttpClient(timeout = 2_000)
      defer: probe.close()
      ready = probe.get(result.url & "/info").code.is2xx
    except CatchableError:
      discard
    if not ready:
      if epochTime() > deadline:
        result.error = "the visual replay player did not answer at " &
          result.url
        result.url = ""
        return
      os.sleep(100)
  result.chans = cast[ptr HttpChannels](allocShared0(sizeof(HttpChannels)))
  result.chans.jobs.open()
  result.chans.answers.open()
  result.chans.wakeWrite = wakeWrite
  createThread(result.thread, httpLoop, result.chans)
  result.running = true
  result.client = result.newHttpVisualReplayClient()

proc inactiveClient*(): VisualReplayClient =
  ## A client that answers nothing: the panes of a recording whose player is
  ## not running (they say why through `VisualReplayPanesVM.playerError`).
  proc never[T](what: string): Future[T] =
    result = newFuture[T](what)
    result.fail(newException(CatchableError,
      "the visual replay player is not running"))
  VisualReplayClient(
    playerUrl: "",
    getInfoProc: proc(): Future[VisualReplayInfo] =
      never[VisualReplayInfo]("info"),
    getFrameByGeidProc: proc(g: uint64): Future[VisualReplayFrame] =
      never[VisualReplayFrame]("frame"),
    getFrameByFrameProc: proc(f: int): Future[VisualReplayFrame] =
      never[VisualReplayFrame]("frame"),
    getFrameByDrawProc: proc(d: int): Future[VisualReplayFrame] =
      never[VisualReplayFrame]("frame"),
    getFrameByFrameDrawProc: proc(f, d: int): Future[VisualReplayFrame] =
      never[VisualReplayFrame]("frame"),
    getDrawCallsProc: proc(f: int): Future[seq[VisualReplayDrawCall]] =
      never[seq[VisualReplayDrawCall]]("draws"),
    getPixelHistoryProc: proc(x, y, f: int):
        Future[seq[VisualReplayPixelHistoryEntry]] =
      never[seq[VisualReplayPixelHistoryEntry]]("history"),
    getShaderDebugProc: proc(r: VisualReplayShaderDebugRequest):
        Future[VisualReplayShaderDebugInfo] =
      never[VisualReplayShaderDebugInfo]("shader"))

proc panesFor*(h: NativeVisualReplay; store: ReplayDataStore = nil):
    VisualReplayPanesVM =
  ## The panes' model for this host's recording, connected: the player's
  ## client when it runs, an inactive one and the reason when it does not.
  if h.isNil:
    return nil
  let client = if h.client.isNil: inactiveClient() else: h.client
  result = createVisualReplayPanesVM(client, store)
  result.connect(true, h.url, h.error)

proc close*(h: NativeVisualReplay) =
  ## Stop the worker and the player; remove a stream this host extracted.
  if h.isNil:
    return
  if h.running:
    h.running = false
    h.chans.jobs.send(HttpJob(kind: hjStop))
    joinThread(h.thread)
    h.chans.jobs.close()
    h.chans.answers.close()
    deallocShared(h.chans)
    h.chans = nil
  if not h.process.isNil:
    if h.process.running:
      h.process.terminate()
      discard h.process.waitForExit(2_000)
      if h.process.running:
        h.process.kill()
    h.process.close()
    h.process = nil
  if h.extractedDir.len > 0:
    removeDir(h.extractedDir)
    h.extractedDir = ""
