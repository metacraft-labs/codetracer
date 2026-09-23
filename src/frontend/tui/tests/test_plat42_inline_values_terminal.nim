## PLAT-42 — `PLAT22-PG3` RE-MEASURED FROM A RUN: the two native editors' inline
## values, at the same stops, from one producer.
##
## Run (tui lane flags):
##   nim c -r <tui flags> src/frontend/tui/tests/test_plat42_inline_values_terminal.nim
##
## What PG3 recorded was two editors showing different data under one name.
## Re-measured on 2026-09-23 from runs rather than from source:
##
##   * the SHIPPED terminal drew NO inline value on any line — its host built
##     the source model before loading the locals and passed none;
##   * the shipped GPUI binary draws the execution line's values from
##     `editor_surface.inlineValuesOf` over `StateVM`
##     (`src/tests/visual/plat42-surfaces.json`, three stops with values);
##   * the desktop editor's recorded runs (`answers/*.electron.json`,
##     `inline-value-runs-by-line`) show no inline-value chip at any of the six
##     stops — its mid-line chips are the flow overlay's, a different feature.
##
## The host now passes `inlineValuesOf` (the producer GPUI uses) at the
## terminal's row budget. This suite drives the terminal host through the
## production `openTuiSession` / `refresh` to the SAME three stops the GPUI
## record names — the scenario operations, read from `scenarios.json` — and
## asserts the terminal's execution line carries values for EXACTLY the names
## GPUI's row carried, and draws them; and at a stop whose line names nothing
## in scope, that nothing is drawn. Names, not text: the two media present a
## value at their own row budget, so `05 07 2a…` on one and a narrower form on
## the other are one value, twice.
##
## No mocks: a real replay-server, the real `calc` recording, the production
## host, and a committed record of the shipped GPUI binary.

import std/[json, os, strutils, tables, unittest]

import codetracer_embed
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/source_binding
import ../app/views/source_pane
import ../host/tui_session
import ./fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 160
  Rows = 48
  ValueScenarios = ["advanced-state", "returned-calltrace",
                    "continued-event-log"]
  QuietScenario = "stepped-editor"
    ## A stop whose execution line names nothing in scope — the GPUI record
    ## carries no value on it.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc gpuiExecRow(sid: string): JsonNode =
  let rec = parseJson(readFile(repo / "src/tests/visual/plat42-surfaces.json"))
  for r in rec["scenarios"][sid]["rows"]:
    if r["pointer"].getStr == "eptExecution":
      return r
  nil

proc gpuiNames(row: JsonNode): seq[string] =
  ## `data-ct-values` is `name=value|name=value`.
  for part in row["values"].getStr.split('|'):
    if part.len > 0:
      result.add part.split('=', maxsplit = 1)[0]

proc lineOfRow(row: JsonNode): int =
  var digits = ""
  for ch in row["text"].getStr:
    if ch.isDigit: digits.add ch
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc drive(s: TuiSession; sid: string) =
  ## The scenario's own operations, read from the file the GPUI record and
  ## the Electron capture were taken from.
  let scen = parseJson(readFile(repo / "src/tests/visual/scenarios.json"))
  for sc in scen["scenarios"]:
    if sc["id"].getStr != sid: continue
    for op in sc["operations"]:
      let times = if op.hasKey("times"): op["times"].getInt else: 1
      for _ in 0 ..< times:
        case op["kind"].getStr
        of "stepIn": s.session.stepIn()
        of "next": s.session.stepForward()
        of "stepOut": s.session.stepOut()
        of "continueForward": s.session.continueForward()
        else: discard

suite "PLAT-42: PG3 re-measured — one producer, two native editors":

  test "the host passes the SHARED producer, not raw variables":
    let src = readFile(repo / "src/frontend/tui/host/tui_session.nim")
    ck "inlineValues = inlineValuesOf(s.state, tuiRowBudget(" in src
    # …and it loads the locals BEFORE building the source model.
    ck src.find("s.session.requestAndLoadLocals()") <
       src.find("rt.app.source = sourcePaneModelFor(")

  let resolution = resolveFixture("calc")
  for sid in @ValueScenarios & @[QuietScenario]:
    test "at " & sid & ": the terminal draws exactly the names GPUI drew":
      if resolution.outcome == foMissingPrereq:
        let message = missingPrereqMessage(resolution.spec, resolution.detail)
        echo "  ", message
        ck message.startsWith(MissingPrereqSkipPrefix)
        skip()
      else:
        let gpuiRow = gpuiExecRow(sid)
        ck not gpuiRow.isNil
        let want = gpuiNames(gpuiRow)
        let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
        let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6)
        defer: s.close()
        s.setViewportHeight(rt.sourcePaneRows())
        s.drive(sid)
        s.refresh(rt)
        let model = rt.app.source
        # The same stop on both media.
        ck model.executionLine == lineOfRow(gpuiRow)
        let lineText = model.heldTextAt(model.executionLine)
        var got: seq[string] = @[]
        for a in annotationsForLine(lineText, model.values):
          got.add a.name
        checkpoint(sid & " terminal=" & $got & " gpui=" & $want)
        ck got == want
        # …and the terminal DRAWS them on the execution line — or draws
        # nothing there when there is nothing.
        let screen = sourcePaneScreen(model, Cols, Rows)
        let row = 1 + model.executionLine - model.viewportTop
        let painted = rowText(screen.rows[row])
        checkpoint(painted)
        if want.len > 0:
          ck ("/* " & want[0] & ": ") in painted
        else:
          ck "/* " notin painted

suite "PLAT-42 PG3 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
