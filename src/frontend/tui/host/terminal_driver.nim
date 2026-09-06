## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
## See `host/native_host.nim`'s header for the full rule, and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that keeps
## `app/` on the other side of it.
##
## host/terminal_driver.nim — CTUI-11. The TTY: termios raw mode, a restore that
## survives a signal, the alternate screen, the read loop and the token framing.
##
## ## Why this file is CTUI-11's and not CTUI-9's
##
## CTUI-9 landed the whole of key DISPATCH — `app/input/keymap.resolve`, the
## four-mode machine, the motions — and declined the driver, on the ground that
## a loop landed then would have had to be reopened here to put capability
## negotiation ahead of its first frame. That is exactly what this module's
## constructor enforces: `newTerminalDriver` takes a resolved
## `TerminalCapabilities` and there is no other way to build one, so no path
## exists on which a frame is painted before the terminal was negotiated with.
##
## ## THE FRAMING IS SHARED WITH THE SNAPSHOT RUNTIME, NOT FORKED FROM IT
##
## `testing/test_app_runtime.nim` has framed input tokens, read bytes with a
## timeout and emitted a frame since CTUI-2, and CTUI-6 taught it whole escape
## sequences so `decodeMouse` could be asserted against real bytes. Those three
## pieces are now HERE, and that module imports them. The direction is forced
## and is worth stating: `tests/test_tui_build_prerequisites.nim` asserts that
## no module under `testing/` appears in `main.nim`'s import closure, so the
## shipped driver could not have imported the runtime — the shared code has to
## live on this side of that line, and the test-only runtime reaches down to it.
##
## Sharing it is not tidiness. The framing is the one piece of this front-end
## that is exercised against a real terminal on every Tier-2 case in the tree,
## and a second copy in the shipped binary would be the copy nothing tested.
##
## ## What `InputFramer` changed, and what it deliberately did not
##
## Byte for byte, `InputFramer` reproduces the runtime's previous behaviour on
## every sequence any suite in this tree sends — including the two the harness
## documentation records as load-bearing:
##
##   * a lone `\x1b` is held (it is a prefix of every escape sequence), and
##     `\x1b\x1b` delivers exactly one `Esc` token, because the second byte
##     breaks the prefix and is honoured on its own;
##   * an unterminated CSI longer than `MaxSequenceBytes` is dropped rather than
##     accumulated forever.
##
## It adds ONE thing: **SS3**. `ESC O P` … `ESC O S` are xterm's F1-F4, they are
## exactly what `TermAssert.sendKey("f1")` writes, §4.2 binds `F1` to the
## command palette, and `keymap.keyName` has decoded them since CTUI-9 — but the
## old framing dropped the `ESC`, delivered `O` and then `P` as two ordinary
## bytes, so `F1` was a binding no terminal could reach. Nothing in this tree
## sent those bytes (checked before the change), so no existing byte stream
## moves.
##
## ## The restore is nim-termctl's, and that is the whole point
##
## `enableRawMode` installs SIGINT/SIGTERM/SIGHUP/SIGQUIT handlers and an
## `atexit` hook on first call, and all of them run one async-signal-safe
## function that leaves the alternate screen, drops mouse reporting, shows the
## cursor and `tcsetattr`s the saved termios back — using only `write(2)` and
## `tcsetattr`, with no allocation. Writing a second one here would be a second
## thing to keep correct, on the path where correctness is hardest to observe.
##
## Note what `cfmakeraw(3)` means for `Ctrl+c`: `ISIG` is cleared, so `0x03`
## arrives as a byte and §4.2's "Quit Debugger — exit CodeTracer TUI session
## CLEANLY" is reachable, instead of the line discipline killing the process
## first. CTUI-9 made the same change to the snapshot runtime for the same
## reason. SIGTERM and SIGHUP — a `kill`, a closed terminal window — are the
## signals the handler still exists for, and they are the ones a restore has to
## survive.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it owns the tty.".}

