import asyncdispatch, asyncnet, json, strutils, sequtils

# --------------------------
# Small helper types & procs
# --------------------------
type
  DapClient = ref object
    sock: AsyncSocket
    seq*: int                # monotonically-increasing request id

proc newDapClient*(host = "127.0.0.1",
                   port = Port(4711)): Future[DapClient] {.async.} =
  ## Open a TCP connection to the adapter.
  let s = await dial(host, port)
  result = DapClient(sock: s, seq: 1)

proc sendPacket*(c: DapClient, payload: JsonNode) {.async.} =
  ## Frame & transmit one DAP message.
  payload["seq"] = %c.seq      # add/overwrite the 'seq' field
  inc c.seq

  let body = $payload          # JSON-encode
  let header = "Content-Length: " & $body.len & "\r\n\r\n"
  await c.sock.send(header & body)

proc readPacket*(c: DapClient): Future[JsonNode] {.async.} =
  ## Receive one DAP message (blocking until complete).
  var contentLen = 0
  var line: string

  # Read header lines
  while true:
    line = await c.sock.recvLine()
    if line.len == 0: continue         # ignore stray CRLF
    if line == "\r\n": break           # blank line terminates header block
    if line.startsWith("Content-Length:"):
      contentLen = parseInt(line.split(':')[1].strip())

  # Consume trailing CRLF after headers, then the JSON body.
  discard await c.sock.recvExact(2)    # CRLF
  let body = await c.sock.recvExact(contentLen)
  result = parseJson(body)

# --------------------------
# Demo: initialize handshake
# --------------------------
proc demo() {.async.} =
  let cli = await newDapClient()

  # Minimal 'initialize' request (DAP §3.1.1)
  var initReq = %*{
    "type": "request",
    "command": "initialize",
    "arguments": {
      "clientID":      "nim-dap",
      "clientName":    "Nim DAP demo",
      "adapterID":     "debug-adapter",
      "linesStartAt1": true,
      "columnsStartAt1": true,
      "pathFormat":    "path"
    }
  }
  await cli.sendPacket(initReq)
  echo ">> sent initialize"

  let resp = await cli.readPacket()
  echo "<< got response:\n", resp.pretty()

  # TODO: follow up with 'launch' or 'attach', set breakpoints, etc.
  await cli.sock.close()
