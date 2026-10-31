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

import std/[exitprocs, monotimes, os, posix, strtabs, strutils, sysrand, times]

import term_assert

import ../../testing/dual_snap
import ../../../../common/replay_server_path   # the one search order

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

  WedgeContainer* = "trace.ct"
    ## The one entry of the wedge folder: a NAMED PIPE that nothing ever
    ## writes, under a container's name.
    ##
    ## WHY A PIPE, AND WHY NOT GARBAGE BYTES ANY MORE. The wedge used to be a
    ## 4 KB `trace.bin` of pseudo-random bytes, measured (CTUI-14) to make
    ## `replay-server` answer `launch` and then never send `stopped`. The engine
    ## has since learnt to read that file's header and refuse it: on `agents`
    ## `5192276c07c` it answers at once — "the replay server's handler for
    ## launch (seq 3) panicked: Invalid file header" — and the terminal
    ## correctly exits `ExitUnreadableRecording` (5), so every case built on
    ## the old folder measured a refusal and called it a stall. That is the
    ## engine getting better, not the clock getting worse, and the remedy is a
    ## folder that STILL stalls a correct engine.
    ##
    ## A pipe does, for real and in the engine's own code: the folder holds a
    ## `.ct` entry, so `host/native_host.traceFolderProblem` accepts it; the
    ## engine opens the container to read its header, and an open of a pipe
    ## with no writer does not return. That is the hung-network-mount shape
    ## the handshake clock exists for. Measured on the same tree: exit 4 after
    ## the 30 s default budget, `the replay engine stopped answering`, and no
    ## `replay-server` left behind once the terminal gave up on it.

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
  ## A folder with a RECORDING'S SHAPE whose recording never arrives: one
  ## `WedgeContainer`, a named pipe nothing writes (see `WedgeContainer` for
  ## why a pipe and not bytes).
  ##
  ## Built rather than checked in — git cannot hold a pipe, and the property
  ## that matters is what the construction says out loud. Under the TEMP
  ## directory, per process, rather than in `test-logs/`: a pipe in a tree
  ## people copy is a `cp -r` that never finishes. Removed when the suite
  ## exits.
  result = getTempDir() / "ctui14-wedge-" & $getCurrentProcessId()
  createDir(result)
  let pipe = result / WedgeContainer
  var st: Stat
  if stat(pipe.cstring, st) == 0:
    if S_ISFIFO(st.st_mode):
      return
    removeFile(pipe)
  if mkfifo(pipe.cstring, Mode(0o600)) != 0:
    raiseOSError(osLastError(), "cannot make the wedge's pipe " & pipe)
  let folder = result
  addExitProc(proc() = removeDir(folder))

proc isPipe*(path: string): bool =
  ## Whether `path` is a named pipe — what `wedgeFolder`'s one entry must be.
  ## Here rather than in the suite so the suite need not import `posix`, whose
  ## `sleep` shadows `os.sleep`.
  var st: Stat
  stat(path.cstring, st) == 0 and S_ISFIFO(st.st_mode)

# ---------------------------------------------------------------------------
# This run's mark
# ---------------------------------------------------------------------------
#
# ## WHOSE ENGINES ARE COUNTED: THE ONES THIS RUN MARKED
#
# The question every survivor check asks is "did a session THIS RUN started
# leave its engine behind?". It is NOT "is any `replay-server` alive on this
# host?", and a shared workstation answers that second question with yes all
# day: other worktrees' suites, a mutation grade in this very tree, the
# developer's own TUI pane. Each starts and stops engines on its own clock.
#
# The detector used to answer the second question and subtract a baseline
# taken when this module loaded. That excused only the engines ALREADY running
# at that instant; one another process started while the suite ran was
# counted as this suite's leak, and the lane went red on a quiet product
# (codetracer-pm `issues/2026-10-21-tui-orphan-suites-count-replay-servers-
# other-worktrees-start-during-the-run.md`). Worse, the noise looked exactly
# like a real leak, so a real one on a busy host would have been waved away.
#
# So every session these suites start carries a PER-RUN MARK in its
# environment (`RunTokenEnvVar`=`runToken()`), the TUI hands its environment
# down to the `replay-server` it spawns (`stdio_backend.startReplayServer`
# calls `startProcess` with no `env`, i.e. inherited), and the detector keeps
# only engines whose `/proc/<pid>/environ` holds that exact entry. The
# baseline is gone: an engine that was running before the run cannot carry a
# token minted when it started, so excluding it needs no snapshot, and the
# check no longer depends on WHEN anything else on the host started.
#
# A leaked engine keeps the mark: `environ` is fixed at `execve`, and
# reparenting to `init` — the very thing that makes a leak invisible to
# `waitpid` — does not touch it. That is why the mark is in the environment
# and not in a process group or session, which a leaked child can leave.

const
  RunTokenEnvVar* = "CODETRACER_TUI_TEST_RUN_TOKEN"
    ## The environment variable that marks a process as started by THIS run.
    ##
    ## Read by nothing in the product; it exists only to be found in
    ## `/proc/<pid>/environ` by `markedReplayServerPids`.

proc mintRunToken(): string =
  ## A token no other run on this host can hold.
  ##
  ## THREE INGREDIENTS, because each alone has a collision the others close:
  ## the pid is unique among LIVE processes but recycled; the wall-clock
  ## nanoseconds separate two runs that drew the same recycled pid; and 16
  ## bytes from the kernel's CSPRNG (`std/sysrand`, `getrandom(2)`) separate
  ## two runs whose clocks agree — containers, or a clock that was set back.
  ## RAISES rather than falling back to something weaker: a token that might
  ## collide is a detector that might count another run's engine, which is
  ## the defect this exists to remove.
  var entropy: array[16, byte]
  if not urandom(entropy):
    raise newException(OSError,
      "could not read the kernel's random source to mint the run token")
  let now = getTime()
  result = $getCurrentProcessId() & "-" & $now.toUnix & "." &
           $now.nanosecond & "-"
  for b in entropy:
    result.add toHex(b)

