## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/hyperlinks.nim — CTUI-6. OSC 8 hyperlinks, emitted INLINE with the
## frame the compositor produced.
##
## ## Why this module has to exist at all
##
## CodeTracer-TUI.md §3.3.3 gives every call frame a file and a line, and
## CTUI-6 asks that the frames "render as OSC 8 hyperlinks", asserted through
## `TermAssert`'s `hyperlinkAt`. **isonim-tui has no hyperlink concept**: a grep
## for `hyperlink`/`osc8` over `isonim-tui/src/` (2026-09-05) returns nothing,
## `Cell` carries no link id, and `testing/snapshot/ansi.encodeAnsi` emits SGR
## transitions and runes and nothing else. So the escape has to be written by
## the front-end around the cells the compositor already decided.
##
## ## INLINE, NOT AS AN OVERLAY PASS, AND THE REASON IS A RACE
##
## The obvious shape — paint the frame, then go back and repaint the linked
## spans wrapped in OSC 8 — is wrong twice over:
##
##   1. **It breaks the frame barrier.** `testing/test_app_runtime.nim` uses the
##      cursor coming to rest at `(rows-1, cols-1)` as the proof that a frame is
##      complete, and `dual_snap.waitForCompleteFrame` polls for exactly that.
##      A second pass moves the cursor after the barrier has already been
##      reachable, so a parent can observe "frame complete" with the link pass
##      still in flight and read a screen that is half-linked.
##   2. **OSC 8 is not retroactive.** libvterm records the link against the
##      cells printed BETWEEN the open and the close
##      (`nim-libvterm/src/nim_libvterm/extended_state.nim`, `dispatchOsc8` ->
##      `setGridRange`, which fills from the cursor position at open to the
##      cursor position at close). Cells already on screen when the link opens
##      carry nothing.
##
## Emitting the open/close inside the ordinary row walk costs no cursor motion
## at all, so the barrier still fires exactly when the last cell of the last row
## is parsed.
##
## ## THE ENCODER IS THE PRODUCTION ONE, AND THAT IS CHECKED RATHER THAN CLAIMED
##
## `frameBytesWithHyperlinks` walks the same `ScreenBuffer` in the same order as
## `isonim_tui`'s `encodeAnsi`, carrying the same `renderSgr(prev, curr)`
## transitions across rows, and re-glues rows with `CSI <row>;1H` exactly as
## `testing/test_app_runtime.frameBytes` does. A second encoder that drifted
## from the first would make every cross-tier comparison a comparison of two
## different programs — so `tests/real_terminal/test_real_call_stack.nim`
## asserts that with NO links the output is byte-identical to `frameBytes`,
## which is the only form of that claim a reader can check.
##
## That assertion is IN THE TIER-2 LANE although it needs no terminal, and the
## reason is a `--path`: `frameBytes` lives in `testing/test_app_runtime.nim`,
## which imports `term_assert_client`, whose path only the `tui-real-terminal`
## lane carries (`docs/tui-testing.md`, "Running it"). A Tier-1 suite that could
## reach it would be one edit away from spawning a pty in the fast lane.
##
## ## The link's end column, and why a link never reaches the last column
##
## `setGridRange` bounds the filled range by the cursor position at the CLOSE.
## A run of cells that ends at the right edge leaves libvterm's cursor in the
## pending-wrap state, still reported at the last column, so the final cell can
## fall outside the range. Callers therefore keep a linked span clear of the
## pane's last column — `app/views/call_stack.nim` reserves one trailing cell —
## and this module states the rule rather than silently producing a link that is
## one cell short on some rows.

import std/unicode

import isonim_tui

import ./styled_row

type
  PaneHyperlink* = object
    ## One OSC 8 target, in SCREEN cell coordinates.
    ##
    ## Screen coordinates rather than pane-relative ones because the emitter
    ## walks the whole composited buffer once: a pane that reported its own
    ## coordinates would need every caller to translate, and a caller that
    ## forgot would link the wrong row of another pane.
    row*: int
    col*: int
    width*: int
      ## Cells the link covers, starting at `col`.
    url*: string

