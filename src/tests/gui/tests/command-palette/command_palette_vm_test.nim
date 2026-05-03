## test_command_palette_vm.nim
##
## Unit tests for CommandPaletteVM — the ViewModel for the Command
## Palette overlay panel.
##
## Verifies:
## - Initial-state defaults (isActive, inputValue, inputPlaceholder,
##   query, results, selectedIndex, mode, activeCommandName, the
##   hasResults / resultCount memos).
## - open / close / clear (overlay lifecycle).
## - setQuery (legacy ``onInput`` mirror — pushes query + resets the
##   selection).
## - setResults / setSelected (clamping into ``[0, results.len)``,
##   re-clamping after a result-set replace).
## - setMode (normal / agent toggle that the legacy ``inAgentMode``
##   flag tracked).
## - setInputPlaceholder / setActiveCommandName (legacy
##   ``changePlaceholder`` / ``activeCommandName`` mirrors).
##
## Co-located per the Test-Co-Location-Convention so the panel's
## ViewModel tests live alongside the panel module's surface area
## in the gui-tests tree.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/command-palette/command_palette_vm_test.nim

import std/unittest
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/command_palette_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeEntry(value: string;
               kind: CommandPaletteResultKind = cprkCommand;
               level: CommandPaletteNotificationLevel = cpnlInfo;
               file: string = "";
               line: int = 0;
               symbolKind: string = ""): CommandPaletteResultEntry =
  ## Test fixture builder for ``CommandPaletteResultEntry`` rows.
  ## Mirrors ``makeCpEntry`` in ``isonim_views_test.nim`` so the same
  ## shape works for both the headless view tests and the VM-only
  ## tests here.  Defaults to a plain command-kind / info-level row.
  CommandPaletteResultEntry(
    value: value,
    valueHighlighted: value,
    kind: kind,
    level: level,
    file: file,
    line: line,
    symbolKind: symbolKind,
    snippetSource: "",
  )

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "CommandPaletteVM initial state":

  test "every signal defaults to its closed/empty value":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      check not vm.isActive.val
      check vm.inputValue.val == ""
      check vm.inputPlaceholder.val == ""
      check vm.query.val == ""
      check vm.results.val.len == 0
      check vm.selectedIndex.val == 0
      check vm.activeCommandName.val == ""
      check vm.mode.val == cpmNormal

      dispose()

  test "hasResults / resultCount memos report the empty branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      check not vm.hasResults.val
      check vm.resultCount.val == 0

      dispose()

  test "store reference is preserved":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      # The VM holds the same store ref the factory was given.
      # Behavioural sanity check (the store is the one constructed
      # via ``makeStoreWithMock``) — ``cast[pointer]`` does not
      # survive the JS backend's emit and crashes node.
      check not vm.store.isNil
      check vm.store == store

      dispose()

# ---------------------------------------------------------------------------
# open / close / clear
# ---------------------------------------------------------------------------

suite "CommandPaletteVM open / close / clear":

  test "open() flips isActive on; second call is a no-op":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      check not vm.isActive.val
      vm.open()
      check vm.isActive.val

      # Subscriber-counter sanity: re-opening should not fire the
      # signal again.  We approximate by calling open() repeatedly
      # and verifying the stored state stays consistent.
      vm.open()
      vm.open()
      check vm.isActive.val

      dispose()

  test "close() resets every transient piece of state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.open()
      vm.setQuery("hello")
      vm.setInputPlaceholder("hint")
      vm.setMode(cpmAgent)
      vm.setActiveCommandName("open")
      vm.setResults([makeEntry("a"), makeEntry("b")])
      vm.setSelected(1)

      vm.close()

      check not vm.isActive.val
      check vm.inputValue.val == ""
      check vm.inputPlaceholder.val == ""
      check vm.query.val == ""
      check vm.results.val.len == 0
      check vm.selectedIndex.val == 0
      check vm.activeCommandName.val == ""
      check vm.mode.val == cpmNormal

      dispose()

  test "clear() drops input/query/results without flipping isActive":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.open()
      vm.setQuery("hello")
      vm.setResults([makeEntry("a")])
      vm.setSelected(0)

      vm.clear()

      # The overlay stays open — the legacy ``clear`` helper is
      # invoked between keystrokes that produce no matches and the
      # palette must keep painting.
      check vm.isActive.val
      check vm.inputValue.val == ""
      check vm.query.val == ""
      check vm.results.val.len == 0
      check vm.selectedIndex.val == 0

      dispose()

