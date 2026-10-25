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
##   4. `CSI ? u`               PLAT-68: does the terminal implement the Kitty
##                              keyboard protocol? One that does answers
##                              `CSI ? <flags> u` BEFORE the fence; one that
##                              does not answers only the fence
##                              (Base-Keymaps-And-Layer-Stack.md §7.2).
##   5. DA1 (`CSI c`)           the FENCE. Every terminal and multiplexer
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

import std/[monotimes, os, osproc, posix, streams, strutils, times]

import ./capabilities
import ./terminal_cache
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
  KittyKeyboardQuery* = "\x1b[?u"
    ## PLAT-68: query the Kitty keyboard flags. Asked on every round: whether
    ## the CUA base's `Ctrl+Shift+…` chords can be typed depends on it.
  CellSizeQuery* = "\x1b[16t"
    ## PLAT-51: the cell's size in pixels — `CSI 6 ; height ; width t`.
  XtversionQuery* = "\x1b[>q"
    ## PLAT-71 (Terminal-Adaptation §4.2 row 6): XTVERSION, the terminal's
    ## name and version — `DCS > | name(version) ST`.
  Da2Query* = "\x1b[>c"
    ## Row 7: DA2, the terminal's type and firmware version.
  SyncModeQuery* = "\x1b[?2026$p"
  GraphemeModeQuery* = "\x1b[?2027$p"
    ## Row 8: DECRQM for synchronized output (2026) and grapheme clustering
    ## (2027). `Ps = 0` is a NEGATIVE answer.
  GraphemeModeOnBytes* = "\x1b[?2027h"
  GraphemeModeOffBytes* = "\x1b[?2027l"
  SyncOffBytes* = "\x1b[?2026l"
  CursorReportQuery* = "\x1b[6n"
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

proc isModeReply*(token: string): bool =
  ## PLAT-71: a DECRQM answer for synchronized output or grapheme clustering.
  token.startsWith("\x1b[?2026;") or token.startsWith("\x1b[?2027;")

proc isKittyKeyboardReply*(token: string): bool =
  ## `CSI ? <flags> u` — the answer to `CSI ? u`.
  if not (token.len >= 4 and token.startsWith("\x1b[?") and token[^1] == 'u'):
    return false
  for c in token[3 ..< token.len - 1]:
    if c notin '0'..'9': return false
  true

proc isReplyToken*(token: string): bool =
  ## Whether an input token is a terminal's ANSWER rather than a key: an OSC,
  ## DCS or APC string, a DA1 report, or (PLAT-51) a DECRQM answer for 1016
  ## or a cell-size report. No key produces any of these.
  if token.len < 2 or token[0] != '\x1b':
    return false
  token[1] in {']', 'P', '_'} or isDa1Reply(token) or
    isPixelMouseReply(token) or isCellSizeReply(token) or
    isKittyKeyboardReply(token) or
    # PLAT-71: DA2 and the DECRQM answers for 2026 / 2027. No key is either.
    isDa2Reply(token) or isModeReply(token)

proc isCprToken*(token: string): bool =
  ## `CSI <row> ; <col> R` — a cursor report, or a modified F3 in legacy
  ## xterm (`CSI 1 ; 5 R` is Ctrl+F3). Which one it is depends on whether the
  ## width probe is still waiting (`cprOpen`).
  parseCpr(token)[0]

proc cprOpen*(probe: TerminalProbe): bool =
  ## §4.3's F3 rule: while the width probe has asked for N cursor reports and
  ## fewer have arrived, a `CSI r ; c R` is a REPLY; after that it is a key.
  probe.cprAnswers.len < probe.cprExpected

proc isReplyTokenFor*(probe: TerminalProbe; token: string): bool =
  ## `isReplyToken`, and a cursor report while the width probe waits for one.
  isReplyToken(token) or (isCprToken(token) and probe.cprOpen)

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
  if not probe.isReplyTokenFor(token):
    return false
  probe.attempted = true
  if isDa1Reply(token):
    probe.answered = true
    return true
  # PLAT-71: the width probe's cursor reports (§4.3), in the order asked;
  # the width of probe i is its column minus one.
  if isCprToken(token):
    let (_, _, col) = parseCpr(token)
    probe.cprAnswers.add max(0, col - 1)
    return true
  if token.startsWith("\x1bP>|"):
    let (ok, text) = parseXtversionReply(token)
    if ok:
      probe.xtversion = text
    return true
  if isDa2Reply(token):
    let (ok, pp, pv) = parseDa2(token)
    if ok:
      probe.da2Answered = true
      probe.da2Pp = pp
      probe.da2Pv = pv
    return true
  if isModeReply(token):
    let (ok, mode, ps) = parseDecrqm(token)
    if ok and mode == 2026:
      probe.sync2026Answered = true
      probe.sync2026 = ps
    elif ok and mode == 2027:
      probe.grapheme2027Answered = true
      probe.grapheme2027 = ps
    return true
  if isKittyKeyboardReply(token):
    probe.kittyKeyboardAnswered = true
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