import std/[monotimes, os, posix, strutils, times, unicode]

import isonim_tui
import nim_termctl

import ../app/input/modal_state
import ../app/theme/degradation
import ../app/views/styled_row
import ./capabilities
import ./resize
import ./ssh_tuning

export capabilities, resize
export ssh_tuning

# ---------------------------------------------------------------------------
# Token framing
# ---------------------------------------------------------------------------

const
  Esc* = '\x1b'
  MaxSequenceBytes* = 64
    ## A CSI longer than this is not a sequence, it is a stuck terminal or a
    ## paste of binary. Dropped rather than accumulated, so one bad byte cannot
    ## make the front-end stop responding to the keyboard for the rest of the
    ## session.

type
  InputFramer* = object
    ## The byte-to-token state machine, as a value.
    ##
    ## A VALUE AND NOT A LOOP, which is what makes it assertable without a
    ## terminal: `app/input/keymap.keyName` takes a whole token, so the framing
    ## and the decoding are two functions with a string between them rather than
    ## one function with a file descriptor in it.
    pending*: string

proc initInputFramer*(): InputFramer =
  InputFramer(pending: "")

proc reset*(f: var InputFramer) =
  f.pending = ""

proc isCsiFinal*(c: char): bool =
  ## Whether `c` terminates a CSI sequence: ECMA-48's final-byte range
  ## 0x40-0x7E. Parameter bytes are 0x30-0x3F and intermediates 0x20-0x2F, so
  ## `ESC [ < 0 ; 12 ; 5 M` ends at `M` and `ESC [ 21 ~` at `~`.
  c >= '\x40' and c <= '\x7e'

proc feed*(f: var InputFramer; b: char): (bool, string) =
  ## One byte in; a complete token out, or `(false, "")` while one is still
  ## being assembled.
  ##
  ## The three shapes are xterm's own: a bare byte, `ESC [ … <final>` (CSI) and
  ## `ESC O <x>` (SS3). Everything else that starts with `ESC` is resolved the
  ## way the snapshot runtime has always resolved it — the escape is dropped and
  ## the byte that broke the prefix is honoured on its own, which is what makes
  ## `\x1b\x1b` deliver exactly one `Esc`.
  if f.pending.len == 0:
    if b != Esc:
      return (true, $b)
    f.pending = $Esc
    return (false, "")

  f.pending.add b
  if f.pending.len == 2:
    case b
    of '[', 'O':
      # A CSI or an SS3 is starting; keep accumulating.
      return (false, "")
    else:
      # NOT AN ESCAPE SEQUENCE. Drop the `ESC` and honour the byte that broke
      # it, exactly as the runtime always has: `\x1b\x1b` therefore yields one
      # `Esc`, and a `q` after a stray escape still quits.
      let broke = $b
      f.reset()
      return (true, broke)

  if f.pending[1] == 'O':
    # `ESC O <x>` — three bytes, no parameters. xterm's PC-style function keys
    # F1-F4 (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).
    let token = f.pending
    f.reset()
    return (true, token)

  # A CSI. Parameters and intermediates accumulate; the final byte ends it.
  if f.pending.len > MaxSequenceBytes:
    f.reset()
    return (false, "")
  if isCsiFinal(b):
    let token = f.pending
    f.reset()
    return (true, token)
  (false, "")

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

const
  ReadTimeout* = -1
  ReadEof* = -2
  ReadWoke* = -3
    ## `wakeFd` became readable. Returned rather than handled here so the
    ## caller — which owns the `ResizeWatcher` — is the one that drains the
    ## self-pipe, and so "a signal arrived" and "a byte arrived" are two
    ## different answers rather than one timeout.

