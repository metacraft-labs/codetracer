## test_image_emission.nim — PLAT-14, Tier 1 THROUGH THE REAL RENDERER STACK.
##
## ## What only this file can say
##
## `src/common/terminal_graphics/emit_test.nim` asserts the escape sequences as
## strings. It runs in `common-units`, which has no renderer, so it cannot say
## either of the two things below — and both are places where a correct string
## can still be the wrong thing to have produced.
##
##   1. **THE SECOND IMPLEMENTATION AGREES WITH THE FIRST.**
##      `nim_termctl/image.nim` already emits Kitty and iTerm2 sequences, and
##      `terminal_graphics/emit.nim` emits them again — deliberately, for the
##      two reasons that module's header states (`src/common/` is compiled
##      under `nim js`, and `emitKittyChunked` cannot express `a=p` or cell
##      extents). Verification-Harness-Traps §14 is explicit that two copies of
##      one rule let the control agree with itself, and the answer when a second
##      copy is unavoidable is to GRADE ONE AGAINST THE OTHER. So this file
##      builds the same payload through both and asserts the byte strings are
##      IDENTICAL for the case they both express. A divergence in the chunk
##      boundary, the base64 alphabet or the framing reddens this lane instead
##      of producing two different pictures on two code paths.
##
##   2. **THE BYTES REACH A DRIVER.** `isonim_tui`'s `TerminalTestHarness` owns
##      the real `HeadlessDriver` the compositor paints through, and
##      `bytesEmitted` is every byte that driver was handed. An image emission
##      written through it is asserted where a real terminal would read it,
##      rather than as a value a test constructed and inspected.
##
## The Tier-2 half — a REAL pty, a real terminal parser, the image read back AS
## AN IMAGE — is `tests/real_terminal/test_real_image_emission.nim`.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none. `TerminalTestHarness` is not a mock and this repository has
## said so since CTUI-2: it is the real renderer, the real compositor and the
## real headless driver, with no terminal attached. `nim_termctl`'s emitters are
## the shipped ones. `setSupportOverride` pins the CAPABILITY DETECTION, which
## is the hook `isonim-tui` publishes for exactly this and is what
## `CodeTracer-TUI-Graphics.md` §7 asks for ("with the protocol set pinned via
## `setProtocolOverride`, so a tier cannot rot because nobody's terminal uses
## it"); it replaces no code on the emission path.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[strutils, unittest]

import isonim_tui
import nim_termctl/image as termctlImage

import ../../../common/terminal_graphics

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 28

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

