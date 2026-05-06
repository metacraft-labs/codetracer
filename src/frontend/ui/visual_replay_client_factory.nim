import
  ../viewmodel/viewmodels/visual_replay_client

import std/[json, options]
import isonim/core/async_compat

when defined(js):
  import ../lib/logging

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

  proc fetchFrameText(url, infoUrl: cstring): VisualReplayFuture[cstring] {.importjs: """
    ((async function(url, infoUrl) {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error("visual replay frame request failed: " + response.status);
      }

      const contentType = response.headers.get("content-type") || "";
      if (contentType.includes("application/json")) {
        return await response.text();
      }

      const infoResponse = await fetch(infoUrl);
      if (!infoResponse.ok) {
        throw new Error("visual replay info request failed: " + infoResponse.status);
      }
      const info = await infoResponse.json();
      const width = Number(info.width || 0);
      const height = Number(info.height || 0);
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
      ctx.putImageData(new ImageData(raw.slice(0, width * height * 4), width, height), 0, 0);

      const parsedUrl = new URL(url, window.location.href);
      const frame = {
        imageSrc: canvas.toDataURL("image/png"),
        width,
        height,
      };
      if (parsedUrl.searchParams.has("geid")) {
        frame.geid = Number(parsedUrl.searchParams.get("geid") || 0);
      }
      if (parsedUrl.searchParams.has("frame")) {
        frame.frame = Number(parsedUrl.searchParams.get("frame") || 0);
      }
      return JSON.stringify(frame);
    })(#, #))
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
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
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

    proc getFrame(url: string): VisualReplayFuture[VisualReplayFrame] =
      let textFuture = fetchFrameText(cstring(url), cstring(infoUrl(baseUrl)))
      result = newPromise proc(resolve: proc(value: VisualReplayFrame)) =
        async_compat.onComplete(textFuture,
          onSuccess = proc(raw: cstring) =
            resolve(frameFromJson(parseJson($raw))),
          onError = proc(message: string) =
            raise newException(CatchableError, message))

    VisualReplayClient(
      playerUrl: baseUrl,
      getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
        let fut = getJson(infoUrl(baseUrl))
        result = newPromise proc(resolve: proc(value: VisualReplayInfo)) =
          async_compat.onComplete(fut,
            onSuccess = proc(node: JsonNode) = resolve(infoFromJson(node)),
            onError = proc(message: string) =
              raise newException(CatchableError, message)),
      getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
        getFrame(frameByGeidUrl(baseUrl, geid)),
      getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
        getFrame(frameByFrameUrl(baseUrl, frame)),
      getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
        getFrame(frameByDrawUrl(baseUrl, draw)),
      getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
        let fut = getJson(drawCallsUrl(baseUrl))
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
  else:
    createInactiveVisualReplayClient(playerUrl)
