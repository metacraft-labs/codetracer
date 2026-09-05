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

const
  TestAppCaptureByte* = 'S'
    ## What the parent sends to say "I have the whole frame; ask for it now".
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

  TestAppUsageError* = object of CatchableError

const DefaultTestAppLabel* = "settled"

proc initTestAppOptions*(cols = 80; rows = 24): TestAppOptions =
  TestAppOptions(cols: cols, rows: rows, testIpc: false,
                 label: DefaultTestAppLabel, settle: true)

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

proc readByteWithTimeout(timeoutMs: int): int =
  ## One byte from fd 0, or -1 on timeout, or -2 on EOF.
  var rs: TFdSet
  FD_ZERO(rs)
  FD_SET(0.cint, rs)
  var tv: Timeval
  tv.tv_sec = posix.Time(timeoutMs div 1000)
  tv.tv_usec = clong((timeoutMs mod 1000) * 1000)
  let ready = posix.select(1.cint, addr rs, nil, nil, addr tv)
  if ready <= 0: return -1
  var b: char
  let got = posix.read(0.cint, addr b, 1)
  if got == 0: return -2
  if got < 0: return -1
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

proc runSnapshotApp*(build: proc(r: TerminalRenderer): TerminalNode;
                     opts: TestAppOptions): int =
  ## Paint `build`'s tree once at `opts.cols` x `opts.rows`, then serve the
  ## parent until it says to quit. Returns the process's exit status; the
  ## caller is the only thing that quits.
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

  let h = newTerminalTestHarness(opts.cols, opts.rows)
  h.mount(build)
  h.flush()
  emit(frameBytes(h.driver.buffer))
  # The cursor now rests at (rows-1, cols-1). That IS the barrier; see the
  # module header. Nothing else may be written to fd 1 from here on, or the
  # cursor moves and the parent's barrier stops meaning "frame complete".

  let deadline = getMonoTime() + initDuration(seconds = TestAppDeadlineSeconds)
  result = TestAppExitDeadline
  while getMonoTime() < deadline:
    let b = readByteWithTimeout(100)
    if b == -2:
      result = TestAppExitOk
      break
    if b < 0: continue
    let ch = char(b)
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
      client.requestScreenshot(opts.label)
  h.dispose()
  if connected:
    client.close()

proc snapshotAppMain*(build: proc(r: TerminalRenderer): TerminalNode;
                      args: seq[string]): int =
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
