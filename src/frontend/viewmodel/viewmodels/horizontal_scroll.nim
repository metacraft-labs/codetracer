## viewmodels/horizontal_scroll.nim — a text pane's HORIZONTAL VIEW: how far
## right it is scrolled, whether its overflow-only bar exists, what the bar's
## gestures and the keys do to it, and the editor's caret-follow.
##
## Spec: `codetracer-specs/spec/GUI/Layout-And-Navigation/Horizontal-Overflow.md`
## §4. The panes: the editor (Debug and Edit mode), the Terminal Output pane's
## line view and Build Output.
##
## **The bar is the vertical scrubber's model on the column axis (§4.2)** —
## `barModel` is `scrollbar_scrubber.scrubberModel(contentCols, leftCol,
## viewportCols)`, so a track click centres the clicked column and a thumb drag
## follows, exactly as every list scrubber does. There is no second thumb
## arithmetic: every front-end projects `barModel`'s fractions onto its track
## (eighth blocks, pixels) and hands a pointer back as a fraction
## (`clickTrack`, `dragThumb`).
##
## Everything a front-end does to a pane's horizontal view goes through this
## module — the wheel (`scrollBy` with `WheelColumns`), the view keys
## (`scrollHalf`, `scrollToLineStart`), the bar, a resize (`setViewport`), new
## content (`setContent`) and the editor's caret (`followCaret`). A front-end
## holds one `HorizontalView` per pane and draws from `leftCol`.
##
## Pure; C and JavaScript backends.

import ./scrollbar_scrubber

export scrollbar_scrubber

const
  WheelColumns* = 6
    ## §4.3: one horizontal wheel notch is 6 columns — Vim's `'mousescroll'`
    ## default (`hor:6`). The terminal's notch is a report; GPUI and the
    ## desktop turn a pixel delta into notches of one column's width each.
  CaretFollowMargin* = 4
    ## §4.5: the caret is kept this many columns inside the view (at most a
    ## quarter of it).

type
  HorizontalView* = object
    ## One text pane's horizontal state, in DISPLAY COLUMNS (tabs expanded,
    ## wide glyphs two).
    leftCol*: int
      ## The first column shown.
    contentCols*: int
      ## How wide the content is: the editor's widest line (exact), an output
      ## pane's widest line measured so far (`ContentWidth`).
    viewportCols*: int
      ## How many columns the pane shows.

  CaretFollow* = object
    ## §4.5's "only the caret moves the view": the caret position the view
    ## last followed. The view follows again only when the caret is somewhere
    ## else, so a wheel or a bar scroll leaves an unmoved caret off-screen.
    line*, column*: int
    armed*: bool
      ## A caret has been followed at least once.

  ContentWidth* = object
    ## §4.1's "widest line measured so far" for a pane that holds a WINDOW
    ## of its output: it only grows while the output is the same output, and
    ## is reset when the output is replaced.
    widest*: int
    generation*: int
      ## The output it measured (whatever the pane's model calls its
      ## identity: a build's session, the loaded output's ViewModel).
    measured*: int
      ## How many of that output's lines `measureLines` has measured.

func overflows*(v: HorizontalView): bool =
  ## HO-1: the bar exists iff the content is wider than the view.
  v.viewportCols > 0 and v.contentCols > v.viewportCols

func maxLeftCol*(v: HorizontalView): int =
  max(0, v.contentCols - v.viewportCols)

func barModel*(v: HorizontalView; mark = -1): ScrubberModel =
  ## §4.2: the bar IS the scrubber model, columns for rows. `mark` is the
  ## editor's caret column (its track mark), -1 for the output panes.
  scrubberModel(v.contentCols, v.leftCol, v.viewportCols, current = mark)

proc settle(v: var HorizontalView) =
  ## The bar disappears → the view returns to column 0; otherwise the view
  ## stays inside the content — and the one cell past it, which only the
  ## caret's follow puts it on (the caret after the widest line's last
  ## character, `followedLeftCol`).
  if not v.overflows:
    v.leftCol = 0
  else:
    v.leftCol = clamp(v.leftCol, 0, v.maxLeftCol + 1)

proc setViewport*(v: var HorizontalView; cols: int) =
  ## The pane was laid out `cols` columns wide. The view does not move when
  ## the bar appears (§4.1), and returns to 0 when it disappears.
  v.viewportCols = max(0, cols)
  v.settle()

proc setContent*(v: var HorizontalView; cols: int) =
  ## The content is now `cols` wide (an edit, a wider line loaded).
  v.contentCols = max(0, cols)
  v.settle()

proc scrollTo(v: var HorizontalView; left: int): bool =
  let before = v.leftCol
  v.leftCol = if v.overflows: clamp(left, 0, v.maxLeftCol) else: 0
  v.leftCol != before

proc scrollBy*(v: var HorizontalView; cols: int): bool =
  ## Move the view `cols` columns right (negative: left) — the wheel
  ## (`WheelColumns` a notch) and `view.scroll-left` / `-right`. Answers
  ## whether it moved.
  v.scrollTo(v.leftCol + cols)

proc scrollHalf*(v: var HorizontalView; right: bool): bool =
  ## `view.scroll-left-half` / `view.scroll-right-half`: half the view.
  let half = max(1, v.viewportCols div 2)
  v.scrollBy(if right: half else: -half)

proc scrollToLineStart*(v: var HorizontalView): bool =
  ## `view.scroll-to-line-start`: back to column 0.
  v.scrollTo(0)

