## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
## See `host/native_host.nim`'s header for the full rule.
##
## host/ssh_tuning.nim — CTUI-14. What actually goes down the wire: the frame
## bytes, the DEC 2026 bracket, dirty-region line diffing, and write
## coalescing.
##
## ## Why this is a module and not three lines in the driver
##
## Everything here is a PURE FUNCTION OF TWO SCREEN BUFFERS. `TerminalDriver`
## owns a file descriptor and a termios; this owns the answer to "given what the
## terminal is already showing, what is the least I have to say to make it show
## this instead". Those are different questions, and only the second one can be
## asserted without a terminal — which is why the whole of `app/tests/
## test_ssh_tuning.nim` runs in the fast lane with no pty at all.
##
## The three pieces CTUI-14 names, and what each is actually for:
##
## **DEC 2026 framing.** `\e[?2026h` … `\e[?2026l` asks the terminal to hold
## the frame it is about to receive and to show it all at once. Over a link with
## latency this is the difference between a frame that arrives and a frame that
## arrives in pieces the user watches assemble. It is CTUI-11's `bracketFrame`,
## moved here with the rest of the emission — `host/terminal_driver.nim`
## re-exports it, so every existing caller and every existing assertion is
## untouched.
##
## **Dirty-region line diffing.** A full 120x40 frame is a little over 9 KB
## every time anything changes. §8's budget for a single line step is **250
## bytes**, and that number is not reachable by any amount of care inside a
## full-frame emitter: the frame is the size it is. So the emitter keeps the
## buffer it last sent and emits only the runs of cells that differ.
##
## **Write coalescing**, and the contract it is written against: *coalescing
## must not increase p50 input latency*. The rule that makes that structural
## rather than argued is one line — **a frame is held only when the input the
## user has already typed is still waiting to be handled**. A key that arrives
## with nothing behind it is never delayed by a single millisecond, because
## `hold` returns false for it. What coalescing removes is the frame nobody
## would ever have seen: five held keys used to paint five screens of which four
## were replaced before a terminal could show them.
##
## ## THE GHOST-CELL RULE, which is why runs are not simply `cells.diff`
##
## `isonim_tui`'s `ScreenBuffer.diff` gives contiguous runs of changed cells,
## with a per-row content hash making the unchanged rows O(1). It is exactly the
## right primitive and it cannot be emitted verbatim, for the reason
## `docs/tui-testing.md` opens with: a wide glyph occupies TWO columns, and the
## second is a ghost (`width == 0`) that no emitter may write. A run that begins
## on a ghost would put the cursor between the halves of a glyph, and a run that
## wrote its ghosts would shift every column after it by one.
##
## So a run is EXPANDED LEFT onto the head of any wide glyph it starts inside,
## and the cells are read back out of the buffer rather than taken from the
## region — the region says WHERE, the buffer says WHAT. Ghosts inside a run are
## skipped, exactly as `encodeAnsi` skips them, because the terminal advances
## two columns of its own accord when it accepts a wide glyph.
##
## ## What the emitter guarantees to its callers
##
##   * **The screen is the same screen.** A diffed frame and a full frame put a
##     terminal into identical states.
##     `tests/real_terminal/test_real_high_latency.nim` asserts that against a
##     real terminal, over 100 steps, by comparing the final screen with the
##     same key sequence's zero-latency run.
##   * **The cursor comes to rest on the bottom-right cell**, which is the frame
##     barrier every Tier-2 suite in this tree waits on
##     (`dual_snap.waitForCompleteFrame`). A full frame reaches it by writing
##     the last cell; a diffed frame — which may not have touched the last row
##     at all — reaches it with an explicit CUP.
##   * **The terminal's SGR state is `default` between frames.** `encodeAnsi`
##     ends a full frame with a reset; a diffed frame ends with one too. That is
##     what lets a run start encoding from `defaultStyle()` instead of having to
##     remember what the last frame left behind.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it owns the tty.".}

import std/[os, posix, unicode]

import isonim_tui

import ./capabilities

# ---------------------------------------------------------------------------
# Bytes
# ---------------------------------------------------------------------------

const
  ClearScreenBytes* = "\x1b[2J\x1b[H"
  SynchronizedOpenBytes* = "\x1b[?2026h"
  SynchronizedCloseBytes* = "\x1b[?2026l"
    ## DEC 2026. `h` asks the terminal to hold the frame it is about to receive
    ## and `l` releases it, so a partially transmitted frame is never shown.
    ## §6.3 names Kitty, iTerm2, WezTerm, Alacritty and Foot; every other
    ## terminal ignores an unknown DECSET, and `TerminalCapabilities` is what
    ## decides whether either byte string is emitted at all.
  SgrResetBytes* = "\x1b[0m"

