## IsoNim DOM-rendering view for the Visual Replay Video Player panel.
##
## Renders the transport chrome (Play/Pause/scrub/FF/RW/Step/Picker), the
## frame canvas, and the magnifier loupe overlay used by picker mode. State
## comes from VideoPlayerVM; frame fetching is still owned by the wrapped
## FrameViewerVM.
##
## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md

import std/[options, strformat]

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/dom_api as isonim_dom
  import isonim/web/web_renderer

import ../viewmodels/frame_viewer_vm
import ../viewmodels/video_player_vm
import ../viewmodels/visual_replay_client

# ---------------------------------------------------------------------------
# Display helpers.
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc playStateLabel(vm: VideoPlayerVM): string =
  if vm.playState.val == Playing: "Pause" else: "Play"

proc playStateIcon(vm: VideoPlayerVM): string =
  if vm.playState.val == Playing: "⏸" else: "▶"

proc rateBadge(vm: VideoPlayerVM): string =
  if vm.playState.val == Playing:
    let arrow = if vm.direction.val == Forward: "▶" else: "◀"
    arrow & " " & $int(vm.rate.val) & "×"
  else:
    "Paused"

proc bufferingDisplay(vm: VideoPlayerVM): string =
  displayIf(vm.bufferingDegraded.val and vm.playState.val == Playing)

proc currentFrameLabel(vm: VideoPlayerVM): string =
  let total = vm.frameVm.frameCount.val
  if total > 0:
    "Frame " & $vm.frameVm.currentFrame.val & " / " & $(total - 1)
  else:
    "Frame " & $vm.frameVm.currentFrame.val

proc currentDrawLabel(vm: VideoPlayerVM): string =
  let calls = vm.frameVm.drawCalls.val
  if vm.frameVm.selectedDrawCall.val.isSome:
    "Draw " & $vm.frameVm.selectedDrawCall.val.get & " / " &
      (if calls.len > 0: $(calls.len - 1) else: "?")
  elif calls.len > 0:
    "Draw 0 / " & $(calls.len - 1)
  else:
    ""

proc frameImageDisplay(vm: VideoPlayerVM): string =
  displayIf(vm.frameVm.frameImageSrc.val.len > 0 and not vm.frameVm.loading.val)

proc loadingDisplay(vm: VideoPlayerVM): string =
  displayIf(vm.frameVm.loading.val)

proc errorDisplay(vm: VideoPlayerVM): string =
  displayIf(vm.frameVm.error.val.len > 0)

proc emptyDisplay(vm: VideoPlayerVM): string =
  displayIf(vm.frameVm.frameImageSrc.val.len == 0 and
            not vm.frameVm.loading.val and
            vm.frameVm.error.val.len == 0)

proc magnifierDisplay(vm: VideoPlayerVM): string =
  displayIf(vm.pickerState.val == PickerActive and vm.magnifier.val.isSome)

proc rootClassFor(vm: VideoPlayerVM; baseClass: string): string =
  if vm.pickerState.val == PickerActive:
    baseClass & " picker-active"
  else:
    baseClass

proc pickerButtonClass(vm: VideoPlayerVM): string =
  if vm.pickerState.val == PickerActive:
    "video-player-button video-player-picker pressed"
  else:
    "video-player-button video-player-picker"

proc canvasOverlayClass(vm: VideoPlayerVM): string =
  if vm.pickerState.val == PickerActive:
    "video-player-canvas-overlay picker"
  else:
    "video-player-canvas-overlay"

proc maxFrameValue(vm: VideoPlayerVM): string =
  if vm.frameVm.frameCount.val > 0: $(vm.frameVm.frameCount.val - 1) else: "0"

proc currentFrameValue(vm: VideoPlayerVM): string =
  $vm.frameVm.currentFrame.val

proc magnifierStyle(vm: VideoPlayerVM): string =
  if vm.magnifier.val.isNone: return ""
  let m = vm.magnifier.val.get
  ## Position the loupe slightly above-right of the cursor so it doesn't
  ## occlude the pixel being inspected.
  &"left: {m.displayX + 24:.0f}px; top: {m.displayY - 96:.0f}px;"

proc magnifierReadout(vm: VideoPlayerVM): string =
  if vm.magnifier.val.isNone: return ""
  let m = vm.magnifier.val.get
  &"x={m.sourceX} y={m.sourceY}  frame {vm.frameVm.currentFrame.val}"

proc selectedPixelText(vm: VideoPlayerVM): string =
  let pixel = vm.frameVm.selectedPixel.val
  if pixel.isSome:
    "Selected: " & $pixel.get.x & ", " & $pixel.get.y
  else:
    "No pixel selected"

