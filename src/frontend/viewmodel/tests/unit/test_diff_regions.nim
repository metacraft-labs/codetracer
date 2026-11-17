## test_diff_regions.nim — the unified diff's model on the shared editor
## (`view_vocabulary/diff_regions`): which unchanged runs collapse and what
## each gesture on a collapsed region's boundary does to it, the word-level
## marks inside a changed run, and the old revision's spacers that keep it
## row for row beside the new one — decided without a browser.
##
## The expected values are Monaco 0.54's behaviour for the same texts and
## options (`UnchangedRegion.fromDiffs`, `showMoreAbove` / `showMoreBelow` /
## `showAll`, the boundary widget's drag in `hideUnchangedRegionsFeature`),
## which the desktop's diff views use when the shared editor is off.
##
## No mocks: every value here is the shipped type, built by the shipped code
## from real texts.

import std/[strutils, unittest]

import ../../../view_vocabulary/[editor_dom_frame, diff_regions]

proc numbered(prefix: string; n: int): seq[string] =
  for i in 1 .. n: result.add prefix & $i

suite "unchanged regions":
  test "a run between changes keeps context at both ends":
    # 40 equal lines, one changed line at 20.
    var a = numbered("line", 40)
    var b = a
    b[19] = "changed"
    let hs = lineDiff(a, b)
    check hs.len == 1
    let rs = unchangedRegions(hs, a.len, b.len, 3, 3)
    # lines 1..16 (a run at the start keeps context below only) and 24..40
    # (a run at the end keeps context above only)
    check rs.len == 2
    check rs[0] == UnchangedRegion(originalLine: 1, modifiedLine: 1, lineCount: 16)
    check rs[1] == UnchangedRegion(originalLine: 24, modifiedLine: 24, lineCount: 17)
    check rs[0].hiddenCount == 16
    check rs[0].bandAfterLine(true) == 0
    check rs[1].bandAfterLine(true) == 23

  test "a run between two changes, and one too short to collapse":
    var a = numbered("l", 30)
    var b = a
    b[4] = "x"      # line 5
    b[25] = "y"     # line 26
    b[9] = "z"      # line 10: 4 lines after the first change
    let hs = lineDiff(a, b)
    check hs.len == 3
    let rs = unchangedRegions(hs, a.len, b.len, 3, 3)
    # 6..9 (4 lines) is under 2*3+3; 11..25 (15 lines) collapses to 14..22;
    # 1..4 needs 3+3 lines; 27..30 too.
    check rs.len == 1
    check rs[0] == UnchangedRegion(originalLine: 14, modifiedLine: 14, lineCount: 9)

  test "removed and added lines shift the new revision's numbers":
    var a = numbered("l", 30)
    var b = a[0 ..< 5] & @["new1", "new2", "new3"] & a[5 .. ^1]
    b.delete(26)    # old line 24 removed (new index 26 after the insert)
    let hs = lineDiff(a, b)
    check hs == @[DiffHunk(oldFrom: 5, oldTo: 5, newFrom: 5, newTo: 8),
                  DiffHunk(oldFrom: 23, oldTo: 24, newFrom: 26, newTo: 26)]
    let rs = unchangedRegions(hs, a.len, b.len, 0, 3)
    check rs == @[UnchangedRegion(originalLine: 1, modifiedLine: 1, lineCount: 2),
                  UnchangedRegion(originalLine: 9, modifiedLine: 12, lineCount: 12),
                  UnchangedRegion(originalLine: 28, modifiedLine: 30, lineCount: 3)]
    check rs[1].hiddenOriginalSpan == (8, 19)
    check rs[1].hiddenModifiedSpan == (11, 22)

  test "equal texts have no region":
    let a = numbered("l", 20)
    check unchangedRegions(lineDiff(a, a), a.len, a.len, 3, 3).len == 0

  test "a press, Shift+Enter, the menu and showAll":
    var r = UnchangedRegion(originalLine: 4, modifiedLine: 4, lineCount: 12)
    r.showMoreAbove(10)
    check r.visibleTop == 10
    check r.hiddenCount == 2
    check r.hiddenModifiedSpan == (13, 14)
    check r.bandAfterLine(true) == 13
    # both ends draw from the same pool: the bottom can take only what is left
    r.showMoreBelow(10)
    check r.visibleBottom == 2
    check r.hiddenCount == 0
    check r.controlsHidden
    var s = UnchangedRegion(originalLine: 4, modifiedLine: 4, lineCount: 12)
    s.showMoreBelow(1_000_000)   # "to the file's edge"
    check s.visibleBottom == 12 and s.hiddenCount == 0
    var t = UnchangedRegion(originalLine: 4, modifiedLine: 4, lineCount: 12,
                            visibleTop: 3)
    t.showAll()
    check t.visibleTop == 3 and t.visibleBottom == 9 and t.controlsHidden

  test "a drag reveals one line per line height, and a small move is a press":
    let r = UnchangedRegion(originalLine: 1, modifiedLine: 1, lineCount: 12)
    check not dragMoved(100.0, 102.0)
    check dragMoved(100.0, 103.0)
    # the upper boundary dragged three lines down (18 px lines)
    check draggedVisibleTop(0, 100.0, 154.0, 18, r) == 3
    check draggedVisibleTop(0, 100.0, 60.0, 18, r) == 0          # up: nothing to undo
    check draggedVisibleTop(0, 100.0, 1000.0, 18, r) == 12       # clamped
    # the lower boundary dragged three lines UP
    check draggedVisibleBottom(0, 100.0, 46.0, 18, r) == 3
    check draggedVisibleBottom(0, 100.0, 140.0, 18, r) == 0
    var half = r
    half.visibleTop = 10
    check draggedVisibleBottom(0, 100.0, 0.0, 18, half) == 2     # what is left

  test "a caret on a hidden line shows it from the nearer end":
    var r = UnchangedRegion(originalLine: 10, modifiedLine: 12, lineCount: 20)
    check r.revealModifiedLine(14)      # 3rd line: nearer the top
    check r.visibleTop == 3
    check r.revealModifiedLine(29)      # 18th line: nearer the bottom
    check r.visibleBottom == 3
    check not r.revealModifiedLine(13)  # already shown
    check not r.revealModifiedLine(50)  # not in the region

  test "the live regions, and hidden spans merged with folds":
    let rs = @[UnchangedRegion(originalLine: 1, modifiedLine: 1, lineCount: 5,
                               visibleTop: 5),
               UnchangedRegion(originalLine: 20, modifiedLine: 20, lineCount: 5)]
    check liveRegions(rs) == @[1]
    check mergeSpans(@[(2, 4), (10, 12)], @[(5, 6), (20, 19)]) == @[(2, 6), (10, 12)]

