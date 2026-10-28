## event_log_scroll_area_dom_test.nim
##
## The Event Log's scroll area stays as tall as the whole log, in a real DOM,
## whatever the table's fit does.
##
## The Event Log is a virtual list: its scroll area (`.eventLog-scroll-space`)
## is as tall as every row of the log at the rows' pitch, and the window held
## (`.eventLog-rows`) sits `loadedStart` rows down in it, so the scrollbar
## spans the log and a scroll asks for the rows it reaches
## (`GUI/Core-Panes/Event-Log-Pane.md` § The scrollbar is a scrubber over the
## whole log). Its height and its offset used to be `height = …` and
## `transform = …` bindings beside a `style = …` binding (the table's width
## in SCROLL). A `style` binding replaces the element's whole inline style
## each time it re-runs, so the first change of the table's fit wiped the
## height: the scroll area shrank to the window held and the scrollbar
## reached only the rows already loaded. In VS Code the Event Log then never
## paged past its first window (codetracer-vscode-extension#40;
## codetracer-pm issues/2026-10-20-vscode-event-log-does-not-page-past-its-first-window.md).
##
## This suite mounts the view under `WebRenderer` into jsdom's document, over
## a log of 200 events of which 3 are held, and reads the scroll area's and
## the table's inline style before and after the fit changes both ways (to
## SCROLL, and back to FIT).
##
## jsdom's canvas has no 2D context, which the Event Log measures its cells'
## text with; a stand-in measures at a fixed advance. jsdom lays nothing out,
## so the inline style is what is read, not a box.
##
## The backend is a `MockBackendService` answering every request; nothing
## here reads what it answers.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/unittest

import isonim/core/owner
import isonim/core/async_compat
import isonim/web/[web_renderer, dom_api]

import ../viewmodel/backend/mock_backend
import ../viewmodel/store/[replay_data_store, types]
import ../viewmodel/viewmodels/event_log_vm
import ../viewmodel/views/isonim_event_log_view

proc query(root: Element; selector: cstring): Element
  {.importjs: "(#.querySelector(#) || null)".}
proc styleOf(el: Element; prop: cstring): cstring
  {.importjs: "(#.style.getPropertyValue(#) || '')".}
proc documentBody(): Node {.importjs: "(document.body)@".}

{.emit: """
// jsdom's canvas has no 2D context; the event log measures its cells' text
// with one. A fixed advance per character stands in.
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

suite "the Event Log's scroll area spans the whole log":
  test "its height and the window's offset survive every change of the fit":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      var rows: seq[EventLogRow] = @[]
      for i in 0 ..< 3:
        rows.add EventLogRow(eventId: uint64(i + 1), kind: "event",
                             line: i + 1, value: "e" & $i,
                             rrTicks: uint64(i + 1), file: "/src/main.py")
      store.applyEventLogRows(rows, 0, recordsTotal = 200)
      vm.setRowHeightPx(20.0)
      let panel = renderEventLogPanel[WebRenderer, Element](WebRenderer(), vm)
      discard appendChild(documentBody(), Node(panel))
      drainPlatformCallbacks()
      let space = panel.query(cstring".eventLog-scroll-space")
      let table = panel.query(cstring".eventLog-rows")
      ck not isNodeNil(Node(space))
      ck not isNodeNil(Node(table))
      if not isNodeNil(Node(space)) and not isNodeNil(Node(table)):
        # 200 events at 20 px: the scroll area is 4000 px, before any fit.
        ck $space.styleOf(cstring"height") == "4000px"
        ck $table.styleOf(cstring"transform") == "translateY(0px)"
        # A pane far too narrow for the columns' floors: SCROLL, a width.
        vm.setTableMetrics(5, 7.0)
        drainPlatformCallbacks()
        ck ($space.styleOf(cstring"min-width")).len > 0   # CONTROL: the fit changed
        ck $space.styleOf(cstring"height") == "4000px"
        ck $table.styleOf(cstring"transform") == "translateY(0px)"
        # A wide pane: FIT again, no width.
        vm.setTableMetrics(1000, 7.0)
        drainPlatformCallbacks()
        ck ($space.styleOf(cstring"min-width")).len == 0  # CONTROL
        ck $space.styleOf(cstring"height") == "4000px"
        ck $table.styleOf(cstring"transform") == "translateY(0px)"
      dispose()

if failed > 0:
  {.emit: "process.exitCode = 1;".}