# ---------------------------------------------------------------------------
# Event handlers (button onclicks).
# ---------------------------------------------------------------------------

proc onPlayClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.togglePlay()

proc onFastForwardClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.fastForward()

proc onRewindClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.rewind()

proc onJumpStartClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.jumpToStart()

proc onJumpEndClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.jumpToEnd()

proc onStepFrameBackClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.stepFrame(-1)

proc onStepFrameForwardClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.stepFrame(1)

proc onStepDrawBackClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.stepDrawCall(-1)

proc onStepDrawForwardClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.stepDrawCall(1)

proc onPickerClick(vm: VideoPlayerVM): proc() =
  result = proc() = vm.togglePicker()

# ---------------------------------------------------------------------------
# Template.
# ---------------------------------------------------------------------------

template renderVideoPlayerPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClassFor(vm, rootClass)):
      ## --- Canvas area -----------------------------------------------------
      tdiv(class = "video-player-stage"):
        tdiv(class = "video-player-empty", display = emptyDisplay(vm)):
          text "No visual recording loaded"
        tdiv(class = "video-player-loading", display = loadingDisplay(vm)):
          text "Loading frame…"
        tdiv(class = "video-player-error", display = errorDisplay(vm)):
          text vm.frameVm.error.val
        img(class = "video-player-image",
            src = vm.frameVm.frameImageSrc.val,
            alt = "Visual replay frame",
            display = frameImageDisplay(vm))
        ## Picker mode overlay — the click handler installed in mount lifts
        ## the click into commitPickedPixel() via the magnifier coordinates.
        tdiv(class = canvasOverlayClass(vm)):
          text ""
        ## Magnifier loupe (positioned via inline style driven by the
        ## magnifier signal). The pixel grid inside the loupe is rendered by
        ## a JS routine bound at mount time onto the .video-player-loupe-canvas
        ## element below.
        tdiv(class = "video-player-loupe",
             display = magnifierDisplay(vm),
             style = magnifierStyle(vm)):
          canvas(class = "video-player-loupe-canvas",
                 width = "120",
                 height = "120"):
            text ""
          tdiv(class = "video-player-loupe-readout"):
            text magnifierReadout(vm)
      ## --- Transport bar ---------------------------------------------------
      tdiv(class = "video-player-transport"):
        button(class = "video-player-button video-player-jump-start",
               title = "Jump to start (Home)",
               onclick = onJumpStartClick(vm)):
          text "⏮"
        button(class = "video-player-button video-player-rewind",
               title = "Rewind / cycle reverse speed (J)",
               onclick = onRewindClick(vm)):
          text "⏪"
        button(class = "video-player-button video-player-play",
               title = "Play / Pause (Space)",
               onclick = onPlayClick(vm)):
          text playStateIcon(vm)
        button(class = "video-player-button video-player-fast-forward",
               title = "Fast forward / cycle speed (L)",
               onclick = onFastForwardClick(vm)):
          text "⏩"
        button(class = "video-player-button video-player-jump-end",
               title = "Jump to end (End)",
               onclick = onJumpEndClick(vm)):
          text "⏭"
        tdiv(class = "video-player-divider"):
          text ""
        button(class = "video-player-button video-player-step-draw-back",
               title = "Previous draw call (Shift+←)",
               onclick = onStepDrawBackClick(vm)):
          text "⏷←"
        button(class = "video-player-button video-player-step-draw-forward",
               title = "Next draw call (Shift+→)",
               onclick = onStepDrawForwardClick(vm)):
          text "⏷→"
        tdiv(class = "video-player-divider"):
          text ""
        button(class = "video-player-button video-player-step-frame-back",
               title = "Previous frame (←)",
               onclick = onStepFrameBackClick(vm)):
          text "⇕←"
        button(class = "video-player-button video-player-step-frame-forward",
               title = "Next frame (→)",
               onclick = onStepFrameForwardClick(vm)):
          text "⇕→"
        tdiv(class = "video-player-divider"):
          text ""
        button(class = pickerButtonClass(vm),
               title = "Pixel picker (P)",
               onclick = onPickerClick(vm)):
          text "🎯"
        tdiv(class = "video-player-rate-badge"):
          text rateBadge(vm)
        tdiv(class = "video-player-buffering",
             display = bufferingDisplay(vm),
             title = "Frame fetch behind playback rate"):
          text "●"
      ## --- Scrub slider ----------------------------------------------------
      tdiv(class = "video-player-scrubber"):
        input(class = "video-player-scrub-range",
              `type` = "range",
              min = "0",
              max = maxFrameValue(vm),
              value = currentFrameValue(vm))
        tdiv(class = "video-player-scrub-labels"):
          tdiv(class = "video-player-frame-label"):
            text currentFrameLabel(vm)
          tdiv(class = "video-player-draw-label"):
            text currentDrawLabel(vm)
          tdiv(class = "video-player-selected-pixel"):
            text selectedPixelText(vm)

