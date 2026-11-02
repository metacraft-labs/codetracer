## IsoNim DOM-rendering view for the visual replay Pixel History panel.

import std/[math, options, strformat]

import isonim/core/[computation, signals]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

import ../viewmodels/pixel_history_vm
import ../viewmodels/visual_replay_client

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

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

proc showsEmptyHint(vm: PixelHistoryVM): bool =
  vm.entries.val.len == 0 and not vm.loading.val and vm.error.val.len == 0

proc renderPixelHistoryEntry[R, N](r: R; vm: PixelHistoryVM;
                                   entry: proc(): VisualReplayPixelHistoryEntry;
                                   index: int): N =
  ## One draw call that touched the pixel. M6: the whole row is the "jump to
  ## source" affordance — clicking routes through ``selectEntry`` which calls
  ## ``jumpToSourceForEntry`` and, via the backend's ``ct/seek-to-geid`` →
  ## ``complete-move`` chain, opens the source file at the line that issued
  ## this draw call. The ``title`` is the discoverability cue the spec asks
  ## for ("click an entry... to jump the editor"); entries with no source
  ## mapping (``geid == 0``) are silently no-ops at the VM layer.
  ui(r):
    button(class = entryClass(vm, index),
           `data-geid` = $entry().geid,
           title = "Click to jump to the source line that issued draw " &
                    $entry().drawCallIndex,
           onclick = onEntryClick(vm, index)):
      tdiv(class = "pixel-history-entry-main"):
        span(class = "pixel-history-draw"):
          text "Draw " & $entry().drawCallIndex
        span(class = "pixel-history-geid"):
          text "GEID " & $entry().geid
        span(class = "pixel-history-pass"):
          text passText(entry())
      tdiv(class = "pixel-history-colors"):
        span(class = "pixel-history-color"):
          span(class = "pixel-history-swatch",
               style = "background: " & colorCss(entry().preColor)):
            text ""
          span(class = "pixel-history-color-label"):
            text "Pre " & colorText(entry().preColor)
        span(class = "pixel-history-color"):
          span(class = "pixel-history-swatch",
               style = "background: " & colorCss(entry().shaderOutput)):
            text ""
          span(class = "pixel-history-color-label"):
            text "Shader " & colorText(entry().shaderOutput)
        span(class = "pixel-history-color"):
          span(class = "pixel-history-swatch",
               style = "background: " & colorCss(entry().postColor)):
            text ""
          span(class = "pixel-history-color-label"):
            text "Post " & colorText(entry().postColor)
      tdiv(class = "pixel-history-tests"):
        text testsText(entry())

proc renderPixelHistoryPanel*[R, N](r: R; vm: PixelHistoryVM): N =
  ## The Pixel History panel, under any renderer (Shared-DOM-Front-Ends D3).
  ## The empty hint and the entry list follow the ViewModel reactively
  ## (`show`, `indexEach`); the panel host (`ui/panel_host`) mounts it.
  var emptySlot, list: N
  let panel = ui(r):
    tdiv(class = "pixel-history-component isonim-pixel-history"):
      tdiv(class = "pixel-history-header"):
        span(class = "pixel-history-title"):
          text "Pixel History"
        span(class = "pixel-history-pixel"):
          text pixelText(vm)
      tdiv(class = "pixel-history-loading", display = displayIf(vm.loading.val)):
        text "Loading pixel history..."
      tdiv(class = "pixel-history-error", display = displayIf(vm.error.val.len > 0)):
        text vm.error.val
      tdiv(ref = emptySlot):
        discard
      tdiv(class = "pixel-history-list", ref = list):
        discard
  show(r, emptySlot,
    proc(): bool = showsEmptyHint(vm),
    proc(): N =
      ui(r):
        tdiv(class = "pixel-history-empty"):
          text "Click a frame pixel")
  indexEach[VisualReplayPixelHistoryEntry, R, N](r, list,
    proc(): seq[VisualReplayPixelHistoryEntry] = vm.entries.val,
    proc(entry: proc(): VisualReplayPixelHistoryEntry; index: int): N =
      renderPixelHistoryEntry[R, N](r, vm, entry, index))
  panel
