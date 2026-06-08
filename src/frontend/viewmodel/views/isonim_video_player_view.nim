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

## Loupe geometry — keep these in lockstep with .video-player-loupe-canvas
## in styles/components/video_player.styl.
##
## Spec (Visual-Replay.md §Loupe Specification):
##   "Diameter: 120 px (configurable). Magnification: 8× (samples an 11×11
##    pixel neighbourhood…)"
##
## With an 11×11 grid at 8× we cover 88 px of the 120 px canvas; the
## remaining 32 px (16 on each side) is margin between the magnified pixels
## and the circular border, leaving room for the 2 px border + ring without
## visually crowding the centre marker.
const
  LoupeCanvasSize* = 120
  LoupeGridRadius* = 5            ## (11 - 1) / 2 — pixels on either side of centre
  LoupeGridSize* = LoupeGridRadius * 2 + 1   ## 11×11 sample grid
  LoupePixelScale* = 8           ## device pixels per source pixel
  LoupeGridPixels* = LoupeGridSize * LoupePixelScale   ## 88
  LoupeGridOffset* = (LoupeCanvasSize - LoupeGridPixels) div 2  ## 16

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

proc errorDisplay(vm: VideoPlayerVM): string {.used.} =
  ## Retained for tests that still query the old helper directly.
  ## Wired in M1; the M5 redesign replaces the centred error placeholder
  ## with a bottom-left red badge driven by ``playerErrorDisplay`` /
  ## ``transportDisabledClass``.
  displayIf(vm.frameVm.error.val.len > 0)

proc emptyDisplay(vm: VideoPlayerVM): string =
  ## "No visual recording loaded" — only when none of the other overlays
  ## (loading / error / startup spinner) are taking precedence and there
  ## is no image to show.
  displayIf(vm.frameVm.frameImageSrc.val.len == 0 and
            not vm.frameVm.loading.val and
            vm.frameVm.error.val.len == 0 and
            not isStartupSpinnerVisible(
              vm.frameVm.visualReplayAvailable.val,
              vm.frameVm.playerUrl.val,
              vm.frameVm.frameCount.val,
              vm.frameVm.error.val))

proc startupSpinnerDisplay(vm: VideoPlayerVM): string =
  ## Spec §Status Indicators — Player connecting: "Spinner badge over
  ## centre of canvas, 'Starting player…'.  ct_gfx_player process
  ## launched; waiting for /info to succeed."
  displayIf(isStartupSpinnerVisible(
    vm.frameVm.visualReplayAvailable.val,
    vm.frameVm.playerUrl.val,
    vm.frameVm.frameCount.val,
    vm.frameVm.error.val))

proc playerErrorDisplay(vm: VideoPlayerVM): string =
  ## Red badge bottom-left when the player process exits or returns an
  ## error.  Spec §Status Indicators / "Player error".
  displayIf(vm.frameVm.error.val.len > 0)

proc transportDisabledClass(vm: VideoPlayerVM): string =
  ## Spec §Status Indicators / "Player error": "controls disabled".
  ## Toggle a class on the whole transport bar; the CSS sets opacity
  ## and ``pointer-events: none`` so every button is greyed and
  ## inert in one place.
  if vm.frameVm.error.val.len > 0:
    "video-player-transport disabled"
  else:
    "video-player-transport"

proc scrubDisabledAttr(vm: VideoPlayerVM): string =
  ## Disable the scrub slider when the player has errored.
  if vm.frameVm.error.val.len > 0: "disabled" else: ""

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