# ---------------------------------------------------------------------------
# setQuery
# ---------------------------------------------------------------------------

suite "CommandPaletteVM setQuery":

  test "setQuery pushes the query text + mirrors it into inputValue":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.setQuery(":open")
      check vm.query.val == ":open"
      check vm.inputValue.val == ":open"

      vm.setQuery("file.nim")
      check vm.query.val == "file.nim"
      check vm.inputValue.val == "file.nim"

      dispose()

  test "setQuery resets the selection back to row 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.setResults([makeEntry("a"), makeEntry("b"), makeEntry("c")])
      vm.setSelected(2)
      check vm.selectedIndex.val == 2

      vm.setQuery("x")
      # New keystroke -> selection back to top.
      check vm.selectedIndex.val == 0

      dispose()

# ---------------------------------------------------------------------------
# setResults / setSelected (clamping)
# ---------------------------------------------------------------------------

suite "CommandPaletteVM setResults / setSelected":

  test "setResults bulk-replaces the result list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.setResults([
        makeEntry("a"),
        makeEntry("b"),
      ])
      check vm.results.val.len == 2
      check vm.hasResults.val
      check vm.resultCount.val == 2

      # Replace the seq wholesale.
      vm.setResults([makeEntry("only")])
      check vm.results.val.len == 1
      check vm.results.val[0].value == "only"

      vm.setResults([])
      check vm.results.val.len == 0
      check not vm.hasResults.val
      check vm.resultCount.val == 0

      dispose()

  test "setResults re-clamps a stale selection into the new range":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.setResults([
        makeEntry("a"),
        makeEntry("b"),
        makeEntry("c"),
        makeEntry("d"),
      ])
      vm.setSelected(3)
      check vm.selectedIndex.val == 3

      # Shrink the result set — selection clamps to the new tail.
      vm.setResults([makeEntry("a"), makeEntry("b")])
      check vm.selectedIndex.val == 1

      # Empty result set — selection collapses to 0.
      vm.setResults([])
      check vm.selectedIndex.val == 0

      dispose()

  test "setSelected clamps into [0, results.len)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.setResults([makeEntry("a"), makeEntry("b"), makeEntry("c")])

      vm.setSelected(-99)
      check vm.selectedIndex.val == 0

      vm.setSelected(99)
      check vm.selectedIndex.val == 2

      vm.setSelected(1)
      check vm.selectedIndex.val == 1

      dispose()

  test "setSelected on an empty result list collapses to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.setResults([])
      vm.setSelected(7)
      check vm.selectedIndex.val == 0

      dispose()

# ---------------------------------------------------------------------------
# mode / placeholder / activeCommandName
# ---------------------------------------------------------------------------

suite "CommandPaletteVM mode / placeholder / activeCommandName":

  test "setMode flips between normal and agent":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      check vm.mode.val == cpmNormal
      vm.setMode(cpmAgent)
      check vm.mode.val == cpmAgent
      vm.setMode(cpmNormal)
      check vm.mode.val == cpmNormal

      dispose()

  test "setInputPlaceholder updates the autocomplete hint signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      check vm.inputPlaceholder.val == ""
      vm.setInputPlaceholder(":open file.nim")
      check vm.inputPlaceholder.val == ":open file.nim"

      vm.setInputPlaceholder("")
      check vm.inputPlaceholder.val == ""

      dispose()

  test "setActiveCommandName mirrors the legacy field":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      check vm.activeCommandName.val == ""
      vm.setActiveCommandName("open")
      check vm.activeCommandName.val == "open"

      vm.setActiveCommandName("")
      check vm.activeCommandName.val == ""

      dispose()
