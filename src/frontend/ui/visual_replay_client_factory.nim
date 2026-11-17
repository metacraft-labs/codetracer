import
  ../viewmodel/viewmodels/visual_replay_client

import std/[json, options]
import isonim/core/async_compat

when defined(js):
  import ../lib/logging
  import std/jsffi

when not defined(js):
  import std/asyncdispatch

when defined(js):
  proc fetchJsonText(url: cstring): VisualReplayFuture[cstring] {.importjs: """
    ((async function(url) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error("visual replay request failed: " + response.status);
      }
      return await response.text();
    })(#))
  """.}

  proc newInfoCache(): JsObject {.importjs: "({})".}

  proc fetchFrameText(url, infoUrl: cstring;
                      infoCache: JsObject): VisualReplayFuture[cstring] {.importjs: """
    ((async function(url, infoUrl, cache) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error("visual replay frame request failed: " + response.status);
      }

      const contentType = response.headers.get("content-type") || "";
      if (contentType.includes("application/json")) {
        return await response.text();
      }

      // THE FRAME SAYS ITS OWN SIZE (MCR-Visual-Replay.md, `GET /frame`):
      // `X-Width` / `X-Height` are the image's, `X-Source-Width` /
      // `X-Source-Height` the framebuffer's. Only a player that does not
      // expose them is asked `/info`, once per client, never per frame.
      let width = Number(response.headers.get("x-width") || 0);
      let height = Number(response.headers.get("x-height") || 0);
      let sourceWidth = Number(response.headers.get("x-source-width") || 0);
      let sourceHeight = Number(response.headers.get("x-source-height") || 0);
      if (width <= 0 || height <= 0) {
        if (!cache.info) {
          const infoResponse = await fetch(infoUrl);
          if (!infoResponse.ok) {
            throw new Error("visual replay info request failed: " + infoResponse.status);
          }
          cache.info = await infoResponse.json();
        }
        width = Number(cache.info.width || 0);
        height = Number(cache.info.height || 0);
      }
      if (width <= 0 || height <= 0) {
        throw new Error("visual replay player returned invalid frame dimensions");
      }

      const raw = new Uint8ClampedArray(await response.arrayBuffer());
      if (raw.length < width * height * 4) {
        throw new Error(
          "visual replay player returned a short RGBA frame: " +
          raw.length + " < " + (width * height * 4)
        );
      }

      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      const ctx = canvas.getContext("2d");
      if (!ctx) {
        throw new Error("visual replay frame conversion could not create a 2d context");
      }
      // A GL player sends the framebuffer's rows bottom-up, as
      // `glReadPixels` returns them (`X-Row-Order: bottom-up`): the image
      // is drawn top row first, so they are flipped — and a picked pixel's
      // `y` then counts from the top, as `/pixel-history` takes it.
      let pixels = raw.slice(0, width * height * 4);
      if ((response.headers.get("x-row-order") || "") === "bottom-up") {
        const rowBytes = width * 4;
        const flipped = new Uint8ClampedArray(pixels.length);
        for (let row = 0; row < height; row++) {
          flipped.set(pixels.subarray((height - 1 - row) * rowBytes,
                                      (height - row) * rowBytes),
                      row * rowBytes);
        }
        pixels = flipped;
      }
      ctx.putImageData(new ImageData(pixels, width, height), 0, 0);

      const parsedUrl = new URL(url, window.location.href);
      const frame = {
        imageSrc: canvas.toDataURL("image/png"),
        width,
        height,
        sourceWidth: sourceWidth > 0 ? sourceWidth : width,
        sourceHeight: sourceHeight > 0 ? sourceHeight : height,
      };
      if (parsedUrl.searchParams.has("geid")) {
        frame.geid = Number(parsedUrl.searchParams.get("geid") || 0);
      }
      if (parsedUrl.searchParams.has("frame")) {
        frame.frame = Number(parsedUrl.searchParams.get("frame") || 0);
      }
      // THE DRAW CALL SHOWN AND ITS FRAME'S RANGE (`X-Draw`,
      // `X-Frame-Draw-Start` / `X-Frame-Draw-Count`): what the draw-call
      // stepping counts within. Absent headers leave them unknown.
      const drawHeader = response.headers.get("x-draw");
      if (drawHeader !== null) frame.drawIndex = Number(drawHeader);
      const xFrame = response.headers.get("x-frame");
      if (xFrame !== null) frame.frame = Number(xFrame);
      const drawStart = response.headers.get("x-frame-draw-start");
      if (drawStart !== null) frame.frameDrawStart = Number(drawStart);
      const drawCount = response.headers.get("x-frame-draw-count");
      if (drawCount !== null) frame.frameDrawCount = Number(drawCount);
      return JSON.stringify(frame);
    })(#, #, #))
  """.}

  proc postJsonText(url, body: cstring): VisualReplayFuture[cstring] {.importjs: """
    ((async function(url, body) {
      const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: body
      });
      if (!response.ok) {
        throw new Error("visual replay request failed: " + response.status);
      }
      return await response.text();
    })(#, #))
  """.}

proc completedVisualFuture*[T](value: T): VisualReplayFuture[T] =
  when defined(js):
    result = newPromise proc(resolve: proc(value: T)) =
      resolve(value)
  else:
    result = newFuture[T]("visual replay inactive client")
    result.complete(value)

