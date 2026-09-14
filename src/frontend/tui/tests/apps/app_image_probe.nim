## apps/app_image_probe.nim — PLAT-14's Tier-2 child.
##
## NOT A TEST FILE. `ci/lib/test-lane-files.sh` finds `test_*.nim`, so a module
## called anything else under `tests/` is a fixture the suites drive rather than
## a suite the lane runs. `tests/real_terminal/test_real_image_probe.nim`
## compiles this with `testing/dual_snap.compileChildApp` and spawns it in a
## real pty.
##
## ## WHY A CHILD AND NOT AN IN-PROCESS TEST
##
## Three things about PLAT-14 cannot be established without a real terminal on
## the other end of a real file descriptor, and all three are in this file:
##
##   1. **The probe's own I/O.** `host/image_probe.probeGraphics` writes an
##      escape to an fd and polls another for a reply with a deadline. An
##      in-process test can hand `resolveImageCapability` a `GraphicsProbe`
##      value — `app/tests/test_image_capability.nim` sweeps 1,728 of them —
##      but it cannot say that the function which PRODUCES that value reports
##      "not answered" when nothing answers. That is a claim about a timeout on
##      a pty, and this child is how it is made.
##   2. **The emission is read back AS AN IMAGE.** §7 tier 2: TermAssert parses
##      the Kitty APC through `nim-libvterm` and hands the suite decoded pixels.
##      A byte-level assertion cannot tell a well-formed escape carrying a
##      corrupt payload from one carrying the picture.
##   3. **The cell tiers leave NO graphics escape on the screen.** §3's failure
##      mode is garbage in the user's terminal, and "garbage" is a statement
##      about what the terminal made of the bytes, not about the bytes.
##
## ## MODES
##
## `argv[1]` selects one, and each writes a line starting with `PLAT14 ` that
## the suite waits for by name — never a sleep.
##
##   `probe`  raw-mode the tty, run the real probe, print the resolved
##            capability. Prints `PLAT14 PROBING` first, so the suite can
##            inject a reply inside the window without racing the spawn.
##   `draw`   resolve from the environment and emit the fixture PNG at tier 0.
##   `cells`  resolve from the environment and emit a cell rendering.
##
## The capability is always resolved by the product's own
## `resolveImageCapability`; nothing here decides a tier.

import std/[os, posix, strutils, termios]

import ../../../../common/terminal_graphics
import ../../host/image_probe

const
  ReadyMarker = "PLAT14 READY"
  ProbingMarker = "PLAT14 PROBING"
  ProbeTimeoutEnv = "CT_IMAGE_PROBE_TIMEOUT_MS"

proc fixturePath(): string =
  currentSourcePath().parentDir.parentDir / "fixtures" /
    "plat14_ramp_4x4.png"

proc rasterFromFixtureColours(): RgbaImage =
  ## The SAME picture `plat14_ramp_4x4.png` holds, as a raster: a 4x4 ramp
  ## where red rises with the column and green rises with the row, so every one
  ## of the eight half-block cells it renders into carries a DISTINCT
  ## foreground and background pair. A picture with repeated cells would be
  ## satisfied by a renderer that ignored one axis.
  ##
  ## NOT DECODED FROM THE PNG — this build has no PNG decoder, which is the
  ## bound `raster.nim`'s header records and the reason a cell tier cannot draw
  ## `image/png` at all. The two fixtures are one picture expressed twice, and
  ## `test_real_image_probe.nim` asserts the PNG's DECODED pixels, read back
  ## from the terminal, against the same formula — which is what keeps them one
  ## picture.
  var px = newSeq[byte](4 * 4 * 4)
  for y in 0 ..< 4:
    for x in 0 ..< 4:
      let i = (y * 4 + x) * 4
      px[i] = byte(40 + 50 * x)
      px[i + 1] = byte(40 + 50 * y)
      px[i + 2] = 128'u8
      px[i + 3] = 255'u8
  initRgbaImage(4, 4, px)

