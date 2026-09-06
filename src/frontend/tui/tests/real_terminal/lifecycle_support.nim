## lifecycle_support.nim — CTUI-14. The pty-lifecycle helpers the four
## `test_real_*` suites this milestone adds all need.
##
## NOT A TEST FILE, and the name is what says so: `ci/lib/test-lane-files.sh`
## finds `test_*.nim` under this directory, so a module called anything else is
## a library the suites import rather than a suite the lane runs.
##
## ## Nothing here calls `check`
##
## Every function below either answers a question or RAISES, and that is
## deliberate. `std/unittest`'s `check` assigns `testStatusIMPL`, which the
## `test` template injects into its own scope; inside a `proc` that symbol is
## invisible, `check` silently takes its `else` branch, and the case prints
## `[OK]` while `programResult` goes to 1. A shared helper is exactly where that
## trap does the most damage, so the rule here is stronger than "use a
## template": these do not assert at all. The suites do.
##
## ## The failures are diagnoses, not timeouts
##
## `codetracer-specs/Testing/Verification-Harness-Traps.md` §3: a timeout is a
## symptom whose natural remedy — raise the timeout — is wrong for every cause
## it can have. So every wait below fails naming the status row it saw, whether
## the child was alive, and its exit code, which is what tells "still opening
## the trace" from "the engine refused" from "the binary died".

import std/[monotimes, os, posix, strutils, times]

import term_assert

import ../../testing/dual_snap

const
  ShowCursorSequence* = "\x1b[?25h"
  AltScreenEnterSequence* = "\x1b[?1049h"
  AltScreenLeaveSequence* = "\x1b[?1049l"
    ## The alternate screen, as the two sequences `nim-termctl` writes.
    ##
    ## COUNTED IN THE RAW STREAM AND NOT READ OFF THE TERMINAL, because the
    ## terminal's alt-screen state after the child has exited is `false`
    ## whether the child left it correctly or never entered it — the same "live
    ## flag, not a latch" property CTUI-11 recorded about DEC 2026's
    ## `synchronizedOutput`.

  WedgeBytes* = 4096
    ## The size of the garbage `trace.bin` the wedge folder holds.
    ##
    ## Big enough that `replay-server` reads a header out of it and commits to
    ## opening the recording — which is what makes it STALL rather than refuse
    ## — and small enough to write in one call. Measured: at this size the
    ## engine answers `initialize`, `configurationDone` and `launch` in full
    ## (`Content-Length: 102`, all 102 bytes, `success: true`) and then never
    ## sends the `stopped` event the handshake waits for, and never exits. The
    ## stall is at a MESSAGE BOUNDARY, so this folder does not exercise
    ## `DapStdioBackend.broken`; that guard is for a stall mid-body.

  HandshakeEnvVar* = "CODETRACER_TUI_HANDSHAKE_MS"
    ## `host/native_host.HandshakeEnvVar`. Spelled again rather than imported:
    ## reaching `host/` from a Tier-2 suite is allowed but would pull the
    ## entrypoint's module graph in to read one string, and a mismatch shows up
    ## as the clock case failing with both spellings named.

type
  AltScreenCounts* = object
    enters*: int
    leaves*: int

