## test_move_in_flight_badge.nim — the top bar's status badge while a move is
## in flight (CodeTracer-TUI §3.3.1's statuses).
##
## A move blocks the terminal's loop until the replay answers, so the host
## paints one frame just before the move is sent: the badge then reads
## STEPPING / REVERSING / SEEKING instead of PAUSED over a stop the replay is
## leaving. These cases pin the three pieces the host builds that frame from:
##
##   * `statusWhileMoving` — which badge a move gets;
##   * `TuiApp.replayStatus` is what the header draws (`shellModel`);
##   * `TuiRuntime.moveStarting` is called once per move, BEFORE the move
##     reaches the engine (the engine still reports the old tick), for a key
##     and for a `:command` alike, and never for a token that does not move.
##
## No mocks: the recording (`calc`), the replay server and the session are
## the real ones (`fixtures/fixture_provider`). The `moveStarting` closure is
## the host's seam, captured here the way `main.nim` installs it — the one
## stand-in, and it is not a mock: it records the call the product makes and
## does what the host does (set the badge).

import std/[strutils, unittest]

import codetracer_embed
import backend/stdio_backend   # `DapReadBound`
import ../app/runtime
import ../app/tui_app
import ../app/views/shell
import ../app/theme/capabilities
import ../host/tui_session
import ./fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 160
  Rows = 48

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken("\r", 0'i64)

proc badge(app: TuiApp): string =
  let h = headerText(app.shellModel(Cols, Rows).header, Cols)
  h[h.rfind('[') .. ^1].strip()

suite "the move-in-flight badge":

  test "each move names what the replay is doing":
    ck statusWhileMoving(kaStepOver) == esStepping
    ck statusWhileMoving(kaStepInto) == esStepping
    ck statusWhileMoving(kaContinue) == esStepping
    ck statusWhileMoving(kaReverseStepOver) == esReversing
    ck statusWhileMoving(kaReverseContinue) == esReversing
    ck statusWhileMoving(kaSeekToTick) == esSeeking
    ck statusWhileMoving(kaJumpToEnd) == esSeeking
    ck statusWhileMoving(kaHistoryBack) == esSeeking

  test "the header draws the application's replay status":
    let app = newTuiApp()
    ck app.replayStatus == esPaused
    ck app.badge == "[PAUSED]"
    app.replayStatus = esStepping
    ck app.badge == "[STEPPING]"
    app.replayStatus = esReversing
    ck app.badge == "[REVERSING]"

  let resolution = resolveFixture("calc")

  test "a move is announced before it reaches the engine, a non-move never":
    if resolution.outcome == foMissingPrereq:
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6,
                             bound = DapReadBound(timeoutMs: 60_000,
                                                  interruptFd: -1))
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      s.refresh(rt)
      var calls: seq[(KeyAction, uint64, string)] = @[]
      rt.moveStarting = proc(action: KeyAction) =
        rt.app.replayStatus = statusWhileMoving(action)
        calls.add (action, s.session.getCurrentRRTicks(), rt.app.badge)

      # --- a :command that moves ---------------------------------------------
      let before = s.session.getCurrentRRTicks()
      let moved = rt.typeLine("next")
      ck moved.awaitsMove
      ck moved.action == kaStepOver
      checkpoint("calls: " & $calls)
      ck calls.len == 1
      ck calls[0][0] == kaStepOver
      # announced while the engine was still at the old stop
      ck calls[0][1] == before
      ck calls[0][2] == "[STEPPING]"
      s.applyOutcome(rt, moved)
      rt.app.replayStatus = esPaused
      ck s.session.getCurrentRRTicks() != before
      ck rt.app.badge == "[PAUSED]"

      # --- a :command that does not move ------------------------------------
      calls.setLen 0
      let other = rt.typeLine("break 1")
      s.applyOutcome(rt, other)
      ck not other.awaitsMove
      ck calls.len == 0

suite "the move-in-flight badge — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
