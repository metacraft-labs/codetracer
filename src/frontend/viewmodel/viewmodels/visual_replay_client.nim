## Small, injectable client boundary for the visual replay player.
##
## Production code can provide an HTTP-backed client; tests and StoryBook pass a
## fake client at this same boundary.

import std/[json, options, sequtils, strutils]

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

  VisualReplayPixelColor* = object
    r*: float
    g*: float
    b*: float
    a*: float

  VisualReplayPixelTestStatus* = object
    depth*: string
    stencil*: string
    blend*: string
    cull*: string

  VisualReplayPixelHistoryEntry* = object
    geid*: uint64
    drawCallIndex*: int
    fragmentIndex*: int
    primitiveId*: int
    preColor*: VisualReplayPixelColor
    shaderOutput*: VisualReplayPixelColor
    postColor*: VisualReplayPixelColor
    preDepth*: float
    postDepth*: float
    passed*: bool
    failureReason*: string
    testStatus*: VisualReplayPixelTestStatus

  VisualReplayShaderDebugRequest* = object
    x*: int
    y*: int
    frame*: Option[int]
    geid*: Option[uint64]
    drawCallIndex*: Option[int]
    fragmentIndex*: Option[int]
    primitiveId*: Option[int]

  VisualReplayShaderValue* = object
    name*: string
    value*: string
    valueType*: string

  VisualReplayShaderStep* = object
    stepIndex*: int
    instruction*: string
    sourceLine*: int
    variables*: seq[VisualReplayShaderValue]
    registers*: seq[VisualReplayShaderValue]

  VisualReplayShaderDebugInfo* = object
    shaderStage*: string
    entryPoint*: string
    source*: string
    sourceLines*: seq[string]
    steps*: seq[VisualReplayShaderStep]

  VisualReplayClient* = ref object
    playerUrl*: string
    getInfoProc*: proc(): VisualReplayFuture[VisualReplayInfo]
    getFrameByGeidProc*: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame]
    getFrameByFrameProc*: proc(frame: int): VisualReplayFuture[VisualReplayFrame]
    getFrameByDrawProc*: proc(draw: int): VisualReplayFuture[VisualReplayFrame]
    getDrawCallsProc*: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]]
    getPixelHistoryProc*: proc(x, y, frame: int):
      VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]]
    getShaderDebugProc*: proc(request: VisualReplayShaderDebugRequest):
      VisualReplayFuture[VisualReplayShaderDebugInfo]

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

proc frameByDrawUrl*(playerUrl: string; draw: int): string =
  normalizedPlayerUrl(playerUrl) & "/frame?draw=" & $draw

proc drawCallsUrl*(playerUrl: string): string =
  normalizedPlayerUrl(playerUrl) & "/draw-calls"

proc pixelHistoryUrl*(playerUrl: string; x, y, frame: int): string =
  normalizedPlayerUrl(playerUrl) & "/pixel-history?x=" & $x &
    "&y=" & $y & "&frame=" & $frame

proc shaderDebugUrl*(playerUrl: string): string =
  normalizedPlayerUrl(playerUrl) & "/shader-debug"

proc pixelHistoryRequestToJson*(x, y, frame: int): JsonNode =
  %*{
    "x": x,
    "y": y,
    "frame": frame,
  }

proc shaderDebugRequestToJson*(request: VisualReplayShaderDebugRequest): JsonNode =
  result = %*{
    "x": request.x,
    "y": request.y,
  }
  if request.frame.isSome:
    result["frame"] = %request.frame.get
  if request.geid.isSome:
    result["geid"] = %request.geid.get
  if request.drawCallIndex.isSome:
    result["draw"] = %request.drawCallIndex.get
    result["draw_call_index"] = %request.drawCallIndex.get
  if request.fragmentIndex.isSome:
    result["fragment_index"] = %request.fragmentIndex.get
  if request.primitiveId.isSome:
    result["primitive_id"] = %request.primitiveId.get

