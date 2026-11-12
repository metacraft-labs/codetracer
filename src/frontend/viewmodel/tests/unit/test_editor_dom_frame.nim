## test_editor_dom_frame.nim — the shared editor's DOM frame, as a value
## (`view_vocabulary/editor_dom_frame`): what the desktop's shared editor
## (`ui/shared_editor`) draws for one viewport, decided without a browser.
##
## The cases hold the frame to a real `EditingDocument` — the editing core
## the terminal and GPUI edit — and to the core's own decoration mapping:
## a decoration put on a line follows the text through a keystroke; a fold
## hides exactly the block the core's `fold-all` would fold; a view zone
## pushes the lines below it down by its height and a pointer over it answers
## its anchor line; Monaco's UTF-16 columns and the core's bytes convert both
## ways over text with two-byte and four-byte characters.
##
## No mocks: every value here is the shipped type, built by the shipped code.

import std/[strutils, tables, unittest]

import ../../editing_core
import ../../editor/[document_version, change_set]
import ../../../view_vocabulary/editor_dom_frame
import ../../../tui/app/syntax/[lexical, token_class]

const Source = """def main():
    x = 1
    if x:
        y = 2

    return x
print(main())
"""

proc docOf(text: string): EditingDocument =
  initEditingDocument("/src/main.py", text)

suite "the line index":
  test "line starts, ends and the line of an offset":
    let ix = buildLineIndex(Source, DocumentVersion(0))
    check ix.lineCount == 8          # the text ends in a newline
    check ix.lineStart(1) == "def main():\n".len
    check ix.lineText(Source, 1) == "    x = 1"
    check ix.lineEnd(0) == "def main():".len
    check ix.lineOfOffset(0) == 0
    check ix.lineOfOffset("def main():\n".len) == 1
    check ix.lineOfOffset("def main():\n".len - 1) == 0
    check ix.lineText(Source, 4) == ""
    check ix.lineText(Source, 7) == ""

suite "the line index follows an edit":
  test "the moved index equals a rebuilt one, for edits anywhere":
    var d = docOf(Source)
    var ix = buildLineIndex(d.state.doc, d.timeline.version)
    let script = @[(0, 0, "Enter"), (3, 4, "Enter"), (7, 0, "x"),
                   (2, 2, "BackSpace"), (5, 1, "Delete"), (1, 0, "Enter"),
                   (8, 0, "y")]
    var t = 1000'i64
    for (line, col, key) in script:
      let before = d.timeline.version
      d.moveCaretTo(min(line, d.lineCount - 1), col)
      discard d.applyKey(editScopeOf(d), key, t)
      t += 1000
      let cs = d.timeline.delta(before)
      ix = updatedLineIndex(ix, cs, d.state.doc, d.timeline.version)
      let rebuilt = buildLineIndex(d.state.doc, d.timeline.version)
      check ix.starts == rebuilt.starts
      check ix.textLen == rebuilt.textLen
    check d.state.doc != Source

suite "Monaco's columns and the core's bytes":
  test "two-byte and four-byte characters convert both ways":
    let line = "a\xC3\xA9b\xF0\x9F\x98\x80c"   # a é b 😀 c
    check monacoColumnOf(line, 0) == 1
    check monacoColumnOf(line, 1) == 2     # after `a`
    check monacoColumnOf(line, 3) == 3     # after `é` (2 bytes, 1 unit)
    check monacoColumnOf(line, 4) == 4     # after `b`
    check monacoColumnOf(line, 8) == 6     # after 😀 (4 bytes, 2 units)
    check byteColumnOf(line, 3) == 3
    check byteColumnOf(line, 6) == 8
    check byteColumnOf(line, 7) == 9
    for b in [0, 1, 3, 4, 8, 9]:
      check byteColumnOf(line, monacoColumnOf(line, b)) == b
  test "positions and offsets agree over a document":
    let ix = buildLineIndex(Source, DocumentVersion(0))
    for (line, col) in [(1, 1), (2, 5), (4, 9), (7, 6)]:
      let off = ix.offsetOfPosition(Source, line, col)
      check ix.positionOfOffset(Source, off) == (line, col)

