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
##     `openTuiSession`, steps in 33 times (the `noir-declined-arm` scenario's
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
import ../../gpui/tests/plat42_gutter

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/source_binding   # re-exports `editor_surface`
import ../app/views/source_pane
import ../host/tui_session
import ./fixtures/fixture_provider

import codetracer_embed   # `Signal.val`, `EditorVM.toggleFlowOverlay`
import backend/[backend_service, stdio_backend]   # the transport under test

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  FlowScenario = "noir-declined-arm"
  MaxStepIns = 200
    ## A bound on the walk to the record's stop, not the stop: the terminal
    ## steps in until it is where the GPUI record's execution pointer is (see
    ## `recordedStop`), so the two cannot be about different stops whatever
    ## number of steps reaches it. A COUNT used to be the link
    ## (`plat42_surfaces_record.py`'s `stepIn=33`, asserted equal here), and a
    ## count is the engine's: on 2026-10-04 the engine began opening a
    ## recording in the program's entry call rather than on the trace format's
    ## `<toplevel>` entry step — for this Noir program five steps further on —
    ## and the same count reached a different stop. The record's own
    ## operations stay its provenance and are named in a checkpoint.
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
      let line = gutterLineOf(r["text"].getStr)
      if line > 0: result.add line

proc recordedStop(rec: JsonNode): tuple[line: int, code: string] =
  ## The row the GPUI record's EXECUTION POINTER is on: its line, and the
  ## program text the row drew there (gutter and inline comment dropped).
  for r in rec["flowScenarios"][FlowScenario]["rows"]:
    if r["pointer"].getStr != "eptNone":
      let text = r["text"].getStr
      result.line = gutterLineOf(text)
      var code = text
      let numberAt = code.find($result.line)
      if numberAt >= 0: code = code[numberAt + len($result.line) .. ^1]
      code = code.replace("\xC2\xA0", " ")
      let comment = code.find("/*")
      if comment >= 0: code = code[0 ..< comment]
      result.code = code.strip()
      return

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


suite "PLAT-42: the native transport hands the engine's events to its subscribers":

  test "a subscriber sees the event a request produced, delivered with its reply":
    # The flow window rides on this: `FlowVM` subscribes through
    # `BackendService.onEvent`, and until 2026-09-23 the stdio adapter
    # collected subscribers and never called one. The FLOW itself can still
    # arrive through the reply on this engine (`flow_vm`'s reply path), so the
    # case above cannot see a transport that stopped delivering; this one can.
    let resolution = resolveFixture("calc")
    if resolution.outcome == foMissingPrereq:
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      let s = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6)
      defer: s.close()
      let svc = s.session.backend.toBackendService()
      var seen: seq[string] = @[]
      svc.onEvent(proc(e: JsonNode) = seen.add e{"kind"}.getStr(""))
      let dbg = s.session.session.store.debugger.val
      discard svc.send("ct/load-calltrace-section", %*{
        "location": {"rrTicks": dbg.rrTicks.int64, "path": dbg.location.file,
                     "line": dbg.location.line},
        "startCallLineIndex": 0, "height": 10, "depth": 5,
        "rawIgnorePatterns": "", "optimizeCollapse": true,
        "autoCollapsing": false, "renderCallLineIndex": 0})
      checkpoint("delivered: " & $seen)
      ck "ct/updated-calltrace" in seen

suite "PLAT-42: the terminal draws the flow overlay GPUI drew":

  test "the declined arm is the same lines on both media, and is painted de-emphasised":
    let rec = parseJson(readFile(recordPath))
    checkpoint("the record's own operations: " &
               rec["flowScenarios"][FlowScenario]["replayOps"].getStr)
    let stop = recordedStop(rec)
    checkpoint("the record's stop: line " & $stop.line & " `" & stop.code & "`")
    ck stop.line > 0
    ck stop.code.len > 0
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

      # TO THE RECORD'S STOP, by what it is: the first stop on the line the
      # GPUI pointer is on, whose program text is the text the GPUI row drew.
      var stepIns = 0
      proc atRecordedStop(): bool =
        let line = s.session.getCurrentLine()
        line == stop.line and
          readFile(s.session.getCurrentFile()).splitLines()[line - 1].strip() ==
            stop.code
      while stepIns < MaxStepIns and not atRecordedStop():
        s.session.stepIn()
        inc stepIns
      checkpoint("reached the record's stop after " & $stepIns & " step-ins")
      ck atRecordedStop()
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
          # PLAT-46: a not-taken line's CODE is the not-taken role; an inline
          # value annotation after it keeps the annotation's own muted role.
          # Before roles both were `bright_black`, and this compared the colour.
          ck st.role in [FlowNotTakenStyle.role, AnnotationStyle.role]
      # The header ran: it keeps at least one syntax colour.
      let header = codeStylesOf(screen, model, expected[0] - 1)
      var coloured = 0
      for st in header:
        if st.role != FlowNotTakenStyle.role and st.role != srNone: inc coloured
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
          if st.role != FlowNotTakenStyle.role and st.role != srNone: inc recoloured
      ck recoloured > 0

  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
