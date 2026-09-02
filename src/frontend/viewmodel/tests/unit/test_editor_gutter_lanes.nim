## The editor gutter's band map — asserted as NUMBERS.
##
## WHAT THIS SUITE IS FOR
## ----------------------
## Three concerns were placed in this strip by three different changes, and the
## fourth had nowhere to go. Measured on `cloud` 402c1d35 at `/noir`, line 1,
## with `getBoundingClientRect` on each element:
##
##     .gutter        left 293  right 366  width 73
##     .diff-line     left 293  right 366  width 73  HEIGHT 0   <- the VCS slot
##     .gutter-line   left 306  right 335
##     breakpoint     left 336  right 345
##     tracepoint     left 347  right 357
##
## The VCS slot overlapped the line number by 29px, the breakpoint by 9px and
## the tracepoint by 10px, simultaneously. It did no visible harm only because
## it had no height — so every gutter check in the repository was green over a
## strip with no room for a change indicator at all.
##
## THE ASSERTIONS BELOW PRINT WHAT THEY RESOLVED, and that is not decoration.
## A check that reports `true` cannot be read against a screenshot or against
## the browser gate's own numbers; a check that reports
## `vcs [45,50) marker [50,80)` can, and `ci/test/web-renderer-mounts.sh`
## asserts the PAINTED boxes against the same declaration. Neither half is
## trusted on its own.
##
## Compile + run:
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_editor_gutter_lanes.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_editor_gutter_lanes.nim
##
## Both backends, because the band widths are integer arithmetic over an em and
## `div` on the JS backend is not the same operation it is on C unless someone
## has been careful. It is asserted here rather than assumed.
##
## No external binaries: `editor_gutter_lanes` is pure.

import std/[sequtils, strutils, unittest]

import ../../viewmodels/editor_gutter_lanes

const
  FontSize = 15
    ## The measured `em` of `.monaco-editor` on the `/noir` surface: the
    ## run-test control resolved to 11px against a declared `0.75em`, and
    ## 0.75 * 15 = 11.25. Every expected pixel below is derived from this.
  GutterWidth = 73
    ## `.gutter`'s measured width on the same surface. It is `100%` of the
    ## margin minus the folding lane and the marker gap, so the two bands that
    ## fall outside it still resolve here — `resolveBands` lays out the whole
    ## margin and `.gutter` is a sub-range of it.

proc bandLine(resolved: seq[ResolvedBand]): string =
  ## `pointer [0,11) line-number [11,26) ...` — the sentence every failure
  ## below prints, so a red run says WHERE the bands went and not merely that
  ## they were wrong.
  resolved.mapIt($it.band & " [" & $it.leftPx & "," & $it.rightPx & ")").join(" ")

