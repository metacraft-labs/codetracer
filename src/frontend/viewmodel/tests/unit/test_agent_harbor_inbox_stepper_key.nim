## The Inbox panel names its own keys: its hint and its Previous / Next
## tooltips say `]` and `[`, the Inbox table's rows, even though the window's
## table also binds the same operations to `Alt+]` / `Alt+[` (the sessions
## bar's keys, which step the inbox from anywhere and so resolve in the panel
## too).
##
## * **The precondition**: the window's `Alt+]` / `Alt+[` rows exist and,
##   typed in the Inbox panel, run Next and Previous. Without them the
##   question this file asks would answer itself.
## * **The words**: `stepperKey`, `stepperTitle` and `itemHintText` name `]`
##   and `[`, and the key named, typed in the Inbox panel, runs the operation
##   (the key shown is one that does what it says).
## * **The rows named** are the Inbox table's own, so a rebinding of the
##   window's chords cannot reach the panel's words.
##
## No mocks: the shipped CUA base, the shared router and the shared words.

import std/unittest
import ../../keymap/[base_keymaps, context_keys, editing_keymap,
                     keymap_router, operation_catalogue, scope_path]
import ../../views/agent_harbor_changes_inbox_words
import ../../views/agent_harbor_sessions_bar_words

proc webRouter(): KeymapRouter =
  ## The router `stepperKey` asks: the CUA base on the web front-end.
  initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb, platform: hostPlatform(),
                                      keyProtocol: kpNative))

let inbox = @[element(ekWindow, "window"), pane(InboxPanelScope)]

proc resolve(path: ScopePath; key: string): string =
  ## The operation `key`, typed at `path`, resolves to; "" for none.
  var r = webRouter()
  let res = r.route(SessionFacts(), path, nmNormal, key, 0)
  if res.kind == erOperation: res.operation else: ""

suite "the window's chords reach the Inbox panel too":
  test "Alt+] and Alt+[ are window rows and step the inbox inside the panel":
    var next, previous = 0
    for b in webRouter().effective.rows:
      if tableOf(b) == GlobalTable and b.operation == InboxNextOperation: inc next
      if tableOf(b) == GlobalTable and b.operation == InboxPreviousOperation: inc previous
    check next == 1
    check previous == 1
    check resolve(inbox, InboxNextChord) == InboxNextOperation
    check resolve(inbox, InboxPreviousChord) == InboxPreviousOperation

suite "the Inbox panel's words name its own keys":
  test "stepperKey names ] and [":
    check stepperKey(true) == "]"
    check stepperKey(false) == "["

  test "the Previous and Next tooltips name ] and [":
    check stepperTitle(true) == NextTitle & " (])"
    check stepperTitle(false) == PreviousTitle & " ([)"

  test "the item hint names ]":
    check itemHintText() == "Select an item, or press ] for the one at the top"

  test "the key named, typed in the Inbox panel, runs the operation":
    check resolve(inbox, stepperKey(true)) == InboxNextOperation
    check resolve(inbox, stepperKey(false)) == InboxPreviousOperation

suite "the keys named are the Inbox table's rows":
  test "] and [ are rows of the Inbox table for Next and Previous":
    var named = 0
    for b in webRouter().effective.rows:
      if tableOf(b) == InboxTable and
         (b.operation == InboxNextOperation and b.spelling == stepperKey(true) or
          b.operation == InboxPreviousOperation and b.spelling == stepperKey(false)):
        inc named
    check named == 2
