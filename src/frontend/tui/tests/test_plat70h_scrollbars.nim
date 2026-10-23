## test_plat70h_scrollbars.nim — PLAT-70 Part H (Scrollbar-Scrubbers.md §7),
## the terminal's scrollbars:
##
##   * THE PAINTER, swept: every glyph tier × thickness × pointer state ×
##     track setting, on both axes — the glyphs are the table's (§7.2), the
##     thumb covers the cells the model says (widened only under the pointer
##     and while held), the roles are §7.3's, the track is drawn exactly when
##     the option or the state asks for it, and no cell of a bar carries a
##     background of its own (SB-2). Spot checks name the spec's glyphs one
##     by one, so a swapped column is caught by name;
##   * THE TIERS: the ASCII thumb is `#` and the track `|` / `-`; a faded
##     cell is blended toward its ground at 24 bits and hidden from 1/2 on
##     the sixteen colours;
##   * SB-1, a source gate with its planted violation: no view but the style
##     module paints in a scrollbar role or spells the eighth-block tables;
##   * THE RUNTIME, on a real recording (`calc`, the python recorder, the real
##     replay-server): the editor's bar — hover on the thumb widens it, hover
##     on the track reveals the track, a grab by the thumb's last cell keeps
##     its offset (SB-3), a left press jumps and then drags and a middle
##     press pages, and held, repeats until the thumb reaches the pointer
##     (SB-4); the fade goes out and back in through intermediate frames
##     (SB-6); `:set scrollbar-thickness thick` re-draws every bar and is
##     remembered (SB-7); every pane with a bar answers hover and a paging
##     press with its own view only (SB-8).
##
## No mocks: the painters, the runtime, the session and the engine are the
## shipped ones; the remembered preference is the runtime's `savePreference`
## hook capturing what the host would write — the one stand-in, and not a
## mock: it is the seam `main.nim` fills with `saveLayoutPreference`, whose
## file format `test_plat70h_scrollbar_model` round-trips.

import std/[os, strutils, unicode, unittest]

import codetracer_embed
import headless_app/layout_model

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/degradation
import ../app/theme/roles
import ../app/views/borders
import ../app/views/shell
import ../app/views/styled_row
import ../app/views/scrubber_track
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 556

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 48
  BarCells = 12

