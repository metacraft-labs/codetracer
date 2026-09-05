## app_borders.nim — CTUI-2 snapshot app: box-drawing borders.
##
## One component tree, exported so the Tier-1 half of
## `tests/real_terminal/test_cross_tier_snapshot_equivalence.nim` composites the
## SAME proc in process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime and the frame barrier.
##
## What this one is for: the U+250x box-drawing block is three bytes per glyph
## in UTF-8 and one column wide, so it is where a terminal and a compositor
## first have to agree that a multi-byte glyph is not a multi-column one. The
## frame is deliberately taller and wider than 80x24 so the 80x24 geometry
## CLIPS it and the 120x40 geometry does not — two different screens from one
## tree, which is what makes running both geometries worth doing.

import std/strutils

import isonim_tui

const
  FrameWidth = 104
  FrameRows = 30

proc rowNode(r: TerminalRenderer; text: string): TerminalNode =
  result = r.createElement("div")
  r.appendChild(result, r.createTextNode(text))

proc buildTree*(r: TerminalRenderer): TerminalNode =
  let root = r.createElement("div")
  let inner = FrameWidth - 2
  r.appendChild(root, rowNode(r, "┌" & "─".repeat(inner) & "┐"))
  for i in 0 ..< FrameRows - 2:
    var body = "│"
    let label = " row " & align($i, 2) & " "
    body.add label
    body.add "·".repeat(max(0, inner - label.len - 1))
    # A right-hand rule so the closing edge is not the only thing on the far
    # side of the row: a border test whose interior is blank cannot tell a
    # dropped interior from a correctly blank one.
    body.add "┊"
    body.add "│"
    r.appendChild(root, rowNode(r, body))
  r.appendChild(root, rowNode(r, "└" & "─".repeat(inner) & "┘"))
  root

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an
  # unused runtime with it — ten `UnusedImport` warnings across five apps,
  # in a lane whose output is read for the ones that matter.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
