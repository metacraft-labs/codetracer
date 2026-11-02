## test_plat71_glyph_table.nim — PLAT-71, Tier 1. The ONE glyph table
## (CodeTracer-TUI-Terminal-Adaptation.md §6), drawn.
##
##   * TA-6 — no chrome code point under `tui/app/views/` outside the table: a
##     source gate over every view module, with a PLANTED `"▏"` that the gate
##     must find (a gate that found nothing on a planted control is not a
##     gate);
##   * TA-7 — content is never transliterated: a source line holding `● ─ …`
##     is drawn verbatim on the ASCII tier, while the gutter's breakpoint mark
##     on the same row is the table's `*`;
##   * every profile's FULL SCREEN, painted by the runtime on a real recording
##     (the calc fixture, ASCII source): on the ASCII tier every cell of the
##     chrome is ASCII; under the ambiguous-wide rule no cell is an East Asian
##     Width `A` glyph (TA-8, on a painted screen rather than on the table);
##     on `basic` no glyph outside the WGL4 drawing set; with `modern-unicode`
##     resolved on, a thin scrollbar is drawn with `🮇`;
##   * §9.2 — the Event Log's location column loses its MIDDLE and keeps the
##     file name, its `…` recorded where it is drawn, and drawn as the
##     table's marker on the ASCII tier; a number value is never cut
##     silently;
##   * §8 — a copy on a terminal the profile found no OSC 52 writer for says
##     the text stayed inside CodeTracer and where to look; on one that takes
##     OSC 52 it says only what was copied.
##
## No mocks. The recording is real (`fixture_provider`), the runtime is the
## shipped one, and the screens are its own `shellScreenOf`.
##
## Templates, not procs, for anything that calls `check`.

import std/[os, strutils, unicode, unittest]

import isonim_tui
import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/borders
import ../app/views/glyph_table
import ../app/views/scrollbar_styles
import ../app/views/source_pane
import ../app/views/styled_row
import ../app/views/gutter
import ../app/views/event_log
import ../app/formatters/type_formatters
import ../app/views/tree_node
import ../app/layout/cells
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 41

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 140
  Rows = 40
  TableModules = ["glyph_table.nim", "scrollbar_styles.nim", "borders.nim"]
    ## The table itself (§6.3, and its scrollbar part §6.4; `borders` is a
    ## view onto it whose ASCII map is derived, not spelled).

proc chromeCodePoints(): seq[string] =
  ## Every non-ASCII glyph the table can produce, the scrollbar part
  ## included — what may appear only in the table.
  result = allChromeCodePoints()
  for tier in GlyphTier:
    for thickness in BarThickness:
      for looks in [ScrollbarGlyphs[tier][thickness].rest,
                    ScrollbarGlyphs[tier][thickness].widened]:
        for axis in BarAxis:
          for g in looks[axis].thumb.byMask & looks[axis].thumb.joined &
                   @[looks[axis].track]:
            if g.len > 0 and ord(g[0]) >= 0x80 and g != RvSpace and
               g notin result:
              result.add g

proc codeOf(line: string): string =
  ## A source line without its comment: everything before the first `#` that
  ## is not inside a string or character literal.
  var inStr = false
  var i = 0
  while i < line.len:
    let c = line[i]
    if inStr:
      if c == '\\': inc i
      elif c == '"': inStr = false
    elif c == '"':
      inStr = true
    elif c == '\'' and i + 2 < line.len and line[i + 2] == '\'':
      i += 2
    elif c == '#':
      return line[0 ..< i]
    inc i
  line

proc violations(source: string; forbidden: seq[string]): seq[string] =
  ## The lines of `source` whose CODE spells a chrome code point.
  var n = 0
  for line in source.splitLines():
    inc n
    let code = codeOf(line)
    for g in forbidden:
      if code.contains(g):
        result.add $n & ": " & g & "  " & line.strip
        break

