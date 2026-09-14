## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
## See `host/native_host.nim`'s header for the full rule, and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## keeps `app/` on the other side of it.
##
## host/image_probe.nim — PLAT-14 deliverable 5's EMPIRICAL half.
##
## `CodeTracer-TUI-Graphics.md` §3: *"Detection must test the **effective**
## path, not the outermost terminal's advertisement"* and *"capability
## detection must be empirical where it can be"*.
##
## This file is the "where it can be". It writes a Kitty graphics query and a
## primary-device-attributes request down the same descriptor the image will
## go down, waits a bounded time for a reply to come back up the same path, and
## hands the answer to `app/theme/image_capability.resolveImageCapability`,
## which is a pure function and decides what it means.
##
## ## WHY THIS IS NOT DONE AT STARTUP
##
## `host/capabilities.nim` records CTUI-11's rule: probes are environment-only
## plus a bounded non-blocking query, because the cold-start gate is 50 ms and a
## blocking probe fails a published gate rather than merely feeling slow. A
## graphics probe is a round trip to the terminal and, under tmux, a `tmux
## show-options` spawn as well — neither belongs on the startup path.
##
## So the image axis is resolved LAZILY: the first time a pane has an image to
## draw, and never if no pane ever does. That is also why the whole of
## `ImageCapability` is a value a caller passes around rather than something
## `TerminalCapabilities` carries: a capability that is sometimes unresolved
## must not be a field that is sometimes wrong.
##
## ## WHAT A TIMEOUT MEANS HERE, AND WHY IT IS A DIAGNOSIS
##
## `Verification-Harness-Traps` §3: a timeout is a symptom whose natural remedy
## is wrong for every cause it can have. The answer here is that the timeout is
## not the diagnosis — `GraphicsProbe.answered` is. The probe sends the
## graphics query FIRST and a DA1 request BEHIND it; every terminal and every
## multiplexer answers DA1, so:
##
##   * DA1 came back, graphics reply did not -> the path is alive and does not
##     pass graphics. A measured negative.
##   * neither came back -> the far end is not answering at all. Also a
##     measured negative, and a stronger one.
##
## Both resolve to a cell tier, which is why the distinction costs nothing in
## behaviour and everything in a failure message.
##
## ## NOTHING HERE DECIDES ANYTHING
##
## Two functions that read, and one that spawns `tmux`. Every consequence is
## drawn by the pure resolver in `app/`.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it reads the tty.".}

import std/[os, osproc, posix, strutils, times]

import ../../../common/terminal_graphics/emit
import ../app/theme/image_capability

export image_capability

const
  ProbeImageId* = 31
    ## The Kitty image id the query is issued under. Any non-zero id works; a
    ## fixed one is used so the reply can be recognised by its id rather than
    ## by position in a stream that may also carry a DA1 answer.

  ProbeQuery* = "\x1b_Gi=" & $ProbeImageId &
                ",s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
    ## Kitty's documented support query: a 1x1 RGB image, `a=q` (query, do not
    ## display), `t=d` (the payload is inline base64 data). A terminal that
    ## understands the protocol answers `\x1b_Gi=31;OK\x1b\\`; one that does
    ## not ignores the whole APC string, which is why this is safe to send to a
    ## terminal that has never heard of Kitty.

  ProbeFence* = "\x1b[c"
    ## Primary Device Attributes. The fence — see this module's header.

  ProbeOkReply* = "\x1b_Gi=" & $ProbeImageId & ";OK"

  DefaultProbeTimeoutMs* = 200
    ## How long to wait for the fence.
    ##
    ## A CEILING ON A LOCAL ROUND TRIP AND NOT A GUESS AT A REMOTE ONE. The
    ## probe is only ever run when a pane is about to draw an image, so a wait
    ## that expires costs one image's worth of latency and resolves to a cell
    ## tier that draws immediately — the failure is slow ONCE and then correct,
    ## rather than wrong. `probeGraphics` takes the timeout as a parameter so a
    ## caller on a link it knows about can raise it.

