## test_plat70f_pointer_shapes.nim — the pointer's shape as one function
## (Pointer-Affordances.md §2, §3; PA-1, PA-2), and a click on a hop row as the
## shared rule's (`state_pane_keys.stateRowClick`).
##
## No mocks: pure functions, the shipped tables, and (native only) the shipped
## source tree the PA-1 gate reads.

import std/[sets, strutils, unittest]

import ../../../../common/pointer_shape
import viewmodels/origin_chain_types
import viewmodels/state_pane_keys
from headless_app/pane_clicks import ClickInventory, ClickBehaviour

proc shape(kind: HitKind; disabled = false; truncated = false): PointerShape =
  pointerShapeOf(HitTarget(kind: kind, disabled: disabled, truncated: truncated))

suite "the table at rest (§3.2)":
  test "clickable elements point, and a disabled one refuses":
    for kind in [hkControl, hkTab, hkRow, hkExpander, hkLoadMore, hkGutterGlyph]:
      check shape(kind) == psPointer
      check shape(kind, disabled = true) == psNotAllowed

  test "a truncated cell points; a cell that fits does not":
    check shape(hkCell, truncated = true) == psPointer
    check shape(hkCell) == psDefault

  test "text, dividers, handles and scrollbars":
    check shape(hkEditorText) == psText
    check shape(hkTextInput) == psText
    check shape(hkDividerVertical) == psColResize
    check shape(hkColumnSeparator) == psColResize
    check shape(hkDividerHorizontal) == psRowResize
    check shape(hkDragHandle) == psGrab
    check shape(hkScrubber) == psDefault
    check shape(hkGutterLine) == psDefault
    check shape(hkNone) == psDefault

suite "during a gesture (§3.3)":
  const
    Legal = PointerGesture(kind: pgTabDrag, legalDrop: true)
    Refused = PointerGesture(kind: pgTabDrag, legalDrop: false)

  test "the gesture's shape, whatever is under the pointer":
    for kind in HitKind:
      let target = HitTarget(kind: kind)
      check pointerShapeOf(target, Legal) == psGrabbing
      check pointerShapeOf(target, Refused) == psNotAllowed
      check pointerShapeOf(target, PointerGesture(kind: pgColumnDrag)) == psColResize
      check pointerShapeOf(target, PointerGesture(kind: pgRowDrag)) == psRowResize
      check pointerShapeOf(target, PointerGesture(kind: pgScrubberDrag)) == psDefault
      check pointerShapeOf(target, PointerGesture(kind: pgTextSelection)) == psText
      check pointerShapeOf(target, PointerGesture(kind: pgLineSelection)) == psDefault

suite "each medium's spelling (§2)":
  test "the eight names, closed":
    var names: seq[string]
    for s in PointerShape:
      names.add s.cssName
      check pointerShapeNamed(s.cssName) == (true, s)
    check names == @["default", "pointer", "text", "col-resize", "row-resize",
                     "grab", "grabbing", "not-allowed"]
    check not pointerShapeNamed("hand")[0]

  test "xterm's names":
    check X11PointerNames[psPointer] == "hand2"
    check X11PointerNames[psGrabbing] == "fleur"
    check X11PointerNames[psNotAllowed] == "X_cursor"

  test "the fallback chain stops at what the terminal has (§5.2)":
    check supportedFallback(psGrabbing, {psGrab, psDefault}) == (true, psGrab)
    check supportedFallback(psGrabbing, {psPointer}) == (true, psPointer)
    check supportedFallback(psGrab, {psPointer, psDefault}) == (true, psPointer)
    check supportedFallback(psColResize, {psDefault}) == (true, psDefault)
    check supportedFallback(psNotAllowed, {psPointer, psDefault}) == (true, psDefault)
    check supportedFallback(psPointer, {}) == (false, psDefault)