proc readByteWithTimeout*(timeoutMs: int; fd: cint = STDIN_FILENO;
                          wakeFd: cint = -1): int =
  ## One byte from `fd`, or `ReadTimeout` / `ReadEof` / `ReadWoke`.
  ##
  ## `wakeFd` is `host/resize.resizeWakeFd()` — the read end of the SIGWINCH
  ## self-pipe. Selecting on it rather than polling on the timeout is what keeps
  ## a reflow's latency the kernel's rather than this loop's: with a 100 ms poll
  ## every measured resize would carry up to 100 ms of this function in it, and
  ## CTUI-14's budget for the whole reflow is 20.
  var rs: TFdSet
  FD_ZERO(rs)
  FD_SET(fd, rs)
  var maxFd = fd
  if wakeFd >= 0:
    FD_SET(wakeFd, rs)
    if wakeFd > maxFd: maxFd = wakeFd
  var tv: Timeval
  tv.tv_sec = posix.Time(timeoutMs div 1000)
  tv.tv_usec = clong((timeoutMs mod 1000) * 1000)
  let ready = posix.select(maxFd + 1, addr rs, nil, nil, addr tv)
  if ready <= 0: return ReadTimeout
  if wakeFd >= 0 and FD_ISSET(wakeFd, rs) != 0 and FD_ISSET(fd, rs) == 0:
    return ReadWoke
  if FD_ISSET(fd, rs) == 0: return ReadWoke
  var b: char
  let got = posix.read(fd, addr b, 1)
  if got == 0: return ReadEof
  if got < 0: return ReadTimeout
  int(ord(b))

# ---------------------------------------------------------------------------
# Frame bytes
# ---------------------------------------------------------------------------
#
# `ClearScreenBytes`, `SynchronizedOpenBytes`, `SynchronizedCloseBytes`,
# `bracketFrame`, `frameBytes` and `writeAll` MOVED TO `host/ssh_tuning.nim` in
# CTUI-14, and are re-exported above. They went because they are the emission
# and CTUI-14 gave the emission a policy — a full frame and a diffed frame are
# two answers to one question, and a module that owned only the first would
# have owned a third of it. Nothing about them changed, so
# `test_real_capability_negotiation.nim`'s DEC 2026 pairing gate and
# `test_real_call_stack.nim`'s hyperlink identity assertion resolve and read
# exactly as they did.

proc composite*(rows: seq[StyledRow]; cols, height: int): ScreenBuffer =
  ## One frame's component tree, laid out and composited into a screen buffer.
  ##
  ## The three production types — `TerminalRenderer`, `newHeadlessDriver`,
  ## `newCompositor` — rather than `isonim_tui`'s `TerminalTestHarness`, which is
  ## exactly those three in a bundle plus a `TestClock`, a `Pilot` and an event
  ## log. A shipped binary has no business carrying a virtual clock, and the
  ## bytes are identical because the compositing path is the same one.
  ##
  ## A FRESH RENDERER, DRIVER AND COMPOSITOR PER FRAME. `test_app_runtime`
  ## records why: the driver's buffer is the diff base, so remounting onto the
  ## old one emits a delta, and this front-end's frame barrier needs a whole
  ## frame. `resetNodeIds` keeps node ids bounded across a long session rather
  ## than letting them climb with the frame count.
  resetNodeIds()
  let renderer = TerminalRenderer()
  let driver = newHeadlessDriver(cols, height)
  let comp = newCompositor(cols, height)
  comp.paint(styledRowsTree(renderer, rows), driver)
  driver.buffer