proc bracketFrame*(caps: TerminalCapabilities; body: string): string =
  ## `body` wrapped in DEC 2026, or `body` unchanged.
  ##
  ## A PURE FUNCTION, and that is what makes the pairing assertable at all. The
  ## Tier-2 gate reads `synchronizedOutput()` off a real terminal, and libvterm
  ## holds that flag only BETWEEN the two sequences — after a complete frame it
  ## reads `false` whether the frame opened and closed correctly or never opened
  ## at all. So "the bracket is emitted and correctly paired" is asserted here,
  ## absolutely, on the bytes the driver writes; and "the terminal was left
  ## un-bracketed" is asserted there, on the flag. Neither claim is the other's,
  ## and neither alone is the gate.
  ##
  ## MOVED HERE FROM `host/terminal_driver.nim` BY CTUI-14, unchanged, because
  ## the bracket is one of the three things this module is for and a driver that
  ## kept it would have owned a third of the emission policy. `terminal_driver`
  ## re-exports this module, so `test_real_capability_negotiation.nim` and every
  ## other caller resolve it exactly as before.
  if not caps.synchronizedOutput:
    return body
  SynchronizedOpenBytes & body & SynchronizedCloseBytes

# `cursorTo(row, col)` — `CSI <row+1> ; <col+1> H` from ZERO-BASED coordinates
# — is `isonim_tui`'s own (`text/ansi.nim`), re-exported with the rest of that
# module and used unchanged. A second one here would have been a second place
# for an off-by-one that a frame emitted one row high does not look wrong for.

proc writeAll*(fd: cint; s: string) =
  ## One `write(2)` loop, no stdio buffering. Short writes are retried because a
  ## terminal whose reader is behind will accept only part of a frame at a time,
  ## and a 200x60 frame is comfortably larger than a pty's buffer.
  ##
  ## THIS IS WHERE COALESCING EARNS ITS NAME: whatever the emitter produced goes
  ## out in one loop, so a held-and-merged frame is one burst on the wire rather
  ## than several.
  var off = 0
  while off < s.len:
    let n = posix.write(fd, unsafeAddr s[off], s.len - off)
    if n < 0:
      let e = osLastError()
      if cint(e) == EINTR: continue
      return
    if n == 0: return
    off += n

proc frameBytes*(buf: ScreenBuffer): string =
  ## The exact byte stream one composited frame writes, in full.
  ##
  ## MOVED HERE FROM `testing/test_app_runtime.nim` by CTUI-11 and from
  ## `host/terminal_driver.nim` by CTUI-14; the body is unchanged and its two
  ## rules were measured rather than assumed:
  ##
  ##   * `encodeAnsi` is the production SGR path — the same `text/ansi.renderSgr`
  ##     transitions any isonim-tui driver emits — so what a terminal parses here
  ##     is what a terminal parses from a snapshot app, which is what makes
  ##     CTUI-2's cross-tier equality a statement about this emitter.
  ##   * libvterm does not carriage-return on a line feed (LNM defaults off), so
  ##     a stream that separated rows with `\n` would stair-step. Each row is
  ##     re-glued with an explicit `CSI <row> ; 1 H`.
  ##
  ## The cursor therefore comes to rest on the bottom-right cell exactly when
  ## the frame is complete, which is the frame barrier every Tier-2 suite in this
  ## tree waits on (`dual_snap.waitForCompleteFrame`), and `encodeAnsi`'s
  ## trailing reset is what leaves the terminal's SGR state at `default`.
  result = ClearScreenBytes
  let raw = encodeAnsi(buf)
  var row = 1
  var line = ""
  for ch in raw:
    if ch == '\n':
      result.add "\x1b[" & $row & ";1H" & line
      line = ""
      inc row
    else:
      line.add ch
  if line.len > 0:
    result.add "\x1b[" & $row & ";1H" & line

# ---------------------------------------------------------------------------
# Dirty runs
# ---------------------------------------------------------------------------

type
  DirtyRun* = object
    ## A half-open span of columns on one row that has to be re-sent.
    ##
    ## A LOCATION AND NOT A PAYLOAD. The cells are read out of the new buffer
    ## when the run is emitted, which is what lets `expand` widen a run onto the
    ## head of a wide glyph without having to carry a cell it was never given.
    row*: int
    startCol*: int
    endCol*: int
      ## Exclusive.

const
  DefaultJoinGap* = 6
    ## Two runs on one row separated by this many unchanged cells or fewer are
    ## emitted as ONE run.
    ##
    ## MEASURED RATHER THAN GUESSED, and the arithmetic is the whole
    ## justification: a second run costs a `CSI <r> ; <c> H`, which is 6 to 9
    ## bytes depending on the coordinates, plus whatever SGR the jump forces.
    ## Re-sending N unchanged cells costs N bytes and no escape at all. So
    ## joining pays for any gap up to roughly the length of the cursor address
    ## that separating them would need, and 6 is the low end of that range —
    ## chosen low on purpose, because the cells in the gap may carry style
    ## transitions that make them cost more than a byte each.

