## Headless tests for FrameViewerVM.

import std/[json, options, strutils, unittest]

import isonim/core/[owner, signals]
import isonim/viewmodel
import backend/mock_backend
import store/replay_data_store
import vm_test_helpers
import viewmodels/frame_viewer_vm
import viewmodels/pixel_history_vm
import viewmodels/shader_debug_vm
import viewmodels/visual_replay_client

type
  FakeVisualReplayClient = ref object
    client: VisualReplayClient
    geidRequests: seq[uint64]
    frameRequests: seq[int]
    drawRequests: seq[int]
    drawCallRequests: int
    pixelHistoryRequests: seq[PixelHistoryPixel]
    shaderDebugRequests: seq[VisualReplayShaderDebugRequest]
    failFrames: bool

proc makeFakeClient(): FakeVisualReplayClient =
  result = FakeVisualReplayClient()
  let fake = result
  fake.client = VisualReplayClient(
    playerUrl: "http://player.test/",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      newCompletedFuture(VisualReplayInfo(frameCount: 4, width: 320, height: 200)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      fake.geidRequests.add(geid)
      if fake.failFrames:
        return newFailedFuture[VisualReplayFrame]("player failed")
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-geid-" & $geid,
        geid: some(geid),
        frame: some(2),
        width: 320,
        height: 200,
      )),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      fake.frameRequests.add(frame)
      if fake.failFrames:
        return newFailedFuture[VisualReplayFrame]("frame failed")
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-index-" & $frame,
        geid: some(uint64(100 + frame)),
        frame: some(frame),
        width: 320,
        height: 200,
      )),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      fake.drawRequests.add(draw)
      if fake.failFrames:
        return newFailedFuture[VisualReplayFrame]("draw failed")
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-draw-" & $draw,
        geid: some(uint64(200 + draw)),
        frame: some(draw),
        width: 320,
        height: 200,
      )),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      inc fake.drawCallRequests
      newCompletedFuture(@[
        VisualReplayDrawCall(index: 0, geid: 100'u64,
                             name: "glClear", pipeline: "clear"),
        VisualReplayDrawCall(index: 1, geid: 101'u64,
                             name: "glDrawElements", pipeline: "mesh"),
      ]),
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      fake.pixelHistoryRequests.add(PixelHistoryPixel(x: x, y: y, frame: frame))
      newCompletedFuture(@[
        VisualReplayPixelHistoryEntry(
          geid: 101'u64,
          drawCallIndex: 1,
          fragmentIndex: 0,
          primitiveId: 7,
          preColor: VisualReplayPixelColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0),
          shaderOutput: VisualReplayPixelColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0),
          postColor: VisualReplayPixelColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0),
          passed: true,
          testStatus: VisualReplayPixelTestStatus(
            depth: "pass", stencil: "pass", blend: "applied", cull: "pass")),
        VisualReplayPixelHistoryEntry(
          geid: 102'u64,
          drawCallIndex: 2,
          fragmentIndex: 0,
          primitiveId: 8,
          preColor: VisualReplayPixelColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0),
          shaderOutput: VisualReplayPixelColor(r: 0.0, g: 1.0, b: 0.0, a: 1.0),
          postColor: VisualReplayPixelColor(r: 1.0, g: 0.0, b: 0.0, a: 1.0),
          passed: false,
          failureReason: "depth_failed",
          testStatus: VisualReplayPixelTestStatus(
            depth: "failed", stencil: "pass", blend: "unchanged", cull: "pass")),
      ]),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      fake.shaderDebugRequests.add(request)
      newCompletedFuture(VisualReplayShaderDebugInfo(
        shaderStage: "fragment",
        entryPoint: "main",
        source: "",
        sourceLines: @[
          "#version 450",
          "layout(location = 0) in vec2 v_uv;",
          "layout(location = 0) out vec4 out_color;",
          "void main() {",
          "  vec4 base = vec4(v_uv, 0.25, 1.0);",
          "  out_color = base;",
          "}",
        ],
        steps: @[
          VisualReplayShaderStep(
            stepIndex: 0,
            instruction: "OpLoad %v_uv",
            sourceLine: 2,
            variables: @[
              VisualReplayShaderValue(
                name: "v_uv", valueType: "vec2", value: "[0.25, 0.25]"),
            ],
            registers: @[
              VisualReplayShaderValue(
                name: "%12", valueType: "ptr", value: "input.v_uv"),
            ]),
          VisualReplayShaderStep(
            stepIndex: 1,
            instruction: "OpCompositeConstruct %base",
            sourceLine: 5,
            variables: @[
              VisualReplayShaderValue(
                name: "base", valueType: "vec4", value: "[0.25, 0.25, 0.25, 1.00]"),
            ],
            registers: @[
              VisualReplayShaderValue(
                name: "%18", valueType: "vec4", value: "base"),
            ]),
          VisualReplayShaderStep(
            stepIndex: 2,
            instruction: "OpStore %out_color",
            sourceLine: 6,
            variables: @[
              VisualReplayShaderValue(
                name: "out_color", valueType: "vec4", value: "[0.25, 0.25, 0.25, 1.00]"),
            ],
            registers: @[
              VisualReplayShaderValue(
                name: "%out", valueType: "vec4", value: "rgba"),
            ]),
        ])),
  )

