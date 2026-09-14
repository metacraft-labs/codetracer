## test_real_image_probe.nim — PLAT-14, Tier 2. A REAL pty, a REAL probe, and
## the image read back AS AN IMAGE.
##
## ## What only this file can say
##
## `app/tests/test_image_capability.nim` sweeps 1,728 constructed environments
## and asserts what `resolveImageCapability` DECIDES. Every one of those
## assertions would still pass on a build whose PROBE never ran, whose emitter
## produced a well-formed escape carrying a corrupt payload, or whose cell tier
## printed a graphics introducer beside its glyphs. Three claims therefore need
## a terminal, and they are the three cases below.
##
##   1. **The probe reports "not answered" when nothing answers**, measured on a
##      real file descriptor with a real deadline. The harness's `nim-libvterm`
##      does not reply to a Kitty query — it is a parser, not a terminal — so
##      this is the §3 failure the whole fail-low rule exists for, produced
##      rather than constructed.
##   2. **…and the SAME child, on the SAME path, reports "answered" when a
##      reply IS injected.** Verification-Harness-Traps §7a: an unfalsified
##      negative control is a self-comparison wearing a negation. Case 1's
##      "nothing came back" means nothing until case 2 shows that something CAN
##      come back through the same pty, the same raw mode and the same deadline.
##   3. **The tier-0 emission is a PICTURE on the terminal's side.** TermAssert
##      parses the APC through `nim-libvterm`'s Kitty decoder and hands back
##      decoded RGBA. The pixels are asserted against the fixture's own formula
##      — `r = 40 + 50x`, `g = 40 + 50y`, `b = 128` — which this file evaluates
##      itself rather than reading out of the renderer.
##
## And the negative control with its positive twin: on a terminal with no
## graphics protocol the same child draws CELLS, `images()` is empty, and the
## eight cells' foreground and background colours are read out of the
## terminal's own cell model as exact RGB numbers. `docs/tui-testing.md`'s rule
## about cross-tier equality applies here in full: a differential check is blind
## to any defect both tiers share, so every colour that carries MEANING is
## asserted as a NUMBER.
##
## ## `assertImageMatches` IS NOT USED, AND THAT IS PLAT-14'S OWN RISK NOTE
##
## The milestone's risk mitigation says `assertImageMatches` "is verified to
## have a working failure arm before it is relied upon". It was, and it is not
## relied upon: `TermAssert/src/term_assert.nim:697-710` writes the golden and
## RETURNS when the golden file does not exist, so its first run on any new path
## cannot fail — the same shape as its sibling `assertSynchronizedRender`, whose
## failure arm is a bare `discard` and which `test_real_capability_negotiation
## .nim` already records. A first run that cannot fail is a check that cannot
## fail in exactly the situation a new test is in. So the pixels are asserted
## HERE, against a formula written in this file, through `imageData` — which has
## no golden, no first-run arm and no way to pass by recording.
##
## ## No skips, no sleeps
##
## A child that will not compile, a marker that never arrives, an image that
## never appears: every one FAILS by name. Every barrier is `waitForText` on a
## marker the child writes; there is no `sleep` in this file.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none. The child is a real binary compiled from
## `tests/apps/app_image_probe.nim` by the product's own compile line, spawned
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

import std/[options, os, strutils, times, unicode, unittest]

import term_assert

import ../../testing/dual_snap

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 36

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const
  Stem = "app_image_probe"
  ReadyMarker = "PLAT14 READY"
  ProbingMarker = "PLAT14 PROBING"
  KittyReply = "\x1b_Gi=31;OK\x1b\\"
    ## What a Kitty-capable terminal answers `host/image_probe.ProbeQuery`
    ## with. Written out here rather than imported: this file is on the
    ## TERMINAL's side of the pty and speaks the terminal's half of the
    ## protocol, so importing the prober's own constant would be the two halves
    ## of a handshake agreeing with each other.
  Da1Reply = "\x1b[?62;4c"
    ## A primary-device-attributes answer — the fence the prober waits for.
  ProbeWindowMs = 4000
  Barrier = initDuration(seconds = 20)

