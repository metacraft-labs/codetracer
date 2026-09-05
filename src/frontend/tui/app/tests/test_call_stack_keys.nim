## test_call_stack_keys.nim — CTUI-6, Tier 1, PURE.
##
## ## What this suite is for, and why it is under `app/tests/`
##
## `app/input/call_stack_keys.nim` is a pure function of a model and a token.
## Every navigation fact this milestone rests on is decided here — that `k` at
## the innermost frame does NOT wrap to the entry point, that a collapsed
## recursion is one keystroke wide rather than forty-nine, that the wheel
## scrolls without moving the inspection cursor, that a click outside the pane
## is not a click on its nearest row — and each of those is a case a real
## terminal can only exercise one at a time.
##
## It lives under `app/tests/` because it needs NOTHING a host provides, which
## is CTUI-5's stated convention and `docs/tui-testing.md`'s: a suite here is
## covered by `tests/test_tui_facade_boundary.nim`'s walk, so it cannot grow an
## import of `headless_session`, `std/osproc` or `std/posix` without reddening
## that guard. The three CTUI-6 suites that DO need a session live one directory
## up for the same reason.
##
## ## THE MOUSE BYTES ARE THE ONES TERMASSERT WRITES
##
## `TermAssert.sendMouseClick(row, col)` writes
## `ESC [ < <button> ; <col+1> ; <row+1> M` — SGR 1006, 1-based on the wire
## (`TermAssert/src/term_assert.nim`). The decoder is asserted against exactly
## those bytes, INCLUDING the off-by-one, so the Tier-2 case can click a row and
## assert what happened rather than re-deriving where the click should have
## landed.
##
## ## No mocks, and no debugger either
##
## Nothing here opens a session: the frames are a constructed value, which is
## the whole point of the pane being a pure function of one.
##
## ## Templates, not procs, for anything that calls `check`

import std/[strutils, unittest]

import ../input/call_stack_keys
import ../views/call_stack

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 100

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  PaneWidth = 40
  PaneHeight = 9
  BodyHeight = PaneHeight - 1
  UserRoot = "/opt/ctui6/app"
  SamplePath = UserRoot & "/main.py"

proc sampleFrames(recursion = 5; tail = 3): seq[StackFrame] =
  ## `recursion` identical frames, then `tail` distinct ones.
  result = @[]
  for i in 0 ..< recursion:
    result.add StackFrame(index: i, id: 100 - i, name: "descend",
                          path: SamplePath, line: 42)
  for i in 0 ..< tail:
    result.add StackFrame(index: recursion + i, id: 10 - i,
                          name: "outer" & $i, path: SamplePath,
                          line: 100 + i)

proc sampleModel(recursion = 5; tail = 3): CallStackModel =
  initCallStackModel(frames = sampleFrames(recursion, tail),
                     userRoots = @[UserRoot])

proc screenOf(model: CallStackModel): CallStackScreen =
  callStackScreen(model, PaneWidth, PaneHeight)

proc mouseBytes(row, col: int; button = 0; press = true): string =
  ## Exactly what `TermAssert.sendMouseClick` writes for `(row, col)`.
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if press: "M" else: "m")

