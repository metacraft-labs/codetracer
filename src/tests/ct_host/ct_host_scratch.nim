## ct_host_scratch.nim
##
## The scratch directory a `ct host` end-to-end suite runs `ct host` in, and
## the check that the `CODETRACER_HOME` inside it is short enough for the
## Unix sockets the product binds under it. Shared by the suites in this
## directory (lane `ct-host-admission`, through `ct_host_harness`) and by
## `../ct_host_manifest/` (lane `ct-host-manifest`). Not a suite: the lanes
## run `test_*.nim` only.
##
## ## Why it exists
##
## `ct host`'s server talks to its session manager over a Unix-domain socket
## at `$CODETRACER_HOME/tmp/session-manager/<pid>.sock`, and the session
## manager gives every replay a socket of its own at
## `$CODETRACER_HOME/tmp/session-manager/<pid>/<replay id>.sock`. A socket
## address holds a fixed number of bytes (`sockaddr_un.sun_path`, 108 on
## Linux and 104 on macOS, each including the terminating NUL; unix(7),
## https://man7.org/linux/man-pages/man7/unix.7.html), and a longer path
## cannot be bound. The suites made their scratch directory with
## `createTempDir` under the default `TMPDIR`, which on macOS is the deep
## per-user `/var/folders/<..>/T/`: the session manager's socket did not fit,
## no replay ever started, and every case that needed one timed out instead
## of failing with a cause.
##
## So the scratch directory is made under `/tmp` (`createHostScratch`), and a
## suite refuses a home whose longest socket path does not fit before it
## starts `ct host` (`requireSocketPathsFit`), naming the path, its length and
## the limit.

import std/[os, strutils, tempfiles]

const
  HomeDirName* = "ct-home"
    ## The `CODETRACER_HOME` of a suite's `ct host`, inside its scratch
    ## directory.
  ScratchBase = "/tmp"
    ## Short on every POSIX host, wherever `TMPDIR` points.
  PidDigits = when defined(macosx): 5 else: 7
    ## Digits in the largest process id: macOS's `PID_MAX` is 99999; Linux's
    ## `pid_max` can be raised to `PID_MAX_LIMIT`, 4194304 (proc(5)). The
    ## session manager's pid is a component of every socket path it binds.
  ReplayIdDigits = 4
    ## Replay ids budgeted for: numbered from 0 and never reused, and no
    ## suite starts thousands.

var sunPathBytes {.importc: "sizeof(((struct sockaddr_un *)0)->sun_path)",
                   header: "<sys/un.h>".}: csize_t
  ## The size of `sun_path` as this host's C headers declare it, the same
  ## expression the session manager checks every bind against.

proc maxUnixSocketPathBytes*(): int =
  ## The longest path, in bytes, a Unix socket address holds: `sun_path`
  ## less its terminating NUL.
  int(sunPathBytes) - 1

proc longestSocketPathUnder*(home: string): string =
  ## The longest Unix socket path the product derives under `home`: a
  ## replay's, with the largest pid and replay id budgeted for.
  home / "tmp" / "session-manager" / repeat('9', PidDigits) /
    (repeat('9', ReplayIdDigits) & ".sock")

proc socketBoundViolation*(home: string): string =
  ## Why `home` cannot be a `CODETRACER_HOME` — the longest socket path under
  ## it, its length in bytes and the limit — or "" when every socket path
  ## under it fits. `home` is measured as spelled and, when it exists, by
  ## its real path too (macOS's `/tmp` is a link to `/private/tmp`), and the
  ## longer one decides.
  let max = maxUnixSocketPathBytes()
  var spellings = @[absolutePath(home)]
  if dirExists(home):
    let real = expandFilename(home)
    if real != spellings[0]:
      spellings.add real
  for spelling in spellings:
    let socketPath = longestSocketPathUnder(spelling)
    if socketPath.len > max:
      return "the CODETRACER_HOME " & home & " is too deep for the Unix sockets " &
        "CodeTracer binds under it: " & socketPath & " is " & $socketPath.len &
        " bytes, and a socket address holds " & $max & " (sockaddr_un.sun_path). " &
        "The session manager would refuse to bind it and no replay could start. " &
        "Use a home of at most " & $(max - (socketPath.len - spelling.len)) & " bytes."
  ""

proc requireSocketPathsFit*(home: string) =
  ## Raise `IOError` with `socketBoundViolation`'s message when `home` does
  ## not fit. Call it before starting anything with `CODETRACER_HOME=home`.
  let violation = socketBoundViolation(home)
  if violation.len > 0:
    raise newException(IOError, violation)

proc createHostScratch*(prefix: string): string =
  ## A fresh scratch directory under `/tmp`, named `prefix` and a random
  ## suffix, whose `HomeDirName` fits the socket bound (checked).
  result = createTempDir(prefix, "", ScratchBase)
  requireSocketPathsFit(result / HomeDirName)
