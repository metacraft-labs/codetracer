## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
## See `host/native_host.nim`'s header for the full rule, and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## keeps `app/` on the other side of it.
##
## host/resize.nim — CTUI-3. SIGWINCH into reactive width / height signals.
##
## ## Why this is in `host/` and not in `app/`
##
## CTUI-3 names the file `host/resize.nim`, and the reason is not filing. A
## signal handler, a self-pipe and `ioctl(TIOCGWINSZ)` are process- and
## terminal-level capabilities: `std/posix` is on `app/`'s forbidden list, and
## `test_tui_facade_boundary.nim` reports any module under `app/` that reaches
## it — including, deliberately, a test module under `app/tests/`. So
## `app/tests/test_resize_reflow.nim` exercises REFLOW through the in-process
## harness's `h.resize`, and the SIGNAL is exercised where a signal can
## actually be delivered: `tests/real_terminal/test_real_shell_geometry.nim`,
## through a real pty and a real `setWindowSize`.
##
## That split is not a gap in coverage, it is the campaign's testing rule
## (docs/tui-testing.md): "SIGWINCH — `h.resize()` is a method call;
## `setWindowSize` is a kernel signal".
##
## ## The handler does nothing but write one byte
##
## Async-signal-safety is not negotiable: a handler that called `ioctl`, or
## allocated, or touched the Nim GC, would be a latent crash under a resize
## storm — and a window drag IS a resize storm. So the handler is
## `nim-termctl`'s (`installWinchHandler`), which writes a single byte into a
## non-blocking self-pipe and returns, and every question that needs an answer
## is asked from the main loop by `pump`.
##
## Reusing nim-termctl's handler rather than installing a second one is also
## what keeps this module compatible with `isonim_tui`'s `PosixDriver`, which
## installs the same one: `installWinchHandler` is idempotent, so a TUI that
## later starts a real driver does not end up with two handlers racing for one
## signal.
##
## ## What `pump` returns, and why it is not `void`
##
## `pump` answers "did the size change?". A caller repaints on `true` and does
## nothing on `false`, which matters because SIGWINCH is delivered for changes
## this application does not care about — a pixel-size change with the same
## cell geometry sends one too. Repainting on every signal would make the
## CTUI-14 reflow budget a function of how fast the user drags.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it owns SIGWINCH.".}

import std/[os, posix, strutils]

import isonim/core/signals
import nim_termctl

type
  TerminalSize* = object
    ## A terminal's size in CELLS. Named rather than a bare tuple because it is
    ## returned from three places and read in four, and `(80, 24)` versus
    ## `(24, 80)` is a mistake a tuple invites.
    cols*: int
    rows*: int

  ResizeWatcher* = ref object
    ## The two reactive signals a view binds to, plus what is needed to keep
    ## them true.
    width*: Signal[int]
    height*: Signal[int]
    fd*: cint
      ## Which descriptor is asked for the size. The OUTPUT side, because that
      ## is the one guaranteed to be the terminal a TUI draws on; stdin can be
      ## a pipe while stdout is a tty.
    deliveries*: int
      ## How many SIGWINCH notifications this watcher has consumed. Exposed so
      ## a test can distinguish "the signal never arrived" from "the signal
      ## arrived and the size was unchanged" — two states that look identical
      ## from the signals alone, and that have completely different causes.
    changes*: int
      ## How many of those actually moved the geometry.

const
  FallbackCols* = 80
  FallbackRows* = 24
    ## What a size query falls back to when there is no terminal at all — a
    ## pipe, a CI log, `nohup`. 80x24 rather than zero: a zero-sized shell
    ## projects to `prNoSpace` and would report a layout failure for what is
    ## really "there is no screen here", and those must not be the same report.

proc sizeFromEnv*(): TerminalSize =
  ## `$COLUMNS` / `$LINES`, or the fallback. The second source, used when the
  ## ioctl fails: a terminal multiplexer or a CI runner that exports them is
  ## more likely to be right than the constants below it.
  result = TerminalSize(cols: FallbackCols, rows: FallbackRows)
  try:
    let cols = getEnv("COLUMNS", "").strip()
    if cols.len > 0:
      let n = parseInt(cols)
      if n > 0:
        result.cols = n
  except ValueError:
    discard
  try:
    let rows = getEnv("LINES", "").strip()
    if rows.len > 0:
      let n = parseInt(rows)
      if n > 0:
        result.rows = n
  except ValueError:
    discard

proc terminalSizeOf*(fd: cint): TerminalSize =
  ## The size of the terminal on `fd`, via `ioctl(TIOCGWINSZ)`.
  ##
  ## TOTAL: never raises. `nim-termctl`'s `terminalSize` raises an `OSError`
  ## when `fd` is not a tty, and a resize watcher that propagated that would
  ## make "the program is not attached to a terminal" — an ordinary state for
  ## every piped run and every unit test — arrive as an exception from a paint.
  ## A degenerate answer from the ioctl (a zero row or column count, which a
  ## pty reports before its size is set) is treated the same way.
  try:
    let size = terminalSize(fd)
    if size.cols > 0 and size.rows > 0:
      return TerminalSize(cols: size.cols, rows: size.rows)
  except CatchableError:
    discard
  sizeFromEnv()