suite "word-level marks":
  test "only the words that changed are marked":
    let a = @["let total = add(x, y);", "same"]
    let b = @["let result = add(x, z);", "same"]
    let hs = lineDiff(a, b)
    check hs.len == 1
    let ic = innerChanges(a, b, hs[0])
    check ic.deleted.len == 2
    check a[0][ic.deleted[0].fromCol ..< ic.deleted[0].toCol] == "total"
    check a[0][ic.deleted[1].fromCol ..< ic.deleted[1].toCol] == "y"
    check ic.inserted.len == 2
    check b[0][ic.inserted[0].fromCol ..< ic.inserted[0].toCol] == "result"
    check b[0][ic.inserted[1].fromCol ..< ic.inserted[1].toCol] == "z"
    check ic.inserted[0].line == 0

  test "a changed run over several lines maps marks to their lines":
    let a = @["a", "fn one() {", "  old_call();", "}"]
    let b = @["a", "fn one() {", "  new_call(1);", "  extra();", "}"]
    let hs = lineDiff(a, b)
    check hs.len == 1
    let ic = innerChanges(a, b, hs[0])
    for s in ic.inserted:
      check s.line in 2 .. 3
      check s.toCol > s.fromCol
    var marked = ""
    for s in ic.inserted: marked.add b[s.line][s.fromCol ..< s.toCol] & "|"
    check "new_call" in marked
    check "extra" in marked
    check ic.deleted.len == 1
    check a[2][ic.deleted[0].fromCol ..< ic.deleted[0].toCol] == "old_call"

  test "a run that only adds or only removes is marked whole-line":
    let a = @["a", "b"]
    let b = @["a", "x", "y", "b"]
    let hs = lineDiff(a, b)
    check innerChanges(a, b, hs[0]).inserted.len == 0
    check wholeLineMarks(hs[0]).insertedLines == @[1, 2]
    check wholeLineMarks(hs[0]).deletedLines.len == 0
    let del = lineDiff(b, a)
    check wholeLineMarks(del[0]).deletedLines == @[1, 2]

suite "the old revision aligned beside the new one":
  test "an added run is a spacer after the old line it follows":
    # old: a b c        new: a X Y b c   (X, Y added after a)
    let hs = lineDiff(@["a", "b", "c"], @["a", "X", "Y", "b", "c"])
    let zs = originalZones(hs, [], 18)
    check zs == @[AlignZone(afterLine: 1, heightPx: 36, order: 0)]

  test "an overlay block after an added line splits the spacer":
    let hs = lineDiff(@["a", "b", "c"], @["a", "X", "Y", "b", "c"])
    # a 30 px block under new line 2 (the first added line)
    let zs = originalZones(hs, [AlignZone(afterLine: 2, heightPx: 30)], 18)
    check zs.len == 3
    check zs[0] == AlignZone(afterLine: 1, heightPx: 18, order: 0)
    check zs[1] == AlignZone(afterLine: 1, heightPx: 30, order: 1)
    check zs[2] == AlignZone(afterLine: 1, heightPx: 18, order: 2)

  test "a block after an unchanged line follows the line's old number":
    # old: a b c d    new: a c d Z  (b removed, Z added at the end)
    let hs = lineDiff(@["a", "b", "c", "d"], @["a", "c", "d", "Z"])
    check hs.len == 2
    # a band under new line 2 ("c") is under old line 3
    let zs = originalZones(hs, [AlignZone(afterLine: 2, heightPx: 24, order: -2)], 18)
    check AlignZone(afterLine: 3, heightPx: 24, order: 0) in zs
    # and Z's spacer is after old line 4
    check zs[^1].afterLine == 4 and zs[^1].heightPx == 18

  test "a block right above a change goes below the removed lines":
    # old: a b c    new: a X c  (b changed to X)
    let hs = lineDiff(@["a", "b", "c"], @["a", "X", "c"])
    let zs = originalZones(hs, [AlignZone(afterLine: 1, heightPx: 10)], 18)
    # new: [a][removed b][block][X] -> old: [a][b][block][X's spacer]
    check zs == @[AlignZone(afterLine: 2, heightPx: 10, order: 0),
                  AlignZone(afterLine: 2, heightPx: 18, order: 1)]
    # one drawn before the removed lines' block stays above them
    let first = originalZones(hs, [AlignZone(afterLine: 1, heightPx: 10, order: -2)], 18)
    check first[0] == AlignZone(afterLine: 1, heightPx: 10, order: 0)
