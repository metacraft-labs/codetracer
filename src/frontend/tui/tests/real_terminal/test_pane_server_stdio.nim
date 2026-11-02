## test_pane_server_stdio.nim — HSF-E1, the pane server as an editor starts
## it: `build/bin/codetracer-tui --pane-server`, spoken to over its stdio with
## the LSP base protocol's framing, and over its DAP endpoint's TCP socket.
##
## `test_pane_server.nim` asserts the protocol message by message in-process;
## this suite asserts what only the real process can show: the framing in both
## directions, notifications interleaved with responses on one stream, a DAP
## client on the socket `initialize` names moving the session the panes show,
## and the LSP exit convention (status 0 after `shutdown` + `exit`).
##
## Needs the binary (`just build-tui`), as the real-terminal suites do; its
## absence is a failure, not a skip — a transport suite that skipped would
## pass with no transport at all.

import std/[base64, json, net, os, osproc, sequtils, streams, strutils, unittest]

import ../fixtures/fixture_provider

proc frame(msg: JsonNode): string =
  let body = $msg
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc readMessage(s: Stream): JsonNode =
  ## One framed message, or nil at the end of the stream.
  var length = -1
  while true:
    var line = ""
    if not s.readLine(line):
      return nil
    line = line.strip(chars = {'\r', '\n'})
    if line.len == 0:
      break
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].toLowerAscii == "content-length":
      length = parseInt(line[colon + 1 .. ^1].strip())
  if length < 0:
    return nil
  parseJson(s.readStr(length))

proc readSocketMessage(sock: Socket): JsonNode =
  var length = -1
  while true:
    let line = sock.recvLine(timeout = 20_000).strip(chars = {'\r', '\n'})
    if line.len == 0:
      break
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].toLowerAscii == "content-length":
      length = parseInt(line[colon + 1 .. ^1].strip())
  if length < 0:
    return nil
  parseJson(sock.recv(length, timeout = 20_000))

type Editor = object
  p: Process
  nextId: int

proc call(e: var Editor; meth: string; params: JsonNode = newJObject()):
    (JsonNode, seq[JsonNode]) =
  ## Send a request and read up to its response; the notifications read
  ## before it are returned too (they belong to earlier requests).
  inc e.nextId
  let id = e.nextId
  e.p.inputStream.write(frame(%*{"jsonrpc": "2.0", "id": id, "method": meth,
                                 "params": params}))
  e.p.inputStream.flush()
  var notes: seq[JsonNode] = @[]
  while true:
    let m = e.p.outputStream.readMessage()
    if m.isNil:
      return (nil, notes)
    if m{"id"}.getInt(-1) == id:
      return (m, notes)
    notes.add m

proc notify(e: var Editor; meth: string) =
  e.p.inputStream.write(frame(%*{"jsonrpc": "2.0", "method": meth}))
  e.p.inputStream.flush()

proc methods(ms: seq[JsonNode]): seq[string] =
  ms.mapIt(it{"method"}.getStr(""))

