## test_history_cursor.nim
##
## BACK LANDS ON THE PREVIOUS LOCATION, and forward lands on the next one.
##
## ## The defect this is shaped against
##
## History navigation on `cloud` produced the right behaviour through two
## names that were each wrong, in opposite directions:
##
##   1. `ui/debug.nim`'s `handleHistoryJump(isForward: bool)` INCREMENTED
##      `historyIndex` when `isForward` was true. `historyIndex` counts back
##      from the end of `jumpHistory`, which is appended to in visit order, so
##      incrementing walks toward OLDER entries — the back gesture.
##   2. The two call sites each compensated: `ui/debug.nim`'s toolbar `case`
##      mapped `"history-back"` to `isForward = true`, and
##      `ui/shortcuts.nim` declared `BROWSER_FORWARD = 3` / `BROWSER_BACK = 4`,
##      which are the platform's Back and Forward respectively.
##
## Correcting either half alone shipped a Back button that went forward, and
## NOTHING IN THE SUITE COULD HAVE SAID SO. There was no test over the cursor
## at all — `src/tests/gui/tests/debug-controls/toolbar-tooltip-chords.spec.ts`
## goes as far as excluding these two controls from the loop that drives every
## other toolbar button, on the grounds that driving them would assert through
## a known-wrong mapping.
##
## So the assertions here are the ones that were missing, and every one of
## them is a LANDED-ON VALUE. Not "a jump was dispatched", not "the direction
## enum came back `hdOlder`" on its own: the element of a concrete visit list
## that the cursor ends up on. A gesture that dispatches perfectly to the
## wrong location passes the first two and fails these.
##
## ## Why this file can exist at all
##
## The cursor used to live inside `ui/debug.nim`, which imports Karax, Monaco
## and the Electron bridge and cannot be compiled by a unit lane — which is
## most of the reason it was never tested. `ui/history_cursor.nim` is
## import-free, so this runs on both the C (`vm-unit`) and JS (`vm-unit-js`)
## backends, discovered by glob.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_history_cursor.nim

import std/unittest

import ../../../ui/history_cursor

# ---------------------------------------------------------------------------
# A counted `check` — Verification-Harness-Traps.md §4c.
# ---------------------------------------------------------------------------

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

template startCount() =
  asserted = 0

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

# ---------------------------------------------------------------------------
# The fixture, and the orientation it encodes
# ---------------------------------------------------------------------------

const Visited = ["first", "second", "third", "current"]
  ## A visit list in the order `DebugComponent.onCompleteMove` builds one: it
  ## APPENDS every completed move, so the last element is where the user is
  ## standing. The names say so, and the first test asserts it, because every
  ## other assertion in this file is only meaningful against that orientation.

proc landing(historyIndex: int): string =
  ## What the user sees after the cursor becomes `historyIndex`.
  ##
  ## `jumpHistory[^historyIndex]`, spelled the way `handleHistoryJump` spells
  ## it, so a change to that indexing convention breaks this file rather than
  ## quietly passing over a different one.
  Visited[Visited.len - historyIndex]

