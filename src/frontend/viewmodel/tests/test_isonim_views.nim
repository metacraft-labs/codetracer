## test_isonim_views.nim
##
## Unit tests for the IsoNim DOM-rendering State panel view.
##
## Verifies that `renderStatePanel` produces the correct MockNode tree
## and that reactive updates (tab switching, variable list changes,
## loading state) propagate to the DOM automatically.
##
## Uses MockRenderer for headless testing — no browser required.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_isonim_views.nim

import std/[unittest, asyncdispatch, strutils, tables]
import isonim/core/[signals, owner]
import isonim/testing/mock_dom
import ../backend/backend_service
import ../backend/mock_backend
import ../store/types
import ../store/replay_data_store
import ../viewmodels/state_vm
import ../views/isonim_state_view

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  try:
    poll(0)
  except ValueError:
    discard

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc findByClass*(node: MockNode; cls: string): MockNode =
  ## Find the first descendant (or self) whose "class" attribute
  ## contains `cls` as a whole word. Returns nil if not found.
  if node.kind == mnkElement:
    let nodeClass = node.attributes.getOrDefault("class", "")
    # Check if cls appears as a whole word in the class attribute.
    for part in nodeClass.split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  return nil

proc findAllByClass*(node: MockNode; cls: string): seq[MockNode] =
  ## Find all descendants (including self) whose "class" attribute
  ## contains `cls` as a whole word.
  if node.kind == mnkElement:
    let nodeClass = node.attributes.getOrDefault("class", "")
    for part in nodeClass.split(' '):
      if part == cls:
        result.add(node)
        break
  for child in node.children:
    result.add(findAllByClass(child, cls))

proc findByTag*(node: MockNode; tag: string): MockNode =
  ## Find the first descendant (or self) with the given tag name.
  if node.kind == mnkElement and node.tag == tag:
    return node
  for child in node.children:
    let found = findByTag(child, tag)
    if found != nil:
      return found
  return nil

# ---------------------------------------------------------------------------
# Structure tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — structure":

  test "renders root with state-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "state-component"

      dispose()

  test "renders three tab buttons":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let tabBar = findByClass(panel, "state-tabs")
      check tabBar != nil
      check tabBar.tag == "div"

      let localsBtn = findByClass(panel, "tab-locals")
      let globalsBtn = findByClass(panel, "tab-globals")
      let watchesBtn = findByClass(panel, "tab-watches")

      check localsBtn != nil
      check globalsBtn != nil
      check watchesBtn != nil

      check localsBtn.tag == "button"
      check globalsBtn.tag == "button"
      check watchesBtn.tag == "button"

      # Locals tab should have the "active" class by default
      check "active" in localsBtn.attributes["class"]
      check "active" notin globalsBtn.attributes["class"]
      check "active" notin watchesBtn.attributes["class"]

      dispose()

  test "renders variable list container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let container = findByClass(panel, "value-components-container")
      check container != nil
      check container.tag == "div"

      dispose()

  test "renders loading indicator (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let indicator = findByClass(panel, "loading-indicator")
      check indicator != nil
      check indicator.styles.getOrDefault("display", "none") == "none"

      dispose()

  test "renders watch input container (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let watchContainer = findByClass(panel, "watch-input-container")
      check watchContainer != nil
      check watchContainer.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Tab switching tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — tab switching":

  test "clicking globals tab updates active class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let globalsBtn = findByClass(panel, "tab-globals")
      check globalsBtn != nil
      globalsBtn.fireEvent("click")

      check vm.activeTab.val == stGlobals

      # Active class should have moved
      check "active" in globalsBtn.attributes["class"]

      let localsBtn = findByClass(panel, "tab-locals")
      check "active" notin localsBtn.attributes["class"]

      dispose()

  test "clicking watches tab shows watch input":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let watchesBtn = findByClass(panel, "tab-watches")
      check watchesBtn != nil
      watchesBtn.fireEvent("click")

      check vm.activeTab.val == stWatches

      let watchContainer = findByClass(panel, "watch-input-container")
      check watchContainer != nil
      check watchContainer.styles["display"] == "block"

      dispose()

  test "switching back to locals hides watch input":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      # Go to watches
      let watchesBtn = findByClass(panel, "tab-watches")
      watchesBtn.fireEvent("click")

      let watchContainer = findByClass(panel, "watch-input-container")
      check watchContainer.styles["display"] == "block"

      # Go back to locals
      let localsBtn = findByClass(panel, "tab-locals")
      localsBtn.fireEvent("click")

      check watchContainer.styles["display"] == "none"

      dispose()

