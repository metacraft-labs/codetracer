## test_editor_surface_web_terminal.nim
##
## Shared-DOM-Front-Ends D7.4 (a): the web editor (Monaco, which holds the
## file's text itself) and the terminal's source pane (`SourceVM`, which asks
## for the window it shows) mark the same lines for the same position. Both
## surfaces are built from one session store — one debugger position, one set
## of breakpoints, one set of values in scope — and compared row by row: the
## execution pointer, the mark, the values and the flow state of every line.
##
## No mocks beyond `MockBackendService` standing in for the DAP transport; the
## store, the ViewModels and both surface builders are the shipped ones.

import std/[strutils, unittest]

import isonim/core/[signals, computation, async_compat]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import store/degraded_state
import viewmodels/[editor_vm, source_vm, state_vm]
import ../../../view_vocabulary/editor_surface
import ../../../../common/value_presentation

const
  Path = "/src/main.py"
  Text = @["def main():", "    x = 1", "    y = x + 1", "    print(y)",
           "main()"]

proc buildStore(): ReplayDataStore =
  let mock = newMockBackendService(autoRespond = true)
  createReplayDataStore(mock.toBackendService())

proc rowFacts(row: EditorRow): string =
  $row.line & "|" & $row.pointer & "|" & $row.mark & "|" & $row.flow & "|" &
    $row.values

suite "the web editor and the terminal mark the same lines":

  test "one position, one set of points and values, the same rows":
    let store = buildStore()
    let editor = createEditorVM(store)
    let source = createSourceVM(store, editor)
    let state = createStateVM(store)
    store.updateDebuggerPosition(42'u64, Path, 3)
    store.locals.locals.val = @[
      Variable(name: "x", value: "1", typeName: "int"),
      Variable(name: "y", value: "2", typeName: "int")]
    store.applyVerifiedBreakpoints(Path, verified = @[(line: 2, column: 0)],
                                   disabled = @[(line: 4, column: 0)])
    drainPlatformCallbacks()

    # The terminal: the window the source pane asks for, fulfilled.
    source.setViewport(Viewport(rows: Text.len, cols: 80, firstRow: 0))
    check source.fulfill(source.revision.val, 1, Text, Text.len)
    let terminal = editorSurfaceFor(source, editor, state, nil, savVerified,
      tuiValueBudget(), "terminal",
      points = editorPointsOf(store.pointList.rows.val))

    # The web: the same lines, read from the editor that holds them.
    let web = editorSurfaceForView(Path, 1, Text.len,
      proc(line: int): string = Text[line - 1],
      store, editor, state, nil, tuiValueBudget(), "web")

    check terminal.executionLine == 3
    check web.executionLine == 3
    check terminal.rows.len == Text.len
    check web.rows.len == Text.len
    for i in 0 ..< min(terminal.rows.len, web.rows.len):
      check rowFacts(web.rows[i]) == rowFacts(terminal.rows[i])
    # And the facts themselves, so agreeing on nothing cannot pass.
    check web.rows[1].mark == emBreakpoint
    check web.rows[3].mark == emBreakpointDisabled
    check web.rows[2].pointer == eptExecution
    check web.rows[2].values.len > 0

  test "a position in another file marks no line in this one":
    let store = buildStore()
    let editor = createEditorVM(store)
    let state = createStateVM(store)
    store.updateDebuggerPosition(7'u64, "/src/other.py", 3)
    let web = editorSurfaceForView(Path, 1, Text.len,
      proc(line: int): string = Text[line - 1],
      store, editor, state, nil, tuiValueBudget(), "web")
    check web.executionLine == 0
    for row in web.rows:
      check row.pointer != eptExecution
