## Headless tests for `src/frontend/ui/measured_width.nim`: how often the
## session tab bar reads its width from the layout.
##
## Regression target: the tab bar renders on every `data.redraw()` and read
## `clientWidth` each time, which forces the browser to lay out everything the
## redraw had just written (327 ms of one call-trace jump's renderer time on a
## loaded host). The width is now read once and again only after a resize.
##
## The one stand-in, and why it is not a mock: `read` is the layout read the
## bar makes (`clientWidth`); the closure counts the calls and returns the
## width a laid-out bar would. The count is the subject; no timing is involved.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/session-chrome/measured_width_test.nim

import std/unittest

import ../../../../frontend/ui/measured_width

suite "measured width":

  test "ten renders without a resize read the layout once":
    var measured: MeasuredWidth
    var reads = 0
    for _ in 0 ..< 10:
      check measured.widthOf(proc(): int = (inc reads; 960)) == 960
    check reads == 1
    check measured.reads == 1

  test "a resize makes the next render read it again":
    var measured: MeasuredWidth
    var width = 960
    var reads = 0
    discard measured.widthOf(proc(): int = (inc reads; width))
    width = 640
    measured.invalidate()
    check measured.widthOf(proc(): int = (inc reads; width)) == 640
    check measured.widthOf(proc(): int = (inc reads; width)) == 640
    check reads == 2

  test "a bar not laid out yet is read again":
    var measured: MeasuredWidth
    var width = 0
    var reads = 0
    check measured.widthOf(proc(): int = (inc reads; width)) == 0
    width = 800
    check measured.widthOf(proc(): int = (inc reads; width)) == 800
    check measured.widthOf(proc(): int = (inc reads; width)) == 800
    check reads == 2