proc repoRoot*(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

proc tuiBinary*(): string =
  repoRoot() / "build" / "bin" / "codetracer-tui"

proc wedgeFolder*(): string =
  ## A folder with a RECORDING'S SHAPE and no recording in it.
  ##
  ## Built rather than checked in. A 4 KB blob of pseudo-random bytes in the
  ## repository would be a fixture nobody could read, and the property that
  ## matters is what the construction says out loud: it holds a `trace.bin`, so
  ## `host/native_host.traceFolderProblem` accepts it, and the bytes are not a
  ## recording, so the engine stalls on it.
  ##
  ## DETERMINISTIC rather than random, because a test whose subject differs
  ## every run is a test whose failures cannot be compared. The generator is a
  ## plain LCG; nothing here depends on the bytes' statistical properties, only
  ## on their not being a trace.
  result = repoRoot() / "test-logs" / "ctui14-wedge"
  createDir(result)
  let blob = result / "trace.bin"
  if fileExists(blob) and getFileSize(blob) == WedgeBytes:
    return
  var bytes = newString(WedgeBytes)
  var state = 0x5eed_1234'u32
  for i in 0 ..< WedgeBytes:
    state = state * 1103515245'u32 + 12345'u32
    bytes[i] = char((state shr 16) and 0xff'u32)
  writeFile(blob, bytes)

proc tuiSession*(args: seq[string]; cols, rows: int; handshakeMs = 0;
                 term = "xterm-256color"): TuiTestSession =
  ## The shipped binary in a real pty, with a KNOWN environment and its raw
  ## byte stream kept.
  ##
  ## `envRemove` on the five that decide colour and synchronized output is not
  ## tidiness: the lane inherits whatever terminal the developer or the CI
  ## runner is in, and a case that asserted anything about the emission under
  ## an inherited `COLORTERM=truecolor` would be asserting the runner's
  ## environment.
  var builder = newTuiTest(tuiBinary(), args)
    .width(cols).height(rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", term)
    .envSet("LANG", "en_US.UTF-8")
  # BLOCKED **OR** SET, NEVER BOTH — kept deliberately, though the harness no
  # longer requires it.
  #
  # `TermAssert.effectiveEnv` used to apply the blocklist to the overrides as
  # well (`if k in blocked: continue`), so a variable that was removed and then
  # set was simply absent. That is how the first version of the clock case came
  # to measure `DefaultHandshakeMs` twice — 30013 ms and 30016 ms — and report
  # a 3 ms difference between two budgets 4500 ms apart. The failure was the
  # harness's, the assertion was right, and this shape is what made the case
  # honest again.
  #
  # FIXED IN `TermAssert` (an explicit `envSet` now wins over `envRemove` and
  # over the tmux defaults, with `tests/test_harness_env_overrides.nim` pinning
  # it), and written up as trap 11 of
  # `codetracer-specs/Testing/Verification-Harness-Traps.md`. This file keeps
  # the discipline anyway: the workspace pins no `TermAssert` revision, so this
  # lane can be built against a checkout that predates the fix, and "each
  # variable is either blocked or set" costs nothing and depends on neither
  # behaviour.
  if handshakeMs > 0:
    builder = builder.envSet(HandshakeEnvVar, $handshakeMs)
  else:
    builder = builder.envRemove(HandshakeEnvVar)
  builder.spawn()

proc altScreenCounts*(sess: var TuiTestSession): AltScreenCounts =
  ## How many times the child entered and left the alternate screen.
  ##
  ## COUNTS AND NOT BOOLEANS. "The leave was sent" is satisfied by a stream
  ## with two enters and one leave, which is a terminal the user does not get
  ## back.
  let bytes = sess.transcriptBytes()
  AltScreenCounts(enters: bytes.count(AltScreenEnterSequence),
                  leaves: bytes.count(AltScreenLeaveSequence))

proc statusRowText*(sess: var TuiTestSession; cols, rows: int): string =
  ## The bottom row, right-trimmed.
  ##
  ## `strutils.strip` EXPLICITLY. `docs/tui-testing.md` records the trap:
  ## `unicode.strip` returns an ALL-whitespace string unchanged where
  ## `strutils.strip` returns "", so a blank row would read as `cols`
  ## characters long.
  strutils.strip(sess.regionText(rows - 1, 0, cols, 1), leading = false)

proc waitForOpeningFrame*(sess: var TuiTestSession; cols, rows: int;
                          timeoutMs = 30000) =
  ## Wait for FRAME 0 — the shell, with `opening …` on the status line, painted
  ## before `replay-server` is spawned.
  ##
  ## This is the state a wedge case has to reach before it sends a key: the
  ## alternate screen is claimed and the process is about to enter, or is
  ## already inside, the DAP handshake.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = statusRowText(sess, cols, rows)
    if last.contains("opening "):
      return
    if not sess.isAlive:
      raise newException(AssertionFailedError,
        "the binary exited before painting frame 0: status row was '" & last &
        "', exit code " & $sess.exitCode())
  raise newException(AssertionFailedError,
    "frame 0 never arrived within " & $timeoutMs & " ms: status row was '" &
    last & "', child alive=" & $sess.isAlive)

proc settleOnDebugger*(sess: var TuiTestSession; cols, rows: int;
                       timeoutMs = 180000) =
  ## Wait for FRAME 1 — the debugger — rather than for frame 0.
  ##
  ## `main.nim` paints twice on startup and both frames end with the cursor on
  ## the bottom-right cell, so `waitForCompleteFrame` alone returns on frame 0.
  ## The status row is what tells them apart, and the cursor barrier after it is
  ## what says frame 1 is complete.
  ##
  ## The default timeout is deliberately generous. Opening a recording is a
  ## `replay-server` spawn plus a DAP handshake plus the first `stackTrace`,
  ## `ct/load-locals` and `ct/event-load`, and this lane runs on hosts that are
  ## also building something else — measured at 66 ms idle and tens of seconds
  ## at load 58 on the same machine. A tight timeout here would fail as "the
  ## debugger never painted" for a run that was merely queued behind a compiler.
  discard sess.drainOutput(30)
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = statusRowText(sess, cols, rows)
    if last.len > 0 and not last.contains("opening "):
      waitForCompleteFrame(sess, cols, rows, timeoutMs = 30000)
      return
    if not sess.isAlive:
      raise newException(AssertionFailedError,
        "the binary exited before painting the debugger: status row was '" &
        last & "', exit code " & $sess.exitCode())
  raise newException(AssertionFailedError,
    "the binary never painted the debugger within " & $timeoutMs &
    " ms: status row was '" & last & "', child alive=" & $sess.isAlive)

# ---------------------------------------------------------------------------
# Surviving children
# ---------------------------------------------------------------------------

proc replayServerPids*(): seq[int] =
  ## Every live `replay-server` on this host, by pid.
  ##
  ## `/proc` rather than `pgrep`, so the answer does not depend on a tool being
  ## installed, and `comm` rather than `cmdline`, because `comm` is the
  ## executable's own name and cannot be spoofed by an argument that happens to
  ## mention it — including this suite's own command lines.
  result = @[]
  for kind, path in walkDir("/proc"):
    if kind != pcDir:
      continue
    let name = path.extractFilename
    if name.len == 0 or not name[0].isDigit:
      continue
    var pid = 0
    try:
      pid = parseInt(name)
    except ValueError:
      continue
    try:
      if strutils.strip(readFile(path / "comm")) == "replay-server":
        result.add pid
    except CatchableError:
      # The process exited between the `walkDir` and the read. Not an error:
      # a process that is gone is not a surviving child.
      discard

let baselineReplayServers = replayServerPids()
  ## The `replay-server` processes that were already running when this module
  ## was loaded.
  ##
  ## A BASELINE RATHER THAN A ZERO, because a developer's own session — or a
  ## `vm-gui-headless` run in another terminal — is not this suite's leak. What
  ## the suites assert is that no pid OUTSIDE this set survives, which is a
  ## statement about the sessions they started.

proc survivingReplayServers*(graceMs = 3000): seq[int] =
  ## `replay-server` processes that this run started and that are still alive.
  ##
  ## Polled rather than sampled once: a child is reaped asynchronously after
  ## its parent exits, so an immediate read would report a leak that is merely
  ## a race. The grace period ENDS EARLY the moment the set is empty, so a
  ## clean run costs one read.
  let deadline = getMonoTime() + initDuration(milliseconds = graceMs)
  while true:
    result = @[]
    for pid in replayServerPids():
      if pid notin baselineReplayServers:
        result.add pid
    if result.len == 0 or getMonoTime() >= deadline:
      return
    sleep(50)

proc noSurvivingReplayServer*(): bool =
  survivingReplayServers().len == 0

proc describeSurvivors*(): string =
  let pids = survivingReplayServers(graceMs = 0)
  if pids.len == 0: "none" else: $pids

proc reapableChildren*(): int =
  ## How many of THIS PROCESS's own children are still unreaped.
  ##
  ## `waitpid(-1, …, WNOHANG)` answers `-1`/`ECHILD` when there are none at
  ## all, `0` when there are live children it will not block for, and a pid
  ## when it reaped one. The pattern is `isonim-tui`'s
  ## `test_real_no_orphan_processes`; the difference is that this returns the
  ## COUNT it drained rather than one call's answer, so "there were three
  ## zombies" and "there were none" are different numbers.
  ##
  ## A LOOP RATHER THAN ONE CALL, so "there were three zombies" and "there
  ## were none" are different numbers rather than the same `-1`.
  result = 0
  var status: cint
  while true:
    let drained = waitpid(Pid(-1), status, WNOHANG)
    if drained <= 0:
      return
    inc result

proc replayServerPath*(): string =
  ## Where `replay-server` is, or "" when it has not been built.
  ##
  ## The same search order `host/native_host.findReplayServer` uses —
  ## `REPLAY_SERVER_BIN`, then the debug build tree, then cargo's own output
  ## directories. Spelled again rather than imported because reaching `host/`
  ## from here would pull the entrypoint's module graph into a suite that only
  ## wants a path, and a divergence shows up as the detector's positive arm
  ## failing to start a process.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let root = repoRoot()
  for candidate in [
      root / "src" / "build-debug" / "bin" / "replay-server",
      root / "src" / "db-backend" / "target" / "debug" / "replay-server",
      root / "src" / "db-backend" / "target" / "release" / "replay-server"]:
    if fileExists(candidate):
      return candidate
  ""
