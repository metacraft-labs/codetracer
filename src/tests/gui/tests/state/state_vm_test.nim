## test_state_vm.nim
##
## Unit tests for StateVM — the ViewModel for the state (locals/globals/watches)
## panel.
##
## Verifies:
## - Initial state defaults (activeTab, expandedPaths, selectedPath, etc.)
## - Tab switching via selectTab updates activeTab and currentVariables
## - toggleExpand adds/removes paths from expandedPaths
## - selectPath sets the selected variable path
## - addWatch / removeWatch manage the watch expressions list
## - currentVariables memo returns locals when on stLocals tab
## - currentVariables memo returns globals when on stGlobals tab
## - isLoading memo reflects store loading state
## - Auto-load effect fires requestLocals when debugger rrTicks changes
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_state_vm.nim

import std/[json, unittest, sets, options, strutils]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/state_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  ## Returns both so tests can inspect the mock's receivedCommands.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "StateVM initial state":

  test "activeTab defaults to stLocals":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.activeTab.val == stLocals
      dispose()

  test "expandedPaths starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.expandedPaths.val.len == 0
      dispose()

  test "selectedPath starts as empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.selectedPath.val == ""
      dispose()

  test "watchExpressions starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.watchExpressions.val.len == 0
      dispose()

  test "isLoading starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      # See calltrace's "isLoading starts false" — the auto-load
      # effect briefly sets lsLoading; drain() lets the mock backend's
      # response callback flip it back to lsIdle.
      drain()
      check vm.isLoading.val == false
      dispose()

  test "currentVariables starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.currentVariables.val.len == 0
      dispose()

# ---------------------------------------------------------------------------
# Tab switching
# ---------------------------------------------------------------------------