const
  TmuxFormats* = ["client_termfeatures", "client_termname", "client_termtype",
                  "client_utf8", "version", "allow-passthrough",
                  "set-clipboard", "extended-keys", "focus-events", "mouse"]
    ## PLAT-71 (Terminal-Adaptation §4.5): EVERY tmux fact, in ONE
    ## `tmux display -p`: tmux's view of its client (its features, its TERM,
    ## its XTVERSION identity, whether it is UTF-8), tmux's version, and the
    ## options that decide what reaches this pane. tmux answers every query
    ## itself, so what it knows about the OUTER terminal comes from here and
    ## never from a passthrough query (TA-14).

proc tmuxFormatString*(): string =
  var parts: seq[string] = @[]
  for f in TmuxFormats:
    parts.add "#{" & f & "}"
  parts.join("\t")

type
  TmuxQuery* = object
    ## The `tmux display -p` running BESIDE the start-up write (§4.5: the
    ## spawn runs in parallel, so it adds no wait).
    process*: Process
    started*: bool

proc startTmuxQuery*(): TmuxQuery =
  ## Spawn the one `tmux display -p`. Called before the round is written.
  try:
    result.process = startProcess("tmux", args = ["display", "-p",
                                  tmuxFormatString()],
                                  options = {poUsePath, poStdErrToStdOut})
    result.started = true
  except CatchableError, Defect:
    result.started = false

proc applyTmuxFacts*(probe: var TerminalProbe; line: string) =
  ## One `display -p` line — the `TmuxFormats` values, tab-separated — into
  ## the probe. A tmux too old for a format prints it empty; nothing is
  ## claimed for an empty value.
  let parts = line.strip(leading = false).split('\t')
  if parts.len < TmuxFormats.len:
    return
  # tmux's own facts (its version, its options) are known whether or not a
  # client is attached; what it says about its CLIENT only when one is — a
  # detached server lists no features, and nothing is claimed about 24-bit
  # colour from that silence.
  probe.tmuxVersion = parts[4].strip()
  probe.tmuxPassthrough = parts[5].strip()
  probe.tmuxSetClipboard = parts[6].strip()
  probe.tmuxExtendedKeys = parts[7].strip()
  probe.tmuxFocusEvents = parts[8].strip()
  probe.tmuxMouse = parts[9].strip()
  if parts[0].len == 0 or parts[1].len == 0:
    return
  probe.tmuxQueried = true
  probe.tmuxClientTerm = parts[1].strip()
  probe.tmuxClientTermType = parts[2].strip()
  probe.tmuxClientUtf8 = parts[3].strip()
  for feature in parts[0].split(','):
    if feature.strip() == "RGB":
      probe.tmuxRgb = true
      if probe.truecolorVia.len == 0:
        probe.truecolorVia = "tmux"

proc finishTmuxQuery*(q: var TmuxQuery; probe: var TerminalProbe) =
  ## Collect the spawn's answer (it has had the round's wait to finish).
  if not q.started:
    return
  try:
    let output = q.process.outputStream.readAll()
    let code = q.process.waitForExit()
    q.process.close()
    q.started = false
    if code == 0:
      applyTmuxFacts(probe, output)
  except CatchableError, Defect:
    q.started = false

proc readTmuxFeatures*(probe: var TerminalProbe) =
  ## The tmux facts, read synchronously (`startTmuxQuery` and
  ## `finishTmuxQuery` back to back) — for a caller that has no round.
  var q = startTmuxQuery()
  finishTmuxQuery(q, probe)

proc writeQueries(fd: cint; data: string): bool =
  var written = 0
  while written < data.len:
    let n = posix.write(fd, cast[pointer](unsafeAddr data[written]),
                        data.len - written)
    if n <= 0:
      return false
    written += int(n)
  true

const MinProbeColumns* = 3
  ## §4.3: on a terminal narrower than this the width probe is skipped.

