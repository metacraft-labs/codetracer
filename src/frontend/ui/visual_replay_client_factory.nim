import
  ../viewmodel/viewmodels/visual_replay_client

import std/[json, options]
import isonim/core/async_compat

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
    createJsonVisualReplayClient(
      playerUrl,
      proc(url: string): VisualReplayFuture[JsonNode] =
        let textFuture = fetchJsonText(cstring(url))
        result = newPromise proc(resolve: proc(value: JsonNode)) =
          async_compat.onComplete(textFuture,
            onSuccess = proc(raw: cstring) =
              resolve(parseJson($raw)),
            onError = proc(message: string) =
              raise newException(CatchableError, message)),
      proc(url: string; body: JsonNode): VisualReplayFuture[JsonNode] =
        let textFuture = postJsonText(cstring(url), cstring($body))
        result = newPromise proc(resolve: proc(value: JsonNode)) =
          async_compat.onComplete(textFuture,
            onSuccess = proc(raw: cstring) =
              resolve(parseJson($raw)),
            onError = proc(message: string) =
              raise newException(CatchableError, message)))
  else:
    createInactiveVisualReplayClient(playerUrl)