const
  Osc8Start* = "\x1b]8;;"
  Osc8Terminator* = "\x1b\\"
    ## ST. BEL would also be accepted by libvterm, but ST is the form the OSC 8
    ## specification writes and it cannot be confused with a bell a test is
    ## asserting about.

proc osc8Open*(url: string): string =
  ## Open a hyperlink. Empty `url` closes instead, which is what the
  ## specification says an empty URI means.
  Osc8Start & url & Osc8Terminator

proc osc8Close*(): string =
  Osc8Start & Osc8Terminator

proc linkAt(links: openArray[PaneHyperlink]; row, col: int): int =
  ## Index of the link that STARTS at `(row, col)`, or -1.
  result = -1
  for i, link in links:
    if link.row == row and link.col == col and link.width > 0 and
       link.url.len > 0:
      return i

proc frameBytesWithHyperlinks*(buf: ScreenBuffer;
                               links: openArray[PaneHyperlink]): string =
  ## The bytes for one frame, with `links` opened and closed inline.
  ##
  ## Byte-identical to `testing/test_app_runtime.frameBytes` when `links` is
  ## empty; see this module's header for why that identity is asserted rather
  ## than described.
  result = "\x1b[2J\x1b[H"
  var prev = defaultStyle()
  var openUntil = -1
    ## Column at which the currently open link must be closed, or -1.
  for r in 0 ..< buf.rowsCount:
    result.add "\x1b[" & $(r + 1) & ";1H"
    if openUntil >= 0:
      # A link never spans rows: the row walk re-homes the cursor, and
      # `setGridRange` would fill every intervening cell of the screen.
      result.add osc8Close()
      openUntil = -1
    for c in 0 ..< buf.cols:
      let cell = buf[r, c]
      if cell.width == 0:
        # The trailing half of a wide glyph. `encodeAnsi` emits nothing for it
        # and neither does this, or every wide glyph would shift the row.
        continue
      if openUntil >= 0 and c >= openUntil:
        result.add osc8Close()
        openUntil = -1
      let starting = linkAt(links, r, c)
      if starting >= 0 and openUntil < 0:
        result.add osc8Open(links[starting].url)
        openUntil = c + links[starting].width
      let curr = newStyle(cell.fg, cell.bg, cell.attrs)
      let trans = renderSgr(prev, curr)
      if trans.len > 0:
        result.add trans
        prev = curr
      if cell.rune.int32 == 0:
        result.add ' '
      else:
        result.add $cell.rune
    if openUntil >= 0:
      result.add osc8Close()
      openUntil = -1
  result.add reset()

proc paneHyperlinkFor*(path: string; line: int; row, col, width: int):
    PaneHyperlink =
  ## A `file://` link to `path:line`, as terminals that support the `#L`
  ## fragment (VS Code, iTerm2, WezTerm) read it.
  ##
  ## The fragment rather than a query string: `file:///x/y.nim#L42` is what
  ## every editor-integrating terminal documents, and a link a terminal opens
  ## at the wrong line is worse than no link.
  PaneHyperlink(row: row, col: col, width: width,
                url: "file://" & path & "#L" & $max(1, line))

proc linkedCells*(links: openArray[PaneHyperlink]): int =
  ## Total cells covered by `links`. A count a test asserts on rather than
  ## "there is at least one link".
  for link in links:
    if link.url.len > 0:
      result += max(0, link.width)

proc textUnder*(row: StyledRow; col, width: int): string =
  ## The text of `[col, col+width)` cells of an encoded row.
  ##
  ## Used to state what a link covers in a failure message, and by the tests
  ## that assert a link's extent is the location field and not the whole row.
  result = ""
  var at = 0
  for span in row:
    for r in runes(span.text):
      let w = max(1, displayWidth($r))
      if at >= col and at < col + width:
        result.add $r
      at += w
