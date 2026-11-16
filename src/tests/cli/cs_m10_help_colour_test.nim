## CS-M10 (Clispec Library campaign, reprobuild-pm): `ct`'s help screens are
## printed as clispec's printer prints them: coloured only on a terminal,
## and as wide as the terminal (or `COLUMNS`), at most 100 columns.
##
## The real `ct` binary is run with `--help` (and `-h`):
##
##   * on a pseudo-terminal this test opens itself (`posix_openpt`, the
##     window size set with `TIOCSWINSZ`), as the session leader with the
##     terminal as its controlling terminal and as stdin, stdout and stderr:
##     with `TERM=xterm` and no `NO_COLOR` the page is styled; with
##     `NO_COLOR=1`, or `TERM=dumb`, it is plain; the page is as wide as the
##     terminal (80, 60, and 120 capped at 100) unless `COLUMNS` says
##     otherwise;
##   * with stdout a pipe (and `TERM=xterm`, no `NO_COLOR`): plain, 80
##     columns wide.
##
## Every output is compared in full with what `ctHelpScreen` (the function
## ct's loader prints help with) renders in this process for that request,
## width and colour, so the test checks the decision (colour or not, which
## width) on the binary, and `cs_m10_cli_surface_unchanged_test.nim` checks
## the page itself.  On the terminal the line discipline writes each newline
## as CR LF; the output is compared with CR LF read as LF.
##
## The binary is `$CODETRACER_E2E_CT_PATH`, else `$CODETRACER_BUILD_DIR/bin/ct`,
## else `src/build-debug/bin/ct` (the order the other CLI suites use).  A
## platform where no pseudo-terminal can be opened fails this test; it does
## not skip it.  The test kills only the process it started, by its pid
## (before it is reaped), and every run has a deadline: on the terminal its
## own, through pipes `timeout`'s.
##
## Lane: `cli-record` (`ci/lib/test-lane-files.sh` globs `src/tests/cli`).

when not (defined(linux) or defined(macosx)):
  {.error: "cs_m10_help_colour_test: needs a POSIX pseudo-terminal".}

import std/[os, osproc, posix, streams, strtabs, strutils, tempfiles, times,
            unittest]
import confutils/clispec_config
import ../../ct/[codetracerconf, version]

const
  ThisDir = currentSourcePath.parentDir
  RepoRoot = ThisDir.parentDir.parentDir.parentDir
  DeadlineSeconds = 60.0
  ## Non-empty, as `codetracer.nim`'s is: the help lists `--version`.
  VersionText = "CodeTracer version: " & version.CodeTracerVersionStr

type Outcome = tuple[output: string, code: int]

proc ctBinary(): string =
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len == 0:
    result = getEnv("CODETRACER_BUILD_DIR", RepoRoot / "src" / "build-debug") /
      "bin" / "ct"
  result = absolutePath(result)

proc baseEnv(scratch: string): seq[(string, string)] =
  ## The environment every run starts from: PATH, a private HOME, TMPDIR and
  ## CODETRACER_HOME, and the dev shell's run-time library path.
  result = @[("PATH", getEnv("PATH")), ("HOME", scratch / "home"),
             ("TMPDIR", scratch / "tmp"), ("CODETRACER_HOME", scratch / "cthome")]
  for v in ["CODETRACER_LD_LIBRARY_PATH", "LD_LIBRARY_PATH", "LOCALE_ARCHIVE"]:
    if existsEnv(v): result.add (v, getEnv(v))

proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}
proc ioctlArg(fd: cint; request: culong): cint {.importc: "ioctl",
  header: "<sys/ioctl.h>", varargs.}
var TIOCSCTTY {.importc, header: "<sys/ioctl.h>".}: culong
var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
type
  Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

