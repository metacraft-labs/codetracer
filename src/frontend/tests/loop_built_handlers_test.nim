## Delayed activation uses the item drawn by each legacy DOM control.
## jsdom supplies the browser DOM. Recording IPC/Golden Layout boundaries
## avoid starting Electron windows or a replay engine; production builders,
## event listeners and DAP request correlation run unchanged. Monaco model
## creation at import time is inert in the shared bootstrap; these tests never
## enter an editor model or replace any tested handler.
import ./legacy_loop_dom_bootstrap
import std/[unittest, jsffi, asyncjs]
import ../types
import ../renderer
import ../ui/[layout, shortcuts, panel_transfer, file_conflict_dialog]
import ../services/debugger_service
import ../dap
import ../viewmodel/platform/outcome as platform_outcome
import ../lib/jslib
import kdom

var failures = 0
var assertions = 0
template ck(condition: untyped) =
  inc assertions
  if not condition: inc failures
  check condition

proc click(element: JsObject) {.importjs: "#.dispatchEvent(new window.MouseEvent('click', {bubbles: true}))".}
proc tick(): Future[void] {.importjs: "Promise.resolve()".}
proc packetWindows(): JsObject {.importjs: "({windows: [{id: 11, title: 'First', sessionId: 7}, {id: 22, title: 'Second', sessionId: 7}, {id: 33, title: 'Other session', sessionId: 8}]})".}
proc panel(): GoldenContentItem {.importjs: "({parent: null, toConfig: () => ({type: 'component', componentType: 'State'})})".}

suite "legacy loop-built handlers keep their own item":
  test "layout menu options and rendered clicks dispatch the selected option":
    var seen: seq[string] = @[]
    let menu = createContextMenuFromOptions(nil, nil, @[
      ContextMenuOption(label: "First", action: proc(c: GoldenContainer; s: GoldenItemState) = seen.add "first"),
      ContextMenuOption(label: "Second", action: proc(c: GoldenContainer; s: GoldenItemState) = seen.add "second")])
    menu.actions[0]()
    ck seen == @["first"]
    seen = @[]
    menu.dom = menu.renderContextMenu()
    menu.dom.toJs.querySelectorAll(cstring".context-menu-option")[0].click()
    ck seen == @["first"]
    menu.dom.toJs.querySelectorAll(cstring".context-menu-option")[1].click()
    ck seen == @["first", "second"]

  test "file conflict buttons retain all four distinct actions":
    var seen: seq[string] = @[]
    let overlay = buildFileConflictOverlay(cstring"/first.nim")
    wireFileConflictActions(overlay, proc(action: cstring) = seen.add $action)
    overlay.toJs.querySelector(cstring"[data-action='discard']").click()
    overlay.toJs.querySelector(cstring"[data-action='save']").click()
    overlay.toJs.querySelector(cstring"[data-action='merge']").click()
    overlay.toJs.querySelector(cstring"[data-action='keep']").click()
    ck seen == @["discard", "save", "merge", "keep"]

  test "preset buttons import the preset named on the activated button":
    var seen: seq[string] = @[]
    let transport = JsObject{}
    transport.send = proc(channel: cstring; payload: JsObject) =
      if channel == cstring"CODETRACER::keybindings-import": seen.add $payload.preset.to(cstring)
    data.ipc = transport
    openShortcutsDialog()
    let buttons = kdom.document.toJs.querySelectorAll(cstring"[data-kb-preset]")
    ck buttons.length.to(int) >= 2
    let expected = $buttons[0].getAttribute(cstring"data-kb-preset").to(cstring)
    buttons[0].click()
    ck seen == @[expected]

  test "send-to-window menu sends to the named compatible window":
    var sent: seq[int] = @[]
    let transport = JsObject{}
    transport.send = proc(channel: cstring; payload: JsObject) = sent.add payload.targetWindowId.to(int)
    let electronObject = JsObject{}
    electronObject.ipcRenderer = transport
    panel_transfer.electron = electronObject
    let items = buildSendToWindowMenuItems(panel(), 7, packetWindows())
    ck items.len == 3
    items[0].handler(nil)
    items[1].handler(nil)
    items[2].handler(nil)
    ck sent == @[11, 22, -1]

proc breakpointAnswers() {.async.} =
  echo "[Case] deferred breakpoint answers retain each requested file"
  var requests: seq[JsObject] = @[]
  var seen: seq[string] = @[]
  let transport = JsObject{}
  transport.send = proc(channel: cstring; payload: JsObject) = requests.add payload
  data.dapApi = DapApi(ipc: transport)
  data.onBreakpointsVerified = proc(path: cstring; lines: seq[int]) =
    seen.add $path & ":" & $lines[0]
  let service = DebuggerService(data: data,
    breakpointTable: JsAssoc[cstring, JsAssoc[int, UIBreakpoint]]{})
  service.breakpointTable[cstring"/first.nim"] = JsAssoc[int, UIBreakpoint]{}
  service.breakpointTable[cstring"/first.nim"][10] = UIBreakpoint(enabled: true)
  service.breakpointTable[cstring"/second.nim"] = JsAssoc[int, UIBreakpoint]{}
  service.breakpointTable[cstring"/second.nim"][20] = UIBreakpoint(enabled: true)
  service.dapSetBreakpoints()
  ck requests.len == 2
  # Resolve in reverse order only after BOTH requests/closures exist.
  for index in countdown(requests.high, 0):
    let request = requests[index]
    let line = request.arguments.lines[0].to(int)
    data.dapApi.resolvePendingDapResponse(js{
      request_seq: request["seq"], success: true,
      body: js{breakpoints: @[js{verified: true, line: line}]}})
    await tick()
  ck seen == @["/second.nim:20", "/first.nim:10"]

proc deferredFold() {.async.} =
  echo "[Case] deferred foldOutcome visits every item in order"
  var release: proc(value: PlatformOutcome[platform_outcome.Nothing])
  let gate = newPromise(proc(resolve: proc(value: PlatformOutcome[platform_outcome.Nothing])) =
    release = resolve)
  var seen: seq[int] = @[]
  let folded = foldOutcome(@[11, 22, 33],
    proc(item: int): PlatformFuture[PlatformOutcome[platform_outcome.Nothing]] =
      seen.add item
      if item == 11: gate else: resolvedOk())
  ck seen == @[11]
  release(succeeded())
  let settled = await folded
  ck settled.ok
  ck seen == @[11, 22, 33]

proc main() {.async.} =
  await breakpointAnswers()
  await deferredFold()
  if assertions != 13:
    inc failures
  echo "loop-built assertions: ", assertions, "; failures: ", failures
  {.emit: "if (`failures` !== 0) process.exitCode = 1;".}

discard main().catch(proc(error: Error) =
  echo "loop-built async failure: ", error.message
  {.emit: "process.exitCode = 1;".})