proc plainScreen*(buf: ScreenBuffer): string =
  ## A composited screen as PLAIN TEXT: one line per row, trailing blanks
  ## trimmed, no escape sequences at all.
  ##
  ## For `--headless`, whose entire output contract is "something a
  ## CI job can `grep`". Deliberately NOT `encodeAnsi`: a pipeline that has to
  ## strip SGR before it can match is a pipeline that will match the wrong
  ## thing on the day a colour changes.
  ##
  ## A zero rune is a cell nothing was written to, and a wide glyph's
  ## continuation cell has `width == 0` — emitting either would put a NUL or a
  ## duplicated half-glyph into the text, so the first becomes a space and the
  ## second is skipped.
  var lines: seq[string] = @[]
  for r in 0 ..< buf.rowsCount:
    var line = ""
    for cell in buf.rows[r].cells:
      if cell.width == 0:
        continue
      if cell.rune.int32 == 0:
        line.add ' '
      else:
        line.add unicode.toUTF8(cell.rune)
    # `strutils.strip` EXPLICITLY. `std/unicode` is imported here for `toUTF8`
    # and exports a `strip` of its own that leaves an all-whitespace string
    # UNCHANGED (nim 2.2.8) — recorded in `docs/tui-testing.md` as a trap this
    # tree has already been bitten by. A blank row is the common case here, so
    # the wrong overload would put `cols` spaces on every empty line.
    lines.add strutils.strip(line, leading = false, trailing = true)
  lines.join("\n")

proc plainFrame*(caps: TerminalCapabilities; rows: seq[StyledRow];
                 cols, height: int): string =
  ## The same composited frame `paint` writes to a tty, read as PLAIN TEXT.
  ##
  ## `--headless`'s whole output. It is here rather than in `host/headless.nim`
  ## because `degradeRows` and `composite` are called from this module and
  ## nowhere else, so there is exactly one thing in this front-end that turns a
  ## pane tree into a screen — a headless render and a terminal render cannot
  ## drift apart into two renderers.
  plainScreen(composite(degradeRows(rows, caps), cols, height))

# ---------------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------------

type
  DriverEventKind* = enum
    ## What the loop woke up for. Four answers rather than one, because
    ## "nothing happened", "the window changed" and "the terminal went away" have
    ## completely different consequences and folding any two of them into a
    ## timeout is how a closed terminal becomes an idle spin.
    dekToken = "token"
    dekResize = "resize"
    dekIdle = "idle"
    dekEof = "eof"

  DriverEvent* = object
    kind*: DriverEventKind
    token*: string
      ## One complete input token on `dekToken`: a byte, or a whole escape
      ## sequence. Exactly what `app/input/keymap.keyName` and
      ## `app/input/mouse.decodeMouse` are written to take.
    size*: TerminalSize
      ## The NEW geometry on `dekResize`, read back from `ioctl(TIOCGWINSZ)`.

  TerminalDriver* = ref object
    ## The terminal, claimed.
    caps*: TerminalCapabilities
      ## RESOLVED BEFORE THIS OBJECT EXISTS. There is no setter and no default:
      ## `newTerminalDriver` takes it, which is the structural form of CTUI-11's
      ## "capabilities resolve before first paint".
    inFd*: cint
    outFd*: cint
    watcher*: ResizeWatcher
      ## CTUI-3's SIGWINCH self-pipe and the two reactive size signals.
    framer*: InputFramer
    buffered*: seq[string]
      ## Complete input tokens framed while the input loop was NOT running.
      ##
      ## CTUI-14. The handshake's escape hatch (`absorbInterruptByte`) reads
      ## the user's bytes off the same fd `nextEvent` reads, and a byte read
      ## there and dropped would be a keystroke the front-end lost. So every
      ## byte it takes is framed and queued here, and `nextEvent` empties this
      ## before it goes back to the kernel — which is what makes the hatch
      ## LOSSLESS rather than merely responsive.
    emitter*: FrameEmitter
      ## CTUI-14's `host/ssh_tuning.nim`: what actually goes down the wire, and
      ## the memory of what the terminal is already showing.
      ##
      ## The driver owns a file descriptor and this owns the answer to "what is
      ## the least I have to say" — which is why every assertion about the
      ## second one is in the fast lane with no pty in sight.
    coalescer*: WriteCoalescer
      ## Whether the frame the application just produced has to go out NOW. The
      ## caller answers `morePending`; see `ssh_tuning.hold` for why that
      ## parameter, and not a clock, is what keeps p50 input latency unmoved.
    framesPainted*: int
    bytesEmitted*: int
      ## Counters, for the status line and for a benchmark. Not decoration: a
      ## repaint budget that could only be measured by reading a pty would be
      ## a budget nothing in the fast lane could assert.
    started: bool
    rawMode: RawMode
    altScreen: AltScreen
    mouseCapture: MouseCapture
    mouseOwned: bool
    altOwned: bool
    rawOwned: bool

