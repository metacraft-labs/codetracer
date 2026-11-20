## plat18_calltrace_slice.nim — the second pane on the WASM core: Call Trace.
##
## `plat18_slice.nim` drove the variables pane three ways from one source.
## This module drives the CALL TRACE pane the same three ways, through the
## same host (`plat18_slice_host/`), so the evaluation no longer rests on a
## single pane:
##
##   | arm            | build                          | what it is |
##   |----------------+--------------------------------+------------|
##   | `js-direct`    | `nim js`                       | the current build: `renderCalltracePanel[WebRenderer, Element]`, including its DOM decoration |
##   | `js-crossing`  | `nim js -d:ctPlat18Frame`      | the same core, emitting the command frame the host applies |
##   | `wasm-crossing`| wasm32 `-d:ctPlat18Frame`      | the core in WebAssembly, same frame, same host applier |
##
## ## WHY THIS PANE
##
## It is the other pane a step always touches, and it is a different shape
## from the variables pane: a long list of rows, each with an argument list
## of its own (`indexEach` inside `indexEach`), a selection that moves on
## every step, and a scroll area sized from the trace. It also has the
## DECORATION the variables pane has not: on `WebRenderer` the panel draws
## its guide lines into an SVG, fits its cells to the measured width and
## watches its own size (`decorateCalltracePanel`). That code READS the
## document's layout, so on this pane the boundary question §3 leaves open —
## "a pane whose view reads the tree" — is real.
##
## The decoration is host-side behaviour: it runs on DOM nodes in the page
## and needs nothing from the core except what the rows already carry. In a
## WebAssembly front-end it would stay in the host, beside the applier, and
## read the nodes the host owns without crossing. So the crossing arms render
## the panel WITHOUT it, and `js-direct` — the build that ships — renders it
## WITH it. The two crossing arms therefore compare exactly (same source, same
## renderer, two compilers), and `js-direct` is the product as it is. The
## driver's parity check says which comparison each phase is held to.
##
## ## THE FIXTURE
##
## 600 calls at depths 0–5, every one with two arguments and a return value,
## as the store holds a loaded section (`updateCalltraceSection`). The phases
## keep the names the host knows:
##
##   MOUNT     the panel over a two-call section
##   EXPAND    the store's section becomes the 600-call one (a section load:
##             what scrolling, or a jump into a deep trace, does)
##   STEP      the selected call moves to the next row — what a step does to
##             this pane when the section is already loaded
##   COLLAPSE  the section goes back to two calls
##
## ## MOCKS
##
## `MockBackendService` stands in for the DAP transport, as in the first
## slice and as the ViewModel testing architecture mandates. The store, the
## `CalltraceVM`, the view, the reactive layer and — on `js-direct` — the real
## `WebRenderer` against the real DOM are the product's own.

import std/[options, tables]

import isonim/core/signals
import isonim/core/owner
import isonim/core/async_compat

import ../../store/types as store_types
import ../../store/replay_data_store
import ../../backend/mock_backend
import ../../viewmodels/calltrace_vm
import ../../views/isonim_calltrace_view

when defined(ctPlat18Frame):
  import ./plat18_frame_renderer
  import isonim/core/boundary_meter
else:
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

const
  WideCallCount* = 600
  NarrowCallCount* = 2

proc callLine(index: int): CallLine =
  CallLine(index: index.int64,
           name: "worker_" & $(index mod 37),
           depth: index mod 6,
           hasChildren: (index mod 6) < 5,
           callKey: "c" & $index,
           location: store_types.Location(file: "/src/pipeline/stage.py",
                                          line: 10 + index mod 200),
           rrTicks: uint64(1000 + index * 7))

proc section(count: int): (seq[CallLine], Table[string, seq[CallArg]]) =
  var lines: seq[CallLine] = @[]
  var args = initTable[string, seq[CallArg]]()
  for i in 0 ..< count:
    let line = callLine(i)
    lines.add line
    args[line.callKey] = @[
      CallArg(name: "item", text: "Record(id=" & $i & ", stage='parse')"),
      CallArg(name: "budget", text: $(i * 3)),
      CallArg(name: "__return", text: "Ok(" & $(i * 2) & ")")]
  (lines, args)

var
  theStore: ReplayDataStore
  theVm: CalltraceVM
  stepTick = 0
  wide: (seq[CallLine], Table[string, seq[CallArg]])
  narrow: (seq[CallLine], Table[string, seq[CallArg]])
  builtFixture = false

