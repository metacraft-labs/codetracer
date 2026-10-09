## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
## See `host/native_host.nim`'s header for the full rule, and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## keeps `app/` on the other side of it.
##
## host/terminal_probe.nim — PLAT-46 deliverables 5 and 8: ONE start-up query
## round that asks the terminal what the environment cannot tell us.
##
## ## What is asked, in one write
##
##   1. `OSC 11 ; ?`            the terminal's ACTUAL background colour — vim's
##                              `t_RB`; answered by xterm, kitty, WezTerm,
##                              iTerm2, Alacritty, foot, VTE, Windows Terminal
##                              and tmux (which answers with the pane's own
##                              background).
##   2. XTGETTCAP `RGB`, `Tc`   whether the terminal CLAIMS 24-bit colour, by
##                              terminfo capability name (kitty, foot, WezTerm,
##                              recent xterm).
##   3. DECRQSS `m` after a     whether it KEEPS a 24-bit SGR: a terminal that
##      24-bit `SGR 48:2`       reports `48:2:…` back stored the colour it was
##                              given; one that approximated reports `48;5;N`.
##                              The SGR is reset straight after.
##   4. DA1 (`CSI c`)           the FENCE. Every terminal and multiplexer
##                              answers it, and in order, so its answer says
##                              "everything above has been answered or never
##                              will be" and ends the wait early.
##
## Inside tmux, `tmux display -p '#{client_termfeatures}'` is spawned as well,
## beside the write: tmux does not forward DECRQSS or XTGETTCAP, and whether it
## passes 24-bit colour on to its client is exactly the `RGB` feature
## (`terminal-features`). A tmux without it is WITHHOLDING 24-bit colour, and
## the status line says how to stop it.
##
## ## One bounded wait, and replies that arrive after it
##
## `runStartupProbe` waits for the fence at most `startupProbeTimeoutMs()`
## (`DefaultStartupProbeMs`, overridable with `CT_TUI_PROBE_TIMEOUT_MS`) — ONE
## wait for both questions, not two. A local terminal answers the whole round
## in well under a millisecond, so the first frame is painted in the right
## mode and depth. A terminal on a slow link may answer later: the driver's
## framer keeps recognising reply strings until the fence arrives (or
## `ReplyWindowMs` passes), and the main loop hands every late reply to
## `noteReply`, re-resolves and repaints. A terminal that never answers leaves
## the environment's answer and Dark in place — vim's default.
##
## ## Nothing here decides anything
##
## `TerminalProbe` is what was SEEN. `app/theme/capabilities.resolveCapabilities`
## decides what it means.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it owns the tty.".}

import std/[monotimes, os, osproc, posix, strutils, times]

import ./capabilities
import ./terminal_driver
import ../app/input/mouse

export mouse

export capabilities

const
  Osc11Query* = "\x1b]11;?\x1b\\"
  XtGetTcapQuery* = "\x1bP+q524742;5463\x1b\\"
    ## `RGB` and `Tc`, hex-encoded as XTGETTCAP requires.
  DecrqssProbeSgr* = "\x1b[48:2:1:2:3m"
    ## A 24-bit background whose value (1,2,3) no real palette entry has, so a
    ## report that echoes `2:1:2:3` can only be the colour kept verbatim.
  DecrqssQuery* = "\x1bP$qm\x1b\\"
  SgrReset* = "\x1b[m"
  Da1Query* = "\x1b[c"
  PixelMouseQuery* = "\x1b[?1016$p"
    ## PLAT-51: DECRQM for SGR-pixel mouse reporting (DECSET 1016). The
    ## answer is `CSI ? 1016 ; Ps $ y` — Ps 1 / 2 / 3 recognised, 0 / 4 not.
  CellSizeQuery* = "\x1b[16t"
    ## PLAT-51: the cell's size in pixels — `CSI 6 ; height ; width t`.
  StartupQueries* = Osc11Query & XtGetTcapQuery & DecrqssProbeSgr &
                    DecrqssQuery & SgrReset & Da1Query
    ## The whole round, written in ONE `write(2)` so a terminal answers it as
    ## one burst and the DA1 fence is last.

  DefaultStartupProbeMs* = 10
    ## The bounded wait for the fence before the first frame. A local terminal
    ## answers in well under a millisecond; this is the ceiling a terminal that
    ## never answers (a bare parser, a dumb pipe that claims to be a tty) costs
    ## the cold start, and CTUI-11's cold-start gate is 50 ms.
  ReplyWindowMs* = 3000
    ## How long after the queries a LATE reply is still recognised as one, when
    ## the fence never came back.

