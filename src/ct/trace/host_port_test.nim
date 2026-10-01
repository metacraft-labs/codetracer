## host_port_test.nim
##
## WHICH PORT `ct host` ASKS FOR, and where that answer comes from.
##
## `CLI/ct/host.md` §Options has always said `--port <n>` /
## `CODETRACER_HOST_PORT` / default **auto-assign**, and until 2026-10-01
## neither half held: the variable existed nowhere, and `hostPort` declared no
## `defaultValue`, so confutils made the flag mandatory. Filed as
## `codetracer-specs/issues/2026-09-30-ct-host-port-env-and-auto-assign-are-unimplemented.md`,
## and the hosted path is why it mattered rather than being tidiness — WD2 puts
## `ct host` inside a container whose port the SUBSTRATE allocates, which is
## exactly the auto-assign case and the one where the caller must learn the port
## from the process instead of dictating it.
##
## `resolveHostPort` is the whole of that decision. The three sources mean a
## precedence, and the two things easiest to get backwards are what this suite
## is for:
##
##   * **absence must be distinguishable from a choice.** The flag's default is
##     `-1` for the reason `hostBind`'s is the empty string: with a real port as
##     the default there is no value meaning "the operator said nothing", so the
##     environment variable could never be consulted without also overriding an
##     explicit `--port`.
##   * **a malformed environment value is REFUSED, not ignored.** Falling back to
##     auto-assign on a typo would put the server on a port the operator neither
##     chose nor knows about — which is worse than refusing, because the process
##     would look healthy.
##
## That the resolved port is then actually BOUND, and that an auto-assigned one
## is read back from the socket and printed, is the separate claim
## `src/frontend/tests/index_reports_the_port_it_bound_test.nim` makes against a
## running server. Neither suite is sufficient alone: this one cannot see a
## listener, and that one cannot see the CLI.
##
## Lane: `ct-trace-units` (discovered by `src/ct/trace/*_test.nim`).

import
  std/[strutils, unittest],
  ./host

const ExpectedAssertions = 23
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

suite "ct host port resolution":
  test "nothing said anywhere is auto-assign":
    let r = resolveHostPort(-1, "")
    ck r.error.len == 0
    ck r.autoAssigned
    # `0` is the kernel's own spelling for "any free port", so there is no scan
    # and no race between choosing and binding.
    ck r.port == AutoAssignPort
    ck r.port == 0

  test "the flag wins over the environment":
    let r = resolveHostPort(8901, "7000")
    ck r.error.len == 0
    ck not r.autoAssigned
    ck r.port == 8901

  test "the environment is consulted when the flag is absent":
    let r = resolveHostPort(-1, "7000")
    ck r.error.len == 0
    ck not r.autoAssigned
    ck r.port == 7000

  test "whitespace around the environment value is not a port":
    let r = resolveHostPort(-1, "  7000\n")
    ck r.error.len == 0
    ck r.port == 7000

  test "an explicit --port 0 is auto-assign said out loud":
    # It must not be treated as a chosen port: a caller waiting for a URL
    # naming port 0 is waiting for something no client can connect to.
    let r = resolveHostPort(0, "")
    ck r.error.len == 0
    ck r.port == 0
    ck r.autoAssigned

  test "CODETRACER_HOST_PORT=0 is auto-assign too":
    let r = resolveHostPort(-1, "0")
    ck r.error.len == 0
    ck r.port == 0
    ck r.autoAssigned

suite "a malformed environment value is refused, not ignored":
  test "a non-number names itself in the error":
    let r = resolveHostPort(-1, "eight-thousand")
    ck r.error.len > 0
    ck r.error.contains("eight-thousand")
    # NOT silently auto-assigned. A typo that fell through would leave the
    # server on a port the operator neither chose nor knows about.
    ck not r.autoAssigned

  test "a number outside the port range is refused":
    ck resolveHostPort(-1, "70000").error.len > 0
    ck resolveHostPort(-1, "-5").error.len > 0

  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
