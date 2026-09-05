## NOT-A-TEST-LANE-FILE: this is the CHILD-SIDE RUNTIME snapshot apps link, not
## a suite. It asserts nothing and has no `unittest` block; the `test_` prefix
## is the name CTUI-2 gives it in
## codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org, and it is kept so
## the deliverable and the file agree. What EXERCISES it is
## `src/frontend/tui/tests/real_terminal/test_ipc_settled_frame.nim`, which
## asserts on its flag surface directly and spawns a binary built from it —
## `ci/test/test-lane-coverage.sh` reported it as run by no lane, which is
## correct and is why this line exists.
##
## LAYER RULE — `src/frontend/tui/testing/` is TEST-ONLY infrastructure, and it
## is a third layer rather than a corner of either of the other two.
##
## `app/` may not touch a process or a terminal; `host/` may, and is the
## release binary's only door to those. This directory needs BOTH — it composites
## a tree in process (`app/`'s capability) and it drives a real tty and a real
## child process (`host/`'s) — so it belongs to neither, and putting it in either
## would mean widening that layer's rule for something the shipped binary never
## links.
##
## The rule that makes that safe is stated as an assertion rather than as a
## convention: NOTHING UNDER `testing/` IS REACHABLE FROM `main.nim`.
## `src/frontend/tui/tests/test_tui_build_prerequisites.nim` walks the release
## entrypoint's resolved import closure on every run and fails if a module under
## this directory appears in it. That is what keeps `--test-ipc` — the flag this
## module parses — out of a release build, which is CTUI-2's contract for it.
## The toolchain says the same thing a second way: this module imports
## `term_assert_client`, whose `--path` only the `tui-real-terminal` lane and the
## child-app compile line carry, so a release build that reached here would not
## compile at all.
##
## testing/test_app_runtime.nim — the child side of a cross-tier snapshot.
##
## ## What a snapshot app is
##
## A snapshot app is one component tree and nothing else. It exports
##
##     proc buildTree*(r: TerminalRenderer): TerminalNode
##
## and, under `when isMainModule`, hands that proc to `runSnapshotApp` here. The
## Tier-2 test compiles the module into a binary and spawns it in a pty; the
## Tier-1 half of the same test IMPORTS the module and calls the same
## `buildTree` against an in-process `TerminalTestHarness`. One tree, two ways —
## which is the only construction under which "the two screens are equal" says
## anything about the renderer rather than about two hand-written fixtures.
##
## ## How the bytes get out
##
## The runtime composites through the real `TerminalTestHarness` and writes
## `testing/snapshot/ansi.encodeAnsi(buffer)` to fd 1, re-glued with an explicit
## `CSI <row>;1H` before each row. Two reasons, both measured rather than
## assumed:
##
##   * `encodeAnsi` is the production SGR path — the same `text/ansi.renderSgr`
##     transitions a real driver emits — so what a terminal parses here is what
##     a terminal would parse from the app.
##   * libvterm does not carriage-return on a line feed (LNM defaults off), so a
##     stream that separated rows with `\n` would stair-step. isonim-tui's own
##     M29 child runtime re-glues for exactly this reason.
##
## ## THE FRAME BARRIER, AND WHY IT IS THE CURSOR
##
## A test that reads the screen has to know the whole frame arrived. Three
## candidate barriers were considered and two were rejected on evidence:
##
##   * `waitForText(needle)` — races by construction. It passes on a partially
##     painted frame that happens to contain the needle, which is the trap
##     codetracer-specs/Testing/Verification-Harness-Traps.md §3 is about.
##   * an OSC title emitted after the frame — libvterm delivers OSC payloads as
##     STRING FRAGMENTS, and `nim-libvterm`'s `settermprop` mirror OVERWRITES
##     `title` per fragment rather than accumulating. TermAssert reads the pty in
##     4096-byte chunks, so a title straddling a chunk boundary would land as its
##     own tail and the barrier would never match.
##   * THE CURSOR, which is what this runtime uses. `encodeAnsi` emits every
##     cell of every row in order, so the last glyph written is the bottom-right
##     one, and the cursor comes to rest at `(rows-1, cols-1)` exactly when the
##     frame is complete. It cannot be there earlier: a partially painted last
##     row leaves the cursor at some `(rows-1, k < cols-1)`, and every earlier
##     row leaves it on an earlier row. Cursor motion is libvterm's state
##     machine, which buffers a split escape sequence across feeds, so unlike
##     the OSC path a chunk boundary cannot lose it.
##
## `dual_snap.waitForCompleteFrame` is the reader of that barrier, and its
## failure names the cursor position it DID observe.
##
## ## `--test-ipc`, and why the child waits to be asked
##
## Under `--test-ipc` the runtime connects `TermAssertClient` to
## `$TERM_ASSERT_URI` and, when asked, calls `requestScreenshot(label)` so the
## harness records the frame the CHILD declares final.
##
## It waits to be asked, and the reason is a race that is invisible until it
## bites. The pty and the IPC socket are TWO UNORDERED CHANNELS. TermAssert's
## `pump` reads the pty 4096 bytes at a time and services IPC BETWEEN chunks
## (`TermAssert/src/term_assert.nim`, `pump`), so a screenshot requested
## immediately after a paint is serviced with the tail of that paint still
## unread — the harness records a PARTIAL frame and the test compares against it
## happily. A 120x40 frame is well over 4096 bytes, so this is the normal case
## rather than the unlucky one.
##
## The handshake removes the race without a sleep anywhere: the parent waits for
## the cursor barrier (which proves it has consumed the whole frame), then sends
## one byte, and only then does the child ask. What the child still owns is the
## decision to answer — `--never-settle` makes it paint, park the cursor and
## never ask, which is the negative arm `test_ipc_settled_frame.nim` needs.

