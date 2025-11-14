import
  std / [ async, jsffi, json, strformat, strutils ],
  ../../[ types, config ],
  ../../lib/[ jslib ],
  ../../../common/ct_logging,
  ../electron_vars

type
  RawDapMessage* = ref object
    raw*: cstring

var backendManagerSocket*: JsObject = nil
var replayStartHandler*: proc(body: JsObject) = nil

proc registerStartReplayHandler*(handler: proc(body: JsObject)) =
  replayStartHandler = handler

proc stringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}

proc wrapJsonForSending*(obj: JsObject): cstring =
    let stringified_packet = stringify(obj)
    let len = len(stringified_packet)
    let header = &"Content-Length: {len}\r\n\r\n"
    let res = header.cstring & stringified_packet
    return res.cstring

proc onDapRawMessage*(sender: js, response: JsObject) {.async.} =
  if not backendManagerSocket.isNil:
    let txt = wrapJsonForSending(response)
    backendManagerSocket.write txt
  else:
    # TODO: put in a queue, or directly make an error, as it might be made hard to happen,
    # if sending from frontend only after dap socket setup here
    errorPrint "backend socket is nil, couldn't send ", response.toJs

proc handleFrame(frame: string) =
  let body: JsObject = Json.parse(frame)
  let msgtype = body["type"].to(cstring)

  if msgtype == "response":
    if jsHasKey(body, cstring"command"):
      let command = body["command"].to(cstring)
      if command == cstring("ct/start-replay"):
        if not replayStartHandler.isNil:
          replayStartHandler(body)
        return
    mainWindow.webContents.send("CODETRACER::dap-receive-response", body)
  elif msgtype == "event":
    mainWindow.webContents.send("CODETRACER::dap-receive-event", body)
  else:
    echo "unknown DAP message: ", body

var dapMessageBuffer = ""

proc setupProxyForDap*(socket: JsObject) =
  let lineBreakSize = 4

  socket.on(cstring"data", proc(data: cstring) =
    dapMessageBuffer.add $data

    while true:
      # Try and find the `Content-length` header's end
      let hdrEnd = dapMessageBuffer.find("\r\n\r\n")

      # We're still waiting on the header
      if hdrEnd < 0: break

      # We parse the header
      let header = dapMessageBuffer[0 ..< hdrEnd]
      var contentLen = -1
      for line in header.splitLines:
        if line.startsWith("Content-Length:"):
          contentLen = line.split(":")[1].strip.parseInt
          break
      if contentLen < 0:
        # Is this the right kind of exception ???
        raise newException(ValueError, "DAP header without Content-Length")

      # We try and parse the body
      let frameEnd = hdrEnd + lineBreakSize + contentLen  # 4 = len("\r\n\r\n")

      # We don't have the whole body yet
      if dapMessageBuffer.len < frameEnd: break

      # We handle the frame
      let body = dapMessageBuffer.substr(hdrEnd + lineBreakSize, frameEnd - 1)
      handleFrame(body)

      # We sanitize the buffer
      dapMessageBuffer = dapMessageBuffer.substr(frameEnd)
  )
