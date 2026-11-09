## input/editor_pointer.nim — what a press and a drag do in the editor, as
## data, for the terminal and GPUI (Editor-Pane.md § Mouse Gestures, MC.1–MC.7).
##
## The rows are `scope × modifiers × gesture × element kind → operation`
## (Input-Routing §5.1) and are the same under every base; a base differs only
## in the mode a selection leaves it in (`pointerModeRows`, MC.7). A front-end
## hit-tests the press to a `PointerHit`, calls `pressEditor` and performs the
## `PointerEffect` that comes back: everything that is a selection has already
## happened on the document, and everything that belongs to the debugger is
## handed back, because its engine lives in the front-end's session.
##
## The desktop's text surface is Monaco's, which runs this same table's source
## (`dispatchMouse`); its parity with this module is measured by MC-D1.

import ../editing_core
import ../keymap/editing_keymap
import ./click_counter

export click_counter

type
  PointerElement* = enum
    peText = "text"
    peGutterGlyph = "gutter-glyph"
    peGutterLineNumber = "gutter-line-number"

  PointerButton* = enum
    pbLeft = "left"
    pbMiddle = "middle"
    pbRight = "right"

  PointerMods* = enum
    pmNone = "none"
    pmShift = "shift"
    pmAlt = "alt"
    pmShiftAlt = "shift+alt"
    pmCtrl = "ctrl"
    pmCtrlAlt = "ctrl+alt"

  PointerEffect* = enum
    ## What the front-end still has to do. The pure selection cases are
    ## `pfSelected`.
    pfNone
    pfSelected
    pfToggleBreakpoint
    pfSetBreakpointEnabled
    pfLineJump
    pfCallJump
    pfContextMenu

  PointerOperation* = enum
    poNone = ""
    poCaret = "editor.move-caret-to"
    poExtend = "editor.extend-by-unit-to"
    poSelectWord = "editor.select-word-at"
    poSelectLine = "editor.select-line-at"
    poSelectAll = "editor.select-all"
    poAddCursor = "editor.add-cursor-at-point"
    poAddLineCursor = "editor.add-cursor-at-point(line)"
    poColumnSelect = "editor.column-select-to"
    poToggleBreakpoint = "editor.toggle-breakpoint"
    poSetEnabled = "editor.set-breakpoint-enabled"
    poLineJump = "debugger.jump-to-line"
    poCallJump = "debugger.jump-to-call"
    poContextMenu = "context-menu.open"

  PointerRow* = object
    element*: PointerElement
    mods*: PointerMods
    button*: PointerButton
    minCount*, maxCount*: int
    operation*: PointerOperation

  PointerHit* = object
    element*: PointerElement
    line*: int
      ## 1-based.
    offset*: int
      ## The byte offset of the caret boundary the press resolved to.
    displayColumn*: int
      ## 0-based, past the end of the line where the pointer is.
    cellHit*: bool
      ## The press named a cell (MC.3), the terminal without DECSET 1016.

  PointerPress* = object
    timeMs*: int64
    button*: PointerButton
    mods*: PointerMods
    hit*: PointerHit
    documentId*: string
    platformCount*: int

  PointerAction* = object
    effect*: PointerEffect
    count*: int
    operation*: PointerOperation
    ## False for a press the counter dropped as a duplicate.
    fresh*: bool

  EditorPointerState* = object
    ## The gesture state one editor pane keeps between pointer reports.
    counter*: ClickCounter
    held*: bool
      ## A press that selects is down, so motion extends.
    extendsKeepOthers: bool
    columnDrag: bool
    hintLine*: int
      ## The glyph column's hover hint (gesture 7a), 0 for none. It is a state
      ## of the view, drawn only where the line has no mark.