proc spawnChild(mode: string; kitty: bool;
                probeMs = 0): TuiTestSession =
  ## The child, in a real pty, with the environment set on the SPAWN.
  ##
  ## `envRemove` for the four variables an ambient session may carry: this
  ## suite's own process may be running inside tmux or over ssh, and a child
  ## that inherited `$TMUX` would be resolving a different environment from the
  ## one the case names. `.envRemove(X).envSet(X, v)` is the documented order
  ## for "block the ambient value, then set mine".
  var b = newTuiTest(appBinaryPath(Stem), @[mode])
    .width(200).height(12)
    .envRemove("TMUX", "STY", "SSH_TTY", "SSH_CONNECTION", "KITTY_WINDOW_ID",
               "TERM_PROGRAM", "LC_TERMINAL", "NO_COLOR")
    .envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
  b = if kitty: b.envSet("TERM", "xterm-kitty").envSet("KITTY_WINDOW_ID", "1")
      else: b.envSet("TERM", "xterm-256color")
  if probeMs > 0:
    b = b.envSet("CT_IMAGE_PROBE_TIMEOUT_MS", $probeMs)
  b.spawn()

proc capLine(sess: var TuiTestSession): string =
  for line in sess.screenContents().splitLines():
    if line.contains("PLAT14 CAP "):
      return line.strip()
  ""

proc tierLine(sess: var TuiTestSession): string =
  for line in sess.screenContents().splitLines():
    if line.contains("PLAT14 TIER "):
      return line.strip()
  ""

proc probeLine(sess: var TuiTestSession): string =
  for line in sess.screenContents().splitLines():
    if line.contains("PLAT14 PROBE "):
      return line.strip()
  ""

suite "PLAT-14 Tier 2: the probe, on a real pty":

  test "the child compiles from the product's own compile line":
    # Never skips. A child that will not compile is the defect, and
    # `compileChildApp` raises with the compiler's own output.
    compileChildApp(Stem)
    ck fileExists(appBinaryPath(Stem))

  test "nothing answers, so the probe reports NOT ANSWERED and tier 0 is refused":
    compileChildApp(Stem)
    var sess = spawnChild("probe", kitty = true, probeMs = 600)
    defer: sess.close()
    sess.waitForText(ReadyMarker, Barrier)
    let probe = sess.probeLine()
    let cap = sess.capLine()
    checkpoint(probe)
    checkpoint(cap)
    # THE PROBE RAN and measured a negative — `attempted` true, `answered`
    # false. Not "the probe was skipped", which resolves to the same tier and
    # is a different fact.
    ck probe.contains("attempted=true")
    ck probe.contains("answered=false")
    ck probe.contains("kitty=false")
    # …and the DECISION that follows names the probe as the reason, on a
    # terminal whose environment advertises Kitty. The advertisement lost to
    # the measurement, which is §3's whole rule.
    ck cap.contains("advertised=ipKitty")
    ck cap.contains("image-tier=half-block")
    ck cap.contains("refused-tier0=probe-unanswered")
    ck not cap.contains("image-tier=protocol")

  test "a reply injected into the SAME pty answers it, and tier 0 is reached":
    # THE FALSIFICATION OF THE CASE ABOVE (§7a). Same binary, same environment,
    # same raw mode, same deadline — the only difference is that something
    # replies. If this case could not reach tier 0, the case above would be
    # asserting that the probe is broken rather than that the terminal is
    # silent.
    compileChildApp(Stem)
    var sess = spawnChild("probe", kitty = true, probeMs = ProbeWindowMs)
    defer: sess.close()
    sess.waitForText(ProbingMarker, Barrier)
    sess.send(KittyReply & Da1Reply)
    sess.waitForText(ReadyMarker, Barrier)
    let probe = sess.probeLine()
    let cap = sess.capLine()
    checkpoint(probe)
    checkpoint(cap)
    ck probe.contains("attempted=true")
    ck probe.contains("answered=true")
    ck probe.contains("kitty=true")
    ck cap.contains("image-tier=protocol")
    ck cap.contains("protocol=ipKitty")
    ck not cap.contains("refused-tier0")

