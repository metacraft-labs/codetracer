## test_real_frame_viewer.nim — PLAT-15, Tier 2. A REAL pty, a REAL terminal
## state machine, and the magnifier's picked pixel read back out of the
## terminal's own cell model.
##
## ## WHICH TIER THIS FILE IS, AND WHAT ONLY IT CAN SAY
##
## `src/common/terminal_graphics/magnifier_test.nim` is the gate and it runs in
## `common-units`, in process, against a `CellGrid`. `app/tests/
## test_frame_viewer_pane.nim` is Tier 1 and runs in `tui`, in process, against
## `isonim_tui`'s `TerminalTestHarness`. Both assert values THIS BUILD
## produced. This file asserts what a TERMINAL made of them, and the three
## claims below are the ones the other two cannot reach:
##
##   1. **The cell a coordinate names carries that pixel's colour ON SCREEN.**
##      `libvterm` parsed the SGR runs and the glyphs; an emitter that wrote
##      the right cells in the wrong order, or an SGR run that leaked past a
##      row boundary, produces a correct `CellGrid` and a wrong screen.
##   2. **The picture is not one flat colour.** The magnifier's whole claim is
##      that neighbouring cells show DIFFERENT pixels, so the sweep counts
##      distinct colours and asserts there are many — §4b's non-vacuity floor,
##      on a screen.
##   3. **A degraded pane still draws the rest of itself on a terminal.**
##      §2.6 is a statement about what a user sees.
##
## **Cross-tier equivalence would be blind to a defect both tiers share**, and
## that is why nothing here is a comparison against the in-process screen: both
## sides would be reading what this repository emitted. Every colour that
## carries meaning is asserted as a NUMBER, recomputed from the fixture's own
## formula in THIS file — the child never sends a colour, only the coordinates
## its model resolved.
##
## ## No skips, no sleeps
##
## A child that will not compile, a marker that never arrives: every one FAILS
## by name. Every barrier is `waitForText` on a marker the child writes; there
## is no `sleep` in this file.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none. The child is a real binary compiled from
## `tests/apps/app_frame_viewer.nim` by the product's own compile line, spawned
## in a real pty by `nim-pty`, with its bytes parsed by a real `libvterm`. The
## environment is set on the SPAWN (`envSet`/`envRemove`), which is the process
## boundary and not a substitution inside the subject.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[options, os, strutils, times, unittest]

import term_assert

import ../../testing/dual_snap

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 61

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const
  Stem = "app_frame_viewer"
  ReadyMarker = "PLAT15 READY"
  Barrier = initDuration(seconds = 20)

func expectedChannel(x, y: int): (int, int, int) =
  ## THE FIXTURE'S FORMULA, evaluated in THIS file.
  ##
  ## `tests/apps/app_frame_viewer.nim` writes the same formula into a raster;
  ## this is the independent evaluation the screen is compared against, on
  ## PLAT-14's rule for its Tier-2 decode — compare the implementation with the
  ## standard, never with itself.
  (10 + 15 * x, 6 + 20 * y, 200)

proc spawnChild(mode: string; kitty = false): TuiTestSession =
  ## `envRemove` for the variables an ambient session may carry: this suite's
  ## own process may be running inside tmux or over ssh, and a child that
  ## inherited `$TMUX` would be resolving a different environment from the one
  ## the case names.
  var b = newTuiTest(appBinaryPath(Stem), @[mode])
    .width(120).height(24)
    .envRemove("TMUX", "STY", "SSH_TTY", "SSH_CONNECTION", "KITTY_WINDOW_ID",
               "TERM_PROGRAM", "LC_TERMINAL", "NO_COLOR")
    .envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
  b = if kitty: b.envSet("TERM", "xterm-kitty").envSet("KITTY_WINDOW_ID", "1")
      else: b.envSet("TERM", "xterm-256color")
  b.spawn()

proc markerLine(sess: var TuiTestSession; key: string): string =
  for line in sess.screenContents().splitLines():
    if line.contains("PLAT15 " & key & " "):
      return line.strip()
  ""

