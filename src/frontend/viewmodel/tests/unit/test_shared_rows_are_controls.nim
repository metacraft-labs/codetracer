## test_shared_rows_are_controls.nim
##
## The shared views' clickable rows announce themselves and take a tab stop.
##
## A row of the Call Trace, of the Event Log, a value-history line or a value's
## caret in the Variables pane answers a click and is drawn with the hand
## cursor. Front-End-Architecture §7 forbids an interactive `div`: such an
## element carries `role="button"` and `tabindex="0"`, so a screen reader
## announces it and the keyboard reaches it
## (https://www.w3.org/WAI/ARIA/apg/patterns/button/). Enter and Space on it
## are its click (`views/isonim_activation`); that half needs a browser's key
## events and is `src/frontend/tests/shared_rows_keyboard_dom_test.nim`'s.
## Recorded as codetracer-pm
## issues/2026-10-24-shared-pane-rows-are-clickable-without-a-role-a-keyboard-path-or-a-link.md.
##
## WHAT IS REAL: the views every front-end mounts, rendered under
## `MockRenderer`, over their real ViewModels and store. The backend is a
## `MockBackendService`: what is asserted is the markup and, for the click a
## key stands for, the request it sends.
##
## THE HAND IS ONLY ON CONTROLS. The last suite reads the stylesheets the views
## are drawn with: the list scrubbers (a pane's scrollbar, pressed and dragged
## but not a control a click activates) and the data table's body (only its
## rows take a click) carried `cursor: pointer`, so they offered the hand with
## no role and no keyboard path — the orphans an embedding host's pointer
## audit found after the rows themselves were fixed.
##
## THE CONTROL: a leaf call's toggle is NOT a control (it is the picture of
## having no children), so it must read `presentation` with no tab stop — a
## view that stamped `role="button"` on everything would fail it.

import std/[strutils, tables, unittest]

import isonim/core/[async_compat, owner]
import isonim/testing/mock_dom

import ../../backend/mock_backend
import ../../store/[replay_data_store, types]
import ../../store/types as store_types
import ../../viewmodels/[calltrace_vm, event_log_vm, state_vm]
import ../../views/[isonim_calltrace_view, isonim_event_log_view,
                    isonim_state_view]

# Counted, so a loop over an empty list cannot pass by asserting nothing.
const ExpectedAssertions = 44

var checks = 0
template ck(cond: untyped) =
  inc checks
  check cond

proc allByClass(node: MockNode; cls: string; found: var seq[MockNode]) =
  if node.isNil: return
  if node.kind == mnkElement and
      cls in node.attributes.getOrDefault("class", "").split(' '):
    found.add node
  for child in node.children:
    allByClass(child, cls, found)

proc allByClass(node: MockNode; cls: string): seq[MockNode] =
  allByClass(node, cls, result)

proc attr(node: MockNode; name: string): string =
  if node.isNil: "<no element>" else: node.attributes.getOrDefault(name, "<unset>")

proc isControl(node: MockNode): bool =
  node.attr("role") == "button" and node.attr("tabindex") == "0"

proc callLine(index: int; name: string; children = false;
              expanded = false): CallLine =
  CallLine(index: index.int64, name: name, depth: 0, hasChildren: children,
           isExpanded: expanded, callKey: $index,
           location: Location(file: "/src/main.py", line: index + 1),
           rrTicks: uint64(index + 1))

proc event(id: uint64; line: int; value: string): EventLogRow =
  EventLogRow(eventId: id, kind: "event", line: line, value: value,
              rrTicks: id, file: "/src/main.py")

