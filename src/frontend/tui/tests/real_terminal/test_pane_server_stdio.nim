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

import std/[json, net, os, osproc, sequtils, streams, strutils, unittest]

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