proc clickTrack*(v: var HorizontalView; fraction: float): bool =
  ## §4.2 / HO-3: a press on the track at `fraction` centres the column
  ## `round(fraction * (contentCols - 1))`, clamped at the ends. The view
  ## only (HO-4): nothing here can reach a caret.
  if not v.overflows: return false
  v.scrollTo(v.barModel.clickAt(fraction))

proc dragThumb*(v: var HorizontalView; thumbStartFraction: float): bool =
  ## §4.2: the thumb, held, follows the pointer continuously.
  if not v.overflows: return false
  v.scrollTo(v.barModel.dragTo(thumbStartFraction))

func followedLeftCol*(leftCol, caretCol, lineEndCol, viewportCols,
                      maxLeftCol: int): int =
  ## §4.5: the least move that brings `caretCol` back into a view of
  ## `viewportCols` starting at `leftCol`, with the margin
  ## `min(4, viewportCols div 4)`.
  ##
  ## The margin is not applied past the line's end (`lineEndCol`, the
  ## column after its last character): on the right the view needs to show
  ## no more than the line has, so `End` brings the end into view and leaves
  ## the caret on the view's last column, not four columns of blank later.
  ## At column 0 the left margin reaches 0 by itself. The clamp's upper end
  ## admits the caret's own cell after the WIDEST line's last character —
  ## that cell is not content (HO-1 counts characters) and the caret must
  ## still be seen there (HO-5).
  if viewportCols <= 0:
    return 0
  let margin = min(CaretFollowMargin, viewportCols div 4)
  result = leftCol
  if caretCol < result + margin:
    result = max(0, caretCol - margin)
  let rightMargin = max(0, min(margin, lineEndCol - caretCol))
  if caretCol >= result + viewportCols - rightMargin:
    result = caretCol - viewportCols + rightMargin + 1
  result = clamp(result, 0, max(maxLeftCol, caretCol - viewportCols + 1))

proc followCaret*(v: var HorizontalView; f: var CaretFollow;
                  line, caretCol, lineEndCol: int): bool =
  ## §4.5: when the caret is somewhere it was not when the view last
  ## followed it, move the view the least distance that shows it with the
  ## margin. EVERY caret move reaches here — typing, motions, a find match, a
  ## click, a go-to-line, the execution pointer — because the front-end calls
  ## it with the caret as it is before each frame, whatever moved it. A
  ## scroll that left the caret where it was changes nothing (`f` still
  ## names that caret). Answers whether the view moved.
  if f.armed and f.line == line and f.column == caretCol:
    return false
  f = CaretFollow(line: line, column: caretCol, armed: true)
  if not v.overflows:
    return v.scrollTo(0)
  let before = v.leftCol
  v.leftCol = followedLeftCol(v.leftCol, caretCol, lineEndCol,
                              v.viewportCols, v.maxLeftCol)
  v.leftCol != before

proc measure*(w: var ContentWidth; generation, cols: int): int =
  ## §4.1: the widest line measured so far of output `generation`: a
  ## different generation starts again from `cols`; the same one only grows.
  ## Never a function of the pane's width.
  if generation != w.generation:
    w = ContentWidth(widest: 0, generation: generation)
  w.widest = max(w.widest, cols)
  w.widest

proc measureLines*[T](w: var ContentWidth; generation: int;
                      lines: openArray[T]; widthOf: proc(line: T): int): int =
  ## §4.1 over an output's lines as a pane holds them: only the lines not
  ## measured yet are measured (`measure`). An output with fewer lines than
  ## were measured was replaced in place, and is measured from nothing, as
  ## another `generation` is. Answers the widest so far.
  if generation != w.generation or lines.len < w.measured:
    w = ContentWidth(widest: 0, generation: generation)
  for i in w.measured ..< lines.len:
    discard w.measure(generation, widthOf(lines[i]))
  w.measured = lines.len
  w.widest

proc measureWindow*[T](w: var ContentWidth; generation: int;
                       lines: openArray[T]; widthOf: proc(line: T): int): int =
  ## §4.1 for a pane that holds a WINDOW of its output (only the lines it
  ## shows): every held line is measured, and the widest only grows over the
  ## windows delivered while the output is the same `generation` — "the
  ## widest line measured so far". Answers it.
  discard w.measure(generation, 0)
  for line in lines:
    discard w.measure(generation, widthOf(line))
  w.widest

func wheelColumnsOf*(deltaPx, linePx: float): int =
  ## §4.3: a pixel wheel delta (GPUI, the desktop) in columns — a line's
  ## worth of pixels is one notch, `WheelColumns` columns ("the column
  ## equivalent of a line") — rounded, and never less than one column in the
  ## delta's direction. The sign is the delta's.
  if deltaPx == 0.0 or linePx <= 0.0: return 0
  let cols = deltaPx / linePx * float(WheelColumns)
  let n = int(cols + (if cols > 0: 0.5 else: -0.5))
  if n != 0: n elif deltaPx > 0: 1 else: -1

func overflowMarkers*(rowWidth: int; v: HorizontalView):
    tuple[precedes, extends: bool] =
  ## §4.6: a row whose text continues left of the view shows `‹` in its first
  ## text column; one whose text continues right of the view shows `›` in its
  ## last — Vim's `listchars` `precedes:` / `extends:`, per row. `rowWidth`
  ## is the row's display width (its text starts at column 0).
  (precedes: v.leftCol > 0 and rowWidth > 0,
   extends: rowWidth > v.leftCol + v.viewportCols)