const
  AnyCount = high(int)
  EditorPointerRows*: array[31, PointerRow] = [
    # MC.2: the text, unmodified.
    PointerRow(element: peText, mods: pmNone, button: pbLeft, minCount: 1,
               maxCount: 1, operation: poCaret),
    PointerRow(element: peText, mods: pmNone, button: pbLeft, minCount: 2,
               maxCount: 2, operation: poSelectWord),
    PointerRow(element: peText, mods: pmNone, button: pbLeft, minCount: 3,
               maxCount: 3, operation: poSelectLine),
    PointerRow(element: peText, mods: pmNone, button: pbLeft, minCount: 4,
               maxCount: AnyCount, operation: poSelectAll),
    # MC.4: Shift extends by the count's unit.
    PointerRow(element: peText, mods: pmShift, button: pbLeft, minCount: 1,
               maxCount: 3, operation: poExtend),
    PointerRow(element: peText, mods: pmShift, button: pbLeft, minCount: 4,
               maxCount: AnyCount, operation: poSelectAll),
    # MC.4: Alt adds a cursor, in every editor (OQ-G1).
    PointerRow(element: peText, mods: pmAlt, button: pbLeft, minCount: 1,
               maxCount: 1, operation: poAddCursor),
    PointerRow(element: peText, mods: pmAlt, button: pbLeft, minCount: 2,
               maxCount: 2, operation: poSelectWord),
    PointerRow(element: peText, mods: pmAlt, button: pbLeft, minCount: 3,
               maxCount: 3, operation: poSelectLine),
    PointerRow(element: peText, mods: pmAlt, button: pbLeft, minCount: 4,
               maxCount: AnyCount, operation: poSelectAll),
    PointerRow(element: peText, mods: pmShiftAlt, button: pbLeft, minCount: 1,
               maxCount: 1, operation: poColumnSelect),
    PointerRow(element: peText, mods: pmShiftAlt, button: pbLeft, minCount: 2,
               maxCount: 2, operation: poExtend),
    PointerRow(element: peText, mods: pmShiftAlt, button: pbLeft, minCount: 3,
               maxCount: 3, operation: poExtend),
    PointerRow(element: peText, mods: pmShiftAlt, button: pbLeft, minCount: 4,
               maxCount: AnyCount, operation: poSelectAll),
    # MC.6: the debugger's own clicks win, at every count, and select nothing.
    PointerRow(element: peText, mods: pmCtrl, button: pbLeft, minCount: 1,
               maxCount: AnyCount, operation: poLineJump),
    PointerRow(element: peText, mods: pmCtrlAlt, button: pbLeft, minCount: 1,
               maxCount: AnyCount, operation: poCallJump),
    PointerRow(element: peText, mods: pmNone, button: pbMiddle, minCount: 1,
               maxCount: 1, operation: poLineJump),
    PointerRow(element: peText, mods: pmNone, button: pbMiddle, minCount: 2,
               maxCount: AnyCount, operation: poCallJump),
    PointerRow(element: peText, mods: pmNone, button: pbRight, minCount: 1,
               maxCount: AnyCount, operation: poContextMenu),
    # Shift + right-click is the same menu: a GPUI window has no native menu
    # to fall back to (Native-Front-End-Parity.md, "GPUI has NO escape hatch").
    # The browser and terminal stand down on Shift before a press reaches here.
    PointerRow(element: peText, mods: pmShift, button: pbRight, minCount: 1,
               maxCount: AnyCount, operation: poContextMenu),
    # MC.5, gestures 7 and 8: the glyph column. Its presses are not counted.
    # Alt is VS Code's `onMouseDown` in `breakpointEditorContribution`: on a
    # breakpoint it toggles the enabled state instead of removing it.
    PointerRow(element: peGutterGlyph, mods: pmNone, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poToggleBreakpoint),
    PointerRow(element: peGutterGlyph, mods: pmShift, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poToggleBreakpoint),
    PointerRow(element: peGutterGlyph, mods: pmAlt, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poSetEnabled),
    PointerRow(element: peGutterGlyph, mods: pmNone, button: pbRight,
               minCount: 1, maxCount: AnyCount, operation: poSetEnabled),
    # MC.5, gestures 9-12: the line numbers. Monaco tests
    # `startedOnLineNumbers` before the count, so every press selects the line.
    PointerRow(element: peGutterLineNumber, mods: pmNone, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poSelectLine),
    PointerRow(element: peGutterLineNumber, mods: pmCtrl, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poSelectLine),
    PointerRow(element: peGutterLineNumber, mods: pmShift, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poExtend),
    PointerRow(element: peGutterLineNumber, mods: pmAlt, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poAddLineCursor),
    PointerRow(element: peGutterLineNumber, mods: pmShiftAlt, button: pbLeft,
               minCount: 1, maxCount: AnyCount, operation: poSelectLine),
    PointerRow(element: peGutterLineNumber, mods: pmNone, button: pbRight,
               minCount: 1, maxCount: AnyCount, operation: poContextMenu),
    PointerRow(element: peGutterLineNumber, mods: pmShift, button: pbRight,
               minCount: 1, maxCount: AnyCount, operation: poContextMenu),
  ]

