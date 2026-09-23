## PLAT-42 — the flow overlay on the TERMINAL, compared with what the shipped
## GPUI binary drew at the same stop.
##
## Run:
##   nim c -r src/frontend/tui/tests/test_plat42_flow_overlay_terminal.nim
##
## `PLAT22-PG2` said neither native editor could draw the flow overlay because
## the ViewModel had no per-line fact. It now has one — `FlowVM.styledLines` —
## and this suite is the terminal's half of the evidence that both media draw
## it from that one fact:
##
##   * it opens the real `noir_space_ship` recording through the production
##     `openTuiSession`, steps in 15 times (the `noir-declined-arm` scenario's
##     own operations), and calls the production `refresh`;
##   * the lines the terminal's source-pane MODEL marks not-taken must equal
##     the lines the GPUI binary's render plan marked `efsNotTaken` in
##     `src/tests/visual/plat42-surfaces.json` — two front-ends, no shared
##     rendering code, one stop;
##   * the PAINTED rows for those lines carry the de-emphasised style and no
##     syntax colour, while the arm's header — which ran — keeps its colours;
##   * NEGATIVE TWIN: with the overlay toggled off through `EditorVM`, the
##     same stop paints those lines in syntax colour again.
##
## NO MOCKS. A real `replay-server`, a real recording, the production host.
## When the recording cannot be produced the skip is LOUD and counted
## (`fixture_provider`'s rule), never a green run over nothing.

import std/[json, os, strutils, unittest]

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/source_binding   # re-exports `editor_surface`
import ../app/views/source_pane
import ../host/tui_session
import ./fixtures/fixture_provider

import codetracer_embed   # `Signal.val`, `EditorVM.toggleFlowOverlay`

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  FlowScenario = "noir-declined-arm"
  StepIns = 15
    ## `plat42_surfaces_record.py`'s `FLOW_SCENARIOS` spells this
    ## `stepIn=15`; the case below asserts the record says the same, so the two
    ## cannot silently be about different stops.
  Cols = 120
  Rows = 40

let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repoRoot / "src/tests/visual/plat42-surfaces.json"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc gpuiNotTaken(rec: JsonNode): seq[int] =
  ## The lines GPUI marked not-taken, by the gutter number in the row's text.
  for r in rec["flowScenarios"][FlowScenario]["rows"]:
    if r["flow"].getStr == "efsNotTaken":
      var digits = ""
      for ch in r["text"].getStr:
        if ch.isDigit: digits.add ch
        else: break
      if digits.len > 0: result.add parseInt(digits)

proc codeStylesOf(screen: SourcePaneScreen; model: SourcePaneModel;
                  line: int): seq[CellStyle] =
  ## The styles of every non-blank span in `line`'s CODE column.
  let rowIndex = 1 + line - model.viewportTop   # row 0 is the title
  if rowIndex < 1 or rowIndex >= screen.rows.len:
    return @[]
  var at = 0
  for span in screen.rows[rowIndex]:
    if at >= screen.gutterWidth and span.text.strip().len > 0:
      result.add span.style
    at += cellWidthOf(span.text)

suite "PLAT-42: the terminal draws the flow overlay GPUI drew":

  test "the declined arm is the same lines on both media, and is painted de-emphasised":
    let rec = parseJson(readFile(recordPath))
    ck rec["flowScenarios"][FlowScenario]["replayOps"].getStr == "stepIn=" & $StepIns
    let expected = gpuiNotTaken(rec)
    checkpoint("GPUI's not-taken lines: " & $expected)
    ck expected.len > 0

    let resolution = resolveFixture("noir_space_ship")
    if resolution.outcome == foMissingPrereq:
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      # The record must be about THIS recording, or the comparison is between
      # two programs.
      ck resolution.tracePath.lastPathPart == rec["flowTrace"].getStr

      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6)
      defer: s.close()
      s.setViewportHeight(rt.sourcePaneRows())
      s.refresh(rt)
      # The product default reached the host.
      ck s.session.session.editorVM.showFlowOverlay.val == FlowOverlayShownByDefault

      for _ in 0 ..< StepIns:
        s.session.stepIn()
      s.refresh(rt)

      let model = rt.app.source
      checkpoint("terminal's not-taken lines: " & $model.notTakenLines)
      ck model.notTakenLines == expected

      let screen = sourcePaneScreen(model, Cols, Rows)
      for line in expected:
        let styles = codeStylesOf(screen, model, line)
        checkpoint("line " & $line & " styles: " & $styles)
        ck styles.len > 0
        for st in styles:
          ck st.fg == FlowNotTakenStyle.fg
      # The header ran: it keeps at least one syntax colour.
      let header = codeStylesOf(screen, model, expected[0] - 1)
      var coloured = 0
      for st in header:
        if st.fg != FlowNotTakenStyle.fg and st.fg.len > 0: inc coloured
      ck coloured > 0

      # NEGATIVE TWIN — the overlay hidden, the same stop.
      s.session.session.editorVM.toggleFlowOverlay()
      s.refresh(rt)
      let hidden = rt.app.source
      ck hidden.notTakenLines.len == 0
      let hiddenScreen = sourcePaneScreen(hidden, Cols, Rows)
      var recoloured = 0
      for line in expected:
        for st in codeStylesOf(hiddenScreen, hidden, line):
          if st.fg != FlowNotTakenStyle.fg and st.fg.len > 0: inc recoloured
      ck recoloured > 0

  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