proc valueAfter(line, key: string): string =
  let at = line.find("PLAT15 " & key & " ")
  if at < 0: return ""
  line[at + ("PLAT15 " & key & " ").len .. ^1].strip().split(' ')[0]

proc intsOf(text: string): seq[int] =
  result = @[]
  for part in text.split(','):
    try: result.add parseInt(part.strip())
    except ValueError: discard

suite "PLAT-15 Tier 2: the magnifier, on a real terminal":

  test "the child compiles from the product's own compile line":
    # Never skips. A child that will not compile is the defect, and
    # `compileChildApp` raises with the compiler's own output.
    compileChildApp(Stem)
    ck fileExists(appBinaryPath(Stem))

  test "every magnifier cell on the SCREEN carries the pixel it names":
    compileChildApp(Stem)
    var sess = spawnChild("magnify")
    defer: sess.close()
    sess.waitForText(ReadyMarker, Barrier)

    let tier = sess.markerLine("TIER")
    checkpoint(tier)
    # THE FRAME resolved to a cell tier and the OVERLAY draws at one too.
    ck tier.contains("PLAT15 TIER half-block")
    ck tier.contains("overlay=half-block")

    let origin = intsOf(valueAfter(sess.markerLine("ORIGIN"), "ORIGIN"))
    let pick = intsOf(valueAfter(sess.markerLine("PICK"), "PICK"))
    let cursor = intsOf(valueAfter(sess.markerLine("CURSOR"), "CURSOR"))
    let window = intsOf(valueAfter(sess.markerLine("WINDOW"), "WINDOW"))
    let zoom = intsOf(valueAfter(sess.markerLine("ZOOM"), "ZOOM"))
    let gridText = valueAfter(sess.markerLine("GRID"), "GRID")
    checkpoint("origin " & $origin & " pick " & $pick & " cursor " & $cursor &
               " window " & $window & " zoom " & $zoom & " grid " & gridText)
    ckEq origin.len, 2
    ckEq pick.len, 2
    ckEq cursor.len, 2
    ckEq window.len, 4
    ckEq zoom.len, 2
    # §2.4's CORRECTION SURVIVED TO THE TERMINAL: at the default 1:2 cell one
    # source pixel is TWO cells wide and ONE tall.
    ckEq zoom, @[2, 1]
    let grid = gridText.split('x')
    ckEq grid.len, 2
    let cols = parseInt(grid[0])
    let rows = parseInt(grid[1])
    ckEq cols, window[2] * zoom[0]
    ckEq rows, window[3] * zoom[1]

    # THE SWEEP. For every cell of the overlay, the pixel it shows is derived
    # from the window and the zoom — both of which the child printed from the
    # product's own model — and the COLOUR is `expectedChannel`, evaluated
    # here. The terminal's own cell model is what is read.
    var compared = 0
    var matched = 0
    var distinctFgs: seq[string] = @[]
    for r in 0 ..< rows:
      for c in 0 ..< cols:
        let sx = window[0] + c div zoom[0]
        let sy = window[1] + r div zoom[1]
        let (wr, wg, wb) = expectedChannel(sx, sy)
        # `origin` is 1-based, as `emitCellGrid` takes it; `cellAt` is 0-based.
        let cell = sess.cellAt(origin[0] - 1 + r, origin[1] - 1 + c)
        if cell.fg.kind == ckRgb and cell.bg.kind == ckRgb and
           int(cell.fg.r) == wr and int(cell.fg.g) == wg and
           int(cell.fg.b) == wb and
           int(cell.bg.r) == wr and int(cell.bg.g) == wg and
           int(cell.bg.b) == wb:
          inc matched
        else:
          checkpoint("cell (" & $r & "," & $c & ") shows pixel (" & $sx & "," &
                     $sy & ") want " & $wr & "," & $wg & "," & $wb &
                     " got fg=" & $cell.fg & " bg=" & $cell.bg)
        let key = $cell.fg
        if key notin distinctFgs:
          distinctFgs.add key
        inc compared
    checkpoint("cells matching the fixture formula: " & $matched & "/" &
               $compared & "; distinct foregrounds: " & $distinctFgs.len)
    ck compared == cols * rows
    ck matched == compared
    # THE NON-VACUITY FLOOR (§4b). A magnifier that painted one flat colour
    # would satisfy the sweep above for a window whose pixels happened to
    # agree; the fixture gives every source pixel its own colour, so the number
    # of DISTINCT foregrounds on screen is the window's pixel count.
    ckEq distinctFgs.len, window[2] * window[3]

    # THE CURSOR'S OWN CELL shows the coordinate the child REPORTED, and the
    # colour is the formula's. This is §5's contract on a screen: the number
    # handed to `pixel_history_vm` names the pixel a user is looking at.
    let (cr, cg, cb) = expectedChannel(pick[0], pick[1])
    let cursorCell = sess.cellAt(origin[0] - 1 + cursor[1],
                                 origin[1] - 1 + cursor[0])
    checkpoint("cursor cell fg=" & $cursorCell.fg)
    ck cursorCell.fg.kind == ckRgb
    ckEq int(cursorCell.fg.r), cr
    ckEq int(cursorCell.fg.g), cg
    ckEq int(cursorCell.fg.b), cb
    # …AND THE PIXEL BESIDE IT IS A DIFFERENT COLOUR. Without this the
    # assertion above is satisfied by a screen on which every cell is the same.
    let (nr, _, _) = expectedChannel(pick[0] + 1, pick[1])
    ck nr != cr
    let neighbour = sess.cellAt(origin[0] - 1 + cursor[1],
                                origin[1] - 1 + cursor[0] + zoom[0])
    ck neighbour.fg.kind == ckRgb
    ckEq int(neighbour.fg.r), nr

    # THE MAGNIFIER IS NEVER A GRAPHICS-PROTOCOL EMISSION. `magnifierTier`
    # renders it at a cell tier on every terminal, so a terminal-side image
    # parser finds nothing — asserted here rather than left to the reader.
    ckEq sess.images().len, 0

  test "a tier-0 terminal still magnifies at a CELL tier":
    # The same child on a Kitty advertisement. The FRAME's tier is 0 and the
    # OVERLAY's is 1 — `magnifier.magnifierTier`'s one substitution, observed
    # on a terminal rather than asserted about a function.
    compileChildApp(Stem)
    var sess = spawnChild("magnify", kitty = true)
    defer: sess.close()
    sess.waitForText(ReadyMarker, Barrier)
    let tier = sess.markerLine("TIER")
    checkpoint(tier)
    ck tier.contains("PLAT15 TIER protocol")
    ck tier.contains("overlay=half-block")
    ckEq sess.images().len, 0
    # …and the picture is STILL on the screen, so "no image" is not "nothing
    # was drawn" (§7a).
    let origin = intsOf(valueAfter(sess.markerLine("ORIGIN"), "ORIGIN"))
    let window = intsOf(valueAfter(sess.markerLine("WINDOW"), "WINDOW"))
    let zoom = intsOf(valueAfter(sess.markerLine("ZOOM"), "ZOOM"))
    let (wr, wg, wb) = expectedChannel(window[0], window[1])
    let first = sess.cellAt(origin[0] - 1, origin[1] - 1)
    ck first.fg.kind == ckRgb
    ckEq int(first.fg.r), wr
    ckEq int(first.fg.g), wg
    ckEq int(first.fg.b), wb