# ---------------------------------------------------------------------------
# Variable rendering tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — variables":

  test "renders local variables":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      store.updateLocals(@[
        makeVariable("x", "42", "int"),
        makeVariable("y", "hello", "string"),
      ])

      let panel = renderStatePanel(r, vm)
      let container = findByClass(panel, "value-components-container")
      check container != nil

      let rows = findAllByClass(container, "variable-row")
      check rows.len == 2

      # Check first variable content
      let firstText = rows[0].textContent
      check "x" in firstText
      check "42" in firstText
      check "int" in firstText

      # Check second variable content
      let secondText = rows[1].textContent
      check "y" in secondText
      check "hello" in secondText

      dispose()

  test "variables update reactively when store changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      # Initially no variables
      let container = findByClass(panel, "value-components-container")
      check container.children.len == 0

      # Add variables
      store.updateLocals(@[
        makeVariable("count", "7", "int"),
      ])

      check container.children.len == 1
      check "count" in container.children[0].textContent
      check "7" in container.children[0].textContent

      # Update variables
      store.updateLocals(@[
        makeVariable("count", "8", "int"),
        makeVariable("name", "\"world\"", "string"),
      ])

      check container.children.len == 2
      check "8" in container.children[0].textContent
      check "name" in container.children[1].textContent

      dispose()

  test "switching to globals shows global variables":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      store.updateLocals(@[
        makeVariable("localVar", "1", "int"),
      ])
      store.locals.globals.val = @[
        Variable(name: "globalVar", value: "99", typeName: "int",
                 hasChildren: false, children: @[]),
      ]

      let panel = renderStatePanel(r, vm)

      # Initially shows locals
      let container = findByClass(panel, "value-components-container")
      check container.children.len == 1
      check "localVar" in container.children[0].textContent

      # Switch to globals
      vm.selectTab(stGlobals)

      check container.children.len == 1
      check "globalVar" in container.children[0].textContent

      dispose()

  test "expanded variable shows children":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      store.updateLocals(@[
        makeVariable("obj", "{...}", "MyObj",
          hasChildren = true,
          children = @[
            makeVariable("field1", "10", "int"),
            makeVariable("field2", "20", "int"),
          ]),
      ])

      let panel = renderStatePanel(r, vm)
      let container = findByClass(panel, "value-components-container")

      # Initially collapsed: only the parent row
      check container.children.len == 1

      # Expand
      vm.toggleExpand("obj")

      # Now should show parent + 2 children = 3 rows
      check container.children.len == 3
      check "obj" in container.children[0].textContent
      check "field1" in container.children[1].textContent
      check "field2" in container.children[2].textContent

      dispose()

# ---------------------------------------------------------------------------
# Loading state tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — loading":

  test "loading indicator becomes visible when loading":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let indicator = findByClass(panel, "loading-indicator")

      check indicator.styles["display"] == "none"

      store.locals.loadingState.val = lsLoading
      check indicator.styles["display"] == "block"

      store.locals.loadingState.val = lsIdle
      check indicator.styles["display"] == "none"

      dispose()

# ---------------------------------------------------------------------------
# Text content tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — text content":

  test "tab buttons have correct text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let localsBtn = findByClass(panel, "tab-locals")
      let globalsBtn = findByClass(panel, "tab-globals")
      let watchesBtn = findByClass(panel, "tab-watches")

      check localsBtn.textContent == "Locals"
      check globalsBtn.textContent == "Globals"
      check watchesBtn.textContent == "Watches"

      dispose()

  test "loading indicator shows Loading text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let indicator = findByClass(panel, "loading-indicator")

      check indicator.textContent == "Loading..."

      dispose()

  test "watch input has placeholder":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let input = findByClass(panel, "watch-input")

      check input != nil
      check input.attributes["placeholder"] == "Add watch expression..."

      dispose()