proc viewsDir(): string = repoRoot() / "src/frontend/tui/app/views"

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

proc capsWith(tier: ChromeTier; ambiguousWide = false;
              modern = false): TerminalCapabilities =
  result = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result.tier = tier
  result.borders = if tier == tierAscii: bmAscii else: bmUnicode
  result.ambiguousWide = ambiguousWide
  result.modernUnicode = modern

proc screenOf(path: string; caps: TerminalCapabilities): seq[string] =
  ## The whole screen the runtime paints on this profile, row by row.
  let rt = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard rt.enableLayoutBinding()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  result = rt.shellScreenOf().rows
  s.close()

var contentRunes: seq[string] = @[]
  ## Every non-ASCII character of the recorded PROGRAM — content, which the
  ## screen draws as recorded on every tier (TA-7). The calc program's
  ## docstring has em dashes; they are not chrome.

proc isContent(rune: Rune): bool = $rune in contentRunes

proc nonAsciiCells(rows: seq[string]): seq[string] =
  for r, row in rows:
    for rune in row.runes:
      if int(rune) >= 0x80 and not rune.isContent:
        result.add $r & ":" & $rune

const Wgl4Drawing = [
  # §6.1's `basic` tier: WGL4 / CP437 box drawing, blocks and shades, the
  # marks it lists, and the typographic punctuation a font with them has.
  "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "═", "║",
  "▀", "▄", "█", "▌", "▐", "░", "▒", "▓", "●", "○", "♦", "▲", "▼", "►",
  "◄", "■", "□", "·", "…", "‹", "›", "≡", "×", "ƒ", "•", "—", "–"]