suite "CTUI-6: the call stack's keys and mouse are a pure function":

  test "SGR 1006 decodes to zero-based coordinates, or to nothing":
    let (ok, event) = decodeMouse(mouseBytes(row = 4, col = 11))
    ck ok
    ck event.kind == mekPress
    ck event.button == mbLeft
    ck event.row == 4
    ck event.col == 11
    # The RELEASE half of the same click, which must not act.
    let (ok2, release) = decodeMouse(mouseBytes(4, 11, press = false))
    ck ok2
    ck release.kind == mekRelease
    ck release.row == 4
    # Wheel events ride the same protocol as buttons 64 and 65.
    let (ok3, up) = decodeMouse(mouseBytes(2, 2, button = 64))
    ck ok3
    ck up.button == mbWheelUp
    let (ok4, down) = decodeMouse(mouseBytes(2, 2, button = 65))
    ck ok4
    ck down.button == mbWheelDown
    # Modifiers are decoded away rather than rejected: a ctrl-click is still a
    # click on the row it happened on. (16 is the ctrl bit.)
    let (ok5, ctrlClick) = decodeMouse(mouseBytes(3, 3, button = 16))
    ck ok5
    ck ctrlClick.button == mbLeft
    ck ctrlClick.row == 3
    # …and everything that is not an SGR-1006 report is refused, one negative
    # per way of being wrong, so "returns false" cannot be the only path tested.
    for junk in ["", "j", "\x1b[A", "\x1b[<0;1M", "\x1b[<0;1;2X",
                 "\x1b[<a;1;2M", "\x1b[<0;1;2;3M"]:
      let (bad, _) = decodeMouse(junk)
      checkpoint("decodeMouse(" & junk.escape() & ")")
      ck not bad

  test "motion clamps at both ends and never wraps":
    var model = sampleModel()
    let screen = screenOf(model)
    # The pane opens on the innermost frame, and `k` there is a NO-OP rather
    # than a jump to the entry point — a cursor that wrapped would make a held
    # key look like the stack was cycling.
    ck model.selected == 0
    ck model.applyKey(KeyUp, screen) == csaSelectionUnchanged
    ck model.selected == 0
    # `j` crosses the COLLAPSED recursion in one keystroke: five frames, one
    # row. This is the property the group exists for and the one a
    # frame-indexed motion would get wrong.
    ck model.applyKey(KeyDown, screen) == csaSelectionMoved
    ck model.selected == 5
    ck model.applyKey(KeyUp, screen) == csaSelectionMoved
    ck model.selected == 0
    # `G` is the entry point, `g` the innermost frame.
    ck model.applyKey(KeyBottom, screen) == csaSelectionMoved
    ck model.selected == model.frames.len - 1
    ck model.applyKey(KeyDown, screen) == csaSelectionUnchanged
    ck model.selected == model.frames.len - 1
    ck model.applyKey(KeyTop, screen) == csaSelectionMoved
    ck model.selected == 0
    # The arrow keys are the same motions, so a user who does not think in Vim
    # gets the same pane.
    ck model.applyKey(KeyArrowDown, screen) == csaSelectionMoved
    ck model.selected == 5
    ck model.applyKey(KeyArrowUp, screen) == csaSelectionMoved
    ck model.selected == 0
    # An unbound token changes nothing and SAYS so — `csaNone`, not
    # `csaSelectionUnchanged`, because a caller decides whether to repaint from
    # the difference.
    ck model.applyKey("Z", screen) == csaNone
    ck model.applyKey("", screen) == csaNone
    ck model.selected == 0

  test "a page is the body's height, in rows rather than in frames":
    var model = sampleModel(recursion = 4, tail = 20)
    let screen = screenOf(model)
    ck screen.bodyHeight == BodyHeight
    ck model.paneRows().len == 21
    ck model.applyKey(KeyPageDown, screen) == csaSelectionMoved
    # Row 0 is the collapsed group; a page down lands `BodyHeight` rows later,
    # which is frame `4 + BodyHeight - 1`.
    ck model.selected == 4 + BodyHeight - 1
    ck model.scrollTop > 0
    ck model.applyKey(KeyPageUp, screen) == csaSelectionMoved
    ck model.selected == 0
    ck model.scrollTop == 0

  test "expanding is a state, and collapsing keeps the cursor on a real row":
    var model = sampleModel()
    ck model.paneRows().len == 4
    ck model.applyKey(KeyToggleGroup, screenOf(model)) == csaGroupToggled
    ck model.paneRows().len == 9
    # Once expanded, the cursor sits on the MEMBER row for frame 0 rather than
    # on the header — the header of an open group represents no frame, which is
    # what keeps `j` from skipping the member it just revealed.
    ck rowOfFrame(model.paneRows(), 0) == 1
    ck model.applyKey(KeyDown, screenOf(model)) == csaSelectionMoved
    ck model.selected == 1
    ck model.applyKey(KeyDown, screenOf(model)) == csaSelectionMoved
    ck model.selected == 2
    # Collapsing with a MEMBER selected: the cursor cannot stay on a frame that
    # no longer has a row, so it lands on the group's innermost member.
    ck model.applyKey(KeyToggleGroup, screenOf(model)) == csaGroupToggled
    ck model.selected == 0
    ck model.paneRows().len == 4
    ck rowOfFrame(model.paneRows(), model.selected) == 0
    # A frame outside any group has nothing to toggle, and the pane says so
    # rather than pretending it did something.
    ck model.applyKey(KeyBottom, screenOf(model)) == csaSelectionMoved
    ck model.applyKey(KeyToggleGroup, screenOf(model)) == csaNone

  test "the wheel scrolls the pane and leaves the inspection cursor alone":
    var model = sampleModel(recursion = 4, tail = 20)
    discard model.applyKey(KeyToggleGroup, screenOf(model))
    let screen = screenOf(model)
    ck model.paneRows().len > BodyHeight
    let selectedBefore = model.selected
    ck model.applyKey(mouseBytes(3, 2, button = 65), screen) == csaScrolled
    ck model.scrollTop == WheelScrollRows
    # §4.4: the wheel scrolls "without requiring pane focus", so it must NOT
    # move the cursor — which is what would drag the source view along with it.
    ck model.selected == selectedBefore
    ck model.applyKey(mouseBytes(3, 2, button = 64), screen) == csaScrolled
    ck model.scrollTop == 0
    # …and it stops at the top rather than going negative.
    ck model.applyKey(mouseBytes(3, 2, button = 64), screen) ==
       csaSelectionUnchanged
    ck model.scrollTop == 0
    # A wheel event OUTSIDE the pane's columns is not this pane's business.
    ck model.applyKey(mouseBytes(3, PaneWidth + 5, button = 65), screen) ==
       csaNone
    ck model.scrollTop == 0

  test "a click lands on the row that was painted, and nowhere else":
    var model = sampleModel()
    let screen = screenOf(model)
    # Row 0 of the pane is the title; the body starts at row 1.
    let groupRow = bodyRowForFrame(screen, 0)
    let outerRow = bodyRowForFrame(screen, 5)
    ck groupRow == 1
    ck outerRow == 2
    ck rowAtScreenRow(screen, 0) == -1
    ck rowAtScreenRow(screen, groupRow) == 0
    ck model.applyKey(mouseBytes(outerRow, 4), screen) == csaSelectionMoved
    ck model.selected == 5
    # The release half of the same click does nothing, so one click is one
    # action rather than two.
    ck model.applyKey(mouseBytes(outerRow, 4, press = false), screen) == csaNone
    ck model.selected == 5
    # Clicking the title row, a row past the last frame, or a column outside the
    # pane is not a click on the nearest frame.
    ck model.applyKey(mouseBytes(0, 4), screen) == csaNone
    ck model.applyKey(mouseBytes(PaneHeight - 1, 4), screen) == csaNone
    ck model.applyKey(mouseBytes(outerRow, PaneWidth + 3), screen) == csaNone
    ck model.selected == 5
    # Clicking an EXPANDED group's header collapses it — the only way back from
    # a long expansion with the mouse alone.
    discard model.applyKey(KeyTop, screen)
    discard model.applyKey(KeyToggleGroup, screenOf(model))
    ck model.isExpanded(0)
    let openScreen = screenOf(model)
    # The HEADER row of the open group, found in what was painted rather than
    # assumed: `bodyRowForFrame` answers with the MEMBER row for frame 0, which
    # is a different row and a different click.
    var headerRow = -1
    for i, visible in openScreen.visible:
      if visible.kind == cskGroup:
        headerRow = openScreen.area.row + 1 + i
        break
    ck headerRow == 1
    ck model.applyKey(mouseBytes(headerRow, 2), openScreen) == csaGroupToggled
    ck not model.isExpanded(0)

  test "frame rows carry the fields §3.3.3 names":
    let model = sampleModel()
    let screen = screenOf(model)
    let row = rowText(screen.rows[2])
    checkpoint("frame row: '" & row & "'")
    # Index, signature, basename, line — and the badge.
    ck row.contains("#5")
    ck row.contains("outer0()")
    ck row.contains("main.py:100")
    ck row.contains(UserBadge)
    ck not row.contains(SamplePath)      # the BASENAME, not the path
    # A library frame is badged and dimmed through the same path.
    var withLibrary = model
    withLibrary.frames.add StackFrame(index: 8, id: 0, name: "_run",
                                      path: "/nix/store/x/lib/runpy.py",
                                      line: 7)
    let libRow = rowText(callStackScreen(withLibrary, PaneWidth,
                                         PaneHeight).rows[5])
    checkpoint("library row: '" & libRow & "'")
    ck libRow.contains(LibraryBadge)
    ck libRow.contains("runpy.py:7")
    ck classifyFrame("/nix/store/x/lib/runpy.py", @[UserRoot]) == foLibrary
    # An empty pane says so rather than painting nothing.
    let empty = callStackScreen(initCallStackModel(), PaneWidth, PaneHeight)
    ck empty.totalRows == 0
    ck rowText(empty.rows[1]).contains(EmptyStackText)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