proc readImageEnv*(): ImageEnv =
  ## Every environment variable the image axis reads, and nothing reads one
  ## anywhere else — `host/capabilities.readTerminalEnv`'s contract for the
  ## axis PLAT-14 adds.
  ##
  ## `passthrough` is left `ptUnknown` here. Reading it costs a `tmux
  ## show-options` spawn, so it is `readTmuxPassthrough`'s own function and the
  ## caller decides whether to pay for it — and `ptUnknown` is the value that
  ## REFUSES tier 0 under tmux, so a caller that skips the spawn gets the safe
  ## answer rather than an optimistic one.
  initImageEnv(
    tmux = getEnv("TMUX", ""),
    sty = getEnv("STY", ""),
    termProgram = getEnv("TERM_PROGRAM", ""),
    lcTerminal = getEnv("LC_TERMINAL", ""),
    kittyWindowId = getEnv("KITTY_WINDOW_ID", ""),
    sshConnection = getEnv("SSH_CONNECTION", ""),
    sshTty = getEnv("SSH_TTY", ""),
    passthrough = ptUnknown)

proc readTmuxPassthrough*(): PassthroughState =
  ## tmux's `allow-passthrough`, read from tmux itself.
  ##
  ## `tmux show-options -gv allow-passthrough` prints `on`, `all` or `off`, or
  ## nothing at all on a tmux too old to have the option — and "too old to have
  ## the option" is exactly the case that must not resolve to `ptOn`. Anything
  ## this function does not recognise is `ptUnknown`, which refuses tier 0.
  ##
  ## `on` and `all` are both accepted: `all` additionally forwards sequences in
  ## panes that are not visible, which is a superset of what an image needs.
  var output = ""
  var code = -1
  try:
    (output, code) = execCmdEx("tmux show-options -gv allow-passthrough")
  except CatchableError, Defect:
    return ptUnknown
  if code != 0:
    return ptUnknown
  case output.strip().toLowerAscii()
  of "on", "all": ptOn
  of "off": ptOff
  else: ptUnknown

proc writeAll(fd: cint; data: string): bool =
  var written = 0
  while written < data.len:
    let n = posix.write(fd, cast[pointer](unsafeAddr data[written]),
                        data.len - written)
    if n <= 0:
      return false
    written += int(n)
  true

proc probeGraphics*(writeFd: cint = STDOUT_FILENO;
                    readFd: cint = STDIN_FILENO;
                    timeoutMs = DefaultProbeTimeoutMs;
                    wrapForTmux = false): GraphicsProbe =
  ## Send the query down `writeFd`, collect whatever comes back on `readFd`
  ## until the DA1 fence or the deadline, and report what was SEEN.
  ##
  ## THE REPLY IS NOT CONSUMED FROM A COOKED TERMINAL. The caller is expected
  ## to have the terminal in raw mode already — `host/terminal_driver.nim` puts
  ## it there before the first paint — because in canonical mode the reply sits
  ## in the line buffer until a newline that will never come, and the probe
  ## would report a measured negative that is really a measurement error. A
  ## caller that cannot guarantee raw mode should not call this: the zero
  ## `GraphicsProbe` is the honest answer for "not measured", and it resolves
  ## to the same cell tier.
  result = GraphicsProbe(attempted: true)
  var query = ProbeQuery
  if wrapForTmux:
    query = tmuxPassthrough(query)
  if not writeAll(writeFd, query & ProbeFence):
    # The descriptor refused the write. Nothing was measured and nothing is
    # claimed: `answered` stays false, which resolves to a cell tier.
    return
  let deadline = getTime() + initDuration(milliseconds = timeoutMs)
  var buf = ""
  var chunk = newString(512)
  while getTime() < deadline:
    var pollFd = TPollfd(fd: readFd, events: POLLIN, revents: 0)
    let remaining = (deadline - getTime()).inMilliseconds
    let waitMs = cint(max(1, min(remaining, 50)))
    let ready = poll(addr pollFd, Tnfds(1), waitMs)
    if ready <= 0:
      continue
    let n = posix.read(readFd, cast[pointer](addr chunk[0]), chunk.len)
    if n <= 0:
      break
    buf.add chunk[0 ..< n]
    if buf.contains(ProbeOkReply):
      result.kitty = true
    # The DA1 answer is `CSI ? <params> c`. Its terminating `c` is the fence.
    let da1 = buf.find("\x1b[?")
    if da1 >= 0 and buf.find('c', da1) > da1:
      result.answered = true
      let attrs = buf[da1 + 3 ..< buf.find('c', da1)]
      for part in attrs.split(';'):
        if part == "4":
          result.sixel = true
      break
  if buf.contains(ProbeOkReply):
    # A Kitty reply is itself proof the path round-trips, whether or not the
    # DA1 fence was recognised. Stated as a separate arm rather than folded
    # into the loop so that "the fence decided" and "the graphics reply
    # decided" are two facts and not one.
    result.kitty = true
    result.answered = true