proc createInactiveVisualReplayClient*(playerUrl: string): VisualReplayClient =
  VisualReplayClient(
    playerUrl: "",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      completedVisualFuture(VisualReplayInfo(frameCount: 0, width: 0, height: 0)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      completedVisualFuture(VisualReplayFrame(
        imageSrc: "",
        geid: some(geid),
        frame: none(int),
        width: 0,
        height: 0)),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      completedVisualFuture(VisualReplayFrame(
        imageSrc: "",
        geid: none(uint64),
        frame: some(frame),
        width: 0,
        height: 0)),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      completedVisualFuture(VisualReplayFrame(
        imageSrc: "",
        geid: none(uint64),
        frame: none(int),
        width: 0,
        height: 0)),
    getDrawCallsProc: proc(frame: int): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      completedVisualFuture(newSeq[VisualReplayDrawCall]()),
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      completedVisualFuture(newSeq[VisualReplayPixelHistoryEntry]()),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      completedVisualFuture(VisualReplayShaderDebugInfo(
        shaderStage: "",
        entryPoint: "",
        source: "",
        sourceLines: @[],
        steps: @[])),
  )

proc createHttpVisualReplayClient*(playerUrl: string): VisualReplayClient =
  when defined(js):
    let baseUrl = normalizedPlayerUrl(playerUrl)

    proc getJson(url: string): VisualReplayFuture[JsonNode] =
      let textFuture = fetchJsonText(cstring(url))
      result = newPromise proc(resolve: proc(value: JsonNode)) =
        async_compat.onComplete(textFuture,
          onSuccess = proc(raw: cstring) =
            resolve(parseJson($raw)),
          onError = proc(message: string) =
            raise newException(CatchableError, message))

    proc postJson(url: string; body: JsonNode): VisualReplayFuture[JsonNode] =
      let textFuture = postJsonText(cstring(url), cstring($body))
      result = newPromise proc(resolve: proc(value: JsonNode)) =
        async_compat.onComplete(textFuture,
          onSuccess = proc(raw: cstring) =
            resolve(parseJson($raw)),
          onError = proc(message: string) =
            raise newException(CatchableError, message))

    let infoCache = newInfoCache()
    proc getFrame(url: string): VisualReplayFuture[VisualReplayFrame] =
      let textFuture = fetchFrameText(cstring(url), cstring(infoUrl(baseUrl)),
                                      infoCache)
      result = newPromise proc(resolve: proc(value: VisualReplayFrame)) =
        async_compat.onComplete(textFuture,
          onSuccess = proc(raw: cstring) =
            resolve(frameFromJson(parseJson($raw))),
          onError = proc(message: string) =
            raise newException(CatchableError, message))

    var client: VisualReplayClient
    client = VisualReplayClient(
      playerUrl: baseUrl,
      getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
        let fut = getJson(infoUrl(baseUrl))
        result = newPromise proc(resolve: proc(value: VisualReplayInfo)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) = resolve(infoFromJson(node)),
            onError = proc(message: string) =
              raise newException(CatchableError, message)),
      getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
        getFrame(client.sizedFrameUrl(frameByGeidUrl(baseUrl, geid))),
      getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
        getFrame(client.sizedFrameUrl(frameByFrameUrl(baseUrl, frame))),
      getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
        getFrame(client.sizedFrameUrl(frameByDrawUrl(baseUrl, draw))),
      getFrameByFrameDrawProc: proc(frame, draw: int):
          VisualReplayFuture[VisualReplayFrame] =
        getFrame(client.sizedFrameUrl(frameByFrameDrawUrl(baseUrl, frame, draw))),
      getDrawCallsProc: proc(frame: int): VisualReplayFuture[seq[VisualReplayDrawCall]] =
        let fut = getJson(drawCallsUrl(baseUrl, frame))
        result = newPromise proc(resolve: proc(value: seq[VisualReplayDrawCall])) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) =
              var calls: seq[VisualReplayDrawCall] = @[]
              for item in node.items:
                calls.add(drawCallFromJson(item))
              resolve(calls),
            onError = proc(message: string) =
              raise newException(CatchableError, message)),
      getPixelHistoryProc: proc(x, y, frame: int):
          VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
        let fut = postJson(pixelHistoryUrl(baseUrl, x, y, frame),
          pixelHistoryRequestToJson(x, y, frame))
        result = newPromise proc(resolve: proc(value: seq[VisualReplayPixelHistoryEntry])) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) =
              var entries: seq[VisualReplayPixelHistoryEntry] = @[]
              try:
                let items =
                  if node.kind == JArray: node
                  elif node.hasKey("modifications"): node["modifications"]
                  elif node.hasKey("entries"): node["entries"]
                  else: newJArray()
                for item in items.items:
                  entries.add(pixelHistoryEntryFromJson(item))
              except:
                cerror "visual replay pixel history parse failed: " &
                  getCurrentExceptionMsg()
              resolve(entries),
            onError = proc(message: string) =
              raise newException(CatchableError, message)),
      getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
          VisualReplayFuture[VisualReplayShaderDebugInfo] =
        let fut = postJson(shaderDebugUrl(baseUrl), shaderDebugRequestToJson(request))
        result = newPromise proc(resolve: proc(value: VisualReplayShaderDebugInfo)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) =
              resolve(shaderDebugInfoFromJson(node)),
            onError = proc(message: string) =
              raise newException(CatchableError, message)),
    )
    client
  else:
    createInactiveVisualReplayClient(playerUrl)
