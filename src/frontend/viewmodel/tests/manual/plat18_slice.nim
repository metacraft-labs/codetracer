## plat18_slice.nim — PLAT-18 deliverable 2: the vertical slice.
##
## The variables pane, with the 600-member fixture, driven from a host in
## Electron. One source, THREE builds, and the third is the one the milestone
## is about:
##
##   | arm            | build                          | what it is |
##   |----------------+--------------------------------+------------|
##   | `js-direct`    | `nim js`                       | **the current build.** The core is JS, the renderer is `WebRenderer`, and the DOM calls are ordinary JS calls in one heap |
##   | `js-crossing`  | `nim js -d:ctPlat18Frame`      | the same core, emitting a handle-and-bytes command frame that the host decodes and applies |
##   | `wasm-crossing`| wasm32 `-d:ctPlat18Frame`      | **PLAT-17's core**, same frame, same host applier |
##
## ## WHY THREE AND NOT TWO
##
## Two arms would give one difference and two explanations for it. Three give
## a factorisation, and the middle arm is the control that separates them:
##
##   `js-crossing` − `js-direct`     = THE COST OF CROSSING, at a fixed runtime
##   `wasm-crossing` − `js-crossing` = THE COST OF THE RUNTIME, at a fixed boundary
##
## Without `js-crossing`, "wasm is slower" cannot be told from "a serialised
## boundary is slower", and those have opposite implications: the first is an
## argument against the WASM core and the second is an argument against this
## boundary design, which §3 says explicitly is the variable that decides it.
##
## All three run **in one Electron renderer process, against one document,
## interleaved**, because the host is loaded and an absolute wall time taken
## on a loaded host is a coin flip (Verification-Harness-Traps.md §12a). A
## ratio between arms measured back to back carries the same scheduler noise
## on both sides.
##
## ## NO MOCKS BEYOND THE ONE THE ARCHITECTURE MANDATES
##
## `MockBackendService` stands in for the DAP transport. The `StateVM`, the
## `state_view` projection, the IsoNim view, the presenter, the reactive layer
## and — in `js-direct` — the real `WebRenderer` against Chromium's real DOM
## are all the product's own.
##
## ## THE HOST API
##
## Every entry point below is `{.exportc.}` and takes no arguments, so both
## the JS backend's own globals and emscripten's `ccall` can reach it. The
## host drives the same four phases the marshalling probe measures:
## `p18Mount`, `p18Expand`, `p18Step`, `p18Collapse`, plus `p18Reset` to build
## a fresh world. `p18FrameBase` / `p18FrameLen` expose the command frame;
## `p18Rows` reports what the core believes it drew, which the host compares
## against what the DOCUMENT actually holds; and `p18Ops` reports how many
## operations the core PUT IN the frame, which the host compares against how
## many it APPLIED.

import std/strutils

import isonim/core/signals
import isonim/core/owner
import isonim/core/async_compat

import ../../store/types as store_types
import ../../store/replay_data_store
import ../../backend/mock_backend
import ../../viewmodels/state_vm
import ../../views/state_view
import ../../views/isonim_state_view

import ../../../../common/value_presentation

when defined(ctPlat18Frame):
  import ./plat18_frame_renderer
  import isonim/core/boundary_meter
else:
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

const
  WideMemberCount = 600
  WideName = "mapping"

# ---------------------------------------------------------------------------
# The fixture — the same rule `plat18_marshalling_probe.nim` uses, and the
# same rule the recorded `wide_state` program declares:
# `mapping["key_%03d" % i] = i * 2`, decoded as a tuple.
# ---------------------------------------------------------------------------

proc renderedAtStatePanelBudget(v: PValue): string =
  present(v, StatePanelBudget).root.text

proc wideEntry(index: int): PValue =
  let key = "key_" & align($index, 3, '0')
  PValue(kind: pvkTuple, typeName: "Tuple", sourceKind: "Tuple",
         members: @[
           member("", PValue(kind: pvkString, text: key, typeName: "String",
                             sourceKind: "String")),
           member("", PValue(kind: pvkInt, text: $(index * 2), typeName: "Int",
                             sourceKind: "Int"))])