suite "decorations live in the core's set and follow the text":
  test "deltaDecorations adds, answers ids and removes":
    var t = initDecorationTable(DocumentVersion(0))
    let ids = t.deltaDecorations([], [
      DecoRequest(fromOffset: 12, toOffset: 21,
                  options: DecoOptions(className: "on", isWholeLine: true)),
      DecoRequest(fromOffset: 0, toOffset: 3,
                  options: DecoOptions(inlineClassName: "kw"))])
    check ids.len == 2
    check ids[0] != ids[1]
    check t.rangeOf(ids[0]) == (true, 12, 21)
    let left = t.deltaDecorations([ids[0]], [])
    check left.len == 0
    check not t.rangeOf(ids[0]).found
    check t.rangeOf(ids[1]) == (true, 0, 3)

  test "a decoration follows its line through a keystroke":
    var d = docOf(Source)
    var t = initDecorationTable(d.timeline.version)
    # Line 4 (`        y = 2`), whole line.
    let ix0 = buildLineIndex(d.state.doc, d.timeline.version)
    let a = ix0.lineStart(3)
    let ids = t.deltaDecorations([], [DecoRequest(fromOffset: a,
      toOffset: ix0.lineEnd(3),
      options: DecoOptions(className: "on", isWholeLine: true,
                           glyphMarginClassName: "gutter-glyph-breakpoint"))])
    # Type a new line at the very start of the document.
    d.moveCaretTo(0, 0)        # 0-based
    discard d.applyKey(editScopeOf(d), "Enter", 1000)
    check d.state.doc.startsWith("\n")
    t.followDocument(d)
    check t.mapped == 1
    let ix1 = buildLineIndex(d.state.doc, d.timeline.version)
    let r = t.rangeOf(ids[0])
    check r.found
    check ix1.lineOfOffset(r.fromOffset) == 4     # moved down one line
    let byLine = t.decorationsByLine(ix1, 0, ix1.lineCount - 1)
    check byLine.hasKey(4)
    check "on" in byLine[4].lineClasses
    check "gutter-glyph-breakpoint" in byLine[4].glyphClasses
    check not byLine.hasKey(3)

  test "margin classes go on the range's first line only":
    let ix = buildLineIndex(Source, DocumentVersion(0))
    var t = initDecorationTable(DocumentVersion(0))
    discard t.deltaDecorations([], [DecoRequest(fromOffset: ix.lineStart(1),
      toOffset: ix.lineEnd(2),
      options: DecoOptions(className: "diff", glyphMarginClassName: "g",
                           inlineClassName: "i"))])
    let byLine = t.decorationsByLine(ix, 0, 7)
    check "g" in byLine[1].glyphClasses
    check byLine[2].glyphClasses.len == 0
    check "diff" in byLine[2].lineClasses
    check byLine[1].inline.len == 1
    check byLine[1].inline[0].fromCol == 0
    check byLine[1].inline[0].toCol == 9
    check byLine[1].inline[0].cls == "i"
    check byLine[2].inline.len == 1
    check byLine[2].inline[0].toCol == ix.lineText(Source, 2).len

  test "injected content goes at the range's end":
    let ix = buildLineIndex(Source, DocumentVersion(0))
    var t = initDecorationTable(DocumentVersion(0))
    let e = ix.lineEnd(1)
    discard t.deltaDecorations([], [DecoRequest(fromOffset: e, toOffset: e,
      options: DecoOptions(afterContent: "x = 1", afterClass: "flow-value",
                           showIfCollapsed: true))])
    let byLine = t.decorationsByLine(ix, 1, 1)
    check byLine[1].after.len == 1
    check byLine[1].after[0].col == ix.lineText(Source, 1).len
    check byLine[1].after[0].text == "x = 1"
    check byLine[1].after[0].cls == "flow-value"

suite "folding hides the indented block":
  test "a fold hides the deeper lines and keeps the trailing blank one":
    let ix = buildLineIndex(Source, DocumentVersion(0))
    check isFoldable(ix, Source, 0)
    check isFoldable(ix, Source, 2)
    check not isFoldable(ix, Source, 1)
    check foldEnd(ix, Source, 2) == 3        # `if x:` hides `y = 2` only
    check foldEnd(ix, Source, 0) == 5        # `def` hides through `return x`
    check hiddenRanges(ix, Source, [2]) == @[(first: 3, last: 3)]
    check hiddenRanges(ix, Source, [0, 2]) == @[(first: 1, last: 5)]
    check hiddenRanges(ix, Source, [1]).len == 0