let runTokenValue = mintRunToken()
  ## Minted ONCE, when the module loads, so every session this process starts
  ## carries the same mark and the detector recognises all of them.

proc runToken*(): string =
  ## This run's mark: the value `RunTokenEnvVar` carries in every session the
  ## suites start.
  runTokenValue

proc carryRunMark*(builder: TuiTestBuilder): TuiTestBuilder =
  ## Put this run's mark in a session's environment.
  ##
  ## EVERY SESSION WHOSE ENGINE A SURVIVOR CHECK LOOKS FOR MUST GO THROUGH
  ## THIS (`tuiSession` does). A session without it is invisible to the
  ## detector — its leak would pass every check — which is why the five full
  ## sessions in `test_real_no_orphans.nim` assert that each live session's
  ## engine IS found while it runs.
  builder.envSet(RunTokenEnvVar, runTokenValue)

proc markedEnvironment*(): StringTableRef =
  ## This process's environment plus this run's mark, for a `startProcess`
  ## that should count as one of this run's engines.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result[RunTokenEnvVar] = runTokenValue

proc unmarkedEnvironment*(): StringTableRef =
  ## This process's environment WITHOUT any run mark, for a `startProcess`
  ## that must look like somebody else's engine.
  ##
  ## Stripped explicitly rather than trusted absent: if this suite was
  ## started by something that itself set `RunTokenEnvVar`, an inherited
  ## copy would carry THAT run's token. It could not match `runToken()`
  ## either, but a negative arm should not rest on that argument.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key != RunTokenEnvVar:
      result[key] = value

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
  ##
  ## EVERY SESSION CARRIES THIS RUN'S MARK (`carryRunMark`), which the TUI
  ## hands down to the `replay-server` it spawns: the survivor checks count
  ## only engines that carry it, so a session started without it would leak
  ## invisibly.
  var builder = newTuiTest(tuiBinary(), args)
    .width(cols).height(rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", term)
    .envSet("LANG", "en_US.UTF-8")
    .carryRunMark()
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
#
# Counted by THIS RUN'S MARK: see "This run's mark" above for why, and for
# what an engine has to carry to be found.

proc replayServerPids*(): seq[int] =
  ## EVERY live `replay-server` on this host, by pid — whoever started it.
  ##
  ## NOT A LEAK DETECTOR. On a shared host this includes other worktrees'
  ## engines and the developer's own; `markedReplayServerPids` is the one the
  ## survivor checks use. This one is kept for the negative arm, which has to
  ## show that an engine the detector ignores is nevertheless alive.
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

proc carriesRunMark(pid: int): bool =
  ## Whether `pid`'s environment holds EXACTLY `RunTokenEnvVar=<runToken()>`.
  ##
  ## `/proc/<pid>/environ` is the environment the process was `exec`ed with,
  ## as NUL-separated `KEY=VALUE` entries. The whole entry is compared, not a
  ## substring, so a token that is a prefix of another — or a variable whose
  ## VALUE happens to contain this one — is not a match.
  ##
  ## UNREADABLE MEANS NOT OURS. The file is readable only by the process's own
  ## uid (and `ptrace` permission), so a `replay-server` another user runs
  ## raises here, and so does one that exited after the `comm` read. Neither
  ## is an engine this run started and is still running, and this run's own
  ## engines always run as this uid — the TUI is our child and spawns them.
  let wanted = RunTokenEnvVar & "=" & runTokenValue
  try:
    for entry in readFile("/proc" / $pid / "environ").split('\0'):
      if entry == wanted:
        return true
  except CatchableError:
    discard
  false

proc markedReplayServerPids*(): seq[int] =
  ## The live `replay-server` processes THIS RUN's sessions started: the
  ## host-wide `comm` walk, kept only where the run's mark is in the
  ## environment. Whatever else runs on the host, it is not in this list.
  result = @[]
  for pid in replayServerPids():
    if carriesRunMark(pid):
      result.add pid

proc survivingReplayServers*(graceMs = 3000): seq[int] =
  ## `replay-server` processes this run's sessions started that are still
  ## alive — only those, whatever else runs on the host.
  ##
  ## Polled rather than sampled once: a child is reaped asynchronously after
  ## its parent exits, so an immediate read would report a leak that is merely
  ## a race. The grace period ENDS EARLY the moment the set is empty, so a
  ## clean run costs one read.
  let deadline = getMonoTime() + initDuration(milliseconds = graceMs)
  while true:
    result = markedReplayServerPids()
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
  ## Resolved by `src/common/replay_server_path` — the module
  ## `host/native_host.findReplayServer` delegates to as well — so this
  ## detector's positive arm and the TUI's own host find THE SAME engine. That
  ## module is imported rather than `host/`, which would pull the entrypoint's
  ## module graph into a suite that only wants a path. Its order keeps what
  ## this proc already searched (`REPLAY_SERVER_BIN`, `CODETRACER_BUILD_DIR`,
  ## the repro output root, the tup tree, cargo's two) and adds
  ## `CT_BUILD_OUT_ROOT` ahead of `CODETRACER_BUILD_DIR`; while each caller
  ## spelled the list privately the two orders diverged, and a checkout built
  ## only through `repro` found an engine here that the host would not
  ## (codetracer-pm
  ## `issues/2026-09-29-replay-server-discovery-misses-the-repro-build-output-root.md`).
  locateReplayServer()
