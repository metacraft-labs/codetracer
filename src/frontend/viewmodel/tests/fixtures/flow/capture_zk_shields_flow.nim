## Capture a REAL `ct/load-flow` window from the `zk_shields` Noir recording,
## for `tests/unit/test_flow_layout.nim` to run the layout over.
##
## Why a captured fixture rather than a hand-written one
## -----------------------------------------------------
## `viewmodels/flow_layout.nim` is the placement half of Omniscience, extracted
## out of `ui/flow.nim`. A hand-written window can be made to agree with
## whatever the extraction happens to do; a recorded one cannot. `zk_shields`
## exercises the parts that are hardest to invent: a `for` loop
## (`shield.nr:4..15`) whose body mutates `remaining_shield` with `-=` and `+=`,
## so before/after values genuinely differ and all three of the spec's value
## modes occur; 80 calls at depth 3; and a loop window that carries
## `rrTicksForIterations`, `loopIterationSteps` and `positionStepCounts` in the
## exact shape the Rust backend serialises them.
##
## This is a GENERATOR, not a test. No lane picks it up (`vm-unit` discovers
## `tests/unit/test_*.nim`, `vm-native` discovers `src/tests/gui/tests/*_test.nim`),
## and it needs a built `replay-server`, which is why the suite reads its
## committed output instead of running it.
##
## Two things about the DAP exchange are worth writing down, because both cost
## an hour to discover and neither is documented anywhere else:
##
##   1. **`FlowMode` goes on the wire as a NUMBER.** It is `Serialize_repr` in
##      `db-backend/src/task.rs`, so `Call` is `0`. Sending the Nim enum's
##      spelling is accepted as a request and answered with a window for the
##      wrong location — which is the arg mismatch `viewmodels/flow_vm.nim`'s
##      header records the backend rejecting.
##   2. **The real window arrives as a `ct/updated-flow` EVENT**, not in the
##      response; the response carries a placeholder. Events queue, so the queue
##      has to be drained before the request or `waitForEvent` hands back a
##      window computed for an earlier position.
##
## Usage:
##   nim c -r --path:src/frontend/viewmodel --path:src/frontend --path:src \
##     src/frontend/viewmodel/tests/fixtures/flow/capture_zk_shields_flow.nim \
##     --trace:$HOME/.local/share/codetracer/<id> \
##     --replay-server:<path to replay-server>
##
## It writes `zk_shields_flow_window.json` beside itself: the raw
## `viewUpdates[0]` of the event, the debugger position it was requested for,
## and the source of the file the window belongs to. Nothing is normalised or
## trimmed — the point of the fixture is that it is what the backend really
## sends.

import std/[json, os, strutils]

import headless_session
import backend/stdio_backend

const
  LoopBodyLine = 7
    ## `remaining_shield -= damage;` — inside the `for i in 0..8` loop of
    ## `iterate_asteroids`. Breaking here and continuing puts the debugger in a
    ## pass of the loop that is NOT the first, which is the position #593 got
    ## wrong and therefore the one worth capturing.
  PassesToSkip = 4
    ## How many breakpoint hits to run past before capturing. Deep enough that
    ## `activeIterationForTicks` must do real work; shallow enough that the
    ## fixture stays small.

proc argValue(name: string): string =
  for i in 1 .. paramCount():
    let p = paramStr(i)
    if p.startsWith(name & ":") or p.startsWith(name & "="):
      return p[name.len + 1 .. ^1]
  ""