proc renderVideoPlayerPanel*(r: MockRenderer; vm: VideoPlayerVM): MockNode =
  renderVideoPlayerPanelImpl(r, vm, "video-player-component")

# ---------------------------------------------------------------------------
# Web-only mounting and DOM event wiring.
# ---------------------------------------------------------------------------

when defined(js):
  ## Bind canvas-area mouse events to the picker pipeline. The cursor's
  ## position over .video-player-image is reported back to the VM as
  ## (renderedX, renderedY, renderedWidth, renderedHeight); the VM converts
  ## to source-pixel coordinates.
  proc setCanvasMouseHandlers(
      panel: isonim_dom.Element;
      onMouseMove: proc(renderedX, renderedY, renderedWidth,
                        renderedHeight: float) {.closure.};
      onClick: proc(renderedX, renderedY, renderedWidth,
                    renderedHeight: float) {.closure.})
      {.importjs: """
        (function(panel, onMouseMove, onClick) {
          function imageForEvent(event) {
            return event.target && event.target.closest
              ? event.target.closest(".video-player-stage")?.querySelector(".video-player-image")
              : null;
          }
          panel.addEventListener("mousemove", function(event) {
            const image = imageForEvent(event);
            if (!image) return;
            const rect = image.getBoundingClientRect();
            const x = event.clientX - rect.left;
            const y = event.clientY - rect.top;
            if (x < 0 || y < 0 || x >= rect.width || y >= rect.height) return;
            onMouseMove(x, y, rect.width, rect.height);
          });
          panel.addEventListener("mouseleave", function() {
            onMouseMove(-1, -1, 0, 0);
          });
          panel.addEventListener("click", function(event) {
            const image = imageForEvent(event);
            if (!image) return;
            const rect = image.getBoundingClientRect();
            onClick(
              event.clientX - rect.left,
              event.clientY - rect.top,
              rect.width,
              rect.height
            );
          });
        })(#, #, #);
      """.}

  proc setScrubRangeHandler(input: isonim_dom.Element; vm: VideoPlayerVM)
      {.importjs: """
        #.addEventListener("input", function(event) {
          #.scrubTo(Number(event.target.value || 0));
        });
      """.}

  proc querySelector(node: isonim_dom.Element;
                     selector: cstring): isonim_dom.Element
      {.importjs: "#.querySelector(#)".}

  proc isNilElement(node: isonim_dom.Element): bool
      {.importjs: "# == null".}

  proc renderVideoPlayerPanel*(r: WebRenderer;
                               vm: VideoPlayerVM): isonim_dom.Element =
    renderVideoPlayerPanelImpl(r, vm,
      "video-player-component isonim-video-player")

  proc mountIsoNimVideoPlayer*(container: isonim_dom.Element;
                               vm: VideoPlayerVM) =
    let r = WebRenderer()
    let panel = renderVideoPlayerPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))

    setCanvasMouseHandlers(panel,
      proc(renderedX, renderedY, renderedWidth, renderedHeight: float) =
        ## mouseleave reports (-1, -1, 0, 0); treat as "hide magnifier".
        if renderedWidth <= 0 or renderedHeight <= 0:
          vm.magnifier.val = none(MagnifierPosition)
          return
        vm.updateMagnifier(renderedX, renderedY, renderedWidth, renderedHeight),
      proc(renderedX, renderedY, renderedWidth, renderedHeight: float) =
        if vm.pickerState.val == PickerActive:
          ## Make sure the magnifier reflects the click position before
          ## commit (covers the "click without prior mousemove" path).
          vm.updateMagnifier(renderedX, renderedY,
                             renderedWidth, renderedHeight)
          vm.commitPickedPixel()
        else:
          ## Fallback: clicks outside picker mode still update the pixel
          ## selection — useful for the existing pixel-history workflow.
          vm.frameVm.selectPixelFromRenderedPoint(
            renderedX, renderedY, renderedWidth, renderedHeight))

    let scrub = querySelector(panel, cstring".video-player-scrub-range")
    if not isNilElement(scrub):
      setScrubRangeHandler(scrub, vm)
