## IsoNim DOM-rendering view for the visual replay Pixel History panel.

import std/[math, options, strformat]

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/dom_api as isonim_dom
  import isonim/web/web_renderer

import ../viewmodels/pixel_history_vm
import ../viewmodels/visual_replay_client

proc pixelText(vm: PixelHistoryVM): string =
  if vm.selectedPixel.val.isSome:
    let pixel = vm.selectedPixel.val.get
    "Pixel " & $pixel.x & ", " & $pixel.y & " frame " & $pixel.frame
  else:
    "No pixel selected"

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc colorCss(color: VisualReplayPixelColor): string =
  let r = int(round(max(0.0, min(color.r, 1.0)) * 255.0))
  let g = int(round(max(0.0, min(color.g, 1.0)) * 255.0))
  let b = int(round(max(0.0, min(color.b, 1.0)) * 255.0))
  let a = max(0.0, min(color.a, 1.0))
  &"rgba({r}, {g}, {b}, {a:.3f})"

proc colorText(color: VisualReplayPixelColor): string =
  &"{color.r:.2f}, {color.g:.2f}, {color.b:.2f}, {color.a:.2f}"

proc entryClass(vm: PixelHistoryVM; index: int): string =
  if vm.selectedEntry.val.isSome and vm.selectedEntry.val.get == index:
    "pixel-history-entry selected"
  else:
    "pixel-history-entry"

proc passText(entry: VisualReplayPixelHistoryEntry): string =
  if entry.passed:
    "Passed"
  elif entry.failureReason.len > 0:
    "Failed: " & entry.failureReason
  else:
    "Failed"

proc testsText(entry: VisualReplayPixelHistoryEntry): string =
  "Depth " & entry.testStatus.depth &
    "  Stencil " & entry.testStatus.stencil &
    "  Blend " & entry.testStatus.blend &
    "  Cull " & entry.testStatus.cull

proc onEntryClick(vm: PixelHistoryVM; index: int): proc() =
  let captured = index
  result = proc() = vm.selectEntry(captured)

template renderPixelHistoryPanelImpl(r, vm, rootClass: untyped): untyped =
  ui(r):
    tdiv(class = rootClass):
      tdiv(class = "pixel-history-header"):
        span(class = "pixel-history-title"):
          text "Pixel History"
        span(class = "pixel-history-pixel"):
          text pixelText(vm)
      tdiv(class = "pixel-history-loading", display = displayIf(vm.loading.val)):
        text "Loading pixel history..."
      tdiv(class = "pixel-history-error", display = displayIf(vm.error.val.len > 0)):
        text vm.error.val
      if vm.entries.val.len == 0 and not vm.loading.val and vm.error.val.len == 0:
        tdiv(class = "pixel-history-empty"):
          text "Click a frame pixel"
      tdiv(class = "pixel-history-list"):
        for i, entry in vm.entries.val:
          button(class = entryClass(vm, i),
                 `data-geid` = $entry.geid,
                 onclick = onEntryClick(vm, i)):
            tdiv(class = "pixel-history-entry-main"):
              span(class = "pixel-history-draw"):
                text "Draw " & $entry.drawCallIndex
              span(class = "pixel-history-geid"):
                text "GEID " & $entry.geid
              span(class = "pixel-history-pass"):
                text passText(entry)
            tdiv(class = "pixel-history-colors"):
              span(class = "pixel-history-color"):
                span(class = "pixel-history-swatch",
                     style = "background: " & colorCss(entry.preColor)):
                  text ""
                span(class = "pixel-history-color-label"):
                  text "Pre " & colorText(entry.preColor)
              span(class = "pixel-history-color"):
                span(class = "pixel-history-swatch",
                     style = "background: " & colorCss(entry.shaderOutput)):
                  text ""
                span(class = "pixel-history-color-label"):
                  text "Shader " & colorText(entry.shaderOutput)
              span(class = "pixel-history-color"):
                span(class = "pixel-history-swatch",
                     style = "background: " & colorCss(entry.postColor)):
                  text ""
                span(class = "pixel-history-color-label"):
                  text "Post " & colorText(entry.postColor)
            tdiv(class = "pixel-history-tests"):
              text testsText(entry)

proc renderPixelHistoryPanel*(r: MockRenderer; vm: PixelHistoryVM): MockNode =
  renderPixelHistoryPanelImpl(r, vm, "pixel-history-component")

when defined(js):
  proc renderPixelHistoryPanel*(r: WebRenderer;
                                vm: PixelHistoryVM): isonim_dom.Element =
    renderPixelHistoryPanelImpl(r, vm,
      "pixel-history-component isonim-pixel-history")

  proc mountIsoNimPixelHistory*(container: isonim_dom.Element;
                                vm: PixelHistoryVM) =
    let r = WebRenderer()
    let panel = renderPixelHistoryPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
