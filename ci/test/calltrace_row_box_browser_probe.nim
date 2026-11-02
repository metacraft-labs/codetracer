## calltrace_row_box_browser_probe.nim — mount the Call Trace pane in a REAL
## browser, styled by the REAL stylesheet, over rows that do and do not show
## a return value, so `ci/test/calltrace-row-box-in-browser.sh` can measure
## every row.
##
## ## WHY THIS EXISTS
##
## A call-trace row is meant to be exactly its toggle's height, 1.5625em
## (`calltrace.styl` `.toggle-call`). It was not: a row that showed a return
## value laid out ~0.8 px taller at a 16 px root, because `.return` puts the
## arrow (SpaceGrotesk) and the value (SpaceMono) on one baseline-aligned
## line, and two typefaces' ascents and descents do not agree. The pane's
## mean row advance therefore measured ~25.28 px against a 25 px box, a
## number that moved with how many calls returned something (codetracer-pm
## issue 2026-10-18-electron-calltrace-row-advance-exceeds-its-own-row-box).
##
## The defect lives in the interaction of THREE real things: the view's
## markup, the shipped stylesheet and the shipped fonts. A restated
## stylesheet (`calltrace_guides_chromium_test.nim`'s `RowCss`) cannot see
## it, and neither can a page whose fonts did not load — the fallback face
## has different metrics. So this mounts `renderCalltracePanel[WebRenderer,
## Element]`, the procedure the browser runs, and the gate supplies the
## compiled shipped theme (`default_dark_theme_electron.styl`, which imports
## `codetracer.styl`) with its `@font-face` URLs made loadable.
##
## The probe asserts nothing; it paints, and the gate measures.
##
## ## THE FIXTURE
##
## `RowCount` calls over depths 0..4 (indents that go down and back up), with
## 0, 1 or 2 arguments, a return value on every other call (short, long,
## quoted, and a value with no arguments beside it), parents shown expanded
## and collapsed, and one SELECTED row that shows a return value — the row
## the eye is on, and the one with the most decoration. Every combination of
## "has arguments" x "has a return value" occurs, so a defect tied to either
## part of a row is in the sample.
##
## ## THE ONE MOCK
##
## The store's backend is `MockBackendService`, because nothing on this page
## talks to a debugger: the subject is how rows already in the store are laid
## out, and the rows enter through `updateCalltraceSection`, the store entry
## point the desktop's `syncCalltraceData` uses. The backend is never asked
## anything that would change what is drawn.
##
## Build (browser target, the shipped web arm's defines):
##   nim js -d:ctWeb -d:ctRenderer -d:chronicles_enabled=off \
##     --path:src --path:src/frontend/viewmodel -o:<out>/probe.js \
##     ci/test/calltrace_row_box_browser_probe.nim

import std/[options, tables]

import isonim/core/owner
import isonim/web/dom_api as dom
import isonim/web/web_renderer

import ../../src/frontend/viewmodel/backend/backend_service
import ../../src/frontend/viewmodel/backend/mock_backend
import ../../src/frontend/viewmodel/store/types as store_types
import ../../src/frontend/viewmodel/store/replay_data_store
import ../../src/frontend/viewmodel/viewmodels/calltrace_vm
import ../../src/frontend/viewmodel/views/isonim_calltrace_view

const
  RowCount = 40
    ## Enough rows for every depth/argument/return combination to occur
    ## several times, and few enough that all of them are on screen in the
    ## gate's frame at the largest root font size it measures.
  SelectedRow = 7
    ## Odd, so the selected row shows a return value.

const ReturnTexts = ["42", "\"ok\"", "nil",
                     "Point(x: 12, y: -3)", "true",
                     "@[1, 2, 3, 4, 5, 6, 7, 8]"]
  ## Values of different widths and glyph mixes (digits, quotes, brackets,
  ## a minus), so no single glyph's metrics decide the reading.

proc depthOf(i: int): int =
  ## 0 1 2 3 4 3 2 1 0 1 ... — rows deeper, shallower and level with their
  ## neighbours.
  let k = i mod 8
  if k <= 4: k else: 8 - k

proc hasReturn(i: int): bool = i mod 2 == 1

proc argCount(i: int): int = i mod 3

proc fixtureLines(): seq[CallLine] =
  for i in 0 ..< RowCount:
    let parent = depthOf(i + 1) > depthOf(i)
    result.add CallLine(
      index: int64(i),
      name: "compute_step_" & $i,
      depth: depthOf(i),
      rrTicks: uint64(1000 + i),
      location: Location(file: "probe.nim", line: i + 1),
      hasChildren: parent,
      isExpanded: parent and i mod 4 != 0,
      callKey: "call-" & $i)

proc fixtureArgs(): Table[string, seq[CallArg]] =
  ## Per-call arguments, then the return value under `ReturnArgName` — the
  ## shape `replay_data_store.callArgsOf` gives a decoded call.
  for i in 0 ..< RowCount:
    var args: seq[CallArg]
    for k in 0 ..< argCount(i):
      args.add CallArg(name: "arg" & $k, text: $(k * 7 + i))
    if hasReturn(i):
      args.add CallArg(name: ReturnArgName,
                       text: ReturnTexts[(i div 2) mod ReturnTexts.len])
    if args.len > 0:
      result["call-" & $i] = args

proc main() =
  let backend = newMockBackendService(autoRespond = true).toBackendService()
  let store = createReplayDataStore(backend)
  let host = dom.getElementById(dom.document, cstring"ct-calltrace-pane")
  var vm: CalltraceVM
  createRoot proc(dispose: proc()) =
    vm = createCalltraceVM(store)
    store.updateCalltraceSection(fixtureLines(), startIndex = 0'i64,
                                 totalCount = uint64(RowCount),
                                 args = fixtureArgs())
    vm.selectEntry(some(int64(SelectedRow)))
    discard dom.appendChild(dom.Node(host), dom.Node(
      renderCalltracePanel[WebRenderer, dom.Element](WebRenderer(), vm)))

  # A machine-readable line beside the painted DOM, so the gate can tell "the
  # rows laid out wrong" from "the fixture never loaded".
  var withReturn = 0
  for i in 0 ..< RowCount:
    if hasReturn(i): inc withReturn
  let summary = dom.getElementById(dom.document, cstring"ct-probe-summary")
  dom.appendChild(dom.Node(summary), dom.createTextNode(dom.document, cstring(
    "rows=" & $store.calltrace.lines.val.len &
    " withReturn=" & $withReturn &
    " selected=" & $SelectedRow)))

main()