proc normalizeColor(color: VisualReplayPixelColor): VisualReplayPixelColor =
  if color.r > 1.0 or color.g > 1.0 or color.b > 1.0 or color.a > 1.0:
    VisualReplayPixelColor(
      r: color.r / 255.0,
      g: color.g / 255.0,
      b: color.b / 255.0,
      a: color.a / 255.0)
  else:
    color

proc colorFromJson(node: JsonNode): VisualReplayPixelColor =
  if node.kind == JArray and node.len >= 4:
    return normalizeColor(VisualReplayPixelColor(
      r: node[0].getFloat(0.0),
      g: node[1].getFloat(0.0),
      b: node[2].getFloat(0.0),
      a: node[3].getFloat(1.0)))
  else:
    return normalizeColor(VisualReplayPixelColor(
      r: node{"r"}.getFloat(0.0),
      g: node{"g"}.getFloat(0.0),
      b: node{"b"}.getFloat(0.0),
      a: node{"a"}.getFloat(1.0)))

proc hasReason(reason, name: string): bool =
  reason.toLowerAscii.contains(name.toLowerAscii)

proc testStatusFromJson(node: JsonNode; passed: bool;
                        failureReason: string): VisualReplayPixelTestStatus =
  let tests = node{"testStatus"}
  if not tests.isNil and tests.kind == JObject:
    return VisualReplayPixelTestStatus(
      depth: tests{"depth"}.getStr("pass"),
      stencil: tests{"stencil"}.getStr("pass"),
      blend: tests{"blend"}.getStr(if passed: "applied" else: "skipped"),
      cull: tests{"cull"}.getStr("pass"))

  let failures = node{"failure_reason"}
  proc status(flagName, reasonName: string): string =
    if node{flagName}.getBool(false) or
        failureReason.hasReason(reasonName) or
        (not failures.isNil and failures.kind == JArray and failures.getElems.anyIt(
          it.getStr("").hasReason(reasonName))):
      "failed"
    else:
      "pass"

  VisualReplayPixelTestStatus(
    depth: status("depth_failed", "depth"),
    stencil: status("stencil_failed", "stencil"),
    blend: if node{"blend"}.getBool(false) or node{"blending"}.getBool(false):
      "applied" else: "unchanged",
    cull: if node{"backface_culled"}.getBool(false) or
      node{"cull_failed"}.getBool(false) or failureReason.hasReason("cull"):
        "failed" else: "pass")

proc pixelHistoryEntryFromJson*(node: JsonNode): VisualReplayPixelHistoryEntry =
  let passed = node{"passed"}.getBool(false)
  let failureReason =
    if not node{"failure_reason"}.isNil and node{"failure_reason"}.kind == JArray:
      node["failure_reason"].getElems.mapIt(it.getStr("")).join(", ")
    else:
      node{"failure_reason"}.getStr(node{"failureReason"}.getStr(""))
  proc pickColor(names: openArray[string]; fallback: JsonNode): JsonNode =
    for name in names:
      if node.hasKey(name):
        return node[name]
    fallback
  VisualReplayPixelHistoryEntry(
    geid: uint64(node{"geid"}.getBiggestInt(node{"eventId"}.getBiggestInt(0))),
    drawCallIndex: node{"draw_call_index"}.getInt(
      node{"drawCallIndex"}.getInt(node{"draw"}.getInt(0))),
    fragmentIndex: node{"fragment_index"}.getInt(node{"fragmentIndex"}.getInt(0)),
    primitiveId: node{"primitive_id"}.getInt(node{"primitiveID"}.getInt(-1)),
    preColor: colorFromJson(pickColor(["pre_color", "preColor", "preMod"],
                                      %*[0, 0, 0, 1])),
    shaderOutput: colorFromJson(pickColor(
      ["shader_output", "shaderOutput", "shaderOut"], %*[0, 0, 0, 1])),
    postColor: colorFromJson(pickColor(["post_color", "postColor", "postMod"],
                                       %*[0, 0, 0, 1])),
    preDepth: node{"pre_depth"}.getFloat(node{"preDepth"}.getFloat(0.0)),
    postDepth: node{"post_depth"}.getFloat(node{"postDepth"}.getFloat(0.0)),
    passed: passed,
    failureReason: failureReason,
    testStatus: testStatusFromJson(node, passed, failureReason))

