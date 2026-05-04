## Storybook-compatible exports for CodeTracer IsoNim panels.
##
## Compiled with:
##   nim js -o:storybook/dist/components.js src/frontend/storybook_components.nim

when not defined(js):
  {.error: "storybook_components.nim requires the JS backend (nim js)".}

import isonim/rxcore
import isonim/viewmodel
import isonim/web/dom_api as isonim_dom

import viewmodel/backend/mock_backend
import viewmodel/store/[replay_data_store, types]
import viewmodel/viewmodels/terminal_output_vm
import viewmodel/views/isonim_terminal_output_view

type DisposeProc = proc()

proc makeStore(): ReplayDataStore =
  let mock = newMockBackendService(autoRespond = true)
  createReplayDataStore(mock.toBackendService)

proc makeReferenceLines(): seq[TerminalLine] =
  @[
    TerminalLine(lineIndex: 0, fragments: @[
      TerminalEventFragment(
        htmlText: "<span class=\"ansi-bright-green-fg\">CodeTracer</span> replay started",
        eventIndex: 10,
        rrTicks: 100'u64,
      ),
    ]),
    TerminalLine(lineIndex: 1, fragments: @[
      TerminalEventFragment(
        htmlText: "running ",
        eventIndex: 11,
        rrTicks: 140'u64,
      ),
      TerminalEventFragment(
        htmlText: "<span class=\"ansi-bright-cyan-fg\">noir-space-ship</span>",
        eventIndex: 12,
        rrTicks: 180'u64,
      ),
    ]),
    TerminalLine(lineIndex: 2, fragments: @[
      TerminalEventFragment(
        htmlText: "<span class=\"ansi-bright-yellow-fg\">warning:</span> flow loop still rendering",
        eventIndex: 13,
        rrTicks: 220'u64,
      ),
    ]),
  ]

proc applyTerminalOutputFixture(vm: TerminalOutputVM; fixture: cstring) =
  case $fixture
  of "loading":
    vm.clearLines()
    vm.setCurrentRRTicks(0'u64)
  of "empty":
    vm.setLines(@[])
    vm.setCurrentRRTicks(0'u64)
  else:
    vm.setLines(makeReferenceLines())
    vm.setCurrentRRTicks(180'u64)

proc mountTerminalOutputPanel*(container: isonim_dom.Element;
                               fixture: cstring): DisposeProc {.exportc.} =
  ## Mount a real TerminalOutputVM through the production IsoNim panel view.
  var rootDisposer: proc()
  var store: ReplayDataStore
  var vm: TerminalOutputVM

  createRoot proc(dispose: proc()) =
    rootDisposer = dispose
    store = makeStore()
    vm = createTerminalOutputVM(store)
    vm.applyTerminalOutputFixture(fixture)
    mountIsoNimTerminalOutput(container, vm)

  return proc() =
    if vm != nil:
      vm.dispose()
    if store != nil:
      store.dispose()
    if rootDisposer != nil:
      rootDisposer()
    container.innerHTML = ""
