## IsoNim DOM-rendering view for the visual replay Pixel History panel.

import std/[math, options, strformat]

import isonim/core/[computation, signals]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

import ../viewmodels/pixel_history_vm
import ../viewmodels/visual_replay_client

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc colorCss(color: VisualReplayPixelColor): string =
  let r = colorByte(color.r)
  let g = colorByte(color.g)
  let b = colorByte(color.b)
  let a = max(0.0, min(color.a, 1.0))
  &"rgba({r}, {g}, {b}, {a:.3f})"

proc entryClass(vm: PixelHistoryVM; index: int): string =
  if vm.selectedEntry.val.isSome and vm.selectedEntry.val.get == index:
    "pixel-history-entry selected"
  else:
    "pixel-history-entry"

# An entry's press is the pointer row `pixel-history.activate`, performed by
# the front-end on the entry's `data-pixel-history-index` (on the desktop
# `ui/pixel_history.nim`'s procedure).

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
           `data-pixel-history-index` = $index):
      tdiv(class = "pixel-history-entry-main"):
        span(class = "pixel-history-draw"):
          text drawText(entry())
        span(class = "pixel-history-geid"):
          text geidText(entry())
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
          text PixelHistoryHeading
        span(class = "pixel-history-pixel"):
          text pixelText(vm)
      tdiv(class = "pixel-history-loading", display = displayIf(vm.loading.val)):
        text PixelHistoryLoadingText
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
          text PixelHistoryEmptyText)
  indexEach[VisualReplayPixelHistoryEntry, R, N](r, list,
    proc(): seq[VisualReplayPixelHistoryEntry] = vm.entries.val,
    proc(entry: proc(): VisualReplayPixelHistoryEntry; index: int): N =
      renderPixelHistoryEntry[R, N](r, vm, entry, index))
  panel