proc startupProbeTimeoutMs*(): int =
  ## `DefaultStartupProbeMs`, or `CT_TUI_PROBE_TIMEOUT_MS` when it is a
  ## non-negative integer — how a test on a PTY that answers slowly on purpose
  ## gives the round room.
  let raw = getEnv("CT_TUI_PROBE_TIMEOUT_MS", "")
  if raw.len > 0:
    try:
      let v = parseInt(raw)
      if v >= 0:
        return v
    except ValueError:
      discard
  DefaultStartupProbeMs

proc isDa1Reply*(token: string): bool =
  token.len >= 4 and token.startsWith("\x1b[?") and token[^1] == 'c'

proc isPixelMouseReply*(token: string): bool =
  token.startsWith("\x1b[?1016;") and token.endsWith("$y")

proc isCellSizeReply*(token: string): bool =
  token.startsWith("\x1b[6;") and token.endsWith("t")

proc isReplyToken*(token: string): bool =
  ## Whether an input token is a terminal's ANSWER rather than a key: an OSC,
  ## DCS or APC string, a DA1 report, or (PLAT-51) a DECRQM answer for 1016
  ## or a cell-size report. No key produces any of these.
  if token.len < 2 or token[0] != '\x1b':
    return false
  token[1] in {']', 'P', '_'} or isDa1Reply(token) or
    isPixelMouseReply(token) or isCellSizeReply(token)

proc decodeHex(s: string): string =
  result = ""
  var i = 0
  while i + 1 < s.len:
    try:
      result.add char(fromHex[int](s[i .. i + 1]))
    except ValueError:
      return ""
    i += 2

proc noteReply*(probe: var TerminalProbe; token: string): bool =
  ## Record what one reply token says. Returns whether it was a reply at all.
  if not isReplyToken(token):
    return false
  probe.attempted = true
  if isDa1Reply(token):
    probe.answered = true
    return true
  if isPixelMouseReply(token):
    # `CSI ? 1016 ; Ps $ y`: 1 set, 2 reset, 3 permanently set — the mode is
    # known; 0 not recognised, 4 permanently reset.
    probe.pixelMouseAnswered = true
    let body = token["\x1b[?1016;".len ..< token.len - 2]
    try:
      probe.pixelMouse = parseInt(body) in {1, 2, 3}
    except ValueError:
      probe.pixelMouse = false
    return true
  if isCellSizeReply(token):
    let parts = token["\x1b[6;".len ..< token.len - 1].split(';')
    if parts.len == 2:
      try:
        let h = parseInt(parts[0])
        let w = parseInt(parts[1])
        if h > 0 and w > 0:
          probe.cellHeightPx = h
          probe.cellWidthPx = w
      except ValueError:
        discard
    return true
  if token.startsWith("\x1b]11;"):
    let (ok, rgb) = parseOsc11Reply(token)
    if ok:
      probe.hasBackground = true
      probe.background = rgb
    return true
  if token.startsWith("\x1bP1+r"):
    # XTGETTCAP, valid answer: `DCS 1 + r <hex name>=<hex value> ST`, one or
    # more `;`-separated. Any answer for `RGB` or `Tc` is a claim of 24-bit.
    let body = token[5 .. ^1].split('\x1b')[0]
    for item in body.split(';'):
      let name = decodeHex(item.split('=')[0])
      if name in ["RGB", "Tc"]:
        probe.truecolor = true
        if probe.truecolorVia.len == 0:
          probe.truecolorVia = "xtgettcap"
    return true
  if token.startsWith("\x1bP1$r"):
    # DECRQSS, valid answer: the SGR the terminal is holding. xterm writes
    # direct colour with an (empty) colour-space field, `48:2::1:2:3`; others
    # write `48:2:1:2:3` or the semicolon form `48;2;1;2;3`. The (1,2,3)
    # triple is the proof: no palette approximation lands on it.
    if (token.contains("48:2") or token.contains("48;2")) and
       (token.contains(":1:2:3") or token.contains(";1;2;3")):
      probe.truecolor = true
      if probe.truecolorVia.len == 0:
        probe.truecolorVia = "decrqss"
    return true
  true