proc newTerminalDriver*(caps: TerminalCapabilities;
                        inFd: cint = STDIN_FILENO;
                        outFd: cint = STDOUT_FILENO): TerminalDriver =
  ## A driver over a negotiated terminal. Touches no OS state — `start` does
  ## that — so constructing one is as passive as constructing a `TuiApp`.
  TerminalDriver(caps: caps, inFd: inFd, outFd: outFd, watcher: nil,
                 framer: initInputFramer(), buffered: @[],
                 emitter: newFrameEmitter(caps),
                 coalescer: initWriteCoalescer(),
                 framesPainted: 0, bytesEmitted: 0,
                 started: false, mouseOwned: false, altOwned: false,
                 rawOwned: false)

proc size*(d: TerminalDriver): TerminalSize =
  ## The terminal's current geometry, through the watcher when one exists so a
  ## reader and a subscriber cannot disagree.
  if d.watcher.isNil: terminalSizeOf(d.outFd) else: d.watcher.currentSize()

proc start*(d: TerminalDriver) =
  ## Claim the terminal: SIGWINCH, raw mode, the alternate screen, the cursor,
  ## and mouse reporting if it was negotiated.
  ##
  ## ORDER IS THE SAME AS `isonim_tui`'s own `PosixDriver.start`, and for its
  ## reasons: SIGWINCH first so a resize that arrives during startup is not
  ## lost; raw mode next, because it is what installs the signal-safe restore
  ## every step after it depends on; then the alternate screen, so the user's
  ## scrollback is already saved when anything is drawn.
  if d.started:
    return
  # THE EMITTER FORGETS WHAT THE TERMINAL IS SHOWING. It is about to be a
  # different screen — the alternate one — and diffing against a memory of the
  # screen this process is leaving would emit a delta onto a blank page.
  d.emitter.reset()
  d.watcher = newResizeWatcher(d.outFd)
  try:
    d.rawMode = enableRawMode(d.inFd)
    d.rawOwned = true
  except OSError:
    # NOT A TTY. Reported by leaving `rawOwned` false rather than by raising:
    # `main.nim` has already decided whether it has a screen (`stdoutIsTerminal`)
    # and a driver that raised here would turn "you piped me into a file" into a
    # stack trace out of termios.
    discard
  d.altScreen = enterAltScreen(d.outFd)
  d.altOwned = true
  writeAll(d.outFd, HideCursorBytes)
  if d.caps.mouse:
    # SGR-1006 (`?1000h ?1006h`), which is what `app/input/mouse.decodeMouse`
    # decodes and what `TermAssert.sendMouseClick` writes. `mouseProtocol()`
    # reads `mpSgr` back off the terminal from this, and reads `mpNone` under
    # `--no-mouse` — the negotiation, observed from the terminal's side.
    d.mouseCapture = enableMouseCapture(d.outFd)
    d.mouseOwned = true
  # NOTHING IS SENT FOR THE KITTY KEYBOARD PROTOCOL OR FOR modifyOtherKeys,
  # on a terminal that advertises either. See
  # `app/theme/capabilities.TerminalCapabilities.kittyKeyboard`: both change
  # every key's encoding, `app/input/keymap.keyName` decodes xterm's classic
  # one, and a driver that switched encodings without a decoder would make
  # §4.2's function keys unreachable on exactly the terminals users choose for
  # their key handling.
  d.started = true