suite "PLAT-71 Tier 1: the glyph table, drawn":

  test "TA-6: no chrome code point in a view outside the table":
    let forbidden = chromeCodePoints()
    checkpoint("chrome code points owned by the table: " & $forbidden.len)
    ck forbidden.len > 60
    # THE PLANTED CONTROL: the same scan over a line that spells one.
    ck violations("  DividerGlyph* = \"▏\"", forbidden).len == 1
    ck violations("  ## a comment that names ▏ is fine", forbidden).len == 0
    ck violations("  x = \"#\" & \"▏\"  # trailing", forbidden).len == 1
    var scanned = 0
    var found: seq[string] = @[]
    for path in walkFiles(viewsDir() / "*.nim"):
      let name = extractFilename(path)
      if name in TableModules:
        continue
      inc scanned
      for v in violations(readFile(path), forbidden):
        found.add name & ":" & v
    checkpoint("view modules scanned: " & $scanned & "; violations: " & $found)
    ck scanned > 30
    ck found.len == 0

  test "TA-7: content is never transliterated on the ASCII tier":
    var g = newStyledGrid(60, 4)
    g.glyphs = GlyphProfile(tier: tierAscii)
    let model = initSourcePaneModel(path = "content.py", firstHeldLine = 1,
      heldLines = @["s = \"● ─ …\"  # the program's own glyphs"],
      totalLineCount = 1, viewportTop = 1,
      marks = @[(1, gmBreakpoint)])
    discard paintSourcePane(g, CellArea(col: 0, row: 0, width: 60, height: 3),
                            model)
    var text = ""
    for r in 0 ..< 3:
      text.add g.rowText(r) & "\n"
    checkpoint(text)
    ck text.contains("\"● ─ …\"")      # the program's text, verbatim
    ck text.contains("*")             # the table's ASCII breakpoint
    ck not text.contains("●  ")       # …not the Unicode mark in the gutter

  test "every profile's full screen on a real recording":
    let calc = resolveFixture(pythonSpec("calc"))
    if calc.outcome != foRecorded:
      checkpoint(calc.detail)
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      let program = repoRoot() / calc.spec.program
      ck fileExists(program)
      for rune in readFile(program).runes:
        if int(rune) >= 0x80 and $rune notin contentRunes:
          contentRunes.add $rune
      checkpoint("the program's own non-ASCII characters: " & $contentRunes)
      let extended = screenOf(calc.tracePath, capsWith(tierExtended))
      ck nonAsciiCells(extended).len > 0      # the Unicode chrome is there
      # ASCII: every cell is ASCII (the calc program's source is ASCII).
      let ascii = screenOf(calc.tracePath, capsWith(tierAscii))
      let leaks = nonAsciiCells(ascii)
      checkpoint("ASCII-tier non-ASCII cells: " & $leaks)
      if leaks.len > 0:
        for r, row in ascii:
          checkpoint($r & "| " & row)
      ck leaks.len == 0
      # Ambiguous-wide: no East Asian Width `A` glyph on the screen at all.
      let wide = screenOf(calc.tracePath, capsWith(tierExtended,
                                               ambiguousWide = true))
      var ambiguous: seq[string] = @[]
      for r, row in wide:
        for rune in row.runes:
          # The truncation marker is `…` drawn as two cells by decision
          # (OQ-T2), and the program's own text is drawn as recorded.
          if eawClass(int32(rune)) == eawAmbiguous and $rune != "…" and
             not rune.isContent:
            ambiguous.add $r & ":" & $rune
      checkpoint("ambiguous-wide EAW-A cells: " & $ambiguous)
      ck ambiguous.len == 0
      # Basic: only the WGL4 drawing set.
      let basic = screenOf(calc.tracePath, capsWith(tierBasic))
      var outside: seq[string] = @[]
      for r, row in basic:
        for rune in row.runes:
          if int(rune) >= 0x80 and $rune notin Wgl4Drawing and
             not rune.isContent:
            outside.add $r & ":" & $rune
      checkpoint("basic-tier glyphs outside WGL4: " & $outside)
      ck outside.len == 0

  test "modern-unicode resolved on draws the Legacy Computing thumb":
    var o = DefaultScrollbarOptions
    o.thickness = btThin
    o.modernUnicode = true
    ck o.glyphTierOf(GlyphProfile()) == gtModern
    ck o.lookOf(axVertical, bsIdle, gtModern).thumb.byMask[^1] == "🮇"
    ck o.glyphTierOf(GlyphProfile(ambiguousWide: true)) == gtAmbiguousModern
    ck o.lookOf(axVertical, bsIdle, gtAmbiguousModern).thumb.byMask[^1] == "🮇"
    ck o.lookOf(axHorizontal, bsIdle, gtAmbiguousModern).thumb.byMask[^1] ==
       RvSpace
    ck o.glyphTierOf(GlyphProfile(tier: tierBasic)) == gtBasic
    ck o.glyphTierOf(GlyphProfile(tier: tierAscii)) == gtAscii
    o.modernUnicode = false
    ck o.glyphTierOf(GlyphProfile()) == gtClassic

  test "§6.6: one width function, under an explicit policy":
    # A combining mark and a joiner take no cell of their own — the
    # compositor draws none for them, so counting one shifts the row.
    ck cellWidthOf("e\u0301") == 1
    ck cellWidthOf("a\u200Db") == 2
    ck cellWidthOf("…") == 1
    ck cellWidthOf("…", awWide) == 2
    ck cellSlice("e\u0301xyz", 0, 2) == "e\u0301x"
    ck padRight("…", 3, awWide) == "… "
    # The grid paints under ITS policy: on a wide terminal the cell after an
    # East Asian Width `A` character is two columns on.
    var g = newStyledGrid(10, 1)
    g.ambiguous = awWide
    g.paint(0, 0, "…x")
    ck g.runeAt(0, 0) == "…" and g.runeAt(0, 1) == "" and g.runeAt(0, 2) == "x"
    var n = newStyledGrid(10, 1)
    n.paint(0, 0, "e\u0301x")
    ck n.runeAt(0, 1) == "x"

  test "§9.2: a path loses its middle, a number is never cut silently":
    const File = "src/frontend/a_rather_long_module_name_for_the_log.py"
    var rows: seq[EventRow] = @[]
    for i in 0 ..< 3:
      rows.add EventRow(index: i, tick: uint64(1000 + i), file: File,
                        line: 120 + i, content: "out " & $i,
                        category: ecOutput)
    let pages: EventPages = proc(offset, limit: int): EventPage =
      var page = EventPage(total: rows.len)
      for k in offset ..< min(rows.len, offset + limit):
        page.rows.add rows[k]
      page.atEnd = offset + limit >= rows.len
      page
    var model = initEventLogModel(pages = pages, pageSize = 32)
    model.ensureWindow(0, rows.len)
    discard model.columns.showColumn(elcLocation)
    discard model.columns.setColumnWidth(elcLocation, 18)
    let screen = eventLogScreen(model, 90, 8)
    var locCut: seq[CutCell] = @[]
    for c in screen.cuts:
      if c.column == $elcLocation: locCut.add c
    ck locCut.len == 3
    proc textOf(row: StyledRow): string =
      for span in row: result.add span.text
    var drawn = ""
    for (col, at, w) in screen.columnCells:
      if col == elcLocation:
        let row = screen.rows[screen.headerRow + 1].textOf
        drawn = row.runeSubStr(at, w).strip
    checkpoint("the location drawn: " & drawn)
    # The line number — the end — and the name's start both stay; the `…`
    # is in between (the end cut would have lost the line number).
    ck drawn.startsWith("a_r") and drawn.endsWith(":120") and
       drawn.contains("…") and not drawn.endsWith("…")
    if locCut.len > 0:
      # The `…` is recorded where it is drawn, in the middle.
      let row = screen.rows[locCut[0].row].textOf
      ck row.runeSubStr(locCut[0].ellipsisCol, 1) == "…"
    # On the ASCII tier the middle `…` is the table's marker, in the middle.
    let ascii = markCut(fitCellAs("a_rather_long_name.py:120", 12, ckPath),
                        glyphProfileOf(capsWith(tierAscii)))
    checkpoint("ASCII: " & ascii)
    ck ascii.contains("~") and not ascii.contains("…") and
       ascii.endsWith(":120")
    # A raw number value narrower than its digits: never a prefix of them.
    let num = valueCell(TreeRowSpec(name: "n", value: "123456789012"), 6)
    checkpoint("the number drawn: " & num.text)
    ck num.truncated and num.text == "1e+11"
    let num7 = valueCell(TreeRowSpec(name: "n", value: "123456789012"), 7)
    ck num7.truncated and num7.text == "1.2e+11"

  test "§8: a copy without OSC 52 says it stayed inside CodeTracer":
    let calc = resolveFixture(pythonSpec("calc"))
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      proc copied(clipboard: string): string =
        var caps = capsWith(tierExtended)
        caps.clipboard = clipboard
        let rt = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
        discard rt.enableLayoutBinding()
        let s = openTuiSession(calc.tracePath, viewportHeight = Rows - 8)
        s.header(rt)
        s.learnExtent()
        s.refresh(rt)
        discard rt.focusHostedPane(paneCalltrace)
        discard rt.runNamedOperation("list.copy", "", 0)
        result = rt.app.notification
        s.close()
      # No identity that takes OSC 52, no tmux passing it on (xterm here).
      let resolved = capsWith(tierExtended)
      ck resolved.clipboard == ClipboardInAppOnly
      let inApp = copied(resolved.clipboard)
      checkpoint("in-app only: " & inApp)
      ck inApp.startsWith("copied ") and inApp.endsWith(InAppOnlyCopyNote)
      let osc = copied("osc52")
      checkpoint("osc52: " & osc)
      ck osc.startsWith("copied ") and not osc.contains("inside CodeTracer")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
