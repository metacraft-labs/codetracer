## shared_rows_keyboard_dom_test.nim
##
## Enter and Space on a shared view's clickable row do what its click does,
## in a real DOM.
##
## `views/isonim_activation` turns Enter or Space on a focused
## `[role="button"]` that is not a native control into that element's
## `click()` (https://www.w3.org/WAI/ARIA/apg/patterns/button/), so the
## keyboard runs the handler the view already attached. This suite mounts the
## Call Trace and Event Log views under `WebRenderer` into jsdom's document,
## presses keys on their rows and reads the requests the click sends. The
## markup half (every such row is a `role="button"` with a tab stop) is
## `viewmodel/tests/unit/test_shared_rows_are_controls.nim`'s. Recorded as
## codetracer-pm
## issues/2026-10-24-shared-pane-rows-are-clickable-without-a-role-a-keyboard-path-or-a-link.md.
##
## jsdom's canvas has no 2D context, which the Event Log measures its cells'
## text with; a stand-in measures at a fixed advance. Nothing here reads a
## size. (The runner supplies the rest of the page jsdom lacks.)
##
## The backend is a `MockBackendService`: the request a key sends is the
## evidence that the row's action ran. THE CONTROLS: a key that is not Enter
## or Space sends nothing, and neither does a held key's repeat.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/[options, unittest]

import isonim/core/owner
import isonim/core/async_compat
import isonim/web/[web_renderer, dom_api]

import ../viewmodel/backend/mock_backend
import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/viewmodels/[calltrace_vm, event_log_vm]
import ../viewmodel/views/[isonim_calltrace_view, isonim_event_log_view]

proc queryAll(root: Element; selector: cstring): seq[Element]
  {.importjs: "Array.from(#.querySelectorAll(#))".}
proc documentBody(): Node {.importjs: "(document.body)@".}
proc focusEl(el: Element) {.importjs: "#.focus()".}
proc isFocused(el: Element): bool {.importjs: "(document.activeElement === #)".}
proc pressKey(el: Element; key: cstring; repeat: bool) {.importjs: """
  #.dispatchEvent(new window.KeyboardEvent('keydown',
    { key: #, repeat: #, bubbles: true, cancelable: true }))""".}

{.emit: """
// jsdom's canvas has no 2D context; the event log measures its cells' text
// with one. A fixed advance per character stands in: no width is asserted.
if (window.HTMLCanvasElement) {
  window.HTMLCanvasElement.prototype.getContext = function () {
    return { font: '', measureText: (t) => ({ width: String(t).length * 7 }) };
  };
}
""".}

var failed = 0
template ck(cond: untyped) =
  if not (cond):
    inc failed
  check cond

proc callLine(index: int; name: string): CallLine =
  CallLine(index: index.int64, name: name, depth: 0, callKey: $index,
           location: Location(file: "/src/main.py", line: index + 1),
           rrTicks: uint64(index + 1))

proc count(mock: MockBackendService; command: string): int =
  for c in mock.receivedCommands:
    if c.command == command:
      inc result

suite "Enter and Space on a shared row are its click":
  test "a call's text: Enter and Space go to the call; another key does not":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      store.calltrace.lines.val = @[callLine(0, "main"), callLine(1, "helper")]
      store.calltrace.totalCallsCount.val = 2
      let panel = renderCalltracePanel[WebRenderer, Element](WebRenderer(), vm)
      discard appendChild(documentBody(), Node(panel))
      drainPlatformCallbacks()
      let texts = panel.queryAll(cstring".call-text")
      ck texts.len == 2
      if texts.len == 2:
        let text = texts[1]
        text.focusEl()
        ck text.isFocused   # `tabindex="0"`: the keyboard can reach it
        mock.clearReceivedCommands()
        text.pressKey(cstring"a", false)
        drainPlatformCallbacks()
        ck mock.count("ct/calltrace-jump") == 0   # CONTROL
        text.pressKey(cstring"Enter", false)
        drainPlatformCallbacks()
        ck mock.count("ct/calltrace-jump") == 1
        text.pressKey(cstring"Enter", true)
        drainPlatformCallbacks()
        ck mock.count("ct/calltrace-jump") == 1   # CONTROL: a repeat
        mock.clearReceivedCommands()
        texts[0].pressKey(cstring" ", false)
        drainPlatformCallbacks()
        ck mock.count("ct/calltrace-jump") == 1
      dispose()

  test "an event-log row: Enter goes to the event":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      var rows: seq[EventLogRow] = @[]
      for i in 0 ..< 3:
        rows.add EventLogRow(eventId: uint64(i + 1), kind: "event",
                             line: i + 1, value: "e" & $i,
                             rrTicks: uint64(i + 1), file: "/src/main.py")
      store.applyEventLogRows(rows, 0, recordsTotal = 3)
      let panel = renderEventLogPanel[WebRenderer, Element](WebRenderer(), vm)
      discard appendChild(documentBody(), Node(panel))
      drainPlatformCallbacks()
      let shown = panel.queryAll(cstring"tr.eventLog-row")
      ck shown.len == 3
      if shown.len == 3:
        mock.clearReceivedCommands()
        shown[2].pressKey(cstring"Tab", false)
        drainPlatformCallbacks()
        ck mock.count("ct/event-jump") == 0   # CONTROL
        shown[2].pressKey(cstring"Enter", false)
        drainPlatformCallbacks()
        ck mock.count("ct/event-jump") == 1
      dispose()

if failed > 0:
  {.emit: "process.exitCode = 1;".}
