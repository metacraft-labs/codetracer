## test_plat70g_differential.nim — MC-D1, MC-D2 and MC-D3 (Editor-Pane.md).
##
## MC-D1: for a fixed document and fixed presses, the shared pointer model the
## terminal (under DECSET 1016) and GPUI run ends on the selection the real Monaco
## ended on. The desktop's answers are `src/tests/visual/answers/
## plat70g-mc.electron.json`, captured from the real app by
## `plat70g-mc-capture.spec.ts`.
##
## MC-D2: one recorded press stream gives one count through the terminal's decoder
## and through GPUI's event path. GPUI's platform count is the one stand-in, and
## why it is not a mock: it is `gpui-pre-linux`'s own rule (400 ms since the
## previous press, 5 px, same button) transcribed, because no display server runs
## in this lane; `test_plat70g_gpui_plan` drives the real shim path.
##
## MC-D3: for every lane of the gutter, sampled at its edges and centre, the zone
## and the press's result are equal across the three front-ends.
##
## And the source gate: no front-end compares press times itself.

import std/[json, os, strutils, unittest]

import ../../viewmodel/editing_core
import ../../viewmodel/input/editor_pointer
import ../../viewmodel/keymap/editing_keymap
import ../../viewmodel/viewmodels/editor_gutter_lanes
import ../app/input/mouse
import ../app/views/gutter

const Answers = "../../../tests/visual/answers/plat70g-mc.electron.json"

let answers = parseJson(readFile(currentSourcePath().parentDir / Answers))
let fixture = answers["fixture"].getStr

proc offsetOf(d: EditingDocument; line, column: int): int =
  ## Monaco's 1-based position, in UTF-16 columns, as a byte offset.
  let ls = d.lines
  var o = 0
  for i in 0 ..< line - 1: o += ls[i].len + 1
  var units = 0
  var at = 0
  let text = ls[line - 1]
  while units < column - 1 and at < text.len:
    let b = ord(text[at])
    at += (if b < 0x80: 1 elif b < 0xE0: 2 elif b < 0xF0: 3 else: 4)
    inc units
  o + at

proc modsOf(word: string): PointerMods =
  case word
  of "shift": pmShift
  of "alt": pmAlt
  of "shift+alt": pmShiftAlt
  else: pmNone

suite "MC-D1":
  test "the shared model ends where Monaco ends, on every press":
    var population = 0
    var wrong = 0
    for a in answers["presses"]:
      let line = a["line"].getInt
      let column = a["column"].getInt
      let count = a["count"].getInt
      var d = initEditingDocument("/f", fixture)
      d.setReadOnly(true)
      var g: EditorPointerState
      for i in 0 ..< count:
        let press = PointerPress(
          timeMs: int64(i) * 50, button: pbLeft, mods: modsOf(a["mods"].getStr),
          hit: PointerHit(element: peText, line: line,
                          offset: d.offsetOf(line, column),
                          displayColumn: column - 1),
          documentId: "/f", platformCount: i + 1)
        discard g.pressEditor(d, press)
        g.releaseEditor()
      var got: seq[string] = @[]
      for r in d.state.selection.ranges:
        got.add d.state.doc[r.rangeFrom ..< r.rangeTo]
      var want: seq[string] = @[]
      for s in a["selections"]: want.add s.getStr
      inc population
      if got != want:
        inc wrong
        if wrong <= 12:
          checkpoint($a["mods"] & " " & $line & ":" & $column & " x" & $count &
                     ": ours " & $got & ", Monaco " & $want)
    echo "  MC-D1: ", population, " presses"
    check population == 15 * 4 * 4
    check wrong == 0

suite "MC-D2":
  test "one press stream, one count, through both decoders":
    # (time, x px, y px, button): a double, a pause, a triple, a move, a double.
    const Stream = [(0, 100, 40, 0), (120, 100, 40, 0), (900, 100, 40, 0),
                    (1100, 100, 40, 0), (1300, 100, 40, 0), (1500, 300, 40, 0),
                    (1600, 300, 40, 0), (1700, 300, 40, 1)]
    var terminal, window: ClickCounter
    var lastTime = -100000
    var lastX, lastButton = -1
    var platform = 0
    var population = 0
    for (t, x, y, button) in Stream:
      let token = "\e[<" & $button & ";" & $(x div 10 + 1) & ";" & $(y div 20 + 1) & "M"
      let (ok, ev) = decodeMouse(token)
      check ok
      let viaTerminal = terminal.observe(ClickPress(
        timeMs: t, button: ord(ev.button), element: "e", line: ev.row,
        position: ev.col, platformCount: NoPlatformCount))
      terminal.noteRelease()
      platform = if t - lastTime <= 400 and abs(x - lastX) <= 5 and
                    button == lastButton: platform + 1 else: 1
      (lastTime, lastX, lastButton) = (t, x, button)
      let viaWindow = window.observe(ClickPress(
        timeMs: t, button: button, element: "e", line: y div 20,
        position: x div 10, platformCount: platform))
      window.noteRelease()
      check viaTerminal.count == viaWindow.count
      inc population
    check population == Stream.len

suite "MC-D3":
  test "every lane's zone and press result, on all three front-ends":
    const Font = 14
    const Total = 110
    var population = 0
    # GPUI's and the desktop's bands, in pixels.
    let g = windowGutterGeometry(Font, Total)
    let e = answers["gutter"]
    check gbGlyph.widthPx(Font) == e["glyphWidth"].getInt
    for b in resolveBands(Font, Total):
      let want = case b.band
        of gbGlyph: gzGlyph
        of gbPointer, gbLineNumber: gzLineNumber
        else: gzControl
      for x in [b.leftPx, (b.leftPx + b.rightPx) div 2, b.rightPx - 1]:
        if b.rightPx > b.leftPx:
          check g.gutterZoneAt(x) == want
          inc population
    # The desktop's bands, by Monaco's own target types.
    # A band's centre and right edge. Monaco classifies its first pixels as the
    # band before (`offset <= width`, and its own rounding): measured, three
    # pixels in is still the previous band, so the left edge is not compared.
    for (name, want) in [("glyph", 2), ("lineNumber", 3), ("decorations", 4)]:
      for i in 1 .. 2:
        check e[name][i].getInt == want
        inc population
    # The terminal's cells.
    let t = terminalGutterGeometry(gutterWidth(2), GutterMarkCells)
    check t.gutterZoneAt(0) == gzGlyph
    for cell in 1 ..< gutterWidth(2):
      check t.gutterZoneAt(cell) == gzLineNumber
      inc population
    inc population
    # The press's result, per zone, is one row table.
    var d = initEditingDocument("/f", fixture)
    var p: EditorPointerState
    let glyph = p.pressEditor(d, PointerPress(
      button: pbLeft, hit: PointerHit(element: peGutterGlyph, line: 1),
      documentId: "/f", platformCount: NoPlatformCount))
    p.releaseEditor()
    check glyph.effect == pfToggleBreakpoint
    check d.state.selection.mainRange.isEmpty
    let number = p.pressEditor(d, PointerPress(
      timeMs: 1000, button: pbLeft,
      hit: PointerHit(element: peGutterLineNumber, line: 1),
      documentId: "/f", platformCount: NoPlatformCount))
    check number.effect == pfSelected
    check not d.state.selection.mainRange.isEmpty
    echo "  MC-D3: ", population, " lane samples"
    check population >= 30

suite "the source gate":
  test "no front-end compares press times itself":
    for dir in ["../app/input", "../app/views"]:
      for f in walkFiles(currentSourcePath().parentDir / dir / "*.nim"):
        check "epochTime" notin readFile(f)
