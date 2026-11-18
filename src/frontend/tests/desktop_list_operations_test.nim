## desktop_list_operations_test.nim — every list operation the CUA base binds
## on the desktop runs there, or the desktop answers it.
##
## LANE: `frontend-js`. Compile and run:
##   nim js -d:nodejs --path:src/frontend/viewmodel \
##     -r src/frontend/tests/desktop_list_operations_test.nim
##
## The desktop's router (`ui/key_router`) stops the event of every operation
## it runs. A list row of the CUA base the desktop neither performs nor
## answers resolves, logs "not available on the desktop" on the console and
## hands the key on to the element — what `Ctrl+Enter`
## (`list.activate-redirected`, CUA-Keymap.md §3.6) did until codetracer-pm
## `issues/2026-10-30-ctrl-enter-on-a-desktop-list-resolves-to-an-operation-
## the-desktop-does-not-run.md`. So the list table is held to the base, row
## by row, as `monaco_operations_test.nim` holds the editing table.
##
## §3.6 binds `Ctrl+Enter` wherever the front-end is not the web studio, and
## says a list whose rows have no second destination answers that it has
## none. The desktop has no such list: its Test Results pane takes no keys
## (Test-Results-Pane.md §8.4), and no other list has a second destination.
## So the desktop answers, on the status bar (`desktopAnswerOf`, the pure half
## of the router's dispatch).
##
## No mocks: the shipped base rows, the shipped router, the shipped tables
## and the shipped answer.

import std/[unittest, strutils]

import ../ui/native_key_operations
import ../viewmodel/keymap/[keymap_router, base_rows, cua_keymap,
                            client_actions, scope_path, context_keys,
                            editing_keymap]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 12

const DesktopPerforms = [
  ## List and output-pane operations the desktop's dispatch performs itself
  ## (`key_router.runTableOperation` and `runDesktopOperation`'s own cases),
  ## not through a `ClientAction`.
  "list.show-detail", "list.copy", "list.toggle-expand",
  "view.scroll-left", "view.scroll-right"]

const Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                            keyProtocol: kpNative)
const DesktopMac = KeyDelivery(frontEnd: feDesktop, platform: pkMac,
                               keyProtocol: kpNative)
const Web = KeyDelivery(frontEnd: feWeb, platform: pkLinux,
                        keyProtocol: kpNative)

let facts = SessionFacts(product: pmDebug, replayLoaded: true,
                         editor: sourceViewFacts())

func inPane(kind: string): ScopePath =
  @[element(ekWindow, "window"), pane(kind)]

suite "the desktop's list table":

  test "every list operation CUA binds on the desktop runs or is answered there":
    var missing: seq[string] = @[]
    var checked = 0
    for row in CuaRows:
      if row.table != ListTable: continue
      inc checked
      let op = row.operation
      if clientActionOf(op).len > 0 or op in DesktopPerforms or
         desktopAnswerOf(op, inPane("calltrace"), mac = false).len > 0:
        continue
      missing.add row.chords & " " & op & " [" & row.whenText & "]"
    checkpoint("no desktop route: " & $missing)
    counted checked >= 15
    counted missing.len == 0

suite "Ctrl+Enter on a desktop list":

  test "the desktop's router resolves it; the web studio's does not":
    var desk = initKeymapRouter(bkCua, Desktop)
    counted desk.route(facts, inPane("calltrace"), nmNormal, "Ctrl+Enter",
                       0).operation == "list.activate-redirected"
    var web = initKeymapRouter(bkCua, Web)
    counted web.route(facts, inPane("calltrace"), nmNormal, "Ctrl+Enter",
                      0).operation != "list.activate-redirected"

  test "a list answers that its rows have no second destination":
    let note = desktopAnswerOf("list.activate-redirected",
                               inPane("calltrace"), mac = false)
    checkpoint(note)
    counted "Open in the Other Tab" in note
    counted "no second destination" in note
    counted desktopAnswerOf("list.activate-redirected", inPane("eventLog"),
                            mac = false) == note

  test "the Test Results pane says it takes no keys, and names the press":
    let note = desktopAnswerOf("list.activate-redirected",
                               inPane("testResults"), mac = false)
    checkpoint(note)
    counted "takes no keys" in note
    counted "Ctrl+click" in note
    let macNote = desktopAnswerOf("list.activate-redirected",
                                  inPane("testResults"), mac = true)
    counted "Cmd+click" in macNote and "Ctrl+click" notin macNote

  test "the macOS desktop resolves it too (Ctrl, not Cmd: §3.6's chord)":
    var desk = initKeymapRouter(bkCua, DesktopMac)
    counted desk.route(facts, inPane("eventLog"), nmNormal, "Ctrl+Enter",
                       0).operation == "list.activate-redirected"

  test "an operation the desktop runs is not answered instead":
    counted desktopAnswerOf("list.activate", inPane("calltrace"),
                            mac = false).len == 0

  test "desktop_list_operations_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
