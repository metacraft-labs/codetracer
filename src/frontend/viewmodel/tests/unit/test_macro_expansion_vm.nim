## test_macro_expansion_vm.nim — Editor-Hosted-Front-Ends §E15, the shared
## core of Toggle Macro Expansion: what the store makes of a stop inside an
## expansion, and what `MacroExpansionVM` asks the replay and shows.
##
## The replay is a `MockBackendService`, and that is the one stand-in here:
## these cases pin the REQUESTS the ViewModel sends (`ct/update-expansion`,
## its expand and its collapse) and the state an answer leaves, which a real
## engine cannot be made to answer selectively. The answers are the shape
## `db-backend` sends — a `Location` with camelCase fields and each
## `expansionParents` entry a JSON array — as the replay answered for
## `test-programs/nim_macro_steps` (2026-11-17). The real engine end to end is
## `tui/tests/test_macro_expansion_native.nim` and `test_pane_server`'s §E15
## case. The expansion's text comes from a stub `SourceProvider`, the seam
## the ViewModel reads through.
##
## Each toggle is followed by `replayAnswers()`: under `nim js` a completed
## future's callback is queued, not run (`async_compat.onComplete`), so the
## answer lands when the platform's callbacks are drained, as the event loop
## would drain them.

import std/[json, options, unittest]

import isonim/core/[signals, async_compat]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewmodels/[macro_expansion_vm, source_vm]
import sdk/source_provider

proc replayAnswers() =
  ## The replay's answer arrives: run the callbacks the sends queued.
  drainPlatformCallbacks()

const
  Main = "/work/nim_macro_steps/main.nim"
  Expanded = "/work/nimcache/expanded.nim"
  ExpandedText = ["# addTwice expansion in main internal line 2", "",
                  "counter += 3", "counter += 3"]

proc expandAnswer(): JsonNode =
  ## The replay's answer to Toggle Macro Expansion on `main.nim:17`.
  %*{"success": true, "command": "ct/update-expansion", "body": {
    "path": "unknown", "line": -1, "highLevelPath": Expanded,
    "highLevelLine": 3, "expansionParents": [[Main, 17, 1]],
    "expansionDepth": 1, "expansionId": 0, "expansionFirstLine": 1,
    "expansionLastLine": 4, "isExpanded": true}}

proc nothingAnswer(): JsonNode =
  ## …and on a line that expands nothing: a default `Location`.
  %*{"success": true, "command": "ct/update-expansion", "body": {
    "path": "", "line": 0, "isExpanded": false, "expansionParents": []}}

proc insideMove(): JsonNode =
  ## `ct/complete-move` for a stop inside the expanded call (the replay's
  ## `apply_macro_expansion_level`).
  %*{"location": {"path": Expanded, "line": 3, "rrTicks": 40,
                  "isExpanded": true, "expansionParents": [[Main, 17, 1]],
                  "expansionFirstLine": 1, "expansionLastLine": 4,
                  "functionName": "main", "key": "1"}}

proc textProvider(): SourceProvider =
  SourceProvider(kind: spkDapSource, name: "expanded.nim",
    supportsProc: proc(): bool = true,
    fetchProc: proc(request: SourceLineRequest;
                    onResult: proc(fetch: SourceFetch)) =
      var lines: seq[string] = @[]
      for n in request.firstLine .. request.lastLine:
        if n >= 1 and n <= ExpandedText.len: lines.add ExpandedText[n - 1]
      onResult(SourceFetch(status: sfsAvailable, request: request,
                           firstLine: request.firstLine, lines: lines)))

proc setup(): (MockBackendService, ReplayDataStore, MacroExpansionVM) =
  let mock = newMockBackendService()
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createMacroExpansionVM(store)
  vm.setSourceProvider(textProvider())
  (mock, store, vm)

