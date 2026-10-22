## low_level_code_markup_dom_test.nim
##
## HSF-D3, Tier-2: a source line in the Low Level Code pane is TEXT in a real
## DOM. The line is a line of the recorded program's own source — markup by
## construction for HTML, JSX or template files — and the pane renders it
## under `WebRenderer` into jsdom's document; a line that parsed as markup
## would add an `<img>` whose `onerror` runs.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/[unittest, tables]

import isonim/core/owner
import isonim/web/[web_renderer, dom_api]

import ../viewmodel/backend/mock_backend
import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/viewmodels/low_level_code_vm
import ../viewmodel/views/isonim_low_level_code_view

const Markup = "<img src=x onerror=\"globalThis.ctLowLevelMarkupRan = true\">"

proc queryAll(root: Element; selector: cstring): seq[Element]
  {.importjs: "Array.from(#.querySelectorAll(#))".}
proc textOf(el: Element): cstring {.importjs: "#.textContent".}
proc childElementCount(el: Element): int {.importjs: "#.childElementCount".}
proc markupRan(): bool {.importjs: "(globalThis.ctLowLevelMarkupRan === true)".}
proc documentBody(): Node {.importjs: "(document.body)@".}

var failed = 0
template ck(cond: untyped) =
  if not (cond):
    inc failed
  check cond

suite "the Low Level Code pane sets source lines as text":
  test "a source line containing markup renders as text":
    createRoot proc(dispose: proc()) =
      let store = createReplayDataStore(newMockBackendService().toBackendService())
      let vm = createLowLevelCodeVM(store)
      vm.setInstructions(@[LowLevelInstruction(
        name: "mov", offset: 1, highLevelPath: "/src/page.html",
        highLevelLine: 3)])
      var text = initTable[string, string]()
      text[sourceKey("/src/page.html", 3)] = Markup
      vm.sourceText.val = text
      let panel = renderLowLevelCodePanel[WebRenderer, Element](
        WebRenderer(), vm)
      discard appendChild(documentBody(), Node(panel))
      let lines = panel.queryAll(cstring".low-level-code-source-line-text")
      ck lines.len == 1
      if lines.len == 1:
        ck $lines[0].textOf == Markup
        ck lines[0].childElementCount == 0
      ck panel.queryAll(cstring"img").len == 0
      ck not markupRan()
      dispose()

if failed > 0:
  {.emit: "process.exitCode = 1;".}