suite "history cursor — which way is back":

  test "the cursor starts on the newest entry, which is where the user is":
    startCount()
    # The premise of the whole file, asserted rather than assumed. `1` is the
    # value `resetBeforeRestart` and `resetJumpHistoryFromStartIndex` both
    # install, and it must mean "the most recently visited location".
    ck landing(1) == "current"
    ck landing(Visited.len) == "first"
    expectCount(2)

  test "back lands on the previously visited location":
    ## The single assertion that would have caught a one-sided correction of
    ## either inversion. It goes through BOTH halves — the action id is
    ## resolved to a direction, and the direction moves the cursor.
    startCount()
    let direction = historyDirectionOfAction(HistoryBackActionId)
    let next = nextHistoryIndex(Visited.len, 1, direction)
    ck next == 2
    ck landing(next) == "third"
    expectCount(2)

  test "forward from the newest entry refuses, and lands nowhere":
    ## REFUSED, not clamped. A clamp would re-issue a jump to the location
    ## already showing, which costs a round trip and records a redundant move.
    startCount()
    let direction = historyDirectionOfAction(HistoryForwardActionId)
    ck nextHistoryIndex(Visited.len, 1, direction) == 0
    expectCount(1)

  test "back walks the whole list to the oldest entry and then stops":
    ## The COUNT and every landing, not "at least one step" — the membership
    ## is knowable, so it is asserted.
    startCount()
    let direction = historyDirectionOfAction(HistoryBackActionId)
    var cursor = 1
    var landed: seq[string] = @[]
    for _ in 0 ..< 10:
      let next = nextHistoryIndex(Visited.len, cursor, direction)
      if next == 0:
        break
      cursor = next
      landed.add landing(cursor)
    ck landed.len == 3
    ck landed == @["third", "second", "first"]
    ck cursor == Visited.len
    ck nextHistoryIndex(Visited.len, cursor, direction) == 0
    expectCount(4)

  test "forward from the oldest entry retraces the list back to the newest":
    startCount()
    let direction = historyDirectionOfAction(HistoryForwardActionId)
    var cursor = Visited.len
    var landed: seq[string] = @[]
    for _ in 0 ..< 10:
      let next = nextHistoryIndex(Visited.len, cursor, direction)
      if next == 0:
        break
      cursor = next
      landed.add landing(cursor)
    ck landed == @["second", "third", "current"]
    ck cursor == 1
    ck nextHistoryIndex(Visited.len, cursor, direction) == 0
    expectCount(3)

  test "back then forward returns to the location it started on":
    ## The composition, stated as a value. A pair of directions that were both
    ## `hdOlder` would pass every one-directional check above by moving
    ## consistently; this one requires them to be opposites.
    startCount()
    let back = nextHistoryIndex(
      Visited.len, 2, historyDirectionOfAction(HistoryBackActionId))
    ck landing(back) == "second"
    let forward = nextHistoryIndex(
      Visited.len, back, historyDirectionOfAction(HistoryForwardActionId))
    ck forward == 2
    ck landing(forward) == "third"
    expectCount(3)

  test "the two toolbar ids name opposite directions":
    startCount()
    ck historyDirectionOfAction(HistoryBackActionId) == hdOlder
    ck historyDirectionOfAction(HistoryForwardActionId) == hdNewer
    ck historyDirectionOfAction(HistoryBackActionId) !=
       historyDirectionOfAction(HistoryForwardActionId)
    expectCount(3)

  test "the fourth mouse button is Back and the fifth is Forward":
    ## `MouseEvent.button`: 3 is the fourth button, which desktop browsers
    ## make Back, and 4 is the fifth, Forward. `ui/shortcuts.nim` had these
    ## two numbers under each other's names.
    ##
    ## Asserted as LANDINGS as well as directions, because the numbers being
    ## right is only half of it — what matters is that pressing the physical
    ## Back button puts the user on the location they were on before.
    startCount()
    ck MouseButtonBack == 3
    ck MouseButtonForward == 4
    ck landing(nextHistoryIndex(
      Visited.len, 1, historyDirectionOfMouseButton(MouseButtonBack))) == "third"
    ck nextHistoryIndex(
      Visited.len, 1, historyDirectionOfMouseButton(MouseButtonForward)) == 0
    ck landing(nextHistoryIndex(
      Visited.len, Visited.len,
      historyDirectionOfMouseButton(MouseButtonForward))) == "second"
    expectCount(5)

  test "the mouse buttons and the toolbar ids agree on direction":
    ## The two gestures are the same navigation and must not drift apart —
    ## the mouse path drifting from the toolbar path is precisely what the
    ## swapped constants were.
    startCount()
    ck historyDirectionOfMouseButton(MouseButtonBack) ==
       historyDirectionOfAction(HistoryBackActionId)
    ck historyDirectionOfMouseButton(MouseButtonForward) ==
       historyDirectionOfAction(HistoryForwardActionId)
    expectCount(2)

  test "an empty history refuses in both directions":
    ## `jumpHistory` is empty before the first completed move and after
    ## `resetBeforeRestart`. Both directions, because a guard that only
    ## covered one would leave the other indexing `[^1]` of nothing.
    startCount()
    ck nextHistoryIndex(0, 1, hdOlder) == 0
    ck nextHistoryIndex(0, 1, hdNewer) == 0
    expectCount(2)

  test "a one-entry history has nowhere to go":
    startCount()
    ck nextHistoryIndex(1, 1, hdOlder) == 0
    ck nextHistoryIndex(1, 1, hdNewer) == 0
    expectCount(2)
