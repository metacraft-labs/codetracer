## views/isonim_test_results_view.nim
##
## IsoNim view for the Test Results pane (`Content.TestResults`).
##
## Structure, both renderers::
##
##   div.component-container.test-results
##     div.test-results-headline      text "5 tests, not run yet"
##     div.test-results-body
##       div.test-results-row[.not-run|.passed|.failed|…]   (one per test)
##         span.test-results-mark      "✓" / "✗" / "·" / …
##         span.test-results-name      "test_main"
##         span.test-results-where     "src/main.nr:13"
##         span.test-results-duration  "2 ms"   (only once it has run)
##         div.test-results-message                (failures only)
##     div.test-results-absence[.hidden]
##       text  why a run cannot be started here
##     div.test-results-empty[.hidden]
##       text "No tests found in this project."
##
## ## Why the mark is a glyph and the state is also a class
##
## §1a's mock-up reads `✓ test_main 2ms`, so the glyph is what a user scans.
## But a glyph is not a machine-readable state, and
## `ci/test/web-renderer-mounts.sh` asserts on PAINTED TEXT — so the class
## carries the state for CSS and the glyph carries it for the reader, and the
## gate can check either. The row's text is deliberately self-sufficient: a
## reader who cannot see colour still gets mark, name, location and duration.
##
## ## The absence line is not an error state
##
## `runAbsence` is shown as ordinary content, below the rows, because on the
## web it is the permanent and correct answer — there is no `nargo` in a tab
## and the wasm worker dispatches only `compile` and `trace`. Rendering it as
## an error would tell a visitor something is broken when nothing is.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/test_results_vm

const TestResultsContainerClass* = "component-container test-results"

const EmptyStateText* = "No tests found in this project."

proc stateClass*(state: TestResultsRowState): string =
  "test-results-row " & $state

proc stateMark*(state: TestResultsRowState): string =
  ## The glyph §1a's mock-up uses, extended to the states a real run has.
  ## `·` for not-run rather than a blank, so every row has a mark column and
  ## the list does not look ragged.
  case state
  of trsNotRun: "·"
  of trsRunning: "…"
  of trsPassed: "✓"
  of trsFailed: "✗"
  of trsSkipped: "–"
  of trsErrored: "!"
  of trsCancelled: "×"

proc rowWhere*(row: TestResultsRow): string =
  if row.file.len == 0: ""
  elif row.line > 0: row.file & ":" & $row.line
  else: row.file

proc rowDuration*(row: TestResultsRow): string =
  ## Empty until the test has actually run. "0 ms" against a test nobody
  ## started is a measurement the pane did not make.
  if row.state == trsNotRun: ""
  else: formatDurationMs(row.durationMs)

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderRowMock(r: MockRenderer; row: TestResultsRow): MockNode =
  let mark = stateMark(row.state)
  let where = rowWhere(row)
  let duration = rowDuration(row)
  let message = row.message
  let node = ui(r):
    tdiv(class = stateClass(row.state)):
      span(class = "test-results-mark"):
        text mark
      span(class = "test-results-name"):
        text row.name
      span(class = "test-results-where"):
        text where
      span(class = "test-results-duration"):
        text duration
  if message.len > 0:
    let detail = ui(r):
      tdiv(class = "test-results-message"):
        text message
    r.appendChild(node, detail)
  node

proc renderTestResultsPanel*(r: MockRenderer; vm: TestResultsVM): MockNode =
  var headlineNode: MockNode
  var bodyContainer: MockNode
  var absenceNode: MockNode
  var emptyContainer: MockNode

  let panel = ui(r):
    tdiv(class = TestResultsContainerClass, tabIndex = "2"):
      tdiv(ref = headlineNode, class = "test-results-headline"):
        discard
      tdiv(ref = bodyContainer, class = "test-results-body"):
        discard
      tdiv(ref = absenceNode, class = "test-results-absence hidden"):
        discard
      tdiv(ref = emptyContainer, class = "test-results-empty hidden"):
        text EmptyStateText

  createRenderEffect proc() =
    let rows = vm.rows.val
    let absence = vm.runAbsence.val

    r.clearChildren(headlineNode)
    r.appendChild(headlineNode, r.createTextNode(vm.headline.val))

    r.clearChildren(bodyContainer)
    for row in rows:
      r.appendChild(bodyContainer, renderRowMock(r, row))

    r.clearChildren(absenceNode)
    if absence.len > 0:
      r.appendChild(absenceNode, r.createTextNode(absence))
      r.setAttribute(absenceNode, "class", "test-results-absence")
    else:
      r.setAttribute(absenceNode, "class", "test-results-absence hidden")

    if rows.len == 0:
      r.setAttribute(emptyContainer, "class", "test-results-empty")
    else:
      r.setAttribute(emptyContainer, "class", "test-results-empty hidden")

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc webElement(tag, cssClass: string): isonim_dom.Element =
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    n

  proc webTextElement(tag, textValue, cssClass: string): isonim_dom.Element =
    let n = webElement(tag, cssClass)
    isonim_dom.appendChild(isonim_dom.Node(n),
      isonim_dom.createTextNode(isonim_dom.document, cstring(textValue)))
    n

  proc clearWeb(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc setWebText(node: isonim_dom.Element; value: string) =
    clearWeb(node)
    if value.len > 0:
      isonim_dom.appendChild(isonim_dom.Node(node),
        isonim_dom.createTextNode(isonim_dom.document, cstring(value)))

  proc renderRowWeb(row: TestResultsRow): isonim_dom.Element =
    let node = webElement("div", stateClass(row.state))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", stateMark(row.state),
                                     "test-results-mark")))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", row.name, "test-results-name")))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", rowWhere(row),
                                     "test-results-where")))
    isonim_dom.appendChild(isonim_dom.Node(node),
      isonim_dom.Node(webTextElement("span", rowDuration(row),
                                     "test-results-duration")))
    if row.message.len > 0:
      isonim_dom.appendChild(isonim_dom.Node(node),
        isonim_dom.Node(webTextElement("div", row.message,
                                       "test-results-message")))
    node

  proc renderTestResultsPanel*(r: WebRenderer;
                               vm: TestResultsVM): isonim_dom.Element =
    var headlineNode: isonim_dom.Element
    var bodyContainer: isonim_dom.Element
    var absenceNode: isonim_dom.Element
    var emptyContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = TestResultsContainerClass, tabIndex = "2"):
        tdiv(ref = headlineNode, class = "test-results-headline"):
          discard
        tdiv(ref = bodyContainer, class = "test-results-body"):
          discard
        tdiv(ref = absenceNode, class = "test-results-absence hidden"):
          discard
        tdiv(ref = emptyContainer, class = "test-results-empty hidden"):
          text EmptyStateText

    createRenderEffect proc() =
      let rows = vm.rows.val
      let absence = vm.runAbsence.val

      setWebText(headlineNode, vm.headline.val)

      clearWeb(bodyContainer)
      for row in rows:
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(renderRowWeb(row)))

      setWebText(absenceNode, absence)
      isonim_dom.setAttribute(absenceNode, cstring"class",
        cstring(if absence.len > 0: "test-results-absence"
                else: "test-results-absence hidden"))

      isonim_dom.setAttribute(emptyContainer, cstring"class",
        cstring(if rows.len == 0: "test-results-empty"
                else: "test-results-empty hidden"))

    panel

  proc mountIsoNimTestResultsPanel*(container: isonim_dom.Element;
                                    vm: TestResultsVM) =
    let r = WebRenderer()
    let panel = renderTestResultsPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