proc widthProbeBytes*(cols = 80): (string, int) =
  ## §4.3's width probe and how many cursor reports it asks for: each probe
  ## printed at the top-left of the alternate screen with a `CSI 6 n` after
  ## it, the row erased in the same write, all inside a DEC 2026 bracket so a
  ## terminal that implements it never shows them. Frame 0 overwrites the
  ## row anyway.
  if cols < MinProbeColumns:
    return ("", 0)
  var bytes = "\x1b[?2026h"
  var n = 0
  for p in WidthProbe:
    bytes.add "\x1b[1;1H" & WidthProbeText[p] & CursorReportQuery
    inc n
  bytes.add "\x1b[1;1H\x1b[2K" & SyncOffBytes
  (bytes, n)

proc queriesFor*(flags: CapabilityFlags; env = TerminalEnv(term: "xterm");
                 cols = 80): string =
  ## The round this command line needs, in the order the header lists.
  ##
  ## Only what can change a decision is asked: no background query when
  ## `--theme` pinned the mode, and no 24-bit query when a flag decided the
  ## depth or `--palette=terminal` asked for the sixteen colours — which also
  ## keeps the DECRQSS probe's own 24-bit SGR out of a byte stream the user
  ## asked to be sixteen-colour only. DA1 always ends it.
  ##
  ## PLAT-71 (Terminal-Adaptation §4.2): XTVERSION, DA2, DECRQM 2026 / 2027
  ## and the width probe are asked on every start, before the fence — so
  ## their answers have all arrived (or never will) when DA1's does. The
  ## Linux console gets only the width probe and the fence: `console_codes(4)`
  ## documents DA and CPR, and nothing says it ignores the rest silently.
  result = ""
  if env.term.toLowerAscii == "linux":
    result.add widthProbeBytes(cols)[0]
    result.add Da1Query
    return
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
  result.add KittyKeyboardQuery
  result.add XtversionQuery & Da2Query & SyncModeQuery & GraphemeModeQuery
  result.add widthProbeBytes(cols)[0]
  result.add Da1Query

proc cprCountFor*(env: TerminalEnv; cols: int): int =
  ## How many cursor reports `queriesFor` asks for on this terminal.
  widthProbeBytes(cols)[1]

proc monoMs(): int64 = (getMonoTime() - MonoTime()).inMilliseconds

proc runStartupProbe*(d: TerminalDriver; env: TerminalEnv;
                      flags: CapabilityFlags;
                      timeoutMs = startupProbeTimeoutMs()): TerminalProbe =
  ## Write the round, then read until the DA1 fence or `timeoutMs`.
  ##
  ## MUST RUN AFTER `d.start()`: the answers come back on the input fd, and a
  ## terminal in canonical mode holds them in its line buffer until a newline
  ## that never comes. Every NON-reply token read here (a key typed ahead) is
  ## queued on `d.buffered`, which `nextEvent` drains first, so nothing the
  ## user typed is lost (Terminal-Adaptation §4.8 rule 2, TA-4).
  ##
  ## Inside tmux the one `tmux display -p` is spawned BEFORE the write and
  ## collected after the wait, so it costs no wait of its own (§4.5).
  result = TerminalProbe(attempted: true)
  let cols = d.size().cols
  result.cprExpected = cprCountFor(env, cols)
  var tmux = TmuxQuery()
  if env.tmux.len > 0:
    tmux = startTmuxQuery()
  let writtenAt = getMonoTime()
  if not writeQueries(d.outFd, queriesFor(flags, env, cols)):
    finishTmuxQuery(tmux, result)
    return
  d.expectReplies(true)
  let deadline = writtenAt + initDuration(milliseconds = timeoutMs)
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
      result.rttMeasured = true
      result.rttMs = int((getMonoTime() - writtenAt).inMilliseconds)
  finishTmuxQuery(tmux, result)
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
    # --- PLAT-71 -----------------------------------------------------------
    prefs*: TerminalPrefs
      ## The remembered settings: global and per terminal (§5.2 ranks 4–5).
    session*: TerminalChoices
      ## What `:set` chose in this session (rank 1).
    cacheKey*: string
    cacheEntries*: seq[CachedProfile]
    cache*: Option[CachedProfile]
      ## This terminal's last answers (§4.7), consulted only where nothing
      ## live has answered.
    cacheReadable*: bool
    cacheMessage*: string
    cacheWritten*: bool
    useCache*: bool

proc resolve*(n: StartupNegotiation): TerminalCapabilities =
  ## The profile from everything known now (TA-1's pure function).
  resolveCapabilities(n.env, n.flags, n.probe, n.prefs, n.session, n.cache)

