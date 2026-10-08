## test_plat51_shared_models.nim — PLAT-51, the two PURE models the three
## front-ends share, swept rather than sampled:
##
##   * `viewmodels/scrollbar_scrubber` — a list pane's scrollbar scrubber
##     (Scrollbar-Scrubbers.md): over populations from 1 to a million rows,
##     views of 1 to 40 rows and tracks of 8 to 600 units, a press on the
##     track's LAST unit shows the population's LAST row and on its first the
##     first (§5); a press anywhere is monotonic in the pointer; the thumb
##     never leaves the track (a drag's fetch count is bounded where the
##     front-ends issue fetches: `test_plat51_scrubbers`, the GPUI plan
##     suite);
##   * `viewmodels/value_changes` — what a stop changed (CTUI-7's anchor rule,
##     shared by the desktop's `.value-changed`, the terminal's and GPUI's
##     accents since PLAT-51): the anchor is the recording's predecessor, an
##     added binding counts, a removed one has no row to mark, the first stop
##     marks nothing.
##
## No mocks: pure functions of values. Runs on the C and the JS backends.

import std/[tables, unittest]

import viewmodels/scrollbar_scrubber
import viewmodels/value_changes

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Totals = [1, 2, 5, 69, 70, 603, 10_000, 1_000_000]
  Views = [1, 10, 27, 40]
  Tracks = [8, 40, 200, 595]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 211

suite "PLAT-51: the list scrubber model, swept":

  test "the track's ends are the population's ends, at every size":
    var cases = 0
    var endsOk = 0
    var monotonic = 0
    var inTrack = 0
    for total in Totals:
      for visible in Views:
        for units in Tracks:
          inc cases
          let m = scrubberModel(total, 0, visible)
          let last = m.clickAt(trackFractionAt(units - 1, units))
          let first = m.clickAt(trackFractionAt(0, units))
          # The LAST row of the whole population is in the view after a press
          # on the last unit; the first after a press on the first.
          if last == m.maxFirstVisible and last + min(visible, total) >= total and
             first == 0:
            inc endsOk
          var prev = -1
          var ok = true
          for pos in 0 ..< units:
            let top = m.clickAt(trackFractionAt(pos, units))
            if top < prev: ok = false
            prev = top
          if ok: inc monotonic
          var spanOk = true
          for fv in [0, total div 3, total - 1, total + 5]:
            let span = scrubberModel(total, fv, visible).thumbSpan(
              units, min(units, 8))
            if span.start < 0 or span.start + span.length > units or
               span.length < 1:
              spanOk = false
          if spanOk: inc inTrack
    checkpoint($cases & " cases")
    ck cases == Totals.len * Views.len * Tracks.len
    ck endsOk == cases
    ck monotonic == cases
    ck inTrack == cases

  test "a press per unit on every track: the thumb's start follows the view":
    for total in Totals:
      for units in Tracks:
        let m = scrubberModel(total, 0, 27)
        for pos in [0, units div 2, units - 1]:
          let top = m.clickAt(trackFractionAt(pos, units))
          let moved = scrubberModel(total, top, 27)
          let span = moved.thumbSpan(units, 8)
          ck span.start >= 0
          ck span.start + span.length <= units

suite "PLAT-51: what a stop changed, as every front-end marks it":

  proc vals(pairs: openArray[(string, string)]): Table[string, string] =
    for (k, v) in pairs: result[k] = v

  test "the anchor is the recording's predecessor; the first stop marks nothing":
    var t = initValueTimeline()
    t.observe(20, vals({"x": "2", "y": "1"}))
    let first = t.diffAt(20)
    ck first.currentKnown
    ck not first.anchorKnown
    ck first.modifiedPaths().len == 0
    t.observe(10, vals({"x": "1", "y": "1"}))
    let d = t.diffAt(20)
    ck d.anchorKnown and d.anchorTick == 10
    ck d.modifiedPaths() == @["x"]
    ck d.isModified("x")
    ck not d.isModified("y")
    # A stop observed between them becomes the anchor (a backward step's
    # rule: what the step INTO tick 20 changed, not where the user came from).
    t.observe(15, vals({"x": "2", "y": "1"}))
    let e = t.diffAt(20)
    ck e.anchorTick == 15
    ck e.modifiedPaths().len == 0

  test "an added binding is marked; a removed one has no row to mark":
    var t = initValueTimeline()
    t.observe(1, vals({"a": "1", "gone": "x"}))
    t.observe(2, vals({"a": "1", "b": "2"}))
    let d = t.diffAt(2)
    ck d.changeFor("b") == vchAdded
    ck d.isModified("b")
    ck d.changeFor("gone") == vchRemoved
    ck not d.isModified("gone")
    ck d.modifiedPaths() == @["b"]
    ck not t.diffAt(3).currentKnown

suite "PLAT-51 shared models: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