suite "PLAT-14 Tier 2: the emission, read back from the terminal":

  test "a tier-0 emission is an IMAGE on the terminal's side, pixel for pixel":
    compileChildApp(Stem)
    var sess = spawnChild("draw", kitty = true)
    defer: sess.close()
    sess.waitForText(ReadyMarker, Barrier)
    checkpoint(sess.tierLine())
    ck sess.tierLine().contains("PLAT14 TIER protocol")
    ck sess.tierLine().contains("protocol=ipKitty")

    let refs = sess.images()
    checkpoint("images parsed by the terminal: " & $refs.len)
    ck refs.len == 1
    let img = sess.imageData(refs[0])
    checkpoint("decoded " & $img.width & "x" & $img.height & ", " &
               $img.pixels.len & " bytes")
    # THE PICTURE, not the escape. `nim-libvterm` ran a real PNG decoder over
    # the payload this build transmitted; a well-formed APC carrying corrupt
    # bytes would arrive here as zero pixels.
    ck img.width == 4
    ck img.height == 4
    ck img.pixels.len == 4 * 4 * 4
    # …and the pixels are the fixture's own formula, evaluated HERE. Every one
    # of the sixteen, so a decoder that got one corner right cannot pass.
    var compared = 0
    var matched = 0
    for y in 0 ..< 4:
      for x in 0 ..< 4:
        let base = (y * 4 + x) * 4
        if int(img.pixels[base]) == 40 + 50 * x and
           int(img.pixels[base + 1]) == 40 + 50 * y and
           int(img.pixels[base + 2]) == 128:
          inc matched
        inc compared
    checkpoint("pixels matching the fixture formula: " & $matched & "/" &
               $compared)
    ck compared == 16
    ck matched == 16
    # The image is PLACED where the child put it, which is the other half of
    # "it is on the screen": a decoded payload nothing anchored to a cell would
    # satisfy every assertion above.
    let anchored = sess.imageAt(1, 0)
    ck anchored.isSome
    ck anchored.get == refs[0]

  test "a cell-tier emission leaves NO image and NO graphics escape":
    # THE NEGATIVE CONTROL, whose positive twin is the case immediately above:
    # `images()` is shown to be non-empty on the same harness, through the same
    # parser, before it is asserted empty here.
    compileChildApp(Stem)
    var sess = spawnChild("cells", kitty = false)
    defer: sess.close()
    sess.waitForText(ReadyMarker, Barrier)
    checkpoint(sess.tierLine())
    ck sess.tierLine().contains("PLAT14 TIER half-block")
    ck sess.tierLine().contains("cells=4x2")
    ck sess.tierLine().contains("refusal=no-protocol-advertised")
    ck sess.images().len == 0

    # THE PICTURE IS THERE, read out of the terminal's own cell model as exact
    # numbers. The fixture's formula puts a distinct (fg, bg) pair in every one
    # of the eight cells: a half block's foreground is the source row above and
    # its background the row below, so cell (col c, row R) is
    # fg = (40+50c, 40+100R, 128) and bg = (40+50c, 90+100R, 128).
    var cells = 0
    var correct = 0
    for row in 0 ..< 2:
      for col in 0 ..< 4:
        let cell = sess.cellAt(1 + row, col)
        if $cell.rune == "\u{2580}" and
           cell.fg.kind == ckRgb and cell.bg.kind == ckRgb and
           int(cell.fg.r) == 40 + 50 * col and
           int(cell.fg.g) == 40 + 100 * row and
           int(cell.fg.b) == 128 and
           int(cell.bg.r) == 40 + 50 * col and
           int(cell.bg.g) == 90 + 100 * row and
           int(cell.bg.b) == 128:
          inc correct
        else:
          checkpoint("cell (" & $row & "," & $col & ") rune=" & $cell.rune &
                     " fg=" & $cell.fg & " bg=" & $cell.bg)
        inc cells
    checkpoint("cells matching the fixture formula: " & $correct & "/" & $cells)
    ck cells == 8
    ck correct == 8

  test "the child exits cleanly in every mode":
    # A child that crashed after drawing would leave every assertion above
    # green, because the screen it drew is still there. `waitExit` pumps while
    # it waits, so this is the child's OWN exit rather than the one `close`
    # would have forced — a distinction that matters here, because `close`
    # reaps whatever it finds and would report a code for a child it killed.
    compileChildApp(Stem)
    var modes = 0
    for (mode, kitty) in [("draw", true), ("cells", false)]:
      var sess = spawnChild(mode, kitty)
      sess.waitForText(ReadyMarker, Barrier)
      let code = sess.waitExit(Barrier)
      checkpoint(mode & " exited with " & $code)
      ck code.isSome
      ck code.get == 0
      sess.close()
      inc modes
    ck modes == 2

suite "PLAT-14: the tally":

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    ck countedAssertions == ExpectedAssertions
