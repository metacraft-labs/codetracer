## host_bind_test.nim
##
## WHICH INTERFACE `ct host` ASKS FOR, and where that answer comes from.
##
## `CLI/ct/host.md` documents `--bind <addr>`, `CODETRACER_HOST_BIND` and a
## default of `127.0.0.1`. Three sources means a precedence, and a precedence
## that is only ever exercised by hand is one nobody notices reversing.
##
## `resolveHostBind` is the whole of that decision — `hostCommand` calls it
## once and forwards the result to the Electron main process as `--bind`. That
## the forwarded value is then actually BOUND, rather than printed and
## discarded, is the separate claim `src/frontend/tests/
## index_server_binds_loopback_test.nim` makes by connecting to the running
## server from this host's own routable address. Neither suite is sufficient
## alone: this one cannot see a listener, and that one cannot see the CLI.
##
## Lane: `ct-trace-units` (discovered by `src/ct/trace/*_test.nim`).

import
  std/unittest,
  ./host

# THE TALLY IS PART OF THE SUITE, not decoration: a `test` block that asserts
# nothing still prints one `[OK]`, so the lane's case count cannot tell a live
# suite from a gutted one. `ExpectedAssertions` is what makes deleting a check
# a red build rather than a quieter green one.
const ExpectedAssertions = 12
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

suite "ct host bind resolution":
  test "nothing said anywhere is loopback":
    ck resolveHostBind("", "") == "127.0.0.1"
    ck resolveHostBind("", "") == DefaultHostBind

  test "the environment widens the default":
    ck resolveHostBind("", "0.0.0.0") == "0.0.0.0"
    ck resolveHostBind("", "::") == "::"

  test "the flag outranks the environment":
    # The case the precedence exists for: a shell profile exports the wide
    # value, and one invocation takes it back.
    ck resolveHostBind("127.0.0.1", "0.0.0.0") == "127.0.0.1"
    ck resolveHostBind("10.0.0.5", "0.0.0.0") == "10.0.0.5"

  test "whitespace-only is absence, not an address":
    # `CODETRACER_HOST_BIND=` and `CODETRACER_HOST_BIND=" "` both mean the
    # variable is not really set; handing either to `listen` would fail with
    # an errno rather than fall back.
    ck resolveHostBind("   ", "") == "127.0.0.1"
    ck resolveHostBind("", "  ") == "127.0.0.1"
    ck resolveHostBind(" \t ", " \n ") == "127.0.0.1"

  test "surrounding whitespace is stripped, not rejected":
    ck resolveHostBind(" 0.0.0.0 ", "") == "0.0.0.0"
    ck resolveHostBind("", "\t192.168.1.2\n") == "192.168.1.2"

  test "a malformed address is passed through, not silently defaulted":
    # Deliberate. Swallowing it would bind loopback while the operator
    # believes they asked for something else; passing it through makes the
    # bind fail and name the address.
    ck resolveHostBind("not-an-address", "") == "not-an-address"

  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