proc ensureFixture() =
  ## Built once, outside every measured region: making 600 `CallLine`s is
  ## the recording's cost, not the boundary's.
  if not builtFixture:
    wide = section(WideCallCount)
    narrow = section(NarrowCallCount)
    builtFixture = true

proc load(s: (seq[CallLine], Table[string, seq[CallArg]])) =
  theStore.updateCalltraceSection(s[0], 0'i64, uint64(s[0].len), args = s[1])

proc p18Reset() {.exportc.} =
  ensureFixture()
  stepTick = 0
  createRoot proc(dispose: proc()) =
    theStore = createReplayDataStore(newMockBackendService().toBackendService())
    theVm = createCalltraceVM(theStore)
  load(narrow)
  drainPlatformCallbacks()
  when defined(ctPlat18Frame):
    resetFrameRenderer()

when defined(ctPlat18Frame):
  var theRenderer = FrameRenderer()
  var thePanelRoot: FrameNode

  proc p18Mount() {.exportc.} =
    wireReset()
    thePanelRoot = renderCalltracePanel[FrameRenderer, FrameNode](theRenderer, theVm)
    appendChild(theRenderer, NoFrameNode, thePanelRoot)

  proc p18FrameBase(): int {.exportc.} = wireBase()
  proc p18FrameLen(): int {.exportc.} = wireBytes()
  proc p18Ops(): int {.exportc.} = wireOpCount()
  proc p18ReadCrossings(): int {.exportc.} = readCrossings
  proc p18Dispatch(id: int) {.exportc.} = dispatchCallback(id)

else:
  var theRenderer = WebRenderer()

  proc hostContainer(): isonim_dom.Element
      {.importjs: "document.getElementById('ct-p18-root')".}

  proc p18Mount() {.exportc.} =
    let panel = renderCalltracePanel[WebRenderer, isonim_dom.Element](theRenderer, theVm)
    isonim_dom.appendChild(isonim_dom.Node(hostContainer()),
                           isonim_dom.Node(panel))

  proc p18FrameBase(): int {.exportc.} = 0
  proc p18FrameLen(): int {.exportc.} = 0
  proc p18Ops(): int {.exportc.} = 0
  proc p18ReadCrossings(): int {.exportc.} = 0
  proc p18Dispatch(id: int) {.exportc.} = discard

proc p18BeginFrame() {.exportc.} =
  when defined(ctPlat18Frame):
    wireReset()

proc p18Expand() {.exportc.} =
  load(wide)
  drainPlatformCallbacks()

proc p18Step() {.exportc.} =
  inc stepTick
  theVm.selectEntry(some(int64(stepTick mod WideCallCount)))
  drainPlatformCallbacks()

proc p18Collapse() {.exportc.} =
  load(narrow)
  drainPlatformCallbacks()

proc p18Rows(): int {.exportc.} =
  ## What the CORE holds: the section's rows. The host compares it against
  ## the document's `.calltrace-call-line` count.
  theStore.calltrace.lines.val.len

proc p18OpManifest() {.exportc.} =
  ## The opcode table, published by the side that owns it — see
  ## `plat18_slice.nim`.
  when defined(ctPlat18Frame):
    wireReset()
    for op in BoundaryOp:
      wirePutU8(ord(op))
      wirePutStr($op)

when defined(js) and not defined(nodejs):
  when defined(ctPlat18Frame):
    {.emit: """
globalThis.p18Frame = {
  reset: p18Reset, mount: p18Mount, beginFrame: p18BeginFrame,
  expand: p18Expand, step: p18Step, collapse: p18Collapse,
  rows: p18Rows, frameLen: p18FrameLen, frameBytes: globalThis.ctP18_frame,
  ops: p18Ops, readCrossings: p18ReadCrossings, dispatch: p18Dispatch,
  opManifest: p18OpManifest
};
""".}
  else:
    {.emit: """
globalThis.p18Direct = {
  reset: p18Reset, mount: p18Mount, beginFrame: p18BeginFrame,
  expand: p18Expand, step: p18Step, collapse: p18Collapse,
  rows: p18Rows, frameLen: p18FrameLen, frameBytes: null,
  ops: p18Ops, readCrossings: p18ReadCrossings, dispatch: p18Dispatch,
  opManifest: p18OpManifest
};
""".}

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime()
      {.importc: "emscripten_exit_with_live_runtime", header: "<emscripten.h>".}

when isMainModule:
  when defined(emscripten):
    # Main must not return: ORC destroys the main module's globals at the end
    # of `NimMainModule`, and the host calls the entry points after it. See
    # `plat18_slice.nim` for the measurement that found it.
    emscriptenExitWithLiveRuntime()
