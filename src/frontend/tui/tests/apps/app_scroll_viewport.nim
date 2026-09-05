## app_scroll_viewport.nim — CTUI-2 snapshot app: a scrolled viewport.
##
## ## What "scroll region" means here, precisely
##
## It does NOT mean DECSTBM (`CSI top;bottom r`). isonim-tui's compositor never
## emits one: `compositor.paint` diffs the new buffer against the last and
## writes the changed rows, so a scroll is a repaint rather than a terminal
## scroll region, and there is no `CSI r` anywhere in
## `isonim-tui/src/isonim_tui/`. Saying so here rather than letting the
## filename imply otherwise is the point of this paragraph: what this app
## exercises is a VIEWPORT — content longer than the screen, rendered from an
## offset, with the rows above and below the window absent — and what the
## cross-tier comparison then proves is that the terminal shows the same window
## the compositor thinks it does.
##
## That is still the load-bearing half. A viewport is where off-by-one row
## arithmetic lives, and it is the shape every pane CTUI-5 onward renders.

import std/strutils

import isonim_tui

const
  DocumentLines* = 400
  ScrollOffset* = 137
    ## Deliberately not a round number and not near an edge, so a viewport that
    ## silently clamped to 0 or to the end would be obvious in the plaintext
    ## rather than plausible.
  ViewportRows* = 34
    ## More rows than an 80x24 screen has and fewer than a 120x40 screen has,
    ## so one geometry clips the viewport and the other does not.

proc documentLine*(i: int): string =
  ## The document is a pure function of the line index so both tiers, and any
  ## later reader of the goldens, can reconstruct what row N should hold.
  "line " & align($i, 4, '0') & " │ " &
    (if i mod 17 == 0: "── section marker ──"
     elif i mod 5 == 0: "· minor tick"
     else: "text for line " & $i)

proc rowNode(r: TerminalRenderer; text: string): TerminalNode =
  result = r.createElement("div")
  r.appendChild(result, r.createTextNode(text))

proc buildTree*(r: TerminalRenderer): TerminalNode =
  let root = r.createElement("div")
  r.appendChild(root, rowNode(r,
    "viewport " & $ScrollOffset & ".." & $(ScrollOffset + ViewportRows - 1) &
    " of " & $DocumentLines))
  for i in ScrollOffset ..< min(DocumentLines, ScrollOffset + ViewportRows):
    # A scrollbar column on the left of each row, so the window's position in
    # the document is visible in the CELLS and not only in the header.
    let inThumb = (i - ScrollOffset) * 3 < ViewportRows
    r.appendChild(root, rowNode(r,
      (if inThumb: "█" else: "░") & " " & documentLine(i)))
  root

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an
  # unused runtime with it — ten `UnusedImport` warnings across five apps,
  # in a lane whose output is read for the ones that matter.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