proc drawCallFromJson*(node: JsonNode): VisualReplayDrawCall =
  VisualReplayDrawCall(
    index: node{"index"}.getInt(0),
    geid: uint64(node{"geid"}.getBiggestInt(0)),
    name: node{"name"}.getStr("draw"),
    pipeline: node{"pipeline"}.getStr(""),
  )

proc frameFromJson*(node: JsonNode): VisualReplayFrame =
  result = VisualReplayFrame(
    imageSrc: node{"imageSrc"}.getStr(node{"url"}.getStr("")),
    width: node{"width"}.getInt(0),
    height: node{"height"}.getInt(0),
  )
  if node.hasKey("geid"):
    result.geid = some(uint64(node["geid"].getBiggestInt))
  if node.hasKey("frame"):
    result.frame = some(node["frame"].getInt)

proc infoFromJson*(node: JsonNode): VisualReplayInfo =
  VisualReplayInfo(
    frameCount: node{"frameCount"}.getInt(node{"frames"}.getInt(0)),
    width: node{"width"}.getInt(0),
    height: node{"height"}.getInt(0),
  )

proc stringValueFromJson(node: JsonNode): string =
  if node.isNil:
    return ""
  case node.kind
  of JString:
    node.getStr("")
  of JNull:
    ""
  else:
    $node

proc shaderValueFromJson(node: JsonNode): VisualReplayShaderValue =
  VisualReplayShaderValue(
    name: node{"name"}.getStr(node{"id"}.getStr("")),
    value: stringValueFromJson(node{"value"}),
    valueType: node{"type"}.getStr(node{"valueType"}.getStr("")),
  )

proc shaderValuesFromJson(node: JsonNode): seq[VisualReplayShaderValue] =
  if node.isNil:
    return
  if node.kind == JArray:
    for item in node.items:
      result.add(shaderValueFromJson(item))
  elif node.kind == JObject:
    for name, value in node.pairs:
      result.add(VisualReplayShaderValue(
        name: name,
        value: stringValueFromJson(value),
        valueType: ""))

proc shaderStepFromJson(node: JsonNode; fallbackIndex: int): VisualReplayShaderStep =
  let line = node{"line"}.getInt(
    node{"sourceLine"}.getInt(node{"source_line"}.getInt(0)))
  VisualReplayShaderStep(
    stepIndex: node{"step"}.getInt(node{"stepIndex"}.getInt(fallbackIndex)),
    instruction: node{"instruction"}.getStr(node{"opcode"}.getStr("")),
    sourceLine: line,
    variables: shaderValuesFromJson(node{"variables"}),
    registers: shaderValuesFromJson(node{"registers"}),
  )

proc shaderDebugInfoFromJson*(node: JsonNode): VisualReplayShaderDebugInfo =
  let source = node{"source"}.getStr(
    node{"shaderSource"}.getStr(node{"fragmentShaderSource"}.getStr("")))
  result = VisualReplayShaderDebugInfo(
    shaderStage: node{"stage"}.getStr(node{"shaderStage"}.getStr("fragment")),
    entryPoint: node{"entryPoint"}.getStr(node{"entry"}.getStr("main")),
    source: source,
    sourceLines: @[],
    steps: @[],
  )
  let sourceLines = node{"sourceLines"}
  if not sourceLines.isNil and sourceLines.kind == JArray:
    for line in sourceLines.items:
      result.sourceLines.add(line.getStr(""))
  elif source.len > 0:
    result.sourceLines = source.splitLines()

  let stepNodes = node{"steps"}
  let traceNodes = node{"trace"}
  let steps =
    if not stepNodes.isNil and stepNodes.kind == JArray: stepNodes
    elif not traceNodes.isNil and traceNodes.kind == JArray: traceNodes
    else: newJArray()
  var index = 0
  for item in steps.items:
    result.steps.add(shaderStepFromJson(item, index))
    inc index

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

