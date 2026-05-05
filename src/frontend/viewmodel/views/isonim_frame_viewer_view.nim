## IsoNim DOM-rendering view for the visual replay Frame Viewer panel.

import std/options

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/dom_api as isonim_dom
  import isonim/web/web_renderer

import ../viewmodels/frame_viewer_vm
import ../viewmodels/visual_replay_client

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc frameStatusText(vm: FrameViewerVM): string =
  if vm.currentGeid.val.isSome:
    "GEID " & $vm.currentGeid.val.get
  else:
    "Frame " & $vm.currentFrame.val

proc frameCountText(vm: FrameViewerVM): string =
  if vm.frameCount.val > 0: " / " & $(vm.frameCount.val - 1) else: ""

proc connectionStatusText(vm: FrameViewerVM): string =
  if not vm.visualReplayAvailable.val:
    "Visual replay absent"
  elif vm.playerUrl.val.len > 0:
    "Visual replay connected"
  else:
    "Visual replay not connected"

proc connectionStatusClass(vm: FrameViewerVM): string =
  if not vm.visualReplayAvailable.val:
    "frame-viewer-connection-status absent"
  elif vm.playerUrl.val.len > 0:
    "frame-viewer-connection-status connected"
  else:
    "frame-viewer-connection-status disconnected"

proc selectedPixelText(vm: FrameViewerVM): string =
  let pixel = vm.selectedPixel.val
  if pixel.isSome:
    "Pixel " & $pixel.get.x & ", " & $pixel.get.y
  else:
    "No pixel selected"

proc drawCallClass(vm: FrameViewerVM; index: int): string =
  if vm.selectedDrawCall.val.isSome and vm.selectedDrawCall.val.get == index:
    "frame-viewer-draw-call selected"
  else:
    "frame-viewer-draw-call"

proc drawCallText(call: VisualReplayDrawCall): string =
  "#" & $call.index & " " & call.name & " GEID " & $call.geid

proc imageAltText(vm: FrameViewerVM): string =
  "Visual replay " & frameStatusText(vm)

proc emptyDisplay(vm: FrameViewerVM): string =
  displayIf(vm.frameImageSrc.val.len == 0 and not vm.loading.val and
    vm.error.val.len == 0)

proc imageDisplay(vm: FrameViewerVM): string =
  displayIf(vm.frameImageSrc.val.len > 0)

proc loadingDisplay(vm: FrameViewerVM): string =
  displayIf(vm.loading.val)

proc errorDisplay(vm: FrameViewerVM): string =
  displayIf(vm.error.val.len > 0)

proc frameInputValue(vm: FrameViewerVM): string =
  $vm.currentFrame.val

proc maxFrameValue(vm: FrameViewerVM): string =
  if vm.frameCount.val > 0: $(vm.frameCount.val - 1) else: "0"

proc onDrawCallClick(vm: FrameViewerVM; index: int): proc() =
  let captured = index
  result = proc() = vm.selectDrawCall(captured)

template renderFrameViewerPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "frame-viewer-toolbar"):
        span(class = "frame-viewer-player-url"):
          text vm.playerUrl.val
        span(class = connectionStatusClass(vm)):
          text connectionStatusText(vm)
        tdiv(class = "frame-viewer-frame-controls"):
          button(class = "frame-viewer-prev-frame",
                 onclick = proc() = vm.previousFrame()):
            text "<"
          span(class = "frame-viewer-frame-label"):
            text frameStatusText(vm)
            text frameCountText(vm)
          button(class = "frame-viewer-next-frame",
                 onclick = proc() = vm.nextFrame()):
            text ">"
      tdiv(class = "frame-viewer-scrubber"):
        input(class = "frame-viewer-frame-range",
              `type` = "range",
              min = "0",
              max = maxFrameValue(vm),
              value = frameInputValue(vm))
      tdiv(class = "frame-viewer-body"):
        tdiv(class = "frame-viewer-frame-stage"):
          tdiv(class = "frame-viewer-empty", display = emptyDisplay(vm)):
            text "No frame loaded"
          tdiv(class = "frame-viewer-loading", display = loadingDisplay(vm)):
            text "Loading frame..."
          tdiv(class = "frame-viewer-error", display = errorDisplay(vm)):
            text vm.error.val
          img(class = "frame-viewer-image",
              src = vm.frameImageSrc.val,
              alt = imageAltText(vm),
              display = imageDisplay(vm))
        tdiv(class = "frame-viewer-side-panel"):
          tdiv(class = "frame-viewer-selected-pixel"):
            text selectedPixelText(vm)
          tdiv(class = "frame-viewer-draw-calls"):
            tdiv(class = "frame-viewer-draw-calls-header"):
              text "Draw Calls"
            if vm.drawCalls.val.len == 0:
              tdiv(class = "frame-viewer-draw-calls-empty"):
                text "No draw calls"
            for i, call in vm.drawCalls.val:
              button(class = drawCallClass(vm, i),
                     onclick = onDrawCallClick(vm, i)):
                span(class = "frame-viewer-draw-call-name"):
                  text drawCallText(call)
                span(class = "frame-viewer-draw-call-pipeline"):
                  text call.pipeline

proc renderFrameViewerPanel*(r: MockRenderer; vm: FrameViewerVM): MockNode =
  renderFrameViewerPanelImpl(r, vm, "frame-viewer-component")

when defined(js):
  proc setImageClickHandler(image: isonim_dom.Element; vm: FrameViewerVM)
      {.importjs: """
        (function(image, vm) {
          image.addEventListener("click", function(event) {
            const rect = image.getBoundingClientRect();
            vm.selectPixelFromRenderedPoint(
            event.clientX - rect.left,
            event.clientY - rect.top,
            rect.width,
            rect.height
            );
          });
        })(#, #);
      """.}

  proc setFrameRangeInputHandler(input: isonim_dom.Element; vm: FrameViewerVM)
      {.importjs: """
        #.addEventListener("input", function(event) {
          #.loadFrameByIndex(Number(event.target.value || 0));
        });
      """.}

  proc querySelector(node: isonim_dom.Element; selector: cstring): isonim_dom.Element
      {.importjs: "#.querySelector(#)".}

  proc isNilElement(node: isonim_dom.Element): bool {.importjs: "# == null".}

  proc renderFrameViewerPanel*(r: WebRenderer;
                               vm: FrameViewerVM): isonim_dom.Element =
    renderFrameViewerPanelImpl(r, vm,
      "frame-viewer-component isonim-frame-viewer")

  proc mountIsoNimFrameViewer*(container: isonim_dom.Element;
                               vm: FrameViewerVM) =
    let r = WebRenderer()
    let panel = renderFrameViewerPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
    let image = querySelector(panel, cstring".frame-viewer-image")
    if not isNilElement(image):
      setImageClickHandler(image, vm)
    let frameRange = querySelector(panel, cstring".frame-viewer-frame-range")
    if not isNilElement(frameRange):
      setFrameRangeInputHandler(frameRange, vm)