import std/[monotimes, os, posix, strutils, termios, times]

import isonim_tui
import term_assert_client

# THE HOST LAYER, IMPORTED FROM `testing/` AND FROM NOWHERE ELSE A BINARY
# SHIPS. CTUI-3 puts SIGWINCH in `host/resize.nim` because a signal handler and
# an `ioctl` are host capabilities; this directory is the third layer that is
# allowed to need both halves (see this module's header), and
# `tests/test_tui_build_prerequisites.nim` asserts that nothing under
# `testing/` is reachable from `main.nim`, so the release binary links none of
# it.
import ../host/resize

const
  TestAppCaptureByte* = 'S'
    ## What the parent sends to say "I have the whole frame; ask for it now".
  TestAppStepKey* = "\x1b[21~"
    ## xterm's F10, which is exactly what `TermAssert`'s `sendKey("f10")`
    ## writes (`TermAssert/src/term_assert.nim:432`).
    ##
    ## CTUI-5's Tier-2 test is specified as "step with `sendKey(\"f10\")`", so
    ## a snapshot app has to be able to ADVANCE rather than only to paint. The
    ## runtime therefore recognises this one sequence, increments a step
    ## counter and repaints; a builder that ignores its `step` argument behaves
    ## exactly as it did before.
    ##
    ## THIS IS NOT A FLAG and adds nothing to any command line. `--test-ipc`,
    ## `--never-settle` and `--reflow` remain the only three test-only flags,
    ## which is what `tests/test_tui_build_prerequisites.nim` asserts about.
  TestAppQuitByte* = 'q'
  TestAppDeadlineSeconds* = 30
    ## A child that is never told anything must still die, or a failing test
    ## leaves a process holding a pty. Exit code 4 says so distinguishably.

  TestAppExitOk* = 0
  TestAppExitUsage* = 2
  TestAppExitIpc* = 3
  TestAppExitDeadline* = 4

