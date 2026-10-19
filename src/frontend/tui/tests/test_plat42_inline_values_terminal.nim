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
import ../../gpui/tests/plat42_gutter

import codetracer_embed
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/source_binding
import ../app/views/source_pane
import ../host/tui_session
import ./fixtures/fixture_provider
import ../../viewmodel/editor/[inlay, row_projection, wrap]

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
  gutterLineOf(row["text"].getStr)

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
    # The shared producer, at this medium's budget — handed to the pane
    # through PLAT-29's stop reconciliation since 2026-09-23.
    ck "inlineValuesOf(s.state, tuiRowBudget(" in src
    ck "s.valueGate.installable(" in src
    ck "inlineValues = values)" in src
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

suite "PLAT-28: REAL inline values, placed by the inlay model":
  ## PLAT-28's real-stack box: *"A real recording, stepped, with inline values
  ## from the real value-presentation pipeline placed on real source lines —
  ## not constructed `EditorValue`s."* The recording is `calc`, driven to a
  ## scenario stop through the real `replay-server`; the values are the ones
  ## the shipped host hands the source pane (`inlineValuesOf` at the terminal's
  ## row budget), on the line the debugger stopped at. They go through
  ## `decorationsForRow` — the encoding both editor surfaces now use — and
  ## `inlay.inlayWrapCache`, and the claim §8.3 makes is asserted on them: an
  ## inline value OCCUPIES COLUMNS, so it widens its line by exactly its cells
  ## and moves the wrap point where the plain line would not wrap.

  let resolution = resolveFixture("calc")
  test "at " & ValueScenarios[0] & ": the stop's own values widen the line and move the wrap":
    if resolution.outcome == foMissingPrereq:
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6)
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      s.drive(ValueScenarios[0])
      s.refresh(rt)
      let model = rt.app.source
      let lineText = model.heldTextAt(model.executionLine)
      var vs: seq[EditorValue] = @[]
      for a in annotationsForLine(lineText, model.values):
        vs.add EditorValue(name: a.name, value: a.value)
      checkpoint("line " & $model.executionLine & ": " & lineText & " " & $vs)
      ck vs.len > 0
      let doc = lineText & "\n"
      let ds = decorationSet(decorationsForRow(
        emNone, eptExecution, efsUnknown, vs, 0, lineText.len, 0))
      let policy = ColumnPolicy(tabSize: 4, ambiguous: awNarrow)
      var widgetCells = 0
      for v in vs: widgetCells += valueWidth(v)
      let unbounded = WrapSettings(wrapColumn: 0, policy: policy)
      let lineWidth = initWrapCache(doc, unbounded).metricsOf(0).width
      # THE VALUES OCCUPY COLUMNS: the decorated line is wider by exactly them.
      ck inlayWrapCache(doc, unbounded, ds).metricsOf(0).width ==
         lineWidth + widgetCells
      # AND THEY MOVE THE WRAP POINT: at a column the plain line fits in
      # exactly, the decorated one takes a second row.
      let settings = WrapSettings(wrapColumn: lineWidth + widgetCells - 1,
                                  policy: policy)
      let plain = initWrapCache(doc, settings)
      let deco = inlayWrapCache(doc, settings, ds)
      ck plain.rowsInLine(0) == 1
      ck deco.rowsInLine(0) == 2
      # …and the text before them is where it was.
      ck deco.rowAt(0).width >= lineWidth

suite "PLAT-42 PG3 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