proc magnifierColorReadout(vm: VideoPlayerVM): string =
  ## RGBA readout per spec: "RGBA channel values (0–1, four decimals)".
  ## Visual-Replay.md §Loupe Specification.
  let c = vm.magnifierCenterColor.val
  if c.isNone: return ""
  let v = c.get
  &"RGBA {v.r:0.4f} {v.g:0.4f} {v.b:0.4f} {v.a:0.4f}"

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
        ## M5: startup spinner overlay — centred badge over the canvas
        ## while /info has not yet succeeded.  Spec §Status Indicators
        ## / "Player connecting".  The spinning ring is pure CSS
        ## (see styles/components/video_player.styl
        ## .video-player-startup-spinner).
        tdiv(class = "video-player-startup",
             display = startupSpinnerDisplay(vm)):
          tdiv(class = "video-player-startup-spinner"):
            text ""
          tdiv(class = "video-player-startup-label"):
            text "Starting player…"
        ## M5: player-error badge — bottom-left red banner.  Spec
        ## §Status Indicators / "Player error".  The transport bar is
        ## visibly disabled in parallel via ``transportDisabledClass``.
        tdiv(class = "video-player-error",
             display = playerErrorDisplay(vm)):
          tdiv(class = "video-player-error-icon"):
            text "!"
          tdiv(class = "video-player-error-message"):
            text vm.frameVm.error.val
        img(class = "video-player-image",
            src = vm.frameVm.frameImageSrc.val,
            alt = "Visual replay frame",
            display = frameImageDisplay(vm))
        ## Hidden mirror canvas at 1:1 source resolution. The frame image is
        ## blitted here once per frame so the loupe can sample 11×11 pixel
        ## neighbourhoods cheaply (getImageData) without bouncing through
        ## another image load. Spec: Visual-Replay.md §Loupe Specification —
        ## "The source pixels come from a hidden <canvas> that mirrors the
        ## frame image at 1:1."
        canvas(class = "video-player-mirror-canvas"):
          text ""
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
          tdiv(class = "video-player-loupe-readout video-player-loupe-rgba"):
            text magnifierColorReadout(vm)
      ## --- Transport bar ---------------------------------------------------
      ## Class flips to ``video-player-transport disabled`` when the
      ## player has errored — CSS sets opacity + pointer-events: none
      ## so every button is greyed and inert in one place.  Spec
      ## §Status Indicators / "Player error".
      tdiv(class = transportDisabledClass(vm)):
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
        ## Clear-frame tick marks (Visual-Replay.md §Scrub Slider).
        ## ``layoutScrubTicks`` (video_player_vm.nim) maps the frame
        ## indices into 0..100 % positions across the track; each tick
        ## is an absolutely-positioned div whose ``left: <pct>%`` is
        ## set inline (CSS handles size + colour via
        ## ``.video-player-scrub-tick``).  The seq is fed by
        ## ``FrameViewerVM.clearFrames`` (M5-followup; populated by
        ## ``loadInfo`` from the ``/info`` ``clearFrames`` field).
        ## Empty input (legacy traces, no clear-frame metadata) →
        ## no ticks via the helper's early return.
        tdiv(class = "video-player-scrub-ticks"):
          # ``for tick in seq[ScrubTick]`` yields ``lent ScrubTick`` on
          # Nim 2.x, which cannot be captured by the closure inside
          # ``tdiv(... style = "...")``.  Copy the field eagerly into a
          # local ``float`` so the closure captures a plain value.
          for tick in layoutScrubTicks(
              vm.frameVm.clearFrames.val, vm.frameVm.frameCount.val):
            let leftPercent = tick.leftPercent
            tdiv(class = "video-player-scrub-tick",
                 style = "left: " & $leftPercent & "%"):
              text ""
        input(class = "video-player-scrub-range",
              `type` = "range",
              min = "0",
              max = maxFrameValue(vm),
              value = currentFrameValue(vm),
              disabled = scrubDisabledAttr(vm))
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

  # Listen for both "input" (live drag) and "change" (final value) so the
  # test harness's programmatic ``dispatchEvent("change")`` and a real
  # user's drag both feed the VM.  Pass the seek closure through Nim
  # rather than calling ``vm.scrubTo`` from raw JS — Nim's JS backend
  # otherwise dead-code-strips ``scrubTo`` because the raw JS body is
  # opaque to the compiler, leaving ``vm.scrubTo is not a function`` at
  # runtime.
  proc setScrubRangeHandler(input: isonim_dom.Element;
                            onSeek: proc(frame: int)) {.importjs: """
    (function(el, onSeek) {
      const handler = function(event) {
        onSeek(Number((event.target && event.target.value) || 0));
      };
      el.addEventListener("input", handler);
      el.addEventListener("change", handler);
    })(#, #);
  """.}

  proc querySelector(node: isonim_dom.Element;
                     selector: cstring): isonim_dom.Element
      {.importjs: "#.querySelector(#)".}

  proc isNilElement(node: isonim_dom.Element): bool
      {.importjs: "# == null".}

  ## Install the mirror-canvas binding + loupe renderer on the panel. The
  ## image's onload handler resizes the mirror to source resolution and
  ## blits the frame into it (the source for all loupe samples). The
  ## returned-as-a-side-effect `panel.__videoPlayerLoupe.render(...)`
  ## function is invoked from a reactive effect whenever the magnifier
  ## position or frame source changes.
  ##
  ## onCenterColor receives the RGBA channel values (0..1) of the centre
  ## sample so the VM can surface them to the loupe footer.
  proc installLoupeBindings(
      panel: isonim_dom.Element;
      gridRadius, pixelScale, gridOffset, canvasSize: int;
      onCenterColor: proc(r, g, b, a: float; valid: bool) {.closure.})
      {.importjs: """
        (function(panel, gridRadius, pixelScale, gridOffset, canvasSize, onCenterColor) {
          var image = panel.querySelector(".video-player-image");
          var mirror = panel.querySelector(".video-player-mirror-canvas");
          var loupe = panel.querySelector(".video-player-loupe-canvas");
          if (!image || !mirror || !loupe) return;

          // Hide the mirror canvas from layout but keep it in the DOM so its
          // 2D context survives across renders. We use !important via the
          // CSS rule for .video-player-mirror-canvas to win against any
          // sibling :nth-child styles.
          mirror.style.display = "none";

          var mirrorCtx = mirror.getContext("2d", { willReadFrequently: true });
          var loupeCtx = loupe.getContext("2d");
          if (!mirrorCtx || !loupeCtx) return;
          loupeCtx.imageSmoothingEnabled = false;
          mirrorCtx.imageSmoothingEnabled = false;

          function blitFrameToMirror() {
            // Source resolution is the natural size of the frame image.
            var w = image.naturalWidth | 0;
            var h = image.naturalHeight | 0;
            if (w <= 0 || h <= 0) return;
            if (mirror.width !== w) mirror.width = w;
            if (mirror.height !== h) mirror.height = h;
            mirrorCtx.clearRect(0, 0, w, h);
            try {
              mirrorCtx.drawImage(image, 0, 0);
            } catch (err) {
              // drawImage can throw for cross-origin images; we fail silent
              // and let the loupe remain blank rather than break the panel.
              console.warn("video player: mirror blit failed:", err);
            }
          }

          image.addEventListener("load", blitFrameToMirror);
          // If the image is already cached and complete, blit immediately.
          if (image.complete && image.naturalWidth > 0) {
            blitFrameToMirror();
          }

          function relativeLuminance(r, g, b) {
            // sRGB luminance; we only use it to pick the centre marker
            // colour, so the simple linear approximation is enough.
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
          }

          function clearLoupe() {
            loupeCtx.clearRect(0, 0, canvasSize, canvasSize);
            onCenterColor(0, 0, 0, 0, false);
          }

          panel.__videoPlayerLoupe = {
            render: function(sourceX, sourceY) {
              var w = mirror.width;
              var h = mirror.height;
              if (w <= 0 || h <= 0) {
                clearLoupe();
                return;
              }

              // The 11×11 sample window starts at (sourceX - gridRadius,
              // sourceY - gridRadius). Per spec edge handling we read each
              // pixel individually, leaving out-of-bounds samples as the
              // transparent black we just cleared the loupe to.
              loupeCtx.clearRect(0, 0, canvasSize, canvasSize);

              var startX = sourceX - gridRadius;
              var startY = sourceY - gridRadius;

              // Compute the intersection of the sample window with the
              // mirror so we only call getImageData once for the in-bounds
              // region — much faster than 121 1×1 reads.
              var sx = Math.max(0, startX);
              var sy = Math.max(0, startY);
              var ex = Math.min(w, startX + (gridRadius * 2 + 1));
              var ey = Math.min(h, startY + (gridRadius * 2 + 1));
              if (ex > sx && ey > sy) {
                var src = mirrorCtx.getImageData(sx, sy, ex - sx, ey - sy);
                // Paint each in-bounds sample as an 8×8 (pixelScale)
                // filled rect on the loupe.
                for (var gy = 0; gy < src.height; gy++) {
                  for (var gx = 0; gx < src.width; gx++) {
                    var idx = (gy * src.width + gx) * 4;
                    var r = src.data[idx];
                    var g = src.data[idx + 1];
                    var b = src.data[idx + 2];
                    var a = src.data[idx + 3] / 255;
                    var dx = gridOffset + (sx + gx - startX) * pixelScale;
                    var dy = gridOffset + (sy + gy - startY) * pixelScale;
                    loupeCtx.fillStyle = "rgba(" + r + "," + g + "," + b + "," + a + ")";
                    loupeCtx.fillRect(dx, dy, pixelScale, pixelScale);
                  }
                }
              }

              // Centre marker: 1 px ring around the central pixel block.
              // Colour inverts based on the underlying pixel luminance so it
              // remains visible on both light and dark samples (spec:
              // "highlighted with a 1 px white ring on black, inverting if
              // the underlying pixel is light").
              var centreInBounds = (sourceX >= 0 && sourceY >= 0 &&
                                    sourceX < w && sourceY < h);
              var cr = 0, cg = 0, cb = 0, ca = 0;
              if (centreInBounds) {
                var centrePixel = mirrorCtx.getImageData(sourceX, sourceY, 1, 1).data;
                cr = centrePixel[0];
                cg = centrePixel[1];
                cb = centrePixel[2];
                ca = centrePixel[3];
                onCenterColor(cr / 255, cg / 255, cb / 255, ca / 255, true);
              } else {
                onCenterColor(0, 0, 0, 0, false);
              }

              var ringColour =
                centreInBounds && relativeLuminance(cr, cg, cb) > 140
                  ? "rgb(0,0,0)" : "rgb(255,255,255)";
              var rx = gridOffset + gridRadius * pixelScale;
              var ry = gridOffset + gridRadius * pixelScale;
              loupeCtx.lineWidth = 1;
              loupeCtx.strokeStyle = ringColour;
              // Pixel-aligned half-step keeps the 1 px stroke crisp.
              loupeCtx.strokeRect(rx + 0.5, ry + 0.5, pixelScale - 1, pixelScale - 1);
            },
            clear: clearLoupe,
          };
        })(#, #, #, #, #, #);
      """.}

  proc renderLoupeAt(panel: isonim_dom.Element; sourceX, sourceY: int)
      {.importjs: """
        (function(p, x, y) {
          if (p.__videoPlayerLoupe) p.__videoPlayerLoupe.render(x, y);
        })(#, #, #);
      """.}

  ## True when ``ui/video_player.nim`` installed the Playwright
  ## ``__CODETRACER_TEST__`` test hook — i.e. when the renderer is
  ## running under ``startOptions.inTest``.  The flag exists outside
  ## ``data`` so the view module (which doesn't import ``data``) can
  ## still consult it.  Used to disable the auto-advance rAF loop in
  ## tests; see the comment at its install site below.
  proc isInTest(): bool {.importjs: """
    (function() {
      return typeof window !== "undefined"
          && typeof window.__CODETRACER_TEST__ === "object"
          && window.__CODETRACER_TEST__ !== null
          && typeof window.__CODETRACER_TEST__.videoPlayerAction === "function";
    })()
  """.}

  ## Install a single self-rescheduling requestAnimationFrame loop on
  ## the panel.  ``onTick`` is called with ``performance.now()`` on
  ## every frame; it is a no-op when paused (see
  ## ``VideoPlayerVM.tickPlayback``).  The handle is stowed on the
  ## panel so the harness can cancel it on unmount, even though the
  ## panel itself rarely unmounts in practice.
  ##
  ## Spec (Visual-Replay.md §Frame Rate and Buffering):
  ##   "Playback is paced by requestAnimationFrame; the player issues
  ##    HTTP frame requests with a coalescing serial so only the most
  ##    recent request's image is rendered."
  proc installPlaybackTickLoop(
      panel: isonim_dom.Element;
      onTick: proc(nowMs: float) {.closure.})
      {.importjs: """
        (function(panel, onTick) {
          if (panel.__videoPlayerTickHandle) return;
          var raf = (typeof window !== "undefined" &&
                     typeof window.requestAnimationFrame === "function")
            ? window.requestAnimationFrame.bind(window)
            : function(cb) { return setTimeout(function() { cb(Date.now()); }, 16); };
          function tick(now) {
            try {
              onTick(typeof now === "number" ? now : Date.now());
            } catch (err) {
              console.warn("video player tick error:", err);
            }
            panel.__videoPlayerTickHandle = raf(tick);
          }
          panel.__videoPlayerTickHandle = raf(tick);
        })(#, #);
      """.}

  proc clearLoupe(panel: isonim_dom.Element)
      {.importjs: """
        (function(p) {
          if (p.__videoPlayerLoupe) p.__videoPlayerLoupe.clear();
        })(#);
      """.}

  ## M2 historical note: a raw window-level Escape keydown handler used to
  ## live here (``installEscapeHandler``).  M4 retired it in favour of the
  ## standard ClientAction pipeline — ``ClientAction.videoPlayerCancelPicker``
  ## is registered through ``configureVideoPlayerShortcuts`` in
  ## ``ui/shortcuts.nim`` and routed onto ``VideoPlayerVM.cancelPicker`` via
  ## ``dispatchVideoPlayerAction``.  The new wiring respects focus scoping
  ## (only fires when the Video Player is focused or hovered) and falls
  ## through to ``aEscape`` when picker mode is inactive, so it can coexist
  ## with the other Escape consumers (modals, search bars, the active focus
  ## component's ``onEscape``).
  ## Spec: Visual-Replay.md §Pixel Picker Mode → Activation.

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
          vm.magnifierCenterColor.val = none(VisualReplayPixelColor)
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
      let capturedVm = vm
      setScrubRangeHandler(scrub, proc(frame: int) =
        capturedVm.scrubTo(frame))

    ## Loupe pixel-grid rendering. The JS side owns the mirror canvas and
    ## the per-frame blit; the Nim side drives it from a reactive effect
    ## that reads both the magnifier signal and frameImageSrc (so a frame
    ## change re-renders the loupe under a stationary cursor).
    installLoupeBindings(panel,
      LoupeGridRadius, LoupePixelScale, LoupeGridOffset, LoupeCanvasSize,
      proc(r, g, b, a: float; valid: bool) =
        if valid:
          vm.magnifierCenterColor.val = some(VisualReplayPixelColor(
            r: r, g: g, b: b, a: a))
        else:
          vm.magnifierCenterColor.val = none(VisualReplayPixelColor))

    createEffect proc() =
      ## Re-render whenever cursor moves OR the underlying frame image
      ## source changes (the latter so the loupe stays accurate when the
      ## frame advances under a stationary cursor — e.g. during scrub).
      let mag = vm.magnifier.val
      let imageSrc = vm.frameVm.frameImageSrc.val
      if mag.isNone or imageSrc.len == 0:
        clearLoupe(panel)
        return
      let m = mag.get
      renderLoupeAt(panel, m.sourceX, m.sourceY)

    ## M5: install the rAF auto-advance loop.  ``tickPlayback`` is a
    ## no-op when paused so the loop is cheap to keep running across
    ## the panel's lifetime — no install/uninstall on play/pause.
    ## Spec: Visual-Replay.md §Frame Rate and Buffering.
    ##
    ## Under Playwright (``startOptions.inTest``) the auto-advance
    ## clamp-and-pause behaviour races every "press FF, assert badge,
    ## press FF again" sequence: 60Hz rAF advances the 4-frame fake
    ## fixture past the end well before the spec lands its next FF
    ## invocation, which silently pauses the player and resets the
    ## rate cycle from 1× on the next press.  The keyboard-shortcuts
    ## spec asserts the documented 1× → 2× → 4× → 8× progression,
    ## which only holds when the VM stays in Playing between presses.
    ## Skipping the rAF in test mode preserves the deterministic state
    ## the spec needs without touching production code paths — the
    ## actual tick math is exercised headlessly by
    ## ``video_player_polish_test.nim``.
    if not isInTest():
      installPlaybackTickLoop(panel,
        proc(nowMs: float) =
          vm.tickPlayback(nowMs))

    ## Escape → cancelPicker now flows through the standard ClientAction
    ## pipeline registered in ``ui/shortcuts.nim`` (M4).  No raw keydown
    ## listener is installed here — the global Mousetrap wrapper for
    ## ``ClientAction.videoPlayerCancelPicker`` queries
    ## ``videoPlayerHasFocus()`` and ``vm.pickerState`` before delegating.
