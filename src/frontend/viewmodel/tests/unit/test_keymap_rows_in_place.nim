## test_keymap_rows_in_place.nim — reading a keymap's rows costs no copy.
##
## `EditingKeymap.bindings` copies the whole table (a detached value: the
## caller may keep or change it). A caller on a per-key or per-item path that
## only reads the rows pays the table's size each time, and one that asks
## for it per operation pays the table's size times the operations: the chord
## lookup's reference did, and ran past the JS lane's 30-minute bound. Such
## callers iterate `rows`, which reads the rows in place.
##
## This suite holds that by COUNT, not by time: `keymapTableCopies` counts
## every whole-table copy, and the paths below must leave it where it was.
## A count does not depend on the host's load; a time would.
##
## ## No mocks
## The shipped bases and router; the words modules the omnibox and the gaze
## mark draw from.

import std/unittest

import ../../keymap/[base_keymaps, editing_keymap, keymap_router, scope_path]
import ../../editing_core
import ../../views/[agent_harbor_gaze_words, agent_harbor_process_switcher_words]

const ExpectedAssertions = 6
var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

suite "a keymap's rows, read in place":
  test "rows yields the rows bindings copies, in order":
    var same = true
    var count = 0
    for base in BaseKeymap:
      let km = keymapOf(base).keymap
      let copied = km.bindings
      var i = 0
      for b in km.rows:
        if i >= copied.len or b.operation != copied[i].operation or
           b.spelling != copied[i].spelling or b.argument != copied[i].argument:
          same = false
        inc i
      if i != copied.len: same = false
      count += i
    ck same
    ck count > 100

  test "iterating rows copies no table":
    for base in BaseKeymap: discard keymapOf(base)   # each base built once
    let before = keymapTableCopies
    var seen = 0
    for base in BaseKeymap:
      for b in keymapOf(base).keymap.rows:
        if b.chords.len > 0: inc seen
    ck seen > 100
    ck keymapTableCopies == before

  test "the words a drawn item asks for copy no table":
    for base in BaseKeymap: discard keymapOf(base)
    let before = keymapTableCopies
    for base in BaseKeymap:
      discard gazePauseChord(base)
      for b in keymapOf(base).keymap.rows:
        discard processChord(b.operation, base)
    ck keymapTableCopies == before

  test "a user keymap's rows, read per key, copy no table":
    var router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feDesktop,
      platform: pkLinux, keyProtocol: kpNative),
      user = parseUserKeymap("""[{"key": "ctrl+alt+j", "command": "debugger.step-over"}]"""))
    let before = keymapTableCopies
    var bound = 0
    for key in ["ctrl+alt+j", "f10", "enter", "escape"]:
      for b in router.user.rows:
        if b.chords.len == 1 and b.chords[0] == key: inc bound
    check bound >= 0
    ck keymapTableCopies == before

suite "assertion count":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
