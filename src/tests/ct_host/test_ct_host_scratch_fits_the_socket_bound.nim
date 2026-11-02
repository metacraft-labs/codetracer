## test_ct_host_scratch_fits_the_socket_bound.nim
##
## The scratch directory the `ct host` suites run in (`ct_host_scratch`) gives
## `ct host` a `CODETRACER_HOME` with room for every Unix socket the product
## binds under it, and a home without that room is refused before anything is
## started, by a message naming the socket path, its length and the limit.
##
## ## Why the claim matters
##
## The suites made their scratch directory under the default `TMPDIR`; on
## macOS that is `/var/folders/<..>/T/`, the session manager's socket under
## it was longer than `sockaddr_un.sun_path` holds, and every case that needed
## a replay timed out rather than naming the cause.
##
## ## What runs
##
## The real helper, on real directories under `/tmp`, and the bound as this
## host's C headers declare it (`sizeof(sun_path)`). No `ct host` is started:
## the property is about the directory the suites hand it.
##
## Lane: `ct-host-admission` (`just test-ct-host-admission`).

import std/[os, strutils, unittest]

import ct_host_scratch

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 17

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc homeWithSocketPathOf(base: string; length: int): string =
  ## A home under `base` whose longest socket path is exactly `length` bytes.
  let tail = longestSocketPathUnder(base / "h").len - (base / "h").len
  result = base / repeat('h', length - tail - base.len - 1)
  doAssert longestSocketPathUnder(result).len == length

suite "the ct host suites' scratch home fits the Unix socket bound":

  test "the bound is sun_path less its NUL":
    let max = maxUnixSocketPathBytes()
    checkpoint("bound: " & $max)
    when defined(macosx):
      ck max == 103
    elif defined(linux):
      ck max == 107
    else:
      ck max > 0

  test "the longest socket path is a replay's, with the largest pid":
    let path = longestSocketPathUnder("/tmp/h")
    ck path.startsWith("/tmp/h/tmp/session-manager/9")
    ck path.endsWith("/9999.sock")

  test "a scratch directory is made under /tmp, and its home fits":
    let scratch = createHostScratch("ct-sb-")
    try:
      checkpoint(scratch)
      ck scratch.startsWith("/tmp/ct-sb-")
      ck dirExists(scratch)
      ck socketBoundViolation(scratch / HomeDirName) == ""
    finally:
      removeDir(scratch)

  test "a home is accepted at the bound and refused one byte past it, by name":
    let max = maxUnixSocketPathBytes()
    let fits = homeWithSocketPathOf("/tmp", max)
    ck socketBoundViolation(fits) == ""
    var raised = false
    try:
      requireSocketPathsFit(fits)
    except IOError:
      raised = true
    ck not raised

    let tooLong = homeWithSocketPathOf("/tmp", max + 1)
    let violation = socketBoundViolation(tooLong)
    checkpoint(violation)
    ck violation.contains(longestSocketPathUnder(tooLong))
    ck violation.contains("is " & $(max + 1) & " bytes")
    ck violation.contains("holds " & $max)
    ck violation.contains("sun_path")
    ck violation.contains("at most " & $fits.len & " bytes")
    var message = ""
    try:
      requireSocketPathsFit(tooLong)
    except IOError as e:
      message = e.msg
    ck message == violation

  test "the home's real path is measured too":
    # A short link to a deep directory: the link fits, its target does not.
    let max = maxUnixSocketPathBytes()
    let scratch = createHostScratch("ct-sb-")
    try:
      let deep = scratch / repeat('d', max - scratch.len - 20)
      createDir(deep)
      let link = scratch / "l"
      createSymlink(deep, link)
      ck longestSocketPathUnder(link).len <= max
      let violation = socketBoundViolation(link)
      checkpoint(violation)
      ck violation.contains(expandFilename(deep))
      ck violation.contains("sun_path")
    finally:
      removeDir(scratch)

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
