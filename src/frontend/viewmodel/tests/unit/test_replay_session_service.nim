## Headless tests for the hook the Run path asks for a replay session through.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## ## What this suite is for
##
## An injected service that nothing installs is a call into nothing that
## returns without complaint, and that is this repository's signature defect —
## a thing that builds and is never delivered. So the subject is not "the
## service can be called" but "a caller can tell whether anything took the
## request", and the uninstalled case is asserted first in every test that
## depends on it.

import std/unittest

import ../../backend/replay_session_service

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 18

proc request(raw: string): ReplaySessionRequest =
  ReplaySessionRequest(
    rawMemoryTrace: raw, packageDir: "hello_noir", projectRoot: "/hello_noir")

suite "the Run path can ask for a replay session without knowing how to open one":

  test "with nothing installed, a request is refused rather than swallowed":
    resetReplaySessionServiceForTests()
    counted not replaySessionServiceInstalled()
    counted not requestReplaySession(request("{\"events\":[]}"))

  test "an installed service receives the request verbatim":
    resetReplaySessionServiceForTests()
    var seen: seq[ReplaySessionRequest]
    installReplaySessionService(ReplaySessionService(
      startProc: proc(r: ReplaySessionRequest) = seen.add r))
    counted replaySessionServiceInstalled()
    counted requestReplaySession(request("{\"events\":[1]}"))
    # A COUNT, because "the service was called" and "the service was called
    # once" differ by a double-open, which is two workers and two 18 MB wasm
    # instances over one store.
    counted seen.len == 1
    counted seen[0].rawMemoryTrace == "{\"events\":[1]}"
    counted seen[0].packageDir == "hello_noir"
    counted seen[0].projectRoot == "/hello_noir"

  test "a service with no startProc is not installed":
    # The half-installed case, which would otherwise pass
    # `replaySessionServiceInstalled` and then crash on a nil call.
    resetReplaySessionServiceForTests()
    installReplaySessionService(ReplaySessionService())
    counted not replaySessionServiceInstalled()
    counted not requestReplaySession(request("{}"))

  test "an empty trace is refused before the service is reached":
    # `producer.stdoutText` is cleared on the next `beginPhase`, so a request
    # built after one is an empty string — and a session opened over it would
    # report "the tracer produced no output at all" from inside a worker
    # rather than from the caller that had nothing to give it.
    resetReplaySessionServiceForTests()
    var calls = 0
    installReplaySessionService(ReplaySessionService(
      startProc: proc(r: ReplaySessionRequest) = calls += 1))
    counted not requestReplaySession(request(""))
    counted not requestReplaySession(request("   \n\t "))
    counted calls == 0
    # ...and a non-empty one still gets through, so the guard is a filter and
    # not an off switch.
    counted requestReplaySession(request("{}"))
    counted calls == 1

  test "the reset is real, so cases cannot pass on a neighbour's service":
    resetReplaySessionServiceForTests()
    counted not replaySessionServiceInstalled()
    installReplaySessionService(ReplaySessionService(
      startProc: proc(r: ReplaySessionRequest) = discard))
    counted replaySessionServiceInstalled()
    resetReplaySessionServiceForTests()
    counted not replaySessionServiceInstalled()

  test "the assertion count is measured":
    check countedAssertions == ExpectedAssertions
