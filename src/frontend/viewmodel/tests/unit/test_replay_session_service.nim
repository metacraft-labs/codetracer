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

const ExpectedAssertions = 36

proc hostWithSecondSession(): bool = true
proc hostWithoutSecondSession(): bool = false
  ## Named rather than written inline at each call site: a `proc(): bool =
  ## false` inside a constructor argument list is where Nim's parser wants a
  ## block, and the error it gives names an indentation problem four lines from
  ## the actual one.

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

  test "a new session tab is a REQUEST, and a refusal opens nothing":
    # §9.1 wants two tests open in two tabs. This host holds one live session —
    # `web_replay_host.openSession` terminates any previous engine, because two
    # engines answering one store would interleave two recordings into one
    # timeline — so the request is refused BY NAME.
    #
    # THE ASSERTION THAT MATTERS IS `seen.len == 0`. Falling back to the current
    # tab would answer a different question than the one asked and destroy the
    # session the user wanted to keep beside this one, which is the entire
    # reason they asked for a new tab. A refusal that opened something anyway
    # would satisfy every other check here.
    resetReplaySessionServiceForTests()
    var seen: seq[ReplaySessionRequest]
    installReplaySessionService(ReplaySessionService(
      # PARENTHESISED. Without them the `,` is read as another argument to
      # `seen.add`, and the next field is swallowed into the proc body — the
      # error names a type mismatch inside `add`, four lines from the cause.
      startProc: (proc(r: ReplaySessionRequest) = seen.add r),
      canOpenSecondSession: hostWithoutSecondSession))
    counted not canOpenSecondReplaySession()

    var wanted = request("{\"events\":[1]}")
    wanted.newSessionTab = true
    counted openReplaySession(wanted) == rsoNoSecondSession
    counted seen.len == 0

    # CONTROL: the same trace WITHOUT the new-tab request opens. So the refusal
    # is about the tab and not about the service being broken.
    counted openReplaySession(request("{\"events\":[1]}")) == rsoOpened
    counted seen.len == 1
    counted not seen[0].newSessionTab

    # MIRROR: a host that CAN hold a second session gets the request through
    # unchanged, so this vocabulary is not a permanent no.
    resetReplaySessionServiceForTests()
    var seen2: seq[ReplaySessionRequest]
    installReplaySessionService(ReplaySessionService(
      startProc: (proc(r: ReplaySessionRequest) = seen2.add r),
      canOpenSecondSession: hostWithSecondSession))
    counted canOpenSecondReplaySession()
    counted openReplaySession(wanted) == rsoOpened
    counted seen2.len == 1
    counted seen2[0].newSessionTab

    # A service with no predicate has not ESTABLISHED that it can, so it
    # cannot. Nil is read as no in both directions.
    resetReplaySessionServiceForTests()
    installReplaySessionService(ReplaySessionService(
      startProc: proc(r: ReplaySessionRequest) = discard))
    counted not canOpenSecondReplaySession()
    counted openReplaySession(wanted) == rsoNoSecondSession

  test "the outcome vocabulary tells the four answers apart":
    # `bool` collapsed three different states into `false`, and a caller shows
    # different things for them: no host at all, nothing to open, and a tab
    # that could not be made.
    resetReplaySessionServiceForTests()
    counted openReplaySession(request("{\"events\":[1]}")) == rsoNoHost
    installReplaySessionService(ReplaySessionService(
      startProc: (proc(r: ReplaySessionRequest) = discard),
      canOpenSecondSession: hostWithSecondSession))
    counted openReplaySession(request("")) == rsoEmptyTrace
    counted openReplaySession(request("   \n\t ")) == rsoEmptyTrace
    counted openReplaySession(request("{}")) == rsoOpened
    # And the two-valued form still agrees with it, so the older callers that
    # only ask "did a debugger open" cannot drift from this.
    counted requestReplaySession(request("{}"))
    counted not requestReplaySession(request(""))

  test "the assertion count is measured":
    check countedAssertions == ExpectedAssertions