proc getFrameByDraw*(client: VisualReplayClient;
                     draw: int): VisualReplayFuture[VisualReplayFrame] =
  assert client.getFrameByDrawProc != nil,
    "VisualReplayClient.getFrameByDrawProc is not set"
  client.getFrameByDrawProc(draw)

proc getDrawCalls*(client: VisualReplayClient):
    VisualReplayFuture[seq[VisualReplayDrawCall]] =
  assert client.getDrawCallsProc != nil,
    "VisualReplayClient.getDrawCallsProc is not set"
  client.getDrawCallsProc()

proc getPixelHistory*(client: VisualReplayClient; x, y, frame: int):
    VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
  assert client.getPixelHistoryProc != nil,
    "VisualReplayClient.getPixelHistoryProc is not set"
  client.getPixelHistoryProc(x, y, frame)

proc getShaderDebug*(client: VisualReplayClient;
                     request: VisualReplayShaderDebugRequest):
    VisualReplayFuture[VisualReplayShaderDebugInfo] =
  assert client.getShaderDebugProc != nil,
    "VisualReplayClient.getShaderDebugProc is not set"
  client.getShaderDebugProc(request)

proc createJsonVisualReplayClient*(
    playerUrl: string;
    getJson: proc(url: string): VisualReplayFuture[JsonNode];
    postJson: proc(url: string; body: JsonNode): VisualReplayFuture[JsonNode] = nil
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
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      let fut = getJson(frameByDrawUrl(baseUrl, draw))
      when defined(js):
        result = newPromise proc(resolve: proc(value: VisualReplayFrame)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) = resolve(frameFromJson(node)),
            onError = proc(msg: string) =
              raise newException(CatchableError, msg))
      else:
        result = newFuture[VisualReplayFrame]("visual replay frame draw")
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
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      let fut = getJson(pixelHistoryUrl(baseUrl, x, y, frame))
      when defined(js):
        result = newPromise proc(resolve: proc(value: seq[VisualReplayPixelHistoryEntry])) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) =
              var entries: seq[VisualReplayPixelHistoryEntry] = @[]
              let items =
                if node.kind == JArray: node
                elif node.hasKey("modifications"): node["modifications"]
                elif node.hasKey("entries"): node["entries"]
                else: newJArray()
              for item in items.items:
                entries.add(pixelHistoryEntryFromJson(item))
              resolve(entries),
            onError = proc(msg: string) =
              raise newException(CatchableError, msg))
      else:
        result = newFuture[seq[VisualReplayPixelHistoryEntry]](
          "visual replay pixel history")
        let outFuture = result
        async_compat.onComplete(fut,
          onSuccess = proc(node: JsonNode) =
            var entries: seq[VisualReplayPixelHistoryEntry] = @[]
            let items =
              if node.kind == JArray: node
              elif node.hasKey("modifications"): node["modifications"]
              elif node.hasKey("entries"): node["entries"]
              else: newJArray()
            for item in items.items:
              entries.add(pixelHistoryEntryFromJson(item))
            outFuture.complete(entries),
          onError = proc(msg: string) =
            outFuture.fail(newException(CatchableError, msg)))
    ,
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      assert postJson != nil,
        "VisualReplayClient shader debug transport requires JSON POST"
      let fut = postJson(shaderDebugUrl(baseUrl), shaderDebugRequestToJson(request))
      when defined(js):
        result = newPromise proc(resolve: proc(value: VisualReplayShaderDebugInfo)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) = resolve(shaderDebugInfoFromJson(node)),
            onError = proc(msg: string) =
              raise newException(CatchableError, msg))
      else:
        result = newFuture[VisualReplayShaderDebugInfo]("visual replay shader debug")
        let outFuture = result
        async_compat.onComplete(fut,
          onSuccess = proc(node: JsonNode) =
            outFuture.complete(shaderDebugInfoFromJson(node)),
          onError = proc(msg: string) =
            outFuture.fail(newException(CatchableError, msg)))
    ,
  )