type
  TestAppOptions* = object
    ## The child's command line, as a value — parsed apart from any effect so
    ## `test_tui_build_prerequisites.nim` can ask what the flag surface IS.
    cols*: int
    rows*: int
    testIpc*: bool
      ## `--test-ipc`. TEST-ONLY: this flag exists on snapshot apps and NOWHERE
      ## else. `app/cli.parseTuiCommand` refuses it, `TuiHelpText` does not
      ## mention it, and no module under `testing/` is reachable from
      ## `main.nim` — all three asserted by
      ## `src/frontend/tui/tests/test_tui_build_prerequisites.nim`.
    label*: string
      ## The screenshot label the child asks the harness to record under.
    settle*: bool
      ## False under `--never-settle`: paint the frame, park the cursor, and
      ## then decline to ask for a screenshot however often it is asked. The
      ## negative arm of the IPC suite.
    reflow*: bool
      ## `--reflow`. TEST-ONLY, exactly like `--test-ipc`: install
      ## `host/resize.nim`'s SIGWINCH watcher, take the initial geometry from
      ## the tty rather than from `--cols` / `--rows`, and repaint at the new
      ## size whenever the kernel says the window changed.
      ##
      ## This is what makes CTUI-3's "the only place SIGWINCH is genuinely
      ## exercised" a real claim: the parent calls `setWindowSize`, the KERNEL
      ## delivers the signal, and the child reads its new size back with
      ## `ioctl(TIOCGWINSZ)`. Nothing about that is observable from the
      ## in-process harness.

  SteppedTreeBuilder* = proc(r: TerminalRenderer;
                             cols, rows, step: int): TerminalNode {.closure.}
    ## A tree that depends on the terminal's size AND on how many times the
    ## parent has pressed F10. The most general shape; the two below are
    ## implemented in terms of it so there is ONE paint path.

  SizedTreeBuilder* = proc(r: TerminalRenderer;
                           cols, rows: int): TerminalNode {.closure.}
    ## A tree that depends on the terminal's size.
    ##
    ## The fixed-size `buildTree*(r)` of CTUI-2's snapshot apps cannot express a
    ## responsive shell: `app/views/shell.nim` composes each screen row for a
    ## known width, so the SIZE is an input to the tree rather than something
    ## the compositor applies afterwards. Both shapes are supported, and the
    ## fixed one is implemented in terms of this one so there is a single paint
    ## path.

  TestAppUsageError* = object of CatchableError

const DefaultTestAppLabel* = "settled"

proc initTestAppOptions*(cols = 80; rows = 24): TestAppOptions =
  TestAppOptions(cols: cols, rows: rows, testIpc: false,
                 label: DefaultTestAppLabel, settle: true, reflow: false)

proc parseIntFlag(arg, name: string): int =
  let raw = arg[name.len + 1 .. ^1]
  try:
    result = parseInt(raw)
  except ValueError:
    raise newException(TestAppUsageError,
      name & " expects an integer, got '" & raw & "'")
  if result <= 0:
    raise newException(TestAppUsageError,
      name & " expects a positive integer, got '" & raw & "'")

proc parseTestAppArgs*(args: openArray[string]): TestAppOptions =
  ## Classify a snapshot app's arguments. Raises `TestAppUsageError` rather
  ## than quitting, so the parser is answerable from a test.
  result = initTestAppOptions()
  for arg in args:
    if arg.startsWith("--cols="):
      result.cols = parseIntFlag(arg, "--cols")
    elif arg.startsWith("--rows="):
      result.rows = parseIntFlag(arg, "--rows")
    elif arg == "--test-ipc":
      result.testIpc = true
    elif arg.startsWith("--label="):
      result.label = arg["--label=".len .. ^1]
      if result.label.len == 0:
        raise newException(TestAppUsageError, "--label= expects a name")
    elif arg == "--never-settle":
      result.settle = false
    elif arg == "--reflow":
      result.reflow = true
    else:
      raise newException(TestAppUsageError, "unknown argument '" & arg & "'")
  if not result.testIpc and not result.settle:
    raise newException(TestAppUsageError,
      "--never-settle is only meaningful with --test-ipc")

# ---------------------------------------------------------------------------
# tty handling
# ---------------------------------------------------------------------------

var savedTermios: Termios
var termiosSaved = false

