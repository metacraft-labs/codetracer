## app_color_depth.nim — CTUI-2 snapshot app: colour and attribute depth.
##
## Every colour representation the compositor's inline-style path can produce,
## and every attribute `compositor.styleFor` can set, so the cross-tier
## comparison has something to disagree about in the STYLE half of a cell
## rather than only in its rune.
##
## Three of the four colour kinds are reachable here and the fourth is not:
## `compositor.parseColorOrDefault` accepts `default`, the sixteen ANSI names,
## and `#RRGGBB`, so `ckAnsi` and `ckRgb` and `ckDefault` are exercised while
## `ckIndexed` (SGR 38;5;N for N >= 16) has no spelling in an inline style
## today. Recorded rather than papered over: a later milestone that emits
## indexed-256 colour needs a case here, and this comment is where it starts.
##
## `dim` is included ON PURPOSE even though libvterm cannot observe it. It is
## what makes the `dim-has-no-tier-2-representation` exclusion in `dual_snap`
## an exercised exclusion instead of a hypothetical one, and the suite asserts
## that a dim cell really is present in the Tier-1 canon — an excluded field
## that no case produces is an exclusion nobody can check.

import std/strutils

import isonim_tui

const
  AnsiNames* = ["black", "red", "green", "yellow", "blue", "magenta", "cyan",
                "white", "bright_black", "bright_red", "bright_green",
                "bright_yellow", "bright_blue", "bright_magenta",
                "bright_cyan", "bright_white"]
  DimRowText* = "dim-magenta-on-default"
    ## Named so the suite's positive control for the dim exclusion can find the
    ## row by content rather than by a coordinate that a layout change moves.

proc styledRow(r: TerminalRenderer; text: string; fg = ""; bg = "";
               attrs: openArray[string] = []): TerminalNode =
  result = r.createElement("div")
  if fg.len > 0: r.setStyle(result, "color", fg)
  if bg.len > 0: r.setStyle(result, "background-color", bg)
  for a in attrs: r.setStyle(result, a, "true")
  r.appendChild(result, r.createTextNode(text))

proc buildTree*(r: TerminalRenderer): TerminalNode =
  ## ROW ORDER IS LOAD-BEARING, and it was chosen after a run rather than
  ## before one. The attribute rows come FIRST because the compositor drops
  ## every entry whose row is past the screen (`compositor.render`:
  ## `if entry.row >= c.rows: continue`), and with the colour ramps in front
  ## the `dim` row landed at index 39 — clipped away at 80x24 AND at 120x40,
  ## which left the suite's positive control for the `dim` exclusion asserting
  ## over a row no geometry rendered. Measured: `dim cells: tier 1 0, tier 2 0`.
  let root = r.createElement("div")
  r.appendChild(root, styledRow(r, "default fg, default bg, no attrs"))
  # Attributes, one per row and then combined, so a failure names one
  # attribute rather than a set.
  r.appendChild(root, styledRow(r, "bold", fg = "green", attrs = ["bold"]))
  r.appendChild(root, styledRow(r, "italic", fg = "green", attrs = ["italic"]))
  r.appendChild(root, styledRow(r, "underline", fg = "green",
                                attrs = ["underline"]))
  r.appendChild(root, styledRow(r, "reverse", fg = "green",
                                attrs = ["reverse"]))
  r.appendChild(root, styledRow(r, DimRowText, fg = "magenta",
                                attrs = ["dim"]))
  r.appendChild(root, styledRow(r, "bold+italic+underline+reverse",
                                fg = "cyan", bg = "blue",
                                attrs = ["bold", "italic", "underline",
                                         "reverse"]))
  # 24-bit truecolor, both channels.
  r.appendChild(root, styledRow(r, "rgb #7c7aed on #102030",
                                fg = "#7c7aed", bg = "#102030"))
  r.appendChild(root, styledRow(r, "rgb #ff0000 on #00ff00",
                                fg = "#ff0000", bg = "#00ff00"))
  # The sixteen ANSI colours as foregrounds, then as backgrounds. As
  # backgrounds they also fill the row's trailing blanks, which is the only
  # way a cross-tier comparison sees a styled BLANK cell — and a blank cell
  # with a background is where "trailing whitespace" stops being cosmetic.
  for name in AnsiNames:
    r.appendChild(root, styledRow(r, "fg " & name.align(14), fg = name))
  for name in AnsiNames:
    r.appendChild(root, styledRow(r, "bg " & name.align(14), fg = "black",
                                  bg = name))
  root

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an
  # unused runtime with it — ten `UnusedImport` warnings across five apps,
  # in a lane whose output is read for the ones that matter.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