suite "editor gutter band map":

  test "the four concerns each resolve to a band, left to right":
    ## The user's report, as a value: breakpoints/tracepoints, VCS change
    ## indicators, line numbers and the run-test control must each have
    ## somewhere of their own to be.
    let order = concernsInOrder().mapIt($it)
    checkpoint "concerns, left to right: " & order.join(" ")
    check order == @[
      "current-line-arrow", "run-test-control",
      "line-number",
      "vcs-change",
      "breakpoint", "tracepoint",
      "folding-chevron"]

  test "the run-test control is not in the breakpoint's band":
    ## (b), stated as the thing that would have to be false for a gutter click
    ## meant as "place a breakpoint" to start a test run instead.
    checkpoint "run-test control -> " & $gcRunTestControl.bandFor &
      ", breakpoint -> " & $gcBreakpoint.bandFor &
      ", tracepoint -> " & $gcTracepoint.bandFor
    check gcRunTestControl.bandFor == gbPointer
    check gcBreakpoint.bandFor == gbMarker
    check gcTracepoint.bandFor == gbMarker
    check gcRunTestControl.bandFor != gcBreakpoint.bandFor

  test "the VCS band is its own band and is not the marker band":
    ## The correction. Before this module `.diff-line` had no band: it was laid
    ## across the line number and both markers at once.
    checkpoint "vcs-change -> " & $gcVcsChange.bandFor &
      ", line-number -> " & $gcLineNumber.bandFor
    check gcVcsChange.bandFor == gbVcs
    check gcVcsChange.bandFor != gcBreakpoint.bandFor
    check gcVcsChange.bandFor != gcLineNumber.bandFor
    check gbVcs.owners == @[gcVcsChange]

  test "the marker gap owns nothing and the folding band is Monaco's":
    checkpoint "marker-gap owners: " & $gbMarkerGap.owners.len &
      ", folding isOurs: " & $gbFolding.isOurs
    check gbMarkerGap.owners.len == 0
    check gbVcsSplit.owners.len == 0
    check gbFolding.isOurs == false
    check gbMarker.isOurs
    check gbVcs.isOurs

  test "the bands resolve to these pixels at the measured font size":
    ## THE NUMBERS, not a verdict. Every one of them is `widthEmMilli *
    ## fontSize div 1000` and any change to a band's declared width lands here
    ## before it lands in a browser.
    let resolved = resolveBands(FontSize, GutterWidth)
    checkpoint bandLine(resolved)
    check resolved.len == 7
    check resolved.mapIt($it.band) == @[
      "pointer", "line-number", "vcs", "vcs-split", "marker", "marker-gap",
      "folding"]
    # pointer 0.75em -> 11, vcs 0.35em -> 5, vcs-split 0.25em -> 3,
    # marker 2.05em -> 30, gap 0.45em -> 6, folding 0.85em -> 12. Fixed total
    # 67; the line number takes the remaining 6 of the 73 measured.
    check resolved[0].leftPx == 0
    check resolved[0].rightPx == 11
    check resolved[1].leftPx == 11
    check resolved[1].rightPx == 17
    check resolved[2].leftPx == 17
    check resolved[2].rightPx == 22
    check resolved[3].leftPx == 22
    check resolved[3].rightPx == 25
    check resolved[4].leftPx == 25
    check resolved[4].rightPx == 55
    check resolved[5].leftPx == 55
    check resolved[5].rightPx == 61
    check resolved[6].leftPx == 61
    check resolved[6].rightPx == 73

  test "no two bands share a pixel":
    ## Computed from the resolved EDGES, so a band moved on top of another is
    ## caught by arithmetic rather than by someone re-reading the offsets. The
    ## failure prints the offending pair and the overlap in pixels.
    let resolved = resolveBands(FontSize, GutterWidth)
    let clashes = overlappingBands(resolved)
    checkpoint "layout: " & bandLine(resolved)
    checkpoint "overlaps: " & clashes.mapIt(
      $it.a & "/" & $it.b & " " & $it.px & "px").join(", ")
    check clashes.len == 0

  test "a band moved onto its neighbour is detected":
    ## THE PROOF THAT THE CHECK ABOVE CAN FAIL. `overlappingBands` is handed a
    ## layout in which the VCS band has been slid back over the line number —
    ## the exact shape `.diff-line` had before it was given a band — and must
    ## report it.
    let broken = @[
      ResolvedBand(band: gbPointer, leftPx: 0, rightPx: 11),
      ResolvedBand(band: gbLineNumber, leftPx: 11, rightPx: 20),
      ResolvedBand(band: gbVcs, leftPx: 0, rightPx: 55),
      ResolvedBand(band: gbMarker, leftPx: 25, rightPx: 55)]
    let clashes = overlappingBands(broken)
    checkpoint "overlaps found: " & clashes.mapIt(
      $it.a & "/" & $it.b & " " & $it.px & "px").join(", ")
    check clashes.len == 3
    check clashes.anyIt(it.a == gbPointer and it.b == gbVcs and it.px == 11)
    check clashes.anyIt(it.a == gbLineNumber and it.b == gbVcs and it.px == 9)
    check clashes.anyIt(it.a == gbVcs and it.b == gbMarker and it.px == 30)

  test "abutting bands are not an overlap":
    ## The twin of the check above. `[0,10)` and `[10,20)` share no pixel, and
    ## a version of `overlappingBands` that reported them would make the
    ## no-overlap assertion unfailable-by-being-always-red instead.
    let touching = @[
      ResolvedBand(band: gbPointer, leftPx: 0, rightPx: 10),
      ResolvedBand(band: gbLineNumber, leftPx: 10, rightPx: 20)]
    check overlappingBands(touching).len == 0

  test "zero-width bands are not reported as overlapping":
    ## `.diff-line` was 73px wide and 0px TALL, which this model cannot
    ## express — but a band given no WIDTH is the same mistake one axis over,
    ## and it must not be silently listed as clashing with everything it sits
    ## inside.
    let collapsed = @[
      ResolvedBand(band: gbVcs, leftPx: 20, rightPx: 20),
      ResolvedBand(band: gbMarker, leftPx: 0, rightPx: 55)]
    check overlappingBands(collapsed).len == 0

  test "the margin reservation grows by the VCS band":
    ## The half that keeps the line number's room. Monaco sizes the margin as
    ## the number column plus `lineDecorationsWidthPx`; a band added to our
    ## markup and not to this total is paid for out of the digits.
    let vcs = gbVcs.widthPx(FontSize) + gbVcsSplit.widthPx(FontSize)
    let withVcs = lineDecorationsWidthPx(FontSize)
    # What the function returned before the VCS band existed, recomputed here
    # rather than remembered: marker 1.8em + folding 0.5em.
    let withoutVcs = max(20, (FontSize * 9) div 5 + FontSize div 2)
    checkpoint "fontSize " & $FontSize & ": vcs band + split " & $vcs & "px, " &
      "lineDecorationsWidth " & $withoutVcs & " -> " & $withVcs
    check gbVcs.widthPx(FontSize) == 5
    check gbVcsSplit.widthPx(FontSize) == 3
    check vcs == 8
    check withoutVcs == 34
    check withVcs == 42
    check withVcs - withoutVcs == vcs

  test "the reservation never drops below Monaco's floor":
    ## `max(20, ...)` is load-bearing at small font sizes, and a floor asserted
    ## nowhere is a floor that gets refactored away.
    ## Raw sums, so the assertions below say which side of the floor each font
    ## size falls on rather than only what came out:
    ##   7 -> 12 + 1 + 1 + 3 = 18   floored to 20
    ##   8 -> 14 + 2 + 2 + 4 = 22   above it
    ##   9 -> 16 + 3 + 2 + 4 = 25   above it
    let raw = proc(f: int): int =
      (f * 9) div 5 + gbVcs.widthPx(f) + gbVcsSplit.widthPx(f) + f div 2
    checkpoint "fontSize 7: raw " & $raw(7) & " -> " & $lineDecorationsWidthPx(7) &
      "; 8: raw " & $raw(8) & " -> " & $lineDecorationsWidthPx(8) &
      "; 9: raw " & $raw(9) & " -> " & $lineDecorationsWidthPx(9) &
      "; 15: raw " & $raw(15) & " -> " & $lineDecorationsWidthPx(15)
    check raw(7) == 18
    check lineDecorationsWidthPx(7) == 20
    check raw(8) == 22
    check lineDecorationsWidthPx(8) == 22
    check raw(9) == 25
    check lineDecorationsWidthPx(9) == 25
    check lineDecorationsWidthPx(1) == 20

  test "band widths are the same integers on both backends":
    ## `div` over `emMilli * fontSize` is the one piece of arithmetic in this
    ## module, and the JS backend's numbers are IEEE754 doubles. A width that
    ## came out 30 on C and 29.999 on JS would put the marker band one pixel
    ## from where the stylesheet puts it on exactly one of the two.
    let widths = GutterBand.toSeq.mapIt($it & "=" & $it.widthPx(FontSize))
    checkpoint widths.join(" ")
    check gbPointer.widthPx(FontSize) == 11
    check gbLineNumber.widthPx(FontSize) == RemainderWidth
    check gbVcs.widthPx(FontSize) == 5
    check gbVcsSplit.widthPx(FontSize) == 3
    check gbMarker.widthPx(FontSize) == 30
    check gbMarkerGap.widthPx(FontSize) == 6
    check gbFolding.widthPx(FontSize) == 12

  test "a gutter too narrow for its bands reports it rather than clamping":
    ## The line number absorbs the remainder, and when there is none it comes
    ## out non-positive. Reported, because a clipped line number that a model
    ## claims is 0px wide is invisible to every check written against it.
    let resolved = resolveBands(FontSize, 40)
    checkpoint bandLine(resolved)
    let lineNumber = resolved.filterIt(it.band == gbLineNumber)[0]
    check lineNumber.rightPx - lineNumber.leftPx == -27