func pointerOperation*(element: PointerElement; mods: PointerMods;
                       button: PointerButton; count: int): PointerOperation =
  ## The row for this press. No row is `poNone`: an unassigned gesture does
  ## nothing at all (§ Mouse Gestures).
  for row in EditorPointerRows:
    if row.element == element and row.mods == mods and row.button == button and
       count >= row.minCount and count <= row.maxCount:
      return row.operation
  poNone

func pointerModsOf*(ctrl, alt, shift: bool): PointerMods =
  if ctrl: (if alt: pmCtrlAlt else: pmCtrl)
  elif alt: (if shift: pmShiftAlt else: pmAlt)
  elif shift: pmShift
  else: pmNone

func pointerModeAfter*(base: BaseKeymap; mode: EditingMode; unit: PointerUnit;
                       empty: bool): EditingMode =
  ## MC.7's table: the mode a pointer selection leaves the document in. The
  ## selecting operations do not know about modes and the views have no `case`
  ## over the base; this is the one place the base decides.
  case base
  of bkVim:
    if mode == emInsert:
      emInsert
    elif empty:
      if mode in {emVisual, emVisualLine, emVisualBlock}: emNormal else: mode
    elif unit in {puLine, puDocument}:
      emVisualLine
    else:
      emVisual
  of bkEmacs:
    # An active mark is `visual` (Editing-Operations §2.2 D, "Mark and kill
    # ring").
    if empty: emInsert else: emVisual
  of bkCua, bkKakoune:
    mode

proc applyPointerMode(d: var EditingDocument) =
  let st = d.state
  let unit = if st.pointerAnchor.unit == puNone: puCharacter
             else: st.pointerAnchor.unit
  var empty = true
  for r in st.selection.ranges:
    if not r.isEmpty:
      empty = false
  d.state.mode = pointerModeAfter(d.model, st.mode, unit, empty)

proc runPointerOp(d: var EditingDocument; name: string; args: OpArgs;
                  nowMs: int64) =
  discard d.applyNamed(name, args, nowMs)