proc enterRawMode() =
  ## Turn off ECHO and ICANON on fd 0.
  ##
  ## Not cosmetic: the pty starts in cooked mode, so the parent's one capture
  ## byte would be ECHOED back onto the screen the test is about to compare —
  ## a divergence manufactured by the harness itself, at whatever cell the
  ## cursor happened to be parked on.
  if tcGetAttr(0.cint, addr savedTermios) != 0:
    return
  termiosSaved = true
  var raw = savedTermios
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON)
  raw.c_cc[VMIN] = 0.char
  raw.c_cc[VTIME] = 0.char
  discard tcSetAttr(0.cint, TCSANOW, addr raw)

proc leaveRawMode() =
  if termiosSaved:
    discard tcSetAttr(0.cint, TCSANOW, addr savedTermios)
    termiosSaved = false

proc emit(s: string) =
  ## One `write(2)`, no stdio buffering. Short writes are retried because a pty
  ## whose reader is behind will accept only part of a frame at a time.
  var off = 0
  while off < s.len:
    let n = posix.write(1.cint, unsafeAddr s[off], s.len - off)
    if n < 0:
      let e = osLastError()
      if cint(e) == EINTR: continue
      return
    if n == 0: return
    off += n

const
  TestAppReadTimeout* = -1
  TestAppReadEof* = -2
  TestAppReadWoke* = -3
    ## `wakeFd` became readable. Returned rather than handled here so the
    ## caller — which owns the `ResizeWatcher` — is the one that drains the
    ## self-pipe, and so "a signal arrived" and "a byte arrived" are two
    ## different answers rather than one timeout.

proc readByteWithTimeout(timeoutMs: int; wakeFd: cint = -1): int =
  ## One byte from fd 0, or `TestAppReadTimeout` / `TestAppReadEof` /
  ## `TestAppReadWoke`.
  ##
  ## `wakeFd` is `host/resize.resizeWakeFd()` — the read end of the SIGWINCH
  ## self-pipe — when the caller is reflowing. Selecting on it rather than
  ## polling on the timeout is what keeps a reflow's latency the kernel's
  ## rather than this loop's: with a 100 ms poll every measured resize would
  ## carry up to 100 ms of this function in it, and CTUI-14's budget for the
  ## whole reflow is 20.
  var rs: TFdSet
  FD_ZERO(rs)
  FD_SET(0.cint, rs)
  var maxFd = 0.cint
  if wakeFd >= 0:
    FD_SET(wakeFd, rs)
    if wakeFd > maxFd: maxFd = wakeFd
  var tv: Timeval
  tv.tv_sec = posix.Time(timeoutMs div 1000)
  tv.tv_usec = clong((timeoutMs mod 1000) * 1000)
  let ready = posix.select(maxFd + 1, addr rs, nil, nil, addr tv)
  if ready <= 0: return TestAppReadTimeout
  if wakeFd >= 0 and FD_ISSET(wakeFd, rs) != 0 and FD_ISSET(0.cint, rs) == 0:
    return TestAppReadWoke
  if FD_ISSET(0.cint, rs) == 0: return TestAppReadWoke
  var b: char
  let got = posix.read(0.cint, addr b, 1)
  if got == 0: return TestAppReadEof
  if got < 0: return TestAppReadTimeout
  int(ord(b))

# ---------------------------------------------------------------------------
# painting
# ---------------------------------------------------------------------------

proc frameBytes*(buf: ScreenBuffer): string =
  ## The exact byte stream a snapshot app writes for one frame.
  ##
  ## Exposed rather than inlined so a test can assert on the emission without
  ## a pty — and so the row re-gluing rule described in this module's header
  ## has exactly one implementation.
  result = "\x1b[2J\x1b[H"
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
# the runtime
# ---------------------------------------------------------------------------