suite "the differential's population (PA-2)":
  # Every row of the click inventory names an element: its kinds, enabled and
  # disabled, at rest and in each gesture. A new row is a new element and moves
  # this count, which is how a kind the function has never seen gets noticed.
  const
    GestureStates = ord(high(PointerGestureKind)) + 2
      ## Every gesture kind, and a tab drag's two answers.
    DisabledStates = 2

  func kindOfRow(row: ClickBehaviour): HitKind =
    ## The element a row of the inventory is on.
    let target = row.target.toLowerAscii
    if "divider" in target: hkDividerVertical
    elif "gutter" in target: hkGutterGlyph
    elif "editor text" in target: hkEditorText
    elif "omnibox" in target or "field" in target: hkTextInput
    elif "toggle" in target or "expander" in target: hkExpander
    elif "load" in target: hkLoadMore
    elif "tab" in target: hkTab
    elif "row" in target or "file" in target or "folder" in target or
         "node" in target or "hop" in target or "entry" in target: hkRow
    elif "scrub" in target or "scrollbar" in target: hkScrubber
    elif "separator" in target: hkColumnSeparator
    elif "cell" in target: hkCell
    else: hkControl

  test "the count is derived from the inventory":
    var kinds: HashSet[HitKind]
    for row in ClickInventory:
      kinds.incl row.kindOfRow
    # The kinds a press lands on, and the ones only a pointer passes over
    # (a label, a line number, a drag handle) that no row of the inventory is.
    for kind in kinds:
      check kind in {low(HitKind) .. high(HitKind)}
    let population = (ord(high(HitKind)) + 1) * DisabledStates * GestureStates
    check population == 256

  test "every state answers from the closed set":
    var seen: HashSet[PointerShape]
    for kind in HitKind:
      for disabled in [false, true]:
        for gesture in PointerGestureKind:
          for legal in [false, true]:
            seen.incl pointerShapeOf(
              HitTarget(kind: kind, disabled: disabled),
              PointerGesture(kind: gesture, legalDrop: legal))
    # `grab` at rest only, everything else too: every shape is reachable.
    check seen.len == ord(high(PointerShape)) + 1

suite "a click on a hop row (Variable-State-Pane § Value origin)":
  let rows = @[
    StateKeyRow(kind: srkVariable, path: "x", hop: -1, chainOpen: true),
    StateKeyRow(kind: srkHop, path: "x", hop: 0, tick: 90),
    StateKeyRow(kind: srkHop, path: "x", hop: 1, tick: 18),
    StateKeyRow(kind: srkVariable, path: "y", hop: -1)]

  test "seeks to the hop's tick and leaves the cursor on it":
    let effect = stateRowClick(rows, StateCursor(path: "x", hop: 1))
    check effect.kind == skeSeek
    check effect.tick == 18'u64
    check effect.cursor == StateCursor(path: "x", hop: 1)
    check effect.hop == 1

  test "is what Enter does there":
    let at = StateCursor(path: "x", hop: 0)
    check stateRowClick(rows, at) == stateKey(rows, at, "list.activate")

  test "a hop no longer listed does nothing":
    check stateRowClick(rows, StateCursor(path: "x", hop: 7)).kind == skeNone

  test "a chain on its own (the desktop's panel) has one stop per hop":
    var chain = OriginChain()
    var a, b: OriginHop
    a.location.rrTicks = 90'u64
    b.location.rrTicks = 18'u64
    chain.hops = @[a, b]
    let own = chain.chainKeyRows
    check own.len == 2
    let effect = stateRowClick(own, StateCursor(hop: 1))
    check effect.kind == skeSeek
    check effect.tick == 18'u64
    check stateRowClick(own, StateCursor(hop: 2)).kind == skeNone

when not defined(js):
  # -------------------------------------------------------------------------
  # PA-1: one shape function, as a source gate with a planted control
  # -------------------------------------------------------------------------
  import std/os

  const
    Frontend = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    PointerSheet = "components/pointer.styl"

  func hasCursorDeclaration(text: string): bool =
    for line in text.splitLines:
      let t = line.strip
      if t.startsWith("//"):
        continue
      if t.startsWith("cursor:") or t.startsWith("cursor ") or
         t.contains("cursor:"):
        return true

  func namesAShape(text: string): bool =
    ## A front-end module spelling a shape instead of asking the function.
    text.contains("\"cursor\", \"")

  proc stylesheetsSettingCursor(): seq[string] =
    for path in walkDirRec(Frontend / "styles"):
      if path.endsWith(".styl") and not path.endsWith(PointerSheet) and
         hasCursorDeclaration(readFile(path)):
        result.add path

  suite "PA-1: one shape function (source gate)":
    test "the gate sees a planted declaration":
      check hasCursorDeclaration(".a\n  cursor: pointer\n")
      check hasCursorDeclaration(".a\n  cursor pointer\n")
      check not hasCursorDeclaration("// the cursor: a comment\n.a\n  color: red\n")

    test "no stylesheet but the eight rules' says cursor":
      check stylesheetsSettingCursor().len == 0

    test "the eight rules cover the closed set":
      let sheet = readFile(Frontend / "styles" / PointerSheet)
      for s in PointerShape:
        check sheet.contains($s)

    test "the gate sees a front-end naming a shape":
      check namesAShape("r.setStyle(el, \"cursor\", \"pointer\")")

    test "no native front-end module sets a cursor by name":
      for dir in ["gpui", "tui/app", "tui/host"]:
        for path in walkDirRec(Frontend / dir):
          if not path.endsWith(".nim") or "/tests/" in path:
            continue
          check not namesAShape(readFile(path))
