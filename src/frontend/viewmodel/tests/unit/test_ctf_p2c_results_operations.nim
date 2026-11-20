## CTF-P2c step 2: the omnibox result commands' keys and presses are routed
## operations, the same in every host (study D48; Input-Routing-And-Keymaps.md
## §4 and §5.1), and the web view draws what the viewmodel holds.
##
## * **The keys are keymap rows**: the router resolves `Enter`, `Down`, `Up`
##   and `Tab` in the results' scope to `results.open`, `results.next`,
##   `results.previous` and `results.insert`, and `runResultsOperation`
##   moves the viewmodel.
## * **The catalogue holds every operation** the results' elements carry or
##   their keys run, in the results' table.
## * **The web view carries them**: on IsoNim's mock renderer every row
##   carries `results.open` and its index, `+N more` `results.more` and its
##   group, the way back `results.all`; the results are the `results` scope
##   (`data-ct-pane`), and the view installs no press handler of its own.
## * **A press routed as the page's pointer listener routes it** does what
##   the operation says: a row opens, `+N more` shows its group alone, the
##   way back shows every group.
## * **The view draws the viewmodel**: each group's id, state and rows in
##   order, the query's match in bold, a rich row's sandboxed box with its
##   height held to 12rem, and the scripts of an untrusted box taken out.
##
## No mocks beyond IsoNim's mock renderer (the view's DOM): the viewmodels
## are the results stories' own (`createResultsStoryVM`), over the scripted
## providers and Agent Harbor source those stories use.

import std/[sequtils, strutils, tables, unittest]
import isonim/core/owner
import isonim/testing/mock_dom
import ../../views/isonim_agent_harbor_results_view
import ../../../stories/agent_harbor_results_stories
import ../../keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                     editing_keymap, operation_catalogue]
import ../../input/element_press

let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feTerminal,
  platform: hostPlatform(), keyProtocol: kpLegacy))
let path = @[element(ekWindow, "window"), pane(ResultsScope)]

proc collect(n: MockNode; name: string; into: var seq[MockNode]) =
  if n.attributes.hasKey(name): into.add n
  for ch in n.children: collect(ch, name, into)

proc all(n: MockNode; name: string): seq[MockNode] = collect(n, name, result)

proc attr(n: MockNode; name: string): string = n.attributes.getOrDefault(name, "")

proc textOf(n: MockNode): string = n.textContent
  ## Its text and its children's (`mock_dom.textContent`).

proc classed(n: MockNode; class: string; into: var seq[MockNode]) =
  if class in n.attr("class").splitWhitespace: into.add n
  for ch in n.children: classed(ch, class, into)

proc byClass(n: MockNode; class: string): seq[MockNode] = classed(n, class, result)

proc handlers(n: MockNode): int =
  result = n.eventListeners.len + n.eventHandlers.len + n.pointerHandlers.len
  for ch in n.children: result += handlers(ch)

proc render(vm: ResultCommandsVM): MockNode =
  renderAgentHarborResults[MockRenderer, MockNode](MockRenderer(), vm)

proc carrying(root: MockNode; operation: string): seq[MockNode] =
  root.all(OperationAttribute).filterIt(it.attr(OperationAttribute) == operation)

proc press(vm: ResultCommandsVM; el: MockNode): string =
  ## A press on `el` as the page's pointer listener routes it; the host runs
  ## it on the element's target. Returns the operation run ("" declined).
  let outcome = resolveElementPress(routerResolver(router, SessionFacts()), path,
    ButtonElementKind, el.attr(OperationAttribute), {}, "Click")
  if vm.runResultsPress(outcome.operation, el.attr(ResultsTargetAttribute)):
    outcome.operation
  else: ""