proc readTmuxFeatures*(probe: var TerminalProbe) =
  ## tmux's view of its client: does it pass 24-bit colour on (`RGB`)?
  ##
  ## `client_termfeatures` lists the features tmux uses for the client this
  ## pane is displayed on; `client_termname` is that client's `TERM`, for the
  ## remedy's pattern. A tmux too old for the format, or with no client,
  ## prints nothing useful — `tmuxQueried` stays false and nothing is claimed.
  var output = ""
  var code = -1
  try:
    (output, code) = execCmdEx(
      "tmux display -p '#{client_termfeatures}\t#{client_termname}'")
  except CatchableError, Defect:
    return
  if code != 0:
    return
  let line = output.strip(leading = false)
  let parts = line.split('\t')
  if parts.len < 2 or parts[0].len == 0:
    return
  probe.tmuxQueried = true
  probe.tmuxClientTerm = parts[1].strip()
  for feature in parts[0].split(','):
    if feature.strip() == "RGB":
      probe.tmuxRgb = true
      if probe.truecolorVia.len == 0:
        probe.truecolorVia = "tmux"

proc writeQueries(fd: cint; data: string): bool =
  var written = 0
  while written < data.len:
    let n = posix.write(fd, cast[pointer](unsafeAddr data[written]),
                        data.len - written)
    if n <= 0:
      return false
    written += int(n)
  true

proc queriesFor*(flags: CapabilityFlags): string =
  ## The round this command line needs, in the order the header lists.
  ##
  ## Only what can change a decision is asked: no background query when
  ## `--theme` pinned the mode, and no 24-bit query when a flag decided the
  ## depth or `--palette=terminal` asked for the sixteen colours — which also
  ## keeps the DECRQSS probe's own 24-bit SGR out of a byte stream the user
  ## asked to be sixteen-colour only. DA1 always ends it.
  result = ""
  if not flags.themePinned:
    result.add Osc11Query
  let depthDecided = flags.noColor or flags.theme == utPlain or
                     flags.forceTrueColor
  if not depthDecided and flags.palette != pkTerminal:
    result.add XtGetTcapQuery & DecrqssProbeSgr & DecrqssQuery & SgrReset
  # PLAT-51: whether the mouse can report PIXELS (1016) and how big a cell
  # is — GoldenLayout's drop zones are decided in pixels (Layout-ViewModel
  # §4.2.2). Not asked under `--no-mouse`.
  if not flags.noMouse:
    result.add PixelMouseQuery & CellSizeQuery
  result.add Da1Query

proc runStartupProbe*(d: TerminalDriver; env: TerminalEnv;
                      flags: CapabilityFlags;
                      timeoutMs = startupProbeTimeoutMs()): TerminalProbe =
  ## Write the round, then read until the DA1 fence or `timeoutMs`.
  ##
  ## MUST RUN AFTER `d.start()`: the answers come back on the input fd, and a
  ## terminal in canonical mode holds them in its line buffer until a newline
  ## that never comes. Every NON-reply token read here (a key typed ahead) is
  ## queued on `d.buffered`, which `nextEvent` drains first, so nothing the
  ## user typed is lost.
  result = TerminalProbe(attempted: true)
  if not writeQueries(d.outFd, queriesFor(flags)):
    return
  d.expectReplies(true)
  if env.tmux.len > 0 and flags.palette != pkTerminal:
    readTmuxFeatures(result)
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not result.answered:
    let left = (deadline - getMonoTime()).inMilliseconds
    if left <= 0:
      break
    let b = readByteWithTimeout(int(left), d.inFd)
    if b < 0:
      if b == ReadEof:
        break
      continue
    let (complete, token) = d.framer.feed(char(b))
    if not complete:
      continue
    if not noteReply(result, token):
      d.buffered.add token
  if result.answered:
    d.expectReplies(false)

