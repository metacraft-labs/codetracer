## row_links_dom_test.nim
##
## A linked shared row (Shared-DOM-Front-Ends D10) in a real DOM: a plain click
## on the link is the row's click and does not navigate; a modified click is
## the browser's and does not run the row's action; Enter on the link is a
## plain click.
##
## The views are the Call Trace and Event Log, mounted under `WebRenderer` into
## jsdom's document with a host link builder, as BlockTracer mounts them. The
## clicks are real `MouseEvent`s dispatched on the links; whether the browser
## would navigate is read from the event (`defaultPrevented`), which is what
## `row_link_dom` decides. The markup half is
## `viewmodel/tests/unit/test_row_address.nim`'s. Recorded as codetracer-pm
## issues/2026-10-24-shared-pane-rows-are-clickable-without-a-role-a-keyboard-path-or-a-link.md.
##
## jsdom's canvas has no 2D context, which the Event Log measures its cells'
## text with; a stand-in measures at a fixed advance. Nothing here reads a
## size.
##
## The backend is a `MockBackendService`: the request a click sends is the
## evidence that the row's action ran. THE CONTROLS: a Ctrl-click and a
## Shift-click send nothing and are not cancelled.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/unittest

import isonim/core/owner
import isonim/core/async_compat
import isonim/web/[web_renderer, dom_api]

import ../viewmodel/backend/mock_backend
import ../viewmodel/store/[replay_data_store, row_address, types]
import ../viewmodel/viewmodels/[calltrace_vm, event_log_vm]
import ../viewmodel/views/[isonim_calltrace_view, isonim_event_log_view]

proc queryAll(root: Element; selector: cstring): seq[Element]
  {.importjs: "Array.from(#.querySelectorAll(#))".}
proc documentBody(): Node {.importjs: "(document.body)@".}
proc hrefOf(el: Element): cstring {.importjs: "(#.getAttribute('href') || '')".}
proc clickWith(el: Element; ctrl, shift: bool): bool {.importjs: """
  (function (el, ctrl, shift) {
    var ev = new window.MouseEvent('click', { bubbles: true, cancelable: true,
      button: 0, ctrlKey: ctrl, shiftKey: shift });
    el.dispatchEvent(ev);
    return ev.defaultPrevented;
  })(#, #, #)""".}
  ## Click `el`; true when the browser's navigation was cancelled.
proc pressEnterOnLink(el: Element): bool {.importjs: """
  (function (el) {
    // A browser turns Enter on a focused link into a click with no modifier;
    // jsdom does not, so that click is dispatched here.
    var ev = new window.MouseEvent('click', { bubbles: true, cancelable: true,
      button: 0, detail: 0 });
    el.dispatchEvent(ev);
    return ev.defaultPrevented;
  })(#)""".}

{.emit: """
if (window.HTMLCanvasElement) {
  window.HTMLCanvasElement.prototype.getContext = function () {
    return { font: '', measureText: (t) => ({ width: String(t).length * 7 }) };
  };
}
""".}

var failed = 0
template ck(cond: untyped) =
  ## Evaluates `cond` once: a click is an action, not only a value.
  let ok = cond
  if not ok:
    inc failed
  check ok

proc count(mock: MockBackendService; command: string): int =
  for c in mock.receivedCommands:
    if c.command == command:
      inc result

proc links(a: RowAddress): string =
  case a.kind
  of rakFrame: "?t=" & $a.rrTicks & "&a=call:" & $a.callPath[^1]
  of rakEvent: "?t=" & $a.rrTicks & "&e=" & $a.eventIndex
  of rakNone: ""

suite "a linked shared row: plain click is the row's, a modified one the browser's":
  test "a call's link":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      store.calltrace.lines.val = @[
        CallLine(index: 0, name: "main", callKey: "0", rrTicks: 1,
                 location: Location(file: "/src/main.py", line: 1)),
        CallLine(index: 1, name: "helper", callKey: "1", rrTicks: 2,
                 location: Location(file: "/src/main.py", line: 2))]
      store.calltrace.totalCallsCount.val = 2
      let panel = renderCalltracePanel[WebRenderer, Element](WebRenderer(), vm,
                                                             links)
      discard appendChild(documentBody(), Node(panel))
      drainPlatformCallbacks()
      let texts = panel.queryAll(cstring"a.call-text")
      ck texts.len == 2
      if texts.len == 2:
        let link = texts[1]
        ck $link.hrefOf == "?t=2&a=call:1"
        mock.clearReceivedCommands()
        # CONTROLS: the browser's clicks.
        ck not link.clickWith(ctrl = true, shift = false)
        ck not link.clickWith(ctrl = false, shift = true)
        drainPlatformCallbacks()
        ck mock.count("ct/calltrace-jump") == 0
        ck link.clickWith(ctrl = false, shift = false)
        drainPlatformCallbacks()
        ck mock.count("ct/calltrace-jump") == 1
        ck link.pressEnterOnLink()
        drainPlatformCallbacks()
        ck mock.count("ct/calltrace-jump") == 2
      dispose()

  test "an event's link":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      var rows: seq[EventLogRow] = @[]
      for i in 0 ..< 3:
        rows.add EventLogRow(eventId: uint64(i + 1), eventIndex: i,
                             kind: "event", line: i + 1, value: "e" & $i,
                             rrTicks: uint64(i + 1), file: "/src/main.py")
      store.applyEventLogRows(rows, 0, recordsTotal = 3)
      let panel = renderEventLogPanel[WebRenderer, Element](WebRenderer(), vm,
                                                            links)
      discard appendChild(documentBody(), Node(panel))
      drainPlatformCallbacks()
      let shown = panel.queryAll(cstring"tr.eventLog-row a.eventLog-row-link")
      ck shown.len == 3
      if shown.len == 3:
        let link = shown[2]
        ck $link.hrefOf == "?t=3&e=2"
        mock.clearReceivedCommands()
        ck not link.clickWith(ctrl = true, shift = false)   # CONTROL
        drainPlatformCallbacks()
        ck mock.count("ct/event-jump") == 0
        ck link.clickWith(ctrl = false, shift = false)
        drainPlatformCallbacks()
        ck mock.count("ct/event-jump") == 1
      dispose()

if failed > 0:
  {.emit: "process.exitCode = 1;".}