proc wideVariable(): store_types.Variable =
  var children: seq[store_types.Variable] = @[]
  var memberPValues: seq[PMember] = @[]
  for i in 0 ..< WideMemberCount:
    let pv = wideEntry(i)
    memberPValues.add member("", pv)
    children.add store_types.Variable(
      name: $i, value: renderedAtStatePanelBudget(pv), presented: pv,
      typeName: "Tuple", hasChildren: false, children: @[])
  let whole = PValue(kind: pvkSequence, typeName: "Dict", sourceKind: "Seq",
                     members: memberPValues)
  store_types.Variable(name: WideName, value: renderedAtStatePanelBudget(whole),
                       presented: whole, typeName: "Dict",
                       hasChildren: true, children: children)

proc narrowVariable(tick: int): store_types.Variable =
  ## Fixed width, so the STEP phase's byte count does not move when the
  ## counter crosses a power of ten.
  let pv = PValue(kind: pvkInt, text: align($tick, 6, '0'), typeName: "Int",
                  sourceKind: "Int")
  store_types.Variable(name: "counter", value: renderedAtStatePanelBudget(pv),
                       presented: pv, typeName: "int",
                       hasChildren: false, children: @[])

# ---------------------------------------------------------------------------
# The world
# ---------------------------------------------------------------------------

var
  theStore: ReplayDataStore
  theVm: StateVM
  theWide: store_types.Variable
  stepTick = 0
  builtFixture = false

proc ensureFixture() =
  if not builtFixture:
    theWide = wideVariable()
    builtFixture = true

proc p18Reset() {.exportc.} =
  ## A fresh store and a fresh VM, outside any measured region. The fixture
  ## itself is built once: constructing 600 `PValue`s is the RECORDING's cost,
  ## not the boundary's, and charging it to every sample would put a constant
  ## in front of the thing being compared.
  ensureFixture()
  createRoot proc(dispose: proc()) =
    theStore = createReplayDataStore(newMockBackendService().toBackendService())
    theVm = createStateVM(theStore)
  theStore.locals.locals.val = @[narrowVariable(0), theWide]
  drainPlatformCallbacks()
  when defined(ctPlat18Frame):
    resetFrameRenderer()

when defined(ctPlat18Frame):
  var theRenderer = FrameRenderer()
  var thePanelRoot: FrameNode

  proc p18Mount() {.exportc.} =
    wireReset()
    thePanelRoot = renderStatePanel(theRenderer, theVm)
    # The panel's own root has to reach the host's document; nothing in the
    # view says where it goes. Handle 0 is the host's container by
    # convention — the one index this module never allocates.
    appendChild(theRenderer, NoFrameNode, thePanelRoot)

  proc p18FrameBase(): int {.exportc.} = wireBase()
  proc p18FrameLen(): int {.exportc.} = wireBytes()
  # How many operations the CORE put in the current frame. The host compares
  # it against how many it APPLIED; see `driver.js`'s `checkOps`.
  proc p18Ops(): int {.exportc.} = wireOpCount()
  proc p18ReadCrossings(): int {.exportc.} = readCrossings
  proc p18Dispatch(id: int) {.exportc.} = dispatchCallback(id)

else:
  var theRenderer = WebRenderer()

  proc hostContainer(): isonim_dom.Element
      {.importjs: "document.getElementById('ct-p18-root')".}

  proc p18Mount() {.exportc.} =
    let panel = renderStatePanel(theRenderer, theVm)
    isonim_dom.appendChild(isonim_dom.Node(hostContainer()),
                           isonim_dom.Node(panel))

  proc p18FrameBase(): int {.exportc.} = 0
  proc p18FrameLen(): int {.exportc.} = 0
  # `js-direct` has no frame, so it puts no operations in one — and the host
  # applies no frame on this arm, so the two zeroes agree honestly rather than
  # the check being skipped for it.
  proc p18Ops(): int {.exportc.} = 0
  proc p18ReadCrossings(): int {.exportc.} = 0
  proc p18Dispatch(id: int) {.exportc.} = discard

proc p18BeginFrame() {.exportc.} =
  ## Start a new command frame. A no-op on `js-direct`, where there is none.
  when defined(ctPlat18Frame):
    wireReset()

proc p18Expand() {.exportc.} =
  theVm.toggleExpand(WideName)
  drainPlatformCallbacks()

proc p18Step() {.exportc.} =
  inc stepTick
  theStore.locals.locals.val = @[narrowVariable(stepTick), theWide]
  drainPlatformCallbacks()

proc p18Collapse() {.exportc.} =
  theVm.toggleExpand(WideName)
  drainPlatformCallbacks()