proc replyWindowOpen*(probe: TerminalProbe; startedMs, nowMs: int64): bool =
  ## Whether a late reply can still arrive: the fence has not, and the window
  ## has not closed.
  probe.attempted and not probe.answered and nowMs - startedMs < ReplyWindowMs

# ---------------------------------------------------------------------------
# The negotiation, as the entrypoint holds it
# ---------------------------------------------------------------------------

type
  StartupNegotiation* = ref object
    ## The environment, the flags and what the terminal has answered so far —
    ## everything `resolveCapabilities` needs to re-decide when a LATE reply
    ## arrives. Held by `main.nim` for the life of the session.
    env*: TerminalEnv
    flags*: CapabilityFlags
    probe*: TerminalProbe
    startedMs*: int64
    caps*: TerminalCapabilities

proc monoMs(): int64 = (getMonoTime() - MonoTime()).inMilliseconds

proc negotiateOnTerminal*(d: TerminalDriver;
                          flags: CapabilityFlags): StartupNegotiation =
  ## Run the start-up round on a STARTED driver and adopt what it decides.
  let env = readTerminalEnv(d.outFd)
  result = StartupNegotiation(env: env, flags: flags, startedMs: monoMs())
  if probeWanted(env, flags):
    result.probe = d.runStartupProbe(env, flags)
  result.caps = resolveCapabilities(env, flags, result.probe)
  d.adoptCapabilities(result.caps)

proc takeReply*(n: StartupNegotiation; d: TerminalDriver;
                token: string): (bool, bool) =
  ## `(wasReply, capabilitiesChanged)` for one input token. A reply is never a
  ## key: the caller drops it instead of handing it to the keymap.
  if n.isNil or not isReplyToken(token):
    return (false, false)
  discard noteReply(n.probe, token)
  if n.probe.answered:
    d.expectReplies(false)
  let next = resolveCapabilities(n.env, n.flags, n.probe)
  if next == n.caps:
    return (true, false)
  n.caps = next
  d.adoptCapabilities(next)
  (true, true)

proc closeReplyWindow*(n: StartupNegotiation; d: TerminalDriver) =
  ## Stop recognising reply strings once the window has passed with no fence,
  ## so `ESC ]` / `ESC P` go back to meaning Alt+key.
  if n.isNil:
    return
  if not replyWindowOpen(n.probe, n.startedMs, monoMs()):
    d.expectReplies(false)

proc switchTheme*(n: StartupNegotiation; d: TerminalDriver;
                  theme: UiTheme): bool =
  ## §4.3's `:theme <dark|light>` on a LIVE session: pin the named mode, as
  ## `--theme` would have at start-up, re-resolve with everything the terminal
  ## has answered so far, and adopt the result on the driver so the next frame
  ## is a full repaint in the new mode. A background answer arriving later no
  ## longer moves the mode — the user chose it. Returns whether the
  ## capabilities changed.
  if n.isNil:
    return false
  n.flags.theme = theme
  n.flags.themePinned = true
  let next = resolveCapabilities(n.env, n.flags, n.probe)
  if next == n.caps:
    return false
  n.caps = next
  d.adoptCapabilities(next)
  true

proc mouseMetricsOf*(probe: TerminalProbe; mouseOn: bool): MouseMetrics =
  ## PLAT-51: how this terminal's mouse reports map to pixels. SGR-pixel
  ## (1016) only when the terminal recognises the mode AND said how big a cell
  ## is (without it a pixel could not be put back into its cell); else cells,
  ## mapped to their centres through the measured cell size — or the
  ## desktop's when the terminal did not say.
  result = MouseMetrics(pixels: false, cellW: DesktopCellWidthPx,
                        cellH: DesktopCellHeightPx, measured: false)
  if probe.cellWidthPx > 0 and probe.cellHeightPx > 0:
    result.cellW = float(probe.cellWidthPx)
    result.cellH = float(probe.cellHeightPx)
    result.measured = true
  result.pixels = mouseOn and probe.pixelMouse and result.measured
