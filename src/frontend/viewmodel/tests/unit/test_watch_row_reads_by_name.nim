## test_watch_row_reads_by_name.nim
##
## A watch typed into the State pane is answered, drawn, and READABLE BY ITS
## NAME: the pane holds exactly one element named after the watch, and that
## element is the row carrying the answer.
##
## THE DEFECT (codetracer-pm issues/2026-10-22-a-watch-typed-in-the-browser-
## never-produces-a-row.md). In the browser, `initial_shield` was typed into
## the Watches tab, the session's stop loader re-sent `ct/load-locals` with it,
## the replay answered, `applyLocalsResponse` split the answer into
## `store.locals.watches`, and the view drew the row. Yet the Playwright spec
## reported "never produced a row" with `Received string: ""`. The row's
## origin badge repeated the row's `data-variable-name`, so the pane held TWO
## elements named `initial_shield` — the row, and inside it the badge, whose
## text is empty. A reader that maps `data-variable-name` to the element's text
## (the spec's `watchRows`) ended on the badge. `data-variable-name` is the
## State pane's ROW selector (codetracer-pm Live-HCR-GUI-E2E-Test-Design.md,
## "Semantic Test Selectors"); one name must mean one row.
##
## The suite walks the whole path the browser takes up to the DOM, in one
## long-lived panel: a `DebuggerSession` whose stop loader follows the store
## (`ui_js`'s page-placement shape), `StateVM.addWatch` (what the watch input's
## submit handler calls), the Watches tab selected by a click on the tab
## button, and the IsoNim view the browser mounts.
##
## THE STAND-INS, and why each is needed:
## - `MockBackendService`, answering `ct/load-locals` FROM ITS OWN ARGUMENTS:
##   one row marked `value.isWatch` per expression the request named, shaped
##   as the replay answers a Noir `Field` (a `String` carrying `0x` + 64 hex
##   digits, `db-backend` via `noir/tooling/tracer`'s `field_to_hex`). A canned
##   answer carrying the watch row would draw it whatever the request asked,
##   so "the row is there" would not mean "the watch was asked for".
## - `MockRenderer`: IsoNim's renderer-agnostic DOM, so the view code the
##   browser runs (`renderStatePanel`) is walked natively. It is the same
##   generic proc instantiated for the browser's `WebRenderer`.
##
## Runs on the C and JS backends (`vm-unit`, `vm-unit-js`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_watch_row_reads_by_name.nim

import std/[json, strutils, tables, unittest]

import isonim/core/[async_compat, owner, signals]
import isonim/testing/mock_dom

import backend/[backend_service, mock_backend]
import store/replay_data_store
import viewmodels/state_vm
import views/isonim_state_view
import sdk/[debugger_session, trace_source]

const
  InitialShieldHex =
    "0x0000000000000000000000000000000000000000000000000000000000002710"
    ## 10000, as the Noir tracer records a `Field`.

proc answeringWatchesFromTheRequest(mock: MockBackendService): BackendService =
  ## The mock's transport, except that `ct/load-locals` is answered from the
  ## request: one local, plus one `isWatch` row per requested expression,
  ## each with the origin summary the engine attaches to a local's row.
  result = mock.toBackendService()
  let inner = result.sendProc
  result.sendProc = proc(command: string;
                         args: JsonNode): BackendFuture[JsonNode] =
    let viaMock = inner(command, args)
    if command != "ct/load-locals":
      return viaMock
    var rows = newJArray()
    rows.add %*{"expression": "initial_shield", "value": {
      "kind": 9, "text": InitialShieldHex,
      "typ": {"kind": 9, "langType": "Field"}}}
    for w in args{"watchExpressions"}.getElems:
      rows.add %*{
        "expression": w.getStr,
        "value": {"kind": 9, "text": InitialShieldHex, "isWatch": true,
                  "typ": {"kind": 9, "langType": "Field"}},
        "originSummary": {"confidence": 1.0, "hopCount": 1,
                          "isPlaceholder": false, "placeholderToken": nil,
                          "terminatorExpr": "10000",
                          "terminatorFunction": "main",
                          "terminatorKind": "literal"}}
    newCompletedFuture[JsonNode](%*{"success": true, "body": {"locals": rows}})

proc elementsNamed(node: MockNode; name: string; acc: var seq[MockNode]) =
  ## Every element whose `data-variable-name` is `name` — what
  ## `querySelectorAll("[data-variable-name]")` filtered by name returns.
  if node.kind == mnkElement and
      node.attributes.getOrDefault("data-variable-name", "") == name:
    acc.add node
  for child in node.children:
    elementsNamed(child, name, acc)

proc elementsNamed(node: MockNode; name: string): seq[MockNode] =
  elementsNamed(node, name, result)

proc firstWithClass(node: MockNode; cls: string): MockNode =
  if node.kind == mnkElement and
      cls in node.attributes.getOrDefault("class", "").split(' '):
    return node
  for child in node.children:
    let found = firstWithClass(child, cls)
    if found != nil:
      return found
  nil

suite "a watch typed into the Variables pane is one row, readable by its name":

  test "the list holds one element named after the watch, and it shows the answer":
    createRoot proc(done: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let s = newDebuggerSession(mock.answeringWatchesFromTheRequest())
      s.attach(localFolderTrace("/tmp/noir_space_ship"))
      s.store.updateDebuggerPosition(5'u64, "/src/main.nr", 3)
      drainPlatformCallbacks()

      let vm = s.session.stateVM
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), vm)
      # What the watch input's submit handler calls.
      vm.addWatch("initial_shield")
      drainPlatformCallbacks()

      # The request carried the watch, and its answer was applied.
      var asked = false
      for c in mock.receivedCommands:
        if c.command == "ct/load-locals" and
            c.args{"watchExpressions"} == %*["initial_shield"]:
          asked = true
      check asked
      check s.store.locals.watches.val.len == 1

      # THE ASSERTION THE DEFECT FAILS: one element per row by that name.
      # The pane is one list (Variable-State-Pane.md, 2026-10-24), so the
      # local `initial_shield` and the watch `initial_shield` are two rows,
      # the watch last — and no element inside a row repeats the name.
      let named = panel.elementsNamed("initial_shield")
      check named.len == 2
      if named.len >= 1:
        let row = named[^1]   # the one a "last write wins" reader keeps
        check "value-expanded" in row.attributes.getOrDefault("class", "")
        check "value-watch" in row.attributes.getOrDefault("class", "")
        let valueCell = firstWithClass(row, "value-expanded-text")
        check not valueCell.isNil
        if not valueCell.isNil:
          # The presenter's rendering of a `Field` (PLAT-2): leading zeros
          # stripped, so 10000 reads `0x2710`.
          check valueCell.textContent == "0x2710"
        # The origin badge is still the row's, found inside it.
        check not firstWithClass(row, "ct-origin-badge").isNil

      s.dispose()
      done()