proc runWidth*(r: DirtyRun): int =
  r.endCol - r.startCol

proc expandLeftOntoWideHead(buf: ScreenBuffer; row, col: int): int =
  ## `col`, moved back onto the head of a wide glyph when it points at a ghost.
  ##
  ## A ghost is `width == 0` and is never written; a run that began on one would
  ## address the cursor to the middle of a glyph and then emit nothing for it,
  ## putting every following cell of the run one column to the left. Measured on
  ## `┌世界─┐` in the cross-tier suite, which is where this tree learned that a
  ## wide glyph costs one column of drift per occurrence when it is mishandled.
  var c = col
  while c > 0 and buf[row, c].width == 0:
    dec c
  c

proc dirtyRuns*(prev, curr: ScreenBuffer;
                joinGap: int = DefaultJoinGap): seq[DirtyRun] =
  ## The runs of `curr` that differ from `prev`, ghost-expanded and joined.
  ##
  ## `isonim_tui`'s `ScreenBuffer.diff` does the comparison — including the
  ## per-row `contentHash` fast path that makes an unchanged row cost nothing —
  ## and everything below is about what a TERMINAL needs, which that function
  ## has no opinion about.
  ##
  ## Geometry mismatch returns the empty sequence rather than a partial answer:
  ## a caller whose buffers disagree about their size has to send a full frame,
  ## and returning "no changes" for two different screens would be the worst
  ## possible answer. `FrameEmitter.emit` checks the geometry itself and never
  ## reaches here with a mismatch; this is the second lock on the same door.
  result = @[]
  if prev.cols != curr.cols or prev.rowsCount != curr.rowsCount:
    return
  for region in diff(prev, curr):
    if region.row < 0 or region.row >= curr.rowsCount:
      continue
    let startCol = expandLeftOntoWideHead(curr, region.row, region.col)
    let endCol = min(region.col + region.width, curr.cols)
    if endCol <= startCol:
      continue
    if result.len > 0 and result[^1].row == region.row and
       startCol - result[^1].endCol <= joinGap:
      result[^1].endCol = max(result[^1].endCol, endCol)
    else:
      result.add DirtyRun(row: region.row, startCol: startCol, endCol: endCol)

proc emitRuns*(buf: ScreenBuffer; runs: seq[DirtyRun]): string =
  ## The bytes that turn a terminal already showing the previous frame into one
  ## showing `buf`.
  ##
  ## THE SGR STATE IS TRACKED ACROSS THE WHOLE FRAME, not reset per run. A `CSI
  ## r ; c H` moves the cursor and changes nothing else, so what the terminal is
  ## painting in after one run is exactly what the last cell of that run left —
  ## and this function knows what that was, because it wrote it. The frame opens
  ## from `defaultStyle()`, which the previous frame's trailing reset
  ## established, and closes with a reset so the next one can do the same.
  if runs.len == 0:
    return ""
  result = ""
  var prevStyle = defaultStyle()
  for run in runs:
    result.add cursorTo(run.row, run.startCol)
    for c in run.startCol ..< run.endCol:
      let cell = buf[run.row, c]
      if cell.width == 0:
        # The trailing half of a wide glyph. The terminal advanced two columns
        # when it took the head, so writing anything here would overwrite the
        # glyph with its own second cell.
        continue
      let curr = newStyle(cell.fg, cell.bg, cell.attrs)
      let trans = renderSgr(prevStyle, curr)
      if trans.len > 0:
        result.add trans
        prevStyle = curr
      if cell.rune.int32 == 0:
        result.add ' '
      else:
        result.add unicode.toUTF8(cell.rune)
  result.add SgrResetBytes

# ---------------------------------------------------------------------------
# Coalescing
# ---------------------------------------------------------------------------

type
  WriteCoalescer* = object
    ## Whether the frame the application just produced has to go out NOW.
    ##
    ## THE CONTRACT IS ENFORCED BY THE SHAPE OF `hold`, not by a measurement:
    ## a frame is held only when there is input the user has ALREADY typed that
    ## has not been handled yet, so the frame that answers a user's last
    ## keystroke is never delayed. That is why this takes `morePending` and no
    ## clock — a time-based coalescer with a 10 ms window would add up to 10 ms
    ## to every keystroke that arrived alone, which is 60% of §8's whole p50
    ## budget spent on nothing.
    maxHeld*: int
      ## A ceiling on consecutive held frames. Without it, a held key repeating
      ## faster than the application can answer would freeze the screen for as
      ## long as the user leant on it: `morePending` would be true every time.
    held*: int
      ## How many frames have been held since the last one that went out.