proc queryTerminalSize*(): TerminalSize =
  ## The size of the terminal this process is drawing on.
  terminalSizeOf(STDOUT_FILENO)

proc installResizeSignal*() =
  ## Install the SIGWINCH handler. Idempotent, and it is nim-termctl's — see
  ## the module header on why a second handler would be a mistake.
  installWinchHandler()

proc resizeWakeFd*(): cint =
  ## The read end of the self-pipe, for a caller that multiplexes it with stdin
  ## in one `select`. CALL `installResizeSignal` FIRST — see below.
  ##
  ## This is what makes a reflow arrive without a poll interval: an event loop
  ## blocked in `select` wakes on the signal's byte rather than on a timer,
  ## which is the difference between the CTUI-14 idle-CPU target and a spin.
  ##
  ## WHAT THIS RETURNS BEFORE THE HANDLER IS INSTALLED IS **0**, NOT -1.
  ## `nim-termctl`'s `winchPipeReadFd` documents itself as answering -1 in that
  ## state, but `posix_backend.nim`'s `gWinchPipeR` is an uninitialised
  ## `{.threadvar.}: cint`, and Nim zero-initialises those — measured: 0 before
  ## `installWinchHandler`, 3 after. Zero is stdin, so a caller that trusted the
  ## documented sentinel would end up selecting on the keyboard and calling a
  ## buffered keystroke a resize.
  ##
  ## Nothing here is exposed to that, and deliberately: `newResizeWatcher`
  ## installs before it does anything else, and `pump` reaches `pendingResize`
  ## only through a watcher. The sentinel is written down rather than worked
  ## around because the fix belongs in nim-termctl — recorded as a follow-up in
  ## CodeTracer-TUI.milestones.org, CTUI-3.
  winchPipeReadFd()

proc pendingResize*(): bool =
  ## Whether at least one SIGWINCH byte is waiting, WITHOUT consuming it.
  ##
  ## Separate from `pump` so a caller can decide to coalesce a burst — and so a
  ## test can assert the byte arrived before asserting what was done with it.
  let fd = winchPipeReadFd()
  # This guard is nim-termctl's documented sentinel and it DOES NOT FIRE before
  # the handler is installed — see `resizeWakeFd` for the measurement. It is
  # kept because it is the correct test AFTER `uninstallWinchHandler`, which
  # does set -1; the reason nothing selects on stdin here is that every caller
  # arrives through `newResizeWatcher`, which installs first.
  if fd < 0:
    return false
  var rs: TFdSet
  FD_ZERO(rs)
  FD_SET(fd, rs)
  var tv: Timeval
  tv.tv_sec = posix.Time(0)
  tv.tv_usec = posix.Suseconds(0)
  posix.select(fd + 1, addr rs, nil, nil, addr tv) > 0

proc newResizeWatcher*(fd: cint = STDOUT_FILENO): ResizeWatcher =
  ## A watcher whose signals already hold the CURRENT size.
  ##
  ## Seeded rather than started at zero, because a view that mounted against
  ## `0 x 0` and only became right on the first resize would render one wrong
  ## frame on every launch — and on a terminal nobody resizes, forever.
  installResizeSignal()
  let size = terminalSizeOf(fd)
  ResizeWatcher(width: createSignal(size.cols), height: createSignal(size.rows),
                fd: fd, deliveries: 0, changes: 0)

proc currentSize*(w: ResizeWatcher): TerminalSize =
  ## What the watcher's signals currently say. Read through the signals rather
  ## than re-queried, so a reader and a subscriber cannot disagree.
  TerminalSize(cols: w.width.val, rows: w.height.val)

proc applySize*(w: ResizeWatcher; size: TerminalSize): bool =
  ## Write `size` into the signals, returning whether anything moved.
  ##
  ## Public because it is the seam a test drives without a signal: CTUI-3's
  ## Tier-1 reflow suite has no pty, and a watcher that could only be moved by
  ## a kernel would be untestable in the fast lane. The SIGNAL path is asserted
  ## at Tier 2, where a signal exists.
  result = false
  if size.cols > 0 and size.cols != w.width.val:
    w.width.val = size.cols
    result = true
  if size.rows > 0 and size.rows != w.height.val:
    w.height.val = size.rows
    result = true
  if result:
    inc w.changes

proc pump*(w: ResizeWatcher): bool =
  ## Consume every pending SIGWINCH and re-read the terminal's size.
  ##
  ## Returns whether the geometry actually changed. A burst of signals from one
  ## window drag is coalesced into a single `true`, which is what keeps the
  ## reflow cost proportional to the number of distinct sizes rather than to
  ## the number of signals.
  if not pendingResize():
    return false
  drainWinchPipe()
  inc w.deliveries
  applySize(w, terminalSizeOf(w.fd))

proc describe*(w: ResizeWatcher): string =
  ## For a failure message: the size, and how it got there.
  $w.width.val & "x" & $w.height.val & " (deliveries " & $w.deliveries &
    ", changes " & $w.changes & ")"