proc onTerminal(bin: string; args: openArray[string];
                env: openArray[(string, string)]; columns: int): Outcome =
  ## Runs `bin args` as the session leader of a new pseudo-terminal
  ## `columns` wide, and reads everything it writes until it exits.
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  doAssert master >= 0, "posix_openpt failed: no pseudo-terminal"
  doAssert grantpt(master) == 0 and unlockpt(master) == 0,
    "grantpt/unlockpt failed"
  let slaveName = $ptsname(master)
  var size = Winsize(ws_row: 50, ws_col: cushort(columns))
  discard ioctlArg(master, TIOCSWINSZ, addr size)
  var argvList = @[bin]
  for a in args: argvList.add a
  var envList: seq[string]
  for (k, v) in env: envList.add k & "=" & v
  let argv = allocCStringArray(argvList)
  let envp = allocCStringArray(envList)
  let cSlave = slaveName.cstring
  let cExe = bin.cstring
  let pid = fork()
  doAssert pid >= 0, "fork failed"
  if pid == 0:
    discard setsid()
    let slave = posix.open(cSlave, O_RDWR)
    if slave < 0:
      exitnow(126)
    discard ioctlArg(slave, TIOCSCTTY, 0)
    discard ioctlArg(slave, TIOCSWINSZ, addr size)
    discard dup2(slave, 0)
    discard dup2(slave, 1)
    discard dup2(slave, 2)
    if slave > 2:
      discard close(slave)
    discard close(master)
    discard execve(cExe, argv, envp)
    exitnow(127)
  deallocCStringArray(argv)
  deallocCStringArray(envp)
  let deadline = epochTime() + DeadlineSeconds
  var text = ""
  var exited = false
  var code = -1
  var buf: array[4096, char]
  proc reap(flags: cint): bool =
    var st: cint
    if waitpid(pid, st, flags) == pid:
      result = true
      exited = true
      code = if WIFEXITED(st): WEXITSTATUS(st) else: -1
  proc stop() =
    # Ours, started above and not yet reaped (so the pid is still ours):
    # stopped by its pid and reaped.
    if not exited:
      discard kill(pid, SIGKILL)
      discard reap(0)
      text.add "\n<no exit within " & $DeadlineSeconds & " s; killed>"
  while true:
    if epochTime() > deadline:
      stop()
      break
    var fds = [TPollfd(fd: master, events: POLLIN)]
    let ready = poll(addr fds[0], 1, 200)
    if ready > 0:
      let n = posix.read(master, addr buf[0], buf.len)
      if n > 0:
        for i in 0 ..< n: text.add buf[i]
        continue
      # 0 or EIO: no slave descriptor is left open.
      break
    if ready == 0:
      # Nothing to read: done once the child had exited before this poll.
      if exited:
        break
      discard reap(WNOHANG)
  # The terminal is closed on the child's side; wait for its exit, still
  # under the deadline.
  while not exited and epochTime() <= deadline:
    if not reap(WNOHANG):
      discard poll(nil, 0, 50)
  stop()
  discard close(master)
  result = (text.replace("\r\n", "\n"), code)

proc throughPipes(bin: string; args: openArray[string];
                  env: openArray[(string, string)]): Outcome =
  ## Runs `bin args` with stdout and stderr on pipes and no controlling
  ## terminal (`setsid`), under `timeout`; returns stdout.
  var e = newStringTable(modeCaseSensitive)
  for (k, v) in env: e[k] = v
  let setsidExe = findExe("setsid", followSymlinks = false)
  doAssert setsidExe.len > 0, "no `setsid` on PATH"
  # Not followed: on a coreutils multi-call install `timeout` is a link to
  # `coreutils`, which runs as `timeout` only when called by that name.
  # `timeout` stops the child it starts (ct) after the deadline, so the reads
  # below end.
  let timeoutExe = findExe("timeout", followSymlinks = false)
  doAssert timeoutExe.len > 0, "no `timeout` on PATH"
  let p = startProcess(setsidExe, args = @["-w", timeoutExe, "-k", "5",
                       $int(DeadlineSeconds), bin] & @args, env = e,
                       options = {})
  p.inputStream.close()
  let o = p.outputStream.readAll()
  discard p.errorStream.readAll()
  result = (o, p.waitForExit())
  p.close()

