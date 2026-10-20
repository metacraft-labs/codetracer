## test_plat70a_horizontal_scroll.nim — PLAT-70 Part A (Horizontal-Overflow.md
## §4), the SHARED horizontal view every front-end draws its text panes'
## overflow-only bar from (`viewmodels/horizontal_scroll`) and the editor's
## content width and caret-follow (`editing_core.contentCols` / `followView`),
## swept rather than sampled:
##
##   * HO-1 — the bar exists iff the content is wider than the view; a line one
##     column wider than the view shows it, deleting one character takes it
##     away and the view back to column 0;
##   * HO-3 — a press at track fraction `f` centres column
##     `round(f × (contentCols − 1))`, clamped, over contents from 1 column to
##     a million and views of 1 to 400;
##   * HO-5 — after EVERY caret-moving operation, over random documents,
##     widths and motion sequences, the caret is in view: `leftCol ≤ caretCol <
##     leftCol + viewportCols`; and the margin is 4 columns in from the edge
##     (`min(4, viewportCols div 4)`) except past the line's end;
##   * §4.1 — the editor's content width is EXACT and maintained PER LINE as
##     change sets arrive: after random edits it equals the widest line of the
##     document measured from nothing, line by line;
##   * the output panes' content is the widest line measured SO FAR: it only
##     grows for one output, starts again for another, and never depends on
##     the pane's width;
##   * §4.3's notch (6 columns, a line's worth of pixels) and §4.6's markers;
##   * §4.4's view keys, per base, through the one router: CUA `Left` /
##     `Right`, Emacs `C-x <` / `C-x >`, Vim and Kakoune `z h` / `z l` /
##     `z H` / `z L` / `0` — in the two output panes and nowhere else, and
##     `z` still maximizes every other pane.
##
## No mocks: pure values, the shipped editing core and its vocabulary. Runs
## on the C and the JS backends.

import std/[math, random, strutils, unittest]

import ../../editing_core
import ../../editor/change_set
import ../../keymap/keymap_router

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 152

proc widestFromNothing(text: string): int =
  ## The oracle: every line measured from nothing, with the rule the view
  ## states (`ViewColumnPolicy`: the columns the native front-ends draw — a
  ## tab one column, as the terminal's grid and GPUI's rows draw it; ASCII
  ## one column) — written out here rather than calling the editor's.
  for line in text.split('\n'):
    result = max(result, line.len)

proc caretView(d: EditingDocument): int = d.caretViewColumn

