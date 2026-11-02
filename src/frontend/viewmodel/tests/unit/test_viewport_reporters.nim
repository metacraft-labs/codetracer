## test_viewport_reporters.nim — the same pane asks for the same window on
## every front-end (Viewport-Driven-Loading V3, HSF-V2).
##
## Each front-end reports the panes it shows through `setViewport`, converting
## its own units with `pane_viewport`:
##
##   - the terminal, from its layout's cell rectangle
##     (`tui_session.pageCallTrace`: `cellPaneViewport(rows, cols, top,
##     colsPerLevel = CallRowIndentCells)`);
##   - GPUI, from its element's rows and pixel width
##     (`gpui_host.pageCalltrace`: `cellPaneViewport(rows, widthPx, top,
##     colsPerLevel = CallIndentPx)`, `CallIndentPx = CallRowIndentPx`);
##   - the DOM, from what the panel host measures
##     (`ui/panel_host.startMeasuring`: `pixelPaneViewport(clientHeight,
##     clientWidth, rowAdvance, scrollTop, CallDepthIndentPx)`).
##
## Here one pane — 30 rows scrolled to row 40, wide enough for 40 levels — is
## described in each front-end's units, reported to a `CalltraceVM` over the
## same trace position, and the `ct/load-calltrace-section` each asks for is
## compared. The State pane's report (which sizes the locals request) is
## compared the same way. The backend is a `MockBackendService`: what is under
## test is what the ViewModel SENDS, which the mock records.
##
## Runs on the C and JS backends.

import std/[json, unittest]

import isonim/core/[signals, owner, async_compat]

import backend/[backend_service, mock_backend]
import store/replay_data_store
import pane_viewport
import viewmodels/[calltrace_vm, state_vm]
from views/isonim_calltrace_view import CallDepthIndentPx

const
  Rows = 30
  FirstRow = 40
  Levels = 40
  DomRowAdvancePx = 25.28
    ## A row advance that is not a whole number of pixels and not exact in
    ## binary floating point, so `rows * advance / advance` lands a hair off
    ## the count — the case `pixelPaneViewport`'s tolerance exists for. (It
    ## is the mean the desktop once measured while rows with a return value
    ## were taller than the rest, codetracer-pm issue 2026-10-18; the rows
    ## are now all 1.5625em, which is fractional too at other zooms —
    ## 20.3125 px at a 13 px root.)

type Front = enum
  terminal, gpui, dom

proc reported(front: Front): Viewport =
  ## The pane, in `front`'s units, as its reporter converts it.
  case front
  of terminal:
    cellPaneViewport(Rows, Levels * CallRowIndentCells, FirstRow,
                     colsPerLevel = CallRowIndentCells)
  of gpui:
    cellPaneViewport(Rows, Levels * CallRowIndentPx, FirstRow,
                     colsPerLevel = CallRowIndentPx)
  of dom:
    pixelPaneViewport(float(Rows) * DomRowAdvancePx,
                      float(Levels) * CallDepthIndentPx,
                      DomRowAdvancePx,
                      float(FirstRow) * DomRowAdvancePx,
                      CallDepthIndentPx)

proc callTraceRequestOf(front: Front): JsonNode =
  ## The section the call trace's ViewModel asks for, at one trace position,
  ## when `front` reports the pane.
  var asked: JsonNode = nil
  createRoot proc(dispose: proc()) =
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    store.updateDebuggerPosition(1234'u64, "/src/main.rs", 17)
    let vm = createCalltraceVM(store)
    mock.clearReceivedCommands()
    vm.setViewport(reported(front))
    drainPlatformCallbacks()
    for c in mock.receivedCommands:
      if c.command == "ct/load-calltrace-section":
        asked = c.args
    dispose()
  asked

suite "one pane, one request, on every front-end":

  test "the call trace's section is the same from the terminal, GPUI and the DOM":
    let t = callTraceRequestOf(terminal)
    let g = callTraceRequestOf(gpui)
    let d = callTraceRequestOf(dom)
    check not t.isNil and not g.isNil and not d.isNil
    if not t.isNil and not g.isNil and not d.isNil:
      check t == g
      check t == d
      # And it is the window the shared policy derives for that pane.
      check t["startCallLineIndex"].getBiggestInt == FirstRow - TrailRows
      check t["height"].getInt == Rows + LeadRows + TrailRows
      check t["depth"].getInt == Levels
      check t["location"]["rrTicks"].getBiggestInt == 1234

  test "the State pane's report is the same from every front-end":
    var reports: seq[Viewport] = @[]
    for front in Front:
      createRoot proc(dispose: proc()) =
        let mock = newMockBackendService(autoRespond = true)
        let vm = createStateVM(createReplayDataStore(mock.toBackendService()))
        let v = reported(front)
        vm.setViewport(Viewport(rows: v.rows, firstRow: v.firstRow))
        reports.add vm.viewport.val
        dispose()
    check reports.len == 3
    check reports[0] == reports[1]
    check reports[0] == reports[2]
    check reports[0].rows == Rows

  test "an unmeasured pane asks for nothing, whichever front-end it is on":
    check not cellPaneViewport(0, 80, 0, CallRowIndentCells).measured
    check not pixelPaneViewport(0.0, 320.0, DomRowAdvancePx, 0.0,
                                CallDepthIndentPx).measured
    check not pixelPaneViewport(400.0, 320.0, 0.0, 0.0,
                                CallDepthIndentPx).measured