suite "VisualReplayClient URL construction":
  test "constructs player endpoint URLs":
    check infoUrl("http://localhost:9000/") == "http://localhost:9000/info"
    check frameByGeidUrl("http://localhost:9000/", 42'u64) ==
      "http://localhost:9000/frame?geid=42"
    check frameByFrameUrl("http://localhost:9000/", 3) ==
      "http://localhost:9000/frame?frame=3"
    check frameByDrawUrl("http://localhost:9000/", 7) ==
      "http://localhost:9000/frame?draw=7"
    check drawCallsUrl("http://localhost:9000/") ==
      "http://localhost:9000/draw-calls"
    check pixelHistoryUrl("http://localhost:9000/", 12, 34, 2) ==
      "http://localhost:9000/pixel-history?x=12&y=34&frame=2"
    check shaderDebugUrl("http://localhost:9000/") ==
      "http://localhost:9000/shader-debug"

suite "FrameViewerVM frame loading":
  test "fetches frame for GEID and updates draw calls":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadFrameForGeid(42'u64)
    drain()
    drain()

    check fake.geidRequests == @[42'u64]
    check vm.currentGeid.val == some(42'u64)
    check vm.currentFrame.val == 2
    check vm.frameImageSrc.val == "frame-geid-42"
    check vm.loading.val == false
    check vm.error.val == ""
    check fake.drawCallRequests == 1
    check vm.drawCalls.val.len == 2

    vm.dispose()

  test "test_geid_change_fetches_new_frame":
    createRoot proc(dispose: proc()) =
      let fake = makeFakeClient()
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createFrameViewerVM(fake.client, store)
      vm.frameImageSrc.val = "stale-frame"

      store.updateCurrentGeid(some(77'u64))

      check fake.geidRequests == @[77'u64]
      check vm.loading.val
      check vm.frameImageSrc.val == ""
      check vm.currentGeid.val == some(77'u64)

      drain()
      drain()

      check vm.loading.val == false
      check vm.frameImageSrc.val == "frame-geid-77"
      check vm.currentFrame.val == 2
      check vm.error.val == ""

      store.updateCurrentGeid(some(88'u64))
      check fake.geidRequests == @[77'u64, 88'u64]
      check vm.loading.val
      check vm.frameImageSrc.val == ""

      drain()
      check vm.frameImageSrc.val == "frame-geid-88"
      check vm.loading.val == false

      dispose()

  test "switches by frame index and clears GEID before response":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadFrameForGeid(42'u64)
    drain()
    vm.loadFrameByIndex(3)
    drain()
    drain()

    check fake.frameRequests == @[3]
    check vm.currentFrame.val == 3
    check vm.currentGeid.val == some(103'u64)
    check vm.frameImageSrc.val == "frame-index-3"
    check vm.loading.val == false

    vm.dispose()

  test "draw-call scrubber fetches draw frame and routes GEID seek":
    createRoot proc(dispose: proc()) =
      let fake = makeFakeClient()
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createFrameViewerVM(fake.client, store)

      vm.loadDrawCalls()
      drain()
      vm.scrubToDrawCall(1)
      drain()
      drain()

      check fake.drawRequests == @[1]
      check vm.selectedDrawCall.val == some(1)
      check vm.frameImageSrc.val == "frame-draw-1"
      check vm.currentGeid.val == some(201'u64)
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == SeekToGeidCommand
      check mock.receivedCommands[0].args["geid"].getBiggestInt == 101

      dispose()

  test "handles player errors and clears stale frame data":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadFrameByIndex(1)
    drain()
    check vm.frameImageSrc.val == "frame-index-1"

    fake.failFrames = true
    vm.loadFrameByIndex(2)
    drain()

    check vm.loading.val == false
    check vm.error.val == "frame failed"
    check vm.frameImageSrc.val == ""
    check vm.drawCalls.val.len == 0
    check vm.selectedDrawCall.val.isNone

    vm.dispose()

suite "FrameViewerVM selection":
  test "maps rendered pixel coordinates into image pixel coordinates":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)
    vm.frameWidth.val = 320
    vm.frameHeight.val = 200

    vm.selectPixelFromRenderedPoint(80.0, 50.0, 160.0, 100.0)

    check vm.selectedPixel.val.isSome
    check vm.selectedPixel.val.get.x == 160
    check vm.selectedPixel.val.get.y == 100

    vm.selectPixelFromRenderedPoint(0.0, 0.0, 0.0, 100.0)
    check vm.selectedPixel.val.isNone

    vm.dispose()

  test "pixel click maps image coordinates and loads PixelHistoryVM":
    let fake = makeFakeClient()
    let frameVm = createFrameViewerVM(fake.client)
    let pixelVm = createPixelHistoryVM(fake.client)
    frameVm.frameWidth.val = 320
    frameVm.frameHeight.val = 200
    frameVm.currentFrame.val = 3
    frameVm.onPixelSelected =
      proc(x, y, frame: int; geid: Option[uint64]) =
        pixelVm.loadPixelHistory(x, y, frame)

    frameVm.selectPixelFromRenderedPoint(40.0, 25.0, 160.0, 100.0)
    drain()

    check frameVm.selectedPixel.val.isSome
    check frameVm.selectedPixel.val.get.x == 80
    check frameVm.selectedPixel.val.get.y == 50
    check fake.pixelHistoryRequests == @[
      PixelHistoryPixel(x: 80, y: 50, frame: 3)]
    check pixelVm.entries.val.len == 2

    pixelVm.dispose()
    frameVm.dispose()

  test "selected pixel and pixel history entry drive shader debug context":
    let fake = makeFakeClient()
    let frameVm = createFrameViewerVM(fake.client)
    let pixelVm = createPixelHistoryVM(fake.client)
    let shaderVm = createShaderDebugVM(fake.client)
    frameVm.frameWidth.val = 320
    frameVm.frameHeight.val = 200
    frameVm.currentFrame.val = 3
    frameVm.currentGeid.val = some(246'u64)
    frameVm.onPixelSelected =
      proc(x, y, frame: int; geid: Option[uint64]) =
        pixelVm.loadPixelHistory(x, y, frame)
        shaderVm.loadFromPixel(x, y, frame, geid)
    pixelVm.onEntrySelected =
      proc(entry: VisualReplayPixelHistoryEntry) =
        let pixel = pixelVm.selectedPixel.val.get
        shaderVm.loadFromPixelHistoryEntry(pixel.x, pixel.y, pixel.frame, entry)

    frameVm.selectPixelFromRenderedPoint(40.0, 25.0, 160.0, 100.0)
    drain()

    check fake.shaderDebugRequests.len == 1
    check fake.shaderDebugRequests[0].x == 80
    check fake.shaderDebugRequests[0].y == 50
    check fake.shaderDebugRequests[0].frame == some(3)
    check fake.shaderDebugRequests[0].geid == some(246'u64)
    check fake.shaderDebugRequests[0].drawCallIndex.isNone

    pixelVm.selectEntry(1)
    drain()

    check fake.shaderDebugRequests.len == 2
    check fake.shaderDebugRequests[1].x == 80
    check fake.shaderDebugRequests[1].y == 50
    check fake.shaderDebugRequests[1].frame == some(3)
    check fake.shaderDebugRequests[1].geid == some(102'u64)
    check fake.shaderDebugRequests[1].drawCallIndex == some(2)
    check fake.shaderDebugRequests[1].primitiveId == some(8)

    shaderVm.dispose()
    pixelVm.dispose()
    frameVm.dispose()

  test "selects and clears draw calls by index":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadDrawCalls()
    drain()
    vm.selectDrawCall(1)
    check vm.selectedDrawCall.val == some(1)

    vm.selectDrawCall(99)
    check vm.selectedDrawCall.val.isNone

    vm.dispose()

suite "PixelHistoryVM":
  test "parses real ct_gfx_player pixel history entries":
    let payload = parseJson("""
      [
        {
          "drawCallIndex": 4,
          "geid": 15990,
          "preColor": [0, 0, 0, 255],
          "postColor": [32, 86, 221, 255],
          "passed": true
        }
      ]
    """)

    let entry = pixelHistoryEntryFromJson(payload[0])

    check entry.drawCallIndex == 4
    check entry.geid == 15990'u64
    check entry.preColor.a == 1.0
    check entry.postColor.r > 0.12
    check entry.postColor.r < 0.13
    check entry.postColor.g > 0.33
    check entry.postColor.g < 0.34
    check entry.postColor.b > 0.86
    check entry.postColor.b < 0.87
    check entry.passed
    check entry.testStatus.depth == "pass"

  test "test_pixel_history_vm_loads_entries":
    let fake = makeFakeClient()
    let vm = createPixelHistoryVM(fake.client)

    vm.loadPixelHistory(12, 34, 1)
    drain()

    check fake.pixelHistoryRequests == @[PixelHistoryPixel(x: 12, y: 34, frame: 1)]
    check vm.entries.val.len == 2
    check vm.selectedPixel.val == some(PixelHistoryPixel(x: 12, y: 34, frame: 1))
    check vm.loading.val == false
    check vm.error.val == ""
    check vm.entries.val[0].postColor.r == 1.0
    check vm.entries.val[0].drawCallIndex == 1
    check vm.entries.val[0].geid == 101'u64
    check vm.entries.val[0].testStatus.depth == "pass"
    check vm.entries.val[0].testStatus.blend == "applied"
    check vm.entries.val[1].shaderOutput.g == 1.0
    check vm.entries.val[1].drawCallIndex == 2
    check vm.entries.val[1].geid == 102'u64
    check vm.entries.val[1].testStatus.depth == "failed"
    check vm.entries.val[1].testStatus.cull == "pass"

    vm.dispose()

  test "clicking a pixel history entry routes a GEID seek":
    createRoot proc(dispose: proc()) =
      let fake = makeFakeClient()
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createPixelHistoryVM(fake.client, store)

      vm.loadPixelHistory(10, 20, 0)
      drain()
      vm.selectEntry(1)

      check vm.selectedEntry.val == some(1)
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == SeekToGeidCommand
      check mock.receivedCommands[0].args["geid"].getBiggestInt == 102

      dispose()

  # M6: explicit source-jump entry-point tests.  The whole-row click path
  # exercised by ``selectEntry`` above is the user-facing affordance, but the
  # public ``jumpToSourceForEntry`` proc is the contract any future
  # alternative trigger (icon button, context menu, keyboard shortcut)
  # should call.  These tests pin the input → backend-command shape and the
  # defensive edge cases the spec leaves underspecified.
  test "jumpToSourceForEntry dispatches ct/seek-to-geid for the entry's GEID":
    createRoot proc(dispose: proc()) =
      let fake = makeFakeClient()
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createPixelHistoryVM(fake.client, store)

      vm.loadPixelHistory(10, 20, 0)
      drain()
      let dispatched = vm.jumpToSourceForEntry(0)

      check dispatched
      # The whole-row click handler is NOT triggered here — we only
      # exercise ``jumpToSourceForEntry`` — so ``selectedEntry`` stays
      # at its initial ``none`` and the seek command is the only call
      # routed through the store.
      check vm.selectedEntry.val.isNone
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == SeekToGeidCommand
      check mock.receivedCommands[0].args["geid"].getBiggestInt == 101

      dispose()

  test "jumpToSourceForEntry is a no-op for out-of-range indices":
    createRoot proc(dispose: proc()) =
      let fake = makeFakeClient()
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createPixelHistoryVM(fake.client, store)

      vm.loadPixelHistory(10, 20, 0)
      drain()

      check not vm.jumpToSourceForEntry(-1)
      check not vm.jumpToSourceForEntry(999)
      check mock.receivedCommands.len == 0

      dispose()

  test "jumpToSourceForEntry skips entries with no source mapping (geid == 0)":
    createRoot proc(dispose: proc()) =
      let fake = makeFakeClient()
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createPixelHistoryVM(fake.client, store)

      # Inject a synthetic entry whose GEID is 0 — this models a draw
      # call that the backend could not resolve to a source location
      # (e.g. a generated shader-compile step that has no user-facing
      # line).  The spec leaves the UX undefined; the defensive choice
      # is a silent no-op rather than misleading the editor.
      vm.entries.val = @[
        VisualReplayPixelHistoryEntry(
          geid: 0'u64,
          drawCallIndex: 7,
          passed: true,
          testStatus: VisualReplayPixelTestStatus(
            depth: "pass", stencil: "pass", blend: "applied", cull: "pass"))]

      check not vm.jumpToSourceForEntry(0)
      check mock.receivedCommands.len == 0

      dispose()

  test "jumpToSourceForEntry is a no-op when no replay store is wired":
    # When the PixelHistoryVM is constructed without a ReplayDataStore
    # (e.g. early bootstrap or unit tests that don't need backend
    # plumbing), the source-jump path must remain inert — there is no
    # transport to dispatch ``ct/seek-to-geid`` on — but it must still
    # be safe to call from view code.
    let fake = makeFakeClient()
    let vm = createPixelHistoryVM(fake.client)

    vm.loadPixelHistory(10, 20, 0)
    drain()

    check not vm.jumpToSourceForEntry(0)

    vm.dispose()

suite "ShaderDebugVM":
  test "parses real ct_gfx_player shader debug response":
    let payload = parseJson("""
      {
        "drawCallIndex": 236,
        "geid": 16810,
        "vertexShaderSource": "#version 300 es\nvoid main() {}\n",
        "fragmentShaderSource": "#version 300 es\nprecision mediump float;\nout vec4 fragColor;\nvoid main() {\n  fragColor = vec4(1.0);\n}\n",
        "outputColor": [184, 126, 69, 255]
      }
    """)

    let info = shaderDebugInfoFromJson(payload)

    check info.shaderStage == "fragment"
    check info.entryPoint == "main"
    check info.source.contains("fragColor")
    check info.sourceLines.len > 0
    check info.steps.len == 0

  test "test_shader_debug_vm_steps_interpreter_trace":
    let fake = makeFakeClient()
    let vm = createShaderDebugVM(fake.client)

    vm.loadFromPixel(12, 34, 1, some(210'u64))
    drain()

    check fake.shaderDebugRequests.len == 1
    check fake.shaderDebugRequests[0].x == 12
    check fake.shaderDebugRequests[0].y == 34
    check fake.shaderDebugRequests[0].frame == some(1)
    check fake.shaderDebugRequests[0].geid == some(210'u64)
    check vm.debugInfo.val.isSome
    check vm.debugInfo.val.get.steps.len == 3
    check vm.currentStepIndex.val == 0
    check vm.currentSourceLine() == 2
    check vm.currentStep().get.variables[0].name == "v_uv"
    check vm.currentStep().get.registers[0].value == "input.v_uv"
    check vm.currentStep().get.instruction == "OpLoad %v_uv"

    vm.stepForward()
    check vm.currentStepIndex.val == 1
    check vm.currentSourceLine() == 5
    check vm.currentStep().get.variables[0].name == "base"
    check vm.currentStep().get.registers[0].name == "%18"

    vm.stepForward()
    check vm.currentStepIndex.val == 2
    check vm.currentSourceLine() == 6
    check vm.currentStep().get.variables[0].name == "out_color"
    check vm.currentStep().get.registers[0].value == "rgba"

    vm.stepBackward()
    check vm.currentStepIndex.val == 1
    check vm.currentStep().get.instruction == "OpCompositeConstruct %base"

    vm.dispose()