suite "the shared views' clickable rows are controls":

  test "a call's text and a parent's toggle are buttons; a leaf's dot is not":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      store.calltrace.lines.val = @[callLine(0, "main", children = true),
                                    callLine(1, "helper")]
      store.calltrace.totalCallsCount.val = 2
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      drainPlatformCallbacks()
      let texts = panel.allByClass("call-text")
      ck texts.len == 2
      for t in texts:
        ck t.isControl
      let toggles = panel.allByClass("toggle-call")
      ck toggles.len == 2
      if toggles.len == 2:
        ck toggles[0].isControl
        ck toggles[0].attr("aria-expanded") == "false"
        # CONTROL: the leaf.
        ck toggles[1].attr("role") == "presentation"
        ck toggles[1].attr("tabindex") == "-1"
      # The click a key stands for still goes to the call.
      mock.clearReceivedCommands()
      if texts.len == 2:
        texts[1].fireEvent("click")
      drainPlatformCallbacks()
      ck mock.findCommand("ct/calltrace-jump").isSome
      dispose()

  test "an event-log row, a header cell and a column check are buttons":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      var rows: seq[EventLogRow] = @[]
      for i in 0 ..< 3:
        rows.add event(uint64(i + 1), i + 1, "e" & $i)
      store.applyEventLogRows(rows, 0, recordsTotal = 3)
      let panel = renderEventLogPanel[MockRenderer, MockNode](MockRenderer(), vm)
      drainPlatformCallbacks()
      let shown = panel.allByClass("eventLog-row")
      ck shown.len == 3
      for row in shown:
        ck row.isControl
      var headers = 0
      for header in panel.allByClass("eventLog-column-header"):
        for cell in header.children:
          if cell.kind == mnkElement and cell.attr("data-column") != "<unset>":
            inc headers
            ck cell.isControl
      ck headers > 0
      let checksShown = panel.allByClass(EventLogColumnCheckClass)
      ck checksShown.len > 0
      for c in checksShown:
        ck c.isControl
        ck c.attr("aria-pressed") in ["true", "false"]
      mock.clearReceivedCommands()
      if shown.len == 3:
        shown[1].fireEvent("click")
      drainPlatformCallbacks()
      ck mock.findCommand("ct/event-jump").isSome
      dispose()

  test "a value's caret and a value-history line are buttons":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createStateVM(store)
      store.locals.locals.val = @[
        store_types.Variable(name: "point", value: "Point(x:1)",
                             typeName: "Point", hasChildren: true,
                             children: @[store_types.Variable(
                               name: "x", value: "1", typeName: "int")]),
        store_types.Variable(name: "n", value: "42", typeName: "int")]
      drainPlatformCallbacks()
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), vm)
      drainPlatformCallbacks()
      let carets = panel.allByClass("value-expand-button")
      ck carets.len >= 1
      for c in carets:
        ck c.isControl
        ck c.attr("aria-expanded") in ["true", "false"]
      vm.toggleHistory("n")
      vm.updateHistory("n", @[ValueHistoryRow(locationTicks: 100, valueText: "40"),
                              ValueHistoryRow(locationTicks: 110, valueText: "42")])
      drainPlatformCallbacks()
      let lines = panel.allByClass("ct-history-inline-row")
      ck lines.len == 2
      for l in lines:
        ck l.isControl
      dispose()

const
  ScrubberStyl = staticRead("../../../styles/components/list_scrubber.styl")
  DataTablesStyl = staticRead("../../../styles/components/data_tables.styl")

proc stylBlock(text, header: string; indent: int): string =
  ## The lines of the Stylus block whose header line is exactly `header` at
  ## `indent` spaces, up to the next non-blank line indented no deeper.
  var inside = false
  for line in text.splitLines:
    let stripped = line.strip(leading = true, trailing = true)
    let depth = line.len - line.strip(leading = true, trailing = false).len
    if inside:
      if stripped.len > 0 and depth <= indent and not stripped.startsWith("//"):
        break
      result.add line & "\n"
    elif depth == indent and stripped == header:
      inside = true

suite "the hand is drawn only on a control":

  test "a list scrubber is a scrollbar, not a control, and shows no hand":
    for header in [".ct-list-scrubber", ".ct-hscrubber"]:
      let rule = stylBlock(ScrubberStyl, header, 0)
      ck rule.len > 0                     # the rule is where this test looks
      ck "cursor: pointer" notin rule

  test "a table's body shows no hand; its control rows do":
    let body = stylBlock(DataTablesStyl, "tbody", 4)
    ck body.len > 0
    ck "cursor: pointer" notin body
    let rows = stylBlock(DataTablesStyl, "&[role=\"button\"]", 4)
    ck rows.len > 0
    ck "cursor: pointer" in rows

suite "assertion count":
  test "every assertion ran":
    echo "CHECKS: ", checks
    check checks == ExpectedAssertions
