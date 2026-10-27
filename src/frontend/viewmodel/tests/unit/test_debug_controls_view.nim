## test_debug_controls_view.nim
##
## The topbar's debugger controls are ONE view generic over the renderer
## (Shared-DOM-Front-Ends D3). This suite renders the very proc Electron and
## the web page render, under `MockRenderer`, and drives it the way a user
## does: a click on a button goes to `DebugControlsVM.invokeToolbarAction`
## with that button's id, the history buttons follow the VM's history, the
## history lists appear and disappear with the VM's `historyList`, and the
## topbar host shows the debugger controls or the edit-mode commands by
## `topbarSurface`.
##
## The backend is a `MockBackendService`: what is asserted is the request a
## click makes (`ct/history-jump`, a step) and the DOM it leaves.

import std/[json, strutils, tables, unittest]

import isonim/core/signals
import isonim/testing/mock_dom

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewmodels/[debug_controls_vm, edit_mode_toolbar]
import views/[isonim_debug_controls_view, isonim_edit_mode_toolbar_view]

proc byId(node: MockNode; id: string): MockNode =
  if node.isNil: return nil
  if node.attributes.getOrDefault("id", "") == id: return node
  for child in node.children:
    let found = byId(child, id)
    if not found.isNil: return found

proc byClass(node: MockNode; cls: string; found: var seq[MockNode]) =
  if node.isNil: return
  if cls in node.attributes.getOrDefault("class", "").split(' '):
    found.add node
  for child in node.children:
    byClass(child, cls, found)

proc disabled(node: MockNode): bool = node.attributes.hasKey("disabled")

proc sent(mock: MockBackendService; command: string): seq[JsonNode] =
  for c in mock.receivedCommands:
    if c.command == command: result.add c.args

proc setup(): (ReplayDataStore, DebugControlsVM, MockBackendService) =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  (store, createDebugControlsVM(store), mock)

proc moveTo(store: ReplayDataStore; ticks: uint64; line: int) =
  store.updateDebuggerPosition(ticks, "/src/main.py", line)

suite "the debugger controls panel":

  test "every control is there under its page-object id":
    let (_, vm, _) = setup()
    let panel = renderDebugControlsPanel[MockRenderer, MockNode](MockRenderer(), vm)
    for id in ["history-back-image", "history-list-before-image",
               "history-forward-image", "history-list-after-image",
               "reverse-next-image", "next-image", "reverse-step-in-image",
               "step-in-image", "reverse-step-out-image", "step-out-image",
               "reverse-continue-image", "continue-image",
               "run-to-entry-image", "reset-operation-image",
               "run-tests-image", "stop-image"]:
      check not panel.byId(id).isNil
    check panel.attributes["data-topbar-surface"] == DebugToolbarSurfaceValue

  test "a click is the toolbar action its id names":
    let (store, vm, mock) = setup()
    store.moveTo(5, 1)
    let panel = renderDebugControlsPanel[MockRenderer, MockNode](MockRenderer(), vm)
    fireEvent(panel.byId("run-to-entry-image"), "click")
    check mock.sent("ct/run-to-entry").len == 1

  test "the history buttons follow the history, and back jumps":
    let (store, vm, mock) = setup()
    let panel = renderDebugControlsPanel[MockRenderer, MockNode](MockRenderer(), vm)
    let back = panel.byId("history-back-image")
    let forward = panel.byId("history-forward-image")
    check back.disabled and forward.disabled
    store.moveTo(10, 1)
    store.moveTo(20, 2)
    check not back.disabled
    check forward.disabled
    fireEvent(back, "click")
    let jumps = mock.sent("ct/history-jump")
    check jumps.len == 1 and jumps[0]["rrTicks"].getInt == 10
    store.moveTo(10, 1)
    check not forward.disabled

  test "the history list opens, lists, jumps and closes":
    let (store, vm, mock) = setup()
    for t in 1 .. 3: store.moveTo(uint64(t * 10), t)
    let panel = renderDebugControlsPanel[MockRenderer, MockNode](MockRenderer(), vm)
    check panel.byId(HistoryListId).isNil
    fireEvent(panel.byId("history-list-before-image"), "click")
    let list = panel.byId(HistoryListId)
    check not list.isNil
    var entries: seq[MockNode] = @[]
    byClass(panel, "history-list-entry", entries)
    check entries.len == 2
    check entries.len == 2 and entries[0].textContent.contains("tick 20")
    fireEvent(entries[1], "click")       # the oldest: tick 10
    let jumps = mock.sent("ct/history-jump")
    check jumps.len == 1 and jumps[0]["rrTicks"].getInt == 10
    check panel.byId(HistoryListId).isNil

  test "run-tests is disabled while its run is pending":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    var finish: proc(succeeded: bool)
    var commands = defaultDebugCommands(store)
    commands.runTests = proc(done: proc(succeeded: bool)) = finish = done
    let vm = createDebugControlsVM(store, commands)
    let panel = renderDebugControlsPanel[MockRenderer, MockNode](MockRenderer(), vm)
    let button = panel.byId("run-tests-image")
    check not button.disabled
    fireEvent(button, "click")
    check button.disabled
    finish(true)
    check not button.disabled

suite "the topbar host":

  test "debugger controls, then the edit-mode commands a platform installed":
    let (_, vm, _) = setup()
    let r = MockRenderer()
    let host = r.createElement("div")
    renderTopbar[MockRenderer, MockNode](r, host, vm)
    check not host.byId("next-image").isNil
    var invoked: seq[string] = @[]
    let model = EditToolbarModel(mode: EditMode)
    vm.setEditToolbar(model, proc(id: string) = invoked.add id)
    vm.toolbarMode.val = EditMode
    check host.byId("next-image").isNil
    var surfaces: seq[MockNode] = @[]
    byClass(host, "edit-mode-toolbar", surfaces)
    check surfaces.len == 1
    vm.toolbarMode.val = DebugMode
    check not host.byId("next-image").isNil