suite "PLAT-70 Part A: the horizontal view, the bar's model":

  test "HO-1: the bar exists iff the content is wider than the view":
    var checked = 0
    for view in [1, 2, 7, 40, 133]:
      for content in [0, view - 1, view, view + 1, view * 3]:
        var v = HorizontalView()
        v.setViewport(view)
        v.setContent(max(0, content))
        ck v.overflows == (content > view)
        inc checked
    ck checked == 25
    # In the editor: a line one column wider than the view, then one
    # character of it deleted — the bar goes, and the view returns to 0.
    let view = 20
    var d = initEditingDocument("a.txt", "short\n" & repeat('x', view + 1) &
                                         "\nend\n")
    var hv: HorizontalView
    var follow: CaretFollow
    d.moveCaretTo(1, view + 1)
    discard d.followView(hv, follow, view)
    ck hv.overflows
    ck hv.leftCol > 0
    discard d.applyNamed("delete-char-backward", OpArgs(), 0)
    discard d.followView(hv, follow, view)
    ck d.contentCols == view
    ck not hv.overflows
    ck hv.leftCol == 0

  test "HO-3: a track press centres round(f * (C - 1)), clamped, swept":
    var cases, ok = 0
    for content in [1, 2, 9, 70, 603, 10_000, 1_000_000]:
      for view in [1, 3, 40, 399]:
        for step in 0 .. 20:
          let f = float(step) / 20.0
          var v = HorizontalView(contentCols: content, viewportCols: view)
          discard v.clickTrack(f)
          inc cases
          let want = if content <= view: 0
                     else: clamp(int(round(f * float(content - 1))) -
                                 view div 2, 0, content - view)
          if v.leftCol == want: inc ok
    ck cases == 7 * 4 * 21
    ck ok == cases
    # A press at the track's last unit shows the content's last column, at
    # the first the first — on tracks of 8 to 600 units.
    for units in [8, 40, 200, 600]:
      var v = HorizontalView(contentCols: 1000, viewportCols: 80)
      discard v.clickTrack(trackFractionAt(units - 1, units))
      ck v.leftCol + v.viewportCols == v.contentCols
      discard v.clickTrack(trackFractionAt(0, units))
      ck v.leftCol == 0

  test "the bar moves the view only, and stays inside the content":
    var v = HorizontalView(contentCols: 300, viewportCols: 50)
    ck v.scrollBy(-10) == false
    ck v.leftCol == 0
    ck v.scrollBy(WheelColumns)
    ck v.leftCol == 6
    ck v.scrollBy(10_000)
    ck v.leftCol == v.maxLeftCol
    ck v.scrollHalf(right = false)
    ck v.leftCol == v.maxLeftCol - 25
    ck v.scrollToLineStart()
    ck v.leftCol == 0
    # The thumb, held, follows; its start at fraction 0.5 is half the
    # content's columns in.
    ck v.dragThumb(0.5)
    ck v.leftCol == 150
    # Wider than the content: nothing to scroll, the view at column 0.
    v.setViewport(400)
    ck not v.overflows
    ck v.leftCol == 0
    ck v.scrollBy(6) == false

  test "HO-5: after every caret move the caret is in view, with the margin":
    var rng = initRand(70_001)
    let ops = ["move-char-right", "move-char-left", "move-line-down",
               "move-line-up", "move-line-end", "move-line-start",
               "move-group-right", "move-group-left", "move-doc-end",
               "move-doc-start"]
    var moves, inView, marginOk, documents = 0
    for doc in 0 ..< 40:
      inc documents
      var text = ""
      for line in 0 ..< rng.rand(1 .. 12):
        let width = rng.rand(0 .. 160)
        for i in 0 ..< width:
          text.add(if rng.rand(9) == 0: ' ' else: char(ord('a') + rng.rand(25)))
        text.add '\n'
      var d = initEditingDocument("p.txt", text)
      var hv: HorizontalView
      var follow: CaretFollow
      let view = rng.rand(4 .. 90)
      discard d.followView(hv, follow, view)
      for step in 0 ..< 60:
        discard d.applyNamed(ops[rng.rand(ops.high)], OpArgs(), 0)
        discard d.followView(hv, follow, view)
        inc moves
        let caret = d.caretView
        if hv.leftCol <= caret and caret < hv.leftCol + view or
           not hv.overflows and caret == view:
          inc inView
        # The margin: a caret that is not at its line's end or start, in a
        # view wider than 8, is never in the outer `min(4, view div 4)`
        # columns of an overflowing view unless the view is at the content's
        # start (or its end, for the right margin).
        let margin = min(4, view div 4)
        let lines = d.lines
        let lineEnd = lines[d.caretLine - 1].len
        let leftOk = caret >= hv.leftCol + margin or hv.leftCol == 0
        let rightOk = caret < hv.leftCol + view - margin or
                      caret + margin > lineEnd or
                      hv.leftCol >= hv.maxLeftCol
        if not hv.overflows or (leftOk and rightOk): inc marginOk
    checkpoint("documents " & $documents & ", caret moves " & $moves)
    ck moves == 40 * 60
    ck inView == moves
    ck marginOk == moves

  test "§4.5: End shows the line's end; the margin is 4 columns in":
    let line = repeat('y', 200)
    var d = initEditingDocument("e.txt", line & "\n")
    var hv: HorizontalView
    var follow: CaretFollow
    discard d.followView(hv, follow, 40)
    discard d.applyNamed("move-line-end", OpArgs(), 0)
    discard d.followView(hv, follow, 40)
    # The caret after the last character, on the view's last column.
    ck d.caretView == 200
    ck hv.leftCol == 200 - 40 + 1
    discard d.applyNamed("move-line-start", OpArgs(), 0)
    discard d.followView(hv, follow, 40)
    ck hv.leftCol == 0
    # Walked right past the edge: 4 columns in from it, never on it.
    for i in 0 ..< 45:
      discard d.applyNamed("move-char-right", OpArgs(), 0)
    discard d.followView(hv, follow, 40)
    ck d.caretView == 45
    ck hv.leftCol == 45 - 40 + 4 + 1
    # A wheel leaves the caret where it is, even off-screen: only the caret
    # moves the view.
    ck hv.scrollBy(WheelColumns * 10)
    let scrolled = hv.leftCol
    discard d.followView(hv, follow, 40)
    ck hv.leftCol == scrolled
    # …and the next caret move brings it back.
    discard d.applyNamed("move-char-left", OpArgs(), 0)
    discard d.followView(hv, follow, 40)
    ck hv.leftCol <= d.caretView and
       d.caretView < hv.leftCol + 40
    # `End` on a line that overflows but is NOT the widest: the margin is
    # not applied past the line's end, so its end lands on the view's last
    # column — not 4 columns in, which the clamp would allow here.
    var two = initEditingDocument("f.txt", repeat('a', 100) & "\n" &
                                           repeat('b', 300) & "\n")
    var hv2: HorizontalView
    var follow2: CaretFollow
    discard two.followView(hv2, follow2, 40)
    discard two.applyNamed("move-line-end", OpArgs(), 0)
    discard two.followView(hv2, follow2, 40)
    ck two.caretView == 100
    ck hv2.leftCol == 100 - 40 + 1

  test "§4.1: the editor's content width is exact, maintained per line":
    var rng = initRand(70_002)
    var exact, edits = 0
    for doc in 0 ..< 12:
      var text = ""
      for line in 0 ..< rng.rand(1 .. 30):
        for i in 0 ..< rng.rand(0 .. 120):
          text.add(case rng.rand(19)
                   of 0: '\t'
                   of 1: ' '
                   else: char(ord('a') + rng.rand(25)))
        text.add '\n'
      var d = initEditingDocument("w.txt", text)
      ck d.contentCols == widestFromNothing(d.text)
      for e in 0 ..< 40:
        let n = d.text.len
        let a = rng.rand(n)
        let b = min(n, a + rng.rand(0 .. 30))
        var ins = ""
        for i in 0 ..< rng.rand(0 .. 50):
          ins.add(case rng.rand(14)
                  of 0: '\n'
                  of 1: '\t'
                  else: char(ord('a') + rng.rand(25)))
        discard d.applyChangeSet(changeSet(n, a, b, ins), 0)
        inc edits
        # Measured per line by `drainJournal`, never re-measured whole here:
        # the per-line table equals a measurement from nothing.
        if d.widths.valid and d.contentCols == widestFromNothing(d.text):
          inc exact
    ck edits == 12 * 40
    ck exact == edits
    # Wide glyphs are two columns; a tab is ONE, as the panes draw it (the
    # editing policy's tab stops, 4, are goal columns, not drawn columns).
    var wide = initEditingDocument("u.txt", "ab\t世界\n")
    ck wide.contentCols == 3 + 2 + 2
    ck wide.settings.policy.tabSize == 4

  test "the output panes: the widest line measured so far":
    var w: ContentWidth
    ck w.measure(1, 30) == 30
    ck w.measure(1, 12) == 30          # only grows for one output
    ck w.measure(1, 90) == 90
    ck w.measure(2, 12) == 12          # another output: from nothing
    # A pane holding a WINDOW of the output: every window it is handed
    # grows the widest, a narrower one never shrinks it, another output
    # starts again.
    var ww: ContentWidth
    let len = proc(s: string): int = s.len
    ck ww.measureWindow(1, ["ab", repeat('x', 40)], len) == 40
    ck ww.measureWindow(1, ["a", "bc"], len) == 40
    ck ww.measureWindow(2, ["abc"], len) == 3
    # Never a function of the pane: the same output measured through views
    # of any width is the same content.
    for view in [10, 80, 400]:
      var v = HorizontalView()
      v.setViewport(view)
      v.setContent(w.widest)
      ck v.contentCols == 12

  test "§4.3 the notch, §4.6 the markers":
    ck WheelColumns == 6
    ck wheelColumnsOf(26.0, 26.0) == 6           # one line: one notch
    ck wheelColumnsOf(-52.0, 26.0) == -12
    ck wheelColumnsOf(13.0, 26.0) == 3
    ck wheelColumnsOf(1.0, 26.0) == 1            # never less than a column
    ck wheelColumnsOf(-1.0, 26.0) == -1
    ck wheelColumnsOf(0.0, 26.0) == 0
    let v = HorizontalView(leftCol: 10, contentCols: 100, viewportCols: 30)
    ck overflowMarkers(100, v) == (precedes: true, extends: true)
    ck overflowMarkers(40, v) == (precedes: true, extends: false)
    ck overflowMarkers(0, v) == (precedes: false, extends: false)
    let atStart = HorizontalView(leftCol: 0, contentCols: 100,
                                 viewportCols: 30)
    ck overflowMarkers(31, atStart) == (precedes: false, extends: true)
    ck overflowMarkers(30, atStart) == (precedes: false, extends: false)

  test "§4.4: the view keys, per base, in the output panes only":
    let delivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                               keyProtocol: kpKitty)
    let facts = SessionFacts(product: pmDebug, replayLoaded: true,
                             editor: EditorFacts(readOnly: true,
                                                 mode: emInsert))
    let window = element(ekWindow, "window")
    let tab = element(ekTab, "tab:1")
    proc pathOf(paneKind: string): ScopePath = @[window, tab, pane(paneKind)]
    proc run(base: BaseKeymap; paneKind: string;
             keys: varargs[string]): string =
      var r = initKeymapRouter(base, delivery)
      var t = 1_000'i64
      var res: EditingResolution
      for k in keys:
        res = r.route(facts, pathOf(paneKind), nmNormal, k, t)
        t += 10
      case res.kind
      of erOperation: res.operation
      of erPending: "pending"
      of erCharacter: "char"
      of erNothing: "nothing"
    for paneKind in ["terminalOutput", "buildOutput"]:
      ck run(bkCua, paneKind, "Left") == "view.scroll-left"
      ck run(bkCua, paneKind, "Right") == "view.scroll-right"
      ck run(bkEmacs, paneKind, "Ctrl+x", "<") == "view.scroll-right-half"
      ck run(bkEmacs, paneKind, "Ctrl+x", ">") == "view.scroll-left-half"
      for base in [bkVim, bkKakoune]:
        ck run(base, paneKind, "z", "h") == "view.scroll-left"
        ck run(base, paneKind, "z", "l") == "view.scroll-right"
        ck run(base, paneKind, "z", "H") == "view.scroll-left-half"
        ck run(base, paneKind, "z", "L") == "view.scroll-right-half"
        ck run(base, paneKind, "0") == "view.scroll-to-line-start"
        ck run(base, paneKind, "z") == "pending"
    # Elsewhere the same keys are not the view's, and `z` maximizes.
    for paneKind in ["calltrace", "eventLog", "state"]:
      ck run(bkCua, paneKind, "Left") != "view.scroll-left"
      ck run(bkCua, paneKind, "Right") != "view.scroll-right"
    ck run(bkEmacs, "calltrace", "Ctrl+x", "<") != "view.scroll-right-half"
    for base in [bkVim, bkKakoune]:
      ck run(base, "calltrace", "z") == "layout.maximize-pane"
      ck run(base, "state", "z") == "layout.maximize-pane"
      ck run(base, "calltrace", "0") != "view.scroll-to-line-start"

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
