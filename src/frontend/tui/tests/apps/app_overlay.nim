## app_overlay.nim — CTUI-2 snapshot app: layers and opaque fills.
##
## ## What an overlay is in this compositor, measured rather than assumed
##
## `compositor.layerFromStyle` reads `layer: N` and `position: overlay`, and
## `compositor.render` sorts entries by layer with a stable sort before
## compositing, so a higher layer is painted last and wins. A node on a layer
## above 0 also gets `fillBackground: true` unconditionally
## (`walkLayoutImpl`), which is what gives an overlay the "masking" property —
## its styled blanks overwrite the whole of its span rather than letting the
## layer below show through.
##
## What it does NOT do today is put two entries on the same ROW. The walker's
## row counter increments once per emitted entry, so an overlay occupies rows
## of its own and there is no geometric overlap to test. This app therefore
## exercises the two halves that DO exist — layer ordering and the opaque fill
## — and the third is written down here rather than implied by the filename.
## The opaque fill is the more valuable of the two for a cross-tier comparison
## anyway: it is the only construction that produces a screen full of BLANK
## CELLS THAT CARRY STYLE, which is where a compositor's idea of a row and a
## terminal's idea of a row diverge most quietly, because plaintext cannot see
## the difference at all and only `cellmap.json` can.

import std/strutils

import isonim_tui

proc rowNode(r: TerminalRenderer; text: string): TerminalNode =
  result = r.createElement("div")
  r.appendChild(result, r.createTextNode(text))

proc layeredRow(r: TerminalRenderer; text, layer, fg, bg: string): TerminalNode =
  result = r.createElement("div")
  r.setStyle(result, "layer", layer)
  r.setStyle(result, "color", fg)
  r.setStyle(result, "background-color", bg)
  r.appendChild(result, r.createTextNode(text))

proc buildTree*(r: TerminalRenderer): TerminalNode =
  let root = r.createElement("div")
  for i in 0 ..< 8:
    r.appendChild(root, rowNode(r,
      "base row " & align($i, 2, '0') & " " & "▒".repeat(60)))

  # `position: overlay` — the spelling that promotes to layer 1 without naming
  # a number.
  let promoted = r.createElement("div")
  r.setStyle(promoted, "position", "overlay")
  r.setStyle(promoted, "color", "bright_white")
  r.setStyle(promoted, "background-color", "blue")
  r.appendChild(promoted, r.createTextNode("position:overlay — promoted to layer 1"))
  r.appendChild(root, promoted)

  # Explicit layers, out of document order on purpose: 3 is written before 2,
  # so a stable sort by layer is the only thing that can produce the order the
  # goldens record.
  r.appendChild(root, layeredRow(r, "layer 3 — painted last",
                                 "3", "black", "bright_yellow"))
  r.appendChild(root, layeredRow(r, "layer 2 — painted second",
                                 "2", "white", "magenta"))
  r.appendChild(root, layeredRow(r, "layer 1 — painted first",
                                 "1", "black", "cyan"))

  # A nested subtree under an overlay: the layer is INHERITED by children, and
  # so is the opaque fill, which is the property a modal dialog depends on.
  let panel = r.createElement("div")
  r.setStyle(panel, "layer", "2")
  r.setStyle(panel, "background-color", "bright_black")
  r.setStyle(panel, "color", "bright_white")
  for line in ["┌── modal ──────────────┐",
               "│ inherited layer + bg  │",
               "│ and an inherited fg   │",
               "└───────────────────────┘"]:
    r.appendChild(panel, rowNode(r, line))
  r.appendChild(root, panel)

  for i in 0 ..< 8:
    r.appendChild(root, rowNode(r,
      "tail row " & align($i, 2, '0') & " " & "▒".repeat(60)))
  root

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an
  # unused runtime with it — ten `UnusedImport` warnings across five apps,
  # in a lane whose output is read for the ones that matter.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