proc pressEditor*(g: var EditorPointerState; d: var EditingDocument;
                  p: PointerPress): PointerAction =
  ## One press, counted and dispatched.
  let observed = g.counter.observe(ClickPress(
    timeMs: p.timeMs, button: ord(p.button),
    element: p.documentId & "/" & $p.hit.element, line: p.hit.line,
    position: p.hit.offset, platformCount: p.platformCount))
  if observed.duplicate:
    return PointerAction(effect: pfNone, count: observed.count, fresh: false)
  # MC.5: glyph presses are not counted, so each press is the row's only count.
  let count = if p.hit.element == peGutterGlyph: 1 else: observed.count
  let op = pointerOperation(p.hit.element, p.mods, p.button, count)
  result = PointerAction(count: count, operation: op, fresh: true)
  let keep = p.mods in {pmAlt, pmShiftAlt}
  var args = OpArgs(number: p.hit.offset)
  args.pointer = PointerArgs(cellHit: p.hit.cellHit, keepOthers: keep,
                             displayColumn: p.hit.displayColumn)
  g.held = false
  g.columnDrag = false
  g.extendsKeepOthers = keep
  case op
  of poNone:
    result.effect = pfNone
  of poCaret:
    d.state.selection = caretSelection(p.hit.offset)
    d.state.pointerAnchor = PointerAnchor(
      unit: puCharacter, first: p.hit.offset, last: p.hit.offset,
      selection: d.state.selection)
    g.held = true
    result.effect = pfSelected
    d.applyPointerMode()
  of poExtend:
    # A Shift+press grows by the count's unit, and on the line numbers always
    # by lines, from the anchor the selection already has (`_moveToSelect`,
    # `_wordSelectDrag`, `_lineSelectDrag`).
    args.pointer.unit =
      if p.hit.element == peGutterLineNumber or count == 3: puLine
      elif count == 2: puWord
      else: puCharacter
    d.runPointerOp("extend-by-unit-to", args, p.timeMs)
    g.held = true
    result.effect = pfSelected
    d.applyPointerMode()
  of poSelectWord:
    d.runPointerOp("select-word-at", args, p.timeMs)
    g.held = true
    result.effect = pfSelected
    d.applyPointerMode()
  of poSelectLine:
    d.runPointerOp("select-line-at", args, p.timeMs)
    g.held = true
    result.effect = pfSelected
    d.applyPointerMode()
  of poSelectAll:
    d.runPointerOp("select-all", args, p.timeMs)
    g.held = true
    result.effect = pfSelected
    d.applyPointerMode()
  of poAddCursor:
    d.runPointerOp("add-cursor-at-point", args, p.timeMs)
    g.held = true
    result.effect = pfSelected
  of poAddLineCursor:
    args.pointer.wholeLine = true
    d.runPointerOp("add-cursor-at-point", args, p.timeMs)
    g.held = true
    result.effect = pfSelected
  of poColumnSelect:
    d.runPointerOp("column-select-to", args, p.timeMs)
    g.held = true
    g.columnDrag = true
    result.effect = pfSelected
  of poToggleBreakpoint: result.effect = pfToggleBreakpoint
  of poSetEnabled: result.effect = pfSetBreakpointEnabled
  of poLineJump: result.effect = pfLineJump
  of poCallJump: result.effect = pfCallJump
  of poContextMenu:
    # K47: a right press places the caret before its menu opens, unless it
    # lands inside the selection the menu's Copy is about.
    var inside = false
    for r in d.state.selection.ranges:
      if not r.isEmpty and r.rangeFrom <= p.hit.offset and
         p.hit.offset <= r.rangeTo:
        inside = true
    if not inside:
      d.state.selection = caretSelection(p.hit.offset)
    result.effect = pfContextMenu

proc dragEditor*(g: var EditorPointerState; d: var EditingDocument; hit: PointerHit;
                 nowMs: int64): bool =
  ## Motion with the press held. A drag from the numbers continues by lines
  ## into the text, because the unit is the anchor's and not the element's.
  ## Answers whether the press owns the pointer.
  if not g.held:
    return false
  var args = OpArgs(number: hit.offset)
  args.pointer = PointerArgs(keepOthers: g.extendsKeepOthers,
                             displayColumn: hit.displayColumn)
  if g.columnDrag:
    d.runPointerOp("column-select-to", args, nowMs)
  else:
    d.runPointerOp("extend-by-unit-to", args, nowMs)
  d.applyPointerMode()
  true

proc releaseEditor*(g: var EditorPointerState) =
  g.held = false
  g.counter.noteRelease()

proc hoverEditor*(g: var EditorPointerState; element: PointerElement; line: int;
                  lineHasMark: bool): bool =
  ## Motion with no press: the glyph column's hint on an unmarked line.
  ## Answers whether the hint changed.
  let next = if element == peGutterGlyph and not lineHasMark and line > 0: line
             else: 0
  result = next != g.hintLine
  g.hintLine = next