suite "HSF-E1: codetracer-tui --pane-server over stdio":

  test "an editor's session, framed, with a DAP client beside it":
    let binary = repoRoot() / "build" / "bin" / "codetracer-tui"
    check fileExists(binary)
    if not fileExists(binary):
      echo "  build it first: just build-tui"
      return
    let resolution = resolveFixture("calc")
    if resolution.outcome == foMissingPrereq:
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      fail()
      return
    var e = Editor(p: startProcess(binary, args = ["--pane-server"],
                                   options = {}))
    defer:
      if e.p.running: e.p.kill()
      e.p.close()

    let (init, _) = e.call("initialize", %*{"capabilities": {"media": ["text"]}})
    check init{"result", "protocolVersion"}.getInt == 1
    let port = init{"result", "capabilities", "dap", "port"}.getInt
    check port > 0

    let (opened, _) = e.call("session/open", %*{"trace": resolution.tracePath})
    check opened{"result", "mode"}.getStr == "debug"
    let sid = opened{"result", "session"}.getInt

    discard e.call("pane/open", %*{"session": sid, "pane": "calltrace",
                                   "width": 60, "height": 10})
    # The pane's keymap and content arrive as notifications after its answer.
    let (_, afterOpen) = e.call("session/list")
    check "pane/keymap" in methods(afterOpen)
    check "pane/content" in methods(afterOpen)
    for m in afterOpen:
      if m{"method"}.getStr == "pane/content":
        check m{"params", "rows"}.len == 10

    # ---- the DAP client moves the session; the editor's panes follow -----
    let sock = newSocket()
    sock.connect("127.0.0.1", Port(port))
    var dseq = 0
    proc dap(command: string; args: JsonNode = newJObject()): JsonNode =
      inc dseq
      sock.send(frame(%*{"seq": dseq, "type": "request", "command": command,
                         "arguments": args}))
      while true:
        let m = sock.readSocketMessage()
        if m.isNil or (m{"type"}.getStr == "response" and
                       m{"request_seq"}.getInt == dseq):
          return m
    check dap("initialize"){"success"}.getBool
    check dap("attach"){"success"}.getBool
    check dap("threads"){"body", "threads"}.len == 1
    check dap("next", %*{"threadId": 1}){"success"}.getBool
    let (_, afterStep) = e.call("session/list")
    # The editor follows a move it did not make. (Whether a pane's rows
    # change depends on the step — a step inside one call leaves the call
    # trace as it was — so the rows are asserted in-process, on a jump.)
    check "session/position" in methods(afterStep)
    discard dap("disconnect")
    sock.close()

    # ---- shutdown and exit: status 0 -----------------------------------
    let (down, _) = e.call("shutdown")
    check down{"error"}.isNil
    e.notify("exit")
    check e.p.waitForExit(timeout = 30_000) == 0

# ---------------------------------------------------------------------------
# The image medium (Editor-Hosted-Front-Ends Q2)
# ---------------------------------------------------------------------------
#
# A recording whose folder carries a gfx stream has graphics. The recording
# here is `calc` with the visual-replay repository's `mpv` corpus stream
# (`codetracer-visual-replay/tests/corpus_phase1/mpv`, a real recording of a
# real GL program) placed in its `gfx_stream/`, exactly where the product
# looks for one. The player is the real `ct_gfx_player`, found as `ct
# gfx-replay` finds it (`CODETRACER_CT_GFX_PLAYER_CMD`, beside `ct`, PATH),
# with its licence in the environment. No mock anywhere: what is asserted is
# the PNG the server encodes from the player's own pixels.

proc pngSize(png: string): (int, int) =
  ## The IHDR's width and height, after checking the PNG signature.
  doAssert png.len > 24 and png[0 ..< 8] == "\x89PNG\r\n\x1a\n", "not a PNG"
  proc be32(s: string; at: int): int =
    (s[at].ord shl 24) or (s[at + 1].ord shl 16) or (s[at + 2].ord shl 8) or
      s[at + 3].ord
  (be32(png, 16), be32(png, 20))

proc graphicsRecording(tracePath: string): string =
  ## A copy of `tracePath` carrying the `mpv` gfx stream, or "" when the
  ## corpus is not checked out beside this repository.
  let corpus = repoRoot() / ".." / "codetracer-visual-replay" / "tests" /
               "corpus_phase1" / "mpv"
  if not dirExists(corpus):
    return ""
  result = getTempDir() / "ct-pane-server-graphics-" & $getCurrentProcessId()
  removeDir(result)
  copyDir(tracePath, result)
  copyDir(corpus, result / "gfx_stream")