proc rememberAnswers*(n: StartupNegotiation) =
  ## Write this terminal's answers to the cache once the fence has come back
  ## (a session the terminal did not answer remembers nothing).
  if n.isNil or n.cacheWritten or not n.useCache or not n.cacheReadable or
     not n.probe.answered:
    return
  n.cacheWritten = true
  let entry = cacheEntryOf(n.cacheKey, n.probe, n.caps)
  n.cacheEntries = rememberInCache(n.cacheEntries, entry)
  let failure = saveTerminalCache(n.cacheEntries)
  if failure.len > 0:
    n.cacheMessage = "the terminal cache could not be written: " & failure

proc negotiateOnTerminal*(d: TerminalDriver; flags: CapabilityFlags;
                          prefs = TerminalPrefs();
                          useCache = true): StartupNegotiation =
  ## Run the start-up round on a STARTED driver and adopt what it decides.
  let env = readTerminalEnv(d.outFd)
  result = StartupNegotiation(env: env, flags: flags, startedMs: monoMs(),
                              prefs: prefs, useCache: useCache,
                              cacheReadable: true)
  if useCache and env.isTty:
    result.cacheKey = cacheKeyOf(env)
    let loaded = loadTerminalCache()
    result.cacheEntries = loaded.entries
    result.cacheReadable = loaded.readable
    result.cacheMessage = loaded.message
    result.cache = lookupCache(loaded.entries, result.cacheKey, nowSeconds())
  if probeWanted(env, flags, prefs):
    result.probe = d.runStartupProbe(env, flags)
  result.caps = result.resolve()
  d.adoptCapabilities(result.caps)
  result.rememberAnswers()

proc takeReply*(n: StartupNegotiation; d: TerminalDriver;
                token: string): (bool, bool) =
  ## `(wasReply, capabilitiesChanged)` for one input token. A reply is never a
  ## key: the caller drops it instead of handing it to the keymap.
  if n.isNil or not n.probe.isReplyTokenFor(token):
    return (false, false)
  let wasAnswered = n.probe.answered
  discard noteReply(n.probe, token)
  if n.probe.answered:
    d.expectReplies(false)
    if not wasAnswered and not n.probe.rttMeasured:
      # A LATE fence: the round trip is the time since the round was
      # written (§4.6) — a slow link, measured.
      n.probe.rttMeasured = true
      n.probe.rttMs = int(monoMs() - n.startedMs)
  let next = n.resolve()
  if n.probe.answered:
    n.rememberAnswers()
  if next == n.caps:
    return (true, false)
  n.caps = next
  d.adoptCapabilities(next)
  (true, true)

proc setSessionChoice*(n: StartupNegotiation; d: TerminalDriver;
                       choices: TerminalChoices): bool =
  ## PLAT-71: a runtime `:set` of a terminal setting (rank 1): re-resolve
  ## with it and adopt the result. Returns whether the profile changed.
  if n.isNil:
    return false
  n.session = merge(choices, n.session)
  let next = n.resolve()
  if next == n.caps:
    return false
  n.caps = next
  d.adoptCapabilities(next)
  true

proc restartProbe*(n: StartupNegotiation; d: TerminalDriver) =
  ## `:terminal-info`'s `r`: ask the terminal again. The round is written
  ## now and its answers arrive through the main loop (`takeReply`), as a
  ## slow terminal's late answers do; the profile is re-resolved on each.
  if n.isNil or not probeWanted(n.env, n.flags, n.prefs, n.session):
    return
  let cols = d.size().cols
  n.probe = TerminalProbe(attempted: true,
                          cprExpected: cprCountFor(n.env, cols))
  if n.env.tmux.len > 0:
    readTmuxFeatures(n.probe)
  n.startedMs = monoMs()
  n.cacheWritten = false
  if writeQueries(d.outFd, queriesFor(n.flags, n.env, cols)):
    d.expectReplies(true)

proc setPrefs*(n: StartupNegotiation; d: TerminalDriver;
               prefs: TerminalPrefs): bool =
  ## The remembered settings changed (a scoped `y` on the test card).
  if n.isNil:
    return false
  n.prefs = prefs
  let next = n.resolve()
  if next == n.caps:
    return false
  n.caps = next
  d.adoptCapabilities(next)
  true

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
  let next = n.resolve()
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

const HoverCoalesceMs* = 50'i64
  ## Terminal-Adaptation §4.6: on a link-conservative session, hover-driven
  ## repaints are coalesced to one per this many milliseconds.

proc isPointerPassing*(token: string): bool =
  ## A motion report with no button held: the pointer merely passing.
  let (isMouse, event) = decodeMouse(token)
  isMouse and event.kind == mekMotion and
    event.button notin {mbLeft, mbMiddle, mbRight}