proc paintOne(o: ScrollbarOptions; axis: BarAxis; state: BarState;
              m: ScrubberModel; faded = 0'f32): StyledGrid =
  ## One bar of `BarCells` cells in a pane of the editor's ground, painted as
  ## the shell would (the options and the pointer on the grid).
  result = newStyledGrid(20, 20)
  result.fillSurface(0, 0, 20, 20, srSurfaceEditor)
  result.painting = paneEditor
  result.scrollbars = ScrollbarFrame(
    options: o,
    pointer: BarPointer(active: state != bsIdle, pane: paneEditor,
                        axis: axis, state: state))
  result.scrollbars.faded[paneEditor] = faded
  if axis == axVertical: result.paintBar(axis, 5, 2, BarCells, m)
  else: result.paintBar(axis, 5, 2, BarCells, m)

proc cellAt(g: StyledGrid; axis: BarAxis; i: int): (string, CellStyle) =
  if axis == axVertical: (g.runeAt(2 + i, 5), g.styleAt(2 + i, 5))
  else: (g.runeAt(5, 2 + i), g.styleAt(5, 2 + i))

suite "PLAT-70 Part H: the painter, every column of the table":

  test "glyphs, thumb cells, roles, the track and the ground, swept":
    let m = scrubberModel(100, 30, 20)
    let span = m.spanOf(BarCells)
    var cases = 0
    for tier in [false, true]:
      for t in BarThickness:
        for track in [false, true]:
          for state in BarState:
            for axis in BarAxis:
              inc cases
              let o = ScrollbarOptions(thickness: t, track: track,
                                       modernUnicode: tier, fade: true)
              let g = paintOne(o, axis, state, m)
              let look = o.lookOf(axis, state)
              let showTrack = track or state.trackRevealed
              var bad: seq[string] = @[]
              for i in 0 ..< BarCells:
                let (glyph, style) = g.cellAt(axis, i)
                let mask = segmentMask(span, i, look.thumb.segments)
                # SB-2: the pane's ground, nothing of the bar's own.
                if style.bg.len > 0 or style.surface != srSurfaceEditor:
                  bad.add "ground " & $i
                if mask != 0:
                  let want = if showTrack and look.thumb.joined.len > 0:
                               look.thumb.joined[mask]
                             else: look.thumb.byMask[mask]
                  if glyph != want or style.role != o.thumbRole(state):
                    bad.add "thumb " & $i & " '" & glyph & "'"
                elif showTrack:
                  if glyph != look.track or style.role != trackRole(state):
                    bad.add "track " & $i & " '" & glyph & "'"
                elif glyph != " " or style.role != srNone:
                  bad.add "blank " & $i & " '" & glyph & "'"
              if bad.len > 0:
                checkpoint($tier & " " & $t & " track=" & $track & " " &
                           $state & " " & $axis & ": " & bad.join(", "))
              ck bad.len == 0
              # The bar is recorded, with its pane and model.
              ck g.bars.len == 1 and g.bars[0].pane == paneEditor and
                 g.bars[0].axis == axis and g.bars[0].cells == BarCells
    ck cases == 2 * 4 * 2 * 4 * 2

  test "§7.2 by name: each thickness's thumb and track":
    let m = scrubberModel(100, 30, 20)
    proc body(o: ScrollbarOptions; axis: BarAxis; state: BarState = bsIdle): string =
      let g = paintOne(o, axis, state, m)
      let (first, last) = o.thumbCellRange(axis, m.spanOf(BarCells), BarCells)
      g.cellAt(axis, (first + last) div 2)[0]
    let classic = DefaultScrollbarOptions
    var modern = classic
    modern.modernUnicode = true
    proc with(o: ScrollbarOptions; t: BarThickness): ScrollbarOptions =
      result = o
      result.thickness = t
    ck classic.with(btHairline).body(axVertical) == "▕"
    ck classic.with(btHairline).body(axHorizontal) == "▁"
    ck classic.with(btThin).body(axVertical) == "┃"
    ck classic.with(btThin).body(axHorizontal) == "━"
    ck classic.with(btThick).body(axVertical) == "▐"
    ck classic.with(btThick).body(axHorizontal) == "▄"
    ck classic.with(btFull).body(axVertical) == "█"
    ck classic.with(btFull).body(axHorizontal) == "▄"
    ck modern.with(btThin).body(axVertical) == "🮇"
    ck modern.with(btThin).body(axHorizontal) == "▂"
    # Widened under the pointer, from the edge.
    ck classic.with(btHairline).body(axVertical, bsHoverThumb) == "▐"
    ck classic.with(btHairline).body(axHorizontal, bsHoverThumb) == "▄"
    ck classic.with(btThin).body(axVertical, bsHeld) == "▐"
    ck classic.with(btThick).body(axVertical, bsHoverThumb) == "█"
    ck modern.with(btHairline).body(axVertical, bsHoverThumb) == "🮈"
    ck modern.with(btHairline).body(axHorizontal, bsHoverThumb) == "▃"
    # The tracks.
    ck ScrollbarGlyphs[gtClassic][btThin].rest[axVertical].track == "│"
    ck ScrollbarGlyphs[gtClassic][btThin].rest[axHorizontal].track == "─"
    ck ScrollbarGlyphs[gtClassic][btHairline].rest[axVertical].track == "▕"
    ck ScrollbarGlyphs[gtModern][btThin].rest[axVertical].track == "▕"
    # The thin thumb joins the track; the full thumb's ends are eighths.
    var onTrack = classic.with(btThin)
    onTrack.track = true
    let joined = paintOne(onTrack, axVertical, bsIdle,
                          scrubberModel(100, 33, 20))
    var sawJoin = false
    for i in 0 ..< BarCells:
      if joined.cellAt(axVertical, i)[0] in ["╽", "╿"]: sawJoin = true
    ck sawJoin
    ck ScrollbarGlyphs[gtModern][btFull].rest[axVertical].thumb.byMask[0b11] ==
       "🮂"
    ck ScrollbarGlyphs[gtClassic][btFull].rest[axVertical].thumb.byMask[0b11] ==
       "▔"
    ck ScrollbarGlyphs[gtClassic][btFull].rest[axVertical].thumb.byMask[0b1100_0000] ==
       "▂"

  test "the hit area is the thumb at rest, whatever it is drawn as":
    let m = scrubberModel(100, 30, 20)
    for t in BarThickness:
      let o = ScrollbarOptions(thickness: t)
      let rest = o.thumbCellRange(axVertical, m.spanOf(BarCells), BarCells)
      ck rest[0] >= 0 and rest[1] >= rest[0]
      let bar = BarSpot(pane: paneEditor, axis: axVertical, origin: 5, at: 2,
                        cells: BarCells, model: m)
      ck o.onThumb(bar, rest[0]) and o.onThumb(bar, rest[1])
      ck not o.onThumb(bar, rest[1] + 1)

  test "faded: absent at 1, recorded still; the mark is drawn in its role":
    let m = scrubberModel(100, 30, 20, current = 90)
    let gone = paintOne(DefaultScrollbarOptions, axVertical, bsIdle, m, 1.0)
    var drawn = 0
    for i in 0 ..< BarCells:
      if gone.cellAt(axVertical, i)[0] != " ": inc drawn
    ck drawn == 0
    ck gone.bars.len == 1
    var g = newStyledGrid(20, 20)
    g.fillSurface(0, 0, 20, 20, srSurfaceEditor)
    g.paintVerticalScrubber(5, 2, BarCells, m)
    var marked = 0
    for i in 0 ..< BarCells:
      if g.styleAt(2 + i, 5).role == srScrubberMark: inc marked
    ck marked == 1

suite "PLAT-70 Part H: the tiers":

  test "ASCII: the thumb is #, the track | and -":
    let ascii = TerminalCapabilities(colors: cdMonochrome, borders: bmAscii,
                                     mouse: true, mode: dmDark,
                                     palette: pkDesign, theme: utDark)
    var o = DefaultScrollbarOptions
    o.track = true
    for t in BarThickness:
      o.thickness = t
      for axis in BarAxis:
        let g = paintOne(o, axis, bsIdle, scrubberModel(100, 33, 20))
        var text = ""
        if axis == axVertical:
          for r in 2 ..< 2 + BarCells:
            for span in degradeRow(g.rowSpansIn(r, 5, 1), ascii):
              text.add span.text
        else:
          for span in degradeRow(g.rowSpansIn(5, 2, BarCells), ascii):
            text.add span.text
        let track = if axis == axVertical: '|' else: '-'
        var ok = text.len == BarCells
        for c in text:
          if c notin {'#', track}: ok = false
        if not ok: checkpoint($t & " " & $axis & ": '" & text & "'")
        ck ok and '#' in text and track in text

  test "a faded cell is blended at 24 bits and hidden from 1/2 on 16":
    let true24 = TerminalCapabilities(colors: cdTrueColor, borders: bmUnicode,
                                      mouse: true, mode: dmDark,
                                      palette: pkDesign, theme: utDark)
    var c16 = true24
    c16.colors = cdAnsi16
    let full = CellStyle(role: srScrollbarThumb, surface: srSurfaceEditor)
    var half = full
    half.faded = 0.5
    let a = degradeStyle(full, true24)
    let b = degradeStyle(half, true24)
    ck a.fg.len == 7 and b.fg.len == 7 and a.fg != b.fg and b.fg != b.bg
    var gone = full
    gone.faded = 0.6
    let d = degradeStyle(gone, c16)
    ck d.fg == d.bg
    var shown = full
    shown.faded = 0.4
    ck degradeStyle(shown, c16).fg == degradeStyle(full, c16).fg

suite "PLAT-70 Part H: modern-unicode reaches the position sliders too":

  test "a slider's partial cells are foreground glyphs, not reversed cells":
    # A one-cell thumb starting 3 eighths into cell 0: cell 0 holds its right
    # 5 eighths, cell 1 its left 3 (Terminal Output's screen scrubber).
    let span = ThumbSpan(start: 3, length: 8)
    let classic = thumbCells(span, 3, vertical = false)
    let modern = thumbCells(span, 3, vertical = false, modern = true)
    ck classic[0].kind == tcThumbReversed
    ck modern[0].kind == tcThumb and modern[0].glyph == "🮉"
    ck modern[1].kind == tcThumb and modern[1].glyph == classic[1].glyph
    # Down a vertical slider the thumb's bottom end is an exact upper eighth.
    let v = thumbCells(span, 3, vertical = true, modern = true)
    ck v[1].kind == tcThumb and v[1].glyph == "🮃"
    ck thumbCells(span, 3, vertical = true)[1].kind == tcThumbReversed
    # Every glyph the table adds degrades on the ASCII tier.
    ck asciiFor("🮉") == "#" and asciiFor("🮊") == "#" and asciiFor("🮋") == "#"

suite "PLAT-70 Part H: SB-1, one glyph table":

  test "no view but the style module paints a scrollbar role or its eighths":
    proc violations(name, text: string): seq[string] =
      if name in ["scrollbar_styles.nim", "scrubber_track.nim"]:
        return
      let lines = text.splitLines()
      for i, line in lines:
        let code = line.split("##")[0].split("# ")[0]
        if "srScrollbar" in code or "LowerEighths" in code or
           "LeftEighths" in code:
          result.add name & ":" & $(i + 1)
    let views = currentSourcePath().parentDir() / ".." / "app" / "views"
    var found: seq[string] = @[]
    var scanned = 0
    for f in walkDir(views):
      if f.path.endsWith(".nim"):
        inc scanned
        found.add violations(f.path.extractFilename, readFile(f.path))
    checkpoint("view modules scanned: " & $scanned & "; " & found.join(" "))
    ck scanned > 30
    ck found.len == 0
    # The planted violation reddens.
    ck violations("source_pane.nim",
                  "  g.paint(r, c, \"┃\", CellStyle(role: srScrollbarThumb))"
                 ).len == 1

# ---------------------------------------------------------------------------
# The runtime, on a real recording
# ---------------------------------------------------------------------------

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

let calc = resolveFixture(pythonSpec("calc"))

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard result.enableLayoutBinding()

proc sgr(code, row, col: int; release = false; motion = false): string =
  "\x1b[<" & $(code + (if motion: 32 else: 0)) & ";" & $(col + 1) & ";" &
    $(row + 1) & (if release: "m" else: "M")

proc send(s: TuiSession; rt: TuiRuntime; token: string; nowMs = 0'i64) =
  let outcome = rt.handleToken(token, nowMs)
  s.applyOutcome(rt, outcome)

proc open(path: string): (TuiRuntime, TuiSession) =
  let rt = newRuntime()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  (rt, s)

proc barOf(rt: TuiRuntime; pane: PaneKind; axis: BarAxis):
    tuple[found: bool, bar: BarSpot] =
  for b in rt.shellScreenOf().bars:
    if b.pane == pane and b.axis == axis:
      return (true, b)

proc thumbCells(rt: TuiRuntime; bar: BarSpot): (int, int) =
  rt.scrollbars.options.thumbCellRange(bar.axis, bar.model.spanOf(bar.cells),
                                       bar.cells)

proc rowOf(bar: BarSpot; cell: int): int = bar.at + cell

proc markFree(bar: BarSpot; first, last: int): int =
  ## A thumb cell the current-position mark is not drawn over.
  let mark = bar.model.currentMarkRow(0, bar.cells)
  for c in [(first + last) div 2, first + 1, last - 1, first, last]:
    if c >= first and c <= last and c != mark: return c
  first

proc roleAt(screen: ShellScreen; row, col: int): (string, SemanticRole) =
  var c = 0
  for span in screen.styledRows[row]:
    let w = span.text.runeLen
    if col >= c and col < c + w:
      return ($span.text.runeAtPos(col - c), span.style.role)
    c += w

proc roleAt(rt: TuiRuntime; row, col: int): (string, SemanticRole) =
  rt.shellScreenOf().roleAt(row, col)

suite "PLAT-70 Part H: every bar answers the pointer (a real recording)":

  test "hover, grab, jump, page and hold on the editor's bar":
    require calc.outcome == foRecorded
    let (rt, s) = open(calc.tracePath)
    defer: s.close()
    var (found, bar) = rt.barOf(paneEditor, axVertical)
    require found
    checkpoint("editor bar: col " & $bar.origin & " rows " & $bar.at & "+" &
               $bar.cells & " over " & $bar.model.total)
    ck bar.model.total > bar.cells
    var (first, last) = rt.thumbCells(bar)
    let inside = bar.markFree(first, last)
    # Hover on the thumb: widened, the hover role.
    s.send(rt, sgr(3, bar.rowOf(inside), bar.origin, motion = true))
    ck rt.scrollbars.pointer.active and
       rt.scrollbars.pointer.state == bsHoverThumb
    let (glyph, role) = rt.roleAt(bar.rowOf(inside), bar.origin)
    ck glyph == "▐" and role == srScrollbarThumbHover
    # Hover on the track: the track revealed, the thumb at rest.
    let away = if last + 3 < bar.cells: last + 3 else: 0
    s.send(rt, sgr(3, bar.rowOf(away), bar.origin, motion = true))
    ck rt.scrollbars.pointer.state == bsHoverTrack
    ck rt.roleAt(bar.rowOf(away), bar.origin) ==
       ("▕", srScrollbarTrackRevealed)
    ck rt.roleAt(bar.rowOf(inside), bar.origin)[1] == srScrollbarThumb
    # SB-3: grabbed by its LAST cell and moved 4 cells down, the thumb's
    # first cell moved 4 cells — the offset is kept.
    s.send(rt, sgr(0, bar.rowOf(last), bar.origin))
    ck rt.scrollbars.grab.active
    ck rt.scrollbars.pointer.state == bsHeld
    ck rt.roleAt(bar.rowOf(last), bar.origin)[1] == srScrollbarThumbHeld
    s.send(rt, sgr(0, bar.rowOf(last + 2), bar.origin, motion = true))
    s.send(rt, sgr(0, bar.rowOf(last + 4), bar.origin, motion = true))
    s.send(rt, sgr(0, bar.rowOf(last + 4), bar.origin, release = true))
    ck not rt.scrollbars.grab.active
    (found, bar) = rt.barOf(paneEditor, axVertical)
    let moved = rt.thumbCells(bar)
    checkpoint("thumb " & $first & ".." & $last & " -> " & $moved)
    ck moved[0] == first + 4
    # SB-4: a LEFT press on the track jumps (centring the row there) and
    # holds the thumb by its middle.
    let topBefore = bar.model.firstVisible
    s.send(rt, sgr(0, bar.rowOf(bar.cells - 1), bar.origin))
    ck rt.scrollbars.grab.active
    s.send(rt, sgr(0, bar.rowOf(bar.cells - 1), bar.origin, release = true))
    (found, bar) = rt.barOf(paneEditor, axVertical)
    ck bar.model.firstVisible == bar.model.maxFirstVisible
    ck bar.model.firstVisible != topBefore
    # A MIDDLE press on the track pages toward the pointer, one view less
    # one, and held it repeats until the thumb reaches the pointer.
    let atEnd = bar.model.firstVisible
    s.send(rt, sgr(1, bar.rowOf(0), bar.origin), 1000)
    (found, bar) = rt.barOf(paneEditor, axVertical)
    ck bar.model.firstVisible == max(0, atEnd - bar.model.pageSize)
    ck rt.scrollbars.paging.hold.active
    var pages = 1
    var t = 1000'i64 + RepeatDelayMs
    while rt.scrollbars.paging.hold.active and pages < 100:
      let ticked = rt.tickScrollbars(t)
      if ticked.sourceScroll.kind != sskNone:
        inc pages
        s.applyOutcome(rt, ticked)
      t += RepeatEveryMs
    (found, bar) = rt.barOf(paneEditor, axVertical)
    checkpoint("pages " & $pages & ", top " & $bar.model.firstVisible)
    ck bar.model.firstVisible == 0
    ck not rt.scrollbars.paging.hold.active
    s.send(rt, sgr(1, bar.rowOf(0), bar.origin, release = true), t)

  test "SB-6: the bars fade out, then back in on a scroll, in steps":
    require calc.outcome == foRecorded
    let (rt, s) = open(calc.tracePath)
    defer: s.close()
    discard rt.tickScrollbars(10_000)
    # The pointer rests in the editor's code, far from its bar, from the
    # start: what wakes the bars below is the SCROLL, not the pointer
    # coming in.
    block:
      let (found, bar) = rt.barOf(paneEditor, axVertical)
      require found
      s.send(rt, sgr(3, bar.at + 2, bar.origin - 10, motion = true), 10_000)
    discard rt.shellScreenOf()
    var levels: seq[float32] = @[]
    var t = 10_000'i64
    while t < 10_000 + FadeAfterMs + FadeOutMs + 64:
      discard rt.tickScrollbars(t)
      levels.add rt.scrollbarFrame().faded[paneEditor]
      t += 16
    var between = 0
    for v in levels:
      if v > 0 and v < 1: inc between
    ck levels[0] == 0 and levels[^1] == 1
    ck between >= 10
    # A wheel scrolls the editor: its bars wake and fade back in, in steps.
    let (found, bar) = rt.barOf(paneEditor, axVertical)
    require found
    s.send(rt, sgr(65, bar.at + 2, bar.origin - 10), t)
    discard rt.shellScreenOf()
    var back: seq[float32] = @[]
    for i in 0 .. 20:
      discard rt.tickScrollbars(t + int64(i) * 16)
      back.add rt.scrollbarFrame().faded[paneEditor]
    var rising = 0
    for v in back:
      if v > 0 and v < 1: inc rising
    checkpoint("fade in: " & $back)
    ck rising >= 5
    ck back[^1] == 0
    # A pointer that arrives just before the loop's next idle tick (they are
    # `IdlePollMs`, 200 ms, apart while every bar is gone): the fade-in
    # starts at its arrival, so the frame right after it is still almost
    # faded — never an instant fade-in.
    let u = t + 20 * 16 + FadeAfterMs + FadeOutMs + 100
    discard rt.tickScrollbars(u)
    ck rt.scrollbarFrame().faded[paneEditor] == 1
    s.send(rt, sgr(35, bar.at + 2, bar.origin, motion = true), u + 199)
    discard rt.tickScrollbars(u + 199)
    checkpoint("the frame after the pointer came: faded " &
               $rt.scrollbarFrame().faded[paneEditor])
    ck rt.scrollbarFrame().faded[paneEditor] > 0.8
    # With `scrollbar-fade off` nothing fades.
    discard rt.applyLayoutSetting(lsScrollbarFade, "off", remember = false)
    for i in 0 .. 200:
      discard rt.tickScrollbars(t + 5000 + int64(i) * 16)
      ck rt.scrollbarFrame().faded[paneEditor] == 0

  test "SB-7: `:set scrollbar-thickness thick` re-draws every bar, remembered":
    require calc.outcome == foRecorded
    let (rt, s) = open(calc.tracePath)
    defer: s.close()
    var saved: seq[(string, string)] = @[]
    rt.savePreference = proc(name, value: string): string =
      saved.add (name, value)
      ""
    s.send(rt, ":")
    for c in "set scrollbar-thickness thick": s.send(rt, $c)
    s.send(rt, "\r")
    ck saved == @[("scrollbar-thickness", "thick")]
    ck rt.scrollbars.options.thickness == btThick
    let (found, bar) = rt.barOf(paneEditor, axVertical)
    require found
    let (first, last) = rt.thumbCells(bar)
    ck rt.roleAt(bar.rowOf(bar.markFree(first, last)), bar.origin) ==
       ("▐", srScrollbarThumbSolid)
    s.send(rt, ":")
    for c in "set scrollbar-thickness huge": s.send(rt, $c)
    s.send(rt, "\r")
    ck rt.app.notification.contains("huge")
    ck rt.scrollbars.options.thickness == btThick

  test "SB-8: every pane with a bar answers hover and a paging press":
    require calc.outcome == foRecorded
    let (rt, s) = open(calc.tracePath)
    defer: s.close()
    var answered: seq[string] = @[]
    for b in rt.shellScreenOf().bars:
      if b.model.total <= b.model.visible:
        continue
      let (first, last) = rt.thumbCells(b)
      let onThumb = if b.axis == axVertical: (b.at + first, b.origin)
                    else: (b.origin, b.at + first)
      s.send(rt, sgr(3, onThumb[0], onThumb[1], motion = true))
      ck rt.scrollbars.pointer.pane == b.pane and
         rt.scrollbars.pointer.axis == b.axis and
         rt.scrollbars.pointer.state == bsHoverThumb
      # Drawn hovered on that bar, and on no other.
      let screen = rt.shellScreenOf()
      var elsewhere = 0
      for other in screen.bars:
        if other.pane == b.pane and other.axis == b.axis: continue
        for i in 0 ..< other.cells:
          let (row, col) = if other.axis == axVertical: (other.at + i, other.origin)
                           else: (other.origin, other.at + i)
          if screen.roleAt(row, col)[1] == srScrollbarThumbHover: inc elsewhere
      ck elsewhere == 0
      let far = if last + 1 < b.cells: b.cells - 1 else: 0
      let onTrack = if b.axis == axVertical: (b.at + far, b.origin)
                    else: (b.origin, b.at + far)
      let before = b.model.firstVisible
      s.send(rt, sgr(1, onTrack[0], onTrack[1]))
      s.send(rt, sgr(1, onTrack[0], onTrack[1], release = true))
      var after = -1
      for b2 in rt.shellScreenOf().bars:
        if b2.pane == b.pane and b2.axis == b.axis:
          after = b2.model.firstVisible
      checkpoint($b.pane & " " & $b.axis & ": " & $before & " -> " & $after)
      ck after != before
      answered.add $b.pane & "/" & $b.axis
    checkpoint("bars answered: " & answered.join(" "))
    ck answered.len >= 2

suite "PLAT-70 Part H: assertion count":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