suite "HSF-E1: the image medium, over stdio":

  test "an editor that declares images is sent the frame as a PNG":
    let binary = repoRoot() / "build" / "bin" / "codetracer-tui"
    check fileExists(binary)
    if not fileExists(binary):
      return
    let resolution = resolveFixture("calc")
    if resolution.outcome == foMissingPrereq:
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      fail()
      return
    if getEnv("CODETRACER_CT_GFX_PLAYER_CMD").len == 0 and
       findExe("ct_gfx_player").len == 0:
      echo "  MISSING-PREREQ SKIP: the visual replay player — set " &
           "CODETRACER_CT_GFX_PLAYER_CMD to ct_gfx_player (with its licence " &
           "in the environment)"
      skip()
      return
    let folder = graphicsRecording(resolution.tracePath)
    if folder.len == 0:
      echo "  MISSING-PREREQ SKIP: codetracer-visual-replay is not checked " &
           "out beside this repository (its corpus holds the gfx stream)"
      skip()
      return
    defer: removeDir(folder)

    # ---- an image-capable editor ----------------------------------------
    block:
      var e = Editor(p: startProcess(binary, args = ["--pane-server"],
                                     options = {}))
      defer:
        if e.p.running: e.p.kill()
        e.p.close()
      let (init, _) = e.call("initialize",
                             %*{"capabilities": {"media": ["text", "image"]}})
      check init{"result", "capabilities", "media"} == %["text", "image"]
      check "frameViewer" in init{"result", "capabilities", "panes"}.getElems.mapIt(it.getStr)
      let (opened, _) = e.call("session/open", %*{"trace": folder})
      let graphics = opened{"result", "graphics"}
      checkpoint("graphics: " & $graphics)
      check graphics{"available"}.getBool
      check graphics{"frameCount"}.getInt > 1
      let sid = opened{"result", "session"}.getInt
      discard e.call("pane/open", %*{"session": sid, "pane": "frameViewer",
                                     "width": 50, "height": 6})
      let (_, shown) = e.call("session/list")
      let contents = shown.filterIt(it{"method"}.getStr == "pane/content")
      check contents.len == 1
      if contents.len == 1:
        let image = contents[0]{"params", "image"}
        check image{"mediaType"}.getStr == "image/png"
        check image{"encoding"}.getStr == "base64"
        check image{"frame"}.getInt == 0
        let png = decode(image{"data"}.getStr)
        check pngSize(png) == (graphics{"width"}.getInt,
                               graphics{"height"}.getInt)
        check (image{"width"}.getInt, image{"height"}.getInt) == pngSize(png)
        check contents[0]{"params", "rows"}[0]{"text"}.getStr.contains(" of ")
      # The next frame is sent once; the same frame is not sent again.
      let (moved, _) = e.call("operation/run",
        %*{"session": sid, "operation": "frame-viewer.next-frame"})
      check moved{"result", "ok"}.getBool
      let (_, afterNext) = e.call("session/list")
      let next = afterNext.filterIt(it{"method"}.getStr == "pane/content")
      check next.len == 1
      check next.len == 1 and next[0]{"params", "image", "frame"}.getInt == 1
      discard e.call("operation/run", %*{"session": sid,
                                         "operation": "debugger.step-over"})
      let (_, afterStep) = e.call("session/list")
      check afterStep.filterIt(it{"method"}.getStr == "pane/content" and
                               it{"params", "pane"}.getStr == "frameViewer" and
                               it{"params"}.hasKey("image")).len == 0
      discard e.call("shutdown")
      e.notify("exit")
      check e.p.waitForExit(timeout = 30_000) == 0

    # ---- a text-only editor: the same pane, without the image ------------
    block:
      var e = Editor(p: startProcess(binary, args = ["--pane-server"],
                                     options = {}))
      defer:
        if e.p.running: e.p.kill()
        e.p.close()
      let (init, _) = e.call("initialize",
                             %*{"capabilities": {"media": ["text"]}})
      check init{"result", "capabilities", "media"} == %["text"]
      let (opened, _) = e.call("session/open", %*{"trace": folder})
      let sid = opened{"result", "session"}.getInt
      discard e.call("pane/open", %*{"session": sid, "pane": "frameViewer",
                                     "width": 80, "height": 6})
      let (_, shown) = e.call("session/list")
      let contents = shown.filterIt(it{"method"}.getStr == "pane/content")
      check contents.len == 1
      if contents.len == 1:
        check not contents[0]{"params"}.hasKey("image")
        let texts = contents[0]{"params", "rows"}.getElems.mapIt(it{"text"}.getStr)
        check texts.anyIt(it.contains("declares the image medium"))
      discard e.call("shutdown")
      e.notify("exit")
      check e.p.waitForExit(timeout = 30_000) == 0