proc main() =
  let tracePath = argValue("--trace")
  let replayServer = argValue("--replay-server")
  if tracePath.len == 0 or replayServer.len == 0:
    quit("usage: capture_zk_shields_flow --trace:DIR --replay-server:BIN", 2)
  if not fileExists(replayServer):
    quit("replay-server not found: " & replayServer, 2)
  if not dirExists(tracePath):
    quit("trace directory not found: " & tracePath, 2)

  echo "trace:         ", tracePath
  echo "replay-server: ", replayServer

  let session = newHeadlessDebugSession(tracePath, replayServer)
  defer: session.close()

  let entryFile = session.getCurrentFile()
  echo "entry:         ", entryFile, ":", session.getCurrentLine()
  let shieldPath = entryFile.parentDir / "shield.nr"
  if not fileExists(shieldPath):
    quit("shield.nr not found next to the entry file: " & shieldPath, 1)

  session.setBreakpoint(shieldPath, LoopBodyLine)
  for _ in 0 ..< PassesToSkip:
    session.continueForward()
  echo "stopped:       ", session.getCurrentFile(), ":",
    session.getCurrentLine(), " ticks=", session.getCurrentRRTicks()

  let move = session.lastCompleteMoveEvent
  if move.isNil or not move.hasKey("body"):
    quit("no ct/complete-move observed", 1)
  let location = move["body"].getOrDefault("location")
  if location.isNil or location.kind != JObject:
    quit("ct/complete-move carried no location", 1)

  # See the header: drain first, ask with `flowMode: 0`, take the event.
  discard session.drainEvents()
  discard session.sendRawDapRequest("ct/load-flow", %*{
    "flowMode": 0,
    "location": location,
  })
  let event = session.backend.waitForEvent("ct/updated-flow", maxMessages = 120)
  let view = event["body"]["viewUpdates"][0]

  var realIterations = 0
  for index in 1 ..< view["loops"].len:
    let ticks = view["loops"][index].getOrDefault("rrTicksForIterations")
    if not ticks.isNil and ticks.kind == JArray and ticks.len > realIterations:
      realIterations = ticks.len
  if realIterations <= 1:
    quit("the captured window carries no real loop — the fixture would be " &
      "useless for the loop cases", 1)

  echo "window:        ", view["steps"].len, " steps, ",
    view["loops"].len, " loops, ", realIterations, " iteration headers"

  # ONE field is dropped, and this is the whole of the difference between the
  # fixture and what the backend sent: `FlowStep.originSummaries`.
  #
  # It is Value-Origin-Tracking's per-variable summary, and on this recording
  # every entry is a placeholder whose `placeholderToken` is a base64 blob
  # embedding a step id, a pattern fingerprint and an issue time. It is 150 KB
  # of the 210 KB window, it is not read by anything in `flow_layout.nim` — the
  # layer places values, it does not resolve their origins — and the tokens
  # would make the fixture churn on every recapture for reasons that have
  # nothing to do with layout. Everything a placement decision reads
  # (`position`, `loop`, `iteration`, `stepCount`, `rrTicks`, `exprOrder`,
  # `beforeValues`, `afterValues`, and the whole of `loops`,
  # `loopIterationSteps` and `positionStepCounts`) is untouched.
  for step in view["steps"]:
    if step.kind == JObject and step.hasKey("originSummaries"):
      step.delete("originSummaries")

  let doc = %*{
    "_provenance": {
      "program": "zk_shields (noir_space_ship)",
      "generator":
        "src/frontend/viewmodel/tests/fixtures/flow/capture_zk_shields_flow.nim",
      "breakpoint": "shield.nr:" & $LoopBodyLine,
      "passesSkipped": PassesToSkip,
      "note": "viewUpdates[0] of the ct/updated-flow event, verbatim except " &
        "that FlowStep.originSummaries is dropped — see the generator.",
    },
    "position": {
      "path": session.getCurrentFile(),
      "line": session.getCurrentLine(),
      "rrTicks": session.getCurrentRRTicks().int,
    },
    "sourceLines": readFile(shieldPath).splitLines(),
    "viewUpdate": view,
  }

  let outPath = currentSourcePath().parentDir / "zk_shields_flow_window.json"
  writeFile(outPath, doc.pretty(2))
  echo "wrote ", outPath, " (", getFileSize(outPath), " bytes)"

when isMainModule:
  main()