suite "§E15: the store, for a stop inside an expanded macro call":
  test "the debugger position is the call; the stop keeps the expansion":
    let (_, store, _) = setup()
    store.applyCompleteMove(insideMove())
    check store.debugger.val.location.file == Main
    check store.debugger.val.location.line == 17
    let stop = store.stop.val
    check stop.isExpanded
    check stop.path == Expanded and stop.line == 3
    check (stop.expansionFirstLine, stop.expansionLastLine) == (1, 4)
    check (stop.expansionCallPath, stop.expansionCallLine) == (Main, 17)

  test "a parent written as a Nim tuple object is read too":
    check expansionCallSiteOf(%*{"isExpanded": true, "expansionParents":
      [{"Field0": Main, "Field1": 17, "Field2": 1}]}) == (Main, 17)
    check expansionCallSiteOf(%*{"isExpanded": false, "expansionParents":
      [[Main, 17, 1]]}) == ("", 0)

suite "§E15: MacroExpansionVM":
  test "the toggle asks the replay, and the answer opens the expansion":
    let (mock, _, vm) = setup()
    mock.expect("ct/update-expansion", expandAnswer())
    var said = ""
    vm.toggle(Main, 17, proc(ok: bool; detail: string) = said = detail)
    replayAnswers()
    let sent = mock.findCommand("ct/update-expansion")
    check sent.isSome
    if sent.isSome:
      check sent.get.args == expansionRequestArgs(Main, 17)
      check sent.get.args{"update", "kind"}.getStr == "MacroUpdateExpand"
    check said == "the expansion of main.nim:17 beside the source"
    check vm.isOpen(Main, 17)
    let rows = vm.displayRows()
    check rows.len == 5
    check rows[0].kind == merHeading and rows[0].text == "main.nim:17 · expanded.nim 1–4"
    check rows[3].kind == merLine and rows[3].number == 3 and
          rows[3].text == "counter += 3"
    check not rows[3].executing

  test "a line that expands nothing is refused and opens nothing":
    let (mock, _, vm) = setup()
    mock.expect("ct/update-expansion", nothingAnswer())
    var answer = (ok: true, detail: "")
    vm.toggle(Main, 16, proc(ok: bool; detail: string) = answer = (ok, detail))
    replayAnswers()
    check answer == (ok: false, detail: "No macro expansion at main.nim:16")
    check vm.expansions.val.len == 0

  test "a stop inside the expansion is its execution row":
    let (mock, store, vm) = setup()
    mock.expect("ct/update-expansion", expandAnswer())
    vm.toggle(Main, 17)
    replayAnswers()
    store.applyCompleteMove(insideMove())
    let e = vm.expansions.val[0]
    check vm.executionRow(e) == 3
    var marked: seq[int] = @[]
    for r in vm.displayRows():
      if r.executing: marked.add r.number
    check marked == @[3]

  test "a stop inside an expansion nobody opened here opens it":
    let (mock, store, vm) = setup()
    store.applyCompleteMove(insideMove())
    check vm.isOpen(Main, 17)
    check mock.findCommand("ct/update-expansion").isNone
    check vm.executionRow(vm.expansions.val[0]) == 3

  test "toggled again it closes, and the replay's level follows (collapse)":
    let (mock, _, vm) = setup()
    mock.expect("ct/update-expansion", expandAnswer())
    vm.toggle(Main, 17)
    replayAnswers()
    mock.clearReceivedCommands()
    mock.expect("ct/update-expansion", %*{"success": true, "body": {}})
    var said = ""
    vm.toggle(Main, 17, proc(ok: bool; detail: string) = said = detail)
    replayAnswers()
    check not vm.isOpen(Main, 17)
    check said == "the expansion of main.nim:17 closed"
    let sent = mock.findCommand("ct/update-expansion")
    check sent.isSome
    if sent.isSome:
      check sent.get.args{"update", "kind"}.getStr == "MacroUpdateCollapse"
      check sent.get.args{"line"}.getInt == 17
