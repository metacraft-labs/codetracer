## complete_move_redelivery_test.nim
##
## A PANE BUILT AFTER A MOVE IS GIVEN THAT MOVE ONCE, AND IT ALONE.
##
## A pane built after the debugger moved asks the session's middleware for
## the last move (`InternalLastCompleteMove`): an editor asks when it
## registers and again once its Monaco is up, and the Trace pane asks when it
## registers. The middleware used to answer by replaying the move to EVERY
## pane. Each replay carries the move's `resetFlow`, so every editor already
## showing the stop rebuilt its inline flow: a Call Trace jump that opened a
## new file built that file's `FlowComponent` three times, and the engine
## computed the flow for each.
##
## Two fixes, and this suite holds both:
##
##   * `middleware.nim` answers only the subscriber that asked
##     (`Subscriber.emitRaw` on the asker, not the mediator's fan-out);
##   * `EditorViewComponent.onCompleteMove` does not rebuild a flow that is
##     already for the redelivered move's stop. An editor asks twice itself,
##     so the first fix alone still leaves two builds.
##
## The first case is the whole sequence and counts builds: one jump that
## builds a new editor builds its flow once (three before both fixes). The
## second holds the guard to exactly its condition: a redelivered move to the
## flow's own stop builds nothing, while a new move to the same stop and a
## redelivered move to another stop still build. The third holds the
## middleware to answering the asker only.
##
## A build is counted from the component itself: `loadFlow` hands the
## component it replaces to the new one (`handoffFlow`), and nothing in this
## suite takes a hand-off down (that happens when a flow answer is drawn), so
## the chain's length is the number of builds.
##
## ## What is real, and the stand-ins
##
## REAL: the window's `data` and its first session (`types`), its `DapApi`
## and views mediator, `middleware.setupMiddlewareApis` (the DAP -> views
## move fan-out and the `InternalLastCompleteMove` answer), component
## mediators built by `types.setupLocalViewToMiddlewareApi`, and
## `EditorViewComponent.register` / `onCompleteMove` / `loadFlow`. The move
## reaches the views through `DapApi.receive`, as the main process's
## `ct/complete-move` event does.
##
## STAND-INS, each because jsdom cannot run the real thing:
##
##   * the Monaco instance: an object with the members `onCompleteMove` and
##     the flow's per-move work call (`getOptions`, `updateOptions`, ...),
##     each a no-op. Monaco needs a layout engine jsdom lacks, and what is
##     counted here is the editor's decision to build a flow, not Monaco's
##     drawing of one. `legacy_loop_dom_bootstrap` supplies the import-time
##     Monaco models, as for the other renderer suites.
##   * the second `InternalLastCompleteMove` an editor sends: the suite sends
##     it from the editor's own mediator, as `initMonacoForEditor` does as its
##     last step, because `initMonacoForEditor` itself creates a Monaco.
##   * the `ipc` object's `send`, which records outgoing frames (the flow's
##     own requests) instead of writing them to the main process.
##   * `MoveSink`, a `Subscriber` registered for `CtCompleteMove` beside the
##     editors, which records what the views fan-out delivers to it. It is the
##     one destination observed, and it replaces no code under test.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import ./legacy_loop_dom_bootstrap
import std/[jsffi, asyncjs]

import ../types
import ../lib/monaco_lib
import ../communication
import ../middleware
import ../dap
import ../ui/editor
import ../../common/ct_event

proc failExit() {.importjs: "(function() { process.exitCode = 1; })()".}

const ExpectedChecks = 11
var checks = 0
var failedChecks = 0
var caseFailed = false

template ck(cond: untyped; detail: string = "") =
  inc checks
  if not (cond):
    inc failedChecks
    caseFailed = true
    echo "    Check failed: " & astToStr(cond) &
      (if detail.len > 0: "  -- " & detail else: "")

proc endCase(name: string) =
  echo(if caseFailed: "  [FAILED] " else: "  [OK] ", name)
  caseFailed = false

proc settle(): Future[void] =
  ## One task turn: `onCompleteMove` is async, and the work this suite reads
  ## is done before its first `await` returns.
  newPromise proc(resolve: proc()) =
    {.emit: "setTimeout(`resolve`, 0);".}

# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------

proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) = discard
  ipc

proc standInMonaco(): MonacoEditor {.importjs: """
  (() => {
    const noop = () => {};
    return {
      getOptions: () => ({}), updateOptions: noop, getOption: () => 19,
      deltaDecorations: () => [], changeViewZones: noop,
      addContentWidget: noop, removeContentWidget: noop,
      layoutContentWidget: noop, getModel: () => null,
      revealLineInCenterIfOutsideViewport: noop, getLayoutInfo: () => ({}),
      getScrollTop: () => 0, getDomNode: () => null,
      getTopForLineNumber: () => 0, setValue: noop,
    };
  })()""".}

type MoveSink = ref object of Subscriber
  moves: seq[bool]   ## each delivered move's `redelivered`

method emitRaw(s: MoveSink; kind: CtEventKind; payload: JsObject;
               source: Subscriber) =
  if kind == CtCompleteMove:
    s.moves.add payload.to(MoveState).redelivered

data.ipc = recordingIpc()
data.dapApi.ipc = data.ipc
data.config = Config(flow: FlowConfigObjWrapper(enabled: true))
for content in Content:
  data.ui.componentMapping[content] = JsAssoc[int, Component]{}
setupMiddlewareApis(data.dapApi, data.viewsApi)

