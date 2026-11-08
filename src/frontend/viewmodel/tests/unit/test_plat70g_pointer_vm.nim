## test_plat70g_pointer_vm.nim — the editor's pointer model, the shared half of
## multi-click selection (Editor-Pane.md MC.1 – MC.7), on the C and JS backends.
##
## No mocks: a real `EditingDocument` over a fixture holding the lines the
## milestone names, driven through `pressEditor` / `dragEditor`. The real
## Monaco code is compared in `tui/tests/test_plat70g_word_oracle.nim`.

import std/[unicode, unittest]

import ../../editing_core
import ../../input/editor_pointer
import ../../keymap/editing_keymap
import ../../sdk/breakpoints
import ../../viewmodels/editor_gutter_lanes
import ../../viewmodels/layout_settings

const Fixture =
  "snake_case_name = other.attr(x)\n" & # 1
  "    indented\n" &                    # 2
  "a == b and p->q\n" &                 # 3
  "a.b\n" &                             # 4
  "\n" &                                # 5
  "price λx 3€ end\n" &                 # 6
  "last line no terminator"             # 7

proc doc(model = bkCua; text = Fixture): EditingDocument =
  initEditingDocument("/f.txt", text, model)

proc off(d: EditingDocument; line, col: int): int =
  ## Byte offset of 1-based `line`, 0-based byte `col`.
  let ls = d.lines
  var o = 0
  for i in 0 ..< line - 1: o += ls[i].len + 1
  o + col

proc press(g: var EditorPointerState; d: var EditingDocument; t: int64; line, col: int;
           mods = pmNone; button = pbLeft; element = peText; cell = false;
           platform = NoPlatformCount; displayColumn = -1): PointerAction =
  let hit = PointerHit(element: element, line: line, offset: d.off(line, col),
                       displayColumn: (if displayColumn >= 0: displayColumn else: col),
                       cellHit: cell)
  result = g.pressEditor(d, PointerPress(timeMs: t, button: button, mods: mods,
                                         hit: hit, documentId: d.path,
                                         platformCount: platform))
  g.releaseEditor()

proc selected(d: EditingDocument): string =
  let r = d.state.selection.mainRange
  d.state.doc[r.rangeFrom ..< r.rangeTo]

suite "ClickCounter (MC.1)":
  proc at(c: var ClickCounter; t: int64; pos = 5; button = 0; element = "e";
          platform = NoPlatformCount; release = true): int =
    result = c.observe(ClickPress(timeMs: t, button: button, element: element,
                                  line: 1, position: pos,
                                  platformCount: platform)).count
    if release: c.noteRelease()

  test "counts on from the previous press, with no cap":
    var c: ClickCounter
    check c.at(0) == 1
    # Four presses 300 ms apart: measured from the first press this would
    # reset on the third.
    check c.at(300) == 2
    check c.at(600) == 3
    check c.at(900) == 4
    check c.at(1200) == 5

  test "the interval resets it, and is the setting":
    var c: ClickCounter
    check c.at(0) == 1
    check c.at(450) == 1
    c.intervalMs = 600
    check c.at(900) == 2

  test "the same-position run limits it":
    var c: ClickCounter
    check c.at(0, pos = 5) == 1
    check c.at(100, pos = 6) == 1
    check c.at(200, pos = 6) == 2

  test "a change of button or element resets it":
    var c: ClickCounter
    check c.at(0) == 1
    check c.at(100, button = 1) == 1
    check c.at(200, button = 1) == 2
    check c.at(300, button = 1, element = "other") == 1

  test "the platform count limits it, and is capped at previous + 1":
    var c: ClickCounter
    # The OS-stricter case: a fast second press the platform calls a first.
    check c.at(0, platform = 1) == 1
    check c.at(100, platform = 1) == 1
    check c.at(200, platform = 5) == 2

  test "a press with no release since is a duplicate, and is not counted":
    var c: ClickCounter
    check c.at(0) == 1
    let first = c.observe(ClickPress(timeMs: 100, element: "e", line: 1,
                                     position: 5, platformCount: NoPlatformCount))
    check first.count == 2
    check not first.duplicate
    let dup = c.observe(ClickPress(timeMs: 110, element: "e", line: 1,
                                   position: 5, platformCount: NoPlatformCount))
    check dup.duplicate
    check dup.count == 2
    c.noteRelease()
    check c.at(150) == 3