proc resolved(): ImageCapability =
  let env = initTerminalEnv(
    term = getEnv("TERM", ""), colorterm = getEnv("COLORTERM", ""),
    termProgram = getEnv("TERM_PROGRAM", ""), lcAll = getEnv("LC_ALL", ""),
    lcCtype = getEnv("LC_CTYPE", ""), lang = getEnv("LANG", ""),
    noColor = getEnv("NO_COLOR", ""), isTty = isatty(STDOUT_FILENO) == 1)
  let ienv = readImageEnv()
  resolveImageCapability(env, ienv, resolveCapabilities(env,
                         initCapabilityFlags()), initCapabilityFlags())

proc withRawMode(body: proc()) =
  ## `probeGraphics`'s documented precondition. In canonical mode the reply
  ## sits in the line buffer until a newline that will never come, and the
  ## probe would report a measured negative that is really a measurement error.
  var saved: Termios
  let haveTty = tcGetAttr(STDIN_FILENO, addr saved) == 0
  if haveTty:
    var raw = saved
    raw.c_lflag = raw.c_lflag and not (Cflag(ICANON) or Cflag(ECHO))
    raw.c_cc[VMIN] = 0.char
    raw.c_cc[VTIME] = 0.char
    discard tcSetAttr(STDIN_FILENO, TCSANOW, addr raw)
  try:
    body()
  finally:
    if haveTty:
      discard tcSetAttr(STDIN_FILENO, TCSANOW, addr saved)

proc emitLine(text: string) =
  stdout.write(text & "\r\n")
  stdout.flushFile()

proc runProbe() =
  var probe: GraphicsProbe
  withRawMode(proc() =
    emitLine(ProbingMarker)
    var timeout = DefaultProbeTimeoutMs
    let configured = getEnv(ProbeTimeoutEnv, "")
    if configured.len > 0:
      try: timeout = parseInt(configured)
      except ValueError: discard
    probe = probeGraphics(timeoutMs = timeout))
  let env = initTerminalEnv(
    term = getEnv("TERM", ""), colorterm = getEnv("COLORTERM", ""),
    lang = getEnv("LANG", ""), isTty = isatty(STDOUT_FILENO) == 1)
  let cap = resolveImageCapability(env, readImageEnv(),
                                   resolveCapabilities(env,
                                                       initCapabilityFlags()),
                                   initCapabilityFlags(), probe)
  emitLine("PLAT14 PROBE attempted=" & $probe.attempted &
           " answered=" & $probe.answered & " kitty=" & $probe.kitty)
  emitLine("PLAT14 CAP " & describe(cap))
  emitLine(ReadyMarker)

proc runDraw() =
  let cap = resolved()
  let payload = cast[seq[byte]](readFile(fixturePath()))
  stdout.write("\x1b[2;1H")
  if cap.tier == itProtocol:
    stdout.write(emitProtocolImage(cap.protocol, payload, 7, 1, 4, 2, false,
                                   cap.wrapForMultiplexer).bytes)
  stdout.flushFile()
  emitLine("\x1b[6;1HPLAT14 TIER " & tierName(cap.tier) &
           " protocol=" & $cap.protocol)
  emitLine(ReadyMarker)

proc runCells() =
  let cap = resolved()
  let fit = fitToCells(4, 4, DefaultCellAspect, 4, 4)
  let grid = renderCells(rasterFromFixtureColours(), cap.tier, fit)
  stdout.write(emitCellGrid(grid, cwTrueColor, originRow = 2, originCol = 1))
  stdout.flushFile()
  emitLine("\x1b[6;1HPLAT14 TIER " & tierName(cap.tier) &
           " cells=" & $grid.cols & "x" & $grid.rows &
           " refusal=" & $cap.refusal)
  emitLine(ReadyMarker)

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "probe"
  case mode
  of "probe": runProbe()
  of "draw": runDraw()
  of "cells": runCells()
  else:
    emitLine("PLAT14 UNKNOWN MODE " & mode)
    emitLine(ReadyMarker)
    quit(2)
  # A short settle before exiting, so the final marker is out of the pty
  # buffer before the descriptor closes. NOT A BARRIER: every assertion in
  # `test_real_image_probe.nim` waits for a marker this process wrote, and the
  # suite waits for this process's OWN exit rather than forcing one.
  sleep(150)