suite "StateVM tab switching":

  test "selectTab changes activeTab signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectTab(stGlobals)
      check vm.activeTab.val == stGlobals

      vm.selectTab(stWatches)
      check vm.activeTab.val == stWatches

      vm.selectTab(stLocals)
      check vm.activeTab.val == stLocals

      dispose()

  test "currentVariables returns locals when on stLocals tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      # Populate the store's locals signal directly.
      let testLocals = @[
        Variable(name: "x", value: "42", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "y", value: "hello", typeName: "string",
                 hasChildren: false, children: @[]),
      ]
      store.locals.locals.val = testLocals

      vm.selectTab(stLocals)
      check vm.currentVariables.val.len == 2
      check vm.currentVariables.val[0].name == "x"
      check vm.currentVariables.val[1].name == "y"

      dispose()

  test "currentVariables returns globals when on stGlobals tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      # Populate globals.
      let testGlobals = @[
        Variable(name: "gCounter", value: "7", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      store.locals.globals.val = testGlobals

      vm.selectTab(stGlobals)
      check vm.currentVariables.val.len == 1
      check vm.currentVariables.val[0].name == "gCounter"

      dispose()

  test "currentVariables returns empty seq when on stWatches tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      # Even if locals and globals have data, watches tab returns empty
      # (watch results are not yet wired through the store).
      store.locals.locals.val = @[
        Variable(name: "x", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      store.locals.globals.val = @[
        Variable(name: "g", value: "2", typeName: "int",
                 hasChildren: false, children: @[]),
      ]

      vm.selectTab(stWatches)
      check vm.currentVariables.val.len == 0

      dispose()

  test "currentVariables updates reactively when tab changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.locals.locals.val = @[
        Variable(name: "local1", value: "a", typeName: "string",
                 hasChildren: false, children: @[]),
      ]
      store.locals.globals.val = @[
        Variable(name: "global1", value: "b", typeName: "string",
                 hasChildren: false, children: @[]),
      ]

      # Track via an effect.
      var observed: seq[Variable] = @[]
      createEffect proc() =
        observed = vm.currentVariables.val

      # Initially on locals tab.
      check observed.len == 1
      check observed[0].name == "local1"

      # Switch to globals.
      vm.selectTab(stGlobals)
      check observed.len == 1
      check observed[0].name == "global1"

      dispose()

# ---------------------------------------------------------------------------
# Expand / collapse
# ---------------------------------------------------------------------------

suite "StateVM expand/collapse":

  test "toggleExpand adds a path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.toggleExpand("x")
      check "x" in vm.expandedPaths.val

      dispose()

  test "toggleExpand removes an already expanded path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.toggleExpand("x")
      check "x" in vm.expandedPaths.val

      vm.toggleExpand("x")
      check "x" notin vm.expandedPaths.val

      dispose()

  test "toggleExpand handles multiple paths independently":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.toggleExpand("a")
      vm.toggleExpand("b")
      vm.toggleExpand("c")

      check "a" in vm.expandedPaths.val
      check "b" in vm.expandedPaths.val
      check "c" in vm.expandedPaths.val

      # Collapse only "b"
      vm.toggleExpand("b")
      check "a" in vm.expandedPaths.val
      check "b" notin vm.expandedPaths.val
      check "c" in vm.expandedPaths.val

      dispose()

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

suite "StateVM selection":

  test "selectPath sets the selected path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectPath("myVar.field")
      check vm.selectedPath.val == "myVar.field"

      dispose()

  test "selectPath with empty string clears selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectPath("x")
      check vm.selectedPath.val == "x"

      vm.selectPath("")
      check vm.selectedPath.val == ""

      dispose()

# ---------------------------------------------------------------------------
# Watch expressions
# ---------------------------------------------------------------------------

suite "StateVM watch expressions":

  test "addWatch appends a new expression":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("counter")
      check vm.watchExpressions.val == @["counter"]

      vm.addWatch("total")
      check vm.watchExpressions.val == @["counter", "total"]

      dispose()

  test "addWatch ignores empty strings":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("")
      check vm.watchExpressions.val.len == 0

      dispose()

  test "addWatch ignores duplicate expressions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("x")
      vm.addWatch("x")
      check vm.watchExpressions.val == @["x"]

      dispose()

  test "removeWatch removes an existing expression":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("a")
      vm.addWatch("b")
      vm.addWatch("c")

      vm.removeWatch("b")
      check vm.watchExpressions.val == @["a", "c"]

      dispose()

  test "removeWatch is a no-op for non-existent expressions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("x")
      vm.removeWatch("y")
      check vm.watchExpressions.val == @["x"]

      dispose()

# ---------------------------------------------------------------------------
# isLoading memo
# ---------------------------------------------------------------------------

suite "StateVM isLoading":

  test "isLoading reflects store loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      # Drain to flush the auto-load response and reach the
      # idle-after-load baseline before manually asserting transitions.
      drain()

      check vm.isLoading.val == false

      store.locals.loadingState.val = lsLoading
      check vm.isLoading.val == true

      store.locals.loadingState.val = lsIdle
      check vm.isLoading.val == false

      dispose()

  test "isLoading is false when loading state is lsError":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.locals.loadingState.val = lsError
      check vm.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# Auto-load effect
# ---------------------------------------------------------------------------

suite "StateVM auto-load effect":

  test "changing rrTicks triggers requestLocals on the backend":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # The auto-load effect fires on creation (no rrTicks guard),
      # so clear initial commands to isolate the position change.
      mock.clearReceivedCommands()

      # Simulate the debugger moving to a new position.
      var dbg = store.debugger.val
      dbg.rrTicks = 100'u64
      store.debugger.val = dbg
      drain()

      # The effect should have triggered requestLocals.
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "ct/load-locals"
      check mock.receivedCommands[0].args["rrTicks"].getBiggestInt == 100

      dispose()

  test "auto-load effect fires again when rrTicks changes a second time":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # The auto-load effect no longer guards on rrTicks > 0, so
      # the initial effect run at rrTicks=0 also fires a request.
      let initialCount = mock.receivedCommands.len

      # First move.
      var dbg = store.debugger.val
      dbg.rrTicks = 50'u64
      store.debugger.val = dbg
      drain()
      check mock.receivedCommands.len == initialCount + 1

      # Second move — different rrTicks, so a new request should fire.
      dbg = store.debugger.val
      dbg.rrTicks = 75'u64
      store.debugger.val = dbg
      drain()
      check mock.receivedCommands.len == initialCount + 2
      check mock.receivedCommands[^1].args["rrTicks"].getBiggestInt == 75

      dispose()

  test "auto-load effect fires even for rrTicks == 0 (DB-based traces)":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # The auto-load effect no longer guards on rrTicks > 0 because
      # DB-based traces always have rrTicks=0. RequestTracker handles
      # deduplication of redundant requests.
      # The initial effect run at rrTicks=0 fires a request.
      check mock.receivedCommands.len >= 1
      check mock.receivedCommands[0].command == "ct/load-locals"

      dispose()

# ---------------------------------------------------------------------------
# Code-state-line population (mirrors the legacy ``StateComponent.excerpt``
# proc which read ``data.ui.editors[path].sourceLines[line - 1]`` and
# rendered ``#code-state-line-{id}``).
#
# These tests reproduce the DB-trace gap closed by TODO 5.2(g):
# ``replay_data_store.updateCodeStateLine`` is the bridge from the legacy
# ``state.nim`` move handler into the StateVM, and the ``codeStateLine``
# memo is what the IsoNim view reads to render the populated /
# ``no-code`` markup.
# ---------------------------------------------------------------------------

suite "StateVM code-state-line":

  test "codeStateLine starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.codeStateLine.val == ""
      dispose()

  test "updateCodeStateLine populates the memo with the formatted text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      # Simulates the ``state.nim`` move handler resolving the source
      # line for the current debugger position.
      store.updateCodeStateLine(11, "    let result = add(x, y);")
      check vm.codeStateLine.val == "11 |     let result = add(x, y);"

      dispose()

  test "updateCodeStateLine with empty source clears the memo":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.updateCodeStateLine(10, "let x = 3;")
      check vm.codeStateLine.val == "10 | let x = 3;"

      # Empty source = "no source available" (the editor for this path
      # hasn't loaded its source lines yet). The view falls back to
      # the ``no-code`` class.
      store.updateCodeStateLine(11, "")
      check vm.codeStateLine.val == ""

      dispose()

  test "codeStateLine memo updates reactively as moves occur":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      var observed: seq[string] = @[]
      createEffect proc() =
        observed.add(vm.codeStateLine.val)

      # Initial empty value.
      check observed == @[""]

      store.updateCodeStateLine(5, "fn main() {")
      store.updateCodeStateLine(7, "    let x = 1;")
      store.updateCodeStateLine(8, "    let y = 2;")

      check observed == @[
        "",
        "5 | fn main() {",
        "7 |     let x = 1;",
        "8 |     let y = 2;",
      ]

      dispose()

# ---------------------------------------------------------------------------
# DB-trace move scenario — exercises the full update path that drives
# the IsoNim state view for Materialized traces (rrTicks always = 0):
#   CtCompleteMove arrives, updateDebuggerPosition mutates the store's
#   debugger signal, the autoLoad effect fires ``ct/load-locals``, and
#   the matching CtLoadLocalsResponse path calls updateLocals to feed
#   the variables into the panel.
#
# This is the lowest-layer reproduction of the WASM
# ``state panel supports integer values`` GUI test failure: the
# variables must reach the StateVM's ``currentVariables`` memo via
# ``store.updateLocals``, AND the source line must reach
# ``vm.codeStateLine`` via ``store.updateCodeStateLine`` for the panel
# to be populated end-to-end.
# ---------------------------------------------------------------------------

suite "StateVM DB-trace state panel population":

  test "DB-trace move populates locals and codeStateLine":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # Pretend a CtCompleteMove arrived from a Materialized (DB)
      # trace: rrTicks remains 0, only the location.line / file change.
      var dbg = store.debugger.val
      dbg.rrTicks = 0'u64                          # DB traces don't use rr ticks
      dbg.location = Location(file: "main.rs", line: 13, column: 0)
      store.debugger.val = dbg
      drain()

      # The autoLoad effect should still issue a load-locals request
      # for the new position even at rrTicks = 0.
      check mock.findCommand("ct/load-locals").isSome

      # Now simulate the ``state.nim`` move handler doing its work:
      # 1. It pulls ``sourceLines[line - 1]`` from the editor cache
      #    and pushes the formatted "<line> | <source>" into the
      #    store via ``updateCodeStateLine``.
      # 2. It receives the ``ct/load-locals`` response and pushes
      #    the parsed locals into the store via ``updateLocals``.
      store.updateCodeStateLine(13, "    let result = add(x, y);")
      store.updateLocals(@[
        makeVariable("x", "3", "i32"),
        makeVariable("y", "4", "i32"),
      ])

      # The state panel must now expose:
      #   * the formatted source-line text — what the
      #     ``#code-state-line-0`` element shows above the variables
      #     list (matches the wasm_example "state panel loaded
      #     initially" assertion: text contains "13 | ").
      #   * the loaded variables — what the wasm_example
      #     "state panel supports integer values" test reads.
      check vm.codeStateLine.val == "13 |     let result = add(x, y);"
      check vm.codeStateLine.val.contains("13 | ")

      check vm.currentVariables.val.len == 2
      check vm.currentVariables.val[0].name == "x"
      check vm.currentVariables.val[0].value == "3"
      check vm.currentVariables.val[0].typeName == "i32"
      check vm.currentVariables.val[1].name == "y"
      check vm.currentVariables.val[1].value == "4"
      check vm.currentVariables.val[1].typeName == "i32"

      dispose()

  test "successive DB-trace moves update both locals and codeStateLine":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # First step — line 11.
      var dbg1 = store.debugger.val
      dbg1.rrTicks = 0'u64
      dbg1.location = Location(file: "main.rs", line: 11, column: 0)
      store.debugger.val = dbg1
      drain()
      store.updateCodeStateLine(11, "let x = 3;")
      store.updateLocals(@[ makeVariable("x", "3", "i32") ])

      check vm.codeStateLine.val == "11 | let x = 3;"
      check vm.currentVariables.val.len == 1

      # Second step — line 12: the panel must reflect the new
      # position immediately, mirroring the rebuild the legacy Karax
      # ``StateComponent.redraw()`` did on every move.
      var dbg2 = store.debugger.val
      dbg2.location = Location(file: "main.rs", line: 12, column: 0)
      store.debugger.val = dbg2
      drain()
      store.updateCodeStateLine(12, "let y = 4;")
      store.updateLocals(@[
        makeVariable("x", "3", "i32"),
        makeVariable("y", "4", "i32"),
      ])

      check vm.codeStateLine.val == "12 | let y = 4;"
      check vm.currentVariables.val.len == 2

      dispose()
