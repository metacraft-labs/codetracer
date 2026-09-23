## PLAT-42 — PER-LINE STATUS ON THE SHIPPED TERMINAL: `:break` reaches the
## engine and the gutter marks what the engine verified.
##
## Run (tui lane flags):
##   nim c -r <tui flags> src/frontend/tui/tests/test_plat42_line_status_terminal.nim
##
## Measured on 2026-09-23, before this suite: the shipped terminal answered
## `:break` and `F9` with *"no breakpoint service is wired"* —
## `CommandServices.setBreakpoint` had no production value — and its host
## passed no points to the source pane, so `ecLineStatus` was `esRendered` on a
## surface nothing a user ran could fill. The host now toggles through the
## engine's `setBreakpoints` and keeps the lines the ENGINE VERIFIED.
##
## Every case goes through the product's own path: `:`, the characters and
## `Enter` as tokens into `handleToken`, then `TuiSession.applyOutcome` — the
## rule `main.nim` runs — then the painted pane. Asserted:
##
##   * the outcome refreshes WITHOUT pumping for a move (a pump there waits on
##     a `stopped` event no engine sends — the `:` path pumped after ANY
##     `drDone` until this suite, which `:break` succeeding would have hung);
##   * the gutter marks the engine-verified line and NO OTHER ROW — the
##     negative twin a renderer that marks every row fails;
##   * a second breakpoint keeps the first (DAP's `setBreakpoints` replaces
##     the source's whole set, so a toggle that sent one line would clear the
##     other on the engine while the gutter still drew it);
##   * toggling a line again clears it and only it;
##   * the ENGINE holds the set: `c` stops on a marked line.
##
## No mocks: a real replay-server, the real `calc` recording, the production
## host and runtime.

import std/[os, strutils, unittest]

import codetracer_embed
import backend/stdio_backend   # `DapReadBound`, the product's read clock
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/source_binding
import ../app/views/source_pane
import ../app/views/gutter
import ../host/tui_session
import ./fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 160
  Rows = 48
  PumpClockMs = 60_000
    ## Per message. A real move on `calc` answers in well under a second.
  StepsToFirstStop = 6
    ## `scenarios.json`'s `stepped-editor`: calc stopped inside a function
    ## body, on a line that ran — so the engine has a step to bind to.

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  ## `:`, every character, `Enter` — one token at a time, as a terminal's
  ## bytes arrive.
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken("\r", 0'i64)

proc markedRows(rt: TuiRuntime): seq[int] =
  ## The source lines whose PAINTED gutter carries the breakpoint glyph.
  let model = rt.app.source
  let screen = sourcePaneScreen(model, Cols, Rows)
  for i in 1 ..< screen.rows.len:
    let text = rowText(screen.rows[i])
    let gutterText = text[0 ..< min(text.len, screen.gutterWidth + 4)]
    if BreakpointGlyph in gutterText:
      result.add model.viewportTop + i - 1

suite "PLAT-42: per-line status on the shipped terminal":

  let resolution = resolveFixture("calc")

  test ":break reaches the engine, and the gutter marks what it verified":
    if resolution.outcome == foMissingPrereq:
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      # THE PRODUCT'S OWN READ CLOCK (CTUI-14), so a pump that waits for a
      # `stopped` event no engine sends — the defect `awaitsMove` exists to
      # prevent after `:break` — fails this case instead of hanging the lane.
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6,
                             bound = DapReadBound(timeoutMs: PumpClockMs,
                                                  interruptFd: -1))
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      s.refresh(rt)
      for _ in 0 ..< StepsToFirstStop:
        s.session.stepIn()
      s.refresh(rt)
      let here = rt.app.source.executionLine
      checkpoint("stopped on line " & $here)
      ck here > 0
      # Nothing is marked before anything is set.
      ck rt.markedRows().len == 0

      # --- one breakpoint, on the line that ran ------------------------------
      let first = rt.typeLine("break " & $here)
      checkpoint("status: " & first.detail)
      ck first.action == kaToggleBreakpoint
      ck not first.awaitsMove
      ck first.refreshesSession
      ck "breakpoint at" in first.detail
      s.applyOutcome(rt, first)
      ck s.points.len == 1
      let bound = s.points[0].line
      ck bound >= 1
      ck rt.app.source.markFor(bound) == gmBreakpoint
      # THE TWIN: the glyph is on the verified line and on no other row.
      ck rt.markedRows() == @[bound]

      # --- a second one keeps the first -------------------------------------
      # A later line of the same file: the first line after `bound` whose
      # engine binding lands somewhere other than `bound`.
      var second = -1
      for candidate in bound + 1 .. bound + 40:
        let o = rt.typeLine("break " & $candidate)
        s.applyOutcome(rt, o)
        if s.points.len == 2:
          second = candidate
          break
        if s.points.len != 1:
          break
      checkpoint("points: " & $s.points)
      ck second > 0
      ck s.points.len == 2
      var lines: seq[int] = @[]
      for p in s.points: lines.add p.line
      ck bound in lines
      let marked = rt.markedRows()
      checkpoint("marked rows: " & $marked)
      ck marked.len == 2
      for l in lines: ck l in marked

      # --- the ENGINE holds both: continue stops on one of them -------------
      let moved = rt.handleToken("c", 0'i64)
      ck moved.awaitsMove
      s.applyOutcome(rt, moved)
      checkpoint("continued to line " & $rt.app.source.executionLine)
      ck rt.app.source.executionLine in lines

      # --- toggling clears exactly the one named -----------------------------
      let cleared = rt.typeLine("break " & $bound)
      s.applyOutcome(rt, cleared)
      ck s.points.len == 1
      ck s.points[0].line != bound
      ck rt.markedRows() == @[s.points[0].line]

  test "the command path pumps only for a navigation":
    # The rule itself, for every action the interpreter can answer `drDone`
    # for without moving: none of them may be pumped.
    for a in KeyAction:
      if changesSessionState(a):
        ck not movesTheDebugger(a)
    ck changesSessionState(kaToggleBreakpoint)
    ck movesTheDebugger(kaContinue)

suite "PLAT-42 line status — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