proc stop*(d: TerminalDriver) =
  ## Give the terminal back. Idempotent, and safe to call after a failed
  ## `start`.
  ##
  ## The same order `nim-termctl`'s signal handler uses, so a clean exit and a
  ## SIGTERM leave the terminal in the same state: mouse off, alternate screen
  ## left, cursor shown, termios restored last.
  if d.mouseOwned:
    disableMouseCapture(d.mouseCapture)
    d.mouseOwned = false
  if d.altOwned:
    leaveAltScreen(d.altScreen)
    d.altOwned = false
  writeAll(d.outFd, ShowCursorBytes)
  if d.rawOwned:
    disableRawMode(d.rawMode)
    d.rawOwned = false
  d.started = false

proc paint*(d: TerminalDriver; rows: seq[StyledRow];
            prologue = ""; epilogue = "") =
  ## One frame, degraded to the negotiated tier and written in ONE `write(2)`
  ## loop.
  ##
  ## `degradeRows` is the choke point CTUI-11's gate rests on: every span's
  ## style goes through `app/theme/degradation`, so "the monochrome screen
  ## carries no colour attributes" is a property of this call rather than a
  ## claim about the eighteen view modules that painted the spans.
  ##
  ## ONE WRITE, and that is what makes the DEC 2026 bracket worth emitting: a
  ## frame split across several `write(2)` calls gives the terminal a chance to
  ## render between them, which is the tear the bracket exists to prevent.
  ##
  ## CTUI-14 put `host/ssh_tuning.FrameEmitter` between the buffer and the
  ## write. What reaches the terminal is now usually the RUNS that changed
  ## rather than the whole screen — §8's 250-byte budget for a single line step
  ## is not reachable any other way — and the emitter's own contract is that a
  ## diffed frame and a full frame leave a terminal in the same state.
  let sz = d.size()
  let degraded = degradeRows(rows, d.caps)
  let buf = composite(degraded, sz.cols, sz.rows)
  let stream = d.emitter.emit(buf, prologue, epilogue)
  writeAll(d.outFd, stream)
  d.coalescer.noteFlush()
  inc d.framesPainted
  d.bytesEmitted += stream.len

proc inputPending*(d: TerminalDriver): bool =
  ## Whether there is input this process has already been given and has not
  ## handled — either framed onto `buffered`, or sitting on the input fd.
  ##
  ## THE WHOLE OF THE COALESCING CONTRACT RESTS ON THIS ANSWER, and it is a
  ## zero-timeout `select` rather than a guess: `ssh_tuning.hold` defers a frame
  ## only when this is true, so a keystroke that arrives with nothing behind it
  ## is answered by a paint on the same turn of the loop. A conservative
  ## implementation that ever said `true` when the user was idle would trade
  ## exactly the latency §8's p50 budget is about.
  if d.buffered.len > 0:
    return true
  var rs: TFdSet
  FD_ZERO(rs)
  FD_SET(d.inFd, rs)
  var tv: Timeval
  tv.tv_sec = posix.Time(0)
  tv.tv_usec = 0
  posix.select(d.inFd + 1, addr rs, nil, nil, addr tv) > 0

proc holdFrame*(d: TerminalDriver; alsoPending = false): bool =
  ## Whether to skip the repaint for the input just handled because more input
  ## is already waiting. See `ssh_tuning.WriteCoalescer`.
  ##
  ## `alsoPending` is for input that never touched this driver's fd:
  ## `host/key_journal.nim`'s replay feeds the runtime from a file, and a
  ## replayed burst has to coalesce exactly as a typed one does or the
  ## benchmark that drives it would be measuring a path the user never takes.
  d.coalescer.hold(alsoPending or d.inputPending())