let sink = MoveSink(name: cstring"move sink")
data.viewsApi.subscribers[CtCompleteMove].add sink

var nextId = 0

proc editorFor(path: cstring): EditorViewComponent =
  ## An editor whose Monaco is up, as the pane holds it once mounted. Not yet
  ## registered: `register` is what a newly built pane calls.
  let monaco = standInMonaco()
  inc nextId
  result = EditorViewComponent(
    id: nextId, path: path, name: path, editorView: ViewSource,
    data: data, service: data.services.editor,
    monacoEditor: monaco,
    tabInfo: TabInfo(name: path, monacoEditor: monaco,
                     location: types.Location(path: path)))

proc attach(editor: EditorViewComponent) =
  ## What `registerComponent` does for a new pane.
  editor.register(setupLocalViewToMiddlewareApi(
    cstring("editor #" & $editor.id & " api"), data.viewsApi))

proc builds(editor: EditorViewComponent): int =
  ## Flow components built for this editor: the hand-off chain's length.
  var flow = editor.flow
  while not flow.isNil:
    inc result
    flow = flow.handoffFlow

proc stop(path: cstring; line, rrTicks: int): types.Location =
  types.Location(path: path, line: line, rrTicks: rrTicks,
                 sourceDigest: cstring"", functionFirst: 1, functionLast: 20)

proc wireShape(o: JsObject): JsObject {.importjs:
  "JSON.parse(JSON.stringify(#, (k, v) => typeof v === 'bigint' ? Number(v) : v))".}
  ## A value as it arrives off the wire: JSON, whose numbers are JS numbers
  ## (a Nim-built `int64` is a `BigInt`, which no wire frame carries).

proc move(location: types.Location; redelivered = false): MoveState =
  wireShape(MoveState(status: cstring"ok", location: location, resetFlow: true,
                      redelivered: redelivered).toJs).to(MoveState)

proc jump(location: types.Location) =
  ## The backend's `ct/complete-move` for a jump, through the session's
  ## `DapApi`, as the main process delivers it.
  data.dapApi.receive(CtCompleteMove, move(location).toJs)

proc askForLastMove(editor: EditorViewComponent) =
  ## The request `initMonacoForEditor` sends as its last step.
  editor.api.emit(InternalLastCompleteMove, EmptyArg())

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

proc caseOneJumpBuildsTheNewEditorsFlowOnce() {.async.} =
  # main.nr is open; the jump goes into shield.nr, whose editor is built
  # after the move.
  let main = editorFor(cstring"/src/main.nr")
  main.attach()
  await settle()
  let target = stop(cstring"/src/shield.nr", 5, 1000)
  jump(target)
  await settle()
  let shield = editorFor(cstring"/src/shield.nr")
  shield.attach()            # asks for the last move (`register`)
  await settle()
  shield.askForLastMove()    # and again once Monaco is up
  await settle()
  main.askForLastMove()      # main.nr asks too (`reloadFlowAfterActivation`)
  await settle()
  ck shield.builds == 1, "shield.nr's flow was built " & $shield.builds & " times"
  ck not shield.flow.isNil and shield.flow.location.rrTicks == 1000 and
    shield.flow.location.line == 5, "and it is for the stop"
  ck main.builds == 0, "main.nr's flow was built " & $main.builds & " times"
  main.unregister()
  shield.unregister()
  endCase("one jump that builds a new editor builds its flow once")

proc caseTheGuardIsExactlyTheRedeliveredSameStop() {.async.} =
  let editor = editorFor(cstring"/src/calc.nr")
  editor.attach()
  await settle()
  let here = stop(cstring"/src/calc.nr", 7, 2000)
  discard editor.onCompleteMove(move(here))
  await settle()
  ck editor.builds == 1, "a new move builds the stop's flow"
  discard editor.onCompleteMove(move(here, redelivered = true))
  await settle()
  ck editor.builds == 1, "the same move redelivered builds nothing"
  discard editor.onCompleteMove(move(here))
  await settle()
  ck editor.builds == 2, "a new move to the same stop builds again"
  let later = stop(cstring"/src/calc.nr", 9, 2600)
  discard editor.onCompleteMove(move(later, redelivered = true))
  await settle()
  ck editor.builds == 3, "a redelivered move to another stop builds"
  ck editor.flow.location.rrTicks == 2600
  editor.unregister()
  endCase("a redelivered move to the flow's own stop builds nothing, and only that")

proc caseOnlyTheAskerIsAnswered() {.async.} =
  sink.moves = @[]
  let editor = editorFor(cstring"/src/other.nr")
  editor.attach()
  await settle()
  jump(stop(cstring"/src/other.nr", 3, 3000))
  await settle()
  ck sink.moves == @[false], "the move itself reaches every pane"
  editor.askForLastMove()
  await settle()
  ck sink.moves == @[false], "a pane that did not ask is not given the move again"
  ck editor.location.rrTicks == 3000
  editor.unregister()
  endCase("the last move is given to the pane that asked for it")

proc main() {.async.} =
  echo ""
  echo "[Suite] a move given again to a pane built after it"
  await caseOneJumpBuildsTheNewEditorsFlowOnce()
  await caseTheGuardIsExactlyTheRedeliveredSameStop()
  await caseOnlyTheAskerIsAnswered()
  echo "CHECKS: " & $checks
  if checks != ExpectedChecks:
    echo "  [FAILED] assertion count is " & $checks & ", expected " & $ExpectedChecks
    failExit()
  if failedChecks > 0:
    failExit()

discard main()