proc p18Rows(): int {.exportc.} =
  ## What the CORE believes is on screen. The host compares this against what
  ## the DOCUMENT holds; agreement is the slice's non-vacuity floor, and a
  ## timing over a document that never got its 602 rows is a timing of
  ## nothing.
  getStateViewState(theVm).variables.len

proc p18OpManifest() {.exportc.} =
  ## THE OPCODE TABLE, WRITTEN BY THE SIDE THAT OWNS IT.
  ##
  ## The host has to turn a byte back into an operation, and the obvious way
  ## to let it — a switch with the numbers written out in JavaScript — is a
  ## second copy of `BoundaryOp` in a file the Nim compiler does not read
  ## (Verification-Harness-Traps.md §14). Inserting an enum member in the
  ## middle would then silently renumber one side only, and every op after it
  ## would be applied as the wrong one: `SetAttribute` arriving as
  ## `SetTextContent` is not a crash, it is a document that quietly says
  ## something else.
  ##
  ## So the module publishes the table instead. One record per operation —
  ## `u8 ordinal`, then the name as a length-prefixed string — in the same
  ## frame format as everything else, and the host builds its dispatch from
  ## it. The host additionally REFUSES a manifest that does not name every
  ## operation it knows how to apply.
  when defined(ctPlat18Frame):
    wireReset()
    for op in BoundaryOp:
      wirePutU8(ord(op))
      wirePutStr($op)

when defined(js) and not defined(nodejs):
  # Bind the entry points as globals for the host page. `{.exportc.}` on this
  # backend emits each as a top-level function with exactly that name, so the
  # binding is a reference and not a wrapper — a wrapper would put a JS frame
  # inside every measured region on ONE of the three arms.
  #
  # The two JS arms carry DIFFERENT global names because the host loads them
  # into ONE page: interleaving is the whole design (a loaded host makes an
  # absolute timing a coin flip), and two bundles that both answered to `p18`
  # would have the second silently measuring the first.
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
  when defined(ctP18InMain):
    # The in-`main` control. It exists because the defect below was found by
    # the difference between these two, and a claim about "after main" needs
    # the "inside main" half to have been measured too.
    p18Reset()
    p18Mount()
    p18Expand()
    echo "P18DBG IN-MAIN rows=", p18Rows(), " frame=", p18FrameLen()
  elif defined(emscripten):
    # ## MAIN MUST NOT RETURN, AND THIS IS THE FIRST THING WIRING THE CORE
    # ## INTO A FRONT-END FOUND
    #
    # PLAT-17 built the core and ran the suites; its bound 4 is that nothing
    # was wired into a front-end. The first consequence of wiring it is this,
    # and it is not an emscripten quirk — it is Nim's own code generation:
    #
    #   N_NIMCALL(void, NimMainModule)(void) {
    #     …the module body…
    #     eqdestroy___…(&theWide__plat18slice);
    #     eqdestroy___…(theVm__plat18slice);
    #     …
    #   }
    #
    # **ORC destroys the main module's globals at the END of `NimMainModule`.**
    # For an ordinary program that is exactly right: the program's life is
    # main's life. For a module whose entry points a HOST calls after main has
    # returned — which is what a WASM core in a browser is — every global has
    # been destroyed before the first call arrives, and the memory has been
    # handed back to `dlmalloc`.
    #
    # It does not fail loudly. Measured on this tree, wasm32, `--mm:orc`,
    # DEBUG, emscripten 4.0.12: `p18Reset` ran, built the 600-member fixture,
    # and then `MockBackendService` refused `ct/load-locals` as "not a valid
    # DAP command" — because `dap_commands.VALID_DAP_COMMANDS` still reported
    # `card == 81` while `"ct/load-locals" in …` had become **false**. The
    # hash was identical across the flip (-2111093306); the set's STORAGE had
    # been freed and reused by the fixture's own allocations. A destroyed
    # global that still answers its length is the worst shape this can take:
    # the same program, the same input, a different answer, and nothing red.
    #
    # `emscripten_exit_with_live_runtime()` unwinds out of main by throwing,
    # so the destructor epilogue never runs and the runtime stays up. The
    # in-`main` control above is what tells this apart from a wasm arithmetic
    # or memory bug: identical code inside main draws all 602 rows.
    emscriptenExitWithLiveRuntime()
  else:
    discard
