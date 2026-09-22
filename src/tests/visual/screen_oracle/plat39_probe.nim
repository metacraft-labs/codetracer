## PLAT-39 — a runnable probe, not a gate.
##
## Reads every pinned frame and prints what came back, so a human can look at
## the oracle's output next to the screenshots. Also re-derives the two
## published thresholds (`OcrConfidenceFloor`, `GutterMedianThreshold`) over
## the current corpus and prints the candidate table, which is what makes them
## §36b parameters with visible losers rather than constants with a story.
##
## NOT-A-CI-GATE: this prints; it does not assert. The assertions live in
## `test_screen_oracle.nim`.

import std/[os, strformat, strutils]
import gui_assert/image_math
import ./screen_reading
import ./domain_models
import ./pane_grammar
import ./region_locator
import ./vision_producer

const Scenarios = ["entry-shell", "stepped-editor", "advanced-state",
                   "returned-calltrace", "continued-event-log",
                   "breakpoint-editor"]

proc main() =
  let root = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
  let capDir = root / "src/tests/visual/captures/electron"
  let scratch = getEnv("TMPDIR", "/tmp") / "plat39-probe"
  createDir(scratch)

  let (unavailable, why) = detectElementsIsUnavailable()
  echo "detectElements(ebOmniParser) unavailable: ", unavailable
  echo "  reason: ", why.splitLines()[0]
  echo ""

  for s in Scenarios:
    let path = capDir / (s & ".png")
    let r = readFrame(path, scratch)
    echo &"=== {s}  ({r.width}x{r.height}) ==="
    var ids: seq[string]
    for p in r.panes:
      if p.id != piOther and p.id != piUnknown:
        ids.add $p.id & "@" & $p.rect
    echo "  panes identified: ", ids.join("  ")
    echo "  cells located:    ", r.panes.len

    case r.programState.kind
    of srRead:
      echo &"  ProgramState: READ {r.programState.value.variableStates.len} vars"
      for v in r.programState.value.variableStates:
        echo &"      {v.name:<16} type={v.valueType:<10} value={v.value[0 .. min(44, v.value.high)]}"
    of srEmpty: echo "  ProgramState: EMPTY"
    of srUnreadable: echo "  ProgramState: ", describe(r.programState)

    case r.eventLog.kind
    of srRead:
      echo &"  EventLog: READ events={r.eventLog.value.events.len} ofRows={r.eventLog.value.ofRows}"
      for e in r.eventLog.value.events[0 .. min(2, r.eventLog.value.events.high)]:
        echo "      ", e.consoleOutput
    of srEmpty: echo "  EventLog: EMPTY"
    of srUnreadable: echo "  EventLog: ", describe(r.eventLog)

    case r.editor.kind
    of srRead:
      echo &"  Editor: READ highlighted={r.editor.value.higlitedLineNumber}"
    of srEmpty: echo "  Editor: EMPTY"
    of srUnreadable: echo "  Editor: ", describe(r.editor)
    echo ""

when isMainModule:
  main()