suite "PLAT-15 Tier 2: a degraded pane, on a real terminal":

  test "an UNMAGNIFIED tier-0 pane reports on a real terminal, and draws on":
    # THE CASE THE CAMPAIGN DID NOT HAVE. The only `xterm-kitty` case in this
    # file magnifies, and the child set `magnified = true` unconditionally — so
    # the one tier-0 route any case here took was the one
    # `magnifier.magnifierTier` substitutes a cell tier for. The ORDINARY path
    # (a graphics terminal, a frame, no magnifier) raised a `CellRenderError`
    # out of the paint until PLAT-15's landing pass, and nothing on a terminal
    # had ever tried it.
    compileChildApp(Stem)
    var sess = spawnChild("tier0", kitty = true)
    defer: sess.close()
    sess.waitForText(ReadyMarker, Barrier)
    let screen = sess.screenContents()
    checkpoint(sess.markerLine("TIER"))
    checkpoint(sess.markerLine("DEGRADED"))
    # THE TERMINAL RESOLVED TO TIER 0 AND NOTHING WAS MAGNIFIED — both, because
    # either alone is satisfied by the magnified case above.
    ck sess.markerLine("TIER").contains("PLAT15 TIER protocol")
    ck sess.markerLine("TIER").contains("gap=protocol-not-painted")
    ck sess.markerLine("MAGNIFIED").contains("PLAT15 MAGNIFIED false")
    # §8.2 ON A SCREEN: what is missing, and the flag that would draw it here.
    ck screen.contains("--image-tier=half-block")
    ck screen.contains("paints cells")
    # §4: THE TITLE STILL NAMES THE TIER THAT RESOLVED, not the one it fell to.
    ck screen.contains("FRAME VIEWER")
    ck screen.contains("image-tier=protocol")
    # …and the REMEDY's `--image-tier=half-block` is not a claim about what was
    # drawn: the title's tier and the remedy's flag are different strings on
    # different rows, and only the first is what the user is looking at.
    ck not sess.markerLine("TIER").contains("half-block")
    # §2.6: THE REST OF THE PANE IS STILL DRAWN.
    ck screen.contains("PIXEL HISTORY")
    ck screen.contains("glDrawElements")
    # AND NOTHING WAS TRANSMITTED AS AN IMAGE. The terminal advertises Kitty
    # graphics and this pane emitted no payload — which is the FACT the gap
    # reports, read off the terminal's own image parser rather than claimed.
    ckEq sess.images().len, 0

  test "an octant pin shows a refusal, a remedy, the tier AND the rest":
    compileChildApp(Stem)
    var sess = spawnChild("degrade")
    defer: sess.close()
    sess.waitForText(ReadyMarker, Barrier)
    let screen = sess.screenContents()
    checkpoint(sess.markerLine("TIER"))
    checkpoint(sess.markerLine("DEGRADED"))
    # PLAT-14 RESIDUE 3: the pin resolved, and the pane REPORTED rather than
    # raising.
    ck sess.markerLine("TIER").contains("PLAT15 TIER octant")
    ck sess.markerLine("TIER").contains("gap=tier-not-drawable")
    # WHAT IS MISSING AND HOW TO GET IT, on the screen.
    ck screen.contains("--image-tier=sextant")
    ck screen.contains("--image-tier=braille")
    # §4: THE TITLE STILL NAMES THE TIER.
    ck screen.contains("FRAME VIEWER")
    ck screen.contains("image-tier=octant")
    ck screen.contains("frame 7/40")
    ck screen.contains("16x12px")
    # §2.6: THE REST OF THE PANE STILL RENDERS.
    ck screen.contains("PIXEL HISTORY")
    ck screen.contains("glClear")
    ck screen.contains("glDrawElements")
    ck screen.contains("d:failed")

  test "the child exits cleanly in every mode":
    # A child that crashed after drawing would leave every assertion above
    # green, because the screen it drew is still there. `waitExit` pumps while
    # it waits, so this is the child's OWN exit rather than the one `close`
    # would have forced.
    compileChildApp(Stem)
    var modes = 0
    for mode in ["magnify", "degrade", "tier0"]:
      var sess = spawnChild(mode, kitty = mode == "tier0")
      sess.waitForText(ReadyMarker, Barrier)
      let code = sess.waitExit(Barrier)
      checkpoint(mode & " exited with " & $code)
      # `waitExit` answers `none` when the deadline expired rather than when
      # the child exited, so the presence of a code and the code itself are two
      # different facts and both are asserted.
      ck code.isSome
      ckEq code.get, 0
      sess.close()
      inc modes
    ckEq modes, 3

suite "PLAT-15 Tier 2: the tally":

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    ckEq countedAssertions, ExpectedAssertions