proc expected(argv: seq[string]; width: int; styled: bool): string =
  ## The page ct prints for `argv` at `width`, styled or not, rendered here
  ## by the function ct's loader prints help with, plus the newline ct
  ## ends it with when it lacks one.
  let options = ctCliOptions(VersionText)
  try:
    discard CtCli.load(argv, CliSources(), options)
  except CliHelpRequest as e:
    result = ctHelpScreen(e, options, width, styled)
  except CatchableError as e:
    return "<no help request: " & e.msg & ">"
  if not result.endsWith("\n"):
    result.add "\n"

proc firstDifference(a, b: string): string =
  let al = a.splitLines
  let bl = b.splitLines
  for i in 0 ..< max(al.len, bl.len):
    let x = if i < al.len: al[i] else: "<none>"
    let y = if i < bl.len: bl[i] else: "<none>"
    if x != y:
      return "line " & $(i + 1) & ":\n  got:      " & x.escape &
        "\n  expected: " & y.escape
  "none"

let bin = ctBinary()
let scratch = createTempDir("ct_cs_m10_colour_", "")
for d in ["home", "tmp", "cthome"]: createDir(scratch / d)

suite "CS-M10: ct prints help in colour only where clispec would":
  test "the ct binary exists":
    checkpoint("ct binary: " & bin)
    check fileExists(bin)

  proc compare(o: Outcome; want: string) =
    if o.output != want:
      checkpoint(firstDifference(o.output, want))
    check o.code == 0
    check o.output == want

  test "on a terminal, `ct --help` is styled and as wide as the terminal":
    let env = baseEnv(scratch) & @[("TERM", "xterm")]
    let o = onTerminal(bin, ["--help"], env, 80)
    check "\e[" in o.output
    compare(o, expected(@["--help"], 80, true))

  test "on a terminal, `ct record -h` is the short page, styled":
    let env = baseEnv(scratch) & @[("TERM", "xterm")]
    let o = onTerminal(bin, ["record", "-h"], env, 80)
    check "\e[" in o.output
    compare(o, expected(@["record", "-h"], 80, true))
    check o.output != expected(@["record", "--help"], 80, true)

  test "on a terminal 60 columns wide, the page is 60 columns wide":
    let env = baseEnv(scratch) & @[("TERM", "xterm")]
    compare(onTerminal(bin, ["record", "--help"], env, 60),
            expected(@["record", "--help"], 60, true))

  test "on a terminal 120 columns wide, the page is 100 columns wide":
    let env = baseEnv(scratch) & @[("TERM", "xterm")]
    compare(onTerminal(bin, ["record", "--help"], env, 120),
            expected(@["record", "--help"], 100, true))

  test "COLUMNS outranks the terminal's width":
    let env = baseEnv(scratch) & @[("TERM", "xterm"), ("COLUMNS", "70")]
    compare(onTerminal(bin, ["record", "--help"], env, 90),
            expected(@["record", "--help"], 70, true))

  test "with NO_COLOR=1, `ct --help` on a terminal is plain":
    let env = baseEnv(scratch) & @[("TERM", "xterm"), ("NO_COLOR", "1")]
    let o = onTerminal(bin, ["--help"], env, 80)
    check "\e[" notin o.output
    compare(o, expected(@["--help"], 80, false))

  test "with TERM=dumb, `ct --help` on a terminal is plain":
    let env = baseEnv(scratch) & @[("TERM", "dumb")]
    let o = onTerminal(bin, ["--help"], env, 80)
    check "\e[" notin o.output
    compare(o, expected(@["--help"], 80, false))

  test "with stdout not a terminal, `ct --help` is plain and 80 columns wide":
    let env = baseEnv(scratch) & @[("TERM", "xterm")]
    let o = throughPipes(bin, ["--help"], env)
    check "\e[" notin o.output
    compare(o, expected(@["--help"], 80, false))
    let r = throughPipes(bin, ["record", "--help"], env)
    compare(r, expected(@["record", "--help"], 80, false))

try:
  removeDir(scratch)
except OSError:
  discard
