## app_wide_glyphs.nim — CTUI-2 snapshot app: THE HOSTILE CASE.
##
## A CJK wide glyph beside a combining mark next to a box-drawing border, which
## is where a compositor and a terminal most plausibly disagree about width.
## They did: see the three defects recorded in
## `src/frontend/tui/testing/dual_snap.nim`'s header, the first of which was
## found by this file and is a one-column-per-wide-glyph drift between the
## composited buffer and what a terminal renders from the bytes it emitted.
##
## ## What the combining mark proves, and what it does not
##
## `世界́` is U+4E16, U+754C, U+0301. isonim-tui's `rawCellsForEntry` skips every
## rune whose `displayWidth` is 0, so the combining acute is DROPPED BEFORE THE
## BYTES ARE EMITTED — the terminal never sees it. So this app proves the two
## tiers agree about a screen the mark is absent from; it does NOT prove that a
## combining mark renders identically in both, because at present no combining
## mark reaches Tier 2 at all.
##
## That is worth stating rather than letting the green run imply otherwise, and
## it is worth keeping in the tree rather than deleting: the day isonim-tui
## attaches combining marks to their base cluster instead of dropping them,
## this case starts asserting the stronger thing without an edit, and
## `test_cross_tier_snapshot_equivalence.nim` asserts the CURRENT behaviour
## (the mark is absent from both sides) so the change cannot land silently.

import std/strutils

import isonim_tui

const
  CombiningAcute* = "́"
  HostileRow* = "┌世" & CombiningAcute & "界" & CombiningAcute & "─┐"
    ## The mark follows each wide glyph, so if it were ever given a column of
    ## its own the drift would show up immediately to the right of it.

proc rowNode(r: TerminalRenderer; text: string): TerminalNode =
  result = r.createElement("div")
  r.appendChild(result, r.createTextNode(text))

proc buildTree*(r: TerminalRenderer): TerminalNode =
  let root = r.createElement("div")
  r.appendChild(root, rowNode(r, HostileRow))
  # A wide glyph at the START of a row, in the MIDDLE, and pressed against the
  # right-hand border: three positions, because a width bug that only bites at
  # a boundary is exactly the one a single sample misses.
  r.appendChild(root, rowNode(r, "世界" & "─".repeat(28) & "世界│"))
  r.appendChild(root, rowNode(r, "│" & "─".repeat(14) & "世界" &
                                 "─".repeat(14) & "│"))
  # Alternating wide and narrow, so every wide glyph's trailing half has a
  # narrow neighbour on both sides.
  var alternating = ""
  for i in 0 ..< 20:
    alternating.add "世"
    alternating.add "|"
  r.appendChild(root, rowNode(r, alternating))
  # Wide glyphs that run PAST the 80-column edge but not past 120, so the two
  # geometries clip the same row differently.
  r.appendChild(root, rowNode(r, "界".repeat(55)))
  # An emoji: also width 2 by East-Asian-Width rules, and four bytes rather
  # than three, so it exercises the UTF-8 decode as well as the width table.
  r.appendChild(root, rowNode(r, "┤🙂🙂┆世界┆🙂├"))
  root

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an
  # unused runtime with it — ten `UnusedImport` warnings across five apps,
  # in a lane whose output is read for the ones that matter.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
