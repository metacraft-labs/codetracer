## Small, injectable client boundary for the visual replay player.
##
## Production code can provide an HTTP-backed client; tests and StoryBook pass a
## fake client at this same boundary.

import std/[json, options, strutils]

import isonim/core/async_compat

type
  VisualReplayFuture*[T] = PlatformFuture[T]

  VisualReplayInfo* = object
    frameCount*: int
    width*: int
    height*: int

  VisualReplayFrame* = object
    imageSrc*: string
    geid*: Option[uint64]
    frame*: Option[int]
    width*: int
    height*: int

  VisualReplayDrawCall* = object
    index*: int
    geid*: uint64
    name*: string
    pipeline*: string

  VisualReplayClient* = ref object
    playerUrl*: string
    getInfoProc*: proc(): VisualReplayFuture[VisualReplayInfo]
    getFrameByGeidProc*: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame]
    getFrameByFrameProc*: proc(frame: int): VisualReplayFuture[VisualReplayFrame]
    getDrawCallsProc*: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]]

proc normalizedPlayerUrl*(playerUrl: string): string =
  result = playerUrl.strip
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc infoUrl*(playerUrl: string): string =
  normalizedPlayerUrl(playerUrl) & "/info"

proc frameByGeidUrl*(playerUrl: string; geid: uint64): string =
  normalizedPlayerUrl(playerUrl) & "/frame?geid=" & $geid

proc frameByFrameUrl*(playerUrl: string; frame: int): string =
  normalizedPlayerUrl(playerUrl) & "/frame?frame=" & $frame

proc drawCallsUrl*(playerUrl: string): string =
  normalizedPlayerUrl(playerUrl) & "/draw-calls"

proc drawCallFromJson(node: JsonNode): VisualReplayDrawCall =
  VisualReplayDrawCall(
    index: node{"index"}.getInt(0),
    geid: uint64(node{"geid"}.getBiggestInt(0)),
    name: node{"name"}.getStr("draw"),
    pipeline: node{"pipeline"}.getStr(""),
  )

proc frameFromJson(node: JsonNode): VisualReplayFrame =
  result = VisualReplayFrame(
    imageSrc: node{"imageSrc"}.getStr(node{"url"}.getStr("")),
    width: node{"width"}.getInt(0),
    height: node{"height"}.getInt(0),
  )
  if node.hasKey("geid"):
    result.geid = some(uint64(node["geid"].getBiggestInt))
  if node.hasKey("frame"):
    result.frame = some(node["frame"].getInt)

proc infoFromJson(node: JsonNode): VisualReplayInfo =
  VisualReplayInfo(
    frameCount: node{"frameCount"}.getInt(node{"frames"}.getInt(0)),
    width: node{"width"}.getInt(0),
    height: node{"height"}.getInt(0),
  )

proc getInfo*(client: VisualReplayClient): VisualReplayFuture[VisualReplayInfo] =
  assert client.getInfoProc != nil, "VisualReplayClient.getInfoProc is not set"
  client.getInfoProc()

proc getFrameByGeid*(client: VisualReplayClient;
                     geid: uint64): VisualReplayFuture[VisualReplayFrame] =
  assert client.getFrameByGeidProc != nil,
    "VisualReplayClient.getFrameByGeidProc is not set"
  client.getFrameByGeidProc(geid)

proc getFrameByFrame*(client: VisualReplayClient;
                      frame: int): VisualReplayFuture[VisualReplayFrame] =
  assert client.getFrameByFrameProc != nil,
    "VisualReplayClient.getFrameByFrameProc is not set"
  client.getFrameByFrameProc(frame)

proc getDrawCalls*(client: VisualReplayClient):
    VisualReplayFuture[seq[VisualReplayDrawCall]] =
  assert client.getDrawCallsProc != nil,
    "VisualReplayClient.getDrawCallsProc is not set"
  client.getDrawCallsProc()

proc createJsonVisualReplayClient*(
    playerUrl: string;
    getJson: proc(url: string): VisualReplayFuture[JsonNode]
  ): VisualReplayClient =
  ## Create a client from a JSON transport. This is the preferred production
  ## adapter shape because tests can assert exact endpoint URLs independently
  ## of HTTP mechanics.
  let baseUrl = normalizedPlayerUrl(playerUrl)
  VisualReplayClient(
    playerUrl: baseUrl,
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      let fut = getJson(infoUrl(baseUrl))
      when defined(js):
        result = newPromise proc(resolve: proc(value: VisualReplayInfo)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) = resolve(infoFromJson(node)),
            onError = proc(msg: string) =
              raise newException(CatchableError, msg))
      else:
        result = newFuture[VisualReplayInfo]("visual replay info")
        let outFuture = result
        async_compat.onComplete(fut,
          onSuccess = proc(node: JsonNode) = outFuture.complete(infoFromJson(node)),
          onError = proc(msg: string) =
            outFuture.fail(newException(CatchableError, msg)))
    ,
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      let fut = getJson(frameByGeidUrl(baseUrl, geid))
      when defined(js):
        result = newPromise proc(resolve: proc(value: VisualReplayFrame)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) = resolve(frameFromJson(node)),
            onError = proc(msg: string) =
              raise newException(CatchableError, msg))
      else:
        result = newFuture[VisualReplayFrame]("visual replay frame geid")
        let outFuture = result
        async_compat.onComplete(fut,
          onSuccess = proc(node: JsonNode) = outFuture.complete(frameFromJson(node)),
          onError = proc(msg: string) =
            outFuture.fail(newException(CatchableError, msg)))
    ,
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      let fut = getJson(frameByFrameUrl(baseUrl, frame))
      when defined(js):
        result = newPromise proc(resolve: proc(value: VisualReplayFrame)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) = resolve(frameFromJson(node)),
            onError = proc(msg: string) =
              raise newException(CatchableError, msg))
      else:
        result = newFuture[VisualReplayFrame]("visual replay frame index")
        let outFuture = result
        async_compat.onComplete(fut,
          onSuccess = proc(node: JsonNode) = outFuture.complete(frameFromJson(node)),
          onError = proc(msg: string) =
            outFuture.fail(newException(CatchableError, msg)))
    ,
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      let fut = getJson(drawCallsUrl(baseUrl))
      when defined(js):
        result = newPromise proc(resolve: proc(value: seq[VisualReplayDrawCall])) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) =
              var calls: seq[VisualReplayDrawCall] = @[]
              for item in node.items:
                calls.add(drawCallFromJson(item))
              resolve(calls),
            onError = proc(msg: string) =
              raise newException(CatchableError, msg))
      else:
        result = newFuture[seq[VisualReplayDrawCall]]("visual replay draw calls")
        let outFuture = result
        async_compat.onComplete(fut,
          onSuccess = proc(node: JsonNode) =
            var calls: seq[VisualReplayDrawCall] = @[]
            for item in node.items:
              calls.add(drawCallFromJson(item))
            outFuture.complete(calls),
          onError = proc(msg: string) =
            outFuture.fail(newException(CatchableError, msg)))
    ,
  )