proc resizeAckBytes*(cols, rows: int): string =
  ## `CSI 8 ; rows ; cols t` — what the child emits after a SIGWINCH, before
  ## repainting.
  ##
  ## WHY A CHILD EMITS A WINDOW-OP AT ALL. `TermAssert.assertWindowResize` reads
  ## libvterm's window-op log, and that log is filled ONLY by sequences the
  ## child writes — `nim-libvterm`'s `decodeWindowOp`, reached from
  ## `handleCsi`. `TuiTestSession.setWindowSize` resizes the pty and the
  ## harness's own screen model and records nothing, so an assertion made after
  ## it alone would be an assertion about the HARNESS.
  ##
  ## So this sequence is the child's ACKNOWLEDGEMENT of the size it read back
  ## from `ioctl(TIOCGWINSZ)` after the kernel delivered SIGWINCH. Asserting on
  ## it is therefore a statement about the signal path end to end: the parent
  ## resized the pty, the kernel signalled, `host/resize.nim` woke on its
  ## self-pipe, the ioctl returned these numbers, and they are the numbers the
  ## parent asked for. It moves no cursor, so the frame barrier below is
  ## unaffected.
  "\x1b[8;" & $rows & ";" & $cols & "t"

proc stepLabel*(base: string; step: int): string =
  ## The screenshot label the child asks for at step `step`.
  ##
  ## Step 0 keeps the parent's label unchanged, so every CTUI-2 and CTUI-3
  ## suite that asks for `settled` still gets `settled`. Later steps append
  ## `-stepN`, so a parent driving F10 can ask for the frame it wants by name
  ## rather than by timing.
  if step <= 0: base else: base & "-step" & $step

proc runSnapshotApp*(build: SteppedTreeBuilder; opts: TestAppOptions): int =
  ## Paint `build`'s tree at `opts.cols` x `opts.rows` — or, under `--reflow`,
  ## at whatever size the tty reports — then serve the parent until it says to
  ## quit. Returns the process's exit status; the caller is the only thing that
  ## quits.
  var client: TuiTestClient
  var connected = false
  if opts.testIpc:
    # BEFORE the paint, so a miswired socket is reported as text on the screen
    # rather than as a frame that never gets a label — two states the IPC
    # suite has to be able to tell apart.
    try:
      client = connectHarness()
      connected = true
    except TuiTestClientError as e:
      emit("\x1b[2J\x1b[HTERM_ASSERT_URI connect failed: " & e.msg & "\r\n")
      return TestAppExitIpc

  enterRawMode()
  defer: leaveRawMode()

  # UNDER `--reflow` THE SIZE COMES FROM THE KERNEL, not from the command line.
  # That is the whole point: the parent's `setWindowSize` changes what
  # `ioctl(TIOCGWINSZ)` returns, and a child that trusted `--cols` would reflow
  # to a number the parent told it rather than to the one the terminal has.
  var watcher: ResizeWatcher = nil
  var cols = opts.cols
  var rows = opts.rows
  var wakeFd = cint(-1)
  if opts.reflow:
    watcher = newResizeWatcher()
    let size = watcher.currentSize()
    cols = size.cols
    rows = size.rows
    wakeFd = resizeWakeFd()

  var step = 0
  var h = newTerminalTestHarness(cols, rows)
  h.mount(proc(r: TerminalRenderer): TerminalNode = build(r, cols, rows, step))
  h.flush()
  emit(frameBytes(h.driver.buffer))
  # The cursor now rests at (rows-1, cols-1). That IS the barrier; see the
  # module header. Nothing else may be written to fd 1 from here on, or the
  # cursor moves and the parent's barrier stops meaning "frame complete".

  let deadline = getMonoTime() + initDuration(seconds = TestAppDeadlineSeconds)
  result = TestAppExitDeadline
  # An escape sequence arrives one byte at a time through `readByteWithTimeout`,
  # so the step key is accumulated rather than matched on a single read. Only a
  # PREFIX of `TestAppStepKey` is retained: anything else resets the buffer, so
  # a stray `\x1b` cannot swallow the quit byte that follows it.
  var pendingKey = ""
  while getMonoTime() < deadline:
    let b = readByteWithTimeout(100, wakeFd)
    if b == TestAppReadEof:
      result = TestAppExitOk
      break
    if b < 0:
      if not watcher.isNil and watcher.pump():
        # A REAL SIGWINCH, folded in. Acknowledge the size the ioctl reported,
        # then repaint the whole frame at it — in that order, because the
        # acknowledgement must not land after the frame and move the cursor
        # off the barrier.
        let size = watcher.currentSize()
        cols = size.cols
        rows = size.rows
        emit(resizeAckBytes(cols, rows))
        h.dispose()
        h = newTerminalTestHarness(cols, rows)
        h.mount(proc(r: TerminalRenderer): TerminalNode =
          build(r, cols, rows, step))
        h.flush()
        emit(frameBytes(h.driver.buffer))
      continue
    let ch = char(b)
    if pendingKey.len > 0 or ch == '\x1b':
      pendingKey.add ch
      if pendingKey == TestAppStepKey:
        pendingKey = ""
        inc step
        h.dispose()
        h = newTerminalTestHarness(cols, rows)
        h.mount(proc(r: TerminalRenderer): TerminalNode =
          build(r, cols, rows, step))
        h.flush()
        emit(frameBytes(h.driver.buffer))
        # The cursor is back on the barrier, so the parent's
        # `waitForCompleteFrame` means "the NEW frame is complete".
        continue
      if TestAppStepKey.startsWith(pendingKey):
        continue
      pendingKey = ""
      # Fall through: the byte that broke the prefix is still an ordinary
      # byte and must be honoured, or a `q` after a stray escape would hang.
    if ch == TestAppQuitByte or b == 0x04:
      result = TestAppExitOk
      break
    if ch == TestAppCaptureByte:
      if not connected:
        # Asked for a screenshot without `--test-ipc`. Silent by design: the
        # equivalence suite sends nothing, and a stray byte must not move the
        # cursor and break the barrier for a test that is reading the screen.
        continue
      if not opts.settle:
        # `--never-settle`. The child hears the request and declines, which is
        # the state "label never arrived" has to be distinguishable FROM a
        # hung child and FROM a socket that was never connected.
        continue
      client.requestScreenshot(stepLabel(opts.label, step))
  h.dispose()
  if connected:
    client.close()