proc pngLikePayload(n: int): seq[byte] =
  ## The PNG magic followed by deterministic filler. `nim_termctl`'s Kitty
  ## encoder refuses anything whose `SourceFormat` is not `sfPng`, so the
  ## comparison below needs a payload the SHIPPED emitter will accept — the
  ## magic is what makes this a PNG-shaped byte string rather than arbitrary
  ## bytes wearing the label.
  result = @[0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  for i in 8 ..< n:
    result.add byte(i mod 251)

proc termctlImageOf(payload: seq[byte]): termctlImage.Image =
  termctlImage.Image(bytes: payload, format: termctlImage.sfPng,
                     width: 0, height: 0,
                     preferredFormat: termctlImage.ifKitty)

proc rasterOf(): RgbaImage =
  ## A 4x4 raster with four distinct quadrant colours, so a cell rendering of
  ## it has something to get wrong.
  var px = newSeq[byte](4 * 4 * 4)
  for y in 0 ..< 4:
    for x in 0 ..< 4:
      let i = (y * 4 + x) * 4
      px[i] = (if x < 2: 200'u8 else: 20'u8)
      px[i + 1] = (if y < 2: 200'u8 else: 20'u8)
      px[i + 2] = 90'u8
      px[i + 3] = 255'u8
  initRgbaImage(4, 4, px)

suite "PLAT-14: the second emitter is graded against the shipped one":

  test "kittyTransmit is byte-identical to nim_termctl.emitKittyChunked":
    var sizes = 0
    for n in [16, 3072, 3073, 6144, 9000]:
      let payload = pngLikePayload(n)
      let shipped = termctlImage.emitKittyChunked(termctlImageOf(payload), 12)
      # `cols = 0, rows = 0` is the case both emitters express: no cell-extent
      # keys. With extents this build's string is longer BY CONSTRUCTION, which
      # the next case asserts.
      ckEq kittyTransmit(payload, 12, cols = 0, rows = 0), shipped
      inc sizes
    # THE SIZES SPAN THE CHUNK BOUNDARY. 3072 source bytes are exactly 4096
    # base64 characters — one full chunk — and 3073 is the first that needs a
    # second. A comparison run only on a small payload would agree about a
    # chunker that had no boundary at all.
    ckEq sizes, 5
    # …and the emitters genuinely differ where this build extends them, so the
    # equality above is an agreement and not a tautology.
    ck kittyTransmit(pngLikePayload(16), 12, cols = 4, rows = 2) !=
       termctlImage.emitKittyChunked(termctlImageOf(pngLikePayload(16)), 12)

  test "iterm2Inline is byte-identical to nim_termctl.emitITerm2Inline":
    var sizes = 0
    for n in [16, 1024, 4096]:
      let payload = pngLikePayload(n)
      ckEq iterm2Inline(payload),
           termctlImage.emitITerm2Inline(termctlImageOf(payload))
      inc sizes
    ckEq sizes, 3

  test "the chunk size is the same number, measured from the shipped output":
    # `nim_termctl.kittyChunkBytes` is not exported, so the constant is
    # MEASURED rather than compared: the first chunk of a long payload is
    # exactly `KittyChunkBytes` base64 characters.
    let shipped = termctlImage.emitKittyChunked(
      termctlImageOf(pngLikePayload(9000)), 1)
    let firstSemi = shipped.find(';')
    let firstEnd = shipped.find("\x1b\\", firstSemi)
    ckEq firstEnd - firstSemi - 1, KittyChunkBytes

  test "isonim-tui's image widget and this build agree on the same image":
    # THE WIDGET IS REUSED, not replaced: `isonim_tui.ImageWidget` is what a
    # pane mounts for tier 0, and its emission has to be the string this
    # milestone's link budget and placement rules were measured against.
    let harness = newTerminalTestHarness(40, 20)
    defer: harness.dispose()
    setSupportOverride(termctlImage.ImageProtocols(kitty: true, iterm2: false,
                                                   sixel: false))
    defer: clearSupportOverride()
    let payload = pngLikePayload(2048)
    let widget = newImageWidget(harness.renderer, termctlImageOf(payload),
                                widthCells = 8, heightCells = 4)
    ckEq widget.protocol(), ImageEmittedProtocol.ipKitty
    ck widget.emittedBytes().startsWith("\x1b_G")
    ckEq widget.emittedBytes(),
         kittyTransmit(payload, uint32(widget.currentImageId()))
    # THE FALSIFYING TWIN: pinned to no protocol at all, the widget emits
    # nothing and the text fallback is what the cells carry — so the equality
    # above is about the Kitty path and not about both sides being empty.
    setSupportOverride(termctlImage.ImageProtocols(kitty: false, iterm2: false,
                                                   sixel: false))
    let harness2 = newTerminalTestHarness(40, 20)
    defer: harness2.dispose()
    let fallback = newImageWidget(harness2.renderer, termctlImageOf(payload),
                                  widthCells = 8, heightCells = 4)
    ckEq fallback.protocol(), ImageEmittedProtocol.ipNone
    ckEq fallback.emittedBytes(), ""

suite "PLAT-14: the bytes reach a driver":

  test "a cell-tier emission arrives at the headless driver, byte for byte":
    let harness = newTerminalTestHarness(40, 20)
    defer: harness.dispose()
    let fit = fitToCells(4, 4, DefaultCellAspect, 4, 4)
    ckEq fit.cols, 4
    ckEq fit.rows, 2
    let grid = renderCells(rasterOf(), itHalfBlock, fit)
    let bytes = emitCellGrid(grid, cwTrueColor, originRow = 2, originCol = 3)
    harness.clearBytesEmitted()
    harness.driver.writeRaw(bytes)
    # THE DRIVER SAW EXACTLY THOSE BYTES. `bytesEmitted` is the whole of what
    # the driver was handed, and after `clearBytesEmitted` it holds this and
    # nothing else.
    ckEq harness.bytesEmitted(), bytes
    ck harness.bytesEmitted().contains("\x1b[2;3H")
    ck harness.bytesEmitted().contains("\x1b[3;3H")
    ck not containsGraphicsEscape(harness.bytesEmitted())
    # THE POSITIVE TWIN for the scanner, through the same driver and the same
    # predicate: a tier-0 emission down the same path DOES carry one.
    harness.clearBytesEmitted()
    harness.driver.writeRaw(kittyTransmit(pngLikePayload(64), 3))
    ck containsGraphicsEscape(harness.bytesEmitted())

  test "a scrub re-places instead of re-transmitting, at the driver":
    let harness = newTerminalTestHarness(40, 20)
    defer: harness.dispose()
    let payload = pngLikePayload(4096)
    harness.clearBytesEmitted()
    harness.driver.writeRaw(
      emitProtocolImage(ipKitty, payload, 21, 1, 8, 4, false).bytes)
    let firstFrame = harness.bytesEmitted().len
    harness.clearBytesEmitted()
    for step in 0 ..< 10:
      harness.driver.writeRaw(
        emitProtocolImage(ipKitty, payload, 21, 1, 8, 4, true).bytes)
    let tenScrubSteps = harness.bytesEmitted().len
    checkpoint("first frame: " & $firstFrame & " B; ten scrub steps: " &
               $tenScrubSteps & " B")
    # §3's claim, as bytes on a driver: TEN re-displays cost less than ONE
    # upload, and none of them carries the payload.
    ck tenScrubSteps < firstFrame
    ck firstFrame > 4096
    ckEq tenScrubSteps, 10 * "\x1b_Ga=p,i=21,p=1,c=8,r=4\x1b\\".len

suite "PLAT-14: the tally":

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    ck countedAssertions == ExpectedAssertions
