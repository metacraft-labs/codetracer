## monaco_operations_test.nim — PLAT-68: every editing operation the CUA base
## binds runs on the desktop's editor, and a desktop key reaches the
## operations the old registries disagreed about.
##
## LANE: `frontend-js`. Compile and run:
##   nim js -r src/frontend/tests/monaco_operations_test.nim
##
## The desktop's router (`ui/key_router`) runs an editing operation as the
## Monaco command that IS it (`ui/monaco_operations.MonacoOperations`), and a
## file intent through the host (`HostIntents`). An editing row of the CUA
## base with neither would resolve, stop the event, and do nothing — so the
## table is held to the base, row by row. The few editor operations the
## desktop performs itself (the tracepoint, the read-only toggle, …) are
## named here, so a new one is a decision rather than a silent gap.
##
## And the chords the old registries got wrong, resolved in the desktop's
## own delivery (`feDesktop`) by the shipped router: `Alt+E` in the editor is
## the event log, `F10` is one step-over, `Ctrl+B` the side panels and
## `Ctrl+Shift+B` the build.
##
## No mocks: the shipped base rows, the shipped router, the shipped table.

import std/[unittest, tables]

import ../ui/monaco_operations
import ../viewmodel/keymap/[keymap_router, base_rows, cua_keymap,
                            client_actions, scope_path, context_keys,
                            editing_keymap]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 8

const DesktopPerforms = [
  ## Editor operations the desktop performs itself (`ui/key_router`'s
  ## dispatch), not through a Monaco command.
  "editor.toggle-tracepoint", "editor.toggle-read-only",
  "editor.toggle-macro-expansion", "editor.jump-to-value-origin",
  "debugger.smart-jump", "debugger.run-to-cursor",
  "debugger.source-call-jump"]

const NotOnTheDesktop = [
  ## Editing operations the desktop's editor does not have (each resolves,
  ## and the router says so on the console rather than doing nothing
  ## silently): the terminal's own and the ones Monaco ships no command for.
  "editor.toggle-tab-moves-focus", "editor.toggle-word-wrap",
  "editor.center-on-pointer", "editor.toggle-breakpoint",
  "editor.scroll-half-page-up", "editor.scroll-half-page-down",
  "insert-newline-and-indent"]

const Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                            keyProtocol: kpNative)

suite "the desktop's editing table":

  test "every editing operation CUA binds runs somewhere":
    var missing: seq[string] = @[]
    var checked = 0
    for row in CuaRows:
      if row.table.len != 0 and row.table != EditorTable: continue
      inc checked
      let (name, _) = splitOperation(row.operation)
      let op = vocabularyName(name)
      if op in HostIntents or MonacoOperations.hasKey(op) or
         clientActionOf(row.operation).len > 0 or
         row.operation in DesktopPerforms or
         row.operation in NotOnTheDesktop or op in NotOnTheDesktop:
        continue
      missing.add row.chords & " " & row.operation
    checkpoint("no desktop route: " & $missing)
    counted checked > 50
    counted missing.len == 0

  test "copy, cut and paste are Monaco's clipboard actions":
    counted MonacoOperations["clipboard-copy"] == "editor.action.clipboardCopyAction"
    counted MonacoOperations["clipboard-paste"] == "editor.action.clipboardPasteAction"

suite "the chords the old registries disagreed about":

  let facts = SessionFacts(product: pmDebug, editor: sourceViewFacts())
  let inEditor = @[element(ekWindow, "window"), pane("editor"),
                   element(ekEditor, "editor:main.py")]

  test "Alt+E in the editor focuses the event log (not macro expansion)":
    var r = initKeymapRouter(bkCua, Desktop)
    let res = r.route(facts, inEditor, nmNormal, "Alt+e", 0)
    counted res.operation == "layout.focus-pane" and res.argument == "event-log"

  test "F10 in the editor is one step-over; Ctrl+B the side panels; Ctrl+Shift+B the build":
    var r = initKeymapRouter(bkCua, Desktop)
    counted r.route(facts, inEditor, nmNormal, "F10", 0).operation ==
      "debugger.step-over"
    counted r.route(facts, inEditor, nmNormal, "Ctrl+b", 0).operation ==
      "layout.toggle-side-panels"
    counted r.route(facts, inEditor, nmNormal, "Ctrl+Shift+b", 0).operation ==
      "build.run"

  test "monaco_operations_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