proc runSnapshotApp*(build: SizedTreeBuilder; opts: TestAppOptions): int =
  ## The SIZED shape, in terms of the stepped one. A builder that does not
  ## depend on the step paints the same tree however often F10 is pressed.
  runSnapshotApp(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      build(r, cols, rows), opts)

proc runSnapshotApp*(build: proc(r: TerminalRenderer): TerminalNode;
                     opts: TestAppOptions): int =
  ## The fixed-size shape, in terms of the sized one. Two paint paths would be
  ## two things to keep true, and the CTUI-2 apps are the ones the cross-tier
  ## equality rests on.
  runSnapshotApp(
    proc(r: TerminalRenderer; cols, rows: int): TerminalNode = build(r), opts)

proc snapshotAppMain*(build: SteppedTreeBuilder; args: seq[string]): int =
  ## `runSnapshotApp` plus argument parsing, as one function of `argv` that
  ## returns a status. Every `apps/*.nim` main block is one call to this.
  ##
  ## Returns a status rather than quitting for the reason `main.nim` records
  ## about itself: a child that exited 0 on an unhandled exception would make
  ## a crash indistinguishable from a clean run to every assertion the parent
  ## makes about it.
  try:
    let opts = parseTestAppArgs(args)
    runSnapshotApp(build, opts)
  except TestAppUsageError as e:
    stderr.writeLine("snapshot-app: " & e.msg)
    TestAppExitUsage

proc snapshotAppMain*(build: SizedTreeBuilder; args: seq[string]): int =
  ## The SIZED shape of `snapshotAppMain`.
  snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      build(r, cols, rows), args)

proc snapshotAppMain*(build: proc(r: TerminalRenderer): TerminalNode;
                      args: seq[string]): int =
  ## The fixed-size shape of `snapshotAppMain`.
  snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows: int): TerminalNode = build(r), args)