suite "the vertical layout":
  test "zones push lines down and folds take them out":
    let lay = verticalLayout(8, 20, @[(first: 3, last: 3)],
                             [ZoneSpec(id: 1, afterLine: 1, heightPx: 50)])
    check lay.topOfLine(1) == 0
    check lay.topOfLine(2) == 20 + 50          # below the zone after line 1
    check lay.topOfLine(3) == 40 + 50
    check lay.topOfLine(5) == 60 + 50          # line 4 is folded away
    check lay.topOfLine(4) == lay.topOfLine(5) # a hidden line has no height
    check lay.zoneTop(ZoneSpec(id: 1, afterLine: 1, heightPx: 50)) == 20
    check lay.contentHeight == 7 * 20 + 50
    check lay.lineAtY(0) == 1
    check lay.lineAtY(19) == 1
    check lay.lineAtY(45) == 1                 # inside the zone: its anchor
    check lay.lineAtY(70) == 2
    check lay.lineAtY(110) == 5
    check lay.visibleLines(0, 115) == @[1, 2, 3, 5]
    check lay.visibleLines(90, 40) == @[3, 5]

  test "a zone under a folded line is hidden with it":
    let lay = verticalLayout(6, 10, @[(first: 1, last: 2)],
                             [ZoneSpec(id: 1, afterLine: 2, heightPx: 30)])
    check lay.contentHeight == 4 * 10
    check lay.topOfLine(4) == 10

suite "a line's spans":
  test "tokens cut at decoration edges, the text concatenates back":
    let line = "    x = 1"
    var ctx = ""
    let runs = tokenRuns(lexerForPath("a.py"), line, ctx)
    check runs.len > 1
    var deco = LineDecorations()
    deco.inline.add (fromCol: 4, toCol: 5, cls: "ct-hit")
    deco.after.add (col: line.len, text: "x=1", cls: "flow-value")
    let spans = lineSpans(line, runs, deco)
    check textOfSpans(spans) == line
    var sawHit = false
    var sawAfter = false
    for s in spans:
      if s.kind == skText and s.text == "x":
        sawHit = "ct-hit" in s.classes
      if s.kind == skInjected:
        sawAfter = s.text == "x=1" and s.classes == @["flow-value"] and
                   s.fromCol == line.len
    check sawHit
    check sawAfter
    # The number keeps its token class through the cuts.
    var numberClass = tcPlain
    for s in spans:
      if s.text == "1": numberClass = s.tokenClass
    check numberClass == tcNumber

suite "brackets and words":
  test "the bracket at the caret and its partner":
    let t = "f(a[1], {b})"
    check matchingBracket(t, 1) == (true, 1, 11)
    check matchingBracket(t, 12) == (true, 1, 11)
    check matchingBracket(t, 3) == (true, 3, 5)
    check matchingBracket(t, 8) == (true, 8, 10)
    check not matchingBracket("abc", 1).found
  test "the word at a column":
    let line = "  foo_bar(baz)"
    check wordAt(line, 3) == (true, 2, 9)
    check wordAt(line, 9) == (true, 2, 9)
    check wordAt(line, 11) == (true, 10, 13)
    check not wordAt(line, 0).found

suite "the unified diff's line diff":
  test "removed, added and changed runs, and nothing for equal text":
    let a = @["a", "b", "c", "d", "e"]
    let b = @["a", "c", "x", "y", "e", "f"]
    let hs = lineDiff(a, b)
    # `b` removed; `d` changed to `x`, `y`; `f` added at the end.
    check hs.len == 3
    check hs[0] == DiffHunk(oldFrom: 1, oldTo: 2, newFrom: 1, newTo: 1)
    check hs[1] == DiffHunk(oldFrom: 3, oldTo: 4, newFrom: 2, newTo: 4)
    check hs[2] == DiffHunk(oldFrom: 5, oldTo: 5, newFrom: 5, newTo: 6)
    check lineDiff(a, a).len == 0
    check splitLinesKeep("x\ny\n") == @["x", "y", ""]