const
  InterruptTokens*: array[2, string] = ["\x03", "q"]
    ## The tokens that END A WAIT the user did not ask to be in.
    ##
    ## §4.2's two quit bindings and nothing else. `Ctrl+d` is deliberately
    ## absent: §4.2 binds it to "Half Page Down", and a user who reached for a
    ## scroll while a trace was opening must not have the trace closed under
    ## them. `Esc` is absent for the framing reason `docs/tui-testing.md`
    ## records — a lone `\x1b` is held as the prefix of every escape sequence,
    ## so it is not a token a single keystroke can produce.

proc absorbInterruptByte*(d: TerminalDriver): bool =
  ## Read ONE byte from the input fd, frame it, queue it, and say whether it
  ## asks the current wait to end.
  ##
  ## CTUI-14's escape hatch, and the callback behind
  ## `stdio_backend.DapReadBound.onInterrupt`. It exists because the terminal
  ## is already in raw mode when the DAP handshake runs: `cfmakeraw` has
  ## cleared `ISIG`, so `Ctrl+c` is a byte on this fd and NOT a signal, and
  ## with no input loop yet running there was nothing on the other side of it.
  ##
  ## THE BYTE IS NEVER DROPPED. It goes through the same `InputFramer` the
  ## loop uses and any complete token lands on `d.buffered`, which `nextEvent`
  ## drains first — so a user who typed ahead while the trace was opening finds
  ## their keys waiting for them rather than eaten by the adapter.
  var b: char
  let got = posix.read(d.inFd, addr b, 1)
  if got <= 0:
    # EOF on the terminal is itself a reason to stop waiting: there is nobody
    # left to show the trace to.
    return got == 0
  let (complete, token) = d.framer.feed(b)
  if not complete:
    return false
  d.buffered.add token
  token in InterruptTokens

proc nextEvent*(d: TerminalDriver; timeoutMs: int = 100): DriverEvent =
  ## Block until a token, a resize, a timeout or end-of-input.
  ##
  ## ONE BYTE PER CALL through the framer, which is what keeps a multi-byte
  ## escape sequence from being split across two of the caller's iterations: a
  ## partial sequence leaves `dekIdle` and the framer holding it, so the caller
  ## repaints nothing and comes straight back.
  ##
  ## TOKENS TAKEN BY `absorbInterruptByte` COME OUT HERE FIRST, in the order
  ## they were typed. Reaching for the kernel while `d.buffered` still held a
  ## key would deliver the user's input out of order — and, for the `Ctrl+c`
  ## that ended a stalled open, would deliver it never.
  if d.buffered.len > 0:
    let token = d.buffered[0]
    d.buffered.delete(0)
    return DriverEvent(kind: dekToken, token: token)
  let wake = if d.watcher.isNil: cint(-1) else: resizeWakeFd()
  let b = readByteWithTimeout(timeoutMs, d.inFd, wake)
  if b == ReadEof:
    return DriverEvent(kind: dekEof)
  if b < 0:
    if not d.watcher.isNil and d.watcher.pump():
      return DriverEvent(kind: dekResize, size: d.watcher.currentSize())
    return DriverEvent(kind: dekIdle)
  let (complete, token) = d.framer.feed(char(b))
  if complete:
    return DriverEvent(kind: dekToken, token: token)
  DriverEvent(kind: dekIdle)

proc nowMs*(): int64 =
  ## A monotonic millisecond clock, for `keymap.resolve`'s bounded pending
  ## timeout.
  ##
  ## MONOTONIC AND NOT WALL-CLOCK: `PendingTimeoutMs` is a duration, and a
  ## `Ctrl+w` prefix must not expire because NTP stepped the clock backwards
  ## while the user was deciding which pane to focus.
  (getMonoTime() - MonoTime()).inMilliseconds

proc describe*(d: TerminalDriver): string =
  ## For a status line or a failure message: what was negotiated and what has
  ## been drawn.
  let sz = d.size()
  $sz.cols & "x" & $sz.rows & "  " & describe(d.caps) &
    "  frames=" & $d.framesPainted & " bytes=" & $d.bytesEmitted