suite "the word (MC.3)":
  test "the boundary rule":
    let c = wordClassifier()
    proc w(line: string; at: int): string =
      let s = c.wordAtBoundary(line, at)
      line[s.first ..< s.last]
    check w("snake_case_name = x", 3) == "snake_case_name"
    check w("a.b", 1) == "a"
    check w("a.b", 2) == "b"
    check w("a == b", 3) == "=="
    check w("p->q", 2) == "->"
    check w("    x", 2) == "    "
    check w("", 0) == ""
    check w("λx €y", 1) == "λx"
    check w("3€ end", 1) == "3€"

  test "the cell rule differs only on a single separator":
    let c = wordClassifier()
    proc w(line: string; at: int): string =
      let s = c.wordAtCell(line, at)
      line[s.first ..< s.last]
    check w("a.b", 1) == "."
    check w("a.b", 0) == "a"
    check w("a  b", 1) == "  "
    check w("a == b", 2) == "=="
    check w("abc", 3) == "abc"

  test "the separators are a setting":
    let c = wordClassifier("_")
    let s = c.wordAtBoundary("snake_case-name", 2)
    check "snake_case-name"[s.first ..< s.last] == "snake"
    check c.classOf(Rune(ord('-'))) == wcRegular

suite "counts on the text (MC.2)":
  test "double, triple, quadruple":
    var d = doc()
    var g: EditorPointerState
    check g.press(d, 0, 1, 2).operation == poCaret
    check d.state.selection.mainRange.isEmpty
    check g.press(d, 100, 1, 2).operation == poSelectWord
    check d.selected == "snake_case_name"
    check g.press(d, 200, 1, 2).operation == poSelectLine
    check d.selected == "snake_case_name = other.attr(x)\n"
    check g.press(d, 300, 1, 2).operation == poSelectAll
    check d.selected == Fixture
    discard g.press(d, 400, 1, 2)
    check d.selected == Fixture

  test "the last line selects to the end of the document":
    var d = doc()
    var g: EditorPointerState
    discard g.press(d, 0, 7, 2)
    discard g.press(d, 100, 7, 2)
    discard g.press(d, 200, 7, 2)
    check d.selected == "last line no terminator"

  test "the same presses further apart are single clicks":
    var d = doc()
    var g: EditorPointerState
    for t in [0'i64, 450, 900]:
      check g.press(d, t, 1, 2).count == 1
      check d.state.selection.mainRange.isEmpty

  test "selecting is not refused in a read-only document":
    var d = doc()
    d.setReadOnly(true)
    var g: EditorPointerState
    discard g.press(d, 0, 1, 2)
    discard g.press(d, 100, 1, 2)
    check d.selected == "snake_case_name"

suite "drag after a multi-click (MC.4)":
  test "by word, never below the anchor":
    var d = doc()
    var g: EditorPointerState
    discard g.press(d, 0, 1, 19)  # inside `other`
    discard g.press(d, 100, 1, 19)
    check d.selected == "other"
    g.held = true
    let on = PointerHit(element: peText, line: 1, offset: d.off(1, 26))  # `attr`
    check g.dragEditor(d, on, 150)
    check d.selected == "other.attr"
    let back = PointerHit(element: peText, line: 1, offset: d.off(1, 20))
    check g.dragEditor(d, back, 160)
    check d.selected == "other"
    let before = PointerHit(element: peText, line: 1, offset: d.off(1, 2))
    check g.dragEditor(d, before, 170)
    check d.selected == "snake_case_name = other"

  test "by line, from the numbers, into the text":
    var d = doc()
    var g: EditorPointerState
    discard g.press(d, 0, 3, 0, element = peGutterLineNumber)
    check d.selected == "a == b and p->q\n"
    g.held = true
    let on = PointerHit(element: peText, line: 4, offset: d.off(4, 1))
    check g.dragEditor(d, on, 100)
    check d.selected == "a == b and p->q\na.b\n"
    let up = PointerHit(element: peGutterLineNumber, line: 2, offset: d.off(2, 0))
    check g.dragEditor(d, up, 110)
    check d.selected == "    indented\na == b and p->q\n"

  test "the line drag moves in display rows under wrap":
    let settings = wrapSettings(5)
    var d = initEditingDocument("/w.txt", "one\nabcdefghijklmno\nend\n", bkCua,
                                settings)
    var g: EditorPointerState
    discard g.press(d, 0, 1, 0, element = peGutterLineNumber)
    g.held = true
    # Inside the wrapped line's first row: the head is the next ROW's start.
    let on = PointerHit(element: peText, line: 2, offset: d.off(2, 2))
    check g.dragEditor(d, on, 100)
    check d.selected == "one\nabcde"

  test "above the anchor the head is the pointer's display row":
    var d = initEditingDocument("/w.txt", "abcdefghijklmno\nend\nlast\n", bkCua,
                                wrapSettings(5))
    var g: EditorPointerState
    discard g.press(d, 0, 3, 0, element = peGutterLineNumber)
    g.held = true
    let on = PointerHit(element: peText, line: 1, offset: d.off(1, 7))
    check g.dragEditor(d, on, 100)
    check d.selected == "fghijklmno\nend\nlast\n"

  test "any other selection change ends the anchor":
    var d = doc()
    var g: EditorPointerState
    discard g.press(d, 0, 1, 2)
    discard g.press(d, 100, 1, 2)
    check d.state.pointerAnchorAlive
    d.moveCaretTo(2, 0)
    check not d.state.pointerAnchorAlive

  test "Shift extends by the count's unit, keeping the anchor":
    var d = doc()
    var g: EditorPointerState
    discard g.press(d, 0, 1, 19)
    discard g.press(d, 100, 1, 19)
    discard g.press(d, 600, 1, 26, mods = pmShift)
    check d.selected == "other.at"
    var e = doc()
    var h: EditorPointerState
    discard h.press(e, 0, 1, 19)
    discard h.press(e, 500, 1, 26, mods = pmShift)
    discard h.press(e, 600, 1, 26, mods = pmShift)
    check e.selected == "ther.attr"

  test "column selection clips the short line and skips the one it misses":
    var d = doc(text = "abcdefgh\nab\nabcd\nabcdefgh")
    var g: EditorPointerState
    discard g.press(d, 0, 1, 1)
    discard g.press(d, 500, 4, 5, mods = pmShiftAlt)
    let rs = d.state.selection.ranges
    var cuts: seq[string] = @[]
    for r in rs: cuts.add d.state.doc[r.rangeFrom ..< r.rangeTo]
    check cuts == @["bcde", "b", "bcd", "bcde"]

  test "Alt adds a cursor, also read-only, and a press in a cursor removes it":
    var d = doc()
    d.setReadOnly(true)
    var g: EditorPointerState
    discard g.press(d, 0, 1, 2)
    check g.press(d, 500, 3, 1, mods = pmAlt).operation == poAddCursor
    check d.state.selection.rangeCount == 2
    # Alt+double selects the word at the new cursor, the first one stays.
    discard g.press(d, 600, 3, 1, mods = pmAlt)
    check d.state.selection.rangeCount == 2
    check d.selected == "a"
    discard g.press(d, 1200, 3, 0, mods = pmAlt)
    check d.state.selection.rangeCount == 1

  test "Alt on the numbers adds a whole-line cursor":
    var d = doc()
    var g: EditorPointerState
    discard g.press(d, 0, 1, 2)
    check g.press(d, 500, 4, 0, mods = pmAlt,
                  element = peGutterLineNumber).operation == poAddLineCursor
    check d.state.selection.rangeCount == 2
    check d.selected == "a.b\n"

suite "the debugger's own clicks win (MC.6)":
  test "they select nothing, at every count":
    for (mods, button, want) in [(pmCtrl, pbLeft, pfLineJump),
                                 (pmCtrlAlt, pbLeft, pfCallJump)]:
      var d = doc()
      var g: EditorPointerState
      check g.press(d, 0, 1, 2, mods = mods, button = button).effect == want
      check g.press(d, 100, 1, 2, mods = mods, button = button).effect == want
      check d.state.selection.mainRange.isEmpty

  test "the middle button: single jumps to the line, double into the call":
    var d = doc()
    var g: EditorPointerState
    check g.press(d, 0, 1, 2, button = pbMiddle).effect == pfLineJump
    check g.press(d, 100, 1, 2, button = pbMiddle).effect == pfCallJump
    check d.state.selection.mainRange.isEmpty

  test "the glyph column toggles once per press, uncounted, selecting nothing":
    var d = doc()
    var g: EditorPointerState
    for t in [0'i64, 100, 200, 300]:
      let a = g.press(d, t, 2, 0, element = peGutterGlyph)
      check a.effect == pfToggleBreakpoint
      check a.count == 1
    check d.state.selection.mainRange.isEmpty
    check g.press(d, 500, 2, 0, button = pbRight,
                  element = peGutterGlyph).effect == pfSetBreakpointEnabled
    check g.press(d, 600, 2, 0, mods = pmCtrl,
                  element = peGutterGlyph).effect == pfNone

  test "every press on a number selects the line, and Ctrl changes nothing":
    var d = doc()
    var g: EditorPointerState
    for t in [0'i64, 100, 200, 300, 400]:
      discard g.press(d, t, 3, 0, element = peGutterLineNumber)
      check d.selected == "a == b and p->q\n"
    check g.press(d, 900, 4, 0, mods = pmCtrl,
                  element = peGutterLineNumber).effect == pfSelected
    check d.selected == "a.b\n"
    check g.press(d, 1400, 4, 0, button = pbRight,
                  element = peGutterLineNumber).effect == pfContextMenu
    check g.press(d, 1900, 4, 0, button = pbMiddle,
                  element = peGutterLineNumber).effect == pfNone

  test "a duplicate press does nothing at all":
    var d = doc()
    var g: EditorPointerState
    let hit = PointerHit(element: peGutterGlyph, line: 2, offset: d.off(2, 0))
    let p = PointerPress(timeMs: 0, button: pbLeft, mods: pmNone, hit: hit,
                         documentId: d.path, platformCount: NoPlatformCount)
    check g.pressEditor(d, p).effect == pfToggleBreakpoint
    let again = g.pressEditor(d, p)
    check not again.fresh
    check again.effect == pfNone

suite "the modal bases (MC.7)":
  test "Vim":
    var d = doc(bkVim)
    var g: EditorPointerState
    discard g.press(d, 0, 1, 2)
    check d.state.mode == emNormal
    discard g.press(d, 100, 1, 2)
    check d.state.mode == emVisual
    discard g.press(d, 200, 1, 2)
    check d.state.mode == emVisualLine
    discard g.press(d, 300, 1, 2)
    check d.state.mode == emVisualLine
    discard g.press(d, 900, 2, 2)
    check d.state.mode == emNormal
    discard g.press(d, 1500, 4, 0, element = peGutterLineNumber)
    check d.state.mode == emVisualLine

  test "Vim in INSERT stays in INSERT, with the selection":
    var d = doc(bkVim)
    d.state.mode = emInsert
    var g: EditorPointerState
    discard g.press(d, 0, 1, 2)
    discard g.press(d, 100, 1, 2)
    check d.state.mode == emInsert
    check d.selected == "snake_case_name"

  test "Kakoune leaves the mode alone, Emacs activates the mark":
    var k = doc(bkKakoune)
    var g: EditorPointerState
    discard g.press(k, 0, 1, 2)
    discard g.press(k, 100, 1, 2)
    check k.state.mode == emNormal
    check k.selected == "snake_case_name"
    var e = doc(bkEmacs)
    var h: EditorPointerState
    discard h.press(e, 0, 1, 2)
    discard h.press(e, 100, 1, 2)
    check e.state.mode == emVisual
    discard h.press(e, 800, 1, 2)
    check e.state.mode == emInsert

suite "the gutter's zones (MC.5)":
  test "the glyph lane is first, and every front-end asks one function":
    let bands = resolveBands(14, 110)
    check bands[0].band == gbGlyph
    check bands[0].leftPx == 0
    check bands[0].rightPx == gbGlyph.widthPx(14)
    check bandFor(gcBreakpoint) == gbGlyph
    check bandFor(gcTracepoint) == gbGlyph
    let g = windowGutterGeometry(14, 110)
    check g.gutterZoneAt(0) == gzGlyph
    let edge = gbGlyph.widthPx(14)
    check g.gutterZoneAt(edge - 1) == gzGlyph
    check g.gutterZoneAt(edge) == gzLineNumber # the pointer lane is the numbers'
    var vcsAt = 0
    for b in bands:
      if b.band == gbVcs: vcsAt = b.leftPx
    check g.gutterZoneAt(vcsAt) == gzControl
    check g.gutterZoneAt(110) == gzNone
    check windowGutterGeometry(14, 110, runTestControl = true).gutterZoneAt(edge) ==
      gzControl
    let t = terminalGutterGeometry(9, 1)
    check t.gutterZoneAt(0) == gzGlyph
    check t.gutterZoneAt(1) == gzLineNumber
    check t.gutterZoneAt(8) == gzLineNumber

  test "the hint shows only over the glyph column of an unmarked line":
    var g: EditorPointerState
    check g.hoverEditor(peGutterGlyph, 3, lineHasMark = false)
    check g.hintLine == 3
    check g.hoverEditor(peGutterGlyph, 4, lineHasMark = true)
    check g.hintLine == 0
    discard g.hoverEditor(peGutterGlyph, 3, lineHasMark = false)
    check g.hoverEditor(peText, 3, lineHasMark = false)
    check g.hintLine == 0

suite "inline breakpoints at the caret":
  let held = @[BreakpointSpec(line: 3, enabled: true)]

  test "column 2 and later toggle a column breakpoint in place of the line's":
    let once = inlineBreakpointPlan(held, 3, 5, 20)
    check once.len == 1
    check columnBreakpointAt(once, 3, 5)
    let twice = inlineBreakpointPlan(once, 3, 5, 20)
    check twice.len == 0

  test "column 1 is a line breakpoint":
    check inlineBreakpointPlan(@[], 3, 1, 20) ==
      @[BreakpointSpec(line: 3, enabled: true)]

  test "the column is clamped, and no capability means the line":
    check columnBreakpointAt(inlineBreakpointPlan(@[], 3, 99, 7), 3, 7)
    check inlineBreakpointPlan(@[], 3, 5, 20, columnsSupported = false) ==
      @[BreakpointSpec(line: 3, enabled: true)]

  test "a glyph press removes whatever the line holds, as VS Code's":
    let column = @[BreakpointSpec(line: 3, column: 5, enabled: true)]
    check plannedToggle(column, 3).len == 0
    check plannedToggle(@[], 3) == @[BreakpointSpec(line: 3, enabled: true)]

suite "the settings":
  test ":set multi-click-interval takes milliseconds, in both spellings":
    for line in [":set multi-click-interval=600", ":set multi-click-interval 600"]:
      let s = parseSetLine(line)
      check s.ok
      check s.setting == lsMultiClickInterval
      check s.value == "600"
    check not parseSetLine(":set multi-click-interval=soon").ok
    check not parseSetLine(":set multi-click-interval=0").ok
    var v = defaultLayoutSettings()
    check v.multiClickIntervalMs == 400
    check v.assignValue(lsMultiClickInterval, "600")
    check v.multiClickIntervalMs == 600

  test "word-separators keeps its characters":
    var v = defaultLayoutSettings()
    check v.wordSeparators == UsualWordSeparators
    check v.assignValue(lsWordSeparators, "_-")
    check v.wordSeparators == "_-"