proc initWriteCoalescer*(maxHeld: int = 8): WriteCoalescer =
  ## `8` is the default ceiling: at §8's 16 ms p50 budget that is at most one
  ## painted frame per ~128 ms of continuous input, which is well inside the
  ## rate at which a terminal being scrolled still looks like it is moving.
  WriteCoalescer(maxHeld: max(1, maxHeld), held: 0)

proc hold*(c: var WriteCoalescer; morePending: bool): bool =
  ## Whether to skip painting this frame because a better one is imminent.
  ##
  ## Returns FALSE — paint now — whenever nothing more is pending, which is the
  ## whole latency argument, and whenever the ceiling has been reached.
  if not morePending or c.held >= c.maxHeld:
    c.held = 0
    return false
  inc c.held
  true

proc noteFlush*(c: var WriteCoalescer) =
  ## A frame went out for a reason other than `hold` saying so — a resize, the
  ## first paint. The run of held frames ends here too.
  c.held = 0

# ---------------------------------------------------------------------------
# The emitter
# ---------------------------------------------------------------------------

type
  FrameEmitter* = ref object
    ## The last frame sent, and the policy for sending the next one.
    caps*: TerminalCapabilities
    diffing*: bool
      ## `false` sends a full frame every time — the behaviour every release
      ## before CTUI-14 had, kept reachable so the two can be measured against
      ## each other in the SAME run (`benchmarks/tui_benchmarks.nim` does
      ## exactly that) rather than across two builds.
    joinGap*: int
    previous*: ScreenBuffer
    hasPrevious*: bool
    fullFrames*: int
    diffFrames*: int
    emptyFrames*: int
      ## Frames whose diff was empty: nothing on the screen changed. They still
      ## cost the cursor park, because a caller waiting on the frame barrier is
      ## waiting whether or not the application had anything to say.
    bytesEmitted*: int

proc newFrameEmitter*(caps: TerminalCapabilities; diffing = true;
                      joinGap = DefaultJoinGap): FrameEmitter =
  FrameEmitter(caps: caps, diffing: diffing, joinGap: joinGap,
               hasPrevious: false, fullFrames: 0, diffFrames: 0,
               emptyFrames: 0, bytesEmitted: 0)

proc reset*(e: FrameEmitter) =
  ## Forget what the terminal is showing. The next frame is a full one.
  ##
  ## Called on a resize and on `start`, because both leave the terminal in a
  ## state this emitter did not write and therefore cannot diff against.
  e.hasPrevious = false

proc emit*(e: FrameEmitter; buf: ScreenBuffer;
           prologue = ""; epilogue = ""): string =
  ## The bytes for one frame, bracketed, and the emitter's memory updated.
  ##
  ## The full-frame arm is taken when there is nothing to diff against, when the
  ## geometry moved, and when the diff would cost MORE than the frame — which is
  ## a real case rather than a defensive one: a scroll changes every row, and a
  ## per-run cursor address on top of every row's contents is strictly worse
  ## than sending the rows.
  var body = ""
  var full = false
  if not e.diffing or not e.hasPrevious or
     e.previous.cols != buf.cols or e.previous.rowsCount != buf.rowsCount:
    full = true
  else:
    let runs = dirtyRuns(e.previous, buf, e.joinGap)
    let diffBody = emitRuns(buf, runs)
    let fullBody = frameBytes(buf)
    if runs.len == 0:
      body = ""
      inc e.emptyFrames
    elif diffBody.len < fullBody.len:
      body = diffBody
      inc e.diffFrames
    else:
      body = fullBody
      full = true
  if full:
    body = frameBytes(buf)
    inc e.fullFrames
  # THE CURSOR PARK. A full frame reaches the bottom-right cell by writing it;
  # a diffed frame may not have touched the last row at all, and the frame
  # barrier every Tier-2 suite waits on is a cursor position rather than a
  # count of bytes.
  let park = if full: "" else: cursorTo(buf.rowsCount - 1, buf.cols - 1)
  let stream = bracketFrame(e.caps, prologue & body & park & epilogue)
  e.previous = buf
  e.hasPrevious = true
  e.bytesEmitted += stream.len
  stream

proc describe*(e: FrameEmitter): string =
  ## For a benchmark line or a failure message.
  "full=" & $e.fullFrames & " diff=" & $e.diffFrames &
    " empty=" & $e.emptyFrames & " bytes=" & $e.bytesEmitted &
    " diffing=" & $e.diffing & " joinGap=" & $e.joinGap &
    " sync=" & $e.caps.synchronizedOutput