proc withResults(fixture: string; body: proc(vm: ResultCommandsVM)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = createResultsStoryVM(fixture)
    body(vm)
    vm.dispose()
    disposeRoot()

suite "the results' keys are keymap rows":
  test "each key resolves to the results' operation in their scope":
    for (op, key) in [(ResultsOpenOperation, "Enter"), (ResultsNextOperation, "Down"),
                      (ResultsPreviousOperation, "Up"), (ResultsInsertOperation, "Tab")]:
      check router.chordFor(op, SessionFacts(), path, nmNormal) == key

  test "every operation is catalogued in the results' table":
    var catalogued: seq[string]
    for entry in Catalogue:
      if entry.table == ResultsTable: catalogued.add entry.name
    for op in @ResultsOperations & @ResultsPressOperations:
      check op in catalogued
    check catalogued.len == 6

  test "Down and Up move the selection, Enter opens, Tab inserts":
    withResults("search-final", proc(vm: ResultCommandsVM) =
      check vm.runResultsOperation(ResultsNextOperation)
      check vm.selected.val == 1
      check vm.runResultsOperation(ResultsPreviousOperation)
      check vm.selected.val == 0
      check vm.runResultsOperation(ResultsOpenOperation)
      check vm.openedLine == "Opened src/shield.nr"
      check not vm.runResultsOperation("composer.send"))
    withResults("slash-completion", proc(vm: ResultCommandsVM) =
      check vm.runResultsOperation(ResultsInsertOperation)
      check vm.input == "/ai Check the clamp against the spec and /nargo-test ")

suite "the web view carries the operations and holds no handler":
  test "every row, +N more and the way back name their operation and target":
    withResults("search-final", proc(vm: ResultCommandsVM) =
      let root = vm.render
      check root.all("data-ct-pane").mapIt(it.attr("data-ct-pane")) == @[ResultsScope]
      check root.handlers == 0
      let rows = root.carrying(ResultsOpenOperation)
      check rows.len == vm.selectableRows.len
      for i, row in rows: check row.attr(ResultsTargetAttribute) == $i
      check root.carrying(ResultsMoreOperation).mapIt(it.attr(ResultsTargetAttribute)) ==
            @["symbols", "program-text"])

  test "+N more shows the group alone; the way back shows every group":
    withResults("search-long", proc(vm: ResultCommandsVM) =
      var root = vm.render
      check vm.press(root.carrying(ResultsMoreOperation)[0]) == ResultsMoreOperation
      check vm.alone.val == "program-text"
      root = vm.render
      check root.all("data-ah-group").mapIt(it.attr("data-ah-group")) == @["program-text"]
      check vm.press(root.carrying(ResultsAllOperation)[0]) == ResultsAllOperation
      check vm.alone.val == "")

  test "a press on a row opens it; one with a target it cannot read is declined":
    withResults("search-final", proc(vm: ResultCommandsVM) =
      let root = vm.render
      check vm.press(root.carrying(ResultsOpenOperation)[1]) == ResultsOpenOperation
      check vm.selected.val == 1
      check vm.openedLine.startsWith("Opened src/")
      check not vm.runResultsPress(ResultsOpenOperation, "not a number")
      check not vm.runResultsPress(ResultsMoreOperation, ""))

suite "the web view draws the viewmodel":
  test "each group's id, state and rows, in order; the match in bold":
    withResults("search-partial", proc(vm: ResultCommandsVM) =
      let root = vm.render
      var ids, states, words: seq[string]
      for g in vm.groups:
        ids.add g.group.id
        states.add $g.group.state
        words.add stateWord(g.group)
      let groups = root.all("data-ah-group")
      check groups.mapIt(it.attr("data-ah-group")) == ids
      check groups.mapIt(it.attr("data-ah-state")) == states
      check root.byClass("ah-results-state").mapIt(it.textOf) == words
      var titles: seq[string]
      for g in vm.groups:
        for r in g.rows: titles.add r.title
      check root.all("data-ah-title").mapIt(it.attr("data-ah-title")) == titles
      for m in root.byClass("ah-results-match"):
        check m.textOf.toLowerAscii == "shield"
      check root.byClass("ah-results-row-selected").len == 1)

  test "a rich row's box is a frame held to what its source asks; without HTML, no frame":
    withResults("rich-rows", proc(vm: ResultCommandsVM) =
      let root = vm.render
      let frames = root.byClass("ah-results-box")
      check frames.len == 3
      check frames.mapIt(it.attr("style")) ==
            @["height: 132px", "height: 120px", "height: 64px"]
      check root.byClass("ah-results-note").mapIt(it.textOf) == @[ScriptsNotRun])
    withResults("text-fallback", proc(vm: ResultCommandsVM) =
      let root = vm.render
      check root.byClass("ah-results-box").len == 0
      check root.byClass("ah-results-tag-html").len == 0)

  test "an untrusted box is given its HTML without its scripts":
    withResults("rich-rows", proc(vm: ResultCommandsVM) =
      var untrusted = 0
      for row in vm.selectableRows:
        if row.html.len > 0 and not row.trusted:
          inc untrusted
          check "<script" in row.html.toLowerAscii
          check "<script" notin boxHtml(row).toLowerAscii
      check untrusted == 1)
